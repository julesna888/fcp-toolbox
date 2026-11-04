import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum MetadataKind: String, CaseIterable, Identifiable, Sendable {
    case location = "Posizione (GPS)"
    case device = "Dispositivo e programma"
    case dates = "Date"
    case text = "Titolo, commenti, autore"
    case everything = "Tutto"
    public var id: String { rawValue }
}

public struct MetadataCleanResult: Sendable {
    public let output: URL?
    public let problem: String?
    public let removed: [String]
}

extension Doctor {
    /// Which of a video's metadata keys belong to the chosen groups.
    static func metadataKeys(_ tags: [String: String], matching kinds: Set<MetadataKind>) -> [String] {
        if kinds.contains(.everything) { return Array(tags.keys) }
        return tags.keys.filter { key in
            let k = key.lowercased()
            return kinds.contains { kind in
                switch kind {
                case .location: return k.contains("location") || k.contains("gps") || k.contains("iso6709")
                case .device: return ["make", "model", "software", "encoder", "com.android.version", "manufacturer"].contains { k.contains($0) }
                case .dates: return k.contains("creation") || k.contains("date") || k.contains("time")
                case .text: return ["title", "comment", "description", "artist", "author", "copyright", "album", "genre", "composer", "synopsis"].contains { k.contains($0) }
                case .everything: return true
                }
            }
        }
    }

    private static let photoExtensions: Set<String> = ["jpg", "jpeg", "heic", "png", "tif", "tiff"]
    public static func isPhoto(_ url: URL) -> Bool { photoExtensions.contains(url.pathExtension.lowercased()) }

    private static func uniqueSibling(of source: URL, suffix: String) -> URL {
        let dir = source.deletingLastPathComponent(), ext = source.pathExtension
        let stem = source.deletingPathExtension().lastPathComponent + suffix
        var out = dir.appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)")
        var n = 2
        while fm.fileExists(atPath: out.path) {
            out = dir.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        return out
    }

    /// Writes a copy ("… pulito") without the chosen metadata. The original is never changed.
    /// Photos are saved again by macOS at maximum quality (JPEG/HEIC are re-compressed very slightly); videos are copied without re-encoding.
    public static func cleanMetadata(_ source: URL, remove kinds: Set<MetadataKind>) -> MetadataCleanResult {
        func fail(_ m: String) -> MetadataCleanResult { MetadataCleanResult(output: nil, problem: m, removed: []) }
        guard !kinds.isEmpty else { return fail("Scegli almeno un tipo di dati da togliere.") }
        let out = uniqueSibling(of: source, suffix: " pulito")
        let before = probe([source.deletingLastPathComponent()])
        let result = isPhoto(source) ? cleanPhoto(source, to: out, kinds: kinds) : cleanVideo(source, to: out, kinds: kinds)
        guard let removed = result.removed else {
            try? fm.removeItem(at: out)  // the unfinished file this call created
            return fail(result.problem ?? "Pulizia non riuscita.")
        }
        _ = logOperation(kind: "metadata", summary: "Metadata tolti da \(source.lastPathComponent): \(kinds.map(\.rawValue).sorted().joined(separator: ", "))",
                         paths: [out], estimated: byteSize(out), failures: [], before: before)
        return MetadataCleanResult(output: out, problem: nil, removed: removed)
    }

    private static func cleanVideo(_ source: URL, to out: URL, kinds: Set<MetadataKind>) -> (removed: [String]?, problem: String?) {
        guard let ffmpeg = ffmpegPath else { return (nil, "ffmpeg non trovato (brew install ffmpeg).") }
        guard let info = try? probeMedia(source) else { return (nil, "Non riesco a leggere \(source.lastPathComponent).") }
        let keys = metadataKeys(info.tags, matching: kinds)
        var args = ["-hide_banner", "-loglevel", "error", "-i", source.path, "-map", "0", "-c", "copy"]
        if kinds.contains(.everything) {
            args += ["-map_metadata", "-1", "-fflags", "+bitexact"]
        } else {
            for k in keys { args += ["-metadata", "\(k)="] }
            if kinds.contains(.dates) {
                args += ["-metadata:s:v", "creation_time=", "-metadata:s:a", "creation_time="]
            } else if let created = info.tags["creation_time"] {
                args += ["-metadata", "creation_time=\(created)"]  // ffmpeg loses the date on a remux unless it is set again
            }
        }
        let r = run(ffmpeg, args + [out.path])
        guard r.status == 0, let made = try? probeMedia(out), made.duration > 0 else {
            return (nil, "Pulizia non riuscita: " + (r.out.split(separator: "\n").last.map(String.init) ?? "errore sconosciuto"))
        }
        let left = Set(made.tags.keys).intersection(keys)
        if !left.isEmpty && !kinds.contains(.everything) { return (nil, "Alcuni dati sono rimasti nel file: \(left.sorted().joined(separator: ", "))") }
        return (keys.sorted(), nil)
    }

