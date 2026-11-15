import SwiftUI
import AppKit

struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let t = topRadius, b = bottomRadius
        var path = Path()
        path.move(to: .zero)
        path.addQuadCurve(to: CGPoint(x: t, y: t), control: CGPoint(x: t, y: 0))
        path.addLine(to: CGPoint(x: t, y: h - b))
        path.addQuadCurve(to: CGPoint(x: t + b, y: h), control: CGPoint(x: t, y: h))
        path.addLine(to: CGPoint(x: w - t - b, y: h))
        path.addQuadCurve(to: CGPoint(x: w - t, y: h - b), control: CGPoint(x: w - t, y: h))
        path.addLine(to: CGPoint(x: w - t, y: t))
        path.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - t, y: 0))
        path.closeSubpath()
        return path
    }
}

private struct BlurFade: ViewModifier {
    var radius: CGFloat
    var opacity: Double
    var scale: CGFloat

    func body(content: Content) -> some View {
        content
            .blur(radius: radius)
            .opacity(opacity)
            .scaleEffect(scale, anchor: .top)
    }
}

extension View {
    /// Las capas nunca salen de la jerarquía: interrumpir una transición de SwiftUI
    /// a medias puede dejar en pantalla una copia huérfana del contenido.
    /// El contenido entra cuando la forma ya casi se ha abierto y sale antes de que se cierre.
    func islandLayer(visible: Bool) -> some View {
        modifier(BlurFade(radius: visible ? 0 : 10, opacity: visible ? 1 : 0, scale: visible ? 1 : 0.92))
            .animation(visible ? .easeOut(duration: 0.24).delay(0.14) : .easeIn(duration: 0.09), value: visible)
            .allowsHitTesting(visible)
    }
}

/// Como `.periodic`, pero sin despertar la vista mientras la capa está oculta.
struct PausableSchedule: TimelineSchedule {
    var interval: TimeInterval
    var paused: Bool

    func entries(from startDate: Date, mode: Mode) -> AnySequence<Date> {
        guard !paused else { return AnySequence([startDate]) }
        return AnySequence(sequence(first: startDate) { $0.addingTimeInterval(interval) })
    }
}

struct IslandView: View {
    @ObservedObject var model: IslandModel

    private var isExpanded: Bool { model.mode == .expanded }
    /// Rebota solo al abrir: al cerrar, un rebote encogería la isla por debajo del notch y lo dejaría a la vista.
    private var spring: Animation {
        isExpanded ? .spring(response: 0.42, dampingFraction: 0.72) : .spring(response: 0.36, dampingFraction: 1)
    }
    private var shape: NotchShape {
        NotchShape(topRadius: isExpanded ? 16 : 4, bottomRadius: isExpanded ? 32 : 12)
    }

