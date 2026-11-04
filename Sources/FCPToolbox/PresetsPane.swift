import AppKit
import FCPCore
import SwiftUI

private let batchMediaExtensions: Set<String> = ["mov", "mp4", "m4v", "mxf", "avi", "mkv", "mts", "m2ts", "webm", "wav", "mp3", "m4a", "aac", "aif", "aiff", "flac"]

/// Folders are opened one level; only audio and video files are kept.
func batchFiles(_ urls: [URL]) -> [URL] {
    expandFiles(urls).filter { batchMediaExtensions.contains($0.pathExtension.lowercased()) }
}

/// Edits the parameters of one step.
struct StepEditor: View {
    @Binding var step: Step

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch step.kind {
            case .resize:
                HStack {
                    TextField("Larghezza", value: $step.width, format: .number).frame(width: 80)
                    Text("×")
                    TextField("Altezza", value: $step.height, format: .number).frame(width: 80)
                    Picker("", selection: $step.fit) {
                        Text("Riempi (taglia ai lati)").tag(false)
                        Text("Intero (barre nere)").tag(true)
                    }.labelsHidden().frame(width: 220)
                }
                Text("Mai deformato. 1080×1920 è il formato verticale per Reel, TikTok e Shorts.").font(.caption).foregroundStyle(.secondary)
            case .compress:
                HStack { Text("Massimo"); TextField("MB", value: $step.targetMB, format: .number).frame(width: 70); Text("MB") }
            case .audio:
                Picker("Formato", selection: $step.audio) {
                    ForEach(AudioFormat.allCases) { Text($0.label).tag($0.rawValue) }
                }.pickerStyle(.segmented).frame(width: 220)
                Text("Dopo questo passaggio il file è solo audio: mettilo per ultimo.").font(.caption).foregroundStyle(.secondary)
            case .stripMetadata:
                ForEach(MetadataKind.allCases) { k in
                    Toggle(k.rawValue, isOn: Binding(
                        get: { step.metadata.contains(k.rawValue) },
                        set: { on in
                            step.metadata.removeAll { $0 == k.rawValue }
                            if on { step.metadata.append(k.rawValue) }
                        }))
                }
            case .rename:
                TextField("Nome", text: $step.pattern).frame(width: 260)
                Text("{name} nome originale, {n} numero (anche {n:3}), {date} data. Esempio: {name} reel").font(.caption).foregroundStyle(.secondary)
            default:
                Text(step.kind == .prepare ? "Frame rate fisso, H.264 e AAC: sicuro per Final Cut e CapCut." : "Porta il volume a -14 LUFS senza ricodificare il video.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Builds a list of steps in order; used by the preset editor and the batch pane.
struct StepListEditor: View {
    @Binding var steps: [Step]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(steps.indices), id: \.self) { i in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(i + 1)").font(.headline).foregroundStyle(Theme.green).frame(width: 20)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(steps[i].kind.title).font(.headline)
                        StepEditor(step: $steps[i])
                    }
                    Spacer()
                    Button { steps.swapAt(i, i - 1) } label: { Image(systemName: "arrow.up") }.disabled(i == 0).accessibilityLabel("Sposta su").help("Sposta su")
                    Button { steps.swapAt(i, i + 1) } label: { Image(systemName: "arrow.down") }.disabled(i == steps.count - 1).accessibilityLabel("Sposta giù").help("Sposta giù")
                    Button { if steps.indices.contains(i) { steps.remove(at: i) } } label: { Image(systemName: "trash") }.accessibilityLabel("Elimina passo").help("Elimina passo")
                }
                .buttonStyle(.borderless)
                .card(padding: 10)
            }
            Menu("Aggiungi un passaggio") {
                ForEach(Step.Kind.allCases, id: \.self) { k in Button(k.title) { steps.append(Step(k)) } }
            }.fixedSize()
            if let problem = Doctor.validateSteps(steps), !steps.isEmpty { Text(problem).foregroundStyle(Theme.orange) }
        }
    }
}

