import AppKit
import ApplicationServices
import ServiceManagement

enum Transient: Equatable {
    case volume(Float)
    case brightness(Float)
    case power(level: Int, pluggedIn: Bool)
    case output(name: String, isBluetooth: Bool)
    case track(title: String, artist: String)
    case lowBattery(level: Int)
    case lowPower
    case event(title: String, minutes: Int)
}

enum CompactContent: Equatable {
    case music
    case transient(Transient)
}

enum IslandMode: Equatable {
    case idle
    case music
    case transient
    case expanded
}

enum Preference {
    static let showMusic = "showMusic"
    static let showVolume = "showVolume"
    static let showPower = "showPower"
    static let showOutput = "showOutput"
    static let replaceSystemHUD = "replaceSystemHUD"
    static let expandOnHover = "expandOnHover"
    static let hoverDuration = "hoverDuration"
    static let tapToExpand = "tapToExpand"
    static let swipeToSkip = "swipeToSkip"
    static let swipeToToggle = "swipeToToggle"
    static let haptics = "haptics"
    static let peekOnChange = "peekOnChange"
    static let peekDuration = "peekDuration"
    static let useArtworkColor = "useArtworkColor"
    static let showPercentage = "showPercentage"
    static let warnLowBattery = "warnLowBattery"
    static let lowBatteryThreshold = "lowBatteryThreshold"
    static let notifyLowPower = "notifyLowPower"
    static let soundLowBattery = "soundLowBattery"
    static let hourlyChime = "hourlyChime"
    static let keepAwake = "keepAwake"
    static let hideInFullscreen = "hideInFullscreen"
    static let hideFromCapture = "hideFromCapture"
    static let forceSimulatedNotch = "forceSimulatedNotch"
    static let notchWidthOffset = "notchWidthOffset"
    static let notchHeightOffset = "notchHeightOffset"
    static let showCalendar = "showCalendar"
    static let eventReminder = "eventReminder"
    static let eventMinutes = "eventMinutes"
    static let soundCalendar = "soundCalendar"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            showMusic: true, showVolume: true, showPower: true, showOutput: true,
            expandOnHover: true, hoverDuration: 0.1, tapToExpand: true,
            swipeToSkip: true, swipeToToggle: true, haptics: true,
            peekOnChange: true, peekDuration: 2.5, useArtworkColor: true,
            warnLowBattery: true, lowBatteryThreshold: 20, notifyLowPower: true, soundLowBattery: true,
            eventReminder: true, eventMinutes: 5, soundCalendar: true,
        ])
    }
}

final class IslandModel: ObservableObject {
    @Published var notch = CGSize(width: 180, height: 32)
    @Published var hovering = false {
        didSet {
            if hovering && !oldValue { media.refreshDetails() }
            updateCompact()
        }
    }
    @Published private(set) var transient: Transient? { didSet { updateCompact() } }
    @Published private(set) var track: Track? { didSet { updateCompact() } }
    /// Conserva lo último mostrado para que se vea mientras la capa se desvanece.
    @Published private(set) var compact = CompactContent.music
    @Published private(set) var artwork: NSImage? { didSet { artworkColor = artwork?.averageColor } }
    @Published private(set) var artworkColor: NSColor?
    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var calendarEnabled = false
    @Published private(set) var useArtworkColor = true
    @Published private(set) var showPercentage = false
    @Published private(set) var battery: BatteryState?
    @Published private(set) var showMusic = true { didSet { updateCompact() } }

    private let media = MediaMonitor()
    private let power = PowerMonitor()
    private let volume = VolumeMonitor()
    private let brightness = BrightnessControl()
    private let calendar = CalendarMonitor()
    private let keepAwake = KeepAwake()
    private var clock: Timer?
    private var lastChimeHour = Calendar.current.component(.hour, from: Date())
    private lazy var keyTap = HUDKeyTap { [weak self] key in self?.handle(key) ?? false }
    private var dismissal: DispatchWorkItem?
    private var permissionRetry: Timer?

    var mode: IslandMode {
        if hovering { return .expanded }
        if transient != nil { return .transient }
        if track?.isPlaying == true && showMusic { return .music }
        return .idle
    }

    var size: CGSize {
        switch mode {
        case .idle:
            return CGSize(width: notch.width + 10, height: notch.height + 1)
        case .music, .transient:
            return compactSize
        case .expanded:
            return expandedSize
        }
    }

    var compactSize: CGSize {
        switch compact {
        case .transient(.output), .transient(.track), .transient(.event):
            return CGSize(width: notch.width + 360, height: notch.height)
        default:
            return CGSize(width: notch.width + 130, height: notch.height)
        }
    }

    var expandedSize: CGSize {
        let tall = track != nil || calendarEnabled
        return CGSize(
            width: max(notch.width + 240, 460) + (calendarEnabled ? 190 : 0),
            height: notch.height + (tall ? 138 : 96)
        )
    }

    /// Color de la carátula para los acentos, o blanco si está desactivado.
    var accent: NSColor { useArtworkColor ? artworkColor ?? .white : .white }

