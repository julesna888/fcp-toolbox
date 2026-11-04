import XCTest
@testable import FCPCore

final class PerfTests: XCTestCase {
    private func fake(pressure: Int = 1, swap: Int64 = 0, thermal: Int = 0, busy: [String] = []) -> PerfSample {
        PerfSample(date: Date(), cpuPercent: 10, memUsed: 8_000_000_000, memTotal: 16_000_000_000, pressure: pressure,
                   swapUsed: swap, swapTotal: 9_000_000_000, diskMBps: 0, fcpCPU: 0, fcpRSS: 0, thermal: thermal, busy: busy)
    }

    func testRealSampleIsPlausibleAndLogged() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString)")
        let log = dir.appendingPathComponent("perf.jsonl")
        let s = Doctor.sample(log: log)
        XCTAssertEqual(s.memTotal, Int64(ProcessInfo.processInfo.physicalMemory))
        XCTAssertGreaterThan(s.memUsed, 500_000_000)
        XCTAssertLessThanOrEqual(s.memUsed, s.memTotal)
        XCTAssertTrue((0...100).contains(s.cpuPercent), "cpu \(s.cpuPercent)")
        XCTAssertTrue([1, 2, 4].contains(s.pressure), "pressure \(s.pressure)")
        XCTAssertGreaterThanOrEqual(s.swapTotal, 0)
        XCTAssertGreaterThanOrEqual(s.diskMBps, 0)
        let history = Doctor.perfHistory(at: log)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].memTotal, s.memTotal)
        print("PRESTAZIONI: CPU \(Int(s.cpuPercent))%, RAM \(formatBytes(s.memUsed))/\(formatBytes(s.memTotal)), pressione \(s.pressure), swap \(formatBytes(s.swapUsed)), disco \(String(format: "%.1f", s.diskMBps)) MB/s, busy \(s.busy)")
    }

    func testSummaryNeedsRecurrenceNotASingleSpike() {
        let calm = (0..<10).map { _ in fake() } + [fake(pressure: 4)]
        XCTAssertFalse(Doctor.summarize(calm).findings.contains { $0.contains("pressione") })

        let bad = (0..<4).map { _ in fake(pressure: 2, swap: 6_000_000_000, thermal: 2, busy: ["Arc 80%"]) } + (0..<6).map { _ in fake() }
        let f = Doctor.summarize(bad).findings.joined(separator: "\n")
        XCTAssertTrue(f.contains("pressione in 4 misure su 10"))
        XCTAssertTrue(f.contains("swap"))
        XCTAssertTrue(f.contains("caldo"))
        XCTAssertTrue(f.contains("Arc"))
        XCTAssertTrue(Doctor.summarize([fake()]).findings.contains { $0.contains("Poche misure") })
    }
}
