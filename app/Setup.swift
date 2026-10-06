// Setup.swift: the checklist the first-run window shows. Built from the
// doctor's machine line (missing=a,b ok=c,d; Backend.swift) plus the two
// permissions only the app itself can see (screen recording and microphone).
// No AppKit here, so the bench tests it:
//   swiftc -parse-as-library app/Setup.swift tests/SetupTests.swift -o /tmp/setup-tests && /tmp/setup-tests
import Foundation

/// What the item's button does. The window maps each case to one action.
enum SetupFix: Equatable {
    case screenSettings     // Privacy > Screen & System Audio Recording
    case micPermission      // ask, or Privacy > Microphone if already refused
    case soundInput         // Sound > Input, to pick the real microphone
    case chooseFolder       // the recordings folder picker
    case connectCalendar    // Connect calendar…
    case none               // nothing a click can fix; the text says what to do
}

struct SetupItem: Equatable {
    let key: String
    let ok: Bool
    let required: Bool
    let fix: SetupFix
}

enum Setup {
    /// Display order: what blocks everything else first, the optional calendar last.
    static let order = ["script", "dir", "other", "screen_permission", "mic_permission", "microphone", "folder", "disk", "calendar"]

    static func fix(_ key: String) -> SetupFix {
        switch key {
        case "screen_permission": return .screenSettings
        case "mic_permission": return .micPermission
        case "microphone": return .soundInput
        case "folder", "disk": return .chooseFolder
        case "calendar": return .connectCalendar
        default: return .none
        }
    }

    /// The doctor's "#state key=value ..." line, as a dictionary. Values have no
    /// spaces by contract (keys and comma lists), so a split on spaces is exact.
    static func parseState(_ output: String) -> [String: String] {
        guard let line = output.components(separatedBy: .newlines).last(where: { $0.hasPrefix("#state ") }) else { return [:] }
        var d: [String: String] = [:]
        for part in line.dropFirst("#state ".count).split(separator: " ") {
            guard let i = part.firstIndex(of: "=") else { continue }
            d[String(part[..<i])] = String(part[part.index(after: i)...])
        }
        return d
    }

    /// The checklist. An item the doctor did not check (the microphone in class
    /// mode) does not appear. The screen permission is OK only when BOTH the app
    /// sees it and the doctor's own preflight agrees: either one alone has lied
    /// (a new grant only reaches a new process). The microphone permission only
    /// blocks when something will record your voice: meeting mode, or a
    /// connected calendar (calendar recordings are meetings by default). A
    /// doctor that did not answer is one red "script" item, never a green list.
    static func items(state: [String: String], screenPermission: Bool, micPermission: Bool) -> [SetupItem] {
        guard state["verdict"] == "SETUP_OK" || state["verdict"] == "SETUP_INCOMPLETE" else {
            return [SetupItem(key: "script", ok: false, required: true, fix: .none)]
        }
        func list(_ k: String) -> Set<String> { Set((state[k] ?? "").split(separator: ",").map(String.init)) }
        let missing = list("missing"), found = list("ok")
        var status: [String: Bool] = [:]
        for k in found { status[k] = true }
        for k in missing { status[k] = false }      // missing wins over a stray ok
        let doctorScreen = status.removeValue(forKey: "permission")
        status["screen_permission"] = screenPermission && doctorScreen != false
        status["mic_permission"] = micPermission
        status["calendar"] = (state["calendar"] ?? "none") != "none"
        var out = order.compactMap { k -> SetupItem? in
            guard let ok = status[k] else { return nil }
            let voice = state["mode"] == "meeting" || (state["calendar"] ?? "none") != "none"
            return SetupItem(key: k, ok: ok, required: k == "mic_permission" ? voice : k != "calendar", fix: ok ? .none : fix(k))
        }
        // Fail closed: a missing item this list does not know yet (a newer
        // doctor) is one red "other" line, never dropped into a green window.
        if !missing.subtracting(order).subtracting(["permission"]).isEmpty {
            out.insert(SetupItem(key: "other", ok: false, required: true, fix: .none), at: max(0, out.count - 1))
        }
        return out
    }

    /// Ready to record: every required item green. The calendar never blocks.
    static func complete(_ items: [SetupItem]) -> Bool { !items.isEmpty && items.allSatisfy { $0.ok || !$0.required } }
}
