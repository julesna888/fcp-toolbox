import XCTest
@testable import FCPCore

final class SubtitlesTests: XCTestCase {
    let srt = "\u{FEFF}1\r\n00:00:01,000 --> 00:00:03,500\r\nciao  a tutti ,benvenuti\r\n\r\n2\r\n00:00:03,500 --> 00:00:03,900\r\ntroppo veloce questa battuta lunghissima davvero\r\n\r\n3\r\n00:01:02,250 --> 00:01:12,000\r\nuna battuta\nche dura\ntroppo a lungo\r\n"

    func testSRTRoundTripAndVTTConversion() {
        let cues = Doctor.parseSRT(srt)
        XCTAssertEqual(cues.count, 3)
        XCTAssertEqual(cues[0].start, 1.0)
        XCTAssertEqual(cues[0].end, 3.5)
        XCTAssertEqual(cues[2].start, 62.25)
        XCTAssertEqual(cues[2].text, "una battuta\nche dura\ntroppo a lungo")

        XCTAssertEqual(Doctor.parseSRT(Doctor.renderSRT(cues)), cues)
        let vtt = Doctor.renderVTT(cues)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\n00:00:01.000 --> 00:00:03.500"))
        XCTAssertEqual(Doctor.parseVTT(vtt), cues)
        // VTT may omit the hour and add cue settings
        let short = Doctor.parseVTT("WEBVTT\n\n01:02.500 --> 01:04.000 align:start\nHello")
        XCTAssertEqual(short.first?.start, 62.5)
        XCTAssertEqual(short.first?.end, 64.0)
        XCTAssertEqual(Doctor.parseSRT("niente").count, 0)
    }

    func testReadabilityChecksFindEachProblem() {
        let issues = Doctor.checkSubtitles(Doctor.parseSRT(srt))
        let kinds = Set(issues.map { "\($0.cue):\($0.kind)" })
        XCTAssertTrue(kinds.contains("2:troppo breve"), "\(kinds)")
        XCTAssertTrue(kinds.contains("2:troppo veloce"))
        XCTAssertTrue(kinds.contains("3:troppo lunga"))
        XCTAssertTrue(kinds.contains("3:troppe righe"))
        XCTAssertFalse(kinds.contains { $0.hasPrefix("1:") })  // the first one is fine

        let overlap = [SubtitleCue(index: 1, start: 0, end: 3, text: "a lungo discorso qui"), SubtitleCue(index: 2, start: 2, end: 5, text: "seconda battuta qui")]
        XCTAssertEqual(Doctor.checkSubtitles(overlap).map(\.kind), ["sovrapposta"])
        let long = [SubtitleCue(index: 1, start: 0, end: 5, text: String(repeating: "a", count: 50))]
        XCTAssertEqual(Doctor.checkSubtitles(long).map(\.kind), ["riga lunga"])
        XCTAssertEqual(Doctor.checkSubtitles([SubtitleCue(index: 1, start: 2, end: 2, text: "x")]).map(\.kind), ["tempi"])
        XCTAssertEqual(Doctor.checkSubtitles([SubtitleCue(index: 1, start: 0, end: 2, text: "  ")]).map(\.kind), ["vuota"])
    }

    func testPunctuationFixCleansSpacingWithoutRewritingWords() {
        let fixed = Doctor.fixPunctuation(Doctor.parseSRT(srt))
        XCTAssertEqual(fixed[0].text, "Ciao a tutti, benvenuti")
        XCTAssertEqual(fixed[1].text, "troppo veloce questa battuta lunghissima davvero")  // previous cue did not end a sentence
        let two = Doctor.fixPunctuation([SubtitleCue(index: 1, start: 0, end: 2, text: "Finito ."), SubtitleCue(index: 2, start: 2, end: 4, text: "poi si riparte")])
        XCTAssertEqual(two.map(\.text), ["Finito.", "Poi si riparte"])
        XCTAssertEqual(Doctor.fixPunctuation([SubtitleCue(index: 1, start: 0, end: 2, text: "ecc. e S.p.A.")])[0].text, "Ecc. e S.p.A.")
    }

    func testTranscriptionExplainsWhatIsMissing() throws {
        XCTAssertThrowsError(try Doctor.transcribe(URL(fileURLWithPath: "/x.mov"), model: URL(fileURLWithPath: "/nope/ggml-base.bin"),
                                                   outputDir: FileManager.default.temporaryDirectory.appendingPathComponent("sub-\(UUID().uuidString)"))) {
            guard let e = $0 as? SubtitleError else { return XCTFail("\($0)") }
            let ok: Bool
            switch e { case .noModel, .noTool: ok = true; default: ok = false }
            XCTAssertTrue(ok, "\(e)")
        }
        XCTAssertTrue(Doctor.whisperModels(in: [URL(fileURLWithPath: "/nonexistent")]).isEmpty)
        print("WHISPER: cli=\(Doctor.whisperCLI ?? "assente"), modelli=\(Doctor.whisperModels().map(\.lastPathComponent))")
    }

    /// Runs only when a model is installed: transcribes a spoken sentence made with the macOS voice.
    func testRealTranscriptionWhenAModelExists() throws {
        let found = Doctor.whisperModels().first
        try XCTSkipIf(found == nil, "nessun modello Whisper installato")
        let model = try XCTUnwrap(found)
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("wh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Alice", "-o", d.appendingPathComponent("v.aiff").path, "Buongiorno a tutti, questo è un test."]
        try say.run(); say.waitUntilExit()
        let srt = try Doctor.transcribe(d.appendingPathComponent("v.aiff"), model: model, language: "it", outputDir: d)
        let text = try String(contentsOf: srt).lowercased()
        XCTAssertTrue(text.contains("buongiorno"), text)
    }
}
