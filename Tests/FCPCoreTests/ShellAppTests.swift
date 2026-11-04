import XCTest
@testable import FCPCore
@testable import FCPToolbox

/// Checks that every string in the catalog really exists in the app's screens.
@MainActor final class ShellAppTests: XCTestCase {
    func testEveryCatalogTargetExists() {
        for e in ToolCatalog.all {
            switch e.target {
            case .sidebar(let raw): XCTAssertNotNil(Tool(rawValue: raw), e.id)
            case .extra(let raw): XCTAssertNotNil(ToolsView.Extra(rawValue: raw), e.id)
            case .convert(let raw):
                let t = ConvertTool(rawValue: raw)
                XCTAssertNotNil(t, e.id)
                XCTAssertEqual(t?.title, e.title, "catalog title must match the card title")
            case .inspector(let raw): XCTAssertTrue(["Sottotitoli", "Controllo consegna", "Copie leggere (proxy)", "Info file"].contains(raw), e.id)
            }
            XCTAssertNotNil(Shell.sidebarTool(for: e.id), e.id)
        }
        XCTAssertEqual(Shell.sidebarTool(for: DeepLink.dropID), .tools)
        XCTAssertNil(Shell.sidebarTool(for: "nope"))
    }

    func testExternalOpenRouting() {
        let m = Model()
        let link = DeepLink.make(toolID: "trim", files: [URL(fileURLWithPath: "/tmp/a.mov")])!
        m.handleExternal([link])
        XCTAssertEqual(m.openRequest?.toolID, "trim")
        XCTAssertEqual(m.openRequest?.urls, [URL(fileURLWithPath: "/tmp/a.mov")])
        m.handleExternal([URL(fileURLWithPath: "/tmp/b.srt")])
        XCTAssertEqual(m.openRequest?.toolID, DeepLink.dropID)
        m.handleExternal([URL(string: "fcptoolbox://tool/bogus")!])
        XCTAssertNotNil(m.notice)
    }
}
