import Foundation

/// What a dropped file is, decided from its extension (or from being a folder).
public enum FileKind: String, CaseIterable, Sendable {
    case video, audio, image, subtitle, folder, other
    /// Only used in `ToolEntry.accepts`: "any file". `FileKind.of` never returns it.
    case any

    static let video_: Set<String> = ["mov", "mp4", "m4v", "mxf", "mkv", "avi", "mts", "m2ts", "webm", "mpg", "mpeg", "wmv", "3gp", "flv", "mpg4"]
    static let audio_: Set<String> = ["wav", "mp3", "aac", "m4a", "aif", "aiff", "flac", "ogg", "caf", "wma"]
    static let image_: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp", "dng"]
    static let subtitle_: Set<String> = ["srt", "vtt"]

    public static func of(_ url: URL) -> FileKind {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? nil
        if isDir == true || (isDir == nil && url.hasDirectoryPath) { return .folder }
        let e = url.pathExtension.lowercased()
        if video_.contains(e) { return .video }
        if audio_.contains(e) { return .audio }
        if image_.contains(e) { return .image }
        if subtitle_.contains(e) { return .subtitle }
        return .other
    }
}

/// Where a catalog entry leads. Plain strings keep FCPCore free of UI types: the app maps them
/// (a test in the app target checks every string really exists).
public enum ToolTarget: Equatable, Sendable {
    /// A sidebar screen (`Tool` raw value).
    case sidebar(String)
    /// A card of "Strumenti" (`ToolsView.Extra` raw value).
    case extra(String)
    /// A conversion card of "Strumenti" (`ConvertTool` raw value).
    case convert(String)
    /// A tab of "Controlla video" (`InspectorView.Mode` raw value).
    case inspector(String)
}

public struct ToolEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    /// Italian + English words people may type; matching ignores case and accents.
    public let keywords: [String]
    /// File kinds the tool can start from. Empty = it does not take files (opens empty).
    public let accepts: Set<FileKind>
    public let target: ToolTarget
}

public struct ToolSuggestion: Identifiable, Equatable, Sendable {
    public let entry: ToolEntry
    /// False when the tool only suits some of the dropped files.
    public let suitsAll: Bool
    public var id: String { entry.id }
}

public enum ToolCatalog {
    private static func e(_ id: String, _ title: String, _ summary: String, _ keywords: [String],
                          _ accepts: [FileKind], _ target: ToolTarget) -> ToolEntry {
        ToolEntry(id: id, title: title, summary: summary, keywords: keywords, accepts: Set(accepts), target: target)
    }

