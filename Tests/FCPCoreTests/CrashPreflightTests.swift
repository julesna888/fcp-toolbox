import XCTest
@testable import FCPCore

final class CrashPreflightTests: XCTestCase {
    private func writeCrash(_ dir: URL, name: String, message: String) throws {
        let head = #"{"app_name":"Final Cut Pro","timestamp":"2026-10-29 14:01:45.00 +0100","app_version":"10.7.1","os_version":"macOS 26.6"}"#
        let body = """
        {"exception":{"type":"EXC_BAD_INSTRUCTION","signal":"SIGILL"},
         "asi":{"libsystem_c.dylib":["\(message)"]},
         "faultingThread":0,
         "usedImages":[{"name":"AppKit"}],
         "threads":[{"queue":"com.apple.main-thread","frames":[{"imageIndex":0,"symbol":"_NSViewValidateGeometry"}]}]}
        """.replacingOccurrences(of: "\n", with: "")
        try (head + "\n" + body).write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testCrashesAreGroupedBySignature() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("crash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeCrash(dir, name: "Final Cut Pro-1.ips", message: "Invalid view geometry: width is NaN")
        try writeCrash(dir, name: "Final Cut Pro-2.ips", message: "Invalid view geometry: width is NaN")
        try writeCrash(dir, name: "Final Cut Pro-3.ips", message: "Something else")
        try writeCrash(dir, name: "Other App-1.ips", message: "ignored")
        try "not json".write(to: dir.appendingPathComponent("Final Cut Pro-bad.ips"), atomically: true, encoding: .utf8)

        let groups = Doctor.crashes(in: [dir])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].reports.count, 2)
        XCTAssertTrue(groups[0].note.contains("aggiorna Final Cut"))
        XCTAssertEqual(groups[0].reports[0].topFrames, ["AppKit: _NSViewValidateGeometry"])
        XCTAssertTrue(Doctor.supportText(groups[0]).contains("10.7.1"))
    }

    func testProcessParsingKeepsOnlyTopLevelUserApps() {
        let arc = Doctor.parseProcess("  123  1.5 800000 /Applications/Arc.app/Contents/MacOS/Arc")
        XCTAssertEqual(arc?.name, "Arc")
        XCTAssertEqual(arc?.isUserApp, true)
        XCTAssertEqual(arc?.rssBytes, 800_000 * 1024)
        let helper = Doctor.parseProcess("124 0.0 5000 /Applications/Arc.app/Contents/Frameworks/X.app/Contents/MacOS/X")
        XCTAssertEqual(helper?.isUserApp, false)
        XCTAssertEqual(Doctor.parseProcess("1 0.0 10 /usr/sbin/cfprefsd")?.isUserApp, false)
        XCTAssertNil(Doctor.parseProcess("garbage"))
        XCTAssertFalse(Doctor.processes().isEmpty)
    }

    func testPreflightFlagsLowSpaceAndHeavyApps() {
        let vol = Volume(url: URL(fileURLWithPath: "/Volumes/X"), name: "X", total: 500_000_000_000,
                         free: 10_000_000_000, format: "apfs", internalDisk: false, smart: nil)
        let arc = RunningProcess(pid: 1, name: "Arc", cpu: 1, rssBytes: 4_000_000_000, isUserApp: true)
        let fcp = RunningProcess(pid: 2, name: "Final Cut Pro", cpu: 1, rssBytes: 9_000_000_000, isUserApp: true)
        XCTAssertEqual(Doctor.closable([arc, fcp]).map(\.name), ["Arc"])

        let bad = Doctor.preflight(volumes: [vol], lowSpaceGB: 50, procs: [arc, fcp],
                                   totalRAM: 16_000_000_000, lowPower: true, thermalSerious: false)
        XCTAssertEqual(bad.filter { $0.level == .warn }.count, 3)
        let good = Doctor.preflight(volumes: [], lowSpaceGB: 50, procs: [],
                                    totalRAM: 16_000_000_000, lowPower: false, thermalSerious: false)
        XCTAssertTrue(good.allSatisfy { $0.level == .ok })
    }
}
