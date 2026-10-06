// CaptureTests.swift: the bench for app/Engine/Quality.swift and
// app/Engine/Target.swift. Pure rules, no screen: the presets' numbers, the
// disk scaling, the conf encoding of a target and its fallbacks.
//   swiftc -parse-as-library app/Engine/*.swift tests/CaptureTests.swift -o /tmp/capture-tests && /tmp/capture-tests
// Exits 1 if any assertion fails.
import Foundation

var fails = 0, total = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    total += 1
    if ok { print("ok   \(name)") } else { fails += 1; print("FAIL \(name)"); let d = detail(); if !d.isEmpty { print("      \(d)") } }
}

@main
struct CaptureTests {
    static func main() {
        // ---- quality ----
        check(Quality.economy.fps == 8 && Quality.economy.videoBitrate == 2_000_000, "economy: 8 fps, 2 Mb/s")
        check(Quality.normal.fps == 12 && Quality.normal.videoBitrate == 4_000_000, "normal: 12 fps, 4 Mb/s")
        check(Quality.high.fps == 24 && Quality.high.videoBitrate == 8_000_000, "high: 24 fps, 8 Mb/s")
        let d = Recorder.Options(folder: "/x")
        check(Quality.parse(nil) == .normal && d.fps == Quality.normal.fps && d.videoBitrate == Quality.normal.videoBitrate,
              "the default is normal, and normal is what the engine always recorded")
        check(Quality.audioBitrate == Writer.Settings(width: 2, height: 2).audioBitrate, "the estimate uses the Writer's audio bitrate")
        for (s, q) in [("economy", Quality.economy), ("normal", .normal), ("high", .high), (" HIGH ", .high), ("Economy", .economy)] {
            check(Quality.parse(s) == q, "parse '\(s)'")
        }
        for s in [nil, "", "ultra", "1", "hi", "economia"] as [String?] {
            check(Quality.parse(s) == .normal, "unknown or missing '\(s ?? "nil")' is normal (fail safe)")
        }
        check(abs(Quality.normal.gbPerHour(meeting: false) - 1.8576) < 1e-9, "normal class: 1.8576 GB/h",
              "\(Quality.normal.gbPerHour(meeting: false))")
        check(abs(Quality.normal.gbPerHour(meeting: true) - 1.9152) < 1e-9, "normal meeting: 1.9152 GB/h (two audio tracks)")
        check(abs(Quality.economy.gbPerHour(meeting: false) - 0.9576) < 1e-9 && abs(Quality.high.gbPerHour(meeting: false) - 3.6576) < 1e-9,
              "economy 0.9576, high 3.6576 GB/h (class)")
        for m in [false, true] {
            check(Quality.economy.gbPerHour(meeting: m) < Quality.normal.gbPerHour(meeting: m)
                  && Quality.normal.gbPerHour(meeting: m) < Quality.high.gbPerHour(meeting: m), "GB/h grows economy < normal < high (meeting \(m))")
        }
        for q in Quality.allCases { check(q.gbPerHour(meeting: true) > q.gbPerHour(meeting: false), "\(q): a meeting takes more than a class") }
        check(Quality.economy.perHourLabel(meeting: false) == "1.0" && Quality.normal.perHourLabel(meeting: false) == "1.9"
              && Quality.high.perHourLabel(meeting: true) == "3.7", "menu labels")
        // The disk rules were set for normal: normal stays exactly as it was.
        for m in [false, true] {
            check(Quality.normal.scale(meeting: m) == 1, "normal scale is exactly 1")
            check(Quality.normal.minFreeGB(20, meeting: m) == 20 && Quality.normal.minFreeGB(30, meeting: m) == 30, "normal: MIN_FREE_GB as configured")
        }
        check(Quality.high.minFreeGB(20, meeting: false) == 40 && Quality.economy.minFreeGB(20, meeting: false) == 11,
              "the minimum scales with the preset, rounded up", "\(Quality.high.minFreeGB(20, meeting: false)) \(Quality.economy.minFreeGB(20, meeting: false))")
        check(Quality.normal.hoursLeft(freeGB: 500, meeting: false) == 500 * 10 / 18, "normal: disk_h = free*10/18, as before")
        check(Quality.high.hoursLeft(freeGB: 500, meeting: false) < Quality.normal.hoursLeft(freeGB: 500, meeting: false)
              && Quality.economy.hoursLeft(freeGB: 500, meeting: false) > Quality.normal.hoursLeft(freeGB: 500, meeting: false),
              "hours left: fewer at high, more at economy")
        check(Quality.normal.hoursLeft(freeGB: 0, meeting: true) == 0, "no disk, no hours")

        // ---- target: the conf ----
        for t in [CaptureTarget.main, .display(1), .display(69_733_382)] {
            check(CaptureTarget.parse(conf: t.conf) == t, "conf round-trip \(t)")
            check(CaptureTarget.parse(oneShot: t.oneShot) == t, "one-shot round-trip \(t)")
        }
        check(CaptureTarget.window(42).conf == nil, "a window is never written to the conf")
        check(CaptureTarget.parse(conf: "window:42") == .main, "a window in the conf is ignored: main")
        check(CaptureTarget.parse(oneShot: "window:42") == .window(42), "a window for one start")
        check(CaptureTarget.parse(oneShot: CaptureTarget.window(42).oneShot) == .window(42), "window one-shot round-trip")
        check(CaptureTarget.parse(conf: nil) == .main && CaptureTarget.parse(conf: "") == .main && CaptureTarget.parse(conf: "tv") == .main,
              "missing or unknown conf: main")
        check(CaptureTarget.parse(conf: "display:abc") == .display(0), "a display that does not parse: display 0 (falls back with the warning)")
        check(CaptureTarget.parse(oneShot: nil) == nil && CaptureTarget.parse(oneShot: " ") == nil, "no one-shot: the conf decides")
        check(CaptureTarget.parse(oneShot: "window:x") == .window(0), "a window that does not parse stays a window (fail closed)")

        // ---- target: resolution ----
        let ds: [UInt32] = [1, 5], ws: [UInt32] = [100, 200]
        check(CaptureTarget.resolve(.main, displays: ds, mainID: 1, windows: ws) == .display(1, fellBack: false), "main: the main display")
        check(CaptureTarget.resolve(.main, displays: [5], mainID: 1, windows: ws) == .display(5, fellBack: false), "main missing: the first display, like before")
        check(CaptureTarget.resolve(.display(5), displays: ds, mainID: 1, windows: ws) == .display(5, fellBack: false), "a connected display: that one")
        check(CaptureTarget.resolve(.display(9), displays: ds, mainID: 1, windows: ws) == .display(1, fellBack: true), "a display gone: main, with the warning")
        check(CaptureTarget.resolve(.display(0), displays: ds, mainID: 1, windows: ws) == .display(1, fellBack: true), "display 0: main, with the warning")
        check(CaptureTarget.resolve(.window(200), displays: ds, mainID: 1, windows: ws) == .window(200), "an open window: that window")
        check(CaptureTarget.resolve(.window(300), displays: ds, mainID: 1, windows: ws) == .windowGone, "a window gone: windowGone, never the whole screen")
        check(CaptureTarget.resolve(.window(0), displays: ds, mainID: 1, windows: [0]) == .windowGone, "window 0 never records")
        check(CaptureTarget.resolve(.main, displays: [], mainID: 1, windows: ws) == .noDisplay
              && CaptureTarget.resolve(.display(5), displays: [], mainID: 1, windows: ws) == .noDisplay, "no display at all: noDisplay")

        // ---- target: window size ----
        let a = CaptureTarget.windowSize(width: 801.5, height: 601.25, scale: 2)
        check(a == (1603 & ~1, 1202 & ~1) && a.0 % 2 == 0 && a.1 % 2 == 0, "a window in pixels, even sides", "\(a)")
        let b = CaptureTarget.windowSize(width: 3000, height: 2000, scale: 2)
        check(b.0 <= 4096 && b.1 <= 2304 && b.0 % 2 == 0 && b.1 % 2 == 0 && abs(Double(b.0) / Double(b.1) - 1.5) < 0.01,
              "a huge window fits H.264's limit, keeping its shape", "\(b)")
        check(CaptureTarget.windowSize(width: 333, height: 777, scale: 1) == (332, 776), "odd sides become even")
        let c = CaptureTarget.windowSize(width: 0, height: .nan, scale: .infinity)
        check(c.0 >= 2 && c.1 >= 2, "nonsense in, a minimal frame out", "\(c)")
        check(CaptureTarget.windowSize(width: 100, height: 50, scale: 0) == (100, 50), "an unknown scale counts as 1")

        // ---- target: the windows the menu offers ----
        let list = [CaptureTarget.Window(id: 3, app: "Zoom", bundle: "us.zoom", title: "Meeting", layer: 0),
                    CaptureTarget.Window(id: 4, app: "Ipsio", bundle: "own.ipsio", title: "Setup", layer: 0),
                    CaptureTarget.Window(id: 5, app: "Dock", bundle: "com.apple.dock", title: "Dock", layer: 20),
                    CaptureTarget.Window(id: 6, app: "Safari", bundle: "com.apple.Safari", title: "", layer: 0),
                    CaptureTarget.Window(id: 7, app: "Keynote", bundle: "com.apple.Keynote", title: "Slides", layer: 0)]
        let p = CaptureTarget.pickable(list, ownBundle: "own.ipsio")
        check(p.map { $0.id } == [7, 3], "the menu: normal layer, titled, not Ipsio, by app", "\(p.map { $0.id })")
        check(p.first?.label == "Keynote: Slides" && !p.contains { $0.label.contains("\u{2014}") }, "label App: title, no em-dash")
        let long = CaptureTarget.Window(id: 8, app: "A", bundle: "a", title: String(repeating: "x", count: 80), layer: 0)
        check(long.label.count == 3 + 60, "a long title is cut at 60", "\(long.label.count)")

        print("\n\(total - fails)/\(total) ok")
        exit(fails == 0 ? 0 : 1)
    }
}
