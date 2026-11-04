import Foundation

/// "Is there a newer version?" Asks GitHub's public release list; only runs when the user asks.
public enum UpdateCheck {
    public static let latestURL = URL(string: "https://api.github.com/repos/julesna888/fcp-toolbox/releases/latest")!

    public struct Release: Equatable {
        public let version: String   // "0.13.5", without the leading "v"
        public let page: URL         // where to download it
    }

    /// Reads GitHub's "latest release" answer. Nil if it is not a release we can use.
    public static func parse(_ data: Data) -> Release? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = o["tag_name"] as? String, let page = (o["html_url"] as? String).flatMap(URL.init(string:)),
              page.scheme == "https", page.host == "github.com" else { return nil }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, page: page)
    }

    /// Compares dotted numbers ("0.13.10" is newer than "0.13.9").
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        let a = latest.split(separator: ".").map { Int($0) ?? 0 }, b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
