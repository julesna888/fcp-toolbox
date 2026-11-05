import AppKit
import FCPCore
import SwiftUI
import UniformTypeIdentifiers

private func freshURL(_ dir: URL, _ stem: String, _ ext: String) -> URL {
    var u = dir.appendingPathComponent("\(stem).\(ext)")
    var n = 2
    while FileManager.default.fileExists(atPath: u.path) { u = dir.appendingPathComponent("\(stem) \(n).\(ext)"); n += 1 }
    return u
}

private func pickFolder(_ message: String) -> URL? {
    let p = NSOpenPanel()
    p.canChooseDirectories = true; p.canChooseFiles = false; p.message = L(message)
    return p.runModal() == .OK ? p.url : nil
}

// MARK: - Inspector

/// What a media file really contains, whether it fits a delivery, its subtitles, and proxies.
struct InspectorView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case details = "Info file", delivery = "Controllo consegna", subtitles = "Sottotitoli", proxy = "Copie leggere (proxy)"
        var id: String { rawValue }
    }

    @EnvironmentObject var model: Model
    @State private var mode: Mode = .details
    @State private var subtitleFile: URL?
    @State private var infos: [MediaInfo] = []
    @State private var failed = 0
    @State private var picking = false
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // subtitles: code kept, tab hidden (the user edits them in CapCut)
                // the tab stays hidden unless we arrive from "Trascina qui" / search with a .srt/.vtt
                Picker("", selection: $mode) { ForEach(Mode.allCases.filter { $0 != .subtitles || mode == .subtitles }) { Text(L($0.rawValue)).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
                if mode != .subtitles {
                    HStack {
                        Button(L("Scegli file o cartella…")) { picking = true }
                        if loading { ProgressView().controlSize(.small) }
                        Text(infos.isEmpty ? "" : LF("%@ file", infos.count) + (failed > 0 ? LF(" · %@ non leggibili", failed) : "")).foregroundStyle(.secondary)
                    }
                    if Doctor.ffprobePath == nil {
                        Text(L("Serve ffprobe (brew install ffmpeg) per leggere i file.")).foregroundStyle(Theme.orange).card()
                    }
                }
                switch mode {
                case .details: ForEach(infos) { DetailsCard(info: $0) }
                case .delivery: DeliveryPane(infos: infos)
                case .subtitles: SubtitlesPane(initial: subtitleFile)
                case .proxy: ProxyPane(infos: infos)
                }
                if infos.isEmpty && mode != .subtitles {
                    Text(L("Scegli uno o più file video o una cartella: li leggo senza modificarli.")).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .spacePreview(infos.map(\.url))
        .navigationTitle(L("Controlla il video finito"))
        .onChange(of: model.openRequest, initial: true) { _, r in
            guard let r, let entry = ToolCatalog.entry(r.toolID), case .inspector(let raw) = entry.target,
                  let m = Mode(rawValue: raw) else { return }
            model.openRequest = nil
            mode = m
            if m == .subtitles { subtitleFile = r.urls.first } else if !r.urls.isEmpty { load(r.urls) }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.movie, .audio, .folder], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { load(urls) }
        }
    }

    private func load(_ urls: [URL]) {
        loading = true
        Task {
            let result = await Task.detached(priority: .utility) { () -> ([MediaInfo], Int) in
                var ok: [MediaInfo] = [], bad = 0
                for u in urls {
                    _ = u.startAccessingSecurityScopedResource()
                    if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        if let r = try? Doctor.probeFolder(u) { ok += r.ok; bad += r.failed.count }
                    } else if let m = try? Doctor.probeMedia(u) { ok.append(m) } else { bad += 1 }
                }
                return (ok, bad)
            }.value
            infos = result.0; failed = result.1; loading = false
        }
    }
}

