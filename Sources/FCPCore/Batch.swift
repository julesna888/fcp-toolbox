import Foundation

// MARK: - Steps and presets

/// One operation of a workflow. Each step takes the file made by the previous one.
public struct Step: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case prepare, resize, normalize, compress, audio, stripMetadata, rename

        public var title: String {
            switch self {
            case .prepare: return "Prepara il video per montare"
            case .resize: return "Ridimensiona"
            case .normalize: return "Sistema il volume per i social"
            case .compress: return "Riduci il peso (MB)"
            case .audio: return "Solo audio"
            case .stripMetadata: return "Togli i metadati"
            case .rename: return "Rinomina il file"
            }
        }
    }

    public var kind: Kind
    public var audio = "mp3"  // AudioFormat raw value
    public var targetMB = 50
    public var width = 1080
    public var height = 1920
    /// Resize: false = fill (crop centred, nothing stretched), true = fit (whole picture, black bars).
    public var fit = false
    public var metadata: [String] = [MetadataKind.everything.rawValue]  // MetadataKind raw values
    public var pattern = "{name}"

    public init(_ kind: Kind) { self.kind = kind }

    public static func resize(_ w: Int, _ h: Int, fit: Bool = false) -> Step { var s = Step(.resize); s.width = w; s.height = h; s.fit = fit; return s }
    public static func compress(mb: Int) -> Step { var s = Step(.compress); s.targetMB = mb; return s }
    public static func audio(_ f: AudioFormat) -> Step { var s = Step(.audio); s.audio = f.rawValue; return s }
    public static func rename(_ pattern: String) -> Step { var s = Step(.rename); s.pattern = pattern; return s }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: Keys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        audio = try c.decodeIfPresent(String.self, forKey: .audio) ?? audio
        targetMB = try c.decodeIfPresent(Int.self, forKey: .targetMB) ?? targetMB
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? width
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? height
        fit = try c.decodeIfPresent(Bool.self, forKey: .fit) ?? fit
        metadata = try c.decodeIfPresent([String].self, forKey: .metadata) ?? metadata
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern) ?? pattern
    }
    private enum Keys: String, CodingKey { case kind, audio, targetMB, width, height, fit, metadata, pattern }

    public var audioFormat: AudioFormat { AudioFormat(rawValue: audio) ?? .mp3 }
    public var metadataKinds: Set<MetadataKind> { Set(metadata.compactMap { MetadataKind(rawValue: $0) }) }

    /// Short plain-language description, with the parameters.
    public var summary: String {
        switch kind {
        case .resize: return "Ridimensiona a \(width)×\(height) (\(fit ? "intero, con barre" : "riempi, taglia ai lati"))"
        case .compress: return TF("Riduci sotto %@ MB", targetMB)
        case .audio: return TF("Solo audio %@", audioFormat.label)
        case .stripMetadata: return TF("Togli metadati: %@", metadataKinds.map(\.rawValue).sorted().joined(separator: ", "))
        case .rename: return TF("Rinomina: %@", pattern)
        default: return kind.title
        }
    }

    /// Added to the name when no rename step says otherwise.
    var suffix: String {
        switch kind {
        case .prepare: return "_pronto"
        case .resize: return "_\(width)x\(height)"
        case .normalize: return "_-14LUFS"
        case .compress: return "_\(targetMB)MB"
        case .stripMetadata: return " pulito"
        case .audio, .rename: return ""
        }
    }
}

public struct Preset: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var steps: [Step]
    public var outputFolder: String?
    public var isBuiltIn: Bool { id.hasPrefix("builtin.") }

    public init(id: String = UUID().uuidString, name: String, steps: [Step], outputFolder: String? = nil) {
        self.id = id; self.name = name; self.steps = steps; self.outputFolder = outputFolder
    }
}

extension Doctor {
    /// Presets that come with the app. They live in code, never in the JSON file.
    public static let starterPresets: [Preset] = [
        Preset(id: "builtin.instagram", name: "Prepara per Instagram Reel",
               steps: [Step(.prepare), .resize(1080, 1920), Step(.normalize), .rename("{name} reel")]),
        Preset(id: "builtin.whatsapp", name: "Per WhatsApp (max 16 MB)", steps: [.compress(mb: 16)]),
        Preset(id: "builtin.mp3", name: "Solo audio MP3", steps: [.audio(.mp3)]),
        Preset(id: "builtin.youtube", name: "YouTube Full HD con volume giusto",
               steps: [Step(.prepare), .resize(1920, 1080, fit: true), Step(.normalize)]),
    ]