    private static func cleanPhoto(_ source: URL, to out: URL, kinds: Set<MetadataKind>) -> (removed: [String]?, problem: String?) {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil), let type = CGImageSourceGetType(src),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return (nil, "Non riesco ad aprire \(source.lastPathComponent) come foto.")
        }
        var removed: [String] = []
        var new: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1.0]
        func drop(_ dict: CFString, _ keys: [CFString]?, label: String) {
            guard let d = new[dict] as? [CFString: Any] ?? props[dict] as? [CFString: Any], !d.isEmpty else { return }
            guard let keys else { new[dict] = kCFNull; removed.append(label); return }
            let hit = keys.filter { d[$0] != nil }
            guard !hit.isEmpty else { return }
            var copy = d
            for k in hit { copy[k] = kCFNull }
            new[dict] = copy
            removed.append(label)
        }
        let all = kinds.contains(.everything)
        if all || kinds.contains(.location) { drop(kCGImagePropertyGPSDictionary, nil, label: "GPS") }
        if all || kinds.contains(.device) {
            drop(kCGImagePropertyTIFFDictionary, [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFSoftware], label: "Dispositivo")
            drop(kCGImagePropertyExifDictionary, [kCGImagePropertyExifLensMake, kCGImagePropertyExifLensModel, kCGImagePropertyExifBodySerialNumber,
                                                   kCGImagePropertyExifCameraOwnerName, kCGImagePropertyExifLensSerialNumber], label: "Obiettivo e numero di serie")
        }
        if all || kinds.contains(.dates) {
            drop(kCGImagePropertyExifDictionary, [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized], label: "Date")
            drop(kCGImagePropertyTIFFDictionary, [kCGImagePropertyTIFFDateTime], label: "Data")
        }
        if all || kinds.contains(.text) {
            drop(kCGImagePropertyIPTCDictionary, nil, label: "IPTC")
            drop(kCGImagePropertyTIFFDictionary, [kCGImagePropertyTIFFImageDescription, kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright], label: "Testi")
            drop(kCGImagePropertyExifDictionary, [kCGImagePropertyExifUserComment], label: "Commento")
        }
        if all {
            for d in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyMakerAppleDictionary,
                      kCGImagePropertyExifAuxDictionary, kCGImagePropertyMakerCanonDictionary, kCGImagePropertyMakerNikonDictionary] {
                if props[d] != nil { new[d] = kCFNull }
            }
            removed.append("Tutto")
        }
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) else { return (nil, "Non riesco a creare il nuovo file.") }
        CGImageDestinationAddImageFromSource(dest, src, 0, new as CFDictionary)
        guard CGImageDestinationFinalize(dest), fm.fileExists(atPath: out.path) else { return (nil, "Non riesco a salvare la foto pulita.") }
        return (removed, nil)
    }

    /// Metadata present in a photo or video, for showing before cleaning.
    public static func metadataSummary(_ url: URL) -> [String] {
        if isPhoto(url) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return [] }
            var out: [String] = []
            if p[kCGImagePropertyGPSDictionary] != nil { out.append("Posizione GPS") }
            if let t = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                let device = [t[kCGImagePropertyTIFFMake], t[kCGImagePropertyTIFFModel]].compactMap { $0 as? String }.joined(separator: " ")
                if !device.isEmpty { out.append("Dispositivo: \(device)") }
            }
            if let e = p[kCGImagePropertyExifDictionary] as? [CFString: Any], let d = e[kCGImagePropertyExifDateTimeOriginal] { out.append("Scattata il \(d)") }
            if p[kCGImagePropertyIPTCDictionary] != nil { out.append("Titolo/autore (IPTC)") }
            return out
        }
        return ((try? probeMedia(url))?.tags ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
    }
}
