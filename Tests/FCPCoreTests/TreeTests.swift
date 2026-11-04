import XCTest
@testable import FCPCore

final class TreeTests: XCTestCase {
    var tmp: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("tree-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    private func write(_ url: URL, bytes: Int = 0) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    func testTreeListsEventsProjectsAndLinkedClips() throws {
        let lib = tmp.appendingPathComponent("Film.fcpbundle")
        let ev = lib.appendingPathComponent("Evento 1")
        try write(ev.appendingPathComponent("CurrentVersion.fcpevent"))
        try write(ev.appendingPathComponent("Il mio progetto/CurrentVersion.fcpevent.txt"), bytes: 10)
        let media = tmp.appendingPathComponent("Final Cut Original Media/2026-01-01/a.mov")
        try write(media, bytes: 100_000)
        let linkDir = ev.appendingPathComponent("Original Media")
        try fm.createDirectory(at: linkDir, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkDir.appendingPathComponent("a.mov"), withDestinationURL: media)
        try fm.createSymbolicLink(at: linkDir.appendingPathComponent("gone.mov"),
                                  withDestinationURL: tmp.appendingPathComponent("nope.mov"))

        let nodes = Doctor.tree(of: [Doctor.scan(lib)])
        XCTAssertEqual(nodes.count, 1)
        let event = try XCTUnwrap(nodes[0].children?.first)
        XCTAssertEqual(event.kind, .event)
        XCTAssertEqual(event.media, 2)
        XCTAssertEqual(event.missing, 1)
        XCTAssertGreaterThanOrEqual(event.external, 100_000)
        XCTAssertTrue(event.children?.contains { $0.kind == .project && $0.name == "Il mio progetto" } == true)
        XCTAssertTrue(event.children?.contains { $0.kind == .group } == true)
    }

    func testTrashStaysInsideRoots() throws {
        let inside = tmp.appendingPathComponent("root/file.txt")
        try write(inside, bytes: 5)
        let outsideDir = fm.temporaryDirectory.appendingPathComponent("out-\(UUID().uuidString)")
        let outside = outsideDir.appendingPathComponent("keep.txt")
        try write(outside, bytes: 5)
        defer { try? fm.removeItem(at: outsideDir) }

        let root = tmp.appendingPathComponent("root")
        let r = Doctor.trash([inside, outside, root], within: [root])
        XCTAssertEqual(r.moved, 1)
        XCTAssertEqual(r.failures.count, 2)  // outside + the root itself
        XCTAssertFalse(fm.fileExists(atPath: inside.path))
        XCTAssertTrue(fm.fileExists(atPath: outside.path))
        XCTAssertTrue(fm.fileExists(atPath: root.path))
    }
}
