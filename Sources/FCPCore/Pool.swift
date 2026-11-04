import AVFoundation
import Foundation

/// What the app learned about one clip before it goes into Final Cut.
public struct ClipInfo: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let size: Int64
    public let seconds: Double
    public let width: Int
    public let height: Int
    public let fps: Double
    public let codec: String
    public let hasVideo: Bool
    public let hasAudio: Bool
    /// Things that make Final Cut slow or unhappy.
    public let notes: [String]
}

/// Where a downloaded folder will go: `<pool>/<client>/<video>/Originali`.
public struct PoolPlan: Sendable {
    public let client: String
    public let video: String
    public let folder: URL
    public var originals: URL { folder.appendingPathComponent("Originali") }
    public var others: URL { folder.appendingPathComponent("Altro") }
    /// Media files in natural name order: clip2 before clip10.
    public let media: [URL]
    /// Everything else (briefs, PDFs…): kept, in "Altro".
    public let rest: [URL]
}

public struct PoolResult: Sendable {
    public var media: [URL] = []
    /// The media files that were really put in the pool now (not duplicates that were already there).
    public var placed: [URL] = []
    public var moved = 0
    public var duplicates = 0
    public var renamed = 0
    public var failures: [String] = []
}

extension Doctor {
    public static let mediaExtensions: Set<String> = [
        "mov", "mp4", "m4v", "mxf", "avi", "mkv", "mts", "m2ts", "mpg", "mpeg",
        "wav", "aif", "aiff", "mp3", "m4a", "aac", "jpg", "jpeg", "png", "heic", "tif", "tiff", "psd",
    ]
    static let junkNames: Set<String> = [".DS_Store", "Thumbs.db", "desktop.ini"]

