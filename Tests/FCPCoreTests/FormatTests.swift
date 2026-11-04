import XCTest
@testable import FCPCore

final class FormatTests: XCTestCase {
    func testVolumeNameIsCleanedAndShort() {
        XCTAssertEqual(Doctor.sanitizedVolumeName("  Montaggio/../:Cliente 1  "), "MontaggioCliente 1")
        XCTAssertEqual(Doctor.sanitizedVolumeName(String(repeating: "a", count: 40)).count, 27)
        XCTAssertEqual(Doctor.sanitizedVolumeName("///"), "")
    }

    func testBootDiskIsNeverOffered() {
        let bootName = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]))?.volumeName
        XCTAssertNotNil(bootName)
        for t in Doctor.eraseCandidates() {
            XCTAssertFalse(t.volumes.contains(bootName ?? "?"), "\(t)")
        }
    }

    func testEraseRefusesUnknownOrMalformedDisk() {
        let fake = EraseTarget(id: "disk0", name: "x", size: 1, solidState: true, volumes: [], used: 0)
        XCTAssertThrowsError(try Doctor.erase(fake, as: .apfs, name: "Prova"))
        let bad = EraseTarget(id: "disk1; rm -rf /", name: "x", size: 1, solidState: true, volumes: [], used: 0)
        XCTAssertThrowsError(try Doctor.erase(bad, as: .apfs, name: "Prova"))
    }

    /// Real erase, but only on a throwaway raw disk image that this test attaches itself.
    func testEraseOnAThrowawayDiskImage() throws {
        let fm = FileManager.default
        let img = fm.temporaryDirectory.appendingPathComponent("raw-\(UUID().uuidString).img")
        XCTAssertTrue(fm.createFile(atPath: img.path, contents: nil))
        let h = try FileHandle(forWritingTo: img)
        try h.truncate(atOffset: 300_000_000)
        try h.close()
        defer { try? fm.removeItem(at: img) }

        let attach = Doctor.run("/usr/bin/hdiutil",
                                ["attach", "-nomount", "-imagekey", "diskimage-class=CRawDiskImage", img.path])
        try XCTSkipIf(attach.status != 0, "hdiutil non disponibile: \(attach.out)")
        let dev = attach.out.split(whereSeparator: \.isNewline).first.map { String($0.split(separator: " ")[0]) } ?? ""
        let id = (dev as NSString).lastPathComponent
        defer { _ = Doctor.run("/usr/bin/hdiutil", ["detach", dev, "-force"]) }

        let info = Doctor.diskutilPlist(["info", "-plist", id])
        XCTAssertEqual(info?["VirtualOrPhysical"] as? String, "Virtual", "il test deve toccare solo l'immagine")
        guard info?["VirtualOrPhysical"] as? String == "Virtual" else { return }
        _ = try Doctor.eraseUnchecked(id: id, format: .apfs, name: "ProvaFCP")
        // APFS puts the volume on a synthesized disk, so look for it by its mount point.
        let vol = Doctor.diskutilPlist(["info", "-plist", "/Volumes/ProvaFCP"])
        XCTAssertEqual(vol?["FilesystemType"] as? String, "apfs")
        XCTAssertEqual(vol?["VolumeName"] as? String, "ProvaFCP")
    }
}
