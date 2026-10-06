// HelperCLI.swift: ipsio-helper, the helper mode end to end from Terminal.
// Records in meeting mode through the app's backend, with the live
// transcriber on Backend.audioTap and the on-device brain, for N seconds;
// prints each live line and each tip as it comes, then stops and writes
// "<name>.helper.md" next to the recording, as HelperController does.
//   ipsio-helper [seconds=90] [pt|en] [--engine auto|analyzer|legacy]
// The state folder is IPSIO_DIR, else the current directory (never ~/.ipsio);
// its conf (KEY='value') says RECORDINGS_DIR. Build, with an Info.plist for
// the Speech permission (see tools/TranscribeCLI.swift):
//   printf '%s' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>app.ipsio.helper-cli</string><key>NSSpeechRecognitionUsageDescription</key><string>Transcribes the meeting live on this Mac.</string><key>NSMicrophoneUsageDescription</key><string>Records the microphone.</string></dict></plist>' > /tmp/ipsio-helper.plist
//   swiftc -O -parse-as-library app/Engine/*.swift app/Transcribe/*.swift app/Helper/HelperCore.swift app/Helper/HelperLocal.swift \
//     app/Helper/LiveTranscriber.swift tools/HelperCLI.swift -o /tmp/ipsio-helper \
//     -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker /tmp/ipsio-helper.plist
import CoreMedia
import Foundation

@main
struct HelperCLI {
    static func conf(_ dir: String) -> [String: String] {
        var d: [String: String] = [:]
        for l in ((try? String(contentsOfFile: dir + "/conf", encoding: .utf8)) ?? "").components(separatedBy: .newlines) {
            guard let i = l.firstIndex(of: "="), !l.hasPrefix("#") else { continue }
            var v = String(l[l.index(after: i)...]).trimmingCharacters(in: .whitespaces)
            if v.count >= 2, let f = v.first, f == "'" || f == "\"", v.last == f { v = String(v.dropFirst().dropLast()) }
            d[String(l[..<i]).trimmingCharacters(in: .whitespaces)] = v
        }
        return d
    }

    static let t0 = Date()
    static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.S"; return f }()
    static func now() -> Double { Date().timeIntervalSince(t0) }
    static func log(_ s: String) {
        let now = Date()
        print(String(format: "[%6.1fs %@] ", now.timeIntervalSince(t0), fmt.string(from: now)) + s); fflush(stdout)
    }

    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        var engine = TranscribeEngine.auto
        if let i = args.firstIndex(of: "--engine"), i + 1 < args.count, let e = TranscribeEngine(rawValue: args[i + 1]) {
            engine = e; args.removeSubrange(i...i + 1)
        }
        let seconds = args.first.flatMap(Double.init) ?? 90
        let lang = args.count > 1 ? args[1] : "pt"
        let dir = ProcessInfo.processInfo.environment["IPSIO_DIR"] ?? FileManager.default.currentDirectoryPath
        let b = Backend(dir: dir, capture: Recorder(), conf: { conf(dir) })
        log("pid \(getpid()), state \(dir), \(Int(seconds)) s, \(lang)")

        let why = LocalModel.unavailableReason()
        log("on-device model: " + (why ?? "available"))
        let brain: HelperBrain? = why == nil ? LocalBrain() : nil

        let live: LiveTranscriber
        do { live = try LiveTranscriber(language: lang, engine: engine, clock: { Date().timeIntervalSinceReferenceDate }) }
        catch { log("no live transcription: \(error)"); exit(1) }
        log("live engine: \(live.engine)")

        // The state lives on one queue, as on the app's main thread.
        let sq = DispatchQueue(label: "ipsio.helper-cli.state")
        var state = HelperState(lang: lang)
        var lastPartial: [Speaker: Double] = [:]
        live.onLine = { who, text, final in
            sq.async {
                if final {
                    let before = state.window.count
                    state.hear(who, text, final: true, at: now())
                    let kept = state.window.count > before
                    log("\(kept ? "LINE" : "ECHO dropped") \(who.rawValue): \(text)")
                    lastPartial[who] = nil
                } else {
                    if lastPartial[who] == nil { log("partial \(who.rawValue) begins: \(HelperText.clip(text, 60))") }
                    lastPartial[who] = now()
                    state.hear(who, text, final: false, at: now())
                }
            }
        }
        live.onEvent = { e in log("live: " + e) }
        live.onSound = { who, dB in sq.async { state.sound(who, dB: dB, at: now()) } }
        // Buffers per track, and the format of the first one, for the report.
        var counts: [String: Int] = [:]
        let cq = DispatchQueue(label: "ipsio.helper-cli.count")
        var tipLatencies: [Double] = []

