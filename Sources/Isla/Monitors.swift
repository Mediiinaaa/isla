import AppKit
import AudioToolbox
import CoreAudio
import IOKit.ps

// MARK: - Música

enum Player: String {
    case spotify = "Spotify"
    case music = "Music"

    var bundleID: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
    var notification: String { self == .spotify ? "com.spotify.client.PlaybackStateChanged" : "com.apple.Music.playerInfo" }
}

enum RepeatMode: Equatable {
    case off, all, one

    var symbol: String { self == .one ? "repeat.1" : "repeat" }

    /// Spotify devuelve un booleano y Música el modo; el script de detalles escribe uno de los dos.
    init(script text: String) {
        switch text {
        case "one": self = .one
        case "all", "true": self = .all
        default: self = .off
        }
    }
}

struct Track: Equatable {
    var player: Player
    var title: String
    var artist: String
    var isPlaying: Bool
    var duration: Double?
    var position: Double?
    var positionDate = Date()
    var shuffle: Bool?
    var repeatMode: RepeatMode?

    func position(at date: Date) -> Double? {
        guard let position else { return nil }
        let elapsed = isPlaying ? date.timeIntervalSince(positionDate) : 0
        return min(position + elapsed, duration ?? .greatestFiniteMagnitude)
    }
}

enum MediaCommand: String {
    case playPause = "playpause"
    case next = "next track"
    case previous = "previous track"
}

/// Spotify y Música anuncian cada cambio con una notificación distribuida.
final class MediaMonitor {
    var onChange: ((Track?) -> Void)?
    var onArtwork: ((NSImage?) -> Void)?
    private var current: Track?
    private var artworkKey: String?
    /// Una posición pedida antes de un salto llega con el valor antiguo y se descarta.
    private var seekDate = Date.distantPast
    private let artworkPath = NSTemporaryDirectory() + "isla-artwork"

