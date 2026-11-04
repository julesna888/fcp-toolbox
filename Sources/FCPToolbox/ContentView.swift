import FCPCore
import SwiftUI
import UniformTypeIdentifiers

enum Tool: String, CaseIterable, Identifiable {
    case freeSpace = "Libera spazio"
    case tools = "Strumenti"
    case download = "Scarica da link"
    case pool = "Ordina cartelle clienti"
    case preflight = "Controllo prima di montare"
    case crash = "Diagnosi crash Final Cut"
    case libraries = "Librerie e progetti"
    case map = "Mappa spazio"
    case disks = "Dischi"
    case backup = "Backup verificato"
    case missing = "Media mancanti"
    case orphans = "Media orfani"
    case cleanup = "Cache e render"
    case health = "Salute libreria"
    case automations = "Avvisi automatici"
    case inspector = "Controlla il video finito"
    case manage = "Gestione media"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .freeSpace: return "sparkles"
        case .tools: return "wrench.and.screwdriver"
        case .download: return "arrow.down.circle"
        case .pool: return "tray.and.arrow.down.fill"
        case .preflight: return "gauge.with.dots.needle.67percent"
        case .crash: return "bolt.trianglebadge.exclamationmark"
        case .libraries: return "books.vertical"
        case .map: return "internaldrive"
        case .disks: return "externaldrive.fill"
        case .backup: return "checkmark.shield"
        case .missing: return "exclamationmark.triangle"
        case .orphans: return "questionmark.folder"
        case .cleanup: return "externaldrive.badge.minus"
        case .health: return "heart.text.square"
        case .automations: return "bell.badge"
        case .inspector: return "film"
        case .manage: return "square.stack.3d.up"
        }
    }
}

enum ToolGroup: String, CaseIterable, Identifiable {
    case work = "Lavoro"
    case library = "Libreria"
    case space = "Spazio"
    case media = "Media"
    var id: String { rawValue }
}

extension Tool {
    var group: ToolGroup {
        switch self {
        case .tools, .download, .pool, .preflight, .crash, .automations: return .work
        case .libraries, .backup, .health: return .library
        case .freeSpace, .map, .disks, .cleanup: return .space
        case .missing, .orphans, .inspector, .manage: return .media
        }
    }

    /// Tools that stay in the app (other screens link to them) but are not offered in the sidebar:
    /// either another screen does the same job better, or they only listed things without a next step.
    var hidden: Bool {
        switch self {
        case .freeSpace, .tools, .download, .pool, .preflight, .crash, .automations, .inspector: return false
        default: return true
        }
    }