    func start() {
        Preference.registerDefaults()

        media.onChange = { [weak self] new in
            guard let self else { return }
            let changed = new != nil && (new?.title != self.track?.title || new?.artist != self.track?.artist)
            self.track = new
            if changed, let new, new.isPlaying, !new.title.isEmpty, self.enabled(Preference.peekOnChange), !self.hovering {
                let duration = UserDefaults.standard.double(forKey: Preference.peekDuration)
                self.show(.track(title: new.title, artist: new.artist), duration: duration)
            }
        }
        media.onArtwork = { [weak self] in self?.artwork = $0 }
        media.start()

        power.onChange = { [weak self] new in
            guard let self else { return }
            let previous = self.battery
            self.battery = new
            guard let previous, let new else { return }
            if previous.pluggedIn != new.pluggedIn, self.enabled(Preference.showPower) {
                self.show(.power(level: new.level, pluggedIn: new.pluggedIn))
            }
            let threshold = UserDefaults.standard.integer(forKey: Preference.lowBatteryThreshold)
            if !new.pluggedIn, new.level <= threshold, previous.level > threshold, self.enabled(Preference.warnLowBattery) {
                self.show(.lowBattery(level: new.level), duration: 4)
                if self.enabled(Preference.soundLowBattery) { NSSound(named: "Basso")?.play() }
            }
        }
        power.start()

        volume.onChange = { [weak self] in
            guard let self, self.enabled(Preference.showVolume) else { return }
            self.show(.volume($0))
        }
        volume.onOutputChange = { [weak self] name, isBluetooth in
            guard let self, self.enabled(Preference.showOutput) else { return }
            self.show(.output(name: name, isBluetooth: isBluetooth))
        }
        volume.start()

        calendar.onChange = { [weak self] in self?.events = $0 }
        calendar.onReminder = { [weak self] event, minutes in
            guard let self else { return }
            self.show(.event(title: event.title, minutes: minutes), duration: 5)
            if self.enabled(Preference.soundCalendar) { NSSound(named: "Glass")?.play() }
        }

        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, ProcessInfo.processInfo.isLowPowerModeEnabled, self.enabled(Preference.notifyLowPower) else { return }
            self.show(.lowPower)
        }

        clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }

        applyPreferences()
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyPreferences()
        }
    }

    func toggleShuffle() { media.toggleShuffle() }
    func toggleRepeat() { media.toggleRepeat() }
    func togglePlayback() { media.send(.playPause) }
    func nextTrack() { media.send(.next) }
    func previousTrack() { media.send(.previous) }
    func seek(to seconds: Double) { media.seek(to: seconds) }

    private func updateCompact() {
        let next: CompactContent
        switch mode {
        case .music: next = .music
        case .transient:
            guard let transient else { return }
            next = .transient(transient)
        case .idle, .expanded: return
        }
        if compact != next { compact = next }
    }

    private func enabled(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }

    private func applyPreferences() {
        let music = enabled(Preference.showMusic)
        if showMusic != music { showMusic = music }
        let artworkColors = enabled(Preference.useArtworkColor)
        if useArtworkColor != artworkColors { useArtworkColor = artworkColors }
        let percentage = enabled(Preference.showPercentage)
        if showPercentage != percentage { showPercentage = percentage }
        let wantsCalendar = enabled(Preference.showCalendar)
        if calendarEnabled != wantsCalendar {
            calendarEnabled = wantsCalendar
            if wantsCalendar {
                calendar.start()
            } else {
                calendar.stop()
                events = []
            }
        }
        keepAwake.isEnabled = enabled(Preference.keepAwake)
        let replace = enabled(Preference.replaceSystemHUD)
        if replace != keyTap.isRunning || (replace && permissionRetry == nil && !keyTap.isRunning) {
            updateKeyTap(replace: replace)
        }
    }

    private func updateKeyTap(replace: Bool) {
        permissionRetry?.invalidate()
        permissionRetry = nil
        guard replace else {
            keyTap.stop()
            return
        }
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary), keyTap.start() { return }
        // El usuario concede el permiso de Accesibilidad en Ajustes del Sistema
        permissionRetry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, AXIsProcessTrusted(), self.keyTap.start() else { return }
            timer.invalidate()
            self.permissionRetry = nil
        }
    }

    /// Devuelve true si la tecla se ha atendido; si no, llega al sistema como siempre.
    private func handle(_ key: HUDKey) -> Bool {
        switch key {
        case .volumeUp: return volume.adjust(by: 1 / 16)
        case .volumeDown: return volume.adjust(by: -1 / 16)
        case .mute: return volume.toggleMute()
        case .brightnessUp, .brightnessDown:
            guard let value = brightness.adjust(by: key == .brightnessUp ? 1 / 16 : -1 / 16) else { return false }
            show(.brightness(value))
            return true
        }
    }

    private func tick() {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour != lastChimeHour {
            lastChimeHour = hour
            if enabled(Preference.hourlyChime) { NSSound(named: "Tink")?.play() }
        }
        guard calendarEnabled else { return }
        calendar.refresh()
        if enabled(Preference.eventReminder) {
            calendar.fireReminders(minutesBefore: UserDefaults.standard.integer(forKey: Preference.eventMinutes))
        }
    }

    private func show(_ value: Transient, duration: Double = 1.8) {
        transient = value
        dismissal?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.transient = nil }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}
