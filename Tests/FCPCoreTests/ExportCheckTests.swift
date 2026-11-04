import XCTest
@testable import FCPCore

final class ExportCheckTests: XCTestCase {
    private func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func make(_ out: URL, size: String, rate: Int, seconds: Int, audioSeconds: Int? = nil, format: String? = nil) throws {
        var args = ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=duration=\(seconds):size=\(size):rate=\(rate)",
                    "-f", "lavfi", "-i", "sine=duration=\(audioSeconds ?? seconds)", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                    "-c:a", "aac", "-ac", "2", "-ar", "48000"]
        if let format { args += ["-f", format] }
        args.append(out.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }

    private func results(_ r: [CheckResult]) -> [String: Bool] { Dictionary(r.map { ($0.label, $0.ok) }, uniquingKeysWith: { a, _ in a }) }

    func testVerticalClipPassesReelsAndHorizontalDoesNot() throws {
        try XCTSkipUnless(Doctor.ffprobePath != nil && FileManager.default.isExecutableFile(atPath: "/usr/local/bin/ffmpeg"))
        let d = try dir()
        try make(d.appendingPathComponent("v.mp4"), size: "1080x1920", rate: 30, seconds: 3)
        try make(d.appendingPathComponent("h.mp4"), size: "1280x720", rate: 30, seconds: 3)
        let reels = try XCTUnwrap(Doctor.deliveryProfiles.first { $0.name == "Instagram Reels" })

        let good = Doctor.checkDelivery(try Doctor.probeMedia(d.appendingPathComponent("v.mp4")), spec: reels)
        XCTAssertTrue(good.allSatisfy(\.ok), "\(good.filter { !$0.ok }.map(\.detail))")

        let bad = results(Doctor.checkDelivery(try Doctor.probeMedia(d.appendingPathComponent("h.mp4")), spec: reels))
        XCTAssertEqual(bad["Orientamento"], false)
        XCTAssertEqual(bad["Risoluzione minima"], false)
        XCTAssertEqual(bad["Codec video"], true)
    }

    func testRealFrameRateAndAudioAreCheckedNotTheName() throws {
        try XCTSkipUnless(Doctor.ffprobePath != nil && FileManager.default.isExecutableFile(atPath: "/usr/local/bin/ffmpeg"))
        let d = try dir()
        try make(d.appendingPathComponent("spot.mov"), size: "1920x1080", rate: 29, seconds: 2)
        let adv = try XCTUnwrap(Doctor.deliveryProfiles.first { $0.name == "ADV 1080p" })
        let r = results(Doctor.checkDelivery(try Doctor.probeMedia(d.appendingPathComponent("spot.mov")), spec: adv))
        XCTAssertEqual(r["Risoluzione"], true)
        XCTAssertEqual(r["Frame rate"], false)     // 29 fps is not allowed
        XCTAssertEqual(r["Canali audio"], true)
        XCTAssertEqual(r["Frequenza audio"], true)
        XCTAssertEqual(r["Codec video"], true)
    }

    func testTechnicalAnomalies() throws {
        try XCTSkipUnless(Doctor.ffprobePath != nil && FileManager.default.isExecutableFile(atPath: "/usr/local/bin/ffmpeg"))
        let d = try dir()
        try make(d.appendingPathComponent("liar.mp4"), size: "640x360", rate: 25, seconds: 2, format: "matroska")  // mkv inside a .mp4 name
        try make(d.appendingPathComponent("short-audio.mp4"), size: "640x360", rate: 25, seconds: 4, audioSeconds: 1)
        try make(d.appendingPathComponent("odd.mp4"), size: "642x362", rate: 25, seconds: 1)
        let liar = Doctor.technicalAnomalies(try Doctor.probeMedia(d.appendingPathComponent("liar.mp4")))
        XCTAssertTrue(liar.contains { $0.contains("contenitore reale è matroska") }, "\(liar)")
        let short = Doctor.technicalAnomalies(try Doctor.probeMedia(d.appendingPathComponent("short-audio.mp4")))
        XCTAssertTrue(short.contains { $0.contains("durate diverse") }, "\(short)")
        XCTAssertEqual(Doctor.technicalAnomalies(try Doctor.probeMedia(d.appendingPathComponent("odd.mp4"))), [])
    }

