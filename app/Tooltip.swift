// Tooltip.swift: the text macOS shows when the pointer rests on the menu bar
// icon. Without it the icon said nothing on hover, and an office that had
// renamed the app from a "class recorder" could not tell, by hovering, which
// app that dot was or whether it was recording. Always starts with the app's
// name; then what it is doing now, in the user's language.
// Pure, so the bench (tests/TooltipTests.swift) can fail a broken one.
import Foundation

enum Tooltip {
    /// - lang: "pt" or anything else (English).
    /// - recording: a recorder is running now.
    /// - mode: "meeting" or "class" (the menu's mode).
    /// - meeting: the calendar meeting being recorded, if the calendar started it.
    static func text(lang: String, recording: Bool, mode: String, meeting: String?) -> String {
        let pt = lang == "pt"
        guard recording else {
            return pt ? "Ipsio · pronto para gravar aulas e reuniões" : "Ipsio · ready to record classes and meetings"
        }
        if let m = meeting?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty {
            return (pt ? "Ipsio · gravando: " : "Ipsio · recording: ") + m
        }
        if mode == "meeting" { return pt ? "Ipsio · gravando reunião" : "Ipsio · recording a meeting" }
        return pt ? "Ipsio · gravando aula" : "Ipsio · recording a class"
    }
}
