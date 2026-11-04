import XCTest
@testable import FCPCore

final class VideoToolsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// 6 s clip: red 0–2 s, blue 2–4 s, green 4–6 s.
    private func threeShots() throws -> URL {
        let ffmpeg = try XCTUnwrap(Doctor.ffmpegPath, "ffmpeg non installato")
        let out = dir.appendingPathComponent("three.mp4")
        var a = ["-loglevel", "error"]
        for c in ["red", "blue", "green"] { a += ["-f", "lavfi", "-i", "color=c=\(c):s=320x240:d=2:r=25"] }
        a += ["-filter_complex", "concat=n=3:v=1:a=0", "-pix_fmt", "yuv420p", "-g", "10", out.path]
        let r = Doctor.run(ffmpeg, a)
        try XCTSkipIf(r.status != 0, r.out)
        return out
    }

    func testTimecode() {
        XCTAssertEqual(Doctor.timecode(65.5, fps: 25), "00:01:05:12")
        XCTAssertEqual(Doctor.timecode(0, fps: 30), "00:00:00:00")
        XCTAssertEqual(Doctor.timecode(3600, fps: 24), "01:00:00:00")
    }

    func testShotDetectorFindsTheTwoCuts() throws {
        try XCTSkipIf(Doctor.ffmpegPath == nil, "ffmpeg non installato")
        let shots = Doctor.detectShots(try threeShots())
        XCTAssertEqual(shots.count, 3, "\(shots)")
        XCTAssertEqual(shots[1], 2, accuracy: 0.1)
        XCTAssertEqual(shots[2], 4, accuracy: 0.1)
    }

    func testFrameImageIsAJPEG() throws {
        try XCTSkipIf(Doctor.ffmpegPath == nil, "ffmpeg non installato")
        let data = try XCTUnwrap(Doctor.frameImage(of: try threeShots(), at: 3, width: 160))
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])
    }

    func testTrimFastAndPreciseNeverTouchTheOriginal() throws {
        try XCTSkipIf(Doctor.ffmpegPath == nil, "ffmpeg non installato")
        let src = try threeShots()
        let size = try FileManager.default.attributesOfItem(atPath: src.path)[.size] as? Int
        let fast = Doctor.trim(src, start: 2, end: 4, precise: false)
        let a = try XCTUnwrap(fast.output, fast.problem ?? "")
        XCTAssertEqual(try Doctor.probeMedia(a).duration, 2, accuracy: 0.6)
        let exact = Doctor.trim(src, start: 1, end: 3, precise: true)
        let b = try XCTUnwrap(exact.output, exact.problem ?? "")
        XCTAssertEqual(try Doctor.probeMedia(b).duration, 2, accuracy: 0.15)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: src.path)[.size] as? Int, size)
        XCTAssertNotNil(Doctor.trim(src, start: 3, end: 2, precise: false).problem)
        XCTAssertNotNil(Doctor.trim(src, start: 99, end: 100, precise: false).problem)
        let again = try XCTUnwrap(Doctor.trim(src, start: 2, end: 4, precise: false).output)
        XCTAssertNotEqual(again, a)
    }
}
