import Foundation

public enum DownloadKind: Equatable, Sendable {
    case video
    case audio(AudioFormat)
}

public struct DownloadResult: Sendable {
    public let output: URL?
    public let problems: [String]
    /// Things that did not fail but that the editor should know (for example a codec Final Cut cannot open).
    public let notes: [String]
    public var ok: Bool { output != nil && problems.isEmpty }
}

extension Doctor {
    /// yt-dlp is a free, separate program (brew install yt-dlp): the app only drives it.
    public static var ytdlpPath: String? {
        ["/usr/local/bin/yt-dlp", "/opt/homebrew/bin/yt-dlp", NSHomeDirectory() + "/.local/bin/yt-dlp"]
            .first { fm.isExecutableFile(atPath: $0) }
    }

    /// A pasted link, cleaned. Only http(s) with a real host is accepted: no local files, no odd schemes.
    public static func cleanLink(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: t), ["http", "https"].contains(u.scheme?.lowercased()),
              let host = u.host, host.contains(".") || host == "localhost" else { return nil }
        return u
    }

    static func downloadArguments(link: URL, kind: DownloadKind, outputDir: URL, ffmpegDir: String) -> [String] {
        var a = ["--no-playlist", "--no-overwrites", "--newline", "--no-quiet",
                 "--progress-template", "download:PROGRESS %(progress._percent_str)s",
                 "--print", "after_move:filepath",
                 "-P", outputDir.path, "-o", "%(title).120B [%(id)s].%(ext)s",
                 "--ffmpeg-location", ffmpegDir]
        switch kind {
        case .video:
            // H.264 + AAC first: YouTube's best formats are often VP9/AV1, which Final Cut cannot open.
            a += ["-f", "bv*[vcodec^=avc1]+ba[acodec^=mp4a]/b[ext=mp4]/bv*+ba/b", "--merge-output-format", "mp4"]
        case .audio(let f):
            a += ["-x", "--audio-format", f == .aac ? "m4a" : f.rawValue, "--audio-quality", "0"]
        }
        return a + [link.absoluteString]
    }

    /// A readable reason from yt-dlp's output.
    static func downloadProblem(_ log: String) -> String {
        let l = log.lowercased()
        if l.contains("login") || l.contains("sign in") || l.contains("cookies") || l.contains("log in") {
            return "Il sito chiede di accedere: questo strumento non usa i tuoi account, quindi non può scaricarlo."
        }
        if l.contains("private") || l.contains("unavailable") || l.contains("not available") {
            return "Video privato o non disponibile."
        }
        if l.contains("unsupported url") { return "Questo link non è supportato." }
        if l.contains("unable to download") || l.contains("urlopen error") || l.contains("network") {
            return "Non riesco a collegarmi: controlla la connessione."
        }
        return log.split(separator: "\n").last { $0.contains("ERROR") }.map(String.init) ?? "Download non riuscito."
    }

    /// Downloads one link into `outputDir`. Never overwrites; `control.cancel()` stops it.
    public static func download(_ link: String, kind: DownloadKind, outputDir: URL, ytdlp: String? = ytdlpPath,
                                control: ProxyControl = ProxyControl(),
                                progress: @escaping @Sendable (Double) -> Void = { _ in }) -> DownloadResult {
        func fail(_ m: String) -> DownloadResult { DownloadResult(output: nil, problems: [m], notes: []) }
        guard let url = cleanLink(link) else { return fail("Questo non sembra un link: incolla l'indirizzo completo (https://…).") }
        guard let ytdlp else { return fail("Manca yt-dlp. Installalo dal Terminale (vedi il riquadro «Scarica da link»).") }
        guard let ffmpeg = ffmpegPath else { return fail("Serve ffmpeg: brew install ffmpeg") }
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        if control.isCancelled { return fail("Interrotto.") }

        // Everything is downloaded into a brand new work folder and only the result is moved to `outputDir`:
        // extracting audio deletes its source file, and that must never be a file the user already has.
        let work = fm.temporaryDirectory.appendingPathComponent("fcp-dl-\(UUID().uuidString)")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }  // our own scratch folder
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ytdlp)
        p.arguments = downloadArguments(link: url, kind: kind, outputDir: work,
                                        ffmpegDir: URL(fileURLWithPath: ffmpeg).deletingLastPathComponent().path)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let outText = LockedText(), errText = LockedText()
        out.fileHandleForReading.readabilityHandler = { h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            outText.append(s)
            for line in s.split(separator: "\n") where line.hasPrefix("PROGRESS") {
                let number = line.dropFirst(8).trimmingCharacters(in: CharacterSet(charactersIn: "% ").union(.whitespaces))
                if let v = Double(number) { progress(min(1, v / 100)) }
            }
        }
        err.fileHandleForReading.readabilityHandler = { h in errText.append(String(decoding: h.availableData, as: UTF8.self)) }
        control.attach(p)
        do { try p.run() } catch { return fail("Non riesco ad avviare yt-dlp: \(error.localizedDescription)") }
        p.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        outText.append(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        errText.append(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        control.attach(nil)

        if control.isCancelled { return fail("Interrotto.") }
        guard p.terminationStatus == 0 else { return fail(downloadProblem(errText.value + "\n" + outText.value)) }
        guard let path = outText.value.split(separator: "\n").map(String.init).last(where: { $0.hasPrefix("/") && fm.fileExists(atPath: $0) }) else {
            return fail("yt-dlp non ha creato nessun file (forse esiste già con quel nome).")
        }
        let made = URL(fileURLWithPath: path)
        var file = outputDir.appendingPathComponent(made.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: file.path) {
            file = outputDir.appendingPathComponent("\(made.deletingPathExtension().lastPathComponent) \(n).\(made.pathExtension)")
            n += 1
        }
        do { try fm.moveItem(at: made, to: file) } catch { return fail("Non riesco a salvare in \(outputDir.lastPathComponent): \(error.localizedDescription)") }
        var notes: [String] = []
        guard let info = try? probeMedia(file) else {
            return DownloadResult(output: file, problems: ["Il file scaricato non si apre: potrebbe essere incompleto."], notes: notes)
        }
        if kind == .video, let v = info.video, v.codec != "h264" {
            notes.append("Il video è \(v.codec): Final Cut potrebbe non aprirlo. Usa «Prepara per montaggio» per convertirlo.")
        }
        logOperation(kind: "download", summary: "Scaricato da link: \(file.lastPathComponent)", paths: [file],
                     estimated: info.size, failures: [], before: probe([outputDir]))
        return DownloadResult(output: file, problems: [], notes: notes)
    }
}

private final class LockedText: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ s: String) { lock.lock(); text += s; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return text }
}
