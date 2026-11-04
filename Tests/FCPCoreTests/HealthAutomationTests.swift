import XCTest
@testable import FCPCore

final class HealthAutomationTests: XCTestCase {
    private func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ha-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // MARK: Health

    func testHealthyLibraryScoresHighAndEachProblemLowersIt() {
        var i = HealthInput()
        i.mediaTotal = 100; i.freeBytes = 200_000_000_000; i.libraryBytes = 1_000_000_000; i.cacheBytes = 50_000_000
        i.lastBackup = i.now.addingTimeInterval(-2 * 86_400); i.changedSinceBackup = 0
        let good = Doctor.assessHealth(i)
        XCTAssertEqual(good.score, 100)
        XCTAssertEqual(good.label, "In buona salute")
        XCTAssertTrue(good.indicators.allSatisfy { $0.advice == nil })

        var missing = i; missing.mediaMissing = 3
        XCTAssertLessThan(Doctor.assessHealth(missing).score, good.score)
        XCTAssertLessThanOrEqual(Doctor.assessHealth(missing).indicators.first { $0.name == "Media collegati" }!.score!, 60)

        var noBackup = i; noBackup.lastBackup = nil
        let nb = Doctor.assessHealth(noBackup)
        XCTAssertEqual(nb.indicators.first { $0.name == "Backup" }?.score, 0)
        XCTAssertLessThanOrEqual(nb.score, 75)  // backup weighs 25

        var stale = i; stale.lastBackup = i.now.addingTimeInterval(-90 * 86_400)
        XCTAssertEqual(Doctor.assessHealth(stale).indicators.first { $0.name == "Backup" }?.score, 20)

        var changed = i; changed.changedSinceBackup = 12
        XCTAssertEqual(Doctor.assessHealth(changed).indicators.first { $0.name == "Backup" }?.score, 80)

        var low = i; low.freeBytes = 3_000_000_000
        XCTAssertEqual(Doctor.assessHealth(low).indicators.first { $0.name == "Spazio libero" }?.score, 0)

        var ro = i; ro.writable = false
        XCTAssertEqual(Doctor.assessHealth(ro).indicators.first { $0.name == "Accesso alla libreria" }?.score, 40)
    }

    func testUnmeasuredIndicatorsDoNotCountAndWeightsAreReported() {
        var i = HealthInput()
        i.lastBackup = i.now
        i.changedSinceBackup = 0
        let r = Doctor.assessHealth(i)  // no media, no free-space reading
        XCTAssertNil(r.indicators.first { $0.name == "Media collegati" }?.score)
        XCTAssertNil(r.indicators.first { $0.name == "Spazio libero" }?.score)
        XCTAssertEqual(r.score, 100)  // only backup and access were measured, both perfect
        XCTAssertTrue(r.note.contains("pesi"))
    }

    func testRealLibraryFolderIsReadAndScored() throws {
        let lib = try dir().appendingPathComponent("Test.fcpbundle")
        try FileManager.default.createDirectory(at: lib.appendingPathComponent("Evento/Render Files"), withIntermediateDirectories: true)
        try Data(count: 200_000).write(to: lib.appendingPathComponent("Evento/Render Files/r.mov"))
        let r = Doctor.health(of: Doctor.scan(lib), history: [], now: Date())
        XCTAssertEqual(r.indicators.first { $0.name == "Accesso alla libreria" }?.score, 100)
        XCTAssertEqual(r.indicators.first { $0.name == "Backup" }?.score, 0)  // history is empty: never backed up
        XCTAssertNotNil(r.indicators.first { $0.name == "Spazio libero" }?.score)
    }

    func testSpaceForecastIsHonestAboutBeingAnEstimate() {
        let t = Date()
        func snap(_ d: Double, _ total: Int64) -> LibrarySnapshot { LibrarySnapshot(date: t.addingTimeInterval(d * 86_400), path: "/x", total: total, parts: [:]) }
        let g = Growth(first: snap(0, 100_000_000_000), last: snap(10, 150_000_000_000))  // 5 GB/day
        let text = Doctor.predictSpace(free: 100_000_000_000, growth: g)
        XCTAssertTrue(text?.contains("circa 20 giorni") ?? false, text ?? "nil")
        XCTAssertTrue(text?.contains("stima") ?? false)
        XCTAssertNil(Doctor.predictSpace(free: 1, growth: nil))
        XCTAssertNil(Doctor.predictSpace(free: 1, growth: Growth(first: snap(0, 5), last: snap(0.2, 9))))
        XCTAssertNil(Doctor.predictSpace(free: 1, growth: Growth(first: snap(0, 9), last: snap(5, 5))))
    }

    // MARK: Automations

    private func env(libs: [URL], free: Int64?, backups: [BackupRecord] = [], crashes: [String] = [], now: Date = Date(),
                     report: URL? = nil, delivery: [(file: String, problems: [String])] = []) -> AutomationEnv {
        AutomationEnv(now: { now }, libraries: { libs }, freeSpace: { _ in free }, backups: { backups }, crashFiles: { crashes },
                      deliveryProblems: { _, _, _ in delivery }, writeReport: { _ in report })
    }

    func testNothingRunsUntilTheMasterSwitchIsOn() throws {
        let lib = try dir().appendingPathComponent("A.fcpbundle")
        var state = AutomationState()
        XCTAssertEqual(Doctor.runAutomations(AutomationConfig(), state: &state, env: env(libs: [lib], free: 1)), [])
        XCTAssertEqual(state, AutomationState())
    }