private struct DetailsCard: View {
    let info: MediaInfo
    var body: some View {
        let anomalies = Doctor.technicalAnomalies(info)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L(info.url.lastPathComponent)).font(.headline)
                Spacer()
                Text(formatBytes(info.size)).foregroundStyle(.secondary)
            }
            Text("\(info.container) · \(String(format: "%.1f", info.duration)) s").foregroundStyle(.secondary)
            if let v = info.video {
                Text("Video: \(v.codec) \(v.displayWidth)×\(v.displayHeight) · \(String(format: "%g", v.fps)) fps\(v.isVFR ? L(" (variabile)") : "") · \(v.bitDepth) bit \(v.chroma)\(v.isHDR ? " · HDR" : "")")
            } else {
                Text(L("Nessun video: solo audio."))
            }
            ForEach(Array(info.audio.enumerated()), id: \.offset) { _, a in
                Text(LF("Audio: %@ · %@ canali · %@ Hz", a.codec, a.channels, a.sampleRate))
            }
            ForEach(anomalies, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange) }
            if info.video?.isVFR == true {
                Text(L("Frame rate variabile: è una stima dai dati del file, non una certezza. Può dare problemi di sync nel montaggio.")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .card()
    }
}

/// Volume and silences of the real audio, measured with ffmpeg when the card appears.
private struct AudioCard: View {
    let info: MediaInfo
    @State private var results: [CheckResult]?
    @State private var failed: String?

    var body: some View {
        Group {
            if info.audio.isEmpty {
                EmptyView()
            } else if let results {
                ForEach(Array(results.enumerated()), id: \.offset) { _, r in
                    Label(L(r.detail), systemImage: r.ok ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .foregroundStyle(r.ok ? Color.secondary : Theme.orange)
                }
            } else if let failed {
                Text(L(failed)).foregroundStyle(.secondary)
            } else {
                HStack { ProgressView().controlSize(.small); Text(L("Misuro volume e silenzi…")).foregroundStyle(.secondary) }
            }
        }
        .task(id: info.url) {
            let url = info.url, duration = info.duration
            let r = await Task.detached(priority: .utility) {
                Result { try Doctor.audioAdvice(Doctor.audioLevels(of: url), duration: duration) }
            }.value
            switch r {
            case .success(let list): results = list
            case .failure(let e): failed = e.localizedDescription
            }
        }
    }
}

private struct DeliveryPane: View {
    let infos: [MediaInfo]
    @State private var profile = Doctor.deliveryProfiles.first?.name ?? ""
    private var specs: [DeliverySpec] { Doctor.deliveryProfiles + Doctor.loadCustomSpecs() }

    var body: some View {
        Picker(L("Dove lo consegni?"), selection: $profile) { ForEach(specs) { Text(L($0.name)).tag($0.name) } }.frame(maxWidth: 360)
        Text(L("I profili sono indicativi: controlla sempre le specifiche aggiornate della piattaforma. Profili tuoi: aggiungili in delivery-specs.json nella cartella di FCP Toolbox."))
            .font(.caption).foregroundStyle(.secondary)
        if let spec = specs.first(where: { $0.name == profile }) {
            ForEach(infos) { m in
                let results = Doctor.checkDelivery(m, spec: spec)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(L(m.url.lastPathComponent)).font(.headline)
                        Spacer()
                        Text(results.allSatisfy(\.ok) ? L("Va bene") : LF("%@ problemi", results.filter { !$0.ok }.count))
                            .foregroundStyle(results.allSatisfy(\.ok) ? Theme.green : Theme.orange)
                    }
                    ForEach(results) { r in
                        Label(L(r.detail), systemImage: r.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(r.ok ? Color.secondary : Theme.orange)
                    }
                    AudioCard(info: m)
                }
                .card()
            }
        }
    }
}

