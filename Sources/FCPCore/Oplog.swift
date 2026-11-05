import Foundation

/// Free space of one volume at one moment.
public struct FreeProbe: Sendable {
    public let volume: URL?
    public let free: Int64?
}

/// One cleanup or trash operation, as kept in the operations log.
public struct OperationRecord: Codable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var kind: String
    public var summary: String
    public var paths: [String]
    public var estimatedBytes: Int64
    public var freeBefore: Int64?
    public var freeAfter: Int64?
    public var failures: [String]

    /// How much more free space the disk really shows. Nil when it could not be measured.
    public var verifiedDelta: Int64? {
        guard let a = freeAfter, let b = freeBefore else { return nil }
        return a - b
    }

    /// One honest sentence comparing the estimate with what the disk reports.
    public var verification: String {
        guard let d = verifiedDelta else { return "Lo spazio sul disco non è stato misurato." }
        if kind != "clean" {
            return TF("Spostato nel Cestino: lo spazio si libera quando lo svuoti (ora il disco mostra %@).", signed(d))
        }
        if estimatedBytes > 0, d < estimatedBytes / 2 {
            return TF("Il disco mostra %@ invece dei %@ stimati: altre scritture in corso o snapshot locali (Time Machine) possono trattenere lo spazio.", signed(d), formatBytes(estimatedBytes))
        }
        return TF("Misurato sul disco: %@ liberi in più.", signed(d))
    }

    private func signed(_ n: Int64) -> String { (n < 0 ? "-" : "+") + formatBytes(abs(n)) }
}

extension Doctor {
    public static var operationsLogURL: URL {
        // `swift test` must not fill the user's real audit log with test entries
        if NSClassFromString("XCTestCase") != nil {
            return URL(fileURLWithPath: NSTemporaryDirectory() + "fcp-test-operations.jsonl")
        }
        return URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/FCP Toolbox/operations.jsonl")
    }

    static func freeSpace(of volume: URL) -> Int64? {
        // volumeAvailableCapacityKey is what is really free now; the "important usage" key counts purgeable space.
        // A URL caches what it read before; without a fresh one the second reading repeats the first.
        let fresh = URL(fileURLWithPath: volume.path)
        return (try? fresh.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity).map(Int64.init)
    }

    /// Free space on the volume that holds all the given paths. Nil volume if they sit on different disks.
    public static func probe(_ urls: [URL]) -> FreeProbe {
        let vols = Set(urls.compactMap { try? $0.resourceValues(forKeys: [.volumeURLKey]).volume?.path })
        guard vols.count == 1, let path = vols.first else { return FreeProbe(volume: nil, free: nil) }
        let v = URL(fileURLWithPath: path)
        return FreeProbe(volume: v, free: freeSpace(of: v))
    }

    /// Measures the free space again, builds the record and appends it to the log. Never throws:
    /// a log that cannot be written must not hide the result of the operation.
    @discardableResult
    public static func logOperation(kind: String, summary: String, paths: [URL], estimated: Int64,
                                    failures: [String], before: FreeProbe,
                                    log: URL = operationsLogURL) -> OperationRecord {
        let after = before.volume.flatMap { freeSpace(of: $0) }
        let record = OperationRecord(id: UUID(), date: Date(), kind: kind, summary: summary,
                                     paths: paths.map(\.path), estimatedBytes: estimated,
                                     freeBefore: before.free, freeAfter: after, failures: failures)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(record) {
            try? fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let h = try? FileHandle(forWritingTo: log) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data + Data("\n".utf8))
            } else {
                try? (data + Data("\n".utf8)).write(to: log)
            }
        }
        return record
    }

    /// Past operations, newest first.
    public static func operations(at log: URL = operationsLogURL) -> [OperationRecord] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? dec.decode(OperationRecord.self, from: Data($0.utf8)) }
            .sorted { $0.date > $1.date }
    }
}
