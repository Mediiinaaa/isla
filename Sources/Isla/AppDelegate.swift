import AppKit
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = IslandModel()
    private var panel: IslandPanel!
    private let screenLock = ScreenLockMonitor()
    private var statusItem: NSStatusItem!
    private var monitors: [Any] = []
    private var settingsWindow: NSWindow?
    private var collapse: DispatchWorkItem?
    private var opening: DispatchWorkItem?
    private var hoverCheck: Timer?
    /// Tras cerrar con un gesto no se reabre hasta que el ratón salga de la isla.
    private var closedBySwipe = false
    private var swipeX: CGFloat = 0
    private var swipeY: CGFloat = 0
    private var swipeDone = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preference.registerDefaults()
        registerLoginItemOnce()
        panel = IslandPanel(model: model)
        panel.applyPreferences()
        panel.reposition()
        panel.orderFrontRegardless()

        // Con el Mac bloqueado o la pantalla apagada, la isla no se dibuja
        screenLock.onChange = { [weak self] hidden in
            guard let self else { return }
            if hidden {
                self.panel.orderOut(nil)
            } else {
                self.panel.reposition()
                self.panel.orderFrontRegardless()
            }
        }
        screenLock.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Isla")
        let menu = NSMenu()
        menu.addItem(withTitle: "Ajustes…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Salir de Isla", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        // El monitor global cubre el ratón fuera de la isla y el local cuando está encima
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            self?.updateHover()
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            self?.updateHover()
            return event
        }) {
            monitors.append(local)
        }

        if let taps = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            self?.handleTap()
            return event
        }) {
            monitors.append(taps)
        }

        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.panel.applyPreferences()
            self?.panel.reposition()
        }

        if let swipes = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            self?.handleSwipe(event)
            return event
        }) {
            monitors.append(swipes)
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.panel.reposition()
        }

        model.start()
    }

    /// Solo la primera vez: si luego se desactiva en Ajustes, no vuelve a activarse.
    private func registerLoginItemOnce() {
        let key = "loginItemConfigured"
        guard !UserDefaults.standard.bool(forKey: key), Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            NSLog("Isla: no se pudo activar el inicio automático: %@", error.localizedDescription)
        }
    }

    private func updateHover() {
        let inside = panel.islandRect.contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !inside
        if inside {
            collapse?.cancel()
            collapse = nil
            // Si el ratón sale muy rápido puede no llegar ningún evento: se comprueba aparte
            if hoverCheck == nil {
                hoverCheck = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    self?.updateHover()
                }
            }
            if !model.hovering, !closedBySwipe, opening == nil, UserDefaults.standard.bool(forKey: Preference.expandOnHover) {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.opening = nil
                    if self.panel.islandRect.contains(NSEvent.mouseLocation) {
                        self.model.hovering = true
                    }
                }
                opening = work
                DispatchQueue.main.asyncAfter(deadline: .now() + UserDefaults.standard.double(forKey: Preference.hoverDuration), execute: work)
            }
            return
        }
        closedBySwipe = false
        opening?.cancel()
        opening = nil
        guard model.hovering else {
            stopHoverCheck()
            return
        }
        if collapse == nil {
            // Un pequeño margen evita que se cierre al rozar el borde
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.collapse = nil
                if !self.panel.islandRect.contains(NSEvent.mouseLocation) {
                    self.model.hovering = false
                    self.stopHoverCheck()
                }
            }
            collapse = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
    }

    private func stopHoverCheck() {
        hoverCheck?.invalidate()
        hoverCheck = nil
    }

    private func handleTap() {
        guard !model.hovering, UserDefaults.standard.bool(forKey: Preference.tapToExpand),
              panel.islandRect.contains(NSEvent.mouseLocation)
        else { return }
        closedBySwipe = false
        model.hovering = true
    }

    /// Dos dedos sobre la isla: en horizontal cambia de canción y en vertical abre o cierra.
    private func handleSwipe(_ event: NSEvent) {
        if event.phase == .began {
            swipeX = 0
            swipeY = 0
            swipeDone = false
        }
        // Con la lista de salidas abierta, deslizar desplaza la lista
        guard panel.islandRect.contains(NSEvent.mouseLocation), event.hasPreciseScrollingDeltas,
              !event.phase.isEmpty, !swipeDone, !(model.hovering && model.choosingOutput)
        else { return }
        let direction: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        swipeX += event.scrollingDeltaX * direction
        swipeY += event.scrollingDeltaY * direction
        guard max(abs(swipeX), abs(swipeY)) > 50 else { return }
        swipeDone = true

        let defaults = UserDefaults.standard
        if abs(swipeX) > abs(swipeY) {
            guard defaults.bool(forKey: Preference.swipeToSkip), model.track != nil else { return }
            if swipeX < 0 {
                model.nextTrack()
            } else {
                model.previousTrack()
            }
        } else {
            guard defaults.bool(forKey: Preference.swipeToToggle) else { return }
            if swipeY > 0 {
                closedBySwipe = false
                model.hovering = true
            } else {
                closedBySwipe = true
                opening?.cancel()
                opening = nil
                model.hovering = false
            }
        }
        if defaults.bool(forKey: Preference.haptics) {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(login: LoginItem())))
            window.title = "Ajustes de Isla"
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class IslandPanel: NSPanel {
    private static let canvas = CGSize(width: 720, height: 260)
    private let model: IslandModel

    init(model: IslandModel) {
        self.model = model
        super.init(
            contentRect: CGRect(origin: .zero, size: Self.canvas),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        contentView = FirstMouseHostingView(rootView: IslandView(model: model))
    }

    override var canBecomeKey: Bool { true }

    // Sin esto AppKit empuja la ventana por debajo de la barra de menús
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func applyPreferences() {
        let defaults = UserDefaults.standard
        sharingType = defaults.bool(forKey: Preference.hideFromCapture) ? .none : .readOnly
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if !defaults.bool(forKey: Preference.hideInFullscreen) { behavior.insert(.fullScreenAuxiliary) }
        if collectionBehavior != behavior { collectionBehavior = behavior }
    }

    private var islandScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    func reposition() {
        guard let screen = islandScreen else { return }
        let notch = Self.notchSize(of: screen)
        if model.notch != notch { model.notch = notch }
        let hardware = Self.hasHardwareNotch(screen)
        if model.hardwareNotch != hardware { model.hardwareNotch = hardware }
        setFrame(
            CGRect(
                x: screen.frame.midX - Self.canvas.width / 2,
                y: screen.frame.maxY - Self.canvas.height,
                width: Self.canvas.width,
                height: Self.canvas.height
            ),
            display: true
        )
    }

    /// Zona de la pantalla que ocupa ahora la isla, con un margen para que sea fácil de alcanzar.
    var islandRect: CGRect {
        guard let screen = islandScreen else { return .zero }
        let size = model.size
        // En reposo la isla mide lo que el notch: algo más de margen para alcanzarla
        let margin = model.mode == .idle ? CGSize(width: 9, height: 4) : CGSize(width: 4, height: 3)
        return CGRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        ).insetBy(dx: -margin.width, dy: -margin.height)
    }

    private static func hasHardwareNotch(_ screen: NSScreen) -> Bool {
        !UserDefaults.standard.bool(forKey: Preference.forceSimulatedNotch) && screen.safeAreaInsets.top > 0
            && screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil
    }

    private static func notchSize(of screen: NSScreen) -> CGSize {
        let defaults = UserDefaults.standard
        var size = CGSize(width: 180, height: 26) // Pantalla sin notch: una píldora bajo el borde superior
        if hasHardwareNotch(screen), let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            size = CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        }
        size.width += defaults.double(forKey: Preference.notchWidthOffset).rounded()
        size.height += defaults.double(forKey: Preference.notchHeightOffset).rounded()
        return size
    }
}

/// Permite pulsar los botones al primer clic aunque la app no esté activa.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
