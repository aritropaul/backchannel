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

/// The chat list's scroll view, without responsive scrolling. That tracks a trackpad
/// gesture off the main event path, so the window's scroll monitor saw only its first
/// event and never the lift that reveals Archived (`trackPull`).
private final class ChatListScrollView: NSScrollView {
    override class var isCompatibleWithResponsiveScrolling: Bool { false }
}

final class ChatListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSSearchFieldDelegate {
    enum Item {
        case pinned([Chat])
        case archived(count: Int, unread: Int)
        /// Locked chats (Touch ID to open), revealed by the same pull as Archived.
        case locked(count: Int)
        case back(String)
        case chat(Chat)
        case header(String)
        case hit(Store.SearchHit)
        /// The short rule between pinned chats and the rest in the compact column.
        case divider

        var key: String {
            switch self {
            case .pinned: "~pinned"
            case .archived: "~archived"
            case .locked: "~locked"
            case .back: "~back"
            case .divider: "~divider"
            case .chat(let c): c.jid
            case .header(let t): "~h:" + t
            case .hit(let h): "~m:\(h.chat)/\(h.id)"
            }
        }
    }

    let store: Store
    weak var delegate: ChatListDelegate?

    /// The sidebar never closes. Dragged narrower than `fullMinWidth` it snaps to
    /// `compactWidth`, Messages' column of avatars (see `MainSplitViewController`).
    static let compactWidth: CGFloat = 94
    static let fullMinWidth: CGFloat = 280
    /// Below this width the list draws as the compact column.
    private static let compactBelow: CGFloat = (compactWidth + fullMinWidth) / 2
    /// How far the fingers have to travel down past the top before letting go shows Archived.
    private static let pullTravel: CGFloat = 240
    private(set) var compact = false
    /// Archived stays out of the list until a deliberate pull down past its top.
    private var archiveRevealed = false
    private var pullArmed = false
    /// Finger travel past the top in the current gesture; nil when it didn't start at the top.
    private var pullDistance: CGFloat?
    private var fullTop: NSLayoutConstraint!
    private var compactTop: NSLayoutConstraint!
    private var scrollMonitor: Any?

    private(set) var items: [Item] = []
    private var all: [Chat] = []
    private var showingArchived = false
    /// Inside "Locked chats", after Touch ID. Leaving it locks them again.
    private var showingLocked = false
    /// Search limited to one chat (the contact panel's Search button).
    private var scope: Chat?
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
    private let scrollView: NSScrollView = ChatListScrollView()
    let tableView = NSTableView()
    private let pinnedGrid = PinnedGridView()
    /// The pull's progress ring, in the gap the rubber band opens above the list.
    private let pullIndicator = PullIndicator()
    /// Something is archived or locked, so a pull has something to show (read once per gesture).
    private var pullHasHidden = false
    /// Rows the next list change slides in instead of fading (Archived, from a pull).
    private var slideIn: Set<String> = []

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
        status.lineBreakMode = .byTruncatingTail
        status.translatesAutoresizingMaskIntoConstraints = false
        // The header must never widen the sidebar. At the default 750, the status line
        // ("Connecting…", "Loading your chats…") and the search field out-pull the split
        // view's hold on the divider (about 250), so they shoved the sidebar past the compact
        // column and the window grew to make room, a few points every launch and more on
        // longer notes. Below that hold they truncate instead.
        for v in [search, filters, status] as [NSView] {
            v.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        }

        pinnedGrid.onSelect = { [weak self] c in self?.select(jid: c.jid) }
        pinnedGrid.onMenu = { c in
            let m = NSMenu()
            ChatListViewController.actions(for: c).forEach(m.addItem)
            return m
        }

