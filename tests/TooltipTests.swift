// TooltipTests.swift: the bench for the menu bar tooltip. Compiles with app/Tooltip.swift:
//   swiftc -parse-as-library app/Tooltip.swift tests/TooltipTests.swift -o /tmp/tooltip-tests && /tmp/tooltip-tests
// Exits 1 if any assertion fails.
import Foundation

var fails = 0, total = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    total += 1
    if ok { print("ok   \(name)") } else { fails += 1; print("FAIL \(name)"); let d = detail(); if !d.isEmpty { print("      \(d)") } }
}

@main
struct TooltipTests {
    static func main() {
        let idlePt = Tooltip.text(lang: "pt", recording: false, mode: "class", meeting: nil)
        check(idlePt == "Ipsio · pronto para gravar aulas e reuniões", "idle, Portuguese: the name and both uses", idlePt)
        let idleEn = Tooltip.text(lang: "en", recording: false, mode: "meeting", meeting: "Weekly")
        check(idleEn == "Ipsio · ready to record classes and meetings", "idle ignores mode and a stale meeting", idleEn)

        let meetPt = Tooltip.text(lang: "pt", recording: true, mode: "meeting", meeting: nil)
        check(meetPt == "Ipsio · gravando reunião", "manual meeting says meeting, not class", meetPt)
        let classPt = Tooltip.text(lang: "pt", recording: true, mode: "class", meeting: nil)
        check(classPt == "Ipsio · gravando aula", "class mode says class", classPt)
        let classEn = Tooltip.text(lang: "en", recording: true, mode: "class", meeting: nil)
        check(classEn == "Ipsio · recording a class", "English class", classEn)

        let cal = Tooltip.text(lang: "pt", recording: true, mode: "class", meeting: "  Reunião semanal ")
        check(cal == "Ipsio · gravando: Reunião semanal", "calendar recording names the meeting, trimmed", cal)
        let blank = Tooltip.text(lang: "en", recording: true, mode: "meeting", meeting: "   ")
        check(blank == "Ipsio · recording a meeting", "a blank meeting name falls back to the mode", blank)

        for lang in ["pt", "en", "xx"] { for on in [true, false] { for mode in ["class", "meeting"] {
            let s = Tooltip.text(lang: lang, recording: on, mode: mode, meeting: nil)
            check(s.hasPrefix("Ipsio · "), "always starts with the app's name (\(lang), \(on), \(mode))", s)
        } } }

        print("\n\(total - fails)/\(total) passed")
        exit(fails == 0 ? 0 : 1)
    }
}
