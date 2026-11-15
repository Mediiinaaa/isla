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

struct Track: Equatable {
    var player: Player
    var title: String
    var artist: String
    var isPlaying: Bool
    var duration: Double?
    var position: Double?
    var positionDate = Date()
    var shuffle: Bool?
    var repeats: Bool?

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

    func toggleRepeat() {
        guard var track = current else { return }
        let command = track.player == .spotify
            ? "set repeating to not repeating"
            : "if song repeat is off then set song repeat to all else set song repeat to off"
        runAppleScript("tell application \"\(track.player.rawValue)\"\n\(command)\nend tell") { _ in }
        track.repeats = !(track.repeats ?? false)
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
            latest.repeats = lines[4] == "true"
            self.current = latest
            self.onChange?(latest)
            if self.artworkKey != key {
                self.artworkKey = key
                self.loadArtwork(player: track.player, reference: lines[0])
            }
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
                set r to (song repeat is not off)
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
            track.repeats = current.repeats
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
    var onOutputChange: ((String, Bool) -> Void)?
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
            self?.bindDefaultDevice()
            self?.announceOutput()
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

    private func announceOutput() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let label = name?.takeRetainedValue() as String?
        else { return }

        address.mSelector = kAudioDevicePropertyTransportType
        var transport = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        let bluetooth = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        onOutputChange?(label, bluetooth)
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
