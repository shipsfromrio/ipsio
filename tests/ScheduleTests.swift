// ScheduleTests.swift: the calendar bench. Compiles together with app/Schedule.swift:
//   swiftc -parse-as-library app/Schedule.swift tests/ScheduleTests.swift -o /tmp/schedule-tests && /tmp/schedule-tests
// Exits 1 if any assertion fails. tests/mutants.sh breaks the calendar on
// purpose, one defect at a time, and requires this bench to fail each one.
import Foundation

var fails = 0, total = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    total += 1
    if ok { print("ok   \(name)") } else { fails += 1; print("FAIL \(name)"); let d = detail(); if !d.isEmpty { print("      \(d)") } }
}
let sp = TimeZone(identifier: "America/Sao_Paulo")!
func at(_ s: String, _ tz: TimeZone = sp) -> Date {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz; f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.date(from: s)!
}
func hhmm(_ d: Date, _ tz: TimeZone = sp) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz; f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: d)
}
func ics(_ body: String) -> String { "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n" + body.replacingOccurrences(of: "\n", with: "\r\n") + "END:VCALENDAR\r\n" }

@main
struct ScheduleTests {
    static func main() {
        // ------------------------------------------------------ Google calendar ---
        let google = ics("""
        BEGIN:VTIMEZONE
        TZID:America/Sao_Paulo
        BEGIN:STANDARD
        DTSTART:19700101T000000
        TZOFFSETFROM:-0300
        TZOFFSETTO:-0300
        END:STANDARD
        END:VTIMEZONE
        BEGIN:VEVENT
        DTSTART;TZID=America/Sao_Paulo:20261005T100000
        DTEND;TZID=America/Sao_Paulo:20261005T110000
        RRULE:FREQ=WEEKLY;BYDAY=MO,WE;UNTIL=20261031T235959Z
        EXDATE;TZID=America/Sao_Paulo:20261007T100000
        UID:weekly@google.com
        SUMMARY:Weekly sync
        DESCRIPTION:Join with Google Meet: https://meet.google.com/abc-defg-hij\\nOr dial: +1 555 0000
        X-GOOGLE-CONFERENCE:https://meet.google.com/abc-defg-hij
        END:VEVENT
        BEGIN:VEVENT
        DTSTART;TZID=America/Sao_Paulo:20261012T140000
        DTEND;TZID=America/Sao_Paulo:20261012T153000
        RECURRENCE-ID;TZID=America/Sao_Paulo:20261012T100000
        UID:weekly@google.com
        SUMMARY:Weekly sync (moved)
        X-GOOGLE-CONFERENCE:https://meet.google.com/abc-defg-hij
        END:VEVENT
        BEGIN:VEVENT
        DTSTART;TZID=America/Sao_Paulo:20261014T100000
        DTEND;TZID=America/Sao_Paulo:20261014T110000
        RECURRENCE-ID;TZID=America/Sao_Paulo:20261014T100000
        UID:weekly@google.com
        STATUS:CANCELLED
        SUMMARY:Weekly sync
        END:VEVENT
        BEGIN:VEVENT
        DTSTART:20261006T170000Z
        DTEND:20261006T180000Z
        UID:zoom1
        SUMMARY:Proposal\\, second round
        LOCATION:https://us02web.zoom.us/j/123456789?pwd=abcDEF
        END:VEVENT
        BEGIN:VEVENT
        DTSTART:20261006T150000Z
        DTEND:20261006T160000Z
        UID:lunch
        SUMMARY:Lunch
        LOCATION:Restaurant
        END:VEVENT
        BEGIN:VEVENT
        DTSTART:20261008T170000Z
        DTEND:20261008T180000Z
        UID:cancelled-single
        STATUS:CANCELLED
        SUMMARY:Cancelled single
        LOCATION:https://meet.google.com/ccc-dddd-eee
        END:VEVENT
        BEGIN:VEVENT
        DTSTART;VALUE=DATE:20261010
        UID:allday-no-end
        SUMMARY:Holiday no end
        DESCRIPTION:https://meet.google.com/xxx-yyyy-zzz
        END:VEVENT
        BEGIN:VEVENT
        DTSTART;VALUE=DATE:20261008
        DTEND;VALUE=DATE:20261009
        UID:allday
        SUMMARY:Holiday with link
        DESCRIPTION:https://meet.google.com/xxx-yyyy-zzz
        END:VEVENT
        BEGIN:VEVENT
        DTSTART:20261007T130000Z
        DTEND:20261007T140000Z
        UID:declined
        SUMMARY:Declined
        ATTENDEE;CN="Me: the owner";PARTSTAT=DECLINED:mailto:me@example.com
        ATTENDEE;PARTSTAT=ACCEPTED:mailto:other@example.com
        DESCRIPTION:https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0?context=y
        END:VEVENT
        BEGIN:VEVENT
        DTSTART:20261008T130000Z
        DTEND:20261008T140000Z
        UID:colleague-declined
        SUMMARY:Colleague declined
        ATTENDEE;PARTSTAT=DECLINED:mailto:someme@example.com
        LOCATION:https://meet.google.com/ddd-eeee-fff
        END:VEVENT
        BEGIN:VEVENT
        DTSTART:20261009T130000Z
        DURATION:PT45M
        UID:teams1
        SUMMARY:Folded Teams
        DESCRIPTION:Join: https://teams.microsoft.com/l/meetup-join/19%3amee
         ting_abc%40thread.v2/0
        END:VEVENT
        BEGIN:VEVENT
        DTSTART:20261009T160000Z
        DTEND:20261009T170000Z
        UID:alarm
        SUMMARY:Only the alarm has a link
        BEGIN:VALARM
        ACTION:DISPLAY
        DESCRIPTION:https://meet.google.com/aaa-bbbb-ccc
        END:VALARM
        END:VEVENT

        """)
        let from = at("2026-10-04 00:00"), to = at("2026-10-20 00:00")
        let r = Schedule.readICS(google, from: from, to: to, me: "me@example.com", zone: sp)
        let summary = r.meetings.map { "\(hhmm($0.start)) \($0.title)" }
        check(r.meetings.count == 6, "Google: 6 meetings with a link in the window", "\(summary)")
        check(summary.contains { $0.contains("Colleague declined") }, "a colleague whose address ends like mine declining does not drop the meeting", "\(summary)")
        check(summary.contains("2026-10-05 10:00 Weekly sync"), "weekly: first occurrence")
        check(!summary.contains { $0.hasPrefix("2026-10-07 10:00") }, "EXDATE removes the occurrence", "\(summary)")
        check(summary.contains("2026-10-12 14:00 Weekly sync (moved)"), "RECURRENCE-ID moves the occurrence", "\(summary)")
        check(!summary.contains { $0.hasPrefix("2026-10-12 10:00") }, "the moved occurrence leaves its old slot", "\(summary)")
        check(!summary.contains { $0.hasPrefix("2026-10-14 10:00") }, "a cancelled occurrence disappears", "\(summary)")
        check(summary.contains("2026-10-19 10:00 Weekly sync"), "weekly goes on to the end of the window", "\(summary)")
        check(summary.contains("2026-10-06 14:00 Proposal, second round"), "UTC becomes local time and \\, becomes a comma", "\(summary)")
        check(!summary.contains { $0.contains("Lunch") }, "an event without a link is left out")
        check(!summary.contains { $0.contains("Holiday") }, "all-day is left out (with and without DTEND)")
        check(!summary.contains { $0.contains("Cancelled") }, "a cancelled single event is left out")
        check(!summary.contains { $0.contains("Declined") }, "declined by me is left out")
        check(!summary.contains { $0.contains("alarm") }, "a link only in VALARM does not count")
        if let t = r.meetings.first(where: { $0.title == "Folded Teams" }) {
            check(t.link == "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0", "a folded iCal line is unfolded", t.link)
            check(t.end.timeIntervalSince(t.start) == 45 * 60, "DURATION becomes the end")
        } else { check(false, "the event with a folded line is kept") }
        if let z = r.meetings.first(where: { $0.id.hasPrefix("zoom1") }) {
            check(z.link == "https://us02web.zoom.us/j/123456789?pwd=abcDEF", "a Zoom link with password stays whole", z.link)
        }
        if let m = r.meetings.first(where: { $0.title.contains("moved") }) {
            check(m.id == "weekly@google.com@" + String(Int(at("2026-10-12 10:00").timeIntervalSince1970)), "a moved occurrence keeps the original slot's id", m.id)
            check(hhmm(m.end) == "2026-10-12 15:30", "a moved occurrence has its own end", hhmm(m.end))
        }
        let ids = r.meetings.map { $0.id }
        check(Set(ids).count == ids.count, "unique ids")
        let noMe = Schedule.readICS(google, from: from, to: to, me: "", zone: sp)
        check(noMe.meetings.contains { $0.title == "Declined" }, "without CALENDAR_ME the decline is not mine")
        let all = Schedule.readICS(google, from: from, to: to, me: "me@example.com", linkOnly: false, zone: sp)
        check(all.meetings.contains { $0.title == "Lunch" } && !all.meetings.contains { $0.title.contains("Holiday") }, "linkOnly=false brings events without a link, but never all-day")

        // ------------------------------------------------------------ rules ---
        let ny = TimeZone(identifier: "America/New_York")!
        let dst = ics("""
        BEGIN:VEVENT
        DTSTART;TZID=America/New_York:20261026T100000
        DTEND;TZID=America/New_York:20261026T110000
        RRULE:FREQ=WEEKLY;BYDAY=MO
        UID:dst
        SUMMARY:Crosses the end of daylight saving
        LOCATION:https://meet.google.com/aaa-bbbb-ccc
        END:VEVENT

        """)
        let rd = Schedule.readICS(dst, from: at("2026-10-25 00:00", ny), to: at("2026-11-10 00:00", ny), zone: sp)
        check(rd.meetings.map { hhmm($0.start, ny) } == ["2026-10-26 10:00", "2026-11-02 10:00", "2026-11-09 10:00"], "wall-clock time kept across daylight saving", "\(rd.meetings.map { hhmm($0.start, ny) })")

        func dates(_ rr: String, _ start: String, _ until: String) -> [String] {
            Schedule.expand(rrule: rr, start: at(start), tz: sp, until: at(until)).0.map { hhmm($0) }
        }
        check(dates("FREQ=DAILY;COUNT=3", "2026-10-05 09:00", "2026-12-01 00:00") == ["2026-10-05 09:00", "2026-10-06 09:00", "2026-10-07 09:00"], "COUNT")
        let cnt = Schedule.readICS(ics("""
        BEGIN:VEVENT
        DTSTART;TZID=America/Sao_Paulo:20261005T090000
        DTEND;TZID=America/Sao_Paulo:20261005T093000
        RRULE:FREQ=DAILY;COUNT=3
        EXDATE;TZID=America/Sao_Paulo:20261006T090000
        UID:c
        LOCATION:https://meet.google.com/aaa-bbbb-ccc
        END:VEVENT

        """), from: at("2026-10-01 00:00"), to: at("2026-12-01 00:00"), zone: sp)
        check(cnt.meetings.count == 2, "COUNT counts before EXDATE (RFC 5545)", "\(cnt.meetings.map { hhmm($0.start) })")
        check(dates("FREQ=WEEKLY;INTERVAL=2;BYDAY=TU", "2026-10-06 15:00", "2026-11-04 00:00") == ["2026-10-06 15:00", "2026-10-20 15:00", "2026-11-03 15:00"], "INTERVAL=2 weekly")
        check(dates("FREQ=MONTHLY;BYDAY=2TU", "2026-10-13 15:00", "2027-01-01 00:00") == ["2026-10-13 15:00", "2026-11-10 15:00", "2026-12-08 15:00"], "second Tuesday of the month")
        check(dates("FREQ=MONTHLY;BYDAY=-1FR", "2026-10-30 15:00", "2027-01-01 00:00") == ["2026-10-30 15:00", "2026-11-27 15:00", "2026-12-25 15:00"], "last Friday of the month")
        check(dates("FREQ=MONTHLY;BYMONTHDAY=31", "2026-10-31 08:00", "2027-02-01 00:00") == ["2026-10-31 08:00", "2026-12-31 08:00", "2027-01-31 08:00"], "day 31 skips short months")
        check(dates("FREQ=WEEKLY;BYDAY=MO;UNTIL=20261019", "2026-10-05 08:00", "2026-12-01 00:00") == ["2026-10-05 08:00", "2026-10-12 08:00", "2026-10-19 08:00"], "a date-only UNTIL includes the day")
        check(dates("FREQ=YEARLY", "2025-10-05 08:00", "2027-10-06 00:00") == ["2025-10-05 08:00", "2026-10-05 08:00", "2027-10-05 08:00"], "yearly")
        let old = dates("FREQ=DAILY", "2015-01-05 08:00", "2026-10-07 00:00")
        check(old.suffix(2) == ["2026-10-05 08:00", "2026-10-06 08:00"], "an old endless daily rule reaches today", "\(old.suffix(2))")
        let (only, warning) = Schedule.expand(rrule: "FREQ=MONTHLY;BYDAY=MO,TU;BYSETPOS=1", start: at("2026-10-05 08:00"), tz: sp, until: at("2027-01-01 00:00"))
        check(only.count == 1 && warning != nil, "a rule not understood becomes a warning, not silence")

        // ------------------------------------------------------------- list ---
        let list = Schedule.readList("""
        # day start end name
        2026-10-05 07:58 08:57 Meeting A
        2026-10-05 23:30 00:30 Crosses midnight
        this is not a line
        """, zone: sp)
        check(list.meetings.count == 2, "list: two meetings")
        check(list.warnings.count == 1, "list: an invalid line becomes a warning")
        if list.meetings.count == 2 {
            check(hhmm(list.meetings[0].start) == "2026-10-05 07:58" && list.meetings[0].title == "Meeting A", "list: time and name")
            check(hhmm(list.meetings[1].end) == "2026-10-06 00:30", "list: an end before the start crosses midnight")
        }

        // --------------------------------------------------------- decision ---
        func mt(_ id: String, _ s: String, _ e: String) -> Meeting { Meeting(id: id, title: id, start: at(s), end: at(e), link: "", source: "list") }
        let a = mt("A", "2026-10-05 10:00", "2026-10-05 11:00"), b = mt("B", "2026-10-05 11:00", "2026-10-05 12:00")
        let ab = [b, a]
        func target(_ t: String, _ skip: Set<String> = []) -> String { Schedule.target(now: at(t), meetings: ab, skipped: skip, before: 120, after: 300)?.id ?? "-" }
        check(target("2026-10-05 09:57") == "-", "before the margin: no recording")
        check(target("2026-10-05 09:58") == "A", "2 min before: already recording")
        check(target("2026-10-05 10:57") == "A", "during the meeting: records it")
        check(target("2026-10-05 10:58") == "B", "back-to-back: switches to the one starting")
        check(target("2026-10-05 12:04") == "B", "5 min after the end: still recording")
        check(target("2026-10-05 12:05") == "-", "after the margin: stops")
        check(target("2026-10-05 11:01", ["B"]) == "A", "next one skipped: the previous keeps its margin")
        check(target("2026-10-05 11:30", ["B"]) == "-", "a skipped one is not recorded")
        let twins = [mt("Y", "2026-10-05 10:00", "2026-10-05 11:00"), mt("X", "2026-10-05 10:00", "2026-10-05 11:00")]
        check(Schedule.target(now: at("2026-10-05 10:30"), meetings: twins, skipped: [], before: 0, after: 0)?.id == "X", "a tie is decided by id, not by order")
        let next = Schedule.upcoming(now: at("2026-10-05 11:30"), meetings: ab, after: 300, n: 5)
        check(next.map { $0.id } == ["B"], "upcoming: only what is still to come or recording")

        // -------------------------------------------------- cache and merge ---
        let c1 = Meeting(id: "i1", title: "With\ttab\nbreak", start: at("2026-10-05 10:00"), end: at("2026-10-05 11:00"), link: "https://meet.google.com/a", source: "ics")
        let c2 = Meeting(id: "l1", title: "List", start: at("2026-10-05 12:00"), end: at("2026-10-05 13:00"), link: "", source: "list")
        let back = Schedule.deserialize(Schedule.serialize([c1, c2]))
        check(back.count == 2 && back[0].title == "With tab break" && back[0].start == c1.start && back[1].source == "list", "cache round-trips without tab or line break")
        let newList = Meeting(id: "l2", title: "New", start: at("2026-10-05 15:00"), end: at("2026-10-05 16:00"), link: "", source: "list")
        let m = Schedule.merge(fresh: [newList], sourcesOk: ["list"], cache: [c1, c2])
        check(m.map { $0.id } == ["i1", "l2"], "a failed source lives on through the cache; one that answered replaces", "\(m.map { $0.id })")

        check(Schedule.fileTitle("Client/Project: revisão\tfinal") == "Client-Project- revisão final", "file title without / or :")
        check(Schedule.fileTitle(String(repeating: "é", count: 200)).count == 80, "file title cut at 80 whole characters")

        // ------------------------------------------------------------ sources ---
        let missing = Sources.fetch("/nonexistent/ipsio-test.ics")
        if case .failure = missing { check(true, "a missing local .ics is an error, not an empty calendar") }
        else { check(false, "a missing local .ics is an error, not an empty calendar") }

        // ------------------------------------------------------ stale calendar ---
        let t0 = at("2026-10-05 08:00")
        check(!Schedule.stale(configured: false, lastOk: nil, start: t0, now: at("2026-10-06 08:00")), "no calendar is never stale")
        check(!Schedule.stale(configured: true, lastOk: at("2026-10-05 09:00"), start: t0, now: at("2026-10-05 10:59")), "read 1h59 ago is fresh")
        check(Schedule.stale(configured: true, lastOk: at("2026-10-05 09:00"), start: t0, now: at("2026-10-05 11:01")), "read 2h01 ago is stale")
        check(!Schedule.stale(configured: true, lastOk: nil, start: t0, now: at("2026-10-05 09:00")), "never read, launched 1 h ago: not yet")
        check(Schedule.stale(configured: true, lastOk: nil, start: t0, now: at("2026-10-05 10:30")), "never read, launched 2h30 ago: stale")
        let sdir = NSTemporaryDirectory() + "ipsio-stale-\(getpid())"
        try? FileManager.default.createDirectory(atPath: sdir, withIntermediateDirectories: true)
        let ss = Sources(dir: sdir, conf: [:])
        check(ss.readLastOk() == nil, "no success on record reads as nil")
        ss.writeLastOk(at("2026-10-05 09:00"))
        check(ss.readLastOk() == at("2026-10-05 09:00"), "the last success survives a restart")
        try? FileManager.default.removeItem(atPath: sdir)

        // ------------------------------------------------- connect calendar ---
        check(Sources.normalizeAddress(" webcal://calendar.example.com/x/basic.ics ") == "https://calendar.example.com/x/basic.ics", "webcal becomes https, spaces trimmed")
        check(Sources.normalizeAddress("http://calendar.example.com/x.ics") == nil, "plain http is refused")
        check(Sources.normalizeAddress("calendar.example.com/x.ics") == nil, "an address without scheme is refused")
        check(Sources.normalizeAddress("https:// broken.example.com") == nil, "an address with a space is refused")
        let cdir = NSTemporaryDirectory() + "ipsio-connect-\(getpid())"
        try? FileManager.default.removeItem(atPath: cdir)
        let src = Sources(dir: cdir, conf: [:])
        let soon = ics("""
        BEGIN:VEVENT
        UID:c1
        SUMMARY:Soon
        DTSTART:20261005T150000Z
        DTEND:20261005T160000Z
        LOCATION:https://meet.google.com/abc-defg-hij
        END:VEVENT

        """)
        var asked = ""
        let good = src.connect("webcal://calendar.example.com/s.ics", now: at("2026-10-05 10:00"), fetcher: { asked = $0; return .success(soon) })
        if case .success(let n) = good { check(n == 1, "connect counts the meetings ahead", "\(n)") } else { check(false, "connect counts the meetings ahead", "\(good)") }
        check(asked == "https://calendar.example.com/s.ics", "connect fetches the normalized address")
        let saved = (try? String(contentsOfFile: src.urlFile, encoding: .utf8)) ?? ""
        check(saved == "https://calendar.example.com/s.ics\n", "connect saves the address", saved)
        let perm = ((try? FileManager.default.attributesOfItem(atPath: src.urlFile))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
        check(perm == 0o600, "the saved address is owner-only (0600)", String(perm, radix: 8))
        let html = src.connect("https://calendar.example.com/other.ics", fetcher: { _ in .success("<html>login</html>") })
        if case .failure = html { check(true, "an answer that is not a calendar is refused") } else { check(false, "an answer that is not a calendar is refused") }
        let down = src.connect("https://calendar.example.com/other.ics", fetcher: { _ in .failure(Sources.Failure(description: "HTTP 404")) })
        if case .failure = down { check(true, "an address that fails is refused") } else { check(false, "an address that fails is refused") }
        var called = false
        _ = src.connect("ftp://calendar.example.com/x", fetcher: { _ in called = true; return .success(soon) })
        check(!called, "an invalid address is not even fetched")
        check(((try? String(contentsOfFile: src.urlFile, encoding: .utf8)) ?? "") == saved, "a refused paste keeps the calendar that worked")
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: cdir)) ?? []).filter { $0.hasPrefix(".calendar.url.") }
        check(leftovers.isEmpty, "no temporary file left behind", "\(leftovers)")
        try? FileManager.default.removeItem(atPath: cdir)

        print("\n\(total - fails)/\(total) ok")
        exit(fails == 0 ? 0 : 1)
    }
}
