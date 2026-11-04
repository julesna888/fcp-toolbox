import Foundation

/// What the user switched on. Everything is off until the master switch is on, and each rule can be turned off alone.
public struct AutomationConfig: Codable, Equatable, Sendable {
    public var enabled = false
    public var lowSpace = true
    public var lowSpaceGB = 20
    public var backupReminder = true
    public var backupDays = 7
    public var crashWatch = true
    public var weeklyReport = false
    /// Folder where exports land; new files there are checked against `deliveryProfile`.
    public var deliveryFolder: String?
    public var deliveryProfile = "YouTube"
    public init() {}
}

/// What the rules remember between runs, so the same alert is not repeated every few minutes.
public struct AutomationState: Codable, Equatable, Sendable {
    public var lastAlert: [String: Date] = [:]
    public var seenCrashes: [String] = []
    public var crashesInitialised = false
    public var lastReport: Date?
    public var deliveryChecked: Date?
    public init() {}
}

public struct AutomationEvent: Equatable, Sendable {
    public let key: String
    public let title: String
    public let body: String
}

/// The outside world, injectable: tests give fakes, the app uses `.live`.
public struct AutomationEnv {
    public var now: () -> Date
    public var libraries: () -> [URL]
    public var freeSpace: (URL) -> Int64?
    public var backups: () -> [BackupRecord]
    public var crashFiles: () -> [String]
    /// New exports in a folder since a date, with the problems found against a delivery profile.
    public var deliveryProblems: (_ folder: URL, _ profile: String, _ since: Date) -> [(file: String, problems: [String])]
    public var writeReport: (_ text: String) -> URL?

    public static var live: AutomationEnv {
        AutomationEnv(
            now: { Date() },
            libraries: { Doctor.findBundles(in: Doctor.defaultRoots).filter { !Doctor.isAutomaticBackup($0) } },
            freeSpace: { Doctor.probe([$0]).free },
            backups: { Doctor.history() },
            crashFiles: { Doctor.crashes().flatMap(\.reports).map(\.url.path) },
            deliveryProblems: { folder, profile, since in Doctor.checkNewExports(in: folder, profile: profile, since: since) },
            writeReport: { Doctor.writeWeeklyReport($0) })
    }
}

extension Doctor {
    public static var defaultRoots: [URL] {
        let h = NSHomeDirectory()
        return [URL(fileURLWithPath: h + "/Movies")] + ((try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? []).map { URL(fileURLWithPath: "/Volumes/" + $0) }
            .filter { $0.resolvingSymlinksInPath().path != "/" }  // "Macintosh HD" is a link to the whole boot disk
    }

    static var appSupport: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FCP Toolbox")
    }

    public static var automationConfigURL: URL { appSupport.appendingPathComponent("automation-config.json") }
    public static var automationStateURL: URL { appSupport.appendingPathComponent("automation-state.json") }

