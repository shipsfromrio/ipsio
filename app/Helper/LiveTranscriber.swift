// LiveTranscriber.swift: the running capture's audio, transcribed as it
// comes, on this Mac only. One lane per track: the computer sound is Others,
// the microphone is Me (the speaker comes from the track, as in app/Transcribe).
// - macOS 26: SpeechAnalyzer + SpeechTranscriber with volatile results, the
//   engine of the batch transcription. Long-form (no minute per request), and
//   it has languages SFSpeechRecognizer lacks on device (pt-BR on a Mac
//   without Siri's pt-BR asset). Only a model already on the Mac is used:
//   nothing is downloaded while a meeting is running.
// - Else SFSpeechRecognizer with requiresOnDeviceRecognition (fail closed,
//   never the server), on the others' track only (LiveLanes: one task per
//   process). A request ends after a pause (LiveCut) so its line comes out
//   final, and a new one starts.
// The report goes to `onLine`.
import AVFoundation
import Foundation
import Speech

final class LiveTranscriber {
    /// (speaker, text, final). Called on the transcriber's own queue.
    var onLine: ((Speaker, String, Bool) -> Void)?
    /// (speaker, dBFS) about 4 times a second per track, for the cadence. Same queue.
    var onSound: ((Speaker, Double) -> Void)?
    /// What the lanes do (a request opened, cut, ended, failed), for a log. Same queue.
    var onEvent: ((String) -> Void)?
    /// "SpeechAnalyzer" or "SFSpeechRecognizer".
    let engine: String

    private let q = DispatchQueue(label: "ipsio.helper.live")
    private let recognizer: SFSpeechRecognizer?
    private let clock: () -> Double
    private final class Lane {
        let who: Speaker
        var req: SFSpeechAudioBufferRecognitionRequest?
        var task: SFSpeechRecognitionTask?
        var started = 0.0, lastChange: Double?, text = "", lastFinal = ""
        var closing: SFSpeechAudioBufferRecognitionRequest?, closingSince = 0.0   // ended, its line still coming
        var closingText = ""                                                         // its line so far, if the final comes empty
        var held: [AVAudioPCMBuffer] = [], heldSeconds = 0.0                         // audio meanwhile
        var analyzer: AnyObject?   // AnalyzerLane on macOS 26
        var energy = 0.0, values = 0, measured = 0.0
        init(_ who: Speaker) { self.who = who }
    }
    private var lanes: [Speaker: Lane] = [:]
    private var timer: DispatchSourceTimer?
    private var running = false
    private var flushed: [(Speaker, String)] = []
    private var setup: AnyObject?   // AnalyzerSetup on macOS 26

