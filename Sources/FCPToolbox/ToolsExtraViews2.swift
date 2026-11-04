import AppKit
import AVKit
import FCPCore
import SwiftUI
import UniformTypeIdentifiers

private let mediaExtensions: Set<String> = ["mov", "mp4", "m4v", "mxf", "avi", "mkv", "mts", "m2ts", "webm", "jpg", "jpeg", "png", "heic", "tif", "tiff"]

private func timeText(_ s: Double) -> String { String(format: "%d:%05.2f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60)) }

/// A frame of a clip, read in the background.
struct Thumb: View {
    let url: URL
    var at: Double = 0
    var width = 320
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Rectangle().fill(Theme.panelHigh).aspectRatio(16 / 9, contentMode: .fit).overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: "\(url.path)-\(at)") {
            let data = await Task.detached { Doctor.frameImage(of: url, at: at, width: width) }.value
            image = data.flatMap { NSImage(data: $0) }
        }
    }
}

private func saveFile(_ name: String, types: [UTType], write: (URL) throws -> Void) {
    let p = NSSavePanel()
    p.nameFieldStringValue = name
    p.allowedContentTypes = types
    if p.runModal() == .OK, let u = p.url { try? write(u) }
}

// MARK: - Shot detector

struct ShotsPane: View {
    var initialURLs: [URL] = []
    @State private var url: URL?
    @State private var shots: [Double] = []
    @State private var fps = 25.0
    @State private var sensitivity = 0.3
    @State private var busy = false
    @State private var searched = false

    private var list: String {
        shots.enumerated().map { "\(Doctor.timecode($1, fps: fps))\t\(String(format: "%.2f", $1)) s\t\($0 == 0 ? "inizio" : "stacco \($0)")" }.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DropBox(title: "Trascina qui un video: trovo i cambi di inquadratura", button: "Scegli video…",
                    onURLs: { set($0.first) }, onPick: { set(chooseItems(folders: false, message: "Quale video?").first) }, preload: initialURLs)
            if let url {
                HStack {
                    Text(url.lastPathComponent).font(.headline).lineLimit(1)
                    Spacer()
                    Text("Sensibilità").foregroundStyle(.secondary)
                    Slider(value: $sensitivity, in: 0.1...0.6).frame(width: 160)
                    Button("Cerca i cambi") { run(url) }.buttonStyle(.borderedProminent).disabled(busy)
                }
                Text("Più a sinistra trova più stacchi (anche movimenti veloci); più a destra solo i tagli netti. Sui video lunghi può servire un po' di tempo.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if busy { HStack { ProgressView().controlSize(.small); Text("Sto guardando il video…") } }
            if searched && !busy {
                HStack {
                    Text("\(shots.count) inquadrature").font(.headline)
                    Spacer()
                    Button("Copia la lista") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(list, forType: .string) }
                    Button("Salva .txt…") { saveFile("cambi-inquadratura.txt", types: [.plainText]) { try list.write(to: $0, atomically: true, encoding: .utf8) } }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(Array(shots.enumerated()), id: \.offset) { i, t in
                        VStack(alignment: .leading, spacing: 3) {
                            if let url { Thumb(url: url, at: t + 0.1, width: 240) }
                            Text(Doctor.timecode(t, fps: fps)).font(.system(.caption, design: .monospaced))
                            Text(i == 0 ? "inizio" : "stacco \(i)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .card()
            }
        }
    }

    private func set(_ u: URL?) { url = u; shots = []; searched = false; if let u { run(u) } }

    private func run(_ u: URL) {
        busy = true
        let s = sensitivity
        Task {
            let r = await Task.detached { () -> (Double, [Double]) in
                let f = (try? Doctor.probeMedia(u))?.video?.fps ?? 25
                return (f, Doctor.detectShots(u, sensitivity: s))
            }.value
            fps = r.0; shots = r.1; searched = true; busy = false
        }
    }
}

// MARK: - Contact sheet

struct ContactSheetPane: View {
    var initialURLs: [URL] = []
    struct Tile: Identifiable { let id = UUID(); let url: URL; let at: Double; let label: String }
    @State private var tiles: [Tile] = []
    @State private var title = ""
    @State private var selected: URL?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DropBox(title: "Trascina qui un video (griglia dei suoi fotogrammi) o una cartella (un fotogramma per clip)",
                    button: "Scegli cartella…",
                    onURLs: build, onPick: { build(chooseItems(folders: true, message: "Quale cartella?")) }, preload: initialURLs)
            Button("Oppure scegli un solo video…") { build(chooseItems(folders: false, message: "Quale video?")) }
            if busy { ProgressView().controlSize(.small) }
            if !tiles.isEmpty {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Text("Clicca un riquadro e premi la barra spaziatrice per l'anteprima").font(.caption).foregroundStyle(.secondary)
                    Button("Salva come immagine…") { export() }
                }
                sheet(width: nil)
            }
        }
        .spacePreview(selected.map { [$0] } ?? [])
    }

    private func sheet(width: CGFloat?) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], spacing: 8) {
            ForEach(tiles) { t in
                VStack(alignment: .leading, spacing: 2) {
                    Thumb(url: t.url, at: t.at, width: 320)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(selected == t.url ? Theme.green : .clear, lineWidth: 2))
                    Text(t.label).font(.system(.caption2, design: .monospaced)).lineLimit(1)
                }
                .onTapGesture { selected = t.url }
            }
        }
        .padding(16)
        .frame(width: width)
        .background(width == nil ? Theme.panel : Color.black)
    }

    private func build(_ urls: [URL]) {
        busy = true; tiles = []; selected = nil
        Task {
            let result = await Task.detached { () -> (String, [Tile]) in
                let files = expandFiles(urls).filter { mediaExtensions.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                if files.count == 1, let f = files.first, let info = try? Doctor.probeMedia(f), info.duration > 1 {
                    let fps = info.video?.fps ?? 25
                    let n = 20
                    return (f.lastPathComponent, (0..<n).map { i in
                        let t = info.duration * (Double(i) + 0.5) / Double(n)
                        return Tile(url: f, at: t, label: Doctor.timecode(t, fps: fps))
                    })
                }
                let many = Array(files.prefix(150))
                return ("\(many.count) clip", many.map { f in
                    let d = (try? Doctor.probeMedia(f))?.duration ?? 0
                    return Tile(url: f, at: d * 0.3, label: f.lastPathComponent)
                })
            }.value
            title = result.0; tiles = result.1; busy = false
        }
    }

    @MainActor private func export() {
        let r = ImageRenderer(content: sheet(width: 1600))
        r.scale = 1
        guard let cg = r.cgImage else { return }
        guard let data = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { return }
        saveFile("foglio-provini.jpg", types: [.jpeg]) { try data.write(to: $0) }
    }
}

