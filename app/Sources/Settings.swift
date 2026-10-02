import AppKit
import UserNotifications

/// The eight sections of WhatsApp's settings, as WhatsApp lists them.
enum SettingsSection: String, CaseIterable {
    case profile, account, privacy, agents, chats, notifications, shortcuts, help

    var title: String {
        switch self {
        case .profile: "Profile"
        case .account: "Account"
        case .privacy: "Privacy"
        case .agents: "Agents"
        case .chats: "Chats"
        case .notifications: "Notifications"
        case .shortcuts: "Keyboard shortcuts"
        case .help: "Help and feedback"
        }
    }

    var subtitle: String {
        switch self {
        case .profile: "Name, profile picture, username"
        case .account: "Security notifications, account info"
        case .privacy: "Blocked contacts, disappearing messages"
        case .agents: "Agents connected to this account"
        case .chats: "Theme, wallpaper, chat settings"
        case .notifications: "Messages, groups, sounds"
        case .shortcuts: "Quick actions"
        case .help: "Help center, contact us, privacy policy"
        }
    }

    var symbol: String {
        switch self {
        case .profile: "person.crop.circle"
        case .account: "key"
        case .privacy: "lock"
        case .agents: "sparkles"
        case .chats: "text.bubble"
        case .notifications: "bell"
        case .shortcuts: "keyboard"
        case .help: "questionmark.circle"
        }
    }

    /// Extra words search should find this section by.
    var keywords: String {
        switch self {
        case .profile: "about photo picture name username status"
        case .account: "security code phone number linked device log out account info"
        case .privacy: "last seen online profile photo about groups read receipts blocked block disappearing timer"
        case .agents: "ai bot agent"
        case .chats: "theme dark light appearance wallpaper accent color enter send spell check emoji media auto-download archive history"
        case .notifications: "sound preview banner reactions groups badge"
        case .shortcuts: "keyboard shortcut hotkey command"
        case .help: "help faq contact privacy policy terms licenses version"
        }
    }
}

/// Settings (⌘,): a System Settings-style window, profile card and sections on
/// the left, the selected section's grouped rows on the right.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let store: Store
    private let split = NSSplitViewController()
    private let sidebar: SettingsSidebarController
    private let detail: SettingsDetailController

    init(store: Store) {
        self.store = store
        sidebar = SettingsSidebarController(store: store)
        detail = SettingsDetailController(store: store)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 600),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.toolbarStyle = .unified
        w.minSize = NSSize(width: 680, height: 460)
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("WA.Settings")
        super.init(window: w)
        w.delegate = self
        let side = NSSplitViewItem(sidebarWithViewController: sidebar)
        side.minimumThickness = 320
        side.maximumThickness = 380
        side.canCollapse = false
        let main = NSSplitViewItem(viewController: detail)
        main.minimumThickness = 400
        main.automaticallyAdjustsSafeAreaInsets = true
        split.addSplitViewItem(side)
        split.addSplitViewItem(main)
        w.contentViewController = split
        // Assigning the split shrinks the window to its fitting size; set the real one after.
        w.setContentSize(NSSize(width: 860, height: 640))
        let tb = NSToolbar(identifier: "WA.settings")
        tb.displayMode = .iconOnly
        w.toolbar = tb
        sidebar.onSelect = { [weak self] s in self?.show(s) }
        show(.profile)
        if w.frame.origin == .zero { w.center() }
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ s: SettingsSection) {
        sidebar.select(s)
        detail.show(s)
        window?.title = s.title
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        sidebar.refreshProfile()
        detail.reload()
    }

    func windowDidBecomeKey(_ notification: Notification) { detail.refreshPermission() }

    static func postTestNotification() {
        let c = UNMutableNotificationContent()
        c.title = "WA"
        c.body = "Notifications are working."
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "wa-test", content: c, trigger: nil))
    }
}

// MARK: - Sidebar