    /// Real size in bytes (not the block-rounded size on disk).
    static func byteSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
    }

    /// Same bytes: same size first (cheap), then the checksum.
    static func sameContent(_ a: URL, _ b: URL) -> Bool {
        guard byteSize(a) == byteSize(b), let x = try? fileChecksum(a), let y = try? fileChecksum(b) else { return false }
        return x == y
    }

    public static func isFolder(_ url: URL) -> Bool { isDirectory(url) }

    /// What the pool already holds: clients and their videos (videos with no client are listed apart).
    public static func poolContents(_ root: URL) -> [(client: String, videos: [String])] {
        func dirs(_ url: URL) -> [String] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                .filter(isDirectory).map(\.lastPathComponent)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        var out: [(client: String, videos: [String])] = []
        var loose: [String] = []
        for name in dirs(root) {
            let dir = root.appendingPathComponent(name)
            if fm.fileExists(atPath: dir.appendingPathComponent("Originali").path) { loose.append(name) } else {
                out.append((name, dirs(dir)))
            }
        }
        if !loose.isEmpty { out.append(("Senza cliente", loose)) }
        return out
    }

    /// "Rossi - Spot estate" → ("Rossi", "Spot estate"). Drive's own folder names give no client.
    public static func guessClientAndVideo(from folder: String) -> (client: String, video: String) {
        var name = folder.trimmingCharacters(in: .whitespaces)
        if name.lowercased().hasPrefix("drive-download") { return ("", "") }
        if let r = name.range(of: #" \(\d+\)$"#, options: .regularExpression) { name.removeSubrange(r) }
        for sep in [" - ", " – ", " — ", "_", " | "] {
            if let r = name.range(of: sep) {
                return (String(name[..<r.lowerBound]).trimmingCharacters(in: .whitespaces),
                        String(name[r.upperBound...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return ("", name)
    }

    /// A folder name that is safe on every filesystem.
    public static func safeFolderName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\\0").union(.controlCharacters)
        let cleaned = s.unicodeScalars.filter { !bad.contains($0) }
        let name = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespaces)
        return name.hasPrefix(".") ? String(name.drop(while: { $0 == "." })) : name
    }

    /// Client folders are always in CAPITALS, whatever was typed.
    public static func clientFolderName(_ s: String) -> String { safeFolderName(s).uppercased() }

    public static func poolPlan(source: URL, client: String, video: String, poolRoot: URL) -> PoolPlan {
        var media: [URL] = [], rest: [URL] = []
        if let e = fm.enumerator(atPath: source.path) {
            for case let rel as String in e {
                let u = source.appendingPathComponent(rel)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue,
                      !junkNames.contains(u.lastPathComponent), !u.lastPathComponent.hasPrefix("._"),
                      !["crdownload", "part", "download", "tmp"].contains(u.pathExtension.lowercased()) else { continue }
                if mediaExtensions.contains(u.pathExtension.lowercased()) { media.append(u) } else { rest.append(u) }
            }
        }
        let byName: (URL, URL) -> Bool = {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        var folder = poolRoot
        let c = clientFolderName(client), v = safeFolderName(video)
        if !c.isEmpty { folder.appendPathComponent(c) }
        folder.appendPathComponent(v.isEmpty ? "Senza titolo" : v)
        return PoolPlan(client: c, video: v, folder: folder, media: media.sorted(by: byName), rest: rest.sorted(by: byName))
    }

    /// Moves (or copies) the folder's files into the pool. A file that already exists with the same
    /// size is a duplicate and is left where it is; a different file with the same name gets " 2".
    public static func poolImport(_ plan: PoolPlan, move: Bool,
                                  progress: @Sendable (String) -> Void = { _ in }) -> PoolResult {
        var result = PoolResult()
        func place(_ files: [URL], into dir: URL, isMedia: Bool) {
            guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else {
                result.failures.append("\(dir.lastPathComponent): non riesco a creare la cartella")
                return
            }
            for (i, src) in files.enumerated() {
                progress("\(move ? "Sposto" : "Copio") \(i + 1) di \(files.count): \(src.lastPathComponent)")
                var dest = dir.appendingPathComponent(src.lastPathComponent)
                if fm.fileExists(atPath: dest.path) {
                    if sameContent(dest, src) {
                        result.duplicates += 1
                        if isMedia { result.media.append(dest) }
                        continue
                    }
                    var n = 2
                    let base = src.deletingPathExtension().lastPathComponent, ext = src.pathExtension
                    repeat {
                        dest = dir.appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
                        n += 1
                    } while fm.fileExists(atPath: dest.path)
                    result.renamed += 1
                }
                do {
                    if move { try fm.moveItem(at: src, to: dest) } else { try fm.copyItem(at: src, to: dest) }
                    result.moved += 1
                    if isMedia { result.media.append(dest); result.placed.append(dest) }
                } catch {
                    result.failures.append("\(src.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        place(plan.media, into: plan.originals, isMedia: true)
        place(plan.rest, into: plan.others, isMedia: false)
        return result
    }

    /// Clips of the same size that really are the same bytes.
    public static func duplicates(in urls: [URL]) -> [[URL]] {
        var bySize: [Int64: [URL]] = [:]
        for u in urls { bySize[byteSize(u), default: []].append(u) }
        var groups: [[URL]] = []
        for (_, same) in bySize where same.count > 1 {
            var byHash: [String: [URL]] = [:]
            for u in same { if let h = try? fileChecksum(u) { byHash[h, default: []].append(u) } }
            groups += byHash.values.filter { $0.count > 1 }
        }
        return groups
    }

    // MARK: Inspecting

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255), UInt8(code & 255)]
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    public static func inspect(_ url: URL) async -> ClipInfo {
        let asset = AVURLAsset(url: url)
        let seconds = ((try? await asset.load(.duration))?.seconds ?? 0).sanitized
        let video = (try? await asset.loadTracks(withMediaType: .video))?.first
        let hasAudio = !(((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty)
        var w = 0, h = 0, fps = 0.0, codec = "—"
        var notes: [String] = []
        if let v = video {
            let size = (try? await v.load(.naturalSize)) ?? .zero
            let t = (try? await v.load(.preferredTransform)) ?? .identity
            let rotated = abs(t.b) == 1 && abs(t.c) == 1
            w = Int(rotated ? size.height : size.width)
            h = Int(rotated ? size.width : size.height)
            fps = Double((try? await v.load(.nominalFrameRate)) ?? 0)
            let minDur = ((try? await v.load(.minFrameDuration))?.seconds ?? 0).sanitized
            if let f = (try? await v.load(.formatDescriptions))?.first {
                codec = fourCC(CMFormatDescriptionGetMediaSubType(f))
            }
            if fps > 0, minDur > 0, abs(1 / minDur - fps) / fps > 0.1 {
                notes.append("frame rate variabile (tipico dei telefoni): rallenta l'importazione, meglio convertirlo")
            }
            if ["hvc1", "hev1"].contains(codec) { notes.append("HEVC: pesante da importare, valuta i proxy") }
            if max(w, h) >= 3840 { notes.append("4K: usa i proxy o rallenta") }
        }
        return ClipInfo(url: url, size: allocated(url), seconds: seconds, width: w, height: h, fps: fps,
                        codec: codec, hasVideo: video != nil, hasAudio: hasAudio, notes: notes)
    }

    // MARK: Final Cut import file

    static func frameDuration(fps: Double) -> (num: Int, den: Int) {
        let known: [(Double, Int, Int)] = [(23.976, 1001, 24000), (24, 100, 2400), (25, 100, 2500),
                                           (29.97, 1001, 30000), (30, 100, 3000), (50, 100, 5000),
                                           (59.94, 1001, 60000), (60, 100, 6000)]
        if let m = known.min(by: { abs($0.0 - fps) < abs($1.0 - fps) }), abs(m.0 - fps) < 0.05 { return (m.1, m.2) }
        return (100, max(1, Int((fps * 100).rounded())))
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// An FCPXML that creates one event with these clips in the given order, linked where they are.
    /// Opening it in Final Cut imports them without the Import window.
    public static func fcpxml(event: String, clips: [ClipInfo]) -> String {
        var formats: [String: String] = [:]
        var resources = "", items = ""
        var n = 1
        for clip in clips where clip.seconds > 0 && (clip.hasVideo || clip.hasAudio) {
            var formatID: String?
            var fd = (num: 100, den: 2500)
            if clip.hasVideo, clip.width > 0 {
                fd = frameDuration(fps: clip.fps > 0 ? clip.fps : 25)
                let key = "\(clip.width)x\(clip.height)@\(fd.num)/\(fd.den)"
                if formats[key] == nil {
                    formats[key] = "r\(n)"
                    n += 1
                    resources += "    <format id=\"\(formats[key]!)\" frameDuration=\"\(fd.num)/\(fd.den)s\" width=\"\(clip.width)\" height=\"\(clip.height)\"/>\n"
                }
                formatID = formats[key]
            }
            let frames = Int((clip.seconds / (Double(fd.num) / Double(fd.den))).rounded())
            let dur = "\(frames * fd.num)/\(fd.den)s"
            let id = "r\(n)"
            n += 1
            let name = xmlEscape(clip.url.deletingPathExtension().lastPathComponent)
            let fmt = formatID.map { " format=\"\($0)\"" } ?? ""
            resources += "    <asset id=\"\(id)\" name=\"\(name)\" start=\"0s\" duration=\"\(dur)\" hasVideo=\"\(clip.hasVideo ? 1 : 0)\" hasAudio=\"\(clip.hasAudio ? 1 : 0)\"\(fmt)>\n      <media-rep kind=\"original-media\" src=\"\(xmlEscape(clip.url.absoluteString))\"/>\n    </asset>\n"
            items += "      <asset-clip ref=\"\(id)\" name=\"\(name)\" duration=\"\(dur)\"\(fmt) tcFormat=\"NDF\"/>\n"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.10">
          <resources>
        \(resources)  </resources>
          <event name="\(xmlEscape(event))">
        \(items)  </event>
        </fcpxml>

        """
    }
}

private extension Double {
    var sanitized: Double { isFinite && self > 0 ? self : 0 }
}
