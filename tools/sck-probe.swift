// sck-probe.swift: phase F0 of the native engine. Records the main display, the
// system sound and the microphone with ScreenCaptureKit into a fragmented .mov
// (no BlackHole, no ffmpeg), with the same settings as ipsio.sh: 12 fps,
// H.264 on the video chip at 4 Mbps, AAC 128k. Measures what decides whether
// the native engine replaces ffmpeg: CPU, track alignment, and whether the file
// survives a kill -9 in the middle.
//   swiftc -O -swift-version 5 tools/sck-probe.swift -o /tmp/sck-probe
//   /tmp/sck-probe out.mov 60          # seconds; SIGINT also ends it cleanly
// macOS 15+ (microphone inside the stream); this is a probe, not the app.
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

let args = CommandLine.arguments
guard args.count >= 3, let seconds = Double(args[2]) else {
    print("usage: sck-probe <out.mov> <seconds>"); exit(2)
}
let outURL = URL(fileURLWithPath: args[1])
try? FileManager.default.removeItem(at: outURL)

final class Probe: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let writer: AVAssetWriter
    let video: AVAssetWriterInput, system: AVAssetWriterInput, mic: AVAssetWriterInput
    let q = DispatchQueue(label: "probe")
    var started = false, finished = false
    var frames = 0, sysBuffers = 0, micBuffers = 0
    var firstVideo: CMTime?, firstSys: CMTime?, firstMic: CMTime?
    var lastVideo = CMTime.zero, lastSys = CMTime.zero, lastMic = CMTime.zero
    var sysPeak: Float = -200, micPeak: Float = -200

    init(url: URL, width: Int, height: Int) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // Fragments every 2 s: a crash leaves a file that plays up to the last fragment.
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000, AVVideoExpectedSourceFrameRateKey: 12,
                                              AVVideoMaxKeyFrameIntervalKey: 24]])
        let aac: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                                  AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000]
        system = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
        mic = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
        for i in [video, system, mic] { i.expectsMediaDataInRealTime = true; writer.add(i) }
        super.init()
    }

    static func rms(_ sb: CMSampleBuffer) -> Float? {
        guard let fmt = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return nil }
        var sum: Float = 0, n = 0
        try? sb.withAudioBufferList { list, _ in
            for b in list { guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let c = Int(b.mDataByteSize) / 4; for i in 0..<c { sum += p[i] * p[i] }; n += c }
        }
        guard n > 0 else { return nil }
        let r = (sum / Float(n)).squareRoot()
        return r > 0 ? 20 * log10(r) : -200
    }

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid, !finished else { return }
        let t = CMSampleBufferGetPresentationTimeStamp(sb)
        switch type {
        case .screen:
            // Only complete frames carry an image; idle frames are skipped by SCK.
            guard let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = att.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            if !started { writer.startWriting(); writer.startSession(atSourceTime: t); started = true }
            if firstVideo == nil { firstVideo = t }
            lastVideo = t; frames += 1
            if video.isReadyForMoreMediaData { video.append(sb) }
        case .audio:
            guard started else { return }
            if firstSys == nil { firstSys = t }
            lastSys = t; sysBuffers += 1
            if let r = Probe.rms(sb) { sysPeak = max(sysPeak, r) }
            if system.isReadyForMoreMediaData { system.append(sb) }
        case .microphone:
            guard started else { return }
            if firstMic == nil { firstMic = t }
            lastMic = t; micBuffers += 1
            if let r = Probe.rms(sb) { micPeak = max(micPeak, r) }
            if mic.isReadyForMoreMediaData { mic.append(sb) }
        @unknown default: break
        }
    }
    func stream(_ s: SCStream, didStopWithError error: Error) { print("STREAM STOPPED: \(error)"); exit(1) }

    func report() {
        func sec(_ a: CMTime?, _ b: CMTime) -> String { a.map { String(format: "%.3f", (b - $0).seconds) } ?? "-" }
        print("frames=\(frames) system_buffers=\(sysBuffers) mic_buffers=\(micBuffers)")
        print("span video=\(sec(firstVideo, lastVideo)) system=\(sec(firstSys, lastSys)) mic=\(sec(firstMic, lastMic))")
        if let v = firstVideo, let s = firstSys, let m = firstMic {
            print(String(format: "start offset system-video=%.3f mic-video=%.3f", (s - v).seconds, (m - v).seconds))
            print(String(format: "end offset   system-video=%.3f mic-video=%.3f", (lastSys - lastVideo).seconds, (lastMic - lastVideo).seconds))
        }
        print(String(format: "peak rms system=%.1f dB mic=%.1f dB", sysPeak, micPeak))
    }
}

func finish(_ stream: SCStream, _ p: Probe) {
    p.q.sync { p.finished = true }
    let g = DispatchGroup(); g.enter()
    stream.stopCapture { _ in g.leave() }; g.wait()
    for i in [p.video, p.system, p.mic] { i.markAsFinished() }
    g.enter(); p.writer.finishWriting { g.leave() }; g.wait()
    p.report()
    print("writer status=\(p.writer.status.rawValue) error=\(String(describing: p.writer.error))")
    exit(p.writer.status == .completed ? 0 : 1)
}

SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
    guard let display = content?.displays.first else { print("NO DISPLAY (screen permission?): \(String(describing: error))"); exit(1) }
    let cfg = SCStreamConfiguration()
    cfg.width = display.width * 2; cfg.height = display.height * 2   // points to pixels on Retina
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: 12)
    cfg.showsCursor = true
    cfg.capturesAudio = true; cfg.excludesCurrentProcessAudio = true
    cfg.sampleRate = 48_000; cfg.channelCount = 2
    cfg.captureMicrophone = true
    let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
    let p: Probe
    do { p = try Probe(url: outURL, width: cfg.width, height: cfg.height) } catch { print("WRITER: \(error)"); exit(1) }
    let stream = SCStream(filter: filter, configuration: cfg, delegate: p)
    do {
        try stream.addStreamOutput(p, type: .screen, sampleHandlerQueue: p.q)
        try stream.addStreamOutput(p, type: .audio, sampleHandlerQueue: p.q)
        try stream.addStreamOutput(p, type: .microphone, sampleHandlerQueue: p.q)
    } catch { print("OUTPUT: \(error)"); exit(1) }
    stream.startCapture { e in
        if let e = e { print("START FAILED: \(e)"); exit(1) }
        print("recording \(Int(seconds)) s, \(cfg.width)x\(cfg.height) -> \(outURL.path)")
    }
    signal(SIGINT, SIG_IGN)
    let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    sig.setEventHandler { finish(stream, p) }; sig.resume()
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { finish(stream, p) }
    withExtendedLifetime(sig) {}
    objc_setAssociatedObject(stream, "sig", sig, .OBJC_ASSOCIATION_RETAIN)
}
dispatchMain()
