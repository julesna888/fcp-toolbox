import AppKit
import FCPCore
import SwiftUI

func reveal(_ urls: [URL]) {
    NSWorkspace.shared.activateFileViewerSelecting(urls)
}

/// Shown while the first scan runs, or when a scan found nothing for this tool.
struct ScanState: View {
    @EnvironmentObject var model: Model
    let emptyTitle: String
    let emptyText: String

    var body: some View {
        if model.busy {
            VStack(spacing: 10) {
                ProgressView()
                Text(model.status).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(emptyTitle, systemImage: "checkmark.circle", description: Text(emptyText))
        }
    }
}

struct Stat: View {
    let title: String
    let value: String
    var tint: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.bold()).foregroundStyle(tint).monospacedDigit()
            Text(title).font(.callout).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Mappa spazio

struct MapView: View {
    @EnvironmentObject var model: Model
    @State private var sort = [KeyPathComparator(\ImportFolder.size, order: .reverse)]
    @State private var selection = Set<ImportFolder.ID>()
    @State private var pendingTrash: [URL] = []

    var body: some View {
        Group {
            if let r = model.report, !r.imports.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    header(r)
                    Divider()
                    Table(r.imports.sorted(using: sort), selection: $selection, sortOrder: $sort) {
                        TableColumn("Importazione", value: \.name) { Text($0.name) }
                        TableColumn("File", value: \.fileCount) { Text("\($0.fileCount)").monospacedDigit() }.width(60)
                        TableColumn("Peso", value: \.size) { Text(formatBytes($0.size)).monospacedDigit() }.width(90)
                        TableColumn("Usato da una libreria", value: \.linkedSize) {
                            Text(formatBytes($0.linkedSize)).monospacedDigit()
                        }.width(min: 120, ideal: 150)
                        TableColumn("Senza libreria", value: \.orphanSize) {
                            Text(formatBytes($0.orphanSize)).monospacedDigit()
                                .foregroundStyle($0.orphanSize > 0 ? Color.orange : Color.secondary)
                        }.width(min: 100, ideal: 120)
                    }
                    .contextMenu(forSelectionType: ImportFolder.ID.self) { ids in
                        Button("Mostra nel Finder") { reveal(Array(ids)) }
                        Divider()
                        Button("Sposta nel Cestino…", role: .destructive) { pendingTrash = Array(ids) }
                    }
                    .trashConfirmation($pendingTrash,
                                       warning: "Le clip di queste cartelle che una libreria usa diventeranno mancanti.")
                }
            } else {
                ScanState(emptyTitle: "Nessun media trovato",
                          emptyText: "Non ho trovato una cartella “Final Cut Original Media” in questa posizione. Aggiungi il disco dove Final Cut salva i media.")
            }
        }
        .navigationTitle("Mappa spazio")
    }

    private func header(_ r: MediaReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Tile(value: formatBytes(r.totalSize), label: "media di Final Cut")
                Tile(value: formatBytes(r.linkedSize), label: "usati da una libreria", tint: Theme.green)
                Tile(value: formatBytes(r.orphanSize), label: "senza libreria",
                     tint: r.orphanSize > 0 ? Theme.orange : nil)
                Tile(value: "\(r.broken.count)", label: "collegamenti rotti",
                     tint: r.broken.isEmpty ? nil : Theme.orange)
            }
            Text("Una riga per ogni giorno di importazione. Librerie considerate: \(r.libraryNames.isEmpty ? "nessuna" : r.libraryNames.joined(separator: ", ")).")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(16)
    }
}

// MARK: - Media mancanti

struct MissingView: View {
    @EnvironmentObject var model: Model
    @State private var sort = [KeyPathComparator(\BrokenLink.eventLabel)]
    @State private var selection = Set<BrokenLink.ID>()

    private var previewURLs: [URL] {
        (model.report?.broken ?? []).filter { selection.contains($0.id) }.compactMap { $0.found.first }
    }

    /// Where the missing files used to live: a disk that is not plugged in explains them all at once.
    private func causes(_ broken: [BrokenLink]) -> [String] {
        var byDisk: [String: Int] = [:]
        for b in broken {
            let parts = b.target.pathComponents
            let disk = parts.count > 2 && parts[1] == "Volumes" ? parts[2] : ""
            byDisk[disk, default: 0] += 1
        }
        return byDisk.sorted { $0.value > $1.value }.map { disk, n in
            if disk.isEmpty { return "\(n) stavano sul disco del Mac: file spostati o cancellati." }
            let plugged = FileManager.default.fileExists(atPath: "/Volumes/\(disk)")
            return plugged ? "\(n) stavano sul disco “\(disk)”, che è collegato: i file sono stati spostati o cancellati."
                           : "\(n) stavano sul disco “\(disk)”, che ora NON è collegato: collegalo e rifai la scansione."
        }
    }

