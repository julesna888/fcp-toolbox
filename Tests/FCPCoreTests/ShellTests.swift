import XCTest
@testable import FCPCore

final class ShellTests: XCTestCase {
    private func u(_ p: String) -> URL { URL(fileURLWithPath: p) }
    private func ids(_ s: [ToolSuggestion]) -> [String] { s.map(\.entry.id) }

    func testFileKinds() {
        XCTAssertEqual(FileKind.of(u("/x/a.MOV")), .video)
        XCTAssertEqual(FileKind.of(u("/x/a.mxf")), .video)
        XCTAssertEqual(FileKind.of(u("/x/a.wav")), .audio)
        XCTAssertEqual(FileKind.of(u("/x/a.HEIC")), .image)
        XCTAssertEqual(FileKind.of(u("/x/a.srt")), .subtitle)
        XCTAssertEqual(FileKind.of(u("/x/a.vtt")), .subtitle)
        XCTAssertEqual(FileKind.of(u("/x/a.xyz")), .other)
        XCTAssertEqual(FileKind.of(URL(fileURLWithPath: NSTemporaryDirectory())), .folder)
    }

    func testDescribe() {
        XCTAssertEqual(ToolCatalog.describe([u("/a.mov"), u("/b.mp4"), u("/c.jpg"), u("/d.srt")]), "2 video, 1 immagine, 1 sottotitolo")
    }

    func testCatalogIdsUnique() {
        XCTAssertEqual(Set(ToolCatalog.all.map(\.id)).count, ToolCatalog.all.count)
    }

    func testMovSuggestionsOrder() {
        let s = ids(ToolCatalog.suggestions(for: [u("/x/a.mov")]))
        XCTAssertEqual(Array(s.prefix(5)), ["info", "convert.prepare", "convert.audio", "convert.compress", "contact"])
        XCTAssertFalse(s.contains("subtitles"))
        XCTAssertFalse(s.contains("dups"))
    }

    func testSrtOnlyRealOperations() {
        let s = ids(ToolCatalog.suggestions(for: [u("/x/a.srt")]))
        XCTAssertEqual(s, ["subtitles", "rename"])
        XCTAssertEqual(ToolCatalog.entry("subtitles")?.target, .inspector("Sottotitoli"))
    }

    func testMixedPutsToolsForEverythingFirst() {
        let s = ToolCatalog.suggestions(for: [u("/x/a.mov"), u("/x/b.jpg")])
        XCTAssertTrue(s.first!.suitsAll)
        XCTAssertTrue(ids(s).contains("convert.compress"))
        XCTAssertFalse(s.first { $0.entry.id == "convert.compress" }!.suitsAll)
        let firstPartial = s.firstIndex { !$0.suitsAll }!
        XCTAssertTrue(s[..<firstPartial].allSatisfy(\.suitsAll))
    }

    func testFolderAndEmpty() {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        XCTAssertEqual(ids(ToolCatalog.suggestions(for: [folder])).first, "dups")
        XCTAssertTrue(ToolCatalog.suggestions(for: []).isEmpty)
        XCTAssertEqual(ids(ToolCatalog.suggestions(for: [u("/x/a.xyz")])), ["rename"])
    }

    func testSearchRanking() {
        func top(_ q: String) -> String? { ToolCatalog.search(q).first?.title }
        XCTAssertEqual(top("compress video"), "Rimpicciolisci per inviare")
        XCTAssertEqual(top("sottotitoli"), "Sottotitoli SRT/VTT")
        XCTAssertEqual(top("rename"), "Rinomina in blocco")
        XCTAssertEqual(top("doppioni"), "Doppioni")
        XCTAssertEqual(top("duplicates"), "Doppioni")
        XCTAssertEqual(top("trim"), "Taglia clip")
        XCTAssertEqual(top("metadata"), "Pulisci metadata")
        XCTAssertEqual(top("estrai audio"), "Estrai o converti l'audio")
        XCTAssertEqual(top("PROPRIETA"), "Info file", "accents and case ignored")
        XCTAssertEqual(top("sottotitoli"), top("SOTTOTITOLÌ"))
        XCTAssertEqual(top("cmprimi"), "Rimpicciolisci per inviare", "typo tolerance")
        XCTAssertTrue(ToolCatalog.search("qwertyuiop").isEmpty)
        XCTAssertEqual(ToolCatalog.search("  ").count, ToolCatalog.all.count)
    }

