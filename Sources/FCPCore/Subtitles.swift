import Foundation

public struct SubtitleCue: Equatable, Sendable, Identifiable {
    public var id: Int { index }
    public var index: Int
    public var start: Double
    public var end: Double
    public var text: String
    public init(index: Int, start: Double, end: Double, text: String) {
        self.index = index; self.start = start; self.end = end; self.text = text
    }
}

public struct SubtitleRules: Sendable {
    public var maxCharsPerLine = 42
    public var maxLines = 2
    public var minDuration = 1.0
    public var maxDuration = 7.0
    /// Characters per second a viewer can comfortably read.
    public var maxCPS = 17.0
    public init() {}
}

public struct SubtitleIssue: Equatable, Sendable, Identifiable {
    public var id: String { "\(cue)-\(kind)" }
    public let cue: Int
    public let kind: String
    public let detail: String
}

public enum SubtitleError: LocalizedError {
    case noTool(String)
    case noModel(String)
    case failed(String)
    public var errorDescription: String? {
        switch self {
        case .noTool(let t): return "\(t) non trovato. Installalo con Homebrew (brew install \(t == "whisper-cli" ? "whisper-cpp" : "ffmpeg"))."
        case .noModel(let m): return m.isEmpty ? "Nessun modello Whisper trovato. Scaricane uno (file ggml-*.bin) e mettilo in ~/Library/Application Support/FCP Toolbox/models." : "Modello non trovato: \(m)"
        case .failed(let m): return "Trascrizione non riuscita: \(m)"
        }
    }
}

extension Doctor {
    // MARK: Parse and write

