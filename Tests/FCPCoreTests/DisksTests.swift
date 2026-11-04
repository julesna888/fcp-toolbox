import XCTest
@testable import FCPCore

final class DisksTests: XCTestCase {
    func testVolumesReportSaneNumbers() {
        let vols = Doctor.volumes()
        XCTAssertFalse(vols.isEmpty)
        for v in vols {
            XCTAssertGreaterThan(v.total, 0)
            XCTAssertLessThanOrEqual(v.free, v.total)
        }
    }

    func testLargestFilesAreSortedLimitedAndSkipSmallOnes() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("big-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        for (name, kb) in [("a", 300), ("b", 100), ("c", 200), ("tiny", 1)] {
            try Data(count: kb * 1024).write(to: dir.appendingPathComponent(name))
        }
        let found = Doctor.largestFiles(in: [dir], limit: 2, minSize: 50 * 1024)
        XCTAssertEqual(found.map(\.url.lastPathComponent), ["a", "c"])
    }
}
