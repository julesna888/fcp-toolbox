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
                Text(L(model.status)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(L(emptyTitle), systemImage: "checkmark.circle", description: Text(L(emptyText)))
        }
    }
}

struct Stat: View {
    let title: String
    let value: String
    var tint: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L(value)).font(.title2.bold()).foregroundStyle(tint).monospacedDigit()
            Text(L(title)).font(.callout).foregroundStyle(.secondary)
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
                        TableColumn(L("Importazione"), value: \.name) { Text(L($0.name)) }
                        TableColumn(L("File"), value: \.fileCount) { Text("\($0.fileCount)").monospacedDigit() }.width(60)
                        TableColumn(L("Peso"), value: \.size) { Text(formatBytes($0.size)).monospacedDigit() }.width(90)
                        TableColumn(L("Usato da una libreria"), value: \.linkedSize) {
                            Text(formatBytes($0.linkedSize)).monospacedDigit()
                        }.width(min: 120, ideal: 150)
                        TableColumn(L("Senza libreria"), value: \.orphanSize) {
                            Text(formatBytes($0.orphanSize)).monospacedDigit()
                                .foregroundStyle($0.orphanSize > 0 ? Color.orange : Color.secondary)
                        }.width(min: 100, ideal: 120)
                    }
                    .contextMenu(forSelectionType: ImportFolder.ID.self) { ids in
                        Button(L("Mostra nel Finder")) { reveal(Array(ids)) }
                        Divider()
                        Button(L("Sposta nel Cestino…"), role: .destructive) { pendingTrash = Array(ids) }
                    }
                    .trashConfirmation($pendingTrash,
                                       warning: L("Le clip di queste cartelle che una libreria usa diventeranno mancanti."))
                }
            } else {
                ScanState(emptyTitle: "Nessun media trovato",
                          emptyText: "Non ho trovato una cartella “Final Cut Original Media” in questa posizione. Aggiungi il disco dove Final Cut salva i media.")
            }
        }
        .navigationTitle(L("Mappa spazio"))
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
            Text(LF("Una riga per ogni giorno di importazione. Librerie considerate: %@.", r.libraryNames.isEmpty ? L("nessuna") : r.libraryNames.joined(separator: ", ")))
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
            if disk.isEmpty { return LF("%@ stavano sul disco del Mac: file spostati o cancellati.", n) }
            let plugged = FileManager.default.fileExists(atPath: "/Volumes/\(disk)")
            return plugged ? LF("%@ stavano sul disco “%@”, che è collegato: i file sono stati spostati o cancellati.", n, disk)
                           : LF("%@ stavano sul disco “%@”, che ora NON è collegato: collegalo e rifai la scansione.", n, disk)
        }
    }

    var body: some View {
        Group {
            if let r = model.report, !r.broken.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(LF("%@ file mancanti, %@ ritrovabili", r.broken.count, r.recoverableCount))
                            .font(.title3.bold())
                        Text(L("Final Cut li mostra come clip rosse. “Ritrovato in” indica una cartella dove esiste ancora un file con lo stesso nome. Per ricollegarli usa File ▸ Ricollega file in Final Cut."))
                            .foregroundStyle(.secondary)
                        ForEach(causes(r.broken), id: \.self) { Label($0, systemImage: "externaldrive").foregroundStyle(Theme.orange) }
                    }
                    .padding(16)
                    Divider()
                    Table(r.broken.sorted(using: sort), selection: $selection, sortOrder: $sort) {
                        TableColumn(L("File"), value: \.name) { Text(L($0.name)) }
                        TableColumn(L("Libreria › Evento"), value: \.eventLabel) { Text(L($0.eventLabel)) }
                        TableColumn(L("Ritrovato in"), value: \.foundIn) { b in
                            if b.found.isEmpty {
                                Text(L("Non trovato")).foregroundStyle(.secondary)
                            } else {
                                Text(L(b.foundIn)).foregroundStyle(Color.green)
                            }
                        }.width(min: 110, ideal: 140)
                    }
                    .contextMenu(forSelectionType: BrokenLink.ID.self) { ids in
                        let picked = r.broken.filter { ids.contains($0.id) }
                        Button(L("Mostra file ritrovato nel Finder")) { reveal(picked.compactMap { $0.found.first }) }
                            .disabled(picked.allSatisfy { $0.found.isEmpty })
                        Button(L("Copia il percorso mancante")) {
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
        .navigationTitle(L("Media mancanti"))
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
                        Text(LF("%@ file, %@ senza libreria", r.orphans.count, formatBytes(r.orphanSize)))
                            .font(.title3.bold())
                        Text(LF("File in “Final Cut Original Media” che nessuna di queste librerie usa: %@. Se usi altre librerie, anche su altri dischi, aggiungile prima: i loro file sembrerebbero orfani. Finiscono nel Cestino, quindi li puoi recuperare.", r.libraryNames.isEmpty ? L("nessuna") : r.libraryNames.joined(separator: ", ")))
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    Divider()
                    Table(r.orphans.sorted(using: sort), selection: $selection, sortOrder: $sort) {
                        TableColumn(L("File"), value: \.name) { Text(L($0.name)) }
                        TableColumn(L("Importazione"), value: \.importName) { Text(L($0.importName)) }.width(min: 100, ideal: 130)
                        TableColumn(L("Peso"), value: \.size) { Text(formatBytes($0.size)).monospacedDigit() }.width(90)
                    }
                    .contextMenu(forSelectionType: MediaFile.ID.self) { ids in
                        Button(L("Mostra nel Finder")) {
                            reveal(r.orphans.filter { ids.contains($0.id) }.map(\.url))
                        }
                    }
                    .spacePreview(picked.map(\.url))
                    Divider()
                    HStack {
                        Button(L("Seleziona tutti")) { selection = Set(r.orphans.map(\.id)) }
                        Spacer()
                        Text(selection.isEmpty ? L("Nessun file selezionato")
                                               : LF("%@ selezionati · %@", picked.count, formatBytes(pickedSize)))
                            .foregroundStyle(.secondary)
                        Button(L("Sposta nel Cestino…")) { confirming = true }
                            .disabled(selection.isEmpty || model.busy || r.libraryNames.isEmpty)
                    }
                    .padding(12)
                }
                .confirmationDialog(LF("Spostare %@ file nel Cestino?", picked.count),
                                    isPresented: $confirming, titleVisibility: .visible) {
                    Button(L("Sposta nel Cestino"), role: .destructive) {
                        model.trashOrphans(picked)
                        selection = []
                    }
                } message: {
                    Text(LF("%@ di media che nessuna libreria usa. Restano recuperabili dal Cestino. Per liberare davvero lo spazio devi poi svuotarlo.", formatBytes(pickedSize)))
                }
            } else {
                ScanState(emptyTitle: "Nessun file orfano",
                          emptyText: "Ogni file in “Final Cut Original Media” è usato da una libreria trovata.")
            }
        }
        .navigationTitle(L("Media orfani"))
    }
}
