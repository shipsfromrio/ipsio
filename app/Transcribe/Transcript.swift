// Transcript.swift: the pure half of the transcription. No Speech and no
// AVFoundation here, so the bench runs all of it: who a track is, the windows
// a long track is cut into and how their overlap is undone, words grouped
// into utterances, and the merge of the two tracks by time.
import Foundation

/// Who spoke. It comes from the track, never from a voice model: the
/// microphone track is the user, the computer track is everyone else.
enum Speaker: String, Equatable {
    case me = "Me", others = "Others"

    /// The speaker of audio track `index` (0-based) in a file with `count`
    /// audio tracks, nil for a track that is not transcribed.
    /// - 1 track (class mode): the computer sound, the others.
    /// - 2 tracks (meeting mode, the native engine): 1 computer, 2 microphone.
    /// - 3 tracks (ipsio.sh's .mkv remuxed): 1 the mix (skipped), 2 computer, 3 microphone.
    /// Any other layout is unknown: nil for every track, and the caller refuses.
    static func forTrack(_ index: Int, of count: Int) -> Speaker? {
        switch (count, index) {
        case (1, 0), (2, 0), (3, 1): return .others
        case (2, 1), (3, 2): return .me
        default: return nil
        }
    }
}

/// One recognized word, times in seconds from the start of the recording.
struct Word: Equatable {
    var start: Double, end: Double, text: String
    var mid: Double { (start + end) / 2 }
}

/// One line of the transcript.
struct Segment: Equatable {
    var start: Double, end: Double, speaker: Speaker, text: String
}

enum Language {
    /// "pt", "pt-BR", "pt_BR" -> "pt-BR"; "en", "en-US" -> "en-US"; anything else nil.
    static func identifier(_ s: String) -> String? {
        switch s.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "pt", "pt-br": return "pt-BR"
        case "en", "en-us": return "en-US"
        default: return nil
        }
    }
}

/// SFSpeechRecognizer takes about a minute per request, so a track is cut
/// into windows of `length` seconds that overlap by `overlap` seconds (a word
/// cut in half at one edge is whole in the other window).
enum Windows {
    static let length = 50.0, overlap = 2.0

    /// The windows of a track of `duration` seconds, as (start, end).
    static func plan(duration: Double, length: Double = length, overlap: Double = overlap) -> [(start: Double, end: Double)] {
        guard duration > 0, length > overlap, overlap >= 0 else { return [] }
        var out: [(start: Double, end: Double)] = [], start = 0.0
        while true {
            let end = min(start + length, duration)
            out.append((start, end))
            if end >= duration { break }
            start += length - overlap
        }
        return out
    }
}

/// The same windows, cut from samples as they are decoded, so an 8 h track
/// never sits whole in memory. Agrees with `Windows.plan` (the bench checks).
struct WindowSplitter {
    let length: Int, hop: Int
    private var buffer: [Float] = []
    private var offset = 0            // sample index of buffer[0]
    private var emitted = false

    init(rate: Int, length: Double = Windows.length, overlap: Double = Windows.overlap) {
        self.length = max(1, Int(length * Double(rate)))
        self.hop = max(1, self.length - Int(overlap * Double(rate)))
    }

    /// Adds samples; answers the windows that are now complete.
    mutating func push(_ s: [Float]) -> [(start: Int, samples: [Float])] {
        buffer += s
        var out: [(start: Int, samples: [Float])] = []
        while buffer.count >= length {
            out.append((offset, Array(buffer[0..<length])))
            buffer.removeFirst(hop); offset += hop; emitted = true
        }
        return out
    }

    /// The last, shorter window, if it holds anything the previous one did not.
    mutating func finish() -> (start: Int, samples: [Float])? {
        let fresh = emitted ? buffer.count - (length - hop) : buffer.count
        guard fresh > 0 else { return nil }
        defer { buffer = []; emitted = true }
        return (offset, buffer)
    }
}

/// Undoes the overlap: in the stretch two windows share, each word is kept
/// from one window only, the one whose side of the middle of the overlap
/// holds the word's middle. A word both windows heard straddling that middle
/// (same text, starting within half a second) is kept once.
enum Overlap {
    static func merge(_ windows: [(start: Double, words: [Word])], overlap: Double = Windows.overlap) -> [Word] {
        var out: [Word] = []
        for (i, w) in windows.enumerated() {
            let lo = i == 0 ? -Double.infinity : w.start + overlap / 2
            let hi = i + 1 < windows.count ? windows[i + 1].start + overlap / 2 : Double.infinity
            var first = true
            for word in w.words where word.mid >= lo && word.mid < hi {
                if first, i > 0, let last = out.last, norm(last.text) == norm(word.text), abs(last.start - word.start) < 0.5 {
                    first = false; continue
                }
                first = false
                out.append(word)
            }
        }
        return out
    }

