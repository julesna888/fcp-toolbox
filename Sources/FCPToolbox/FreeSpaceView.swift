import FCPCore
import SwiftUI

/// One screen for "free space on this disk": only Final Cut leftovers, safe ones first.
struct FreeSpaceView: View {
    @EnvironmentObject var model: Model
    @State private var disk: Volume.ID?
    @State private var confirmClean = false
    @State private var confirmBackups = false

    private var volume: Volume? { model.volumes.first { $0.id == disk } }
    private var scanned: Bool { volume.map { model.roots == [$0.url] } ?? false }
    private var oldBackups: [Library] { Doctor.oldBackups(model.backups) }
    private var oldBackupBytes: Int64 { oldBackups.reduce(0) { $0 + $1.total } }
    private var analysisBytes: Int64 {
        model.libraries.flatMap(\.items).filter { $0.kind == .onDemand && $0.canClean(includeAnalysis: true) }.reduce(0) { $0 + $1.size }
    }
    private var safeBytes: Int64 { model.freeable - (model.includeAnalysis ? analysisBytes : 0) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                picker
                if scanned { results }
            }
            .padding(16)
        }
        .navigationTitle("Libera spazio")
        .onAppear {
            model.includeAnalysis = false  // analysis files only when asked, here and now
            pickDefaultDisk()
        }
        .onChange(of: model.volumes) { _, _ in pickDefaultDisk() }  // the list loads after the screen appears
        .confirmationDialog("Svuotare render e proxy?", isPresented: $confirmClean, titleVisibility: .visible) {
            Button("Svuota e libera \(formatBytes(model.freeable))", role: .destructive) { model.clean() }
        } message: {
            Text("Final Cut li rigenera da solo, ma su un disco lento ci vuole tempo. Originali e backup non vengono toccati.")
        }
        .confirmationDialog("Spostare \(oldBackups.count) backup nel Cestino?", isPresented: $confirmBackups, titleVisibility: .visible) {
            Button("Cestina \(formatBytes(oldBackupBytes))", role: .destructive) { model.trashItems(oldBackups.map(\.url)) }
        } message: {
            Text("Restano i 3 backup più recenti di ogni cartella.")
        }
    }

    private func pickDefaultDisk() {
        guard !model.volumes.contains(where: { $0.id == disk }) else { return }
        disk = (model.volumes.first { model.roots == [$0.url] } ?? model.volumes.first { !$0.internalDisk } ?? model.volumes.first)?.id
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Da quale disco vuoi liberare spazio?").font(.title3.bold())
            Text("Cerco solo cose di Final Cut. Non tocco i tuoi media in uso né i progetti.").foregroundStyle(.secondary)
            HStack {
                Picker("Disco", selection: $disk) {
                    ForEach(model.volumes) { v in Text("\(v.name) · liberi \(formatBytes(v.free))").tag(Optional(v.id)) }
                }
                .labelsHidden().fixedSize()
                Button(scanned ? "Rifai la ricerca" : "Cerca file inutili") {
                    guard let v = volume else { return }
                    if model.roots == [v.url] { model.rescan() } else { model.roots = [v.url]; model.rescan() }
                }
                .disabled(volume == nil || model.busy)
                if model.busy { ProgressView().controlSize(.small); Text(model.status).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder private var results: some View {
        if !model.busy {
            section(title: "Sicuro da togliere", tint: Theme.green) {
                line("Render e proxy che Final Cut rigenera", safeBytes,
                     button: "Svuota…", enabled: safeBytes > 0) { confirmClean = true }
                line("Backup automatici vecchi (tengo gli ultimi 3)", oldBackupBytes,
                     button: "Cestina…", enabled: oldBackupBytes > 0) { confirmBackups = true }
                if safeBytes == 0 && oldBackupBytes == 0 {
                    Text("Niente da togliere in modo sicuro su questo disco.").foregroundStyle(.secondary)
                }
            }
            section(title: "Da rivedere tu", tint: Theme.orange) {
                Toggle(isOn: $model.includeAnalysis) {
                    HStack { Text("File di analisi (si rigenerano, ma possono volerci ore)"); Spacer(); Text(formatBytes(analysisBytes)).monospacedDigit() }
                }
                .disabled(analysisBytes == 0)
                line("Media non usati da nessuna libreria", model.report?.orphanSize ?? 0,
                     button: "Rivedi…", enabled: (model.report?.orphans.count ?? 0) > 0) { model.requestedTool = .orphans }
                if let names = model.report?.libraryNames, !names.isEmpty {
                    Text("Controllati contro: \(names.joined(separator: ", ")). Se usi altre librerie, aggiungile prima.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if volume?.internalDisk == false {
                Label("Su un disco esterno il Cestino non libera spazio finché non lo svuoti.", systemImage: "trash")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func section<C: View>(title: String, tint: Color, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(tint)
            content()
        }
        .card()
    }

    private func line(_ title: String, _ size: Int64, button: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(formatBytes(size)).monospacedDigit().foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
            Button(button, action: action).disabled(!enabled || model.busy)
        }
    }
}
