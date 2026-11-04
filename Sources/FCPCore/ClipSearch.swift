import Foundation

public struct ClipHit: Identifiable, Equatable, Sendable {
    public var id: String { url.path }
    public let url: URL
    /// CLIP similarity (about 0.2 = unrelated, 0.3 and more = good match), already adjusted for words found in the file name.
    public let score: Double
    /// Second of the clip that matches best.
    public let time: Double
}

/// Footage search with CLIP, a free AI model that runs on this Mac only: no account, no internet after the one-time download,
/// no video ever leaves the computer. The work is done by `clipsearch.py` inside a private Python environment.
extension Doctor {
    public static var clipDir: URL { URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/FCP Toolbox/ai") }
    static var clipPython: String { clipDir.appendingPathComponent("venv/bin/python").path }
    public static var clipIndexURL: URL { clipDir.appendingPathComponent("index.json") }

    private static let clipFiles: [(name: String, url: String, minBytes: Int64)] = [
        ("vision.onnx", "https://huggingface.co/Xenova/clip-vit-base-patch32/resolve/main/onnx/vision_model_quantized.onnx", 80_000_000),
        ("text_it.onnx", "https://huggingface.co/canavar/clip-ViT-B-32-multilingual-v1-ONNX/resolve/main/model.onnx", 500_000_000),
        ("tokenizer_it.json", "https://huggingface.co/canavar/clip-ViT-B-32-multilingual-v1-ONNX/resolve/main/tokenizer.json", 1_000_000),
    ]

    static func fileSize(_ url: URL) -> Int64 { Int64((try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) }

    public static var clipInstalled: Bool {
        fm.isExecutableFile(atPath: clipPython)
            && fm.fileExists(atPath: clipDir.appendingPathComponent("venv/lib/python3.9/site-packages/onnxruntime").path)
            && clipFiles.allSatisfy { fileSize(clipDir.appendingPathComponent("models/\($0.name)")) >= $0.minBytes }
    }

    static func writeClipScript() {
        try? fm.createDirectory(at: clipDir, withIntermediateDirectories: true)
        let url = clipDir.appendingPathComponent("clipsearch.py")
        if (try? String(contentsOf: url, encoding: .utf8)) != clipScript { try? clipScript.write(to: url, atomically: true, encoding: .utf8) }
    }

    /// One-time setup: private Python environment (about 160 MB) and the three model files (about 630 MB). Returns a problem or nil.
    /// Downloads are resumable: a stopped or failed setup continues where it left off.
    public static func clipInstall(control: ProxyControl = ProxyControl(), progress: @escaping @Sendable (Double, String) -> Void) -> String? {
        try? fm.createDirectory(at: clipDir.appendingPathComponent("models"), withIntermediateDirectories: true)
        writeClipScript()
        if !fm.fileExists(atPath: clipDir.appendingPathComponent("venv/lib/python3.9/site-packages/onnxruntime").path) {
            progress(0.02, "Preparo l'ambiente Python…")
            // Apple's own Python 3.9 (Xcode / Command Line Tools): the one with an onnxruntime build for Intel Macs.
            let make = run("/usr/bin/python3", ["-m", "venv", clipDir.appendingPathComponent("venv").path])
            guard make.status == 0 else { return "Non riesco a creare l'ambiente Python: \(make.out.suffix(300))" }
            if control.isCancelled { return "Interrotto." }
            progress(0.05, "Scarico le librerie (onnxruntime, numpy, tokenizers)…")
            let pip = run(clipDir.appendingPathComponent("venv/bin/pip").path, ["install", "--quiet", "onnxruntime==1.19.2", "numpy", "tokenizers"])
            guard pip.status == 0 else { return "Installazione delle librerie non riuscita: \(pip.out.suffix(300))" }
        }
        let total = Double(clipFiles.reduce(0) { $0 + $1.minBytes })
        var done = 0.0
        for f in clipFiles {
            let dest = clipDir.appendingPathComponent("models/\(f.name)")
            if fileSize(dest) >= f.minBytes { done += Double(f.minBytes); continue }
            if control.isCancelled { return "Interrotto." }
            progress(0.15 + 0.85 * done / total, "Scarico il modello \(f.name)…")
            let part = dest.appendingPathExtension("part")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = ["-L", "-f", "-s", "-C", "-", "-o", part.path, f.url]
            guard (try? p.run()) != nil else { return "Non riesco ad avviare curl." }
            control.attach(p)
            let base = done
            while p.isRunning {
                Thread.sleep(forTimeInterval: 0.5)
                progress(0.15 + 0.85 * (base + Double(fileSize(part))) / total, "Scarico il modello \(f.name)…")
            }
            control.attach(nil)
            if control.isCancelled { return "Interrotto." }
            guard p.terminationStatus == 0, fileSize(part) >= f.minBytes else { return "Download di \(f.name) non riuscito: controlla la connessione e riprova (riparte da dove si era fermato)." }
            try? fm.removeItem(at: dest)
            do { try fm.moveItem(at: part, to: dest) } catch { return "Non riesco a salvare \(f.name)." }
            done += Double(f.minBytes)
        }
        progress(1, "Pronto.")
        return clipInstalled ? nil : "Installazione incompleta."
    }

    static let clipVideoExtensions: Set<String> = ["mov", "mp4", "m4v", "mxf", "avi", "mkv", "mts", "m2ts", "webm"]

    /// Looks at the videos in `folder` (subfolders too) and remembers what they show. Clips already seen and unchanged are skipped.
    /// Render files and proxies inside Final Cut libraries are left out: they are copies, not footage.
    public static func clipIndex(folder: URL, indexURL: URL = clipIndexURL, control: ProxyControl = ProxyControl(),
                                 progress: @escaping @Sendable (Int, Int) -> Void) -> (clips: Int, problem: String?) {
        let videos = regularFiles(in: folder).filter {
            clipVideoExtensions.contains($0.pathExtension.lowercased()) && !$0.path.contains("/Render Files/") && !$0.path.contains("/Proxy Media/")
        }.sorted { $0.path < $1.path }
        guard !videos.isEmpty else { return (0, "Nessun video in questa cartella.") }
        return clipIndex(files: videos, indexURL: indexURL, control: control, progress: progress)
    }

    /// Same as the folder version, for an explicit list of video files.
    public static func clipIndex(files videos: [URL], indexURL: URL = clipIndexURL, control: ProxyControl = ProxyControl(),
                                 progress: @escaping @Sendable (Int, Int) -> Void) -> (clips: Int, problem: String?) {
        guard clipInstalled else { return (0, "La ricerca per contenuto non è ancora installata.") }
        guard let ffmpeg = ffmpegPath else { return (0, "Serve ffmpeg: brew install ffmpeg") }
        writeClipScript()
        let list = fm.temporaryDirectory.appendingPathComponent("fcp-cliplist-\(UUID().uuidString).txt")
        defer { try? fm.removeItem(at: list) }  // our own scratch file
        let lines = videos.map { "\($0.path)\t\((try? probeMedia($0))?.duration ?? 0)" }.joined(separator: "\n")
        try? lines.write(to: list, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: clipPython)
        p.arguments = [clipDir.appendingPathComponent("clipsearch.py").path, "index", indexURL.path, ffmpeg, list.path]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let finished = LockedBox<Int>(0)
        out.fileHandleForReading.readabilityHandler = { h in
            for line in String(decoding: h.availableData, as: UTF8.self).split(separator: "\n") {
                guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                if let n = o["done"] as? Int, let t = o["total"] as? Int { progress(n, t) }
                if let c = o["clips"] as? Int { finished.set(c) }
            }
        }
        control.attach(p)
        do { try p.run() } catch { return (0, "Non riesco ad avviare la ricerca: \(error.localizedDescription)") }
        p.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        control.attach(nil)
        if control.isCancelled { return (finished.get(), "Interrotto: i video già guardati restano nell'indice.") }
        guard p.terminationStatus == 0 else {
            return (0, "Indicizzazione non riuscita: " + String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).suffix(300))
        }
        return (finished.get(), nil)
    }

    /// Words of the query (3+ letters) that also appear in a file name make that clip a little more likely.
    static func nameBoost(query: String, fileName: String) -> Double {
        let words = Set(query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 })
        let name = fileName.lowercased()
        return 0.02 * Double(words.filter { name.contains($0) }.count)
    }

