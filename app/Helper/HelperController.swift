// HelperController.swift: the helper mode inside the app. Owns the menu
// ("Modo ajudante"), the panel, the live transcriber and the brain, and
// drives HelperState (HelperCore.swift) on the main thread. The app calls
// refresh(recording:file:) from its own refresh: a recording that starts with
// HELPER_MODE='1' turns the helper on, one that stops turns it off and writes
// "<name>.helper.md" next to the recording.
import AppKit
import Foundation

final class HelperController: NSObject {
    let menuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let sub = NSMenu()
    private let onItem = NSMenuItem(title: "", action: #selector(doToggle), keyEquivalent: "")
    private let brainItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let brainMenu = NSMenu()
    private let localItem = NSMenuItem(title: "", action: #selector(doLocal), keyEquivalent: "")
    private let cloudItem = NSMenuItem(title: "", action: #selector(doCloud), keyEquivalent: "")
    private let infoItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let keyItem = NSMenuItem(title: "", action: #selector(doKey), keyEquivalent: "")
    private let panelItem = NSMenuItem(title: "", action: #selector(doPanel), keyEquivalent: "")

    private let conf: () -> [String: String]
    private let saveConf: ([String: String]) -> Void
    private let lang: () -> String
    private let backend: () -> Backend
    private let panel: HelperPanel

    // One helper session per recording.
    private var session = 0
    private var attempted = false
    private var state: HelperState?
    private var brain: HelperBrain?
    private var live: LiveTranscriber?
    private var media: String?
    private var title = ""
    private var t0 = Date()
    private var timer: Timer?
    private var hasKey = false

    init(conf: @escaping () -> [String: String], writeConf: @escaping ([String: String]) -> Void,
         lang: @escaping () -> String, backend: @escaping () -> Backend) {
        self.conf = conf; self.lang = lang; self.backend = backend
        // The key never reaches the conf, whatever a caller puts in it.
        self.saveConf = { writeConf(HelperSecrets.scrub($0)) }
        self.panel = HelperPanel(lang: lang)
        super.init()
        for m in [onItem, localItem, cloudItem, keyItem, panelItem] { m.target = self }
        sub.autoenablesItems = false; brainMenu.autoenablesItems = false
        infoItem.isEnabled = false
        brainMenu.addItem(localItem); brainMenu.addItem(cloudItem); brainMenu.addItem(infoItem)
        brainItem.submenu = brainMenu
        for m in [onItem, brainItem, keyItem, panelItem] { sub.addItem(m) }
        menuItem.submenu = sub
        hasKey = HelperKeychain.hasKey
    }

    private func t(_ k: String) -> String { HelperTexts.t(k, lang: lang()) }
    private func now() -> Double { Date().timeIntervalSince(t0) }

    // ---- the app's hook ----

    func refresh(recording: Bool, file: () -> String?) {
        let c = conf(), l = lang()
        menuItem.title = t("menu")
        onItem.title = t("menu_on"); onItem.state = HelperConf.on(c) ? .on : .off
        let cloud = HelperConf.wantsCloud(c)
        brainItem.title = HelperTexts.t("brain", t(cloud ? "brain_cloud" : "brain_local"), lang: l)
        localItem.title = t("brain_local"); localItem.state = cloud ? .off : .on
        cloudItem.title = t("brain_cloud"); cloudItem.state = cloud ? .on : .off
        let why = LocalModel.unavailableReason()
        infoItem.isHidden = why == nil
        if let w = why { infoItem.title = t(w) + " " + t("cloud_offer") }
        keyItem.title = t("key_menu")
        panelItem.title = t("panel_menu"); panelItem.state = panel.isVisible ? .on : .off

        let want = recording && HelperConf.on(c)
        if want && !attempted { begin(file: file()) }
        else if !want && attempted { end() }
    }

    // ---- a session ----

    private func begin(file: String?) {
        attempted = true; session += 1
        let my = session, c = conf(), l = lang()
        media = file; title = file.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? ""
        t0 = Date()
        panel.clear()
        switch HelperPolicy.choose(conf: c, localUnavailable: LocalModel.unavailableReason(), hasKey: hasKey) {
        case .off: return
        case .unavailable(let why): say(t(why) + " " + t("cloud_offer")); return
        case .needsKey: say(t("needs_key")); return
        case .needsConsent: say(t("needs_consent")); return
        case .local: brain = LocalBrain()
        case .cloud:
            brain = CloudBrain(model: HelperConf.cloudModel(c), key: { HelperKeychain.read() },
                               consent: { [weak self] in
                                   guard let s = self else { return false }
                                   return Thread.isMainThread ? s.cloudAllowed() : DispatchQueue.main.sync { s.cloudAllowed() }
                               })
        }
        state = HelperState(lang: l)
        panel.setStatus(t("status_listening")); panel.show()
        // The recognizer's authorization may wait for a click: off main.
        DispatchQueue.global(qos: .userInitiated).async {
            let made = Result { try LiveTranscriber(language: l, clock: { Date().timeIntervalSinceReferenceDate }) }
            DispatchQueue.main.async {
                guard my == self.session, self.attempted else { return }
                switch made {
                case .failure(let e):
                    self.brain = nil; self.state = nil
                    self.say(HelperTexts.t("no_live", "\(e)", lang: l))
                case .success(let lt):
                    self.live = lt
                    lt.onLine = { [weak self] who, text, final in
                        DispatchQueue.main.async {
                            guard let s = self, my == s.session else { return }
                            s.state?.hear(who, text, final: final, at: s.now())
                        }
                    }
                    lt.start()
                    self.backend().audioTap = { [weak lt] track, sb in lt?.feed(track, sb) }
                    let tm = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick(my) }
                    RunLoop.main.add(tm, forMode: .common); self.timer = tm
                }
            }
        }
    }

    private func cloudAllowed() -> Bool {
        let c = conf()
        return HelperPolicy.choose(conf: c, localUnavailable: nil, hasKey: hasKey) == .cloud
    }

    private func tick(_ my: Int) {
        guard my == session, var s = state, let b = brain else { return }
        let n = now()
        guard s.shouldAsk(now: n) else { return }
        let req = s.beginAsk(now: n, research: b.kind == .cloud)
        state = s
        panel.setStatus(t("status_thinking"))
        Task {
            let r: Result<BrainReply, Error>
            do { r = .success(try await b.reply(to: req)) } catch { r = .failure(error) }
            await MainActor.run {
                guard my == self.session, var s = self.state else { return }
                let fresh = s.finishAsk(r, now: self.now())
                self.state = s
                self.panel.add(fresh)
                if case .failure(let e) = r {
                    self.panel.setStatus(HelperTexts.t("status_error", HelperSecrets.redact("\(e)"), lang: self.lang()))
                } else { self.panel.setStatus(self.t("status_listening")) }
            }
        }
    }

    private func end() {
        attempted = false; session += 1
        timer?.invalidate(); timer = nil
        backend().audioTap = nil
        live?.stop(); live = nil
        let s = state, b = brain, file = media, name = title, l = lang()
        state = nil; brain = nil; media = nil
        panel.setStatus(t("status_idle"))
        guard let st = s, let br = b, let f = file else { return }
        let body = HelperSummary.md(title: name, lang: l, brain: br.kind == .cloud ? "cloud" : "on this Mac", state: st)
        DispatchQueue.global(qos: .utility).async {
            // Only next to a recording that is there; never over it or its evidence.
            guard FileManager.default.fileExists(atPath: f) else { return }
            _ = try? HelperSummary.write(body, media: f)
        }
    }

    private func say(_ s: String) { panel.setStatus(s); panel.show() }

    // ---- menu ----

    @objc private func doToggle() {
        var c = conf(); let on = !HelperConf.on(c)
        c[HelperConf.mode] = on ? "1" : "0"; saveConf(c)
        if on, !HelperConf.wantsCloud(c), let why = LocalModel.unavailableReason() {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert(); a.messageText = t("unavailable_title"); a.informativeText = t(why) + "\n\n" + t("cloud_offer"); a.runModal()
        }
    }

    @objc private func doLocal() { var c = conf(); c[HelperConf.brain] = "local"; saveConf(c) }

    @objc private func doCloud() {
        NSApp.activate(ignoringOtherApps: true)
        var c = conf()
        if c[HelperConf.consent] != "1" {
            let a = NSAlert(); a.messageText = t("consent_title"); a.informativeText = t("consent_body")
            a.addButton(withTitle: t("consent_ok")); a.addButton(withTitle: t("cancel"))
            guard a.runModal() == .alertFirstButtonReturn else { return }
            c[HelperConf.consent] = "1"
        }
        c[HelperConf.brain] = "cloud"; saveConf(c)
        if !hasKey { doKey() }
    }

    @objc private func doKey() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = t("key_title"); a.informativeText = t("key_body")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        a.accessoryView = field
        a.addButton(withTitle: t("key_save")); a.addButton(withTitle: t("cancel"))
        if hasKey { a.addButton(withTitle: t("key_remove")) }
        a.window.initialFirstResponder = field
        switch a.runModal() {
        case .alertFirstButtonReturn:
            let k = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let done = NSAlert()
            if !HelperKeychain.plausible(k) { done.messageText = t("key_bad") }
            else if HelperKeychain.save(k) { hasKey = true; done.messageText = t("key_saved") }
            else { done.messageText = t("key_failed") }
            done.runModal()
        case .alertThirdButtonReturn:
            HelperKeychain.delete(); hasKey = false
            let done = NSAlert(); done.messageText = t("key_removed"); done.runModal()
        default: break
        }
    }

    @objc private func doPanel() {
        if panel.isVisible { panel.hide() } else {
            if !attempted { panel.setStatus(t("status_idle")) }
            panel.show()
        }
    }
}
