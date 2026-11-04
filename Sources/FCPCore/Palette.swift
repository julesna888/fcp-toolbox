import CoreGraphics
import Foundation
import ImageIO

public struct PaletteColor: Identifiable, Equatable, Sendable {
    public var id: String { hex }
    public let r: Int, g: Int, b: Int
    /// Share of the picture closest to this color (0...1).
    public let share: Double
    public init(r: Int, g: Int, b: Int, share: Double) { self.r = r; self.g = g; self.b = b; self.share = share }
    public var hex: String { String(format: "#%02X%02X%02X", r, g, b) }
}

extension Doctor {
    /// The `count` main colors of a picture, most common first. Colors closer than `minDistance` count as one.
    public static func palette(of image: CGImage, count: Int = 6, minDistance: Double = 60) -> [PaletteColor] {
        let side = 64
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return [] }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let px = data.bindMemory(to: UInt8.self, capacity: side * side * 4)

        // 16 levels per channel: pixels in the same bucket are averaged.
        struct Bucket { var r = 0, g = 0, b = 0, n = 0 }
        var buckets: [Int: Bucket] = [:]
        for i in 0..<(side * side) where px[i * 4 + 3] > 127 {
            let r = Int(px[i * 4]), g = Int(px[i * 4 + 1]), b = Int(px[i * 4 + 2])
            let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
            var bk = buckets[key] ?? Bucket()
            bk.r += r; bk.g += g; bk.b += b; bk.n += 1
            buckets[key] = bk
        }
        let total = buckets.values.reduce(0) { $0 + $1.n }
        guard total > 0 else { return [] }
        typealias RGB = (r: Double, g: Double, b: Double, n: Int)
        let ordered: [RGB] = buckets.values.sorted { $0.n > $1.n }.map { (Double($0.r) / Double($0.n), Double($0.g) / Double($0.n), Double($0.b) / Double($0.n), $0.n) }
        func dist(_ a: RGB, _ c: RGB) -> Double {
            ((a.r - c.r) * (a.r - c.r) + (a.g - c.g) * (a.g - c.g) + (a.b - c.b) * (a.b - c.b)).squareRoot()
        }
        var centers: [RGB] = []
        for c in ordered where centers.count < count && centers.allSatisfy({ dist($0, c) >= minDistance }) { centers.append(c) }
        var shares = [Int](repeating: 0, count: centers.count)
        for c in ordered {
            let nearest = centers.indices.min { dist(centers[$0], c) < dist(centers[$1], c) }!
            shares[nearest] += c.n
        }
        return centers.indices.map {
            PaletteColor(r: Int(centers[$0].r.rounded()), g: Int(centers[$0].g.rounded()), b: Int(centers[$0].b.rounded()),
                         share: Double(shares[$0]) / Double(total))
        }.sorted { $0.share > $1.share }
    }

    /// Palette of an image file, or of one frame of a video (`seconds`).
    public static func palette(ofFile url: URL, at seconds: Double = 0, count: Int = 6) -> [PaletteColor] {
        var image: CGImage?
        if isPhoto(url) || ["gif", "bmp", "webp"].contains(url.pathExtension.lowercased()) {
            image = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        } else if let jpeg = frameImage(of: url, at: seconds, width: 256) {
            image = CGImageSourceCreateWithData(jpeg as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        }
        return image.map { palette(of: $0, count: count) } ?? []
    }
}
