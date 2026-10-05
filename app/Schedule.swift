// Schedule.swift: where the meeting list comes from and WHEN to record each one.
//
// Everything here is a pure function (text and clock in, list and decision
// out), except `Sources`, which reads files, URLs and commands. That is why the
// bench (tests/ScheduleTests.swift) runs with no real Mac: the app and the
// ipsio-calendar CLI call exactly these functions.
//
// Sources (pluggable provider, no credential in the code):
// - ics: the calendar's secret iCal address (Google, Outlook, iCloud: "secret
//   address in iCal format"), one per line in ~/.ipsio/calendar.url. A local
//   .ics file works too. Only events with a Meet, Zoom, Teams or Webex link
//   are kept.
// - list: ~/.ipsio/calendar.txt, one meeting per line
//   "YYYY-MM-DD HH:MM HH:MM Name". Everything is kept (whoever wrote it wants
//   it recorded).
// - command: CALENDAR_COMMAND in the conf, a program that prints lines in the
//   list format. It is the door for a calendar behind its own credential (the
//   credential stays in that program, never in Ipsio).
//
// iCal stores a weekly meeting as ONE entry with a rule (RRULE), exceptions
// (EXDATE) and moved occurrences (RECURRENCE-ID). Reading only DTSTART records
// the first week and misses all the others; that is why expansion lives here,
// with a bench. A rule this expansion does not understand becomes a WARNING in
// the menu, never silence.
import Foundation

struct Meeting: Equatable {
    let id: String        // stable per occurrence: "skip" works through it
    let title: String
    let start: Date
    let end: Date
    let link: String
    let source: String    // "ics", "list", "command": one failing does not erase the others
}

enum Schedule {
    /// Language of the warnings and errors ("en" or "pt"); the app and the CLI
    /// set it from UI_LANGUAGE.
    nonisolated(unsafe) static var lang = "en"
    static func L(_ en: String, _ pt: String) -> String { lang == "pt" ? pt : en }
    /// UI_LANGUAGE from the conf, else the system language (same rule as ipsio.sh).
    static func language(_ conf: [String: String]) -> String {
        if let l = conf["UI_LANGUAGE"], l == "pt" || l == "en" { return l }
        return (Locale.preferredLanguages.first ?? "en").hasPrefix("pt") ? "pt" : "en"
    }
    static var untitled: String { L("(untitled)", "(sem título)") }

    // ================================================================ iCal ===
    struct Prop {
        let name: String
        let params: [String: String]
        let value: String
    }

    /// Logical lines: iCal folds long lines with CRLF + space (RFC 5545 3.1).
    static func unfold(_ text: String) -> [String] {
        var out: [String] = []
        let raw = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for l in raw.components(separatedBy: "\n") {
            if let c = l.first, c == " " || c == "\t", !out.isEmpty {
                out[out.count - 1] += String(l.dropFirst())
            } else {
                out.append(l)
            }
        }
        return out
    }

    /// NAME;PARAM=V;PARAM="V":VALUE. Quotes protect ':' and ';' inside a parameter.
    static func prop(_ line: String) -> Prop? {
        var name = "", params: [String: String] = [:]
        var i = line.startIndex, quoted = false, field = "", pk = ""
        var phase = 0 // 0 name, 1 parameter key, 2 parameter value
        while i < line.endIndex {
            let c = line[i]
            if c == "\"" { quoted.toggle(); i = line.index(after: i); continue }
            if !quoted && (c == ";" || c == ":") {
                if phase == 0 { name = field } else if phase == 2 { params[pk.uppercased()] = field }
                field = ""
                if c == ":" { return Prop(name: name.uppercased(), params: params, value: String(line[line.index(after: i)...])) }
                phase = 1
            } else if !quoted && c == "=" && phase == 1 {
                pk = field; field = ""; phase = 2
            } else {
                field.append(c)
            }
            i = line.index(after: i)
        }
        return nil
    }

    static func text(_ v: String) -> String {
        var out = "", esc = false
        for c in v {
            if esc {
                switch c { case "n", "N": out.append("\n"); default: out.append(c) }
                esc = false
            } else if c == "\\" { esc = true } else { out.append(c) }
        }
        return out
    }

    static var gregorian: Calendar { Calendar(identifier: .gregorian) }

