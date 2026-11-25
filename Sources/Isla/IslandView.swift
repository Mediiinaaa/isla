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
                // En reposo, tras el notch, no se dibuja. Aparece al instante antes de crecer y,
                // al cerrar, se apaga cuando ya casi ha encogido. Solo la opacidad: la forma sigue al muelle
                .animation(hiddenBehindNotch ? .easeOut(duration: 0.15).delay(0.22) : nil) {
                    $0.opacity(hiddenBehindNotch ? 0 : 1)
                }

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
    private var hiddenBehindNotch: Bool { model.mode == .idle && model.hardwareNotch }

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
        case .output(let output):
            compact(
                left: { Image(systemName: output.symbol) },
                right: { Text(output.name).lineLimit(1).truncationMode(.tail) }
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

/// Ondas que bailan mientras suena la música y se recogen al pausar.
/// Cada barra salta a una altura nueva y la animación la lleva hasta ella sin tirones.
struct MusicBars: View {
    var active: Bool
    var color: Color
    var barWidth: CGFloat = 3
    var maxHeight: CGFloat = 14
    @State private var levels: [CGFloat] = [0.45, 0.8, 0.6, 0.35]

    /// Las barras del centro tienden a subir más, como en un ecualizador.
    private static let weights: [CGFloat] = [0.75, 1, 0.9, 0.65]

    var body: some View {
        HStack(spacing: barWidth * 0.7) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: barWidth, height: max(barWidth, maxHeight * (active ? levels[index] : 0.22)))
            }
        }
        .frame(height: maxHeight)
        .animation(.easeOut(duration: 0.3), value: active)
        .task(id: active) {
            guard active else { return }
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.32)) {
                    levels = Self.weights.map { $0 * .random(in: 0.3...1) }
                }
                try? await Task.sleep(for: .milliseconds(320))
            }
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
                    if model.choosingOutput {
                        OutputPicker(model: model)
                    } else {
                        playerSection(track)
                    }
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
                outputButton
            }
            if model.showsLyricLine, let lyrics = model.lyrics {
                LyricsView(
                    lyrics: lyrics,
                    track: track,
                    active: active,
                    rows: 1,
                    rowHeight: 18,
                    font: .system(size: 13, weight: .semibold),
                    alignment: .leading,
                    color: Color(nsColor: model.accent),
                    dim: 0.4
                )
            }
            ProgressRow(track: track, active: active, color: Color(nsColor: model.accent), onSeek: model.seek)
            HStack(spacing: 22) {
                control("shuffle", size: 13, on: track.shuffle, action: model.toggleShuffle)
                control("backward.fill", size: 17, action: model.previousTrack)
                control(track.isPlaying ? "pause.fill" : "play.fill", size: 23, action: model.togglePlayback)
                control("forward.fill", size: 17, action: model.nextTrack)
                control((track.repeatMode ?? .off).symbol, size: 13, on: track.repeatMode.map { $0 != .off }, action: model.toggleRepeat)
            }
        }
    }

    /// Muestra por dónde suena ahora y abre la lista de salidas.
    private var outputButton: some View {
        Button {
            model.refreshOutputs()
            withAnimation(.smooth(duration: 0.25)) { model.choosingOutput = true }
        } label: {
            Image(systemName: model.currentOutputDevice?.symbol ?? "airplayaudio")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.1), in: Circle())
                .contentShape(Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Salida de audio")
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

struct OutputPicker: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Salida de audio")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    withAnimation(.smooth(duration: 0.25)) { model.choosingOutput = false }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(.white.opacity(0.12), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cerrar")
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.outputs) { output in
                        row(output, selected: output.id == model.currentOutput)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func row(_ output: AudioOutput, selected: Bool) -> some View {
        Button {
            model.selectOutput(output)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: output.symbol)
                    .frame(width: 20)
                Text(output.name)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(nsColor: model.accent))
                }
            }
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(.white.opacity(selected ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ProgressRow: View {
    var track: Track
    var active: Bool
    var color: Color
    var textSize: CGFloat = 10
    var onSeek: (Double) -> Void
    @State private var dragFraction: Double?
    /// Solo crece al arrastrar: un toque salta sin que la barra cambie de tamaño.
    @State private var scrubbing = false

    var body: some View {
        TimelineView(PausableSchedule(interval: 0.5, paused: !active)) { context in
            let duration = track.duration ?? 0
            let position = dragFraction.map { $0 * duration } ?? track.position(at: context.date) ?? 0
            HStack(spacing: 8) {
                Text(Self.format(position))
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(scrubbing ? 0.3 : 0.22))
                        Capsule()
                            .fill(color)
                            .frame(width: duration > 0 ? geometry.size.width * min(position / duration, 1) : 0)
                    }
                    .frame(height: scrubbing ? 9 : 5)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragFraction = Self.fraction(value.location.x, width: geometry.size.width)
                            if !scrubbing, abs(value.translation.width) > 3 { scrubbing = true }
                        }
                        .onEnded { value in
                            dragFraction = nil
                            scrubbing = false
                            guard duration > 0 else { return }
                            onSeek(duration * Self.fraction(value.location.x, width: geometry.size.width))
                        })
                }
                .frame(height: 14)
                Text(Self.format(duration))
            }
            .font(.system(size: textSize, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(scrubbing ? 0.9 : 0.6))
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: scrubbing)
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
