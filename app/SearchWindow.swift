// SearchWindow.swift: the search window. A field and a table (recording,
// time, who, what was said). Double-click shows the recording in Finder and
// copies the time ("HH:MM:SS") to paste into the player. The search itself is
// Search.find (tested in tests/SearchTests.swift), run off the main thread;
// an answer to an older query is dropped. Read only, like Search.
import AppKit

final class SearchWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    unowned let app: App
    let window: NSWindow
    private let field = NSSearchField()
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private var hits: [Search.Hit] = []
    private var generation = 0

    init(app: App) {
        self.app = app
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 480, height: 260)
        build()
    }

    private func build() {
        field.target = self; field.action = #selector(search); field.delegate = self
        field.sendsSearchStringImmediately = false
        for (id, w) in [("file", 220.0), ("time", 70.0), ("speaker", 70.0), ("snippet", 380.0)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.width = CGFloat(w); c.minWidth = 50
            table.addTableColumn(c)
        }
        table.dataSource = self; table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.target = self; table.doubleAction = #selector(open)
        let scroll = NSScrollView()
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        let root = NSStackView(views: [field, scroll, status])
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 12, right: 16)
        window.contentView = root
        for v in [field, scroll, status] as [NSView] {
            v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
        }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
    }

    private func texts() {
        window.title = app.t("search_title")
        field.placeholderString = app.t("search_placeholder")
        for (id, k) in [("file", "search_col_file"), ("time", "search_col_time"), ("speaker", "search_col_speaker"), ("snippet", "search_col_snippet")] {
            table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id))?.title = app.t(k)
        }
        if hits.isEmpty && field.stringValue.isEmpty { status.stringValue = app.t("search_hint") }
    }

    func show() {
        texts()
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
    }
    func windowWillClose(_ n: Notification) { generation += 1 }

    @objc func search() {
        generation += 1
        let g = generation, q = field.stringValue, dir = app.currentFolder()
        if Search.terms(q).isEmpty { hits = []; table.reloadData(); status.stringValue = app.t("search_hint"); return }
        status.stringValue = app.t("search_running")
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Search.find(query: q, in: dir)
            DispatchQueue.main.async {
                guard g == self.generation else { return }   // a newer query is on its way
                self.hits = found; self.table.reloadData()
                self.status.stringValue = found.isEmpty ? self.app.t("search_none")
                    : (found.count == 1 ? self.app.t("search_one") : self.app.t("search_many", String(found.count)))
            }
        }
    }

    func numberOfRows(in t: NSTableView) -> Int { hits.count }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        guard row < hits.count, let id = col?.identifier else { return nil }
        let h = hits[row]
        let text: String
        switch id.rawValue {
        case "file": text = (h.media as NSString).lastPathComponent
        case "time": text = h.transcript == nil ? "" : Search.clock(h.seconds)
        case "speaker": text = h.speaker == "Me" ? app.t("search_me") : (h.speaker == "Others" ? app.t("search_others") : h.speaker)
        default: text = h.snippet
        }
        let cell = (t.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let f = NSTextField(labelWithString: ""); f.identifier = id
            f.lineBreakMode = .byTruncatingTail; f.cell?.truncatesLastVisibleLine = true
            return f
        }()
        cell.stringValue = text
        cell.toolTip = id.rawValue == "snippet" || id.rawValue == "file" ? text : nil
        return cell
    }

    /// Shows the recording in Finder and copies the time to the pasteboard.
    @objc func open() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < hits.count else { return }
        let h = hits[row]
        guard FileManager.default.fileExists(atPath: h.media) else { status.stringValue = app.t("search_gone"); return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: h.media)])
        let pb = NSPasteboard.general
        pb.clearContents(); pb.setString(Search.clock(h.seconds), forType: .string)
        status.stringValue = app.t("search_copied", Search.clock(h.seconds))
    }
}
