import AppKit
import FCPCore
import SwiftUI
import UniformTypeIdentifiers

/// «Descrivi le clip»: the AI search model (CLIP, local) writes a short Italian description of what each clip shows.
struct DescribePane: View {
    struct Row: Identifiable {
        let url: URL
        var text: String?   // nil = still working
        var id: String { url.path }
    }

    @EnvironmentObject var model: Model
    @State private var rows: [Row] = []
    @State private var busy = false
    @State private var problem: String?
    @State private var installed = Doctor.clipInstalled

    private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "mxf", "avi", "mkv", "mts", "m2ts", "webm"]
    private static let empty = "(niente di riconoscibile con sicurezza)"

    private var csv: String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return (["nome;descrizione"] + rows.map { "\(q($0.url.lastPathComponent));\(q($0.text ?? ""))" }).joined(separator: "\n") + "\n"
    }
    private var plain: String { rows.map { "\($0.url.lastPathComponent): \($0.text ?? "")" }.joined(separator: "\n") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !installed {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Il componente di ricerca con intelligenza artificiale non è installato.")).font(.headline).foregroundStyle(Theme.orange)
                    Text(L("Per descrivere le clip serve lo stesso componente di «Cerca nei filmati»: installalo da lì (si scarica una volta sola, poi tutto funziona su questo Mac, senza internet)."))
                    Button(L("Apri «Cerca nei filmati»")) { model.open("search") }
                    Button(L("Ricontrolla")) { installed = Doctor.clipInstalled }
                }
            } else {
                DropBox(title: L("Trascina qui clip o una cartella: scrivo che cosa si vede in ognuna"), button: L("Scegli clip o cartella…"),
                        onURLs: add, onPick: { add(chooseItems(folders: false, message: L("Quali clip descrivo?"))) })
                Text(L("Le descrizioni sono generate dall'IA locale in base ad alcuni fotogrammi: sono un aiuto per orientarsi, non una trascrizione. Le tue clip non vengono toccate."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if busy { HStack { ProgressView().controlSize(.small); Text(L("Guardo le clip… la prima volta può servire qualche secondo a clip.")) } }
            if let problem { Text(L(problem)).foregroundStyle(Theme.orange) }
            if !rows.isEmpty {
                HStack {
                    Button(L("Copia tutto")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(plain, forType: .string) }
                    Button(L("Salva .csv…")) { save("descrizioni-clip.csv") { try csv.write(to: $0, atomically: true, encoding: .utf8) } }
                    Button(L("Svuota")) { rows = []; problem = nil }
                }.disabled(busy)
                ForEach(rows) { r in
                    HStack(alignment: .top, spacing: 12) {
                        Thumb(url: r.url, width: 240).frame(width: 150)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L(r.url.lastPathComponent)).font(.headline).lineLimit(1)
                            if let t = r.text { Text(t.isEmpty ? Self.empty : t).textSelection(.enabled) }
                            else { ProgressView().controlSize(.small) }
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private func videos(in urls: [URL]) -> [URL] {
        urls.flatMap { u -> [URL] in
            guard u.hasDirectoryPath else { return [u] }
            let it = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            return (it?.allObjects as? [URL] ?? []).filter { !$0.path.contains("/Render Files/") && !$0.path.contains("/Proxy Media/") }
        }
        .filter { Self.videoExtensions.contains($0.pathExtension.lowercased()) }
        .sorted { $0.path < $1.path }
    }

    private func add(_ urls: [URL]) {
        let found = videos(in: urls).filter { v in !rows.contains { $0.url == v } }
        guard !found.isEmpty, !busy else { if found.isEmpty && !urls.isEmpty { problem = "Non ho trovato video." }; return }
        problem = nil
        busy = true
        rows += found.map { Row(url: $0, text: nil) }
        Task.detached {
            let r = Doctor.clipDescribe(found)
            await MainActor.run {
                for i in rows.indices where rows[i].text == nil && found.contains(rows[i].url) {
                    rows[i].text = r.descriptions[rows[i].url] ?? (r.problem == nil ? L("Clip non leggibile.") : "—")
                }
                problem = r.problem
                busy = false
            }
        }
    }

    private func save(_ name: String, write: (URL) throws -> Void) {
        let p = NSSavePanel()
        p.nameFieldStringValue = name
        p.allowedContentTypes = [.commaSeparatedText]
        if p.runModal() == .OK, let u = p.url {
            do { try write(u) } catch { problem = "Non riesco a salvare il file." }
        }
    }
}
