import AppKit

/// ⌘K with the sidebar folded to its compact column, which has no search field: the
/// sidebar's search in a glass card over the conversation. The field keeps the keyboard
/// (↑ ↓ move, Return opens, Esc closes, and so does ⌘K again); with nothing typed it lists
/// recent chats. Results are the sidebar's own rows: conversations by name, then messages
/// from the full-text index once typing pauses. Keyboard-driven, so it comes and goes
/// without animating (DESIGN.md).
final class QuickSearch: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var onChat: ((Chat) -> Void)?
    var onMessage: ((Store.SearchHit, Chat) -> Void)?
    /// Gone, picked or not.
    var onDismissed: (() -> Void)?

    private enum Row {
        case header(String)
        case chat(Chat)
        case hit(Store.SearchHit, Chat)

        var selectable: Bool { if case .header = self { return false }; return true }
        var height: CGFloat { if case .header = self { return 30 }; return 80 }
        var key: String {
            switch self {
            case .header(let t): "h:" + t
            case .chat(let c): "c:" + c.jid
            case .hit(let h, _): "m:\(h.chat)/\(h.id)"
            }
        }
    }

    static let width: CGFloat = 560
    static let radius: CGFloat = 20
    private static let fieldHeight: CGFloat = 52
    /// Five and a half rows: the half says there's more.
    private static let maxListHeight: CGFloat = 470
    /// The selection sits 10pt in from every edge of the card, so its corners are concentric
    /// with the card's: the rows start `gutter` in and draw it 2pt inside themselves, which
    /// leaves the avatar 12pt inside it (the cells put the avatar 14pt in) and the section
    /// titles in line with the avatars.
    private static let inset: CGFloat = 10
    private static let gutter: CGFloat = 8
    private static let recentCount = 30

    private let store: Store
    private let scrim = SheetScrim()
    private let card = NSView()
    private let glass = NSGlassEffectView()
    private let rim = GlassRim()
    private let icon = NSImageView()
    private let field = NSTextField()
    private let rule = NSBox()
    private let scroll = NSScrollView()
    private let table = QuickSearchTable()
    private let note = NSTextField(labelWithString: "")
    private var listHeight: NSLayoutConstraint!

    private var chats: [Chat] = []
    private var byJID: [String: Chat] = [:]
    private var rows: [Row] = []
    /// Message results for `searched`; they stay until the next search lands, so they
    /// don't blink out on every keystroke.
    private var hits: [Store.SearchHit] = []
    private var searched = ""
    private var pending: DispatchWorkItem?
    private weak var returnFocus: NSResponder?
    private var gone = false

    init(store: Store) {
        self.store = store
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        scrim.onClick = { [weak self] in self?.dismiss() }
        scrim.translatesAutoresizingMaskIntoConstraints = false

        card.wantsLayer = true
        card.translatesAutoresizingMaskIntoConstraints = false
        glass.cornerRadius = Self.radius
        glass.tintColor = Theme.glassTint
        glass.translatesAutoresizingMaskIntoConstraints = false
        rim.radius = Self.radius

        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17)
        field.placeholderString = "Search chats and messages"
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("row"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .regular
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.onHover = { [weak self] i in
            guard let self, self.rows.indices.contains(i), self.rows[i].selectable else { return }
            self.table.selectRowIndexes([i], byExtendingSelection: false)
        }
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: Self.inset, left: 0, bottom: Self.inset, right: 0)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        note.font = .systemFont(ofSize: 13)
        note.textColor = .secondaryLabelColor
        note.alignment = .center
        note.lineBreakMode = .byTruncatingMiddle
        note.isHidden = true
        note.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        [icon, field, rule, scroll, note].forEach(content.addSubview)
        glass.contentView = content
        [rim, glass].forEach(card.addSubview)
        [scrim, card].forEach(addSubview)

        listHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
        listHeight.priority = .defaultHigh   // gives way in a short window
        // A sixth of the way down, never under the toolbar.
        let drop = NSLayoutConstraint(item: card, attribute: .top, relatedBy: .equal, toItem: self, attribute: .bottom,
                                      multiplier: 0.16, constant: 0)
        drop.priority = .defaultLow
        let fill = card.widthAnchor.constraint(equalTo: widthAnchor, constant: -32)
        fill.priority = .defaultHigh   // 560pt at most, otherwise the width less the gutters
        NSLayoutConstraint.activate([
            scrim.leadingAnchor.constraint(equalTo: leadingAnchor), scrim.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrim.topAnchor.constraint(equalTo: topAnchor), scrim.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            fill,
            card.widthAnchor.constraint(lessThanOrEqualToConstant: Self.width),
            card.topAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.topAnchor, constant: 16),
            card.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -24),
            drop,
            rim.leadingAnchor.constraint(equalTo: card.leadingAnchor), rim.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            rim.topAnchor.constraint(equalTo: card.topAnchor), rim.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: card.leadingAnchor), glass.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            glass.topAnchor.constraint(equalTo: card.topAnchor), glass.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: content.topAnchor, constant: Self.fieldHeight / 2),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            field.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            rule.leadingAnchor.constraint(equalTo: content.leadingAnchor), rule.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rule.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.fieldHeight),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.gutter),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.gutter),
            scroll.topAnchor.constraint(equalTo: rule.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            listHeight,
            note.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            note.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            note.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel("Quick Search")
        field.setAccessibilityLabel("Search chats and messages")
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Over the conversation, the field focused; recent chats until something's typed.
    func present(in host: NSView) {
        returnFocus = host.window?.firstResponder
        let locked = ChatPrefs.locked
        chats = (store.chats(archived: false) + store.chats(archived: true)).filter { !locked.contains($0.jid) }
        byJID = Dictionary(chats.map { ($0.jid, $0) }, uniquingKeysWith: { a, _ in a })
        host.addSubview(self)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: host.safeAreaLayoutGuide.leadingAnchor),
            trailingAnchor.constraint(equalTo: host.trailingAnchor),
            topAnchor.constraint(equalTo: host.topAnchor),
            bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        scrim.needsDisplay = true   // its tint depends on the window's appearance
        rebuild(keepSelection: false)
        host.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(field)
    }

    /// Put away without picking. The keyboard goes back where it was, unless something
    /// else (a click in the sidebar) has just taken it.
    func dismiss(restoringFocus: Bool = true) {
        guard !gone else { return }
        gone = true
        pending?.cancel()
        let back = restoringFocus ? returnFocus : nil
        let w = window
        removeFromSuperview()
        if let back, let w { w.makeFirstResponder(back) }
        onDismissed?()
    }

    /// Dev hook: types a query, as the keyboard would.
    func setQuery(_ q: String) {
        field.stringValue = q
        field.currentEditor()?.selectedRange = NSRange(location: (q as NSString).length, length: 0)
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    // MARK: results

    private var query: String { field.stringValue.trimmingCharacters(in: .whitespaces) }

    private func rebuild(keepSelection: Bool) {
        let kept = keepSelection && rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].key : nil
        let q = query
        var out: [Row] = []
        if q.isEmpty {
            let recent = chats.sorted { $0.lastTS > $1.lastTS }.prefix(Self.recentCount)
            if !recent.isEmpty { out.append(.header("Recent")); out += recent.map { .chat($0) } }
        } else {
            let named = chats.filter { $0.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil || $0.jid.contains(q) }
            if !named.isEmpty { out.append(.header("Conversations")); out += named.map { .chat($0) } }
            let locked = ChatPrefs.locked
            let found = hits.compactMap { h -> Row? in
                guard !locked.contains(h.chat), let c = byJID[h.chat] ?? store.chat(h.chat) else { return nil }
                return .hit(h, c)
            }
            if !found.isEmpty { out.append(.header("Messages")); out += found }
        }
        rows = out
        table.reloadData()
        select(kept.flatMap { k in rows.firstIndex { $0.key == k } } ?? rows.firstIndex { $0.selectable })
        resize()
    }

    private func resize() {
        // Nothing found says so once the message search has had its turn.
        let empty = rows.isEmpty && !query.isEmpty && searched == query
        note.stringValue = empty ? "No results for “\(query)”" : ""
        note.isHidden = !empty
        let h = rows.reduce(0) { $0 + $1.height }
        listHeight.constant = rows.isEmpty ? (empty ? 64 : 0) : min(h + 2 * Self.inset, Self.maxListHeight)
        rule.isHidden = listHeight.constant == 0
    }

    private func select(_ i: Int?) {
        guard let i else { table.deselectAll(nil); return }
        table.selectRowIndexes([i], byExtendingSelection: false)
        // The first result brings its section title into view with it.
        table.scrollRowToVisible(i == rows.firstIndex { $0.selectable } ? 0 : i)
    }

    private func move(_ by: Int) {
        let picks = rows.indices.filter { rows[$0].selectable }
        guard !picks.isEmpty else { return }
        let at = picks.firstIndex(of: table.selectedRow) ?? (by > 0 ? -1 : 0)
        let next = picks[(at + by + picks.count) % picks.count]
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next == picks.first ? 0 : next)
    }

    private func pick(_ i: Int) {
        guard rows.indices.contains(i) else { return }
        let row = rows[i]
        dismiss(restoringFocus: false)
        switch row {
        case .chat(let c): onChat?(c)
        case .hit(let h, let c): onMessage?(h, c)
        case .header: break
        }
    }

    @objc private func clicked() { pick(table.clickedRow) }

    /// Conversations filter as you type; the message search waits for a 150ms pause.
    private func scheduleMessageSearch() {
        pending?.cancel()
        pending = nil
        let q = query
        guard !q.isEmpty else { hits = []; searched = ""; return }
        guard q != searched else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.runMessageSearch(q) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func runMessageSearch(_ q: String) {
        pending = nil
        guard !gone, q == query else { return }
        searched = q
        hits = store.searchMessages(q)
        rebuild(keepSelection: true)
    }

    // MARK: field

    func controlTextDidChange(_ obj: Notification) {
        if query.isEmpty { hits = []; searched = "" }
        rebuild(keepSelection: false)
        scheduleMessageSearch()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): pick(table.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        default: return false
        }
        return true
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row].height }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row].selectable }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let r = SidebarRowView()
        r.alwaysEmphasized = true
        r.selectionInset = Self.inset - Self.gutter
        // Hairlines only between two results: none after the last or above a section title.
        r.showsSeparator = rows[row].selectable && row + 1 < rows.count && rows[row + 1].selectable
        return r
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let id = NSUserInterfaceItemIdentifier("header")
            let v = tableView.makeView(withIdentifier: id, owner: nil) as? SectionHeaderView ?? SectionHeaderView()
            v.identifier = id
            v.label.stringValue = title
            return v
        case .chat(let c):
            let v = chatCell(tableView)
            v.configure(c, typing: false)
            return v
        case .hit(let h, let c):
            let v = chatCell(tableView)
            v.configure(hit: h, in: c)
            return v
        }
    }

    private func chatCell(_ tableView: NSTableView) -> ChatCellView {
        let id = NSUserInterfaceItemIdentifier("chat")
        let v = tableView.makeView(withIdentifier: id, owner: nil) as? ChatCellView ?? ChatCellView()
        v.identifier = id
        return v
    }
}

/// The results table: the row under the pointer is the highlighted one, as in the
/// mention list, so the pointer and the arrow keys share one highlight.
private final class QuickSearchTable: NSTableView {
    var onHover: ((Int) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        let r = row(at: convert(event.locationInWindow, from: nil))
        if r >= 0, r != selectedRow { onHover?(r) }
    }
}