    func start() {
        for player in [Player.spotify, .music] {
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(player.notification),
                object: nil,
                queue: .main
            ) { [weak self] note in
                self?.handle(note.userInfo, from: player)
            }
            queryIfRunning(player)
        }
    }

    func send(_ command: MediaCommand) {
        guard let player = current?.player else { return }
        runAppleScript("tell application \"\(player.rawValue)\" to \(command.rawValue)") { _ in }
    }

    func toggleShuffle() {
        guard var track = current else { return }
        let command = track.player == .spotify ? "set shuffling to not shuffling" : "set shuffle enabled to not shuffle enabled"
        runAppleScript("tell application \"\(track.player.rawValue)\" to \(command)") { _ in }
        track.shuffle = !(track.shuffle ?? false)
        current = track
        onChange?(track)
    }

    /// Música pasa por todas, una y desactivado; Spotify no permite repetir una sola desde AppleScript.
    func toggleRepeat() {
        guard var track = current else { return }
        let mode = track.repeatMode ?? .off
        let command: String
        switch track.player {
        case .spotify:
            command = "set repeating to not repeating"
            track.repeatMode = mode == .off ? .all : .off
        case .music:
            command = """
            if song repeat is off then
                set song repeat to all
            else if song repeat is all then
                set song repeat to one
            else
                set song repeat to off
            end if
            """
            track.repeatMode = mode == .off ? .all : mode == .all ? .one : .off
        }
        runAppleScript("tell application \"\(track.player.rawValue)\"\n\(command)\nend tell") { _ in }
        current = track
        onChange?(track)
    }

    func seek(to seconds: Double) {
        guard var track = current else { return }
        // Se vuelve a preguntar al terminar para no leer la posición antigua mientras el reproductor salta.
        runAppleScript("tell application \"\(track.player.rawValue)\" to set player position to \(String(format: "%.2f", seconds))") { [weak self] _ in
            self?.refreshDetails()
        }
        track.position = seconds
        track.positionDate = Date()
        seekDate = track.positionDate
        current = track
        onChange?(track)
    }

    /// Las notificaciones no traen carátula ni posición fiables, así que se piden al reproductor.
    func refreshDetails() {
        guard let track = current else { return }
        let key = track.player.rawValue + track.title + track.artist
        runAppleScript(detailsScript(for: track.player)) { [weak self] output in
            guard let self, var latest = self.current, latest.player == track.player else { return }
            let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard lines.count == 5 else { return }
            latest.duration = Self.number(lines[1])
            latest.position = Self.number(lines[2])
            latest.positionDate = Date()
            latest.shuffle = lines[3] == "true"
            latest.repeatMode = RepeatMode(script: lines[4])
            self.current = latest
            self.onChange?(latest)
            if self.artworkKey != key {
                self.artworkKey = key
                self.loadArtwork(player: track.player, reference: lines[0])
            }
        }
    }

    /// Solo la posición: es barato y mantiene la letra a tiempo aunque se salte desde el propio reproductor.
    func syncPosition() {
        guard let track = current, track.isPlaying,
              !NSRunningApplication.runningApplications(withBundleIdentifier: track.player.bundleID).isEmpty
        else { return }
        let requested = Date()
        runAppleScript("tell application \"\(track.player.rawValue)\" to return player position") { [weak self] output in
            guard let self, requested > self.seekDate, var latest = self.current, latest.player == track.player,
                  latest.title == track.title, latest.artist == track.artist, let position = Self.number(output)
            else { return }
            let now = Date()
            // Un desfase pequeño es el propio retraso de osascript: corregirlo haría temblar la barra
            if let estimated = latest.position(at: now), abs(estimated - position) < 0.3 { return }
            latest.position = position
            latest.positionDate = now
            self.current = latest
            self.onChange?(latest)
        }
    }

    private func detailsScript(for player: Player) -> String {
        switch player {
        case .spotify:
            return """
            tell application "Spotify"
                return (artwork url of current track) & linefeed & ((duration of current track) / 1000) & linefeed & (player position) & linefeed & shuffling & linefeed & repeating
            end tell
            """
        case .music:
            return """
            set hasArt to false
            tell application "Music"
                set d to duration of current track
                set p to player position
                set s to shuffle enabled
                if song repeat is one then
                    set r to "one"
                else if song repeat is all then
                    set r to "all"
                else
                    set r to "off"
                end if
                try
                    set a to raw data of artwork 1 of current track
                    set hasArt to true
                end try
            end tell
            if hasArt then
                set f to open for access (POSIX file "\(artworkPath)") with write permission
                set eof f to 0
                write a to f
                close access f
            end if
            return (hasArt as text) & linefeed & d & linefeed & p & linefeed & s & linefeed & r
            """
        }
    }

    private func loadArtwork(player: Player, reference: String) {
        switch player {
        case .music:
            onArtwork?(reference == "true" ? NSImage(contentsOfFile: artworkPath) : nil)
        case .spotify:
            onArtwork?(nil)
            guard let url = URL(string: reference), url.scheme == "https" else { return }
            let key = artworkKey
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                let image = data.flatMap(NSImage.init(data:))
                DispatchQueue.main.async {
                    guard let self, self.artworkKey == key else { return }
                    self.onArtwork?(image)
                }
            }.resume()
        }
    }

    /// AppleScript escribe los decimales según el idioma del sistema («1,5» en español).
    private static func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }

    private func handle(_ info: [AnyHashable: Any]?, from player: Player) {
        let state = info?["Player State"] as? String
        if state == "Stopped" {
            if current?.player == player { update(nil) }
            return
        }
        var track = Track(
            player: player,
            title: info?["Name"] as? String ?? "",
            artist: info?["Artist"] as? String ?? "",
            isPlaying: state == "Playing"
        )
        // Si sigue la misma canción se conservan los datos para que la barra no se vacíe hasta el siguiente refresco.
        if let current, current.player == player, current.title == track.title, current.artist == track.artist {
            track.duration = current.duration
            track.position = current.position(at: Date())
            track.shuffle = current.shuffle
            track.repeatMode = current.repeatMode
        }
        // Spotify manda «Duration» y Música «Total Time», los dos en milisegundos
        if let milliseconds = (info?["Duration"] ?? info?["Total Time"]) as? NSNumber, milliseconds.doubleValue > 0 {
            track.duration = milliseconds.doubleValue / 1000
        }
        if let position = info?["Playback Position"] as? Double { track.position = position }
        update(track)
    }

    /// Las notificaciones solo llegan al cambiar algo, así que al arrancar se pregunta al reproductor.
    private func queryIfRunning(_ player: Player) {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty else { return }
        let script = """
        tell application "\(player.rawValue)"
            if player state is playing then return name of current track & linefeed & artist of current track
        end tell
        """
        runAppleScript(script) { [weak self] output in
            let lines = output.split(separator: "\n", maxSplits: 1).map(String.init)
            guard let title = lines.first else { return }
            self?.update(Track(player: player, title: title, artist: lines.count > 1 ? lines[1] : "", isPlaying: true))
        }
    }

    private func update(_ track: Track?) {
        current = track
        onChange?(track)
        if track == nil {
            artworkKey = nil
            onArtwork?(nil)
        } else {
            refreshDetails()
        }
    }

    /// Se usa osascript en segundo plano para que la petición de permiso no congele la interfaz.
    private func runAppleScript(_ source: String, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { completion(output) }
        }
    }
}