final class SettingsSidebarController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let store: Store
    private let header = ProfileCardView()
    private let search = NSSearchField()
    private let table = NSTableView()
    private var sections = SettingsSection.allCases
    private var suppress = false
    var onSelect: ((SettingsSection) -> Void)?

    init(store: Store) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = NSView()
        view = v
        header.translatesAutoresizingMaskIntoConstraints = false
        header.onClick = { [weak self] in self?.onSelect?(.profile) }
        search.placeholderString = "Search"
        search.controlSize = .large
        search.delegate = self
        search.target = self
        search.action = #selector(filter)
        search.translatesAutoresizingMaskIntoConstraints = false

        table.addTableColumn(NSTableColumn(identifier: .init("s")))
        table.headerView = nil
        table.style = .sourceList
        table.rowSizeStyle = .custom
        table.rowHeight = 50
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        [header, search, scroll].forEach(v.addSubview)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: v.safeAreaLayoutGuide.topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            search.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        refreshProfile()
    }

    func refreshProfile() {
        let me = Core.shared.me
        header.set(name: store.name(me), phone: JID.phone(me), about: SettingsModel.shared.about,
                   jid: me, path: store.avatar(me))
        Task { [weak self] in
            await SettingsModel.shared.loadProfile()
            guard let self else { return }
            let p = SettingsModel.shared
            self.header.set(name: p.name.isEmpty ? self.store.name(me) : p.name, phone: JID.phone(me), about: p.about,
                            jid: me, path: p.picture.isEmpty ? self.store.avatar(me) : p.picture)
        }
    }

    func select(_ s: SettingsSection) {
        guard let i = sections.firstIndex(of: s) else { return }
        suppress = true
        table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        suppress = false
    }

    @objc private func filter() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        sections = q.isEmpty ? SettingsSection.allCases : SettingsSection.allCases.filter {
            "\($0.title) \($0.subtitle) \($0.keywords)".lowercased().contains(q)
        }
        table.reloadData()
        if let first = sections.first, !q.isEmpty { onSelect?(first) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { sections.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SidebarRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("section")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? SectionCellView ?? SectionCellView()
        cell.identifier = id
        cell.configure(sections[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppress, table.selectedRow >= 0, table.selectedRow < sections.count else { return }
        onSelect?(sections[table.selectedRow])
    }
}

/// Icon, title and one-line summary, like WhatsApp's settings list.
final class SectionCellView: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let sub = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        sub.font = .systemFont(ofSize: 11)
        sub.lineBreakMode = .byTruncatingTail
        [icon, title, sub].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ s: SettingsSection) {
        icon.image = NSImage(systemSymbolName: s.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
        title.stringValue = s.title
        sub.stringValue = s.subtitle
        setAccessibilityLabel("\(s.title), \(s.subtitle)")
        applyColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle { didSet { applyColors() } }

    private func applyColors() {
        let sel = backgroundStyle == .emphasized
        title.textColor = sel ? Theme.onSelection : .labelColor
        sub.textColor = sel ? Theme.onSelectionSecondary : .secondaryLabelColor
        icon.contentTintColor = sel ? Theme.onSelection : .secondaryLabelColor
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 12, y: (bounds.height - 22) / 2, width: 24, height: 22)
        title.frame = NSRect(x: 46, y: bounds.height / 2, width: bounds.width - 54, height: 17)
        sub.frame = NSRect(x: 46, y: bounds.height / 2 - 16, width: bounds.width - 54, height: 15)
    }
}

/// My photo with the About text in a speech bubble above it, and my name below,
/// as at the top of WhatsApp's settings.
final class ProfileCardView: NSView {
    private let bubble = AboutBubble()
    private let avatar = AvatarView(frame: NSRect(x: 0, y: 0, width: 76, height: 76))
    private let name = NSTextField(labelWithString: "")
    private let phone = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        name.alignment = .center
        name.lineBreakMode = .byTruncatingTail
        phone.font = .systemFont(ofSize: 11)
        phone.textColor = .secondaryLabelColor
        phone.alignment = .center
        [avatar, bubble, name, phone].forEach(addSubview)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    /// The About bubble takes 44pt above the photo only when there is an About.
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: bubble.isHidden ? 134 : 178) }

    func set(name n: String, phone p: String, about: String, jid: String, path: String) {
        name.stringValue = n
        phone.stringValue = p
        let about = about.trimmingCharacters(in: .whitespacesAndNewlines)
        bubble.text = about
        bubble.isHidden = about.isEmpty
        avatar.configure(jid: jid, name: n, isGroup: false, path: path, px: 152)
        setAccessibilityLabel("\(n), \(about). Edit profile")
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let bs = bubble.fittingSize(maxWidth: w - 24)
        let top: CGFloat = bubble.isHidden ? 0 : 44
        bubble.frame = NSRect(x: (w - bs.width) / 2, y: 0, width: bs.width, height: bs.height)
        avatar.frame = NSRect(x: (w - 76) / 2, y: top, width: 76, height: 76)
        name.frame = NSRect(x: 0, y: top + 84, width: w, height: 20)
        phone.frame = NSRect(x: 0, y: top + 106, width: w, height: 15)
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// A capsule with a small tail, holding the About line.
final class AboutBubble: NSView {
    var text = "" { didSet { needsDisplay = true } }
    private let font = NSFont.systemFont(ofSize: 12)

    func fittingSize(maxWidth: CGFloat) -> NSSize {
        let tw = (text as NSString).size(withAttributes: [.font: font]).width
        return NSSize(width: min(maxWidth, ceil(tw) + 28), height: 38)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let body = NSRect(x: 0.5, y: 0.5, width: bounds.width - 1, height: 28)
        let path = NSBezierPath(roundedRect: body, xRadius: 14, yRadius: 14)
        let tail = NSBezierPath(ovalIn: NSRect(x: bounds.width * 0.32, y: 30, width: 6, height: 6))
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        tail.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        tail.stroke()
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: body.insetBy(dx: 12, dy: 6),
                                withAttributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: p])
    }
}

// MARK: - Detail

final class SettingsDetailController: NSViewController {
    private let store: Store
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private(set) var section: SettingsSection = .profile

    init(store: Store) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = NSView()
        view = v
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 28, bottom: 32, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: v.safeAreaLayoutGuide.topAnchor),
            // The pane extends under the floating sidebar; keep the rows beside it.
            scroll.leadingAnchor.constraint(equalTo: v.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
    }

    func show(_ s: SettingsSection) {
        section = s
        reload()
        scroll.contentView.scroll(to: .zero)
    }

    func reload() {
        guard isViewLoaded else { _ = view; return reload() }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let panes = SettingsPanes(store: store) { [weak self] in self?.reload() }
        for v in panes.build(section) {
            stack.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -56).isActive = true
        }
    }

    /// The notification permission can change in System Settings while we're open.
    func refreshPermission() {
        if section == .notifications { reload() }
    }
}
