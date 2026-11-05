import AppKit
import FCPCore
import SwiftUI

struct BackupView: View {
    @EnvironmentObject var model: Model
    @State private var source: URL?
    @State private var destination: URL?
    @State private var diff: BackupDiff?
    @State private var running = false
    @State private var log = ""
    @State private var history = Doctor.history()

    private var finalCutIsOpen: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.FinalCut" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L("Copia una libreria su un altro disco, solo ciò che è nuovo o cambiato, e controlla ogni file copiato con un checksum. Non cancella mai niente nella destinazione."))
                    .foregroundStyle(.secondary)
                if model.realLibraries.isEmpty {
                    Text(L("Nessuna libreria trovata. Aggiungi con + il disco o la cartella che la contiene."))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                } else {
                    form
                }
                if !log.isEmpty { Text(L(log)).font(.callout).textSelection(.enabled) }
                historyList
            }
            .padding(16)
        }
        .navigationTitle(L("Backup verificato"))
        .onAppear { source = source ?? model.realLibraries.first?.url }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(L("Libreria"), selection: $source) {
                ForEach(model.realLibraries) { lib in Text(L(lib.name)).tag(Optional(lib.url)) }
            }
            .onChange(of: source) { _ in diff = nil }
            HStack {
                Text(L("Copia in")).frame(width: 70, alignment: .leading)
                Text(destination?.path ?? L("nessuna destinazione")).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(L("Scegli…")) { chooseDestination() }
            }
            if finalCutIsOpen {
                Label(L("Final Cut Pro è aperto: la copia potrebbe non essere coerente. Chiudilo prima."),
                      systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            HStack {
                Button(L("Confronta")) { compare() }.disabled(source == nil || destination == nil || running)
                Button(L("Esegui backup")) { run() }
                    .buttonStyle(.borderedProminent)
                    .disabled(diff == nil || running || diff?.toCopy.isEmpty == true)
                if running { ProgressView().controlSize(.small) }
            }
            if let d = diff {
                Text(d.toCopy.isEmpty
                     ? LF("Il backup è già aggiornato: %@ file identici.", d.same)
                     : LF("%@ nuovi, %@ modificati, %@ identici. Da copiare: %@.", d.new.count, d.changed.count, d.same, formatBytes(d.bytes)))
                    .font(.headline)
                if d.extra > 0 {
                    Text(LF("%@ file stanno solo nella destinazione: restano dove sono.", d.extra)).foregroundStyle(.secondary)
                }
            }
        }
        .card()
    }

    @ViewBuilder private var historyList: some View {
        if !history.isEmpty {
            Text(L("Storico")).font(.title3.bold())
            Table(history) {
                TableColumn(L("Data")) { Text($0.date.formatted(date: .abbreviated, time: .shortened)) }
                    .width(min: 130, ideal: 150)
                TableColumn(L("Libreria")) { Text(URL(fileURLWithPath: $0.source).lastPathComponent) }
                TableColumn(L("Copiati")) { Text("\($0.copied)").monospacedDigit() }.width(70)
                TableColumn(L("Peso")) { Text(formatBytes($0.bytes)).monospacedDigit() }.width(90)
                TableColumn(L("Verificati")) { Text("\($0.verified)").monospacedDigit() }.width(80)
                TableColumn(L("Esito")) { r in
                    Text(r.failures.isEmpty ? "OK" : LF("%@ errori", r.failures.count))
                        .foregroundStyle(r.failures.isEmpty ? Color.green : Color.red)
                }.width(80)
            }
            .frame(minHeight: 200)
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Scegli"
        if panel.runModal() == .OK { destination = panel.url; diff = nil }
    }

    private func compare() {
        guard let s = source, let d = destination else { return }
        let target = d.appendingPathComponent(s.lastPathComponent)
        log = "Confronto…"
        Task {
            diff = await Task.detached(priority: .userInitiated) { Doctor.diff(source: s, destination: target) }.value
            log = ""
        }
    }

    private func run() {
        guard let s = source, let d = destination else { return }
        running = true
        log = "Parto…"
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<BackupRecord, Error> in
                Result { try Doctor.backup(source: s, into: d, progress: { msg in
                    Task { @MainActor in log = msg }
                }) }
            }.value
            running = false
            switch outcome {
            case .success(let r):
                Doctor.record(r)
                history = Doctor.history()
                log = r.failures.isEmpty
                    ? LF("Backup finito: %@ file copiati e verificati.", r.copied)
                    : LF("Backup finito con %@ errori:", r.failures.count) + "\n" + r.failures.prefix(5).joined(separator: "\n")
            case .failure(let e):
                log = e.localizedDescription
            }
            compare()
        }
    }
}
