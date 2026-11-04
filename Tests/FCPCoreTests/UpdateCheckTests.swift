import XCTest
@testable import FCPCore

final class UpdateCheckTests: XCTestCase {
    func testVersionComparisonIsNumeric() {
        XCTAssertTrue(UpdateCheck.isNewer("0.13.10", than: "0.13.9"))
        XCTAssertTrue(UpdateCheck.isNewer("1.0", than: "0.99.9"))
        XCTAssertFalse(UpdateCheck.isNewer("0.13.5", than: "0.13.5"))
        XCTAssertFalse(UpdateCheck.isNewer("0.13.4", than: "0.13.5"))
    }

    func testParsesAGitHubRelease() {
        let json = #"{"tag_name":"v0.14.0","html_url":"https://github.com/julesna888/fcp-toolbox/releases/tag/v0.14.0"}"#
        let r = UpdateCheck.parse(Data(json.utf8))
        XCTAssertEqual(r?.version, "0.14.0")
        XCTAssertEqual(r?.page.host, "github.com")
    }

    func testRefusesAnythingNotOnGitHub() {
        XCTAssertNil(UpdateCheck.parse(Data(#"{"tag_name":"v9","html_url":"https://evil.example/x"}"#.utf8)))
        XCTAssertNil(UpdateCheck.parse(Data("not json".utf8)))
    }
}
