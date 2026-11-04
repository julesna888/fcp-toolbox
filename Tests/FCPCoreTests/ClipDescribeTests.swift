import XCTest
@testable import FCPCore

final class ClipDescribeTests: XCTestCase {
    typealias L = Doctor.DescribeLabel
    let vocab: [L] = [
        L(group: .soggetti, text: "persona"), L(group: .soggetti, text: "cane"), L(group: .soggetti, text: "folla"),
        L(group: .luoghi, text: "negozio"), L(group: .luoghi, text: "spiaggia"),
        L(group: .inquadratura, text: "primo piano"), L(group: .inquadratura, text: "campo lungo"),
    ]

    func testVocabularyIsCleanAndBigEnough() {
        let texts = Doctor.describeVocabulary.map(\.text)
        XCTAssertEqual(Set(texts).count, texts.count, "frasi duplicate: \(texts.filter { t in texts.filter { $0 == t }.count > 1 })")
        XCTAssertGreaterThanOrEqual(texts.count, 250)
        XCTAssertLessThanOrEqual(texts.count, 450)
        XCTAssertTrue(texts.allSatisfy { !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespaces) && !$0.contains("\"") })
        for g in Doctor.DescribeGroup.allCases { XCTAssertTrue(Doctor.describeVocabulary.contains { $0.group == g }, "\(g)") }
    }

    func testBuilderPicksTopLabelsPerGroupInOrder() {
        // mean is about 0.20; persona and negozio and primo piano stand out
        let s: [Float] = [0.30, 0.19, 0.19, 0.29, 0.17, 0.28, 0.18]
        XCTAssertEqual(Doctor.describeLine(scores: s, vocab: vocab), "persona, negozio, primo piano")
    }

    func testBuilderKeepsTwoCloseLabelsButNotWeakOnes() {
        let s: [Float] = [0.30, 0.295, 0.17, 0.15, 0.15, 0.15, 0.15]
        XCTAssertEqual(Doctor.describeLine(scores: s, vocab: vocab), "persona, cane")
        let weak: [Float] = [0.30, 0.25, 0.17, 0.15, 0.15, 0.15, 0.15]
        XCTAssertEqual(Doctor.describeLine(scores: weak, vocab: vocab), "persona", "troppo lontano dal migliore")
    }

    func testBuilderRespectsThresholds() {
        XCTAssertEqual(Doctor.describeLine(scores: [Float](repeating: 0.21, count: 7), vocab: vocab), "", "tutto uguale: niente da dire")
        XCTAssertEqual(Doctor.describeLine(scores: [0.15, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1], vocab: vocab), "", "sotto il minimo assoluto")
        XCTAssertEqual(Doctor.describeLine(scores: [0.3], vocab: vocab), "", "dimensioni diverse")
        var rules = Doctor.DescribeRules()
        rules.maxPhrases = 1
        XCTAssertEqual(Doctor.describeLine(scores: [0.30, 0.19, 0.19, 0.29, 0.17, 0.28, 0.18], vocab: vocab, rules: rules), "persona")
    }

    func testVocabularyFileChangesWhenOnePhraseChanges() {
        var v = Doctor.describeVocabulary
        let a = Doctor.describeVocabularyJSON(v)
        XCTAssertEqual(a, Doctor.describeVocabularyJSON(v))
        v[0] = L(group: v[0].group, text: v[0].text + "!")
        XCTAssertNotEqual(a, Doctor.describeVocabularyJSON(v), "il file cambia, quindi la cache viene ricalcolata")
    }

    func testWithoutCLIPSaysSo() throws {
        try XCTSkipIf(Doctor.clipInstalled)
        XCTAssertNotNil(Doctor.clipDescribe([URL(fileURLWithPath: "/x.mov")]).problem)
    }

    func testRealDescriptionOfSeaLikeClipAndCacheInvalidation() throws {
        try XCTSkipUnless(Doctor.clipInstalled, "ricerca per contenuto non installata")
        let ffmpeg = try XCTUnwrap(Doctor.ffmpegPath)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func make(_ name: String, _ source: String) throws -> URL {
            let u = dir.appendingPathComponent(name)
            let r = Doctor.run(ffmpeg, ["-loglevel", "error", "-f", "lavfi", "-i", source, "-t", "2", "-pix_fmt", "yuv420p", u.path])
            try XCTSkipIf(r.status != 0, r.out)
            return u
        }
        // sky, sea, sand
        let a = try make("a.mp4", "color=c=0x87ceeb:s=320x100:r=25[t];color=c=0x0b5fa5:s=320x100:r=25[m];color=c=0xf0dfa0:s=320x40:r=25[b];[t][m][b]vstack=inputs=3")
        let b = try make("b.mp4", "color=c=black:s=320x240:r=25")
        let index = dir.appendingPathComponent("index.json")
        let t0 = Date()
        let r = Doctor.clipDescribe([a, b], indexURL: index)
        print("clipDescribe (analisi + vocabolario): \(Date().timeIntervalSince(t0)) s")
        XCTAssertNil(r.problem)
        let da = try XCTUnwrap(r.descriptions[a]), db = try XCTUnwrap(r.descriptions[b])
        print("a: \(da)\nb: \(db)")
        XCTAssertTrue(["mare", "spiaggia", "oceano", "onde", "costa", "cielo", "deserto", "lago"].contains { da.contains($0) }, "descrizione: \(da)")
        XCTAssertNotEqual(da, db)
        XCTAssertFalse(["mare", "spiaggia", "oceano"].contains { db.contains($0) }, "schermo nero descritto come mare: \(db)")

        // cache: second run reuses the vocabulary vectors, a changed vocabulary recomputes them
        let cache = dir.appendingPathComponent("cache.npz")
        let v = Doctor.describeVocabulary
        XCTAssertFalse(Doctor.describeScores(paths: [a.path], indexURL: index, vocab: v, cacheURL: cache).cached)
        let t1 = Date()
        let again = Doctor.describeScores(paths: [a.path], indexURL: index, vocab: v, cacheURL: cache)
        print("seconda descrizione con cache: \(Date().timeIntervalSince(t1)) s")
        XCTAssertTrue(again.cached)
        XCTAssertEqual(again.scores[a.path]?.count, v.count)
        XCTAssertFalse(Doctor.describeScores(paths: [a.path], indexURL: index, vocab: Array(v.dropLast()), cacheURL: cache).cached)
    }
}
