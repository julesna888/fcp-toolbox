import Foundation

public struct RunningProcess: Identifiable, Hashable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    public let cpu: Double
    public let rssBytes: Int64
    public let isUserApp: Bool
}

public enum CheckLevel { case ok, warn }

public struct PreflightCheck: Identifiable {
    public var id: String { title }
    public let title: String
    public let detail: String
    public let level: CheckLevel
}

extension Doctor {
    /// Parses one `ps -o pid=,pcpu=,rss=,comm=` line. The name is the app bundle name if there is one.
    public static func parseProcess(_ line: String) -> RunningProcess? {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count == 4, let pid = Int32(parts[0]), let cpu = Double(parts[1]), let rss = Int64(parts[2]) else { return nil }
        let path = String(parts[3]).trimmingCharacters(in: .whitespaces)
        var name = (path as NSString).lastPathComponent
        var userApp = false
        if let r = path.range(of: ".app/") {
            let before = String(path[..<r.lowerBound])
            name = (before as NSString).lastPathComponent
            // Only top-level apps the user opened, not helpers inside other apps or system ones.
            userApp = path.contains("/Applications/") && !path[r.upperBound...].contains(".app/")
        }
        return RunningProcess(pid: pid, name: name, cpu: cpu, rssBytes: rss * 1024, isUserApp: userApp)
    }

    public static func processes() -> [RunningProcess] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Ao", "pid=,pcpu=,rss=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
            .compactMap { parseProcess(String($0)) }
            .sorted { $0.rssBytes > $1.rssBytes }
    }

    /// Apps that use a lot of memory and could be closed before editing. Final Cut and this app are never listed.
    public static func closable(_ procs: [RunningProcess], minMB: Int64 = 200) -> [RunningProcess] {
        let skip: Set<String> = ["Final Cut Pro", "FCP Toolbox", "Finder"]
        return procs.filter { $0.isUserApp && !skip.contains($0.name) && $0.rssBytes >= minMB * 1_000_000 }
    }

    /// Readiness checks before a long edit. Everything it needs is passed in, so it can be tested.
    public static func preflight(volumes: [Volume], lowSpaceGB: Int, procs: [RunningProcess],
                                 totalRAM: UInt64, lowPower: Bool, thermalSerious: Bool) -> [PreflightCheck] {
        var out: [PreflightCheck] = []
        let low = volumes.filter { $0.free < Int64(lowSpaceGB) * 1_000_000_000 }
        out.append(low.isEmpty
            ? PreflightCheck(title: "Spazio sui dischi", detail: "Tutti i dischi hanno più di \(lowSpaceGB) GB liberi.", level: .ok)
            : PreflightCheck(title: "Spazio sui dischi",
                             detail: low.map { "\($0.name): \(formatBytes($0.free)) liberi" }.joined(separator: " · "), level: .warn))
        let heavy = closable(procs)
        let heavyBytes = heavy.reduce(Int64(0)) { $0 + $1.rssBytes }
        let share = totalRAM == 0 ? 0 : Double(heavyBytes) / Double(totalRAM)
        out.append(share > 0.15
            ? PreflightCheck(title: "Memoria occupata da altre app",
                             detail: "\(heavy.prefix(3).map(\.name).joined(separator: ", ")) usano \(formatBytes(heavyBytes)).", level: .warn)
            : PreflightCheck(title: "Memoria occupata da altre app", detail: "Niente di pesante aperto.", level: .ok))
        out.append(lowPower
            ? PreflightCheck(title: "Risparmio energia", detail: "È attivo: rallenta esportazioni e rendering.", level: .warn)
            : PreflightCheck(title: "Risparmio energia", detail: "Non attivo.", level: .ok))
        out.append(thermalSerious
            ? PreflightCheck(title: "Temperatura", detail: "Il Mac è caldo e sta rallentando.", level: .warn)
            : PreflightCheck(title: "Temperatura", detail: "Nella norma.", level: .ok))
        return out
    }
}
