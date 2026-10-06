// Search.swift: find a word in what was said. Reads the transcripts
// ("<name>.txt", lines "[HH:MM:SS] Me: text", see Transcribe/Export.swift)
// and the recordings' file names in the recordings folder (flat, no
// subfolders). Every word of the query must be in the line (AND), with case
// and accents ignored ("acao" finds "ação"). Read only: nothing is written,
// renamed or deleted; a file that cannot be read is skipped.
// Pure: no AppKit (tests/SearchTests.swift).
import Foundation

enum Search {
    struct Hit: Equatable {
        let media: String        // the .mov/.mkv; the .txt when the recording is gone
        let transcript: String?  // the .txt the line came from; nil for a file-name hit
        let seconds: Int         // offset in the recording; 0 for a file-name hit
        let speaker: String      // "Me", "Others"; "" for a file-name hit
        let snippet: String
    }

    static let media = ["mov", "mkv"]

    /// Lower case, no accents: what both sides are compared in.
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }

    /// The query's words, folded; empty words dropped.
    static func terms(_ q: String) -> [String] {
        fold(q).components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    }

    static func matches(_ text: String, _ terms: [String]) -> Bool {
        guard !terms.isEmpty else { return false }
        let f = fold(text)
        return terms.allSatisfy { f.contains($0) }
    }

    /// "[HH:MM:SS] Speaker: text" into (seconds, speaker, text); nil otherwise.
    static func parse(_ line: String) -> (seconds: Int, speaker: String, text: String)? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let clock = line[line.index(after: line.startIndex)..<close].split(separator: ":", omittingEmptySubsequences: false)
        guard clock.count == 3, clock.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let h = Int(clock[0]), let m = Int(clock[1]), let s = Int(clock[2]), m < 60, s < 60 else { return nil }
        let rest = line[line.index(after: close)...]
        guard rest.hasPrefix(" "), let colon = rest.range(of: ": ") else { return nil }
        let who = rest[rest.index(after: rest.startIndex)..<colon.lowerBound]
        guard !who.isEmpty, !who.contains(" ") else { return nil }
        return (h * 3600 + m * 60 + s, String(who), String(rest[colon.upperBound...]))
    }

    /// "HH:MM:SS", the format the transcript uses.
    static func clock(_ s: Int) -> String {
        let t = max(0, s)
        return String(format: "%02d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
    }

    static func snippet(_ s: String, max: Int = 200) -> String {
        s.count <= max ? s : String(s.prefix(max)) + "..."
    }

    /// Every hit in `dir`, recordings newest first (modification time, then
    /// name), and inside one recording the file name first, then by time.
    static func find(query: String, in dir: String, limit: Int = 200) -> [Hit] {
        let q = terms(query)
        guard !q.isEmpty, limit > 0 else { return [] }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        // One entry per recording: "<dir>/<name>" without the extension.
        var bases: [String: (media: String?, txt: String?)] = [:]
        for n in names where !n.hasPrefix(".") {
            let ext = (n as NSString).pathExtension.lowercased()
            let base = dir + "/" + (n as NSString).deletingPathExtension
            var e = bases[base] ?? (nil, nil)
            if media.contains(ext) {
                // Two recordings of one name (.mov and .mkv): the .mov wins.
                if e.media == nil || ext == "mov" { e.media = dir + "/" + n }
            } else if ext == "txt" { e.txt = dir + "/" + n } else { continue }
            bases[base] = e
        }
        func date(_ p: String) -> Date {
            ((try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date) ?? .distantPast
        }
        let order = bases.map { (base: $0.key, entry: $0.value, date: date($0.value.media ?? $0.value.txt!)) }
            .sorted { $0.date != $1.date ? $0.date > $1.date : $0.base > $1.base }
        var out: [Hit] = []
        for r in order {
            let shown = r.entry.media ?? r.entry.txt!
            if let m = r.entry.media {
                let name = (m as NSString).lastPathComponent
                if matches((name as NSString).deletingPathExtension, q) {
                    out.append(Hit(media: m, transcript: nil, seconds: 0, speaker: "", snippet: name))
                    if out.count >= limit { return out }
                }
            }
            guard let t = r.entry.txt, let text = try? String(contentsOfFile: t, encoding: .utf8) else { continue }
            var lines: [Hit] = []
            for line in text.components(separatedBy: .newlines) {
                guard let p = parse(line), matches(p.text, q) else { continue }
                lines.append(Hit(media: shown, transcript: t, seconds: p.seconds, speaker: p.speaker, snippet: snippet(p.text)))
            }
            // The file is in time order; sorting keeps it so if it was not.
            for h in lines.enumerated().sorted(by: { $0.element.seconds != $1.element.seconds ? $0.element.seconds < $1.element.seconds : $0.offset < $1.offset }) {
                out.append(h.element)
                if out.count >= limit { return out }
            }
        }
        return out
    }
}