    func testCustomSpecsRoundTripAndAudioIsMandatoryByDefault() throws {
        var spec = DeliverySpec(name: "Cliente X")
        spec.exactSizes = ["1280x720"]
        spec.maxDuration = 30
        let file = try dir().appendingPathComponent("specs.json")
        Doctor.saveCustomSpecs([spec], at: file)
        XCTAssertEqual(Doctor.loadCustomSpecs(at: file), [spec])
        XCTAssertEqual(Doctor.loadCustomSpecs(at: file.deletingLastPathComponent().appendingPathComponent("none.json")), [])

        let silent = MediaInfo(url: URL(fileURLWithPath: "/x.mp4"), size: 1, container: "mov,mp4", duration: 10, bitrate: 1_000_000,
                               video: VideoStream(codec: "h264", profile: "", width: 1280, height: 720, rotation: 0, fps: 25, isVFR: false,
                                                  bitDepth: 8, chroma: "4:2:0", pixFmt: "yuv420p", colorSpace: "", transfer: "", primaries: "", bitrate: 1_000_000),
                               audio: [], tags: [:])
        let r = results(Doctor.checkDelivery(silent, spec: spec))
        XCTAssertEqual(r["Audio"], false)
        XCTAssertEqual(r["Risoluzione"], true)
        XCTAssertEqual(r["Durata massima"], true)
    }