// MARK: - Batería

struct BatteryState: Equatable {
    var level: Int
    var pluggedIn: Bool
}

final class PowerMonitor {
    private static let changed = Notification.Name("IslaPowerChanged")
    var onChange: ((BatteryState?) -> Void)?

    func start() {
        NotificationCenter.default.addObserver(forName: Self.changed, object: nil, queue: .main) { [weak self] _ in
            self?.onChange?(Self.read())
        }
        let source = IOPSNotificationCreateRunLoopSource({ _ in
            NotificationCenter.default.post(name: PowerMonitor.changed, object: nil)
        }, nil).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        onChange?(Self.read())
    }

    private static func read() -> BatteryState? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as Array
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let level = description[kIOPSCurrentCapacityKey] as? Int
            else { continue }
            let state = description[kIOPSPowerSourceStateKey] as? String
            return BatteryState(level: level, pluggedIn: state == kIOPSACPowerValue)
        }
        return nil
    }
}

// MARK: - Volumen

final class VolumeMonitor {
    var onChange: ((Float) -> Void)?
    var onOutputChange: ((AudioOutput) -> Void)?
    var onDevicesChange: (() -> Void)?
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var lastVolume: Float?

    private var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private lazy var volumeListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        guard let self, let volume = self.effectiveVolume(), volume != self.lastVolume else { return }
        self.lastVolume = volume
        self.onChange?(volume)
    }

    func start() {
        var defaultDevice = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultDevice, .main) { [weak self] _, _ in
            guard let self else { return }
            self.bindDefaultDevice()
            if let output = AudioOutputs.output(for: self.device) { self.onOutputChange?(output) }
        }
        var devices = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devices, .main) { [weak self] _, _ in
            self?.onDevicesChange?()
        }
        bindDefaultDevice()
    }

    func adjust(by delta: Float) -> Bool {
        guard var volume = readVolume() else { return false }
        volume = min(max(volume + delta, 0), 1)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectSetPropertyData(device, &volumeAddress, 0, nil, size, &volume) == noErr else { return false }
        if isMuted == true {
            var unmuted = UInt32(0)
            size = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectSetPropertyData(device, &muteAddress, 0, nil, size, &unmuted)
        }
        return true
    }

    func toggleMute() -> Bool {
        guard let muted = isMuted else { return false }
        var value: UInt32 = muted ? 0 : 1
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(device, &muteAddress, 0, nil, size, &value) == noErr
    }

    private func bindDefaultDevice() {
        if device != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(device, &volumeAddress, .main, volumeListener)
            AudioObjectRemovePropertyListenerBlock(device, &muteAddress, .main, volumeListener)
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard device != kAudioObjectUnknown else { return }
        // Cambiar de altavoz o auriculares no debe mostrarse como un cambio de volumen
        lastVolume = effectiveVolume()
        if AudioObjectHasProperty(device, &volumeAddress) {
            AudioObjectAddPropertyListenerBlock(device, &volumeAddress, .main, volumeListener)
        }
        if AudioObjectHasProperty(device, &muteAddress) {
            AudioObjectAddPropertyListenerBlock(device, &muteAddress, .main, volumeListener)
        }
    }

    private var isMuted: Bool? {
        guard device != kAudioObjectUnknown, AudioObjectHasProperty(device, &muteAddress) else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private func effectiveVolume() -> Float? {
        isMuted == true ? 0 : readVolume()
    }

    private func readVolume() -> Float? {
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &volume)
        return status == noErr ? volume : nil
    }
}