private struct SubtitlesPane: View {
    var initial: URL?
    @State private var cues: [SubtitleCue] = []
    @State private var source: URL?
    @State private var issues: [SubtitleIssue] = []
    @State private var message: String?
    @State private var pickingSubs = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Controllo sottotitoli")).font(.headline)
            HStack {
                Button(L("Apri sottotitoli (.srt / .vtt)…")) { pickingSubs = true }
                if let source { Text(L(source.lastPathComponent)).foregroundStyle(.secondary) }
            }
            if let message { Text(L(message)).foregroundStyle(.secondary) }
            if !cues.isEmpty {
                Text(LF("%@ battute · %@", cues.count, issues.isEmpty ? L("nessun problema di leggibilità") : LF("%@ da sistemare", issues.count))).font(.headline)
                ForEach(issues) { Label("#\($0.cue) \(L($0.kind)): \(L($0.detail))", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange) }
                HStack {
                    Button(L("Sistema punteggiatura (salva copia)")) { save(Doctor.fixPunctuation(cues), suffix: " corretto", ext: "srt") }
                    Button(L("Salva come VTT")) { save(cues, suffix: "", ext: "vtt") }
                    Button(L("Salva come SRT")) { save(cues, suffix: "", ext: "srt") }
                }
                Text(L("Le correzioni sistemano spazi e maiuscole; non riscrivono le parole e non spostano i tempi.")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .card()
        .onAppear { if let initial { open(initial) } }
        .fileImporter(isPresented: $pickingSubs, allowedContentTypes: [UTType(filenameExtension: "srt") ?? .text, UTType(filenameExtension: "vtt") ?? .text, .text]) { r in
            if case .success(let u) = r { open(u) }
        }
    }

    private func open(_ u: URL) {
        _ = u.startAccessingSecurityScopedResource()
        guard let text = try? String(contentsOf: u, encoding: .utf8) else { message = L("Non riesco a leggere il file."); return }
        cues = u.pathExtension.lowercased() == "vtt" ? Doctor.parseVTT(text) : Doctor.parseSRT(text)
        issues = Doctor.checkSubtitles(cues)
        source = u
        message = cues.isEmpty ? L("Non ho trovato battute in questo file.") : nil
    }

    private func save(_ list: [SubtitleCue], suffix: String, ext: String) {
        guard let source else { return }
        let url = freshURL(source.deletingLastPathComponent(), source.deletingPathExtension().lastPathComponent + suffix, ext)
        let text = ext == "vtt" ? Doctor.renderVTT(list) : Doctor.renderSRT(list)
        do { try text.write(to: url, atomically: true, encoding: .utf8); message = LF("Salvato: %@", url.lastPathComponent) }
        catch { message = LF("Non riesco a salvare: %@", error.localizedDescription) }
    }
}

@MainActor final class ProxyJob: ObservableObject {
    @Published var index = 0
    @Published var fraction = 0.0
    @Published var running = false
    @Published var paused = false
    @Published var results: [ProxyResult] = []
    private(set) var control = ProxyControl()