        let col = NSTableColumn(identifier: .init("c"))
        // Start narrow: the column only grows to fit, so AppKit's default 100pt would keep
        // the table wider than the 94pt compact column when the app opens compact.
        col.width = 40
        col.minWidth = 20
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
        scrollView.verticalScrollElasticity = .allowed   // a short list still has to pull
        scrollView.wantsLayer = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        [search, filters, status, scrollView, pullIndicator].forEach(v.addSubview)
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
            scrollView.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        fullTop = scrollView.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 4)
        // Messages starts the avatar column right under the traffic lights.
        compactTop = scrollView.topAnchor.constraint(equalTo: v.safeAreaLayoutGuide.topAnchor, constant: -10)
        fullTop.isActive = true

        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            self?.trackPull(e)
            return e
        }
        // Locking or unlocking a chat moves it in or out of the list.
        NotificationCenter.default.addObserver(forName: Prefs.changed, object: nil, queue: .main) { [weak self] n in
            let key = n.object as? String
            MainActor.assumeIsolated {
                if key == "WA.lockedChats" { self?.reload() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scrollView,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideArchiveIfScrolledAway() }
        }
        // The ring rides the rubber band, including its spring back after the fingers lift.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePullIndicator() }
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let narrow = view.bounds.width < Self.compactBelow
        if narrow != compact { setCompact(narrow) }
        updatePullIndicator()
    }

    /// How far the list is pulled down past its top.
    private var pullStretch: CGFloat {
        max(0, -(scrollView.contentView.bounds.minY + scrollView.contentInsets.top))
    }

    private func updatePullIndicator() {
        let stretch = pullStretch
        let shown = pullHasHidden && !archiveRevealed && !showingArchived && !showingLocked && isPlain && stretch > 0
        let side = PullIndicator.side
        // Centred in the gap, which grows from the list's top edge.
        let top = scrollView.frame.maxY - scrollView.contentInsets.top
        pullIndicator.frame = NSRect(x: scrollView.frame.midX - side / 2, y: top - stretch / 2 - side / 2, width: side, height: side)
        pullIndicator.update(stretch: shown ? stretch : 0, progress: (pullDistance ?? lastPull) / Self.pullTravel, armed: pullArmed)
    }

    /// The last gesture's travel, so the ring doesn't empty while the list springs back.
    private var lastPull: CGFloat = 0

    /// Messages' compact sidebar: no search or filter, pinned chats first as plain
    /// avatars, a short rule, then everything else.
    private func setCompact(_ on: Bool) {
        compact = on
        for v in [search, filters, status] as [NSView] { v.isHidden = on }
        fullTop.isActive = !on
        compactTop.isActive = on
        if on, let editor = search.currentEditor(), view.window?.firstResponder === editor {
            view.window?.makeFirstResponder(tableView)
        }
        Motion.crossfade(scrollView.layer)
        rebuildItems(animated: false)
        if let jid = selectedJID, let i = index(of: jid) { tableView.scrollRowToVisible(i) }
    }

    // MARK: pull for Archived

    /// Pulling down past the top with fingers still on the trackpad arms the reveal, with a
    /// haptic tick; letting go shows Archived, and pushing back before that disarms it. The
    /// pull is the fingers' travel, not how far the list stretches: the rubber band stiffens
    /// so fast that one deliberate pull stretches it only 15–40pt. Only a gesture that
    /// starts at the top counts and momentum never does, so scrolling or flinging up to the
    /// top doesn't open it by accident.
    private func trackPull(_ e: NSEvent, synthetic: Bool = false) {
        guard synthetic || (e.window === view.window && scrollView.bounds.contains(scrollView.convert(e.locationInWindow, from: nil))),
              !archiveRevealed, !showingArchived, !showingLocked, isPlain else {
            pullArmed = false
            pullDistance = nil
            return
        }
        let atTop = scrollView.contentView.bounds.minY <= -scrollView.contentInsets.top + 1
        switch e.phase {
        case .began:
            pullArmed = false
            pullDistance = atTop ? 0 : nil
            lastPull = 0
            if atTop { pullHasHidden = store.archivedSummary().count > 0 || !ChatPrefs.locked.isEmpty }
        case .changed:
            guard let d = pullDistance else { return }
            let travel = atTop ? max(0, d + e.scrollingDeltaY) : 0
            pullDistance = travel
            lastPull = travel
            if pullArmed, travel < Self.pullTravel / 2 {
                pullArmed = false
            } else if !pullArmed, travel >= Self.pullTravel, pullHasHidden {
                pullArmed = true
                Haptic.arm()
            }
            updatePullIndicator()
        case .ended:
            pullDistance = nil
            guard pullArmed else { updatePullIndicator(); return }
            pullArmed = false
            revealArchive()
        case .cancelled:
            pullArmed = false
            pullDistance = nil
            updatePullIndicator()
        default:
            break
        }
    }

    // MARK: dev (WA_MOMENTS)

    /// A deliberate pull from the top, through the same path as the trackpad's.
    func debugPull() {
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
        scrollView.reflectScrolledClipView(clip)
        let r = view.window.map { $0.convertToScreen(scrollView.convert(scrollView.bounds, to: nil)) } ?? .zero
        var steps: [DevMoments.Step] = [(.began, 0, 6)]
        steps += Array(repeating: (.changed, 0, 7), count: 40)
        steps += Array(repeating: (.changed, 0, 0), count: 20)
        steps.append((.ended, 0, 0))
        DevMoments.play(steps, at: CGPoint(x: r.midX, y: r.maxY - 60), into: { [weak self] e in
            self?.trackPull(e, synthetic: true)
            self?.scrollView.scrollWheel(with: e)
        })
    }

    /// A visible read chat shows an unread dot for two seconds (the view only).
    func debugDot() {
        let range = tableView.rows(in: tableView.visibleRect)
        for i in range.location..<min(items.count, range.location + range.length) {
            guard case .chat(let c) = items[i], !c.hasUnread,
                  let cell = tableView.view(atColumn: 0, row: i, makeIfNecessary: false) as? ChatCellView else { continue }
            let unread = Chat(jid: c.jid, name: c.name, isGroup: c.isGroup, lastTS: c.lastTS, unread: 1, markedUnread: false,
                              pinned: c.pinned, archived: c.archived, mutedUntil: c.mutedUntil, avatar: c.avatar, last: c.last)
            cell.configure(unread, typing: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2 * Motion.slow) { cell.configure(c, typing: false) }
            return
        }
    }

    /// Shows the Archived row at the top of the list (also the dev hook `WA_PULL`).
    func revealArchive() {
        guard !archiveRevealed else { return }
        archiveRevealed = true
        updatePullIndicator()
        // Archived drops in from under the header, where the pull came from.
        slideIn = ["~archived", "~locked"]
        rebuildItems(animated: true)
        slideIn = []
    }

    /// Once Archived has scrolled out of sight and the scroll settles, it hides again
    /// without moving anything that's on screen.
    private func hideArchiveIfScrolledAway() {
        let revealed = items.indices.filter { i in
            switch items[i] { case .archived, .locked: true; default: false }
        }
        guard archiveRevealed, !showingArchived, !showingLocked, let last = revealed.last else { return }
        let rows = tableView.rect(ofRow: revealed[0]).union(tableView.rect(ofRow: last))
        let clip = scrollView.contentView
        guard clip.bounds.minY >= rows.maxY else { return }
        let y = clip.bounds.minY - rows.height
        archiveRevealed = false
        rebuildItems(animated: false)
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    /// No search and no filter: the list Archived belongs to.
    private var isPlain: Bool { compact || (query.isEmpty && filter == 0) }

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
        let locked = ChatPrefs.locked
        if showingLocked {
            all = (store.chats(archived: false) + store.chats(archived: true)).filter { locked.contains($0.jid) }
        } else {
            all = store.chats(archived: showingArchived).filter { !locked.contains($0.jid) }
        }
        rebuildItems(animated: animated)
    }

    private func rebuildItems(animated: Bool) {
        // The compact column has no search field or filter to show, so it lists everything;
        // both come back as they were when the sidebar widens again.
        let q = compact ? "" : query
        let f = compact ? 0 : filter
        var list = all
        if f == 1 { list = list.filter { $0.hasUnread || $0.jid == selectedJID } }
        if f == 2 { list = list.filter(\.isGroup) }
        if !q.isEmpty {
            list = list.filter { $0.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil || $0.jid.contains(q) }
        }
        var out: [Item] = []
        if showingLocked {
            out.append(.back("Locked chats"))
        } else if showingArchived {
            out.append(.back("Archived"))
        } else if q.isEmpty && f == 0 {
            if archiveRevealed {
                let a = store.archivedSummary()
                if a.count > 0 { out.append(.archived(count: a.count, unread: a.unread)) }
                let locked = ChatPrefs.locked.count
                if locked > 0 { out.append(.locked(count: locked)) }
            }
            let pinned = list.filter(\.pinned)
            if !pinned.isEmpty {
                list = list.filter { !$0.pinned }
                if compact {
                    out += pinned.map { .chat($0) }
                    if !list.isEmpty { out.append(.divider) }
                } else {
                    out.append(.pinned(pinned))
                }
            }
        }
        if q.isEmpty {
            out += list.map { .chat($0) }
        } else {
            // Search: matching conversations, then matching messages across every chat
            // (or only the scoped one). Message hits stay from the last search until the
            // next one lands, so they don't blink out on every keystroke. Locked chats
            // never show up outside "Locked chats".
            let locked = showingLocked ? [] : ChatPrefs.locked
            if scope == nil, !list.isEmpty { out.append(.header("Conversations")); out += list.map { .chat($0) } }
            let shown = hits.filter { !locked.contains($0.chat) }
            if !shown.isEmpty { out.append(.header(scope.map { "Messages in \($0.name)" } ?? "Messages")); out += shown.map { .hit($0) } }
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
            tableView.insertRows(at: IndexSet(integer: pos), withAnimation: slideIn.contains(k) ? [.slideDown, .effectFade] : .effectFade)
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
                cell.compact = compact
                cell.configure(c, typing: isTyping(c.jid))
            case (.pinned(let chats), _):
                pinnedGrid.configure(chats, selected: selectedJID)
                heights.insert(i)
            case (.archived(let n, let u), let cell as ListLinkCellView):
                fillArchived(cell, n, u)
                cell.style = compact ? .compact : .entry
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
        cell.compact = compact
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

    /// The contact panel's Search: the field searches only this chat's messages until
    /// it's cleared.
    func searchIn(_ c: Chat) {
        // Coming from the compact column: let the sidebar widen and show its field first.
        view.window?.layoutIfNeeded()
        scope = c
        searchedQuery = ""
        hits = []
        search.placeholderString = "Search \(c.name)"
        search.stringValue = ""
        query = ""
        focusSearch()
        rebuildItems(animated: false)
    }

    private func clearScope() {
        guard scope != nil else { return }
        scope = nil
        searchedQuery = ""
        search.placeholderString = "Search"
    }

    @objc private func searchChanged() {
        query = search.stringValue.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            selectedHit = nil
            clearScope()
        }
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
        hits = store.searchMessages(query, in: scope?.jid)
        rebuildItems(animated: false)
    }

    /// Leaving the field empty ends a chat-scoped search.
    func controlTextDidEndEditing(_ obj: Notification) {
        if search.stringValue.trimmingCharacters(in: .whitespaces).isEmpty { clearScope() }
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
        case .locked: openLocked()
        case .back: showingLocked ? closeLocked() : showArchive(false)
        default: break
        }
    }

    /// Touch ID (or the Mac's password), then the locked chats.
    func openLocked() {
        ChatPrefs.authenticate("open your locked chats") { [weak self] ok in
            guard ok, let self else { return }
            self.showingLocked = true
            self.reload()
            self.tableView.scrollRowToVisible(0)
        }
    }

    private func closeLocked() {
        showingLocked = false
        reload()
    }

    func showArchive(_ on: Bool) {
        showingArchived = on
        reload()
        tableView.scrollRowToVisible(0)
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch items[row] {
        case .chat, .hit: 80
        case .pinned(let cs): PinnedGridView.height(for: cs.count)
        case .header: 30
        case .divider: 10
        default: 44
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let r = SidebarRowView()
        switch items[row] {
        case .chat, .hit: r.showsSeparator = !compact
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
            v.compact = compact
            v.configure(c, typing: isTyping(c.jid))
            return v
        case .pinned(let chats):
            pinnedGrid.configure(chats, selected: selectedJID)
            return pinnedGrid
        case .archived(let n, let unread):
            let v = linkCell()
            fillArchived(v, n, unread)
            v.style = compact ? .compact : .entry
            return v
        case .locked(let n):
            let v = linkCell()
            v.icon.image = NSImage(systemSymbolName: "lock", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
            v.label.stringValue = "Locked chats"
            v.count.stringValue = "\(n)"
            v.highlightsCount = false
            v.toolTip = compact ? "Locked chats" : nil
            v.style = compact ? .compact : .entry
            return v
        case .back(let title):
            let v = linkCell()
            v.icon.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: "Back to Chats")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
            v.label.stringValue = title
            v.count.stringValue = ""
            v.toolTip = "Back to Chats"
            v.style = compact ? .compact : .header
            return v
        case .divider:
            let id = NSUserInterfaceItemIdentifier("divider")
            let v = tableView.makeView(withIdentifier: id, owner: nil) as? DividerCellView ?? DividerCellView()
            v.identifier = id
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
        v.icon.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        v.label.stringValue = "Archived"
        v.count.stringValue = unread > 0 ? "\(unread) unread" : "\(n)"
        v.highlightsCount = unread > 0
        v.toolTip = compact ? "Archived (\(n))" : nil
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
            if query.isEmpty { clearScope() }   // moved on without searching
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
