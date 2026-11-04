import Foundation

/// A set of requirements for a delivery. Only the fields that are set are checked.
public struct DeliverySpec: Codable, Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    /// Where the numbers come from; platform rules change, so built-in profiles are marked as indicative.
    public var note = ""
    public var orientation: String?  // "vertical" | "horizontal"
    public var minWidth: Int?
    public var minHeight: Int?
    public var exactSizes: [String]?  // "1920x1080"
    public var fps: [Double]?
    public var videoCodecs: [String]?
    public var containers: [String]?  // file extensions
    public var maxDuration: Double?
    public var minDuration: Double?
    public var maxSizeMB: Double?
    public var minVideoMbps: Double?
    public var maxVideoMbps: Double?
    public var requireAudio = true
    public var audioChannels: [Int]?
    public var audioSampleRates: [Int]?
    public var audioCodecs: [String]?
    public var minBitDepth: Int?
    public var allowHDR = false
    public var requireConstantFrameRate = true

    public init(name: String) { self.name = name }
}

public struct CheckResult: Identifiable, Sendable {
    public var id: String { label }
    public let label: String
    public let ok: Bool
    public let detail: String
}

extension Doctor {
    static let indicative = "Valori indicativi: controlla le specifiche attuali della piattaforma e modificali se serve."

    public static var deliveryProfiles: [DeliverySpec] {
        func make(_ name: String, _ f: (inout DeliverySpec) -> Void) -> DeliverySpec {
            var s = DeliverySpec(name: name)
            f(&s)
            return s
        }
        return [
            make("Instagram Reels") {
                $0.note = indicative; $0.orientation = "vertical"; $0.minWidth = 720; $0.minHeight = 1280
                $0.fps = nil; $0.videoCodecs = ["h264", "hevc"]; $0.containers = ["mp4", "mov"]; $0.maxDuration = 180
                $0.maxSizeMB = 4000; $0.audioCodecs = ["aac"]
            },
            make("TikTok") {
                $0.note = indicative; $0.orientation = "vertical"; $0.minWidth = 720; $0.minHeight = 1280
                $0.videoCodecs = ["h264", "hevc"]; $0.containers = ["mp4", "mov"]; $0.maxSizeMB = 500; $0.audioCodecs = ["aac"]
            },
            make("YouTube") {
                $0.note = indicative; $0.orientation = "horizontal"; $0.minWidth = 1280; $0.minHeight = 720
                $0.videoCodecs = ["h264", "hevc", "vp9", "av1", "prores"]; $0.containers = ["mp4", "mov", "mkv", "webm"]
                $0.audioCodecs = ["aac", "opus", "flac", "pcm_s16le", "pcm_s24le"]
            },
            make("YouTube Shorts") {
                $0.note = indicative; $0.orientation = "vertical"; $0.minWidth = 720; $0.minHeight = 1280
                $0.videoCodecs = ["h264", "hevc"]; $0.containers = ["mp4", "mov"]; $0.maxDuration = 180
            },
            make("ADV 1080p") {
                $0.note = "Profilo di partenza per spot in Full HD: adattalo alle specifiche del cliente."
                $0.orientation = "horizontal"; $0.exactSizes = ["1920x1080"]; $0.fps = [24, 25, 30, 50, 60]
                $0.videoCodecs = ["h264", "prores"]; $0.audioChannels = [2]; $0.audioSampleRates = [48000]
            },
            make("Master di archivio") {
                $0.note = "Master di alta qualità: ProRes o DNxHD, 10 bit, audio non compresso."
                $0.videoCodecs = ["prores", "dnxhd", "dnxhr"]; $0.minBitDepth = 10; $0.minVideoMbps = 100
                $0.audioCodecs = ["pcm_s16le", "pcm_s24le", "pcm_s32le"]; $0.audioSampleRates = [48000]
            },
        ]
    }

