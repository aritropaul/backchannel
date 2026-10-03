import AppKit
import Quartz
import UniformTypeIdentifiers

/// Root view of the conversation: paints the canvas edge to edge (including
/// under the floating sidebar) and accepts dropped images.
final class DropView: NSView {
    var onDrop: ((URL) -> Void)?
    /// A chat theme's picture (gradient or photo), aspect-filled under everything.
    private let wallpaper = CALayer()
    /// Washes a photo toward the canvas so text and bubbles stay readable.
    private let wash = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        wallpaper.contentsGravity = .resizeAspectFill
        wallpaper.masksToBounds = true
        wallpaper.addSublayer(wash)
        layer?.insertSublayer(wallpaper, at: 0)
        NotificationCenter.default.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateWallpaper() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.canvas.setFill()
        dirtyRect.fill()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wallpaper.frame = bounds
        wash.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateWallpaper()
    }

    func updateWallpaper() {
        let t = ChatThemes.current
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let img = t.isPicture ? Wallpapers.image(for: t, dark: dark) : nil
        if img != nil, wallpaper.contents as! CGImage? !== img { Motion.crossfade(wallpaper, duration: 0.2) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wallpaper.contents = img
        wallpaper.isHidden = img == nil
        wash.backgroundColor = (dark ? NSColor.black : NSColor.white).cgColor
        wash.opacity = Float(Wallpapers.wash(t))
        CATransaction.commit()
        needsDisplay = true
    }

    private func fileURL(_ info: NSDraggingInfo) -> URL? {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL])?
            .first { !$0.hasDirectoryPath }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURL(sender) != nil && onDrop != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = fileURL(sender) else { return false }
        onDrop?(url)
        return true
    }
}