    static func loadJSON<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(T.self, from: d)
    }

    static func saveJSON<T: Encodable>(_ v: T, at url: URL) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard let d = try? enc.encode(v) else { return }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }

    public static func loadAutomationConfig(at url: URL = automationConfigURL) -> AutomationConfig { loadJSON(AutomationConfig.self, at: url) ?? AutomationConfig() }
    public static func saveAutomationConfig(_ c: AutomationConfig, at url: URL = automationConfigURL) { saveJSON(c, at: url) }
    public static func loadAutomationState(at url: URL = automationStateURL) -> AutomationState { loadJSON(AutomationState.self, at: url) ?? AutomationState() }
    public static func saveAutomationState(_ s: AutomationState, at url: URL = automationStateURL) { saveJSON(s, at: url) }

    /// One pass of the enabled rules. Returns what to tell the user; never changes or deletes any file of the user.
    /// The caller decides when to run it (the app does it every few minutes while it is open).
    public static func runAutomations(_ config: AutomationConfig, state: inout AutomationState, env: AutomationEnv = .live) -> [AutomationEvent] {
        guard config.enabled else { return [] }
        let now = env.now()
        var events: [AutomationEvent] = []

        /// The same alert is shown at most once a day.
        func emit(_ key: String, _ title: String, _ body: String) {
            if let last = state.lastAlert[key], now.timeIntervalSince(last) < 86_400 { return }
            state.lastAlert[key] = now
            events.append(AutomationEvent(key: key, title: title, body: body))
        }

        let libs = env.libraries()

        if config.lowSpace {
            var seen = Set<String>()
            for lib in libs {
                guard let free = env.freeSpace(lib) else { continue }
                let volume = probe([lib]).volume?.path ?? lib.deletingLastPathComponent().path
                guard seen.insert(volume).inserted, free < Int64(config.lowSpaceGB) * 1_000_000_000 else { continue }
                emit("space:\(volume)", "Poco spazio libero", "Restano \(formatBytes(free)) sul disco di \"\(lib.lastPathComponent)\". Soglia: \(config.lowSpaceGB) GB.")
            }
        }

        if config.backupReminder {
            let history = env.backups()
            for lib in libs {
                let path = lib.standardizedFileURL.path
                let last = history.filter { $0.source == path }.map(\.date).max()
                let days = last.map { now.timeIntervalSince($0) / 86_400 }
                if days == nil || days! >= Double(config.backupDays) {
                    emit("backup:\(path)", "Backup da fare", days == nil ? "\"\(lib.lastPathComponent)\" non ha mai avuto un backup." : "L'ultimo backup di \"\(lib.lastPathComponent)\" è di \(Int(days!)) giorni fa.")
                }
            }
        }

        if config.crashWatch {
            let files = env.crashFiles()
            if !state.crashesInitialised {
                state.crashesInitialised = true  // the first run only learns what already exists
            } else {
                let fresh = files.filter { !state.seenCrashes.contains($0) }
                if !fresh.isEmpty { emit("crash:\(fresh.sorted().last!)", "Final Cut si è chiuso", "\(fresh.count) nuovo rapporto di crash. Aprilo da \"Crash di Final Cut\".") }
            }
            state.seenCrashes = files
        }

        if config.weeklyReport, state.lastReport.map({ now.timeIntervalSince($0) >= 7 * 86_400 }) ?? true {
            var lines = ["FCP Toolbox — report del \(ISO8601DateFormatter().string(from: now))", ""]
            for lib in libs {
                let r = health(of: scan(lib), history: env.backups(), now: now)
                lines.append("\(lib.lastPathComponent): \(r.score)/100 — \(r.label)")
                for i in r.indicators { lines.append("  • \(i.name): \(i.score.map { "\($0)/100" } ?? "non misurato") — \(i.detail)") }
            }
            if libs.isEmpty { lines.append("Nessuna libreria trovata.") }
            if let url = env.writeReport(lines.joined(separator: "\n")) {
                state.lastReport = now
                emit("report", "Report settimanale pronto", url.lastPathComponent)
            }
        }

        if let folder = config.deliveryFolder, !folder.isEmpty {
            let since = state.deliveryChecked ?? now
            for r in env.deliveryProblems(URL(fileURLWithPath: folder), config.deliveryProfile, since) where !r.problems.isEmpty {
                emit("delivery:\(r.file)", "Export da controllare", "\(r.file) non rispetta \"\(config.deliveryProfile)\": \(r.problems.joined(separator: " "))")
            }
            state.deliveryChecked = now
        }
        return events
    }

    /// New media files in `folder` modified after `since`, checked against the named profile (built-in or custom).
    public static func checkNewExports(in folder: URL, profile: String, since: Date) -> [(file: String, problems: [String])] {
        guard let spec = (deliveryProfiles + loadCustomSpecs()).first(where: { $0.name == profile }) else { return [] }
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.compactMap { u -> (String, [String])? in
            guard mediaExtensions.contains(u.pathExtension.lowercased()),
                  let m = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m > since,
                  let info = try? probeMedia(u) else { return nil }
            return (u.lastPathComponent, checkDelivery(info, spec: spec).filter { !$0.ok }.map(\.detail))
        }
    }

    /// Reports are plain text files in App Support; an existing report is never overwritten.
    public static func writeWeeklyReport(_ text: String) -> URL? {
        let dir = appSupport.appendingPathComponent("reports")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let day = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        var url = dir.appendingPathComponent("Report \(day).txt")
        var n = 2
        while fm.fileExists(atPath: url.path) { url = dir.appendingPathComponent("Report \(day) \(n).txt"); n += 1 }
        return (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }
}
