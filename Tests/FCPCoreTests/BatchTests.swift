import XCTest
@testable import FCPCore

final class BatchTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fcp-batchtest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func needFFmpeg() throws { try XCTSkipIf(Doctor.ffmpegPath == nil || Doctor.ffprobePath == nil, "ffmpeg non installato") }

    /// 640x360, blue sides with a wide green stripe in the middle, with a sine tone.
    private func makeClip(_ name: String, seconds: Int = 3) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Doctor.ffmpegPath!)
        p.arguments = ["-v", "error", "-y", "-f", "lavfi", "-i", "color=c=blue:s=640x360:r=25:d=\(seconds),drawbox=x=190:y=0:w=260:h=360:color=green:t=fill",
                       "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", url.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        return url
    }

    /// Colour of the pixel at (x, y) of the first frame.
    private func pixel(_ url: URL, _ x: Int, _ y: Int) throws -> (r: Int, g: Int, b: Int) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Doctor.ffmpegPath!)
        p.arguments = ["-v", "error", "-i", url.path, "-frames:v", "1", "-vf", "crop=2:2:\(x):\(y),scale=1:1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
        let out = Pipe(); p.standardOutput = out
        try p.run()
        let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        XCTAssertEqual(d.count, 3)
        return (Int(d[0]), Int(d[1]), Int(d[2]))
    }

    private func size(_ url: URL) throws -> (Int, Int) {
        let v = try XCTUnwrap(Doctor.probeMedia(url).video)
        return (v.width, v.height)
    }

    // MARK: resize

    func testFillGives1080x1920AndKeepsTheCentre() throws {
        try needFFmpeg()
        let clip = try makeClip("a.mp4")
        let r = Doctor.resize(clip, width: 1080, height: 1920, fit: false, outputDir: tmp)
        let out = try XCTUnwrap(r.output, r.problems.joined())
        let s = try size(out)
        XCTAssertEqual(s.0, 1080); XCTAssertEqual(s.1, 1920)
        // Cropped from the centre: the blue sides of the source are gone, the whole frame is the green stripe.
        for (x, y) in [(2, 960), (1076, 960), (540, 4), (540, 1914)] {
            let c = try pixel(out, x, y)
            XCTAssertTrue(c.g > 120 && c.r < 90 && c.b < 90, "pixel \(x),\(y) = \(c)")
        }
    }

    func testFitKeepsWholePictureWithBars() throws {
        try needFFmpeg()
        let clip = try makeClip("b.mp4")
        let out = try XCTUnwrap(Doctor.resize(clip, width: 1080, height: 1920, fit: true, outputDir: tmp).output)
        let s = try size(out)
        XCTAssertEqual(s.0, 1080); XCTAssertEqual(s.1, 1920)
        let bar = try pixel(out, 540, 4), left = try pixel(out, 2, 960), mid = try pixel(out, 540, 960)
        XCTAssertTrue(bar.r < 40 && bar.g < 40 && bar.b < 40, "bar \(bar)")
        XCTAssertTrue(left.b > 120 && left.g < 90, "left edge shows the blue side: \(left)")
        XCTAssertTrue(mid.g > 120 && mid.b < 90, "centre \(mid)")
    }

    func testOddSizesBecomeEven() throws {
        try needFFmpeg()
        let clip = try makeClip("c.mp4", seconds: 1)
        let out = try XCTUnwrap(Doctor.resize(clip, width: 541, height: 961, fit: false, outputDir: tmp).output)
        let s = try size(out)
        XCTAssertEqual(s.0 % 2, 0); XCTAssertEqual(s.1 % 2, 0)
    }

    // MARK: pipeline

    func testThreeStepPipelineMakesOneFileAndCleansTheWorkFolder() throws {
        try needFFmpeg()
        let clip = try makeClip("clip.mp4")
        let before = try Data(contentsOf: clip)
        let work = tmp.appendingPathComponent("work"), outDir = tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let steps: [Step] = [Step(.prepare), .resize(1080, 1920), Step(.normalize), .rename("{name} reel")]
        let r1 = Doctor.runPipeline(clip, steps: steps, outputDir: outDir, workRoot: work)
        let o1 = try XCTUnwrap(r1.output, r1.problems.joined())
        XCTAssertEqual(o1.lastPathComponent, "clip reel.mp4")
        let s = try size(o1)
        XCTAssertEqual(s.0, 1080); XCTAssertEqual(s.1, 1920)
        XCTAssertFalse(try Doctor.probeMedia(o1).audio.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [], "work folder cleaned")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outDir.path), ["clip reel.mp4"], "only the final file")
        XCTAssertEqual(try Data(contentsOf: clip), before, "original untouched")
        // Second run: never overwrites.
        let o2 = try XCTUnwrap(Doctor.runPipeline(clip, steps: steps, outputDir: outDir, workRoot: work).output)
        XCTAssertEqual(o2.lastPathComponent, "clip reel 2.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: o1.path))
    }

    func testFailedStepLeavesNothingBehind() throws {
        try needFFmpeg()
        let bad = tmp.appendingPathComponent("bad.mp4")
        try Data("not a video".utf8).write(to: bad)
        let work = tmp.appendingPathComponent("work"), outDir = tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let r = Doctor.runPipeline(bad, steps: [Step(.prepare)], outputDir: outDir, workRoot: work)
        XCTAssertNil(r.output)
        XCTAssertFalse(r.problems.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
        let left = (try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? []
        XCTAssertEqual(left, [])
    }

    func testRenameOnlyCopiesTheOriginal() throws {
        let f = tmp.appendingPathComponent("doc.txt")
        try Data("x".utf8).write(to: f)
        let out = try XCTUnwrap(Doctor.runPipeline(f, steps: [.rename("{name}-{n:3}")], workRoot: tmp).output)
        XCTAssertEqual(out.lastPathComponent, "doc-001.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path), "original still there")
    }

    func testCancelStopsQuicklyAndRemovesPartialFiles() throws {
        try needFFmpeg()
        let clip = try makeClip("long.mp4", seconds: 60)
        let work = tmp.appendingPathComponent("work"), outDir = tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let control = ProxyControl()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { control.cancel() }
        let t0 = Date()
        let r = Doctor.runPipeline(clip, steps: [.resize(1080, 1920), Step(.normalize)], outputDir: outDir, workRoot: work, control: control)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 8)
        XCTAssertNil(r.output)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
    }

    // MARK: presets

    func testValidation() {
        XCTAssertNotNil(Doctor.validateSteps([]))
        XCTAssertNotNil(Doctor.validateSteps([.audio(.mp3), .resize(1080, 1920)]))
        XCTAssertNotNil(Doctor.validateSteps([.rename(" ")]))
        XCTAssertNil(Doctor.validateSteps([Step(.prepare), .audio(.wav), .rename("{name}")]))
    }

    func testStarterPresetsAreValid() {
        XCTAssertGreaterThanOrEqual(Doctor.starterPresets.count, 3)
        for p in Doctor.starterPresets {
            XCTAssertTrue(p.isBuiltIn)
            XCTAssertNil(Doctor.validateSteps(p.steps), p.name)
        }
        let insta = Doctor.starterPresets.first { $0.id == "builtin.instagram" }
        XCTAssertEqual(insta?.steps.map(\.kind), [.prepare, .resize, .normalize, .rename])
        XCTAssertEqual(insta?.steps[1].width, 1080)
        XCTAssertEqual(insta?.steps[1].height, 1920)
    }

    func testPresetJSONRoundTripAndCorruptFile() throws {
        let url = tmp.appendingPathComponent("presets.json")
        XCTAssertEqual(Doctor.loadUserPresets(at: url), [])
        var strip = Step(.stripMetadata); strip.metadata = [MetadataKind.location.rawValue, MetadataKind.dates.rawValue]
        let mine = Preset(name: "Mio", steps: [.resize(720, 1280, fit: true), strip, .compress(mb: 8), .audio(.aac), .rename("{n:2} {name}")], outputFolder: "/tmp/x")
        XCTAssertTrue(Doctor.saveUserPresets(Doctor.starterPresets + [mine], at: url))
        let back = Doctor.loadUserPresets(at: url)
        XCTAssertEqual(back, [mine], "built-ins are never written")
        try Data("{broken".utf8).write(to: url)
        XCTAssertEqual(Doctor.loadUserPresets(at: url), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path), "corrupt file kept aside")
    }

    func testNamePattern() {
        let d = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(Doctor.applyNamePattern("{name} reel {n:3}", stem: "a/b", n: 7, date: d), "a-b reel 007")
        XCTAssertTrue(Doctor.applyNamePattern("{date}", stem: "x", n: 1, date: d).hasPrefix("19"))
    }

    // MARK: queue

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = [], _fail = true
        var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
        var fail: Bool { get { lock.lock(); defer { lock.unlock() }; return _fail } set { lock.lock(); _fail = newValue; lock.unlock() } }
        func record(_ s: String) { lock.lock(); _calls.append(s); lock.unlock() }
    }

    @MainActor func testQueueContinuesAfterFailureAndRetryRerunsOnlyFailures() async {
        let box = Box()
        let q = BatchQueue(runner: { item, _, progress in
            box.record(item.file.lastPathComponent)
            progress(0.5)
            if item.file.lastPathComponent.hasPrefix("bad"), box.fail { return ConvertResult(source: item.file, output: nil, problems: ["rotto"]) }
            return ConvertResult(source: item.file, output: item.file, problems: [])
        })
        let files = ["a.mov", "bad1.mov", "b.mov", "bad2.mov", "c.mov"].map { URL(fileURLWithPath: "/x/\($0)") }
        q.add(files, steps: [Step(.prepare)], label: "Prova")
        q.start()
        await q.waitUntilIdle()
        XCTAssertEqual(box.calls.count, 5, "kept going after the first error")
        XCTAssertEqual(q.counts.done, 3); XCTAssertEqual(q.counts.failed, 2)
        XCTAssertFalse(q.isRunning)
        XCTAssertTrue(q.summary.contains("3 riusciti") && q.summary.contains("2 con errore"))

        box.fail = false
        q.retryFailed()
        await q.waitUntilIdle()
        XCTAssertEqual(Array(box.calls.dropFirst(5)), ["bad1.mov", "bad2.mov"], "only the failures ran again")
        XCTAssertEqual(q.counts.done, 5)
    }

    @MainActor func testStopAllKeepsWaitingItemsAndStopCurrentMovesOn() async {
        let q = BatchQueue(runner: { item, control, _ in
            for _ in 0..<200 where !control.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
            return control.isCancelled ? ConvertResult(source: item.file, output: nil, problems: ["Interrotto."])
                                       : ConvertResult(source: item.file, output: item.file, problems: [])
        })
        q.add((1...3).map { URL(fileURLWithPath: "/x/\($0).mov") }, steps: [Step(.prepare)], label: "T")
        q.start()
        try? await Task.sleep(nanoseconds: 200_000_000)
        q.stopCurrent()  // first fails, second starts
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(q.isRunning)
        q.stopAll()
        await q.waitUntilIdle()
        XCTAssertEqual(q.items.map(\.status).map { s -> String in
            switch s { case .failed: return "F"; case .waiting: return "W"; case .done: return "D"; case .running: return "R" } }, ["F", "F", "W"])
        XCTAssertFalse(q.isRunning)
    }

    @MainActor func testRealQueueWithRealFiles() async throws {
        try needFFmpeg()
        let good = try makeClip("g.mp4", seconds: 1)
        let bad = tmp.appendingPathComponent("b.mp4"); try Data("nope".utf8).write(to: bad)
        let q = BatchQueue()
        q.add([bad, good], steps: [.compress(mb: 5)], label: "Reale", outputDir: tmp.appendingPathComponent("out"))
        q.start()
        await q.waitUntilIdle()
        XCTAssertEqual(q.counts.failed, 1); XCTAssertEqual(q.counts.done, 1)
        if case .done(let u) = q.items[1].status { XCTAssertTrue(FileManager.default.fileExists(atPath: u.path)) } else { XCTFail("second should be done") }
    }
}
