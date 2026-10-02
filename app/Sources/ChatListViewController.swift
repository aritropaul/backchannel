import AppKit

protocol ChatListDelegate: AnyObject {
    func chatList(didSelect chat: Chat?)
    /// A message search result was picked: open its chat scrolled to it.
    func chatList(didSelectMessage id: String, in chat: Chat)
}

/// Source-list row whose selection is the same green as my bubbles (`Theme.selection`), drawn
/// without vibrancy so the glass sidebar doesn't lighten it; chats also get a Messages-style
/// hairline from the text column to the trailing edge.
final class SidebarRowView: NSTableRowView {
    var showsSeparator = false

    override var allowsVibrancy: Bool { false }

    override func drawSelection(in dirtyRect: NSRect) {
        (isEmphasized ? Theme.selection : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 0), xRadius: 10, yRadius: 10).fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard showsSeparator, !isSelected, !isNextRowSelected else { return }
        let x = (subviews.first { $0 is ChatCellView }?.frame.minX ?? 0) + ChatCellView.textX
        let h = 1 / (window?.backingScaleFactor ?? 2)
        NSColor.separatorColor.setFill()
        NSRect(x: x, y: isFlipped ? bounds.maxY - h : 0, width: max(0, bounds.width - x - 20), height: h).fill()
    }
}

final class ChatListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSSearchFieldDelegate {
    enum Item {
        case pinned([Chat])
        case archived(count: Int, unread: Int)
        case back
        case chat(Chat)
        case header(String)
        case hit(Store.SearchHit)

        var key: String {
            switch self {
            case .pinned: "~pinned"
            case .archived: "~archived"
            case .back: "~back"
            case .chat(let c): c.jid
            case .header(let t): "~h:" + t
            case .hit(let h): "~m:\(h.chat)/\(h.id)"
            }
        }
    }

    let store: Store
    weak var delegate: ChatListDelegate?

    private(set) var items: [Item] = []
    private var all: [Chat] = []
    private var showingArchived = false
    private var filter = 0
    private var query = "" {
        didSet {
            guard query.isEmpty else { return }
            hits = []
            searchedQuery = ""
            pendingSearch?.cancel()
            pendingSearch = nil
        }
    }
    /// Message results for `searchedQuery`. List reloads (every incoming message)
    /// reuse them; the full-text search only reruns when the query changes.
    private var hits: [Store.SearchHit] = []
    private var searchedQuery = ""
    private var pendingSearch: DispatchWorkItem?
    private(set) var selectedJID: String?
    /// The picked message search result, so reloads keep it selected.
    private var selectedHit: String?
    private var typing: [String: Date] = [:]
    private var suppressSelection = false
    private var lastReload = Date.distantPast
    private var reloadScheduled = false

    private let search = NSSearchField()
    private let filters = GlassSegmentedControl(labels: ["All", "Unread", "Groups"])
    private let status = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    let tableView = NSTableView()
    private let pinnedGrid = PinnedGridView()

    init(store: Store) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = NSView()
        view = v

