// MeetingDetect.swift: is a call open right now? From the running apps and
// the window titles only (no screen pixels, no audio). An app that merely
// runs is never a meeting: Zoom open on its home window, Teams on a chat, the
// Meet landing page. Only a window that is the call itself counts. The app
// asks this every 15 s and offers to record; Debounce makes it ask once.
// Pure: no AppKit, no ScreenCaptureKit (tests/MeetingDetectTests.swift).
import Foundation

enum MeetingDetect {
    struct Meeting: Equatable {
        let app: String   // "Zoom", "Microsoft Teams", "Google Meet", "Webex", "Slack"
        let key: String   // stable while the call lasts: one offer per key
    }

    static let zoom: Set<String> = ["us.zoom.xos"]
    static let teams: Set<String> = ["com.microsoft.teams2", "com.microsoft.teams"]
    static let webex: Set<String> = ["com.cisco.webexmeetingsapp", "Cisco-Systems.Spark"]
    static let slack: Set<String> = ["com.tinyspeck.slackmacgap"]
    static let browsers: Set<String> = ["com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac",
                                        "company.thebrowser.Browser", "org.mozilla.firefox", "com.brave.Browser"]

    /// Lower case, no accents, split on anything not a letter or digit.
    static func words(_ s: String) -> [String] {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// `phrase` appears in `w` as whole consecutive words ("meetings" is not "meeting").
    static func has(_ w: [String], _ phrase: String) -> Bool {
        let p = words(phrase)
        guard !p.isEmpty, w.count >= p.count else { return false }
        for i in 0...(w.count - p.count) where Array(w[i..<(i + p.count)]) == p { return true }
        return false
    }

    /// "abc-defg-hij" after "Meet - " (hyphen, en dash or em dash). The Meet
    /// home ("Google Meet", "Meet") has no code and does not count.
    static func meetCode(_ title: String) -> String? {
        let dashes = "[-\u{2013}\u{2014}]"
        guard let r = try? NSRegularExpression(pattern: "(?:^|\\s)Meet\\s+" + dashes + "\\s+([a-z]{3}-[a-z]{4}-[a-z]{3})(?![a-z0-9-])",
                                               options: [.caseInsensitive]),
              let m = r.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let g = Range(m.range(at: 1), in: title) else { return nil }
        return title[g].lowercased()
    }

    static func isBrowser(_ id: String) -> Bool { browsers.contains(id) || id.hasPrefix("com.google.Chrome.app.") }

    /// One window: the call it shows, or nil.
    static func classify(bundleID id: String, title: String) -> Meeting? {
        let w = words(title)
        if w.isEmpty { return nil }
        if zoom.contains(id) {
            // The call window, not the app ("Zoom", "Zoom Workplace", "Meetings" tab).
            let call = ["zoom meeting", "reuniao zoom", "reuniao do zoom", "zoom webinar", "webinar zoom", "webinar do zoom"]
            if call.contains(where: { has(w, $0) }) || w == ["meeting"] || w == ["reuniao"] { return Meeting(app: "Zoom", key: "zoom") }
            return nil
        }
        if teams.contains(id) {
            // Teams names its main window after the pane: "Chat | ...", "Calendar | ...".
            if ["chat", "calendar", "calendario", "activity", "atividade", "teams", "equipes"].contains(w[0]) { return nil }
            if ["meeting", "reuniao", "call", "chamada"].contains(where: { has(w, $0) }) { return Meeting(app: "Microsoft Teams", key: "teams") }
            return nil
        }
        if webex.contains(id) {
            if ["meeting", "reuniao", "personal room", "sala pessoal"].contains(where: { has(w, $0) }) { return Meeting(app: "Webex", key: "webex") }
            return nil
        }
        if slack.contains(id) {
            // "Huddle ..." is the huddle window; a channel named huddle-notes is not.
            let lead = title.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
            if lead.hasPrefix("huddle"), w[0] == "huddle" { return Meeting(app: "Slack", key: "slack") }
            return nil
        }
        if isBrowser(id), let c = meetCode(title) { return Meeting(app: "Google Meet", key: "meet:" + c) }
        return nil
    }

    /// The first call among the windows, only from an app that is running.
    static func detect(apps: [String], windows: [(bundleID: String, title: String)]) -> Meeting? {
        let running = Set(apps)
        for win in windows where running.contains(win.bundleID) {
            if let m = classify(bundleID: win.bundleID, title: win.title) { return m }
        }
        return nil
    }

    /// A calendar recording that is on or starts within `margin` (the
    /// calendar records by itself: no offer on top of it).
    static func calendarSoon(now: Date, spans: [(start: Date, end: Date)], margin: TimeInterval = 600) -> Bool {
        spans.contains { now >= $0.start.addingTimeInterval(-margin) && now < $0.end }
    }

    /// Offers once per call. A key is forgotten after `forget` seconds without
    /// being seen, so the next call in the same app is offered again. A call
    /// seen while recording or with a calendar recording near counts as
    /// handled: it is never offered later in the same call.
    struct Debounce {
        var forget: TimeInterval = 120
        private(set) var lastSeen: [String: Date] = [:]
        private(set) var handled: Set<String> = []

        init(forget: TimeInterval = 120) { self.forget = forget }

        /// The meeting to offer now, or nil.
        mutating func step(_ m: Meeting?, now: Date, recording: Bool, calendarSoon: Bool) -> Meeting? {
            for (k, t) in lastSeen where now.timeIntervalSince(t) > forget && k != m?.key {
                lastSeen[k] = nil; handled.remove(k)
            }
            guard let m = m else { return nil }
            if let t = lastSeen[m.key], now.timeIntervalSince(t) > forget { handled.remove(m.key) }
            lastSeen[m.key] = now
            if handled.contains(m.key) { return nil }
            handled.insert(m.key)
            return recording || calendarSoon ? nil : m
        }
    }
}