    static func parseClipHits(_ output: String, query: String) -> [ClipHit] {
        for line in output.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let rs = o["results"] as? [[String: Any]] else { continue }
            return rs.compactMap { r in
                guard let path = r["path"] as? String, let score = r["score"] as? Double else { return nil }
                let url = URL(fileURLWithPath: path)
                return ClipHit(url: url, score: score + nameBoost(query: query, fileName: url.lastPathComponent), time: r["time"] as? Double ?? 0)
            }.sorted { $0.score > $1.score }
        }
        return []
    }

    /// Finds the clips that best match a description such as "persona che cammina sulla spiaggia". Italian works.
    public static func clipSearch(_ query: String, folder: URL? = nil, limit: Int = 30, indexURL: URL = clipIndexURL) -> (hits: [ClipHit], problem: String?) {
        guard clipInstalled else { return ([], "La ricerca per contenuto non è ancora installata.") }
        guard fm.fileExists(atPath: indexURL.path) else { return ([], "Prima fai guardare l'archivio all'app (tasto «Analizza l'archivio»).") }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return ([], nil) }
        writeClipScript()
        let r = run(clipPython, [clipDir.appendingPathComponent("clipsearch.py").path, "search", indexURL.path, q, String(limit * 3), folder?.path ?? ""])
        guard r.status == 0 else { return ([], "Ricerca non riuscita: \(r.out.suffix(300))") }
        return (Array(parseClipHits(r.out, query: q).prefix(limit)), nil)
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}