        search.placeholderString = "Search"
        search.controlSize = .large
        search.font = .systemFont(ofSize: 14)
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged)
        search.translatesAutoresizingMaskIntoConstraints = false

        filters.onChange = { [weak self] i in
            guard let self else { return }
            self.filter = i
            // Unread opens with nothing selected: the chat you were reading has
            // no unread messages, so it doesn't belong in that list.
            if i == 1 { self.select(jid: nil) }
            self.rebuildItems(animated: false)
        }

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        status.translatesAutoresizingMaskIntoConstraints = false

        pinnedGrid.onSelect = { [weak self] c in self?.select(jid: c.jid) }
        pinnedGrid.onMenu = { c in
            let m = NSMenu()
            ChatListViewController.actions(for: c).forEach(m.addItem)
            return m
        }

        let col = NSTableColumn(identifier: .init("c"))
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowSizeStyle = .custom
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.backgroundColor = .clear
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.focusRingType = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(clicked)
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
        tableView.setAccessibilityLabel("Conversations")

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        [search, filters, status, scrollView].forEach(v.addSubview)
        let statusHeight = status.heightAnchor.constraint(equalToConstant: 0)
        statusHeight.identifier = "statusHeight"
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: v.safeAreaLayoutGuide.topAnchor, constant: 6),
            search.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            filters.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            filters.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            filters.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            status.topAnchor.constraint(equalTo: filters.bottomAnchor, constant: 4),
            status.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            statusHeight,
            scrollView.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
    }

    // MARK: data

    /// Coalesces bursts (history sync emits many) into at most ~8 reloads/sec.
    func setNeedsReload() {
        let since = Date().timeIntervalSince(lastReload)
        if since > 0.12 { reload(animated: true); return }
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (0.12 - since)) { [weak self] in
            self?.reloadScheduled = false
            self?.reload(animated: true)
        }
    }

    func reload(animated: Bool = false) {
        lastReload = Date()
        all = store.chats(archived: showingArchived)
        rebuildItems(animated: animated)
    }

    private func rebuildItems(animated: Bool) {
        var list = all
        if filter == 1 { list = list.filter { $0.hasUnread || $0.jid == selectedJID } }
        if filter == 2 { list = list.filter(\.isGroup) }
        if !query.isEmpty {
            list = list.filter { $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil || $0.jid.contains(query) }
        }
        var out: [Item] = []
        let plain = query.isEmpty && filter == 0
        if showingArchived {
            out.append(.back)
        } else if plain {
            let pinned = list.filter(\.pinned)
            if !pinned.isEmpty {
                out.append(.pinned(pinned))
                list = list.filter { !$0.pinned }
            }
            let a = store.archivedSummary()
            if a.count > 0 { out.append(.archived(count: a.count, unread: a.unread)) }
        }
        if query.isEmpty {
            out += list.map { .chat($0) }
        } else {
            // Search: matching conversations, then matching messages across every chat.
            // Message hits stay from the last search until the next one lands, so
            // they don't blink out on every keystroke.
            if !list.isEmpty { out.append(.header("Conversations")); out += list.map { .chat($0) } }
            if !hits.isEmpty { out.append(.header("Messages")); out += hits.map { .hit($0) } }
        }
        applyItems(out, animated: animated)
    }

    /// Reorders with real row moves so a chat visibly travels to the top.
    private func applyItems(_ newItems: [Item], animated: Bool) {
        let oldKeys = items.map(\.key), newKeys = newItems.map(\.key)
        let oldSet = Set(oldKeys), newSet = Set(newKeys)
        let churn = oldSet.symmetricDifference(newSet).count
        suppressSelection = true
        defer { suppressSelection = false }
        if !animated || oldKeys.isEmpty || churn > 6 || Theme.reduceMotion || oldKeys == newKeys {
            let structural = oldKeys != newKeys
            items = newItems
            if structural || !animated {
                tableView.reloadData()
            } else {
                refreshVisible()
            }
            restoreSelection()
            return
        }
        items = newItems
        var current = oldKeys
        tableView.beginUpdates()
        let removeIdx = IndexSet(current.indices.filter { !newSet.contains(current[$0]) })
        if !removeIdx.isEmpty {
            tableView.removeRows(at: removeIdx, withAnimation: .effectFade)
            for i in removeIdx.reversed() { current.remove(at: i) }
        }
        for (i, k) in newKeys.enumerated() where !oldSet.contains(k) {
            let pos = min(i, current.count)
            tableView.insertRows(at: IndexSet(integer: pos), withAnimation: .effectFade)
            current.insert(k, at: pos)
        }
        for i in 0..<newKeys.count where current[i] != newKeys[i] {
            guard let j = current.firstIndex(of: newKeys[i]) else { continue }
            tableView.moveRow(at: j, to: i)
            current.insert(current.remove(at: j), at: i)
        }
        tableView.endUpdates()
        refreshVisible()
        restoreSelection()
    }

    private func refreshVisible() {
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.length > 0 else { return }
        var heights = IndexSet()
        for i in range.location..<min(items.count, range.location + range.length) {
            switch (items[i], tableView.view(atColumn: 0, row: i, makeIfNecessary: false)) {
            case (.chat(let c), let cell as ChatCellView):
                cell.configure(c, typing: isTyping(c.jid))
            case (.pinned(let chats), _):
                pinnedGrid.configure(chats, selected: selectedJID)
                heights.insert(i)
            case (.archived(let n, let u), let cell as ListLinkCellView):
                fillArchived(cell, n, u)
            case (.hit(let h), let cell as ChatCellView):
                if let c = chat(h.chat) ?? store.chat(h.chat) { cell.configure(hit: h, in: c) }
            default: break
            }
        }
        if !heights.isEmpty { tableView.noteHeightOfRows(withIndexesChanged: heights) }
    }

    private func restoreSelection() {
        if let key = selectedHit, let i = items.firstIndex(where: { $0.key == key }) {
            tableView.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        } else if let jid = selectedJID, let i = index(of: jid) {
            tableView.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        pinnedGrid.setSelected(selectedJID)
    }

    func chat(_ jid: String) -> Chat? { all.first { $0.jid == jid } }

    private func index(of jid: String) -> Int? {
        items.firstIndex { if case .chat(let c) = $0 { return c.jid == jid }; return false }
    }

    private var orderedJIDs: [String] {
        items.flatMap { item -> [String] in
            switch item {
            case .pinned(let cs): return cs.prefix(9).map(\.jid)
            case .chat(let c): return [c.jid]
            default: return []
            }
        }
    }

    func select(jid: String?) {
        selectedJID = jid
        selectedHit = nil
        if let jid, !orderedJIDs.contains(jid) {
            // Archived or filtered out: switch to a view that contains it.
            if let c = store.chat(jid), c.archived != showingArchived { showingArchived = c.archived }
            query = ""
            search.stringValue = ""
            filter = 0
            filters.select(0, animated: false)
            reload()
        }
        suppressSelection = true
        restoreSelection()
        if let jid, let i = index(of: jid) { tableView.scrollRowToVisible(i) }
        suppressSelection = false
        delegate?.chatList(didSelect: jid.flatMap { chat($0) ?? store.chat($0) })
    }

    func selectRelative(_ delta: Int) {
        let jids = orderedJIDs
        guard !jids.isEmpty else { return }
        let cur = selectedJID.flatMap { jids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : jids.count)
        select(jid: jids[min(max(0, cur + delta), jids.count - 1)])
    }

    func selectNth(_ n: Int) {
        let jids = orderedJIDs
        guard n < jids.count else { return }
        select(jid: jids[n])
    }

    func focusSearch() { view.window?.makeFirstResponder(search) }
    func focusList() { view.window?.makeFirstResponder(tableView) }
    func setSearch(_ q: String) {
        search.stringValue = q
        searchChanged()
    }
    /// Dev hook: picks a filter segment (0 All, 1 Unread, 2 Groups), as a click would.
    func pickFilter(_ i: Int) {
        filters.select(i, animated: false)
        filters.onChange?(i)
    }
    /// Dev hook: picks the first message result, as a click would.
    func pickFirstHit() {
        guard let i = items.firstIndex(where: { if case .hit = $0 { return true }; return false }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
    }

    func setTyping(chat: String, on: Bool) {
        typing[chat] = on ? Date().addingTimeInterval(25) : nil
        guard let i = index(of: chat), case .chat(let c) = items[i],
              let cell = tableView.view(atColumn: 0, row: i, makeIfNecessary: false) as? ChatCellView else { return }
        cell.configure(c, typing: isTyping(chat))
    }

    private func isTyping(_ jid: String) -> Bool { (typing[jid] ?? .distantPast) > Date() }

    func setStatus(_ text: String?) {
        status.stringValue = text ?? ""
        let h = status.constraints.first { $0.identifier == "statusHeight" }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.reduceMotion ? 0 : 0.2
            ctx.timingFunction = Theme.easeOut
            ctx.allowsImplicitAnimation = true
            h?.constant = text == nil ? 0 : 16
            view.layoutSubtreeIfNeeded()
        }
    }

    // MARK: actions

    @objc private func searchChanged() {
        query = search.stringValue.trimmingCharacters(in: .whitespaces)
        if query.isEmpty { selectedHit = nil }
        rebuildItems(animated: false)
        scheduleMessageSearch()
    }

    /// Conversations filter as you type; the message search waits for a 150ms
    /// pause, so a burst of keystrokes costs one query instead of one each.
    private func scheduleMessageSearch() {
        pendingSearch?.cancel()
        pendingSearch = nil
        guard !query.isEmpty, query != searchedQuery else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.runMessageSearch() }
        }
        pendingSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func runMessageSearch() {
        pendingSearch = nil
        guard !query.isEmpty else { return }
        searchedQuery = query
        hits = store.searchMessages(query)
        rebuildItems(animated: false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        // Return in search opens the top result; Down moves into the list.
        if sel == #selector(NSResponder.insertNewline(_:)) || sel == #selector(NSResponder.moveDown(_:)) {
            if let first = orderedJIDs.first {
                select(jid: first)
                if sel == #selector(NSResponder.moveDown(_:)) { view.window?.makeFirstResponder(tableView) }
            }
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            search.stringValue = ""
            searchChanged()
            return true
        }
        return false
    }

    @objc private func clicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        switch items[row] {
        case .archived: showArchive(true)
        case .back: showArchive(false)
        default: break
        }
    }

    func showArchive(_ on: Bool) {
        showingArchived = on
        reload()
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch items[row] {
        case .chat, .hit: 80
        case .pinned(let cs): PinnedGridView.height(for: cs.count)
        case .header: 30
        default: 44
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let r = SidebarRowView()
        switch items[row] {
        case .chat, .hit: r.showsSeparator = true
        default: break
        }
        return r
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch items[row] {
        case .chat(let c):
            let id = NSUserInterfaceItemIdentifier("chat")
            let v = tableView.makeView(withIdentifier: id, owner: nil) as? ChatCellView ?? ChatCellView()
            v.identifier = id
            v.configure(c, typing: isTyping(c.jid))
            return v
        case .pinned(let chats):
            pinnedGrid.configure(chats, selected: selectedJID)
            return pinnedGrid
        case .archived(let n, let unread):
            let v = linkCell()
            fillArchived(v, n, unread)
            return v
        case .back:
            let v = linkCell()
            v.icon.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: nil)
            v.label.stringValue = "Archived"
            v.count.stringValue = ""
            return v
        case .header(let title):
            let id = NSUserInterfaceItemIdentifier("header")
            let v = tableView.makeView(withIdentifier: id, owner: nil) as? SectionHeaderView ?? SectionHeaderView()
            v.identifier = id
            v.label.stringValue = title
            return v
        case .hit(let h):
            let id = NSUserInterfaceItemIdentifier("chat")
            let v = tableView.makeView(withIdentifier: id, owner: nil) as? ChatCellView ?? ChatCellView()
            v.identifier = id
            if let c = chat(h.chat) ?? store.chat(h.chat) { v.configure(hit: h, in: c) }
            return v
        }
    }

    private func fillArchived(_ v: ListLinkCellView, _ n: Int, _ unread: Int) {
        v.icon.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil)
        v.label.stringValue = "Archived"
        v.count.stringValue = unread > 0 ? "\(unread) unread" : "\(n)"
    }

    private func linkCell() -> ListLinkCellView {
        let id = NSUserInterfaceItemIdentifier("link")
        let v = tableView.makeView(withIdentifier: id, owner: nil) as? ListLinkCellView ?? ListLinkCellView()
        v.identifier = id
        return v
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch items[row] {
        case .chat, .hit: return true
        default: return false
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < items.count else { return }
        switch items[row] {
        case .chat(let c) where c.jid != selectedJID || selectedHit != nil:
            selectedJID = c.jid
            selectedHit = nil
            pinnedGrid.setSelected(c.jid)
            delegate?.chatList(didSelect: c)
        case .hit(let h):
            guard let c = chat(h.chat) ?? store.chat(h.chat) else { return }
            selectedJID = c.jid
            selectedHit = items[row].key
            pinnedGrid.setSelected(c.jid)
            delegate?.chatList(didSelectMessage: h.id, in: c)
        default:
            break
        }
    }

    // MARK: context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard row >= 0, row < items.count, case .chat(let c) = items[row] else { return }
        for i in Self.actions(for: c) { menu.addItem(i) }
    }

    static func actions(for c: Chat) -> [NSMenuItem] {
        var out: [NSMenuItem] = []
        let jid = c.jid
        out.append(ClosureMenuItem(title: c.hasUnread ? "Mark as Read" : "Mark as Unread") {
            Core.shared.call(c.hasUnread ? "mark_read" : "mark_unread", ["chat": jid])
        })
        out.append(ClosureMenuItem(title: c.pinned ? "Unpin" : "Pin") {
            Core.shared.call("pin", ["chat": jid, "on": !c.pinned])
        })
        if c.isMuted {
            out.append(ClosureMenuItem(title: "Unmute") { Core.shared.call("mute", ["chat": jid, "on": false]) })
        } else {
            let mute = NSMenuItem(title: "Mute", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (t, h) in [("For 8 Hours", 8), ("For 1 Week", 168), ("Always", 0)] {
                sub.addItem(ClosureMenuItem(title: t) { Core.shared.call("mute", ["chat": jid, "on": true, "hours": h]) })
            }
            mute.submenu = sub
            out.append(mute)
        }
        out.append(.separator())
        out.append(ClosureMenuItem(title: c.archived ? "Unarchive" : "Archive") {
            Core.shared.call("archive", ["chat": jid, "on": !c.archived])
        })
        return out
    }
}
