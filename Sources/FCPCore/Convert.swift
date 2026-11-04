import Foundation

/// One-click jobs for an editor, all done by ffmpeg on the Mac. The original is never touched:
/// the result is a new file next to it (or in the folder given), and an existing file is never overwritten.
public enum ConvertTool: String, CaseIterable, Identifiable, Sendable {
    case prepare, audio, normalize, compress, still
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .prepare: return "Prepara il video per montare"
        case .audio: return "Estrai o converti l'audio"
        case .normalize: return "Sistema il volume per i social"
        case .compress: return "Rimpicciolisci per inviare"
        case .still: return "Copertina da un video"
        }
    }

    public var summary: String {
        switch self {
        case .prepare: return "Per i video del telefono che in Final Cut vanno fuori sincro. L'originale resta com'è."
        case .audio: return "Prende l'audio da un video, o cambia formato a un file audio (MP3, WAV, AAC)."
        case .normalize: return "Volume giusto per Instagram e YouTube, né troppo basso né troppo alto. L'immagine non cambia."
        case .compress: return "Fa pesare meno il file per mandarlo su WhatsApp, Telegram o email. Scegli tu quanti MB al massimo."
        case .still: return "Salva un'immagine JPG presa a metà del video, per usarla come copertina."
        }
    }

    var needsVideo: Bool { self == .prepare || self == .compress || self == .still }
}

public enum AudioFormat: String, CaseIterable, Identifiable, Sendable {
    case mp3, wav, aac
    public var id: String { rawValue }
    public var ext: String { self == .aac ? "m4a" : rawValue }
    public var label: String { rawValue.uppercased() }
}

public struct ConvertOptions: Sendable {
    public var audioFormat: AudioFormat = .mp3
    public var targetMB: Int = 50
    public init() {}
}

public struct ConvertResult: Sendable {
    public let source: URL
    public let output: URL?
    public let problems: [String]
    public var ok: Bool { output != nil && problems.isEmpty }
}

/// What the first loudnorm pass measured.
struct LoudnessMeasure: Equatable {
    var input: Double, truePeak: Double, range: Double, threshold: Double, offset: Double
}

extension Doctor {
    /// Nearest standard frame rate (29.8 from a phone becomes 30000/1001), as ffmpeg writes it.
    static func standardFPS(_ fps: Double) -> String {
        let table: [(Double, String)] = [(23.976, "24000/1001"), (24, "24"), (25, "25"), (29.97, "30000/1001"),
                                         (30, "30"), (48, "48"), (50, "50"), (59.94, "60000/1001"), (60, "60")]
        if let best = table.min(by: { abs($0.0 - fps) < abs($1.0 - fps) }), abs(best.0 - fps) / best.0 < 0.03 { return best.1 }
        return String(max(1, Int(fps.rounded())))
    }

    static func convertExtension(_ tool: ConvertTool, info: MediaInfo, options: ConvertOptions) -> (suffix: String, ext: String) {
        switch tool {
        case .prepare: return ("_pronto", "mp4")
        case .audio: return ("", options.audioFormat.ext)
        case .normalize:
            return info.video != nil ? ("_-14LUFS", info.url.pathExtension.isEmpty ? "mp4" : info.url.pathExtension) : ("_-14LUFS", "m4a")
        case .compress: return ("_\(options.targetMB)MB", "mp4")
        case .still: return ("_frame", "jpg")
        }
    }

