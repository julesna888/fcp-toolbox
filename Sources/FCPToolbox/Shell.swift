import AppKit
import FCPCore
import SwiftUI

/// "Open this tool, with these files" — the single message the drop zone, the search palette,
/// Finder quick actions and `fcptoolbox://` links all send through `Model.openRequest`.
struct OpenRequest: Equatable {
    let id = UUID()
    let toolID: String
    let urls: [URL]
}

/// Glue between the pure `ToolCatalog` (FCPCore) and the screens.
enum Shell {
    /// Sidebar screen that shows this tool; nil if the id is unknown.
    static func sidebarTool(for toolID: String) -> Tool? {
        if toolID == DeepLink.dropID { return .tools }
        guard let entry = ToolCatalog.entry(toolID) else { return nil }
        switch entry.target {
        case .sidebar(let raw): return Tool(rawValue: raw)
        case .extra, .convert: return .tools
        case .inspector: return .inspector
        }
    }

    /// Requests that need no receiving screen are cleared by ContentView right away.
    static func needsReceiver(_ toolID: String) -> Bool {
        if toolID == DeepLink.dropID { return true }
        guard let entry = ToolCatalog.entry(toolID) else { return false }
        if case .sidebar = entry.target { return false }
        return true
    }

    static func icon(for entry: ToolEntry) -> String {
        switch entry.target {
        case .sidebar(let raw): return Tool(rawValue: raw)?.icon ?? "wrench"
        case .extra(let raw): return ToolsView.Extra(rawValue: raw)?.icon ?? "wrench"
        case .inspector: return "film"
        case .convert(let raw):
            switch ConvertTool(rawValue: raw) {
            case .prepare: return "film.stack"
            case .audio: return "music.note"
            case .normalize: return "speaker.wave.2.fill"
            case .compress: return "arrow.down.right.and.arrow.up.left"
            case .still: return "photo"
            case nil: return "wrench"
            }
        }
    }
}

// MARK: - Trascina qui

/// One big drop area: whatever you drop, it proposes the tools that can really work on it.
struct UniversalDropZone: View {
    @EnvironmentObject var model: Model
    @Binding var urls: [URL]
    @State private var targeted = false
    @State private var showAll = false

    private var suggestions: [ToolSuggestion] { ToolCatalog.suggestions(for: urls) }
    /// The few that fit this file best; the rest sit behind "Altre".
    private var shown: [ToolSuggestion] { showAll ? suggestions : Array(suggestions.prefix(4)) }

    var body: some View {
        VStack(spacing: 12) {
            if urls.isEmpty {
                Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 34)).foregroundStyle(targeted ? Theme.green : .secondary)
                Text(L("Trascina qui qualsiasi file")).font(.title3.bold())
                Text(L("Riconosco il tipo (video, audio, immagine, sottotitoli, cartella) e ti propongo cosa si può fare."))
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(L("Scegli file o cartelle…")) { pick() }
            } else {
                HStack {
                    Text(ToolCatalog.describe(urls)).font(.headline)
                    Text(urls.prefix(3).map(\.lastPathComponent).joined(separator: ", ") + (urls.count > 3 ? "…" : ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button(L("Svuota")) { urls = []; showAll = false }
                }
                if suggestions.isEmpty {
                    Text(L("Per questo tipo di file non ho strumenti.")).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8)], spacing: 8) {
                    ForEach(shown) { s in
                        Button { model.open(s.entry.id, urls: urls) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: Shell.icon(for: s.entry)).frame(width: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(L(s.entry.title)).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    if !s.suitsAll { Text(L("solo per alcuni file")).font(.caption2).foregroundStyle(.secondary) }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(Theme.panelHigh, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(s.entry.summary)
                    }
                }
                if suggestions.count > 4 {
                    Button(showAll ? L("Mostra meno") : "\(L("Altre azioni")) (\(suggestions.count - 4))…") { withAnimation { showAll.toggle() } }
                        .buttonStyle(.link)
                }
                Text(L("I file non vengono modificati: ogni strumento salva un risultato nuovo. Gli strumenti per un solo file usano il primo."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 130)
        .padding(14)
        .background(targeted ? Theme.panelHigh : Theme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7]))
            .foregroundStyle(targeted ? Theme.green : Theme.stroke))
        .dropDestination(for: URL.self) { dropped, _ in urls = dropped; return true } isTargeted: { targeted = $0 }
    }

    private func pick() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = true; p.allowsMultipleSelection = true
        p.message = "Quali file o cartelle?"
        if p.runModal() == .OK { urls = p.urls }
    }
}

// MARK: - Cerca uno strumento (Cmd+K)

struct SearchPalette: View {
    @EnvironmentObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    private var results: [ToolEntry] { ToolCatalog.search(query) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Cerca uno strumento: «compress video», «sottotitoli», «rinomina»…", text: $query)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($focused)
                    .onSubmit { open(selected) }
                    .onKeyPress(.downArrow) { selected = min(selected + 1, max(results.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
            }
            .padding(14)
            Divider()
            if results.isEmpty {
                Text("Nessuno strumento per «\(query)».").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { i, e in
                                Button { open(i) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: Shell.icon(for: e)).frame(width: 24).foregroundStyle(Theme.green)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(e.title).font(.headline)
                                            Text(e.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(i == selected ? Theme.panelHigh : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(e.id)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: selected) { _, i in if results.indices.contains(i) { proxy.scrollTo(results[i].id) } }
                }
            }
            Divider()
            Text("↑↓ per scegliere · Invio per aprire · Esc per chiudere").font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .frame(width: 560, height: 420)
        .background(Theme.bg)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in selected = 0 }
    }

    private func open(_ i: Int) {
        guard results.indices.contains(i) else { return }
        model.open(results[i].id)
        dismiss()
    }
}

// MARK: - Azioni rapide del Finder

struct QuickActionsCard: View {
    @State private var installed: [URL] = QuickActions.installed()
    @State private var confirming = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Azioni rapide nel Finder").font(.headline)
            Text("Dal Finder: seleziona uno o più file, tasto destro, «Azioni rapide», poi «FCP Toolbox - …». L'app si apre sullo strumento scelto con i file già caricati.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Se dopo l'installazione le voci non compaiono, riapri il Finder (o esci e rientra dall'account) e guarda in Impostazioni di Sistema, sezione Estensioni.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Installa le azioni rapide nel Finder…") { confirming = true }
                if !installed.isEmpty { Button("Rimuovi") { remove() } }
                Text(installed.isEmpty ? "Non installate" : "\(installed.count) installate").foregroundStyle(.secondary)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .card()
        .confirmationDialog("Creare \(QuickActions.actions.count) azioni rapide?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Crea in ~/Library/Services") { install() }
        } message: {
            Text("Crea queste cartelle .workflow in ~/Library/Services:\n" + QuickActions.actions.map { "• " + $0.fileName }.joined(separator: "\n")
                 + "\nPuoi toglierle quando vuoi con «Rimuovi»; non tocco altro.")
        }
    }

    private func install() {
        do {
            let made = try QuickActions.install()
            installed = QuickActions.installed()
            message = "Create \(made.count) azioni in ~/Library/Services."
        } catch { message = "Non sono riuscito a crearle: \(error.localizedDescription)" }
    }

    private func remove() {
        do {
            let gone = try QuickActions.remove()
            installed = QuickActions.installed()
            message = "Rimosse \(gone.count) azioni."
        } catch { message = "Non sono riuscito a rimuoverle: \(error.localizedDescription)" }
    }
}
