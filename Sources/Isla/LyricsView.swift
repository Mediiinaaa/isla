import SwiftUI

/// Letra que se desplaza sola: la línea que suena queda en el centro y, si hay tiempos por palabra,
/// se ilumina a medida que se canta.
struct LyricsView: View {
    var lyrics: Lyrics
    var track: Track
    var active: Bool
    /// Impar, para que la línea actual quede en medio.
    var rows: Int
    var rowHeight: CGFloat
    var font: Font
    var alignment: Alignment
    var color: Color
    /// Opacidad de lo que aún no se ha cantado.
    var dim: Double

    var body: some View {
        TimelineView(PausableSchedule(interval: 0.1, paused: !active || !track.isPlaying)) { context in
            let index = lyrics.lineIndex(at: (track.position(at: context.date) ?? 0) + Lyrics.lineLead)
            let current = index ?? 0
            let center = rows / 2
            VStack(spacing: 0) {
                ForEach(lyrics.lines.indices, id: \.self) { line in
                    let distance = abs(line - current)
                    Group {
                        // Solo se dibujan las líneas cercanas; el resto queda fuera de la vista
                        if distance <= center + 1 {
                            LyricText(line: lyrics.lines[line], track: track, live: active && line == index, color: color, dim: dim)
                        } else {
                            Color.clear
                        }
                    }
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                    .frame(height: rowHeight)
                    .opacity(opacity(line: line, index: index, distance: distance))
                    .scaleEffect(line == index || rows == 1 ? 1 : 0.92, anchor: UnitPoint(x: alignment == .leading ? 0 : 0.5, y: 0.5))
                    .blur(radius: rows > 1 && distance >= 2 ? 1.2 : 0)
                }
            }
            .offset(y: CGFloat(center - current) * rowHeight)
            .animation(.spring(response: 0.5, dampingFraction: 0.86), value: index)
        }
        .frame(maxWidth: .infinity)
        .frame(height: CGFloat(rows) * rowHeight, alignment: .top)
        .mask {
            if rows > 1 {
                LinearGradient(
                    stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.22),
                            .init(color: .black, location: 0.78), .init(color: .clear, location: 1)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                Rectangle()
            }
        }
    }

    private func opacity(line: Int, index: Int?, distance: Int) -> Double {
        if line == index { return 1 }
        // Durante la introducción se adelanta la primera línea, apagada
        if index == nil, line == 0 { return 0.5 }
        if rows == 1 { return 0 }
        return max((line < (index ?? 0) ? 0.35 : 0.5) - 0.1 * Double(distance - 1), 0.15)
    }
}

/// Una línea de la letra. La que suena se ilumina palabra a palabra; las demás se ven enteras.
struct LyricText: View {
    var line: Lyrics.Line
    var track: Track
    var live: Bool
    var color: Color
    var dim: Double

    var body: some View {
        if line.words.isEmpty {
            Text(verbatim: line.text.isEmpty ? "♪" : line.text)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !live || !track.isPlaying)) { context in
                words(at: live ? track.position(at: context.date) ?? 0 : .infinity)
            }
        }
    }

    @ViewBuilder
    private func words(at time: Double) -> some View {
        if #available(macOS 15, *) {
            line.words
                .reduce(Text(verbatim: "")) { $0 + Text(verbatim: $1.text).customAttribute(WordTiming(start: $1.start, end: $1.end)) }
                .textRenderer(KaraokeRenderer(time: time, dim: dim))
        } else {
            line.words.reduce(Text(verbatim: "")) {
                $0 + Text(verbatim: $1.text).foregroundColor(time >= $1.start ? color : color.opacity(dim))
            }
        }
    }
}

@available(macOS 15, *)
private struct WordTiming: TextAttribute {
    var start: Double
    var end: Double
}

/// Pinta cada palabra apagada y la ilumina de izquierda a derecha mientras se canta, con un borde suave.
@available(macOS 15, *)
private struct KaraokeRenderer: TextRenderer {
    var time: Double
    var dim: Double
    private let feather: CGFloat = 6

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                guard let word = run[WordTiming.self] else {
                    context.draw(run)
                    continue
                }
                let progress = min(max((time - word.start) / max(word.end - word.start, 0.05), 0), 1)
                guard progress < 1 else {
                    context.draw(run)
                    continue
                }
                var faded = context
                faded.opacity = dim
                faded.draw(run)
                guard progress > 0 else { continue }

                // El frente avanza de un poco antes del principio a un poco después del final,
                // así la palabra empieza apagada del todo y termina encendida sin saltos
                let bounds = run.typographicBounds.rect
                let front = bounds.minX - feather + (bounds.width + feather * 2) * progress
                var lit = context
                lit.clipToLayer { mask in
                    mask.fill(
                        Path(bounds.insetBy(dx: -2, dy: -6)),
                        with: .linearGradient(
                            Gradient(colors: [.black, .clear]),
                            startPoint: CGPoint(x: front - feather, y: bounds.midY),
                            endPoint: CGPoint(x: front + feather, y: bounds.midY)
                        )
                    )
                }
                lit.draw(run)
            }
        }
    }
}
