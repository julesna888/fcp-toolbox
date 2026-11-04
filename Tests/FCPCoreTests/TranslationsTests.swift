import XCTest
@testable import FCPCore

final class TranslationsTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    override func tearDown() { UserDefaults.standard.removeObject(forKey: Lang.key) }

    func testEnglishIsUsedOnlyWhenChosen() {
        Lang.current = .it
        XCTAssertEqual(Lang.tr("Libera spazio"), "Libera spazio")
        Lang.current = .en
        XCTAssertEqual(Lang.tr("Libera spazio"), "Free up space")
        XCTAssertEqual(Lang.tr("Frase mai tradotta"), "Frase mai tradotta", "missing entry falls back to Italian")
    }

    func testNoEmptyOrUnchangedTranslation() {
        for (it, en) in Translations.en {
            XCTAssertFalse(en.trimmingCharacters(in: .whitespaces).isEmpty, it)
            if it != "Media" { XCTAssertNotEqual(it, en, "same text, no need for an entry") }
        }
    }

    func testEveryConversionIsTranslated() {
        for t in ConvertTool.allCases {
            XCTAssertNotNil(Translations.en[t.title], t.title)
            XCTAssertNotNil(Translations.en[t.summary], t.summary)
        }
    }

    /// The tools of the app target are not importable here, so read their names from the source.
    func testEverySidebarPageAndToolCardIsTranslated() throws {
        func quoted(_ file: String, from: String, to: String) throws -> [String] {
            let s = try String(contentsOf: root.appendingPathComponent(file))
            let a = try XCTUnwrap(s.range(of: from)), b = try XCTUnwrap(s.range(of: to, range: a.upperBound..<s.endIndex))
            return s[a.upperBound..<b.lowerBound].components(separatedBy: "\"").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        }
        let pages = try quoted("Sources/FCPToolbox/ContentView.swift", from: "enum Tool: String", to: "var ")
        let groups = try quoted("Sources/FCPToolbox/ContentView.swift", from: "enum ToolGroup", to: "var id")
        let extras = try quoted("Sources/FCPToolbox/ToolsView.swift", from: "enum Extra: String", to: "var id")
        let summaries = try quoted("Sources/FCPToolbox/ToolsView.swift", from: "var summary: String", to: "@EnvironmentObject")
        XCTAssertGreaterThan(pages.count, 10); XCTAssertEqual(extras.count, 14)
        for k in pages + groups + extras + summaries where !k.isEmpty { XCTAssertNotNil(Translations.en[k], k) }
    }
}
