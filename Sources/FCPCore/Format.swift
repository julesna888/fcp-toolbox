import Foundation

/// The formats Final Cut Pro works well on: libraries need APFS or Mac OS Extended.
public enum DiskFormat: String, CaseIterable, Identifiable, Sendable {
    case apfs, hfs
    public var id: String { rawValue }
    var diskutilType: String { self == .apfs ? "APFS" : "JHFS+" }
    public var title: String { self == .apfs ? "APFS" : "Mac OS Esteso (con registro)" }
    public var advice: String {
        self == .apfs
            ? "Il formato giusto per gli SSD: veloce, copie istantanee, Final Cut lo usa di default. Non leggibile da Windows."
            : "Il formato giusto per i dischi meccanici (HDD): APFS su un disco a piatti è lento. Non leggibile da Windows."
    }
}

/// An external physical disk that can be erased.
public struct EraseTarget: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let size: Int64
    public let solidState: Bool
    public let volumes: [String]
    /// Data already on the disk.
    public let used: Int64
    public var recommended: DiskFormat { solidState ? .apfs : .hfs }
}

public enum FormatError: LocalizedError {
    case notAllowed(String)
    case failed(String)
    public var errorDescription: String? {
        switch self {
        case .notAllowed(let m): return m
        case .failed(let m): return "diskutil ha risposto: \(m)"
        }
    }
}

extension Doctor {
    static func run(_ exe: String, _ args: [String]) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return (-1, "impossibile avviare \(exe)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func diskutilPlist(_ args: [String]) -> [String: Any]? {
        let r = run("/usr/sbin/diskutil", args)
        guard r.status == 0, let data = r.out.data(using: .utf8) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// "disk4s2" → "disk4".
    static func wholeDisk(_ id: String) -> String {
        guard let r = id.range(of: #"^disk[0-9]+"#, options: .regularExpression) else { return id }
        return String(id[r])
    }

    /// External, physical, non-boot disks. Nothing else is ever offered for erasing.
    public static func eraseCandidates() -> [EraseTarget] {
        guard let list = diskutilPlist(["list", "-plist", "external", "physical"]),
              let wholes = list["WholeDisks"] as? [String] else { return [] }
        var onDisk: [String: [(name: String, used: Int64)]] = [:]
        var boot = Set<String>()
        for u in fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [] {
            guard let info = diskutilPlist(["info", "-plist", u.path]) else { continue }
            let stores = (info["APFSPhysicalStores"] as? [[String: Any]])?
                .compactMap { $0["APFSPhysicalStore"] as? String } ?? []
            let ids = stores.isEmpty ? [info["ParentWholeDisk"] as? String].compactMap { $0 } : stores.map(wholeDisk)
            let v = try? u.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            let used = Int64(max(0, (v?.volumeTotalCapacity ?? 0) - (v?.volumeAvailableCapacity ?? 0)))
            for id in ids {
                onDisk[id, default: []].append((u.lastPathComponent, used))
                if u.path == "/" { boot.insert(id) }
            }
        }
        return wholes.compactMap { id in
            guard !boot.contains(id), let info = diskutilPlist(["info", "-plist", id]),
                  info["Internal"] as? Bool != true,
                  (info["VirtualOrPhysical"] as? String) != "Virtual",
                  let size = info["TotalSize"] as? Int ?? info["Size"] as? Int else { return nil }
            let vols = onDisk[id] ?? []
            return EraseTarget(id: id, name: (info["MediaName"] as? String) ?? id, size: Int64(size),
                               solidState: info["SolidState"] as? Bool ?? false,
                               volumes: vols.map(\.name), used: vols.reduce(0) { $0 + $1.used })
        }
    }

    /// Letters, digits, space, dash and underscore; at most 27 characters (the HFS+ limit minus a margin).
    public static func sanitizedVolumeName(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let kept = String(String.UnicodeScalarView(s.unicodeScalars.filter { allowed.contains($0) }))
        return String(kept.trimmingCharacters(in: .whitespaces).prefix(27))
    }

    /// Erases the whole disk and creates one volume (GPT map). Re-checks that the disk is still
    /// the same external physical disk the user was shown.
    public static func erase(_ target: EraseTarget, as format: DiskFormat, name: String) throws -> String {
        guard target.id.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil else {
            throw FormatError.notAllowed("Identificativo del disco non valido.")
        }
        let clean = sanitizedVolumeName(name)
        guard !clean.isEmpty else { throw FormatError.notAllowed("Scrivi un nome per il disco.") }
        guard eraseCandidates().contains(where: { $0.id == target.id && $0.size == target.size }) else {
            throw FormatError.notAllowed("Il disco non è più collegato oppure è cambiato. Ricontrolla e riprova.")
        }
        return try eraseUnchecked(id: target.id, format: format, name: clean)
    }

    static func eraseUnchecked(id: String, format: DiskFormat, name: String) throws -> String {
        let r = run("/usr/sbin/diskutil", ["eraseDisk", format.diskutilType, name, "GPT", "/dev/" + id])
        guard r.status == 0 else { throw FormatError.failed(r.out) }
        return r.out
    }
}
