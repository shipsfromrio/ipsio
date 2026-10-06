// LiveTranscriber.swift: the running capture's audio, transcribed as it
// comes, on this Mac only (SFSpeechRecognizer with requiresOnDeviceRecognition:
// fail closed, never the server). One request per track: the computer sound
// is Others, the microphone is Me (the speaker comes from the track, as in
// app/Transcribe). A request ends after a pause (LiveCut) so its line comes
// out final, and a new one starts; the report goes to `onLine`.
import AVFoundation
import Foundation
import Speech

final class LiveTranscriber {
    /// (speaker, text, final). Called on the transcriber's own queue.
    var onLine: ((Speaker, String, Bool) -> Void)?

    private let q = DispatchQueue(label: "ipsio.helper.live")
    private let recognizer: SFSpeechRecognizer
    private let clock: () -> Double
    private final class Lane {
        let who: Speaker
        var req: SFSpeechAudioBufferRecognitionRequest?
        var task: SFSpeechRecognitionTask?
        var started = 0.0, lastChange: Double?, text = "", lastFinal = ""
        init(_ who: Speaker) { self.who = who }
    }
    private var lanes: [Speaker: Lane] = [:]
    private var timer: DispatchSourceTimer?
    private var running = false

    /// Fails (with the reason, for the panel) when on-device recognition is
    /// not there for the language. Blocks for the authorization: call off main.
    init(language: String, clock: @escaping () -> Double) throws {
        guard let id = Language.identifier(language) else { throw TranscribeError.language(language) }
        recognizer = try Legacy.recognizer(id)   // authorized, on device, available; else throws
        recognizer.defaultTaskHint = .dictation
        self.clock = clock
    }

    func start() {
        q.async {
            guard !self.running else { return }
            self.running = true
            let t = DispatchSource.makeTimerSource(queue: self.q)
            t.schedule(deadline: .now() + 0.5, repeating: 0.5)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume(); self.timer = t
        }
    }

    func stop() {
        q.sync {
            running = false; timer?.cancel(); timer = nil
            for l in lanes.values { l.req?.endAudio(); l.task?.cancel() }
            lanes = [:]
        }
    }

    /// A buffer from the capture (Recorder.audioTap).
    func feed(_ track: Recorder.AudioTrack, _ sb: CMSampleBuffer) {
        q.async {
            guard self.running else { return }
            let who: Speaker = track == .mic ? .me : .others
            let lane = self.lanes[who] ?? { let l = Lane(who); self.lanes[who] = l; return l }()
            if lane.req == nil { self.open(lane) }
            lane.req?.appendAudioSampleBuffer(sb)
        }
    }

    private func open(_ lane: Lane) {
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.requiresOnDeviceRecognition = true   // never the server
        r.shouldReportPartialResults = true
        r.addsPunctuation = true
        lane.req = r; lane.started = clock(); lane.lastChange = nil; lane.text = ""
        lane.task = recognizer.recognitionTask(with: r) { [weak self, weak lane] result, error in
            guard let self = self, let lane = lane else { return }
            self.q.async {
                guard self.running, lane.req === r else {
                    // An ended request still delivers its last line.
                    if let res = result, res.isFinal { self.emitFinal(lane, res.bestTranscription.formattedString) }
                    return
                }
                if let res = result {
                    let text = res.bestTranscription.formattedString
                    // macOS 14+: the metadata marks the end of an utterance (the next result starts over).
                    if res.isFinal || res.speechRecognitionMetadata != nil { self.emitFinal(lane, text); lane.text = ""; lane.lastChange = nil }
                    else if text != lane.text { lane.text = text; lane.lastChange = self.clock(); self.onLine?(lane.who, text, false) }
                }
                if error != nil || (result?.isFinal ?? false) { lane.req = nil; lane.task = nil }
            }
        }
    }

    private func emitFinal(_ lane: Lane, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != lane.lastFinal else { return }   // a cut after a metadata line repeats it
        lane.lastFinal = t
        onLine?(lane.who, t, true)
    }

    private func tick() {
        let now = clock()
        for lane in lanes.values {
            guard let r = lane.req else { continue }
            if LiveCut.shouldCut(requestStarted: lane.started, lastChange: lane.lastChange, hasText: !lane.text.isEmpty, now: now) {
                // End this request (its final line arrives by itself) and open the next on the next buffer.
                r.endAudio(); lane.req = nil
            }
        }
    }
}