// MARK: - Trim

struct TrimPane: View {
    var initialURLs: [URL] = []
    @State private var url: URL?
    @State private var player: AVPlayer?
    @State private var duration = 0.0
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var precise = false
    @State private var busy = false
    @State private var result: TrimResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DropBox(title: "Trascina qui il video da tagliare", button: "Scegli video…",
                    onURLs: { load($0.first) }, onPick: { load(chooseItems(folders: false, message: "Quale video?").first) }, preload: initialURLs)
            if let player, let url {
                PlayerBox(player: player).frame(height: 300).clipShape(RoundedRectangle(cornerRadius: 10))
                HStack {
                    Button("Inizio qui") { start = min(player.currentTime().seconds, max(0, end - 0.1)) }
                    TextField("", value: $start, format: .number.precision(.fractionLength(2))).frame(width: 70).textFieldStyle(.roundedBorder)
                    Text("→")
                    TextField("", value: $end, format: .number.precision(.fractionLength(2))).frame(width: 70).textFieldStyle(.roundedBorder)
                    Button("Fine qui") { end = max(player.currentTime().seconds, start + 0.1) }
                    Text("(\(timeText(max(0, end - start))) su \(timeText(duration)))").foregroundStyle(.secondary)
                }
                Picker("", selection: $precise) {
                    Text("Veloce: senza ricodificare, qualità identica, taglia sul punto chiave vicino").tag(false)
                    Text("Preciso: al fotogramma, ricodifica (più lento)").tag(true)
                }
                .pickerStyle(.radioGroup).labelsHidden()
                HStack {
                    Button("Taglia") { cut(url) }.buttonStyle(.borderedProminent).disabled(busy || end <= start)
                    if busy { ProgressView().controlSize(.small) }
                    if let o = result?.output {
                        Text("Fatto: \(o.lastPathComponent)").foregroundStyle(Theme.green).lineLimit(1)
                        Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([o]) }
                    }
                    if let p = result?.problem { Text(p).foregroundStyle(Theme.orange) }
                }
                Text("Il file nuovo («… taglio») è accanto all'originale, che non viene toccato.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func load(_ u: URL?) {
        guard let u else { return }
        url = u; result = nil
        player = AVPlayer(url: u)
        Task {
            let d = await Task.detached { (try? Doctor.probeMedia(u))?.duration ?? 0 }.value
            duration = d; start = 0; end = d
        }
    }

