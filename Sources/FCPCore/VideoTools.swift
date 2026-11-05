import Foundation

public struct TrimResult: Sendable {
    public let output: URL?
    public let problem: String?
}

extension Doctor {
    /// "00:01:05:12" for 65.5 s at 25 fps. Frames are counted with the nominal (rounded) frame rate.
    public static func timecode(_ seconds: Double, fps: Double) -> String {
        let rate = max(1, Int(fps.rounded()))
        let total = Int((max(0, seconds) * Double(rate) + 1e-6).rounded(.down))  // a frame starts at its time: never round up
        let f = total % rate, s = total / rate
        return String(format: "%02d:%02d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60, f)
    }

    /// Times (seconds) where the picture changes shot. Always starts with 0.
    /// `sensitivity` 0.1 (many cuts, also fast motion) … 0.6 (only hard cuts).
    public static func detectShots(_ url: URL, sensitivity: Double = 0.3) -> [Double] {
        guard let ffmpeg = ffmpegPath else { return [] }
        let r = run(ffmpeg, ["-hide_banner", "-nostats", "-i", url.path, "-an", "-vf",
                             "select='gt(scene,\(sensitivity))',showinfo", "-f", "null", "-"])
        guard r.status == 0 else { return [] }
        var times: [Double] = [0]
        for line in r.out.split(separator: "\n") where line.contains("Parsed_showinfo") {
            guard let range = line.range(of: "pts_time:") else { continue }
            let number = line[range.upperBound...].prefix { "0123456789.".contains($0) }
            if let t = Double(number), t > 0.05 { times.append(t) }
        }
        return times
    }

    /// One frame of a video (or the image itself) as JPEG data, `width` pixels wide.
    public static func frameImage(of url: URL, at seconds: Double = 0, width: Int = 320) -> Data? {
        guard let ffmpeg = ffmpegPath else { return nil }
        // straight from ffmpeg's output pipe: no scratch file to write, read back and delete
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-hide_banner", "-loglevel", "error", "-ss", String(format: "%.3f", max(0, seconds)), "-i", url.path,
                       "-frames:v", "1", "-vf", "scale=\(width):-2", "-q:v", "3", "-f", "image2pipe", "-c:v", "mjpeg", "-"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 && !data.isEmpty ? data : nil
    }

    /// Cuts `start…end` out of `source` into a new file next to it ("… taglio"). Never touches the original.
    /// Fast: no re-encoding, the cut falls on the nearest keyframe before `start`. Precise: re-encodes, exact to the frame.
    public static func trim(_ source: URL, start: Double, end: Double, precise: Bool) -> TrimResult {
        func fail(_ m: String) -> TrimResult { TrimResult(output: nil, problem: m) }
        guard let ffmpeg = ffmpegPath else { return fail("ffmpeg non trovato (brew install ffmpeg).") }
        guard let info = try? probeMedia(source) else { return fail(TF("Non riesco a leggere %@.", source.lastPathComponent)) }
        guard start >= 0, end > start, start < info.duration else { return fail("L'inizio deve venire prima della fine, dentro la durata della clip.") }
        let end = min(end, info.duration)
        var ext = source.pathExtension.lowercased()
        if precise && !["mov", "mp4", "m4v"].contains(ext) { ext = "mp4" }
        let dir = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent + " taglio"
        var out = dir.appendingPathComponent("\(stem).\(ext)")
        var n = 2
        while fm.fileExists(atPath: out.path) { out = dir.appendingPathComponent("\(stem) \(n).\(ext)"); n += 1 }

        let before = probe([dir])
        if let free = before.free, info.size + 500_000_000 > free { return fail("Spazio insufficiente per il taglio.") }
        var args = ["-hide_banner", "-loglevel", "error", "-ss", String(format: "%.3f", start), "-i", source.path,
                    "-t", String(format: "%.3f", end - start), "-map", "0:v?", "-map", "0:a?"]
        args += precise ? ["-c:v", "libx264", "-preset", "fast", "-crf", "16", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "256k"]
                        : ["-c", "copy", "-avoid_negative_ts", "make_zero"]
        let r = run(ffmpeg, args + [out.path])
        guard r.status == 0, let made = try? probeMedia(out), made.duration > 0 else {
            try? fm.removeItem(at: out)  // the unfinished file this call created
            return fail("Taglio non riuscito: " + (r.out.split(separator: "\n").last.map(String.init) ?? "errore sconosciuto"))
        }
        _ = logOperation(kind: "trim", summary: "Tagliata \(source.lastPathComponent): \(String(format: "%.1f–%.1f", start, end)) s",
                         paths: [out], estimated: made.size, failures: [], before: before)
        return TrimResult(output: out, problem: nil)
    }
}
