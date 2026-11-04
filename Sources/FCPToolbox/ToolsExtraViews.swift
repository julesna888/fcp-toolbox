import AppKit
import FCPCore
import SwiftUI

/// Opens the system file/folder chooser.
@MainActor func chooseItems(folders: Bool, message: String) -> [URL] {
    let p = NSOpenPanel()
    p.message = message
    p.canChooseFiles = !folders
    p.canChooseDirectories = folders
    p.allowsMultipleSelection = !folders
    return p.runModal() == .OK ? p.urls : []
}

/// Files inside the folders (one level deep, no hidden files); plain files stay as they are.
func expandFiles(_ urls: [URL]) -> [URL] {
    urls.flatMap { u -> [URL] in
        guard u.hasDirectoryPath else { return [u] }
        let items = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: [.isRegularFileKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }
}

struct DropBox: View {
    let title: String
    let button: String
    let onURLs: ([URL]) -> Void
    let onPick: () -> Void
    /// Files handed over by "Trascina qui" / search / Finder: loaded once, as if just dropped.
    var preload: [URL] = []
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc").font(.title)
            Text(title).font(.headline)
            Button(button, action: onPick)
        }
        .frame(maxWidth: .infinity, minHeight: 110)
        .background(targeted ? Theme.panelHigh : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6])).foregroundStyle(targeted ? Theme.green : Theme.stroke))
        .dropDestination(for: URL.self) { urls, _ in onURLs(urls); return true } isTargeted: { targeted = $0 }
        .onAppear { if !preload.isEmpty { onURLs(preload) } }
    }
}

// MARK: - Media inspector

struct InfoPane: View {
    var initialURLs: [URL] = []
    @State private var infos: [MediaInfo] = []
    @State private var errors: [String] = []
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DropBox(title: "Trascina qui uno o più video per vedere tutti i dati", button: "Scegli file…",
                    onURLs: load, onPick: { load(chooseItems(folders: false, message: "Quali file controllo?")) }, preload: initialURLs)
            if busy { ProgressView().controlSize(.small) }
            ForEach(errors, id: \.self) { Text($0).foregroundStyle(Theme.orange) }
            ForEach(infos) { InfoCard(info: $0) }
        }
    }

    private func load(_ urls: [URL]) {
        let files = expandFiles(urls)
        guard !files.isEmpty else { return }
        busy = true; infos = []; errors = []
        Task {
            for f in files {
                let r = await Task.detached { Result { try Doctor.probeMedia(f) } }.value
                switch r {
                case .success(let i): infos.append(i)
                case .failure: errors.append("\(f.lastPathComponent): non è un file video o audio che riesco a leggere.")
                }
            }
            busy = false
        }
    }
}

struct InfoCard: View {
    let info: MediaInfo

