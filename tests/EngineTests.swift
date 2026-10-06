// EngineTests.swift: the bench for the native engine (app/Engine). No screen,
// no microphone, no permission: the rules get numbers, the Writer gets
// synthetic frames and a sine wave, and a child process "crashes" mid-file.
//   swiftc -parse-as-library app/Engine/*.swift tests/EngineTests.swift -o /tmp/engine-tests && /tmp/engine-tests
// Exits 1 if any assertion fails.
import AVFoundation
import CoreMedia
import Foundation

var fails = 0, total = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    total += 1
    if ok { print("ok   \(name)") } else { fails += 1; print("FAIL \(name)"); let d = detail(); if !d.isEmpty { print("      \(d)") } }
}

// ---- synthetic media ----
func videoBuffer(_ t: CMTime, w: Int = 64, h: Int = 48) -> CMSampleBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    memset(CVPixelBufferGetBaseAddress(pb!), Int32(t.value % 255), CVPixelBufferGetDataSize(pb!))
    CVPixelBufferUnlockBaseAddress(pb!, [])
    var fd: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb!, formatDescriptionOut: &fd)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 12), presentationTimeStamp: t, decodeTimeStamp: .invalid)
    var sb: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb!, formatDescription: fd!, sampleTiming: &timing, sampleBufferOut: &sb)
    return sb!
}

/// Stereo float32 at 48 kHz, `frames` long, a sine of amplitude `amp` (0 = silence).
func audioBuffer(_ t: CMTime, frames: Int = 4800, amp: Float = 0.5) -> CMSampleBuffer {
    var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
        mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    var fd: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
    let bytes = frames * 8
    var bb: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &bb)
    var data = [Float](repeating: 0, count: frames * 2)
    let start = Double(t.value) / Double(t.timescale) * 48_000
    for i in 0..<frames { let v = amp * Float(sin(2 * Double.pi * 440 * (start + Double(i)) / 48_000)); data[2 * i] = v; data[2 * i + 1] = v }
    data.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb!, offsetIntoDestination: 0, dataLength: bytes) }
    var sb: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: bb!, formatDescription: fd!, sampleCount: frames, presentationTimeStamp: t, packetDescriptions: nil, sampleBufferOut: &sb)
    return sb!
}

/// Writes `seconds` of 12 fps video plus one or two audio tracks.
func writeSynthetic(_ path: String, seconds: Int, mic: Bool, finish: Bool, fragment: Double = 2) -> Bool {
    try? FileManager.default.removeItem(atPath: path)
    guard let w = try? Writer(url: URL(fileURLWithPath: path), .init(width: 64, height: 48, microphone: mic, fragment: fragment)) else { return false }
    for f in 0..<(seconds * 12) {
        let vt = CMTime(value: CMTimeValue(f), timescale: 12)
        w.appendVideo(videoBuffer(vt))
        // 0.1 s of audio per audio buffer, 10 per second, interleaved with video.
        let a0 = f * 10 / 12, a1 = (f + 1) * 10 / 12
        for k in a0..<a1 {
            let at = CMTime(value: CMTimeValue(k * 4800), timescale: 48_000)
            w.appendSystem(audioBuffer(at))
            if mic { w.appendMic(audioBuffer(at, amp: 0.05)) }
        }
        if !finish { usleep(20_000) }   // let fragments reach the disk before the "crash"
    }
    return finish ? w.finish() : true
}

