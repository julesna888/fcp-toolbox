import AppKit
import FCPCore
import QuickLook
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

/// Space bar opens Quick Look on whatever is selected in the screen on view, in any screen, like in the Finder.
/// Arrow keys move between the files; space again closes it. Typing in a text field is never intercepted.
@MainActor
final class PreviewHub: NSObject, QLPreviewPanelDataSource {
    static let shared = PreviewHub()
    private(set) var urls: [URL] = []
    private var monitor: Any?

    func set(_ new: [URL]) {
        urls = new
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let plain = event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            guard event.keyCode == 49, plain else { return event }
            return MainActor.assumeIsolated { PreviewHub.shared.handleSpace() ? nil : event }
        }
    }

    private func handleSpace() -> Bool {
        if let r = NSApp.keyWindow?.firstResponder, r is NSText || r is NSTextField { return false }  // typing a space
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
            return true
        }
        guard !urls.isEmpty else { return false }
        let panel = QLPreviewPanel.shared()!
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
        return true
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { MainActor.assumeIsolated { urls.count } }
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { index < urls.count ? urls[index] as NSURL : nil }
    }
}

struct SpacePreview: ViewModifier {
    let urls: [URL]

    func body(content: Content) -> some View {
        content
            .onAppear { PreviewHub.shared.set(urls) }
            .onChange(of: urls) { _, new in PreviewHub.shared.set(new) }
            .onDisappear { PreviewHub.shared.set([]) }
    }
}

/// Asks before moving things to the Trash, and says honestly what the user loses.
struct TrashConfirmation: ViewModifier {
    @EnvironmentObject var model: Model
    @Binding var pending: [URL]
    let warning: String

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Spostare \(pending.count) \(pending.count == 1 ? "elemento" : "elementi") nel Cestino?",
            isPresented: Binding(get: { !pending.isEmpty }, set: { if !$0 { pending = [] } }),
            titleVisibility: .visible
        ) {
            Button("Sposta nel Cestino", role: .destructive) {
                model.trashItems(pending)
                pending = []
            }
        } message: {
            Text(([warning] + pending.prefix(4).map(\.lastPathComponent) + (pending.count > 4 ? ["…"] : []))
                .filter { !$0.isEmpty }.joined(separator: "\n"))
        }
    }
}

extension View {
    func spacePreview(_ urls: [URL]) -> some View { modifier(SpacePreview(urls: urls)) }
    func trashConfirmation(_ pending: Binding<[URL]>, warning: String) -> some View {
        modifier(TrashConfirmation(pending: pending, warning: warning))
    }
}

struct LibrariesView: View {
    @EnvironmentObject var model: Model
    @State private var sort = [KeyPathComparator(\Node.size, order: .reverse)]
    @State private var selection = Set<Node.ID>()
    @State private var query = ""
    @State private var pendingTrash: [URL] = []
    @State private var checkingXML = false
    @State private var trashWarning = ""

    private func sorted(_ nodes: [Node]) -> [Node] {
        nodes.sorted(using: sort).map { n in
            var m = n
            m.children = n.children.map(sorted)
            return m
        }
    }

    /// Keeps a node if its name matches (with everything below it) or if something below it matches.
    private func filtered(_ nodes: [Node]) -> [Node] {
        guard !query.isEmpty else { return nodes }
        return nodes.compactMap { n in
            if n.name.localizedCaseInsensitiveContains(query) { return n }
            guard let kids = n.children else { return nil }
            let kept = filtered(kids)
            if kept.isEmpty { return nil }
            var m = n
            m.children = kept
            return m
        }
    }

    private func flat(_ nodes: [Node]) -> [Node] { nodes.flatMap { [$0] + flat($0.children ?? []) } }
    private var selected: [Node] { flat(model.tree).filter { selection.contains($0.id) } }

    private func icon(_ kind: Node.Kind) -> String {
        switch kind {
        case .library: return "books.vertical"
        case .event: return "calendar"
        case .project: return "film"
        case .group: return "photo.on.rectangle"
        case .clip: return "play.rectangle"
        }
    }

    private func warning(for nodes: [Node], original: Bool) -> String {
        if original { return "Cancelli i file video veri: le librerie che li usano li troveranno mancanti." }
        if nodes.contains(where: { $0.kind == .library }) {
            return "Cancelli l'intera libreria. I media collegati fuori dalla libreria restano dove sono."
        }
        if nodes.contains(where: { $0.kind == .event || $0.kind == .project || $0.kind == .group }) {
            return "Cancellare eventi e progetti da fuori Final Cut può lasciare la libreria incoerente. Fai prima un backup."
        }
        return "Le clip tolte dalla libreria non si vedranno più in Final Cut, i file video restano su disco."
    }

