// Backend.swift: the native engine behind the app's run("start"), run("stop")...
// It answers in the exact format ipsio.sh answers (title line, human body,
// "#state key=value ... file=" last), so the app's alarm, calendar and setup
// window read the same keys whichever engine records.
//
// Everything that touches the Mac comes in through Host and Capture, so the
// bench drives every verdict with no screen, no microphone and no permission.
//
// The recording now lives inside the app's process. Two small files in the
// state folder keep the old watchdog contract: "recording" and "recording-mode" exist while a
// recording runs and are removed by stop. Found at launch with no capture
// behind them, they mean the app (or the Mac) went down mid-recording: the
// fragmented .mov is still there, and stop closes the books on it.
import AVFoundation
import CoreGraphics
import Foundation
import IOKit.ps

protocol Capture: AnyObject {
    var recording: Bool { get }
    var stoppedByItself: Error? { get }
    func startAndWait(_ o: Recorder.Options, timeout: Double) -> Result<String, Recorder.Failure>
    func snapshot() -> Recorder.Snapshot?
    func stop() -> Recorder.Summary?
    /// What the last start recorded; nil when the capture cannot tell.
    var resolvedTarget: CaptureTarget.Resolved? { get }
}
extension Capture { var resolvedTarget: CaptureTarget.Resolved? { nil } }
extension Recorder: Capture {}

/// The Mac around the capture. Defaults are the real thing.
struct Host {
    var screenPermission: () -> Bool = { CGPreflightScreenCaptureAccess() }
    var microphone: () -> String? = { AVCaptureDevice.default(for: .audio)?.localizedName }
    /// GiB free, like `df -g`.
    var freeGB: (String) -> Int? = { path in
        let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage.map { Int($0 >> 30) }
    }
    var onBattery: () -> Bool = {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        return type == kIOPMBatteryPowerKey
    }
    var duration: (String) -> Double? = { p in
        let d = AVURLAsset(url: URL(fileURLWithPath: p)).duration.seconds
        return d.isFinite ? d : nil
    }
    var tracks: (String) -> (video: Int, audio: Int) = { p in
        let a = AVURLAsset(url: URL(fileURLWithPath: p))
        return (a.tracks(withMediaType: .video).count, a.tracks(withMediaType: .audio).count)
    }
    /// The test sentence, spoken by another process (our own sound is excluded
    /// from the capture). In pt, Luciana: an American voice reading Portuguese
    /// is unintelligible.
    var say: (String) -> Void = { lang in
        func run(_ args: [String]) -> Bool {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/say"); p.arguments = args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return false }
            p.waitUntilExit(); return p.terminationStatus == 0
        }
        if lang == "pt", run(["-v", "Luciana", "teste de gravação: um, dois, três, quatro, cinco"]) { return }
        _ = run([lang == "pt" ? "teste de gravação: um, dois, três, quatro, cinco" : "recording test: one, two, three, four, five"])
    }
    var sleep: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }
    /// Where the evidence and the hook run: off the caller's thread (the bench runs it in place).
    var background: (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .utility).async(execute: $0) }
    var systemLanguage: () -> String = { (Locale.preferredLanguages.first ?? "en").hasPrefix("pt") ? "pt" : "en" }
    /// Runs the POST_RECORDING hook; only the GPL build has it (the store does not run commands).
    var hook: ((String, String, String) -> Void)? = { command, file, log in
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", command + " \"$1\"", "ipsio-hook", file]
        if !FileManager.default.fileExists(atPath: log) { FileManager.default.createFile(atPath: log, contents: nil) }
        let h = FileHandle(forWritingAtPath: log); h?.seekToEndOfFile()
        let stamp = { () -> String in let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f.string(from: Date()) }
        h?.write("\(stamp()) POST_RECORDING \(file)\n".data(using: .utf8)!)
        p.standardInput = FileHandle.nullDevice; p.standardOutput = h; p.standardError = h
        var rc: Int32 = -1
        if (try? p.run()) != nil { p.waitUntilExit(); rc = p.terminationStatus }
        h?.write("\(stamp()) POST_RECORDING rc=\(rc)\n".data(using: .utf8)!)
        try? h?.close()
    }
}

final class Backend {
    let dir: String
    let capture: Capture
    var host: Host
    let conf: () -> [String: String]
    private var activity: NSObjectProtocol?
    private var recQuality: Quality?   // the preset of the recording in progress
    private let lock = NSLock()   // one command at a time, like one script run per click

