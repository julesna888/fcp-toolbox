import XCTest
@testable import FCPCore

final class MediaManageTests: XCTestCase {
    private func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("mm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    @discardableResult private func file(_ d: URL, _ name: String, _ text: String) throws -> URL {
        let u = d.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
        return u
    }

    func testIdenticalCopiesAreNotConfusedWithVersions() throws {
        let d = try dir()
        try file(d, "clip.mov", "AAAA")
        try file(d, "clip copy.mov", "AAAA")          // identical
        try file(d, "sub/other.mov", "BBBB")
        try file(d, "interview.mov", "first take")
        try file(d, "interview final.mov", "second cut")  // same name family, different content
        try file(d, "scene_01.mov", "x1")
        try file(d, "scene_02.mov", "x2")              // numbered clips are NOT versions

        let r = Doctor.findDuplicates(in: d)
        XCTAssertEqual(r.identical.count, 1)
        XCTAssertEqual(Set(r.identical[0].files.map(\.lastPathComponent)), ["clip.mov", "clip copy.mov"])
        XCTAssertEqual(r.identical[0].wasted, 4)
        XCTAssertEqual(r.versions.count, 1)
        XCTAssertEqual(Set(r.versions[0].files.map(\.lastPathComponent)), ["interview.mov", "interview final.mov"])
    }

    func testRenameDateFormatPrefixSuffixAndFinalCutGuard() throws {
        let d = try dir()
        let a = try file(d, "IMG_1.mov", "1")
        let day = DateFormatter(); day.dateFormat = "yyyyMMdd"
        let today = day.string(from: Date())
        let plan = Doctor.renamePlan([a], template: "CLIENTE_{date:yyyyMMdd}_{name}_{n:2}_v1")
        XCTAssertEqual(plan.first?.to.lastPathComponent, "CLIENTE_\(today)_IMG_1_01_v1.mov")
        let inside = d.appendingPathComponent("Lib.fcpbundle/Evento/Original Media")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let guarded = try file(inside, "clip.mov", "x")
        XCTAssertEqual(Doctor.renamePlan([guarded], template: "altro").first?.conflict, "File di Final Cut: non si rinomina")
    }

    func testRenamePlanTokensAndConflicts() throws {
        let d = try dir()
        let a = try file(d, "IMG_10.mov", "1"), b = try file(d, "IMG_2.mov", "2")
        let plan = Doctor.renamePlan([a, b], template: "Cliente_{n:3}")
        XCTAssertEqual(plan.map { $0.to.lastPathComponent }, ["Cliente_001.mov", "Cliente_002.mov"])  // IMG_2 sorts before IMG_10
        XCTAssertEqual(plan[0].from.lastPathComponent, "IMG_2.mov")
        XCTAssertTrue(plan.allSatisfy { $0.conflict == nil })

        XCTAssertEqual(Doctor.renamePlan([a, b], template: "same").compactMap(\.conflict), ["Due file avrebbero lo stesso nome", "Due file avrebbero lo stesso nome"])
        XCTAssertEqual(Doctor.renamePlan([a], template: "{name}").first?.conflict, "Nome invariato")
        XCTAssertEqual(Doctor.renamePlan([a], template: "{name}", find: "IMG", replace: "Clip").first?.to.lastPathComponent, "Clip_10.mov")
        try file(d, "taken.mov", "t")
        XCTAssertEqual(Doctor.renamePlan([a], template: "taken").first?.conflict, "Esiste già un file con questo nome")
        XCTAssertEqual(Doctor.renamePlan([a], template: "{date}_{name}").first?.to.lastPathComponent.count, "2026-10-31_IMG_10.mov".count)
    }

    func testMovesAreAppliedWithoutOverwritingAndUndone() throws {
        let d = try dir()
        let log = d.appendingPathComponent("log/moves.json")
        let v = try file(d, "a.mov", "v"), w = try file(d, "b.wav", "w"), o = try file(d, "c.xyz", "o")
        try file(d, "Video/a.mov", "already here")
        let plan = Doctor.organizePlan(d, by: .type)
        XCTAssertEqual(plan.first { $0.from.lastPathComponent == v.lastPathComponent }?.conflict, "Esiste già nella cartella di destinazione")
        XCTAssertEqual(plan.first { $0.from.lastPathComponent == w.lastPathComponent }?.to.deletingLastPathComponent().lastPathComponent, "Audio")
        XCTAssertEqual(plan.first { $0.from.lastPathComponent == o.lastPathComponent }?.to.deletingLastPathComponent().lastPathComponent, "Altro")

        let r = Doctor.applyMoves(plan, label: "organizza", log: log)
        XCTAssertEqual(r.done, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: d.appendingPathComponent("Audio/b.wav").path))
        XCTAssertEqual(try String(contentsOf: d.appendingPathComponent("Video/a.mov")), "already here")
        XCTAssertTrue(FileManager.default.fileExists(atPath: v.path))  // the conflicting file stayed
        XCTAssertEqual(Doctor.lastMoveLabel(log: log), "organizza")

        let u = Doctor.undoLastMoves(log: log)
        XCTAssertEqual(u.restored, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: w.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: o.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: d.appendingPathComponent("Audio").path))  // empty bucket removed
        XCTAssertEqual(Doctor.undoLastMoves(log: log).restored, 0)
    }

    func testOrganizeByDateUsesModificationMonth() throws {
        let d = try dir()
        let f = try file(d, "a.mov", "x")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: f.path)  // Nov 2023
        let df = DateFormatter(); df.dateFormat = "yyyy-MM"
        XCTAssertEqual(Doctor.organizePlan(d, by: .date).first?.to.deletingLastPathComponent().lastPathComponent,
                       df.string(from: Date(timeIntervalSince1970: 1_700_000_000)))
    }

    func testCompareFoldersAndManifest() throws {
        let a = try dir(), b = try dir()
        try file(a, "same.mov", "1"); try file(b, "same.mov", "1")
        try file(a, "diff.mov", "1"); try file(b, "diff.mov", "2")
        try file(a, "left.mov", "L"); try file(b, "right.mov", "R")
        try file(a, "sub/deep.mov", "D"); try file(b, "sub/deep.mov", "D")
        let d = Doctor.compareFolders(a, b)
        XCTAssertEqual(d.same, 2)
        XCTAssertEqual(d.different, ["diff.mov"])
        XCTAssertEqual(d.onlyInA, ["left.mov"])
        XCTAssertEqual(d.onlyInB, ["right.mov"])

        let manifest = a.appendingPathComponent("../m-\(UUID().uuidString).json").standardizedFileURL
        XCTAssertEqual(Doctor.writeManifest(for: a, at: manifest), 4)
        XCTAssertTrue(try XCTUnwrap(Doctor.verifyManifest(for: a, at: manifest)).ok)
        try Data("changed!".utf8).write(to: a.appendingPathComponent("diff.mov"))
        try FileManager.default.removeItem(at: a.appendingPathComponent("left.mov"))
        try file(a, "new.mov", "N")
        let c = try XCTUnwrap(Doctor.verifyManifest(for: a, at: manifest))
        XCTAssertEqual(c.changed, ["diff.mov"])
        XCTAssertEqual(c.missing, ["left.mov"])
        XCTAssertEqual(c.new, ["new.mov"])
        XCTAssertFalse(c.ok)
        XCTAssertNil(Doctor.verifyManifest(for: b, at: manifest.deletingLastPathComponent().appendingPathComponent("none.json")))
    }
}