    private func cut(_ u: URL) {
        busy = true; result = nil
        let (s, e, p) = (start, end, precise)
        Task {
            result = await Task.detached { Doctor.trim(u, start: s, end: e, precise: p) }.value
            busy = false
        }
    }
}

// MARK: - Metadata cleaner

struct MetadataPane: View {
    var initialURLs: [URL] = []
    @State private var files: [URL] = []
    @State private var kinds: Set<MetadataKind> = [.location]
    @State private var summary: [String: [String]] = [:]
    @State private var results: [(String, String, Bool)] = []
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DropBox(title: "Trascina qui foto e video da ripulire", button: "Scegli file…",
                    onURLs: set, onPick: { set(chooseItems(folders: false, message: "Quali file?")) }, preload: initialURLs)
            if !files.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cosa togliere").font(.headline)
                    ForEach(MetadataKind.allCases) { k in
                        Toggle(k.rawValue, isOn: Binding(get: { kinds.contains(k) }, set: { on in
                            if on { kinds.insert(k) } else { kinds.remove(k) }
                        }))
                    }
                    Text("Si crea una copia «… pulito» accanto all'originale. Le foto vengono salvate di nuovo alla massima qualità (JPEG e HEIC si ricomprimono pochissimo); i video non vengono ricodificati.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Crea \(files.count) copie pulite") { run() }.buttonStyle(.borderedProminent).disabled(busy || kinds.isEmpty)
                }
                .card()
                ForEach(files.prefix(30), id: \.self) { f in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.lastPathComponent).font(.headline).lineLimit(1)
                        let s = summary[f.path] ?? []
                        Text(s.isEmpty ? "Nessun metadata trovato." : s.prefix(8).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(Array(results.enumerated()), id: \.offset) { _, r in
                Text(r.0 + (r.2 ? " → " : ": ") + r.1).foregroundStyle(r.2 ? Theme.green : Theme.orange)
            }
        }
    }

    private func set(_ urls: [URL]) {
        files = expandFiles(urls); results = []; summary = [:]
        let f = files
        Task {
            let s = await Task.detached { Dictionary(f.prefix(30).map { ($0.path, Doctor.metadataSummary($0)) }, uniquingKeysWith: { a, _ in a }) }.value
            summary = s
        }
    }

    private func run() {
        busy = true; results = []
        let (f, k) = (files, kinds)
        Task {
            let r = await Task.detached { f.map { u -> (String, String, Bool) in
                let c = Doctor.cleanMetadata(u, remove: k)
                return (u.lastPathComponent, c.output?.lastPathComponent ?? c.problem ?? "errore", c.output != nil)
            } }.value
            results = r; busy = false
        }
    }
}

// MARK: - Colors

