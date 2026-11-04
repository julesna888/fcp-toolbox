import Foundation

/// `fcptoolbox://tool/<id>?file=/percent/encoded/path&file=...` — what the Finder quick actions
/// send to the app. `tool/drop` means "show the suggestions for these files".
public struct DeepLink: Equatable, Sendable {
    public static let scheme = "fcptoolbox"
    public static let dropID = "drop"
    public let toolID: String
    public let files: [URL]

    /// Only absolute paths are accepted; unknown tool ids are rejected.
    public static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "tool" else { return nil }
        let id = url.path.split(separator: "/").first.map(String.init) ?? ""
        guard id == dropID || ToolCatalog.entry(id) != nil else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let files = items.filter { $0.name == "file" }.compactMap { $0.value }
            .filter { $0.hasPrefix("/") && !$0.contains("\0") }
            .map { URL(fileURLWithPath: $0) }
        return DeepLink(toolID: id, files: files)
    }

    public static func make(toolID: String, files: [URL]) -> URL? {
        var c = URLComponents()
        c.scheme = scheme; c.host = "tool"; c.path = "/" + toolID
        c.queryItems = files.map { URLQueryItem(name: "file", value: $0.path) }
        return c.url
    }
}
