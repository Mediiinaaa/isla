import AppKit
import CoreGraphics

enum HUDKey: Int {
    // Códigos NX_KEYTYPE_* de IOKit
    case volumeUp = 0
    case volumeDown = 1
    case brightnessUp = 2
    case brightnessDown = 3
    case mute = 7
}

/// Captura las teclas de volumen y brillo para que macOS no muestre su propio aviso.
/// Necesita el permiso de Accesibilidad.
final class HUDKeyTap {
    private let handler: (HUDKey) -> Bool
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    init(handler: @escaping (HUDKey) -> Bool) {
        self.handler = handler
    }

    func start() -> Bool {
        if isRunning { return true }
        let systemDefined = CGEventMask(1 << 14) // NX_SYSDEFINED
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: systemDefined,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<HUDKeyTap>.fromOpaque(context).takeUnretainedValue()
                return owner.process(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        self.tap = nil
        source = nil
    }

    private func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let parsed = NSEvent(cgEvent: event), parsed.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let data = parsed.data1
        guard let key = HUDKey(rawValue: (data & 0xFFFF0000) >> 16) else {
            return Unmanaged.passUnretained(event)
        }
        let isDown = (data & 0xFF00) >> 8 == 0x0A
        // Se consume también al soltar, pero solo si la pulsación se pudo atender
        if isDown {
            lastHandled = handler(key)
        }
        return lastHandled ? nil : Unmanaged.passUnretained(event)
    }

    private var lastHandled = false
}

/// macOS no ofrece una API pública para el brillo: se usa DisplayServices, que es privada,
/// y si deja de existir la tecla vuelve a funcionar como siempre.
final class BrightnessControl {
    private typealias Getter = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias Setter = @convention(c) (UInt32, Float) -> Int32

    private let getter: Getter?
    private let setter: Setter?

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        getter = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: Getter.self) }
        setter = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: Setter.self) }
    }

    func adjust(by delta: Float) -> Float? {
        guard let getter, let setter else { return nil }
        let display = CGMainDisplayID()
        var value: Float = 0
        guard getter(display, &value) == 0 else { return nil }
        value = min(max(value + delta, 0), 1)
        return setter(display, value) == 0 ? value : nil
    }
}