struct PalettePane: View {
    var initialURLs: [URL] = []
    @State private var colors: [PaletteColor] = []
    @State private var url: URL?
    @State private var duration = 0.0
    @State private var time = 0.0
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DropBox(title: "Trascina qui una foto o un video: ne estraggo i colori", button: "Scegli file…",
                    onURLs: { load($0.first) }, onPick: { load(chooseItems(folders: false, message: "Quale file?").first) }, preload: initialURLs)
            HStack {
                Button("Prendi un colore dallo schermo") { pickFromScreen() }
                Text("Il contagocce di macOS: clicca un punto qualsiasi, anche fuori dall'app.").font(.caption).foregroundStyle(.secondary)
            }
            if let url, duration > 0, !Doctor.isPhoto(url) {
                HStack {
                    Text("Fotogramma a \(timeText(time))").foregroundStyle(.secondary)
                    Slider(value: $time, in: 0...duration) { editing in if !editing { reload() } }
                }
                Thumb(url: url, at: time, width: 480).frame(maxHeight: 220)
            }
            if !colors.isEmpty {
                HStack(spacing: 0) { ForEach(colors) { c in Rectangle().fill(swatch(c)).frame(height: 44) } }.clipShape(RoundedRectangle(cornerRadius: 8))
                ForEach(colors) { c in
                    HStack {
                        RoundedRectangle(cornerRadius: 6).fill(swatch(c)).frame(width: 40, height: 28)
                        Text(c.hex).font(.system(.body, design: .monospaced))
                        Text("rgb(\(c.r), \(c.g), \(c.b))").foregroundStyle(.secondary)
                        Spacer()
                        if c.share < 1 { Text("\(Int((c.share * 100).rounded()))%").foregroundStyle(.secondary) }
                        Button(copied == c.hex ? "Copiato" : "Copia") { copy(c.hex) }
                    }
                }
                Button("Copia tutta la palette") { copy(colors.map(\.hex).joined(separator: " ")) }
            }
        }
        .card()
    }

    private func swatch(_ c: PaletteColor) -> Color { Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255) }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string); copied = s
    }

    private func load(_ u: URL?) {
        guard let u else { return }
        url = u; time = 0; duration = 0; colors = []
        Task {
            if !Doctor.isPhoto(u) {
                duration = await Task.detached { (try? Doctor.probeMedia(u))?.duration ?? 0 }.value
                time = duration / 2
            }
            reload()
        }
    }

    private func reload() {
        guard let u = url else { return }
        let t = time
        Task { colors = await Task.detached { Doctor.palette(ofFile: u, at: t) }.value }
    }

    private func pickFromScreen() {
        NSColorSampler().show { picked in
            guard let c = picked?.usingColorSpace(.sRGB) else { return }
            let p = PaletteColor(r: Int((c.redComponent * 255).rounded()), g: Int((c.greenComponent * 255).rounded()),
                                 b: Int((c.blueComponent * 255).rounded()), share: 1)
            colors.removeAll { $0.hex == p.hex }
            colors.insert(p, at: 0)
        }
    }
}

// MARK: - Safe areas

struct SafePane: View {
    @State private var platforms = Doctor.safePlatforms
    @State private var chosen = Doctor.safePlatforms[0].name
    @State private var url: URL?

    private var index: Int { platforms.firstIndex { $0.name == chosen } ?? 0 }

    private func overlay(width: CGFloat, height: CGFloat) -> some View {
        let r = Doctor.safeRect(platforms[index], width: 1080, height: 1920)
        let sx = width / 1080, sy = height / 1920
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.red.opacity(0.35))
            Rectangle().fill(Color.black).frame(width: r.w * sx, height: r.h * sy).offset(x: r.x * sx, y: r.y * sy).blendMode(.destinationOut)
        }
        .compositingGroup()
        .frame(width: width, height: height)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Margini indicativi, controllati a \(Doctor.safeAreaCheckedOn). Le app cambiano spesso aspetto e questa app lavora offline, quindi non li aggiorna da sola: se non coincidono con quello che vedi nell'app, correggi i numeri qui sotto.")
                .font(.caption).foregroundStyle(Theme.orange)
            Picker("", selection: $chosen) { ForEach(platforms) { Text($0.name).tag($0.name) } }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 520)
            HStack(alignment: .top, spacing: 20) {
                ZStack {
                    Rectangle().fill(Color(white: 0.12))
                    if let url { Thumb(url: url, at: 1, width: 540).scaledToFill() }
                    overlay(width: 270, height: 480)
                }
                .frame(width: 270, height: 480).clipped()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Fuori dalla zona rossa il testo è al sicuro. I margini sono in pixel su 1080×1920.").foregroundStyle(.secondary)
                    Stepper("Sopra: \(Int(platforms[index].top)) px", value: $platforms[index].top, in: 0...900, step: 10)
                    Stepper("Sotto: \(Int(platforms[index].bottom)) px", value: $platforms[index].bottom, in: 0...900, step: 10)
                    Stepper("Sinistra: \(Int(platforms[index].left)) px", value: $platforms[index].left, in: 0...400, step: 5)
                    Stepper("Destra: \(Int(platforms[index].right)) px", value: $platforms[index].right, in: 0...400, step: 5)
                    HStack {
                        Button("Mostra su un mio video…") { url = chooseItems(folders: false, message: "Quale video?").first }
                        Button("Salva guida PNG…") { exportGuide() }
                    }
                    Text("La guida PNG è trasparente 1080×1920: mettila sopra la timeline in Final Cut e toglila prima di esportare.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .card()
    }

    @MainActor private func exportGuide() {
        let r = ImageRenderer(content: overlay(width: 1080, height: 1920))
        r.scale = 1
        guard let cg = r.cgImage, let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        saveFile("guida \(chosen).png", types: [.png]) { try data.write(to: $0) }
    }
}

