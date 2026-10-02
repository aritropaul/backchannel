import AppKit

/// Avatar that sits centered in the toolbar, like Messages' conversation header.
final class HeaderAvatarButton: NSView {
    static let size: CGFloat = 40
    let avatar = AvatarView(frame: NSRect(x: 0, y: 0, width: size, height: size))
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        addSubview(avatar)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Show profile")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.size, height: Self.size) }
    override func layout() {
        super.layout()
        avatar.frame = NSRect(x: (bounds.width - Self.size) / 2, y: (bounds.height - Self.size) / 2, width: Self.size, height: Self.size)
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick?() }
}

/// Glass capsule under the toolbar avatar: "Name ›" with presence beneath.
final class HeaderCapsule: NSView {
    private let glass = NSGlassEffectView()
    private let rim = GlassRim()
    private let frost = FrostView()
    private let name = NSTextField(labelWithString: "")
    private let sub = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        glass.cornerRadius = 15
        glass.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView = content
        // Messages' header name is a size up and bolder than a list name (measured against
        // the owner's Messages screenshot: ~14pt bold); 13pt semibold read as condensed.
        name.font = .systemFont(ofSize: 14, weight: .bold)
        name.lineBreakMode = .byTruncatingTail
        sub.font = .systemFont(ofSize: 10.5)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        chevron.contentTintColor = .tertiaryLabelColor
        let text = NSStackView(views: [name, sub])
        text.orientation = .vertical
        text.spacing = 0
        text.alignment = .centerX
        let row = NSStackView(views: [text, chevron])
        row.spacing = 4
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(row)
        rim.radius = 15
        frost.rounded(15)
        frost.translatesAutoresizingMaskIntoConstraints = false
        [frost, rim, glass].forEach(addSubview)
        updateFrost()
        NotificationCenter.default.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateFrost() }
        }
        NSLayoutConstraint.activate([
            frost.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            frost.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            frost.topAnchor.constraint(equalTo: glass.topAnchor),
            frost.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            rim.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            rim.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            rim.topAnchor.constraint(equalTo: glass.topAnchor),
            rim.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: content.topAnchor, constant: 5),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -5),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
            widthAnchor.constraint(lessThanOrEqualToConstant: 340),
        ])
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Over a wallpaper the pill is frosted glass; otherwise a near-solid backing, since
    /// text over moving messages needs a steady read.
    private func updateFrost() {
        let on = Theme.frostsOverWallpaper
        frost.isHidden = !on
        rim.fill = on ? .clear : NSColor.windowBackgroundColor.withAlphaComponent(0.86)
    }

    func set(name n: String, subtitle: String, chevron showChevron: Bool = true) {
        name.stringValue = n
        sub.stringValue = subtitle
        sub.isHidden = subtitle.isEmpty
        chevron.isHidden = !showChevron
        setAccessibilityLabel(subtitle.isEmpty ? "\(n), show profile" : "\(n), \(subtitle), show profile")
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick?() }
}

/// Right-hand glass inspector: Messages' layout (big photo and name, action circles)
/// carrying WhatsApp's contact info (media, starred, notifications, chat theme,
/// disappearing messages, lock, privacy, groups in common, and the actions at the
/// bottom). Deeper settings push pages inside the panel.
final class ProfileViewController: NSViewController {
    let store: Store
    private(set) var jid: String?
    var chat: Chat? { jid.flatMap { store.chat($0) } }
    /// Opens a chat scrolled to a message.
    var onJump: ((String, String) -> Void)?
    var onOpenChat: ((String) -> Void)?
    var onSearchInChat: ((Chat) -> Void)?
    /// Rebuilds the open Chat theme / Wallpaper pages when an Image Playground picture lands.
    var themePageBuild: (() -> Void)?
    var wallpaperPageBuild: (() -> Void)?
    /// Set while a dev hook pushes a page, so screenshots don't catch it mid-slide.
    var debugUnanimated = false

