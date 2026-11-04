import XCTest
@testable import FCPCore

final class PoolTests: XCTestCase {
    let fm = FileManager.default
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("pool-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    @discardableResult
    private func write(_ rel: String, _ text: String = "x") throws -> URL {
        let u = tmp.appendingPathComponent(rel)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
        return u
    }

    func testClientAndVideoAreGuessedFromTheFolderName() {
        XCTAssertEqual(Doctor.guessClientAndVideo(from: "Rossi - Spot estate").client, "Rossi")
        XCTAssertEqual(Doctor.guessClientAndVideo(from: "Rossi - Spot estate").video, "Spot estate")
        XCTAssertEqual(Doctor.guessClientAndVideo(from: "Bianchi_Intervista (1)").video, "Intervista")
        XCTAssertEqual(Doctor.guessClientAndVideo(from: "drive-download-20260101T120000Z-001").client, "")
        XCTAssertEqual(Doctor.guessClientAndVideo(from: "Solo titolo").video, "Solo titolo")
    }

    func testFolderNamesAreSafe() {
        XCTAssertEqual(Doctor.safeFolderName("../Rossi/Spot:1"), "RossiSpot1")
        XCTAssertEqual(Doctor.safeFolderName("  Spot  "), "Spot")
    }

    func testPlanSortsNaturallyAndKeepsOtherFilesApart() throws {
        let src = tmp.appendingPathComponent("download")
        try write("download/clip10.mov")
        try write("download/clip2.mov")
        try write("download/sub/clip1.mp4")
        try write("download/brief.pdf")
        try write("download/.DS_Store")
        try write("download/video.mov.crdownload")
        let plan = Doctor.poolPlan(source: src, client: "Rossi", video: "Spot", poolRoot: tmp.appendingPathComponent("Pool"))
        XCTAssertEqual(plan.media.map(\.lastPathComponent), ["clip1.mp4", "clip2.mov", "clip10.mov"])
        XCTAssertEqual(plan.rest.map(\.lastPathComponent), ["brief.pdf"])
        XCTAssertTrue(plan.originals.path.hasSuffix("Pool/ROSSI/Spot/Originali"))
    }

    func testImportMovesDetectsDuplicatesAndRenamesClashes() throws {
        let src = tmp.appendingPathComponent("download")
        try write("download/a.mov", "uguale")
        try write("download/b.mov", "diverso 1")
        let pool = tmp.appendingPathComponent("Pool")
        try write("Pool/ROSSI/Spot/Originali/a.mov", "uguale")       // same size: duplicate
        try write("Pool/ROSSI/Spot/Originali/b.mov", "altro di più")  // different size: rename
        let plan = Doctor.poolPlan(source: src, client: "Rossi", video: "Spot", poolRoot: pool)
        let r = Doctor.poolImport(plan, move: true)
        XCTAssertTrue(r.failures.isEmpty, "\(r.failures)")
        XCTAssertEqual(r.duplicates, 1)
        XCTAssertEqual(r.renamed, 1)
        XCTAssertTrue(fm.fileExists(atPath: plan.originals.appendingPathComponent("b 2.mov").path))
        XCTAssertTrue(fm.fileExists(atPath: src.appendingPathComponent("a.mov").path), "the duplicate stays where it was")
    }

    func testClientFolderIsAlwaysCapitals() {
        XCTAssertEqual(Doctor.clientFolderName("rossi s.r.l."), "ROSSI S.R.L.")
        XCTAssertEqual(Doctor.clientFolderName("  Città/Verde "), "CITTÀVERDE")
        let plan = Doctor.poolPlan(source: tmp, client: "bianchi", video: "Spot", poolRoot: tmp.appendingPathComponent("Pool"))
        XCTAssertEqual(plan.client, "BIANCHI")
        XCTAssertTrue(plan.folder.path.hasSuffix("Pool/BIANCHI/Spot"))
    }

    func testDuplicatesNeedSameBytesNotJustSameSize() throws {
        let a = try write("a.mov", "12345"), b = try write("b.mov", "12345"), c = try write("c.mov", "54321")
        let groups = Doctor.duplicates(in: [a, b, c])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].map(\.lastPathComponent)), ["a.mov", "b.mov"])
    }

    func testFCPXMLIsWellFormedAndFrameAligned() throws {
        func clip(_ name: String, secs: Double, fps: Double) -> ClipInfo {
            ClipInfo(url: URL(fileURLWithPath: "/Volumes/Disco esterno/Pool/\(name).mov"), size: 1, seconds: secs,
                     width: 1920, height: 1080, fps: fps, codec: "avc1", hasVideo: true, hasAudio: true, notes: [])
        }
        let xml = Doctor.fcpxml(event: "Rossi - Spot & Co", clips: [clip("a", secs: 2, fps: 25), clip("b", secs: 10, fps: 29.97)])
        let doc = try XMLDocument(xmlString: xml, options: [])
        XCTAssertEqual(try doc.nodes(forXPath: "//asset").count, 2)
        XCTAssertEqual(try doc.nodes(forXPath: "//format").count, 2)
        XCTAssertEqual((try doc.nodes(forXPath: "//event/@name").first)?.stringValue, "Rossi - Spot & Co")
        XCTAssertEqual((try doc.nodes(forXPath: "//asset-clip[1]/@duration").first)?.stringValue, "5000/2500s")
        XCTAssertEqual((try doc.nodes(forXPath: "//asset-clip[2]/@duration").first)?.stringValue, "300300/30000s")
        XCTAssertTrue(xml.contains("Disco%20esterno"), "paths are URL-encoded")
        XCTAssertEqual(try doc.nodes(forXPath: "//asset/media-rep/@src").count, 2)

        // The real check: Final Cut's own DTD, when Final Cut is installed. (An older format was refused by Final Cut 10.7.)
        let dtd = "/Applications/Final Cut Pro.app/Contents/Frameworks/Interchange.framework/Versions/A/Resources/FCPXMLv1_10.dtd"
        if fm.fileExists(atPath: dtd) {
            let file = tmp.appendingPathComponent("pool.fcpxml")
            try xml.write(to: file, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xmllint")
            let local = tmp.appendingPathComponent("fcpxml.dtd")  // xmllint cannot load a DTD from a path with spaces
            try fm.copyItem(atPath: dtd, toPath: local.path)
            p.arguments = ["--noout", "--dtdvalid", local.path, file.path]
            let err = Pipe()
            p.standardError = err
            try p.run()
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "Final Cut DTD: \(text)")
        }
    }

    func testInspectReadsARealClip() async throws {
        let ffmpeg = "/usr/local/bin/ffmpeg"
        try XCTSkipUnless(fm.isExecutableFile(atPath: ffmpeg), "ffmpeg non installato")
        let clip = tmp.appendingPathComponent("t.mov")
        let r = Doctor.run(ffmpeg, ["-loglevel", "error", "-f", "lavfi", "-i", "testsrc=duration=2:size=640x360:rate=25",
                                    "-pix_fmt", "yuv420p", clip.path])
        try XCTSkipIf(r.status != 0, r.out)
        let info = await Doctor.inspect(clip)
        XCTAssertEqual(info.width, 640)
        XCTAssertEqual(info.height, 360)
        XCTAssertEqual(info.fps, 25, accuracy: 0.5)
        XCTAssertEqual(info.seconds, 2, accuracy: 0.2)
        XCTAssertTrue(info.hasVideo)
        XCTAssertFalse(info.hasAudio)
    }
}
