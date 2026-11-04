import XCTest
@testable import FCPCore

final class DoctorTests: XCTestCase {
    let fm = FileManager.default
    var root: URL!
    var bundle: URL!
    var event: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        bundle = root.appendingPathComponent("lib.fcpbundle")
        event = bundle.appendingPathComponent("Event 1")
        for dir in ["Original Media", "Render Files", "Transcoded Media/High Quality Media", "Analysis Files"] {
            try fm.createDirectory(at: event.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for file in ["Original Media/a.mov", "Render Files/r.mov",
                     "Transcoded Media/High Quality Media/t.mov", "Analysis Files/x.bin"] {
            try Data(count: 10_000).write(to: event.appendingPathComponent(file))
        }
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    func exists(_ rel: String) -> Bool { fm.fileExists(atPath: event.appendingPathComponent(rel).path) }

    func cleanAll(includeAnalysis: Bool = false) -> CleanResult {
        let items = Doctor.scan(bundle).items.filter { $0.canClean(includeAnalysis: includeAnalysis) }
        return Doctor.clean(items)
    }

    func testFindsBundleInsideFolder() {
        XCTAssertEqual(Doctor.findBundles(in: [root]).map(\.lastPathComponent), ["lib.fcpbundle"])
    }

    func testScanClassifiesFolders() {
        let items = Doctor.scan(bundle).items
        XCTAssertEqual(Set(items.map(\.name)),
                       ["Original Media", "Render Files", "Transcoded Media", "Analysis Files"])
        XCTAssertEqual(items.first { $0.name == "Original Media" }?.blocked, "Originali")
        XCTAssertTrue(items.first { $0.name == "Render Files" }!.canClean(includeAnalysis: false))
        XCTAssertFalse(items.first { $0.name == "Analysis Files" }!.canClean(includeAnalysis: false))
        XCTAssertTrue(items.first { $0.name == "Analysis Files" }!.canClean(includeAnalysis: true))
    }

    func testCleanKeepsOriginalsAndAnalysis() {
        let r = cleanAll()
        XCTAssertTrue(r.failures.isEmpty)
        XCTAssertGreaterThan(r.freed, 0)
        XCTAssertTrue(exists("Original Media/a.mov"))
        XCTAssertTrue(exists("Analysis Files/x.bin"))
        XCTAssertFalse(exists("Render Files/r.mov"))
        XCTAssertFalse(exists("Transcoded Media/High Quality Media/t.mov"))
        XCTAssertTrue(exists("Render Files"))  // the folder itself stays
    }

    func testAnalysisOnlyWhenAsked() {
        _ = cleanAll(includeAnalysis: true)
        XCTAssertFalse(exists("Analysis Files/x.bin"))
        XCTAssertTrue(exists("Original Media/a.mov"))
    }

    func testBrokenOriginalLinkProtectsTranscodedMedia() throws {
        try fm.createSymbolicLink(at: event.appendingPathComponent("Original Media/link.mov"),
                                  withDestinationURL: root.appendingPathComponent("gone.mov"))
        _ = cleanAll()
        XCTAssertTrue(exists("Transcoded Media/High Quality Media/t.mov"))
        XCTAssertFalse(exists("Render Files/r.mov"))
    }

    func testSymlinkedCacheFolderIsNeverFollowed() throws {
        let outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(count: 10_000).write(to: outside.appendingPathComponent("precious.mov"))
        try fm.removeItem(at: event.appendingPathComponent("Render Files"))
        try fm.createSymbolicLink(at: event.appendingPathComponent("Render Files"), withDestinationURL: outside)
        _ = cleanAll()
        XCTAssertTrue(fm.fileExists(atPath: outside.appendingPathComponent("precious.mov").path))
    }

    func testFinalCutAutomaticBackupsAreGroupedNotListed() throws {
        let backup = root.appendingPathComponent("Final Cut Backups.localized/private/20261029_1123_GMT+1.fcpbundle")
        try fm.createDirectory(at: backup.appendingPathComponent("Event/Render Files"), withIntermediateDirectories: true)
        try Data(count: 10_000).write(to: backup.appendingPathComponent("Event/Render Files/r.mov"))
        let lib = Doctor.scan(backup)
        XCTAssertTrue(lib.isBackup)
        XCTAssertTrue(lib.items.isEmpty)
        XCTAssertGreaterThan(lib.total, 0)
        XCTAssertFalse(Doctor.scan(bundle).isBackup)
    }

    func testBackupIsRecognizedByItsNameEvenOutsideABackupsFolder() throws {
        let odd = root.appendingPathComponent("lavoro/20261029_1123_GMT+1.fcpbundle")
        try fm.createDirectory(at: odd, withIntermediateDirectories: true)
        XCTAssertTrue(Doctor.isAutomaticBackup(odd))
        XCTAssertFalse(Doctor.isAutomaticBackup(root.appendingPathComponent("20261029 lavoro.fcpbundle")))
    }

    func testOtherIsWhatTheScanHasNoNameFor() throws {
        try Data(count: 50_000).write(to: bundle.appendingPathComponent("database.bin"))
        let lib = Doctor.scan(bundle)
        XCTAssertGreaterThanOrEqual(lib.other, 50_000)
        XCTAssertLessThan(lib.other, lib.total)
    }

    func testCleanRefusesSpoofedOriginalMedia() {
        let fake = Item(name: "Original Media", label: "x", url: event.appendingPathComponent("Original Media"),
                        size: 1, kind: .clean, blocked: nil)
        let r = Doctor.clean([fake])
        XCTAssertEqual(r.failures.count, 1)
        XCTAssertTrue(exists("Original Media/a.mov"))
    }

    func testCleanRefusesFoldersOutsideALibrary() throws {
        let stray = root.appendingPathComponent("elsewhere/Render Files")
        try fm.createDirectory(at: stray, withIntermediateDirectories: true)
        try Data(count: 10).write(to: stray.appendingPathComponent("keep.txt"))
        let fake = Item(name: "Render Files", label: "x", url: stray, size: 1, kind: .clean, blocked: nil)
        XCTAssertEqual(Doctor.clean([fake]).failures.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: stray.appendingPathComponent("keep.txt").path))
    }

    func testOldBackupsKeepsNewestThreePerFolder() {
        func b(_ folder: String, _ name: String) -> Library {
            Library(url: URL(fileURLWithPath: "/x/\(folder)/\(name).fcpbundle"), total: 10, items: [], isBackup: true)
        }
        let a = ["20260101_1000_GMT+1", "20260102_1000_GMT+1", "20260103_1000_GMT+1", "20260104_1000_GMT+1", "20260105_1000_GMT+1"]
        let all = a.map { b("A", $0) } + [b("B", "20260101_1000_GMT+1")]
        let old = Doctor.oldBackups(all).map(\.name)
        XCTAssertEqual(old, ["20260101_1000_GMT+1.fcpbundle", "20260102_1000_GMT+1.fcpbundle"])
        XCTAssertTrue(Doctor.oldBackups(all, keep: 10).isEmpty)
    }

    func testAppleMediaLibrariesAreNotScanned() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fcp-\(UUID().uuidString)/Movies")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        for p in ["TV/x.fcpbundle", "Mine/y.fcpbundle", "Photos Library.photoslibrary/z.fcpbundle"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(p), withIntermediateDirectories: true)
        }
        XCTAssertEqual(Doctor.findBundles(in: [root]).map(\.lastPathComponent), ["y.fcpbundle"])
    }
}