    static func norm(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}

/// Words into utterances: a new line after a pause, after a sentence ends,
/// or when a line grows too long to read as one subtitle.
enum Utterances {
    static func group(_ words: [Word], speaker: Speaker, maxGap: Double = 1.0, maxLength: Double = 12) -> [Segment] {
        var out: [Segment] = []
        var cur: Segment?
        var endsSentence = false
        for w in words {
            let t = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            // A bare mark (".", ",") the recognizer gave as its own token sticks to the word before.
            if var c = cur, t.allSatisfy({ ".,?!;:".contains($0) }) {
                c.text += t; c.end = max(c.end, w.end); cur = c
            } else if var c = cur, !(endsSentence || w.start - c.end > maxGap || w.end - c.start > maxLength) {
                c.text += " " + t; c.end = max(c.end, w.end); cur = c
            } else {
                if let c = cur { out.append(c) }
                cur = Segment(start: w.start, end: max(w.end, w.start), speaker: speaker, text: t)
            }
            endsSentence = t.last.map { ".?!".contains($0) } ?? false
        }
        if let c = cur { out.append(c) }
        return out
    }
}

extension Utterances {
    /// Joins what a recognizer reported utterance by utterance: words of a
    /// new report that start before the end of what is already heard are
    /// repeats (a cumulative final result, as on macOS 13) and are dropped.
    static func accumulate(_ heard: [Word], _ report: [Word]) -> [Word] {
        let edge = (heard.last?.end ?? -Double.infinity) - 0.02
        return heard + report.filter { $0.start >= edge && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

enum Transcript {
    /// The tracks' segments in one list, by start time; a tie keeps the
    /// order of the tracks, then the order inside each track.
    static func merge(_ tracks: [[Segment]]) -> [Segment] {
        var all: [(seg: Segment, track: Int, i: Int)] = []
        for (t, segs) in tracks.enumerated() { for (i, s) in segs.enumerated() { all.append((s, t, i)) } }
        all.sort { a, b in
            if a.seg.start != b.seg.start { return a.seg.start < b.seg.start }
            if a.track != b.track { return a.track < b.track }
            return a.i < b.i
        }
        return all.map { $0.seg }
    }

    /// Without headphones the microphone hears the speakers, and the others'
    /// words came out twice, once as "Me" (measured on a real Mac). A "Me"
    /// line is that echo when it overlaps an "Others" line in time and most
    /// of its words are in it (`Echo.repeats`). "Others" is never dropped.
    static func dropEcho(_ segs: [Segment], slack: Double = 1.0, share: Double = Echo.share) -> [Segment] {
        let others = segs.filter { $0.speaker == .others }
        return segs.filter { m in
            guard m.speaker == .me else { return true }
            return !others.contains { o in
                guard o.start - slack <= m.end && m.start <= o.end + slack else { return false }
                return Echo.repeats(m.text, in: o.text, share: share)
            }
        }
    }
}

/// The one echo rule, for the finished transcript (`Transcript.dropEcho`) and
/// for helper mode's live lines (`Echo.isEcho`): a line on "Me" is the
/// loudspeaker in the microphone when most of its words are in a line the
/// others said at the same moment. Each caller says what "the same moment" is.
enum Echo {
    static let share = 0.6

    /// Lowercased, accents folded, letters and digits only.
    static func words(_ s: String) -> [String] {
        let f = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        let mapped = f.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(mapped).split(separator: " ").map(String.init)
    }

    /// At least `share` of the words of `mine` are in `theirs`; a line shorter
    /// than `minWords` words is never an echo.
    static func repeats(_ mine: String, in theirs: String, share: Double = Echo.share, minWords: Int = 1) -> Bool {
        let mine = words(mine)
        guard mine.count >= max(1, minWords) else { return false }
        let theirs = Set(words(theirs))
        return Double(mine.filter { theirs.contains($0) }.count) / Double(mine.count) >= share
    }
}

/// A window nobody spoke in is not sent to the recognizer: it saves the
/// time, and a recognizer fed silence sometimes invents a word.
enum Silence {
    static let thresholdDB = -50.0

    /// The RMS of the loudest 100 ms frame, in dBFS; -200 for no samples.
    static func peakDB(_ s: [Float], rate: Int) -> Double {
        let frame = max(1, rate / 10)
        var best = 0.0, i = 0
        while i < s.count {
            let j = min(s.count, i + frame)
            var sum = 0.0
            for k in i..<j { let v = Double(s[k]); sum += v * v }
            best = max(best, sum / Double(j - i))
            i = j
        }
        return best > 0 ? 10 * log10(best) : -200
    }

    static func isSilent(_ s: [Float], rate: Int, threshold: Double = thresholdDB) -> Bool {
        peakDB(s, rate: rate) < threshold
    }
}
