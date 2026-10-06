// ConsentTests.swift: the bench for the consent reminder (app/Consent.swift):
// when to remind, how, and what the notice says. Compiles alone:
//   swiftc -parse-as-library app/Consent.swift tests/ConsentTests.swift -o /tmp/consent-tests && /tmp/consent-tests
// Exits 1 if any assertion fails.
import Foundation

var fails = 0, total = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    total += 1
    if ok { print("ok   \(name)") } else { fails += 1; print("FAIL \(name)"); let d = detail(); if !d.isEmpty { print("      \(d)") } }
}

@main
struct ConsentTests {
    static func main() {
        typealias C = Consent
        func r(_ on: Bool = true, _ mode: String = "meeting", _ tr: C.Trigger, _ id: String? = nil, _ seen: Set<String> = []) -> C.Reminder {
            C.shouldRemind(enabled: on, mode: mode, trigger: tr, eventID: id, alreadyReminded: seen)
        }
        // When.
        for m in ["meeting", "class"] {
            check(r(true, m, .manual) == .dialog, "\(m): a recording by hand asks first (popup)")
            check(r(true, m, .calendar, "e1") == .notification, "\(m): a calendar recording only notifies, never a popup")
            check(r(true, m, .test) == .none, "\(m): the test take does not remind")
            for tr in [C.Trigger.manual, .calendar, .test] { check(r(false, m, tr, "e1") == .none, "\(m): off means never (\(tr))") }
        }
        check(r(true, "meeting", .calendar, "e1", ["e1"]) == .none, "the same calendar event is reminded once")
        check(r(true, "meeting", .calendar, "e2", ["e1"]) == .notification, "another event is reminded")
        check(r(true, "meeting", .calendar, nil, ["e1"]) == .notification, "an event without an id is still reminded")
        check(r(true, "meeting", .manual, "e1", ["e1"]) == .dialog, "by hand asks even if the event was reminded")

        // The conf key: on by default, "0" turns it off.
        check(C.enabled([:]) && C.enabled(["CONSENT_REMINDER": "1"]) && C.enabled(["CONSENT_REMINDER": ""]), "on by default")
        check(!C.enabled(["CONSENT_REMINDER": "0"]), "CONSENT_REMINDER='0' turns it off")

        // What it says.
        let ptM = C.text(lang: "pt", mode: "meeting"), enM = C.text(lang: "en", mode: "meeting")
        let ptC = C.text(lang: "pt", mode: "class"), enC = C.text(lang: "en", mode: "class")
        check(ptM.contains("reunião") && ptM.contains("gravada") && ptM.contains("avise agora"), "pt meeting notice", ptM)
        check(enM.contains("meeting") && enM.contains("recorded") && enM.contains("say so now"), "en meeting notice", enM)
        check(ptC.contains("aula") && ptC.contains("vozes") && ptC != ptM, "pt class notice names the class and the voices", ptC)
        check(enC.contains("class") && enC.contains("voices") && enC != enM, "en class notice names the class and the voices", enC)
        check(C.text(lang: "fr", mode: "meeting") == ptM, "an unknown language falls back to pt, like the rest of the app")
        check(C.text(lang: "en", mode: "other") == enM, "an unknown mode gets the meeting notice (it says more, not less)")
        for s in [ptM, enM, ptC, enC] { check(s.count <= 200, "short enough to paste: \(s.count) chars") }

        // The popup.
        check(C.buttons(lang: "pt") == ["Copiar aviso e gravar", "Gravar", "Cancelar"], "pt buttons, copy first", "\(C.buttons(lang: "pt"))")
        check(C.buttons(lang: "en") == ["Copy notice and record", "Record", "Cancel"], "en buttons, copy first")
        check(C.choice(button: 0) == .copyAndRecord && C.choice(button: 1) == .record && C.choice(button: 2) == .cancel
              && C.choice(button: 9) == .cancel, "buttons map to choices; anything else cancels")
        check(C.t("dialog_body", ptM, lang: "pt").hasSuffix(ptM) && C.t("notif_body", enM, lang: "en").hasSuffix(enM), "the notice goes into the popup and the notification")

        // Every string: both languages, no em-dash, no stray key.
        check(Set(C.pt.keys) == Set(C.en.keys), "pt and en have the same keys")
        for (k, v) in C.pt.merging(C.en.mapValues { $0 }, uniquingKeysWith: { a, b in a + b }) {
            check(!v.contains("\u{2014}") && !v.contains("\u{2013}"), "no em or en dash: \(k)")
        }
        for k in C.pt.keys { check(C.t(k, lang: "pt") != k && C.t(k, lang: "en") != k, "key resolves: \(k)") }

        print("\(total - fails)/\(total) ok")
        exit(fails == 0 ? 0 : 1)
    }
}
