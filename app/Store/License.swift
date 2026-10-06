// License.swift: who may start a recording. Foundation only, no StoreKit, so
// the bench compiles it alone:
//   swiftc -parse-as-library app/Store/License.swift tests/LicenseTests.swift -o /tmp/license-tests && /tmp/license-tests
//
// The Mac App Store build (swiftc -D STORE) is a free download with a 7-day
// full trial, then one non-consumable purchase unlocks it forever. The GPL
// build is always unlocked.
//
// The one rule the app must keep: expiry blocks only NEW recordings. A
// recording already running (started by hand, or by the calendar) is never
// stopped, and the calendar may always stop the one it started. The app asks
// canStartRecording(state) before doRecord, doTest and startCalendar, and
// asks nothing before stopping.
import Foundation

enum LicenseBuild: Equatable { case store, gpl }

enum UnlockReason: String, Equatable { case gpl, purchased }

enum LicenseState: Equatable {
    case unlocked(UnlockReason)
    case trial(daysLeft: Int)
    case expired
}

enum License {
    static let trialDays = 7
    static let day: TimeInterval = 86_400

    /// The build this binary was compiled as.
    static var currentBuild: LicenseBuild {
        #if STORE
        return .store
        #else
        return .gpl
        #endif
    }

    /// The state machine. Time is counted in whole 24-hour periods from the
    /// first launch (not calendar days, so time zones and DST move nothing):
    /// 7 days left at first launch, 1 day left in the last 24 hours, expired at
    /// exactly 7 x 24 hours.
    ///
    /// Clock tampering, failing closed in a sane way:
    /// - `lastSeen` is the latest moment this Mac was seen running the app. A
    ///   clock set back counts from there, so it neither extends the trial nor
    ///   locks anyone out: the trial resumes where it was.
    /// - A clock before the first launch (and before anything seen) is a trial
    ///   with the remaining days counted from the first launch, never more
    ///   than 7.
    static func state(firstLaunch: Date, now: Date, purchased: Bool, build: LicenseBuild, lastSeen: Date? = nil) -> LicenseState {
        if build == .gpl { return .unlocked(.gpl) }
        if purchased { return .unlocked(.purchased) }
        let effective = max(now, lastSeen ?? now)
        // A clock before the first launch counts as zero elapsed: 7 days at most.
        let elapsed = max(0, effective.timeIntervalSince(firstLaunch))
        let left = Double(trialDays) * day - elapsed
        if left <= 0 { return .expired }
        return .trial(daysLeft: Int((left / day).rounded(.up)))
    }

    /// Only a new recording is gated. Stopping, checking the sound and the
    /// calendar finishing a recording it started never ask.
    static func canStartRecording(_ s: LicenseState) -> Bool {
        if case .expired = s { return false }
        return true
    }

    /// Whether the menu shows the buy and restore items.
    static func offersPurchase(_ s: LicenseState) -> Bool {
        if case .unlocked = s { return false }
        return true
    }
}

/// UserDefaults already has this shape; the bench passes a dictionary.
protocol LicenseKeyValue: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
}
extension UserDefaults: LicenseKeyValue {}

/// Where the first launch is remembered: a tiny file in the app's state dir
/// AND the defaults. The earliest first launch and the latest moment seen win,
/// and every read writes both back, so deleting one of them resets nothing.
/// (Deleting both, e.g. the whole sandbox container, does start a new trial;
/// that is accepted.)
struct LicenseRecord {
    let file: URL
    let defaults: LicenseKeyValue
    static let firstKey = "LicenseFirstLaunch"
    static let seenKey = "LicenseLastSeen"

    struct Dates: Equatable { var first: Date; var seen: Date }

    /// Reads, merges, heals and records `now`. The first call ever makes `now`
    /// the first launch.
    @discardableResult
    func touch(now: Date) -> Dates {
        let f = readFile()
        let firsts = [f.first, defaultsDate(Self.firstKey)].compactMap { $0 }
        let seens = [f.seen, defaultsDate(Self.seenKey)].compactMap { $0 }
        let first = firsts.min() ?? now
        let seen = max(seens.max() ?? now, now)
        let d = Dates(first: first, seen: seen)
        write(d)
        return d
    }

    /// Never launched on this Mac: no file and no stored first launch.
    var isNew: Bool { readFile().first == nil && defaultsDate(Self.firstKey) == nil }

    /// The state for this launch: touch, then the state machine.
    func state(now: Date, purchased: Bool, build: LicenseBuild) -> LicenseState {
        let d = touch(now: now)
        return License.state(firstLaunch: d.first, now: now, purchased: purchased, build: build, lastSeen: d.seen)
    }

    private func defaultsDate(_ k: String) -> Date? {
        if let d = defaults.object(forKey: k) as? Date { return d }
        if let n = defaults.object(forKey: k) as? Double, n.isFinite { return Date(timeIntervalSince1970: n) }
        return nil
    }

    /// "first=<epoch seconds>\nseen=<epoch seconds>\n". A missing or garbled
    /// line is simply absent.
    private func readFile() -> (first: Date?, seen: Date?) {
        guard let s = try? String(contentsOf: file, encoding: .utf8) else { return (nil, nil) }
        var first: Date?, seen: Date?
        for line in s.split(whereSeparator: \.isNewline) {
            let p = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard p.count == 2, let n = Double(p[1]), n.isFinite else { continue }
            if p[0] == "first" { first = Date(timeIntervalSince1970: n) }
            if p[0] == "seen" { seen = Date(timeIntervalSince1970: n) }
        }
        return (first, seen)
    }

