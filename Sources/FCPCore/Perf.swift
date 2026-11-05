import Foundation
import Darwin

/// One reading of how loaded the Mac is. Taken only on demand, never by a background timer.
public struct PerfSample: Codable, Sendable, Hashable {
    public var date: Date
    public var cpuPercent: Double
    public var memUsed: Int64
    public var memTotal: Int64
    /// 1 normal, 2 warning, 4 critical (the kernel's own memory pressure level).
    public var pressure: Int
    public var swapUsed: Int64
    public var swapTotal: Int64
    public var diskMBps: Double
    public var fcpCPU: Double
    public var fcpRSS: Int64
    /// ProcessInfo thermal state: 0 nominal … 3 critical.
    public var thermal: Int
    /// The busiest other apps at that moment, "name 35%".
    public var busy: [String]
}

public struct PerfSummary: Sendable {
    public let samples: Int
    public let highPressure: Int
    public let heavySwap: Int
    public let hot: Int
    public let topInterferers: [(name: String, times: Int)]
    public let findings: [String]
}

extension Doctor {
    public static var perfLogURL: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/FCP Toolbox/perf.jsonl")
    }

    static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)) }
        var busy: UInt64 = 0, total: UInt64 = 0
        for i in 0..<Int(count) {
            let b = i * Int(CPU_STATE_MAX)
            let user = UInt64(info[b + Int(CPU_STATE_USER)]), sys = UInt64(info[b + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[b + Int(CPU_STATE_NICE)]), idle = UInt64(info[b + Int(CPU_STATE_IDLE)])
            busy += user + sys + nice
            total += user + sys + nice + idle
        }
        return (busy, total)
    }

    static func memoryUsed() -> Int64 {
        var stats = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size) }
        }
        guard r == KERN_SUCCESS else { return 0 }
        // What the system cannot hand out without compressing or swapping: active + wired + compressed.
        let pages = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return Int64(pages * UInt64(vm_kernel_page_size))
    }

    static func sysctlInt(_ name: String) -> Int {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : 0
    }

    static func swapUsage() -> (used: Int64, total: Int64) {
        var s = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &s, &size, nil, 0) == 0 else { return (0, 0) }
        return (Int64(s.xsu_used), Int64(s.xsu_total))
    }

    static func capture(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Cumulative megabytes moved by all disks, from `iostat -dI`.
    static func diskMegabytes() -> Double {
        let lines = capture("/usr/sbin/iostat", ["-dI"]).split(separator: "\n")
        guard let last = lines.last else { return 0 }
        let nums = last.split(separator: " ").compactMap { Double($0) }
        return stride(from: 2, to: nums.count, by: 3).reduce(0) { $0 + nums[$1] }
    }

    /// Instantaneous CPU per process: the second block printed by `top`, as [pid: percent].
    static func topCPU() -> [Int32: Double] {
        let out = capture("/usr/bin/top", ["-l", "2", "-s", "1", "-n", "8", "-o", "cpu", "-stats", "pid,cpu"])
        let blocks = out.components(separatedBy: "PID")
        guard blocks.count >= 3 else { return [:] }
        var map: [Int32: Double] = [:]
        for line in blocks[2].split(separator: "\n") {
            let f = line.split(separator: " ")
            if f.count >= 2, let pid = Int32(f[0]), let cpu = Double(f[1]) { map[pid] = cpu }
        }
        return map
    }

    /// Takes one sample (about 1.5 seconds) and appends it to the history.
    @discardableResult
    public static func sample(log: URL? = perfLogURL) -> PerfSample {
        let before = cpuTicks()
        let disk0 = diskMegabytes()
        let t0 = Date()
        let top = topCPU()  // also serves as the waiting time between the two readings
        let after = cpuTicks()
        let seconds = max(Date().timeIntervalSince(t0), 0.1)
        var cpu = 0.0
        if let b = before, let a = after, a.total > b.total { cpu = Double(a.busy - b.busy) / Double(a.total - b.total) * 100 }
        let disk = max(0, (diskMegabytes() - disk0) / seconds)

        let procs = processes()
        let names = Dictionary(procs.map { ($0.pid, $0.name) }, uniquingKeysWith: { a, _ in a })
        var perApp: [String: Double] = [:]
        for (pid, c) in top { perApp[names[pid] ?? "pid \(pid)", default: 0] += c }
        let fcp = procs.filter { $0.name == "Final Cut Pro" }
        let swap = swapUsage()
        let s = PerfSample(date: Date(), cpuPercent: cpu, memUsed: memoryUsed(), memTotal: Int64(ProcessInfo.processInfo.physicalMemory),
                           pressure: sysctlInt("kern.memorystatus_vm_pressure_level"), swapUsed: swap.used, swapTotal: swap.total,
                           diskMBps: disk, fcpCPU: perApp["Final Cut Pro"] ?? 0, fcpRSS: fcp.reduce(0) { $0 + $1.rssBytes },
                           thermal: ProcessInfo.processInfo.thermalState.rawValue,
                           busy: perApp.filter { $0.key != "Final Cut Pro" && $0.value >= 20 }
                                      .sorted { $0.value > $1.value }.prefix(3).map { "\($0.key) \(Int($0.value))%" })
        if let log { appendPerf(s, to: log) }
        return s
    }

    static func appendPerf(_ s: PerfSample, to log: URL) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(s) else { return }
        try? fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: log) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data + Data("\n".utf8))
        } else {
            try? (data + Data("\n".utf8)).write(to: log)
        }
    }

    public static func perfHistory(at log: URL = perfLogURL, limit: Int = 2000) -> [PerfSample] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let all = text.split(separator: "\n").compactMap { try? dec.decode(PerfSample.self, from: Data($0.utf8)) }
        return Array(all.suffix(limit))
    }

    /// Recurring problems in the history. A finding needs at least 3 samples and a quarter of them.
    public static func summarize(_ samples: [PerfSample]) -> PerfSummary {
        let n = samples.count
        let pressure = samples.filter { $0.pressure >= 2 }.count
        let swap = samples.filter { $0.swapTotal > 0 && Double($0.swapUsed) / Double($0.memTotal) > 0.25 }.count
        let hot = samples.filter { $0.thermal >= 2 }.count
        var counts: [String: Int] = [:]
        for s in samples { for b in s.busy { counts[String(b.split(separator: " ").dropLast().joined(separator: " ")), default: 0] += 1 } }
        let top = counts.sorted { $0.value > $1.value }.prefix(3).map { (name: $0.key, times: $0.value) }
        func recurring(_ c: Int) -> Bool { c >= 3 && Double(c) / Double(max(n, 1)) >= 0.25 }
        var f: [String] = []
        if recurring(pressure) { f.append(TF("La memoria è sotto pressione in %@ misure su %@: il Mac comprime o scrive su disco. Chiudi app o aggiungi RAM.", pressure, n)) }
        if recurring(swap) { f.append(TF("Lo swap supera un quarto della RAM in %@ misure su %@.", swap, n)) }
        if recurring(hot) { f.append(TF("Il Mac era caldo e rallentava in %@ misure su %@.", hot, n)) }
        for t in top where recurring(t.times) { f.append(TF("%@ usa spesso molta CPU (%@ misure su %@) mentre lavori.", t.name, t.times, n)) }
        if n < 5 { f.append(TF("Poche misure (%@): per vedere problemi ricorrenti servono più sessioni.", n)) }
        return PerfSummary(samples: n, highPressure: pressure, heavySwap: swap, hot: hot, topInterferers: top, findings: f)
    }
}