    /// THE list of tools. To add a screen: append one line here, and map its target in the app.
    public static let all: [ToolEntry] = [
        e("convert.prepare", "Prepara il video per montare", "Per i video del telefono che in Final Cut vanno fuori sincro: li converte in un formato stabile.",
          ["converti", "conversione", "convert", "convert video", "transcode", "fps", "frame rate", "h264", "mp4", "variabile", "vfr", "telefono", "iphone"],
          [.video], .convert("prepare")),
        e("convert.audio", "Estrai o converti l'audio", "Prende l'audio da un video, o cambia formato a un file audio.",
          ["estrai audio", "extract audio", "audio", "mp3", "wav", "aac", "colonna sonora", "convert audio", "rip"],
          [.video, .audio], .convert("audio")),
        e("convert.normalize", "Sistema il volume per i social", "Porta il volume al livello giusto per Instagram e YouTube.",
          ["volume", "loudness", "lufs", "normalize", "normalizza", "livello audio", "troppo basso", "social", "audio basso"],
          [.video, .audio], .convert("normalize")),
        e("convert.compress", "Rimpicciolisci per inviare", "Fa pesare meno il file per mandarlo su WhatsApp, Telegram o email.",
          ["comprimi", "compressione", "compress", "compress video", "ridurre peso", "alleggerisci", "piccolo", "whatsapp", "telegram", "email", "mail", "size", "mb", "shrink"],
          [.video], .convert("compress")),
        e("convert.still", "Copertina da un video", "Salva un fotogramma a metà video come JPG.",
          ["copertina", "thumbnail", "miniatura", "fotogramma", "frame", "still", "cover", "screenshot", "jpg"],
          [.video], .convert("still")),
        e("info", "Info file", "Codec, bitrate, fps reali, risoluzione, audio, spazio occupato, metadata.",
          ["info", "analisi", "analizza", "analyze", "dettagli", "codec", "bitrate", "fps", "risoluzione", "resolution", "ffprobe", "mediainfo", "propriet\u{00E0}"],
          [.video, .audio, .image, .folder], .extra("Info file")),
        e("rename", "Rinomina in blocco", "Prefisso, numero progressivo, data, cerca e sostituisci.",
          ["rinomina", "rename", "batch rename", "nomi", "numerazione", "prefisso", "sostituisci", "renumber"],
          [.any], .extra("Rinomina in blocco")),
        e("ratio", "Calcolatore proporzioni", "16:9, 9:16, 1:1, 4:5, 2.39:1: misure di uscita senza deformare.",
          ["proporzioni", "aspect ratio", "formato", "verticale", "vertical", "quadrato", "16:9", "9:16", "calcolatore", "misure"],
          [], .extra("Calcolatore proporzioni")),
        e("shots", "Cambi di inquadratura", "Trova gli stacchi di un video e dà la lista dei timecode.",
          ["stacchi", "tagli", "scene", "scene detection", "shot", "cut", "cambi", "inquadratura", "timecode", "marker"],
          [.video], .extra("Cambi di inquadratura")),
        e("contact", "Foglio provini", "Griglia di fotogrammi di un video o di una cartella.",
          ["provini", "contact sheet", "griglia", "anteprima", "preview", "miniature", "thumbnails", "sheet"],
          [.video, .folder], .extra("Foglio provini")),
        e("trim", "Taglia clip", "Taglia una clip senza aprire un editor, veloce o preciso.",
          ["taglia", "trim", "cut", "ritaglia", "accorcia", "inizio fine", "in out", "clip"],
          [.video], .extra("Taglia clip")),
        e("metadata", "Pulisci metadata", "Toglie GPS, dispositivo, date o autore da foto e video.",
          ["metadata", "metadati", "gps", "posizione", "privacy", "exif", "pulisci", "clean", "strip", "autore", "dispositivo"],
          [.video, .image], .extra("Pulisci metadata")),
        e("palette", "Colori e palette", "Colori principali di un fotogramma o di un punto dello schermo.",
          ["colori", "colors", "palette", "colore", "contagocce", "eyedropper", "hex", "dominante"],
          [.image, .video], .extra("Colori e palette")),
        e("safe", "Aree sicure social", "Dove Instagram, TikTok e YouTube coprono l'immagine.",
          ["aree sicure", "safe area", "safe zone", "instagram", "tiktok", "youtube", "reel", "shorts", "social"],
          [], .extra("Aree sicure social")),
        e("dups", "Doppioni", "File doppi anche con nomi diversi, anche ricodificati.",
          ["doppioni", "duplicati", "duplicates", "duplicate", "doppi", "uguali", "copie", "dedupe", "identici"],
          [.folder], .extra("Doppioni")),
        e("search", "Cerca nei filmati", "Scrivi cosa cerchi e trova le clip. AI locale e gratuita.",
          ["cerca", "ricerca", "search", "find", "filmati", "clip", "trova", "footage", "persona", "ai"],
          [], .extra("Cerca nei filmati")),
        e("queue", "Coda di lavori", "Metti in coda più lavori: uno alla volta, con stop e riprova.",
          ["coda", "queue", "batch", "lavori", "elaborazione", "in blocco", "processing", "jobs"],
          [], .extra("Coda di lavori")),
        e("presets", "Preset di lavoro", "Ricette salvate (es. Prepara per Instagram) da applicare a molti file.",
          ["preset", "ricetta", "workflow", "instagram", "prepara", "flusso", "automatico"],
          [.video], .extra("Preset di lavoro")),
        e("describe", "Descrivi clip", "Descrizione automatica in italiano di cosa si vede in ogni clip. AI locale.",
          ["descrivi", "descrizione", "describe", "didascalia", "cosa c'è", "contenuto", "ai", "etichette", "tag"],
          [.video, .folder], .extra("Descrivi clip")),
        e("download", "Scarica da link", "Incolla un link YouTube, Instagram o TikTok e salva video o audio.",
          ["scarica", "download", "link", "youtube", "instagram", "tiktok", "yt-dlp", "mp3", "url"],
          [], .sidebar("Scarica da link")),
        e("subtitles", "Sottotitoli SRT/VTT", "Controlla leggibilit\u{00E0}, sistema la punteggiatura (copia), converti SRT in VTT e viceversa.",
          ["sottotitoli", "subtitles", "subs", "srt", "vtt", "didascalie", "captions", "punteggiatura", "converti srt", "leggibilit\u{00E0}"],
          [.subtitle], .inspector("Sottotitoli")),
        e("delivery", "Controllo consegna", "Verifica se un video rispetta i requisiti di una consegna.",
          ["consegna", "delivery", "controllo", "verifica", "requisiti", "specifiche", "export check", "broadcast"],
          [.video, .folder], .inspector("Controllo consegna")),
        e("proxy", "Copie leggere (proxy)", "Crea copie leggere dei video per montare su un Mac lento.",
          ["proxy", "copie leggere", "mac lento", "leggeri", "fluido", "lag", "scatta"],
          [.video, .folder], .inspector("Copie leggere (proxy)")),
        e("freeSpace", "Libera spazio", "Trova cosa occupa spazio e liberalo senza toccare gli originali.",
          ["spazio", "libera spazio", "disco pieno", "free space", "storage", "cache", "render", "pulizia", "cleanup", "disk full"],
          [], .sidebar("Libera spazio")),
        e("pool", "Ordina cartelle clienti", "Metti in ordine i file ricevuti dai clienti.",
          ["clienti", "cartelle", "ordina", "organizza", "organize", "client", "pool", "consegne"],
          [], .sidebar("Ordina cartelle clienti")),
        e("preflight", "Controllo prima di montare", "Controlla i file prima di importarli in Final Cut.",
          ["preflight", "prima di montare", "controllo", "check", "importare", "import", "problemi"],
          [], .sidebar("Controllo prima di montare")),
        e("crash", "Diagnosi crash Final Cut", "Capisce perch\u{00E9} Final Cut si blocca o si chiude.",
          ["crash", "si blocca", "si chiude", "bloccato", "freeze", "diagnosi", "diagnose", "final cut", "fcp", "errore"],
          [], .sidebar("Diagnosi crash Final Cut")),
        e("automations", "Avvisi automatici", "Notifiche quando un disco \u{00E8} quasi pieno e altri controlli.",
          ["avvisi", "notifiche", "alert", "notifications", "automatici", "automations", "automazioni", "disco quasi pieno"],
          [], .sidebar("Avvisi automatici")),
    ]

