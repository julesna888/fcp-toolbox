import Foundation

public enum Kind: Sendable { case protected, clean, onDemand }

/// A known folder inside a .fcpbundle (Render Files, Original Media, ...).
public struct Item: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let name: String
    public let label: String
    public let url: URL
    public let size: Int64
    public let kind: Kind
    /// Why this folder must stay, decided at scan time. nil = no objection.
    public let blocked: String?

    public init(name: String, label: String, url: URL, size: Int64, kind: Kind, blocked: String?) {
        self.name = name
        self.label = label
        self.url = url
        self.size = size
        self.kind = kind
        self.blocked = blocked
    }

    public func canClean(includeAnalysis: Bool) -> Bool {
        guard blocked == nil, size > 0 else { return false }
        return kind == .clean || (kind == .onDemand && includeAnalysis)
    }

    public func note(includeAnalysis: Bool) -> String {
        if let blocked { return blocked }
        if kind == .onDemand && !includeAnalysis { return "Opzionale" }
        return "Rigenerabile"
    }
}

public struct Library: Identifiable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let total: Int64
    public let items: [Item]
    /// Automatic backup made by Final Cut itself (lives in a "Final Cut Backups" folder).
    public let isBackup: Bool
    public var name: String { url.lastPathComponent }
    /// Weight of everything the scan has no name for (database, thumbnails, project files...).
    public var other: Int64 { max(0, total - items.reduce(0) { $0 + $1.size }) }
}

public struct CleanResult: Sendable {
    public var freed: Int64 = 0
    public var failures: [String] = []
}

public func formatBytes(_ n: Int64) -> String {
    n == 0 ? "—" : ByteCountFormatter.string(fromByteCount: n, countStyle: .file)  // base 1000, like Finder
}

public enum Doctor {
    static let kinds: [String: Kind] = [
        "Original Media": .protected,
        "Backups": .protected,
        "Render Files": .clean,
        "Transcoded Media": .clean,  // optimized/proxy, rebuilt from originals
        "Analysis Files": .onDemand,  // rebuilt, but re-analysis can take hours
    ]
    static let fm = FileManager.default

    /// Real bytes on disk. Symlinks are not followed.
    public static func diskSize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey]
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            total += Int64((try? u.resourceValues(forKeys: keys).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    /// Apple's own media libraries (TV, Music, Photos): never contain Final Cut libraries, and
    /// opening them makes macOS ask the user for permission.
    static func isPrivateMediaLibrary(_ u: URL) -> Bool {
        ["photoslibrary", "tvlibrary", "musiclibrary"].contains(u.pathExtension.lowercased())
            || (["TV", "Music"].contains(u.lastPathComponent) && u.deletingLastPathComponent().lastPathComponent == "Movies")
            || u.lastPathComponent == "Music" && u.deletingLastPathComponent().path == NSHomeDirectory()
    }

    /// .fcpbundle folders inside roots (a bundle passed directly is accepted).
    public static func findBundles(in roots: [URL], depth: Int = 3) -> [URL] {
        var found = Set<URL>()
        for root in roots {
            if root.pathExtension == "fcpbundle" { found.insert(root); continue }
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                        options: [.skipsHiddenFiles]) else { continue }
            for case let u as URL in e {
                if u.pathExtension == "fcpbundle" {
                    found.insert(u)
                    e.skipDescendants()
                } else if isPrivateMediaLibrary(u) || e.level >= depth {
                    e.skipDescendants()
                }
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    /// Final Cut names its automatic backups like 20261029_1123_GMT+1.fcpbundle, wherever they end up.
    public static func isAutomaticBackup(_ bundle: URL) -> Bool {
        bundle.lastPathComponent.range(of: #"^\d{8}_\d{4}_GMT[+-]\d+\.fcpbundle$"#, options: .regularExpression) != nil
            || bundle.pathComponents.contains { $0 == "Backups" || $0.hasPrefix("Final Cut Backups") }
    }

    public static func scan(_ bundle: URL) -> Library {
        if isAutomaticBackup(bundle) {  // never listed folder by folder: just weighed
            return Library(url: bundle, total: diskSize(bundle), items: [], isBackup: true)
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        var items: [Item] = []
        if let e = fm.enumerator(at: bundle, includingPropertiesForKeys: Array(keys)) {
            for case let u as URL in e {
                let v = try? u.resourceValues(forKeys: keys)
                let name = u.lastPathComponent
                if v?.isDirectory == true, v?.isSymbolicLink != true, let kind = kinds[name] {
                    e.skipDescendants()
                    items.append(Item(
                        name: name,
                        label: u.pathComponents.suffix(e.level).joined(separator: " › "),
                        url: u, size: diskSize(u), kind: kind,
                        blocked: blockReason(name: name, kind: kind, url: u)))
                } else if e.level >= 4 {
                    e.skipDescendants()
                }
            }
        }
        items.sort { $0.size > $1.size }
        return Library(url: bundle, total: diskSize(bundle), items: items, isBackup: false)
    }

    static func blockReason(name: String, kind: Kind, url: URL) -> String? {
        if kind == .protected { return name == "Backups" ? "Backup" : "Originali" }
        if name == "Transcoded Media", !originalsReachable(url.deletingLastPathComponent()) {
            return "Originali non raggiungibili"
        }
        return nil
    }

    /// Optimized/proxy media is only disposable if every original can still be found.
    static func originalsReachable(_ event: URL) -> Bool {
        let orig = event.appendingPathComponent("Original Media")
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: orig.path, isDirectory: &isDir), isDir.boolValue,
              let e = fm.enumerator(at: orig, includingPropertiesForKeys: [.isSymbolicLinkKey])
        else { return false }
        for case let u as URL in e {
            let isLink = (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
            if isLink, !fm.fileExists(atPath: u.path) { return false }  // fileExists follows the link
        }
        return true
    }

    /// Last line of defence: re-checks everything from the path on disk, not from the Item.
    static func isSafeToEmpty(_ item: Item) -> Bool {
        let parts = item.url.pathComponents
        guard let kind = kinds[item.url.lastPathComponent], kind != .protected,
              parts.contains(where: { $0.hasSuffix(".fcpbundle") }),
              !parts.contains("Original Media"), !parts.contains("Backups"),
              (try? item.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        else { return false }
        if item.url.lastPathComponent == "Transcoded Media" {
            return originalsReachable(item.url.deletingLastPathComponent())
        }
        return true
    }

    /// Empties the folders but keeps the folders themselves. Keeps going after a failure.
    public static func clean(_ items: [Item]) -> CleanResult {
        var result = CleanResult()
        for item in items {
            guard isSafeToEmpty(item) else {
                result.failures.append(TF("%@: saltata per sicurezza", item.label))
                continue
            }
            do {
                for child in try fm.contentsOfDirectory(at: item.url, includingPropertiesForKeys: nil) {
                    try fm.removeItem(at: child)
                }
            } catch {
                result.failures.append("\(item.label): \(error.localizedDescription)")
            }
            result.freed += max(0, item.size - diskSize(item.url))
        }
        return result
    }
}
