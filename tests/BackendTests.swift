// BackendTests.swift: the bench for app/Engine/Backend.swift, the native
// engine behind the app's run("start"), run("stop")... A fake capture and a
// fake Mac drive every verdict; the check is the output contract the app reads
// (title line, body, "#state ... file=" last) and the doctor line the setup
// window turns into its checklist.
//   swiftc -parse-as-library app/Engine/*.swift app/Setup.swift tests/BackendTests.swift -o /tmp/backend-tests && /tmp/backend-tests
// Exits 1 if any assertion fails.
import Foundation

var fails = 0, total = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    total += 1
    if ok { print("ok   \(name)") } else { fails += 1; print("FAIL \(name)"); let d = detail(); if !d.isEmpty { print("      \(d)") } }
}

/// The app's parser (Ipsio.swift parse), so the bench reads what the app reads.
func parse(_ s: String) -> (title: String, body: String, state: [String: String]) {
    var st: [String: String] = [:]
    var lines = s.components(separatedBy: CharacterSet.newlines)
    if let i = lines.lastIndex(where: { $0.hasPrefix("#state") }) {
        var rest = String(lines[i].dropFirst("#state".count))
        if let r = rest.range(of: " file=") { st["file"] = String(rest[r.upperBound...]); rest = String(rest[..<r.lowerBound]) }
        var curKey = "", value = ""
        for tok in rest.split(separator: " ", omittingEmptySubsequences: false) {
            if let eq = tok.firstIndex(of: "="), tok[..<eq].allSatisfy({ $0.isLetter || $0 == "_" }), !tok[..<eq].isEmpty {
                if !curKey.isEmpty { st[curKey] = value }
                curKey = String(tok[..<eq]); value = String(tok[tok.index(after: eq)...])
            } else { value += " " + tok }
        }
        if !curKey.isEmpty { st[curKey] = value }
        lines.remove(at: i)
    }
    return (lines.first ?? "", lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), st)
}

final class FakeCapture: Capture {
    var startResult: Result<String, Recorder.Failure>?   // nil = succeed with a real empty file
    var snap: Recorder.Snapshot?
    var summary: Recorder.Summary?
    var stoppedByItself: Error?
    var starts = 0, stops = 0
    var lastOptions: Recorder.Options?
    var resolvedTarget: CaptureTarget.Resolved?
    var recording: Bool { snap != nil }
    func startAndWait(_ o: Recorder.Options, timeout: Double) -> Result<String, Recorder.Failure> {
        starts += 1; lastOptions = o
        if let r = startResult { return r }
        let p = Naming.output(folder: o.folder, date: Date(), title: o.title)
        FileManager.default.createFile(atPath: p, contents: Data("movie".utf8))
        snap = Recorder.Snapshot(level: Level(verdict: "MEASURING", silence: 0, micSilence: o.meeting ? 0 : nil),
                                 system: [], mic: o.meeting ? micAtStart : nil, seconds: 0, meterAge: 0, file: p)
        summary = Recorder.Summary(file: p, seconds: 3725, sound: .ok, silencePct: 13, average: -24, mic: o.meeting ? .ok : nil,
                                   micDeadPct: o.meeting ? 0 : nil, complete: true, dropped: 0)
        return .success(p)
    }
    var micAtStart: [Float] = [-30, -31]
    func snapshot() -> Recorder.Snapshot? { snap }
    func stop() -> Recorder.Summary? {
        stops += 1
        guard snap != nil else { return nil }
        snap = nil; let s = summary; summary = nil; return s
    }
}

