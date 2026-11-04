import XCTest
@testable import FCPCore

final class ClipSearchTests: XCTestCase {
    func testEmbeddedScriptIsTheSameAsTheFileInScripts() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/clipsearch.py")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(Doctor.clipScript + "\n", text, "Rilancia scripts/gen_clip_script.sh")
    }

    func testNameBoostAndParsing() {
        XCTAssertEqual(Doctor.nameBoost(query: "persona spiaggia tramonto", fileName: "Spiaggia_Tramonto_01.mov"), 0.04, accuracy: 1e-9)
        XCTAssertEqual(Doctor.nameBoost(query: "di un il", fileName: "di un il.mov"), 0, "parole corte ignorate")
        let line = #"{"results": [{"path": "/a/uno.mov", "score": 0.25, "time": 3.5}, {"path": "/a/spiaggia.mov", "score": 0.24, "time": 1.0}], "searched": 2}"#
        let hits = Doctor.parseClipHits("rumore\n" + line, query: "spiaggia")
        XCTAssertEqual(hits.map(\.url.lastPathComponent), ["spiaggia.mov", "uno.mov"], "il nome del file fa salire la clip")
        XCTAssertEqual(hits[1].time, 3.5)
        XCTAssertTrue(Doctor.parseClipHits("niente", query: "x").isEmpty)
    }

    func testSearchWithoutInstallOrIndexSaysWhy() {
        let r = Doctor.clipSearch("mare", indexURL: URL(fileURLWithPath: "/nonexistent/index.json"))
        XCTAssertTrue(r.hits.isEmpty)
        XCTAssertNotNil(r.problem)
    }

    func testRealSearchFindsTheRightClip() throws {
        try XCTSkipUnless(Doctor.clipInstalled, "ricerca per contenuto non installata")
        let ffmpeg = try XCTUnwrap(Doctor.ffmpegPath)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func make(_ name: String, _ source: String) throws {
            let r = Doctor.run(ffmpeg, ["-loglevel", "error", "-f", "lavfi", "-i", source, "-t", "2", "-pix_fmt", "yuv420p", dir.appendingPathComponent(name).path])
            try XCTSkipIf(r.status != 0, r.out)
        }
        // blue over yellow looks like sea and sand; the other is a plain black screen
        try make("a.mp4", "color=c=0x1e6fd9:s=320x120:r=25[t];color=c=0xe8d28a:s=320x120:r=25[b];[t][b]vstack")
        try make("b.mp4", "color=c=black:s=320x240:r=25")
        let index = dir.appendingPathComponent("index.json")
        let r = Doctor.clipIndex(folder: dir, indexURL: index) { _, _ in }
        XCTAssertNil(r.problem)
        XCTAssertEqual(r.clips, 2)
        let found = Doctor.clipSearch("una spiaggia con il mare", indexURL: index)
        XCTAssertNil(found.problem)
        XCTAssertEqual(found.hits.count, 2)
        XCTAssertEqual(found.hits.first?.url.lastPathComponent, "a.mp4", "\(found.hits)")
        XCTAssertEqual(Doctor.clipIndex(folder: dir, indexURL: index) { _, _ in }.clips, 2)
    }
}