    static func parseTime(_ s: String) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for p in parts { guard let v = Double(p) else { return nil }; total = total * 60 + v }
        return total
    }

    static func stamp(_ t: Double, comma: Bool) -> String {
        let ms = Int((max(t, 0) * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, comma ? "," : ".", ms % 1000)
    }

    /// Reads SRT or VTT text: both are blocks separated by a blank line, with a "start --> end" line.
    static func parseCues(_ raw: String) -> [SubtitleCue] {
        let text = raw.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let i = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let times = lines[i].components(separatedBy: "-->")
            guard times.count == 2, let s = parseTime(times[0]),
                  let e = parseTime(times[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ")[0]) else { continue }
            let body = lines[(i + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            cues.append(SubtitleCue(index: cues.count + 1, start: s, end: e, text: body))
        }
        return cues
    }

    public static func parseSRT(_ s: String) -> [SubtitleCue] { parseCues(s) }
    public static func parseVTT(_ s: String) -> [SubtitleCue] { parseCues(s) }

    public static func renderSRT(_ cues: [SubtitleCue]) -> String {
        cues.enumerated().map { "\($0.offset + 1)\n\(stamp($0.element.start, comma: true)) --> \(stamp($0.element.end, comma: true))\n\($0.element.text)\n" }
            .joined(separator: "\n")
    }

    public static func renderVTT(_ cues: [SubtitleCue]) -> String {
        "WEBVTT\n\n" + cues.map { "\(stamp($0.start, comma: false)) --> \(stamp($0.end, comma: false))\n\($0.text)\n" }.joined(separator: "\n")
    }

    // MARK: Checks and fixes

    public static func checkSubtitles(_ cues: [SubtitleCue], rules: SubtitleRules = SubtitleRules()) -> [SubtitleIssue] {
        var out: [SubtitleIssue] = []
        for (i, c) in cues.enumerated() {
            let n = i + 1
            let dur = c.end - c.start
            let lines = c.text.split(separator: "\n").map(String.init)
            if c.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(SubtitleIssue(cue: n, kind: "vuota", detail: "Battuta senza testo.")); continue }
            if dur <= 0 { out.append(SubtitleIssue(cue: n, kind: "tempi", detail: "La fine non è dopo l'inizio.")); continue }
            if dur < rules.minDuration { out.append(SubtitleIssue(cue: n, kind: "troppo breve", detail: "\(String(format: "%.1f", dur)) s, minimo \(rules.minDuration) s.")) }
            if dur > rules.maxDuration { out.append(SubtitleIssue(cue: n, kind: "troppo lunga", detail: "\(String(format: "%.1f", dur)) s, massimo \(rules.maxDuration) s.")) }
            let chars = Double(lines.joined().count)
            if chars / dur > rules.maxCPS { out.append(SubtitleIssue(cue: n, kind: "troppo veloce", detail: "\(Int((chars / dur).rounded())) caratteri al secondo, massimo \(Int(rules.maxCPS)).")) }
            if lines.count > rules.maxLines { out.append(SubtitleIssue(cue: n, kind: "troppe righe", detail: "\(lines.count) righe, massimo \(rules.maxLines).")) }
            if let l = lines.map(\.count).max(), l > rules.maxCharsPerLine { out.append(SubtitleIssue(cue: n, kind: "riga lunga", detail: "\(l) caratteri, massimo \(rules.maxCharsPerLine).")) }
            if i + 1 < cues.count, c.end > cues[i + 1].start + 0.001 { out.append(SubtitleIssue(cue: n, kind: "sovrapposta", detail: "Finisce dopo l'inizio della successiva.")) }
        }
        return out
    }

    /// Cleans spacing and punctuation. It does not rewrite words: abbreviations and names are left alone.
    public static func fixPunctuation(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        var out: [SubtitleCue] = []
        for (i, c) in cues.enumerated() {
            let lines = c.text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                var s = String(line).trimmingCharacters(in: .whitespaces)
                s = s.replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
                s = s.replacingOccurrences(of: #" +([,.;:!?])"#, with: "$1", options: .regularExpression)
                s = s.replacingOccurrences(of: #"([,;:!?])(?=[A-Za-zÀ-ÿ])"#, with: "$1 ", options: .regularExpression)
                return s
            }
            var text = lines.joined(separator: "\n")
            let startsSentence = i == 0 || (out.last?.text.trimmingCharacters(in: .whitespaces).last.map { ".!?…".contains($0) } ?? true)
            if startsSentence, let f = text.first, f.isLowercase { text = f.uppercased() + text.dropFirst() }
            var fixed = c
            fixed.text = text
            out.append(fixed)
        }
        return out
    }

    // MARK: Whisper (local)

    public static var whisperCLI: String? {
        ["/usr/local/bin/whisper-cli", "/opt/homebrew/bin/whisper-cli"].first { fm.isExecutableFile(atPath: $0) }
    }

    public static var modelFolders: [URL] {
        let h = NSHomeDirectory()
        return ["\(h)/Library/Application Support/FCP Toolbox/models", "\(h)/.cache/whisper", "\(h)/.cache/whisper.cpp",
                "/usr/local/share/whisper-cpp/models", "/opt/homebrew/share/whisper-cpp/models"].map { URL(fileURLWithPath: $0) }
    }

    /// Whisper model files found on this Mac, biggest (most accurate) first.
    public static func whisperModels(in folders: [URL] = modelFolders) -> [URL] {
        var found: [URL] = []
        for f in folders {
            for u in (try? fm.contentsOfDirectory(at: f, includingPropertiesForKeys: nil)) ?? [] where u.pathExtension == "bin" && u.lastPathComponent.hasPrefix("ggml-") { found.append(u) }
        }
        return found.sorted { byteSize($0) > byteSize($1) }
    }

    /// Transcribes with whisper.cpp, entirely on this Mac, and writes `<name>.srt` without overwriting anything.
    public static func transcribe(_ media: URL, model: URL, language: String = "auto", outputDir: URL) throws -> URL {
        guard let whisper = whisperCLI else { throw SubtitleError.noTool("whisper-cli") }
        guard let ffmpeg = ffmpegPath else { throw SubtitleError.noTool("ffmpeg") }
        guard fm.fileExists(atPath: model.path) else { throw SubtitleError.noModel(model.lastPathComponent) }
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let wav = fm.temporaryDirectory.appendingPathComponent("fcptoolbox-\(UUID().uuidString).wav")
        defer { try? fm.removeItem(at: wav) }
        let a = Process()
        a.executableURL = URL(fileURLWithPath: ffmpeg)
        a.arguments = ["-v", "error", "-nostdin", "-y", "-i", media.path, "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wav.path]
        a.standardOutput = FileHandle.nullDevice
        a.standardError = FileHandle.nullDevice
        try a.run()
        a.waitUntilExit()
        guard a.terminationStatus == 0 else { throw SubtitleError.failed("l'audio di \(media.lastPathComponent) non è leggibile") }

        var base = outputDir.appendingPathComponent(media.deletingPathExtension().lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: base.appendingPathExtension("srt").path) {
            base = outputDir.appendingPathComponent("\(media.deletingPathExtension().lastPathComponent) \(n)")
            n += 1
        }
        let w = Process()
        w.executableURL = URL(fileURLWithPath: whisper)
        w.arguments = ["-m", model.path, "-f", wav.path, "-l", language, "-osrt", "-of", base.path]
        w.standardOutput = FileHandle.nullDevice
        w.standardError = FileHandle.nullDevice
        try w.run()
        w.waitUntilExit()
        let srt = base.appendingPathExtension("srt")
        guard w.terminationStatus == 0, fm.fileExists(atPath: srt.path) else { throw SubtitleError.failed("whisper-cli non ha prodotto il file") }
        return srt
    }
}
