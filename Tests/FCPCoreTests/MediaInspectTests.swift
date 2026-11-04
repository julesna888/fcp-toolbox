import XCTest
@testable import FCPCore

final class MediaInspectTests: XCTestCase {
    private func ffmpeg(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
        p.arguments = ["-v", "error", "-y"] + args
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }

    private func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("mi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testParsesHDRPhoneRotationAndVFRFromFixedJSON() throws {
        let json = """
        {"streams":[
         {"codec_type":"video","codec_name":"hevc","profile":"Main 10","width":3840,"height":2160,"pix_fmt":"yuv420p10le",
          "bits_per_raw_sample":"10","r_frame_rate":"60/1","avg_frame_rate":"2997/100","color_space":"bt2020nc",
          "color_transfer":"arib-std-b67","color_primaries":"bt2020","bit_rate":"60000000",
          "side_data_list":[{"side_data_type":"Display Matrix","rotation":-90}]},
         {"codec_type":"audio","codec_name":"aac","channels":2,"sample_rate":"48000","bit_rate":"128000"},
         {"codec_type":"audio","codec_name":"pcm_s24le","channels":6,"sample_rate":"96000"}],
         "format":{"format_name":"mov,mp4","duration":"12.5","bit_rate":"61000000","tags":{"com.apple.quicktime.model":"iPhone"}}}
        """
        let info = try XCTUnwrap(Doctor.parseProbe(Data(json.utf8), url: URL(fileURLWithPath: "/x.mov"), size: 99))
        let v = try XCTUnwrap(info.video)
        XCTAssertEqual(v.codec, "hevc")
        XCTAssertEqual(v.bitDepth, 10)
        XCTAssertEqual(v.chroma, "4:2:0")
        XCTAssertTrue(v.isHDR)
        XCTAssertTrue(v.isVFR)
        XCTAssertEqual(v.rotation, -90)
        XCTAssertTrue(v.isVertical)
        XCTAssertEqual(v.displayWidth, 2160)
        XCTAssertEqual(info.audio.map(\.channels), [2, 6])
        XCTAssertEqual(info.audio[1].sampleRate, 96000)
        XCTAssertEqual(info.duration, 12.5)
        XCTAssertEqual(info.tags["com.apple.quicktime.model"], "iPhone")
        XCTAssertNil(Doctor.parseProbe(Data("nope".utf8), url: URL(fileURLWithPath: "/x"), size: 0))
    }

    func testRealFilesAndBatchFolder() throws {
        try XCTSkipUnless(Doctor.ffprobePath != nil && FileManager.default.isExecutableFile(atPath: "/usr/local/bin/ffmpeg"))
        let d = try dir()
        try ffmpeg(["-f", "lavfi", "-i", "testsrc=duration=2:size=1280x720:rate=25", "-f", "lavfi", "-i", "sine=duration=2",
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-ac", "2", "-ar", "48000", d.appendingPathComponent("a.mp4").path])
        try ffmpeg(["-f", "lavfi", "-i", "testsrc=duration=1:size=640x1136:rate=30", "-c:v", "libx264", "-pix_fmt", "yuv422p10le",
                    d.appendingPathComponent("sub").path + "-b.mov"])
        try FileManager.default.createDirectory(at: d.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: URL(fileURLWithPath: d.path + "/sub-b.mov"), to: d.appendingPathComponent("sub/b.mov"))
        try Data("not a video".utf8).write(to: d.appendingPathComponent("broken.mov"))

        let a = try Doctor.probeMedia(d.appendingPathComponent("a.mp4"))
        XCTAssertEqual(a.video?.codec, "h264")
        XCTAssertEqual(a.video?.width, 1280)
        XCTAssertEqual(a.video?.fps, 25)
        XCTAssertEqual(a.video?.isVFR, false)
        XCTAssertEqual(a.video?.bitDepth, 8)
        XCTAssertEqual(a.audio.first?.sampleRate, 48000)
        XCTAssertEqual(a.audio.first?.channels, 2)
        XCTAssertEqual(a.duration, 2, accuracy: 0.2)
        XCTAssertGreaterThan(a.size, 1000)

        let (ok, failed) = try Doctor.probeFolder(d)
        XCTAssertEqual(ok.map { $0.url.lastPathComponent }, ["a.mp4", "b.mov"])
        XCTAssertEqual(failed.map(\.lastPathComponent), ["broken.mov"])
        let b = try XCTUnwrap(ok.last?.video)
        XCTAssertTrue(b.isVertical)
        XCTAssertEqual(b.chroma, "4:2:2")
        XCTAssertEqual(b.bitDepth, 10)
    }
}
