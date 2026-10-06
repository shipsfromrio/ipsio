// TranscribeTests.swift: the bench for the pure half of the transcription
// (windows and their overlap, utterances, the merge, speakers, the exports and
// where they are written). Compiles with app/Transcribe/:
//   swiftc -parse-as-library app/Transcribe/*.swift tests/TranscribeTests.swift -o /tmp/transcribe-tests && /tmp/transcribe-tests
// Exits 1 if any assertion fails. No speech recognition runs here.
import Foundation

var fails = 0, total = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    total += 1
    if ok { print("ok   \(name)") } else { fails += 1; print("FAIL \(name)"); let d = detail(); if !d.isEmpty { print("      \(d)") } }
}
func w(_ s: Double, _ e: Double, _ t: String) -> Word { Word(start: s, end: e, text: t) }
func seg(_ s: Double, _ e: Double, _ who: Speaker, _ t: String) -> Segment { Segment(start: s, end: e, speaker: who, text: t) }
func texts(_ ws: [Word]) -> String { ws.map { $0.text }.joined(separator: " ") }

@main
struct TranscribeTests {
    static func main() {
        // Speakers come from the track, not from a voice.
        check(Speaker.forTrack(0, of: 1) == .others, "class mode: the only track is the others")
        check(Speaker.forTrack(0, of: 2) == .others && Speaker.forTrack(1, of: 2) == .me, "meeting mode: track 1 others, track 2 me")
        check(Speaker.forTrack(0, of: 3) == nil && Speaker.forTrack(1, of: 3) == .others && Speaker.forTrack(2, of: 3) == .me,
              "the script's three tracks: the mix is skipped")
        check((0..<4).allSatisfy { Speaker.forTrack($0, of: 4) == nil } && Speaker.forTrack(0, of: 0) == nil, "an unknown layout has no speaker")
        check(Speaker.me.rawValue == "Me" && Speaker.others.rawValue == "Others", "the labels")

        check(Language.identifier("pt") == "pt-BR" && Language.identifier("PT_br") == "pt-BR", "pt is pt-BR")
        check(Language.identifier("en") == "en-US" && Language.identifier("en-US") == "en-US", "en is en-US")
        check(Language.identifier("fr") == nil && Language.identifier("") == nil, "any other language is refused")

        // Windows: 50 s, 2 s overlap.
        let p = Windows.plan(duration: 120)
        check(p.map { "\(Int($0.start))-\(Int($0.end))" } == ["0-50", "48-98", "96-120"], "120 s is three windows", "\(p)")
        check(Windows.plan(duration: 50).count == 1, "exactly 50 s is one window")
        check(Windows.plan(duration: 98).map { $0.end } == [50, 98], "98 s ends on the second window, no empty third")
        check(Windows.plan(duration: 10).map { "\($0.start)-\($0.end)" } == ["0.0-10.0"], "a short track is one short window")
        check(Windows.plan(duration: 0).isEmpty && Windows.plan(duration: -1).isEmpty, "no audio, no window")
        let long = Windows.plan(duration: 3600)
        check(zip(long, long.dropFirst()).allSatisfy { abs($0.end - $1.start - 2) < 1e-9 } && long.last!.end == 3600,
              "an hour: every pair overlaps by exactly 2 s and the last ends at the end")

        // The splitter cuts the same windows from samples arriving in any sizes.
        let rate = 100
        for (secs, piece) in [(120, 7), (98, 1000), (50, 13), (10, 3), (99, 4900), (0, 5)] {
            var sp = WindowSplitter(rate: rate)
            var got: [String] = []
            let samples = (0..<(secs * rate)).map { Float($0) }
            var i = 0
            while i < samples.count {
                let j = min(samples.count, i + piece)
                for x in sp.push(Array(samples[i..<j])) { got.append("\(x.start / rate)-\((x.start + x.samples.count) / rate)") }
                i = j
            }
            if let x = sp.finish() { got.append("\(x.start / rate)-\((x.start + x.samples.count) / rate)") }
            let want = Windows.plan(duration: Double(secs)).map { "\(Int($0.start))-\(Int($0.end))" }
            check(got == want, "the splitter agrees with the plan: \(secs) s in pieces of \(piece)", "\(got) vs \(want)")
        }
        var sp = WindowSplitter(rate: rate)
        let first = sp.push((0..<(50 * rate)).map { Float($0) })
        check(first.count == 1 && first[0].samples.first == 0 && first[0].samples.last == Float(50 * rate - 1), "a window holds its own samples, in order")
        let second = sp.push((50 * rate..<(98 * rate)).map { Float($0) })
        check(second.count == 1 && second[0].samples.first == Float(48 * rate), "the next window starts 2 s back")

        // Overlap: each word once.
        let a: [Word] = [w(45, 46, "one"), w(47, 48.4, "two"), w(48.6, 49.2, "three"), w(49.5, 49.98, "fou")]
        let b: [Word] = [w(48.0, 48.4, "two"), w(48.6, 49.2, "three"), w(49.5, 50.3, "four"), w(51, 52, "five")]
        let m = Overlap.merge([(0, a), (48, b)])
        check(texts(m) == "one two three four five", "the overlap keeps every word once, the whole one at the edge", texts(m))
        let straddle = Overlap.merge([(0, [w(48.7, 49.1, "same")]), (48, [w(48.9, 49.3, "Same,")])])
        check(texts(straddle) == "same", "a word both windows heard across the middle is kept once", texts(straddle))
        let twice = Overlap.merge([(0, [w(10, 11, "no"), w(48.5, 48.9, "no")]), (48, [w(49.2, 49.6, "no")])])
        check(twice.count == 3, "a word really said twice stays twice", texts(twice))
        check(Overlap.merge([]).isEmpty && Overlap.merge([(0, []), (48, [])]).isEmpty, "silent windows give no words")
        let skip = Overlap.merge([(0, [w(1, 2, "a")]), (48, []), (96, [w(97, 98, "b")])])
        check(texts(skip) == "a b", "a skipped window in the middle loses nothing around it", texts(skip))

        // Utterances.
        let words = [w(0, 0.4, "Hello"), w(0.5, 0.9, "there."), w(1.0, 1.3, "Next"), w(1.4, 1.8, "one"),
                     w(4.0, 4.3, "after"), w(4.4, 4.8, "pause")]
        let u = Utterances.group(words, speaker: .me)
        check(u.map { $0.text } == ["Hello there.", "Next one", "after pause"], "a line ends at a full stop and at a pause", "\(u.map { $0.text })")
        check(u.first.map { $0.start == 0 && $0.end == 0.9 && $0.speaker == .me } == true, "a line spans its words and keeps the speaker")
        let marks = Utterances.group([w(0, 0.5, "transportadora"), w(0.5, 0.6, " ."), w(0.7, 1, "Next")], speaker: .others)
        check(marks.map { $0.text } == ["transportadora.", "Next"], "a bare full stop sticks to its word and still ends the line", "\(marks.map { $0.text })")
        let run = (0..<40).map { w(Double($0) * 0.5, Double($0) * 0.5 + 0.4, "w\($0)") }
        check(Utterances.group(run, speaker: .others).allSatisfy { $0.end - $0.start <= 12 }, "no line runs past 12 s")
        check(Utterances.group([w(0, 1, " "), w(1, 2, "")], speaker: .me).isEmpty && Utterances.group([], speaker: .me).isEmpty,
              "blank words and no words make no line")

        // A recognizer that starts over after each pause, and one that repeats everything.
        let u1 = [w(0, 0.5, "Good"), w(0.6, 1, "morning.")], u2 = [w(3, 3.4, "Thanks.")]
        check(texts(Utterances.accumulate(Utterances.accumulate([], u1), u2)) == "Good morning. Thanks.", "utterances reported one by one are joined")
        check(texts(Utterances.accumulate(u1, u1 + u2)) == "Good morning. Thanks.", "a cumulative report adds only what is new")
        check(texts(Utterances.accumulate(u1 + u2, u2)) == "Good morning. Thanks.", "the final repeat of the last utterance is not added twice")

        // The merge of the two tracks.
        let others = [seg(0, 2, .others, "hi"), seg(5, 6, .others, "so")]
        let me = [seg(1, 3, .me, "hello"), seg(5, 7, .me, "yes")]
        let mg = Transcript.merge([others, me])
        check(mg.map { $0.text } == ["hi", "hello", "so", "yes"], "the tracks interleave by start time; a tie keeps the track order", "\(mg.map { $0.text })")
        check(Transcript.merge([[], []]).isEmpty && Transcript.merge([]).isEmpty, "two silent tracks merge to nothing")
        check(Transcript.merge([others]).map { $0.text } == ["hi", "so"], "class mode: one track merges to itself")

        // Silence.
        check(Silence.isSilent([Float](repeating: 0, count: 16000), rate: 16000), "digital silence is silent")
        check(Silence.isSilent([], rate: 16000) && Silence.peakDB([], rate: 16000) == -200, "no samples is silent")
        let quiet = (0..<16000).map { Float(0.001 * sin(Double($0) / 5)) }
        check(Silence.isSilent(quiet, rate: 16000), "a -63 dB hum is silent", "\(Silence.peakDB(quiet, rate: 16000))")
        var blip = [Float](repeating: 0, count: 32000)
        for i in 16000..<17600 { blip[i] = Float(0.1 * sin(Double(i) / 3)) }
        check(!Silence.isSilent(blip, rate: 16000), "a tenth of a second of voice in silence is not silent", "\(Silence.peakDB(blip, rate: 16000))")

        // Exports.
        check(Export.clock(0) == "00:00:00" && Export.clock(59.99) == "00:00:59" && Export.clock(3661.5) == "01:01:01", "clock rounds down")
        check(Export.clock(-3) == "00:00:00" && Export.clock(36000) == "10:00:00", "clock: negative is zero, ten hours fit")
        check(Export.srtTime(0) == "00:00:00,000" && Export.srtTime(1.2346) == "00:00:01,235" && Export.srtTime(3725.007) == "01:02:05,007",
              "SRT time has a comma and three digits of milliseconds", Export.srtTime(1.2346))
        check(Export.srtTime(59.9996) == "00:01:00,000", "SRT milliseconds carry into the second", Export.srtTime(59.9996))

        let segs = [seg(3.2, 5, .others, "Good  morning,\neveryone."), seg(6, 6, .me, "Hi."), seg(70, 71, .others, "  ")]
        check(Export.txt(segs) == "[00:00:03] Others: Good morning, everyone.\n[00:00:06] Me: Hi.\n", "txt: one line each, blank text dropped", Export.txt(segs))
        let srt = Export.srt(segs)
        check(srt == "1\n00:00:03,200 --> 00:00:05,000\nOthers: Good morning, everyone.\n\n2\n00:00:06,000 --> 00:00:06,500\nMe: Hi.\n\n",
              "srt: numbered from 1, a cue lasts at least half a second", srt)
        let md = Export.md(segs, title: "2026-10-05_14-00 Weekly", language: "en-US")
        check(md.hasPrefix("# 2026-10-05_14-00 Weekly\n") && md.contains("**[00:00:03] Others:** Good morning, everyone.\n\n**[00:00:06] Me:** Hi.\n"),
              "md: a title and one paragraph per line", md)
        check(Export.txt([]) == "(no speech found)\n" && Export.srt([]) == "" && Export.md([], title: "x", language: "pt-BR").contains("_(no speech found)_"),
              "no speech: says so in txt and md, an empty srt")

        // Where the files go, and what they never replace.
        check(Export.outputs(for: "/r/2026-10-05_14-00 Weekly.mov") == ["/r/2026-10-05_14-00 Weekly.txt", "/r/2026-10-05_14-00 Weekly.srt", "/r/2026-10-05_14-00 Weekly.md"],
              "the transcript sits next to the recording, same name")
        let dir = NSTemporaryDirectory() + "ipsio-transcribe-test-\(getpid())"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let mov = dir + "/2026-10-05_14-00 Weekly.mov"
        FileManager.default.createFile(atPath: mov, contents: Data("video".utf8))
        FileManager.default.createFile(atPath: mov + ".sha256", contents: Data("sum  2026-10-05_14-00 Weekly.mov\n".utf8))
        FileManager.default.createFile(atPath: dir + "/2026-10-05_14-00 Weekly.txt", contents: Data("old".utf8))
        let written = (try? Export.write(segs, media: mov, language: "en-US")) ?? []
        check(written.count == 3 && written.allSatisfy { FileManager.default.fileExists(atPath: $0) }, "three files written", "\(written)")
        check((try? String(contentsOfFile: dir + "/2026-10-05_14-00 Weekly.txt", encoding: .utf8)) == Export.txt(segs), "an old transcript is replaced")
        check((try? String(contentsOfFile: mov, encoding: .utf8)) == "video" &&
              (try? String(contentsOfFile: mov + ".sha256", encoding: .utf8)) == "sum  2026-10-05_14-00 Weekly.mov\n",
              "the recording and its .sha256 are untouched")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        check(!left.contains { $0.hasSuffix(".tmp") } && left.count == 5, "no temporary file left behind", "\(left.sorted())")
        var refused = false
        do { try Export.write(segs, media: dir + "/notes.txt", language: "en-US") } catch { refused = true }
        check(refused && !FileManager.default.fileExists(atPath: dir + "/notes.srt"), "a source named .txt is refused before anything is written")
        refused = false
        do { try Export.write(segs, media: dir + "/x.mov.sha256", language: "en-US") } catch { refused = true }
        check(refused, "an evidence file as the source is refused")
        try? FileManager.default.removeItem(atPath: dir)

        // Echo: the microphone hearing the speakers.
        let heard = Segment(start: 4, end: 8, speaker: .others, text: "Teste grava é o numeral normal quality normal.")
        let echo = Segment(start: 4.2, end: 8.1, speaker: .me, text: "Testic grava é o numeral normal quality normal.")
        let reply = Segment(start: 8.5, end: 10, speaker: .me, text: "Sim, concordo com isso.")
        let later = Segment(start: 30, end: 34, speaker: .me, text: "grava é o numeral normal quality normal")
        let e = Transcript.dropEcho([heard, echo, reply, later])
        check(!e.contains(echo), "the microphone's echo of the others is dropped")
        check(e.contains(heard), "the others' line is never dropped")
        check(e.contains(reply), "a reply in other words, right after, is kept")
        check(e.contains(later), "the same words far from the others' line are kept")
        let half = Segment(start: 4, end: 8, speaker: .me, text: "teste grava outra coisa bem diferente aqui agora")
        check(Transcript.dropEcho([heard, half]).contains(half), "a line sharing only a few words is kept")
        check(Transcript.dropEcho([echo]) == [echo], "with no others' line nothing is dropped")
        let othersOnly = Segment(start: 4.2, end: 8.1, speaker: .others, text: echo.text)
        check(Transcript.dropEcho([heard, othersOnly]).count == 2, "two others' lines are both kept")
        let accented = Segment(start: 20, end: 23, speaker: .others, text: "Já está pronto o orçamento?")
        let flat = Segment(start: 20.3, end: 23.2, speaker: .me, text: "ja esta pronto o orcamento")
        check(!Transcript.dropEcho([accented, flat]).contains(flat), "the echo is caught when one track drops the accents")

        print("\n\(total - fails)/\(total) ok")
        exit(fails == 0 ? 0 : 1)
    }
}
