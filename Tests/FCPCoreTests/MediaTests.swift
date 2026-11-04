import XCTest
@testable import FCPCore

final class MediaTests: XCTestCase {
    let fm = FileManager.default
    var root: URL!
    var media: URL!
    var library: Library!

    func write(_ url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 10_000).write(to: url)
    }

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        media = root.appendingPathComponent("Final Cut Original Media")
        try write(media.appendingPathComponent("2026-01-01/a.mov"))      // linked by the library
        try write(media.appendingPathComponent("2026-01-01/b.mov"))      // linked by nobody
        try write(media.appendingPathComponent("2026-01-03/moved.mov"))  // library points to a stale path
        let originals = root.appendingPathComponent("lavoro.fcpbundle/Event/Original Media")
        try fm.createDirectory(at: originals, withIntermediateDirectories: true)
        for (name, target) in [("a.mov", "2026-01-01/a.mov"), ("moved.mov", "2026-01-02/moved.mov"),
                               ("gone.mov", "2026-01-02/gone.mov")] {
            try fm.createSymbolicLink(at: originals.appendingPathComponent(name),
                                      withDestinationURL: media.appendingPathComponent(target))
        }
        library = Doctor.scan(root.appendingPathComponent("lavoro.fcpbundle"))
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    func report() -> MediaReport { Doctor.mediaReport(roots: [root], libraries: [library]) }

    func testFindsMediaFolderFromDiskRoot() {
        XCTAssertEqual(Doctor.findMediaFolders(in: [root]).map(\.lastPathComponent), ["Final Cut Original Media"])
    }

    func testReportSeparatesLinkedOrphanAndBroken() {
        let r = report()
        XCTAssertEqual(Set(r.imports.map(\.name)), ["2026-01-01", "2026-01-03"])
        XCTAssertEqual(r.orphans.map(\.name).sorted(), ["b.mov", "moved.mov"])
        let day1 = r.imports.first { $0.name == "2026-01-01" }!
        XCTAssertGreaterThan(day1.linkedSize, 0)
        XCTAssertEqual(day1.orphanCount, 1)
        XCTAssertEqual(r.broken.count, 2)
        XCTAssertEqual(r.broken.first { $0.name == "moved.mov" }?.found.count, 1)
        XCTAssertEqual(r.broken.first { $0.name == "gone.mov" }?.found.count, 0)
        XCTAssertEqual(r.recoverableCount, 1)
        XCTAssertEqual(r.libraryNames, ["lavoro.fcpbundle"])
    }

    func testTrashMovesOnlyTheOrphanAndKeepsLinkedMedia() {
        let r = report()
        let b = r.orphans.filter { $0.name == "b.mov" }
        let result = Doctor.trashOrphans(b, mediaFolders: r.mediaFolders, libraries: [library])
        XCTAssertEqual(result.moved, 1)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: media.appendingPathComponent("2026-01-01/b.mov").path))
        XCTAssertTrue(fm.fileExists(atPath: media.appendingPathComponent("2026-01-01/a.mov").path))
    }

    func testTrashRefusesAFileALibraryStillUses() {
        let r = report()
        let linked = mediaFile(media.appendingPathComponent("2026-01-01/a.mov"))
        let result = Doctor.trashOrphans([linked], mediaFolders: r.mediaFolders, libraries: [library])
        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: linked.url.path))
    }

    func testTrashRefusesWhenNoLibraryWasConsidered() {
        let r = report()
        let result = Doctor.trashOrphans(r.orphans, mediaFolders: r.mediaFolders, libraries: [])
        XCTAssertEqual(result.moved, 0)
        XCTAssertTrue(fm.fileExists(atPath: media.appendingPathComponent("2026-01-01/b.mov").path))
    }

    func testTrashRefusesFilesOutsideTheMediaFolder() throws {
        let stray = root.appendingPathComponent("other/x.mov")
        try write(stray)
        let r = report()
        let result = Doctor.trashOrphans([mediaFile(stray)], mediaFolders: r.mediaFolders, libraries: [library])
        XCTAssertEqual(result.moved, 0)
        XCTAssertTrue(fm.fileExists(atPath: stray.path))
    }

    func mediaFile(_ url: URL) -> MediaFile {
        MediaFile(key: Doctor.realKey(url), url: url, size: 1, importName: "x", importURL: url.deletingLastPathComponent())
    }
}
