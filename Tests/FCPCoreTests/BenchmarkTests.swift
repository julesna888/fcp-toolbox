import XCTest
@testable import FCPCore

final class BenchmarkTests: XCTestCase {
    private func vol(_ format: String, smart: String? = "Verified", free: Int64 = 300_000_000_000) -> Volume {
        Volume(url: URL(fileURLWithPath: "/Volumes/T"), name: "T", total: 500_000_000_000, free: free,
               format: format, internalDisk: false, smart: smart)
    }
    private let fast = SpeedResult(writeMBps: 900, readMBps: 1000, megabytes: 512)
    private let slow = SpeedResult(writeMBps: 40, readMBps: 90, megabytes: 512)

    func testSuitabilityVerdicts() {
        XCTAssertEqual(Doctor.suitability(of: vol("APFS"), speed: fast).fitness, .good)
        XCTAssertEqual(Doctor.suitability(of: vol("Mac OS Extended (Journaled)"), speed: fast).fitness, .good)
        XCTAssertEqual(Doctor.suitability(of: vol("ExFAT"), speed: fast).fitness, .limited)
        XCTAssertEqual(Doctor.suitability(of: vol("NTFS"), speed: fast).fitness, .unfit)
        XCTAssertEqual(Doctor.suitability(of: vol("MS-DOS (FAT32)"), speed: fast).fitness, .unfit)
        XCTAssertEqual(Doctor.suitability(of: vol("APFS", smart: "Failing"), speed: fast).fitness, .unfit)
        XCTAssertEqual(Doctor.suitability(of: vol("APFS", free: 10_000_000_000), speed: fast).fitness, .limited)
        XCTAssertEqual(Doctor.suitability(of: vol("APFS"), speed: slow).fitness, .limited)
    }

    func testSuitabilityIsHonestAboutWhatItDoesNotKnow() {
        let noSmart = Doctor.suitability(of: vol("APFS", smart: nil), speed: nil)
        XCTAssertEqual(noSmart.fitness, .good)  // unknown health is not a defect
        XCTAssertTrue(noSmart.reasons.contains { $0.contains("SMART non disponibile") })
        XCTAssertTrue(noSmart.reasons.contains { $0.contains("non misurata") })
        let measured = Doctor.suitability(of: vol("APFS"), speed: fast)
        XCTAssertTrue(measured.reasons.contains { $0.contains("sintetica") })
    }

    func testBenchmarkMeasuresAndLeavesNothingBehind() throws {
        let r = try Doctor.benchmark(volume: URL(fileURLWithPath: "/"), megabytes: 64)
        XCTAssertGreaterThan(r.writeMBps, 1)
        XCTAssertGreaterThan(r.readMBps, 1)
        XCTAssertEqual(r.megabytes, 64)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory())) ?? []
        XCTAssertFalse(left.contains { $0.hasPrefix(".fcptoolbox-bench-") })
        print("INTERNO: scrittura \(Int(r.writeMBps)) MB/s, lettura \(Int(r.readMBps)) MB/s")
    }

    func testBenchmarkRefusesWhenSpaceIsShort() {
        XCTAssertThrowsError(try Doctor.benchmark(volume: URL(fileURLWithPath: "/"), megabytes: 100_000_000)) {
            guard case BenchError.notEnoughSpace = $0 else { return XCTFail("wrong error \($0)") }
        }
    }

    /// Opt-in: FCP_BENCH_EXTERNAL=1 runs 128 MB on every mounted external disk you can write to.
    func testExternalDisksWhenAsked() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FCP_BENCH_EXTERNAL"] == "1")
        for v in Doctor.volumes() where !v.internalDisk {
            let r = try Doctor.benchmark(volume: v.url, megabytes: 128)
            let s = Doctor.suitability(of: v, speed: r)
            print("ESTERNO \(v.name) [\(v.format)]: scrittura \(Int(r.writeMBps)) MB/s, lettura \(Int(r.readMBps)) MB/s → \(s.fitness)")
            let left = (try? FileManager.default.contentsOfDirectory(atPath: v.url.path)) ?? []
            XCTAssertFalse(left.contains { $0.hasPrefix(".fcptoolbox-bench-") })
        }
    }
}
