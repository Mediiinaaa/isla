import Foundation

// MARK: - Letras

struct Lyrics: Equatable {
    struct Word: Equatable {
        var text: String
        var start: Double
        var end: Double
    }

    struct Line: Equatable {
        var text: String
        var start: Double
        var end: Double
        /// Vacío si la letra solo está sincronizada por líneas.
        var words: [Word]
    }

    var lines: [Line]

    /// La línea entra un poco antes para que el desplazamiento termine cuando empieza a cantarse.
    static let lineLead = 0.25

    var hasWordTiming: Bool { lines.contains { !$0.words.isEmpty } }

    /// Última línea que ya ha empezado, o nil durante la introducción.
    func lineIndex(at time: Double) -> Int? {
        var low = 0, high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].start <= time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low == 0 ? nil : low - 1
    }
}

// MARK: - Formato LRC

extension Lyrics {
    /// «[01:23.45] texto», con varias marcas si la línea se repite y la etiqueta [offset:] en milisegundos.
    init?(lrc: String) {
        var offset = 0.0
        var entries: [(time: Double, text: String)] = []
        for raw in lrc.split(whereSeparator: \.isNewline) {
            var rest = raw[...]
            var times: [Double] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                rest = rest[rest.index(after: close)...]
                if let time = Self.timestamp(tag) {
                    times.append(time)
                } else if tag.lowercased().hasPrefix("offset:"),
                          let milliseconds = Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                    offset = milliseconds / 1000
                }
            }
            // Las marcas por palabra del LRC ampliado («<00:12.34>») no se usan
            let text = rest
                .replacingOccurrences(of: #"<\d+:\d+(?:[.:]\d+)?>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            entries += times.map { ($0, text) }
        }
        guard entries.contains(where: { !$0.text.isEmpty }) else { return nil }
        // Un offset positivo adelanta la letra
        let sorted = entries.map { (max($0.time - offset, 0), $0.text) }.sorted { $0.0 < $1.0 }
        lines = sorted.indices.map { index in
            let (start, text) = sorted[index]
            let end = index + 1 < sorted.count ? sorted[index + 1].0 : start + 5
            return Line(text: text, start: start, end: end, words: [])
        }
    }

    /// «mm:ss.xx», «mm:ss» o «mm:ss:xx». Devuelve nil para las etiquetas de datos como [ar:Artista].
    private static func timestamp(_ tag: Substring) -> Double? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let minutes = Int(parts[0]), minutes >= 0,
              parts[1].first?.isASCII == true, parts[1].first?.isNumber == true,
              var seconds = Double(parts[1])
        else { return nil }
        if parts.count == 3 {
            guard let fraction = Double("0." + parts[2]) else { return nil }
            seconds += fraction
        }
        return Double(minutes) * 60 + seconds
    }
}

// MARK: - Formato de LRCLIB con palabras

extension Lyrics {
    /// El campo `lyricsfile` de LRCLIB es YAML con esta forma:
    ///
    ///     lines:
    ///     - text: It's a sample line
    ///       start_ms: 27100
    ///       end_ms: 28198
    ///       words:
    ///       - text: 'It''s '
    ///         start_ms: 27139
    ///
    /// Solo se lee esa estructura. Ante cualquier cosa inesperada devuelve nil y se usa el LRC.
    init?(lyricsfile yaml: String) {
        var lines: [Line] = []
        var inLines = false
        for raw in yaml.split(whereSeparator: \.isNewline) {
            let indent = raw.prefix { $0 == " " }.count
            var body = raw.dropFirst(indent)
            if indent == 0, !body.hasPrefix("- ") {
                // Una clave de primer nivel: «lines:» abre la lista y cualquier otra la cierra
                if inLines { break }
                inLines = body.trimmingCharacters(in: .whitespaces) == "lines:"
                continue
            }
            guard inLines else { continue }
            let isItem = body.hasPrefix("- ")
            if isItem { body = body.dropFirst(2) }
            guard let colon = body.firstIndex(of: ":") else { return nil }
            let key = body[..<colon]
            let value = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)

            // Las claves de cada línea quedan a dos espacios y las de cada palabra a cuatro
            switch indent + (isItem ? 2 : 0) {
            case 2:
                if isItem { lines.append(Line(text: "", start: -1, end: -1, words: [])) }
                guard !lines.isEmpty else { return nil }
                switch key {
                case "text":
                    guard let text = Self.scalar(value) else { return nil }
                    lines[lines.count - 1].text = text
                case "start_ms":
                    guard let milliseconds = Double(value) else { return nil }
                    lines[lines.count - 1].start = milliseconds / 1000
                case "end_ms":
                    guard let milliseconds = Double(value) else { return nil }
                    lines[lines.count - 1].end = milliseconds / 1000
                default:
                    continue
                }
            case 4:
                guard !lines.isEmpty else { return nil }
                if isItem { lines[lines.count - 1].words.append(Word(text: "", start: -1, end: -1)) }
                guard !lines[lines.count - 1].words.isEmpty else { continue }
                let last = lines[lines.count - 1].words.count - 1
                switch key {
                case "text":
                    guard let text = Self.scalar(value) else { return nil }
                    lines[lines.count - 1].words[last].text = text
                case "start_ms":
                    guard let milliseconds = Double(value) else { return nil }
                    lines[lines.count - 1].words[last].start = milliseconds / 1000
                case "end_ms":
                    guard let milliseconds = Double(value) else { return nil }
                    lines[lines.count - 1].words[last].end = milliseconds / 1000
                default:
                    continue
                }
            default:
                continue
            }
        }

