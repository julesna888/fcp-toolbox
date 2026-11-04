import Foundation

public enum ProxyCodec: String, Codable, CaseIterable, Sendable {
    case proresProxy = "ProRes Proxy"
    case h264 = "H.264"
    var ext: String { self == .proresProxy ? "mov" : "mp4" }
    var muxer: String { self == .proresProxy ? "mov" : "mp4" }
}

public struct ProxyOptions: Sendable {
    public var codec: ProxyCodec
    /// Target height in pixels. A clip that is already smaller is never enlarged.
    public var height: Int
    /// H.264 quality: lower is better and bigger (18–28 is the useful range).
    public var crf: Int
    public var destination: URL

    public init(codec: ProxyCodec = .proresProxy, height: Int = 540, crf: Int = 23, destination: URL) {
        self.codec = codec
        self.height = height
        self.crf = crf
        self.destination = destination
    }
}

public struct ProxyResult: Sendable {
    public let source: URL
    public let output: URL?
    public let verified: Bool
    public let problems: [String]
    /// A proxy is only proven to work in Final Cut once Final Cut has linked it: this tool cannot check that.
    public var fcpLinkVerified: Bool { false }
}

/// Lets the caller pause, resume or cancel the encoding that is running.
public final class ProxyControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var _cancelled = false
    public init() {}

    public var pid: Int32? { lock.lock(); defer { lock.unlock() }; return process?.isRunning == true ? process?.processIdentifier : nil }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    func attach(_ p: Process?) { lock.lock(); process = p; lock.unlock() }
    public func pause() { if let p = pid { kill(p, SIGSTOP) } }
    public func resume() { if let p = pid { kill(p, SIGCONT) } }
    public func cancel() {
        lock.lock(); _cancelled = true; let p = process; lock.unlock()
        if let p, p.isRunning { p.terminate(); kill(p.processIdentifier, SIGCONT) }  // a stopped process only dies once continued
    }
}

extension Doctor {
    public static var ffmpegPath: String? {
        ["/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg", "/usr/bin/ffmpeg"].first { fm.isExecutableFile(atPath: $0) }
    }

    /// Rough size of the proxy, to refuse early when the destination is too small.
    static func estimatedProxyBytes(_ info: MediaInfo, codec: ProxyCodec, height: Int) -> Int64 {
        let scale = Double(height * height * 16 / 9) / Double(1920 * 1080)
        let mbps = (codec == .proresProxy ? 45.0 : 8.0) * max(scale, 0.1)
        return Int64(info.duration * mbps * 1e6 / 8)
    }

    public static func makeProxy(_ source: URL, options: ProxyOptions, control: ProxyControl = ProxyControl(),
                                 progress: @escaping @Sendable (Double) -> Void = { _ in }) -> ProxyResult {
        func fail(_ m: String) -> ProxyResult { ProxyResult(source: source, output: nil, verified: false, problems: [m]) }
        guard let ffmpeg = ffmpegPath else { return fail("ffmpeg non trovato. Installalo con Homebrew (brew install ffmpeg).") }
        guard let info = try? probeMedia(source), let v = info.video else { return fail("Non riesco a leggere il video di \(source.lastPathComponent).") }

        let height = max(2, min(options.height, v.displayHeight) / 2 * 2)
        let out = options.destination.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent)_proxy.\(options.codec.ext)")
        guard !fm.fileExists(atPath: out.path) else { return fail("\(out.lastPathComponent) esiste già: non lo sovrascrivo.") }
        try? fm.createDirectory(at: options.destination, withIntermediateDirectories: true)
        let need = estimatedProxyBytes(info, codec: options.codec, height: height)
        if let free = freeSpace(of: probe([options.destination]).volume ?? options.destination), need + 500_000_000 > free {
            return fail("Spazio insufficiente per \(source.lastPathComponent): servono circa \(formatBytes(need)), ne restano \(formatBytes(free)).")
        }

        let partial = out.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)  // leftover of an earlier interrupted run of this same job
        var args = ["-v", "error", "-nostdin", "-n", "-i", source.path, "-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0",
                    "-vf", "scale=-2:\(height)"]
        switch options.codec {
        case .proresProxy: args += ["-c:v", "prores_ks", "-profile:v", "0", "-pix_fmt", "yuv422p10le", "-c:a", "pcm_s16le"]
        case .h264: args += ["-c:v", "libx264", "-preset", "fast", "-crf", "\(options.crf)", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"]
        }
        args += ["-f", options.codec.muxer, "-progress", "pipe:1", "-nostats", partial.path]

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let total = max(info.duration, 0.1)
        outPipe.fileHandleForReading.readabilityHandler = { h in
            for line in String(decoding: h.availableData, as: UTF8.self).split(separator: "\n") where line.hasPrefix("out_time_us=") {
                if let us = Double(line.dropFirst(12)) { progress(min(1, us / 1e6 / total)) }
            }
        }
        var errText = Data()
        let errLock = NSLock()
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            errLock.lock(); errText += d; errLock.unlock()
        }
        control.attach(p)
        do { try p.run() } catch { control.attach(nil); return fail("Avvio di ffmpeg non riuscito: \(error.localizedDescription)") }
        if control.isCancelled { control.cancel() }
        p.waitUntilExit()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        control.attach(nil)

        if control.isCancelled { try? fm.removeItem(at: partial); return fail("Annullato.") }
        guard p.terminationStatus == 0 else {
            try? fm.removeItem(at: partial)
            errLock.lock(); let msg = String(decoding: errText, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? "errore sconosciuto"; errLock.unlock()
            return fail("ffmpeg ha fallito su \(source.lastPathComponent): \(msg)")
        }
        do { try fm.moveItem(at: partial, to: out) } catch { return fail("Non riesco a salvare \(out.lastPathComponent): \(error.localizedDescription)") }
        progress(1)

        var problems: [String] = []
        if let o = try? probeMedia(out), let ov = o.video {
            if ov.displayHeight != height { problems.append("Altezza \(ov.displayHeight) invece di \(height).") }
            if options.codec == .proresProxy, ov.codec != "prores" { problems.append("Codec \(ov.codec) invece di ProRes.") }
            if abs(o.duration - info.duration) > 0.5 { problems.append("Durata \(String(format: "%.1f", o.duration)) s invece di \(String(format: "%.1f", info.duration)) s.") }
            if !info.audio.isEmpty, o.audio.isEmpty { problems.append("L'audio non è stato copiato.") }
        } else {
            problems.append("Il proxy creato non è leggibile.")
        }
        return ProxyResult(source: source, output: out, verified: problems.isEmpty, problems: problems)
    }

    /// Runs the files one after the other. Stops when cancelled; the rest are reported as not done.
    public static func makeProxies(_ sources: [URL], options: ProxyOptions, control: ProxyControl = ProxyControl(),
                                   progress: @escaping @Sendable (Int, Double) -> Void = { _, _ in }) -> [ProxyResult] {
        var results: [ProxyResult] = []
        for (i, s) in sources.enumerated() {
            if control.isCancelled {
                results.append(ProxyResult(source: s, output: nil, verified: false, problems: ["Non eseguito: coda annullata."]))
                continue
            }
            results.append(makeProxy(s, options: options, control: control) { progress(i, $0) })
        }
        return results
    }
}
