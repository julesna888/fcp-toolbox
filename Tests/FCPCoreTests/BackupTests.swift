import XCTest
@testable import FCPCore

final class BackupTests: XCTestCase {
    let fm = FileManager.default
    var tmp: URL!
    var src: URL!
    var dst: URL!

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("bk-\(UUID().uuidString)")
        src = tmp.appendingPathComponent("Film.fcpbundle")
        dst = tmp.appendingPathComponent("disk2")
        try fm.createDirectory(at: src.appendingPathComponent("Evento"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        try Data("uno".utf8).write(to: src.appendingPathComponent("Evento/a.txt"))
        try Data("due!".utf8).write(to: src.appendingPathComponent("b.txt"))
        try fm.createSymbolicLink(at: src.appendingPathComponent("Evento/link.mov"),
                                  withDestinationURL: URL(fileURLWithPath: "/nonexistent/clip.mov"))
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    func testFirstBackupCopiesEverythingAndVerifiesIt() throws {
        let r = try Doctor.backup(source: src, into: dst)
        XCTAssertTrue(r.failures.isEmpty, "\(r.failures)")
        XCTAssertEqual(r.verified, 2)
        let copy = dst.appendingPathComponent("Film.fcpbundle")
        XCTAssertEqual(try String(contentsOf: copy.appendingPathComponent("Evento/a.txt")), "uno")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: copy.appendingPathComponent("Evento/link.mov").path),
                       "/nonexistent/clip.mov")
    }

    func testSecondBackupCopiesNothingAndChangesAreDetected() throws {
        _ = try Doctor.backup(source: src, into: dst)
        let copy = dst.appendingPathComponent("Film.fcpbundle")
        XCTAssertTrue(Doctor.diff(source: src, destination: copy).toCopy.isEmpty)

        try Data("tre, più lungo".utf8).write(to: src.appendingPathComponent("b.txt"))
        let d = Doctor.diff(source: src, destination: copy)
        XCTAssertEqual(d.changed, ["b.txt"])
        let r = try Doctor.backup(source: src, into: dst)
        XCTAssertEqual(r.verified, 1)
        XCTAssertEqual(try String(contentsOf: copy.appendingPathComponent("b.txt")), "tre, più lungo")
    }

    func testBackupNeverDeletesWhatOnlyTheDestinationHas() throws {
        _ = try Doctor.backup(source: src, into: dst)
        let copy = dst.appendingPathComponent("Film.fcpbundle")
        try Data("mio".utf8).write(to: copy.appendingPathComponent("solo-qui.txt"))
        _ = try Doctor.backup(source: src, into: dst)
        XCTAssertTrue(fm.fileExists(atPath: copy.appendingPathComponent("solo-qui.txt").path))
        XCTAssertEqual(Doctor.diff(source: src, destination: copy).extra, 1)
    }

    func testRefusesDestinationInsideSource() {
        XCTAssertThrowsError(try Doctor.backup(source: src, into: src.appendingPathComponent("Evento")))
    }

    func testNewerFileInTheBackupIsNeverOverwritten() throws {
        let first = try Doctor.backup(source: src, into: dst)
        let copy = dst.appendingPathComponent("Film.fcpbundle/b.txt")
        // the original changes (different size)…
        try Data("tre!!!".utf8).write(to: src.appendingPathComponent("b.txt"))
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: src.appendingPathComponent("b.txt").path)
        // …but the backup copy was edited later, on purpose
        try Data("lavoro nel backup".utf8).write(to: copy)
        let r = try Doctor.backup(source: src, into: dst)
        XCTAssertEqual(first.failures, [])
        XCTAssertEqual(r.copied, 0)
        XCTAssertTrue(r.failures.contains { $0.contains("più recente") }, "\(r.failures)")
        XCTAssertEqual(try String(contentsOf: copy), "lavoro nel backup")
    }

    func testChangesSinceLastBackupAndIncompleteCopies() throws {
        XCTAssertNil(Doctor.changesSinceLastBackup(source: src, history: []).record)  // never backed up
        let r = try Doctor.backup(source: src, into: dst)
        var c = Doctor.changesSinceLastBackup(source: src, history: [r])
        XCTAssertEqual(c.record?.id, r.id)
        XCTAssertTrue(try XCTUnwrap(c.diff).toCopy.isEmpty)
        try Data("nuovo".utf8).write(to: src.appendingPathComponent("c.txt"))
        c = Doctor.changesSinceLastBackup(source: src, history: [r])
        XCTAssertEqual(c.diff?.new, ["c.txt"])
        // an interrupted copy leaves a .fcptmp behind
        try Data("x".utf8).write(to: dst.appendingPathComponent("Film.fcpbundle/c.txt.fcptmp"))
        XCTAssertEqual(Doctor.incompleteCopies(in: dst), ["Film.fcpbundle/c.txt.fcptmp"])
    }

    func testRefusesWhenTheDestinationHasNoRoomForIt() {
        let e = BackupError.notEnoughSpace(needed: 5_000_000_000, free: 1_000_000_000)
        XCTAssertTrue(e.localizedDescription.contains("Spazio insufficiente"))
    }

    func testHistoryRoundTrip() throws {
        let file = tmp.appendingPathComponent("h/backups.json")
        let r = try Doctor.backup(source: src, into: dst)
        Doctor.record(r, at: file)
        XCTAssertEqual(Doctor.history(at: file).first?.id, r.id)
    }
}
