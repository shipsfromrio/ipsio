// Consent.swift: a reminder to tell the others they are being recorded. Pure:
// what to say (pt, en; meeting or class wording) and when to say it. The app
// shows it (Ipsio.swift): a popup before a recording started by hand, a
// notification for one the calendar started (never a popup there: the
// calendar records on its own, with nobody at the Mac), nothing for the test
// take (it records only a test sentence and is deleted). Off with
// CONSENT_REMINDER='0' in the conf; on by default.
import Foundation

enum Consent {
    enum Trigger { case manual, calendar, test }
    enum Reminder: Equatable { case none, dialog, notification }

    static let confKey = "CONSENT_REMINDER"

    /// On unless the conf says "0".
    static func enabled(_ conf: [String: String]) -> Bool { conf[confKey] != "0" }

    /// The notice to paste in the meeting chat. Class mode still records the
    /// voices coming out of the computer, so it reminds too, in class words.
    static func text(lang: String, mode: String) -> String {
        t(mode == "class" ? "notice_class" : "notice_meeting", lang: lang)
    }

    /// Whether to remind, and how. A calendar event is reminded once (the
    /// recording may restart within the same meeting); `eventID` nil cannot be
    /// remembered, so it is reminded every time. Both modes remind.
    static func shouldRemind(enabled: Bool, mode: String, trigger: Trigger, eventID: String?,
                             alreadyReminded: Set<String>) -> Reminder {
        guard enabled else { return .none }
        switch trigger {
        case .test: return .none
        case .manual: return .dialog
        case .calendar:
            if let id = eventID, alreadyReminded.contains(id) { return .none }
            return .notification
        }
    }

    /// The popup's buttons, in order: the first copies the notice and records.
    enum Choice: Equatable { case copyAndRecord, record, cancel }
    static func choice(button: Int) -> Choice {
        switch button { case 0: return .copyAndRecord; case 1: return .record; default: return .cancel }
    }
    static func buttons(lang: String) -> [String] { ["button_copy", "button_record", "button_cancel"].map { t($0, lang: lang) } }

    static func t(_ k: String, lang: String) -> String { (lang == "en" ? en[k] : pt[k]) ?? k }

    static let pt: [String: String] = [
        "notice_meeting": "Aviso: esta reunião está sendo gravada (tela e som) para registro. Se não concordar, avise agora.",
        "notice_class": "Aviso: esta aula está sendo gravada (tela e som do computador, com as vozes de quem fala) para estudo. Se não concordar, avise agora.",
        "dialog_title": "Avisar que vai gravar?",
        "dialog_body": "Quem está na reunião deve saber que ela está sendo gravada. Cole este aviso no chat:\n\n%1",
        "button_copy": "Copiar aviso e gravar",
        "button_record": "Gravar",
        "button_cancel": "Cancelar",
        "notif_title": "Gravando: avise quem está na reunião",
        "notif_body": "Clique para copiar o aviso e cole no chat: %1",
        "copied": "Aviso copiado. Cole no chat da reunião.",
        "menu": "Lembrar de avisar que está gravando",
    ]
    static let en: [String: String] = [
        "notice_meeting": "Notice: this meeting is being recorded (screen and sound) for the record. If you do not agree, say so now.",
        "notice_class": "Notice: this class is being recorded (screen and computer sound, with the voices of those speaking) for study. If you do not agree, say so now.",
        "dialog_title": "Tell them you are recording?",
        "dialog_body": "Everyone in the meeting should know it is being recorded. Paste this notice in the chat:\n\n%1",
        "button_copy": "Copy notice and record",
        "button_record": "Record",
        "button_cancel": "Cancel",
        "notif_title": "Recording: tell the others",
        "notif_body": "Click to copy the notice, then paste it in the chat: %1",
        "copied": "Notice copied. Paste it in the meeting chat.",
        "menu": "Remind me to announce the recording",
    ]

    /// "%1" filled once (the notice holds no "%").
    static func t(_ k: String, _ a: String, lang: String) -> String { t(k, lang: lang).replacingOccurrences(of: "%1", with: a) }
}