    init(dir: String, capture: Capture, host: Host = Host(), conf: @escaping () -> [String: String]) {
        self.dir = dir; self.capture = capture; self.host = host; self.conf = conf
    }

    // Not "file" and "mode": the legacy ipsio.sh writes those, and a script
    // recording would read here as a crashed one (stop would close it under ffmpeg).
    var fileRec: String { dir + "/recording" }
    var modeRec: String { dir + "/recording-mode" }

    var recording: Bool { capture.recording }
    /// The helper mode's live audio (app/Helper): set to listen, nil to stop.
    var audioTap: ((Recorder.AudioTrack, CMSampleBuffer) -> Void)? {
        get { (capture as? Recorder)?.audioTap }
        set { (capture as? Recorder)?.audioTap = newValue }
    }
    /// The watchdog's signal: the system stopped the capture, or a recording
    /// of a previous run of the app was left behind with nothing capturing it.
    var diedByItself: Bool {
        if capture.recording { return capture.stoppedByItself != nil }
        return FileManager.default.fileExists(atPath: fileRec)
    }
    var whyItDied: String? {
        if let e = capture.stoppedByItself { return "\(e)" }
        if !capture.recording && FileManager.default.fileExists(atPath: fileRec) { return "the app or the Mac stopped during the recording" }
        return nil
    }
    var currentFile: String? {
        (try? String(contentsOfFile: fileRec, encoding: .utf8)).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    // ---- what the conf and the environment decide ----
    struct Settings {
        let lang: String, folder: String, title: String, mode: String, minGB: Int, hookCommand: String
        let quality: Quality, target: CaptureTarget
        let micSource: Recorder.MicSource
    }
    func settings(_ env: [String: String]) -> Settings {
        let c = conf()
        let l = c["UI_LANGUAGE"].flatMap { $0.isEmpty ? nil : $0 } ?? host.systemLanguage()
        let m = env["IPSIO_MODE"] ?? c["MODE"] ?? "class"
        let q = Quality.parse(c["VIDEO_QUALITY"])
        // A window comes only for one start (IPSIO_TARGET); the conf keeps a display.
        let target = CaptureTarget.parse(oneShot: env["IPSIO_TARGET"]) ?? CaptureTarget.parse(conf: c["CAPTURE_TARGET"])
        return Settings(lang: l == "en" ? "en" : "pt",
                        folder: c["RECORDINGS_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? (NSHomeDirectory() + "/Movies/Ipsio"),
                        title: Naming.title(env["IPSIO_TITLE"] ?? c["TITLE"] ?? ""),
                        mode: m == "meeting" ? "meeting" : "class",
                        minGB: q.minFreeGB(Int(c["MIN_FREE_GB"] ?? "") ?? 20, meeting: m == "meeting"),
                        hookCommand: c["POST_RECORDING"] ?? "",
                        quality: q, target: target,
                        micSource: Recorder.MicSource.parse(env["IPSIO_MIC"]))
    }

    /// "about 2 GB per hour" for normal, as the text always said.
    static func perHour(_ s: Settings) -> String { String(format: "%.0f", s.quality.gbPerHour(meeting: s.mode == "meeting")) }

    // ---- formatting, the script's way ----
    static func state(_ pairs: [(String, String)]) -> String {
        "#state " + pairs.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
    }
    /// ffmpeg's time=HH:MM:SS, which the menu shows.
    static func clock(_ s: Double) -> String {
        let t = max(0, Int(s)); return String(format: "%02d:%02d:%02d", t / 3600, t % 3600 / 60, t % 60)
    }
    /// The duration in the "saved" line: 1h05min, 12 min, 40 s.
    static func duration(_ s: Double) -> String {
        let t = max(0, Int(s)), h = t / 3600, m = t % 3600 / 60
        if h > 0 { return String(format: "%dh%02dmin", h, m) }
        return m > 0 ? "\(m) min" : "\(t) s"
    }
    /// `du -h`: 1024 steps, one decimal below 10, rounded up.
    static func size(_ bytes: Int64) -> String {
        var v = Double(max(0, bytes)) / 1024, u = 0
        let units = ["K", "M", "G", "T"]
        while v >= 1024 && u < units.count - 1 { v /= 1024; u += 1 }
        if v < 10 { return String(format: "%.1f", (v * 10).rounded(.up) / 10) + units[u] }
        return String(Int(v.rounded(.up))) + units[u]
    }
    static func fileSize(_ p: String) -> String {
        guard let n = (try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? NSNumber else { return "" }
        return size(n.int64Value)
    }
    static func dB(_ x: Float?) -> String {
        guard let x = x else { return "" }
        return x.isFinite ? String(format: "%.1f", x) : "-inf"
    }
    /// The level of the whole recording so far: the power average of the
    /// samples (what volumedetect's mean_volume measured over the file).
    static func mean(_ samples: [Float]) -> Float? {
        guard !samples.isEmpty else { return nil }
        let p = samples.reduce(0.0) { $0 + ($1.isFinite ? pow(10, Double($1) / 10) : 0) } / Double(samples.count)
        return Sound.dB(p)
    }

    /// A start that failed: the text the app shows, its arguments and the verdict.
    /// A microphone that does not open is a start that did not happen, with
    /// the reason, like any capture that did not start.
    static func failed(_ e: Recorder.Failure, folder: String) -> (key: String, args: [String], verdict: String) {
        switch e {
        case .noPermission: return ("no_permission", [], "NO_PERMISSION")
        case .noDisplay: return ("no_screen", [], "NO_SCREEN")
        case .folder: return ("folder_inaccessible", [folder], "FOLDER_INACCESSIBLE")
        case .alreadyRecording: return ("already_recording", [], "ALREADY_RECORDING")
        case .windowGone: return ("window_gone", [], "WINDOW_GONE")
        case .microphone, .start, .writer, .windowClosed: return ("did_not_start", ["\(e)"], "DID_NOT_START")
        }
    }

    // ---- the commands ----
    func run(_ cmd: String, env: [String: String] = [:]) -> String {
        lock.lock(); defer { lock.unlock() }
        let s = settings(env)
        func t(_ k: String, _ a: String...) -> String { Texts.t(k, a, lang: s.lang) }
        switch cmd {
        case "start": return start(s, t)
        case "level": return level(s, t)
        case "check": return check(s, t)
        case "stop": return stop(s, t, testTake: env["IPSIO_TEST_TAKE"] == "1")
        case "test": return test(s, env, t)
        case "doctor": return doctor(s, t)
        case "folder": return s.folder
        case "title": return s.title
        case "mode": return s.mode
        case "language": return s.lang
        case "microphone": return host.microphone() ?? ""
        case "output", "device": return ""   // nothing to give back: the sound output is never touched
        default: return "usage: start|level|check|stop|test|doctor|folder|title|mode|language|microphone"
        }
    }

    private func start(_ s: Settings, _ t: (String, String...) -> String) -> String {
        if capture.recording { return t("already_recording") + "\n" + Backend.state([("verdict", "ALREADY_RECORDING")]) }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard (try? fm.createDirectory(atPath: s.folder, withIntermediateDirectories: true)) != nil else {
            return t("folder_inaccessible", s.folder) + "\n" + Backend.state([("verdict", "FOLDER_INACCESSIBLE")])
        }
        let free = host.freeGB(s.folder)
        if let f = free, f < s.minGB {
            return t("disk_full", String(f), s.folder, String(s.minGB), Backend.perHour(s)) + "\n" + Backend.state([("verdict", "DISK_FULL"), ("free_gb", String(f))])
        }
        guard host.screenPermission() else { return t("no_permission") + "\n" + Backend.state([("verdict", "NO_PERMISSION")]) }
        let meeting = s.mode == "meeting"
        let micName = meeting ? host.microphone() : nil
        if meeting && micName == nil { return t("no_microphone") + "\n" + Backend.state([("verdict", "NO_MICROPHONE")]) }
        let battery = host.onBattery()
        var o = Recorder.Options(folder: s.folder); o.title = s.title; o.meeting = meeting
        o.fps = s.quality.fps; o.videoBitrate = s.quality.videoBitrate; o.target = s.target
        o.micSource = s.micSource
        let path: String
        switch capture.startAndWait(o, timeout: 30) {
        case .success(let p): path = p
        case .failure(let e):
            let f = Backend.failed(e, folder: s.folder)
            return Texts.t(f.key, f.args, lang: s.lang) + "\n" + Backend.state([("verdict", f.verdict)])
        }
        recQuality = s.quality
        try? (path + "\n").write(toFile: fileRec, atomically: true, encoding: .utf8)
        try? (s.mode + "\n").write(toFile: modeRec, atomically: true, encoding: .utf8)
        // caffeinate -dimsu: the display too, or ScreenCaptureKit stops with it.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled, .suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "Ipsio is recording")
        var micOk = true
        if meeting {
            // Up to 4 s for the first microphone sample. Dead does NOT stop the
            // recording (the others are coming in), but the verdict says so.
            // No sample at all also counts as dead: a silent meter is no proof
            // of a live microphone (fail closed).
            var mic: [Float] = []
            for _ in 0..<8 { mic = capture.snapshot()?.mic ?? []; if !mic.isEmpty { break }; host.sleep(0.5) }
            micOk = !mic.isEmpty && !mic.allSatisfy { Sound.below($0, Sound.micDeadDB) }
        }
        let name = (path as NSString).lastPathComponent
        var out: [String] = []
        if !micOk { out.append(t("microphone_dead_start", name, micName ?? "")) }
        else if meeting { out.append(t("recording_meeting", name, micName ?? "")) }
        else { out.append(t("recording", name)) }
        if battery { out.append(t("battery_warning")) }
        let target: String
        switch capture.resolvedTarget {
        case .display(_, fellBack: true)?: target = "main_fallback"; out.append(t("display_gone"))
        case .window?: target = "window"
        default:
            switch s.target { case .main: target = "main"; case .display: target = "display"; case .window: target = "window" }
        }
        out.append("")
        out.append(t("detail", t("detail_start", free.map(String.init) ?? "?", s.mode)))
        out.append(Backend.state([("verdict", "RECORDING"), ("mode", s.mode), ("microphone", micOk ? "OK" : "DEAD"),
                                  ("battery", battery ? "1" : "0"), ("quality", s.quality.rawValue), ("target", target), ("file", path)]))
        return out.joined(separator: "\n")
    }

    private func level(_ s: Settings, _ t: (String, String...) -> String) -> String {
        guard let snap = capture.snapshot() else { return t("not_recording") + "\n" + Backend.state([("verdict", "NOT_RECORDING")]) }
        let mode = snap.mic != nil ? "meeting" : "class"
        let time = Backend.clock(snap.seconds), size = Backend.fileSize(snap.file)
        let free = host.freeGB(s.folder), hours = (recQuality ?? s.quality).hoursLeft(freeGB: free ?? 0, meeting: mode == "meeting")
        let l = snap.level
        var st: [(String, String)] = [("verdict", l.verdict), ("mode", mode), ("silence", String(l.silence)),
                                       ("time", time), ("size", size), ("disk_h", String(hours))]
        if let ms = l.micSilence { st += [("mic", Backend.dB(snap.mic?.last)), ("mic_silence", String(ms))] }
        var out: [String] = []
        switch l.verdict {
        case "MEASURING": out += [t("measuring"), "", t("detail", t("recorded", time, size))]
        case "NO_SOUND" where snap.meterAge > Sound.staleSeconds:
            // The meter itself went quiet (no buffers at all), not the room.
            out += [t("meter_stalled", String(l.silence)), "", t("detail", t("recorded", time, size))]
        default:
            out.append(t(["NO_SOUND": "no_sound", "LOW": "sound_low", "LOUD": "sound_loud"][l.verdict] ?? "sound_ok"))
            if l.silence > 0 { out.append(t("silent_for", String(l.silence))) }
            if let ms = l.micSilence, ms > 0 { out.append(t("microphone_dead", String(ms))) }
            out.append("")
            out.append(t("detail", t("detail_level", Backend.dB(snap.system.last), time, size, free.map(String.init) ?? "?", String(hours))))
            if l.micSilence != nil { out.append(t("detail", t("detail_mic", Backend.dB(snap.mic?.last)))) }
        }
        out.append(Backend.state(st))
        return out.joined(separator: "\n")
    }

    private func check(_ s: Settings, _ t: (String, String...) -> String) -> String {
        guard let snap = capture.snapshot() else { return t("not_recording") + "\n" + Backend.state([("verdict", "NOT_RECORDING")]) }
        guard let mean = Backend.mean(snap.system) else { return t("too_early") + "\n" + Backend.state([("verdict", "TOO_EARLY")]) }
        let peak = snap.system.max()
        let v = Sound.classify(mean)
        let key = ["NO_SOUND": "no_sound", "LOW": "sound_low", "LOUD": "sound_loud"][v.rawValue] ?? "sound_ok"
        return [t(key), "", t("detail", t("detail_check", Backend.dB(mean), Backend.dB(peak), Backend.clock(snap.seconds), Backend.fileSize(snap.file))),
                Backend.state([("verdict", v.rawValue), ("mean", Backend.dB(mean)), ("peak", Backend.dB(peak))])].joined(separator: "\n")
    }

    private func stop(_ s: Settings, _ t: (String, String...) -> String, testTake: Bool) -> String {
        let fm = FileManager.default
        let left = currentFile
        let sum = capture.stop()
        recQuality = nil
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        // Forget the file once it is dealt with: a second stop must not save it
        // again nor run the hook on it twice.
        defer { try? fm.removeItem(atPath: fileRec); try? fm.removeItem(atPath: modeRec) }
        let path: String, seconds: Double, complete: Bool
        var soundLine: String, title: String, stateExtra: [(String, String)]
        if let r = sum {
            guard fm.fileExists(atPath: r.file) else {
                return t("nothing_recorded") + "\n" + Backend.state([("verdict", "NOTHING_RECORDED")])
            }
            path = r.file; seconds = r.seconds; complete = r.complete
            switch r.sound {
            case .silent: soundLine = t("sum_silent", String(r.silencePct)); title = "saved_silent"
            case .gaps: soundLine = t("sum_gaps", String(100 - r.silencePct), String(format: "%.0f", r.average)); title = "saved_gaps"
            case .low: soundLine = t("sum_low", String(format: "%.0f", r.average)); title = "saved"
            case .ok: soundLine = t("sum_ok", String(format: "%.0f", r.average), String(r.silencePct)); title = "saved"
            case .noMeasure: soundLine = t("no_measure"); title = "saved"
            }
            stateExtra = [("sound", r.sound.rawValue), ("silence_pct", String(r.silencePct)), ("mean", String(format: "%.1f", r.average))]
            if let m = r.mic {
                if m == .dead { soundLine += ", " + t("mic_sum_dead", String(r.micDeadPct ?? 0)); if title == "saved" { title = "saved_mic_dead" } }
                else if m == .ok { soundLine += ", " + t("mic_sum_ok") }
                stateExtra.append(("microphone", m.rawValue))
            }
        } else if let a = left, fm.fileExists(atPath: a) {
            // Left by a previous run that went down mid-recording: the meter
            // died with it, the fragments did not.
            path = a; seconds = host.duration(a) ?? 0; complete = seconds > 0
            soundLine = t("no_measure"); title = "saved"
            stateExtra = [("sound", "NO_MEASURE"), ("silence_pct", "0"), ("mean", "-99.0")]
        } else {
            return t("was_not_recording") + "\n" + Backend.state([("verdict", "NOT_RECORDING")])
        }
        let name = (path as NSString).lastPathComponent, size = Backend.fileSize(path)
        if !complete || seconds <= 0 {
            return [t("does_not_open", name, size), "", Backend.state([("verdict", "DOES_NOT_OPEN"), ("file", path)])].joined(separator: "\n")
        }
        if !testTake { afterSave(path, s) }
        let dur = Backend.duration(seconds)
        return [t(title), t("saved_body", name, dur, size, soundLine, (path as NSString).deletingLastPathComponent), "",
                t("detail", t("detail_stop", String(sum?.dropped ?? 0))),
                Backend.state([("verdict", "SAVED")] + stateExtra + [("duration", dur), ("file", path)])].joined(separator: "\n")
    }

    /// In the background: the .sha256 next to the file (evidence that it was
    /// not changed afterwards), then the POST_RECORDING hook. A failing hook
    /// never touches the video.
    private func afterSave(_ path: String, _ s: Settings) {
        let hook = host.hook, cmd = s.hookCommand, log = dir + "/post-recording.log"
        host.background {
            Evidence.write(for: path)
            if let h = hook, !cmd.isEmpty { h(cmd, path, log) }
        }
    }

    private func test(_ s: Settings, _ env: [String: String], _ t: (String, String...) -> String) -> String {
        if capture.recording { return t("already_recording") + "\n" + Backend.state([("verdict", "ALREADY_RECORDING")]) }
        var e = env; e["IPSIO_TITLE"] = "test"
        let st = start(settings(e), t)
        guard st.contains("#state verdict=RECORDING") else { return st }
        let micName = host.microphone() ?? ""
        host.sleep(2); host.say(s.lang); host.sleep(3)
        let snap = capture.snapshot()
        let file = snap?.file ?? currentFile ?? ""
        _ = stop(s, t, testTake: true)
        let tr = host.tracks(file)
        try? FileManager.default.removeItem(atPath: file)
        guard tr.video > 0 else { return t("test_no_video") + "\n" + Backend.state([("verdict", "TEST_NO_VIDEO")]) }
        let mean = Backend.mean(snap?.system ?? [])
        if Sound.classify(mean) == .noSound { return t("test_no_sound") + "\n" + Backend.state([("verdict", "TEST_NO_SOUND")]) }
        if s.mode == "meeting" {
            let mic = Backend.mean(snap?.mic ?? [])
            if mic.map({ Sound.below($0, Sound.micDeadDB) }) ?? true {
                return t("test_no_microphone", micName) + "\n" + Backend.state([("verdict", "TEST_NO_MICROPHONE"), ("mean", Backend.dB(mean)), ("mic", Backend.dB(mic))])
            }
            return [t("test_ok_meeting", micName), "", t("detail", t("detail_test_mic", Backend.dB(mean), Backend.dB(mic))),
                    Backend.state([("verdict", "TEST_OK"), ("mode", "meeting"), ("mean", Backend.dB(mean)), ("mic", Backend.dB(mic))])].joined(separator: "\n")
        }
        return [t("test_ok"), "", t("detail", t("detail_test", Backend.dB(mean))),
                Backend.state([("verdict", "TEST_OK"), ("mode", "class"), ("mean", Backend.dB(mean))])].joined(separator: "\n")
    }

    /// Checks everything WITHOUT recording and without stopping at the first
    /// problem. The #state line names every item by key (missing=a,b ok=c,d):
    /// the setup window draws its checklist from it. The calendar is optional.
    private func doctor(_ s: Settings, _ t: (String, String...) -> String) -> String {
        var miss: [String] = [], ok: [String] = [], lines: [String] = []
        func bad(_ k: String, _ text: String) {
            miss.append(k); lines.append("X   " + (text.components(separatedBy: "\n").dropFirst().first ?? text))
        }
        func good(_ k: String, _ what: String) { ok.append(k); lines.append(t("doctor_item", what)) }
        let fm = FileManager.default
        if (try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil { good("dir", dir) }
        else { bad("dir", t("folder_inaccessible", dir)) }
        if host.screenPermission() { good("permission", t("screen_permission")) } else { bad("permission", t("no_permission")) }
        if s.mode == "meeting" {
            if let m = host.microphone() { good("microphone", m) } else { bad("microphone", t("no_microphone")) }
        }
        if (try? fm.createDirectory(atPath: s.folder, withIntermediateDirectories: true)) != nil {
            good("folder", s.folder)
            let free = host.freeGB(s.folder)
            if let f = free, f < s.minGB { bad("disk", t("disk_full", String(f), s.folder, String(s.minGB), Backend.perHour(s))) }
            else { good("disk", "\(free.map(String.init) ?? "?") GB") }
        } else { bad("folder", t("folder_inaccessible", s.folder)) }
        let c = conf()
        var cal: [String] = []
        if let d = try? Data(contentsOf: URL(fileURLWithPath: dir + "/calendar.url")), !d.isEmpty { cal.append("ics") }
        if let d = try? Data(contentsOf: URL(fileURLWithPath: dir + "/calendar.txt")), !d.isEmpty { cal.append("list") }
        if !(c["CALENDAR_COMMAND"] ?? "").isEmpty { cal.append("command") }
        if c["CALENDAR_MACOS"] == "1" { cal.append("macos") }
        var out = [t(miss.isEmpty ? "doctor_ok" : "doctor_incomplete"), ""] + lines
        out.append(cal.isEmpty ? t("doctor_calendar_none") : t("doctor_calendar", cal.joined(separator: ",")))
        out.append(Backend.state([("verdict", miss.isEmpty ? "SETUP_OK" : "SETUP_INCOMPLETE"), ("mode", s.mode),
                                  ("missing", miss.joined(separator: ",")), ("ok", ok.joined(separator: ",")),
                                  ("calendar", cal.isEmpty ? "none" : cal.joined(separator: ","))]))
        return out.joined(separator: "\n")
    }
}
