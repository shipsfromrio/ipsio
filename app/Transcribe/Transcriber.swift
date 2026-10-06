// Transcriber.swift: a recording into a transcript, on this Mac only. Each
// audio track is decoded to 16 kHz mono and transcribed on its own, so the
// speaker comes from the track (the microphone is "Me", the computer sound is
// "Others") and two people talking at once stay two lines.
//
// Two engines, both on device:
// - macOS 26: SpeechAnalyzer + SpeechTranscriber (long-form, on device by
//   design). The language model is a system asset; if it is missing, it is
//   downloaded once through AssetInventory (only the model travels, never the
//   audio), or refused when the caller says so.
// - macOS 13 to 25 (or on request): SFSpeechRecognizer with
//   requiresOnDeviceRecognition, in 50 s windows that overlap by 2 s.
// Fail closed: when on-device recognition is not there for the language, the
// answer is an error that says so, never the network.
import AVFoundation
import Foundation
import Speech

enum TranscribeError: Error, CustomStringConvertible {
    case language(String), noAudio, trackLayout(Int), read(String)
    case notAuthorized(String), onDeviceUnavailable(String), modelMissing(String), recognition(String)
    var description: String {
        switch self {
        case .language(let s): return "unknown language \"\(s)\" (pt or en)"
        case .noAudio: return "the file has no audio track"
        case .trackLayout(let n): return "\(n) audio tracks: not an Ipsio recording (1 or 2 tracks)"
        case .read(let s): return "the audio could not be read: \(s)"
        case .notAuthorized(let s): return "speech recognition is not allowed (\(s)): System Settings > Privacy & Security > Speech Recognition"
        case .onDeviceUnavailable(let s): return "on-device recognition is not available for \(s); nothing was sent to the network"
        case .modelMissing(let s): return "the on-device model for \(s) is not installed (downloads are off)"
        case .recognition(let s): return "recognition failed: \(s)"
        }
    }
}

enum TranscribeEngine: String { case auto, analyzer, legacy }

struct TranscriptResult {
    let segments: [Segment]
    let engine: String          // "SpeechAnalyzer" or "SFSpeechRecognizer"
    let audioSeconds: Double    // the longest transcribed track
    let seconds: Double         // wall clock spent
}

enum Transcriber {
    static let rate = 16_000

    /// Transcribes every speaker track of `path`. Blocks; call it off the main thread in the app.
    static func transcribe(path: String, language: String, engine: TranscribeEngine = .auto,
                           allowModelDownload: Bool = true, progress: @escaping (String) -> Void = { _ in }) throws -> TranscriptResult {
        let t0 = Date()
        guard let id = Language.identifier(language) else { throw TranscribeError.language(language) }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let tracks = try audioTracks(asset)
        guard !tracks.isEmpty else { throw TranscribeError.noAudio }
        let speakers = tracks.indices.map { Speaker.forTrack($0, of: tracks.count) }
        guard speakers.contains(where: { $0 != nil }) else { throw TranscribeError.trackLayout(tracks.count) }

        var useAnalyzer = false
        if engine != .legacy {
            #if compiler(>=6.2)
            if #available(macOS 26, *) { useAnalyzer = try Analyzer.ready(id, allowDownload: allowModelDownload, required: engine == .analyzer, progress: progress) }
            #endif
            if engine == .analyzer && !useAnalyzer { throw TranscribeError.onDeviceUnavailable("\(id) (SpeechAnalyzer needs macOS 26)") }
        }
        var recognizer: SFSpeechRecognizer?
        if !useAnalyzer { recognizer = try Legacy.recognizer(id) }

        var perTrack: [[Segment]] = [], audio = 0.0
        for (i, track) in tracks.enumerated() {
            guard let who = speakers[i] else { progress("track \(i + 1): the mix, skipped"); continue }
            progress("track \(i + 1) (\(who.rawValue)): decoding")
            let words: [Word], seconds: Double
            #if compiler(>=6.2)
            if useAnalyzer, #available(macOS 26, *) {
                (words, seconds) = try Analyzer.words(asset: asset, track: track, id: id, label: "track \(i + 1)", progress: progress)
            } else {
                (words, seconds) = try Legacy.words(asset: asset, track: track, recognizer: recognizer!, label: "track \(i + 1)", progress: progress)
            }
            #else
            (words, seconds) = try Legacy.words(asset: asset, track: track, recognizer: recognizer!, label: "track \(i + 1)", progress: progress)
            #endif
            audio = max(audio, seconds)
            let segs = Utterances.group(words, speaker: who)
            progress("track \(i + 1) (\(who.rawValue)): \(words.count) words, \(segs.count) lines")
            perTrack.append(segs)
        }
        return TranscriptResult(segments: Transcript.dropEcho(Transcript.merge(perTrack)), engine: useAnalyzer ? "SpeechAnalyzer" : "SFSpeechRecognizer",
                                audioSeconds: audio, seconds: Date().timeIntervalSince(t0))
    }

    static func audioTracks(_ asset: AVURLAsset) throws -> [AVAssetTrack] {
        do { return try Blocking.run { try await asset.loadTracks(withMediaType: .audio) } }
        catch { throw TranscribeError.read("\(error.localizedDescription)") }
    }

    /// Decodes one track to 16 kHz mono float, a buffer at a time. `each`
    /// gets the samples; answers the time of the first sample in the file
    /// (the track may start a little after 0).
    @discardableResult
    static func decode(asset: AVAsset, track: AVAssetTrack, each: ([Float]) throws -> Void) throws -> Double {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw TranscribeError.read(error.localizedDescription) }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false])
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { throw TranscribeError.read("the track cannot be decoded") }
        reader.add(out)
        guard reader.startReading() else { throw TranscribeError.read(reader.error?.localizedDescription ?? "start") }
        var first: Double?
        while let sb = out.copyNextSampleBuffer() {
            if first == nil { let p = CMSampleBufferGetPresentationTimeStamp(sb); if p.isNumeric { first = p.seconds } }
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let n = CMBlockBufferGetDataLength(bb) / 4
            if n == 0 { continue }
            var a = [Float](repeating: 0, count: n)
            let st = a.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
            guard st == kCMBlockBufferNoErr else { reader.cancelReading(); throw TranscribeError.read("block buffer \(st)") }
            do { try each(a) } catch { reader.cancelReading(); throw error }
        }
        if reader.status == .failed { throw TranscribeError.read(reader.error?.localizedDescription ?? "failed") }
        return max(0, first ?? 0)
    }
}

