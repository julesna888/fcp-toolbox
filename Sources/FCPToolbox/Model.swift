import AppKit
import FCPCore
import SwiftUI

@MainActor
final class Model: ObservableObject {
    /// One instance shared by the window and the menu bar popover.
    static let shared = Model()

    @Published var roots: [URL] = []
    /// A screen asks to open another tool (for example from a health problem to the tool that fixes it).
    @Published var requestedTool: Tool?
    /// "Open tool X with these files": from Trascina qui, the search palette, a Finder quick action or a `fcptoolbox://` link.
    @Published var openRequest: OpenRequest?
    @Published var showSearch = false

    func open(_ toolID: String, urls: [URL] = []) { openRequest = OpenRequest(toolID: toolID, urls: urls) }

    /// Files or `fcptoolbox://` links handed to the app by macOS.
    func handleExternal(_ urls: [URL]) {
        var files: [URL] = []
        for u in urls {
            if u.isFileURL { files.append(u) }
            else if let link = DeepLink.parse(u) { open(link.toolID, urls: link.files) }
            else if u.scheme == DeepLink.scheme { notice = LF("Link di FCP Toolbox non valido: %@", u.absoluteString) }
        }
        if !files.isEmpty { open(DeepLink.dropID, urls: files) }
    }
    @Published var libraries: [Library] = []
    @Published var report: MediaReport?
    @Published var tree: [Node] = []
    @Published var busy = false
    @Published var status = ""
    @Published var picking = false
    @Published var includeAnalysis = false
    @Published var notice: String?

    @Published var volumes: [Volume] = []
    @Published var bigFiles: [BigFile] = []
    @Published var scanningBig = false
    /// Warn when a disk has less free space than this (in GB).
    @Published var lowSpaceGB: Int = {
        let v = UserDefaults.standard.integer(forKey: "lowSpaceGB")
        return v > 0 ? v : 50
    }() { didSet { UserDefaults.standard.set(lowSpaceGB, forKey: "lowSpaceGB") } }

    var lowVolumes: [Volume] { volumes.filter { $0.free < Int64(lowSpaceGB) * 1_000_000_000 } }

    func refreshVolumes() {
        Task {
            volumes = await Task.detached(priority: .utility) { Doctor.volumes() }.value
        }
    }

    func findBigFiles(in places: [URL]) {
        guard !scanningBig, !places.isEmpty else { return }
        scanningBig = true
        Task {
            bigFiles = await Task.detached(priority: .userInitiated) { Doctor.largestFiles(in: places) }.value
            scanningBig = false
        }
    }

    init() {
        refreshVolumes()
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshVolumes() }
            }
        }
        let given = CommandLine.arguments.dropFirst().filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !given.isEmpty { Task { @MainActor in self.add(given) } }
    }

    var cleanable: [Item] {
        libraries.flatMap(\.items).filter { $0.canClean(includeAnalysis: includeAnalysis) }
    }
    var freeable: Int64 { cleanable.reduce(0) { $0 + $1.size } }
    var realLibraries: [Library] { libraries.filter { !$0.isBackup } }
    var backups: [Library] { libraries.filter(\.isBackup) }

    private var finalCutIsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.FinalCut" }
    }

    func add(_ urls: [URL]) {
        for u in urls where !roots.contains(u) { roots.append(u) }
        rescan()
    }

    func remove(_ url: URL) {
        roots.removeAll { $0 == url }
        rescan()
    }

    func rescan() {
        let roots = roots
        guard !busy else { return }
        guard !roots.isEmpty else {
            libraries = []
            report = nil
            tree = []
            return
        }
        busy = true
        Task {
            status = L("Cerco le librerie Final Cut…")
            let libs = await Task.detached(priority: .userInitiated) {
                Doctor.findBundles(in: roots).map(Doctor.scan)
            }.value
            libraries = libs
            Task.detached(priority: .utility) { Doctor.recordSnapshots(libs) }
            status = L("Confronto i media con le librerie…")
            let (rep, nodes) = await Task.detached(priority: .userInitiated) {
                (Doctor.mediaReport(roots: roots, libraries: libs), Doctor.tree(of: libs))
            }.value
            report = rep
            tree = nodes
            status = ""
            busy = false
            if libs.isEmpty && rep.imports.isEmpty {
                notice = "Non ho trovato né librerie né media di Final Cut in questa posizione."
            }
        }
    }

    func clean() {
        guard !finalCutIsRunning else {
            notice = "Final Cut Pro è aperto. Chiudilo e riprova."
            return
        }
        let items = cleanable
        busy = true
        status = L("Svuoto le cartelle…")
        Task {
            let (r, rec) = await Task.detached(priority: .userInitiated) { () -> (CleanResult, OperationRecord) in
                let before = Doctor.probe(items.map(\.url))
                let r = Doctor.clean(items)
                let rec = Doctor.logOperation(kind: "clean", summary: "Svuotate \(items.count) cartelle",
                                              paths: items.map(\.url), estimated: r.freed,
                                              failures: r.failures, before: before)
                return (r, rec)
            }.value
            var msg = LF("Liberati circa %@ (stima). %@", formatBytes(r.freed), rec.verification)
            if !r.failures.isEmpty { msg += "\n\n" + L("Problemi:") + "\n" + r.failures.joined(separator: "\n") }
            notice = msg
            busy = false
            rescan()
        }
    }

    /// Moves what the user picked to the Trash. Limits: inside the added folders, Final Cut closed.
    func trashItems(_ urls: [URL]) {
        guard !finalCutIsRunning else {
            notice = "Final Cut Pro è aperto. Chiudilo e riprova: scrivere in una libreria aperta la rovina."
            return
        }
        let roots = roots
        busy = true
        status = L("Sposto nel Cestino…")
        Task {
            let r = await Task.detached(priority: .userInitiated) { () -> TrashResult in
                let before = Doctor.probe(urls)
                let r = Doctor.trash(urls, within: roots)
                Doctor.logOperation(kind: "trash", summary: "Spostati nel Cestino \(r.moved) elementi",
                                    paths: urls, estimated: r.bytes, failures: r.failures, before: before)
                return r
            }.value
            var msg = LF("Spostati nel Cestino %@ elementi (%@). Svuota il Cestino per liberare lo spazio.", r.moved, formatBytes(r.bytes))
            if !r.failures.isEmpty { msg += "\n\n" + L("Problemi:") + "\n" + r.failures.joined(separator: "\n") }
            notice = msg
            busy = false
            rescan()
        }
    }

    func trashOrphans(_ files: [MediaFile]) {
        guard !finalCutIsRunning else {
            notice = "Final Cut Pro è aperto. Chiudilo e riprova."
            return
        }
        guard let folders = report?.mediaFolders else { return }
        let libs = libraries
        busy = true
        status = L("Sposto i file nel Cestino…")
        Task {
            let r = await Task.detached(priority: .userInitiated) { () -> TrashResult in
                let before = Doctor.probe(files.map(\.url))
                let r = Doctor.trashOrphans(files, mediaFolders: folders, libraries: libs)
                Doctor.logOperation(kind: "trashOrphans", summary: "Spostati nel Cestino \(r.moved) file orfani",
                                    paths: files.map(\.url), estimated: r.bytes, failures: r.failures, before: before)
                return r
            }.value
            var msg = LF("Spostati nel Cestino %@ file (%@). Svuota il Cestino per liberare lo spazio.", r.moved, formatBytes(r.bytes))
            if !r.failures.isEmpty { msg += "\n\n" + L("Problemi:") + "\n" + r.failures.joined(separator: "\n") }
            notice = msg
            busy = false
            rescan()
        }
    }
}
