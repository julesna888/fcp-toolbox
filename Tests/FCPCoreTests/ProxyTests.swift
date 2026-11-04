import XCTest
@testable import FCPCore

final class ProxyTests: XCTestCase {
    private var tools: Bool { Doctor.ffprobePath != nil && FileManager.default.isExecutableFile(atPath: "/usr/local/bin/ffmpeg") }

    private func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("px-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func clip(_ d: URL, _ name: String, size: String, seconds: Int) throws -> URL {
        let u = d.appendingPathComponent(name)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
        p.arguments = ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=duration=\(seconds):size=\(size):rate=25", "-f", "lavfi",
                       "-i", "sine=duration=\(seconds)", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", u.path]
        try p.run()
        p.waitUntilExit()
        return u
    }

    func testProResProxyIsCreatedVerifiedAndNeverOverwritten() throws {
        try XCTSkipUnless(tools)
        let d = try dir()
        let src = try clip(d, "A001.mp4", size: "1920x1080", seconds: 3)
        let before = try Data(contentsOf: src)
        let opts = ProxyOptions(codec: .proresProxy, height: 540, destination: d.appendingPathComponent("Proxy"))

        let r = Doctor.makeProxy(src, options: opts)
        XCTAssertEqual(r.problems, [])
        XCTAssertTrue(r.verified)
        XCTAssertFalse(r.fcpLinkVerified)
        XCTAssertEqual(r.output?.lastPathComponent, "A001_proxy.mov")
        let o = try Doctor.probeMedia(try XCTUnwrap(r.output))
        XCTAssertEqual(o.video?.codec, "prores")
        XCTAssertEqual(o.video?.displayHeight, 540)
        XCTAssertEqual(o.audio.count, 1)
        XCTAssertEqual(try Data(contentsOf: src), before)  // the original is untouched
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: opts.destination.path)
        XCTAssertEqual(leftovers, ["A001_proxy.mov"])

        let again = Doctor.makeProxy(src, options: opts)
        XCTAssertNil(again.output)
        XCTAssertTrue(again.problems.joined().contains("esiste già"))
    }

    func testSmallClipsAreNotEnlargedAndH264Works() throws {
        try XCTSkipUnless(tools)
        let d = try dir()
        let src = try clip(d, "small.mp4", size: "640x360", seconds: 2)
        let r = Doctor.makeProxy(src, options: ProxyOptions(codec: .h264, height: 540, crf: 28, destination: d.appendingPathComponent("P")))
        XCTAssertTrue(r.verified, "\(r.problems)")
        XCTAssertEqual(try Doctor.probeMedia(try XCTUnwrap(r.output)).video?.displayHeight, 360)
        XCTAssertEqual(r.output?.pathExtension, "mp4")
    }

    func testBatchReportsEachFileAndProgress() throws {
        try XCTSkipUnless(tools)
        let d = try dir()
        let a = try clip(d, "a.mp4", size: "640x360", seconds: 1), b = try clip(d, "b.mp4", size: "640x360", seconds: 1)
        let broken = d.appendingPathComponent("broken.mp4")
        try Data("x".utf8).write(to: broken)
        let seen = NSMutableSet()
        let results = Doctor.makeProxies([a, broken, b], options: ProxyOptions(codec: .h264, height: 360, destination: d.appendingPathComponent("P"))) { i, f in
            if f >= 1 { seen.add(i) }
        }
        XCTAssertEqual(results.map(\.verified), [true, false, true])
        XCTAssertEqual(Set(seen.allObjects as! [Int]), [0, 2])
    }

    func testPauseResumeAndCancel() throws {
        try XCTSkipUnless(tools)
        let d = try dir()
        let src = try clip(d, "long.mp4", size: "1920x1080", seconds: 15)
        let opts = ProxyOptions(codec: .proresProxy, height: 720, destination: d.appendingPathComponent("P"))

        func state(_ pid: Int32) -> String {
            Doctor.capture("/bin/ps", ["-o", "stat=", "-p", "\(pid)"]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func start(_ control: ProxyControl) -> (DispatchSemaphore, () -> ProxyResult?) {
            let done = DispatchSemaphore(value: 0)
            var result: ProxyResult?
            DispatchQueue.global().async { result = Doctor.makeProxy(src, options: opts, control: control); done.signal() }
            return (done, { result })
        }
        func waitForProcess(_ c: ProxyControl) -> Int32? {
            for _ in 0..<100 { if let p = c.pid { return p }; Thread.sleep(forTimeInterval: 0.05) }
            return nil
        }

        let c1 = ProxyControl()
        let (done1, res1) = start(c1)
        let pid = try XCTUnwrap(waitForProcess(c1))
        Thread.sleep(forTimeInterval: 0.3)
        c1.pause()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(state(pid).contains("T"), "stato dopo pausa: \(state(pid))")
        c1.resume()
        XCTAssertEqual(done1.wait(timeout: .now() + 120), .success)
        XCTAssertTrue(try XCTUnwrap(res1()).verified)

        let c2 = ProxyControl()
        let opts2 = ProxyOptions(codec: .proresProxy, height: 540, destination: d.appendingPathComponent("Q"))
        let done2 = DispatchSemaphore(value: 0)
        var res2: ProxyResult?
        DispatchQueue.global().async { res2 = Doctor.makeProxy(src, options: opts2, control: c2); done2.signal() }
        _ = try XCTUnwrap(waitForProcess(c2))
        c2.pause()
        c2.cancel()
        XCTAssertEqual(done2.wait(timeout: .now() + 30), .success)
        XCTAssertEqual(res2?.problems, ["Annullato."])
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: opts2.destination.path)) ?? [], [])  // no partial file left
    }
}
