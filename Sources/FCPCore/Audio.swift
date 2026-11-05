import Foundation

public struct Silence: Equatable, Sendable {
    public let start: Double
    public let duration: Double
}

/// What ffmpeg measured on the audio of a file. nil loudness = digital silence all the way through.
public struct AudioLevels: Equatable, Sendable {
    public var lufs: Double?
    public var truePeak: Double?
    public var range: Double?
    public var silences: [Silence] = []
}

extension Doctor {
    /// Loudness (EBU R128), true peak and silences in one ffmpeg pass. Nothing is written to disk.
    public static func audioLevels(of url: URL, silenceDB: Int = -50, minSilence: Double = 1) throws -> AudioLevels {
        guard let ffmpeg = ffmpegPath else { throw MediaError.unreadable("ffmpeg non trovato (brew install ffmpeg)") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-nostats", "-hide_banner", "-i", url.path, "-vn",
                       "-af", "ebur128=peak=true,silencedetect=n=\(silenceDB)dB:d=\(minSilence)", "-f", "null", "-"]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let data = err.fileHandleForReading.readDataToEndOfFile()  // read before waiting: the pipe would fill up
        p.waitUntilExit()
        let log = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0, log.contains("Summary:") else {
            throw MediaError.unreadable(TF("%@ (nessuna traccia audio?)", url.lastPathComponent))
        }
        return parseAudioLevels(log)
    }

    static func parseAudioLevels(_ log: String) -> AudioLevels {
        var a = AudioLevels()
        func number(_ pattern: String, in text: String) -> Double? {
            guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
            return Double(text[r].split(whereSeparator: { $0 == " " || $0 == "\t" })[1])
        }
        let summary = log.components(separatedBy: "Summary:").last ?? ""
        a.lufs = number(#"I:\s+-?[\d.]+ LUFS"#, in: summary)
        a.range = number(#"LRA:\s+[\d.]+ LU"#, in: summary)
        a.truePeak = number(#"Peak:\s+-?[\d.]+ dBFS"#, in: summary)
        for line in log.split(separator: "\n") {
            guard let end = line.range(of: "silence_end: "), let dur = line.range(of: "silence_duration: ") else { continue }
            let e = Double(line[end.upperBound...].prefix { $0 != " " }) ?? 0
            let d = Double(line[dur.upperBound...].prefix { $0 != " " }) ?? 0
            a.silences.append(Silence(start: max(0, e - d), duration: d))
        }
        return a
    }

    /// Plain verdicts for social delivery (target around -14 LUFS). Indicative, like the delivery profiles.
    public static func audioAdvice(_ a: AudioLevels, duration: Double) -> [CheckResult] {
        var out: [CheckResult] = []
        func add(_ label: String, _ ok: Bool, _ detail: String) { out.append(CheckResult(label: label, ok: ok, detail: detail)) }
        guard let lufs = a.lufs else {
            add("Volume", false, "Audio muto: non si sente niente.")
            return out
        }
        let v = String(format: "%.1f", lufs)
        if lufs < -18 {
            add("Volume", false, TF("Volume basso (%@ LUFS): sul telefono si sente poco. Alza l'audio verso -14.", v))
        } else if lufs > -9 {
            add("Volume", false, TF("Volume molto alto (%@ LUFS): le piattaforme lo abbassano o distorce. Abbassa verso -14.", v))
        } else {
            add("Volume", true, TF("Volume %@ LUFS: nella zona giusta (obiettivo circa -14).", v))
        }
        if let peak = a.truePeak, peak > -1 {
            add("Picco", false, TF("Picco %@ dB: rischio di distorsione. Tieni il picco sotto -1 dB.", String(format: "%.1f", peak)))
        }
        for s in a.silences {
            let t = String(format: "%.1f", s.duration)
            if s.start < 0.2 {
                add("Silenzio", false, TF("Silenzio di %@ s all'inizio: taglialo.", t))
            } else if s.start + s.duration > duration - 0.3 {
                add("Silenzio", false, TF("Silenzio di %@ s alla fine: taglialo.", t))
            } else {
                add("Silenzio", false, TF("Silenzio di %@ s a %@ s: controlla che sia voluto.", t, String(format: "%.0f", s.start)))
            }
        }
        return out
    }
}
