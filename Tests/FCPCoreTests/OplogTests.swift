import XCTest
@testable import FCPCore

final class OplogTests: XCTestCase {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("oplog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testVerificationComparesEstimateWithDisk() {
        func rec(kind: String, est: Int64, before: Int64?, after: Int64?) -> OperationRecord {
            OperationRecord(id: UUID(), date: Date(), kind: kind, summary: "", paths: [], estimatedBytes: est,
                            freeBefore: before, freeAfter: after, failures: [])
        }
        let good = rec(kind: "clean", est: 1_000_000_000, before: 10_000_000_000, after: 11_000_000_000)
        XCTAssertEqual(good.verifiedDelta, 1_000_000_000)
        XCTAssertTrue(good.verification.hasPrefix("Misurato sul disco"))
        let short = rec(kind: "clean", est: 1_000_000_000, before: 10_000_000_000, after: 10_100_000_000)
        XCTAssertTrue(short.verification.contains("snapshot"))
        XCTAssertTrue(rec(kind: "trash", est: 5, before: 1, after: 1).verification.contains("Cestino"))
        XCTAssertNil(rec(kind: "clean", est: 5, before: nil, after: nil).verifiedDelta)
    }

    func testLogRoundTripNewestFirstAndBadLinesSkipped() throws {
        let log = try tempDir().appendingPathComponent("ops.jsonl")
        let probe = FreeProbe(volume: nil, free: nil)
        Doctor.logOperation(kind: "clean", summary: "prima", paths: [URL(fileURLWithPath: "/a")], estimated: 10,
                            failures: ["x"], before: probe, log: log)
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.close()
        Thread.sleep(forTimeInterval: 1.1)  // dates are stored to the second
        Doctor.logOperation(kind: "trash", summary: "seconda", paths: [], estimated: 20, failures: [], before: probe, log: log)

        let ops = Doctor.operations(at: log)
        XCTAssertEqual(ops.map(\.summary), ["seconda", "prima"])
        XCTAssertEqual(ops[1].failures, ["x"])
        XCTAssertEqual(ops[1].paths, ["/a"])
        XCTAssertEqual(Doctor.operations(at: log.deletingLastPathComponent().appendingPathComponent("none")).count, 0)
    }

    func testRealDiskMeasurementAfterDeletingAFile() throws {
        let dir = try tempDir()
        let big = dir.appendingPathComponent("big.bin")
        try Data(count: 50_000_000).write(to: big)
        let before = Doctor.probe([big])
        XCTAssertNotNil(before.volume)
        XCTAssertNotNil(before.free)
        try FileManager.default.removeItem(at: big)
        let rec = Doctor.logOperation(kind: "clean", summary: "prova", paths: [big], estimated: 50_000_000,
                                      failures: [], before: before, log: dir.appendingPathComponent("ops.jsonl"))
        XCTAssertNotNil(rec.freeAfter)
        // Other processes write too, so allow slack, but half of the 50 MB must show up (a cached reading gave 0).
        XCTAssertGreaterThan(rec.verifiedDelta ?? 0, 25_000_000)
        print("MISURA REALE: stimati 50 MB, il disco mostra \(rec.verifiedDelta ?? 0) byte in più")
    }
}
