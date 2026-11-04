import Foundation

/// A real file inside a "Final Cut Original Media" folder.
public struct MediaFile: Identifiable, Hashable, Sendable {
    public var id: String { key }
    public let key: String  // fully resolved path, used to compare with library links
    public let url: URL
    public let size: Int64
    public let importName: String
    public let importURL: URL
    public var name: String { url.lastPathComponent }
}

/// A symlink in a library's Original Media whose target no longer exists.
public struct BrokenLink: Identifiable, Hashable, Sendable {
    public var id: String { link.path }
    public let library: String
    public let event: String
    public let link: URL
    public let target: URL
    /// Files with the same name that still exist in the media folders.
    public let found: [URL]
    public var name: String { target.lastPathComponent }
    public var eventLabel: String { "\(library) › \(event)" }
    public var foundIn: String { found.first?.deletingLastPathComponent().lastPathComponent ?? "" }
}

/// One import day/folder under "Final Cut Original Media".
public struct ImportFolder: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let fileCount: Int
    public let size: Int64
    public let linkedSize: Int64
    public let orphanSize: Int64
    public let orphanCount: Int
}

public struct MediaReport: Sendable {
    public let mediaFolders: [URL]
    public let imports: [ImportFolder]
    public let orphans: [MediaFile]
    public let broken: [BrokenLink]
    /// Libraries whose links were used to decide what is "in use".
    public let libraryNames: [String]
    public var totalSize: Int64 { imports.reduce(0) { $0 + $1.size } }
    public var linkedSize: Int64 { imports.reduce(0) { $0 + $1.linkedSize } }
    public var orphanSize: Int64 { imports.reduce(0) { $0 + $1.orphanSize } }
    public var recoverableCount: Int { broken.filter { !$0.found.isEmpty }.count }
}

public struct TrashResult: Sendable {
    public var moved = 0
    public var bytes: Int64 = 0
    public var failures: [String] = []
}

extension Doctor {
    static let mediaFolderName = "Final Cut Original Media"

    static func realKey(_ u: URL) -> String { u.resolvingSymlinksInPath().path }

    public static func findMediaFolders(in roots: [URL], depth: Int = 2) -> [URL] {
        var found = Set<URL>()
        for root in roots {
            if root.lastPathComponent == mediaFolderName { found.insert(root); continue }
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                        options: [.skipsHiddenFiles]) else { continue }
            for case let u as URL in e {
                if u.lastPathComponent == mediaFolderName {
                    found.insert(u)
                    e.skipDescendants()
                } else if u.pathExtension == "fcpbundle" || e.level >= depth {
                    e.skipDescendants()
                }
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    static func mediaFiles(in folder: URL) -> [MediaFile] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey]
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: Array(keys),
                                    options: [.skipsHiddenFiles]) else { return [] }
        var out: [MediaFile] = []
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: keys),
                  v.isRegularFile == true, v.isSymbolicLink != true else { continue }
            var importURL = u
            for _ in 0..<max(0, e.level - 1) { importURL = importURL.deletingLastPathComponent() }
            let isRoot = e.level < 2
            out.append(MediaFile(
                key: realKey(u), url: u, size: Int64(v.totalFileAllocatedSize ?? 0),
                importName: isRoot ? "(radice)" : importURL.lastPathComponent,
                importURL: isRoot ? folder : importURL))
        }
        return out
    }

    typealias RawBroken = (library: String, event: String, link: URL, target: URL)

    /// What the libraries point to: existing targets (as resolved paths) and dead links.
    static func references(of libraries: [Library]) -> (linked: Set<String>, broken: [RawBroken]) {
        var linked = Set<String>()
        var broken: [RawBroken] = []
        for lib in libraries where !lib.isBackup {
            for item in lib.items where item.name == "Original Media" {
                let event = item.url.deletingLastPathComponent().lastPathComponent
                guard let e = fm.enumerator(at: item.url, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { continue }
                for case let u as URL in e {
                    guard (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true,
                          let dest = try? fm.destinationOfSymbolicLink(atPath: u.path) else { continue }
                    let target = URL(fileURLWithPath: dest, relativeTo: u.deletingLastPathComponent()).standardizedFileURL
                    if fm.fileExists(atPath: target.path) {  // follows the link
                        linked.insert(realKey(target))
                    } else {
                        broken.append((lib.name, event, u, target))
                    }
                }
            }
        }
        return (linked, broken)
    }

    public static func mediaReport(roots: [URL], libraries: [Library]) -> MediaReport {
        let folders = findMediaFolders(in: roots)
        let real = libraries.filter { !$0.isBackup }
        let refs = references(of: real)
        let files = folders.flatMap(mediaFiles(in:))

        var perImport: [URL: (name: String, count: Int, size: Int64, linked: Int64, orphanSize: Int64, orphanCount: Int)] = [:]
        var orphans: [MediaFile] = []
        var byName: [String: [URL]] = [:]
        for f in files {
            byName[f.name.lowercased(), default: []].append(f.url)
            var a = perImport[f.importURL] ?? (f.importName, 0, 0, 0, 0, 0)
            a.count += 1
            a.size += f.size
            if refs.linked.contains(f.key) {
                a.linked += f.size
            } else {
                a.orphanSize += f.size
                a.orphanCount += 1
                orphans.append(f)
            }
            perImport[f.importURL] = a
        }
        let imports = perImport.map { url, a in
            ImportFolder(url: url, name: a.name, fileCount: a.count, size: a.size,
                         linkedSize: a.linked, orphanSize: a.orphanSize, orphanCount: a.orphanCount)
        }.sorted { $0.size > $1.size }

        let broken = refs.broken.map { b in
            BrokenLink(library: b.library, event: b.event, link: b.link, target: b.target,
                       found: Array((byName[b.target.lastPathComponent.lowercased()] ?? []).prefix(3)))
        }.sorted { ($0.eventLabel, $0.name) < ($1.eventLabel, $1.name) }

        return MediaReport(mediaFolders: folders, imports: imports,
                           orphans: orphans.sorted { $0.size > $1.size },
                           broken: broken, libraryNames: real.map(\.name).sorted())
    }

    /// Moves files to the Trash (recoverable). Re-checks everything from disk, never trusts the list.
    public static func trashOrphans(_ files: [MediaFile], mediaFolders: [URL], libraries: [Library]) -> TrashResult {
        var result = TrashResult()
        let real = libraries.filter { !$0.isBackup }
        guard !real.isEmpty else {
            result.failures.append("Nessuna libreria considerata: non posso sapere cosa è in uso.")
            return result
        }
        let linked = references(of: real).linked
        let prefixes = mediaFolders.map { $0.path + "/" }
        for f in files {
            guard prefixes.contains(where: { f.url.path.hasPrefix($0) }),
                  let v = try? f.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  v.isRegularFile == true, v.isSymbolicLink != true,
                  !linked.contains(realKey(f.url))
            else {
                result.failures.append("\(f.name): saltato per sicurezza")
                continue
            }
            do {
                try fm.trashItem(at: f.url, resultingItemURL: nil)
                result.moved += 1
                result.bytes += f.size
            } catch {
                result.failures.append("\(f.name): \(error.localizedDescription)")
            }
        }
        return result
    }
}
