import XCTest
@testable import FCPCore

final class AspectRatioTests: XCTestCase {
    func testSimplifiedRatioNamesCommonFormats() {
        XCTAssertEqual(Doctor.simplifiedRatio(width: 1920, height: 1080), "16:9")
        XCTAssertEqual(Doctor.simplifiedRatio(width: 1080, height: 1920), "9:16")
        XCTAssertEqual(Doctor.simplifiedRatio(width: 1080, height: 1350), "4:5")
        XCTAssertEqual(Doctor.simplifiedRatio(width: 1080, height: 1080), "1:1")
        XCTAssertEqual(Doctor.simplifiedRatio(width: 2048, height: 858), "2.39:1")
        XCTAssertEqual(Doctor.simplifiedRatio(width: 1000, height: 700), "10:7")
    }

    func testSizeKeepsRatioWithEvenNumbers() throws {
        let r16 = try XCTUnwrap(Doctor.ratioPresets.first { $0.name == "16:9" }).value
        let r916 = try XCTUnwrap(Doctor.ratioPresets.first { $0.name == "9:16" }).value
        XCTAssertEqual(Doctor.size(ratio: r16, width: 1920)?.height, 1080)
        XCTAssertEqual(Doctor.size(ratio: r916, width: 1080)?.height, 1920)
        XCTAssertEqual(Doctor.size(ratio: 1, height: 1080)?.width, 1080)
        let odd = try XCTUnwrap(Doctor.size(ratio: r16, width: 1001))
        XCTAssertEqual(odd.width % 2, 0)
        XCTAssertEqual(odd.height % 2, 0)
        XCTAssertNil(Doctor.size(ratio: 1))
    }

    func testReframeCropAndFitNeverStretch() throws {
        let a = try XCTUnwrap(Doctor.reframe(width: 1920, height: 1080, to: 9.0 / 16))
        XCTAssertEqual(a.fillWidth, 608)
        XCTAssertEqual(a.fillHeight, 1080)
        XCTAssertEqual(a.cropX, (1920 - 608) / 2)
        XCTAssertEqual(a.cropY, 0)
        XCTAssertEqual(a.cutShare, 1 - 608.0 / 1920, accuracy: 0.001)
        XCTAssertEqual(a.fitWidth, 1920)
        XCTAssertEqual(a.fitHeight, 3414)

        let b = try XCTUnwrap(Doctor.reframe(width: 1920, height: 1080, to: 4.0 / 5))
        XCTAssertEqual(b.fillWidth, 864)
        XCTAssertEqual(b.fillHeight, 1080)

        let c = try XCTUnwrap(Doctor.reframe(width: 1920, height: 1080, to: 2.39))
        XCTAssertEqual(c.fillWidth, 1920)
        XCTAssertTrue((802...806).contains(c.fillHeight))

        let same = try XCTUnwrap(Doctor.reframe(width: 1920, height: 1080, to: 16.0 / 9))
        XCTAssertEqual(same.cutShare, 0, accuracy: 0.001)
        XCTAssertNil(Doctor.reframe(width: 0, height: 1080, to: 1))
    }
}