    func start(_ sources: [URL], options: ProxyOptions) {
        running = true; paused = false; results = []; index = 0; fraction = 0
        control = ProxyControl()
        let c = control
        let job = self
        Task.detached(priority: .utility) {
            let r = Doctor.makeProxies(sources, options: options, control: c) { i, f in
                Task { @MainActor in job.index = i; job.fraction = f }
            }
            await MainActor.run { job.results = r; job.running = false }
        }
    }
    func togglePause() { paused ? control.resume() : control.pause(); paused.toggle() }
    func cancel() { control.cancel(); paused = false }
}

private struct ProxyPane: View {
    let infos: [MediaInfo]
    @StateObject private var job = ProxyJob()
    @State private var codec: ProxyCodec = .proresProxy
    @State private var height = 540
    @State private var destination: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Crea proxy leggeri dei file scelti. Gli originali non vengono toccati.")).foregroundStyle(.secondary)
            HStack {
                Picker(L("Formato"), selection: $codec) { ForEach(ProxyCodec.allCases, id: \.self) { Text(L($0.rawValue)).tag($0) } }.fixedSize()
                Picker(L("Altezza"), selection: $height) { ForEach([360, 540, 720], id: \.self) { Text(LF("%@ px", $0)).tag($0) } }.fixedSize()
                Button(destination.map { LF("In: %@", $0.lastPathComponent) } ?? L("Scegli la cartella dei proxy…")) { destination = pickFolder("Dove salvo i proxy?") }
            }
            HStack {
                Button(LF("Crea %@ proxy", infos.count)) {
                    if let destination { job.start(infos.map(\.url), options: ProxyOptions(codec: codec, height: height, destination: destination)) }
                }
                .disabled(infos.isEmpty || destination == nil || job.running)
                if job.running {
                    Button(job.paused ? L("Riprendi") : L("Pausa")) { job.togglePause() }
                    Button(L("Annulla"), role: .destructive) { job.cancel() }
                    ProgressView(value: job.fraction).frame(width: 160)
                    Text(LF("file %@ di %@", job.index + 1, infos.count)).foregroundStyle(.secondary)
                }
            }
            ForEach(Array(job.results.enumerated()), id: \.offset) { _, r in
                Label(r.output.map { "\($0.lastPathComponent) · " + (r.verified ? L("creato e controllato") : r.problems.map { L($0) }.joined(separator: " ")) }
                      ?? "\(r.source.lastPathComponent): \(r.problems.map { L($0) }.joined(separator: " "))",
                      systemImage: r.verified ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(r.verified ? Color.secondary : Theme.orange)
            }
            if !job.results.isEmpty {
                Text(L("Controllato: apertura, durata, altezza, codec e audio. Che Final Cut li colleghi si vede solo in Final Cut: non posso verificarlo da qui."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .card()
    }
}

// MARK: - Media management

/// Duplicates, renaming, organizing, comparing and checking folders. Nothing is deleted; moves can be undone.
struct ManageView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case duplicates = "Duplicati", rename = "Rinomina", organize = "Organizza", compare = "Confronta", integrity = "Integrità"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .duplicates
    @State private var folder: URL?
    @State private var other: URL?
    @State private var busy = false
    @State private var message: String?

    // duplicates
    @State private var identical: [DuplicateGroup] = []
    @State private var versions: [VersionGroup] = []
    @State private var scanned = false
    @State private var toTrash: URL?
    // rename / organize
    @State private var template = "{name}"
    @State private var find = ""
    @State private var replace = ""
    @State private var startAt = 1
    @State private var organizeBy: OrganizeBy = .type
    @State private var plan: [MoveStep] = []
    @State private var confirmApply = false
    // compare / integrity
    @State private var diff: FolderDiff?
    @State private var check: ManifestCheck?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("", selection: $mode) { ForEach(Mode.allCases) { Text(L($0.rawValue)).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 520)
                    .onChange(of: mode) { _, _ in plan = []; message = nil }
                HStack {
                    Button(folder.map { LF("Cartella: %@", $0.lastPathComponent) } ?? L("Scegli la cartella…")) { folder = pickFolder("Quale cartella?"); reset() }
                    if mode == .compare {
                        Button(other.map { LF("Con: %@", $0.lastPathComponent) } ?? L("Scegli la seconda cartella…")) { other = pickFolder("Con quale cartella la confronto?") }
                    }
                    if busy { ProgressView().controlSize(.small) }
                }
                if let message { Text(L(message)).foregroundStyle(.secondary) }
                if folder != nil {
                    switch mode {
                    case .duplicates: duplicates
                    case .rename: rename
                    case .organize: organize
                    case .compare: compare
                    case .integrity: integrity
                    }
                }
                if let last = Doctor.lastMoveLabel() {
                    HStack {
                        Text(LF("Ultima operazione: %@", L(last))).foregroundStyle(.secondary)
                        Button(L("Annulla ultima operazione")) {
                            let r = Doctor.undoLastMoves()
                            message = LF("Ripristinati %@ file.", r.restored) + (r.failures.isEmpty ? "" : " " + LF("Non riuscito: %@", r.failures.joined(separator: "; ")))
                            plan = []
                        }
                    }
                    .card()
                }
            }
            .padding(16)
        }
        .navigationTitle(L("Gestione media"))
        .confirmationDialog(LF("Spostare nel Cestino %@?", toTrash?.lastPathComponent ?? ""), isPresented: Binding(
            get: { toTrash != nil }, set: { if !$0 { toTrash = nil } }), titleVisibility: .visible) {
            Button(L("Sposta nel Cestino"), role: .destructive) {
                if let u = toTrash, let folder {
                    let r = Doctor.trash([u], within: [folder])
                    message = r.moved == 1 ? L("Nel Cestino (lo recuperi da lì).") : r.failures.joined(separator: " ")
                    scanDuplicates()
                }
                toTrash = nil
            }
        } message: { Text(L("Resta recuperabile dal Cestino finché non lo svuoti.")) }
        .confirmationDialog(LF("Applicare %@ spostamenti?", plan.filter { $0.conflict == nil }.count), isPresented: $confirmApply, titleVisibility: .visible) {
            Button(L("Applica")) {
                let r = Doctor.applyMoves(plan.filter { $0.conflict == nil }, label: mode == .rename ? "Rinomina in \(folder?.lastPathComponent ?? "")" : "Organizza \(folder?.lastPathComponent ?? "")")
                message = LF("Fatto: %@ file.", r.done) + (r.failures.isEmpty ? " " + L("Puoi annullare.") : " " + LF("Problemi: %@", r.failures.joined(separator: "; ")))
                plan = []
            }
        } message: { Text(L("I file non vengono cancellati e non ne sovrascrivo nessuno. Puoi annullare con “Annulla ultima operazione”.")) }
    }

