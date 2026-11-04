import CoreGraphics
import XCTest
@testable import FCPCore

final class EditorToolsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("et-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testPaletteFindsTheMainColorsWithTheirShare() throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [1, 0, 0, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 75, height: 100))
        ctx.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0, 0, 1, 1])!)
        ctx.fill(CGRect(x: 75, y: 0, width: 25, height: 100))
        let p = Doctor.palette(of: try XCTUnwrap(ctx.makeImage()), count: 4)
        XCTAssertEqual(p.count, 2)
        XCTAssertEqual(p[0].hex, "#FF0000")
        XCTAssertEqual(p[0].share, 0.75, accuracy: 0.05)
        XCTAssertEqual(p[1].hex, "#0000FF")
    }

    func testPaletteOfAVideoFrame() throws {
        let ffmpeg = try XCTUnwrap(Doctor.ffmpegPath, "ffmpeg non installato")
        let v = dir.appendingPathComponent("g.mp4")
        let r = Doctor.run(ffmpeg, ["-loglevel", "error", "-f", "lavfi", "-i", "color=c=0x00FF00:s=160x120:d=1:r=25", "-pix_fmt", "yuv420p", v.path])
        try XCTSkipIf(r.status != 0, r.out)
        let p = Doctor.palette(ofFile: v, at: 0.5)
        let top = try XCTUnwrap(p.first)
        XCTAssertGreaterThan(top.g, 200)
        XCTAssertLessThan(top.r, 60)
        XCTAssertLessThan(top.b, 60)
    }

    func testSafeRectScalesAndStaysInside() throws {
        let tt = try XCTUnwrap(Doctor.safePlatforms.first { $0.name == "TikTok" })
        let full = Doctor.safeRect(tt, width: 1080, height: 1920)
        XCTAssertEqual(full.x, 60)
        XCTAssertEqual(full.y, 130)
        XCTAssertEqual(full.w, 1080 - 60 - 120)
        XCTAssertEqual(full.h, 1920 - 130 - 480)
        let half = Doctor.safeRect(tt, width: 540, height: 960)
        XCTAssertEqual(half.x, full.x / 2)
        XCTAssertEqual(half.h, full.h / 2)
        for p in Doctor.safePlatforms {
            let r = Doctor.safeRect(p, width: 1080, height: 1920)
            XCTAssertTrue(r.w > 0 && r.h > 0 && r.x + r.w <= 1080 && r.y + r.h <= 1920, p.name)
        }
    }

    func testSimilarClipsFindsTheSameFootageUnderAnotherNameAndSize() throws {
        let ffmpeg = try XCTUnwrap(Doctor.ffmpegPath, "ffmpeg non installato")
        func make(_ name: String, _ args: [String]) throws {
            let r = Doctor.run(ffmpeg, ["-loglevel", "error"] + args + ["-pix_fmt", "yuv420p", dir.appendingPathComponent(name).path])
            try XCTSkipIf(r.status != 0, r.out)
        }
        try make("originale.mp4", ["-f", "lavfi", "-i", "testsrc2=d=3:s=320x240:r=25"])
        try make("export_finale_v2.mp4", ["-i", dir.appendingPathComponent("originale.mp4").path, "-vf", "scale=160:120", "-crf", "35"])
        try make("altro.mp4", ["-f", "lavfi", "-i", "mandelbrot=s=320x240:r=25", "-t", "3"])
        let groups = Doctor.similarClips(in: dir)
        XCTAssertEqual(groups.count, 1, "\(groups)")
        XCTAssertEqual(Set(groups[0].map(\.lastPathComponent)), ["originale.mp4", "export_finale_v2.mp4"])
    }
}
