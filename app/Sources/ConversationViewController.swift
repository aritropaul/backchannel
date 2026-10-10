import AppKit
import Quartz

/// Root view of the conversation: paints the canvas edge to edge (including
/// under the floating sidebar) and takes dropped files, any number of them.
final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?
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

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL])?
            .filter { !$0.hasDirectoryPath } ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        !fileURLs(sender).isEmpty && onDrop != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}

final class ConversationViewController: NSViewController, QLPreviewPanelDataSource, QLPreviewPanelDelegate {

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

    enum Scroll: Equatable { case bottom, bottomAnimated, anchor, unread, message(String), none }

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

    var msgs: [Message] = []
    var rows: [Row] = [.spacer]
    var layouts: [String: MessageLayout] = [:]
    var contentHeight: CGFloat = 0
    var unreadAnchorID: String?
    var unreadCount = 0
    var expanded: Set<String> = []
    var hasMoreLocal = true
    var askedPhone = false
    var reloading = false
    var replyTo: Message?
    var editing: Message?
    /// Files in the composer's tray, in sending order; the selected one's caption is in the field.
    var attachments: [Attachment] = []
    var selectedAttachment = 0
    /// The photo viewer, while it's open.
    var viewer: MediaViewer?
    var inlineVideo: InlineVideo?
    var waveformTried: Set<String> = []
    var thumbRequested: Set<String> = []
    var posterQueue: [(chat: String, id: String)] = []
    var postersInFlight = 0
    var drafts: [String: String] = [:]
    var lastTypingSent = Date.distantPast
    var typingStop: DispatchWorkItem?
    var typing: [String: (name: String, until: Date)] = [:]
    private var presence: (online: Bool, lastSeen: Date?)?
    var pendingOpen: String?
    /// Attachments to copy into Downloads once they finish downloading.
    var pendingSave: Set<String> = []
    var previewURL: URL?
    /// The message Quick Look is showing, so it can zoom out of (and back into) its bubble.
    var previewSource: String?
    var highlighted: String?
    /// Reactions of mine still flying from the menu to their message (message id → emoji).
    var landing: [String: String] = [:]
    /// Where an animated scroll is heading, while it runs.
    var scrollTarget: CGFloat?
    var jumpVisible = false
    /// The transcript is scrolling or coasting (a touch then belongs to the scroll view).
    private(set) var isScrolling = false

    let scrollView = NSScrollView()
    let tableView = NSTableView()
    let composer = ComposerView()
    /// The @-mention list above the composer, in groups.
    let mentionPicker = MentionPicker()
    /// The card a tapped mention opens.
    var contactSheet: ContactSheet?
    /// The open group's members, for mentions; loaded when "@" is first typed.
    var mentionPeople: [MentionCandidate]?
    let jumpButton = NSButton()
    private let emptyLabel = NSTextField(labelWithString: "")

    static let pageSize = 80

    init(store: Store) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: view

    override func loadView() {
        let root = DropView()
        root.onDrop = { [weak self] urls in self?.attachMany(urls, asDocuments: false) }
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
        mentionPicker.onPick = { [weak self] p in
            self?.composer.insertMention(jid: p.jid, name: p.name)
            self?.mentionPicker.hide()
        }
        [scrollView, topBlur, emptyLabel, composer, jumpButton, capsule, mentionPicker].forEach(view.addSubview)
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
            mentionPicker.leadingAnchor.constraint(equalTo: composer.fieldView.leadingAnchor),
            mentionPicker.trailingAnchor.constraint(lessThanOrEqualTo: composer.fieldView.trailingAnchor),
            mentionPicker.bottomAnchor.constraint(equalTo: composer.fieldView.topAnchor, constant: -8),
        ])

        AudioPlayback.shared.onTick = { [weak self] id in self?.redraw(id: id) }
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(frameChanged),
                                               name: NSView.frameDidChangeNotification, object: scrollView)
        scrollView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scrollView,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isScrolling = true }
        }
        NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scrollView,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isScrolling = false }
        }
    }

    var insets: NSEdgeInsets { scrollView.contentInsets }
    var clip: NSClipView { scrollView.contentView }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateInsets()
    }

    func updateInsets() {
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

    var tableWidth: CGFloat { max(320, scrollView.contentSize.width) }

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
        expanded = []
        layouts = [:]
        composer.hideReply(animated: false)
        clearAttachments(animated: false)
        mentionPicker.hide()
        mentionPeople = nil
        contactSheet?.removeFromSuperview()
        contactSheet = nil
        MentionDirectory.shared.set(c?.isGroup == true ? store.mentionNames(c!.jid) : [])
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
            if pendingSave.contains(m.id), !m.mediaPath.isEmpty {
                pendingSave.remove(m.id)
                Downloads.save(m)
            }

            if m.id == pendingOpen, !m.mediaPath.isEmpty {
                pendingOpen = nil
                DispatchQueue.main.async { [weak self] in
                    if m.kind == .voice || m.kind == .audio { AudioPlayback.shared.toggle(m) } else { self?.open(media: m) }
                }
            }
            if !m.fromMe && appended.contains(m.id) {
                typing[m.sender] = nil
                // The core doesn't announce what lands in the open chat; transcribe it here.
                if m.kind == .voice { Transcripts.shared.arrived(chat: jid, id: m.id) }
            }
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
        // Auto-downloads fail quietly (the thumbnail stays); only explain user-initiated opens and saves.
        guard pendingOpen == id || pendingSave.contains(id) else { return }
        // The server dropped it and the phone was asked to upload it again: keep waiting.
        if status == "retrying" { return }
        if pendingOpen == id { pendingOpen = nil }
        pendingSave.remove(id)
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
            previewSource = nil
        }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewURL == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { previewURL as NSURL? }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        MainActor.assumeIsolated { previewSourceView().map { $0.window?.convertToScreen($0.convert($1, to: nil)) ?? .zero } ?? .zero }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: (any QLPreviewItem)!,
                                  contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        MainActor.assumeIsolated { UncheckedBox(value: previewSource.flatMap { layouts[$0]?.documentImage }) }.value
    }

    /// The bubble Quick Look zooms from, and the document's frame in it.
    private func previewSourceView() -> (NSView, NSRect)? {
        guard let id = previewSource, let row = rowIndex(of: id), let l = layouts[id], let frame = l.documentFrame,
              let v = tableView.view(atColumn: 0, row: row, makeIfNecessary: false), !v.visibleRect.isEmpty else { return nil }
        return (v, frame)
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
