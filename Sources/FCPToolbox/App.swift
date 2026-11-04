import FCPCore
import SwiftUI

@main
struct FCPToolboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = Model.shared

    var body: some Scene {
        Window("FCP Toolbox", id: "main") {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .tint(Theme.blue)
                // links (fcptoolbox://…) and files opened with the app go to the open window, not to a new one
                .onOpenURL { url in
                    NSApp.activate(ignoringOtherApps: true)
                    model.handleExternal([url])
                }
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Aggiungi disco o cartella…") { model.picking = true }
                    .keyboardShortcut("o")
                Button("Aggiorna analisi") { model.rescan() }
                    .keyboardShortcut("r")
                    .disabled(model.roots.isEmpty || model.busy)
            }
            CommandGroup(after: .appInfo) {
                Button("Controlla aggiornamenti…") { Task { await Updater.check() } }
            }
            CommandGroup(after: .textEditing) {
                // works while the app is frontmost; a system-wide hotkey would need extra permissions
                Button("Cerca uno strumento…") { model.showSearch = true }
                    .keyboardShortcut("k")
            }
        }
    }
}

/// Manual update check: asks GitHub for the latest release and, if newer, opens its download page.
/// Nothing is installed by itself and nothing is sent except the request for the public release.
@MainActor
enum Updater {
    static func check() async {
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let alert = NSAlert()
        var open: URL?
        do {
            var req = URLRequest(url: UpdateCheck.latestURL, timeoutInterval: 15)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: req)
            if let r = UpdateCheck.parse(data), UpdateCheck.isNewer(r.version, than: current) {
                alert.messageText = "C'è una versione nuova: \(r.version)"
                alert.informativeText = "Hai la \(current). Scarica il nuovo file .dmg e trascina l'app in Applicazioni al posto della vecchia. Se hai installato con Homebrew: brew upgrade --cask fcp-toolbox."
                alert.addButton(withTitle: "Apri la pagina di download"); alert.addButton(withTitle: "Più tardi")
                open = r.page
            } else {
                alert.messageText = "Hai già l'ultima versione (\(current))"
                alert.addButton(withTitle: "OK")
            }
        } catch {
            alert.messageText = "Non riesco a controllare gli aggiornamenti"
            alert.informativeText = "Serve internet. Riprova più tardi."
            alert.addButton(withTitle: "OK")
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, let open { NSWorkspace.shared.open(open) }
    }
}
