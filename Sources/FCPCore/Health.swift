import Foundation

/// Everything the health score is computed from. Plain values, so the score can be tested without a disk.
public struct HealthInput: Sendable {
    public var mediaTotal = 0
    public var mediaMissing = 0
    public var freeBytes: Int64?
    public var cacheBytes: Int64 = 0
    public var libraryBytes: Int64 = 0
    public var lastBackup: Date?
    /// Files that are new or changed since that backup. Nil when it could not be compared.
    public var changedSinceBackup: Int?
    public var readable = true
    public var writable = true
    public var now = Date()
    public init() {}
}

public struct HealthIndicator: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    /// 0–100, or nil when it could not be measured (then it does not count in the total).
    public let score: Int?
    public let weight: Int
    public let detail: String
    public let advice: String?
}

public struct HealthReport: Sendable {
    public let score: Int
    public let label: String
    public let indicators: [HealthIndicator]
    /// The weights are an editorial choice, not a scientific measure: the report says so.
    public let note = "Il punteggio è una sintesi dei controlli qui sotto, con pesi scelti da noi: serve a capire da dove cominciare, non è una misura ufficiale di Final Cut."
}

extension Doctor {
    /// Linear ramp: `bad` → 0, `good` → 100, clamped. Works for both directions.
    static func ramp(_ v: Double, bad: Double, good: Double) -> Int {
        Int((max(0, min(1, (v - bad) / (good - bad))) * 100).rounded())
    }

    public static func assessHealth(_ i: HealthInput) -> HealthReport {
        var out: [HealthIndicator] = []

        // Missing media (weight 30): any missing file is a real problem, so the score never stays near 100.
        if i.mediaTotal > 0 {
            let ratio = Double(i.mediaMissing) / Double(i.mediaTotal)
            let s = i.mediaMissing == 0 ? 100 : Int(max(0, 60 * (1 - ratio)).rounded())
            out.append(HealthIndicator(name: "Media collegati", score: s, weight: 30,
                detail: i.mediaMissing == 0 ? TF("Tutti i %@ file sono al loro posto.", i.mediaTotal) : TF("%@ file su %@ non si trovano.", i.mediaMissing, i.mediaTotal),
                advice: i.mediaMissing == 0 ? nil : "Ricollega i file mancanti prima di consegnare o spostare la libreria."))
        } else {
            out.append(HealthIndicator(name: "Media collegati", score: nil, weight: 30, detail: "Nessun file collegato da controllare.", advice: nil))
        }

        // Backup (weight 25): fresh within a week is full marks, 60 days or more is 20; unsaved changes cost 20.
        if let last = i.lastBackup {
            let days = max(0, i.now.timeIntervalSince(last) / 86_400)
            var s = 20 + Int((Double(ramp(days, bad: 60, good: 7)) * 0.8).rounded())
            if let c = i.changedSinceBackup, c > 0 { s = max(0, s - 20) }
            let changes = (i.changedSinceBackup ?? 0) > 0 ? TF(" Da allora sono cambiati %@ file.", i.changedSinceBackup!) : ""
            out.append(HealthIndicator(name: "Backup", score: s, weight: 25,
                detail: TF("Ultimo backup %@ giorni fa.%@", Int(days), changes), advice: s < 80 ? "Fai un backup aggiornato." : nil))
        } else {
            out.append(HealthIndicator(name: "Backup", score: 0, weight: 25, detail: "Nessun backup registrato da FCP Toolbox.",
                                       advice: "Fai un backup su un altro disco. Un solo disco può rompersi."))
        }

        // Free space (weight 20): 50 GB or more is comfortable, 5 GB or less is a risk of failed renders.
        if let f = i.freeBytes {
            let gb = Double(f) / 1e9
            let s = ramp(gb, bad: 5, good: 50)
            out.append(HealthIndicator(name: "Spazio libero", score: s, weight: 20, detail: TF("%@ liberi sul disco della libreria.", formatBytes(f)),
                                       advice: s < 60 ? "Libera spazio: con poco spazio render ed esportazioni possono fallire." : nil))
        } else {
            out.append(HealthIndicator(name: "Spazio libero", score: nil, weight: 20, detail: "Non riesco a leggere lo spazio libero.", advice: nil))
        }

        // Access (weight 15): the library has to be readable and writable or Final Cut cannot use it.
        let access = i.readable ? (i.writable ? 100 : 40) : 0
        out.append(HealthIndicator(name: "Accesso alla libreria", score: access, weight: 15,
            detail: !i.readable ? "La libreria non è leggibile." : (!i.writable ? "La libreria è in sola lettura." : "Leggibile e modificabile."),
            advice: access < 100 ? "Controlla che il disco sia collegato e i permessi corretti." : nil))

        // Regenerable files (weight 10): up to 10% of the library is normal, 50% or more is mostly dead weight.
        if i.libraryBytes > 0 {
            let share = Double(i.cacheBytes) / Double(i.libraryBytes)
            let s = ramp(share, bad: 0.5, good: 0.1)
            out.append(HealthIndicator(name: "File rigenerabili", score: s, weight: 10,
                detail: i.cacheBytes == 0 ? "Niente da rigenerare: nessun render o media ottimizzato." : TF("%@ (%@%) si possono rigenerare.", formatBytes(i.cacheBytes), Int((share * 100).rounded())),
                advice: s < 60 ? "Puoi liberarli da Pulizia: Final Cut li ricrea quando servono." : nil))
        }

        let measured = out.compactMap { o in o.score.map { (s: $0, w: o.weight) } }
        let totalW = measured.reduce(0) { $0 + $1.w }
        let score = totalW == 0 ? 0 : Int((Double(measured.reduce(0) { $0 + $1.s * $1.w }) / Double(totalW)).rounded())
        let label = score >= 85 ? "In buona salute" : (score >= 60 ? "Da controllare" : "Da sistemare")
        return HealthReport(score: score, label: label, indicators: out)
    }

    /// A straight-line estimate from two measurements. It cannot know about a big shoot coming up, so it says it is only an estimate.
    public static func predictSpace(free: Int64, growth: Growth?) -> String? {
        guard let g = growth, g.days >= 1, g.delta > 0 else { return nil }
        let perDay = Double(g.delta) / g.days
        let left = Double(free) / perDay
        return TF("Al ritmo misurato (%@ al giorno in %@ giorni) lo spazio libero finirebbe tra circa %@ giorni. È una stima in linea retta: non conosce i prossimi progetti.", formatBytes(Int64(perDay)), Int(g.days), Int(left))
    }

    /// Reads the real state of a library from disk and scores it.
    public static func health(of library: Library, history: [BackupRecord] = history(), now: Date = Date()) -> HealthReport {
        var i = HealthInput()
        i.now = now
        let node = tree(of: [library]).first
        i.mediaTotal = node?.media ?? 0
        i.mediaMissing = node?.missing ?? 0
        i.libraryBytes = library.total
        i.cacheBytes = library.items.filter { $0.kind == .clean }.reduce(0) { $0 + $1.size }
        i.freeBytes = probe([library.url]).free
        i.readable = fm.isReadableFile(atPath: library.url.path)
        i.writable = fm.isWritableFile(atPath: library.url.path)
        let path = library.url.standardizedFileURL.path
        i.lastBackup = history.filter { $0.source == path }.map(\.date).max()
        if i.lastBackup != nil { i.changedSinceBackup = changesSinceLastBackup(source: library.url, history: history).diff?.toCopy.count }
        return assessHealth(i)
    }
}
