import Foundation

public struct VideoStream: Sendable, Hashable {
    public var codec: String
    public var profile: String
    public var width: Int
    public var height: Int
    /// Clockwise degrees the player applies (phone clips are often stored sideways).
    public var rotation: Int
    public var fps: Double
    /// True when the declared and the average frame rate disagree: a heuristic, not a frame-by-frame check.
    public var isVFR: Bool
    public var bitDepth: Int
    public var chroma: String
    public var pixFmt: String
    public var colorSpace: String
    public var transfer: String
    public var primaries: String
    public var bitrate: Int64
    public var duration: Double = 0

    public var displayWidth: Int { abs(rotation) % 180 == 90 ? height : width }
    public var displayHeight: Int { abs(rotation) % 180 == 90 ? width : height }
    public var isVertical: Bool { displayHeight > displayWidth }
    public var isHDR: Bool { transfer == "smpte2084" || transfer == "arib-std-b67" }
}

public struct AudioStream: Sendable, Hashable {
    public var codec: String
    public var channels: Int
    public var sampleRate: Int
    public var bitrate: Int64
    public var duration: Double = 0
}

/// Everything ffprobe knows about one media file.
public struct MediaInfo: Identifiable, Sendable, Hashable {
    public var id: URL { url }
    public var url: URL
    public var size: Int64
    public var container: String
    public var duration: Double
    public var bitrate: Int64
    public var video: VideoStream?
    public var audio: [AudioStream]
    public var tags: [String: String]
}

public enum MediaError: LocalizedError {
    case noFFprobe
    case unreadable(String)
    public var errorDescription: String? {
        switch self {
        case .noFFprobe: return "ffprobe non trovato. Installalo con Homebrew (brew install ffmpeg)."
        case .unreadable(let n): return TF("Impossibile leggere %@.", n)
        }
    }
}

extension Doctor {
    public static var ffprobePath: String? {
        ["/usr/local/bin/ffprobe", "/opt/homebrew/bin/ffprobe", "/usr/bin/ffprobe"].first { fm.isExecutableFile(atPath: $0) }
    }

    static func ratio(_ s: String?) -> Double {
        guard let s, let i = s.firstIndex(of: "/"), let n = Double(s[..<i]), let d = Double(s[s.index(after: i)...]), d > 0 else { return Double(s ?? "") ?? 0 }
        return n / d
    }

    /// Turns ffprobe's JSON into a MediaInfo. Pure, so it can be tested with fixed text.
    public static func parseProbe(_ data: Data, url: URL, size: Int64) -> MediaInfo? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let streams = root["streams"] as? [[String: Any]] ?? []
        let format = root["format"] as? [String: Any] ?? [:]
        func int(_ v: Any?) -> Int64 { Int64(("\(v ?? "")" as String)) ?? 0 }

        var video: VideoStream?
        var audio: [AudioStream] = []
        for s in streams {
            switch s["codec_type"] as? String {
            case "video" where video == nil && (s["disposition"] as? [String: Int])?["attached_pic"] != 1:
                let pix = s["pix_fmt"] as? String ?? ""
                var depth = Int(int(s["bits_per_raw_sample"]))
                if depth == 0 { depth = pix.contains("12") ? 12 : pix.contains("10") ? 10 : 8 }
                let chroma = pix.contains("444") ? "4:4:4" : pix.contains("422") ? "4:2:2" : pix.contains("420") ? "4:2:0" : (pix.isEmpty ? "?" : pix)
                var rot = 0
                if let side = s["side_data_list"] as? [[String: Any]], let r = side.compactMap({ $0["rotation"] }).first { rot = Int(("\(r)" as String)) ?? 0 }
                else if let tags = s["tags"] as? [String: String], let r = tags["rotate"] { rot = Int(r) ?? 0 }
                let declared = ratio(s["r_frame_rate"] as? String), avg = ratio(s["avg_frame_rate"] as? String)
                let vfr = declared > 0 && avg > 0 && abs(declared - avg) / declared > 0.01
                video = VideoStream(codec: s["codec_name"] as? String ?? "?", profile: s["profile"] as? String ?? "",
                                    width: Int(int(s["width"])), height: Int(int(s["height"])), rotation: rot,
                                    fps: avg > 0 ? avg : declared, isVFR: vfr, bitDepth: depth, chroma: chroma, pixFmt: pix,
                                    colorSpace: s["color_space"] as? String ?? "", transfer: s["color_transfer"] as? String ?? "",
                                    primaries: s["color_primaries"] as? String ?? "", bitrate: int(s["bit_rate"]),
                                    duration: Double("\(s["duration"] ?? "")") ?? 0)
            case "audio":
                audio.append(AudioStream(codec: s["codec_name"] as? String ?? "?", channels: Int(int(s["channels"])),
                                         sampleRate: Int(int(s["sample_rate"])), bitrate: int(s["bit_rate"]),
                                         duration: Double("\(s["duration"] ?? "")") ?? 0))
            default: break
            }
        }
        return MediaInfo(url: url, size: size, container: (format["format_name"] as? String) ?? "?",
                         duration: Double("\(format["duration"] ?? "")") ?? 0, bitrate: int(format["bit_rate"]),
                         video: video, audio: audio, tags: format["tags"] as? [String: String] ?? [:])
    }

    public static func probeMedia(_ url: URL) throws -> MediaInfo {
        guard let tool = ffprobePath else { throw MediaError.noFFprobe }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let size = byteSize(url)
        guard p.terminationStatus == 0, let info = parseProbe(data, url: url, size: size) else {
            throw MediaError.unreadable(url.lastPathComponent)
        }
        return info
    }

    /// Inspects every media file under a folder, four at a time. Files that cannot be read are returned apart.
    public static func probeFolder(_ folder: URL) throws -> (ok: [MediaInfo], failed: [URL]) {
        guard ffprobePath != nil else { throw MediaError.noFFprobe }
        var files: [URL] = []
        if let e = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let u as URL in e where mediaExtensions.contains(u.pathExtension.lowercased()) { files.append(u) }
        }
        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let lock = NSLock()
        var ok: [Int: MediaInfo] = [:]
        var failed: [Int: URL] = [:]
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            let r = try? probeMedia(files[i])
            lock.lock(); defer { lock.unlock() }
            if let r { ok[i] = r } else { failed[i] = files[i] }
        }
        return (ok.sorted { $0.key < $1.key }.map(\.value), failed.sorted { $0.key < $1.key }.map(\.value))
    }
}