    /// The ffmpeg arguments for a job. Pure, so it can be tested without running anything.
    static func convertArguments(_ tool: ConvertTool, info: MediaInfo, options: ConvertOptions,
                                 output: URL, loudness: LoudnessMeasure? = nil) -> [String] {
        let head = ["-hide_banner", "-nostdin", "-n", "-i", info.url.path]
        switch tool {
        case .prepare:
            return head + ["-map", "0:v:0", "-map", "0:a?", "-fps_mode", "cfr", "-r", standardFPS(info.video?.fps ?? 30),
                           "-c:v", "libx264", "-crf", "18", "-preset", "veryfast", "-pix_fmt", "yuv420p",
                           "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", output.path]
        case .audio:
            switch options.audioFormat {
            case .mp3: return head + ["-vn", "-c:a", "libmp3lame", "-b:a", "320k", output.path]
            case .wav: return head + ["-vn", "-c:a", "pcm_s16le", output.path]
            case .aac: return head + ["-vn", "-c:a", "aac", "-b:a", "256k", output.path]
            }
        case .normalize:
            var filter = "loudnorm=I=-14:TP=-1:LRA=11"
            if let l = loudness {
                filter += ":measured_I=\(l.input):measured_TP=\(l.truePeak):measured_LRA=\(l.range):measured_thresh=\(l.threshold):offset=\(l.offset):linear=true"
            }
            if info.video != nil {
                return head + ["-map", "0:v:0", "-c:v", "copy", "-map", "0:a:0", "-af", filter, "-c:a", "aac", "-b:a", "256k", output.path]
            }
            return head + ["-vn", "-af", filter, "-c:a", "aac", "-b:a", "256k", output.path]
        case .compress:
            let seconds = max(info.duration, 1)
            let totalKbps = Double(options.targetMB) * 8 * 1024 * 0.93 / seconds  // 7% margin for the container
            let video = max(100, Int(totalKbps) - 96)
            let v = info.video
            let short = min(720, min(v?.displayWidth ?? 720, v?.displayHeight ?? 720)) / 2 * 2
            let scale = (v?.isVertical ?? false) ? "scale=\(short):-2" : "scale=-2:\(short)"
            return head + ["-vf", scale, "-c:v", "libx264", "-b:v", "\(video)k", "-maxrate", "\(video * 3 / 2)k", "-bufsize", "\(video * 2)k",
                           "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "96k", "-ac", "2", "-movflags", "+faststart", output.path]
        case .still:
            return ["-hide_banner", "-nostdin", "-n", "-ss", String(format: "%.2f", info.duration / 2), "-i", info.url.path,
                    "-frames:v", "1", "-q:v", "2", output.path]
        }
    }

    static func parseLoudnorm(_ log: String) -> LoudnessMeasure? {
        guard let open = log.range(of: "{", options: .backwards), let close = log.range(of: "}", options: .backwards),
              open.lowerBound < close.lowerBound,
              let data = String(log[open.lowerBound...close.lowerBound]).data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        func n(_ k: String) -> Double? { j[k].flatMap(Double.init) }
        guard let i = n("input_i"), let tp = n("input_tp"), let lra = n("input_lra"),
              let th = n("input_thresh"), let off = n("target_offset") else { return nil }
        return LoudnessMeasure(input: i, truePeak: tp, range: lra, threshold: th, offset: off)
    }

    private final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }

