// Target.swift: what a recording captures. The main screen (the default), one
// display by its ID, or one window. A display is kept in the conf
// (CAPTURE_TARGET=main | display:<id>); a window is not: its ID dies with the
// window, so it only goes to the next start (IPSIO_TARGET=window:<id>).
// Resolution is pure: the Recorder hands in what ScreenCaptureKit sees.
import Foundation

enum CaptureTarget: Equatable {
    case main
    case display(UInt32)
    case window(UInt32)

    /// The conf value; nil for a window, which is never persisted.
    var conf: String? {
        switch self {
        case .main: return "main"
        case .display(let id): return "display:\(id)"
        case .window: return nil
        }
    }
    /// The value for IPSIO_TARGET (one recording).
    var oneShot: String {
        if case .window(let id) = self { return "window:\(id)" }
        return conf ?? "main"
    }

    /// From the conf: missing or unknown is the main screen, and so is a
    /// window (never persisted). A display that does not parse becomes
    /// display 0, which never exists: it falls back to main with the warning.
    static func parse(conf s: String?) -> CaptureTarget {
        let v = (s ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if v.hasPrefix("display:") { return .display(UInt32(v.dropFirst(8)) ?? 0) }
        return .main
    }
    /// From IPSIO_TARGET: nil when absent. A window that does not parse stays
    /// a window (ID 0 never exists): the user chose a window, so the start
    /// fails instead of recording the whole screen.
    static func parse(oneShot s: String?) -> CaptureTarget? {
        let v = (s ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if v.isEmpty { return nil }
        if v.hasPrefix("window") { return .window(UInt32(v.dropFirst(7)) ?? 0) }
        return parse(conf: v)
    }

    enum Resolved: Equatable {
        case display(UInt32, fellBack: Bool)   // fellBack: the chosen display is gone, this is main
        case window(UInt32)
        case windowGone
        case noDisplay
    }

    /// A display that is gone records the main screen (with a warning); a
    /// window that is gone is an error: never the whole screen in its place.
    static func resolve(_ t: CaptureTarget, displays: [UInt32], mainID: UInt32, windows: [UInt32]) -> Resolved {
        func main(_ fellBack: Bool) -> Resolved {
            if displays.contains(mainID) { return .display(mainID, fellBack: fellBack) }
            if let f = displays.first { return .display(f, fellBack: fellBack) }
            return .noDisplay
        }
        switch t {
        case .main: return main(false)
        case .display(let id): return id != 0 && displays.contains(id) ? .display(id, fellBack: false) : main(true)
        case .window(let id): return id != 0 && windows.contains(id) ? .window(id) : .windowGone
        }
    }

    /// The pixel size for a window of width x height points: times the
    /// display's scale, then fit like a screen (H.264's limit, even sides).
    static func windowSize(width: Double, height: Double, scale: Double) -> (Int, Int) {
        let s = scale.isFinite && scale > 0 ? scale : 1
        func px(_ x: Double) -> Int { x.isFinite && x > 0 ? Int((x * s).rounded()) : 0 }
        return Recorder.fit(px(width), px(height))
    }

    /// A window the menu can offer.
    struct Window: Equatable {
        let id: UInt32, app: String, bundle: String, title: String, layer: Int
        /// "App: title", the title cut at 60 characters (no em-dash).
        var label: String {
            let t = title.count > 60 ? String(title.prefix(59)) + "…" : title
            return app.isEmpty ? t : app + ": " + t
        }
    }
    /// The windows worth recording: normal layer, with a title, not our own;
    /// by app, then title, so the menu stays put between openings.
    static func pickable(_ ws: [Window], ownBundle: String) -> [Window] {
        ws.filter { $0.layer == 0 && !$0.title.trimmingCharacters(in: .whitespaces).isEmpty && $0.bundle != ownBundle && $0.id != 0 }
          .sorted { ($0.app.lowercased(), $0.title.lowercased(), $0.id) < ($1.app.lowercased(), $1.title.lowercased(), $1.id) }
    }
}