    /// An iCal date. The Bool is true for a date-only value (all-day event).
    static func date(_ v: String, tzid: String?, fallback: TimeZone, warnings: inout [String]) -> (Date, Bool)? {
        let s = v.trimmingCharacters(in: .whitespaces)
        let utc = s.hasSuffix("Z")
        let d = utc ? String(s.dropLast()) : s
        let parts = d.split(separator: "T")
        guard let day = parts.first, day.count == 8, let y = Int(day.prefix(4)),
              let mo = Int(day.dropFirst(4).prefix(2)), let da = Int(day.suffix(2)) else { return nil }
        var tz = fallback
        if utc { tz = TimeZone(identifier: "UTC")! }
        else if let t = tzid {
            if let z = TimeZone(identifier: t) { tz = z }
            else { warnings.append(L("unknown time zone '\(t)'; used the Mac's", "fuso '\(t)' desconhecido; usei o do Mac")) }
        }
        var cal = gregorian; cal.timeZone = tz
        var dc = DateComponents(year: y, month: mo, day: da, hour: 0, minute: 0, second: 0)
        if parts.count == 2 {
            let h = parts[1]
            guard h.count >= 4, let hh = Int(h.prefix(2)), let mm = Int(h.dropFirst(2).prefix(2)) else { return nil }
            dc.hour = hh; dc.minute = mm; dc.second = h.count >= 6 ? Int(h.dropFirst(4).prefix(2)) ?? 0 : 0
        }
        guard let dt = cal.date(from: dc) else { return nil }
        return (dt, parts.count == 1)
    }

    static func duration(_ v: String) -> TimeInterval? {
        // PT1H30M, P1D, -PT15M (a negative one is no use as an event end)
        var s = Substring(v.uppercased())
        guard s.first == "P" || s.hasPrefix("+P") else { return nil }
        if s.first == "+" { s = s.dropFirst() }
        s = s.dropFirst()
        var total: TimeInterval = 0, num = "", afterT = false
        for c in s {
            if c.isNumber { num.append(c); continue }
            let n = TimeInterval(Int(num) ?? 0); num = ""
            switch c {
            case "T": afterT = true
            case "W": total += n * 7 * 86400
            case "D": total += n * 86400
            case "H": total += n * 3600
            case "M": total += afterT ? n * 60 : n * 30 * 86400
            case "S": total += n
            default: return nil
            }
        }
        return total
    }

    static let linkPattern: NSRegularExpression = try! NSRegularExpression(
        pattern: #"https?://(?:meet\.google\.com/[a-z0-9-]+|(?:[a-z0-9-]+\.)*zoom\.us/(?:j|my|w|s)/[^\s"'<>\\]+|teams\.microsoft\.com/l/meetup-join/[^\s"'<>\\]+|teams\.live\.com/meet/[^\s"'<>\\]+|(?:[a-z0-9-]+\.)*webex\.com/(?:meet|join|[a-z0-9-]+/j\.php)[^\s"'<>\\]*)"#,
        options: [.caseInsensitive])

    /// The first meeting link in the texts, or "".
    static func link(_ texts: [String]) -> String {
        for t in texts {
            let r = NSRange(t.startIndex..., in: t)
            if let m = linkPattern.firstMatch(in: t, range: r), let rr = Range(m.range, in: t) {
                var l = String(t[rr])
                while let u = l.last, ".,;)>".contains(u) { l.removeLast() }
                return l
            }
        }
        return ""
    }

    struct Raw {
        var uid = "", title = "", status = "", start: Date? = nil, allDay = false
        var end: Date? = nil, dur: TimeInterval? = nil, rrule = "", recId: Date? = nil
        var exDates: [Date] = [], exDays: [DateComponents] = [], tz = TimeZone.current
        var texts: [String] = [], declined = false
    }