    /// Runs ffmpeg. With `progress`, reports 0...1 from ffmpeg's own clock; `control` can stop it at any time.
    static func runFFmpeg(_ ffmpeg: String, _ args: [String], duration: Double = 0, control: ProxyControl? = nil,
                                  progress: (@Sendable (Double) -> Void)? = nil) -> (status: Int32, log: String) {
        if control?.isCancelled == true { return (-2, "Interrotto.") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = progress == nil ? args : ["-progress", "pipe:1", "-nostats"] + args
        let err = Pipe(), out = Pipe()
        p.standardError = err
        p.standardOutput = progress == nil ? FileHandle.nullDevice : out
        let log = LockedData()
        err.fileHandleForReading.readabilityHandler = { h in log.append(h.availableData) }
        if let progress {
            out.fileHandleForReading.readabilityHandler = { h in
                for line in String(decoding: h.availableData, as: UTF8.self).split(separator: "\n") where line.hasPrefix("out_time_us=") {
                    if let us = Double(line.dropFirst(12)), duration > 0 { progress(min(1, max(0, us / 1_000_000 / duration))) }
                }
            }
        }
        control?.attach(p)
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        p.waitUntilExit()
        err.fileHandleForReading.readabilityHandler = nil
        out.fileHandleForReading.readabilityHandler = nil
        log.append(err.fileHandleForReading.readDataToEndOfFile())
        control?.attach(nil)
        return (p.terminationStatus, log.text)
    }

    /// Runs one job. The result file is checked afterwards; a stopped, failed or unreadable result is removed
    /// (it is a file this call just created, never the user's). `control.cancel()` stops it.
    public static func convert(_ source: URL, tool: ConvertTool, options: ConvertOptions = ConvertOptions(),
                               outputDir: URL? = nil, control: ProxyControl = ProxyControl(),
                               progress: @escaping @Sendable (Double) -> Void = { _ in }) -> ConvertResult {
        func fail(_ m: String) -> ConvertResult { ConvertResult(source: source, output: nil, problems: [m]) }
        guard let ffmpeg = ffmpegPath else { return fail("ffmpeg non trovato. Installalo con Homebrew (brew install ffmpeg).") }
        guard let info = try? probeMedia(source) else { return fail("Non riesco a leggere \(source.lastPathComponent).") }
        if tool.needsVideo && info.video == nil { return fail("\(source.lastPathComponent) non ha video.") }
        if !tool.needsVideo && info.audio.isEmpty { return fail("\(source.lastPathComponent) non ha audio.") }

        let dir = outputDir ?? source.deletingLastPathComponent()
        let (suffix, ext) = convertExtension(tool, info: info, options: options)
        let stem = source.deletingPathExtension().lastPathComponent + suffix
        var out = dir.appendingPathComponent("\(stem).\(ext)")
        var n = 2
        while fm.fileExists(atPath: out.path) { out = dir.appendingPathComponent("\(stem) \(n).\(ext)"); n += 1 }

        let need = tool == .compress ? Int64(options.targetMB) * 1_048_576 : info.size
        let before = probe([dir])
        if let free = before.free, need + 500_000_000 > free {
            return fail("Spazio insufficiente: servono circa \(formatBytes(need)), ne restano \(formatBytes(free)).")
        }

        var loudness: LoudnessMeasure?
        if tool == .normalize {
            let measure = runFFmpeg(ffmpeg, ["-hide_banner", "-nostdin", "-i", source.path, "-vn",
                                             "-af", "loudnorm=I=-14:TP=-1:LRA=11:print_format=json", "-f", "null", "-"], control: control)
            if control.isCancelled { return fail("Interrotto.") }
            guard measure.status == 0, let m = parseLoudnorm(measure.log) else { return fail("Non riesco a misurare il volume di \(source.lastPathComponent).") }
            loudness = m
        }

        let run = runFFmpeg(ffmpeg, convertArguments(tool, info: info, options: options, output: out, loudness: loudness),
                            duration: info.duration, control: control, progress: progress)
        var problems: [String] = []
        var discard = false
        if control.isCancelled {
            problems.append("Interrotto.")
            discard = true
        } else if run.status != 0 {
            problems.append("ffmpeg ha fallito su \(source.lastPathComponent): \(run.log.split(separator: "\n").last.map(String.init) ?? "errore sconosciuto")")
            discard = true
        } else if let check = try? probeMedia(out) {
            if tool != .still, abs(check.duration - info.duration) > max(1, info.duration * 0.02) {
                problems.append("La durata del risultato (\(Int(check.duration)) s) non corrisponde all'originale (\(Int(info.duration)) s).")
            }
            if tool == .compress, Double(check.size) > Double(need) * 1.1 {
                problems.append("Il risultato (\(formatBytes(check.size))) supera il limite di \(options.targetMB) MB: prova un limite più alto.")
            }
        } else {
            problems.append("Il file creato non si apre: non è valido.")
            discard = true
        }
        if discard, fm.fileExists(atPath: out.path) { try? fm.removeItem(at: out) }
        let size = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        logOperation(kind: "convert", summary: "\(tool.title): \(source.lastPathComponent)", paths: [out], estimated: Int64(size ?? 0),
                     failures: problems, before: before)
        return ConvertResult(source: source, output: fm.fileExists(atPath: out.path) ? out : nil, problems: problems)
    }
}
