import SwiftUI

/// Look of the app: charcoal surfaces like a grading or editing suite, with the icon's
/// blue → violet → orange kept for accents only.
enum Theme {
    static let bg = Color(red: 0.055, green: 0.059, blue: 0.078)
    static let panel = Color(red: 0.090, green: 0.098, blue: 0.129)
    static let panelHigh = Color(red: 0.125, green: 0.137, blue: 0.176)
    static let stroke = Color.white.opacity(0.08)

    static let blue = Color(red: 0.30, green: 0.49, blue: 1.0)
    static let violet = Color(red: 0.61, green: 0.36, blue: 1.0)
    static let orange = Color(red: 1.0, green: 0.54, blue: 0.24)
    static let red = Color(red: 1.0, green: 0.36, blue: 0.36)
    static let green = Color(red: 0.25, green: 0.84, blue: 0.55)

    static let gradient = LinearGradient(colors: [blue, violet, orange], startPoint: .leading, endPoint: .trailing)
}

extension View {
    /// A raised panel with a hairline border.
    func card(padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
    }
}

/// A big number with a label, for the top of a tool.
struct Tile: View {
    let value: String
    let label: String
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.white))
            Text(label.uppercased())
                .font(.system(size: 10, weight: .medium)).tracking(0.8)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct SidebarRow: View {
    let tool: Tool
    let badge: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: tool.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(tool.tint.gradient, in: RoundedRectangle(cornerRadius: 6))
            Text(L(tool.rawValue))
            Spacer()
            if badge > 0 {
                Text("\(badge)")
                    .font(.caption2.bold().monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Theme.orange, in: Capsule())
                    .foregroundStyle(.black)
            }
        }
    }
}

struct SidebarHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 0) {
                Text("FCP Toolbox").font(.headline)
                Text("per Final Cut Pro").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}
