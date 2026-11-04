import CryptoKit
import Foundation

/// What a backup would copy: files missing from the destination or different from it.
public struct BackupDiff: Sendable {
    public var new: [String] = []
    public var changed: [String] = []
    public var same = 0
    /// Files that only exist in the destination. They are never touched.
    public var extra = 0
    /// Bytes to copy.
    public var bytes: Int64 = 0
    public var toCopy: [String] { new + changed }
}

public struct BackupRecord: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public let date: Date
    public let source: String
    public let destination: String
    public let copied: Int
    public let bytes: Int64
    /// Copied files whose checksum matched the original.
    public let verified: Int
    public let failures: [String]
}

public enum BackupError: LocalizedError {
    case overlap
    case notEnoughSpace(needed: Int64, free: Int64)
    public var errorDescription: String? {
        switch self {
        case .overlap:
            return "La destinazione e la libreria sono una dentro l'altra. Scegli un altro disco o un'altra cartella."
        case .notEnoughSpace(let n, let f):
            return "Spazio insufficiente sulla destinazione: servono circa \(formatBytes(n)) (più un margine), ne restano \(formatBytes(f))."
        }
    }
}

extension Doctor {
    struct Entry { let size: Int64; let mtime: Date; let isLink: Bool; let isDir: Bool }

    /// Everything under `root`, by path relative to it. Symlinks are listed, never followed.
    static func entries(_ root: URL) -> [String: Entry] {
        var out: [String: Entry] = [:]
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        // Relative paths straight from the enumerator: standardizing URLs treats dangling links differently.
        guard let e = fm.enumerator(atPath: root.path) else { return out }
        for case let rel as String in e {
            let u = root.appendingPathComponent(rel)
            // A dangling link (a missing clip) makes resourceValues throw: ask the disk directly.
            let link = (try? fm.destinationOfSymbolicLink(atPath: u.path)) != nil
            let v = link ? nil : try? u.resourceValues(forKeys: Set(keys))
            out[rel] = Entry(
                size: Int64(v?.fileSize ?? 0), mtime: v?.contentModificationDate ?? .distantPast,
                isLink: link, isDir: v?.isDirectory == true)
        }
        return out
    }

    public static func diff(source: URL, destination: URL) -> BackupDiff {
        let s = entries(source), d = entries(destination)
        var r = BackupDiff()
        for (rel, a) in s where !a.isDir {
            guard let b = d[rel], !b.isDir else {
                r.new.append(rel)
                r.bytes += a.size
                continue
            }
            let same: Bool
            if a.isLink {
                same = b.isLink && (try? fm.destinationOfSymbolicLink(atPath: source.appendingPathComponent(rel).path))
                    == (try? fm.destinationOfSymbolicLink(atPath: destination.appendingPathComponent(rel).path))
            } else {
                same = !b.isLink && a.size == b.size && abs(a.mtime.timeIntervalSince(b.mtime)) < 2
            }
            if same { r.same += 1 } else {
                r.changed.append(rel)
                r.bytes += a.size
            }
        }
        r.extra = d.keys.filter { s[$0] == nil }.count
        r.new.sort()
        r.changed.sort()
        return r
    }

    public static func fileChecksum(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 4_000_000), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Incremental copy of `source` into `parent/<source name>`. Copies only what the diff says,
    /// through a temporary name, then checks every copied file against the original. Never deletes.
    public static func backup(source: URL, into parent: URL, verify: Bool = true,
                              progress: @Sendable (String) -> Void = { _ in }) throws -> BackupRecord {
        let src = source.standardizedFileURL
        let dst = parent.appendingPathComponent(src.lastPathComponent)
        let sp = src.path + "/", dp = dst.standardizedFileURL.path + "/"
        guard !dp.hasPrefix(sp), !sp.hasPrefix(dp) else { throw BackupError.overlap }
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)