/// SFSpeechRecognizer, on device only.
enum Legacy {
    static func authorize() throws {
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            let sem = DispatchSemaphore(value: 0)
            SFSpeechRecognizer.requestAuthorization { _ in sem.signal() }
            _ = sem.wait(timeout: .now() + 120)
            status = SFSpeechRecognizer.authorizationStatus()
        }
        switch status {
        case .authorized: return
        case .denied: throw TranscribeError.notAuthorized("denied")
        case .restricted: throw TranscribeError.notAuthorized("restricted")
        default: throw TranscribeError.notAuthorized("not answered")
        }
    }

    static func recognizer(_ id: String) throws -> SFSpeechRecognizer {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: id)) else { throw TranscribeError.onDeviceUnavailable(id) }
        try authorize()
        guard r.supportsOnDeviceRecognition else { throw TranscribeError.onDeviceUnavailable("\(id) (SFSpeechRecognizer)") }
        guard r.isAvailable else { throw TranscribeError.onDeviceUnavailable("\(id) (the recognizer is busy or off)") }
        r.queue = OperationQueue()   // the answers must not need the main thread, which may be waiting
        r.defaultTaskHint = .dictation
        return r
    }

    static func words(asset: AVAsset, track: AVAssetTrack, recognizer: SFSpeechRecognizer,
                      label: String, progress: (String) -> Void) throws -> ([Word], Double) {
        let rate = Transcriber.rate
        var split = WindowSplitter(rate: rate)
        var windows: [(start: Double, words: [Word])] = []
        var total = 0
        func run(_ w: (start: Int, samples: [Float])) throws {
            let start = Double(w.start) / Double(rate)
            if Silence.isSilent(w.samples, rate: rate) {
                windows.append((start, [])); progress("\(label): \(Export.clock(start)) silent, skipped"); return
            }
            let ws = try recognize(w.samples, recognizer: recognizer).map {
                Word(start: $0.start + start, end: $0.end + start, text: $0.text)
            }
            windows.append((start, ws))
            progress("\(label): \(Export.clock(start + Double(w.samples.count) / Double(rate))) done")
        }
        let offset = try Transcriber.decode(asset: asset, track: track) { s in
            total += s.count
            for w in split.push(s) { try run(w) }
        }
        if let w = split.finish() { try run(w) }
        let words = Overlap.merge(windows).map { Word(start: $0.start + offset, end: $0.end + offset, text: $0.text) }
        return (words, Double(total) / Double(rate))
    }

    /// One window, one on-device request; word times from the start of the window.
    static func recognize(_ samples: [Float], recognizer: SFSpeechRecognizer) throws -> [Word] {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Transcriber.rate), channels: 1, interleaved: false)!
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) else { return [] }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true      // never the server
        req.shouldReportPartialResults = false
        req.addsPunctuation = true
        req.append(buf)
        req.endAudio()

        // On macOS 14+ the recognizer starts over after each pause: a result
        // that ends an utterance carries metadata, and the final result holds
        // only the last utterance. So every utterance is collected as it ends.
        let lock = NSLock(), sem = DispatchSemaphore(value: 0)
        var answer: Result<[Word], Error>?
        var heard: [Word] = []
        let task = recognizer.recognitionTask(with: req) { result, error in
            lock.lock(); defer { lock.unlock() }
            guard answer == nil else { return }
            if let r = result {
                var ends = r.isFinal
                if #available(macOS 14, *) { ends = ends || r.speechRecognitionMetadata != nil }
                if ends {
                    heard = Utterances.accumulate(heard, r.bestTranscription.segments.map {
                        Word(start: $0.timestamp, end: $0.timestamp + $0.duration, text: $0.substring)
                    })
                }
                if r.isFinal { answer = .success(heard); sem.signal() }
            } else if let e = error as NSError? {
                // 1110: no speech (left) in the window. Not a failure: what was heard stands.
                answer = e.code == 1110 ? .success(heard) : .failure(TranscribeError.recognition("\(e.domain) \(e.code): \(e.localizedDescription)"))
                sem.signal()
            }
        }
        let limit = Double(samples.count) / Double(Transcriber.rate) * 4 + 60
        if sem.wait(timeout: .now() + limit) == .timedOut {
            task.cancel()
            throw TranscribeError.recognition("no answer in \(Int(limit)) s")
        }
        lock.lock(); defer { lock.unlock() }
        return try answer!.get()
    }
}