    private func reset() { identical = []; versions = []; scanned = false; plan = []; diff = nil; check = nil; message = nil }

    private func isOriginalMedia(_ u: URL) -> Bool { u.path.contains("Original Media") }

    // MARK: duplicates
    @ViewBuilder private var duplicates: some View {
        Button(L("Cerca duplicati")) { scanDuplicates() }.disabled(busy)
        if scanned {
            Text(identical.isEmpty ? L("Nessun file identico.") : LF("%@ gruppi di file identici · %@ recuperabili", identical.count, formatBytes(identical.reduce(0) { $0 + $1.wasted })))
                .font(.headline)
            ForEach(identical) { g in
                VStack(alignment: .leading, spacing: 4) {
                    Text(LF("Identici byte per byte · %@ ciascuno", formatBytes(g.size))).font(.headline)
                    ForEach(g.files, id: \.self) { f in
                        HStack {
                            Text(f.path.replacingOccurrences(of: folder?.path ?? "", with: "…")).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button(L("Cestina…")) { toTrash = f }.disabled(isOriginalMedia(f))
                                .help(isOriginalMedia(f) ? L("I media originali di Final Cut non si toccano da qui") : L("Sposta nel Cestino"))
                        }
                    }
                }
                .card()
            }
            if !versions.isEmpty {
                Text(L("Versioni: stesso nome ma contenuto diverso. Non sono duplicati, non li propongo per l'eliminazione.")).font(.headline)
                ForEach(versions) { v in
                    VStack(alignment: .leading) { Text(L(v.stem)).font(.headline); ForEach(v.files, id: \.self) { Text(L($0.lastPathComponent)).foregroundStyle(.secondary) } }.card()
                }
            }
        }
    }

    private func scanDuplicates() {
        guard let folder else { return }
        busy = true
        Task {
            let r = await Task.detached(priority: .utility) { Doctor.findDuplicates(in: folder) }.value
            identical = r.identical; versions = r.versions; scanned = true; busy = false
        }
    }

