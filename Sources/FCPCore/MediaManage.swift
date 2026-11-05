import CryptoKit
import Foundation

public struct DuplicateGroup: Identifiable, Sendable {
    public var id: String { files.first?.path ?? "" }
    public let files: [URL]
    public let size: Int64
    /// Space that would come back if only one copy were kept.
    public var wasted: Int64 { size * Int64(files.count - 1) }
}

/// Files that look like versions of one another (…copy, …final, …(2)) but do not have the same content.
public struct VersionGroup: Identifiable, Sendable {
    public var id: String { stem }
    public let stem: String
    public let files: [URL]
}

/// One planned move or rename. `conflict` is set when it must not be carried out.
public struct MoveStep: Identifiable, Sendable, Hashable {
    public var id: URL { from }
    public let from: URL
    public let to: URL
    public let conflict: String?
}

public enum OrganizeBy: Sendable { case type, date }

public struct FolderDiff: Sendable {
    public var onlyInA: [String] = []
    public var onlyInB: [String] = []
    public var different: [String] = []
    public var same = 0
}

public struct ManifestCheck: Sendable {
    public var changed: [String] = []
    public var missing: [String] = []
    public var new: [String] = []
    public var ok: Bool { changed.isEmpty && missing.isEmpty }
}

private struct MoveBatch: Codable {
    var date: Date
    var label: String
    var moves: [[String]]  // [from, to]
}