    private func mbps(_ b: Int64) -> String { b > 0 ? String(format: "%.1f Mbps", Double(b) / 1_000_000) : "—" }
    private func time(_ s: Double) -> String {
        let t = Int(s.rounded()); return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t % 3600 / 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(v).textSelection(.enabled)
            Spacer()
        }
    }
    /// Size the file really takes on disk (can differ from its logical size).
    private var onDisk: Int64 {
        Int64((try? info.url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? Int(info.size))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(info.url.lastPathComponent).font(.headline).lineLimit(1)
                Spacer()
                Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([info.url]) }
            }
            row("Durata", time(info.duration))
            row("Spazio occupato", "\(formatBytes(onDisk)) (\(formatBytes(info.size)) di dati)")
            row("Contenitore", info.container)
            row("Bitrate totale", mbps(info.bitrate))
            if let v = info.video {
                Divider()
                row("Codec video", v.codec + (v.profile.isEmpty ? "" : " · \(v.profile)"))
                row("Risoluzione", "\(v.displayWidth)×\(v.displayHeight)" + (v.rotation != 0 ? " (ruotato di \(v.rotation)°)" : ""))
                row("Aspect ratio", Doctor.simplifiedRatio(width: v.displayWidth, height: v.displayHeight))
                row("Fps reali", String(format: "%g", v.fps) + (v.isVFR ? " · variabile (stima)" : " · fissi"))
                row("Bitrate video", mbps(v.bitrate))
                row("Colore", "\(v.bitDepth) bit · \(v.chroma)" + (v.colorSpace.isEmpty ? "" : " · \(v.colorSpace)") + (v.isHDR ? " · HDR" : ""))
            }
            ForEach(Array(info.audio.enumerated()), id: \.offset) { i, a in
                if i == 0 { Divider() }
                row(info.audio.count > 1 ? "Audio \(i + 1)" : "Audio",
                    "\(a.codec) · \(a.channels) canali · \(a.sampleRate) Hz · \(mbps(a.bitrate))")
            }
            if !info.tags.isEmpty {
                Divider()
                ForEach(info.tags.sorted(by: { $0.key < $1.key }), id: \.key) { row($0.key, $0.value) }
            }
            if info.video == nil && info.audio.isEmpty { Text("Nessuna traccia video o audio trovata.").foregroundStyle(Theme.orange) }
        }
        .card()
    }
}

// MARK: - Batch renamer

struct BatchRenamePane: View {
    var initialURLs: [URL] = []
    @State private var files: [URL] = []
    @State private var prefix = ""
    @State private var template = "{name}"
    @State private var suffix = ""
    @State private var find = ""
    @State private var replace = ""
    @State private var startAt = 1
    @State private var confirm = false
    @State private var message: String?

    private var plan: [MoveStep] {
        Doctor.renamePlan(files, template: prefix + template + suffix, find: find, replace: replace, startAt: startAt)
    }

    var body: some View {
        let steps = plan
        let ok = steps.filter { $0.conflict == nil }
        VStack(alignment: .leading, spacing: 12) {
            DropBox(title: "Trascina qui i file o una cartella da rinominare", button: "Scegli file…",
                    onURLs: { files = expandFiles($0); message = nil },
                    onPick: { files = expandFiles(chooseItems(folders: false, message: "Quali file rinomino?")); message = nil }, preload: initialURLs)
            if !files.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Prima del nome", text: $prefix).textFieldStyle(.roundedBorder)
                        TextField("Modello", text: $template).textFieldStyle(.roundedBorder).frame(minWidth: 220)
                        TextField("Dopo il nome", text: $suffix).textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Text("Inserisci:").foregroundStyle(.secondary)
                        ForEach(["{name}", "{n:3}", "{date}", "{date:yyyyMMdd}"], id: \.self) { t in
                            Button(t) { template += t }.buttonStyle(.bordered).controlSize(.small)
                        }
                        Stepper("Parti da \(startAt)", value: $startAt, in: 0...9999).fixedSize()
                    }
                    HStack {
                        TextField("Cerca", text: $find).textFieldStyle(.roundedBorder)
                        TextField("Sostituisci con", text: $replace).textFieldStyle(.roundedBorder)
                    }
                    Text("{name} = nome attuale · {n:3} = numero progressivo di 3 cifre (001, 002…) · {date} = data del file. L'estensione resta uguale.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .card()
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(steps.prefix(200)) { s in
                        HStack {
                            Text(s.from.lastPathComponent).lineLimit(1).foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").font(.caption)
                            Text(s.to.lastPathComponent).lineLimit(1)
                            Spacer()
                            if let c = s.conflict { Text(c).font(.caption).foregroundStyle(Theme.orange) }
                        }
                    }
                    if steps.count > 200 { Text("…e altri \(steps.count - 200) file (vengono rinominati tutti).").foregroundStyle(.secondary) }
                }
                .card()
                Button("Rinomina \(ok.count) file") { confirm = true }
                    .buttonStyle(.borderedProminent).disabled(ok.isEmpty)
            }
            if Doctor.lastMoveLabel() != nil {
                Button("Annulla l'ultima rinomina") {
                    let r = Doctor.undoLastMoves()
                    message = "Ripristinati \(r.restored) file." + (r.failures.isEmpty ? "" : " Non riuscito: \(r.failures.joined(separator: "; "))")
                    files = []
                }
            }
            if let message { Text(message).foregroundStyle(Theme.green) }
        }
        .confirmationDialog("Rinomino \(ok.count) file?", isPresented: $confirm) {
            Button("Rinomina") {
                let r = Doctor.applyMoves(ok, label: "Rinomina \(ok.count) file")
                message = "Rinominati \(r.done) file. Puoi annullare con «Annulla l'ultima rinomina»." + (r.failures.isEmpty ? "" : " Non riusciti: \(r.failures.joined(separator: "; "))")
                files = []
            }
        } message: {
            Text("I file restano nella stessa cartella con il nuovo nome. Puoi annullare subito dopo.")
        }
    }
}