/// All the presets: the ones that come with the app and the user's own.
struct PresetsPane: View {
    @State private var mine: [Preset] = Doctor.loadUserPresets()
    @State private var draft: Preset?
    @State private var toDelete: Preset?
    @State private var message: String?

    private func persist() { if !Doctor.saveUserPresets(mine) { message = "Non riesco a salvare i preset." } }

    private func use(_ p: Preset) {
        let files = batchFiles(chooseItems(folders: false, message: "A quali file applico \"\(p.name)\"?"))
        guard !files.isEmpty else { return }
        BatchQueue.shared.add(files, steps: p.steps, label: p.name, outputDir: p.outputFolder.map { URL(fileURLWithPath: $0) })
        BatchQueue.shared.start()
        message = "\(files.count) file messi in coda e avviati. Guarda i progressi in Coda di lavori."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Un preset è una serie di operazioni salvata con un nome: la applichi a tanti file con un clic. L'originale non viene mai toccato, il risultato è un file nuovo.")
                    .foregroundStyle(.secondary)
                if let message { Text(message).foregroundStyle(message.contains("in coda") || message.contains("salvato") ? Theme.green : Theme.orange) }
                if let d = draft {
                    editor(d)
                } else {
                    Button("Nuovo preset") { draft = Preset(name: "Il mio preset", steps: []) }
                }
                Text("Preset pronti").font(.headline)
                ForEach(Doctor.starterPresets) { row($0) }
                if !mine.isEmpty {
                    Text("I miei preset").font(.headline)
                    ForEach(mine) { row($0) }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Eliminare il preset?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } })) {
            Button("Elimina", role: .destructive) {
                if let t = toDelete { mine.removeAll { $0.id == t.id }; persist() }
                toDelete = nil
            }
            Button("Annulla", role: .cancel) { toDelete = nil }
        } message: { Text("\"\(toDelete?.name ?? "")\" sparisce dalla lista. I file già creati non vengono toccati.") }
    }

    private func row(_ p: Preset) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(p.name).font(.headline)
                if p.isBuiltIn { Text("incluso").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Usa su file…") { use(p) }
                if p.isBuiltIn {
                    Button("Duplica e modifica") { draft = Preset(name: p.name + " (mio)", steps: p.steps, outputFolder: p.outputFolder) }
                } else {
                    Button("Modifica") { draft = p }
                    Button("Elimina", role: .destructive) { toDelete = p }
                }
            }
            ForEach(Array(p.steps.enumerated()), id: \.offset) { Text("\($0.offset + 1). \($0.element.summary)").font(.callout).foregroundStyle(.secondary) }
            if let f = p.outputFolder { Text("Salva in: \(f)").font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func editor(_ d: Preset) -> some View {
        let binding = Binding(get: { draft ?? d }, set: { draft = $0 })
        return VStack(alignment: .leading, spacing: 10) {
            Text(mine.contains { $0.id == d.id } ? "Modifica preset" : "Nuovo preset").font(.headline)
            TextField("Nome del preset", text: binding.name).frame(width: 300)
            StepListEditor(steps: binding.steps)
            HStack {
                Text(binding.wrappedValue.outputFolder ?? "Cartella: accanto all'originale").foregroundStyle(.secondary)
                Button("Scegli cartella…") {
                    if let u = chooseItems(folders: true, message: "Dove salvo i file finiti?").first { draft?.outputFolder = u.path }
                }
                if binding.wrappedValue.outputFolder != nil { Button("Accanto all'originale") { draft?.outputFolder = nil } }
            }
            HStack {
                Button("Salva") {
                    guard let p = draft else { return }
                    if p.name.trimmingCharacters(in: .whitespaces).isEmpty { message = "Dai un nome al preset."; return }
                    if let bad = Doctor.validateSteps(p.steps) { message = bad; return }
                    if let i = mine.firstIndex(where: { $0.id == p.id }) { mine[i] = p } else { mine.append(p) }
                    persist(); draft = nil; message = "Preset salvato."
                }.buttonStyle(.borderedProminent)
                Button("Annulla") { draft = nil }
            }
        }
        .card()
    }
}
