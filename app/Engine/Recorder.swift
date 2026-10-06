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
        case windowGone, windowClosed(String)
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
            }
        }
    }

    private let q = DispatchQueue(label: "ipsio.recorder")
    private var stream: SCStream?
    private var micSession: AVCaptureSession?
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
            if o.meeting, #available(macOS 15.0, *) { cfg.captureMicrophone = true; micInStream = true }
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
            self.q.sync {
                self.writer = w2; self.file = path; self.stream = s
                self.system = Meter(); self.mic = o.meeting ? Meter() : nil
                self.startHost = Recorder.now(); self.lastPTS = .invalid; self.stoppedByItself = nil
                self.resolvedTarget = resolved
                if case .window = resolved { self.windowMode = true } else { self.windowMode = false }
            }
            if o.meeting && !micInStream { self.startMicSession() }
            s.startCapture { e in
                if let e = e {
                    self.q.sync { self.writer = nil; self.stream = nil; self.file = nil }
                    _ = w2.finish(); self.micSession?.stopRunning(); self.micSession = nil
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

    /// macOS 13 and 14: the microphone through AVFoundation, on the same queue.
    private func startMicSession() {
        guard let dev = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: dev) else { return }
        let s = AVCaptureSession(), out = AVCaptureAudioDataOutput()
        guard s.canAddInput(input), s.canAddOutput(out) else { return }
        s.addInput(input); s.addOutput(out)
        out.setSampleBufferDelegate(self, queue: q)
        s.startRunning(); micSession = s
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
            w.appendSystem(sb); feed(&system, sb); note(sb)
        default:
            if #available(macOS 15.0, *), type == .microphone { w.appendMic(sb); if mic != nil { feed(&mic!, sb) } }
        }
    }
    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        guard let w = writer else { return }
        w.appendMic(sb); if mic != nil { feed(&mic!, sb) }
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
        micSession?.stopRunning(); micSession = nil
        let (sys, m, start, last) = q.sync { (system.samples, mic?.samples, w.sessionStart, lastPTS) }
        let complete = w.finish()
        let secs = (start != nil && last.isValid) ? (last - start!).seconds : 0
        let su = Sound.summary(sys), ms = m.map { Sound.micSummary($0) }
        return Summary(file: path, seconds: max(0, secs), sound: su.0, silencePct: su.pct, average: su.avg,
                       mic: ms?.0, micDeadPct: ms?.pct, complete: complete, dropped: w.dropped)
    }
}
