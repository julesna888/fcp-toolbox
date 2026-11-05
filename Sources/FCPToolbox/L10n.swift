import FCPCore
import SwiftUI

/// Text in the language the user picked (Italian is the source text in the code).
func L(_ italian: String) -> String { Lang.tr(italian) }

/// Same, for text with numbers or names inside: write "%@" where they go and pass them in order.
func LF(_ italian: String, _ args: Any...) -> String { Translations.format(italian, args) }

/// Flag button in the toolbar: shows the language you can switch TO.
struct LangSwitch: View {
    // watching the stored value makes the flag redraw by itself when it changes
    @AppStorage(Lang.key) private var raw = ""
    var body: some View {
        let to = (Lang(rawValue: raw) ?? Lang.current).other
        Button { raw = to.rawValue } label: {
            Text(to.flag).font(.system(size: 20))
        }
        .help(to == .en ? "Switch to English" : "Passa all'italiano")
        .accessibilityLabel(to == .en ? "Switch language to English" : "Cambia lingua in italiano")
    }
}

