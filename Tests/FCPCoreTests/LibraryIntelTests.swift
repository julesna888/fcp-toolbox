import XCTest
@testable import FCPCore

final class LibraryIntelTests: XCTestCase {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("li-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func lib(_ name: String, total: Int64, render: Int64) -> Library {
        let url = URL(fileURLWithPath: "/tmp/\(name).fcpbundle")
        let item = Item(name: "Render Files", label: "Render", url: url.appendingPathComponent("Render Files"),
                        size: render, kind: .clean, blocked: nil)
        return Library(url: url, total: total, items: [item], isBackup: false)
    }

    func testSnapshotsTrackGrowthAndSkipNoise() throws {
        let log = try tempDir().appendingPathComponent("s.jsonl")
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        Doctor.recordSnapshots([lib("A", total: 10_000_000_000, render: 1_000_000_000)], at: log, now: t0)
        // changed an hour later: too soon
        Doctor.recordSnapshots([lib("A", total: 11_000_000_000, render: 2_000_000_000)], at: log, now: t0.addingTimeInterval(3600))
        // same size a day later: nothing new
        Doctor.recordSnapshots([lib("A", total: 10_000_000_000, render: 1_000_000_000)], at: log, now: t0.addingTimeInterval(86_400))
        XCTAssertEqual(Doctor.snapshots(for: "/tmp/A.fcpbundle", at: log).count, 1)
        // changed 3 days later: recorded
        Doctor.recordSnapshots([lib("A", total: 14_000_000_000, render: 4_000_000_000)], at: log, now: t0.addingTimeInterval(3 * 86_400))
        let g = try XCTUnwrap(Doctor.growth(of: "/tmp/A.fcpbundle", at: log))
        XCTAssertEqual(g.delta, 4_000_000_000)
        XCTAssertEqual(g.partChanges.first?.label, "Render")
        XCTAssertTrue(g.text.contains("3 giorni"))
        XCTAssertNil(Doctor.growth(of: "/tmp/none.fcpbundle", at: log))
    }

    func testFCPXMLAnomaliesAreFound() throws {
        let dir = try tempDir()
        let real = dir.appendingPathComponent("a.mov")
        try Data(count: 10).write(to: real)
        let gone = dir.appendingPathComponent("gone.mov")
        func clip(_ u: URL, fps: Double) -> ClipInfo {
            ClipInfo(url: u, size: 10, seconds: 4, width: 1920, height: 1080, fps: fps, codec: "h264",
                     hasVideo: true, hasAudio: false, notes: [])
        }
        var xml = Doctor.fcpxml(event: "T", clips: [clip(real, fps: 25), clip(gone, fps: 30)])
        let file = dir.appendingPathComponent("t.fcpxml")
        try xml.write(to: file, atomically: true, encoding: .utf8)
        var r = try Doctor.analyzeFCPXML(file)
        XCTAssertEqual(r.assets, 2)
        XCTAssertEqual(r.clips, 2)
        XCTAssertEqual(r.missingFiles, [gone.path])
        XCTAssertEqual(r.frameRates, ["25 fps", "30 fps"])
        XCTAssertTrue(r.anomalies.contains { $0.contains("Più frame rate") })
        XCTAssertTrue(r.duplicateIDs.isEmpty)
        XCTAssertTrue(r.danglingRefs.isEmpty)
        XCTAssertFalse(r.isClean)

        xml = xml.replacingOccurrences(of: "ref=\"r4\"", with: "ref=\"r99\"")
                 .replacingOccurrences(of: "<asset id=\"r4\"", with: "<asset id=\"r3\"")
        try xml.write(to: file, atomically: true, encoding: .utf8)
        r = try Doctor.analyzeFCPXML(file)
        XCTAssertEqual(r.duplicateIDs, ["r3"])
        XCTAssertEqual(r.danglingRefs, ["asset-clip → r99"])

        let bad = dir.appendingPathComponent("x.fcpxml")
        try "<html/>".write(to: bad, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Doctor.analyzeFCPXML(bad))
    }

    func testCleanFCPXMLHasNoFindings() throws {
        let dir = try tempDir()
        let real = dir.appendingPathComponent("a.mov")
        try Data(count: 10).write(to: real)
        let c = ClipInfo(url: real, size: 10, seconds: 4, width: 1920, height: 1080, fps: 25, codec: "h264",
                         hasVideo: true, hasAudio: true, notes: [])
        let file = dir.appendingPathComponent("t.fcpxml")
        try Doctor.fcpxml(event: "T", clips: [c]).write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(try Doctor.analyzeFCPXML(file).isClean)
    }
}