    private let root = NSView()
    private let panelFrost = FrostView()
    private var pages: [ProfilePage] = []
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let avatar = AvatarView(frame: NSRect(x: 0, y: 0, width: 96, height: 96))
    private let name = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let actions = NSStackView()
    private let infoCard = Card()
    private let mediaCard = Card()
    private let settingsCard = Card()
    private let privacyCard = Card()
    private let detailsCard = Card()
    private let toggleCard = Card()
    private let photosCard = Card()
    private let membersCard = Card()
    private let commonCaption = ProfilePage.note("", size: 13, weight: .semibold)
    private let commonCard = Card()
    private let moreCard = Card()
    private let dangerCard = Card()
    private var loadToken = UUID()
    var blocked: Bool?

    init(store: Store) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = NSView()
        view = v
        // Frosted more than the system glass: the transcript under the panel blurs away.
        panelFrost.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(panelFrost)
        root.translatesAutoresizingMaskIntoConstraints = false
        root.wantsLayer = true
        v.addSubview(root)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 24, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        avatar.translatesAutoresizingMaskIntoConstraints = false
        name.font = .systemFont(ofSize: 22, weight: .bold)
        name.alignment = .center
        name.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 12.5)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        actions.orientation = .horizontal
        actions.spacing = 10   // five 38pt circles fit the panel's 280pt minimum
        // Hug the circles: rebuilt after every click, a loose stack stretched to the
        // panel's width and laid them out from the left.
        actions.setHuggingPriority(.required, for: .horizontal)

        let cards = [infoCard, mediaCard, settingsCard, privacyCard, detailsCard, photosCard, toggleCard, membersCard,
                     commonCaption, commonCard, moreCard, dangerCard]
        ([avatar, name, subtitle, actions] + cards).forEach(stack.addArrangedSubview)
        stack.setCustomSpacing(10, after: avatar)
        stack.setCustomSpacing(2, after: name)
        stack.setCustomSpacing(16, after: subtitle)
        stack.setCustomSpacing(20, after: actions)
        stack.setCustomSpacing(6, after: commonCaption)

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // The close button is a toolbar item tracking this panel (see MainWindowController).
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            panelFrost.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            panelFrost.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            panelFrost.topAnchor.constraint(equalTo: v.topAnchor),
            panelFrost.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            root.topAnchor.constraint(equalTo: v.topAnchor),
            root.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 96),
            avatar.heightAnchor.constraint(equalToConstant: 96),
            name.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -28),
        ])
        for c in cards {
            c.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        commonCaption.alignment = .left
        commonCaption.textColor = .labelColor
    }

    func show(_ chatJID: String) {
        guard let c = store.chat(chatJID) else { return }
        if jid != chatJID { popToRoot(animated: false) }
        jid = chatJID
        let token = UUID()
        loadToken = token
        avatar.configure(jid: c.jid, name: c.name, isGroup: c.isGroup, path: c.avatar, px: 192)
        name.stringValue = c.name
        subtitle.stringValue = c.isGroup ? "Group" : JID.phone(c.jid)
        subtitle.isHidden = false
        buildActions(c)
        infoCard.setRows(c.isGroup ? [] : [Card.labeled("mobile", JID.phone(c.jid), selectable: true)])
        infoCard.isHidden = c.isGroup
        buildSections(c)
        buildToggles(c)
        buildPhotos(c.jid)
        membersCard.setRows([])
        membersCard.isHidden = true
        if blocked == nil || jid != chatJID { blocked = nil }
        scrollToTop()
        Task { [weak self] in
            let info = await Core.shared.callAsync("profile", ["chat": chatJID])
            guard let self, self.loadToken == token else { return }
            self.apply(info, chat: c)
            self.scrollToTop()
        }
        if !c.isGroup {
            Task { [weak self] in
                let list = await Core.shared.callAsync("blocklist", [:])
                guard let self, self.loadToken == token else { return }
                let people = list["blocked"] as? [[String: Any]] ?? []
                self.blocked = people.contains { ($0["jid"] as? String) == chatJID }
                if let fresh = self.chat { self.buildDanger(fresh) }
            }
        }
    }

    /// Rebuilds the cards after something in them changed (a toggle, a page).
    func refreshSections() {
        guard let c = chat else { return }
        buildActions(c)
        buildSections(c)
        buildToggles(c)
    }

    private func scrollToTop() {
        view.layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: -scroll.contentInsets.top))
        scroll.reflectScrolledClipView(clip)
    }

    private func apply(_ info: [String: Any], chat c: Chat) {
        if let n = info["name"] as? String, !n.isEmpty, c.isGroup { name.stringValue = n }
        if let pic = info["picture"] as? String, !pic.isEmpty {
            ImageCache.shared.load(pic, px: 192) { [weak self] img in
                guard let self, let img, self.jid == c.jid else { return }
                Motion.crossfade(self.avatar.layer, duration: 0.2)
                self.avatar.image = img
            }
        }
        var rows: [NSView] = []
        if !c.isGroup { rows.append(Card.labeled("mobile", JID.phone(c.jid), selectable: true)) }
        if let biz = info["business"] as? String, !biz.isEmpty { rows.append(Card.labeled("business", biz)) }
        // WhatsApp returns " " for someone without an About.
        if let about = (info["about"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !about.isEmpty {
            rows.append(Card.labeled("about", about))
        }
        if let topic = info["topic"] as? String, !topic.isEmpty { rows.append(Card.labeled("description", topic)) }
        if let created = info["created"] as? Double, created > 0 {
            let f = DateFormatter()
            f.dateStyle = .long
            rows.append(Card.labeled("created", f.string(from: Date(timeIntervalSince1970: created / 1000))))
        }
        infoCard.setRows(rows)
        infoCard.isHidden = rows.isEmpty
        lastInfo = info
        if let people = info["participants"] as? [[String: Any]] {
            subtitle.stringValue = "Group · \(people.count) members"
            let sorted = people.sorted { a, b in
                let aa = (a["admin"] as? Bool) ?? false, ba = (b["admin"] as? Bool) ?? false
                if aa != ba { return aa }
                return ((a["name"] as? String) ?? "").localizedCaseInsensitiveCompare((b["name"] as? String) ?? "") == .orderedAscending
            }
            var memberRows: [NSView] = [Card.caption("\(people.count) MEMBERS")]
            for p in sorted.prefix(256) {
                let row = MemberRow()
                let pj = (p["jid"] as? String) ?? ""
                row.configure(jid: pj, name: (p["name"] as? String) ?? JID.phone(pj),
                              admin: (p["admin"] as? Bool) ?? false, path: Avatars.shared.path(for: pj) ?? "-")
                memberRows.append(row)
            }
            membersCard.setRows(memberRows, separators: false)
            membersCard.isHidden = false
        }
        // Group members just landed in the store: groups in common may have changed.
        if !c.isGroup { buildCommon(c) }
    }

    /// The last profile lookup (about, business), for Contact details.
    private(set) var lastInfo: [String: Any] = [:]

    private func refresh() {
        guard let j = jid else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, let c = self.store.chat(j) else { return }
            self.buildActions(c)
            self.buildSections(c)
            self.buildToggles(c)
        }
    }

    private func buildActions(_ c: Chat) {
        actions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let jid = c.jid
        let items: [(String, String, () -> Void)] = [
            ("magnifyingglass", "Search in Chat", { [weak self] in self?.onSearchInChat?(c) }),
            (c.isMuted ? "bell.fill" : "bell.slash.fill", c.isMuted ? "Unmute" : "Mute", {
                Core.shared.call("mute", ["chat": jid, "on": !c.isMuted, "hours": 0])
            }),
            (c.pinned ? "pin.slash.fill" : "pin.fill", c.pinned ? "Unpin" : "Pin", {
                Core.shared.call("pin", ["chat": jid, "on": !c.pinned])
            }),
            ("archivebox.fill", c.archived ? "Unarchive" : "Archive", {
                Core.shared.call("archive", ["chat": jid, "on": !c.archived])
            }),
            (c.hasUnread ? "envelope.open.fill" : "envelope.badge.fill", c.hasUnread ? "Mark as Read" : "Mark as Unread", {
                Core.shared.call(c.hasUnread ? "mark_read" : "mark_unread", ["chat": jid])
            }),
        ]
        for (sym, tip, act) in items {
            actions.addArrangedSubview(CircleAction(symbol: sym, tip: tip, size: 38) { [weak self] in
                act()
                self?.refresh()
            })
        }
    }

    private func buildToggles(_ c: Chat) {
        let jid = c.jid
        toggleCard.setRows([
            Card.toggle("Mute Notifications", on: c.isMuted) { on in Core.shared.call("mute", ["chat": jid, "on": on, "hours": 0]) },
            Card.toggle("Pin Conversation", on: c.pinned) { on in Core.shared.call("pin", ["chat": jid, "on": on]) },
            Card.toggle("Archive Conversation", on: c.archived) { on in Core.shared.call("archive", ["chat": jid, "on": on]) },
        ])
    }

    private func buildPhotos(_ chat: String) {
        // Only photos we can actually show (a thumbnail or a downloaded file).
        let items = store.recentPhotos(chat, limit: 40)
            .filter { $0.thumb != nil || (!$0.path.isEmpty && FileManager.default.fileExists(atPath: $0.path)) }
            .prefix(9)
        photosCard.isHidden = items.isEmpty
        guard !items.isEmpty else { return }
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.spacing = 4
        var row: NSStackView?
        for (i, item) in items.enumerated() {
            if i % 3 == 0 {
                let r = NSStackView()
                r.spacing = 4
                r.distribution = .fillEqually
                grid.addArrangedSubview(r)
                r.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
                row = r
            }
            let iv = NSImageView()
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.wantsLayer = true
            iv.layer?.cornerRadius = 6
            iv.layer?.masksToBounds = true
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.heightAnchor.constraint(equalTo: iv.widthAnchor).isActive = true
            iv.image = ImageCache.thumb(item.thumb)
            if !item.path.isEmpty {
                ImageCache.shared.load(item.path, px: 200) { img in if let img { iv.image = img } }
            }
            row?.addArrangedSubview(iv)
        }
        if let r = row, items.count % 3 != 0 {
            for _ in 0..<(3 - items.count % 3) { r.addArrangedSubview(NSView()) }
        }
        photosCard.setRows([Card.caption("PHOTOS"), grid], separators: false)
    }

    // MARK: WhatsApp's sections

    private func buildSections(_ c: Chat) {
        let counts = store.mediaCounts(c.jid)
        let starred = store.starredCount(c.jid)
        let bytes = store.downloads(c.jid).reduce(Int64(0)) { $0 + Fmt.fileSize($1.path) }
        mediaCard.setRows([
            NavRow(symbol: "photo.on.rectangle", title: "Media, links and docs", detail: counts.total > 0 ? counts.total.formatted() : "None") { [weak self] in
                self?.pushMedia()
            },
            NavRow(symbol: "internaldrive", title: "Manage storage", detail: bytes > 0 ? Fmt.bytes(bytes) : "None") { [weak self] in
                self?.pushStorage()
            },
            NavRow(symbol: "star", title: "Starred", detail: starred > 0 ? starred.formatted() : "None") { [weak self] in
                self?.pushStarred()
            },
        ])
        let save: String = switch ChatPrefs.saveMode(c.jid) {
        case .default: "Default"
        case .always: "Always"
        case .never: "Never"
        }
        settingsCard.setRows([
            NavRow(symbol: "bell", title: "Notifications", detail: c.isMuted ? "Muted" : nil) { [weak self] in self?.pushNotifications() },
            NavRow(symbol: "paintpalette", title: "Chat theme") { [weak self] in self?.pushTheme() },
            NavRow(symbol: "square.and.arrow.down", title: "Save to Photos", detail: save) { [weak self] in self?.pushSaveToPhotos() },
        ])
        let lock = NSSwitch()
        lock.state = ChatPrefs.isLocked(c.jid) ? .on : .off
        lock.controlSize = .small
        lock.target = self
        lock.action = #selector(lockFlipped(_:))
        privacyCard.setRows([
            NavRow(symbol: "timer", title: "Disappearing messages", detail: Fmt.timer(c.ephemeral)) { [weak self] in self?.pushDisappearing() },
            NavRow(symbol: "lock.rectangle.on.rectangle", title: "Lock chat", subtitle: "Lock and hide this chat on this Mac.",
                   chevron: false, trailing: lock) { [weak self] in
                lock.state = lock.state == .on ? .off : .on
                self?.lockFlipped(lock)
            },
            NavRow(symbol: "checkerboard.shield", title: "Advanced chat privacy", detail: c.limitSharing ? "On" : "Off") { [weak self] in
                self?.pushAdvancedPrivacy()
            },
            NavRow(symbol: "lock", title: "Encryption",
                   subtitle: "Messages \(c.isGroup ? "in this group are" : "and calls are") end-to-end encrypted.") { [weak self] in
                self?.pushEncryption()
            },
        ])
        detailsCard.isHidden = c.isGroup
        if !c.isGroup {
            detailsCard.setRows([
                NavRow(symbol: "person.crop.circle", title: "Contact details") { [weak self] in self?.pushContactDetails() },
            ])
        }
        if c.isGroup {
            commonCaption.isHidden = true
            commonCard.isHidden = true
        } else {
            buildCommon(c)
        }
        buildMore(c)
        buildDanger(c)
    }

    private func buildCommon(_ c: Chat) {
        let groups = store.commonGroups(with: c.jid)
        commonCaption.stringValue = groups.isEmpty ? "No groups in common" : groups.count == 1 ? "1 group in common" : "\(groups.count) groups in common"
        commonCaption.isHidden = false
        commonCard.isHidden = false
        var rows: [NSView] = [
            NavRow(symbol: "plus.circle", title: "Create group with \(c.name)", chevron: false) { [weak self] in self?.createGroup(with: c) },
            NavRow(symbol: "person.2.badge.plus", title: "Add to group", chevron: false) { [weak self] in self?.pushAddToGroup() },
        ]
        for g in groups.prefix(3) {
            rows.append(PersonRow(jid: g.jid, name: g.name, subtitle: g.members.joined(separator: ", "), isGroup: true, avatar: g.avatar) { [weak self] in
                self?.onOpenChat?(g.jid)
            })
        }
        if groups.count > 3 {
            rows.append(NavRow(symbol: nil, title: "See all") { [weak self] in self?.pushCommonGroups() })
        }
        commonCard.setRows(rows)
    }

    private func buildMore(_ c: Chat) {
        var rows: [NSView] = []
        if !c.isGroup {
            rows.append(actionRow("Share contact", color: Theme.accent) { [weak self] in self?.pushShareContact() })
        }
        rows.append(actionRow(c.favorite ? "Remove from Favorites" : "Add to Favorites", color: Theme.accent) { [weak self] in
            self?.toggleFavorite(c)
        })
        rows.append(actionRow("Change list", color: Theme.accent) { [weak self] in self?.pushLists() })
        rows.append(actionRow("Export chat", color: Theme.accent) { [weak self] in self?.exportChat(c) })
        rows.append(actionRow("Clear chat", color: .systemRed) { [weak self] in self?.clearChat(c) })
        moreCard.setRows(rows)
    }

    func buildDanger(_ c: Chat) {
        dangerCard.isHidden = c.isGroup
        guard !c.isGroup else { return }
        let unblock = blocked == true
        dangerCard.setRows([
            actionRow(unblock ? "Unblock \(c.name)" : "Block \(c.name)", color: .systemRed) { [weak self] in
                self?.toggleBlock(c, block: !unblock)
            },
        ])
    }

    @objc private func lockFlipped(_ sw: NSSwitch) {
        guard let c = chat else { return }
        let on = sw.state == .on
        ChatPrefs.authenticate(on ? "lock this chat" : "unlock this chat") { [weak self] ok in
            guard ok else {
                sw.state = on ? .off : .on
                return
            }
            ChatPrefs.setLocked(c.jid, on)
            self?.refreshSections()
        }
    }

    /// Dev hook (`WA_PROFILE_PAGE`): pushes one of the pages, as a click on its row would.
    func debugPush(_ name: String) {
        debugUnanimated = true
        defer { debugUnanimated = false }
        switch name {
        case "media": pushMedia()
        case "storage": pushStorage()
        case "starred": pushStarred()
        case "notifications": pushNotifications()
        case "theme": pushTheme()
        case "save": pushSaveToPhotos()
        case "disappearing": pushDisappearing()
        case "privacy": pushAdvancedPrivacy()
        case "encryption": pushEncryption()
        case "details": pushContactDetails()
        case "groups": pushCommonGroups()
        case "add": pushAddToGroup()
        case "share": pushShareContact()
        case "lists": pushLists()
        case "refresh": refreshSections()
        case let m where m.hasPrefix("frost-"):
            // Dev: try a material for the panel's frost ("frost-hud-0.7").
            let p = m.split(separator: "-")
            let mats: [String: NSVisualEffectView.Material] = ["hud": .hudWindow, "popover": .popover, "sidebar": .sidebar,
                "under": .underWindowBackground, "full": .fullScreenUI, "menu": .menu, "header": .headerView, "window": .windowBackground]
            panelFrost.lockMaterial(mats[String(p[1])] ?? .hudWindow)
            panelFrost.alphaValue = p.count > 2 ? CGFloat(Double(p[2]) ?? 1) : 1
        case "scroll": scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)))
        default: break
        }
    }

    // MARK: navigation inside the panel

    /// Pushes a page over the root, sliding in from the trailing edge (and back out the
    /// same way on pop), so where it went is where it comes back from.
    func push(_ page: ProfilePage, animated: Bool = true) {
        page.onBack = { [weak self] in self?.pop() }
        let below: NSView = pages.last ?? root
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        pages.append(page)
        view.layoutSubtreeIfNeeded()
        if animated && !debugUnanimated {
            slide(page, below: below, forward: true) { below.isHidden = true }
        } else {
            below.isHidden = true
        }
        view.window?.makeFirstResponder(page)
    }

    func pop() {
        guard let page = pages.popLast() else { return }
        let below: NSView = pages.last ?? root
        below.isHidden = false
        if pages.isEmpty { refreshSections() }   // counts and values may have changed on the page
        slide(page, below: below, forward: false) { page.removeFromSuperview() }
    }

    func popToRoot(animated: Bool) {
        guard !pages.isEmpty else { return }
        pages.forEach { $0.removeFromSuperview() }
        pages.removeAll()
        root.isHidden = false
        root.layer?.removeAllAnimations()
    }

    private func slide(_ page: NSView, below: NSView, forward: Bool, done: @escaping () -> Void) {
        let w = view.bounds.width
        guard let pl = page.layer, let bl = below.layer, !Theme.reduceMotion else {
            if Theme.reduceMotion { Motion.crossfade(view.layer, duration: 0.15) }
            done()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { done() } }
        let a = Theme.spring("transform", response: 0.34, damping: 1)
        a.fromValue = CATransform3DMakeTranslation(forward ? w : 0, 0, 0)
        a.toValue = CATransform3DMakeTranslation(forward ? 0 : w, 0, 0)
        a.fillMode = .forwards
        a.isRemovedOnCompletion = false
        pl.add(a, forKey: "nav")
        let b = Theme.spring("transform", response: 0.34, damping: 1)
        b.fromValue = CATransform3DMakeTranslation(forward ? 0 : -w * 0.3, 0, 0)
        b.toValue = CATransform3DMakeTranslation(forward ? -w * 0.3 : 0, 0, 0)
        b.fillMode = .forwards
        b.isRemovedOnCompletion = false
        bl.add(b, forKey: "nav")
        let o = CABasicAnimation(keyPath: "opacity")
        o.fromValue = forward ? 1 : 0
        o.toValue = forward ? 0 : 1
        o.duration = 0.22
        o.fillMode = .forwards
        o.isRemovedOnCompletion = false
        bl.add(o, forKey: "navFade")
        CATransaction.commit()
        if !forward {
            DispatchQueue.main.asyncAfter(deadline: .now() + a.duration) {
                bl.removeAnimation(forKey: "nav")
                bl.removeAnimation(forKey: "navFade")
            }
        }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Grouped rounded section, as in Messages' info panel.
final class Card: NSView {
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.07) : NSColor.white.withAlphaComponent(0.6)).cgColor
    }

    func setRows(_ rows: [NSView], separators: Bool = true) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, r) in rows.enumerated() {
            if separators && i > 0 {
                let line = NSBox()
                line.boxType = .separator
                stack.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            stack.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    static func caption(_ s: String) -> NSView {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return padded(l, top: 8, bottom: 6)
    }

    static func labeled(_ caption: String, _ value: String, selectable: Bool = false) -> NSView {
        let c = NSTextField(labelWithString: caption)
        c.font = .systemFont(ofSize: 11.5)
        c.textColor = .secondaryLabelColor
        let v = NSTextField(wrappingLabelWithString: value)
        v.font = .systemFont(ofSize: 14)
        v.isSelectable = true
        let s = NSStackView(views: [c, v])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 2
        return padded(s, top: 10, bottom: 10)
    }

    static func toggle(_ title: String, on: Bool, _ change: @escaping (Bool) -> Void) -> NSView {
        let row = ToggleRow(title: title, on: on, change: change)
        return padded(row, top: 8, bottom: 8)
    }

    private static func padded(_ v: NSView, top: CGFloat, bottom: CGFloat) -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        v.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            v.topAnchor.constraint(equalTo: box.topAnchor, constant: top),
            v.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -bottom),
        ])
        return box
    }
}