    /// One colour per sidebar group, so the colour tells you which group a page belongs to.
    var tint: Color {
        switch group {
        case .work: return Theme.blue
        case .library: return Theme.violet
        case .space: return Theme.green
        case .media: return Theme.orange
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: Model
    /// Re-reads the language when it changes, so the sidebar and the page redraw in the new one.
    @AppStorage(Lang.key) private var langRaw = ""
    @State private var showWelcome = !UserDefaults.standard.bool(forKey: WelcomeView.seenKey) || CommandLine.arguments.contains("--welcome")
    @State private var tool: Tool? = Tool.allCases.first { CommandLine.arguments.contains("--tool=\($0)") } ?? .tools

    var body: some View {
        NavigationSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    SidebarHeader().padding(.horizontal, 10).padding(.bottom, 6)
                    ForEach(ToolGroup.allCases.filter { g in Tool.allCases.contains { $0.group == g && !$0.hidden } }) { g in
                        Text(L(g.rawValue).uppercased())
                            .font(.system(size: 10, weight: .semibold)).tracking(0.8)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 2)
                        ForEach(Tool.allCases.filter { $0.group == g && !$0.hidden }) { t in
                            sidebarButton(t)
                        }
                    }
                }
                .padding(10)
            }
            .background(Theme.panel)
            .safeAreaInset(edge: .bottom, spacing: 0) { UpdateFooter() }
            .navigationSplitViewColumnWidth(min: 230, ideal: 250)
            .id(langRaw)
        } detail: {
            detail
                .safeAreaInset(edge: .top, spacing: 0) {
                    if langRaw == "en" && tool != .tools { UntranslatedBanner() }
                }
                .id(langRaw)
        }
        .frame(minWidth: 960, minHeight: 600)
        .background(Theme.bg)
        .scrollContentBackground(.hidden)
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        }
        .fileImporter(isPresented: $model.picking, allowedContentTypes: [.folder, .package],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.add(urls) }
        }
        .sheet(isPresented: $showWelcome) { WelcomeView() }
        .sheet(isPresented: $model.showSearch) { SearchPalette() }
        .onChange(of: model.openRequest, initial: true) { _, r in
            guard let r else { return }
            guard let t = Shell.sidebarTool(for: r.toolID) else {
                model.notice = "Strumento non trovato: \(r.toolID)"; model.openRequest = nil; return
            }
            tool = t
            if !Shell.needsReceiver(r.toolID) { model.openRequest = nil }
        }
        .onChange(of: model.requestedTool) { _, t in
            if let t { tool = t; model.requestedTool = nil }
        }
        .toolbar {
            ToolbarItemGroup {
                LangSwitch()
                Button { model.showSearch = true } label: { Label(L("Cerca strumento"), systemImage: "magnifyingglass") }
                    .help("Cerca uno strumento (⌘K)")
                Button { showWelcome = true } label: { Label(L("Guida"), systemImage: "questionmark.circle") }
                    .help("Rivedi la guida alle funzioni")
                // disk buttons only where a disk is involved: on the tools they only confused
                if tool == .freeSpace || tool?.hidden ?? true {
                    if !model.roots.isEmpty {
                        Menu {
                            ForEach(model.roots, id: \.self) { url in
                                Button("Rimuovi “\(url.lastPathComponent)”") { model.remove(url) }
                            }
                        } label: {
                            Label("Dischi analizzati", systemImage: "externaldrive")
                        }
                        .help("Dischi e cartelle analizzati")
                    }
                    Button { model.picking = true } label: { Label("Aggiungi disco", systemImage: "plus") }
                        .help("Aggiungi disco o cartella (⌘O)")
                    Button { model.rescan() } label: { Label("Rifai analisi", systemImage: "arrow.clockwise") }
                        .help("Rifai l'analisi (⌘R)")
                        .disabled(model.roots.isEmpty || model.busy)
                }
            }
        }
        .alert("FCP Toolbox", isPresented: Binding(
            get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(model.notice ?? "")
        }
    }

    private func sidebarButton(_ t: Tool) -> some View {
        Button { tool = t } label: {
            SidebarRow(tool: t, badge: badge(for: t))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tool == t ? Theme.panelHigh : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .leading) {
                    if tool == t { Capsule().fill(t.tint).frame(width: 3, height: 16).offset(x: -1) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func badge(for tool: Tool) -> Int {
        switch tool {
        case .disks: return model.lowVolumes.count
        case .missing: return model.report?.broken.count ?? 0
        case .orphans: return model.report?.orphans.count ?? 0
        default: return 0
        }
    }

    @ViewBuilder private var detail: some View {
        if tool == .tools {
            ToolsView()
        } else if tool == .download {
            DownloadView()
        } else if tool == .freeSpace {
            FreeSpaceView()
        } else if tool == .disks {
            DisksView()
        } else if tool == .pool {
            PoolView()
        } else if tool == .preflight {
            PreflightView()
        } else if tool == .crash {
            CrashView()
        } else if tool == .health {
            HealthView()
        } else if tool == .automations {
            AutomationsView()
        } else if tool == .inspector {
            InspectorView()
        } else if tool == .manage {
            ManageView()
        } else if model.roots.isEmpty {
            ContentUnavailableView {
                Label("Trascina qui il disco dei tuoi media", systemImage: "externaldrive")
            } description: {
                Text("Ad esempio il tuo SSD esterno. Cerco la cartella “Final Cut Original Media” e le librerie (.fcpbundle) per dirti dove è finito lo spazio. Finché non confermi, non cancello niente.")
            } actions: {
                Button("Scegli…") { model.picking = true }
            }
        } else {
            switch tool ?? .libraries {
            case .freeSpace: FreeSpaceView()
            case .tools: ToolsView()
            case .download: DownloadView()
            case .pool: PoolView()
            case .preflight: PreflightView()
            case .crash: CrashView()
            case .libraries: LibrariesView()
            case .map: MapView()
            case .disks: DisksView()
            case .backup: BackupView()
            case .missing: MissingView()
            case .orphans: OrphansView()
            case .cleanup: CleanupView()
            case .health: HealthView()
            case .automations: AutomationsView()
            case .inspector: InspectorView()
            case .manage: ManageView()
            }
        }
    }
}

struct CleanupView: View {
    @EnvironmentObject var model: Model
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            if model.realLibraries.isEmpty && model.backups.isEmpty {
                ScanState(emptyTitle: "Nessuna libreria",
                          emptyText: "Non ho trovato librerie Final Cut (.fcpbundle) in questa posizione.")
            } else {
                content
            }
            Divider()
            footer
        }
        .navigationTitle("Cache e render")
        .confirmationDialog("Svuotare \(model.cleanable.count) cartelle?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("Svuota e libera \(formatBytes(model.freeable))", role: .destructive) { model.clean() }
        } message: {
            Text("I media originali e i backup non vengono toccati. Final Cut dovrà rigenerare i render.")
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                summary
                ForEach(model.realLibraries) { lib in card(lib) }
                if !model.backups.isEmpty { backupCard }
            }
            .padding(16)
        }
    }

    private var summary: some View {
        let libs = model.realLibraries
        let total = libs.reduce(0) { $0 + $1.total }
        return VStack(alignment: .leading, spacing: 4) {
            Text(libs.isEmpty ? "Nessuna libreria, solo backup automatici"
                              : "\(libs.count) \(libs.count == 1 ? "libreria" : "librerie") · \(formatBytes(total))")
                .font(.title3.bold())
            Text(model.freeable == 0
                 ? "Niente da liberare qui: non ci sono render o media ottimizzati dentro le librerie. Il peso grosso sta nei media: guarda “Mappa spazio”."
                 : "Puoi liberare \(formatBytes(model.freeable)) senza toccare gli originali.")
                .foregroundStyle(.secondary)
        }
    }

    private func card(_ lib: Library) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(lib.name).font(.headline)
                Spacer()
                Text(formatBytes(lib.total)).foregroundStyle(.secondary)
            }
            Divider()
            ForEach(lib.items.filter { $0.size > 0 }) { item in row(item) }
            if lib.other > 0 {
                plainRow("Altri file (database, progetti, miniature)", lib.other)
            }
            if !lib.items.contains(where: { $0.canClean(includeAnalysis: model.includeAnalysis) }) {
                Text("Niente da liberare in questa libreria.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private var backupCard: some View {
        let total = model.backups.reduce(0) { $0 + $1.total }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock.arrow.circlepath").font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Backup automatici di Final Cut").font(.headline)
                Text("\(model.backups.count) copie, create da Final Cut. Per toglierle usa “Librerie e progetti” o il Finder.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Text(formatBytes(total)).foregroundStyle(.secondary)
        }
        .card()
    }

    private func row(_ item: Item) -> some View {
        let canClean = item.canClean(includeAnalysis: model.includeAnalysis)
        let color: Color = canClean ? .green : (item.blocked != nil ? .secondary : .orange)
        return HStack {
            Text(item.label)
            Spacer()
            Text(item.note(includeAnalysis: model.includeAnalysis))
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(color.opacity(0.15), in: Capsule())
                .foregroundStyle(color)
            Text(formatBytes(item.size)).monospacedDigit().frame(width: 90, alignment: .trailing)
        }
    }

    private func plainRow(_ title: String, _ size: Int64) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(formatBytes(size)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Includi i file di analisi", isOn: $model.includeAnalysis)
                .help("Si rigenerano, ma l'analisi può richiedere ore")
            Spacer()
            Text("Liberabili: \(model.freeable == 0 ? "niente" : formatBytes(model.freeable))")
                .foregroundStyle(.secondary)
            Button("Pulisci…") { confirming = true }
                .disabled(model.cleanable.isEmpty || model.busy)
        }
        .padding(12)
    }
}

/// Bottom of the sidebar: the version you have and a visible way to look for a newer one.
struct UpdateFooter: View {
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    @State private var checking = false

    var body: some View {
        HStack(spacing: 8) {
            Text("\(L("Versione")) \(version)").foregroundStyle(.secondary)
            Spacer()
            Button(checking ? L("Controllo…") : L("Controlla aggiornamenti")) {
                checking = true
                Task { await Updater.check(); checking = false }
            }
            .buttonStyle(.link).disabled(checking)
        }
        .font(.caption)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Theme.panel)
        .overlay(alignment: .top) { Divider() }
    }
}
