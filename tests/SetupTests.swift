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
        OK  ffmpeg
        #state verdict=SETUP_OK mode=class missing= ok=dir,ffmpeg,blackhole,screen,switchaudio,device,folder,disk,permission calendar=none
        """
        let st = Setup.parseState(good)
        check(st["verdict"] == "SETUP_OK" && st["missing"] == "" && st["calendar"] == "none", "the #state line is parsed", "\(st)")

        let all = Setup.items(state: st, screenPermission: true, micPermission: true)
        check(keys(all) == "dir+ ffmpeg+ switchaudio+ blackhole+ device+ screen+ screen_permission+ mic_permission+ folder+ disk+ calendar-",
              "a good Mac: every item green, calendar last and off", keys(all))
        check(Setup.complete(all), "a missing calendar does not block")
        check(!all.contains { $0.key == "microphone" }, "class mode shows no microphone item")
        check(!all.contains { $0.key == "permission" }, "the doctor's permission folds into screen_permission")

        let noMic = Setup.items(state: st, screenPermission: true, micPermission: false)
        check(!Setup.complete(noMic), "without the app's microphone permission it is not ready")
        check(noMic.first { $0.key == "mic_permission" }?.fix == .micPermission, "the microphone item asks for the permission")

        // The app sees the grant, but the script's screenshot still fails (or the reverse): red.
        let half = Setup.parseState("#state verdict=SETUP_INCOMPLETE mode=class missing=permission ok=dir,ffmpeg calendar=none")
        check(Setup.items(state: half, screenPermission: true, micPermission: true).first { $0.key == "screen_permission" }?.ok == false,
              "screen permission needs the script's proof too")
        check(Setup.items(state: st, screenPermission: false, micPermission: true).first { $0.key == "screen_permission" }?.ok == false,
              "screen permission needs the app's own grant too")

        let broken = Setup.parseState("#state verdict=SETUP_INCOMPLETE mode=meeting missing=ffmpeg,blackhole,device,microphone,disk ok=dir,switchaudio,folder calendar=ics,list")
        let b = Setup.items(state: broken, screenPermission: true, micPermission: true)
        func fix(_ k: String) -> SetupFix? { b.first { $0.key == k }?.fix }
        check(fix("ffmpeg") == .terminal("brew install ffmpeg"), "ffmpeg is fixed with brew")
        check(fix("blackhole") == .terminal("brew install blackhole-2ch && sudo killall coreaudiod"), "BlackHole reloads the audio system after installing")
        check(fix("device") == .createDevice, "the device is created by the bundled tool")
        check(fix("microphone") == .soundInput, "a missing microphone opens Sound input")
        check(fix("disk") == .chooseFolder, "a full disk offers another folder")
        check(b.first { $0.key == "calendar" }?.ok == true, "a connected calendar is green")
        check(!Setup.complete(b), "anything required missing is not ready")
        check(b.filter { $0.ok }.allSatisfy { $0.fix == .none }, "a green item has no button")

        let both = Setup.parseState("#state verdict=SETUP_INCOMPLETE mode=class missing=device ok=device calendar=none")
        check(Setup.items(state: both, screenPermission: true, micPermission: true).first { $0.key == "device" }?.ok == false,
              "missing wins over a stray ok")

        let newer = Setup.parseState("#state verdict=SETUP_INCOMPLETE mode=class missing=gpu ok=dir,ffmpeg,blackhole,screen,switchaudio,device,folder,disk,permission calendar=none")
        let n = Setup.items(state: newer, screenPermission: true, micPermission: true)
        check(!Setup.complete(n) && n.contains { $0.key == "other" && !$0.ok }, "a missing item the list does not know is red, not dropped", keys(n))

        for bad in ["", "COULD NOT RUN THE SCRIPT\n/x/ipsio.sh: error", "#state verdict=RECORDING file=/a b"] {
            let i = Setup.items(state: Setup.parseState(bad), screenPermission: true, micPermission: true)
            check(i.count == 1 && i[0].key == "script" && !i[0].ok && !Setup.complete(i), "a doctor that did not answer is never green", keys(i))
        }

        let sh = Setup.terminalScript("brew install ffmpeg")
        check(sh.hasPrefix("#!/bin/bash") && sh.contains("shellenv") && sh.contains("https://brew.sh") && sh.contains("\nbrew install ffmpeg\n"),
              "the Terminal script loads Homebrew, stops without it and runs the command")

        print("\n\(total - fails)/\(total) ok")
        exit(fails == 0 ? 0 : 1)
    }
}
