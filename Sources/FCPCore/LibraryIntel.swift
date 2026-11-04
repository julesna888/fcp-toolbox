import Foundation

/// Size of a library at one moment, with the weight of its known parts.
public struct LibrarySnapshot: Codable, Sendable, Hashable {
    public var date: Date
    public var path: String
    public var total: Int64
    public var parts: [String: Int64]
}

public struct Growth: Sendable {
    public let first: LibrarySnapshot
    public let last: LibrarySnapshot
    public var delta: Int64 { last.total - first.total }
    public var days: Double { last.date.timeIntervalSince(first.date) / 86_400 }
    /// Parts that changed by more than 50 MB, biggest change first.
    public var partChanges: [(label: String, delta: Int64)] {
        var out: [(String, Int64)] = []
        for key in Set(first.parts.keys).union(last.parts.keys) {
            let d = (last.parts[key] ?? 0) - (first.parts[key] ?? 0)
            if abs(d) > 50_000_000 { out.append((key, d)) }
        }
        return out.sorted { abs($0.1) > abs($1.1) }.map { (label: $0.0, delta: $0.1) }
    }
    public var text: String {
        let sign = delta >= 0 ? "+" : "-"
        var s = "\(sign)\(formatBytes(abs(delta))) in \(max(1, Int(days.rounded()))) giorni"
        if let top = partChanges.first { s += " (soprattutto \(top.label): \(top.delta >= 0 ? "+" : "-")\(formatBytes(abs(top.delta))))" }
        return s
    }
}

public struct FCPXMLReport: Sendable {
    public var version = ""
    public var assets = 0
    public var clips = 0
    public var frameRates: [String] = []
    public var missingFiles: [String] = []
    public var duplicateIDs: [String] = []
    public var danglingRefs: [String] = []
    public var anomalies: [String] = []
    public var isClean: Bool { missingFiles.isEmpty && duplicateIDs.isEmpty && danglingRefs.isEmpty && anomalies.isEmpty }
}

extension Doctor {
    public static var snapshotsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/FCP Toolbox/snapshots.jsonl")
    }

    public static func snapshots(for path: String, at log: URL = snapshotsURL) -> [LibrarySnapshot] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? dec.decode(LibrarySnapshot.self, from: Data($0.utf8)) }
            .filter { $0.path == path }.sorted { $0.date < $1.date }
    }

    /// Keeps one line per library when something changed or enough time has passed. Automatic backups are skipped.
    public static func recordSnapshots(_ libs: [Library], at log: URL = snapshotsURL, now: Date = Date(),
                                       minInterval: TimeInterval = 6 * 3600) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        var lines = Data()
        for lib in libs where !lib.isBackup {
            if let last = snapshots(for: lib.url.path, at: log).last,
               last.total == lib.total || now.timeIntervalSince(last.date) < minInterval { continue }
            var parts: [String: Int64] = [:]
            for i in lib.items where i.size > 0 { parts[i.label, default: 0] += i.size }
            parts["Altro"] = lib.other
            let snap = LibrarySnapshot(date: now, path: lib.url.path, total: lib.total, parts: parts)
            if let d = try? enc.encode(snap) { lines += d + Data("\n".utf8) }
        }
        guard !lines.isEmpty else { return }
        try? fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: log) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: lines)
        } else {
            try? lines.write(to: log)
        }
    }

    public static func growth(of path: String, at log: URL = snapshotsURL) -> Growth? {
        let s = snapshots(for: path, at: log)
        guard let first = s.first, let last = s.last, first != last else { return nil }
        return Growth(first: first, last: last)
    }

    /// Reads an FCPXML (or .fcpxmld bundle) without modifying it and lists what looks wrong.
    public static func analyzeFCPXML(_ url: URL) throws -> FCPXMLReport {
        var file = url
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { file = url.appendingPathComponent("Info.fcpxml") }
        let doc = try XMLDocument(contentsOf: file, options: [.nodeLoadExternalEntitiesNever])
        guard let root = doc.rootElement(), root.name == "fcpxml" else {
            throw NSError(domain: "FCPXML", code: 1, userInfo: [NSLocalizedDescriptionKey: "Non è un file FCPXML."])
        }
        var r = FCPXMLReport()
        r.version = root.attribute(forName: "version")?.stringValue ?? "?"

        var ids: [String: Int] = [:]
        var rates = Set<String>()
        let resources = root.elements(forName: "resources").first
        for el in resources?.children?.compactMap({ $0 as? XMLElement }) ?? [] {
            if let id = el.attribute(forName: "id")?.stringValue { ids[id, default: 0] += 1 }
            switch el.name {
            case "format":
                if let fd = el.attribute(forName: "frameDuration")?.stringValue, let fps = fps(fromFrameDuration: fd) { rates.insert(fps) }
            case "asset":
                r.assets += 1
                let src = el.attribute(forName: "src")?.stringValue
                    ?? (el.elements(forName: "media-rep").first?.attribute(forName: "src")?.stringValue)
                if let src, let u = URL(string: src), u.isFileURL, !fm.fileExists(atPath: u.path) {
                    r.missingFiles.append(u.path)
                }
                let name = el.attribute(forName: "name")?.stringValue ?? "?"
                if el.attribute(forName: "hasVideo")?.stringValue == "0", el.attribute(forName: "hasAudio")?.stringValue == "0" {
                    r.anomalies.append("\(name): non ha né video né audio.")
                }
                if let d = el.attribute(forName: "duration")?.stringValue, d.hasPrefix("0/") || d == "0s" {
                    r.anomalies.append("\(name): durata zero.")
                }
            default: break
            }
        }
        r.duplicateIDs = ids.filter { $0.value > 1 }.map(\.key).sorted()

        func walk(_ node: XMLElement) {
            for child in node.children?.compactMap({ $0 as? XMLElement }) ?? [] {
                if node.name != "resources" || child.name == "media" {
                    if child.name == "asset-clip" || child.name == "ref-clip" || child.name == "video" || child.name == "audio" { r.clips += 1 }
                    for key in ["ref", "format"] {
                        if let v = child.attribute(forName: key)?.stringValue, ids[v] == nil, child.name != "format" {
                            r.danglingRefs.append("\(child.name ?? "?") → \(v)")
                        }
                    }
                }
                walk(child)
            }
        }
        for el in root.children?.compactMap({ $0 as? XMLElement }) ?? [] where el.name != "resources" { walk(el) }

        r.frameRates = rates.sorted()
        if rates.count > 1 { r.anomalies.append("Più frame rate nello stesso file (\(r.frameRates.joined(separator: ", "))): la timeline potrebbe ricampionare.") }
        return r
    }

    static func fps(fromFrameDuration s: String) -> String? {
        let t = s.replacingOccurrences(of: "s", with: "").split(separator: "/")
        guard t.count == 2, let n = Double(t[0]), let d = Double(t[1]), n > 0 else { return nil }
        return String(format: "%g", (d / n * 100).rounded() / 100) + " fps"
    }
}