    public static func entry(_ id: String) -> ToolEntry? { all.first { $0.id == id } }

    // MARK: Universal search

    /// Lowercase, no accents, single spaces.
    static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "it_IT"))
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    private static func isSubsequence(_ small: String, of big: String) -> Bool {
        var it = big.makeIterator()
        return small.allSatisfy { c in
            while let n = it.next() { if n == c { return true } }
            return false
        }
    }

    /// Score of one query word against one entry; 0 = no match.
    private static func score(_ token: String, _ entry: ToolEntry, title: [String], keywords: [String], summary: String) -> Int {
        var best = 0
        if keywords.contains(token) { best = 6 }
        for k in keywords { if k.hasPrefix(token) || k.split(separator: " ").contains(where: { $0.hasPrefix(token) }) { best = max(best, 5) } }
        for w in title where w.hasPrefix(token) { best = max(best, 5) }
        if best > 0 { return best }
        if title.joined(separator: " ").contains(token) { return 3 }
        if keywords.contains(where: { $0.contains(token) }) { return 3 }
        if summary.contains(token) { return 1 }
        // typo tolerance: letters in order inside a title/keyword word ("cmprimi" -> "comprimi")
        if token.count >= 4, (title + keywords.flatMap { $0.split(separator: " ").map(String.init) }).contains(where: { isSubsequence(token, of: $0) }) { return 1 }
        return 0
    }

    /// Entries matching every word typed, best first. Empty query returns the whole catalog in order.
    public static func search(_ query: String, in list: [ToolEntry] = all) -> [ToolEntry] {
        let tokens = normalize(query).split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return list }
        var scored: [(ToolEntry, Int, Int)] = []
        for (i, entry) in list.enumerated() {
            let title = normalize(entry.title).split(separator: " ").map(String.init)
            let keywords = entry.keywords.map(normalize)
            let summary = normalize(entry.summary)
            var total = 0
            for t in tokens {
                let s = score(t, entry, title: title, keywords: keywords, summary: summary)
                if s == 0 { total = 0; break }
                total += s
            }
            if total > 0 { scored.append((entry, total, i)) }
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }.map(\.0)
    }

    // MARK: Drop suggestions

    /// Preferred order per kind (what an editor most likely wants first). Others follow in catalog order.
    static let preferred: [FileKind: [String]] = [
        .video: ["info", "convert.prepare", "convert.audio", "convert.compress", "contact", "shots", "trim", "convert.still", "convert.normalize", "metadata", "delivery", "proxy", "palette", "rename"],
        .audio: ["info", "convert.audio", "convert.normalize", "rename"],
        .image: ["info", "metadata", "palette", "rename"],
        .subtitle: ["subtitles", "rename"],
        .folder: ["dups", "contact", "info", "delivery", "proxy", "rename"],
    ]

    /// Tools to propose for dropped files, best first. Tools that suit every file come first.
    public static func suggestions(for urls: [URL], in list: [ToolEntry] = all) -> [ToolSuggestion] {
        guard !urls.isEmpty else { return [] }
        let kinds = urls.map(FileKind.of)
        let present = Set(kinds)
        func suits(_ e: ToolEntry, _ k: FileKind) -> Bool { e.accepts.contains(.any) || e.accepts.contains(k) }
        var out: [(ToolSuggestion, Int)] = []
        for (i, e) in list.enumerated() {
            let n = kinds.filter { suits(e, $0) }.count
            guard n > 0 else { continue }
            let rank = present.compactMap { k in preferred[k]?.firstIndex(of: e.id) }.min() ?? 100 + i
            out.append((ToolSuggestion(entry: e, suitsAll: n == kinds.count), rank))
        }
        return out.sorted { a, b in
            if a.0.suitsAll != b.0.suitsAll { return a.0.suitsAll }
            return a.1 < b.1
        }.map(\.0)
    }

    /// "2 video, 1 immagine": what was dropped, in plain Italian.
    public static func describe(_ urls: [URL]) -> String {
        let kinds = urls.map(FileKind.of)
        let names: [(FileKind, String, String)] = [
            (.video, "video", "video"), (.audio, "audio", "audio"), (.image, "immagine", "immagini"),
            (.subtitle, "sottotitolo", "sottotitoli"), (.folder, "cartella", "cartelle"), (.other, "altro file", "altri file"),
        ]
        return names.compactMap { k, one, many in
            let n = kinds.filter { $0 == k }.count
            return n == 0 ? nil : "\(n) \(n == 1 ? one : many)"
        }.joined(separator: ", ")
    }
}