    /// Reads the iCal and returns the occurrences that overlap [from, to],
    /// already expanded, without cancelled ones, without those declined by `me`
    /// and (when `linkOnly`) only those with a meeting link. `warnings` says
    /// what was not understood.
    static func readICS(_ text: String, from: Date, to: Date, me: String = "", linkOnly: Bool = true,
                        zone: TimeZone = .current, source: String = "ics") -> (meetings: [Meeting], warnings: [String]) {
        var warnings: [String] = []
        var raws: [Raw] = []
        var cur: Raw? = nil
        var depth = 0 // a VALARM inside a VEVENT has its own DESCRIPTION
        var meLower = me.lowercased().trimmingCharacters(in: .whitespaces)
        if meLower.hasPrefix("mailto:") { meLower = String(meLower.dropFirst("mailto:".count)) }
        for line in unfold(text) {
            guard let p = prop(line) else { continue }
            if p.name == "BEGIN" {
                if p.value.uppercased() == "VEVENT" { cur = Raw(); cur?.tz = zone; depth = 0 }
                else if cur != nil { depth += 1 }
                continue
            }
            if p.name == "END" {
                if p.value.uppercased() == "VEVENT", let b = cur { raws.append(b); cur = nil }
                else if cur != nil { depth -= 1 }
                continue
            }
            guard cur != nil, depth == 0 else { continue }
            let tzid = p.params["TZID"]
            switch p.name {
            case "UID": cur!.uid = p.value
            case "SUMMARY": cur!.title = Schedule.text(p.value)
            case "STATUS": cur!.status = p.value.uppercased()
            case "DTSTART":
                if case let (d, ad)? = date(p.value, tzid: tzid, fallback: zone, warnings: &warnings) {
                    cur!.start = d; cur!.allDay = ad || p.params["VALUE"]?.uppercased() == "DATE"
                    if let t = tzid, let z = TimeZone(identifier: t) { cur!.tz = z }
                    if p.value.hasSuffix("Z") { cur!.tz = TimeZone(identifier: "UTC")! }
                }
            case "DTEND": cur!.end = date(p.value, tzid: tzid, fallback: zone, warnings: &warnings)?.0
            case "DURATION": cur!.dur = duration(p.value)
            case "RRULE": cur!.rrule = p.value
            case "RECURRENCE-ID":
                if case let (d, _)? = date(p.value, tzid: tzid, fallback: zone, warnings: &warnings) { cur!.recId = d }
            case "EXDATE":
                for v in p.value.split(separator: ",") {
                    if case let (d, ad)? = date(String(v), tzid: tzid, fallback: zone, warnings: &warnings) {
                        if ad || p.params["VALUE"]?.uppercased() == "DATE" {
                            var cal = gregorian; cal.timeZone = zone
                            cur!.exDays.append(cal.dateComponents([.year, .month, .day], from: d))
                        } else { cur!.exDates.append(d) }
                    }
                }
            case "LOCATION", "DESCRIPTION", "URL", "X-GOOGLE-CONFERENCE", "X-MICROSOFT-SKYPETEAMSMEETINGURL":
                cur!.texts.append(Schedule.text(p.value))
            case "ATTENDEE":
                // Exact address, not a suffix: "ana@example.com" must not match a
                // colleague "joana@example.com" who declined.
                var who = p.value.lowercased().trimmingCharacters(in: .whitespaces)
                if who.hasPrefix("mailto:") { who = String(who.dropFirst("mailto:".count)) }
                if !meLower.isEmpty, who == meLower,
                   p.params["PARTSTAT"]?.uppercased() == "DECLINED" { cur!.declined = true }
            default: break
            }
        }

        // Moved occurrences: (uid, original start) -> the new (or cancelled) one.
        var moved: [String: Raw] = [:]
        for b in raws where b.recId != nil { moved[b.uid + "@" + key(b.recId!)] = b }

        var out: [Meeting] = []
        func emit(_ b: Raw, start: Date, original: Date) {
            guard b.status != "CANCELLED", !b.declined, !b.allDay else { return }
            // The master's duration applies to every occurrence; a moved one has its own.
            let end: Date
            if let f = b.end, let s0 = b.start { end = start.addingTimeInterval(f.timeIntervalSince(s0)) }
            else { end = start.addingTimeInterval(b.dur ?? 3600) }
            guard end > start else { return }
            if end.timeIntervalSince(start) > 12 * 3600 { warnings.append(L("'\(b.title)' lasts more than 12 h; left out", "'\(b.title)' dura mais de 12 h; fica de fora")); return }
            guard end > from, start < to else { return }
            let l = link(b.texts)
            if linkOnly && l.isEmpty { return }
            out.append(Meeting(id: b.uid + "@" + key(original), title: b.title.isEmpty ? untitled : b.title,
                               start: start, end: end, link: l, source: source))
        }

        for b in raws where b.recId == nil {
            guard let s0 = b.start else { continue }
            if b.rrule.isEmpty { emit(b, start: s0, original: s0); continue }
            let (dates, warning) = expand(rrule: b.rrule, start: s0, tz: b.tz, until: to)
            if let w = warning { warnings.append("'\(b.title)': \(w)") }
            var cal = gregorian; cal.timeZone = zone
            for d in dates {
                if b.exDates.contains(d) { continue }
                if b.exDays.contains(cal.dateComponents([.year, .month, .day], from: d)) { continue }
                if let r = moved.removeValue(forKey: b.uid + "@" + key(d)) {
                    if let rs = r.start { emit(r, start: rs, original: d) }
                    continue
                }
                emit(b, start: d, original: d)
            }
        }
        // A moved occurrence whose original fell outside the expanded window (or has no master).
        for (_, r) in moved { if let rs = r.start { emit(r, start: rs, original: r.recId!) } }
        out.sort { ($0.start, $0.id) < ($1.start, $1.id) }
        return (out, Array(Set(warnings)).sorted())
    }

    static func key(_ d: Date) -> String { String(Int(d.timeIntervalSince1970)) }

