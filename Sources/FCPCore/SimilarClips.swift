import Foundation

extension Doctor {
    /// A 64-bit fingerprint of one frame: shrink to 8×8 grey, every pixel brighter than the average is a 1.
    /// Re-encoded or resized copies of the same picture get (almost) the same fingerprint.
    static func frameFingerprint(_ url: URL, at seconds: Double) -> UInt64? {
        guard let ffmpeg = ffmpegPath else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-hide_banner", "-loglevel", "error", "-ss", String(format: "%.3f", max(0, seconds)), "-i", url.path,
                       "-frames:v", "1", "-vf", "scale=8:8:flags=area,format=gray", "-f", "rawvideo", "-"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let bytes = [UInt8](out.fileHandleForReading.readDataToEndOfFile())
        p.waitUntilExit()
        guard p.terminationStatus == 0, bytes.count == 64 else { return nil }
        let mean = Double(bytes.reduce(0) { $0 + Int($1) }) / 64
        return bytes.enumerated().reduce(UInt64(0)) { Double($1.element) > mean ? $0 | (1 << UInt64($1.offset)) : $0 }
    }

    /// Videos that show the same footage even if they are different files (other name, other codec or size).
    /// Same duration (within 2%) and nearly equal fingerprints at 25%, 50% and 75% of the clip.
    /// It is an estimate: always look before deleting.
    public static func similarClips(in folder: URL, maxDifference: Int = 6) -> [[URL]] {
        let files = regularFiles(in: folder)
        let lock = NSLock()
        // probe in parallel (as many as there are cores)
        var probed = [(URL, Double)?](repeating: nil, count: files.count)
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            guard let m = try? probeMedia(files[i]), m.video != nil, m.duration > 0.5 else { return }
            lock.lock(); probed[i] = (files[i], m.duration); lock.unlock()
        }
        let all = probed.compactMap { $0 }
        // a clip whose length matches no other clip cannot be a copy: skip its (slow) fingerprints
        let videos = all.filter { a in all.contains { b in b.0 != a.0 && abs(a.1 - b.1) <= max(0.3, 0.02 * max(a.1, b.1)) } }
        typealias Print = (url: URL, duration: Double, hashes: [UInt64])
        var made = [Print?](repeating: nil, count: videos.count)
        DispatchQueue.concurrentPerform(iterations: videos.count) { i in
            let (u, d) = videos[i]
            let hs = [0.25, 0.5, 0.75].compactMap { frameFingerprint(u, at: d * $0) }
            guard hs.count == 3 else { return }
            lock.lock(); made[i] = (u, d, hs); lock.unlock()
        }
        let prints = made.compactMap { $0 }
        func same(_ a: Print, _ b: Print) -> Bool {
            abs(a.duration - b.duration) <= max(0.3, 0.02 * max(a.duration, b.duration))
                && zip(a.hashes, b.hashes).allSatisfy { ($0 ^ $1).nonzeroBitCount <= maxDifference }
        }
        var groups: [[Int]] = []
        for i in prints.indices {
            if let g = groups.firstIndex(where: { grp in grp.contains { same(prints[$0], prints[i]) } }) { groups[g].append(i) } else { groups.append([i]) }
        }
        return groups.filter { $0.count > 1 }.map { $0.map { prints[$0].url }.sorted { $0.path < $1.path } }
    }
}