    var body: some View {
        Group {
            if let r = model.report, !r.broken.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(r.broken.count) file mancanti, \(r.recoverableCount) ritrovabili")
                            .font(.title3.bold())
                        Text("Final Cut li mostra come clip rosse. “Ritrovato in” indica una cartella dove esiste ancora un file con lo stesso nome. Per ricollegarli usa File ▸ Ricollega file in Final Cut.")
                            .foregroundStyle(.secondary)
                        ForEach(causes(r.broken), id: \.self) { Label($0, systemImage: "externaldrive").foregroundStyle(Theme.orange) }
                    }
                    .padding(16)
                    Divider()
                    Table(r.broken.sorted(using: sort), selection: $selection, sortOrder: $sort) {
                        TableColumn("File", value: \.name) { Text($0.name) }
                        TableColumn("Libreria › Evento", value: \.eventLabel) { Text($0.eventLabel) }
                        TableColumn("Ritrovato in", value: \.foundIn) { b in
                            if b.found.isEmpty {
                                Text("Non trovato").foregroundStyle(.secondary)
                            } else {
                                Text(b.foundIn).foregroundStyle(Color.green)
                            }
                        }.width(min: 110, ideal: 140)
                    }
                    .contextMenu(forSelectionType: BrokenLink.ID.self) { ids in
                        let picked = r.broken.filter { ids.contains($0.id) }
                        Button("Mostra file ritrovato nel Finder") { reveal(picked.compactMap { $0.found.first }) }
                            .disabled(picked.allSatisfy { $0.found.isEmpty })
                        Button("Copia il percorso mancante") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(picked.map(\.target.path).joined(separator: "\n"), forType: .string)
                        }
                    }
                    .spacePreview(previewURLs)
                }
            } else {
                ScanState(emptyTitle: "Nessun file mancante",
                          emptyText: "Tutti i collegamenti delle librerie trovate puntano a file che esistono.")
            }
        }
        .navigationTitle("Media mancanti")
    }
}

// MARK: - Media orfani

struct OrphansView: View {
    @EnvironmentObject var model: Model
    @State private var sort = [KeyPathComparator(\MediaFile.size, order: .reverse)]
    @State private var selection = Set<MediaFile.ID>()
    @State private var confirming = false

    private var picked: [MediaFile] { (model.report?.orphans ?? []).filter { selection.contains($0.id) } }
    private var pickedSize: Int64 { picked.reduce(0) { $0 + $1.size } }

    var body: some View {
        Group {
            if let r = model.report, !r.orphans.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(r.orphans.count) file, \(formatBytes(r.orphanSize)) senza libreria")
                            .font(.title3.bold())
                        Text("File in “Final Cut Original Media” che nessuna di queste librerie usa: \(r.libraryNames.isEmpty ? "nessuna" : r.libraryNames.joined(separator: ", ")). Se usi altre librerie, anche su altri dischi, aggiungile prima: i loro file sembrerebbero orfani. Finiscono nel Cestino, quindi li puoi recuperare.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    Divider()
                    Table(r.orphans.sorted(using: sort), selection: $selection, sortOrder: $sort) {
                        TableColumn("File", value: \.name) { Text($0.name) }
                        TableColumn("Importazione", value: \.importName) { Text($0.importName) }.width(min: 100, ideal: 130)
                        TableColumn("Peso", value: \.size) { Text(formatBytes($0.size)).monospacedDigit() }.width(90)
                    }
                    .contextMenu(forSelectionType: MediaFile.ID.self) { ids in
                        Button("Mostra nel Finder") {
                            reveal(r.orphans.filter { ids.contains($0.id) }.map(\.url))
                        }
                    }
                    .spacePreview(picked.map(\.url))
                    Divider()
                    HStack {
                        Button("Seleziona tutti") { selection = Set(r.orphans.map(\.id)) }
                        Spacer()
                        Text(selection.isEmpty ? "Nessun file selezionato"
                                               : "\(picked.count) selezionati · \(formatBytes(pickedSize))")
                            .foregroundStyle(.secondary)
                        Button("Sposta nel Cestino…") { confirming = true }
                            .disabled(selection.isEmpty || model.busy || r.libraryNames.isEmpty)
                    }
                    .padding(12)
                }
                .confirmationDialog("Spostare \(picked.count) file nel Cestino?",
                                    isPresented: $confirming, titleVisibility: .visible) {
                    Button("Sposta nel Cestino", role: .destructive) {
                        model.trashOrphans(picked)
                        selection = []
                    }
                } message: {
                    Text("\(formatBytes(pickedSize)) di media che nessuna libreria usa. Restano recuperabili dal Cestino. Per liberare davvero lo spazio devi poi svuotarlo.")
                }
            } else {
                ScanState(emptyTitle: "Nessun file orfano",
                          emptyText: "Ogni file in “Final Cut Original Media” è usato da una libreria trovata.")
            }
        }
        .navigationTitle("Media orfani")
    }
}
