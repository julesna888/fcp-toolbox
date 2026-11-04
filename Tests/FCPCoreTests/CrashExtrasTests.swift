import XCTest
@testable import FCPCore

final class CrashExtrasTests: XCTestCase {
    private func ips(_ dir: URL, name: String, message: String, symbol: String, version: String = "10.7.1") throws -> URL {
        let head = #"{"app_name":"Final Cut Pro","timestamp":"2026-10-29 14:01:45.00 +0100","app_version":"\#(version)","os_version":"macOS 26.6"}"#
        let body = """
        {"exception":{"type":"EXC_BAD_INSTRUCTION","signal":"SIGILL"},"asi":{"libsystem_c.dylib":["\(message)"]},
         "faultingThread":0,"usedImages":[{"name":"AppKit"}],
         "threads":[{"queue":"com.apple.main-thread","frames":[{"imageIndex":0,"symbol":"\(symbol)"}]}]}
        """.replacingOccurrences(of: "\n", with: "")
        let u = dir.appendingPathComponent(name)
        try (head + "\n" + body).write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    private func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ce-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testManualImportAndComparison() throws {
        let d = try dir()
        let a = try XCTUnwrap(Doctor.importCrash(ips(d, name: "whatever.ips", message: "Invalid view geometry: width is NaN", symbol: "_NSViewValidateGeometry")))
        let same = try XCTUnwrap(Doctor.importCrash(ips(d, name: "other.ips", message: "Invalid view geometry: width is NaN", symbol: "_NSViewValidateGeometry")))
        let diff = try XCTUnwrap(Doctor.importCrash(ips(d, name: "third.ips", message: "Other", symbol: "objc_msgSend", version: "11.0")))
        XCTAssertNil(Doctor.importCrash(d.appendingPathComponent("missing.ips")))
        XCTAssertEqual(Doctor.compare(a, same), ["Stessa causa: eccezione, punto del crash, versione e sistema coincidono."])
        let c = Doctor.compare(a, diff).joined(separator: "\n")
        XCTAssertTrue(c.contains("Messaggio"))
        XCTAssertTrue(c.contains("objc_msgSend"))
        XCTAssertTrue(c.contains("10.7.1 contro 11.0"))
    }

    func testCorrelationReportsWhatItSawAndWhatItDidNot() throws {
        let d = try dir()
        let r = try XCTUnwrap(Doctor.importCrash(ips(d, name: "a.ips", message: "m", symbol: "s"))).reports[0]
        let t = try XCTUnwrap(r.time)
        func s(_ offset: TimeInterval, pressure: Int = 1, thermal: Int = 0) -> PerfSample {
            PerfSample(date: t.addingTimeInterval(offset), cpuPercent: 5, memUsed: 1, memTotal: 16_000_000_000, pressure: pressure,
                       swapUsed: 0, swapTotal: 0, diskMBps: 0, fcpCPU: 0, fcpRSS: 0, thermal: thermal, busy: [])
        }
        XCTAssertTrue(Doctor.correlate(r, perf: []).joined().contains("Nessuna misura"))
        XCTAssertTrue(Doctor.correlate(r, perf: [s(-3600, pressure: 4)]).joined().contains("Nessuna misura"))  // too far
        XCTAssertTrue(Doctor.correlate(r, perf: [s(-120, pressure: 4)]).joined().contains("pressione"))
        XCTAssertTrue(Doctor.correlate(r, perf: [s(-60, thermal: 2)]).joined().contains("caldo"))
        XCTAssertTrue(Doctor.correlate(r, perf: [s(-60)]).joined().contains("nella norma"))
        let snap = LibrarySnapshot(date: t.addingTimeInterval(-86_400), path: "/Volumes/X/Big.fcpbundle", total: 120_000_000_000, parts: [:])
        XCTAssertTrue(Doctor.correlate(r, perf: [], snapshots: [snap]).joined().contains("Big.fcpbundle"))
    }

    func testTechnicalReportAdmitsUncertainty() throws {
        let d = try dir()
        let g = try XCTUnwrap(Doctor.importCrash(ips(d, name: "a.ips", message: "Invalid view geometry: width is NaN", symbol: "_NSViewValidateGeometry")))
        let text = Doctor.technicalReport(g)
        XCTAssertTrue(text.contains("10.7.1"))
        XCTAssertTrue(text.contains("AppKit: _NSViewValidateGeometry"))
        XCTAssertTrue(text.contains("la causa non è dimostrata"))
    }
}