    func testDeepLinkRoundTrip() {
        let files = [u("/Volumes/SSD esterno/Clip è 1 & più.mov"), u("/tmp/b#c?.mp4")]
        let link = DeepLink.make(toolID: "convert.compress", files: files)!
        let parsed = DeepLink.parse(link)
        XCTAssertEqual(parsed?.toolID, "convert.compress")
        XCTAssertEqual(parsed?.files, files)
    }

    func testDeepLinkRejects() {
        XCTAssertNil(DeepLink.parse(URL(string: "https://tool/info?file=/a")!))
        XCTAssertNil(DeepLink.parse(URL(string: "fcptoolbox://tool/nonexistent?file=/a")!))
        XCTAssertNil(DeepLink.parse(URL(string: "fcptoolbox://other/info")!))
        let p = DeepLink.parse(URL(string: "fcptoolbox://tool/info?file=relative.mov&file=/ok.mov")!)
        XCTAssertEqual(p?.files, [u("/ok.mov")])
        XCTAssertEqual(DeepLink.parse(URL(string: "fcptoolbox://tool/drop")!)?.toolID, "drop")
    }

    func testActionsPointToRealTools() {
        for a in QuickActions.actions {
            XCTAssertTrue(a.toolID == DeepLink.dropID || ToolCatalog.entry(a.toolID) != nil, a.toolID)
        }
    }

    func testWorkflowFilesAreValidAndRemovalIsSafe() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qa-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let foreign = dir.appendingPathComponent("Mio.workflow")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        let made = try QuickActions.install(into: dir)
        XCTAssertEqual(made.count, QuickActions.actions.count)
        for b in made {
            let info = try XCTUnwrap(NSDictionary(contentsOf: b.appendingPathComponent("Contents/Info.plist")))
            let svc = try XCTUnwrap((info["NSServices"] as? [[String: Any]])?.first)
            XCTAssertEqual(svc["NSMessage"] as? String, "runWorkflowAsService")
            let wf = try XCTUnwrap(NSDictionary(contentsOf: b.appendingPathComponent("Contents/document.wflow")))
            XCTAssertEqual((wf["actions"] as? [Any])?.count, 1)
        }
        XCTAssertEqual(QuickActions.installed(in: dir).count, made.count)
        _ = try QuickActions.install(into: dir)  // reinstall is idempotent
        XCTAssertEqual(QuickActions.installed(in: dir).count, made.count)
        let removed = try QuickActions.remove(from: dir)
        XCTAssertEqual(removed.count, made.count)
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path), "foreign workflow untouched")
        XCTAssertTrue(QuickActions.installed(in: dir).isEmpty)
    }

    /// Runs the real generated shell script with a fake `open`, then parses what it would have opened.
    func testScriptEncodesPathsForTheApp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("fakeopen.sh")
        let out = dir.appendingPathComponent("out.txt")
        try "#!/bin/bash\nprintf '%s' \"$3\" > '\(out.path)'\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let script = QuickActions.script(toolID: "convert.compress", openCommand: fake.path)
        let files = ["/Volumes/SSD esterno/Clip è 1 & più.mov", "/tmp/a'b\"c.mp4"]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script, "bash"] + files
        try p.run(); p.waitUntilExit()
        let opened = try String(contentsOf: out, encoding: .utf8)
        let link = DeepLink.parse(try XCTUnwrap(URL(string: opened)))
        XCTAssertEqual(link?.toolID, "convert.compress")
        XCTAssertEqual(link?.files.map(\.path), files)
    }
}