    /// Fails (with the reason, for the panel) when no on-device recognition
    /// is there for the language. Blocks for the authorization and the
    /// model check: call off main. `engine`: .auto (the app) takes the
    /// analyzer when it can; .legacy forces SFSpeechRecognizer (the bench of
    /// the macOS 13 to 25 path); .analyzer fails without it.
    init(language: String, engine choice: TranscribeEngine = .auto, clock: @escaping () -> Double) throws {
        guard let id = Language.identifier(language) else { throw TranscribeError.language(language) }
        self.clock = clock
        var why = ""
        #if compiler(>=6.2)
        if #available(macOS 26, *), choice != .legacy {
            do {
                setup = try Blocking.run { try await AnalyzerSetup.make(id) }
                recognizer = nil; engine = "SpeechAnalyzer"; return
            } catch { if choice == .analyzer { throw error }; why = "\(error)" }
        }
        #endif
        if choice == .analyzer { throw TranscribeError.onDeviceUnavailable("\(id) (SpeechAnalyzer needs macOS 26)") }
        do { recognizer = try Legacy.recognizer(id) }   // authorized, on device, available; else throws
        catch let e as TranscribeError {
            if case .onDeviceUnavailable(let s) = e, !why.isEmpty { throw TranscribeError.onDeviceUnavailable("\(s); SpeechAnalyzer: \(why)") }
            throw e
        }
        recognizer?.defaultTaskHint = .dictation
        engine = "SFSpeechRecognizer"
    }

    func start() {
        q.async {
            guard !self.running else { return }
            self.running = true
            guard self.setup == nil else { return }   // the analyzer ends its lines by itself
            let t = DispatchSource.makeTimerSource(queue: self.q)
            t.schedule(deadline: .now() + 0.5, repeating: 0.5)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume(); self.timer = t
        }
    }

    /// Stops listening. The analyzer gets up to `flush` seconds to finish the
    /// line in progress; those last final lines are returned (not sent to
    /// onLine), so the caller can add them before it writes the summary.
    @discardableResult
    func stop(flush: Double = 2) -> [(Speaker, String)] {
        // The lanes stay alive until the end: their last results report through them.
        var ending: [Lane] = []
        q.sync {
            running = false; timer?.cancel(); timer = nil
            for l in lanes.values {
                l.req?.endAudio(); l.task?.cancel()
                if l.analyzer != nil { ending.append(l) }
            }
            lanes = [:]
        }
        #if compiler(>=6.2)
        if #available(macOS 26, *), !ending.isEmpty {
            let g = DispatchGroup()
            let analyzers = ending.compactMap { $0.analyzer as? AnalyzerLane }
            for a in analyzers { g.enter(); a.finish { g.leave() } }
            _ = g.wait(timeout: .now() + flush)
            for a in analyzers { a.cancel() }
        }
        #endif
        return q.sync {
            let f = flushed; flushed = []
            for l in ending { l.analyzer = nil }
            return f
        }
    }

    /// A buffer from the capture (Recorder.audioTap).
    func feed(_ track: Recorder.AudioTrack, _ sb: CMSampleBuffer) {
        q.async {
            guard self.running else { return }
            let who: Speaker = track == .mic ? .me : .others
            let lane = self.lanes[who] ?? { let l = Lane(who); self.lanes[who] = l; return l }()
            if let e = AudioEnergy.of(sb) {
                lane.energy += e.sumSquares; lane.values += e.values
                let now = self.clock()
                if now - lane.measured >= 0.25, lane.values > 0 {
                    self.onSound?(who, 10 * log10(max(lane.energy / Double(lane.values), 1e-12)))
                    lane.energy = 0; lane.values = 0; lane.measured = now
                }
            }
            #if compiler(>=6.2)
            if #available(macOS 26, *), let s = self.setup as? AnalyzerSetup {
                if lane.analyzer == nil {
                    lane.analyzer = AnalyzerLane(s) { [weak self, weak lane] text, final in
                        guard let me = self else { return }
                        me.q.async { if let l = lane { me.report(l, text, final) } }
                    }
                }
                (lane.analyzer as? AnalyzerLane)?.feed(sb)
                return
            }
            #endif
            guard LiveLanes.listens(who, analyzer: false) else { return }
            // A PCM copy: the capture's 48 kHz float (stereo or mono) as AVAudioPCMBuffer is
            // what was measured to work on device; the request converts it itself.
            guard let b = LivePCM.buffer(sb) else { return }
            if lane.req == nil {
                if !LiveCut.mayOpen(closingSince: lane.closing == nil ? nil : lane.closingSince, now: self.clock()) {
                    // A new task now would end the one still writing its line (one per process): hold the audio.
                    lane.held.append(b); lane.heldSeconds += Double(b.frameLength) / b.format.sampleRate
                    while lane.heldSeconds > LiveCut.hold, let f = lane.held.first {
                        lane.held.removeFirst(); lane.heldSeconds -= Double(f.frameLength) / f.format.sampleRate
                    }
                    return
                }
                if lane.closing != nil {
                    self.onEvent?("\(who.rawValue): the ended request never answered, its line as last heard")
                    self.report(lane, lane.closingText, true)
                }
                lane.closing = nil; lane.closingText = ""
                self.open(lane)
                for h in lane.held { lane.req?.append(h) }
                lane.held = []; lane.heldSeconds = 0
            }
            lane.req?.append(b)
        }
    }

    /// One result of a lane (on q): a partial goes out as it is, a final
    /// once (a repeat of the last final is dropped). After stop, finals are
    /// kept for the caller of stop().
    private func report(_ lane: Lane, _ text: String, _ final: Bool) {
        if final {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, t != lane.lastFinal else { return }   // a cut after a metadata line repeats it
            lane.lastFinal = t
            if running { onLine?(lane.who, t, true) } else { flushed.append((lane.who, t)) }
        } else if running, text != lane.text {
            lane.text = text; lane.lastChange = clock(); onLine?(lane.who, text, false)
        }
    }

    private func open(_ lane: Lane) {
        guard let recognizer = recognizer else { return }
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.requiresOnDeviceRecognition = true   // never the server
        r.shouldReportPartialResults = true
        r.addsPunctuation = true
        lane.req = r; lane.started = clock(); lane.lastChange = nil; lane.text = ""
        lane.task = recognizer.recognitionTask(with: r) { [weak self, weak lane] result, error in
            guard let self = self, let lane = lane else { return }
            self.q.async {
                guard self.running, lane.req === r else {
                    // An ended request still delivers its last line; then the next may open. Its final
                    // can come empty (seen on macOS 26.6): the line as last heard stands in for it.
                    let final = (result?.isFinal ?? false) ? result!.bestTranscription.formattedString : ""
                    if lane.closing === r, error != nil || (result?.isFinal ?? false) {
                        let empty = final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        self.onEvent?("\(lane.who.rawValue): ended request " + (error.map { "failed: \($0.localizedDescription)" } ?? "gave its final line (\(final.count) chars)"))
                        self.report(lane, empty ? lane.closingText : final, true)
                        lane.closing = nil; lane.closingText = ""
                    } else if !final.isEmpty { self.report(lane, final, true) }
                    return
                }
                if let res = result {
                    let text = res.bestTranscription.formattedString
                    // macOS 14+: the metadata marks the end of an utterance (the next result starts over).
                    if res.isFinal || res.speechRecognitionMetadata != nil { self.report(lane, text, true); lane.text = ""; lane.lastChange = nil }
                    else { self.report(lane, text, false) }
                }
                if let e = error { self.onEvent?("\(lane.who.rawValue): request failed: \(e.localizedDescription)") }
                if error != nil || (result?.isFinal ?? false) { lane.req = nil; lane.task = nil }
            }
        }
    }

    private func tick() {
        let now = clock()
        for lane in lanes.values {
            guard let r = lane.req else { continue }
            if LiveCut.shouldCut(requestStarted: lane.started, lastChange: lane.lastChange, hasText: !lane.text.isEmpty, now: now) {
                // End this request (its final line arrives by itself); the next opens once it has (LiveCut.mayOpen).
                r.endAudio(); lane.closing = r; lane.closingSince = now; lane.closingText = lane.text; lane.req = nil
                onEvent?("\(lane.who.rawValue): request cut after \(Int(now - lane.started)) s")
            }
        }
    }
}