    var body: some View {
        ZStack(alignment: .top) {
            shape
                .fill(.black)
                .shadow(color: .black.opacity(isExpanded ? 0.5 : 0), radius: 18, y: 8)

            ZStack(alignment: .top) {
                compactLayer
                    .frame(width: model.compactSize.width - 8)
                    .islandLayer(visible: isCompact)
                // Tamaño final fijo: así el texto no se recoloca mientras la forma se abre
                ExpandedView(model: model, active: isExpanded)
                    .frame(width: model.expandedSize.width - 32, height: model.expandedSize.height, alignment: .top)
                    .islandLayer(visible: isExpanded)
            }
            // Marco exacto: la capa desplegada es mayor que la isla y no debe agrandarla
            .frame(width: model.size.width, height: model.size.height, alignment: .top)
            .clipShape(shape)
        }
        .frame(width: model.size.width, height: model.size.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .environment(\.locale, Locale(identifier: "es_ES"))
        .animation(spring, value: model.mode)
        .animation(spring, value: model.size)
    }

    private var isCompact: Bool { model.mode == .music || model.mode == .transient }

    @ViewBuilder
    private var compactLayer: some View {
        switch model.compact {
        case .music:
            compact(
                left: { ArtworkView(image: model.artwork, size: 22, radius: 6) },
                right: { MusicBars(active: model.mode == .music, color: Color(nsColor: model.accent)) }
            )
        case .transient(let transient):
            transientContent(transient)
        }
    }

    @ViewBuilder
    private func transientContent(_ transient: Transient) -> some View {
        switch transient {
        case .volume(let volume):
            compact(
                left: { Image(systemName: volumeSymbol(volume)) },
                right: { level(Double(volume)) }
            )
        case .brightness(let brightness):
            compact(
                left: { Image(systemName: "sun.max.fill") },
                right: { level(Double(brightness)) }
            )
        case .power(let level, let pluggedIn):
            compact(
                left: { Image(systemName: pluggedIn ? "bolt.fill" : "battery.75percent").foregroundStyle(pluggedIn ? .green : .white) },
                right: { Text("\(level)%").monospacedDigit().foregroundStyle(pluggedIn ? .green : .white) }
            )
        case .track(let title, let artist):
            compact(
                left: { ArtworkView(image: model.artwork, size: 22, radius: 6) },
                right: {
                    Text(artist.isEmpty ? title : "\(title) · \(artist)")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            )
        case .lowBattery(let level):
            compact(
                left: { Image(systemName: "battery.25percent").foregroundStyle(.red) },
                right: { Text("\(level)%").monospacedDigit().foregroundStyle(.red) }
            )
        case .lowPower:
            compact(
                left: { Image(systemName: "bolt.circle.fill").foregroundStyle(.yellow) },
                right: { Text("Ahorro").foregroundStyle(.yellow) }
            )
        case .event(let title, let minutes):
            compact(
                left: { Image(systemName: "calendar").foregroundStyle(.orange) },
                right: {
                    Text("\(title) · \(minutes) min")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            )
        case .output(let name, let isBluetooth):
            compact(
                left: { Image(systemName: isBluetooth ? "airpods" : "hifispeaker.fill") },
                right: { Text(name).lineLimit(1).truncationMode(.tail) }
            )
        }
    }

    @ViewBuilder
    private func level(_ value: Double) -> some View {
        if model.showPercentage {
            Text("\(Int((value * 100).rounded()))%").monospacedDigit()
        } else {
            LevelBar(value: value)
        }
    }

    private func volumeSymbol(_ volume: Float) -> String {
        switch volume {
        case 0: return "speaker.slash.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    /// Reparte el contenido a ambos lados del notch físico.
    private func compact<L: View, R: View>(@ViewBuilder left: () -> L, @ViewBuilder right: () -> R) -> some View {
        let wing = (model.compactSize.width - model.notch.width) / 2 - 8
        // En las actividades anchas el icono va al borde y el texto arranca junto al notch
        let isWide = wing > 80
        return HStack(spacing: 0) {
            left()
                .padding(.leading, isWide ? 10 : 0)
                .frame(width: wing, alignment: isWide ? .leading : .center)
            Spacer(minLength: model.notch.width)
            right()
                .padding(.leading, isWide ? 8 : 0)
                .frame(width: wing, alignment: isWide ? .leading : .center)
        }
        .font(.system(size: 13, weight: .semibold))
        .frame(height: model.notch.height)
    }
}

struct ArtworkView: View {
    var image: NSImage?
    var size: CGFloat
    var radius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct LevelBar: View {
    var value: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white).frame(width: geometry.size.width * min(max(value, 0), 1))
            }
        }
        .frame(width: 40, height: 5)
    }
}

struct MusicBars: View {
    var active: Bool
    var color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 12, paused: !active)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: 5 + 9 * abs(sin(time * 3.2 + Double(index) * 1.3)))
                }
            }
            .frame(height: 14)
        }
    }
}

struct ExpandedView: View {
    @ObservedObject var model: IslandModel
    var active: Bool

