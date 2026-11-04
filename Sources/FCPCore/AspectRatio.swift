import Foundation

public struct RatioPreset: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let value: Double  // width / height
}

/// How a source frame becomes a frame of another ratio, without stretching it.
public struct Reframe: Equatable, Sendable {
    /// Crop to fill: the biggest area of the source with the target ratio, centered. Some of the picture is cut.
    public let fillWidth: Int, fillHeight: Int, cropX: Int, cropY: Int
    /// Share of the picture that is cut away by the crop (0...1).
    public let cutShare: Double
    /// Fit: a canvas of the target ratio that holds the whole source; the rest is bars.
    public let fitWidth: Int, fitHeight: Int
}

extension Doctor {
    public static let ratioPresets: [RatioPreset] = [
        RatioPreset(name: "16:9", value: 16.0 / 9),
        RatioPreset(name: "9:16", value: 9.0 / 16),
        RatioPreset(name: "1:1", value: 1),
        RatioPreset(name: "4:5", value: 4.0 / 5),
        RatioPreset(name: "2.39:1", value: 2.39),
    ]

    /// Video encoders want even sizes: nearest even number.
    static func even(_ x: Double) -> Int { max(2, Int((x / 2).rounded()) * 2) }

    /// Size of a frame with ratio `ratio` for a given width or height (the other one is worked out).
    public static func size(ratio: Double, width: Int? = nil, height: Int? = nil) -> (width: Int, height: Int)? {
        if let width, width > 0 { return (even(Double(width)), even(Double(width) / ratio)) }
        if let height, height > 0 { return (even(Double(height) * ratio), even(Double(height))) }
        return nil
    }

    public static func reframe(width w: Int, height h: Int, to ratio: Double) -> Reframe? {
        guard w > 0, h > 0, ratio > 0 else { return nil }
        let source = Double(w) / Double(h)
        let fw: Int, fh: Int, cw: Int, ch: Int
        if source > ratio {  // source is wider: cut the sides, or add bars above and below
            fh = h; fw = min(w, even(Double(h) * ratio))
            cw = w; ch = even(Double(w) / ratio)
        } else {
            fw = w; fh = min(h, even(Double(w) / ratio))
            ch = h; cw = even(Double(h) * ratio)
        }
        let cut = 1 - Double(fw * fh) / Double(w * h)
        return Reframe(fillWidth: fw, fillHeight: fh, cropX: (w - fw) / 2, cropY: (h - fh) / 2,
                       cutShare: max(0, cut), fitWidth: cw, fitHeight: ch)
    }

    /// "1920x1080" → "16:9". Within 1% of a common ratio it uses that name, otherwise the reduced fraction.
    public static func simplifiedRatio(width w: Int, height h: Int) -> String {
        guard w > 0, h > 0 else { return "—" }
        let r = Double(w) / Double(h)
        if let p = ratioPresets.min(by: { abs($0.value - r) < abs($1.value - r) }), abs(p.value - r) / p.value < 0.01 { return p.name }
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let g = gcd(w, h)
        return g > 1 && w / g < 50 && h / g < 50 ? "\(w / g):\(h / g)" : String(format: "%.2f:1", r)
    }
}