    func testLowSpaceAndBackupAlertsAreRaisedOncePerDay() throws {
        let d = try dir()
        let lib = d.appendingPathComponent("A.fcpbundle")
        var cfg = AutomationConfig(); cfg.enabled = true; cfg.crashWatch = false
        var state = AutomationState()
        let t0 = Date()

        let first = Doctor.runAutomations(cfg, state: &state, env: env(libs: [lib], free: 5_000_000_000, now: t0))
        XCTAssertEqual(Set(first.map { $0.title }), ["Poco spazio libero", "Backup da fare"])
        XCTAssertTrue(Doctor.runAutomations(cfg, state: &state, env: env(libs: [lib], free: 5_000_000_000, now: t0.addingTimeInterval(3600))).isEmpty)
        let next = Doctor.runAutomations(cfg, state: &state, env: env(libs: [lib], free: 5_000_000_000, now: t0.addingTimeInterval(90_000)))
        XCTAssertEqual(next.count, 2)

        // plenty of space and a fresh backup: silence
        let rec = BackupRecord(date: t0, source: lib.standardizedFileURL.path, destination: "/x", copied: 1, bytes: 1, verified: 1, failures: [])
        var calm = AutomationState()
        XCTAssertTrue(Doctor.runAutomations(cfg, state: &calm, env: env(libs: [lib], free: 500_000_000_000, backups: [rec], now: t0)).isEmpty)

        // each rule can be turned off alone
        cfg.lowSpace = false; cfg.backupReminder = false
        var off = AutomationState()
        XCTAssertTrue(Doctor.runAutomations(cfg, state: &off, env: env(libs: [lib], free: 1, now: t0)).isEmpty)
    }

    func testCrashWatchIgnoresOldReportsAndFlagsNewOnes() {
        var cfg = AutomationConfig(); cfg.enabled = true; cfg.lowSpace = false; cfg.backupReminder = false
        var state = AutomationState()
        XCTAssertTrue(Doctor.runAutomations(cfg, state: &state, env: env(libs: [], free: nil, crashes: ["/a.ips", "/b.ips"])).isEmpty)
        XCTAssertTrue(Doctor.runAutomations(cfg, state: &state, env: env(libs: [], free: nil, crashes: ["/a.ips", "/b.ips"])).isEmpty)
        let ev = Doctor.runAutomations(cfg, state: &state, env: env(libs: [], free: nil, crashes: ["/a.ips", "/b.ips", "/c.ips"]))
        XCTAssertEqual(ev.map(\.title), ["Final Cut si è chiuso"])
        XCTAssertTrue(Doctor.runAutomations(cfg, state: &state, env: env(libs: [], free: nil, crashes: ["/a.ips", "/b.ips", "/c.ips"])).isEmpty)
    }

    func testWeeklyReportWrittenOnceAWeekAndDeliveryProblemsAreReported() throws {
        let d = try dir()
        var cfg = AutomationConfig(); cfg.enabled = true; cfg.lowSpace = false; cfg.backupReminder = false; cfg.crashWatch = false
        cfg.weeklyReport = true
        cfg.deliveryFolder = d.path
        var state = AutomationState()
        let t0 = Date()
        let report = d.appendingPathComponent("Report.txt")
        let ev = Doctor.runAutomations(cfg, state: &state, env: env(libs: [], free: nil, now: t0, report: report,
                                                                     delivery: [("spot.mov", ["Frame rate 29."]), ("ok.mov", [])]))
        XCTAssertEqual(ev.map(\.title).sorted(), ["Export da controllare", "Report settimanale pronto"])
        XCTAssertTrue(ev.contains { $0.body.contains("spot.mov") && $0.body.contains("Frame rate 29.") })
        XCTAssertEqual(state.lastReport, t0)
        XCTAssertEqual(state.deliveryChecked, t0)

        let later = Doctor.runAutomations(cfg, state: &state, env: env(libs: [], free: nil, now: t0.addingTimeInterval(86_400), report: report))
        XCTAssertTrue(later.isEmpty)  // report is weekly
    }

    func testConfigAndStatePersist() throws {
        let f = try dir()
        var c = AutomationConfig(); c.enabled = true; c.lowSpaceGB = 33; c.deliveryFolder = "/Export"
        Doctor.saveAutomationConfig(c, at: f.appendingPathComponent("c.json"))
        XCTAssertEqual(Doctor.loadAutomationConfig(at: f.appendingPathComponent("c.json")), c)
        XCTAssertFalse(Doctor.loadAutomationConfig(at: f.appendingPathComponent("none.json")).enabled)
        var s = AutomationState(); s.seenCrashes = ["/a"]; s.lastAlert["k"] = Date(timeIntervalSince1970: 1_700_000_000)
        Doctor.saveAutomationState(s, at: f.appendingPathComponent("s.json"))
        XCTAssertEqual(Doctor.loadAutomationState(at: f.appendingPathComponent("s.json")), s)
    }

    func testNewExportsAreCheckedAgainstTheChosenProfile() throws {
        try XCTSkipUnless(Doctor.ffprobePath != nil && FileManager.default.isExecutableFile(atPath: "/usr/local/bin/ffmpeg"))
        let d = try dir()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
        p.arguments = ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=duration=1:size=1280x720:rate=30", "-f", "lavfi", "-i", "sine=duration=1",
                       "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", d.appendingPathComponent("h.mp4").path]
        try p.run(); p.waitUntilExit()
        let r = Doctor.checkNewExports(in: d, profile: "Instagram Reels", since: Date().addingTimeInterval(-60))
        XCTAssertEqual(r.map(\.file), ["h.mp4"])
        XCTAssertFalse(r[0].problems.isEmpty)  // horizontal 720p is not a Reel
        XCTAssertTrue(Doctor.checkNewExports(in: d, profile: "Instagram Reels", since: Date().addingTimeInterval(60)).isEmpty)
        XCTAssertTrue(Doctor.checkNewExports(in: d, profile: "Profilo inesistente", since: .distantPast).isEmpty)
    }
}