final class ToggleRow: NSView {
    private let change: (Bool) -> Void
    private let toggle = NSSwitch()

    init(title: String, on: Bool, change: @escaping (Bool) -> Void) {
        self.change = change
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 14)
        label.translatesAutoresizingMaskIntoConstraints = false
        toggle.state = on ? .on : .off
        toggle.target = self
        toggle.action = #selector(flip)
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.setAccessibilityLabel(title)
        [label, toggle].forEach(addSubview)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            heightAnchor.constraint(equalToConstant: 26),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func flip() { change(toggle.state == .on) }
}

/// Round glass icon button (Messages' info actions, close).
final class CircleAction: NSView {
    private let handler: () -> Void

    init(symbol: String, tip: String, size: CGFloat = 36, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        let glass = NSGlassEffectView()
        glass.cornerRadius = size / 2
        glass.translatesAutoresizingMaskIntoConstraints = false
        let rim = GlassRim()
        rim.radius = size / 2
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: size * 0.36, weight: .medium)) ?? NSImage(), target: nil, action: nil)
        b.isBordered = false
        b.contentTintColor = .labelColor
        b.translatesAutoresizingMaskIntoConstraints = false
        b.target = self
        b.action = #selector(run)
        b.toolTip = tip
        b.setAccessibilityLabel(tip)
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(b)
        glass.contentView = holder
        [rim, glass].forEach(addSubview)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            rim.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            rim.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            rim.topAnchor.constraint(equalTo: glass.topAnchor),
            rim.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            b.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            b.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            b.widthAnchor.constraint(equalToConstant: size),
            b.heightAnchor.constraint(equalToConstant: size),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

final class MemberRow: NSView {
    private let avatar = AvatarView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
    private let name = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "Admin")

    override init(frame: NSRect) {
        super.init(frame: frame)
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        badge.font = .systemFont(ofSize: 10.5, weight: .medium)
        badge.textColor = .secondaryLabelColor
        [avatar, name, badge].forEach(addSubview)
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        avatar.frame = NSRect(x: 6, y: (bounds.height - 28) / 2, width: 28, height: 28)
        badge.sizeToFit()
        let bw = badge.isHidden ? 0 : badge.frame.width
        badge.frame = NSRect(x: bounds.width - 8 - bw, y: (bounds.height - 15) / 2, width: bw, height: 15)
        name.frame = NSRect(x: 42, y: (bounds.height - 17) / 2, width: bounds.width - 54 - bw, height: 17)
    }

    func configure(jid: String, name n: String, admin: Bool, path: String) {
        name.stringValue = n
        badge.isHidden = !admin
        avatar.configure(jid: jid, name: n, isGroup: false, path: path, px: 56)
        needsLayout = true
    }
}
