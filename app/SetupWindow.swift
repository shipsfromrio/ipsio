// SetupWindow.swift: the first-run window. One line per thing Ipsio needs,
// green or red, each red line with the one button that fixes it, and the list
// re-checks itself every few seconds, so a fix made anywhere (Terminal,
// Settings) turns its line green with no extra click. The checklist itself
// comes from Setup.items (tested in tests/SetupTests.swift); this file only
// draws it and wires the buttons to App.applyFix.
import AppKit

final class SetupWindow: NSObject, NSWindowDelegate {
    unowned let app: App
    let window: NSWindow
    private let header = NSTextField(wrappingLabelWithString: "")
    private let rows = NSStackView()
    private let zoomLine = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let testButton = NSButton(title: "", target: nil, action: nil)
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    private(set) var items: [SetupItem] = []
    private var checking = false
    private var timer: Timer?
    /// Called once the required items are all green (the app writes setup-done).
    var onComplete: (() -> Void)?

    init(app: App) {
        self.app = app
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 480),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.delegate = self
        build()
    }

    private func build() {
        let root = NSStackView()
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        header.font = .systemFont(ofSize: 13)
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 12
        zoomLine.font = .systemFont(ofSize: 12); zoomLine.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12, weight: .medium)
        testButton.target = self; testButton.action = #selector(test); testButton.bezelStyle = .rounded
        closeButton.target = self; closeButton.action = #selector(close); closeButton.bezelStyle = .rounded
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [status, spacer, closeButton, testButton])
        footer.orientation = .horizontal; footer.spacing = 8
        for v in [header, rows, zoomLine, footer] { root.addArrangedSubview(v) }
        window.contentView = root
        for v in [header, rows, zoomLine, footer] {
            v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48).isActive = true
        }
    }

    private func texts() {
        window.title = app.t("setup_title")
        header.stringValue = app.t("setup_intro")
        zoomLine.stringValue = "ⓘ  " + app.t("setup_zoom")
        testButton.title = app.t("test"); closeButton.title = app.t("setup_close")
    }

    func show() {
        texts()
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        recheck()
        if timer == nil {
            let t = Timer(timeInterval: 4, repeats: true) { [weak self] _ in self?.recheck() }
            RunLoop.main.add(t, forMode: .common); timer = t
        }
    }
    func windowWillClose(_ n: Notification) { timer?.invalidate(); timer = nil }
    @objc func close() { window.close() }
    @objc func test() { app.doTest() }

    /// Runs the doctor off the main thread; redraws only when something changed
    /// (rebuilding the rows every 4 s would move the button under the mouse).
    /// Skipped while a test or a recording runs: the button stays off, and the
    /// doctor's two ffmpeg listings and screenshot do not compete with the recorder.
    func recheck() {
        if app.busy || app.recording() { testButton.isEnabled = false; testButton.keyEquivalent = "" }
        guard !checking, !app.busy, !app.recording() else { return }
        checking = true
        if items.isEmpty { status.stringValue = app.t("setup_checking") }
        DispatchQueue.global().async {
            let r = self.app.run("doctor")
            DispatchQueue.main.async {
                self.checking = false
                let fresh = Setup.items(state: Setup.parseState(r),
                                        screenPermission: CGPreflightScreenCaptureAccess(), micPermission: self.app.micOk())
                if fresh != self.items { self.items = fresh; self.render() }
                let ready = Setup.complete(fresh)
                let left = fresh.filter { !$0.ok && $0.required }.count
                self.status.stringValue = ready ? self.app.t("setup_ready") : (left == 1 ? self.app.t("setup_left_one") : self.app.t("setup_left", String(left)))
                self.status.textColor = ready ? .systemGreen : .labelColor
                self.testButton.isEnabled = ready && !self.app.busy && !self.app.recording()
                self.testButton.keyEquivalent = ready ? "\r" : ""
                if ready { self.onComplete?() }
            }
        }
    }

    private func render() {
        texts()
        for v in rows.arrangedSubviews { rows.removeArrangedSubview(v); v.removeFromSuperview() }
        for (i, item) in items.enumerated() { rows.addArrangedSubview(row(item, tag: i)) }
        // Grow or shrink to the rows: a fixed height squeezed the footer with many red lines.
        if let root = window.contentView { root.layoutSubtreeIfNeeded(); window.setContentSize(NSSize(width: 580, height: root.fittingSize.height)) }
    }

    private func row(_ item: SetupItem, tag: Int) -> NSView {
        let symbol = item.ok ? "checkmark.circle.fill" : (item.required ? "xmark.circle.fill" : "circle.dashed")
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: item.ok ? "OK" : app.t("setup_missing")) ?? NSImage())
        icon.contentTintColor = item.ok ? .systemGreen : (item.required ? .systemRed : .secondaryLabelColor)
        icon.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let title = NSTextField(labelWithString: app.t("setup_" + item.key))
        title.font = .systemFont(ofSize: 13, weight: item.ok ? .regular : .semibold)
        let text = NSStackView(views: [title]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 2
        if !item.ok {
            let hint = NSTextField(wrappingLabelWithString: app.t("setup_" + item.key + "_hint"))
            hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor
            text.addArrangedSubview(hint)
            hint.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true
        }
        let line = NSStackView(views: [icon, text]); line.orientation = .horizontal; line.alignment = .top; line.spacing = 10
        if !item.ok, item.fix != .none {
            let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let b = NSButton(title: app.t(App.fixLabel(item.fix)), target: self, action: #selector(fix(_:)))
            b.bezelStyle = .rounded; b.tag = tag
            line.addArrangedSubview(spacer); line.addArrangedSubview(b)
        }
        line.widthAnchor.constraint(equalToConstant: 532).isActive = true
        return line
    }

    @objc private func fix(_ b: NSButton) {
        guard b.tag < items.count else { return }
        app.applyFix(items[b.tag].fix)
        // Fixes that finish fast (device, folder) show up on the next check.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.recheck() }
    }
}