    // MARK: rename / organize
    @ViewBuilder private var rename: some View {
        HStack {
            TextField(L("Modello: {name} {n:3} {date}"), text: $template).textFieldStyle(.roundedBorder)
            TextField(L("Trova"), text: $find).textFieldStyle(.roundedBorder)
            TextField(L("Sostituisci"), text: $replace).textFieldStyle(.roundedBorder)
            Stepper(LF("Parti da %@", startAt), value: $startAt, in: 0...9999).fixedSize()
        }
        Button(L("Anteprima")) {
            guard let folder else { return }
            let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
                .filter { Doctor.mediaExtensions.contains($0.pathExtension.lowercased()) }
            plan = Doctor.renamePlan(files, template: template, find: find, replace: replace, startAt: startAt)
            message = plan.isEmpty ? L("Nessun file media in questa cartella.") : nil
        }
        planView
    }

    @ViewBuilder private var organize: some View {
        Picker(L("Ordina per"), selection: $organizeBy) { Text(L("Tipo di file")).tag(OrganizeBy.type); Text(L("Mese")).tag(OrganizeBy.date) }.fixedSize()
        Button(L("Anteprima")) { if let folder { plan = Doctor.organizePlan(folder, by: organizeBy); message = plan.isEmpty ? L("Nessun file da ordinare.") : nil } }
        planView
    }

    @ViewBuilder private var planView: some View {
        if !plan.isEmpty {
            ForEach(plan) { s in
                HStack {
                    Text(L(s.from.lastPathComponent))
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text(s.to.path.replacingOccurrences(of: folder?.path ?? "", with: "…")).foregroundStyle(s.conflict == nil ? Color.primary : Theme.orange)
                    if let c = s.conflict { Text("— \(c)").font(.caption).foregroundStyle(Theme.orange) }
                }
            }
            Button(L("Applica…")) { confirmApply = true }.disabled(plan.allSatisfy { $0.conflict != nil })
        }
    }

    // MARK: compare / integrity
    @ViewBuilder private var compare: some View {
        Button(L("Confronta")) {
            guard let folder, let other else { message = L("Scegli due cartelle."); return }
            busy = true
            Task { diff = await Task.detached(priority: .utility) { Doctor.compareFolders(folder, other) }.value; busy = false }
        }
        .disabled(busy)
        if let d = diff {
            Text(LF("%@ file uguali", d.same)).font(.headline)
            list(L("Solo nella prima"), d.onlyInA); list(L("Solo nella seconda"), d.onlyInB); list(L("Diversi"), d.different)
        }
    }

    @ViewBuilder private var integrity: some View {
        Text(L("Registra l'impronta (SHA-256) di ogni file: dopo una copia o un trasferimento, controlli che nulla sia cambiato o sparito.")).foregroundStyle(.secondary)
        HStack {
            Button(L("Registra impronta")) {
                guard let folder else { return }
                busy = true
                Task { let n = await Task.detached(priority: .utility) { Doctor.writeManifest(for: folder) }.value; message = LF("Impronta di %@ file registrata.", n); busy = false }
            }
            Button(L("Verifica")) {
                guard let folder else { return }
                busy = true
                Task {
                    check = await Task.detached(priority: .utility) { Doctor.verifyManifest(for: folder) }.value
                    message = check == nil ? L("Nessuna impronta registrata per questa cartella.") : nil
                    busy = false
                }
            }
        }
        .disabled(busy)
        if let c = check {
            Text(c.ok ? L("Tutto uguale a quando hai registrato l'impronta.") : L("Qualcosa è cambiato.")).font(.headline)
                .foregroundStyle(c.ok ? Theme.green : Theme.orange)
            list(L("Modificati"), c.changed); list(L("Mancanti"), c.missing); list(L("Nuovi"), c.new)
        }
    }

    @ViewBuilder private func list(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            DisclosureGroup("\(title) (\(items.count))") {
                VStack(alignment: .leading, spacing: 2) { ForEach(items.prefix(200), id: \.self) { Text(L($0)).font(.system(.caption, design: .monospaced)) } }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