let root = NSTemporaryDirectory() + "ipsio-backend-\(getpid())"
var n = 0
/// A fresh state folder, recordings folder and fake Mac for each case.
func fixture(conf: [String: String] = [:]) -> (Backend, FakeCapture, String) {
    n += 1
    let base = "\(root)/\(n)", dir = base + "/state", folder = base + "/rec"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let cap = FakeCapture()
    var c = conf; c["RECORDINGS_DIR"] = c["RECORDINGS_DIR"] ?? folder
    if c["UI_LANGUAGE"] == nil { c["UI_LANGUAGE"] = "en" }
    var h = Host()
    h.screenPermission = { true }; h.microphone = { "Desk Mic" }; h.freeGB = { _ in 500 }; h.onBattery = { false }
    h.duration = { _ in 125 }; h.tracks = { _ in (1, 1) }; h.say = { _ in }; h.sleep = { _ in }
    h.systemLanguage = { "en" }; h.hook = nil
    h.background = { $0() }   // in place: "no evidence" is then a fact, not a race
    let constC = c
    return (Backend(dir: dir, capture: cap, host: h, conf: { constC }), cap, folder)
}
func waitFor(_ cond: () -> Bool) -> Bool {
    for _ in 0..<40 { if cond() { return true }; Thread.sleep(forTimeInterval: 0.05) }
    return cond()
}

