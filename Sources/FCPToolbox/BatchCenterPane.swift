import AppKit
import FCPCore
import SwiftUI

/// The queue: drop many files, choose a preset or your own steps, watch progress, retry what failed.
struct BatchCenterPane: View {
    @ObservedObject private var queue = BatchQueue.shared
    @State private var presets: [Preset] = Doctor.starterPresets + Doctor.loadUserPresets()
    @State private var presetID = Doctor.starterPresets[0].id
    @State private var custom = false
    @State private var customSteps: [Step] = [Step(.prepare)]
    @State private var outputFolder: URL?
    @State private var note: String?

    private var preset: Preset? { presets.first { $0.id == presetID } }
    private var steps: [Step] { custom ? customSteps : (preset?.steps ?? []) }

    private func add(_ urls: [URL]) {
        let files = batchFiles(urls)
        guard !files.isEmpty else { note = "Nessun video o audio tra i file scelti."; return }
        if let bad = Doctor.validateSteps(steps) { note = bad; return }
        let dir = outputFolder ?? (custom ? nil : preset?.outputFolder.map { URL(fileURLWithPath: $0) })
        queue.add(files, steps: steps, label: custom ? "Operazioni scelte" : (preset?.name ?? "Preset"), outputDir: dir)
        note = "\(files.count) file in coda."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Una coda per decine o centinaia di file: scegli cosa fare, trascina i file, vai a fare altro. Un file alla volta, e se uno va storto gli altri continuano. L'originale non viene mai toccato.")
                    .foregroundStyle(.secondary)
                if Doctor.ffmpegPath == nil { MissingToolHelp(what: "Manca ffmpeg, il programma gratuito che converte i video.", command: "brew install ffmpeg", isInstalled: { Doctor.ffmpegPath != nil }) }

                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: $custom) {
                        Text("Un preset").tag(false)
                        Text("Operazioni a scelta").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 320)
                    if custom {
                        StepListEditor(steps: $customSteps)
                    } else {
                        Picker("Preset", selection: $presetID) { ForEach(presets) { Text($0.name).tag($0.id) } }.frame(width: 360)
                        ForEach(Array(steps.enumerated()), id: \.offset) {
                            Text("\($0.offset + 1). \($0.element.summary)").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text(outputFolder?.path ?? "Cartella: quella del preset, altrimenti accanto all'originale").foregroundStyle(.secondary)
                        Button("Scegli cartella…") { outputFolder = chooseItems(folders: true, message: "Dove salvo i file finiti?").first }
                        if outputFolder != nil { Button("Annulla scelta") { outputFolder = nil } }
                    }
                }.card()

                DropBox(title: "Trascina qui video, audio o cartelle", button: "Scegli file…",
                        onURLs: add, onPick: { add(chooseItems(folders: false, message: "Quali file metto in coda?")) })
                if let note { Text(note).foregroundStyle(note.contains("in coda") ? Theme.green : Theme.orange) }
                queueView
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { presets = Doctor.starterPresets + Doctor.loadUserPresets() }
    }

    private var queueView: some View {
        let c = queue.counts
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Coda").font(.headline)
                Text(queue.summary).foregroundStyle(.secondary)
                Spacer()
                if queue.isRunning {
                    Button("Ferma il file in corso") { queue.stopCurrent() }
                    Button("Ferma tutto") { queue.stopAll() }
                } else {
                    Button("Avvia") { queue.start() }.disabled(c.waiting == 0).buttonStyle(.borderedProminent)
                    Button("Riprova gli errori") { queue.retryFailed() }.disabled(c.failed == 0)
                    Button("Togli i finiti") { queue.clearFinished() }.disabled(c.done == 0)
                }
            }
            if queue.items.isEmpty {
                Text("Nessun file in coda. Trascina o scegli i file qui sopra.").foregroundStyle(.secondary)
            } else {
                // Lazy: hundreds of rows cost nothing until they scroll into view.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(queue.items) { BatchRow(item: $0) }
                    }
                }.frame(minHeight: 120, maxHeight: 420)
            }
        }.card()
    }
}

private struct BatchRow: View {
    let item: BatchItem

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(item.file.lastPathComponent).lineLimit(1).truncationMode(.middle)
                switch item.status {
                case .waiting: Text("In attesa · \(item.label)").font(.caption).foregroundStyle(.secondary)
                case .running(let f): ProgressView(value: f).frame(maxWidth: 260)
                case .done(let u): Text("Creato: \(u.lastPathComponent)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                case .failed(let why): Text(why).font(.caption).foregroundStyle(Theme.red).lineLimit(3)
                }
            }
            Spacer()
            if case .done(let u) = item.status { Button("Mostra nel Finder") { reveal([u]) }.buttonStyle(.borderless) }
        }
    }

    @ViewBuilder private var icon: some View {
        switch item.status {
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.red)
        }
    }
}