// MARK: - Duplicates by content

struct DuplicatesPane: View {
    var initialURLs: [URL] = []
    @State private var identical: [DuplicateGroup] = []
    @State private var similar: [[URL]] = []
    @State private var busy = false
    @State private var done = false
    @State private var pending: [URL] = []
    @State private var selected: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DropBox(title: "Trascina qui una cartella: cerco i file doppi anche con nomi diversi", button: "Scegli cartella…",
                    onURLs: { run($0.first) }, onPick: { run(chooseItems(folders: true, message: "Quale cartella?").first) }, preload: initialURLs)
            if busy { HStack { ProgressView().controlSize(.small); Text("Sto confrontando i file…") } }
            if done && !busy {
                if identical.isEmpty && similar.isEmpty { Text("Nessun doppione trovato.").foregroundStyle(Theme.green) }
                if !identical.isEmpty {
                    Text("Copie identiche (stesso contenuto byte per byte)").font(.headline)
                    Text("Si possono liberare \(formatBytes(identical.reduce(0) { $0 + $1.wasted })) tenendone una per gruppo.").foregroundStyle(.secondary)
                    ForEach(identical) { group($0.files) }
                }
                if !similar.isEmpty {
                    Text("Stesso video, file diverso (stima)").font(.headline)
                    Text("Stessa durata e stesse immagini, ma ricodificati o ridimensionati. È una stima: guardali prima di cestinare (clicca e premi spazio).").foregroundStyle(.secondary)
                    ForEach(similar, id: \.self) { group($0) }
                }
            }
        }
        .spacePreview(selected.map { [$0] } ?? [])
        .trashConfirmation($pending, warning: "Va nel Cestino: puoi recuperarlo da lì.")
    }

    private func group(_ files: [URL]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(files, id: \.self) { f in
                HStack {
                    Text(f.lastPathComponent).lineLimit(1)
                    Text(f.deletingLastPathComponent().lastPathComponent).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text(formatBytes(Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))).foregroundStyle(.secondary)
                    Button("Mostra") { NSWorkspace.shared.activateFileViewerSelecting([f]) }
                    Button("Cestino") { pending = [f] }
                }
                .padding(.vertical, 2)
                .background(selected == f ? Theme.panelHigh : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { selected = f }
            }
        }
        .card()
    }

    private func run(_ u: URL?) {
        guard let u else { return }
        busy = true; done = false
        Task {
            let r = await Task.detached { () -> ([DuplicateGroup], [[URL]]) in
                let exact = Doctor.findDuplicates(in: u).identical
                let inExact = Set(exact.flatMap { $0.files })
                // a group of similar clips is only new information if not all of it is already listed as exact copies
                let sim = Doctor.similarClips(in: u).filter { g in !g.allSatisfy { inExact.contains($0) } }
                return (exact, sim)
            }.value
            identical = r.0; similar = r.1; busy = false; done = true
        }
    }
}

// MARK: - Footage search (CLIP)

