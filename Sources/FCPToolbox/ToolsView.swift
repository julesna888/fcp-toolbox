import AppKit
import FCPCore
import SwiftUI
import UniformTypeIdentifiers

/// Runs the files one after the other: a single ffmpeg at a time keeps the Mac usable.
@MainActor final class ConvertJob: ObservableObject {
    /// One job for the whole app: leaving the page and coming back keeps progress, results and the Stop button.
    static let shared = ConvertJob()
    enum State { case waiting, running, done(URL), failed(String) }
    struct Row: Identifiable {
        let id = UUID()
        let url: URL
        var state: State = .waiting
    }

    @Published var rows: [Row] = []
    @Published var running = false
    @Published var fraction = 0.0
    private var control = ProxyControl()
    private var stopped = false

    /// Stops the file in progress and skips the ones still waiting.
    func stop() { stopped = true; control.cancel() }

    func run(_ urls: [URL], tool: ConvertTool, options: ConvertOptions) {
        guard !running, !urls.isEmpty else { return }
        rows = urls.map { Row(url: $0) }
        running = true
        stopped = false
        let job = self
        Task {
            for (i, url) in urls.enumerated() {
                if stopped { rows[i].state = .failed(L("Annullato.")); continue }
                rows[i].state = .running
                fraction = 0
                control = ProxyControl()
                let c = control
                let r = await Task.detached(priority: .userInitiated) {
                    Doctor.convert(url, tool: tool, options: options, control: c) { f in Task { @MainActor in job.fraction = f } }
                }.value
                if let out = r.output, r.ok { rows[i].state = .done(out) } else { rows[i].state = .failed(r.problems.first ?? L("Errore sconosciuto")) }
            }
            running = false
        }
    }
}

@MainActor final class LinkJob: ObservableObject {
    static let shared = LinkJob()
    @Published var running = false
    @Published var fraction = 0.0
    @Published var result: DownloadResult?
    private var control = ProxyControl()

    func stop() { control.cancel() }

    func run(_ link: String, kind: DownloadKind, to dir: URL) {
        guard !running else { return }
        running = true; fraction = 0; result = nil
        control = ProxyControl()
        let c = control
        let job = self
        Task {
            let r = await Task.detached(priority: .userInitiated) {
                Doctor.download(link, kind: kind, outputDir: dir, control: c) { f in Task { @MainActor in job.fraction = f } }
            }.value
            result = r
            running = false
        }
    }
}

/// A tool is missing: say what it is for, give the one command to copy, and let the user check again.
struct MissingToolHelp: View {
    let what: String
    let command: String
    let isInstalled: () -> Bool
    @State private var copied = false
    @State private var tick = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L(what)).foregroundStyle(Theme.orange).fixedSize(horizontal: false, vertical: true)
            Text(L("Si installa una volta sola, dal Terminale: copia il comando, aprilo, incollalo e premi Invio. Poi torna qui e premi «Ricontrolla»."))
                .font(.callout).foregroundStyle(.secondary)
            Text(L(command)).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panelHigh, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button(copied ? L("Copiato") : L("Copia il comando")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                }
                Button(L("Ricontrolla")) { tick += 1; copied = false }
                Text(tick == 0 ? "" : isInstalled() ? L("Trovato! Cambia pagina e torna qui: ora funziona.") : L("Ancora non lo trovo."))
                    .font(.caption).foregroundStyle(tick > 0 && isInstalled() ? Theme.green : .secondary)
            }
        }
        .card()
    }
}

/// Its own page: downloading a link has nothing to do with the tools.
struct DownloadView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("Incolla il link di un video e lo salvo sul Mac, come video oppure solo audio.")).foregroundStyle(.secondary)
                LinkDownloadCard()
            }
            .padding(16)
        }
        .navigationTitle(L("Scarica da link"))
    }
}

/// Paste a YouTube, Instagram or TikTok link, get the video or only the audio.
struct LinkDownloadCard: View {
    @State private var link = ""
    @State private var format = "video"
    @ObservedObject private var job = LinkJob.shared
    private let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

