// TranscribeCLI.swift: ipsio-transcribe, the transcription from Terminal.
//   ipsio-transcribe <file.mov> [pt|en] [--engine auto|analyzer|legacy] [--no-download]
// Writes "<name>.txt", ".srt" and ".md" next to the recording, on device only.
//
// SFSpeechRecognizer asks for the Speech Recognition permission, and a
// binary with no Info.plist is killed when it asks. So the build embeds one:
//   printf '%s' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>app.ipsio.transcribe</string><key>NSSpeechRecognitionUsageDescription</key><string>Transcribes recordings on this Mac.</string></dict></plist>' > /tmp/ipsio-transcribe.plist
//   swiftc -O -parse-as-library app/Transcribe/*.swift tools/TranscribeCLI.swift -o /tmp/ipsio-transcribe \
//     -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker /tmp/ipsio-transcribe.plist
// Exit codes: 0 written, 1 transcription or write failed, 2 usage.
import Foundation

@main
struct TranscribeCLI {
    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        var engine = TranscribeEngine.auto, download = true
        if let i = args.firstIndex(of: "--engine"), i + 1 < args.count, let e = TranscribeEngine(rawValue: args[i + 1]) {
            engine = e; args.removeSubrange(i...i + 1)
        }
        if let i = args.firstIndex(of: "--no-download") { download = false; args.remove(at: i) }
        guard (1...2).contains(args.count), !args[0].hasPrefix("-") else {
            print("usage: ipsio-transcribe <file.mov> [pt|en] [--engine auto|analyzer|legacy] [--no-download]"); exit(2)
        }
        let path = (args[0] as NSString).standardizingPath
        let lang = args.count > 1 ? args[1] : "pt"
        guard FileManager.default.fileExists(atPath: path) else { print("no such file: \(path)"); exit(2) }
        guard let id = Language.identifier(lang) else { print("unknown language \"\(lang)\" (pt or en)"); exit(2) }

        let t0 = Date()
        func log(_ s: String) { print(String(format: "[%6.1fs] ", Date().timeIntervalSince(t0)) + s); fflush(stdout) }
        log("\((path as NSString).lastPathComponent), \(id), engine \(engine.rawValue)")
        do {
            let r = try Transcriber.transcribe(path: path, language: id, engine: engine, allowModelDownload: download, progress: log)
            let files = try Export.write(r.segments, media: path, language: id)
            let speed = r.seconds > 0 ? r.audioSeconds / r.seconds : 0
            log(String(format: "engine=%@ audio=%.1fs took=%.1fs speed=%.1fx realtime lines=%d", r.engine, r.audioSeconds, r.seconds, speed, r.segments.count))
            for f in files { print("wrote \(f)") }
            print("")
            print(Export.txt(r.segments), terminator: "")
        } catch {
            log("FAILED: \(error)")
            exit(1)
        }
    }
}
