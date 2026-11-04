import Foundation

/// A mounted disk with its real free space.
public struct Volume: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let total: Int64
    public let free: Int64
    public let format: String
    public let internalDisk: Bool
    /// "Verified", "Failing"… nil when the disk does not report it (many USB enclosures).
    public let smart: String?

    public var used: Int64 { total - free }
    public var freeRatio: Double { total > 0 ? Double(free) / Double(total) : 0 }
}

public struct BigFile: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let size: Int64
    public let modified: Date
}

extension Doctor {
    /// Disks the user can see in the Finder (system helper volumes are left out).
    public static func volumes() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeLocalizedFormatDescriptionKey, .volumeIsInternalKey,
                                      .volumeIsReadOnlyKey]
        let urls = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { u in
            guard !u.path.hasPrefix("/System/Volumes"), !u.path.hasPrefix("/private"),
                  let v = try? u.resourceValues(forKeys: Set(keys)),
                  v.volumeIsReadOnly != true,  // mounted installers and disk images are never working disks
                  let total = v.volumeTotalCapacity, total > 0 else { return nil }
            let free = min(Int64(total), v.volumeAvailableCapacityForImportantUsage ?? 0)
            return Volume(url: u, name: v.volumeName ?? u.lastPathComponent, total: Int64(total), free: free,
                          format: v.volumeLocalizedFormatDescription ?? "—",
                          internalDisk: v.volumeIsInternal ?? false, smart: smart(of: u))
        }
        .sorted { ($0.internalDisk ? 0 : 1, $0.name) < ($1.internalDisk ? 0 : 1, $1.name) }
    }

    /// SMART status from `diskutil`; nil when the disk does not support it.
    static func smart(of volume: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = ["info", "-plist", volume.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let s = plist["SMARTStatus"] as? String, s != "Not Supported" else { return nil }
        return s
    }

    /// The heaviest regular files under `roots`. Symlinks are never followed.
    public static func largestFiles(in roots: [URL], limit: Int = 100, minSize: Int64 = 50_000_000) -> [BigFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
        var found: [BigFile] = []
        for root in roots {
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys) else { continue }
            for case let u as URL in e {
                guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                      let size = v.totalFileAllocatedSize, Int64(size) >= minSize else { continue }
                found.append(BigFile(url: u, size: Int64(size), modified: v.contentModificationDate ?? .distantPast))
                if found.count > limit * 4 {
                    found = Array(found.sorted { $0.size > $1.size }.prefix(limit))
                }
            }
        }
        return Array(found.sorted { $0.size > $1.size }.prefix(limit))
    }
}