    private var kind: DownloadKind {
        switch format {
        case "mp3": return .audio(.mp3)
        case "wav": return .audio(.wav)
        case "aac": return .audio(.aac)
        default: return .video
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Scarica da link")).font(.headline)
            Text(L("YouTube, Instagram, TikTok e altri. Scarica solo contenuti tuoi o che hai il diritto di usare. Salvo nella cartella Download."))
                .font(.caption).foregroundStyle(.secondary)
            if Doctor.ytdlpPath == nil {
                MissingToolHelp(what: "Manca yt-dlp, il programma gratuito che scarica i video dai link.",
                                command: "python3 -m venv ~/.local/share/yt-dlp && ~/.local/share/yt-dlp/bin/pip install yt-dlp && mkdir -p ~/.local/bin && ln -sf ~/.local/share/yt-dlp/bin/yt-dlp ~/.local/bin/yt-dlp",
                                isInstalled: { Doctor.ytdlpPath != nil })
            }
            HStack {
                TextField(L("Incolla qui il link"), text: $link).textFieldStyle(.roundedBorder)
                    .onSubmit { if !job.running, Doctor.ytdlpPath != nil, !link.trimmingCharacters(in: .whitespaces).isEmpty { job.run(link, kind: kind, to: folder) } }
                Button(L("Incolla")) { link = NSPasteboard.general.string(forType: .string) ?? link }
            }
            HStack {
                Picker("", selection: $format) {
                    Text(L("Video")).tag("video"); Text(L("MP3")).tag("mp3"); Text(L("WAV")).tag("wav"); Text(L("AAC")).tag("aac")
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280)
                if job.running {
                    ProgressView(value: job.fraction).frame(width: 110)
                    Text("\(Int(job.fraction * 100))%").monospacedDigit().foregroundStyle(.secondary)
                    Button(L("Ferma")) { job.stop() }
                } else {
                    Button(L("Scarica")) { job.run(link, kind: kind, to: folder) }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || Doctor.ytdlpPath == nil)
                }
            }
            if let r = job.result {
                if let out = r.output, r.ok {
                    HStack {
                        Text(LF("Fatto: %@", out.lastPathComponent)).foregroundStyle(Theme.green).lineLimit(1)
                        Button(L("Mostra nel Finder")) { NSWorkspace.shared.activateFileViewerSelecting([out]) }
                    }
                }
                ForEach(r.problems, id: \.self) { Text(L($0)).foregroundStyle(Theme.orange) }
                ForEach(r.notes, id: \.self) { Text(L($0)).foregroundStyle(.secondary).font(.caption) }
            }
        }
        .card()
    }
}

