// Writer.swift: the .mov the native engine writes. Fragmented every 2 s, so a
// crash or a power cut leaves a file that plays up to the last fragment (the
// reason ipsio.sh chose .mkv). Video in H.264 on the Mac's video chip; audio
// in separate AAC tracks: track 1 = the computer (the others), track 2 = the
// microphone (you), so a transcription knows who spoke. Players that play
// every enabled track (QuickTime) mix them; nothing is mixed on disk.
// Not thread-safe: the capture calls it from one serial queue.
import AVFoundation
import CoreMedia

final class Writer {
    let url: URL
    private let writer: AVAssetWriter
    private let videoIn: AVAssetWriterInput
    private let systemIn: AVAssetWriterInput
    private let micIn: AVAssetWriterInput?
    private(set) var started = false
    private(set) var sessionStart: CMTime?
    private(set) var dropped = 0          // buffers refused because the input was busy

    struct Settings {
        var width: Int, height: Int
        var fps = 12, videoBitrate = 4_000_000, audioBitrate = 128_000
        var microphone = true
        var fragment: Double = 2
    }

    init(url: URL, _ s: Settings) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: s.fragment, preferredTimescale: 600)
        videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: s.width, AVVideoHeightKey: s.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: s.videoBitrate,
                                              AVVideoExpectedSourceFrameRateKey: s.fps,
                                              AVVideoMaxKeyFrameIntervalKey: s.fps * 2]])
        let aac: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                                  AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: s.audioBitrate]
        systemIn = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
        micIn = s.microphone ? AVAssetWriterInput(mediaType: .audio, outputSettings: aac) : nil
        for i in [videoIn, systemIn] + (micIn.map { [$0] } ?? []) {
            i.expectsMediaDataInRealTime = true
            guard writer.canAdd(i) else { throw NSError(domain: "Ipsio.Writer", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot add a track"]) }
            writer.add(i)
        }
    }

    /// The file starts at the first video frame; audio before it is dropped,
    /// so every track begins together.
    func appendVideo(_ sb: CMSampleBuffer) {
        if !started {
            guard writer.startWriting() else { return }
            sessionStart = CMSampleBufferGetPresentationTimeStamp(sb)
            writer.startSession(atSourceTime: sessionStart!)
            started = true
        }
        append(sb, videoIn)
    }
    func appendSystem(_ sb: CMSampleBuffer) { if started { append(sb, systemIn) } }
    func appendMic(_ sb: CMSampleBuffer) { if started, let m = micIn { append(sb, m) } }

    private func append(_ sb: CMSampleBuffer, _ i: AVAssetWriterInput) {
        guard writer.status == .writing else { return }
        if CMSampleBufferGetPresentationTimeStamp(sb) < (sessionStart ?? .zero) { return }
        if i.isReadyForMoreMediaData { if !i.append(sb) { dropped += 1 } } else { dropped += 1 }
    }

    var failed: Error? { writer.status == .failed ? writer.error ?? NSError(domain: "Ipsio.Writer", code: 2) : nil }

    /// Closes the file. Blocks until AVFoundation is done; true when complete.
    func finish() -> Bool {
        guard started, writer.status == .writing else {
            if !started { writer.cancelWriting(); try? FileManager.default.removeItem(at: url) }
            return false
        }
        for i in [videoIn, systemIn] + (micIn.map { [$0] } ?? []) { i.markAsFinished() }
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return writer.status == .completed
    }
}

/// Energy of an audio buffer for the meter: float32 or int16 PCM, any layout.
enum AudioEnergy {
    static func of(_ sb: CMSampleBuffer) -> (sumSquares: Double, values: Int)? {
        guard let fmt = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM else { return nil }
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bits = Int(asbd.mBitsPerChannel)
        guard (isFloat && bits == 32) || (!isFloat && bits == 16) else { return nil }
        var sum = 0.0, n = 0
        do {
            try sb.withAudioBufferList { list, _ in
                for b in list {
                    guard let raw = b.mData else { continue }
                    if isFloat {
                        let p = raw.assumingMemoryBound(to: Float.self), c = Int(b.mDataByteSize) / 4
                        for i in 0..<c { let v = Double(p[i]); sum += v * v }; n += c
                    } else {
                        let p = raw.assumingMemoryBound(to: Int16.self), c = Int(b.mDataByteSize) / 2
                        for i in 0..<c { let v = Double(p[i]) / 32768; sum += v * v }; n += c
                    }
                }
            }
        } catch { return nil }
        return n > 0 ? (sum, n) : nil
    }
}
