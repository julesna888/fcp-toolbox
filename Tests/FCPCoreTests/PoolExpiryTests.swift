import XCTest
@testable import FCPCore

final class PoolExpiryTests: XCTestCase {
    private let fm = FileManager.default
    private var tmp: URL!
    private var ledger: URL { tmp.appendingPathComponent("ledger/pool-expiry.json") }
    private var fakeTrash: URL { tmp.appendingPathComponent("trash") }
    private var opLog: URL { tmp.appendingPathComponent("ops.jsonl") }

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("pe-\(UUID().uuidString)")
        try fm.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    private func clip(_ rel: String) throws -> URL {
        let u = tmp.appendingPathComponent("pool/\(rel)")
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: u)
        return u
    }
    private func moveToFakeTrash(_ u: URL) throws { try fm.moveItem(at: u, to: fakeTrash.appendingPathComponent(u.lastPathComponent)) }

    func testExpiryIsExactlyThirtyDaysAfterImport() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let e = Doctor.poolExpiryDate(importedAt: t)
        XCTAssertEqual(e, Calendar.current.date(byAdding: .day, value: 30, to: t))
        XCTAssertEqual(e.timeIntervalSince(t) / 86_400, 30, accuracy: 0.05)
    }

    func testOnlyDueClipsGoToTheTrashAndFoldersStay() throws {
        let old = try clip("ROSSI/Spot/Originali/vecchia.mov")
        let fresh = try clip("ROSSI/Spot/Originali/nuova.mov")
        let now = Date()
        Doctor.recordPoolImport([old], at: now.addingTimeInterval(-31 * 86_400), ledger: ledger)
        Doctor.recordPoolImport([fresh], at: now.addingTimeInterval(-29 * 86_400), ledger: ledger)

        let r = Doctor.expirePoolClips(now: now, ledger: ledger, operationsLog: opLog, trash: moveToFakeTrash)
        XCTAssertEqual(r.trashed, [old])
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertTrue(fm.fileExists(atPath: fresh.path))
        XCTAssertTrue(fm.fileExists(atPath: old.deletingLastPathComponent().path), "la cartella Originali resta")
        XCTAssertTrue(fm.fileExists(atPath: tmp.appendingPathComponent("pool/ROSSI/Spot").path), "la cartella del video resta")
        XCTAssertEqual(Doctor.poolExpiryEntries(ledger: ledger).map(\.path), [fresh.path], "la clip non scaduta resta in lista")
    }

    func testNotBeforeTheMomentAndNotAfterItIsMissed() throws {
        let c = try clip("A/V/Originali/c.mov")
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        Doctor.recordPoolImport([c], at: t, ledger: ledger)
        let due = Doctor.poolExpiryDate(importedAt: t)
        XCTAssertTrue(Doctor.expirePoolClips(now: due.addingTimeInterval(-1), ledger: ledger, operationsLog: opLog, trash: moveToFakeTrash).trashed.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: c.path))
        XCTAssertEqual(Doctor.expirePoolClips(now: due, ledger: ledger, operationsLog: opLog, trash: moveToFakeTrash).trashed, [c])
    }

    func testOriginalMediaFoldersAndMissingFilesAreNeverTouched() throws {
        let fcp = try clip("Lib.fcpbundle/Evento/Original Media/a.mov")
        let folder = tmp.appendingPathComponent("pool/ROSSI")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let gone = tmp.appendingPathComponent("pool/ROSSI/sparita.mov")
        let past = Date().addingTimeInterval(-40 * 86_400)
        Doctor.recordPoolImport([fcp, folder, gone], at: past, ledger: ledger)
        let r = Doctor.expirePoolClips(ledger: ledger, operationsLog: opLog, trash: { _ in XCTFail("non deve cestinare niente") })
        XCTAssertTrue(r.trashed.isEmpty)
        XCTAssertEqual(r.gone, 1)
        XCTAssertEqual(r.skipped.count, 2)
        XCTAssertTrue(fm.fileExists(atPath: fcp.path))
        XCTAssertTrue(fm.fileExists(atPath: folder.path))
        XCTAssertTrue(Doctor.poolExpiryEntries(ledger: ledger).isEmpty)
    }

    func testFailedTrashStaysInTheListAndKeepIsRespected() throws {
        let c = try clip("A/V/Originali/c.mov")
        let d = try clip("A/W/Originali/d.mov")
        Doctor.recordPoolImport([c, d], at: Date().addingTimeInterval(-31 * 86_400), ledger: ledger)
        struct Boom: Error {}
        let r = Doctor.expirePoolClips(ledger: ledger, operationsLog: opLog, trash: { _ in throw Boom() })
        XCTAssertEqual(r.failures.count, 2)
        XCTAssertEqual(Doctor.poolExpiryEntries(ledger: ledger).count, 2, "si riprova al prossimo giro")
        XCTAssertEqual(Doctor.cancelPoolExpiry(under: tmp.appendingPathComponent("pool/A/W"), ledger: ledger), 1)
        let again = Doctor.expirePoolClips(ledger: ledger, operationsLog: opLog, trash: moveToFakeTrash)
        XCTAssertEqual(again.trashed, [c])
        XCTAssertTrue(fm.fileExists(atPath: d.path))
    }

    func testImportReportsOnlyNewFilesAsPlaced() throws {
        let src = tmp.appendingPathComponent("download")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("uno".utf8).write(to: src.appendingPathComponent("a.mov"))
        try Data("due".utf8).write(to: src.appendingPathComponent("b.mov"))
        let root = tmp.appendingPathComponent("clienti")
        let first = Doctor.poolImport(Doctor.poolPlan(source: src, client: "rossi", video: "Spot", poolRoot: root), move: false)
        XCTAssertEqual(first.placed.count, 2)
        XCTAssertTrue(first.placed[0].path.contains("/ROSSI/Spot/Originali/"))
        let second = Doctor.poolImport(Doctor.poolPlan(source: src, client: "rossi", video: "Spot", poolRoot: root), move: false)
        XCTAssertEqual(second.duplicates, 2)
        XCTAssertTrue(second.placed.isEmpty, "le copie già presenti non ripartono da zero")
    }

    func testWarningsComeOncePerDayOnlyWhenDueSoon() throws {
        let near = try clip("ROSSI/Spot/Originali/a.mov")
        let near2 = try clip("ROSSI/Spot/Originali/b.mov")
        let far = try clip("VERDI/Reel/Originali/c.mov")
        let now = Date()
        Doctor.recordPoolImport([near, near2], at: now.addingTimeInterval(-28 * 86_400), ledger: ledger)  // expires in ~2 days
        Doctor.recordPoolImport([far], at: now.addingTimeInterval(-10 * 86_400), ledger: ledger)           // 20 days left
        let warned = tmp.appendingPathComponent("warned.json")
        let first = Doctor.poolExpiryWarnings(now: now, ledger: ledger, warned: warned)
        XCTAssertEqual(first.count, 1, "una sola voce per cartella video, niente per le clip lontane")
        XCTAssertTrue(first[0].body.contains("ROSSI / Spot"))
        XCTAssertTrue(first[0].body.contains("2 clip"))
        XCTAssertTrue(first[0].body.contains("Tieni per sempre"))
        XCTAssertTrue(Doctor.poolExpiryWarnings(now: now.addingTimeInterval(600), ledger: ledger, warned: warned).isEmpty, "già mostrato oggi")
        let tomorrow = Doctor.poolExpiryWarnings(now: now.addingTimeInterval(86_400), ledger: ledger, warned: warned)
        XCTAssertEqual(tomorrow.count, 1, "il giorno dopo si ripete")
        XCTAssertTrue(tomorrow[0].body.contains("giorn"))
        XCTAssertTrue(Doctor.poolExpiryWarnings(now: now, ledger: tmp.appendingPathComponent("none.json"), warned: warned).isEmpty)
    }

    func testKeepingForeverMeansNothingIsRecorded() throws {
        let c = try clip("ROSSI/Spot/Originali/a.mov")
        // «Importa e tieni per sempre» simply never calls recordPoolImport
        let r = Doctor.expirePoolClips(now: Date().addingTimeInterval(400 * 86_400), ledger: ledger, operationsLog: opLog, trash: { _ in XCTFail("non deve cestinare") })
        XCTAssertTrue(r.trashed.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: c.path))
    }
}