        guard !lines.isEmpty, lines.allSatisfy({ $0.start >= 0 }),
              lines.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return nil }
        lines.sort { $0.start < $1.start }
        for index in lines.indices {
            let next = index + 1 < lines.count ? lines[index + 1].start : lines[index].start + 5
            if lines[index].end <= lines[index].start { lines[index].end = next }
            var words = lines[index].words
            // Una palabra sin tiempo invalida la línea entera: mejor iluminarla de golpe
            guard !words.isEmpty, words.allSatisfy({ $0.start >= 0 }) else {
                lines[index].words = []
                continue
            }
            words.sort { $0.start < $1.start }
            for word in words.indices {
                let following = word + 1 < words.count ? words[word + 1].start : lines[index].end
                // Sin final propio, la palabra se ilumina hasta la siguiente, como mucho segundo y medio
                if words[word].end <= words[word].start {
                    words[word].end = min(max(following, words[word].start + 0.1), words[word].start + 1.5)
                }
            }
            lines[index].words = words
            lines[index].text = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        }
        self.lines = lines
    }

    /// Valor YAML de una sola línea: sin comillas, entre comillas simples o dobles.
    private static func scalar(_ value: String) -> String? {
        if value.isEmpty || value == "~" || value == "null" { return "" }
        if value.hasPrefix("'") {
            guard value.count >= 2, value.hasSuffix("'") else { return nil }
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if value.hasPrefix("\"") { return doubleQuoted(value) }
        // Bloques de varias líneas, anclas y etiquetas no aparecen en este formato
        if let first = value.first, "|>&*!".contains(first) { return nil }
        return value
    }

    private static func doubleQuoted(_ value: String) -> String? {
        let characters = Array(value.dropFirst())
        var result = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                return index == characters.count - 1 ? result : nil
            }
            guard character == "\\" else {
                result.append(character)
                index += 1
                continue
            }
            index += 1
            guard index < characters.count else { return nil }
            switch characters[index] {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "0": result.append("\0")
            case "_": result.append("\u{A0}")
            case "N": result.append("\u{85}")
            case "L": result.append("\u{2028}")
            case "P": result.append("\u{2029}")
            case "\\", "\"", "/", " ": result.append(characters[index])
            case "x", "u", "U":
                let length = characters[index] == "x" ? 2 : characters[index] == "u" ? 4 : 8
                guard index + length < characters.count,
                      let code = UInt32(String(characters[(index + 1)...(index + length)]), radix: 16),
                      let scalar = Unicode.Scalar(code)
                else { return nil }
                result.unicodeScalars.append(scalar)
                index += length
            default:
                return nil
            }
            index += 1
        }
        return nil
    }
}

// MARK: - LRCLIB

/// Busca letras sincronizadas en LRCLIB (lrclib.net), una base de datos abierta y sin clave.
final class LyricsProvider {
    private enum Outcome {
        case found(Lyrics)
        case missing
        case failed
    }

    private struct Record: Decodable {
        var duration: Double?
        var instrumental: Bool?
        var syncedLyrics: String?
        var lyricsfile: String?

        var lyrics: Lyrics? {
            guard instrumental != true else { return nil }
            let words = lyricsfile.flatMap(Lyrics.init(lyricsfile:))
            if let words, words.hasWordTiming { return words }
            return syncedLyrics.flatMap(Lyrics.init(lrc:)) ?? words
        }
    }

