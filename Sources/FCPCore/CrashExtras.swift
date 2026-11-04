import Foundation

extension CrashReport {
    /// The crash time, from the report header ("2026-10-29 14:01:45.00 +0100").
    public var time: Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
        return f.date(from: date)
    }
}

extension Doctor {
    /// A report the user picked by hand, whatever its file name. Nil if it is not a readable .ips.
    public static func importCrash(_ url: URL) -> CrashGroup? {
        guard let r = parseCrash(url) else { return nil }
        return CrashGroup(signature: r.signature, reports: [r], note: explain(r))
    }

    /// What differs between two crash groups; says so plainly when nothing does.
    public static func compare(_ a: CrashGroup, _ b: CrashGroup) -> [String] {
        guard let x = a.reports.first, let y = b.reports.first else { return [] }
        var out: [String] = []
        if x.exception != y.exception { out.append("Eccezione: \(x.exception) contro \(y.exception).") }
        if x.message != y.message { out.append("Messaggio: “\(x.message)” contro “\(y.message)”.") }
        if x.topFrames.first != y.topFrames.first {
            out.append("Punto del crash: \(x.topFrames.first ?? "?") contro \(y.topFrames.first ?? "?").")
        }
        if x.appVersion != y.appVersion { out.append("Versione di Final Cut: \(x.appVersion) contro \(y.appVersion).") }
        if x.osVersion != y.osVersion { out.append("Sistema: \(x.osVersion) contro \(y.osVersion).") }
        let qx = Set(a.reports.map(\.thread)), qy = Set(b.reports.map(\.thread))
        if qx != qy { out.append("Thread coinvolti: \(qx.sorted().joined(separator: ", ")) contro \(qy.sorted().joined(separator: ", ")).") }
        if out.isEmpty { out.append("Stessa causa: eccezione, punto del crash, versione e sistema coincidono.") }
        return out
    }

    /// Looks for a measurable condition near the crash. It reports what it saw, and also when it saw nothing.
    public static func correlate(_ r: CrashReport, perf: [PerfSample], snapshots: [LibrarySnapshot] = [],
                                 window: TimeInterval = 600) -> [String] {
        guard let t = r.time else { return ["Orario del crash non leggibile: impossibile confrontarlo con altre misure."] }
        var out: [String] = []
        let near = perf.filter { abs($0.date.timeIntervalSince(t)) <= window }
        if near.isEmpty {
            out.append("Nessuna misura delle prestazioni entro \(Int(window / 60)) minuti dal crash: non posso dire se memoria o calore c'entrino.")
        } else {
            if near.contains(where: { $0.pressure >= 2 }) { out.append("Memoria sotto pressione vicino al crash.") }
            if near.contains(where: { $0.memTotal > 0 && Double($0.swapUsed) / Double($0.memTotal) > 0.25 }) { out.append("Swap alto vicino al crash.") }
            if near.contains(where: { $0.thermal >= 2 }) { out.append("Il Mac era caldo vicino al crash.") }
            if out.isEmpty { out.append("Misure vicine al crash (\(near.count)): memoria, swap e temperatura nella norma.") }
        }
        let before = snapshots.filter { $0.date <= t }.sorted { $0.date < $1.date }
        var latest: [String: LibrarySnapshot] = [:]
        for s in before { latest[s.path] = s }
        if let big = latest.values.max(by: { $0.total < $1.total }) {
            out.append("Libreria più grande allora: \((big.path as NSString).lastPathComponent), \(formatBytes(big.total)).")
        }
        return out
    }

    /// A plain-text technical report for a support request.
    public static func technicalReport(_ g: CrashGroup, perf: [PerfSample] = [], snapshots: [LibrarySnapshot] = []) -> String {
        guard let r = g.reports.first else { return "" }
        var s = "# Report crash Final Cut Pro\n\n"
        s += "- Versione: \(r.appVersion)\n- Sistema: \(r.osVersion)\n- Crash con questa firma: \(g.reports.count)\n"
        s += "- Ultimo: \(r.date)\n- Eccezione: \(r.exception)\n"
        if !r.message.isEmpty { s += "- Messaggio: \(r.message)\n" }
        if !r.thread.isEmpty { s += "- Thread: \(r.thread)\n" }
        s += "\n## Primi frame\n" + r.topFrames.map { "- \($0)" }.joined(separator: "\n") + "\n"
        s += "\n## Correlazioni misurate\n" + correlate(r, perf: perf, snapshots: snapshots).map { "- \($0)" }.joined(separator: "\n") + "\n"
        s += "\n## Valutazione\n\(g.note)\n"
        s += "\nQuesta è un'ipotesi dai dati del report: la causa non è dimostrata.\n"
        return s
    }
}