    var body: some View {
        Group {
            if model.tree.isEmpty {
                ScanState(emptyTitle: "Nessuna libreria",
                          emptyText: "Non ho trovato librerie Final Cut (.fcpbundle) in questa posizione.")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Divider()
                    Table(sorted(filtered(model.tree)), children: \.children, selection: $selection, sortOrder: $sort) {
                        TableColumn("Nome", value: \.name) { n in Label(n.name, systemImage: icon(n.kind)) }
                            .width(min: 240, ideal: 320)
                        TableColumn("Peso", value: \.size) { Text(formatBytes($0.size)).monospacedDigit() }.width(90)
                        TableColumn("Fuori dalla libreria", value: \.external) {
                            Text($0.external > 0 ? formatBytes($0.external) : "—").monospacedDigit()
                                .foregroundStyle(Color.secondary)
                        }.width(min: 120, ideal: 150)
                        TableColumn("Media", value: \.media) {
                            Text($0.media > 0 ? "\($0.media)" : "—").monospacedDigit().foregroundStyle(Color.secondary)
                        }.width(70)
                        TableColumn("Mancanti", value: \.missing) { n in
                            Text(n.missing > 0 ? "\(n.missing)" : "—").monospacedDigit()
                                .foregroundStyle(n.missing > 0 ? Color.orange : Color.secondary)
                        }.width(80)
                        TableColumn("Modificato", value: \.modified) { n in
                            Text(n.modified == .distantPast ? "—" : n.modified.formatted(date: .abbreviated, time: .omitted))
                                .foregroundStyle(Color.secondary)
                        }.width(min: 100, ideal: 120)
                    }
                    .contextMenu(forSelectionType: Node.ID.self) { ids in
                        let nodes = flat(model.tree).filter { ids.contains($0.id) }
                        let originals = nodes.compactMap(\.preview)
                        Button("Mostra nel Finder") { reveal(nodes.map { $0.preview ?? $0.url }) }
                        if nodes.count == 1, nodes[0].kind == .library {
                            Button("Apri in Final Cut Pro") { NSWorkspace.shared.open(nodes[0].url) }
                        }
                        Button("Copia il percorso") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(nodes.map { ($0.preview ?? $0.url).path }.joined(separator: "\n"),
                                                           forType: .string)
                        }
                        Divider()
                        Button("Sposta nel Cestino…", role: .destructive) {
                            trashWarning = warning(for: nodes, original: false)
                            pendingTrash = nodes.map(\.url)
                        }
                        if !originals.isEmpty {
                            Button("Sposta il file video originale nel Cestino…", role: .destructive) {
                                trashWarning = warning(for: nodes, original: true)
                                pendingTrash = originals
                            }
                        }
                    }
                    .spacePreview(selected.compactMap(\.preview))
                    .trashConfirmation($pendingTrash, warning: trashWarning)
                }
            }
        }
        .navigationTitle("Librerie e progetti")
        .searchable(text: $query, prompt: "Cerca evento, progetto o clip")
        .fileImporter(isPresented: $checkingXML, allowedContentTypes: [.xml, .package, .folder, .data]) { r in
            guard case .success(let u) = r else { return }
            _ = u.startAccessingSecurityScopedResource()
            do {
                let x = try Doctor.analyzeFCPXML(u)
                let problems = x.missingFiles.count + x.duplicateIDs.count + x.danglingRefs.count + x.anomalies.count
                model.notice = "FCPXML \(x.version): \(x.assets) file, \(x.clips) clip, frame rate \(x.frameRates.joined(separator: ", ")).\n"
                    + (problems == 0 ? "Non ho trovato problemi." : "Problemi: \(x.missingFiles.count) file mancanti, \(x.duplicateIDs.count) ID doppi, \(x.danglingRefs.count) riferimenti rotti. "
                       + x.anomalies.joined(separator: " "))
            } catch { model.notice = "Non riesco a leggere questo FCPXML: \(error.localizedDescription)" }
        }
        .toolbar {
            ToolbarItem {
                Button { checkingXML = true } label: { Label("Controlla FCPXML", systemImage: "doc.text.magnifyingglass") }
                    .help("Legge un FCPXML senza modificarlo e segnala file mancanti e riferimenti rotti")
            }
            ToolbarItem {
                Button { exportCSV() } label: { Label("Esporta elenco", systemImage: "square.and.arrow.up") }
                    .help("Esporta librerie, eventi e progetti in un file CSV")
                    .disabled(model.tree.isEmpty)
            }
        }
    }

    private var header: some View {
        let events = model.tree.flatMap { $0.children ?? [] }
        let projects = events.flatMap { $0.children ?? [] }.filter { $0.kind == .project }
        let missing = model.tree.reduce(0) { $0 + $1.missing }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Tile(value: "\(model.tree.count)", label: model.tree.count == 1 ? "libreria" : "librerie")
                Tile(value: "\(events.count)", label: events.count == 1 ? "evento" : "eventi")
                Tile(value: "\(projects.count)", label: projects.count == 1 ? "progetto" : "progetti")
                Tile(value: formatBytes(model.tree.reduce(0) { $0 + $1.size }), label: "peso totale", tint: Theme.violet)
                Tile(value: "\(missing)", label: "clip mancanti", tint: missing > 0 ? Theme.orange : nil)
            }
            Text("Il peso comprende i media collegati fuori dalla libreria. Apri “Media” in un evento, seleziona una clip e premi la barra spaziatrice per l'anteprima. Tasto destro per le azioni: tutto va nel Cestino, quindi è recuperabile.")
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private func exportCSV() {
        func cell(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["tipo,libreria,evento,progetto,peso_byte,fuori_libreria_byte,media,mancanti,modificato"]
        let iso = ISO8601DateFormatter()
        for lib in model.tree {
            lines.append(["libreria", lib.name, "", "", "\(lib.size)", "\(lib.external)", "\(lib.media)", "\(lib.missing)",
                          iso.string(from: lib.modified)].map(cell).joined(separator: ","))
            for ev in lib.children ?? [] {
                lines.append(["evento", lib.name, ev.name, "", "\(ev.size)", "\(ev.external)", "\(ev.media)",
                              "\(ev.missing)", iso.string(from: ev.modified)].map(cell).joined(separator: ","))
                for p in (ev.children ?? []) where p.kind == .project {
                    lines.append(["progetto", lib.name, ev.name, p.name, "\(p.size)", "0", "0", "0",
                                  iso.string(from: p.modified)].map(cell).joined(separator: ","))
                }
            }
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "librerie-final-cut.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            model.notice = "Non sono riuscito a salvare il file: \(error.localizedDescription)"
        }
    }
}
