import AppKit
import FCPCore
import SwiftUI

struct DisksView: View {
    @EnvironmentObject var model: Model
    @State private var sort = [KeyPathComparator(\BigFile.size, order: .reverse)]
    @State private var selection = Set<BigFile.ID>()
    @State private var pendingTrash: [URL] = []
    @State private var showFormat = CommandLine.arguments.contains("--format")
    @State private var speeds: [URL: SpeedResult] = [:]
    @State private var benchmarking: URL?
    @State private var benchError: [URL: String] = [:]

    private func measure(_ v: Volume) {
        benchmarking = v.url
        benchError[v.url] = nil
        let url = v.url
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<SpeedResult, Error> in
                Result { try Doctor.benchmark(volume: url) }
            }.value
            switch result {
            case .success(let s): speeds[url] = s
            case .failure(let e): benchError[url] = e.localizedDescription
            }
            benchmarking = nil
        }
    }

    /// Where to look for big files: the folders the user added, else every external disk.
    private var places: [URL] {
        model.roots.isEmpty ? model.volumes.filter { !$0.internalDisk }.map(\.url) : model.roots
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !model.lowVolumes.isEmpty { warning }
                ForEach(model.volumes) { volumeCard($0) }
                HStack {
                    thresholdRow
                    Spacer()
                    Button("Formatta un nuovo disco…") { showFormat = true }
                }
                bigFilesSection
            }
            .padding(16)
        }
        .navigationTitle("Dischi")
        .onAppear { model.refreshVolumes() }
        .sheet(isPresented: $showFormat) { FormatDiskSheet() }
        .trashConfirmation($pendingTrash, warning: "I file vanno nel Cestino: se li usa una libreria, le sue clip diventano mancanti.")
    }

    private var warning: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Poco spazio libero su \(model.lowVolumes.map(\.name).joined(separator: ", ")). Meno di \(model.lowSpaceGB) GB: non iniziare un montaggio pesante.")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private func volumeCard(_ v: Volume) -> some View {
        let low = v.free < Int64(model.lowSpaceGB) * 1_000_000_000
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: v.internalDisk ? "internaldrive" : "externaldrive")
                Text(v.name).font(.headline)
                Spacer()
                Text("\(formatBytes(v.free)) liberi su \(formatBytes(v.total))")
                    .foregroundStyle(low ? Color.orange : Color.secondary).monospacedDigit()
            }
            ProgressView(value: Double(v.used), total: Double(v.total))
                .tint(low ? .orange : .accentColor)
            HStack(spacing: 14) {
                Text(v.format)
                Text(v.internalDisk ? "Interno" : "Esterno")
                if let s = v.smart {
                    Text("SMART: \(s)").foregroundStyle(s == "Verified" ? Color.green : Color.red)
                } else {
                    Text("SMART non disponibile")
                }
                Spacer()
                if benchmarking == v.url { ProgressView().controlSize(.small) }
                Button(speeds[v.url] == nil ? "Misura velocità" : "Misura di nuovo") { measure(v) }
                    .buttonStyle(.link).disabled(benchmarking != nil)
                    .help("Scrive e rilegge un file temporaneo da 512 MB, poi lo elimina")
                Button("Mostra nel Finder") { reveal([v.url]) }.buttonStyle(.link)
            }
            .font(.callout).foregroundStyle(.secondary)
            if let e = benchError[v.url] { Text(e).font(.callout).foregroundStyle(Theme.orange) }
            fitness(v)
        }
        .card()
    }

    private func fitness(_ v: Volume) -> some View {
        let s = Doctor.suitability(of: v, speed: speeds[v.url], lowSpaceGB: model.lowSpaceGB)
        let (title, color, icon): (String, Color, String) = switch s.fitness {
        case .good: (speeds[v.url] == nil ? "Formato adatto, velocità da misurare" : "Adatto al video",
                     Theme.green, "checkmark.circle.fill")
        case .limited: ("Adatto con limiti", Theme.orange, "exclamationmark.triangle.fill")
        case .unfit: ("Non adatto al video", .red, "xmark.octagon.fill")
        }
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(s.reasons, id: \.self) { Text("• " + $0).font(.callout).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(title, systemImage: icon).foregroundStyle(color)
        }
    }

    private var thresholdRow: some View {
        Stepper(value: $model.lowSpaceGB, in: 5...2000, step: 5) {
            Text("Avvisami sotto i \(model.lowSpaceGB) GB liberi")
        }
        .frame(maxWidth: 360, alignment: .leading)
    }

    private var bigFilesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("File più grandi").font(.title3.bold())
                Spacer()
                if model.scanningBig { ProgressView().controlSize(.small) }
                Button(model.bigFiles.isEmpty ? "Cerca" : "Cerca di nuovo") { model.findBigFiles(in: places) }
                    .disabled(model.scanningBig || places.isEmpty)
            }
            Text(model.roots.isEmpty
                 ? "Cerco nei dischi esterni (file oltre 50 MB). Aggiungi una cartella con + per cercare solo lì."
                 : "Cerco nelle posizioni aggiunte (file oltre 50 MB).")
                .foregroundStyle(.secondary)
            if !model.bigFiles.isEmpty {
                Table(model.bigFiles.sorted(using: sort), selection: $selection, sortOrder: $sort) {
                    TableColumn("File", value: \.url.lastPathComponent) { Text($0.url.lastPathComponent) }
                        .width(min: 200, ideal: 280)
                    TableColumn("Peso", value: \.size) { Text(formatBytes($0.size)).monospacedDigit() }.width(90)
                    TableColumn("Modificato", value: \.modified) {
                        Text($0.modified.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                    }.width(min: 100, ideal: 120)
                    TableColumn("Cartella", value: \.url.path) {
                        Text($0.url.deletingLastPathComponent().path).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(minHeight: 280)
                .contextMenu(forSelectionType: BigFile.ID.self) { ids in
                    Button("Mostra nel Finder") { reveal(Array(ids)) }
                    Divider()
                    Button("Sposta nel Cestino…", role: .destructive) { pendingTrash = Array(ids) }
                }
                .spacePreview(model.bigFiles.filter { selection.contains($0.id) }.map(\.url))
            }
        }
    }
}