    static let icsDays = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]

    /// Start dates of an RRULE, from DTSTART to `until`. Wall-clock time is kept
    /// in the event's zone (a 10:00 meeting stays at 10:00 after a daylight
    /// saving change). Unsupported rule: only DTSTART, with a warning.
    static func expand(rrule: String, start: Date, tz: TimeZone, until: Date) -> ([Date], String?) {
        var r: [String: String] = [:]
        for part in rrule.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { r[kv[0].uppercased()] = String(kv[1]).uppercased() }
        }
        func onlyFirst(_ what: String) -> ([Date], String?) {
            ([start], L("repeat rule with \(what) not understood; only the first occurrence is kept",
                        "regra de repetição com \(what) não entendida; só a primeira ocorrência entra"))
        }
        let unsupported = ["BYSETPOS", "BYHOUR", "BYMINUTE", "BYSECOND", "BYWEEKNO", "BYYEARDAY"]
        if let n = unsupported.first(where: { r[$0] != nil }) { return onlyFirst(n) }
        let freq = r["FREQ"] ?? ""
        guard ["DAILY", "WEEKLY", "MONTHLY", "YEARLY"].contains(freq) else { return onlyFirst("FREQ=\(freq)") }
        if r["BYMONTH"] != nil && freq != "YEARLY" { return onlyFirst("BYMONTH") }
        let interval = max(1, Int(r["INTERVAL"] ?? "1") ?? 1)
        let count = Int(r["COUNT"] ?? "")
        var ignored: [String] = []
        var until = until
        if let u = r["UNTIL"], case let (du, dateOnly)? = date(u, tzid: nil, fallback: tz, warnings: &ignored) {
            // A date-only UNTIL includes the whole day.
            until = min(until, dateOnly ? du.addingTimeInterval(86399) : du)
        }
        var cal = gregorian; cal.timeZone = tz; cal.firstWeekday = 2
        let hms = cal.dateComponents([.hour, .minute, .second], from: start)
        func atTime(_ y: Int, _ m: Int, _ d: Int) -> Date? {
            cal.date(from: DateComponents(year: y, month: m, day: d, hour: hms.hour, minute: hms.minute, second: hms.second))
        }
        // BYDAY: [(ordinal or nil, weekday 1..7)]
        var byDay: [(Int?, Int)] = []
        for t in (r["BYDAY"] ?? "").split(separator: ",") {
            let s = String(t); let day = String(s.suffix(2))
            guard let w = icsDays[day] else { continue }
            let ord = s.count > 2 ? Int(s.dropLast(2)) : nil
            byDay.append((ord, w))
        }
        let monthDays = (r["BYMONTHDAY"] ?? "").split(separator: ",").compactMap { Int($0) }
        let c0 = cal.dateComponents([.year, .month, .day, .weekday], from: start)

        var dates: [Date] = []
        var emitted = 0
        var period = 0
        // Safety cap: ~50 years of daily periods (an old endless rule has to
        // reach today; counting from DTSTART is what COUNT requires).
        while period < 20000 {
            var candidates: [Date] = []
            switch freq {
            case "DAILY":
                if let d = cal.date(byAdding: .day, value: period * interval, to: start) {
                    let w = cal.component(.weekday, from: d)
                    if byDay.isEmpty || byDay.contains(where: { $0.1 == w }) { candidates = [d] }
                }
            case "WEEKLY":
                // Monday of DTSTART's week, stepping `interval` weeks at a time.
                let back = (c0.weekday! + 5) % 7
                guard let mon0 = cal.date(byAdding: .day, value: -back, to: start),
                      let mon = cal.date(byAdding: .day, value: 7 * interval * period, to: mon0) else { break }
                let days = byDay.isEmpty ? [c0.weekday!] : byDay.map { $0.1 }
                for w in Set(days) {
                    let off = (w + 5) % 7
                    if let d = cal.date(byAdding: .day, value: off, to: mon) {
                        let dc = cal.dateComponents([.year, .month, .day], from: d)
                        if let x = atTime(dc.year!, dc.month!, dc.day!) { candidates.append(x) }
                    }
                }
            case "MONTHLY":
                guard let base = cal.date(from: DateComponents(year: c0.year, month: c0.month! + period * interval, day: 1)) else { break }
                let ym = cal.dateComponents([.year, .month], from: base)
                let nDays = cal.range(of: .day, in: .month, for: base)!.count
                if !monthDays.isEmpty {
                    for d in monthDays {
                        let dd = d > 0 ? d : nDays + d + 1
                        if dd >= 1 && dd <= nDays, let x = atTime(ym.year!, ym.month!, dd) { candidates.append(x) }
                    }
                } else if !byDay.isEmpty {
                    for (ord, w) in byDay {
                        var ofWeekday: [Int] = []
                        for dd in 1...nDays {
                            if let x = atTime(ym.year!, ym.month!, dd), cal.component(.weekday, from: x) == w { ofWeekday.append(dd) }
                        }
                        if let o = ord {
                            let i = o > 0 ? o - 1 : ofWeekday.count + o
                            if i >= 0 && i < ofWeekday.count, let x = atTime(ym.year!, ym.month!, ofWeekday[i]) { candidates.append(x) }
                        } else {
                            for dd in ofWeekday { if let x = atTime(ym.year!, ym.month!, dd) { candidates.append(x) } }
                        }
                    }
                } else if c0.day! <= nDays, let x = atTime(ym.year!, ym.month!, c0.day!) {
                    candidates = [x]
                }
            case "YEARLY":
                let y = c0.year! + period * interval
                if let x = atTime(y, c0.month!, c0.day!), cal.component(.day, from: x) == c0.day! { candidates = [x] }
            default: break
            }
            candidates.sort()
            for d in candidates where d >= start {
                if d > until { return (dates, nil) }
                if let c = count, emitted >= c { return (dates, nil) }
                emitted += 1
                dates.append(d)
            }
            if let c = count, emitted >= c { return (dates, nil) }
            // A period that already starts after the end: done.
            if let last = candidates.last, last > until { return (dates, nil) }
            period += 1
        }
        return (dates, nil)
    }

    // ================================================================ list ===
    /// "YYYY-MM-DD HH:MM HH:MM Name", one per line; # comments. An end before
    /// the start crosses midnight. An invalid line becomes a warning, it does
    /// not vanish.
    static func readList(_ text: String, zone: TimeZone = .current, source: String = "list") -> (meetings: [Meeting], warnings: [String]) {
        var out: [Meeting] = [], warnings: [String] = []
        var cal = gregorian; cal.timeZone = zone
        for (n, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let l = rawLine.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("#") { continue }
            let p = l.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).map(String.init)
            func hm(_ s: String) -> (Int, Int)? {
                let x = s.split(separator: ":"); guard x.count == 2, let h = Int(x[0]), let m = Int(x[1]), h < 24, m < 60 else { return nil }
                return (h, m)
            }
            let d = p.first?.split(separator: "-").compactMap { Int($0) } ?? []
            guard p.count >= 3, d.count == 3, let a = hm(p[1]), let b = hm(p[2]),
                  let s = cal.date(from: DateComponents(year: d[0], month: d[1], day: d[2], hour: a.0, minute: a.1)),
                  var e = cal.date(from: DateComponents(year: d[0], month: d[1], day: d[2], hour: b.0, minute: b.1)) else {
                warnings.append(L("list line \(n + 1) not understood: \(l)", "linha \(n + 1) da lista não entendida: \(l)")); continue
            }
            if e <= s { e = cal.date(byAdding: .day, value: 1, to: e)! }
            let name = p.count > 3 ? p[3] : ""
            out.append(Meeting(id: "list:" + p[0] + " " + p[1] + " " + name, title: name.isEmpty ? untitled : name,
                               start: s, end: e, link: "", source: source))
        }
        out.sort { ($0.start, $0.id) < ($1.start, $1.id) }
        return (out, warnings)
    }

    // ============================================================ decision ===
    /// The meeting that should be recording NOW, or nil. Each one's window is
    /// [start - before, end + after). Two windows touching (back-to-back
    /// meetings): the one that started last wins, and the file changes. A tie
    /// on start: the smallest id, so the decision does not depend on list order.
    /// `current` is the meeting the calendar is recording now. It keeps the
    /// file until its own scheduled end: an overlapping invite (10:30 inside a
    /// 10:00-11:00 call) used to cut the call in the middle, and a back-to-back
    /// one cut its last 2 minutes. Past its end it hands over only to a meeting
    /// that goes beyond it; one it fully covers is not started.
    static func target(now: Date, meetings: [Meeting], skipped: Set<String>, before: TimeInterval, after: TimeInterval, current: String? = nil) -> Meeting? {
        let inside = meetings.filter { !skipped.contains($0.id) && now >= $0.start.addingTimeInterval(-before) && now < $0.end.addingTimeInterval(after) }
        let latest: (Meeting, Meeting) -> Bool = { a, b in a.start != b.start ? a.start < b.start : a.id > b.id }
        if let c = current, let cur = inside.first(where: { $0.id == c }) {
            if now < cur.end { return cur }
            return inside.filter { $0.id != c && $0.end > cur.end }.max(by: latest) ?? cur
        }
        return inside.max(by: latest)
    }

    /// Stale calendar: a source is configured and no reading has fully worked
    /// for `limit` (2 h; it is read every 5 min). Recording goes on from the
    /// cache, but a meeting added since would be missed in silence, so the app
    /// says so. With no success on record, the clock starts at `start` (launch).
    static func stale(configured: Bool, lastOk: Date?, start: Date, now: Date, limit: TimeInterval = 7200) -> Bool {
        guard configured else { return false }
        return now.timeIntervalSince(lastOk ?? start) > limit
    }

    /// One event of the Mac's Calendar app, as plain values: the EventKit
    /// adapter (app/MacCalendar.swift) fills it, and this file stays testable
    /// without EventKit or a permission.
    struct MacEvent {
        let uid: String          // calendarItemExternalIdentifier: the iCal UID when the account has one
        let occurrence: Date     // the slot the occurrence was planned for (moved ones keep their id)
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let cancelled: Bool
        let declined: Bool       // you are an attendee and said no
        let texts: [String]      // url, location, notes: where the meeting link lives
    }

    /// The same rules as the iCal reader: no all-day, cancelled or declined
    /// event, nothing over 12 h, and (with linkOnly) only events with a video
    /// link. The id is uid@slot, like the iCal one, so the same meeting read
    /// from both sources is recorded once.
    static func fromMacEvents(_ evs: [MacEvent], from: Date, to: Date, linkOnly: Bool) -> (meetings: [Meeting], warnings: [String]) {
        var out: [Meeting] = [], warnings: [String] = []
        for e in evs {
            guard !e.cancelled, !e.declined, !e.allDay, e.end > e.start, e.end > from, e.start < to else { continue }
            if e.end.timeIntervalSince(e.start) > 12 * 3600 {
                warnings.append(L("'\(e.title)' lasts more than 12 h; left out", "'\(e.title)' dura mais de 12 h; fica de fora")); continue
            }
            let l = link(e.texts)
            if linkOnly && l.isEmpty { continue }
            out.append(Meeting(id: e.uid + "@" + key(e.occurrence), title: e.title.isEmpty ? untitled : e.title,
                               start: e.start, end: e.end, link: l, source: "macos"))
        }
        return (out, warnings)
    }

    /// The next n that will be (or are being) recorded, in order.
    static func upcoming(now: Date, meetings: [Meeting], after: TimeInterval, n: Int) -> [Meeting] {
        Array(meetings.filter { $0.end.addingTimeInterval(after) > now }.sorted { ($0.start, $0.id) < ($1.start, $1.id) }.prefix(n))
    }

    /// Joins the new reading with the cache: a source that failed now keeps
    /// counting for what it returned last time (a known meeting does not vanish
    /// because the network dropped). A source that answered replaces all of
    /// its own entries.
    static func merge(fresh: [Meeting], sourcesOk: Set<String>, cache: [Meeting]) -> [Meeting] {
        let old = cache.filter { !sourcesOk.contains($0.source) }
        var seen = Set<String>(), out: [Meeting] = []
        for e in (fresh + old) where !seen.contains(e.id) { seen.insert(e.id); out.append(e) }
        return out.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    // =============================================================== cache ===
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }
    static func serialize(_ es: [Meeting]) -> String {
        es.map { e in [String(Int(e.start.timeIntervalSince1970)), String(Int(e.end.timeIntervalSince1970)), clean(e.source), clean(e.id), clean(e.title), clean(e.link)].joined(separator: "\t") }
            .joined(separator: "\n") + (es.isEmpty ? "" : "\n")
    }
    static func deserialize(_ s: String) -> [Meeting] {
        s.components(separatedBy: "\n").compactMap { l in
            let c = l.components(separatedBy: "\t")
            guard c.count == 6, let s = Double(c[0]), let e = Double(c[1]) else { return nil }
            return Meeting(id: c[3], title: c[4], start: Date(timeIntervalSince1970: s), end: Date(timeIntervalSince1970: e), link: c[5], source: c[2])
        }
    }

    /// A title that becomes a file name: no line break, no slash, up to 80 characters.
    static func fileTitle(_ t: String) -> String {
        let s = clean(t).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespaces)
        return String(s.prefix(80)).trimmingCharacters(in: .whitespaces)
    }
}