@main
struct EngineTests {
    static func main() {
        // A child run: write without closing, then die like a crash.
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "crash" {
            _ = writeSynthetic(CommandLine.arguments[2], seconds: 6, mic: true, finish: false, fragment: 1)
            _exit(0)
        }

        // ------------------------------------------------------ classify ---
        check(Sound.classify(nil) == .noSound, "no measurement is no sound")
        check(Sound.classify(-Float.infinity) == .noSound, "-inf is no sound")
        check(Sound.classify(-60.1) == .noSound && Sound.classify(-60) == .low, "silence below -60 dB, like the script")
        check(Sound.classify(-35.1) == .low && Sound.classify(-35) == .ok, "low below -35 dB")
        check(Sound.classify(-10) == .ok && Sound.classify(-9.9) == .loud, "loud above -10 dB")
        check(Sound.trailingSilence([-20, -70, -20, -70, -.infinity]) == 2, "trailing silence counts only the end")
        check(Sound.trailingSilence([]) == 0, "no samples, no silence")

        // ------------------------------------------------------- summary ---
        let s1 = Sound.summary(Array(repeating: -20, count: 87) + Array(repeating: -70, count: 13))
        check(s1.0 == .ok && s1.pct == 13 && s1.avg == -20, "a lunch break (13%) does not make gaps", "\(s1)")
        check(Sound.summary(Array(repeating: -20, count: 60) + Array(repeating: -70, count: 40)).0 == .gaps, "40% silence is gaps")
        check(Sound.summary(Array(repeating: -20, count: 10) + Array(repeating: -70, count: 90)).0 == .silent, "90% silence is silent")
        check(Sound.summary(Array(repeating: -40, count: 10)).0 == .low, "a low average is low")
        check(Sound.summary([]).0 == .noMeasure, "no samples, no measure")
        check(Sound.micSummary(Array(repeating: -90, count: 9) + [-30]).0 == .dead, "a microphone dead 90% of the time is dead")
        check(Sound.micSummary(Array(repeating: -90, count: 8) + [-30, -30]).0 == .ok, "80% dead is not dead")

        // --------------------------------------------------------- meter ---
        var m = Meter()
        // 0.5 amplitude sine has RMS 0.3536 = -9.03 dB; feed 3 s in 10 ms buffers.
        for i in 0..<300 { m.add(sumSquares: 480 * 0.125, frames: 480, at: 100 + Double(i) * 0.01) }
        m.add(sumSquares: 0, frames: 480, at: 103.0)   // opens second 4, closes second 3
        check(m.samples.count == 3, "one sample per whole second", "\(m.samples.count)")
        check(abs((m.last ?? 0) - (-9.03)) < 0.05, "the sample is the RMS in dB", "\(m.last ?? 0)")
        var g = Meter()
        g.add(sumSquares: 480 * 0.125, frames: 480, at: 0)
        g.add(sumSquares: 480 * 0.125, frames: 480, at: 5.2)   // nothing for 4 s
        check(g.samples.count == 5 && g.samples[1] > -20, "a gap in the buffers still yields one sample per second", "\(g.samples)")
        var r = Meter()
        for s in 0..<20 { r.add(sumSquares: s < 10 ? 480 * 0.125 : 0, frames: 480, at: Double(s)) }
        r.add(sumSquares: 0, frames: 480, at: 20)
        check(r.samples[9] > -10 && r.samples[19].isInfinite, "the window is the last 10 s: loud fades out after 10 s of silence", "\(r.samples)")
        check(r.samples[14] > -20, "5 s into silence the 10 s window still hears the sound")

        // --------------------------------------------------------- level ---
        var ok = Meter(); for s in 0..<5 { ok.add(sumSquares: 480 * 0.01, frames: 480, at: 1000 + Double(s)) }
        check(Level.of(system: ok, mic: nil, now: 1005, start: 1000).verdict == "OK", "a fresh meter reads normally")
        check(Level.of(system: ok, mic: nil, now: 1030, start: 1000).verdict == "NO_SOUND", "a meter frozen 20 s is no sound")
        check(Level.of(system: ok, mic: nil, now: 1030, start: 1000).silence >= 20, "a frozen meter counts its age as silence")
        check(Level.of(system: Meter(), mic: nil, now: 1005, start: 1000).verdict == "MEASURING", "an empty meter in the first seconds is measuring")
        check(Level.of(system: Meter(), mic: nil, now: 1025, start: 1000).verdict == "NO_SOUND", "an empty meter after 20 s is no sound")
        check(Level.of(system: ok, mic: Meter(), now: 1005, start: 1000).micSilence == ok.samples.count, "a microphone with no sample is dead since the start")

        // -------------------------------------------------------- naming ---
        let d = DateComponents(calendar: Calendar.current, year: 2026, month: 10, day: 5, hour: 14, minute: 3).date!
        check(Naming.output(folder: "/R", date: d, title: "Hearing: A/B\nnext", exists: { _ in false }) == "/R/2026-10-05_14-03 Hearing- A-B next.mov", "a title is made safe for a file name")
        check(Naming.output(folder: "/R", date: d, title: "", exists: { _ in false }) == "/R/2026-10-05_14-03.mov", "no title, just the date")
        let taken: Set = ["/R/2026-10-05_14-03 X.mov", "/R/2026-10-05_14-03 X (2).mov"]
        check(Naming.output(folder: "/R", date: d, title: "X", exists: { taken.contains($0) }) == "/R/2026-10-05_14-03 X (3).mov", "a taken name gets (2), (3)")

        // ------------------------------------------------------ evidence ---
        let dir = NSTemporaryDirectory() + "ipsio-engine-\(getpid())"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? "abc".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        let sum = Evidence.write(for: dir + "/a.txt")
        check(sum == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 of a known text")
        check((try? String(contentsOfFile: dir + "/a.txt.sha256", encoding: .utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  a.txt\n", "the .sha256 is in shasum -c format")
        check(!FileManager.default.fileExists(atPath: dir + "/a.txt.sha256.tmp"), "no temporary file left behind")
        check(Evidence.write(for: dir + "/missing") == nil, "a missing file gets no evidence")
        let big = dir + "/big.bin"
        FileManager.default.createFile(atPath: big, contents: Data(repeating: 7, count: (4 << 20) + 3))
        let sh = Process(), pipe = Pipe(); sh.executableURL = URL(fileURLWithPath: "/usr/bin/shasum"); sh.arguments = ["-a", "256", big]; sh.standardOutput = pipe
        try? sh.run(); sh.waitUntilExit()
        let ref = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).prefix(64)
        check(ref.count == 64 && Evidence.sha256(big) == String(ref), "a file larger than one read block hashes like shasum", "\(ref) vs \(Evidence.sha256(big) ?? "nil")")

        // ---------------------------------------------------- recorder ---
        check(Recorder.fit(3456, 2234) == (3456, 2234), "a Retina laptop screen keeps its size")
        let f5 = Recorder.fit(5120, 2880)
        check(f5.0 <= 4096 && f5.1 <= 2304 && f5.0 % 2 == 0 && f5.1 % 2 == 0, "a 5K screen is scaled to what H.264 encodes", "\(f5)")

        // ------------------------------------------------------- energy ---
        let e = AudioEnergy.of(audioBuffer(.zero, frames: 48_000, amp: 0.5))
        check(e != nil && abs(Sound.dB(e!.sumSquares / Double(e!.values)) - (-9.03)) < 0.05, "the energy of a sine wave", "\(String(describing: e))")
        check(Sound.dB(AudioEnergy.of(audioBuffer(.zero, amp: 0))!.sumSquares) == -.infinity, "digital silence is -inf")

        // -------------------------------------------------------- writer ---
        let mov = dir + "/w.mov"
        check(writeSynthetic(mov, seconds: 3, mic: true, finish: true), "the writer closes a file")
        let asset = AVURLAsset(url: URL(fileURLWithPath: mov))
        let tracks = asset.tracks
        check(tracks.filter { $0.mediaType == .video }.count == 1 && tracks.filter { $0.mediaType == .audio }.count == 2,
              "meeting: one video and two audio tracks (computer, microphone)", "\(tracks.map { $0.mediaType.rawValue })")
        check(abs(asset.duration.seconds - 3) < 0.3, "the file lasts what was written", "\(asset.duration.seconds)")
        let cls = dir + "/c.mov"
        _ = writeSynthetic(cls, seconds: 1, mic: false, finish: true)
        check(AVURLAsset(url: URL(fileURLWithPath: cls)).tracks.filter { $0.mediaType == .audio }.count == 1, "class mode: one audio track")
        let none = dir + "/none.mov"
        let w0 = try! Writer(url: URL(fileURLWithPath: none), .init(width: 64, height: 48))
        w0.appendSystem(audioBuffer(.zero))
        check(!w0.finish() && !FileManager.default.fileExists(atPath: none), "no video frame ever: no empty file left")

        // ---------------------------------------------------- the crash ---
        let crash = dir + "/crash.mov"
        let p = Process(); p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); p.arguments = ["crash", crash]
        try? p.run(); p.waitUntilExit()
        let ca = AVURLAsset(url: URL(fileURLWithPath: crash))
        check(FileManager.default.fileExists(atPath: crash) && ca.duration.seconds >= 3,
              "a process that dies mid-recording leaves a file that plays up to its last fragment", "\(ca.duration.seconds) s")
        check(ca.tracks.filter { $0.mediaType == .audio }.count == 2, "the crashed file keeps both audio tracks")

        try? FileManager.default.removeItem(atPath: dir)
        print("\(total - fails)/\(total) ok")
        exit(fails == 0 ? 0 : 1)
    }
}
