import FCPCore
import SwiftUI

/// Text in the language the user picked (Italian is the source text in the code).
func L(_ italian: String) -> String { Lang.tr(italian) }

/// Flag button in the toolbar: shows the language you can switch TO.
struct LangSwitch: View {
    var body: some View {
        let to = Lang.current.other
        Button { Lang.current = to } label: {
            Text(to.flag).font(.system(size: 20))
        }
        .help(to == .en ? "Switch to English (only part of the app is translated so far)" : "Passa all'italiano")
        .accessibilityLabel(to == .en ? "Switch language to English" : "Cambia lingua in italiano")
    }
}

/// Shown in English on pages that are not translated yet, so nobody wonders why the text is Italian.
struct UntranslatedBanner: View {
    var body: some View {
        Label("This page is still in Italian.", systemImage: "globe")
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 6)
            .background(Theme.panel)
    }
}
