// Setup.swift: the checklist the first-run window shows. Built from the
// `ipsio doctor` machine line (missing=a,b ok=c,d) plus the two permissions
// only the app itself can see (screen recording and microphone are granted to
// the APP, not to the script). No AppKit here, so the bench tests it:
//   swiftc -parse-as-library app/Setup.swift tests/SetupTests.swift -o /tmp/setup-tests && /tmp/setup-tests
import Foundation

/// What the item's button does. The window maps each case to one action.
enum SetupFix: Equatable {
    case terminal(String)   // a command run in Terminal (Homebrew installs, sudo)
    case createDevice       // the bundled create-device tool, no password
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
    static let order = ["script", "dir", "ffmpeg", "switchaudio", "blackhole", "device", "screen", "other",
                        "screen_permission", "mic_permission", "microphone", "folder", "disk", "calendar"]

    static func fix(_ key: String) -> SetupFix {
        switch key {
        case "ffmpeg": return .terminal("brew install ffmpeg")
        case "switchaudio": return .terminal("brew install switchaudio-osx")
        // The driver only shows up after the audio system reloads.
        case "blackhole": return .terminal("brew install blackhole-2ch && sudo killall coreaudiod")
        case "device": return .createDevice
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
    /// sees it and the script's screenshot proved it: either one alone has lied
    /// (a new grant only reaches a new process). A doctor that did not answer
    /// is one red "script" item, never a green list.
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
            return SetupItem(key: k, ok: ok, required: k != "calendar", fix: ok ? .none : fix(k))
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

    /// The Terminal script for a `.terminal` fix: Homebrew's PATH first (a new
    /// Terminal may not have it), a clear stop when Homebrew is missing, and the
    /// window left open so the person reads the result.
    static func terminalScript(_ command: String) -> String {
        """
        #!/bin/bash
        for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && eval "$("$b" shellenv)"; done
        if ! command -v brew >/dev/null 2>&1; then
          echo "Homebrew is missing. Install it from https://brew.sh and click the button in Ipsio again."
          open https://brew.sh
          exit 1
        fi
        echo "Ipsio: \(command)"
        \(command)
        echo
        echo "Done. You can close this window; Ipsio updates by itself."
        """
    }
}
