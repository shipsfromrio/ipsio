// CalendarCLI.swift: ipsio-calendar, the calendar seen from Terminal. It reads
// the SAME sources as the app (~/.ipsio/calendar.url, calendar.txt,
// CALENDAR_COMMAND) with the SAME functions, and prints what would be
// recorded. It is how to check a source before trusting it, without waiting
// for the meeting.
//   ipsio-calendar               upcoming meetings the app would record
//   ipsio-calendar file.ics      reads a local .ics (or a URL) and lists what is kept
// It never prints the secret address.
import Foundation

@main
struct CalendarCLI {
    static func main() {
        let dir = ProcessInfo.processInfo.environment["IPSIO_DIR"] ?? (NSHomeDirectory() + "/.ipsio")
        let conf = readConf(dir + "/conf")
        // Reads the Mac's Calendar only if this Terminal already has the
        // permission; it never asks (the app asks, under its own name).
        MacCalendar.install()
        Schedule.lang = Schedule.language(conf)
        let L = Schedule.L
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        let args = Array(CommandLine.arguments.dropFirst())
        let now = Date()
        var meetings: [Meeting] = [], errors: [String] = [], warnings: [String] = []
        if let target = args.first {
            switch Sources.fetch(target) {
            case .success(let t):
                let r = Schedule.readICS(t, from: now.addingTimeInterval(-86400), to: now.addingTimeInterval(7 * 86400), me: conf["CALENDAR_ME"] ?? "")
                meetings = r.meetings; warnings = r.warnings
            case .failure(let e): errors.append("\(e)")
            }
        } else {
            let sources = Sources(dir: dir, conf: conf)
            if sources.configured.isEmpty {
                print(L("no calendar source configured in \(dir) (calendar.url, calendar.txt, CALENDAR_COMMAND or CALENDAR_MACOS)",
                        "nenhuma fonte de agenda configurada em \(dir) (calendar.url, calendar.txt, CALENDAR_COMMAND ou CALENDAR_MACOS)"))
                exit(2)
            }
            let r = sources.read(now: now)
            meetings = Schedule.merge(fresh: r.meetings, sourcesOk: r.sourcesOk, cache: sources.readCache())
            errors = r.errors; warnings = r.warnings
            print(L("sources: ", "fontes: ") + sources.configured.joined(separator: ", ")
                  + L("; answered: ", "; responderam: ") + r.sourcesOk.sorted().joined(separator: ", "))
        }
        let after = Double(conf["CALENDAR_AFTER_MIN"] ?? "5").map { $0 * 60 } ?? 300
        for e in Schedule.upcoming(now: now, meetings: meetings, after: after, n: 50) {
            print("\(f.string(from: e.start)) - \(f.string(from: e.end).suffix(5))  \(e.title)  [\(e.source)]\(e.link.isEmpty ? "" : "  " + e.link)")
        }
        for w in warnings { print(L("warning: ", "aviso: ") + w) }
        for e in errors { print(L("ERROR: ", "ERRO: ") + e) }
        exit(errors.isEmpty ? 0 : 1)
    }

    static func readConf(_ p: String) -> [String: String] {
        var d: [String: String] = [:]
        guard let s = try? String(contentsOfFile: p, encoding: .utf8) else { return d }
        for l in s.components(separatedBy: .newlines) {
            guard let i = l.firstIndex(of: "=") else { continue }
            var v = String(l[l.index(after: i)...])
            if v.hasPrefix("'") && v.hasSuffix("'") && v.count >= 2 { v = String(v.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'") }
            d[String(l[..<i])] = v
        }
        return d
    }
}
