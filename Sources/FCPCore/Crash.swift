import Foundation

/// One Final Cut crash, read from a macOS `.ips` report.
public struct CrashReport: Identifiable, Hashable {
    public var id: URL { url }
    public let url: URL
    public let date: String
    public let appVersion: String
    public let osVersion: String
    public let exception: String
    public let message: String
    public let thread: String
    public let topFrames: [String]

    /// Same signature = same bug.
    public var signature: String { "\(exception) · \(message.isEmpty ? (topFrames.first ?? "?") : message)" }
}

public struct CrashGroup: Identifiable {
    public var id: String { signature }
    public let signature: String
    public let reports: [CrashReport]
    public let note: String
}

extension Doctor {
    public static var crashFolders: [URL] {
        let base = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/DiagnosticReports")
        return [base, base.appendingPathComponent("Retired")]
    }

    /// Parses an `.ips` file (a JSON header line, then a JSON body). Nil if it is not readable.
    public static func parseCrash(_ url: URL) -> CrashReport? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let nl = text.firstIndex(of: "\n"),
              let head = try? JSONSerialization.jsonObject(with: Data(text[..<nl].utf8)) as? [String: Any],
              let body = try? JSONSerialization.jsonObject(with: Data(text[text.index(after: nl)...].utf8)) as? [String: Any]
        else { return nil }
        let exc = body["exception"] as? [String: Any]
        let type = (exc?["type"] as? String) ?? "?"
        let signal = (exc?["signal"] as? String).map { " (\($0))" } ?? ""
        let asi = (body["asi"] as? [String: [String]])?.values.first?.first ?? ""
        let images = body["usedImages"] as? [[String: Any]] ?? []
        let threads = body["threads"] as? [[String: Any]] ?? []
        let fault = body["faultingThread"] as? Int ?? 0
        let th = fault < threads.count ? threads[fault] : [:]
        let frames = (th["frames"] as? [[String: Any]] ?? []).prefix(5).map { f -> String in
            let img = (f["imageIndex"] as? Int).flatMap { $0 < images.count ? images[$0]["name"] as? String : nil } ?? "?"
            return "\(img): \(f["symbol"] as? String ?? "?")"
        }
        return CrashReport(url: url, date: head["timestamp"] as? String ?? "",
                           appVersion: head["app_version"] as? String ?? "?",
                           osVersion: head["os_version"] as? String ?? "?",
                           exception: type + signal, message: asi,
                           thread: th["queue"] as? String ?? "", topFrames: Array(frames))
    }

    /// Final Cut crash reports from the given folders, grouped by signature, biggest group first.
    public static func crashes(in folders: [URL] = crashFolders) -> [CrashGroup] {
        var reports: [CrashReport] = []
        for folder in folders {
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for f in files where f.pathExtension == "ips" && f.lastPathComponent.hasPrefix("Final Cut Pro") {
                if let r = parseCrash(f) { reports.append(r) }
            }
        }
        reports.sort { $0.date > $1.date }
        return Dictionary(grouping: reports, by: \.signature)
            .map { CrashGroup(signature: $0.key, reports: $0.value, note: explain($0.value[0])) }
            .sorted { $0.reports.count > $1.reports.count }
    }

    static func explain(_ r: CrashReport) -> String {
        if r.message.contains("Invalid view geometry") {
            return "Final Cut ha provato a disegnare una vista con una misura non valida (NaN). È un errore interno dell'interfaccia, non dei tuoi file. Capita spesso quando la versione di Final Cut (\(r.appVersion)) è troppo vecchia per il sistema (\(r.osVersion)): aggiorna Final Cut Pro dall'App Store. Se non basta, prova a ricreare le impostazioni: chiudi Final Cut e sposta in Cestino ~/Library/Preferences/com.apple.FinalCut.plist."
        }
        return "Causa non riconosciuta. Allega il report quando scrivi all'assistenza Apple."
    }

    /// A short text to paste into a support request.
    public static func supportText(_ g: CrashGroup) -> String {
        guard let r = g.reports.first else { return "" }
        return """
        Final Cut Pro \(r.appVersion) su \(r.osVersion)
        \(g.reports.count) crash con la stessa firma: \(g.signature)
        Ultimo: \(r.date)
        Thread: \(r.thread)
        Frame:
        \(r.topFrames.map { "  " + $0 }.joined(separator: "\n"))
        """
    }
}