// =============================================================== sources ===
/// The only part with side effects: reads the configured sources.
struct Sources {
    let dir: String               // ~/.ipsio
    let conf: [String: String]

    var urlFile: String { dir + "/calendar.url" }
    var listFile: String { dir + "/calendar.txt" }
    var cacheFile: String { dir + "/calendar-cache.tsv" }
    var configured: [String] {
        var f: [String] = []
        if FileManager.default.fileExists(atPath: urlFile) { f.append("ics") }
        if FileManager.default.fileExists(atPath: listFile) { f.append("list") }
        if !(conf["CALENDAR_COMMAND"] ?? "").isEmpty { f.append("command") }
        if conf["CALENDAR_MACOS"] == "1" { f.append("macos") }
        return f
    }

    struct Reading { let meetings: [Meeting]; let sourcesOk: Set<String>; let errors: [String]; let warnings: [String] }

    func read(now: Date = Date(), days: Int = 7) -> Reading {
        let from = now.addingTimeInterval(-86400), to = now.addingTimeInterval(Double(days) * 86400)
        var meetings: [Meeting] = [], ok = Set<String>(), errors: [String] = [], warnings: [String] = []
        let me = conf["CALENDAR_ME"] ?? ""
        let linkOnly = (conf["CALENDAR_LINK_ONLY"] ?? "1") != "0"
        if configured.contains("ics") {
            // The file holds the SECRET address: only the owner reads it (chmod 600).
            let urls = ((try? String(contentsOfFile: urlFile, encoding: .utf8)) ?? "")
                .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
            var failed = false
            for u in urls {
                switch Sources.fetch(u) {
                case .success(let t):
                    guard t.contains("BEGIN:VCALENDAR") else {
                        failed = true; errors.append(Schedule.L("the iCal calendar did not answer with a calendar", "a agenda iCal não respondeu um calendário")); continue
                    }
                    let r = Schedule.readICS(t, from: from, to: to, me: me, linkOnly: linkOnly)
                    meetings += r.meetings; warnings += r.warnings
                case .failure(let e): failed = true; errors.append(Schedule.L("iCal calendar: ", "agenda iCal: ") + e.description)
                }
            }
            if !failed && !urls.isEmpty { ok.insert("ics") }
        }
        if configured.contains("list") {
            if let t = try? String(contentsOfFile: listFile, encoding: .utf8) {
                let r = Schedule.readList(t); meetings += r.meetings.filter { $0.end > from && $0.start < to }; warnings += r.warnings; ok.insert("list")
            } else { errors.append(Schedule.L("could not read ", "não consegui ler ") + listFile) }
        }
        if configured.contains("command"), let cmd = conf["CALENDAR_COMMAND"] {
            switch Sources.runCommand(cmd) {
            case .success(let t):
                let r = Schedule.readList(t, source: "command"); meetings += r.meetings.filter { $0.end > from && $0.start < to }; warnings += r.warnings; ok.insert("command")
            case .failure(let e): errors.append("CALENDAR_COMMAND: \(e)")
            }
        }
        if configured.contains("macos") {
            if let reader = Sources.macReader {
                switch reader(from, to) {
                case .success(let evs):
                    let r = Schedule.fromMacEvents(evs, from: from, to: to, linkOnly: linkOnly)
                    meetings += r.meetings; warnings += r.warnings; ok.insert("macos")
                case .failure(let e): errors.append(Schedule.L("Mac Calendar: ", "Calendário do Mac: ") + e.description)
                }
            } else { errors.append(Schedule.L("Mac Calendar: not available in this program", "Calendário do Mac: indisponível neste programa")) }
        }
        // The same meeting reached through two sources (the iCal address and
        // the Mac's Calendar of the same account) has the same id: keep one.
        var seen = Set<String>()
        meetings = meetings.filter { seen.insert($0.id).inserted }
        return Reading(meetings: meetings, sourcesOk: ok, errors: errors, warnings: warnings)
    }

