// HelperPanel.swift: the small floating panel with the tips. Non-activating
// (a click on it never takes the focus from the meeting app), always on top,
// on every Space and over full-screen apps; closing it only hides it.
// Newest tip first; each tip shows its text, and its "why" on hover or by
// expanding it.
import AppKit

final class HelperPanel: NSObject, NSWindowDelegate {
    static let keep = 30
    private var panel: NSPanel?
    private let stack = NSStackView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let lang: () -> String

    init(lang: @escaping () -> String) { self.lang = lang }

    var isVisible: Bool { panel?.isVisible ?? false }

    private func build() -> NSPanel {
        if let p = panel { return p }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isFloatingPanel = true; p.level = .floating; p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false; p.becomesKeyOnlyIfNeeded = true; p.delegate = self
        p.title = HelperTexts.t("panel_title", lang: lang())
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let doc = FlippedView(); doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack); scroll.documentView = doc
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor), stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor), stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        stack.addArrangedSubview(status)
        status.preferredMaxLayoutWidth = 310
        p.contentView = scroll
        if let s = NSScreen.main?.visibleFrame { p.setFrameTopLeftPoint(NSPoint(x: s.maxX - 360, y: s.maxY - 20)) }
        panel = p
        return p
    }

    func show() { build().orderFrontRegardless() }
    func hide() { panel?.orderOut(nil) }

    func setStatus(_ s: String) { _ = build(); status.stringValue = s }

    func clear() {
        for v in stack.arrangedSubviews where v !== status { stack.removeArrangedSubview(v); v.removeFromSuperview() }
    }

    /// `tips` newest first; they go on top, under the status line.
    func add(_ tips: [HelperTip]) {
        _ = build()
        for tip in tips.reversed() { stack.insertArrangedSubview(TipView(tip, lang: lang()), at: 1) }
        while stack.arrangedSubviews.count > HelperPanel.keep + 1, let last = stack.arrangedSubviews.last {
            stack.removeArrangedSubview(last); last.removeFromSuperview()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

private final class TipView: NSStackView {
    private let why: NSTextField
    private let toggle: NSButton
    private let lang: String

    init(_ tip: HelperTip, lang: String) {
        self.lang = lang
        let text = NSTextField(wrappingLabelWithString: tip.text)
        text.font = .systemFont(ofSize: 13, weight: .medium); text.preferredMaxLayoutWidth = 310
        var more = [tip.why]
        if !tip.answers.isEmpty { more.append(HelperTexts.t("answers", tip.answers, lang: lang)) }
        if let s = tip.source { more.append(HelperTexts.t("source", s, lang: lang)) }
        why = NSTextField(wrappingLabelWithString: more.filter { !$0.isEmpty }.joined(separator: "\n"))
        why.font = .systemFont(ofSize: 11); why.textColor = .secondaryLabelColor; why.preferredMaxLayoutWidth = 310
        why.isHidden = true; why.isSelectable = true
        toggle = NSButton(title: HelperTexts.t("why", lang: lang), target: nil, action: nil)
        toggle.bezelStyle = .inline; toggle.controlSize = .small
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 3
        toolTip = more.filter { !$0.isEmpty }.joined(separator: "\n")
        toggle.target = self; toggle.action = #selector(flip)
        let head = NSTextField(labelWithString: HelperText.clock(tip.t))
        head.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular); head.textColor = .tertiaryLabelColor
        for v in [head, text, toggle, why] { addArrangedSubview(v) }
        if more.allSatisfy({ $0.isEmpty }) { toggle.isHidden = true }
    }
    required init?(coder: NSCoder) { nil }

    @objc private func flip() {
        why.isHidden.toggle()
        toggle.title = HelperTexts.t(why.isHidden ? "why" : "hide", lang: lang)
    }
}