    private func write(_ d: Dates) {
        defaults.set(d.first, forKey: Self.firstKey)
        defaults.set(d.seen, forKey: Self.seenKey)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = "first=\(d.first.timeIntervalSince1970)\nseen=\(d.seen.timeIntervalSince1970)\n"
        try? body.write(to: file, atomically: true, encoding: .utf8)
    }
}

/// What the license says, in pt and en. Like app/Engine/Texts.swift: the first
/// line is the title, the rest the body; %1 is the argument.
enum LicenseTexts {
    static func t(_ k: String, _ a: [String] = [], lang: String) -> String {
        var s = (lang == "en" ? en[k] : pt[k]) ?? k
        for (i, v) in a.enumerated().reversed() { s = s.replacingOccurrences(of: "%\(i + 1)", with: v) }
        return s
    }
    static func title(_ k: String, _ a: [String] = [], lang: String) -> String {
        t(k, a, lang: lang).components(separatedBy: "\n").first ?? ""
    }
    static func body(_ k: String, _ a: [String] = [], lang: String) -> String {
        t(k, a, lang: lang).components(separatedBy: "\n").dropFirst().joined(separator: "\n")
    }

    /// The trial banner's key for this many days left.
    static func trialKey(_ daysLeft: Int) -> String { daysLeft == 1 ? "trial_one" : "trial" }

    static let en: [String: String] = [
        "trial": "TRIAL: %1 DAYS LEFT\nIpsio is fully working during the 7-day trial. Buy Ipsio lifetime once to keep recording after it ends.",
        "trial_one": "TRIAL: LAST DAY\nThe trial ends within 24 hours. Buy Ipsio lifetime once to keep recording; a recording in progress is never stopped.",
        "expired": "TRIAL ENDED\nIpsio no longer starts new recordings. Buy Ipsio lifetime once to unlock it forever, or Restore if you already bought it. Your recordings are all still in their folder.",
        "menu_trial": "Trial: %1 days left",
        "menu_trial_one": "Trial: last day",
        "menu_expired": "Trial ended",
        "menu_buy": "Buy Ipsio lifetime (%1)...",
        "menu_buy_noprice": "Buy Ipsio lifetime...",
        "notice": "7 DAYS FREE, EVERY FEATURE\nIpsio starts a 7-day free trial now, with every feature. When it ends, Ipsio no longer starts new recordings until you buy Ipsio lifetime: one purchase through the App Store, no subscription. A recording in progress always finishes, and your recordings stay yours. Already bought it? Choose Restore purchase.",
        "notice_start": "Start the 7 days",
        "notice_buy": "Buy now",
        "menu_restore": "Restore purchase",
        "purchased": "THANK YOU\nIpsio is unlocked for good on this Apple Account.",
        "purchase_pending": "PURCHASE PENDING\nThe App Store has not confirmed the purchase yet (it may need approval). Ipsio unlocks by itself when it does.",
        "purchase_failed": "PURCHASE FAILED\n%1",
        "restore_none": "NOTHING TO RESTORE\nThis Apple Account has no Ipsio lifetime purchase.",
    ]

    static let pt: [String: String] = [
        "trial": "AVALIAÇÃO: FALTAM %1 DIAS\nO Ipsio funciona por completo nos 7 dias de avaliação. Compre o Ipsio vitalício uma vez para continuar gravando depois.",
        "trial_one": "AVALIAÇÃO: ÚLTIMO DIA\nA avaliação termina em menos de 24 horas. Compre o Ipsio vitalício uma vez para continuar gravando; uma gravação em andamento nunca é interrompida.",
        "expired": "AVALIAÇÃO ENCERRADA\nO Ipsio não inicia mais gravações novas. Compre o Ipsio vitalício uma vez para liberar para sempre, ou Restaure se já comprou. Suas gravações continuam todas na pasta.",
        "menu_trial": "Avaliação: faltam %1 dias",
        "menu_trial_one": "Avaliação: último dia",
        "menu_expired": "Avaliação encerrada",
        "menu_buy": "Comprar Ipsio vitalício (%1)...",
        "menu_buy_noprice": "Comprar Ipsio vitalício...",
        "notice": "7 DIAS GRÁTIS, COM TUDO\nO Ipsio começa agora uma avaliação grátis de 7 dias, com todas as funções. Quando ela acabar, o Ipsio não começa gravações novas até a compra do Ipsio vitalício: uma compra única pela App Store, sem assinatura. Uma gravação em andamento sempre termina, e as suas gravações continuam suas. Já comprou? Escolha Restaurar compra.",
        "notice_start": "Começar os 7 dias",
        "notice_buy": "Comprar agora",
        "menu_restore": "Restaurar compra",
        "purchased": "OBRIGADO\nO Ipsio está liberado para sempre nesta Conta Apple.",
        "purchase_pending": "COMPRA PENDENTE\nA App Store ainda não confirmou a compra (pode precisar de aprovação). O Ipsio se libera sozinho quando ela confirmar.",
        "purchase_failed": "A COMPRA FALHOU\n%1",
        "restore_none": "NADA A RESTAURAR\nEsta Conta Apple não tem a compra do Ipsio vitalício.",
    ]
}
