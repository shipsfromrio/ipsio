// Export.swift: a transcript as text. Pure functions build the .txt, .srt
// and .md; `write` puts them next to the recording ("<name>.txt", ".srt",
// ".md") through a temporary file and a rename, so a reader never sees half a
// file. The recording and its .sha256 are never written: an output path that
// would land on either is refused.
import Foundation

enum Export {
    /// "HH:MM:SS", the second rounded down; negative times read as 0.
    static func clock(_ s: Double) -> String {
        let t = Int(max(0, s).rounded(.down))
        return String(format: "%02d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
    }

    /// The SRT time, "HH:MM:SS,mmm" (a comma before the milliseconds).
    static func srtTime(_ s: Double) -> String {
        let ms = Int((max(0, s) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    /// One line of text: line breaks and runs of spaces become one space.
    static func clean(_ t: String) -> String {
        t.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static let noSpeech = "(no speech found)"

    /// "[HH:MM:SS] Speaker: text", one line each.
    static func txt(_ segs: [Segment]) -> String {
        let lines = segs.compactMap { s -> String? in
            let t = clean(s.text)
            return t.isEmpty ? nil : "[\(clock(s.start))] \(s.speaker.rawValue): \(t)"
        }
        return (lines.isEmpty ? noSpeech : lines.joined(separator: "\n")) + "\n"
    }

    /// Numbered cues from 1; a cue lasts at least 0.5 s, so a word with no
    /// duration still shows. No speech gives an empty file (a valid SRT).
    static func srt(_ segs: [Segment]) -> String {
        var out = "", n = 0
        for s in segs {
            let t = clean(s.text)
            if t.isEmpty { continue }
            n += 1
            let end = max(s.end, s.start + 0.5)
            out += "\(n)\n\(srtTime(s.start)) --> \(srtTime(end))\n\(s.speaker.rawValue): \(t)\n\n"
        }
        return out
    }

    /// Readable: a title, then one paragraph per line of the transcript.
    static func md(_ segs: [Segment], title: String, language: String) -> String {
        var out = "# \(clean(title))\n\nTranscript (\(language)), made on this Mac. Me = the microphone track, Others = the computer sound.\n\n"
        let paras = segs.compactMap { s -> String? in
            let t = clean(s.text)
            return t.isEmpty ? nil : "**[\(clock(s.start))] \(s.speaker.rawValue):** \(t)"
        }
        out += paras.isEmpty ? "_\(noSpeech)_\n" : paras.joined(separator: "\n\n") + "\n"
        return out
    }

    static let kinds = ["txt", "srt", "md"]

    /// "<dir>/<name>.txt", ".srt", ".md" for "<dir>/<name>.<ext>".
    static func outputs(for media: String) -> [String] {
        let base = (media as NSString).deletingPathExtension
        return kinds.map { base + "." + $0 }
    }

    enum Failure: Error, CustomStringConvertible {
        case refused(String), write(String)
        var description: String {
            switch self {
            case .refused(let s): return "refused to write \(s): it would replace the recording or its evidence"
            case .write(let s): return "could not write \(s)"
            }
        }
    }

    /// Writes the three files next to `media`; answers their paths. An old
    /// transcript is replaced; the recording and "<recording>.sha256" never are.
    @discardableResult
    static func write(_ segs: [Segment], media: String, language: String) throws -> [String] {
        let title = ((media as NSString).lastPathComponent as NSString).deletingPathExtension
        let ext = (media as NSString).pathExtension.lowercased()
        if kinds.contains(ext) || ext == "sha256" { throw Failure.refused(media) }
        let paths = outputs(for: media)
        for p in paths where p == media || p == media + ".sha256" { throw Failure.refused(p) }
        let bodies = [txt(segs), srt(segs), md(segs, title: title, language: language)]
        for (p, body) in zip(paths, bodies) {
            let tmp = p + ".tmp"
            do { try body.write(toFile: tmp, atomically: false, encoding: .utf8) }
            catch { try? FileManager.default.removeItem(atPath: tmp); throw Failure.write(p) }
            // rename(2) replaces the old file in one step.
            if rename(tmp, p) != 0 { try? FileManager.default.removeItem(atPath: tmp); throw Failure.write(p) }
        }
        return paths
    }
}