#if compiler(>=6.2)
/// SpeechAnalyzer + SpeechTranscriber (macOS 26). Each track is decoded to a
/// temporary 16 kHz file the analyzer reads, and the file is deleted after.
@available(macOS 26, *)
enum Analyzer {
    /// True when the analyzer can run for `id`. Installs the model when it is
    /// missing and downloads are allowed. When `required` is false, a language
    /// the analyzer lacks answers false (the caller falls back to
    /// SFSpeechRecognizer, also on device); when true, it throws.
    static func ready(_ id: String, allowDownload: Bool, required: Bool, progress: @escaping (String) -> Void) throws -> Bool {
        try Blocking.run {
            guard SpeechTranscriber.isAvailable,
                  let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) else {
                if required { throw TranscribeError.onDeviceUnavailable("\(id) (SpeechTranscriber)") }
                progress("SpeechTranscriber has no \(id) on this Mac; using SFSpeechRecognizer on device")
                return false
            }
            let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
            if await AssetInventory.status(forModules: [t]) != .installed {
                guard allowDownload else { throw TranscribeError.modelMissing(id) }
                if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
                    progress("installing the on-device model for \(id) (the model is downloaded, no audio leaves the Mac)")
                    try await req.downloadAndInstall()
                }
                guard await AssetInventory.status(forModules: [t]) == .installed else { throw TranscribeError.modelMissing(id) }
            }
            return true
        }
    }

    static func words(asset: AVAsset, track: AVAssetTrack, id: String, label: String,
                      progress: @escaping (String) -> Void) throws -> ([Word], Double) {
        let rate = Transcriber.rate
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ipsio-transcribe-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false)!
        var total = 0, loudest = -200.0
        let offset: Double
        do {
            let file = try AVAudioFile(forWriting: tmp, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            offset = try Transcriber.decode(asset: asset, track: track) { s in
                total += s.count
                loudest = max(loudest, Silence.peakDB(s, rate: rate))
                guard let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(s.count)) else { return }
                b.frameLength = AVAudioFrameCount(s.count)
                s.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: s.count) }
                try file.write(from: b)
            }
        } catch let e as TranscribeError { throw e } catch { throw TranscribeError.read(error.localizedDescription) }
        let seconds = Double(total) / Double(rate)
        if total == 0 || loudest < Silence.thresholdDB { progress("\(label): silent, skipped"); return ([], seconds) }
        progress("\(label): \(Export.clock(seconds)) of audio, transcribing")

        let words: [Word] = try Blocking.run {
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) else {
                throw TranscribeError.onDeviceUnavailable(id)
            }
            let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
            let analyzer = SpeechAnalyzer(modules: [t])
            let collect = Task { () throws -> [Word] in
                var out: [Word] = [], step = 0.0
                for try await r in t.results where r.isFinal {
                    for run in r.text.runs {
                        guard let tr = run.audioTimeRange else { continue }
                        let text = String(r.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        if text.isEmpty { continue }
                        out.append(Word(start: tr.start.seconds + offset, end: tr.end.seconds + offset, text: text))
                    }
                    let at = r.range.end.seconds
                    if seconds > 0, at / seconds >= step + 0.1 { step = (at / seconds * 10).rounded(.down) / 10; progress("\(label): \(Int(step * 100))%") }
                }
                return out
            }
            do {
                let file = try AVAudioFile(forReading: tmp)
                if let last = try await analyzer.analyzeSequence(from: file) { try await analyzer.finalizeAndFinish(through: last) }
                else { await analyzer.cancelAndFinishNow() }
            } catch {
                collect.cancel()
                throw TranscribeError.recognition(error.localizedDescription)
            }
            return try await collect.value
        }
        return (words, seconds)
    }
}
#endif

/// Waits for async work from synchronous code (the CLI's main thread, or the
/// app's background queue). Never call it from inside a Swift concurrency task.
enum Blocking {
    final class Box<T>: @unchecked Sendable { var r: Result<T, Error>? }
    static func run<T>(_ op: @escaping () async throws -> T) throws -> T {
        let box = Box<T>(), sem = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.r = .success(try await op()) } catch { box.r = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return try box.r!.get()
    }
}