struct FootageSearchPane: View {
    @State private var installed = Doctor.clipInstalled
    @State private var installing = false
    @State private var installFraction = 0.0
    @State private var installStep = ""
    @State private var problem: String?
    @State private var folder: URL? = UserDefaults.standard.string(forKey: "clipArchive").map { URL(fileURLWithPath: $0) }
    @State private var indexing = false
    @State private var done = 0
    @State private var total = 0
    @State private var indexNote: String?
    @State private var query = ""
    @State private var hits: [ClipHit] = []
    @State private var searching = false
    @State private var searched = false
    @State private var selected: URL?
    @State private var control = ProxyControl()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !installed { setup } else { archive; searchBox; results }
        }
        .spacePreview(selected.map { [$0] } ?? [])
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cerca nei tuoi filmati scrivendo cosa c'è dentro").font(.headline)
            Text("Scrivi «persona che cammina sulla spiaggia» e l'app trova le clip del tuo archivio che lo mostrano. Usa un'intelligenza artificiale gratuita che gira solo su questo Mac: nessun account, nessun costo, i tuoi video non escono dal computer.")
                .foregroundStyle(.secondary)
            Text("Serve un download una tantum di circa 800 MB (librerie e modelli, da Hugging Face) nella cartella dei dati dell'app. Se si interrompe, riparte da dove era arrivato.")
                .font(.caption).foregroundStyle(.secondary)
            if installing {
                ProgressView(value: installFraction)
                HStack { Text(installStep).foregroundStyle(.secondary); Spacer(); Button("Ferma") { control.cancel() } }
            } else {
                Button("Scarica e installa (circa 800 MB)") { install() }.buttonStyle(.borderedProminent)
            }
            if let problem { Text(problem).foregroundStyle(Theme.orange) }
        }
        .card()
    }

    private var archive: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(folder.map { "Archivio: \($0.lastPathComponent)" } ?? "Scegli la cartella dell'archivio…") {
                    if let u = chooseItems(folders: true, message: "Quale cartella contiene i tuoi filmati?").first {
                        folder = u
                        UserDefaults.standard.set(u.path, forKey: "clipArchive")
                    }
                }
                if let folder {
                    if indexing {
                        ProgressView(value: total > 0 ? Double(done) / Double(total) : 0).frame(width: 140)
                        Text("\(done)/\(total)").monospacedDigit().foregroundStyle(.secondary)
                        Button("Ferma") { control.cancel() }
                    } else {
                        Button("Analizza l'archivio") { index(folder) }.buttonStyle(.borderedProminent)
                    }
                }
            }
            Text("L'analisi guarda alcuni fotogrammi di ogni clip (circa 1–2 secondi a clip) e si fa una volta sola: le clip già analizzate e non cambiate vengono saltate. Rifalla quando aggiungi nuovi filmati.")
                .font(.caption).foregroundStyle(.secondary)
            if let indexNote { Text(indexNote).foregroundStyle(Theme.green) }
            if let problem { Text(problem).foregroundStyle(Theme.orange) }
        }
        .card()
    }

    private var searchBox: some View {
        HStack {
            TextField("Cerca o descrivi la scena: «persona che cammina sulla spiaggia»", text: $query)
                .textFieldStyle(.roundedBorder).onSubmit(search)
            Button("Cerca") { search() }.buttonStyle(.borderedProminent).disabled(searching || query.trimmingCharacters(in: .whitespaces).isEmpty)
            if searching { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder private var results: some View {
        if searched && hits.isEmpty && problem == nil && !searching { Text("Nessuna clip trovata.").foregroundStyle(.secondary) }
        if !hits.isEmpty {
            Text("Clicca una clip e premi la barra spaziatrice per l'anteprima. Le prime sono le più adatte; il nome del file conta un po'.")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
                ForEach(hits) { h in
                    VStack(alignment: .leading, spacing: 3) {
                        Thumb(url: h.url, at: h.time, width: 320)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(selected == h.url ? Theme.green : .clear, lineWidth: 2))
                        Text(h.url.lastPathComponent).font(.caption).lineLimit(1)
                        HStack {
                            ProgressView(value: min(1, max(0, (h.score - 0.18) / 0.17))).tint(h.score >= 0.27 ? Theme.green : Theme.orange)
                            Text(String(format: "%.2f", h.score)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        HStack {
                            Text(timeText(h.time)).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Button("Mostra") { NSWorkspace.shared.activateFileViewerSelecting([h.url]) }.controlSize(.small)
                        }
                    }
                    .onTapGesture { selected = h.url }
                }
            }
        }
    }

    private func install() {
        installing = true; problem = nil; control = ProxyControl()
        let c = control
        Task {
            let p = await Task.detached {
                Doctor.clipInstall(control: c) { f, s in Task { @MainActor in installFraction = f; installStep = s } }
            }.value
            installing = false; problem = p; installed = Doctor.clipInstalled
        }
    }

    private func index(_ f: URL) {
        indexing = true; problem = nil; indexNote = nil; done = 0; total = 0; control = ProxyControl()
        let c = control
        Task {
            let r = await Task.detached {
                Doctor.clipIndex(folder: f, control: c) { d, t in Task { @MainActor in done = d; total = t } }
            }.value
            indexing = false; problem = r.problem
            if r.problem == nil || r.clips > 0 { indexNote = "Archivio pronto: \(r.clips) clip analizzate." }
        }
    }

    private func search() {
        let q = query
        searching = true; problem = nil
        Task {
            let r = await Task.detached { Doctor.clipSearch(q, folder: nil) }.value
            hits = r.hits; problem = r.problem; searched = true; searching = false
        }
    }
}


/// AppKit video player. SwiftUI's `VideoPlayer` aborts at launch of the pane on this macOS (AVKit_SwiftUI cannot build its class).
struct PlayerBox: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .inline
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { if v.player !== player { v.player = player } }
}
