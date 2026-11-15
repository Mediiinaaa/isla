import AppKit
import CoreImage
import EventKit
import IOKit.pwr_mgt

// MARK: - Calendario

struct CalendarEvent: Identifiable, Equatable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var color: NSColor
    var joinURL: URL?

    var timeLabel: String {
        if isAllDay { return "Todo el día" }
        let time = start.formatted(date: .omitted, time: .shortened)
        return Calendar.current.isDateInToday(start) ? time : "Mañana, \(time)"
    }
}

final class CalendarMonitor {
    var onChange: (([CalendarEvent]) -> Void)?
    var onReminder: ((CalendarEvent, Int) -> Void)?

    private let store = EKEventStore()
    private var observer: Any?
    private var events: [CalendarEvent] = []
    private var reminded = Set<String>()

    private static let meetingLink = try? NSRegularExpression(
        pattern: #"https://[^\s<>"]*(zoom\.us|meet\.google\.com|teams\.microsoft\.com|webex\.com)[^\s<>"]*"#,
        options: .caseInsensitive
    )

    func start() {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard let self, granted else { return }
                self.observer = NotificationCenter.default.addObserver(
                    forName: .EKEventStoreChanged,
                    object: self.store,
                    queue: .main
                ) { [weak self] _ in
                    self?.refresh()
                }
                self.refresh()
            }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        events = []
    }

    func refresh() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        let now = Date()
        let calendar = Calendar.current
        let end = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now)) ?? now
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let found = store.events(matching: predicate)
            .filter { $0.endDate > now }
            .sorted { ($0.isAllDay ? 1 : 0, $0.startDate) < ($1.isAllDay ? 1 : 0, $1.startDate) }
            .map { event in
                CalendarEvent(
                    id: (event.calendarItemIdentifier) + "\(event.startDate.timeIntervalSince1970)",
                    title: event.title ?? "Sin título",
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    color: event.calendar.color ?? .systemBlue,
                    joinURL: Self.joinURL(in: event)
                )
            }
        guard found != events else { return }
        events = found
        onChange?(found)
    }

    func fireReminders(minutesBefore: Int) {
        let now = Date()
        for event in events where !event.isAllDay && !reminded.contains(event.id) {
            let remaining = event.start.timeIntervalSince(now)
            if remaining > 0, remaining <= Double(minutesBefore) * 60 {
                reminded.insert(event.id)
                onReminder?(event, max(Int((remaining / 60).rounded(.up)), 1))
            }
        }
    }

    private static func joinURL(in event: EKEvent) -> URL? {
        let text = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }.joined(separator: " ")
        let range = NSRange(text.startIndex..., in: text)
        guard let match = meetingLink?.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text)
        else { return nil }
        return URL(string: String(text[swiftRange]))
    }
}

// MARK: - Mantener despierto

final class KeepAwake {
    private var assertion: IOPMAssertionID = 0
    private var active = false

    var isEnabled: Bool {
        get { active }
        set {
            guard newValue != active else { return }
            if newValue {
                active = IOPMAssertionCreateWithName(
                    kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    "Isla: mantener despierto" as CFString,
                    &assertion
                ) == kIOReturnSuccess
            } else {
                IOPMAssertionRelease(assertion)
                active = false
            }
        }
    }
}

// MARK: - Color de la carátula

extension NSImage {
    /// Color medio de la imagen, aclarado si hace falta para que se lea sobre negro.
    var averageColor: NSColor? {
        guard let data = tiffRepresentation, let input = CIImage(data: data),
              let filter = CIFilter(name: "CIAreaAverage", parameters: [
                  kCIInputImageKey: input,
                  kCIInputExtentKey: CIVector(cgRect: input.extent),
              ]),
              let output = filter.outputImage
        else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let color = NSColor(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return NSColor(hue: hue, saturation: min(saturation * 1.3, 1), brightness: max(brightness, 0.8), alpha: 1)
    }
}