    func testAudioLevelsMeasureKnownSignalAndFindSilence() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/local/bin/ffmpeg"))
        let wav = try dir().appendingPathComponent("t.wav")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
        p.arguments = ["-v", "error", "-y", "-f", "lavfi", "-i", "sine=f=1000:d=3,volume=-20dB",
                       "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono:d=2", "-f", "lavfi", "-i", "sine=f=1000:d=3,volume=-20dB",
                       "-filter_complex", "[0][1][2]concat=n=3:v=0:a=1", "-ar", "44100", wav.path]
        try p.run(); p.waitUntilExit()
        let a = try Doctor.audioLevels(of: wav)
        XCTAssertEqual(try XCTUnwrap(a.truePeak), -38.1, accuracy: 0.6)  // sine at -18 dBFS minus 20 dB
        XCTAssertEqual(a.silences.count, 1)
        XCTAssertEqual(a.silences[0].start, 3, accuracy: 0.2)
        XCTAssertEqual(a.silences[0].duration, 2, accuracy: 0.2)
        let advice = Doctor.audioAdvice(a, duration: 8)
        XCTAssertEqual(results(advice)["Volume"], false)  // far too quiet
        XCTAssertEqual(results(advice)["Silenzio"], false)
    }

    func testAudioAdviceVerdicts() {
        let good = Doctor.audioAdvice(AudioLevels(lufs: -14, truePeak: -3, range: 5), duration: 30)
        XCTAssertEqual(good.map(\.ok), [true])
        let loud = Doctor.audioAdvice(AudioLevels(lufs: -7, truePeak: 0.5, range: 2), duration: 30)
        XCTAssertEqual(loud.map(\.ok), [false, false])
        let ends = Doctor.audioAdvice(AudioLevels(lufs: -14, truePeak: -3, range: 5,
                                                  silences: [Silence(start: 0, duration: 2), Silence(start: 28.5, duration: 1.5)]), duration: 30)
        XCTAssertEqual(ends.filter { $0.label == "Silenzio" }.count, 2)
        XCTAssertFalse(Doctor.audioAdvice(AudioLevels(lufs: nil), duration: 5)[0].ok)
    }

    // MARK: - Convert tools

    private func ffmpegOK() throws {
        try XCTSkipUnless(Doctor.ffprobePath != nil && FileManager.default.isExecutableFile(atPath: "/usr/local/bin/ffmpeg"))
    }

    func testStandardFPSSnapsToBroadcastRates() {
        XCTAssertEqual(Doctor.standardFPS(29.8), "30000/1001")
        XCTAssertEqual(Doctor.standardFPS(59.94), "60000/1001")
        XCTAssertEqual(Doctor.standardFPS(24), "24")
        XCTAssertEqual(Doctor.standardFPS(15), "15")
    }

    func testPrepareMakesConstantFrameRateMP4AndNeverOverwrites() throws {
        try ffmpegOK()
        let d = try dir()
        let src = d.appendingPathComponent("clip.mov")
        try make(src, size: "640x360", rate: 25, seconds: 2, format: "mov")
        let r = Doctor.convert(src, tool: .prepare)
        XCTAssertTrue(r.ok, r.problems.joined())
        let out = try XCTUnwrap(r.output)
        XCTAssertEqual(out.lastPathComponent, "clip_pronto.mp4")
        let info = try Doctor.probeMedia(out)
        XCTAssertEqual(info.video?.codec, "h264")
        XCTAssertEqual(info.video?.fps ?? 0, 25, accuracy: 0.01)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))  // original untouched
        let again = Doctor.convert(src, tool: .prepare)
        XCTAssertEqual(again.output?.lastPathComponent, "clip_pronto 2.mp4")
    }

    func testAudioConvertAndStill() throws {
        try ffmpegOK()
        let d = try dir()
        let src = d.appendingPathComponent("v.mp4")
        try make(src, size: "320x180", rate: 25, seconds: 3)
        var o = ConvertOptions(); o.audioFormat = .mp3
        let mp3 = Doctor.convert(src, tool: .audio, options: o)
        XCTAssertTrue(mp3.ok, mp3.problems.joined())
        XCTAssertEqual(try Doctor.probeMedia(try XCTUnwrap(mp3.output)).audio.first?.codec, "mp3")
        o.audioFormat = .wav
        XCTAssertEqual(Doctor.convert(src, tool: .audio, options: o).output?.pathExtension, "wav")
        let still = Doctor.convert(src, tool: .still)
        XCTAssertTrue(still.ok, still.problems.joined())
        XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: try XCTUnwrap(still.output).path)[.size] as? Int) ?? 0, 0)
        // a tool that needs video refuses audio-only input
        XCTAssertFalse(Doctor.convert(try XCTUnwrap(mp3.output), tool: .prepare).ok)
    }

    func testNormalizeBringsQuietAudioNearMinus14() throws {
        try ffmpegOK()
        let d = try dir()
        let src = d.appendingPathComponent("quiet.wav")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
        p.arguments = ["-v", "error", "-y", "-f", "lavfi", "-i", "sine=f=300:d=6,volume=-12dB,tremolo=f=2:d=0.3", src.path]
        try p.run(); p.waitUntilExit()
        let before = try Doctor.audioLevels(of: src)
        XCTAssertLessThan(try XCTUnwrap(before.lufs), -25)
        let r = Doctor.convert(src, tool: .normalize)
        XCTAssertTrue(r.ok, r.problems.joined())
        let after = try Doctor.audioLevels(of: try XCTUnwrap(r.output))
        XCTAssertEqual(try XCTUnwrap(after.lufs), -14, accuracy: 1.5)
    }

    func testCompressStaysUnderTarget() throws {
        try ffmpegOK()
        let d = try dir()
        let src = d.appendingPathComponent("big.mp4")
        try make(src, size: "1280x720", rate: 30, seconds: 8)
        var o = ConvertOptions(); o.targetMB = 1
        let r = Doctor.convert(src, tool: .compress, options: o)
        XCTAssertTrue(r.ok, r.problems.joined())
        let size = try FileManager.default.attributesOfItem(atPath: try XCTUnwrap(r.output).path)[.size] as? Int ?? 0
        XCTAssertLessThan(size, 1_100_000)
    }

    func testConvertCanBeStoppedAndReportsProgress() throws {
        try ffmpegOK()
        let d = try dir()
        let src = d.appendingPathComponent("long.mp4")
        try make(src, size: "1280x720", rate: 30, seconds: 60)
        let control = ProxyControl()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { control.cancel() }
        let started = Date()
        let r = Doctor.convert(src, tool: .prepare, control: control)
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)  // stopped, not run to the end
        XCTAssertNil(r.output)
        XCTAssertEqual(r.problems, ["Interrotto."])
        XCTAssertFalse(FileManager.default.fileExists(atPath: d.appendingPathComponent("long_pronto.mp4").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))

        let short = d.appendingPathComponent("short.mp4")
        try make(short, size: "320x180", rate: 25, seconds: 2)
        let seen = LockedDoubles()
        let ok = Doctor.convert(short, tool: .prepare) { seen.add($0) }
        XCTAssertTrue(ok.ok, ok.problems.joined())
        XCTAssertGreaterThan(seen.max, 0.5)
    }

    // MARK: - Download from link

    func testLinkCleaningAndArguments() {
        XCTAssertNotNil(Doctor.cleanLink("  https://www.youtube.com/watch?v=abc \n"))
        XCTAssertNil(Doctor.cleanLink("ciao"))
        XCTAssertNil(Doctor.cleanLink("file:///etc/passwd"))
        XCTAssertNil(Doctor.cleanLink("javascript:alert(1)"))
        let url = URL(string: "https://example.com/v")!
        let v = Doctor.downloadArguments(link: url, kind: .video, outputDir: URL(fileURLWithPath: "/tmp"), ffmpegDir: "/usr/local/bin")
        XCTAssertTrue(v.contains { $0.contains("avc1") })  // H.264 first, Final Cut cannot open VP9/AV1
        XCTAssertTrue(v.contains("--no-playlist") && v.contains("--no-overwrites"))
        let a = Doctor.downloadArguments(link: url, kind: .audio(.aac), outputDir: URL(fileURLWithPath: "/tmp"), ffmpegDir: "/usr/local/bin")
        XCTAssertEqual(a[a.firstIndex(of: "--audio-format")! + 1], "m4a")
        XCTAssertTrue(Doctor.downloadProblem("ERROR: Sign in to confirm").contains("accedere"))
        XCTAssertTrue(Doctor.downloadProblem("ERROR: Video unavailable").contains("non disponibile"))
        XCTAssertFalse(Doctor.download("ciao", kind: .video, outputDir: FileManager.default.temporaryDirectory).ok)
    }

    /// Real run of yt-dlp against a local web server that serves a generated clip: no third-party site is contacted.
    func testDownloadFromLocalLinkVideoAndAudio() throws {
        try ffmpegOK()
        let found = ProcessInfo.processInfo.environment["FCP_TEST_YTDLP"] ?? Doctor.ytdlpPath
        try XCTSkipIf(found == nil, "yt-dlp not installed")
        let yt = found!
        let served = try dir()
        try make(served.appendingPathComponent("clip.mp4"), size: "320x180", rate: 25, seconds: 2)
        let port = Int.random(in: 20000...50000)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/local/bin/python3")
        server.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1"]
        server.currentDirectoryURL = served
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate() }
        Thread.sleep(forTimeInterval: 1.5)
        let link = "http://localhost:\(port)/clip.mp4"
        let out = try dir()
        let video = Doctor.download(link, kind: .video, outputDir: out, ytdlp: yt)
        XCTAssertTrue(video.ok, video.problems.joined())
        XCTAssertEqual(video.output?.pathExtension, "mp4")
        XCTAssertEqual(try Doctor.probeMedia(try XCTUnwrap(video.output)).video?.codec, "h264")
        let audio = Doctor.download(link, kind: .audio(.mp3), outputDir: out, ytdlp: yt)
        XCTAssertTrue(audio.ok, audio.problems.joined())
        XCTAssertEqual(try Doctor.probeMedia(try XCTUnwrap(audio.output)).audio.first?.codec, "mp3")
        // the same link again makes a new numbered file: the first one is never touched or deleted
        let again = Doctor.download(link, kind: .video, outputDir: out, ytdlp: yt)
        XCTAssertTrue(again.ok, again.problems.joined())
        XCTAssertNotEqual(again.output, video.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(video.output).path))
    }
}

private final class LockedDoubles: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ v: Double) { lock.lock(); values.append(v); lock.unlock() }
    var max: Double { lock.lock(); defer { lock.unlock() }; return values.max() ?? 0 }
}