// MARK: - Aspect ratio

struct RatioPane: View {
    @State private var w = 1920
    @State private var h = 1080
    @State private var target = "9:16"
    @State private var customW = 16.0
    @State private var customH = 9.0

    private var ratio: Double {
        target == "Altro" ? customW / max(customH, 0.1) : Doctor.ratioPresets.first { $0.name == target }?.value ?? 1
    }
    private func line(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary).frame(width: 190, alignment: .leading); Text(v).textSelection(.enabled); Spacer() }
    }

    var body: some View {
        let r = Doctor.reframe(width: w, height: h, to: ratio)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Il tuo video è").foregroundStyle(.secondary)
                TextField("", value: $w, format: .number.grouping(.never)).frame(width: 70).textFieldStyle(.roundedBorder)
                Text("×")
                TextField("", value: $h, format: .number.grouping(.never)).frame(width: 70).textFieldStyle(.roundedBorder)
                Text("(\(Doctor.simplifiedRatio(width: w, height: h)))").foregroundStyle(.secondary)
            }
            HStack {
                Text("Voglio").foregroundStyle(.secondary)
                Picker("", selection: $target) {
                    ForEach(Doctor.ratioPresets) { Text($0.name).tag($0.name) }
                    Text("Altro").tag("Altro")
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 380)
                if target == "Altro" {
                    TextField("", value: $customW, format: .number).frame(width: 50).textFieldStyle(.roundedBorder)
                    Text(":")
                    TextField("", value: $customH, format: .number).frame(width: 50).textFieldStyle(.roundedBorder)
                }
            }
            if let r {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Riempi il quadro (taglia i bordi)").font(.headline)
                    line("Misura", "\(r.fillWidth)×\(r.fillHeight)")
                    line("Si taglia", r.cutShare < 0.0005 ? "niente: stessa forma" : String(format: "%.0f%% dell'immagine", r.cutShare * 100))
                    line("Ritaglio da", "\(r.cropX) px da sinistra, \(r.cropY) px dall'alto")
                    Text("Tutta l'immagine, con barre").font(.headline).padding(.top, 6)
                    line("Tela", "\(r.fitWidth)×\(r.fitHeight)")
                    Text("Nessuna delle due deforma l'immagine: o la tagli, o aggiungi barre.").font(.caption).foregroundStyle(.secondary)
                }
                .card()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Misure di uscita con questa proporzione").font(.headline)
                ForEach([1080, 1920, 3840], id: \.self) { width in
                    if let s = Doctor.size(ratio: ratio, width: width) { line("Larghezza \(width)", "\(s.width)×\(s.height)") }
                }
                ForEach([720, 1080, 2160], id: \.self) { height in
                    if let s = Doctor.size(ratio: ratio, height: height) { line("Altezza \(height)", "\(s.width)×\(s.height)") }
                }
            }
            .card()
        }
    }
}