    /// Checks the real streams of the file against the spec. The name and extension of the file are never trusted.
    public static func checkDelivery(_ m: MediaInfo, spec: DeliverySpec) -> [CheckResult] {
        var out: [CheckResult] = []
        func add(_ label: String, _ ok: Bool, _ detail: String) { out.append(CheckResult(label: label, ok: ok, detail: detail)) }
        func list<T>(_ a: [T]) -> String { a.map { "\($0)" }.joined(separator: ", ") }

        guard let v = m.video else { add("Video", false, "Il file non contiene video."); return out }
        let w = v.displayWidth, h = v.displayHeight
        add("Dimensioni", true, "\(w)×\(h)")
        if let o = spec.orientation {
            let isV = h > w
            add("Orientamento", (o == "vertical") == isV, "È \(isV ? "verticale" : "orizzontale"), richiesto \(o == "vertical" ? "verticale" : "orizzontale").")
        }
        if let mw = spec.minWidth, let mh = spec.minHeight { add("Risoluzione minima", w >= mw && h >= mh, "\(w)×\(h), minimo \(mw)×\(mh).") }
        if let sizes = spec.exactSizes { add("Risoluzione", sizes.contains("\(w)x\(h)"), "\(w)×\(h), richiesto \(list(sizes)).") }
        if let f = spec.fps { add("Frame rate", f.contains { abs($0 - v.fps) < 0.01 }, "\(String(format: "%g", (v.fps * 100).rounded() / 100)) fps, ammessi \(list(f)).") }
        if spec.requireConstantFrameRate { add("Frame rate costante", !v.isVFR, v.isVFR ? "Frame rate variabile." : "Costante.") }
        if let c = spec.videoCodecs { add("Codec video", c.contains(v.codec), "\(v.codec), ammessi \(list(c)).") }
        if let c = spec.containers {
            let ext = m.url.pathExtension.lowercased()
            add("Formato file", c.contains(ext), ".\(ext), ammessi \(list(c)).")
        }
        if let d = spec.maxDuration { add("Durata massima", m.duration <= d, "\(Int(m.duration)) s, massimo \(Int(d)) s.") }
        if let d = spec.minDuration { add("Durata minima", m.duration >= d, "\(Int(m.duration)) s, minimo \(Int(d)) s.") }
        if let s = spec.maxSizeMB { add("Peso massimo", Double(m.size) / 1e6 <= s, "\(formatBytes(m.size)), massimo \(Int(s)) MB.") }
        let mbps = Double(v.bitrate > 0 ? v.bitrate : m.bitrate) / 1e6
        if let b = spec.minVideoMbps { add("Bitrate minimo", mbps >= b, "\(String(format: "%.1f", mbps)) Mbps, minimo \(Int(b)).") }
        if let b = spec.maxVideoMbps { add("Bitrate massimo", mbps <= b, "\(String(format: "%.1f", mbps)) Mbps, massimo \(Int(b)).") }
        if let d = spec.minBitDepth { add("Profondità colore", v.bitDepth >= d, "\(v.bitDepth) bit, minimo \(d).") }
        if !spec.allowHDR { add("SDR", !v.isHDR, v.isHDR ? "Il file è HDR (\(v.transfer))." : "Standard (SDR).") }

        if spec.requireAudio || spec.audioChannels != nil || spec.audioSampleRates != nil || spec.audioCodecs != nil {
            guard let a = m.audio.first else {
                if spec.requireAudio { add("Audio", false, "Manca la traccia audio.") }
                return out
            }
            add("Audio", true, "\(a.codec), \(a.channels) canali, \(a.sampleRate) Hz")
            if let c = spec.audioChannels { add("Canali audio", c.contains(a.channels), "\(a.channels), ammessi \(list(c)).") }
            if let r = spec.audioSampleRates { add("Frequenza audio", r.contains(a.sampleRate), "\(a.sampleRate) Hz, ammessi \(list(r)).") }
            if let c = spec.audioCodecs { add("Codec audio", c.contains(a.codec), "\(a.codec), ammessi \(list(c)).") }
        }
        return out
    }

    static let containerNames: [String: Set<String>] = [
        "mp4": ["mov", "mp4", "m4a", "3gp", "3g2", "mj2"], "mov": ["mov", "mp4", "m4a", "3gp", "3g2", "mj2"],
        "m4v": ["mov", "mp4", "m4a", "3gp", "3g2", "mj2"], "mkv": ["matroska", "webm"], "webm": ["matroska", "webm"],
        "avi": ["avi"], "mxf": ["mxf"],
    ]

    /// Technical oddities that no platform spec mentions but that cause trouble later.
    public static func technicalAnomalies(_ m: MediaInfo) -> [String] {
        var out: [String] = []
        if let names = containerNames[m.url.pathExtension.lowercased()], !names.contains(where: { m.container.contains($0) }) {
            out.append("L'estensione dice .\(m.url.pathExtension.lowercased()) ma il contenitore reale è \(m.container).")
        }
        guard let v = m.video else { out.append("Nessuna traccia video."); return out }
        if m.duration <= 0 { out.append("Durata non rilevata.") }
        if v.width % 2 == 1 || v.height % 2 == 1 { out.append("Dimensioni dispari (\(v.width)×\(v.height)): alcuni codec e piattaforme le rifiutano.") }
        if v.isVFR { out.append("Frame rate variabile: può dare sfasamenti audio e problemi nel montaggio.") }
        if v.rotation != 0 { out.append("Il file è ruotato di \(v.rotation)° nei metadati: alcuni player lo mostrano storto.") }
        if let a = m.audio.first, v.duration > 0, a.duration > 0, abs(v.duration - a.duration) > 0.5 {
            out.append("Audio e video hanno durate diverse (video \(String(format: "%.1f", v.duration)) s, audio \(String(format: "%.1f", a.duration)) s).")
        }
        if m.audio.isEmpty { out.append("Nessuna traccia audio.") }
        return out
    }

    // MARK: Custom specs

    public static var customSpecsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/FCP Toolbox/delivery-specs.json")
    }

    public static func loadCustomSpecs(at url: URL = customSpecsURL) -> [DeliverySpec] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([DeliverySpec].self, from: d)) ?? []
    }

    public static func saveCustomSpecs(_ specs: [DeliverySpec], at url: URL = customSpecsURL) {
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(specs) { try? d.write(to: url) }
    }
}
