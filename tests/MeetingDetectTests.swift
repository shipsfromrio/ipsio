// MeetingDetectTests.swift: the bench for MeetingDetect (which window is a
// call, which is just the app open, and the offer made once). Compiles alone:
//   swiftc -parse-as-library app/MeetingDetect.swift tests/MeetingDetectTests.swift -o /tmp/detect-tests && /tmp/detect-tests
// Exits 1 if any assertion fails.
import Foundation

var fails = 0, total = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    total += 1
    if ok { print("ok   \(name)") } else { fails += 1; print("FAIL \(name)"); let d = detail(); if !d.isEmpty { print("      \(d)") } }
}
typealias M = MeetingDetect.Meeting
func one(_ id: String, _ title: String) -> M? { MeetingDetect.detect(apps: [id], windows: [(bundleID: id, title: title)]) }

@main
struct MeetingDetectTests {
    static func main() {
        let zoom = "us.zoom.xos", teams = "com.microsoft.teams2", oldTeams = "com.microsoft.teams"
        let webex = "com.cisco.webexmeetingsapp", slack = "com.tinyspeck.slackmacgap"

        // Zoom: the app running is not a call; the call window is.
        check(MeetingDetect.detect(apps: [zoom], windows: []) == nil, "Zoom running with no window is not a meeting")
        for t in ["Zoom", "Zoom Workplace", "Home", "Meetings", "Settings", "Configurações", "Zoom Meetings", "Chat", ""] {
            check(one(zoom, t) == nil, "Zoom window '\(t)' is not a meeting")
        }
        for t in ["Zoom Meeting", "Reunião Zoom", "REUNIAO ZOOM", "Zoom Meeting 40-Minutes", "Zoom Webinar", "Meeting", "Reunião"] {
            check(one(zoom, t) == M(app: "Zoom", key: "zoom"), "Zoom window '\(t)' is a meeting")
        }
        check(one(slack, "Zoom Meeting") == nil && one(teams, "Zoom Meeting")?.app == "Microsoft Teams", "a Zoom title in another app is not a Zoom meeting")

        // Teams.
        for id in [teams, oldTeams] {
            for t in ["Meeting with Ana | Microsoft Teams", "Reunião em canal | Microsoft Teams", "Call with Bob | Microsoft Teams",
                      "Chamada com Bia | Microsoft Teams", "Meeting compact view | Microsoft Teams"] {
                check(one(id, t) == M(app: "Microsoft Teams", key: "teams"), "Teams (\(id)) '\(t)' is a meeting")
            }
            for t in ["Chat | Ana | Microsoft Teams", "Calendar | Microsoft Teams", "Calendário | Microsoft Teams",
                      "Activity | Microsoft Teams", "Microsoft Teams", "Chat | Weekly meeting group | Microsoft Teams", "Meetings app"] {
                check(one(id, t) == nil, "Teams (\(id)) '\(t)' is not a meeting")
            }
        }

        // Meet: a browser tab with a code, not the home page.
        let browsers = ["com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac", "company.thebrowser.Browser",
                        "org.mozilla.firefox", "com.brave.Browser"]
        for b in browsers {
            check(one(b, "Meet - abc-defg-hij") == M(app: "Google Meet", key: "meet:abc-defg-hij"), "Meet in \(b)")
        }
        check(one("org.mozilla.firefox", "Meet \u{2013} xyz-abcd-efg \u{2014} Mozilla Firefox")?.key == "meet:xyz-abcd-efg", "Meet with en dash, Firefox suffix")
        check(one("com.google.Chrome", "Meet - ABC-DEFG-HIJ - Google Chrome")?.key == "meet:abc-defg-hij", "the code key is lower case")
        check(one("com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan", "Meet - abc-defg-hij") != nil, "Meet as a Chrome app")
        for t in ["Google Meet", "Meet", "Meet - Google Meet", "Meet - abc-defg-hijk", "Meet - abcd-efg-hij", "Meet - abc-defg-hij-x",
                  "abc-defg-hij", "Comeet - abc-defg-hij", "Gmail - Inbox"] {
            check(one("com.google.Chrome", t) == nil, "browser '\(t)' is not a meeting")
        }
        check(one("com.apple.TextEdit", "Meet - abc-defg-hij") == nil, "a Meet title outside a browser is not a meeting")
        check(MeetingDetect.detect(apps: ["com.google.Chrome"], windows: [(bundleID: "com.google.Chrome", title: "Meet - abc-defg-hij"),
                                                                      (bundleID: "com.google.Chrome", title: "Meet - zzz-zzzz-zzz")])?.key == "meet:abc-defg-hij",
              "two Meet tabs: the first window wins")

        // Webex.
        for t in ["Webex Meeting", "Reunião Webex", "Ana's Personal Room", "Sala pessoal de Ana"] {
            check(one(webex, t) == M(app: "Webex", key: "webex"), "Webex '\(t)' is a meeting")
            check(one("Cisco-Systems.Spark", t)?.app == "Webex", "Webex app '\(t)' is a meeting")
        }
        for t in ["Cisco Webex Meetings", "Webex Meetings", "Webex", "Preferences"] {
            check(one(webex, t) == nil, "Webex '\(t)' is not a meeting")
        }

        // Slack huddle.
        check(one(slack, "Huddle: #general") == M(app: "Slack", key: "slack"), "Slack huddle window")
        check(one(slack, "Huddle with Ana") != nil, "Slack huddle with a person")
        for t in ["Slack", "Slack | general | Acme", "Slack | huddle-notes | Acme", "#huddle - Acme - Slack"] {
            check(one(slack, t) == nil, "Slack '\(t)' is not a huddle")
        }

        // Only running apps count; the first meeting window wins.
        check(MeetingDetect.detect(apps: [], windows: [(bundleID: zoom, title: "Zoom Meeting")]) == nil, "a window of an app not running is ignored")
        check(MeetingDetect.detect(apps: [zoom, slack], windows: [(bundleID: zoom, title: "Zoom Workplace"), (bundleID: slack, title: "Huddle: #x"),
                                                               (bundleID: zoom, title: "Zoom Meeting")])?.app == "Slack", "first meeting window in order")

        // Calendar nearby.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func span(_ a: Double, _ b: Double) -> (start: Date, end: Date) { (now.addingTimeInterval(a), now.addingTimeInterval(b)) }
        check(MeetingDetect.calendarSoon(now: now, spans: [span(599, 3000)]), "a calendar recording in 9:59 is near")
        check(MeetingDetect.calendarSoon(now: now, spans: [span(600, 3000)]), "a calendar recording in exactly 10 min is near")
        check(!MeetingDetect.calendarSoon(now: now, spans: [span(601, 3000)]), "a calendar recording in 10:01 is not")
        check(MeetingDetect.calendarSoon(now: now, spans: [span(-600, 60)]), "a calendar recording on now is near")
        check(!MeetingDetect.calendarSoon(now: now, spans: [span(-600, 0)]), "an ended calendar recording is not")
        check(!MeetingDetect.calendarSoon(now: now, spans: []), "no calendar, nothing near")

        // Debounce: once per call.
        let z = M(app: "Zoom", key: "zoom"), g = M(app: "Google Meet", key: "meet:abc-defg-hij")
        func at(_ s: Double) -> Date { now.addingTimeInterval(s) }
        var d = MeetingDetect.Debounce()
        check(d.step(z, now: at(0), recording: false, calendarSoon: false) == z, "a new meeting is offered")
        check(d.step(z, now: at(15), recording: false, calendarSoon: false) == nil, "the same meeting 15 s later is not offered again")
        check((2...40).allSatisfy { d.step(z, now: at(Double($0) * 15), recording: false, calendarSoon: false) == nil }, "nor in the next 10 min")
        check(d.step(g, now: at(615), recording: false, calendarSoon: false) == g, "another meeting is offered")
        // A short gap (window behind another space, a reconnect) is the same call.
        var e = MeetingDetect.Debounce()
        _ = e.step(z, now: at(0), recording: false, calendarSoon: false)
        _ = e.step(nil, now: at(60), recording: false, calendarSoon: false)
        check(e.step(z, now: at(120), recording: false, calendarSoon: false) == nil, "back after a 2 min gap: same call, no offer")
        // Gone for more than 2 min: forgotten; the next call is offered.
        for s in stride(from: 135.0, through: 255, by: 15) { _ = e.step(nil, now: at(s), recording: false, calendarSoon: false) }
        check(e.lastSeen["zoom"] == nil, "a meeting gone for more than 2 min is forgotten")
        check(e.step(z, now: at(270), recording: false, calendarSoon: false) == z, "a later Zoom call is offered again")
        // Gone 2 min without any tick in between (Mac asleep): still forgotten.
        var f = MeetingDetect.Debounce()
        _ = f.step(z, now: at(0), recording: false, calendarSoon: false)
        check(f.step(z, now: at(121), recording: false, calendarSoon: false) == z, "seen again after 121 s with no tick: offered")
        var f2 = MeetingDetect.Debounce()
        _ = f2.step(z, now: at(0), recording: false, calendarSoon: false)
        check(f2.step(z, now: at(120), recording: false, calendarSoon: false) == nil, "seen again after exactly 120 s: not offered")
        // Never while recording or with the calendar about to record; that call stays handled.
        var r = MeetingDetect.Debounce()
        check(r.step(z, now: at(0), recording: true, calendarSoon: false) == nil, "no offer while recording")
        check(r.step(z, now: at(15), recording: false, calendarSoon: false) == nil, "a call seen while recording is not offered after the stop")
        var c = MeetingDetect.Debounce()
        check(c.step(z, now: at(0), recording: false, calendarSoon: true) == nil, "no offer with a calendar recording near")
        check(c.step(z, now: at(15), recording: false, calendarSoon: false) == nil, "nor later in the same call")
        check(c.step(nil, now: at(30), recording: false, calendarSoon: false) == nil, "nothing open, nothing offered")

        print("\(total - fails)/\(total) ok")
        exit(fails == 0 ? 0 : 1)
    }
}
