import Foundation

/// A library, event, project, or one of an event's media files, with its real weight.
public struct Node: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case library, event, project, group, clip }

    public var id: URL { url }
    public let url: URL
    public let name: String
    public let kind: Kind
    /// Total weight: what lives in the folder plus the media it links outside.
    public let size: Int64
    /// Part of `size` that sits outside the library (linked media).
    public let external: Int64
    /// Media files of the event (links and real files in Original Media).
    public let media: Int
    /// Links whose target no longer exists.
    public let missing: Int
    public let modified: Date
    public var children: [Node]?
    /// The real file to preview with Quick Look (clips only).
    public let preview: URL?
}

extension Doctor {
    static let eventMarker = "CurrentVersion.fcpevent"

    static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    static func allocated(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
    }

    /// Libraries (backups excluded) → events → projects and media, heaviest first.
    public static func tree(of libraries: [Library]) -> [Node] {
        libraries.filter { !$0.isBackup }.map { lib in
            let events = eventNodes(in: lib.url)
            let external = events.reduce(0) { $0 + $1.external }
            return Node(url: lib.url, name: lib.name, kind: .library, size: lib.total + external,
                        external: external, media: events.reduce(0) { $0 + $1.media },
                        missing: events.reduce(0) { $0 + $1.missing }, modified: modified(lib.url),
                        children: events, preview: nil)
        }.sorted { $0.size > $1.size }
    }

    static func eventNodes(in bundle: URL) -> [Node] {
        let kids = (try? fm.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil,
                                                options: [.skipsHiddenFiles])) ?? []
        return kids.filter { isDirectory($0) && fm.fileExists(atPath: $0.appendingPathComponent(eventMarker).path) }
            .map(eventNode)
            .sorted { $0.size > $1.size }
    }

    /// Moves anything the user picked to the Trash (recoverable). The only limits: it must sit inside
    /// one of the folders the user added (never the folder itself), and it must still exist.
    public static func trash(_ urls: [URL], within roots: [URL]) -> TrashResult {
        var result = TrashResult()
        let prefixes = roots.map { $0.standardizedFileURL.path + "/" }
        for url in urls {
            let path = url.standardizedFileURL.path
            guard prefixes.contains(where: { path.hasPrefix($0) }), fm.fileExists(atPath: path) else {
                result.failures.append("\(url.lastPathComponent): fuori dalle cartelle aggiunte, saltato")
                continue
            }
            let size = diskSize(url) + ((try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true ? allocated(url) : 0)
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
                result.moved += 1
                result.bytes += size
            } catch {
                result.failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return result
    }

    static func eventNode(_ ev: URL) -> Node {
        var clips: [Node] = []
        var missing = 0
        var external: Int64 = 0
        var seen = Set<String>()
        let originals = ev.appendingPathComponent("Original Media")
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey]
        if let e = fm.enumerator(at: originals, includingPropertiesForKeys: Array(keys)) {
            for case let u as URL in e {
                let v = try? u.resourceValues(forKeys: keys)
                if v?.isSymbolicLink == true {
                    guard let dest = try? fm.destinationOfSymbolicLink(atPath: u.path) else { continue }
                    let target = URL(fileURLWithPath: dest, relativeTo: u.deletingLastPathComponent()).standardizedFileURL
                    let exists = fm.fileExists(atPath: target.path)
                    let size = exists ? allocated(target) : 0
                    if exists, seen.insert(realKey(target)).inserted { external += size }  // linked twice weighs once
                    if !exists { missing += 1 }
                    clips.append(Node(url: u, name: u.lastPathComponent, kind: .clip, size: size, external: 0,
                                      media: 0, missing: exists ? 0 : 1,
                                      modified: exists ? modified(target) : .distantPast,
                                      children: nil, preview: exists ? target : nil))
                } else if v?.isRegularFile == true {
                    clips.append(Node(url: u, name: u.lastPathComponent, kind: .clip, size: allocated(u), external: 0,
                                      media: 0, missing: 0, modified: modified(u), children: nil, preview: u))
                }
            }
        }
        var children = ((try? fm.contentsOfDirectory(at: ev, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles])) ?? [])
            .filter { isDirectory($0) && kinds[$0.lastPathComponent] == nil }
            .map { p in
                Node(url: p, name: p.lastPathComponent, kind: .project, size: diskSize(p), external: 0,
                     media: 0, missing: 0, modified: modified(p), children: nil, preview: nil)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !clips.isEmpty {
            clips.sort { $0.size > $1.size }
            children.append(Node(url: originals, name: "Media (\(clips.count))", kind: .group,
                                 size: clips.reduce(0) { $0 + $1.size }, external: 0, media: 0, missing: missing,
                                 modified: modified(originals), children: clips, preview: nil))
        }
        return Node(url: ev, name: ev.lastPathComponent, kind: .event, size: diskSize(ev) + external,
                    external: external, media: clips.count, missing: missing, modified: modified(ev),
                    children: children, preview: nil)
    }
}