    /// Diferencia de duración que se acepta: otra versión de la canción iría desacompasada.
    private static let tolerance = 3.0
    private static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "Isla/\(version) (https://github.com/Mediiinaaa/isla)"
    }()

    private var found: [String: Lyrics] = [:]
    private var missing = Set<String>()
    private var task: Task<Void, Never>?
    private var pendingKey: String?

    /// Si llega otra canción antes de terminar, la respuesta anterior se descarta.
    func load(title: String, artist: String, duration: Double, completion: @escaping (Lyrics?) -> Void) {
        let key = [title, artist, String(Int(duration.rounded()))].joined(separator: "\n")
        cancel()
        if let lyrics = found[key] { return completion(lyrics) }
        if missing.contains(key) { return completion(nil) }
        pendingKey = key
        let finish: (Outcome) -> Void = { [weak self] outcome in
            guard let self, self.pendingKey == key else { return }
            self.pendingKey = nil
            if self.found.count + self.missing.count > 200 {
                self.found.removeAll()
                self.missing.removeAll()
            }
            switch outcome {
            case .found(let lyrics):
                self.found[key] = lyrics
                completion(lyrics)
            case .missing:
                self.missing.insert(key)
                completion(nil)
            case .failed:
                // Sin conexión no se guarda nada: se volverá a intentar la próxima vez que suene
                completion(nil)
            }
        }
        // La descarga y la lectura del YAML van fuera del hilo principal
        task = Task.detached(priority: .utility) {
            let outcome = await Self.fetch(title: title, artist: artist, duration: duration)
            guard !Task.isCancelled else { return }
            await MainActor.run { finish(outcome) }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        pendingKey = nil
    }

    private static func fetch(title: String, artist: String, duration: Double) async -> Outcome {
        var titles = [title]
        let simple = simplified(title)
        if !simple.isEmpty, simple != title { titles.append(simple) }

        // Primero la coincidencia exacta; sin letra por palabras se prueba el título sin «Remastered», «feat.»…
        var fallback: Lyrics?
        var failed = false
        for name in titles {
            switch await exact(title: name, artist: artist, duration: duration) {
            case .found(let lyrics):
                if lyrics.hasWordTiming { return .found(lyrics) }
                fallback = fallback ?? lyrics
            case .missing:
                break
            case .failed:
                failed = true
            }
            if Task.isCancelled { return .failed }
        }
        if let fallback { return .found(fallback) }

        switch await search(title: titles.last ?? title, artist: artist, duration: duration) {
        case .found(let lyrics): return .found(lyrics)
        case .missing: return failed ? .failed : .missing
        case .failed: return .failed
        }
    }

    private static func exact(title: String, artist: String, duration: Double) async -> Outcome {
        let query = ["track_name": title, "artist_name": artist, "duration": String(Int(duration.rounded()))]
        guard let (data, status) = await request("get", query) else { return .failed }
        guard status == 200 else { return status == 404 ? .missing : .failed }
        guard let record = try? JSONDecoder().decode(Record.self, from: data),
              abs((record.duration ?? duration) - duration) <= tolerance,
              let lyrics = record.lyrics
        else { return .missing }
        return .found(lyrics)
    }

    private static func search(title: String, artist: String, duration: Double) async -> Outcome {
        guard let (data, status) = await request("search", ["track_name": title, "artist_name": artist]) else { return .failed }
        guard status == 200 else { return status == 404 ? .missing : .failed }
        guard let records = try? JSONDecoder().decode([Record].self, from: data) else { return .missing }
        let candidates = records
            .filter { abs(($0.duration ?? .infinity) - duration) <= tolerance }
            .sorted { abs($0.duration! - duration) < abs($1.duration! - duration) }
        var fallback: Lyrics?
        for record in candidates.prefix(6) {
            guard let lyrics = record.lyrics else { continue }
            if lyrics.hasWordTiming { return .found(lyrics) }
            fallback = fallback ?? lyrics
        }
        return fallback.map(Outcome.found) ?? .missing
    }

    private static func request(_ endpoint: String, _ query: [String: String]) async -> (Data, Int)? {
        guard var components = URLComponents(string: "https://lrclib.net/api/\(endpoint)") else { return nil }
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents deja «+» sin codificar y el servidor lo leería como un espacio
        let encoded = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components.percentEncodedQuery = encoded
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return nil }
        return (data, http.statusCode)
    }

    /// «Canción - Remastered 2011» o «Canción (feat. Alguien)» → «Canción».
    static func simplified(_ title: String) -> String {
        var result = title
        if let dash = result.range(of: " - ") { result = String(result[..<dash.lowerBound]) }
        result = result.replacingOccurrences(
            of: #"\s*[\(\[][^\)\]]*\b(feat|ft|with|con|remaster\w*|live|en vivo|version|versión|edit|mix|explicit)\b[^\)\]]*[\)\]]"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return result.trimmingCharacters(in: .whitespaces)
    }
}
