import Foundation

/// One clip that came into the pool and the day it goes to the Trash.
public struct PoolExpiryEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let importedAt: Date
    public let expiresAt: Date
}

public struct PoolExpiryReport: Sendable {
    public var trashed: [URL] = []
    /// Entries dropped because the file was already gone (moved or deleted by the user).
    public var gone = 0
    public var skipped: [String] = []
    public var failures: [String] = []
}

/// Clips in the pool are moved to the Trash exactly 30 days after they were imported. Folders are never touched.
extension Doctor {
    public static let poolExpiryDays = 30

    public static var poolExpiryLedgerURL: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/FCP Toolbox/pool-expiry.json")
    }

    /// The moment a clip imported at `date` expires: 30 calendar days later, same time of day.
    public static func poolExpiryDate(importedAt date: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: poolExpiryDays, to: date) ?? date.addingTimeInterval(Double(poolExpiryDays) * 86_400)
    }

    private static func coder() -> (JSONEncoder, JSONDecoder) {
        let e = JSONEncoder(), d = JSONDecoder()
        e.dateEncodingStrategy = .iso8601
        d.dateDecodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (e, d)
    }

    public static func poolExpiryEntries(ledger: URL = poolExpiryLedgerURL) -> [PoolExpiryEntry] {
        guard let data = try? Data(contentsOf: ledger), let list = try? coder().1.decode([PoolExpiryEntry].self, from: data) else { return [] }
        return list.sorted { $0.expiresAt < $1.expiresAt }
    }

    private static func savePoolExpiry(_ list: [PoolExpiryEntry], ledger: URL) {
        try? fm.createDirectory(at: ledger.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? coder().0.encode(list) { try? data.write(to: ledger, options: .atomic) }
    }

    /// Remembers the clips that were just put in the pool. A clip already in the list keeps its original date.
    public static func recordPoolImport(_ files: [URL], at date: Date = Date(), ledger: URL = poolExpiryLedgerURL) {
        var list = poolExpiryEntries(ledger: ledger)
        let known = Set(list.map(\.path))
        for f in files where !known.contains(f.path) {
            list.append(PoolExpiryEntry(path: f.path, importedAt: date, expiresAt: poolExpiryDate(importedAt: date)))
        }
        savePoolExpiry(list, ledger: ledger)
    }

    /// The user keeps these clips: they are taken off the list (everything under `folder`).
    @discardableResult
    public static func cancelPoolExpiry(under folder: URL, ledger: URL = poolExpiryLedgerURL) -> Int {
        let list = poolExpiryEntries(ledger: ledger)
        let kept = list.filter { !$0.path.hasPrefix(folder.path + "/") }
        if kept.count != list.count { savePoolExpiry(kept, ledger: ledger) }
        return list.count - kept.count
    }

    /// Moves every clip whose day has come to the Trash (recoverable from there). Only files from the list, never folders,
    /// never anything in "Original Media" or inside a Final Cut library. Runs at launch and every few minutes.
    @discardableResult
    public static func expirePoolClips(now: Date = Date(), ledger: URL = poolExpiryLedgerURL, operationsLog: URL = operationsLogURL,
                                       trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> PoolExpiryReport {
        var report = PoolExpiryReport()
        let list = poolExpiryEntries(ledger: ledger)
        let due = list.filter { $0.expiresAt <= now }
        guard !due.isEmpty else { return report }
        var finished = Set<String>()
        var bytes: Int64 = 0
        for e in due {
            let url = URL(fileURLWithPath: e.path)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: e.path, isDirectory: &isDir) else { report.gone += 1; finished.insert(e.path); continue }
            if isDir.boolValue || e.path.contains("Original Media") || e.path.contains(".fcpbundle") {
                report.skipped.append("\(url.lastPathComponent): non è una clip del pool, non lo tocco")
                finished.insert(e.path)
                continue
            }
            let size = byteSize(url)
            do {
                try trash(url)
                report.trashed.append(url)
                bytes += size
                finished.insert(e.path)
            } catch {
                report.failures.append("\(url.lastPathComponent): \(error.localizedDescription)")  // stays in the list, tried again later
            }
        }
        savePoolExpiry(list.filter { !finished.contains($0.path) }, ledger: ledger)
        if !report.trashed.isEmpty {
            let parent = report.trashed[0].deletingLastPathComponent()
            _ = logOperation(kind: "pool-expiry", summary: "Cestinate \(report.trashed.count) clip del pool scadute dopo \(poolExpiryDays) giorni (le cartelle restano)",
                             paths: report.trashed, estimated: bytes, failures: report.failures, before: probe([parent]), log: operationsLog)
        }
        return report
    }

    public static var poolWarnedURL: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/FCP Toolbox/pool-expiry-warned.json")
    }

    /// Warnings for clips that go to the Trash within `withinDays` days: one per video folder, each shown once per day
    /// (what was already shown is remembered in `warned`, so the five-minute timer does not repeat it).
    public static func poolExpiryWarnings(now: Date = Date(), withinDays: Int = 3,
                                          ledger: URL = poolExpiryLedgerURL, warned: URL = poolWarnedURL) -> [AutomationEvent] {
        let limit = now.addingTimeInterval(Double(withinDays) * 86_400)
        let soon = poolExpiryEntries(ledger: ledger).filter { $0.expiresAt > now && $0.expiresAt <= limit }
        guard !soon.isEmpty else { return [] }
        var seen = Set((try? JSONDecoder().decode([String].self, from: Data(contentsOf: warned))) ?? [])
        let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd"; dayFmt.locale = Locale(identifier: "en_US_POSIX")
        let shown = DateFormatter(); shown.dateFormat = "d MMMM 'alle' HH:mm"; shown.locale = Locale(identifier: "it_IT")
        let today = dayFmt.string(from: now)
        var events: [AutomationEvent] = []
        let byFolder = Dictionary(grouping: soon) { URL(fileURLWithPath: $0.path).deletingLastPathComponent().deletingLastPathComponent() }
        for (folder, entries) in byFolder.sorted(by: { $0.key.path < $1.key.path }) {
            let key = "pool-expiry-\(folder.path)-\(today)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let first = entries.map(\.expiresAt).min() ?? now
            let days = max(1, Int((first.timeIntervalSince(now) / 86_400).rounded(.up)))
            let name = folder.deletingLastPathComponent().lastPathComponent + " / " + folder.lastPathComponent
            events.append(AutomationEvent(
                key: key, title: "Clip del pool in scadenza",
                body: "«\(name)»: \(entries.count) clip vanno nel Cestino il \(shown.string(from: first)) (tra \(days) \(days == 1 ? "giorno" : "giorni")). Per tenerle: FCP Toolbox, Ordina cartelle clienti, «Tieni per sempre»."))
        }
        if !events.isEmpty {
            try? fm.createDirectory(at: warned.deletingLastPathComponent(), withIntermediateDirectories: true)
            // only today's keys are kept: the list never grows
            let keep = seen.filter { $0.hasSuffix("-" + today) }
            if let data = try? JSONEncoder().encode(Array(keep).sorted()) { try? data.write(to: warned, options: .atomic) }
        }
        return events
    }
}
