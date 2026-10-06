// SetupTests.swift: the bench for the first-run checklist. Compiles with app/Setup.swift:
//   swiftc -parse-as-library app/Setup.swift tests/SetupTests.swift -o /tmp/setup-tests && /tmp/setup-tests
// Exits 1 if any assertion fails.
import Foundation

var fails = 0, total = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    total += 1
    if ok { print("ok   \(name)") } else { fails += 1; print("FAIL \(name)"); let d = detail(); if !d.isEmpty { print("      \(d)") } }
}
func keys(_ items: [SetupItem]) -> String { items.map { "\($0.key)\($0.ok ? "+" : "-")" }.joined(separator: " ") }

@main
struct SetupTests {
    static func main() {
        let good = """
        SETUP COMPLETE
        OK  /Users/x/.ipsio
        #state verdict=SETUP_OK mode=class missing= ok=dir,permission,folder,disk calendar=none
        """
        let st = Setup.parseState(good)
        check(st["verdict"] == "SETUP_OK" && st["missing"] == "" && st["calendar"] == "none", "the #state line is parsed", "\(st)")

        let all = Setup.items(state: st, screenPermission: true, micPermission: true)
        check(keys(all) == "dir+ screen_permission+ mic_permission+ folder+ disk+ calendar-",
              "a good Mac: every item green, calendar last and off", keys(all))
        check(Setup.complete(all), "a missing calendar does not block")
        check(!all.contains { $0.key == "microphone" }, "class mode shows no microphone item")
        check(!all.contains { $0.key == "permission" }, "the doctor's permission folds into screen_permission")

        // Class mode with no calendar records no voice: the microphone permission shows, and does not block.
        let classNoMic = Setup.items(state: st, screenPermission: true, micPermission: false)
        check(Setup.complete(classNoMic) && classNoMic.first { $0.key == "mic_permission" }?.ok == false,
              "class mode, no calendar: the microphone permission is shown red but does not block", keys(classNoMic))
        let meeting = Setup.parseState("#state verdict=SETUP_OK mode=meeting missing= ok=dir,permission,microphone,folder,disk calendar=none")
        let noMic = Setup.items(state: meeting, screenPermission: true, micPermission: false)
        check(!Setup.complete(noMic), "meeting mode without the microphone permission is not ready")
        check(noMic.first { $0.key == "mic_permission" }?.fix == .micPermission, "the microphone item asks for the permission")
        let calendar = Setup.parseState("#state verdict=SETUP_OK mode=class missing= ok=dir,permission,folder,disk calendar=macos")
        check(!Setup.complete(Setup.items(state: calendar, screenPermission: true, micPermission: false)),
              "a connected calendar records meetings: the microphone permission blocks")

        // The app sees the grant, but the doctor does not (or the reverse): red.
        let half = Setup.parseState("#state verdict=SETUP_INCOMPLETE mode=class missing=permission ok=dir calendar=none")
        check(Setup.items(state: half, screenPermission: true, micPermission: true).first { $0.key == "screen_permission" }?.ok == false,
              "screen permission needs the doctor's word too")
        let noScreen = Setup.items(state: st, screenPermission: false, micPermission: true)
        check(noScreen.first { $0.key == "screen_permission" }?.ok == false, "screen permission needs the app's own grant too")
        check(noScreen.first { $0.key == "screen_permission" }?.fix == .screenSettings, "the screen permission opens Settings")

        let broken = Setup.parseState("#state verdict=SETUP_INCOMPLETE mode=meeting missing=microphone,disk ok=dir,folder,permission calendar=ics,list")
        let b = Setup.items(state: broken, screenPermission: true, micPermission: true)
        func fix(_ k: String) -> SetupFix? { b.first { $0.key == k }?.fix }
        check(fix("microphone") == .soundInput, "a missing microphone opens Sound input")
        check(fix("disk") == .chooseFolder, "a full disk offers another folder")
        check(b.first { $0.key == "calendar" }?.ok == true, "a connected calendar is green")
        check(!Setup.complete(b), "anything required missing is not ready")
        check(b.filter { $0.ok }.allSatisfy { $0.fix == .none }, "a green item has no button")

        let both = Setup.parseState("#state verdict=SETUP_INCOMPLETE mode=class missing=folder ok=folder calendar=none")
        check(Setup.items(state: both, screenPermission: true, micPermission: true).first { $0.key == "folder" }?.ok == false,
              "missing wins over a stray ok")

        // An old doctor (the script's) naming BlackHole: an item this list does not know is red, not dropped.
        let old = Setup.parseState("#state verdict=SETUP_INCOMPLETE mode=class missing=blackhole ok=dir,folder,disk,permission calendar=none")
        let n = Setup.items(state: old, screenPermission: true, micPermission: true)
        check(!Setup.complete(n) && n.contains { $0.key == "other" && !$0.ok }, "a missing item the list does not know is red, not dropped", keys(n))
        check(!n.contains { $0.key == "blackhole" }, "no BlackHole row exists any more")

        for bad in ["", "DID NOT ANSWER", "#state verdict=RECORDING file=/a b"] {
            let i = Setup.items(state: Setup.parseState(bad), screenPermission: true, micPermission: true)
            check(i.count == 1 && i[0].key == "script" && !i[0].ok && !Setup.complete(i), "a doctor that did not answer is never green", keys(i))
        }

        print("\n\(total - fails)/\(total) ok")
        exit(fails == 0 ? 0 : 1)
    }
}
