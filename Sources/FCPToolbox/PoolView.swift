import AppKit
import FCPCore
import SwiftUI

/// Drop a downloaded folder: it is sorted into CLIENT/Video and checked. Preparing it for Final Cut
/// (a file that opens as a ready-made event) is optional.
struct PoolView: View {
    @EnvironmentObject var model: Model
    @AppStorage("poolRoot") private var poolRootPath = NSHomeDirectory() + "/Movies/Pool FCP"
    @State private var source: URL?
    @State private var client = ""
    @State private var video = ""
    @State private var clips: [ClipInfo] = []
    @State private var restCount = 0
    @State private var duplicateGroups = 0
    @State private var analyzing = false
    @State private var working = false
    @State private var moveFiles = true
    @State private var log = ""
    @State private var importFile: URL?
    @State private var sortedFolder: URL?
    @State private var contents: [(client: String, videos: [String])] = []
    @State private var targeted = false
    @State private var askExpiry = false
    @State private var pendingFinalCut = false
    @State private var expiring: [PoolExpiryEntry] = []

    private var poolRoot: URL { URL(fileURLWithPath: poolRootPath) }
    private var eventName: String { client.isEmpty ? video : "\(client) - \(video)" }
    private var destination: String {
        var url = poolRoot
        if !Doctor.clientFolderName(client).isEmpty { url.appendPathComponent(Doctor.clientFolderName(client)) }
        url.appendPathComponent(Doctor.safeFolderName(video).isEmpty ? "Senza titolo" : Doctor.safeFolderName(video))
        return url.path
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                dropZone
                if source != nil { details }
                if !log.isEmpty { Text(L(log)).font(.callout).textSelection(.enabled) }
                if let f = sortedFolder { sortedCard(f) }
                if let f = importFile { importCard(f) }
                expiringCard
                poolList
            }
            .padding(16)
        }
        .navigationTitle(L("Ordina cartelle clienti"))
        .onAppear { loadContents() }
        .confirmationDialog(LF("Cosa ne faccio di queste %@ clip tra %@ giorni?", clips.count, Doctor.poolExpiryDays),
                            isPresented: $askExpiry, titleVisibility: .visible) {
            Button(LF("Importa e cancella tra %@ giorni", Doctor.poolExpiryDays)) { run(prepareFinalCut: pendingFinalCut, keepForever: false) }
            Button(L("Importa e tieni per sempre")) { run(prepareFinalCut: pendingFinalCut, keepForever: true) }
            Button(L("Annulla"), role: .cancel) {}
        } message: {
            Text(LF("Le clip vanno in %@ (%@). «Cancella tra %@ giorni»: il %@ finiscono nel Cestino, e ti avviso 3 giorni prima. «Tieni per sempre»: non vengono mai cancellate. Le cartelle (cliente, video) restano comunque. Dal Cestino puoi recuperare le clip finché non lo svuoti; un progetto di Final Cut che le usa le troverebbe mancanti.", poolRoot.path, moveFiles ? L("spostate dai Download") : L("copiate"), Doctor.poolExpiryDays, expiryDateText))
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first(where: { Doctor.isFolder($0) }) else { return false }
            setSource(u)
            return true
        } isTargeted: { targeted = $0 }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 34))
                .foregroundStyle(Theme.gradient)
            Text(source == nil ? L("Trascina qui la cartella scaricata") : source!.lastPathComponent).font(.title3.bold())
            Text(L("La metto in CLIENTE / Video e ordino le clip per nome. Final Cut è facoltativo."))
                .foregroundStyle(.secondary)
            Button(L("Scegli cartella…")) { chooseSource() }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .background(targeted ? Theme.panelHigh : Theme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(Theme.blue.opacity(targeted ? 0.9 : 0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                TextField(L("CLIENTE"), text: $client).textFieldStyle(.roundedBorder)
                    .onChange(of: client) { _, new in if new != new.uppercased() { client = new.uppercased() } }
                TextField(L("Video"), text: $video).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text(L("Va in")).foregroundStyle(.secondary)
                Text(L(destination)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(L("Cambia pool…")) { choosePool() }.buttonStyle(.link)
            }
            .font(.callout)
            if analyzing {
                HStack { ProgressView().controlSize(.small); Text(LF("Controllo le clip… %@", clips.count)) }
            } else {
                summary
                if !clips.isEmpty { clipTable }
            }
            Label(LF("Per le clip puoi scegliere: cancellate (nel Cestino) %@ giorni dopo l'importazione, oppure tenute per sempre. Le cartelle restano sempre.", Doctor.poolExpiryDays),
                  systemImage: "clock.badge.exclamationmark.fill")
                .foregroundStyle(Theme.orange)
            HStack {
                Picker("", selection: $moveFiles) {
                    Text(L("Sposta (libera la cartella Download)")).tag(true)
                    Text(L("Copia")).tag(false)
                }
                .pickerStyle(.segmented).frame(width: 320)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(L("Prepara anche per Final Cut")) { askToRun(prepareFinalCut: true) }
                    .disabled(analyzing || working || video.isEmpty || clips.isEmpty)
                Button(L("Metti in ordine")) { askToRun(prepareFinalCut: false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(analyzing || working || video.isEmpty || clips.isEmpty)
            }
        }
        .card()
    }

    private var summary: some View {
        let flagged = clips.filter { !$0.notes.isEmpty }.count
        return VStack(alignment: .leading, spacing: 4) {
            Text(LF("%@ clip, %@", clips.count, formatBytes(clips.reduce(0) { $0 + $1.size })))
                .font(.headline)
            if flagged > 0 {
                Label(LF("%@ clip possono rallentare Final Cut (vedi la colonna Note).", flagged), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.orange)
            }
            if duplicateGroups > 0 {
                Label(LF("%@ gruppi di clip identiche nella cartella.", duplicateGroups), systemImage: "square.on.square")
                    .foregroundStyle(Theme.orange)
            }
            if restCount > 0 {
                Text(LF("%@ file non video finiranno nella cartella “Altro”.", restCount)).foregroundStyle(.secondary)
            }
        }
    }

    private var clipTable: some View {
        Table(clips) {
            TableColumn(L("Clip")) { Text(L($0.url.lastPathComponent)) }.width(min: 160, ideal: 220)
            TableColumn(L("Durata")) { Text(duration($0.seconds)).monospacedDigit() }.width(60)
            TableColumn(L("Formato")) { Text($0.width > 0 ? "\($0.width)×\($0.height)" : "—") }.width(90)
            TableColumn(L("fps")) { Text($0.fps > 0 ? String(format: "%g", ($0.fps * 100).rounded() / 100) : "—") }.width(50)
            TableColumn(L("Codec")) { Text(L($0.codec)) }.width(60)
            TableColumn(L("Peso")) { Text(formatBytes($0.size)).monospacedDigit() }.width(80)
            TableColumn(L("Note")) { c in
                Text(c.notes.joined(separator: " · ")).foregroundStyle(Theme.orange).lineLimit(2)
            }
        }
        .frame(minHeight: 220, maxHeight: 340)
    }

    private func sortedCard(_ folder: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Theme.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Cartella in ordine")).font(.headline)
                Text(L(folder.path)).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button(L("Mostra nel Finder")) { reveal([folder]) }.buttonStyle(.borderedProminent)
        }
        .card()
    }

    private func importCard(_ file: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "film.stack.fill").font(.title2).foregroundStyle(Theme.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Pronto per Final Cut")).font(.headline)
                Text(LF("Si crea l'evento “%@” con le clip in ordine, collegate dove stanno.", eventName))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("Mostra nel Finder")) { reveal([file]) }
            Button(L("Apri in Final Cut Pro")) { openInFinalCut(file) }.buttonStyle(.borderedProminent)
        }
        .card()
    }

    @ViewBuilder private var poolList: some View {
        if !contents.isEmpty {
            Text(L("Clip già ordinate")).font(.title3.bold())
            VStack(alignment: .leading, spacing: 6) {
                ForEach(contents, id: \.client) { c in
                    DisclosureGroup {
                        ForEach(c.videos, id: \.self) { v in
                            Button(v) { reveal([videoFolder(client: c.client, video: v)]) }.buttonStyle(.link)
                        }
                    } label: {
                        Label("\(L(c.client)) · \(c.videos.count)", systemImage: "person.crop.square")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    // MARK: Actions

    private func videoFolder(client: String, video: String) -> URL {
        client == "Senza cliente"
            ? poolRoot.appendingPathComponent(video)
            : poolRoot.appendingPathComponent(client).appendingPathComponent(video)
    }

    private func duration(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

    private func chooseSource() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.prompt = "Scegli"
        p.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
        if p.runModal() == .OK, let u = p.url { setSource(u) }
    }

    private func choosePool() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = L("Usa come pool")
        if p.runModal() == .OK, let u = p.url { poolRootPath = u.path; loadContents() }
    }

    private func setSource(_ url: URL) {
        source = url
        importFile = nil
        log = ""
        sortedFolder = nil
        let guess = Doctor.guessClientAndVideo(from: url.lastPathComponent)
        client = guess.client.uppercased()
        video = guess.video
        analyzing = true
        clips = []
        Task {
            let plan = await Task.detached {
                Doctor.poolPlan(source: url, client: "", video: "x", poolRoot: URL(fileURLWithPath: "/"))
            }.value
            restCount = plan.rest.count
            for u in plan.media { clips.append(await Doctor.inspect(u)) }
            let urls = plan.media
            duplicateGroups = await Task.detached { Doctor.duplicates(in: urls).count }.value
            analyzing = false
        }
    }

    private func run(prepareFinalCut: Bool, keepForever: Bool) {
        guard let src = source else { return }
        let root = poolRoot, c = client, v = video, move = moveFiles
        working = true
        sortedFolder = nil
        importFile = nil
        log = "Parto…"
        Task {
            let plan = await Task.detached { Doctor.poolPlan(source: src, client: c, video: v, poolRoot: root) }.value
            let result = await Task.detached(priority: .userInitiated) {
                Doctor.poolImport(plan, move: move, progress: { msg in Task { @MainActor in log = msg } })
            }.value
            var msg = LF("%@ file nel pool.", result.moved)
            if keepForever {
                if !result.placed.isEmpty { msg += " " + LF("%@ clip tenute per sempre: nessuna cancellazione.", result.placed.count) }
            } else {
                Doctor.recordPoolImport(result.placed)
                AutomationRunner.askPermission()  // the warning three days before needs the notification permission
                if !result.placed.isEmpty { msg += " " + LF("%@ clip andranno nel Cestino il %@.", result.placed.count, expiryDateText) }
            }
            if result.duplicates > 0 { msg += " " + LF("%@ erano già presenti.", result.duplicates) }
            if result.renamed > 0 { msg += " " + LF("%@ rinominati per non sovrascrivere.", result.renamed) }
            if prepareFinalCut {
                var placed: [ClipInfo] = []
                for u in result.media { placed.append(await Doctor.inspect(u)) }
                placed.sort { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
                let xml = Doctor.fcpxml(event: eventName, clips: placed)
                let file = plan.folder.appendingPathComponent("\(Doctor.safeFolderName(eventName)).fcpxml")
                if (try? xml.write(to: file, atomically: true, encoding: .utf8)) != nil { importFile = file }
                clips = placed
            }
            if result.failures.isEmpty { sortedFolder = plan.folder } else { msg += "\n" + L("Problemi:") + "\n" + result.failures.prefix(5).joined(separator: "\n") }
            log = msg
            working = false
            loadContents()
        }
    }

    private func openInFinalCut(_ file: URL) {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.FinalCut") {
            NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            log = LF("Non trovo Final Cut Pro su questo Mac. Il file è qui: %@", file.path)
        }
    }

    private func loadContents() {
        let root = poolRoot
        Task { contents = await Task.detached { Doctor.poolContents(root) }.value }
        expiring = Doctor.poolExpiryEntries()
    }

    /// "3 clip, scadono il 3 dic (tra 12 giorni)".
    private func expiryLine(_ entries: [PoolExpiryEntry]) -> String {
        let first = entries.map(\.expiresAt).min() ?? Date()
        let days = max(0, Int((first.timeIntervalSinceNow / 86_400).rounded(.up)))
        let when = days == 0 ? L("oggi") : LF("tra %@ %@", days, days == 1 ? L("giorno") : L("giorni"))
        return LF("%@ clip, scadono il %@ (%@)", entries.count, first.formatted(date: .abbreviated, time: .shortened), when)
    }

    private var expiryDateText: String {
        Doctor.poolExpiryDate(importedAt: Date()).formatted(date: .long, time: .shortened)
    }

    private func askToRun(prepareFinalCut: Bool) {
        pendingFinalCut = prepareFinalCut
        askExpiry = true
    }

    /// Clips waiting for their day, one line per video folder.
    @ViewBuilder private var expiringCard: some View {
        let groups = Dictionary(grouping: expiring) { URL(fileURLWithPath: $0.path).deletingLastPathComponent().deletingLastPathComponent() }
            .sorted { ($0.value.map(\.expiresAt).min() ?? .distantFuture) < ($1.value.map(\.expiresAt).min() ?? .distantFuture) }
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Clip in scadenza")).font(.headline)
                Text(LF("Vanno nel Cestino %@ giorni dopo l'importazione, e ti avviso 3 giorni prima. «Tieni per sempre» le toglie dalla lista: non verranno mai cancellate.", Doctor.poolExpiryDays))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(groups, id: \.key) { folder, entries in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(folder.deletingLastPathComponent().lastPathComponent + " / " + folder.lastPathComponent).lineLimit(1)
                            Text(expiryLine(entries))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("Tieni per sempre")) { Doctor.cancelPoolExpiry(under: folder); expiring = Doctor.poolExpiryEntries() }
                    }
                }
            }
            .card()
        }
    }
}