    var body: some View {
        VStack(spacing: 0) {
            statusRow
                .frame(height: model.notch.height)
            HStack(alignment: .top, spacing: 16) {
                if let track = model.track {
                    playerSection(track)
                } else {
                    idleSection
                }
                if model.calendarEnabled {
                    EventColumn(events: model.events)
                        .frame(width: 174)
                }
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
    }

    /// Hora y batería a ambos lados del notch físico.
    private var statusRow: some View {
        HStack {
            TimelineView(PausableSchedule(interval: 1, paused: !active)) { context in
                Text(context.date, format: .dateTime.hour().minute())
                    .monospacedDigit()
            }
            Spacer(minLength: model.notch.width)
            if let battery = model.battery {
                HStack(spacing: 3) {
                    if battery.pluggedIn { Image(systemName: "bolt.fill").foregroundStyle(.green) }
                    Text("\(battery.level)%").monospacedDigit()
                }
            }
        }
        .font(.system(size: 12, weight: .semibold))
    }

    private var idleSection: some View {
        VStack(spacing: 2) {
            TimelineView(PausableSchedule(interval: 1, paused: !active)) { context in
                Text(context.date, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.system(size: 15, weight: .semibold))
            }
            Text("Nada sonando")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func playerSection(_ track: Track) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                ArtworkView(image: model.artwork, size: 56, radius: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title.isEmpty ? "Sin título" : track.title)
                        .font(.system(size: 15, weight: .semibold))
                    Text(track.artist)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            ProgressRow(track: track, active: active, color: Color(nsColor: model.accent), onSeek: model.seek)
            HStack(spacing: 22) {
                control("shuffle", size: 13, on: track.shuffle, action: model.toggleShuffle)
                control("backward.fill", size: 17, action: model.previousTrack)
                control(track.isPlaying ? "pause.fill" : "play.fill", size: 23, action: model.togglePlayback)
                control("forward.fill", size: 17, action: model.nextTrack)
                control("repeat", size: 13, on: track.repeats, action: model.toggleRepeat)
            }
        }
    }

    private func control(_ symbol: String, size: CGFloat, on: Bool? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(on == false ? Color.white.opacity(0.4) : Color(nsColor: on == true ? model.accent : .white))
        }
        .buttonStyle(.plain)
    }
}

struct ProgressRow: View {
    var track: Track
    var active: Bool
    var color: Color
    var onSeek: (Double) -> Void
    @State private var dragFraction: Double?

    var body: some View {
        TimelineView(PausableSchedule(interval: 0.5, paused: !active)) { context in
            let duration = track.duration ?? 0
            let position = dragFraction.map { $0 * duration } ?? track.position(at: context.date) ?? 0
            HStack(spacing: 8) {
                Text(Self.format(position))
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.22))
                        Capsule()
                            .fill(color)
                            .frame(width: duration > 0 ? geometry.size.width * min(position / duration, 1) : 0)
                    }
                    .frame(height: 5)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragFraction = Self.fraction(value.location.x, width: geometry.size.width)
                        }
                        .onEnded { value in
                            dragFraction = nil
                            guard duration > 0 else { return }
                            onSeek(duration * Self.fraction(value.location.x, width: geometry.size.width))
                        })
                }
                .frame(height: 14)
                Text(Self.format(duration))
            }
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.6))
        }
    }

    /// Cerca de los extremos se ajusta para que llevarla al principio deje la canción en 0:00.
    private static func fraction(_ x: CGFloat, width: CGFloat) -> Double {
        let value = min(max(Double(x / max(width, 1)), 0), 1)
        return value < 0.03 ? 0 : value
    }

    private static func format(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct EventColumn: View {
    var events: [CalendarEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if events.isEmpty {
                Label("Tu día está libre", systemImage: "calendar")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            ForEach(events.prefix(3)) { event in
                HStack(spacing: 7) {
                    Capsule()
                        .fill(Color(nsColor: event.color))
                        .frame(width: 3, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.title)
                            .font(.system(size: 12, weight: .semibold))
                        Text(event.timeLabel)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    if let link = event.joinURL {
                        Button { NSWorkspace.shared.open(link) } label: {
                            Image(systemName: "video.fill")
                                .font(.system(size: 11))
                                .frame(width: 24, height: 24)
                                .background(.green, in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
