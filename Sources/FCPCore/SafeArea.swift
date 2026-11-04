import Foundation

/// Where social apps cover the picture with their own buttons and captions, measured on a 1080×1920 frame.
public struct SafePlatform: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public var top: Double, bottom: Double, left: Double, right: Double
}

extension Doctor {
    /// When these margins were last checked by hand. The apps change their layout often and this app
    /// cannot look it up (it works offline), so treat them as a guide and adjust them.
    public static let safeAreaCheckedOn = "novembre 2026"

    /// Indicative margins in pixels on a 1080×1920 frame (values commonly given in the platforms' creator guides).
    public static let safePlatforms: [SafePlatform] = [
        SafePlatform(name: "Instagram Reel", top: 270, bottom: 670, left: 65, right: 65),
        SafePlatform(name: "Instagram Storia", top: 250, bottom: 250, left: 65, right: 65),
        SafePlatform(name: "TikTok", top: 130, bottom: 480, left: 60, right: 120),
        SafePlatform(name: "YouTube Short", top: 200, bottom: 500, left: 60, right: 120),
    ]

    /// The safe rectangle for a frame of any size (margins scale with the frame).
    public static func safeRect(_ p: SafePlatform, width: Double, height: Double) -> (x: Double, y: Double, w: Double, h: Double) {
        let sx = width / 1080, sy = height / 1920
        let x = p.left * sx, y = p.top * sy
        return (x, y, max(0, width - x - p.right * sx), max(0, height - y - p.bottom * sy))
    }
}