// MARK: - Salidas de audio

struct AudioOutput: Identifiable, Equatable {
    var id: AudioObjectID
    var name: String
    var transport: UInt32

    var symbol: String {
        let name = name.lowercased()
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            if name.contains("airpods max") { return "airpodsmax" }
            if name.contains("airpods pro") { return "airpodspro" }
            if name.contains("airpods") { return "airpods" }
            if name.contains("beats") { return "beats.headphones" }
            return name.contains("speaker") || name.contains("altavoz") ? "hifispeaker.fill" : "headphones"
        case kAudioDeviceTransportTypeAirPlay:
            return name.contains("homepod") ? "homepod.fill" : "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "tv"
        case kAudioDeviceTransportTypeBuiltIn:
            if name.contains("auricular") || name.contains("headphone") { return "headphones" }
            return name.contains("macbook") ? "laptopcomputer" : "speaker.wave.2.fill"
        default:
            return "hifispeaker.fill"
        }
    }
}

enum AudioOutputs {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    /// Dispositivos que pueden sonar y que macOS ofrece como salida, por orden alfabético.
    static func all() -> [AudioOutput] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(output(for:)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func output(for device: AudioObjectID) -> AudioOutput? {
        guard device != kAudioObjectUnknown else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return nil }

        // Los dispositivos ocultos o que no pueden ser la salida principal no se ofrecen
        var flag = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyIsHidden
        address.mScope = kAudioObjectPropertyScopeGlobal
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &flag) == noErr, flag != 0 { return nil }
        address.mSelector = kAudioDevicePropertyDeviceCanBeDefaultDevice
        address.mScope = kAudioDevicePropertyScopeOutput
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &flag) == noErr, flag == 0 { return nil }

        address.mSelector = kAudioObjectPropertyName
        address.mScope = kAudioObjectPropertyScopeGlobal
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let label = name?.takeRetainedValue() as String?, !label.hasPrefix("CADefaultDeviceAggregate")
        else { return nil }

        address.mSelector = kAudioDevicePropertyTransportType
        var transport = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        return AudioOutput(id: device, name: label, transport: transport)
    }

    static var defaultID: AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(system, &address, 0, nil, &size, &device)
        return device
    }

    static func select(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = device
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        return AudioObjectSetPropertyData(system, &address, 0, nil, size, &device) == noErr
    }
}

// MARK: - Bloqueo

/// Avisa cuando el Mac se bloquea o se apaga la pantalla (al pulsar el botón de encendido,
/// por ejemplo), para que la isla no se vea mientras tanto.
final class ScreenLockMonitor {
    /// true mientras la isla debe estar oculta.
    var onChange: ((Bool) -> Void)?
    private var locked = false
    private var displaysAsleep = false
    private var hidden = false
    private var check: Timer?

    func start() {
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, "com.apple.screenIsLocked") { $0.setLocked(true) }
        observe(distributed, "com.apple.screenIsUnlocked") { $0.setLocked(false) }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification.rawValue) { $0.displaysAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification.rawValue) { $0.displaysAsleep = false }
        if Self.sessionIsLocked() { setLocked(true) }
        update()
    }

    private func observe(_ center: NotificationCenter, _ name: String, _ change: @escaping (ScreenLockMonitor) -> Void) {
        center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            change(self)
            self.update()
        }
    }

    private func update() {
        let value = locked || displaysAsleep
        guard value != hidden else { return }
        hidden = value
        onChange?(value)
    }

    private func setLocked(_ value: Bool) {
        locked = value
        check?.invalidate()
        check = nil
        guard value else { return }
        // Por si se pierde el aviso de desbloqueo: la isla no debe quedarse escondida
        check = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, !Self.sessionIsLocked() else { return }
            self.setLocked(false)
            self.update()
        }
    }

    private static func sessionIsLocked() -> Bool {
        let info = CGSessionCopyCurrentDictionary() as NSDictionary?
        return info?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
