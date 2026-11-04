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
                Text("Copia una libreria su un altro disco, solo ciò che è nuovo o cambiato, e controlla ogni file copiato con un checksum. Non cancella mai niente nella destinazione.")
                    .foregroundStyle(.secondary)
                if model.realLibraries.isEmpty {
                    Text("Nessuna libreria trovata. Aggiungi con + il disco o la cartella che la contiene.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                } else {
                    form
                }
                if !log.isEmpty { Text(log).font(.callout).textSelection(.enabled) }
                historyList
            }
            .padding(16)
        }
        .navigationTitle("Backup verificato")
        .onAppear { source = source ?? model.realLibraries.first?.url }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Libreria", selection: $source) {
                ForEach(model.realLibraries) { lib in Text(lib.name).tag(Optional(lib.url)) }
            }
            .onChange(of: source) { _ in diff = nil }
            HStack {
                Text("Copia in").frame(width: 70, alignment: .leading)
                Text(destination?.path ?? "nessuna destinazione").foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Scegli…") { chooseDestination() }
            }
            if finalCutIsOpen {
                Label("Final Cut Pro è aperto: la copia potrebbe non essere coerente. Chiudilo prima.",
                      systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            HStack {
                Button("Confronta") { compare() }.disabled(source == nil || destination == nil || running)
                Button("Esegui backup") { run() }
                    .buttonStyle(.borderedProminent)
                    .disabled(diff == nil || running || diff?.toCopy.isEmpty == true)
                if running { ProgressView().controlSize(.small) }
            }
            if let d = diff {
                Text(d.toCopy.isEmpty
                     ? "Il backup è già aggiornato: \(d.same) file identici."
                     : "\(d.new.count) nuovi, \(d.changed.count) modificati, \(d.same) identici. Da copiare: \(formatBytes(d.bytes)).")
                    .font(.headline)
                if d.extra > 0 {
                    Text("\(d.extra) file stanno solo nella destinazione: restano dove sono.").foregroundStyle(.secondary)
                }
            }
        }
        .card()
    }

    @ViewBuilder private var historyList: some View {
        if !history.isEmpty {
            Text("Storico").font(.title3.bold())
            Table(history) {
                TableColumn("Data") { Text($0.date.formatted(date: .abbreviated, time: .shortened)) }
                    .width(min: 130, ideal: 150)
                TableColumn("Libreria") { Text(URL(fileURLWithPath: $0.source).lastPathComponent) }
                TableColumn("Copiati") { Text("\($0.copied)").monospacedDigit() }.width(70)
                TableColumn("Peso") { Text(formatBytes($0.bytes)).monospacedDigit() }.width(90)
                TableColumn("Verificati") { Text("\($0.verified)").monospacedDigit() }.width(80)
                TableColumn("Esito") { r in
                    Text(r.failures.isEmpty ? "OK" : "\(r.failures.count) errori")
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
                    ? "Backup finito: \(r.copied) file copiati e verificati."
                    : "Backup finito con \(r.failures.count) errori:\n" + r.failures.prefix(5).joined(separator: "\n")
            case .failure(let e):
                log = e.localizedDescription
            }
            compare()
        }
    }
}