/// Small one-click jobs for an editor: pick a tool, drop files, get a new file next to the original.
struct ToolsView: View {
    enum Extra: String, CaseIterable, Identifiable {
        case info = "Info file", rename = "Rinomina in blocco", ratio = "Calcolatore proporzioni"
        case shots = "Cambi di inquadratura", contact = "Foglio provini", trim = "Taglia clip", metadata = "Pulisci metadata"
        case palette = "Colori e palette", safe = "Aree sicure social", dups = "Doppioni", search = "Cerca nei filmati"
        case queue = "Coda di lavori", presets = "Preset di lavoro", describe = "Descrivi clip"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .info: return "info.circle"
            case .rename: return "textformat.123"
            case .ratio: return "aspectratio"
            case .shots: return "scissors.badge.ellipsis"
            case .contact: return "square.grid.3x3"
            case .trim: return "scissors"
            case .metadata: return "eraser"
            case .palette: return "paintpalette"
            case .safe: return "iphone.gen3"
            case .dups: return "doc.on.doc"
            case .search: return "magnifyingglass"
            case .queue: return "list.bullet.rectangle"
            case .presets: return "slider.horizontal.3"
            case .describe: return "text.quote"
            }
        }
        var summary: String {
            switch self {
            case .info: return "Ti dice tutto di un file: quanto dura, che qualità ha, se è adatto a Final Cut."
            case .rename: return "Cambia il nome a tanti file insieme (es. Clip_001, Clip_002…)."
            case .ratio: return "Ti dà le misure giuste per Instagram, TikTok, YouTube, senza deformare l'immagine."
            case .shots: return "Trova i punti dove cambia l'inquadratura e ti dà l'elenco dei tempi."
            case .contact: return "Crea un'immagine con tanti fotogrammi del video, per vedere tutto in un colpo d'occhio."
            case .trim: return "Taglia l'inizio e la fine di una clip, senza aprire Final Cut."
            case .metadata: return "Toglie da foto e video i dati personali (posizione GPS, telefono usato, autore)."
            case .palette: return "Ti dice quali sono i colori principali di un'immagine o di un punto dello schermo."
            case .safe: return "Ti mostra le zone dove Instagram, TikTok e YouTube coprono il video con scritte e bottoni."
            case .dups: return "Trova i file uguali anche se hanno nomi diversi, così puoi liberare spazio."
            case .search: return "Scrivi cosa cerchi (es. «persona sulla spiaggia») e trova le clip giuste. Gratis, resta sul Mac."
            case .queue: return "Metti più lavori in fila: li fa uno dopo l'altro, mentre tu fai altro."
            case .presets: return "Salva un procedimento (es. «Prepara per Instagram») e applicalo a tanti file in un click."
            case .describe: return "Scrive in italiano cosa si vede in ogni clip, così le ritrovi. Gratis, resta sul Mac."
            }
        }
    }
    @EnvironmentObject var model: Model
    @State private var extra: Extra?
    /// Files handed over by the drop zone / search / Finder; `paneID` restarts the pane so it loads them.
    @State private var preload: [URL] = []
    @State private var paneID = UUID()
    /// A conversion card was picked (the grid gives way to that tool).
    @State private var chosen = false
    private var showingPane: Bool { extra != nil || chosen }
    @State private var dropped: [URL] = []
    /// Files for a conversion: shown with a button, never started by themselves.
    @State private var waiting: [URL] = []
    @State private var dropNote: String?
    @State private var tool: ConvertTool = .prepare
    @State private var options = ConvertOptions()
    @ObservedObject private var job = ConvertJob.shared
    @State private var picking = false
    @State private var targeted = false

    private func icon(_ t: ConvertTool) -> String {
        switch t {
        case .prepare: return "film.stack"
        case .audio: return "music.note"
        case .normalize: return "speaker.wave.2.fill"
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .still: return "photo"
        }
    }

    /// One card of the grid: a conversion or one of the extra tools.
    private struct Card { let key: String; let title: String, summary: String, icon: String; let convert: ConvertTool?; let extra: Extra?; var group = "" }
    /// Keys of the tools used, last used first (kept across launches).
    @AppStorage("toolRecentOrder") private var recentOrder = ""
    /// Every card keeps the same place, so the eye learns where things are.
    private var orderedCards: [Card] {
        ConvertTool.allCases.map { Card(key: "c:\($0.rawValue)", title: $0.title, summary: $0.summary, icon: icon($0), convert: $0, extra: nil) }
            + Extra.allCases.map { Card(key: "e:\($0.rawValue)", title: $0.rawValue, summary: $0.summary, icon: $0.icon, convert: nil, extra: $0) }
    }
    /// The last tools used, most recent first: the only part of the page that moves.
    private var recentCards: [Card] {
        let all = orderedCards
        return Array(recentOrder.split(separator: "\n").compactMap { k in all.first { $0.key == String(k) } }.prefix(3))
    }
    private static let groups: [(name: String, hint: String, extras: Set<Extra>)] = [
        ("Converti e comprimi", "Trasforma un file in un altro: formato, peso, audio, volume.", []),
        ("Analizza e cerca", "Capire cosa c'è nei filmati, trovare clip e doppioni.", [.info, .shots, .contact, .palette, .dups, .search, .describe]),
        ("Prepara e modifica", "Piccoli lavori di emergenza su clip e file.", [.trim, .rename, .metadata, .ratio, .safe]),
        ("Automatizza", "Tanti file in una volta, con ricette salvate.", [.queue, .presets]),
    ]
    /// Cards of one section, most recently used first.
    private func cards(inGroup i: Int) -> [Card] {
        orderedCards.filter { c in
            if let e = c.extra { return Self.groups[i].extras.contains(e) }
            return i == 0
        }
    }
    private func isSelected(_ c: Card) -> Bool { c.extra != nil ? extra == c.extra : (tool == c.convert && extra == nil) }
    private func scrollToPane(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async { withAnimation { proxy.scrollTo("pane", anchor: .top) } }
    }
    private func markUsed(_ key: String) {
        recentOrder = ([key] + recentOrder.split(separator: "\n").map(String.init).filter { $0 != key }).prefix(40).joined(separator: "\n")
    }
    private func pick(_ c: Card) {
        markUsed(c.key)
        if let e = c.extra { extra = e; preload = [] }
        else if let t = c.convert { tool = t; extra = nil; preload = []; waiting = []; chosen = true }
    }

    private func cardButton(_ c: Card) -> some View {
        Button { pick(c) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: c.icon).font(.title2).foregroundStyle(isSelected(c) ? Theme.green : .secondary).frame(height: 28, alignment: .leading).accessibilityHidden(true)
                Text(L(c.title)).font(.headline)
                Text(L(c.summary)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 136, maxHeight: 136, alignment: .topLeading)
            .padding(12)
            .background(isSelected(c) ? Theme.panelHigh : Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isSelected(c) ? Theme.green : Theme.stroke))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected(c) ? .isSelected : [])
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if Doctor.ffmpegPath == nil {
                    MissingToolHelp(what: "Manca ffmpeg, il programma gratuito che converte i video: senza, gli strumenti sui video non funzionano.",
                                    command: "brew install ffmpeg", isInstalled: { Doctor.ffmpegPath != nil })
                }
                if showingPane {
                    Button { extra = nil; chosen = false; waiting = []; preload = [] } label: {
                        Label(L("Tutti gli strumenti"), systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.blue)
                    Text(L(extra?.rawValue ?? tool.title)).font(.title3.bold())
                } else {
                Text(L("Scegli uno strumento, o trascina un file qui sotto e ti propongo cosa fare. Il risultato è sempre un file nuovo accanto all'originale: l'originale non viene toccato."))
                    .foregroundStyle(.secondary)
                UniversalDropZone(urls: $dropped)
                if !recentCards.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("Usati di recente")).font(.headline).accessibilityAddTraits(.isHeader)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10, alignment: .top)], spacing: 10) {
                            ForEach(recentCards, id: \.key) { c in cardButton(c) }
                        }
                    }
                    .padding(.top, 6)
                }
                ForEach(Self.groups.indices, id: \.self) { gi in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L(Self.groups[gi].name)).font(.headline).accessibilityAddTraits(.isHeader)
                        Text(L(Self.groups[gi].hint)).font(.callout).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10, alignment: .top)], spacing: 10) {
                            ForEach(cards(inGroup: gi), id: \.key) { c in cardButton(c) }
                        }
                    }
                    .padding(.top, 6)
                }
                }
                if showingPane {
                Group {
                switch extra {
                case .info: InfoPane(initialURLs: preload).id(paneID)
                case .rename: BatchRenamePane(initialURLs: preload).id(paneID)
                case .ratio: RatioPane()
                case .shots: ShotsPane(initialURLs: preload).id(paneID)
                case .contact: ContactSheetPane(initialURLs: preload).id(paneID)
                case .trim: TrimPane(initialURLs: preload).id(paneID)
                case .metadata: MetadataPane(initialURLs: preload).id(paneID)
                case .palette: PalettePane(initialURLs: preload).id(paneID)
                case .safe: SafePane()
                case .dups: DuplicatesPane(initialURLs: preload).id(paneID)
                case .search: FootageSearchPane()
                case .queue: BatchCenterPane()
                case .presets: PresetsPane()
                case .describe: DescribePane()
                case nil:
                    options(for: tool)
                    if !waiting.isEmpty {
                        HStack {
                            Text(LF("Pronti %@ file per «%@»", waiting.count, L(tool.title))).font(.headline)
                            Spacer()
                            Button(L("Annulla")) { waiting = [] }
                            Button(L("Avvia")) { start(waiting); waiting = [] }.buttonStyle(.borderedProminent)
                        }
                        .card()
                    }
                    if let dropNote { Text(L(dropNote)).font(.callout).foregroundStyle(Theme.orange) }
                    dropZone
                    if !job.rows.isEmpty { results }
                }
                }.id("pane")
                }
            }
            .padding(16)
        }
        // the chosen tool opens below the cards: bring it into view
        .onChange(of: extra) { _, _ in scrollToPane(proxy) }
        .onChange(of: tool) { _, _ in scrollToPane(proxy) }
        .onChange(of: paneID) { _, _ in scrollToPane(proxy) }
        }
        .onChange(of: model.openRequest, initial: true) { _, r in receive(r) }
        .navigationTitle(L("Strumenti"))
        .fileImporter(isPresented: $picking, allowedContentTypes: [.movie, .audio, .audiovisualContent], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { addWaiting(urls) }
        }
    }

    @ViewBuilder private func options(for t: ConvertTool) -> some View {
        switch t {
        case .audio:
            Picker(L("Formato"), selection: $options.audioFormat) { ForEach(AudioFormat.allCases) { Text(L($0.label)).tag($0) } }
                .pickerStyle(.segmented).frame(maxWidth: 260)
        case .compress:
            Picker(L("Limite"), selection: $options.targetMB) {
                ForEach([16, 25, 50, 100], id: \.self) { Text("\($0) MB").tag($0) }
            }
            .pickerStyle(.segmented).frame(maxWidth: 320)
        default: EmptyView()
        }
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc").font(.title)
            Text(job.running ? L("Sto lavorando…") : LF("Trascina qui i file per «%@»", L(tool.title))).font(.headline)
            if job.running {
                Button(L("Ferma tutto")) { job.stop() }
            } else {
                Button(L("Scegli file…")) { picking = true }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(targeted ? Theme.panelHigh : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6])).foregroundStyle(targeted ? Theme.green : Theme.stroke))
        .dropDestination(for: URL.self) { urls, _ in addWaiting(urls); return true } isTargeted: { targeted = $0 }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(job.rows) { row in
                HStack {
                    Text(L(row.url.lastPathComponent)).lineLimit(1)
                    Spacer()
                    switch row.state {
                    case .waiting: Text(L("In attesa")).foregroundStyle(.secondary)
                    case .running:
                        ProgressView(value: job.fraction).frame(width: 110)
                        Text("\(Int(job.fraction * 100))%").monospacedDigit().foregroundStyle(.secondary)
                        Button(L("Ferma")) { job.stop() }
                    case .done(let out):
                        Text(L("Fatto")).foregroundStyle(Theme.green)
                        Button(L("Mostra nel Finder")) { NSWorkspace.shared.activateFileViewerSelecting([out]) }
                    case .failed(let m):
                        Text(L(m)).foregroundStyle(Theme.orange).font(.caption).lineLimit(2)
                    }
                }
            }
        }
        .card()
    }

    /// Takes the requests aimed at this screen (cards of "Converti e scarica" and the drop zone).
    private func receive(_ r: OpenRequest?) {
        guard let r else { return }
        if r.toolID == DeepLink.dropID {
            dropped = r.urls
        } else if let entry = ToolCatalog.entry(r.toolID) {
            switch entry.target {
            case .extra(let raw):
                guard let e = Extra(rawValue: raw) else { return }
                extra = e; preload = r.urls; paneID = UUID(); markUsed("e:\(e.rawValue)")
            case .convert(let raw):
                guard let t = ConvertTool(rawValue: raw) else { return }
                tool = t; extra = nil; preload = []; chosen = true; markUsed("c:\(t.rawValue)")
                waiting = r.urls.filter { FileKind.of($0) != .folder }
            default: return
            }
        } else { return }
        model.openRequest = nil
    }

    /// Same rule as everywhere else: dropped files wait for «Avvia», nothing starts by itself.
    private func addWaiting(_ urls: [URL]) {
        if job.running { dropNote = L("Sto ancora lavorando: aspetta la fine oppure premi «Ferma tutto»."); return }
        let files = urls.filter { !$0.hasDirectoryPath }
        let skipped = urls.count - files.count
        waiting += files.filter { !waiting.contains($0) }
        dropNote = skipped > 0 ? LF("%@ cartelle ignorate: trascina i file, non le cartelle.", skipped) : nil
    }

    private func start(_ urls: [URL]) {
        urls.forEach { _ = $0.startAccessingSecurityScopedResource() }
        job.run(urls.filter { !$0.hasDirectoryPath }, tool: tool, options: options)
    }
}