        for (rel, e) in entries(src) where e.isDir {
            try fm.createDirectory(at: dst.appendingPathComponent(rel), withIntermediateDirectories: true)
        }
        let plan = diff(source: src, destination: dst)
        let free = freeSpace(of: parent) ?? Int64.max
        guard plan.bytes + 500_000_000 <= free else { throw BackupError.notEnoughSpace(needed: plan.bytes, free: free) }
        let changedSet = Set(plan.changed)
        var failures: [String] = []
        var copiedFiles: [String] = []
        var copyFailures = 0
        var bytes: Int64 = 0
        for (i, rel) in plan.toCopy.enumerated() {
            progress("Copio \(i + 1) di \(plan.toCopy.count): \((rel as NSString).lastPathComponent)")
            let from = src.appendingPathComponent(rel), to = dst.appendingPathComponent(rel)
            // A file in the backup that is newer than the original may hold work done there: never overwrite it.
            if changedSet.contains(rel), (try? fm.destinationOfSymbolicLink(atPath: from.path)) == nil,
               let sm = try? from.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               let dm = try? to.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               dm > sm.addingTimeInterval(2) {
                copyFailures += 1
                failures.append("\((rel as NSString).lastPathComponent): nel backup è più recente dell'originale, non sovrascritto")
                continue
            }
            do {
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let target = try? fm.destinationOfSymbolicLink(atPath: from.path) {
                    try? fm.removeItem(at: to)
                    try fm.createSymbolicLink(atPath: to.path, withDestinationPath: target)
                } else {
                    let tmp = to.appendingPathExtension("fcptmp")
                    try? fm.removeItem(at: tmp)
                    try fm.copyItem(at: from, to: tmp)
                    if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
                    try fm.moveItem(at: tmp, to: to)
                    copiedFiles.append(rel)
                    bytes += Int64((try? fm.attributesOfItem(atPath: to.path)[.size] as? Int) ?? 0)
                }
            } catch {
                copyFailures += 1
                failures.append("\((rel as NSString).lastPathComponent): \(error.localizedDescription)")
            }
        }
        var verified = 0
        if verify {
            for (i, rel) in copiedFiles.enumerated() {
                progress("Verifico \(i + 1) di \(copiedFiles.count): \((rel as NSString).lastPathComponent)")
                let a = try? fileChecksum(src.appendingPathComponent(rel))
                let b = try? fileChecksum(dst.appendingPathComponent(rel))
                if let a, a == b { verified += 1 } else {
                    failures.append("\((rel as NSString).lastPathComponent): la copia non coincide con l'originale")
                }
            }
        }
        return BackupRecord(date: Date(), source: src.path, destination: dst.path,
                            copied: plan.toCopy.count - copyFailures, bytes: bytes,
                            verified: verified, failures: failures)
    }

    /// What changed in `source` since the last recorded backup of it. Nil record = never backed up.
    public static func changesSinceLastBackup(source: URL, history: [BackupRecord] = history()) -> (record: BackupRecord?, diff: BackupDiff?) {
        let path = source.standardizedFileURL.path
        guard let last = history.filter({ $0.source == path }).max(by: { $0.date < $1.date }),
              fm.fileExists(atPath: last.destination) else { return (nil, nil) }
        return (last, diff(source: source, destination: URL(fileURLWithPath: last.destination)))
    }

    /// Temporary files left by a copy that was interrupted (power cut, disk unplugged). The next backup replaces them.
    public static func incompleteCopies(in destination: URL) -> [String] {
        guard let e = fm.enumerator(atPath: destination.path) else { return [] }
        return e.compactMap { $0 as? String }.filter { $0.hasSuffix(".fcptmp") }.sorted()
    }

    // MARK: History

    public static var historyURL: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FCP Toolbox/backups.json")
    }

    public static func history(at url: URL = historyURL) -> [BackupRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return ((try? dec.decode([BackupRecord].self, from: data)) ?? []).sorted { $0.date > $1.date }
    }

    public static func record(_ r: BackupRecord, at url: URL = historyURL) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode([r] + history(at: url)) else { return }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