extension Doctor {
    static func regularFiles(in folder: URL) -> [URL] {
        var out: [URL] = []
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        for case let u as URL in e where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { out.append(u) }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: Duplicates and versions

    static func versionStem(_ name: String) -> String {
        var s = (name as NSString).deletingPathExtension.lowercased()
        let pattern = #"( copy( \d+)?| copia( \d+)?|[ _-]final[e]?|\(\d+\)|[ _-]v\d+)$"#
        while let r = s.range(of: pattern, options: .regularExpression) { s.removeSubrange(r) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    public static func findDuplicates(in folder: URL, minSize: Int64 = 1) -> (identical: [DuplicateGroup], versions: [VersionGroup]) {
        let files = regularFiles(in: folder).filter { byteSize($0) >= minSize }
        let identical = duplicates(in: files).map { g in
            DuplicateGroup(files: g.sorted { $0.path < $1.path }, size: byteSize(g[0]))
        }.sorted { $0.wasted > $1.wasted }

        var inIdentical = Set<URL>()
        for g in identical { for f in g.files.dropFirst() { inIdentical.insert(f) } }  // keep one per group for the version check
        var byStem: [String: [URL]] = [:]
        for f in files where !inIdentical.contains(f) { byStem["\(versionStem(f.lastPathComponent)).\(f.pathExtension.lowercased())", default: []].append(f) }
        let versions = byStem.filter { $0.value.count > 1 && Set($0.value.map { $0.lastPathComponent.lowercased() }).count > 1 }
            .map { VersionGroup(stem: $0.key, files: $0.value) }.sorted { $0.stem < $1.stem }
        return (identical, versions)
    }

    // MARK: Rename

    /// Template tokens: {name}, {n} or {n:3} (counter, zero padded), {date} or {date:yyyyMMdd} (modification day). The extension is kept.
    /// Files inside a Final Cut library or its Original Media are never renamed: the library links to them by name.
    public static func renamePlan(_ files: [URL], template: String, find: String = "", replace: String = "", startAt: Int = 1) -> [MoveStep] {
        let sorted = files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        var steps: [(URL, URL, String?)] = []
        for (i, f) in sorted.enumerated() {
            var stem = f.deletingPathExtension().lastPathComponent
            if !find.isEmpty { stem = stem.replacingOccurrences(of: find, with: replace) }
            var name = template.replacingOccurrences(of: "{name}", with: stem)
            let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            name = name.replacingOccurrences(of: "{date}", with: day.string(from: date))
            while let r = name.range(of: #"\{date:([A-Za-z0-9._ -]+)\}"#, options: .regularExpression) {
                let format = String(name[r].dropFirst(6).dropLast())
                let f = DateFormatter()
                f.dateFormat = format
                name.replaceSubrange(r, with: f.string(from: date))
            }
            if let r = name.range(of: #"\{n(:(\d+))?\}"#, options: .regularExpression) {
                let token = String(name[r])
                let pad = token.contains(":") ? Int(token.dropFirst(3).dropLast()) ?? 1 : 1
                name.replaceSubrange(r, with: String(format: "%0\(pad)d", startAt + i))
            }
            name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            let ext = f.pathExtension
            let full = ext.isEmpty ? name : "\(name).\(ext)"
            var problem: String?
            if name.trimmingCharacters(in: .whitespaces).isEmpty { problem = "Nome vuoto" }
            else if full == f.lastPathComponent { problem = "Nome invariato" }
            else if f.path.contains("Original Media") || f.path.contains(".fcpbundle") { problem = "File di Final Cut: non si rinomina" }
            steps.append((f, f.deletingLastPathComponent().appendingPathComponent(full), problem))
        }
        let targets = Dictionary(grouping: steps, by: { $0.1.path.lowercased() })
        return steps.map { s in
            var p = s.2
            if p == nil, (targets[s.1.path.lowercased()]?.count ?? 0) > 1 { p = "Due file avrebbero lo stesso nome" }
            if p == nil, fm.fileExists(atPath: s.1.path) { p = "Esiste già un file con questo nome" }
            return MoveStep(from: s.0, to: s.1, conflict: p)
        }
    }

    // MARK: Organize

    static let typeFolders: [(String, Set<String>)] = [
        ("Video", ["mov", "mp4", "m4v", "mxf", "avi", "mkv", "mts", "m2ts", "r3d", "braw", "webm"]),
        ("Audio", ["wav", "aif", "aiff", "mp3", "m4a", "aac", "flac"]),
        ("Immagini", ["jpg", "jpeg", "png", "heic", "tif", "tiff", "psd", "raw", "dng", "gif"]),
        ("Progetti", ["fcpxml", "xml", "prproj", "drp", "aep", "srt", "vtt"]),
    ]

    /// Plans how loose files in the top level of a folder would be sorted into subfolders. Nothing is moved here.
    public static func organizePlan(_ folder: URL, by mode: OrganizeBy) -> [MoveStep] {
        let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        let month = DateFormatter()
        month.dateFormat = "yyyy-MM"
        return items.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { f in
                let bucket: String
                switch mode {
                case .type: bucket = typeFolders.first { $0.1.contains(f.pathExtension.lowercased()) }?.0 ?? "Altro"
                case .date: bucket = month.string(from: (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date())
                }
                let to = folder.appendingPathComponent(bucket).appendingPathComponent(f.lastPathComponent)
                return MoveStep(from: f, to: to, conflict: fm.fileExists(atPath: to.path) ? "Esiste già nella cartella di destinazione" : nil)
            }
    }

    // MARK: Moves with undo

    public static var movesLogURL: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/FCP Toolbox/moves.json")
    }

    /// Carries out the steps that have no conflict, never overwriting, and records them so they can be undone.
    @discardableResult
    public static func applyMoves(_ steps: [MoveStep], label: String, log: URL = movesLogURL) -> (done: Int, failures: [String]) {
        var done: [[String]] = []
        var failures: [String] = []
        for s in steps where s.conflict == nil {
            guard !fm.fileExists(atPath: s.to.path) else { failures.append(TF("%@: destinazione già presente", s.from.lastPathComponent)); continue }
            do {
                try fm.createDirectory(at: s.to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: s.from, to: s.to)
                done.append([s.from.path, s.to.path])
            } catch { failures.append("\(s.from.lastPathComponent): \(error.localizedDescription)") }
        }
        if !done.isEmpty {
            var batches = loadBatches(log)
            batches.append(MoveBatch(date: Date(), label: label, moves: done))
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            try? fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let d = try? enc.encode(batches) { try? d.write(to: log) }
        }
        return (done.count, failures)
    }

    private static func loadBatches(_ log: URL) -> [MoveBatch] {
        guard let d = try? Data(contentsOf: log) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([MoveBatch].self, from: d)) ?? []
    }

    public static func lastMoveLabel(log: URL = movesLogURL) -> String? { loadBatches(log).last?.label }

    /// Puts the files of the last batch back. Skips anything that changed since (never overwrites).
    @discardableResult
    public static func undoLastMoves(log: URL = movesLogURL) -> (restored: Int, failures: [String]) {
        var batches = loadBatches(log)
        guard let last = batches.popLast() else { return (0, []) }
        var restored = 0
        var failures: [String] = []
        for m in last.moves.reversed() {
            let from = URL(fileURLWithPath: m[0]), to = URL(fileURLWithPath: m[1])
            guard fm.fileExists(atPath: to.path) else { failures.append("\(to.lastPathComponent): non c'è più"); continue }
            guard !fm.fileExists(atPath: from.path) else { failures.append(TF("%@: il nome originale è occupato", from.lastPathComponent)); continue }
            do {
                try fm.moveItem(at: to, to: from)
                restored += 1
                // remove the bucket folder only if it is now empty (removeItem would fail on a non-empty one)
                let parent = to.deletingLastPathComponent()
                if (try? fm.contentsOfDirectory(atPath: parent.path))?.isEmpty == true, parent != from.deletingLastPathComponent() {
                    try? fm.removeItem(at: parent)
                }
            } catch { failures.append("\(to.lastPathComponent): \(error.localizedDescription)") }
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(batches) { try? d.write(to: log) }
        return (restored, failures)
    }

    // MARK: Compare and integrity

    public static func compareFolders(_ a: URL, _ b: URL) -> FolderDiff {
        func rel(_ root: URL) -> [String: URL] {
            let base = root.standardizedFileURL.path
            return Dictionary(regularFiles(in: root).map { (String($0.standardizedFileURL.path.dropFirst(base.count + 1)), $0) }, uniquingKeysWith: { x, _ in x })
        }
        let fa = rel(a), fb = rel(b)
        var d = FolderDiff()
        for (k, u) in fa {
            guard let v = fb[k] else { d.onlyInA.append(k); continue }
            if byteSize(u) == byteSize(v), sameContent(u, v) { d.same += 1 } else { d.different.append(k) }
        }
        d.onlyInB = fb.keys.filter { fa[$0] == nil }.sorted()
        d.onlyInA.sort(); d.different.sort()
        return d
    }

    static func manifestURL(for folder: URL) -> URL {
        let key = SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        return URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/FCP Toolbox/manifests/\(key).json")
    }

    /// Records the SHA-256 of every file so a later check can tell what changed. Stored outside the folder.
    @discardableResult
    public static func writeManifest(for folder: URL, at url: URL? = nil) -> Int {
        let base = folder.standardizedFileURL.path
        var m: [String: String] = [:]
        for f in regularFiles(in: folder) {
            if let h = try? fileChecksum(f) { m[String(f.standardizedFileURL.path.dropFirst(base.count + 1))] = h }
        }
        let dest = url ?? manifestURL(for: folder)
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(m) { try? d.write(to: dest) }
        return m.count
    }

    public static func verifyManifest(for folder: URL, at url: URL? = nil) -> ManifestCheck? {
        guard let d = try? Data(contentsOf: url ?? manifestURL(for: folder)),
              let old = try? JSONDecoder().decode([String: String].self, from: d) else { return nil }
        let base = folder.standardizedFileURL.path
        var seen = Set<String>()
        var r = ManifestCheck()
        for f in regularFiles(in: folder) {
            let k = String(f.standardizedFileURL.path.dropFirst(base.count + 1))
            seen.insert(k)
            guard let was = old[k] else { r.new.append(k); continue }
            if (try? fileChecksum(f)) != was { r.changed.append(k) }
        }
        r.missing = old.keys.filter { !seen.contains($0) }.sorted()
        r.changed.sort(); r.new.sort()
        return r
    }
}
