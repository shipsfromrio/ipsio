// RecCLI.swift: ipsio-rec, the native engine from Terminal. Records for N
// seconds (or until Ctrl-C), prints the live level every 5 s like the app's
// alarm would read it, then the summary and the .sha256. The way to prove the
// engine on a real Mac before the app uses it.
//   swiftc -O -parse-as-library app/Engine/*.swift tools/RecCLI.swift -o /tmp/ipsio-rec
//   /tmp/ipsio-rec <folder> <seconds> [class|meeting] [title]
import Foundation

@main
struct RecCLI {
    static func main() {
        let a = CommandLine.arguments
        guard a.count >= 3, let secs = Double(a[2]) else {
            print("usage: ipsio-rec <folder> <seconds> [class|meeting] [title]"); exit(2)
        }
        let r = Recorder()
        var o = Recorder.Options(folder: a[1])
        o.meeting = a.count > 3 && a[3] == "meeting"
        o.title = a.count > 4 ? a[4] : ""
        let started = DispatchSemaphore(value: 0)
        r.start(o) { res in
            switch res {
            case .success(let p): print("RECORDING \(o.meeting ? "meeting" : "class") -> \(p)")
            case .failure(let e): print("DID NOT START: \(e)"); exit(1)
            }
            started.signal()
        }
        started.wait()
        let end = DispatchSemaphore(value: 0)
        signal(SIGINT, SIG_IGN)
        let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global()); sig.setEventHandler { end.signal() }; sig.resume()
        let tick = DispatchSource.makeTimerSource(queue: .global())
        tick.schedule(deadline: .now() + 5, repeating: 5)
        tick.setEventHandler {
            if let l = r.level() { print("#state verdict=\(l.verdict) silence=\(l.silence)\(l.micSilence.map { " mic_silence=\($0)" } ?? "")") }
            if let e = r.stoppedByItself { print("STOPPED BY ITSELF: \(e)") }
        }
        tick.resume()
        _ = end.wait(timeout: .now() + secs)
        tick.cancel()
        guard let s = r.stop() else { print("NOT RECORDING"); exit(1) }
        print(String(format: "SAVED %@ seconds=%.1f sound=%@ silence_pct=%d mean=%.1f%@ complete=%@ dropped=%d",
                     s.file, s.seconds, s.sound.rawValue, s.silencePct, s.average,
                     s.mic.map { " microphone=\($0.rawValue) dead_pct=\(s.micDeadPct ?? 0)" } ?? "",
                     s.complete ? "yes" : "NO", s.dropped))
        print("sha256 " + (Evidence.write(for: s.file) ?? "FAILED"))
        withExtendedLifetime(sig) {}
        exit(s.complete ? 0 : 1)
    }
}
