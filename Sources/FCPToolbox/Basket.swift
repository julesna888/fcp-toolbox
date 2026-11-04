import AppKit
import FCPCore
import SwiftUI

/// A shelf of files kept within reach. It only remembers where they are: nothing is copied or moved.
@MainActor
final class Basket: ObservableObject {
    static let shared = Basket()
    @Published private(set) var items: [URL] = []
    private let key = "basketPaths"

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        items = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ urls: [URL]) {
        for u in urls where !items.contains(u) { items.append(u) }
        save()
    }

    func remove(_ url: URL) {
        items.removeAll { $0 == url }
        save()
    }

    func clear() {
        items = []
        save()
    }

    /// Forget files that were moved or deleted since.
    func prune() {
        items = items.filter { FileManager.default.fileExists(atPath: $0.path) }
        save()
    }

    private func save() { UserDefaults.standard.set(items.map(\.path), forKey: key) }
}

struct BasketView: View {
    @ObservedObject var basket: Basket
    @ObservedObject var model: Model
    var openMain: () -> Void
    var quit: () -> Void
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "tray.full.fill").foregroundStyle(Theme.gradient)
                Text("Cesto").font(.headline)
                Text("\(basket.items.count)").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if !basket.items.isEmpty {
                    Button("Svuota") { basket.clear() }.buttonStyle(.link)
                        .help("Toglie i file dal cesto. Non li cancella.")
                }
            }
            if basket.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc").font(.title)
                    Text("Trascina qui file e cartelle").bold()
                    Text("Restano dove sono. Li ritrovi qui, pronti da trascinare fuori.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(basket.items, id: \.self) { row($0) }
                    }
                }
            }
            Divider()
            ForEach(model.volumes.prefix(3)) { v in
                HStack {
                    Image(systemName: v.internalDisk ? "internaldrive" : "externaldrive")
                    Text(v.name).lineLimit(1)
                    Spacer()
                    Text("\(formatBytes(v.free)) liberi").monospacedDigit()
                        .foregroundStyle(v.free < Int64(model.lowSpaceGB) * 1_000_000_000 ? Theme.orange : Color.secondary)
                }
                .font(.caption)
            }
            HStack {
                Button("Apri FCP Toolbox") { openMain() }
                Spacer()
                Button("Esci") { quit() }
            }
        }
        .padding(14)
        .frame(width: 340, height: 440)
        .background(Theme.bg)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.blue, lineWidth: targeted ? 2 : 0).padding(2))
        .dropDestination(for: URL.self) { urls, _ in
            basket.add(urls)
            return true
        } isTargeted: { targeted = $0 }
        .onAppear { basket.prune(); model.refreshVolumes() }
    }

    private func row(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(url.deletingLastPathComponent().lastPathComponent).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button { reveal([url]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.plain).help("Mostra nel Finder")
            Button { basket.remove(url) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Toglie dal cesto")
        }
        .padding(6)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .onDrag { NSItemProvider(object: url as NSURL) }
    }
}