    /// Set by the programs that link EventKit (the app, ipsio-calendar); nil
    /// elsewhere, and then the "macos" source reports itself unavailable.
    nonisolated(unsafe) static var macReader: ((Date, Date) -> Result<[Schedule.MacEvent], Failure>)?

    struct Failure: Error, CustomStringConvertible { let description: String }

    /// Never put the address in a message: it IS the credential. Any text that
    /// leaves this function goes through `redact` first.
    static func fetch(_ s: String) -> Result<String, Failure> {
        func redact(_ m: String) -> String {
            var out = m
            for v in [s, String(s.dropFirst("webcal://".count))] where v.count > 8 { out = out.replacingOccurrences(of: v, with: "<calendar address>") }
            return out
        }
        var u = s
        if u.lowercased().hasPrefix("webcal://") { u = "https://" + u.dropFirst("webcal://".count) }
        if u.hasPrefix("/") { u = "file://" + u }
        guard let url = URL(string: u) else { return .failure(Failure(description: Schedule.L("invalid address", "endereço inválido"))) }
        if url.isFileURL {
            if let t = try? String(contentsOf: url, encoding: .utf8) { return .success(t) }
            return .failure(Failure(description: Schedule.L("could not read ", "não consegui ler ") + url.path))
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.setValue("Ipsio", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var res: Result<String, Failure> = .failure(Failure(description: Schedule.L("no answer", "sem resposta")))
        URLSession.shared.dataTask(with: req) { d, r, e in
            if let e = e { res = .failure(Failure(description: redact(e.localizedDescription))) }
            else if let h = r as? HTTPURLResponse, h.statusCode != 200 { res = .failure(Failure(description: "HTTP \(h.statusCode)")) }
            else if let d = d { res = .success(String(decoding: d, as: UTF8.self)) }
            sem.signal()
        }.resume()
        sem.wait()
        return res
    }

    static func runCommand(_ cmd: String) -> Result<String, Failure> {
        // A hung command must not freeze the calendar for good: 60 s, then it is killed.
        let r = Runner.run("/bin/bash", ["-lc", cmd], limit: 60, mergeErr: false)
        if let e = r.launchError { return .failure(Failure(description: e)) }
        if r.timedOut { return .failure(Failure(description: Schedule.L("no answer in 60 s; stopped", "sem resposta em 60 s; interrompido"))) }
        if r.status != 0 {
            return .failure(Failure(description: Schedule.L("exited with ", "saiu com ") + "\(r.status): \(r.err.suffix(200))"))
        }
        return .success(r.out)
    }

    /// When the last reading with every source answering happened (epoch
    /// seconds in a file, so a restart does not reset the stale clock).
    var okFile: String { dir + "/calendar-ok-at" }
    func readLastOk() -> Date? {
        guard let s = try? String(contentsOfFile: okFile, encoding: .utf8), let v = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return Date(timeIntervalSince1970: v)
    }
    func writeLastOk(_ d: Date) { try? String(Int(d.timeIntervalSince1970)).write(toFile: okFile, atomically: true, encoding: .utf8) }

    /// Only meetings of sources still configured: a calendar the person
    /// removed must not keep recording from the cache for days.
    func readCache() -> [Meeting] {
        let c = configured
        return Schedule.deserialize((try? String(contentsOfFile: cacheFile, encoding: .utf8)) ?? "").filter { c.contains($0.source) }
    }
    func writeCache(_ es: [Meeting]) { try? Schedule.serialize(es).write(toFile: cacheFile, atomically: true, encoding: .utf8) }

    /// What "Connect calendar" accepts: an https or webcal address with a host.
    /// webcal becomes https (it is the same request); anything else is refused,
    /// because a typo saved here would fail silently every 5 minutes.
    static func normalizeAddress(_ s: String) -> String? {
        var u = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if u.lowercased().hasPrefix("webcal://") { u = "https://" + u.dropFirst("webcal://".count) }
        guard u.lowercased().hasPrefix("https://"), !u.contains(where: { $0.isWhitespace }),
              let url = URL(string: u), let h = url.host, !h.isEmpty else { return nil }
        return u
    }

    /// Connect calendar: reads the address ONCE and saves it only if it answered
    /// with a calendar (fail closed: a bad paste never replaces a working one).
    /// The file holds a credential: written owner-only (0600) through a
    /// temporary file and a rename, so it is never readable by others, not even
    /// for an instant. Returns how many meetings it saw in the next 7 days.
    func connect(_ address: String, now: Date = Date(),
                 fetcher: (String) -> Result<String, Failure> = Sources.fetch) -> Result<Int, Failure> {
        guard let u = Sources.normalizeAddress(address) else {
            return .failure(Failure(description: Schedule.L("this is not a calendar address (https:// or webcal://)", "isso não é um endereço de agenda (https:// ou webcal://)")))
        }
        let text: String
        switch fetcher(u) {
        case .success(let t): text = t
        case .failure(let e): return .failure(e)
        }
        guard text.contains("BEGIN:VCALENDAR") else {
            return .failure(Failure(description: Schedule.L("the address did not answer with a calendar", "o endereço não respondeu um calendário")))
        }
        let r = Schedule.readICS(text, from: now.addingTimeInterval(-86400), to: now.addingTimeInterval(7 * 86400),
                                 me: conf["CALENDAR_ME"] ?? "", linkOnly: (conf["CALENDAR_LINK_ONLY"] ?? "1") != "0")
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let tmp = dir + "/.calendar.url.\(getpid())"
        try? fm.removeItem(atPath: tmp)
        // open() with the mode, not createFile + chmod: the bytes never exist
        // under the umask's 0644, not even between the write and the chmod.
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        var written = false
        if fd >= 0 {
            let bytes = Array((u + "\n").utf8)
            written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == bytes.count
            close(fd)
        }
        guard written, rename(tmp, urlFile) == 0 else {
            try? fm.removeItem(atPath: tmp)
            return .failure(Failure(description: Schedule.L("could not save ", "não consegui salvar ") + urlFile))
        }
        return .success(r.meetings.filter { $0.end > now }.count)
    }
}

/// Runs a program with a deadline. Waiting for the pipe to close is not enough:
/// a child left in the background (or a wedged ffmpeg under the script) keeps
/// it open, and the caller, the app's "busy" included, would wait forever.
/// On the deadline the program and its direct children get SIGTERM and the
/// caller gets what was printed so far, with timedOut set.
enum Runner {
    struct Result { var out = "", err = "", status: Int32 = -1, timedOut = false, launchError: String? = nil }
    final class Box: @unchecked Sendable {
        let lock = NSLock(); var data = Data()
        func add(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }
    static func run(_ exe: String, _ args: [String], env: [String: String]? = nil, limit: TimeInterval, mergeErr: Bool = true) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        if let env = env { p.environment = env }
        let out = Pipe(), err = mergeErr ? out : Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return Result(launchError: "\(error)") }
        let o = Box(), e = Box(), g = DispatchGroup()
        for (pipe, box) in mergeErr ? [(out, o)] : [(out, o), (err, e)] {
            g.enter()
            let h = pipe.fileHandleForReading
            DispatchQueue.global().async {
                while true { let d = h.availableData; if d.isEmpty { break }; box.add(d) }
                g.leave()
            }
        }
        if g.wait(timeout: .now() + limit) == .timedOut {
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill"); kill.arguments = ["-TERM", "-P", String(p.processIdentifier)]
            try? kill.run(); kill.waitUntilExit()
            if p.isRunning { p.terminate() }
            return Result(out: o.text, err: e.text, status: -1, timedOut: true)
        }
        p.waitUntilExit()
        return Result(out: o.text, err: e.text, status: p.terminationStatus)
    }
}