@main
struct BackendTests {
    static func main() {
        defer { try? FileManager.default.removeItem(atPath: root) }

        // ---- texts ----
        check(Texts.fill("a %1 b %2", ["%2", "x"]) == "a %2 b x", "an argument holding %2 is not filled again")
        check(Set(Texts.en.keys) == Set(Texts.pt.keys), "pt and en have the same keys",
              "\(Set(Texts.en.keys).symmetricDifference(Set(Texts.pt.keys)))")
        check(Texts.t("mic_sum_dead", ["93"], lang: "en") == "microphone DEAD 93% of the time", "a percent sign after an argument stays")
        check(!(Texts.en.values.joined() + Texts.pt.values.joined()).contains("BlackHole"), "no text sends anyone to BlackHole")

        // ---- formatting the script's way ----
        check(Backend.clock(3725) == "01:02:05", "time= like ffmpeg's")
        check(Backend.duration(3725) == "1h02min" && Backend.duration(720) == "12 min" && Backend.duration(40) == "40 s", "duration like the script's")
        check(Backend.size(1_468_007) == "1.5M" && Backend.size(12 << 20) == "12M" && Backend.size(3 << 30) == "3.0G", "sizes like du -h",
              "\(Backend.size(1_468_007)) \(Backend.size(12 << 20)) \(Backend.size(3 << 30))")
        check(abs((Backend.mean([-20, -20]) ?? 0) + 20) < 0.01, "mean of equal samples is that sample")
        check(abs((Backend.mean([-20, -Float.infinity]) ?? 0) + 23.01) < 0.05, "mean is a power average (silence halves the power: -3 dB)")
        check(Backend.mean([]) == nil, "no samples, no mean")
        check(Sound.classify(Backend.mean([-.infinity, -.infinity])) == .noSound, "an all-silent mean is NO_SOUND")

        // ---- start ----
        do {
            let (b, cap, folder) = fixture()
            let o = parse(b.run("start"))
            check(o.state["verdict"] == "RECORDING" && o.state["mode"] == "class" && o.state["microphone"] == "OK" && o.state["battery"] == "0",
                  "start: RECORDING class, microphone OK, no battery", "\(o.state)")
            check(o.title == "RECORDING", "start: title line")
            check(o.state["file"]?.hasPrefix(folder + "/") == true && o.state["file"]?.hasSuffix(".mov") == true, "start: file= is the .mov in the folder", o.state["file"] ?? "")
            check(b.currentFile == o.state["file"], "start: the file record is written (the watchdog's contract)")
            check(b.recording && !b.diedByItself, "start: recording, not dead")
            let again = parse(b.run("start"))
            check(again.state["verdict"] == "ALREADY_RECORDING" && cap.starts == 1, "a second start refuses and does not start")
        }
        do {
            let (b, cap, _) = fixture(conf: ["UI_LANGUAGE": "pt", "TITLE": "Aula: 1/2"])
            let o = parse(b.run("start"))
            check(o.title == "GRAVANDO", "pt: the title in Portuguese", o.title)
            check(cap.lastOptions?.title == "Aula- 1-2", "the conf title, made safe for a file name", cap.lastOptions?.title ?? "")
        }
        do {
            let (b, cap, _) = fixture(conf: ["TITLE": "manual"])
            _ = b.run("start", env: ["IPSIO_TITLE": "Calendar meeting", "IPSIO_MODE": "meeting"])
            check(cap.lastOptions?.title == "Calendar meeting" && cap.lastOptions?.meeting == true, "IPSIO_TITLE and IPSIO_MODE override the conf for one recording")
        }
        do {
            let (b, cap, _) = fixture(); b.host.screenPermission = { false }
            let o = parse(b.run("start"))
            check(o.state["verdict"] == "NO_PERMISSION" && cap.starts == 0, "no screen permission: refuses before capturing")
        }
        do {
            let (b, cap, _) = fixture(conf: ["MIN_FREE_GB": "30"]); b.host.freeGB = { _ in 12 }
            let o = parse(b.run("start"))
            check(o.state["verdict"] == "DISK_FULL" && o.state["free_gb"] == "12" && cap.starts == 0, "disk below the minimum: DISK_FULL", "\(o.state)")
            check(o.body.contains("30 GB"), "the minimum from the conf is in the text")
        }
        do {
            let (b, cap, _) = fixture(conf: ["MODE": "meeting"]); b.host.microphone = { nil }
            check(parse(b.run("start")).state["verdict"] == "NO_MICROPHONE" && cap.starts == 0, "meeting with no input device: NO_MICROPHONE")
        }
        do {
            let (b, _, _) = fixture(conf: ["MODE": "class"]); b.host.microphone = { nil }
            check(parse(b.run("start")).state["verdict"] == "RECORDING", "class mode needs no microphone")
        }
        do {
            let (b, cap, _) = fixture(conf: ["MODE": "meeting"]); cap.micAtStart = [-120, -.infinity]
            let o = parse(b.run("start"))
            check(o.state["verdict"] == "RECORDING" && o.state["microphone"] == "DEAD", "meeting, microphone in digital silence: records, says DEAD")
            check(o.title == "RECORDING, BUT THE MICROPHONE IS DEAD", "dead microphone: its own title", o.title)
        }
        do {
            let (b, cap, _) = fixture(conf: ["MODE": "meeting"]); cap.micAtStart = []
            check(parse(b.run("start")).state["microphone"] == "DEAD", "meeting, no microphone sample at all: DEAD (fail closed)")
        }
        do {
            let (b, _, _) = fixture(conf: ["MODE": "meeting"])
            let o = parse(b.run("start"))
            check(o.state["microphone"] == "OK" && o.title == "RECORDING THE MEETING" && o.body.contains("Desk Mic"), "meeting, live microphone: OK and named")
        }
        do {
            let (b, _, _) = fixture(); b.host.onBattery = { true }
            let o = parse(b.run("start"))
            check(o.state["battery"] == "1" && o.body.contains("BATTERY"), "on battery: battery=1 and the warning")
        }
        for (f, v) in [(Recorder.Failure.noDisplay, "NO_SCREEN"), (.noPermission, "NO_PERMISSION"), (.folder("x"), "FOLDER_INACCESSIBLE"),
                       (.start("boom"), "DID_NOT_START"), (.writer("w"), "DID_NOT_START")] {
            let (b, cap, _) = fixture(); cap.startResult = .failure(f)
            let o = parse(b.run("start"))
            check(o.state["verdict"] == v && b.currentFile == nil, "capture failure \(f) -> \(v), no file record", "\(o.state)")
        }
        do {
            let (b, _, _) = fixture(conf: ["RECORDINGS_DIR": "/dev/null/nope"])
            check(parse(b.run("start")).state["verdict"] == "FOLDER_INACCESSIBLE", "a folder that cannot be created: FOLDER_INACCESSIBLE")
        }

        // ---- level ----
        do {
            let (b, cap, _) = fixture()
            check(parse(b.run("level")).state["verdict"] == "NOT_RECORDING", "level with nothing recording")
            _ = b.run("start")
            let m = parse(b.run("level"))
            check(m.state["verdict"] == "MEASURING" && m.state["silence"] == "0", "level: MEASURING at first", "\(m.state)")
            let f = cap.snap!.file
            cap.snap = Recorder.Snapshot(level: Level(verdict: "OK", silence: 0, micSilence: nil), system: [-22, -21], mic: nil, seconds: 65, meterAge: 1, file: f)
            let ok = parse(b.run("level"))
            check(ok.state["verdict"] == "OK" && ok.state["time"] == "00:01:05" && ok.state["disk_h"] == "277" && ok.state["mode"] == "class",
                  "level: OK with time, disk hours (free*10/18)", "\(ok.state)")
            check(ok.state["size"] == "5.0K" || ok.state["size"]?.hasSuffix("K") == true, "level: size of the file", ok.state["size"] ?? "")
            check(ok.state["mic_silence"] == nil, "class: no mic_silence key")
            cap.snap = Recorder.Snapshot(level: Level(verdict: "NO_SOUND", silence: 95, micSilence: nil), system: [-70], mic: nil, seconds: 200, meterAge: 1, file: f)
            let silent = parse(b.run("level"))
            check(silent.state["verdict"] == "NO_SOUND" && silent.state["silence"] == "95" && silent.title == "NO SOUND", "level: silence counted", "\(silent.state)")
            check(silent.body.contains("95 s"), "level: the silence in the text (the app filters it out of the alarm)")
            cap.snap = Recorder.Snapshot(level: Level(verdict: "NO_SOUND", silence: 31, micSilence: nil), system: [-22], mic: nil, seconds: 200, meterAge: 31, file: f)
            let stalled = parse(b.run("level"))
            check(stalled.state["verdict"] == "NO_SOUND" && stalled.state["silence"] == "31" && stalled.body.contains("received no sound"),
                  "level: a stalled meter is NO_SOUND with its age, and says the capture stopped", stalled.body)
        }
        do {
            let (b, cap, _) = fixture(conf: ["MODE": "meeting"])
            _ = b.run("start")
            cap.snap = Recorder.Snapshot(level: Level(verdict: "OK", silence: 0, micSilence: 120), system: [-22], mic: [-100], seconds: 200, meterAge: 1, file: cap.snap!.file)
            let o = parse(b.run("level"))
            check(o.state["mode"] == "meeting" && o.state["mic_silence"] == "120" && o.state["mic"] == "-100.0", "meeting: mic and mic_silence", "\(o.state)")
            check(o.body.contains("Microphone dead for about 120 s"), "meeting: the dead microphone in the text")
        }

        // ---- check ----
        do {
            let (b, cap, _) = fixture()
            check(parse(b.run("check")).state["verdict"] == "NOT_RECORDING", "check with nothing recording")
            _ = b.run("start")
            check(parse(b.run("check")).state["verdict"] == "TOO_EARLY", "check before the first sample: TOO_EARLY")
            cap.snap = Recorder.Snapshot(level: Level(verdict: "OK", silence: 0, micSilence: nil), system: [-40, -40], mic: nil, seconds: 9, meterAge: 1, file: cap.snap!.file)
            let o = parse(b.run("check"))
            check(o.state["verdict"] == "LOW" && o.state["mean"] == "-40.0" && o.state["peak"] == "-40.0", "check: verdict from the mean", "\(o.state)")
        }

        // ---- stop ----
        do {
            let (b, cap, folder) = fixture()
            _ = b.run("start")
            let file = cap.snap!.file
            let o = parse(b.run("stop"))
            check(o.state["verdict"] == "SAVED" && o.state["sound"] == "OK" && o.state["silence_pct"] == "13" && o.state["mean"] == "-24.0"
                  && o.state["duration"] == "1h02min" && o.state["file"] == file, "stop: SAVED with the summary", "\(o.state)")
            check(o.state["microphone"] == nil, "class: no microphone key")
            check(o.title == "RECORDING SAVED" && o.body.contains("It is in \(folder)."), "stop: title and where it is", o.body)
            check(b.currentFile == nil && !b.diedByItself, "stop: the file record is gone")
            check(waitFor { FileManager.default.fileExists(atPath: file + ".sha256") }, "stop: the .sha256 is written")
            let line = (try? String(contentsOfFile: file + ".sha256", encoding: .utf8)) ?? ""
            check(line == (Evidence.sha256(file) ?? "x") + "  " + (file as NSString).lastPathComponent + "\n", "stop: .sha256 in shasum -c format", line)
            let again = parse(b.run("stop"))
            check(again.state["verdict"] == "NOT_RECORDING", "a second stop saves nothing")
        }
        do {
            let (b, cap, _) = fixture(conf: ["MODE": "meeting"])
            _ = b.run("start")
            cap.summary = Recorder.Summary(file: cap.snap!.file, seconds: 40, sound: .ok, silencePct: 0, average: -20, mic: .dead, micDeadPct: 97, complete: true, dropped: 2)
            let o = parse(b.run("stop"))
            check(o.state["microphone"] == "DEAD" && o.title == "RECORDING SAVED, BUT YOUR MICROPHONE WAS DEAD", "stop: dead microphone in title and state", "\(o.title) \(o.state)")
            check(o.body.contains("microphone DEAD 97% of the time") && o.body.contains("2 buffers dropped") && o.state["duration"] == "40 s", "stop: dead percent, drops, seconds", o.body)
        }
        for (sound, title) in [(Sound.Summary.silent, "RECORDING SAVED, BUT SILENT"), (.gaps, "RECORDING SAVED, WITH SOUND GAPS"), (.noMeasure, "RECORDING SAVED")] {
            let (b, cap, _) = fixture()
            _ = b.run("start")
            cap.summary = Recorder.Summary(file: cap.snap!.file, seconds: 600, sound: sound, silencePct: 95, average: -30, mic: nil, micDeadPct: nil, complete: true, dropped: 0)
            let o = parse(b.run("stop"))
            check(o.title == title && o.state["sound"] == sound.rawValue, "stop: \(sound.rawValue) -> \(title)", o.title)
        }
        do {
            let (b, cap, _) = fixture()
            _ = b.run("start")
            let file = cap.snap!.file
            cap.summary = Recorder.Summary(file: file, seconds: 30, sound: .ok, silencePct: 0, average: -20, mic: nil, micDeadPct: nil, complete: false, dropped: 0)
            let o = parse(b.run("stop"))
            check(o.state["verdict"] == "DOES_NOT_OPEN" && o.state["file"] == file, "stop: a file not closed cleanly is DOES_NOT_OPEN")
            Thread.sleep(forTimeInterval: 0.2)
            check(!FileManager.default.fileExists(atPath: file + ".sha256"), "DOES_NOT_OPEN: no evidence for a broken file")
        }
        do {
            let (b, cap, _) = fixture()
            _ = b.run("start")
            try? FileManager.default.removeItem(atPath: cap.snap!.file)   // the writer deleted it: never got a frame
            let o = parse(b.run("stop"))
            check(o.state["verdict"] == "NOTHING_RECORDED" && b.currentFile == nil, "stop: no frame ever, NOTHING_RECORDED")
        }
        do {
            // The app went down mid-recording: the record is there, the capture is not.
            let (b, _, folder) = fixture()
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let orphan = folder + "/2026-10-05_10-00 Left.mov"
            FileManager.default.createFile(atPath: orphan, contents: Data("frag".utf8))
            try? (orphan + "\n").write(toFile: b.fileRec, atomically: true, encoding: .utf8)
            check(b.diedByItself && !b.recording && b.whyItDied != nil, "a record with no capture behind it: died by itself")
            let o = parse(b.run("stop"))
            check(o.state["verdict"] == "SAVED" && o.state["sound"] == "NO_MEASURE" && o.state["duration"] == "2 min" && o.state["file"] == orphan,
                  "stop after a crash: SAVED up to the last fragment, no measure", "\(o.state)")
            check(!b.diedByItself, "after that stop, the watchdog is quiet")
            check(waitFor { FileManager.default.fileExists(atPath: orphan + ".sha256") }, "the crashed recording gets its .sha256 too")
        }
        do {
            let (b, _, folder) = fixture(); b.host.duration = { _ in nil }
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let orphan = folder + "/x.mov"; FileManager.default.createFile(atPath: orphan, contents: Data())
            try? (orphan + "\n").write(toFile: b.fileRec, atomically: true, encoding: .utf8)
            check(parse(b.run("stop")).state["verdict"] == "DOES_NOT_OPEN", "a crashed recording that does not open: DOES_NOT_OPEN")
        }
        do {
            let (b, cap, _) = fixture()
            _ = b.run("start")
            struct Gone: Error {}
            cap.stoppedByItself = Gone()
            check(b.diedByItself && b.recording, "the system stopped the capture: died by itself")
        }

        // ---- the hook: GPL build only ----
        do {
            let (b, cap, _) = fixture(conf: ["POST_RECORDING": "transcribe"])
            var got: [String] = []; let g = NSLock()
            b.host.hook = { c, f, _ in g.lock(); got = [c, f]; g.unlock() }
            _ = b.run("start"); let file = cap.snap!.file
            _ = b.run("stop")
            check(waitFor { g.lock(); defer { g.unlock() }; return got == ["transcribe", file] }, "POST_RECORDING runs with the file", "\(got)")
        }
        do {
            let (b, cap, _) = fixture(conf: ["POST_RECORDING": "transcribe"])   // host.hook nil = store build
            _ = b.run("start"); let file = cap.snap!.file
            check(parse(b.run("stop")).state["verdict"] == "SAVED", "store build: no hook, still SAVED")
            check(waitFor { FileManager.default.fileExists(atPath: file + ".sha256") }, "store build: evidence still written")
        }

        // ---- test ----
        do {
            let (b, cap, _) = fixture()
            var said = ""
            b.host.say = { l in said = l; cap.snap = Recorder.Snapshot(level: Level(verdict: "OK", silence: 0, micSilence: nil), system: [-70, -25, -24], mic: nil, seconds: 5, meterAge: 0, file: cap.snap!.file) }
            let o = parse(b.run("test"))
            check(o.state["verdict"] == "TEST_OK" && o.state["mode"] == "class" && said == "en", "test: TEST_OK, sentence in the UI language", "\(o.state)")
            check(cap.lastOptions?.title == "test", "test: recorded under the title test")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: cap.lastOptions!.folder)) ?? ["?"]
            Thread.sleep(forTimeInterval: 0.2)
            check(files.isEmpty && ((try? FileManager.default.contentsOfDirectory(atPath: cap.lastOptions!.folder)) ?? ["?"]).isEmpty,
                  "test: the take is deleted, with no .sha256 and no hook", "\(files)")
            check(b.currentFile == nil && !b.recording, "test: nothing left recording")
        }
        do {
            let (b, _, _) = fixture()   // the sentence never arrives: no samples
            check(parse(b.run("test")).state["verdict"] == "TEST_NO_SOUND", "test: no sound came in")
        }
        do {
            let (b, cap, _) = fixture(); b.host.tracks = { _ in (0, 1) }
            b.host.say = { _ in cap.snap = Recorder.Snapshot(level: Level(verdict: "OK", silence: 0, micSilence: nil), system: [-25], mic: nil, seconds: 5, meterAge: 0, file: cap.snap!.file) }
            check(parse(b.run("test")).state["verdict"] == "TEST_NO_VIDEO", "test: no video track")
        }
        do {
            let (b, cap, _) = fixture(conf: ["MODE": "meeting"])
            b.host.say = { _ in cap.snap = Recorder.Snapshot(level: Level(verdict: "OK", silence: 0, micSilence: 5), system: [-25], mic: [-120, -.infinity], seconds: 5, meterAge: 0, file: cap.snap!.file) }
            let o = parse(b.run("test"))
            check(o.state["verdict"] == "TEST_NO_MICROPHONE" && o.body.contains("Desk Mic"), "test, meeting: dead microphone", "\(o.state)")
        }
        do {
            let (b, cap, _) = fixture(conf: ["MODE": "meeting"])
            b.host.say = { _ in cap.snap = Recorder.Snapshot(level: Level(verdict: "OK", silence: 0, micSilence: 0), system: [-25], mic: [-35], seconds: 5, meterAge: 0, file: cap.snap!.file) }
            let o = parse(b.run("test"))
            check(o.state["verdict"] == "TEST_OK" && o.state["mode"] == "meeting" && o.state["mic"] == "-35.0", "test, meeting: TEST_OK with the mic level", "\(o.state)")
        }
        do {
            let (b, _, _) = fixture()
            _ = b.run("start")
            check(parse(b.run("test")).state["verdict"] == "ALREADY_RECORDING", "test while recording refuses")
            check(b.recording, "and the recording goes on")
        }
        do {
            let (b, _, _) = fixture(); b.host.screenPermission = { false }
            check(parse(b.run("test")).state["verdict"] == "NO_PERMISSION", "test passes on the start refusal")
        }

        // ---- doctor, read by the setup window ----
        do {
            let (b, _, _) = fixture()
            let out = b.run("doctor")
            let st = Setup.parseState(out)
            check(st["verdict"] == "SETUP_OK" && st["missing"] == "" && st["ok"] == "dir,permission,folder,disk" && st["calendar"] == "none",
                  "doctor: SETUP_OK, items by key", "\(st)")
            let items = Setup.items(state: st, screenPermission: true, micPermission: true)
            check(Setup.complete(items), "the setup window reads the native doctor as complete")
            check(!items.contains { ["ffmpeg", "blackhole", "device", "switchaudio"].contains($0.key) }, "no BlackHole, ffmpeg or device rows")
        }
        do {
            let (b, _, _) = fixture(conf: ["MODE": "meeting", "CALENDAR_MACOS": "1"])
            b.host.screenPermission = { false }; b.host.microphone = { nil }
            let st = Setup.parseState(b.run("doctor"))
            check(st["verdict"] == "SETUP_INCOMPLETE" && st["missing"] == "permission,microphone" && st["calendar"] == "macos", "doctor: what is missing, all at once", "\(st)")
            let items = Setup.items(state: st, screenPermission: true, micPermission: true)
            check(!Setup.complete(items) && items.contains { $0.key == "screen_permission" && !$0.ok } && items.contains { $0.key == "microphone" && !$0.ok },
                  "the window shows the screen permission and the microphone red")
        }
        do {
            let (b, _, _) = fixture(conf: ["MIN_FREE_GB": "50"]); b.host.freeGB = { _ in 10 }
            let out = b.run("doctor")
            check(Setup.parseState(out)["missing"] == "disk" && out.contains("X   Only 10 GB free"), "doctor: a full disk, with the reason", out)
        }

        // ---- quality and target ----
        do {
            let (b, cap, _) = fixture()
            let o = parse(b.run("start"))
            check(cap.lastOptions?.fps == 12 && cap.lastOptions?.videoBitrate == 4_000_000 && cap.lastOptions?.target == .main,
                  "no VIDEO_QUALITY, no CAPTURE_TARGET: 12 fps, 4 Mb/s, main screen, as always")
            check(o.state["quality"] == "normal" && o.state["target"] == "main" && o.state["file"]?.hasSuffix(".mov") == true,
                  "start: quality= and target= before file=", "\(o.state)")
        }
        do {
            let (b, cap, _) = fixture(conf: ["VIDEO_QUALITY": "high"])
            let o = parse(b.run("start"))
            check(cap.lastOptions?.fps == 24 && cap.lastOptions?.videoBitrate == 8_000_000 && o.state["quality"] == "high", "VIDEO_QUALITY=high reaches the capture")
            let f = cap.snap!.file
            cap.snap = Recorder.Snapshot(level: Level(verdict: "OK", silence: 0, micSilence: nil), system: [-22], mic: nil, seconds: 65, meterAge: 1, file: f)
            let l = parse(b.run("level"))
            check(l.state["disk_h"] == String(Quality.high.hoursLeft(freeGB: 500, meeting: false)) && (Int(l.state["disk_h"] ?? "") ?? 999) < 277,
                  "level: the hours left follow the preset", "\(l.state)")
        }
        do {
            let (b, cap, _) = fixture(conf: ["VIDEO_QUALITY": "ultra"])
            _ = b.run("start")
            check(cap.lastOptions?.fps == 12 && cap.lastOptions?.videoBitrate == 4_000_000, "an unknown VIDEO_QUALITY records normal")
        }
        do {
            let (b, cap, _) = fixture(conf: ["VIDEO_QUALITY": "high"]); b.host.freeGB = { _ in 30 }
            let o = parse(b.run("start"))
            check(o.state["verdict"] == "DISK_FULL" && cap.starts == 0 && o.body.contains("40 GB") && o.body.contains("about 4 GB per hour"),
                  "high: the default minimum doubles (40 GB), the text says 4 GB per hour", o.body)
            let d = b.run("doctor")
            check(Setup.parseState(d)["missing"] == "disk", "doctor: the same scaled minimum", d)
        }
        do {
            let (b, _, _) = fixture(conf: ["VIDEO_QUALITY": "economy"]); b.host.freeGB = { _ in 12 }
            check(parse(b.run("start")).state["verdict"] == "RECORDING", "economy: 12 GB is enough (minimum 11)")
        }
        do {
            let (b, _, _) = fixture(); b.host.freeGB = { _ in 19 }
            let o = parse(b.run("start"))
            check(o.state["verdict"] == "DISK_FULL" && o.body.contains("20 GB") && o.body.contains("about 2 GB per hour"), "normal: minimum 20, 2 GB per hour, as before", o.body)
        }
        do {
            let (b, cap, _) = fixture(conf: ["CAPTURE_TARGET": "display:5"])
            let o = parse(b.run("start"))
            check(cap.lastOptions?.target == .display(5) && o.state["target"] == "display", "CAPTURE_TARGET=display:5 reaches the capture", "\(o.state)")
        }
        do {
            let (b, cap, _) = fixture(conf: ["CAPTURE_TARGET": "display:5"])
            _ = b.run("start", env: ["IPSIO_TARGET": "window:7"])
            check(cap.lastOptions?.target == .window(7), "IPSIO_TARGET=window:7 overrides the conf for one start")
            _ = b.run("stop"); _ = b.run("start")
            check(cap.lastOptions?.target == .display(5), "the next start without it: the conf's display again")
        }
        do {
            let (b, cap, _) = fixture(conf: ["CAPTURE_TARGET": "window:7"])
            _ = b.run("start")
            check(cap.lastOptions?.target == .main, "a window in the conf is not honored: main")
        }
        do {
            let (b, cap, _) = fixture(); cap.startResult = .failure(.windowGone)
            let o = parse(b.run("start", env: ["IPSIO_TARGET": "window:7"]))
            check(o.state["verdict"] == "WINDOW_GONE" && o.title == "THE WINDOW IS GONE" && b.currentFile == nil && !b.recording,
                  "the chosen window is gone: WINDOW_GONE, nothing recorded", "\(o.state)")
        }
        do {
            let (b, cap, _) = fixture(conf: ["CAPTURE_TARGET": "display:9"]); cap.resolvedTarget = .display(1, fellBack: true)
            let o = parse(b.run("start"))
            check(o.state["verdict"] == "RECORDING" && o.state["target"] == "main_fallback" && o.body.contains("not connected"),
                  "a display gone: records main, says so", o.body)
        }
        do {
            let (b, cap, _) = fixture()
            _ = b.run("start", env: ["IPSIO_TARGET": "window:7"])
            cap.stoppedByItself = Recorder.Failure.windowClosed("gone")
            check(b.diedByItself && (b.whyItDied ?? "").contains("window was closed"), "the recorded window closes: the watchdog's signal, with the reason")
            let o = parse(b.run("stop"))
            check(o.state["verdict"] == "SAVED", "and stop saves it like any system stop", "\(o.state)")
        }

        // ---- the small commands ----
        do {
            let (b, _, folder) = fixture(conf: ["UI_LANGUAGE": "pt", "MODE": "meeting"])
            check(b.run("folder") == folder && b.run("mode") == "meeting" && b.run("language") == "pt" && b.run("microphone") == "Desk Mic",
                  "folder, mode, language, microphone")
            check(b.run("output") == "" && b.run("device") == "", "output and device: nothing to give back")
        }

        print("\n\(total - fails)/\(total) ok")
        exit(fails == 0 ? 0 : 1)
    }
}