    public static var presetsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/FCP Toolbox/presets.json")
    }

    /// The user's own presets. A file that cannot be read is kept aside as ".corrupt", not overwritten later.
    public static func loadUserPresets(at url: URL = presetsURL) -> [Preset] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let list = try? JSONDecoder().decode([Preset].self, from: data) { return list.filter { !$0.isBuiltIn } }
        try? fm.removeItem(at: url.appendingPathExtension("corrupt"))
        try? fm.moveItem(at: url, to: url.appendingPathExtension("corrupt"))
        return []
    }

    @discardableResult
    public static func saveUserPresets(_ presets: [Preset], at url: URL = presetsURL) -> Bool {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(presets.filter { !$0.isBuiltIn }) else { return false }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// Why a list of steps cannot work, or nil. Checked before any file is touched.
    public static func validateSteps(_ steps: [Step]) -> String? {
        let work = steps.filter { $0.kind != .rename }
        if steps.isEmpty { return "Aggiungi almeno un passaggio." }
        for s in steps {
            switch s.kind {
            case .resize where s.width < 2 || s.height < 2: return "Le misure del ridimensionamento non sono valide."
            case .compress where s.targetMB < 1: return "Il limite di MB deve essere almeno 1."
            case .rename where s.pattern.trimmingCharacters(in: .whitespaces).isEmpty: return "Il nome del file non può essere vuoto."
            case .stripMetadata where s.metadataKinds.isEmpty: return "Scegli quali metadati togliere."
            default: break
            }
        }
        if let i = work.firstIndex(where: { $0.kind == .audio }), i < work.count - 1 {
            return "Dopo \"Solo audio\" non puoi più lavorare sul video: mettilo per ultimo."
        }
        return nil
    }

    /// {name} original name, {n} or {n:3} item number (padded), {date} modification date of the original.
    public static func applyNamePattern(_ pattern: String, stem: String, n: Int, date: Date) -> String {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        var name = pattern.replacingOccurrences(of: "{name}", with: stem)
            .replacingOccurrences(of: "{date}", with: day.string(from: date))
        if let r = name.range(of: #"\{n(:(\d+))?\}"#, options: .regularExpression) {
            let token = String(name[r])
            let pad = token.contains(":") ? Int(token.dropFirst(3).dropLast()) ?? 1 : 1
            name.replaceSubrange(r, with: String(format: "%0\(pad)d", n))
        }
        return name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    // MARK: - Resize / reframe

    /// Fill crops the centre so the whole frame is picture; fit keeps the whole picture and adds black bars. Never stretches.
    static func resizeFilter(width: Int, height: Int, fit: Bool) -> String {
        let w = even(Double(width)), h = even(Double(height))
        return fit
            ? "scale=\(w):\(h):force_original_aspect_ratio=decrease,pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2:black,setsar=1"
            : "scale=\(w):\(h):force_original_aspect_ratio=increase,crop=\(w):\(h),setsar=1"
    }

    /// Writes "<name>_<W>x<H>.mp4" (H.264 + AAC) in `outputDir`; never overwrites. A failed or stopped result is removed.
    public static func resize(_ source: URL, width: Int, height: Int, fit: Bool, outputDir: URL, control: ProxyControl = ProxyControl(),
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) -> ConvertResult {
        func fail(_ m: String) -> ConvertResult { ConvertResult(source: source, output: nil, problems: [m]) }
        guard let ffmpeg = ffmpegPath else { return fail("ffmpeg non trovato. Installalo con Homebrew (brew install ffmpeg).") }
        guard let info = try? probeMedia(source) else { return fail(TF("Non riesco a leggere %@.", source.lastPathComponent)) }
        guard info.video != nil else { return fail(TF("%@ non ha video.", source.lastPathComponent)) }
        let w = even(Double(width)), h = even(Double(height))
        let stem = source.deletingPathExtension().lastPathComponent + "_\(w)x\(h)"
        var out = outputDir.appendingPathComponent("\(stem).mp4")
        var n = 2
        while fm.fileExists(atPath: out.path) { out = outputDir.appendingPathComponent("\(stem) \(n).mp4"); n += 1 }
        if let free = probe([outputDir]).free, info.size + 500_000_000 > free {
            return fail(TF("Spazio insufficiente: servono circa %@, ne restano %@.", formatBytes(info.size), formatBytes(free)))
        }
        let args = ["-hide_banner", "-nostdin", "-n", "-i", source.path, "-map", "0:v:0", "-map", "0:a?",
                    "-vf", resizeFilter(width: w, height: h, fit: fit),
                    "-c:v", "libx264", "-crf", "18", "-preset", "veryfast", "-pix_fmt", "yuv420p",
                    "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", out.path]
        let run = runFFmpeg(ffmpeg, args, duration: info.duration, control: control, progress: progress)
        var problem: String?
        if control.isCancelled { problem = "Interrotto." }
        else if run.status != 0 { problem = TF("ffmpeg ha fallito su %@: %@", source.lastPathComponent, run.log.split(separator: "\n").last.map(String.init) ?? "errore sconosciuto") }
        else if let made = try? probeMedia(out), let v = made.video {
            if v.width != w || v.height != h { problem = TF("Il risultato è %@×%@ invece di %@×%@.", v.width, v.height, w, h) }
        } else { problem = "Il file creato non si apre: non è valido." }
        if let problem {
            try? fm.removeItem(at: out)  // the file this call just created
            return fail(problem)
        }
        return ConvertResult(source: source, output: out, problems: [])
    }

    // MARK: - Pipeline

    /// Runs the steps one after the other on `source`. Intermediate files live in a private work folder inside
    /// `workRoot` that is always removed; only the final file reaches `outputDir` (default: next to the original),
    /// never overwriting ("name 2"). The original is never moved or changed.
    public static func runPipeline(_ source: URL, steps: [Step], label: String = "Elaborazione", outputDir: URL? = nil, number: Int = 1,
                                   workRoot: URL = FileManager.default.temporaryDirectory, control: ProxyControl = ProxyControl(),
                                   progress: @escaping @Sendable (Double) -> Void = { _ in }) -> ConvertResult {
        let dir = outputDir ?? source.deletingLastPathComponent()
        var existing = dir  // the folder may not exist yet: measure free space on the nearest one that does
        while !fm.fileExists(atPath: existing.path), existing.path != "/" { existing = existing.deletingLastPathComponent() }
        let before = probe([existing])
        func finish(_ out: URL?, _ problems: [String]) -> ConvertResult {
            let size = out.map { byteSize($0) } ?? 0
            logOperation(kind: "batch", summary: "\(label): \(source.lastPathComponent)", paths: out.map { [$0] } ?? [], estimated: size,
                         failures: problems, before: before)
            return ConvertResult(source: source, output: out, problems: problems)
        }
        if let bad = validateSteps(steps) { return finish(nil, [bad]) }

        let work = workRoot.appendingPathComponent("fcp-batch-\(UUID().uuidString)")
        do { try fm.createDirectory(at: work, withIntermediateDirectories: true) } catch { return finish(nil, ["Non riesco a creare la cartella di lavoro."]) }
        defer { try? fm.removeItem(at: work) }  // our own scratch folder

        // A link to the original inside the work folder: steps that write "next to the source" then write here.
        let link = work.appendingPathComponent(source.lastPathComponent)
        do { try fm.createSymbolicLink(at: link, withDestinationURL: source) } catch { return finish(nil, ["Non riesco a preparare il file."]) }

        let processing = steps.filter { $0.kind != .rename }
        var current = link
        var pattern: String?
        var done = 0
        for step in steps {
            if control.isCancelled { return finish(nil, ["Interrotto."]) }
            if step.kind == .rename { pattern = step.pattern; continue }
            let base = Double(done) / Double(processing.count), span = 1 / Double(processing.count)
            let sub: @Sendable (Double) -> Void = { progress(base + $0 * span) }
            let r: ConvertResult
            switch step.kind {
            case .prepare: r = convert(current, tool: .prepare, outputDir: work, control: control, progress: sub)
            case .normalize: r = convert(current, tool: .normalize, outputDir: work, control: control, progress: sub)
            case .compress:
                var o = ConvertOptions(); o.targetMB = step.targetMB
                r = convert(current, tool: .compress, options: o, outputDir: work, control: control, progress: sub)
            case .audio:
                var o = ConvertOptions(); o.audioFormat = step.audioFormat
                r = convert(current, tool: .audio, options: o, outputDir: work, control: control, progress: sub)
            case .resize: r = resize(current, width: step.width, height: step.height, fit: step.fit, outputDir: work, control: control, progress: sub)
            case .stripMetadata:
                let m = cleanMetadata(current, remove: step.metadataKinds)
                r = ConvertResult(source: current, output: m.output, problems: m.problem.map { [$0] } ?? [])
            case .rename: continue
            }
            guard let out = r.output, r.ok else { return finish(nil, [r.problems.first ?? TF("Passaggio non riuscito: %@.", step.kind.title)]) }
            if current != link { try? fm.removeItem(at: current) }  // intermediate of ours: free the space now
            current = out
            done += 1
        }
        if control.isCancelled { return finish(nil, ["Interrotto."]) }

        let stem = source.deletingPathExtension().lastPathComponent
        let date = (try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        var name = pattern.map { applyNamePattern($0, stem: stem, n: number, date: date) } ?? stem + (processing.last?.suffix ?? "")
        if name.trimmingCharacters(in: .whitespaces).isEmpty { name = stem }
        let ext = current.pathExtension
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        func candidate(_ k: Int) -> URL {
            let n = k == 1 ? name : "\(name) \(k)"
            return dir.appendingPathComponent(ext.isEmpty ? n : "\(n).\(ext)")
        }
        var k = 1
        while fm.fileExists(atPath: candidate(k).path) { k += 1 }
        let final = candidate(k)
        do {
            // Only a file made in the work folder is moved; with no processing step the original is copied, never moved.
            if current == link { try fm.copyItem(at: source, to: final) } else { try fm.moveItem(at: current, to: final) }
        } catch {
            try? fm.removeItem(at: final)
            return finish(nil, [TF("Non riesco a salvare %@: %@", final.lastPathComponent, error.localizedDescription)])
        }
        progress(1)
        return finish(final, [])
    }
}
