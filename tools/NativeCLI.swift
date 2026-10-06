// NativeCLI.swift: ipsio-native, the app's backend from Terminal. The
// recording lives in the process, so the commands run in sequence in one go,
// each printing exactly what the app would parse:
//   swiftc -O -parse-as-library app/Engine/*.swift tools/NativeCLI.swift -o /tmp/ipsio-native
//   IPSIO_DIR=/tmp/x /tmp/ipsio-native doctor start sleep:10 level check stop test
// The conf is $IPSIO_DIR/conf (KEY='value' lines), as for the app.
// IPSIO_TARGET=window:<id> records one window for this run (CAPTURE_TARGET keeps a display).
// IPSIO_MIC=avcapture takes the microphone through AVCaptureSession (the macOS
// 13/14 path) even on 15+, to exercise it on a new Mac. Debug only.
import Foundation

@main
struct NativeCLI {
    static func conf(_ dir: String) -> [String: String] {
        var d: [String: String] = [:]
        for l in ((try? String(contentsOfFile: dir + "/conf", encoding: .utf8)) ?? "").components(separatedBy: .newlines) {
            guard let i = l.firstIndex(of: "="), !l.hasPrefix("#") else { continue }
            var v = String(l[l.index(after: i)...]).trimmingCharacters(in: .whitespaces)
            if v.count >= 2, let f = v.first, f == "'" || f == "\"", v.last == f { v = String(v.dropFirst().dropLast()) }
            d[String(l[..<i]).trimmingCharacters(in: .whitespaces)] = v
        }
        return d
    }

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard !args.isEmpty else { print("usage: ipsio-native <command|sleep:N>..."); exit(2) }
        let dir = ProcessInfo.processInfo.environment["IPSIO_DIR"] ?? (NSHomeDirectory() + "/.ipsio")
        let b = Backend(dir: dir, capture: Recorder(), conf: { conf(dir) })
        var env: [String: String] = [:]
        for k in ["IPSIO_TITLE", "IPSIO_MODE", "IPSIO_TARGET", "IPSIO_MIC"] { if let v = ProcessInfo.processInfo.environment[k] { env[k] = v } }
        for a in args {
            if a.hasPrefix("sleep:"), let s = Double(a.dropFirst(6)) { Thread.sleep(forTimeInterval: s); continue }
            print("== \(a)")
            print(b.run(a, env: env))
        }
        if b.recording { print("== stop (left recording)"); print(b.run("stop")) }
        Thread.sleep(forTimeInterval: 1)   // the .sha256 is written in the background
    }
}
