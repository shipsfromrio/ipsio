// Recorder.swift: one recording with ScreenCaptureKit. Screen and computer
// sound come from the same stream (one clock, no BlackHole, the sound output
// is never touched); the microphone comes from the stream on macOS 15+ and
// from AVCaptureSession on 13 and 14. Everything lands on one serial queue,
// which feeds the Writer and the two Meters.
import AVFoundation
import CoreMedia
import ScreenCaptureKit

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Options {
        var folder: String
        var title = ""
        var meeting = false            // microphone in its own track
        var fps = 12
        var videoBitrate = 4_000_000
        var target = CaptureTarget.main
        var micSource = MicSource.auto
    }
    /// Where the microphone comes from. `avcapture` forces the macOS 13/14
    /// path (AVCaptureSession) on 15+, so it can be exercised on a new Mac.
    enum MicSource: Equatable {
        case auto, avcapture
        /// IPSIO_MIC: only the exact word forces; anything else is the default.
        static func parse(_ s: String?) -> MicSource { s?.trimmingCharacters(in: .whitespaces).lowercased() == "avcapture" ? .avcapture : .auto }
    }
    struct Summary {
        let file: String
        let seconds: Double
        let sound: Sound.Summary, silencePct: Int, average: Float
        let mic: Sound.Mic?, micDeadPct: Int?
        let complete: Bool             // the writer closed the file normally
        let dropped: Int
    }
    struct Snapshot {
        let level: Level
        let system: [Float], mic: [Float]?   // one sample per second, dB
        let seconds: Double
        let meterAge: Double                 // seconds since the last computer-sound sample
        let file: String
    }
    enum Failure: Error, CustomStringConvertible {
        case noDisplay, noPermission, folder(String), writer(String), start(String), alreadyRecording
        case windowGone, windowClosed(String), microphone(String)
        var description: String {
            switch self {
            case .noDisplay: return "no display to record"
            case .noPermission: return "no Screen Recording permission"
            case .folder(let s): return "the recordings folder cannot be written: \(s)"
            case .writer(let s): return "the file could not be created: \(s)"
            case .start(let s): return "the capture did not start: \(s)"
            case .alreadyRecording: return "already recording"
            case .windowGone: return "the chosen window is no longer open"
            case .windowClosed(let s): return "the recorded window was closed, or macOS stopped its capture: \(s)"
            case .microphone(let s): return "the microphone did not open: \(s)"
            }
        }
    }

    private let q = DispatchQueue(label: "ipsio.recorder")
    private var stream: SCStream?
    private var micSession: AVCaptureSession?   // only touched on q
    private var micClock: CMClock?              // the session's clock, when it is not the host's
    private var writer: Writer?
    private var system = Meter(), mic: Meter?
    private var startHost: Double = 0
    private var lastPTS = CMTime.invalid
    private(set) var file: String?
    /// Set when the system stopped the capture (display asleep, permission
    /// revoked, another app took the screen): the app's watchdog reads it.
    private(set) var stoppedByItself: Error?
    /// What the last start recorded (a display that fell back to main shows here).
    private(set) var resolvedTarget: CaptureTarget.Resolved?
    private var windowMode = false

    var recording: Bool { q.sync { writer != nil } }

    // ---- live audio for the helper mode (app/Helper) ----
    enum AudioTrack { case system, mic }
    private let tapQ = DispatchQueue(label: "ipsio.recorder.tap")
    private let tapLock = NSLock()
    private var tap: ((AudioTrack, CMSampleBuffer) -> Void)?
    /// Every audio buffer, handed over on its own queue (never the capture's).
    /// nil, the default, costs one check and never changes what is written.
    var audioTap: ((AudioTrack, CMSampleBuffer) -> Void)? {
        get { tapLock.lock(); defer { tapLock.unlock() }; return tap }
        set { tapLock.lock(); tap = newValue; tapLock.unlock() }
    }
    private func forward(_ t: AudioTrack, _ sb: CMSampleBuffer) { if let f = audioTap { tapQ.async { f(t, sb) } } }

    static func now() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    /// Largest frame H.264 encodes (level 5.2, 4096x2304): a 5K screen is scaled down.
    static func fit(_ w: Int, _ h: Int, maxW: Int = 4096, maxH: Int = 2304) -> (Int, Int) {
        let s = min(1, Double(maxW) / Double(w), Double(maxH) / Double(h))
        func even(_ x: Double) -> Int { max(2, Int(x) & ~1) }
        return (even(Double(w) * s), even(Double(h) * s))
    }

    func start(_ o: Options, done: @escaping (Result<String, Failure>) -> Void) {
        if recording { done(.failure(.alreadyRecording)); return }
        guard CGPreflightScreenCaptureAccess() else { done(.failure(.noPermission)); return }
        do { try FileManager.default.createDirectory(atPath: o.folder, withIntermediateDirectories: true) }
        catch { done(.failure(.folder("\(error)"))); return }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            guard let content = content else { done(.failure(error == nil ? .noDisplay : .noPermission)); return }
            let resolved = CaptureTarget.resolve(o.target, displays: content.displays.map { $0.displayID }, mainID: CGMainDisplayID(),
                                                 windows: content.windows.map { $0.windowID })
            let filter: SCContentFilter, w: Int, h: Int
            switch resolved {
            case .noDisplay: done(.failure(.noDisplay)); return
            case .windowGone: done(.failure(.windowGone)); return
            case .window(let id):
                guard let win = content.windows.first(where: { $0.windowID == id }) else { done(.failure(.windowGone)); return }
                filter = SCContentFilter(desktopIndependentWindow: win)
                (w, h) = CaptureTarget.windowSize(width: Double(win.frame.width), height: Double(win.frame.height), scale: Recorder.scale(filter, win.frame))
            case .display(let id, _):
                guard let display = content.displays.first(where: { $0.displayID == id }) else { done(.failure(.noDisplay)); return }
                filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                let mode = CGDisplayCopyDisplayMode(display.displayID)
                (w, h) = Recorder.fit(mode?.pixelWidth ?? display.width * 2, mode?.pixelHeight ?? display.height * 2)
            }
            let cfg = SCStreamConfiguration()
            cfg.width = w; cfg.height = h
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(o.fps))
            cfg.showsCursor = true
            cfg.capturesAudio = true; cfg.excludesCurrentProcessAudio = true
            cfg.sampleRate = 48_000; cfg.channelCount = 2
            var micInStream = false
            if o.meeting, o.micSource == .auto, #available(macOS 15.0, *) { cfg.captureMicrophone = true; micInStream = true }
            let path = Naming.output(folder: o.folder, date: Date(), title: o.title)
            let w2: Writer
            do { w2 = try Writer(url: URL(fileURLWithPath: path), .init(width: w, height: h, fps: o.fps, videoBitrate: o.videoBitrate, microphone: o.meeting)) }
            catch { done(.failure(.writer("\(error)"))); return }
            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            do {
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.q)
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.q)
                if micInStream, #available(macOS 15.0, *) { try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: self.q) }
            } catch { done(.failure(.start("\(error)"))); return }
            // A meeting without its microphone track is not a meeting: fail the
            // start instead of recording an empty track (fail closed).
            var session: AVCaptureSession?
            if o.meeting && !micInStream {
                switch Recorder.openMic(self, self.q) {
                case .success(let m): session = m
                case .failure(let e): _ = w2.finish(); done(.failure(e)); return
                }
            }
            let clock = session.flatMap { Recorder.foreignClock($0.synchronizationClock) }
            self.q.sync {
                self.writer = w2; self.file = path; self.stream = s
                self.micSession = session; self.micClock = clock
                self.system = Meter(); self.mic = o.meeting ? Meter() : nil
                self.startHost = Recorder.now(); self.lastPTS = .invalid; self.stoppedByItself = nil
                self.resolvedTarget = resolved
                if case .window = resolved { self.windowMode = true } else { self.windowMode = false }
            }
            s.startCapture { e in
                if let e = e {
                    let m = self.q.sync { () -> AVCaptureSession? in
                        let m = self.micSession
                        self.writer = nil; self.stream = nil; self.file = nil; self.micSession = nil; self.micClock = nil
                        return m
                    }
                    _ = w2.finish(); m?.stopRunning()
                    done(.failure(.start("\(e)"))); return
                }
                done(.success(path))
            }
        }
    }

    /// Pixels per point for a window: the filter's on macOS 14+, else the
    /// display under the window's center (2 when unknown, like a Retina screen).
    private static func scale(_ f: SCContentFilter, _ frame: CGRect) -> Double {
        if #available(macOS 14.0, *) { return Double(f.pointPixelScale) }
        var id: CGDirectDisplayID = 0, n: UInt32 = 0
        guard CGGetDisplaysWithPoint(CGPoint(x: frame.midX, y: frame.midY), 1, &id, &n) == .success, n == 1,
              let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 else { return 2 }
        return Double(mode.pixelWidth) / Double(mode.width)
    }

    /// What the AVCaptureSession microphone hands over: the format the
    /// stream's microphone and computer sound arrive in on macOS 15+ (float32,
    /// 48 kHz, stereo), whatever the device is (24-bit USB, 16 kHz Bluetooth).
    /// AudioEnergy meters it and the AAC writer gets one format on every Mac.
    static let micPCM: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false]

    /// Why the microphone session cannot record, or nil when it can. Pure:
    /// the facts come in, the first broken one is named.
    static func micProblem(device: Bool, status: AVAuthorizationStatus, inputError: String?, canAdd: Bool, running: Bool) -> String? {
        if !device { return "the Mac has no sound input" }
        if status == .denied || status == .restricted { return "no Microphone permission" }
        if let e = inputError { return e }
        if !canAdd { return "the input cannot be added to the session" }
        if !running { return "the session did not run" }
        return nil
    }

    /// macOS 13 and 14 (or IPSIO_MIC=avcapture): the microphone through
    /// AVFoundation, on the recorder's queue. Running, or the reason why not.
    private static func openMic(_ d: AVCaptureAudioDataOutputSampleBufferDelegate, _ q: DispatchQueue) -> Result<AVCaptureSession, Failure> {
        let st = AVCaptureDevice.authorizationStatus(for: .audio)
        func fail(_ device: Bool, _ inputError: String? = nil, canAdd: Bool = true, running: Bool = false) -> Result<AVCaptureSession, Failure> {
            .failure(.microphone(micProblem(device: device, status: st, inputError: inputError, canAdd: canAdd, running: running) ?? "unknown"))
        }
        guard let dev = AVCaptureDevice.default(for: .audio) else { return fail(false) }
        if st == .denied || st == .restricted { return fail(true) }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: dev) } catch { return fail(true, "\(error)") }
        let s = AVCaptureSession(), out = AVCaptureAudioDataOutput()
        guard s.canAddInput(input), s.canAddOutput(out) else { return fail(true, canAdd: false) }
        s.addInput(input); s.addOutput(out)
        out.audioSettings = micPCM
        out.setSampleBufferDelegate(d, queue: q)
        s.startRunning()
        guard s.isRunning else { s.stopRunning(); return fail(true) }
        return .success(s)
    }

    /// The session's clock when it is not the host clock (ScreenCaptureKit
    /// stamps on the host clock), so its buffers need converting.
    static func foreignClock(_ c: CMClock?) -> CMClock? {
        guard let c = c, !CFEqual(c, CMClockGetHostTimeClock()) else { return nil }
        return c
    }

    /// A copy of the buffer moved by `d` (every timing entry), or nil.
    static func shifted(_ sb: CMSampleBuffer, by d: CMTime) -> CMSampleBuffer? {
        if d == .zero { return sb }
        var n: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &n) == noErr, n > 0 else { return nil }
        var info = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: n)
        guard CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: n, arrayToFill: &info, entriesNeededOut: &n) == noErr else { return nil }
        for i in info.indices {
            info[i].presentationTimeStamp = info[i].presentationTimeStamp + d
            if info[i].decodeTimeStamp.isValid { info[i].decodeTimeStamp = info[i].decodeTimeStamp + d }
        }
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: n,
                                                    sampleTimingArray: &info, sampleBufferOut: &out) == noErr else { return nil }
        return out
    }

    // ---- buffers (all on q) ----
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid, let w = writer else { return }
        switch type {
        case .screen:
            // Only complete frames carry an image; an unchanged screen sends none.
            guard let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = att.first?[.status] as? Int, let st = SCFrameStatus(rawValue: raw) else { return }
            // A recorded window that closes: the stream says stopped. Same path
            // as a system stop (the watchdog saves the file).
            if st == .stopped, windowMode, stoppedByItself == nil { stoppedByItself = Failure.windowClosed("the window is gone") }
            guard st == .complete else { return }
            w.appendVideo(sb); note(sb)
        case .audio:
            w.appendSystem(sb); feed(&system, sb); note(sb); forward(.system, sb)
        default:
            if #available(macOS 15.0, *), type == .microphone { w.appendMic(sb); if mic != nil { feed(&mic!, sb) }; forward(.mic, sb) }
        }
    }
    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        guard let w = writer else { return }
        var b = sb
        if let clock = micClock {
            // The session's clock to the host clock the screen is stamped on.
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            guard let moved = Recorder.shifted(sb, by: CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock()) - pts) else {
                if w.started { w.drop() }; return
            }
            b = moved
        }
        w.appendMic(b); if mic != nil { feed(&mic!, b) }; forward(.mic, b)
    }
    private func feed(_ m: inout Meter, _ sb: CMSampleBuffer) {
        if let e = AudioEnergy.of(sb) { m.add(sumSquares: e.sumSquares, frames: e.values, at: CMSampleBufferGetPresentationTimeStamp(sb).seconds) }
    }
    private func note(_ sb: CMSampleBuffer) {
        let t = CMSampleBufferGetPresentationTimeStamp(sb) + CMSampleBufferGetDuration(sb)
        if !lastPTS.isValid || t > lastPTS { lastPTS = t }
    }
    func stream(_ s: SCStream, didStopWithError error: Error) {
        q.async { self.stoppedByItself = self.windowMode ? Failure.windowClosed("\(error)") : error }
    }

    /// What the app's alarm reads every few seconds.
    func level() -> Level? { snapshot()?.level }

    /// Everything "level" and "check" report, read in one go on the queue.
    func snapshot() -> Snapshot? {
        q.sync {
            guard writer != nil, let f = file else { return nil }
            let now = Recorder.now()
            return Snapshot(level: Level.of(system: system, mic: mic, now: now, start: startHost),
                            system: system.samples, mic: mic?.samples, seconds: now - startHost,
                            meterAge: system.age(now: now, recordingStart: startHost), file: f)
        }
    }

    /// start() for a caller that may block (the app's background queue).
    func startAndWait(_ o: Options, timeout: Double = 30) -> Result<String, Failure> {
        let g = DispatchSemaphore(value: 0), lock = NSLock()
        var r: Result<String, Failure>?, late = false
        start(o) { res in
            lock.lock(); let abandoned = late; r = res; lock.unlock()
            // An answer after the deadline: nobody is waiting for that recording.
            if abandoned, case .success = res { _ = self.stop() }
            g.signal()
        }
        if g.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock(); late = true; lock.unlock()
            _ = stop()
            return .failure(.start("no answer from ScreenCaptureKit in \(Int(timeout)) s"))
        }
        lock.lock(); defer { lock.unlock() }
        return r!
    }

    /// Idempotent: a second stop finds nothing and returns nil, so it can
    /// never hand the same file to anything twice.
    func stop() -> Summary? {
        guard let (w, s, path) = q.sync(execute: { () -> (Writer, SCStream?, String)? in
            guard let w = writer, let p = file else { return nil }
            let s = stream; writer = nil; stream = nil; file = nil
            return (w, s, p)
        }) else { return nil }
        // Bounded: a wedged capture must not hold the file (and the app) forever.
        if let s = s { let g = DispatchSemaphore(value: 0); s.stopCapture { _ in g.signal() }; _ = g.wait(timeout: .now() + 10) }
        let session = q.sync { () -> AVCaptureSession? in let m = micSession; micSession = nil; micClock = nil; return m }
        session?.stopRunning()
        let (sys, m, start, last) = q.sync { (system.samples, mic?.samples, w.sessionStart, lastPTS) }
        let complete = w.finish()
        let secs = (start != nil && last.isValid) ? (last - start!).seconds : 0
        let su = Sound.summary(sys), ms = m.map { Sound.micSummary($0) }
        return Summary(file: path, seconds: max(0, secs), sound: su.0, silencePct: su.pct, average: su.avg,
                       mic: ms?.0, micDeadPct: ms?.pct, complete: complete, dropped: w.dropped)
    }
}
