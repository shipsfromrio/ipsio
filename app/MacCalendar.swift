// MacCalendar.swift: the Mac's Calendar app as a calendar source. Reads every
// account the person already added to Calendar (Google, iCloud, Exchange),
// with no address to paste: one "Allow" for the Calendars permission. This
// file only talks to EventKit; the rules live in Schedule.fromMacEvents.
import EventKit
import Foundation

enum MacCalendar {
    nonisolated(unsafe) static let store = EKEventStore()

    static var authorized: Bool {
        let s = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) { return s == .fullAccess }
        return s == .authorized
    }
    static var denied: Bool {
        let s = EKEventStore.authorizationStatus(for: .event)
        return s == .denied || s == .restricted
    }

    /// Asks once (macOS shows the prompt only while the status is undetermined).
    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { ok, _ in done(ok) }
        } else {
            store.requestAccess(to: .event) { ok, _ in done(ok) }
        }
    }

    /// Plugs the reader into Sources. Call once at program start.
    static func install() {
        Sources.macReader = { from, to in
            guard authorized else {
                return .failure(Sources.Failure(description: Schedule.L(
                    "no Calendars permission (System Settings > Privacy & Security > Calendars)",
                    "sem permissão de Calendários (Ajustes do Sistema > Privacidade e Segurança > Calendários)")))
            }
            // A fresh read every time: events changed on the phone show up
            // here only after the store refreshes its sources.
            store.refreshSourcesIfNecessary()
            let pred = store.predicateForEvents(withStart: from, end: to, calendars: nil)
            let evs = store.events(matching: pred).map { e -> Schedule.MacEvent in
                let declined = (e.attendees ?? []).contains { $0.isCurrentUser && $0.participantStatus == .declined }
                return Schedule.MacEvent(
                    uid: e.calendarItemExternalIdentifier ?? e.eventIdentifier ?? UUID().uuidString,
                    occurrence: e.occurrenceDate ?? e.startDate,
                    title: e.title ?? "", start: e.startDate, end: e.endDate,
                    allDay: e.isAllDay, cancelled: e.status == .canceled, declined: declined,
                    texts: [e.url?.absoluteString ?? "", e.location ?? "", e.notes ?? ""])
            }
            return .success(evs)
        }
    }
}