#if compiler(>=6.2)
/// What every analyzer lane shares: the locale and the audio format the model wants.
@available(macOS 26, *)
final class AnalyzerSetup {
    let locale: Locale, format: AVAudioFormat
    init(_ l: Locale, _ f: AVAudioFormat) { locale = l; format = f }

    static func module(_ l: Locale) -> SpeechTranscriber {
        // The progressive preset (volatile and fast results): without fastResults the
        // analyzer answers in bursts about 11 s apart (measured on macOS 26.6).
        SpeechTranscriber(locale: l, preset: .progressiveTranscription)
    }

    /// Throws when the model for `id` is not on this Mac (no download here).
    static func make(_ id: String) async throws -> AnalyzerSetup {
        guard SpeechTranscriber.isAvailable,
              let l = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) else {
            throw TranscribeError.onDeviceUnavailable("\(id) (SpeechTranscriber)")
        }
        let m = module(l)
        // A command-line process sees "supported" for a model the system has
        // installed (the reservation is per app), so the installed list counts too.
        let installed = await SpeechTranscriber.installedLocales.contains { $0.identifier == l.identifier }
        let status = await AssetInventory.status(forModules: [m])
        guard installed || status == .installed else { throw TranscribeError.modelMissing(id) }
        guard let f = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [m]) else {
            throw TranscribeError.onDeviceUnavailable("\(id) (no audio format for SpeechTranscriber)")
        }
        return AnalyzerSetup(l, f)
    }
}

/// One track through one SpeechAnalyzer: the capture's buffers are converted
/// to the model's format and streamed in; results come out as (text, final).
@available(macOS 26, *)
final class AnalyzerLane {
    private let format: AVAudioFormat
    private var converter: AVAudioConverter?
    private var from: AVAudioFormat?
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private var work: Task<Void, Never>?
    private var reader: Task<Void, Never>?

    /// `report` is called from the analyzer's task.
    init(_ s: AnalyzerSetup, report: @escaping (String, Bool) -> Void) {
        format = s.format
        let m = AnalyzerSetup.module(s.locale)
        let analyzer = SpeechAnalyzer(modules: [m])
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        input = cont
        reader = Task { do { for try await r in m.results { report(String(r.text.characters), r.isFinal) } } catch {} }
        work = Task {
            do {
                if let last = try await analyzer.analyzeSequence(stream) { try await analyzer.finalizeAndFinish(through: last) }
                else { await analyzer.cancelAndFinishNow() }
            } catch { await analyzer.cancelAndFinishNow() }
        }
    }

    /// A capture buffer, converted and queued. Never waits.
    func feed(_ sb: CMSampleBuffer) {
        guard let b = LivePCM.buffer(sb) else { return }
        if from.map({ !$0.isEqual(b.format) }) ?? true {
            converter = AVAudioConverter(from: b.format, to: format); converter?.downmix = true; from = b.format
        }
        guard let c = converter else { return }
        let cap = AVAudioFrameCount((Double(b.frameLength) * format.sampleRate / b.format.sampleRate).rounded(.up)) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return }
        var given = false, err: NSError?
        let st = c.convert(to: out, error: &err) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true; status.pointee = .haveData; return b
        }
        guard st != .error, out.frameLength > 0 else { return }
        input.yield(AnalyzerInput(buffer: out))
    }

    /// End of the audio: the analyzer finishes the line in progress, then `done`.
    func finish(_ done: @escaping () -> Void) {
        input.finish()
        let w = work, r = reader
        Task { await w?.value; await r?.value; done() }
    }

    func cancel() { input.finish(); work?.cancel(); reader?.cancel() }
}
#endif

/// A capture buffer as an AVAudioPCMBuffer in its own format (a copy).
enum LivePCM {
    static func buffer(_ sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fd = CMSampleBufferGetFormatDescription(sb) else { return nil }
        let fmt = AVAudioFormat(cmAudioFormatDescription: fd)
        let n = CMSampleBufferGetNumSamples(sb)
        guard n > 0, let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else { return nil }
        b.frameLength = AVAudioFrameCount(n)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n), into: b.mutableAudioBufferList) == noErr else { return nil }
        return b
    }
}
