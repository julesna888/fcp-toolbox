import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import FCPCore

final class MetadataTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("md-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func photoWithGPS() throws -> URL {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let url = dir.appendingPathComponent("foto.jpg")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let props: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 45.0, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 9.0, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "ACME", kCGImagePropertyTIFFModel: "Cam 1"],
        ]
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func props(_ url: URL) throws -> [CFString: Any] {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
    }

    func testPhotoLocationOnlyKeepsTheCameraName() throws {
        let src = try photoWithGPS()
        XCTAssertNotNil(try props(src)[kCGImagePropertyGPSDictionary])
        let r = Doctor.cleanMetadata(src, remove: [.location])
        let out = try XCTUnwrap(r.output, r.problem ?? "")
        XCTAssertNil(try props(out)[kCGImagePropertyGPSDictionary])
        let tiff = try XCTUnwrap(try props(out)[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        XCTAssertEqual(tiff[kCGImagePropertyTIFFMake] as? String, "ACME")
        XCTAssertNotNil(try props(src)[kCGImagePropertyGPSDictionary], "l'originale non cambia")
        XCTAssertEqual(out.lastPathComponent, "foto pulito.jpg")
    }

    func testPhotoDeviceAndEverything() throws {
        let src = try photoWithGPS()
        let dev = try XCTUnwrap(Doctor.cleanMetadata(src, remove: [.device]).output)
        let tiff = try props(dev)[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertNil(tiff?[kCGImagePropertyTIFFMake])
        XCTAssertNotNil(try props(dev)[kCGImagePropertyGPSDictionary], "la posizione resta se non la scegli")
        let all = try XCTUnwrap(Doctor.cleanMetadata(src, remove: [.everything]).output)
        XCTAssertNil(try props(all)[kCGImagePropertyGPSDictionary])
        XCTAssertNil((try props(all)[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel])
        XCTAssertNotEqual(all, dev, "mai sovrascrivere")
        XCTAssertNotNil(Doctor.cleanMetadata(src, remove: []).problem)
    }

    func testVideoTextOnlyAndEverything() throws {
        let ffmpeg = try XCTUnwrap(Doctor.ffmpegPath, "ffmpeg non installato")
        let src = dir.appendingPathComponent("v.mp4")
        let r = Doctor.run(ffmpeg, ["-loglevel", "error", "-f", "lavfi", "-i", "testsrc=d=1:s=160x120:r=25", "-pix_fmt", "yuv420p",
                                    "-metadata", "title=Segreto", "-metadata", "comment=nota", "-metadata", "creation_time=2020-01-02T03:04:05Z", src.path])
        try XCTSkipIf(r.status != 0, r.out)
        XCTAssertEqual(try Doctor.probeMedia(src).tags["title"], "Segreto")
        let text = Doctor.cleanMetadata(src, remove: [.text])
        let a = try XCTUnwrap(text.output, text.problem ?? "")
        let tagsA = try Doctor.probeMedia(a).tags
        XCTAssertNil(tagsA["title"])
        XCTAssertNil(tagsA["comment"])
        XCTAssertNotNil(tagsA["creation_time"], "le date restano se non le scegli")
        let all = Doctor.cleanMetadata(src, remove: [.everything])
        let b = try XCTUnwrap(all.output, all.problem ?? "")
        let tagsB = try Doctor.probeMedia(b).tags
        XCTAssertNil(tagsB["title"])
        XCTAssertNil(tagsB["creation_time"])
        XCTAssertEqual(try Doctor.probeMedia(b).duration, 1, accuracy: 0.2)
        XCTAssertEqual(try Doctor.probeMedia(src).tags["title"], "Segreto", "l'originale non cambia")
    }

    func testKeyGroups() {
        let tags = ["title": "a", "creation_time": "b", "com.apple.quicktime.location.ISO6709": "c", "encoder": "d", "other": "e"]
        XCTAssertEqual(Doctor.metadataKeys(tags, matching: [.location]), ["com.apple.quicktime.location.ISO6709"])
        XCTAssertEqual(Set(Doctor.metadataKeys(tags, matching: [.everything])), Set(tags.keys))
        XCTAssertEqual(Doctor.metadataKeys(tags, matching: [.device]), ["encoder"])
    }
}
