// Sound.swift: the native engine's live meter and the verdicts drawn from it.
// Same thresholds and the same rules as ipsio.sh (classify, trailing_silence,
// sound_summary, mic_summary), so the app says the same thing whichever engine
// recorded: one sample per second, each the RMS of the last 10 s, in dB.
// Pure: no capture here, so the bench feeds it numbers.
import Foundation

enum Sound {
    static let silenceDB: Float = -60   // computer sound below this = nobody talking there
    static let micDeadDB: Float = -80   // microphone below this = a dead microphone, not silence
    static let staleSeconds: Double = 20 // no new sample this long while recording = no sound coming in

    enum Verdict: String { case noSound = "NO_SOUND", low = "LOW", loud = "LOUD", ok = "OK" }

    /// Decided by the AVERAGE, not the peak: a click hits 0 dB with the average at -20.
    static func classify(_ db: Float?) -> Verdict {
        guard let x = db, x.isFinite, x >= silenceDB else { return .noSound }
        if x < -35 { return .low }
        if x > -10 { return .loud }
        return .ok
    }

    static func below(_ x: Float, _ limit: Float) -> Bool { !x.isFinite || x < limit }

    /// Consecutive seconds below `limit` at the end.
    static func trailingSilence(_ samples: [Float], _ limit: Float = silenceDB) -> Int {
        var n = 0
        for x in samples.reversed() { if below(x, limit) { n += 1 } else { break } }
        return n
    }

    enum Summary: String { case silent = "SILENT", gaps = "GAPS", low = "LOW", ok = "OK", noMeasure = "NO_MEASURE" }

    /// The whole recording: 90% silent = SILENT; 40% = GAPS (a lunch break
    /// recorded along, 13% on a real day, must not count); then the average.
    static func summary(_ samples: [Float]) -> (Summary, pct: Int, avg: Float) {
        guard !samples.isEmpty else { return (.noMeasure, 0, -99) }
        let loud = samples.filter { !below($0, silenceDB) }
        let pct = 100 * (samples.count - loud.count) / samples.count
        let avg = loud.isEmpty ? -99 : loud.reduce(0, +) / Float(loud.count)
        if pct >= 90 { return (.silent, pct, avg) }
        if pct >= 40 { return (.gaps, pct, avg) }
        return (avg < -35 ? .low : .ok, pct, avg)
    }

    enum Mic: String { case dead = "DEAD", ok = "OK", noMeasure = "NO_MEASURE" }

    /// DEAD at 90% or more of the time below the dead-microphone threshold.
    static func micSummary(_ samples: [Float]) -> (Mic, pct: Int) {
        guard !samples.isEmpty else { return (.noMeasure, 0) }
        let pct = 100 * samples.filter { below($0, micDeadDB) }.count / samples.count
        return (pct >= 90 ? .dead : .ok, pct)
    }

    static func dB(_ meanSquare: Double) -> Float { meanSquare > 0 ? Float(10 * log10(meanSquare)) : -Float.infinity }
}

/// One live meter: audio arrives in buffers of any size; every whole second
/// becomes one sample, the RMS of the last 10 s (like astats reset=10 in
/// ipsio.sh, but rolling instead of a sawtooth). Not thread-safe: the
/// capture feeds it from one queue and reads the summary from the same one.
struct Meter {
    private(set) var samples: [Float] = []
    private(set) var lastSampleAt: Double?      // host seconds of the last completed second
    private var startedAt: Double?
    private var second = 0                     // index of the second being filled
    private var energy = 0.0, count = 0         // of the current second
    private var window: [(Double, Int)] = []    // the last 10 completed seconds

    /// `sumSquares` over `frames` values (all channels), the buffer starting at host time `t`.
    mutating func add(sumSquares: Double, frames: Int, at t: Double) {
        if startedAt == nil { startedAt = t }
        let s = Int((t - startedAt!).rounded(.down))
        while s > second { close(at: startedAt! + Double(second + 1)) }
        energy += sumSquares; count += frames
    }

    private mutating func close(at t: Double) {
        window.append((energy, count)); if window.count > 10 { window.removeFirst() }
        let e = window.reduce(0) { $0 + $1.0 }, n = window.reduce(0) { $0 + $1.1 }
        samples.append(n > 0 ? Sound.dB(e / Double(n)) : -Float.infinity)
        lastSampleAt = t; second += 1; energy = 0; count = 0
    }

    var last: Float? { samples.last }

    /// Seconds without a new sample, measured from the start when there is none yet.
    func age(now: Double, recordingStart: Double) -> Double { now - (lastSampleAt ?? recordingStart) }
}

/// What "level" reports while recording: the same fields as the script's
/// #state line, so the app's alarm logic does not care which engine runs.
struct Level: Equatable {
    let verdict: String          // NO_SOUND | LOW | LOUD | OK | MEASURING
    let silence: Int             // seconds
    let micSilence: Int?         // meeting mode only

    static func of(system: Meter, mic: Meter?, now: Double, start: Double) -> Level {
        let micSil = mic.map { m in m.samples.isEmpty ? system.samples.count : Sound.trailingSilence(m.samples, Sound.micDeadDB) }
        // A meter that stopped getting buffers is silence, not "measuring"
        // forever nor the last good value repeated (fail closed).
        let age = system.age(now: now, recordingStart: start)
        if age > Sound.staleSeconds { return Level(verdict: "NO_SOUND", silence: Int(age), micSilence: micSil) }
        guard let last = system.last else { return Level(verdict: "MEASURING", silence: 0, micSilence: micSil) }
        return Level(verdict: Sound.classify(last).rawValue, silence: Sound.trailingSilence(system.samples), micSilence: micSil)
    }
}
