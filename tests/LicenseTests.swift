// LicenseTests.swift: the bench for the trial and the lifetime unlock. Compiles with app/Store/License.swift:
//   swiftc -parse-as-library app/Store/License.swift tests/LicenseTests.swift -o /tmp/license-tests && /tmp/license-tests
// Exits 1 if any assertion fails.
import Foundation

var fails = 0, total = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    total += 1
    if ok { print("ok   \(name)") } else { fails += 1; print("FAIL \(name)"); let d = detail(); if !d.isEmpty { print("      \(d)") } }
}

final class MemoryDefaults: LicenseKeyValue {
    var d: [String: Any] = [:]
    func object(forKey k: String) -> Any? { d[k] }
    func set(_ v: Any?, forKey k: String) { d[k] = v }
}

@main
struct LicenseTests {
    static func main() {
        let day = License.day
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func st(_ offset: TimeInterval, purchased: Bool = false, build: LicenseBuild = .store, seen: TimeInterval? = nil) -> LicenseState {
            License.state(firstLaunch: t0, now: t0.addingTimeInterval(offset), purchased: purchased, build: build,
                          lastSeen: seen.map { t0.addingTimeInterval($0) })
        }

        // The GPL build: always unlocked, whatever the clock or the purchase.
        for off in [-30 * day, 0, 7 * day, 400 * day] {
            check(st(off, build: .gpl) == .unlocked(.gpl), "GPL is unlocked at \(off / day) days", "\(st(off, build: .gpl))")
        }
        check(st(400 * day, purchased: true, build: .gpl) == .unlocked(.gpl), "GPL wins over a purchase")

        // The trial and its day boundaries.
        check(st(0) == .trial(daysLeft: 7), "first launch: 7 days left", "\(st(0))")
        check(st(1) == .trial(daysLeft: 7), "one second later: still 7", "\(st(1))")
        check(st(day - 1) == .trial(daysLeft: 7), "one second before 24 h: still 7", "\(st(day - 1))")
        check(st(day) == .trial(daysLeft: 6), "exactly 24 h: 6 days left", "\(st(day))")
        check(st(6 * day) == .trial(daysLeft: 1), "exactly 6 days: last day", "\(st(6 * day))")
        check(st(7 * day - 1) == .trial(daysLeft: 1), "one second before 7 days: last day", "\(st(7 * day - 1))")
        check(st(7 * day) == .expired, "exactly 7 days later: expired", "\(st(7 * day))")
        check(st(30 * day) == .expired, "a month later: expired")

        // The purchase.
        check(st(0, purchased: true) == .unlocked(.purchased), "bought during the trial: unlocked")
        check(st(365 * day, purchased: true) == .unlocked(.purchased), "bought after expiry: unlocked forever")
        check(st(-5 * day, purchased: true) == .unlocked(.purchased), "bought, clock in the past: unlocked")

        // The clock going back.
        check(st(-1) == .trial(daysLeft: 7), "a clock before the first launch: a trial, not a lockout", "\(st(-1))")
        check(st(-400 * day) == .trial(daysLeft: 7), "a clock far before the first launch: never more than 7 days", "\(st(-400 * day))")
        check(st(-3 * day, seen: 3 * day) == .trial(daysLeft: 4), "clock set back 6 days after 3 days of use: still 4 left, not 7", "\(st(-3 * day, seen: 3 * day))")
        check(st(2 * day, seen: 8 * day) == .expired, "clock set back after expiry: still expired", "\(st(2 * day, seen: 8 * day))")
        check(st(5 * day, seen: 2 * day) == .trial(daysLeft: 2), "a last-seen in the past changes nothing", "\(st(5 * day, seen: 2 * day))")

        // Only NEW recordings are blocked.
        check(!License.canStartRecording(.expired), "expired: no new recording")
        check(License.canStartRecording(.trial(daysLeft: 1)), "last day: a new recording starts")
        check(License.canStartRecording(.unlocked(.purchased)) && License.canStartRecording(.unlocked(.gpl)), "unlocked: a new recording starts")
        check(License.offersPurchase(.expired) && License.offersPurchase(.trial(daysLeft: 3)), "trial and expired offer the purchase")
        check(!License.offersPurchase(.unlocked(.purchased)) && !License.offersPurchase(.unlocked(.gpl)), "unlocked offers nothing")
        // A recording that started on the last day and runs past the end: the
        // gate is asked at start only, so the expiry mid-recording reaches nothing.
        let startedAt = st(7 * day - 60), endsAt = st(7 * day + 3600)
        check(License.canStartRecording(startedAt) && endsAt == .expired,
              "a recording started 1 minute before expiry was allowed to start; the gate says nothing about stopping")

        // The persistence: file + defaults, earliest first launch, latest seen.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ipsio-license-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("license")
        let defs = MemoryDefaults()
        let rec = LicenseRecord(file: file, defaults: defs)
        check(rec.isNew, "never launched: new (the trial terms are shown first)")
        let a = rec.touch(now: t0)
        check(!rec.isNew, "after the first touch: not new")
        check(a.first == t0 && a.seen == t0, "the first touch is the first launch")
        check(FileManager.default.fileExists(atPath: file.path), "the first launch is written to the file")
        check(defs.d[LicenseRecord.firstKey] as? Date == t0, "the first launch is written to the defaults")
        check(rec.touch(now: t0.addingTimeInterval(2 * day)).first == t0, "a later launch keeps the first launch")

        try? FileManager.default.removeItem(at: file)
        check(!rec.isNew, "deleting the file alone does not make it new (the defaults remember)")
        let onlyFile = LicenseRecord(file: dir.appendingPathComponent("only-file"), defaults: MemoryDefaults())
        onlyFile.touch(now: t0)
        check(!LicenseRecord(file: dir.appendingPathComponent("only-file"), defaults: MemoryDefaults()).isNew, "clearing the defaults alone does not make it new (the file remembers)")
        check(rec.state(now: t0.addingTimeInterval(3 * day), purchased: false, build: .store) == .trial(daysLeft: 4),
              "the file deleted: the defaults keep the trial going")
        check(FileManager.default.fileExists(atPath: file.path), "the deleted file is written back")

        defs.d = [:]
        check(rec.state(now: t0.addingTimeInterval(4 * day), purchased: false, build: .store) == .trial(daysLeft: 3),
              "the defaults wiped: the file keeps the trial going")
        check(defs.d[LicenseRecord.firstKey] as? Date == t0, "the wiped defaults are written back")

        // Two stores that disagree: the earliest first launch wins.
        defs.d[LicenseRecord.firstKey] = t0.addingTimeInterval(5 * day)
        check(rec.touch(now: t0.addingTimeInterval(5 * day)).first == t0, "the file's earlier first launch wins over later defaults")
        try? "first=\(t0.addingTimeInterval(6 * day).timeIntervalSince1970)\n".write(to: file, atomically: true, encoding: .utf8)
        defs.d[LicenseRecord.firstKey] = t0
        check(rec.touch(now: t0.addingTimeInterval(5 * day)).first == t0, "the defaults' earlier first launch wins over a later file")

        // The clock going back, through the record: last seen holds.
        check(rec.state(now: t0.addingTimeInterval(1 * day), purchased: false, build: .store) == .trial(daysLeft: 2),
              "clock set back to day 1 after day 5 was seen: 2 days left, not 6")
        check(rec.state(now: t0.addingTimeInterval(8 * day), purchased: false, build: .store) == .expired, "day 8 through the record: expired")
        check(rec.state(now: t0.addingTimeInterval(1 * day), purchased: false, build: .store) == .expired, "and setting the clock back does not revive it")

        // A garbled file is ignored, not trusted and not fatal.
        let fresh = MemoryDefaults()
        let file2 = dir.appendingPathComponent("garbled")
        try? "first=yesterday\nseen=\nnonsense".write(to: file2, atomically: true, encoding: .utf8)
        let g = LicenseRecord(file: file2, defaults: fresh).touch(now: t0)
        check(g.first == t0, "a garbled file reads as absent", "\(g)")

        // The texts: both languages, every key, title and body, %1 filled.
        check(Set(LicenseTexts.en.keys) == Set(LicenseTexts.pt.keys), "pt and en have the same keys")
        for lang in ["en", "pt"] {
            for k in ["trial", "trial_one", "expired", "purchased", "purchase_pending", "purchase_failed", "restore_none", "notice"] {
                check(!LicenseTexts.title(k, ["3"], lang: lang).isEmpty && !LicenseTexts.body(k, ["3"], lang: lang).isEmpty,
                      "\(lang) \(k) has a title and a body")
            }
            check(LicenseTexts.title("trial", ["3"], lang: lang).contains("3"), "\(lang) trial title says the days left")
            check(!LicenseTexts.t("menu_buy", ["US$ 19.99"], lang: lang).contains("%1"), "\(lang) buy item has its price")
            let n = LicenseTexts.body("notice", lang: lang)
            check(n.contains("7") && (n.contains("App Store")), "\(lang) the trial notice says the length and where the purchase is")
            check(!LicenseTexts.t("menu_buy_noprice", lang: lang).contains("%1"), "\(lang) buy item without a price has no hole")
            for (k, v) in (lang == "en" ? LicenseTexts.en : LicenseTexts.pt) {
                check(!v.contains("\u{2014}"), "\(lang) \(k) has no em-dash")
            }
        }
        check(LicenseTexts.trialKey(1) == "trial_one" && LicenseTexts.trialKey(2) == "trial", "one day left has its own text")

        print("\n\(total - fails)/\(total) ok")
        exit(fails == 0 ? 0 : 1)
    }
}