final class ConversationViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, ComposerDelegate,
    QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    enum Row {
        case spacer
        case separator(Date)
        case unread(Int)
        case message(MessageLayout)
        case typing

        var key: String {
            switch self {
            case .spacer: "~spacer"
            case .separator(let d): "~sep\(d.timeIntervalSince1970)"
            case .unread: "~unread"
            case .message(let l): l.msg.id
            case .typing: "~typing"
            }
        }

        var height: CGFloat {
            switch self {
            case .spacer: 0
            case .separator: 30
            case .unread: 34
            case .message(let l): l.height
            case .typing: 48
            }
        }
    }

    private enum Scroll: Equatable { case bottom, bottomAnimated, anchor, unread, message(String), none }

    let store: Store
    private(set) var chat: Chat?
    var onHeader: ((String, String) -> Void)?
    var onProfile: (() -> Void)?
    /// Opens another chat (from a contact card's Message button).
    var onOpenChat: ((String) -> Void)?
    /// The photo viewer opened (true) or closed.
    var onViewer: ((Bool) -> Void)?
    private let capsule = HeaderCapsule()
    private let topBlur = EdgeBlurView()
    private var compose: NewMessageViewController?
    var isComposing: Bool { compose != nil }

    private var msgs: [Message] = []
    private var rows: [Row] = [.spacer]
    private var layouts: [String: MessageLayout] = [:]
    private var contentHeight: CGFloat = 0
    private var unreadAnchorID: String?
    private var unreadCount = 0
    private var expanded: Set<String> = []
    private var hasMoreLocal = true
    private var askedPhone = false
    private var reloading = false
    var replyTo: Message?
    private var editing: Message?
    var pendingImage: (path: String, thumb: String, w: Int, h: Int)?
    var pendingFile: PendingFile?
    /// More files picked with the one in the composer; they follow it when it's sent.
    var queuedAttachments: [URL] = []
    var queueAsDocuments = false
    /// The photo viewer, while it's open.
    var viewer: MediaViewer?
    var inlineVideo: InlineVideo?
    var waveformTried: Set<String> = []
    var thumbRequested: Set<String> = []
    var posterQueue: [(chat: String, id: String)] = []
    var postersInFlight = 0
    private var drafts: [String: String] = [:]
    private var lastTypingSent = Date.distantPast
    private var typingStop: DispatchWorkItem?
    private var typing: [String: (name: String, until: Date)] = [:]
    private var presence: (online: Bool, lastSeen: Date?)?
    private var pendingOpen: String?
    private var previewURL: URL?
    private var highlighted: String?

    private let scrollView = NSScrollView()
    let tableView = NSTableView()
    let composer = ComposerView()
    private let jumpButton = NSButton()
    private let emptyLabel = NSTextField(labelWithString: "")

    private static let pageSize = 80

    init(store: Store) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: view

    override func loadView() {
        let root = DropView()
        root.onDrop = { [weak self] url in self?.attach(url) }
        view = root

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView.postsBoundsChangedNotifications = true

        let col = NSTableColumn(identifier: .init("c"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.style = .plain
        tableView.gridStyleMask = []
        tableView.focusRingType = .none
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.usesAutomaticRowHeights = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel("Messages")
        scrollView.documentView = tableView

        emptyLabel.stringValue = "Select a conversation"
        emptyLabel.font = .systemFont(ofSize: 15, weight: .medium)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        composer.delegate = self
        composer.isHidden = true

        jumpButton.bezelStyle = .glass
        jumpButton.borderShape = .circle
        jumpButton.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: "Jump to latest")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        jumpButton.imagePosition = .imageOnly
        jumpButton.controlSize = .large
        jumpButton.target = self
        jumpButton.action = #selector(jumpToLatest)
        jumpButton.translatesAutoresizingMaskIntoConstraints = false
        jumpButton.wantsLayer = true
        jumpButton.isHidden = true
        jumpButton.toolTip = "Jump to latest"

        capsule.onClick = { [weak self] in self?.onProfile?() }
        capsule.isHidden = true
        [scrollView, topBlur, emptyLabel, composer, jumpButton, capsule].forEach(view.addSubview)
        // The transcript lives in the safe area; the root view's canvas runs under the sidebar.
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            // Runs under the glass profile panel, like Messages, so the panel has something to blur.
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            composer.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            composer.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            composer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
            topBlur.leadingAnchor.constraint(equalTo: view.leadingAnchor),   // edge to edge: no seam by the sidebar
            topBlur.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBlur.topAnchor.constraint(equalTo: view.topAnchor),
            topBlur.bottomAnchor.constraint(equalTo: safe.topAnchor, constant: 44),
            // Tucked under the toolbar avatar, like Messages: the avatar overlaps its top edge.
            capsule.topAnchor.constraint(equalTo: safe.topAnchor, constant: -12),
            capsule.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            jumpButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -22),
            jumpButton.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -12),
        ])

        AudioPlayback.shared.onTick = { [weak self] id in self?.redraw(id: id) }
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(frameChanged),
                                               name: NSView.frameDidChangeNotification, object: scrollView)
        scrollView.postsFrameChangedNotifications = true
    }

    private var insets: NSEdgeInsets { scrollView.contentInsets }
    private var clip: NSClipView { scrollView.contentView }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateInsets()
    }

    private func updateInsets() {
        let top = view.safeAreaInsets.top + (capsule.isHidden ? 0 : 28)
        let bottom = composer.isHidden ? 12 : composer.frame.height + 14 + 10
        let old = scrollView.contentInsets
        guard abs(old.top - top) > 0.5 || abs(old.bottom - bottom) > 0.5 else { return }
        let atBottom = isAtBottom
        scrollView.contentInsets = NSEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottom - 10, right: 0)
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: 0))
        if atBottom { scrollToBottom(animated: false) }
    }

    private var tableWidth: CGFloat { max(320, scrollView.contentSize.width) }

    @objc private func frameChanged() {
        guard chat != nil else { return }
        if let any = layouts.values.first, abs(any.width - tableWidth) > 0.5 {
            rebuildAndReload(.anchor)
        } else {
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: 0))
        }
    }

    // MARK: open / load

    func open(_ c: Chat?) {
        stopInline()
        if c != nil { endCompose() }
        saveDraft()
        chat = c
        ChatThemes.activate(c?.jid)
        (view as? DropView)?.updateWallpaper()
        typing = [:]
        presence = nil
        replyTo = nil
        editing = nil
        pendingImage = nil
        pendingFile = nil
        expanded = []
        layouts = [:]
        composer.hideReply(animated: false)
        composer.hideAttachment(animated: false)
        guard let c else {
            msgs = []
            rows = [.spacer]
            tableView.reloadData()
            composer.isHidden = true
            emptyLabel.isHidden = false
            capsule.isHidden = true
            updateInsets()
            onHeader?("", "")
            return
        }
        emptyLabel.isHidden = true
        if composer.isHidden {
            // Unhiding doesn't trigger a layout pass; size the composer and inset now.
            composer.isHidden = false
            view.layoutSubtreeIfNeeded()
            updateInsets()
        }
        var page = store.messages(chat: c.jid, limit: Self.pageSize)
        unreadCount = c.unread
        unreadAnchorID = nil
        if c.unread > 0 {
            if page.filter({ !$0.fromMe }).count < c.unread && page.count == Self.pageSize {
                page = store.messages(chat: c.jid, limit: min(600, c.unread * 2 + 20))
            }
            var seen = 0
            for m in page.reversed() where !m.fromMe {
                seen += 1
                unreadAnchorID = m.id
                if seen == c.unread { break }
            }
        }
        msgs = page
        hasMoreLocal = page.count >= Self.pageSize
        askedPhone = false
        rebuildAndReload(unreadAnchorID != nil ? .unread : .bottom)
        composer.text = drafts[c.jid] ?? ""
        composer.focus()
        updateHeader()
        Core.shared.call("focus", ["chat": c.jid, "active": NSApp.isActive])
        if c.hasUnread { Core.shared.call("mark_read", ["chat": c.jid]) }
        if !c.isGroup { Core.shared.call("subscribe", ["chat": c.jid]) }
        // Ask the phone to resend history that predates stored link previews/waveforms (once per chat per session).
        Core.shared.call("backfill", ["chat": c.jid])
    }

    func chatUpdated(_ c: Chat) {
        guard c.jid == chat?.jid else { return }
        chat = c
        updateHeader()
    }

    private func saveDraft() {
        guard let jid = chat?.jid else { return }
        let t = composer.text
        drafts[jid] = t.isEmpty ? nil : t
    }

    // MARK: core events

    func messagesChanged(ids: [String]) {
        guard let jid = chat?.jid else { return }
        let wasBottom = isAtBottom
        var appended: Set<String> = []
        var mine = false
        for id in ids {
            guard let m = store.message(chat: jid, id: id) else {
                msgs.removeAll { $0.id == id }
                continue
            }
            if let i = msgs.firstIndex(where: { $0.id == id }) {
                msgs[i] = m
            } else if let last = msgs.last, (m.ts, m.rowid) < (last.ts, last.rowid) {
                guard let first = msgs.first, (m.ts, m.rowid) > (first.ts, first.rowid) else { continue }
                let i = msgs.firstIndex { ($0.ts, $0.rowid) > (m.ts, m.rowid) } ?? msgs.count
                msgs.insert(m, at: i)
            } else {
                msgs.append(m)
                appended.insert(m.id)
                if m.fromMe { mine = true }
            }
            if m.id == pendingOpen, !m.mediaPath.isEmpty {
                pendingOpen = nil
                DispatchQueue.main.async { [weak self] in
                    if m.kind == .voice || m.kind == .audio { AudioPlayback.shared.toggle(m) } else { self?.open(media: m) }
                }
            }
            if !m.fromMe && appended.contains(m.id) { typing[m.sender] = nil }
        }
        if mine {
            unreadAnchorID = nil
            unreadCount = 0
        }
        let follow = !appended.isEmpty && (wasBottom || mine)
        apply(buildRows(), animateIn: appended, scroll: follow ? .bottomAnimated : .anchor)
        updateHeader()
    }

    func reloadWindow() {
        guard let c = chat else { return }
        hasMoreLocal = true
        askedPhone = false
        if let first = msgs.first {
            let fresh = store.messages(chat: c.jid, since: first, limit: 5000)
            let older = store.messages(chat: c.jid, before: first, limit: Self.pageSize)
            msgs = fresh.isEmpty ? store.messages(chat: c.jid, limit: Self.pageSize) : fresh
            if clip.bounds.minY + insets.top < 800, !older.isEmpty {
                msgs.insert(contentsOf: older, at: 0)
            }
        } else {
            msgs = store.messages(chat: c.jid, limit: Self.pageSize)
        }
        rebuildAndReload(msgs.count <= Self.pageSize && isAtBottom ? .bottom : .anchor)
    }

    func typingChanged(sender: String, name: String, on: Bool) {
        typing[sender] = on ? (name, Date().addingTimeInterval(25)) : nil
        updateHeader()
        refreshTypingRow()
        if on {
            DispatchQueue.main.asyncAfter(deadline: .now() + 26) { [weak self] in
                self?.updateHeader()
                self?.refreshTypingRow()
            }
        }
    }

    private func refreshTypingRow() {
        let now = Date()
        typing = typing.filter { $0.value.until > now }
        let has = rows.last.map { if case .typing = $0 { return true }; return false } ?? false
        guard has != !typing.isEmpty else { return }
        apply(buildRows(), animateIn: [], scroll: isAtBottom ? .bottomAnimated : .anchor)
    }

    func presenceChanged(online: Bool, lastSeen: Date?) {
        presence = (online, lastSeen)
        updateHeader()
    }

    func mediaFailed(id: String, status: String) {
        // Auto-downloads fail quietly (the thumbnail stays); only explain user-initiated opens.
        guard pendingOpen == id else { return }
        // The server dropped it and the phone was asked to upload it again: keep waiting.
        if status == "retrying" { return }
        pendingOpen = nil
        NSSound.beep()
        if status == "expired", let window = view.window {
            let a = NSAlert()
            a.messageText = "This media is no longer available"
            a.informativeText = "WhatsApp's servers no longer have it, and your phone couldn't send it again. Ask the sender to send it again."
            a.beginSheetModal(for: window)
        }
    }

    private func updateHeader() {
        guard let c = chat else { return }
        let now = Date()
        typing = typing.filter { $0.value.until > now }
        var sub = ""
        if let t = typing.first {
            sub = c.isGroup ? "\(t.value.name) is typing…" : "typing…"
        } else if !c.isGroup, let p = presence {
            sub = p.online ? "online" : (p.lastSeen.map(Fmt.lastSeen) ?? "")
        }
        onHeader?(c.name, sub)
        capsule.set(name: c.name, subtitle: sub)
        capsule.isHidden = false
    }

    /// Clicks on the capsule's top edge land in the toolbar band; the window controller forwards them here.
    func capsuleTakesClick(at windowPoint: NSPoint) -> Bool {
        guard !capsule.isHidden, capsule.window != nil,
              capsule.bounds.contains(capsule.convert(windowPoint, from: nil)) else { return false }
        capsule.onClick?()
        return true
    }

    // MARK: compose (inline "To:")

    func startCompose(onPick: @escaping (String) -> Void) {
        endCompose()
        open(nil)
        let vc = NewMessageViewController(store: store) { [weak self] jid in
            self?.endCompose()
            onPick(jid)
        }
        vc.onCancel = { [weak self] in self?.endCompose() }
        addChild(vc)
        let v = vc.view
        v.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 30),
            v.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            v.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            v.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        compose = vc
        emptyLabel.isHidden = true
        capsule.set(name: "New Message", subtitle: "", chevron: false)
        capsule.isHidden = false
        onHeader?("New Message", "")
        Motion.fade(v.layer, duration: 0.15)
        DispatchQueue.main.async { vc.focusField() }
    }

    func endCompose() {
        guard let vc = compose else { return }
        vc.view.removeFromSuperview()
        vc.removeFromParent()
        compose = nil
        if chat == nil {
            capsule.isHidden = true
            emptyLabel.isHidden = false
        }
    }

    // MARK: rows

    private static func statusText(_ m: Message) -> String? {
        switch m.status {
        case MessageStatus.pending: return "Sending…"
        case MessageStatus.sent: return "Sent"
        case MessageStatus.delivered: return "Delivered"
        case MessageStatus.read: return "Read"
        case MessageStatus.played: return m.kind == .voice ? "Played" : "Read"
        default: return nil
        }
    }

    private func buildRows() -> [Row] {
        guard let c = chat else { return [.spacer] }
        let width = tableWidth
        var out: [Row] = [.spacer]
        var next: [String: MessageLayout] = [:]
        var total: CGFloat = 0
        let lastOutgoing = msgs.last { $0.fromMe && $0.kind != .revoked }?.id

        // A run breaks on a separator, a sender change, a 5-minute gap, the unread
        // divider, or around stickers/emoji-only messages.
        func separatorBefore(_ i: Int) -> Bool {
            guard i > 0 else { return true }
            let p = msgs[i - 1], m = msgs[i]
            return !Fmt.sameDay(p.date, m.date) || m.ts - p.ts > 45 * 60 * 1000
        }
        func breakBefore(_ i: Int) -> Bool {
            guard i > 0 else { return true }
            let p = msgs[i - 1], m = msgs[i]
            if separatorBefore(i) || m.id == unreadAnchorID { return true }
            return p.fromMe != m.fromMe || p.sender != m.sender || m.ts - p.ts > 5 * 60 * 1000
                || p.kind == .sticker || m.kind == .sticker
        }

        for (i, m) in msgs.enumerated() {
            if separatorBefore(i) {
                out.append(.separator(m.date))
                total += 30
            }
            if m.id == unreadAnchorID && unreadCount > 0 {
                out.append(.unread(unreadCount))
                total += 34
            }
            var flags = MessageLayout.Flags()
            flags.firstInRun = breakBefore(i)
            flags.lastInRun = i == msgs.count - 1 || breakBefore(i + 1)
            flags.showSender = c.isGroup && !m.fromMe && flags.firstInRun
            flags.gutter = c.isGroup && !m.fromMe
            flags.showAvatar = flags.gutter && flags.lastInRun
            flags.status = m.id == lastOutgoing ? Self.statusText(m) : nil
            flags.expanded = expanded.contains(m.id)
            let l: MessageLayout
            if let old = layouts[m.id], old.msg == m, abs(old.width - width) < 0.5, old.flags == flags {
                l = old
            } else {
                l = MessageLayout(msg: m, width: width, flags: flags)
            }
            next[m.id] = l
            out.append(.message(l))
            total += l.height
        }
        if !typing.isEmpty {
            out.append(.typing)
            total += 48
        }
        layouts = next
        contentHeight = total + 8
        return out
    }

    private func rebuildAndReload(_ scroll: Scroll) {
        reloading = true
        defer { reloading = false }
        let anchor = captureAnchor()
        rows = buildRows()
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()
        restore(scroll, anchor: anchor)
    }

    /// Applies new rows with the smallest table change: in-place updates
    /// crossfade, inserts animate in, removals fade. Large or prepended changes
    /// fall back to a plain reload so paging never animates.
    private func apply(_ newRows: [Row], animateIn: Set<String>, scroll: Scroll) {
        let oldKeys = rows.map(\.key), newKeys = newRows.map(\.key)
        let diff = newKeys.difference(from: oldKeys)
        let prepended = diff.insertions.contains { if case .insert(let o, _, _) = $0 { return o == 1 && !oldKeys.isEmpty }; return false }
            && oldKeys.count > 1
        if diff.count > 40 || prepended {
            rows = newRows
            reloading = true
            let anchor = captureAnchor()
            tableView.reloadData()
            tableView.layoutSubtreeIfNeeded()
            restore(scroll == .bottomAnimated ? .bottom : scroll, anchor: anchor)
            reloading = false
            return
        }
        reloading = true
        defer { reloading = false }
        let anchor = captureAnchor()
        var removed = IndexSet(), inserted = IndexSet()
        for change in diff {
            switch change {
            case .remove(let o, _, _): removed.insert(o)
            case .insert(let o, _, _): inserted.insert(o)
            }
        }
        let oldRows = rows
        rows = newRows
        if !removed.isEmpty || !inserted.isEmpty {
            tableView.beginUpdates()
            if !removed.isEmpty { tableView.removeRows(at: removed, withAnimation: .effectFade) }
            if !inserted.isEmpty { tableView.insertRows(at: inserted, withAnimation: []) }
            tableView.endUpdates()
        }
        // In-place: same key, different layout object → rebind the live view.
        var heightChanged = IndexSet(integer: 0)
        var oldByKey: [String: Row] = [:]
        for r in oldRows { oldByKey[r.key] = r }
        for (i, r) in newRows.enumerated() where !inserted.contains(i) {
            guard case .message(let l) = r, case .message(let old)? = oldByKey[r.key], old !== l else { continue }
            if abs(old.height - l.height) > 0.1 { heightChanged.insert(i) }
            if let v = tableView.view(atColumn: 0, row: i, makeIfNecessary: false) as? BubbleView { v.item = l }
        }
        tableView.noteHeightOfRows(withIndexesChanged: heightChanged)
        tableView.layoutSubtreeIfNeeded()

        for i in inserted {
            guard i < rows.count else { continue }
            switch rows[i] {
            case .message(let l) where animateIn.contains(l.msg.id):
                if let v = tableView.view(atColumn: 0, row: i, makeIfNecessary: false) { animateEntrance(v, sent: l.msg.fromMe) }
            case .typing:
                (tableView.view(atColumn: 0, row: i, makeIfNecessary: false) as? TypingBubbleView)?.animateIn()
            default:
                if let v = tableView.view(atColumn: 0, row: i, makeIfNecessary: false) { Motion.fade(v.layer, duration: 0.2) }
            }
        }
        restore(scroll, anchor: anchor)
    }

    /// Sent bubbles rise out of the composer; received ones slide up into place.
    private func animateEntrance(_ v: NSView, sent: Bool) {
        v.wantsLayer = true
        guard let layer = v.layer else { return }
        if Theme.reduceMotion {
            Motion.fade(layer)
            return
        }
        let down: CGFloat = (v.superview?.isFlipped ?? true) ? 1 : -1
        let t = Theme.spring("transform", response: sent ? 0.32 : 0.3, damping: sent ? 0.86 : 1)
        t.fromValue = CATransform3DMakeTranslation(0, down * (sent ? 28 : 10), 0)
        t.toValue = CATransform3DIdentity
        layer.add(t, forKey: "enter")
        Motion.fade(layer, from: sent ? 0.4 : 0, duration: 0.2)
    }

    private func restore(_ scroll: Scroll, anchor: (id: String, offset: CGFloat)?) {
        switch scroll {
        case .none:
            break
        case .bottom:
            scrollToBottom(animated: false)
        case .bottomAnimated:
            scrollToBottom(animated: !Theme.reduceMotion)
        case .anchor:
            if let a = anchor, let row = rowIndex(of: a.id) {
                scrollTo(y: tableView.rect(ofRow: row).minY - a.offset)
            } else {
                scrollToBottom(animated: false)
            }
        case .unread:
            if let row = rows.firstIndex(where: { if case .unread = $0 { return true }; return false }) {
                scrollTo(y: tableView.rect(ofRow: row).minY - 24 - insets.top)
            } else {
                scrollToBottom(animated: false)
            }
        case .message(let id):
            if let row = rowIndex(of: id) {
                let r = tableView.rect(ofRow: row)
                scrollTo(y: r.midY - (clip.bounds.height + insets.top - insets.bottom) / 2 - insets.top / 2, animated: true)
            }
        }
        updateJump()
    }

    func rowIndex(of id: String) -> Int? {
        rows.firstIndex { if case .message(let l) = $0 { return l.msg.id == id }; return false }
    }

    private func captureAnchor() -> (id: String, offset: CGFloat)? {
        guard !rows.isEmpty, tableView.numberOfRows == rows.count else { return nil }
        let visible = clip.bounds
        let top = visible.minY + insets.top
        let range = tableView.rows(in: visible)
        guard range.length > 0 else { return nil }
        for i in range.location..<min(rows.count, range.location + range.length) {
            guard case .message(let l) = rows[i] else { continue }
            let r = tableView.rect(ofRow: i)
            if r.maxY > top { return (l.msg.id, r.minY - visible.minY) }
        }
        return nil
    }

    /// Bottom-anchored if we're there, or an animated scroll is already taking us there.
    private var isAtBottom: Bool {
        let maxY = tableView.frame.height + insets.bottom - 40
        if let t = scrollTarget, t + clip.bounds.height >= maxY { return true }
        return clip.bounds.maxY >= maxY
    }

    private var scrollTarget: CGFloat?

    private func scrollTo(y: CGFloat, animated: Bool = false) {
        let maxY = max(-insets.top, tableView.frame.height - clip.bounds.height + insets.bottom)
        let target = NSPoint(x: 0, y: min(max(-insets.top, y), maxY))
        if animated && abs(target.y - clip.bounds.minY) < clip.bounds.height * 2.5 {
            scrollTarget = target.y
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.32
                ctx.timingFunction = Theme.easeOut
                clip.animator().setBoundsOrigin(target)
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.scrollTarget == target.y else { return }
                    self.scrollTarget = nil
                    // Content may have grown during the animation: settle at the true bottom.
                    if target.y >= self.tableView.frame.height - self.clip.bounds.height + self.insets.bottom - 40 {
                        self.scrollToBottom(animated: false)
                    }
                }
            })
        } else {
            scrollTarget = nil
            clip.scroll(to: target)
        }
        scrollView.reflectScrolledClipView(clip)
    }

    private func scrollToBottom(animated: Bool) {
        scrollTo(y: .greatestFiniteMagnitude, animated: animated)
    }

    @objc private func jumpToLatest() {
        if msgs.count > Self.pageSize * 3, let c = chat {
            msgs = store.messages(chat: c.jid, limit: Self.pageSize)
            hasMoreLocal = true
            rebuildAndReload(.bottom)
            return
        }
        scrollToBottom(animated: !Theme.reduceMotion)
    }

    @objc private func boundsChanged() {
        updateJump()
        guard !reloading, chat != nil else { return }
        if clip.bounds.minY + insets.top < 900 { loadOlder() }
    }

    private func loadOlder() {
        guard let c = chat, let first = msgs.first else { return }
        if hasMoreLocal {
            let older = store.messages(chat: c.jid, before: first, limit: Self.pageSize)
            if older.count < Self.pageSize { hasMoreLocal = false }
            if !older.isEmpty {
                msgs.insert(contentsOf: older, at: 0)
                rebuildAndReload(.anchor)
                return
            }
        }
        if !askedPhone {
            askedPhone = true
            Core.shared.call("older", ["chat": c.jid])
        }
    }

    private var jumpVisible = false

    private func updateJump() {
        let far = tableView.frame.height + insets.bottom - clip.bounds.maxY > 600
        guard far != jumpVisible, chat != nil else { return }
        jumpVisible = far
        guard let layer = jumpButton.layer else { jumpButton.isHidden = !far; return }
        if far {
            jumpButton.isHidden = false
            Motion.pop(layer, size: jumpButton.bounds.size, from: 0.85, response: 0.25, damping: 0.85)
        } else {
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.jumpVisible else { return }
                    self.jumpButton.isHidden = true
                    self.jumpButton.layer?.opacity = 1
                }
            }
            let o = CABasicAnimation(keyPath: "opacity")
            o.fromValue = 1
            o.toValue = 0
            o.duration = 0.12
            o.timingFunction = Theme.easeOut
            layer.opacity = 0
            layer.add(o, forKey: "fadeOut")
            CATransaction.commit()
        }
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return 1 }
        if case .spacer = rows[row] {
            let visible = clip.bounds.height - insets.top - insets.bottom
            return max(1, visible - contentHeight)
        }
        return rows[row].height
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("row")
        let v = tableView.makeView(withIdentifier: id, owner: nil) as? PlainRowView ?? PlainRowView()
        v.identifier = id
        return v
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .spacer:
            return nil
        case .separator(let d):
            let id = NSUserInterfaceItemIdentifier("sep")
            let v = tableView.makeView(withIdentifier: id, owner: nil) as? SeparatorView ?? SeparatorView()
            v.identifier = id
            v.date = d
            return v
        case .unread(let n):
            let id = NSUserInterfaceItemIdentifier("unread")
            let v = tableView.makeView(withIdentifier: id, owner: nil) as? UnreadBarView ?? UnreadBarView()
            v.identifier = id
            v.count = n
            return v
        case .typing:
            let id = NSUserInterfaceItemIdentifier("typing")
            let v = tableView.makeView(withIdentifier: id, owner: nil) as? TypingBubbleView ?? TypingBubbleView()
            v.identifier = id
            return v
        case .message(let l):
            let id = NSUserInterfaceItemIdentifier("msg")
            let v = tableView.makeView(withIdentifier: id, owner: nil) as? BubbleView ?? BubbleView()
            v.identifier = id
            v.controller = self
            v.item = l
            if v.playerView != nil, inlineVideo?.id != l.msg.id { stopInline() }   // its cell was reused
            v.highlight = l.msg.id == highlighted
            if l.wantsAutoDownload { Core.shared.call("download", ["chat": chat?.jid ?? "", "id": l.msg.id]) }
            fillWaveformIfNeeded(l.msg)
            requestThumbIfNeeded(l.msg)
            return v
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    // MARK: message actions

    func reply(to m: Message) {
        guard m.kind != .revoked, m.kind != .pending else { return }
        editing = nil
        replyTo = m
        let name = m.fromMe ? "You" : m.senderName
        composer.showReply(name: name, text: Fmt.preview(kind: m.kind, text: m.text, fileName: m.fileName),
                           color: Theme.accent)
        composer.focus()
    }

    func toggleVoice(_ m: Message) {
        if m.mediaPath.isEmpty {
            pendingOpen = m.id
            Core.shared.call("download", ["chat": chat?.jid ?? "", "id": m.id, "retry": true])
            return
        }
        AudioPlayback.shared.toggle(m)
    }

    /// Redraws one message's bubble in place (voice progress ticks, avatar arrivals).
    func redraw(id: String) {
        guard let row = rowIndex(of: id),
              let v = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? BubbleView else { return }
        v.needsDisplay = true
    }

    /// Group sender pictures arrive asynchronously; repaint what's on screen.
    func refreshAvatars() {
        guard chat?.isGroup == true else { return }
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.length > 0 else { return }
        for i in range.location..<min(rows.count, range.location + range.length) {
            (tableView.view(atColumn: 0, row: i, makeIfNecessary: false) as? BubbleView)?.needsDisplay = true
        }
    }

    func expand(_ m: Message) {
        expanded.insert(m.id)
        apply(buildRows(), animateIn: [], scroll: .anchor)
    }

    func retry(_ m: Message) {
        Core.shared.call("retry", ["chat": chat?.jid ?? "", "id": m.id])
    }

    func jump(to id: String) {
        guard let c = chat, !id.isEmpty else { return }
        if rowIndex(of: id) == nil {
            guard let target = store.message(chat: c.jid, id: id) else { NSSound.beep(); return }
            msgs = store.messages(chat: c.jid, since: target, limit: 5000)
            hasMoreLocal = true
        }
        highlighted = id
        rebuildAndReload(.none)
        restore(.message(id), anchor: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.highlighted == id else { return }
            self.highlighted = nil
            if let row = self.rowIndex(of: id), let v = self.tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? BubbleView {
                v.highlight = false
            }
        }
    }

    /// Dev hook: plays the newest downloaded video in the open chat.
    func playLatestVideo() {
        guard let c = chat, let id = store.latestID(chat: c.jid, kind: .video), let m = store.message(chat: c.jid, id: id) else {
            NSLog("WA video: none in chat"); return
        }
        jump(to: id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.open(media: m) }
    }

    func open(media m: Message) {
        if m.kind == .voice || m.kind == .audio {
            toggleVoice(m)
            return
        }
        if m.kind == .location, let l = layouts[m.id]?.mapsURL {
            NSWorkspace.shared.open(l)
            return
        }
        guard m.hasMedia || !m.mediaPath.isEmpty else { return }
        if m.kind == .image {
            showViewer(m)   // shows the thumbnail and fetches the photo if it isn't here yet
            return
        }
        if m.kind == .sticker {
            if !m.mediaPath.isEmpty, FileManager.default.fileExists(atPath: m.mediaPath) {
                openStickerCard(m)
            } else {
                // Not here yet: fetch it (from the phone if the server dropped it), then open.
                pendingOpen = m.id
                Core.shared.call("download", ["chat": chat?.jid ?? "", "id": m.id, "retry": true])
            }
            return
        }
        if !m.mediaPath.isEmpty, FileManager.default.fileExists(atPath: m.mediaPath) {
            let url = URL(fileURLWithPath: m.mediaPath)
            if m.kind == .video {
                playInline(m, url: url)
            } else if m.kind == .image {
                showViewer(m)
            } else if m.kind == .sticker {
                return   // a sticker is part of the conversation, not a photo to open
            } else {
                NSWorkspace.shared.open(url)
            }
            return
        }
        pendingOpen = m.id
        Core.shared.call("download", ["chat": chat?.jid ?? "", "id": m.id, "retry": true])
    }

    /// A sticker's card, anchored on its bubble.
    func openStickerCard(_ m: Message) {
        guard let row = rowIndex(of: m.id),
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? BubbleView,
              let r = cell.item?.mediaRect else { return }
        showStickerCard(m, from: cell, at: r)
    }

    /// The message menu, laid out like Messages': reactions on top, then what you can do
    /// with the message, then what you can do to it, then deleting.
    func menu(for m: Message) -> NSMenu {
        let menu = NSMenu()
        var group: [NSMenuItem] = []
        func item(_ title: String, _ symbol: String?, _ action: @escaping @MainActor () -> Void) {
            let i = ClosureMenuItem(title: title, action: action)
            if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            group.append(i)
        }
        func endGroup() {
            guard !group.isEmpty else { return }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            group.forEach(menu.addItem)
            group = []
        }
        let live = m.kind != .revoked && m.kind != .pending

        if live {
            let mine = m.reactions?.mine
            let strip = ReactionStripView(recent: EmojiCatalog.recent, mine: mine?.isEmpty == false ? mine : nil,
                                          onPick: { [weak self] e in
                                              EmojiCatalog.used(e)
                                              self?.react(m, e == mine ? "" : e)
                                          },
                                          onMore: { [weak self] in self?.pickReaction(for: m) })
            let header = NSMenuItem()
            header.view = strip
            menu.addItem(header)
        }

        if live { item("Reply…", "arrowshape.turn.up.left") { [weak self] in self?.reply(to: m) } }
        if m.fromMe && live && m.kind == .text && Date().timeIntervalSince(m.date) < 15 * 60 {
            item("Edit…", "pencil") { [weak self] in self?.beginEdit(m) }
        }
        if live {
            item(m.starred ? "Unstar" : "Star", m.starred ? "star.slash" : "star") { [weak self] in
                guard let chat = self?.chat?.jid else { return }
                Task { _ = await Core.shared.callAsync("star", ["chat": chat, "id": m.id, "on": !m.starred]) }
            }
        }
        if m.fromMe && m.status == MessageStatus.failed {
            item("Try Again", "arrow.clockwise") { [weak self] in self?.retry(m) }
        }
        endGroup()

        if !m.text.isEmpty && live {
            item("Copy", "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(m.text, forType: .string)
            }
        }
        if m.hasMedia || !m.mediaPath.isEmpty {
            item(m.mediaPath.isEmpty ? "Download" : "Open", m.mediaPath.isEmpty ? "arrow.down.circle" : "eye") { [weak self] in self?.open(media: m) }
            if !m.mediaPath.isEmpty {
                item("Show in Finder", "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: m.mediaPath)]) }
            }
        }
        if m.kind == .sticker, !m.mediaPath.isEmpty {
            let sticker = StickerItem(path: m.mediaPath, mime: m.mime, width: m.width, height: m.height)
            let fav = StickerLibrary.hash(of: m.mediaPath).map { store.isFavoriteSticker(hash: $0) } ?? false
            item(fav ? "Remove from Favorites" : "Add to Favorites", fav ? "star.slash" : "star") {
                ConversationViewController.setFavorite(sticker, !fav)
            }
        }
        endGroup()

        if m.fromMe && live && Date().timeIntervalSince(m.date) < 2 * 24 * 3600 {
            item("Delete for Everyone…", "trash") { [weak self] in self?.confirmRevoke(m) }
        }
        endGroup()
        return menu
    }

    /// The menu's smiley: any emoji as the reaction, from a picker on the message.
    private func pickReaction(for m: Message) {
        guard let row = rowIndex(of: m.id),
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? BubbleView,
              let item = cell.item, let anchor = item.bubble ?? item.mediaRect ?? item.cardRect else { return }
        let picker = ReactionPickerViewController()
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = picker
        pop.contentSize = ReactionPickerViewController.size
        picker.onPick = { [weak self, weak pop] e in
            EmojiCatalog.used(e)
            self?.react(m, e)
            pop?.performClose(nil)
        }
        pop.show(relativeTo: anchor, of: cell, preferredEdge: .maxY)
    }

    private func react(_ m: Message, _ emoji: String) {
        Core.shared.call("react", ["chat": chat?.jid ?? "", "id": m.id, "emoji": emoji])
    }

    private func beginEdit(_ m: Message) {
        replyTo = nil
        editing = m
        composer.showReply(name: "Edit message", text: m.text, color: Theme.accent)
        composer.text = m.text
        composer.focus()
    }

    private func confirmRevoke(_ m: Message) {
        guard let window = view.window else { return }
        let a = NSAlert()
        a.messageText = "Delete this message for everyone?"
        a.informativeText = "It will be replaced with “This message was deleted” for everyone in the chat."
        a.addButton(withTitle: "Delete for Everyone")
        a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        a.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                _ = Core.shared.call("revoke", ["chat": self?.chat?.jid ?? "", "id": m.id])
            }
        }
    }

    // MARK: composer

    func composerSend(_ text: String) {
        guard let c = chat else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let e = editing {
            if !trimmed.isEmpty && trimmed != e.text {
                Core.shared.call("edit", ["chat": c.jid, "id": e.id, "text": trimmed])
            }
            editing = nil
            composer.hideReply(animated: true)
            composer.text = ""
            return
        }
        var res: [String: Any]
        var textAfter = ""
        if let f = pendingFile, f.isAudio {
            // Audio has no caption; any text goes after it as its own message.
            res = Core.shared.call("send_audio", ["chat": c.jid, "path": f.path, "name": f.name, "mime": f.mime,
                                                  "seconds": f.seconds, "quote": replyTo?.id ?? ""])
            textAfter = trimmed
        } else if let f = pendingFile {
            res = Core.shared.call("send_file", ["chat": c.jid, "path": f.path, "name": f.name, "mime": f.mime, "text": trimmed,
                                                 "thumb": f.thumb ?? "", "width": f.width, "height": f.height,
                                                 "seconds": f.seconds, "quote": replyTo?.id ?? ""])
        } else if let img = pendingImage {
            res = Core.shared.call("send_image", ["chat": c.jid, "path": img.path, "thumb": img.thumb, "width": img.w, "height": img.h,
                                                  "mime": "image/jpeg", "text": trimmed, "quote": replyTo?.id ?? ""])
        } else {
            let text = Prefs.emojiReplace ? Emoticons.replace(text) : text
            var args: [String: Any] = ["chat": c.jid, "text": text, "quote": replyTo?.id ?? ""]
            if let p = composer.linkPreview, text.contains(p.url.absoluteString) || WAText.firstURL(text) == p.url {
                args["link_url"] = p.url.absoluteString
                args["link_title"] = p.title
                args["thumb"] = p.thumbPath ?? ""
            }
            res = Core.shared.call("send_text", args)
        }
        if let err = res["error"] as? String {
            NSSound.beep()
            NSLog("send failed: %@", err)
            return
        }
        if Prefs.outgoingSound { NSSound(named: "Pop")?.play() }
        if !textAfter.isEmpty { _ = Core.shared.call("send_text", ["chat": c.jid, "text": textAfter]) }
        sendQueuedAttachments()
        composer.text = ""
        drafts[c.jid] = nil
        replyTo = nil
        pendingImage = nil
        pendingFile = nil
        composer.hideReply(animated: true)
        composer.hideAttachment(animated: true)
        typingStop?.cancel()
        lastTypingSent = .distantPast
    }

    func composerSendVoice(_ r: VoiceRecorder.Result) {
        guard let c = chat else { return }
        let res = Core.shared.call("send_voice", ["chat": c.jid, "path": r.url.path, "seconds": r.seconds,
                                                  "waveform": Data(r.waveform).base64EncodedString(), "quote": replyTo?.id ?? ""])
        if res["error"] != nil { NSSound.beep() }
        replyTo = nil
        composer.hideReply(animated: true)
    }

    func composerDidChangeHeight() {
        view.layoutSubtreeIfNeeded()
        updateInsets()
    }

    func composerDidType() {
        guard let c = chat else { return }
        if Date().timeIntervalSince(lastTypingSent) > 8 {
            lastTypingSent = Date()
            Core.shared.call("typing", ["chat": c.jid, "on": true])
        }
        typingStop?.cancel()
        let jid = c.jid
        let stop = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                Core.shared.call("typing", ["chat": jid, "on": false])
                self?.lastTypingSent = .distantPast
            }
        }
        typingStop = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: stop)
    }

    func composerAttach(from anchor: NSView) {
        showAttachMenu(from: anchor)
    }

    func composerExpressions(from anchor: NSView) {
        showExpressions(from: anchor)
    }

    /// The composer's ☺ button (dev hook).
    var expressionAnchor: NSView { composer.expressionAnchor }

    func composerCancelReply() {
        if editing != nil { composer.text = "" }
        replyTo = nil
        editing = nil
        composer.hideReply(animated: true)
    }

    func composerCancelAttachment() {
        pendingImage = nil
        pendingFile = nil
        queuedAttachments = []
        composer.hideAttachment(animated: true)
    }

    func composerPasteImage(_ image: NSImage) -> Bool {
        guard chat != nil, let tiff = image.tiffRepresentation else { return false }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("paste-\(UUID().uuidString).tiff")
        guard (try? tiff.write(to: url)) != nil else { return false }
        prepareImage(url)
        return true
    }

    /// Re-encodes to JPEG (≤2560px) plus a small inline thumbnail, off the main thread.
    func prepareImage(_ url: URL) {
        guard chat != nil else { return }
        let jid = chat?.jid
        DispatchQueue.global(qos: .userInitiated).async {
            let out = ConversationViewController.encode(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let out, self.chat?.jid == jid else { NSSound.beep(); return }
                    self.pendingImage = (out.path, out.thumb, out.w, out.h)
                    if let img = NSImage(contentsOfFile: out.thumb) {
                        self.composer.showAttachment(img, label: "Photo · \(out.w)×\(out.h)\(self.queuedSuffix). Add a caption, then press Return.")
                    }
                    self.composer.focus()
                }
            }
        }
    }

    @concurrent nonisolated static func encodePhoto(_ url: URL) async -> (path: String, thumb: String, w: Int, h: Int)? {
        encode(url)
    }

    nonisolated private static func encode(_ url: URL) -> (path: String, thumb: String, w: Int, h: Int)? {
        guard let full = ImageCache.decode(url, px: 2560), let small = ImageCache.decode(url, px: 96) else { return nil }
        let dir = FileManager.default.temporaryDirectory
        let id = UUID().uuidString
        let path = dir.appendingPathComponent("\(id).jpg"), thumb = dir.appendingPathComponent("\(id)-thumb.jpg")
        func write(_ img: CGImage, _ to: URL, _ q: Double) -> Bool {
            guard let d = CGImageDestinationCreateWithURL(to as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
            CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
            return CGImageDestinationFinalize(d)
        }
        guard write(full, path, 0.85), write(small, thumb, 0.6) else { return nil }
        return (path.path, thumb.path, full.width, full.height)
    }

    // MARK: Quick Look

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { previewURL != nil }
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
            previewURL = nil
        }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewURL == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { previewURL as NSURL? }
    }
}

/// NSMenuItem that runs a closure.
nonisolated final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, action handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() {
        let h = handler
        MainActor.assumeIsolated { h() }
    }
}
