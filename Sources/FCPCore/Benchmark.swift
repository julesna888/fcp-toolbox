import Foundation

/// Sequential speed of a volume, measured with a synthetic test. It says what the disk can do in a
/// straight line, not how it behaves under Final Cut (many small reads, several streams, thermal limits).
public struct SpeedResult: Sendable, Equatable {
    public let writeMBps: Double
    public let readMBps: Double
    public let megabytes: Int
}

public enum BenchError: LocalizedError, Equatable {
    case notEnoughSpace(needed: Int64, free: Int64)
    case notWritable
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notEnoughSpace(let n, let f): return "Spazio insufficiente per il test: servono \(formatBytes(n)), ne restano \(formatBytes(f))."
        case .notWritable: return "Il disco non è scrivibile."
        case .failed(let m): return "Test interrotto: \(m)"
        }
    }
}

public enum Fitness: Sendable { case good, limited, unfit }

public struct Suitability: Sendable {
    public let fitness: Fitness
    public let reasons: [String]
}

extension Doctor {
    /// Writes then reads back one temporary file on the volume, bypassing the system cache.
    /// The file is created by this function and always removed; nothing else on the disk is touched.
    public static func benchmark(volume: URL, megabytes: Int = 512,
                                 progress: (@Sendable (String) -> Void)? = nil) throws -> SpeedResult {
        let size = Int64(megabytes) * 1_000_000
        let free = freeSpace(of: volume) ?? 0
        guard free > size + 1_000_000_000 else { throw BenchError.notEnoughSpace(needed: size + 1_000_000_000, free: free) }
        // The root of the startup disk is not writable for a normal user; the Home folder sits on the same disk.
        let dir = fm.isWritableFile(atPath: volume.path) ? volume
                : (volume.path == "/" ? URL(fileURLWithPath: NSHomeDirectory()) : nil)
        guard let dir else { throw BenchError.notWritable }

        let path = dir.appendingPathComponent(".fcptoolbox-bench-\(UUID().uuidString)").path
        let fd = open(path, O_CREAT | O_RDWR | O_EXCL, 0o600)
        guard fd >= 0 else { throw BenchError.failed(String(cString: strerror(errno))) }
        defer { close(fd); unlink(path) }
        _ = fcntl(fd, F_NOCACHE, 1)

        let chunk = 8_000_000
        var buffer = [UInt8](repeating: 0, count: chunk)
        for i in 0..<chunk { buffer[i] = UInt8.random(in: 0...255) }  // not compressible, so no shortcut
        let chunks = Int(size) / chunk

        func seconds(_ t0: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9 }

        progress?("Scrivo…")
        var t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<chunks {
            let n = buffer.withUnsafeBytes { write(fd, $0.baseAddress, chunk) }
            guard n == chunk else { throw BenchError.failed(String(cString: strerror(errno))) }
        }
        _ = fcntl(fd, F_FULLFSYNC)
        let wSec = seconds(t0)

        progress?("Leggo…")
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw BenchError.failed(String(cString: strerror(errno))) }
        t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<chunks {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, chunk) }
            guard n == chunk else { throw BenchError.failed("lettura incompleta") }
        }
        let rSec = seconds(t0)

        let mb = Double(chunks * chunk) / 1e6
        return SpeedResult(writeMBps: mb / max(wSec, 0.001), readMBps: mb / max(rSec, 0.001), megabytes: chunks * chunk / 1_000_000)
    }

    /// Is this disk a sensible place for video work? Every reason is something that can be checked.
    public static func suitability(of v: Volume, speed: SpeedResult?, lowSpaceGB: Int = 50) -> Suitability {
        var reasons: [String] = []
        var fit = Fitness.good
        func worsen(_ f: Fitness) { if f == .unfit || (f == .limited && fit == .good) { fit = f } }

        let fmt = v.format.lowercased()
        if fmt.contains("ntfs") {
            worsen(.unfit); reasons.append("NTFS: il Mac lo legge ma non ci scrive.")
        } else if fmt.contains("fat32") || fmt.contains("ms-dos") {
            worsen(.unfit); reasons.append("FAT32: i file sono limitati a 4 GB, i video li superano subito.")
        } else if fmt.contains("exfat") {
            worsen(.limited); reasons.append("exFAT: va bene per i media, ma Apple indica APFS o Mac OS Esteso per le librerie, e se si scollega male si rovina più facilmente.")
        } else if fmt.contains("apfs") || fmt.contains("mac os") {
            reasons.append("Formato \(v.format): adatto a Final Cut.")
        } else {
            worsen(.limited); reasons.append("Formato \(v.format): non lo conosco come adatto a Final Cut.")
        }

        if let s = v.smart {
            if s == "Verified" { reasons.append("SMART: verificato.") }
            else { worsen(.unfit); reasons.append("SMART: \(s). Il disco segnala un problema, non metterci lavoro importante.") }
        } else {
            reasons.append("SMART non disponibile: non posso dire nulla sullo stato di salute (succede con molti box USB).")
        }

        if v.free < Int64(lowSpaceGB) * 1_000_000_000 {
            worsen(.limited); reasons.append("Meno di \(lowSpaceGB) GB liberi.")
        }

        if let s = speed {
            if s.writeMBps < 100 || s.readMBps < 100 {
                worsen(.limited)
                reasons.append("Velocità sequenziale bassa (scrittura \(Int(s.writeMBps)) MB/s, lettura \(Int(s.readMBps)) MB/s): ok per proxy e 1080p, stretto per 4K o ProRes.")
            } else {
                reasons.append("Velocità sequenziale: scrittura \(Int(s.writeMBps)) MB/s, lettura \(Int(s.readMBps)) MB/s.")
            }
            reasons.append("È una misura sintetica: in montaggio, con più flussi insieme e dopo molti minuti, può andare meno.")
        } else {
            reasons.append("Velocità non misurata.")
        }
        return Suitability(fitness: fit, reasons: reasons)
    }
}