        live.start()
        let env = ["IPSIO_MODE": "meeting", "IPSIO_TITLE": "helper e2e"]
        let st = b.run("start", env: env)
        print(st); fflush(stdout)
        guard st.contains("verdict=RECORDING"), let media = b.currentFile else { live.stop(); exit(1) }
        b.audioTap = { track, sb in
            cq.async {
                let k = track == .mic ? "mic" : "system"
                if counts[k] == nil, let f = CMSampleBufferGetFormatDescription(sb), let a = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee {
                    log("first \(k) buffer: \(a.mSampleRate) Hz, \(a.mChannelsPerFrame) ch, flags \(a.mFormatFlags), \(a.mBitsPerChannel) bit, \(CMSampleBufferGetNumSamples(sb)) frames")
                }
                counts[k, default: 0] += 1
            }
            live.feed(track, sb)
        }

        // The controller's tick: ask the brain when the cadence says so.
        let timer = DispatchSource.makeTimerSource(queue: sq)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler {
            guard let br = brain else { return }
            let n = now()
            guard state.shouldAsk(now: n) else { return }
            let heard = state.othersLastHeard ?? n
            let req = state.beginAsk(now: n, research: false, small: true)
            log("ASK #\(state.asked) (others quiet since \(String(format: "%.1f", n - heard)) s, prompt \(req.prompt.count) chars)")
            Task {
                let r: Result<BrainReply, Error>
                do { r = .success(try await br.reply(to: req)) } catch { r = .failure(error) }
                sq.async {
                    let fresh = state.finishAsk(r, now: now())
                    let lat = now() - heard
                    switch r {
                    case .failure(let e): log("ASK failed after \(String(format: "%.1f", now() - n)) s: \(e)")
                    case .success(let rep):
                        log("ANSWER in \(String(format: "%.1f", now() - n)) s (\(String(format: "%.1f", lat)) s after the others' speech): \(rep.tips.count) tips, \(fresh.count) new, \(rep.claims.count) claims")
                        if !fresh.isEmpty { tipLatencies.append(lat) }
                        for c in rep.claims { log("  claim \(c.side.rawValue) [\(c.kind.rawValue)]: \(c.text)") }
                        for t in fresh { log("  TIP: \(t.text.replacingOccurrences(of: "\n", with: " / "))  (why: \(t.why))") }
                        for t in rep.tips where !fresh.contains(where: { $0.text == t.text }) { log("  tip dropped as a repeat: \(t.text)") }
                    }
                }
            }
        }
        timer.resume()

        // The main run loop must turn, as in the app: Foundation Models answers through it.
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))

        // Stop as HelperController.end() does: tap off, transcriber off, then the backend.
        sq.sync { timer.cancel() }
        b.audioTap = nil
        let f0 = now()
        let last = live.stop()
        sq.sync {
            log("transcriber stopped in \(String(format: "%.1f", now() - f0)) s, \(last.count) final line(s) from the flush")
            for (who, text) in last { state.hear(who, text, final: true, at: now()); log("LINE (flush) \(who.rawValue): \(text)") }
        }
        print(b.run("stop")); fflush(stdout)
        Thread.sleep(forTimeInterval: 1)   // the .sha256 is written in the background
        cq.sync { log("buffers: \(counts)") }
        let body = sq.sync { HelperSummary.md(title: ((media as NSString).lastPathComponent as NSString).deletingPathExtension, lang: lang, brain: "on this Mac", state: state) }
        do { let p = try HelperSummary.write(body, media: media); log("wrote \(p)") } catch { log("summary not written: \(error)") }
        sq.sync {
            log("asked \(state.asked), failed \(state.failed), tips \(state.tips.count), lines \(state.window.count)")
            if !tipLatencies.isEmpty { log("speech end to tip: " + tipLatencies.map { String(format: "%.1f", $0) }.joined(separator: ", ") + " s") }
        }
        print("\n----- helper.md -----\n" + body)
    }
}
