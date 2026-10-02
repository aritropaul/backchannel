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
        name.font = .systemFont(ofSize: 13, weight: .semibold)
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
        rim.fill = NSColor.windowBackgroundColor.withAlphaComponent(0.86)   // text over moving content needs a solid read
        [rim, glass].forEach(addSubview)
        NSLayoutConstraint.activate([
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

/// Right-hand glass inspector, laid out like Messages' info panel: close button,
/// big photo and name, action circles, then grouped cards.
final class ProfileViewController: NSViewController {
    private let store: Store
    private(set) var jid: String?
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let avatar = AvatarView(frame: NSRect(x: 0, y: 0, width: 96, height: 96))
    private let name = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let actions = NSStackView()
    private let infoCard = Card()
    private let toggleCard = Card()
    private let photosCard = Card()
    private let membersCard = Card()
    private var loadToken = UUID()

    init(store: Store) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = NSView()
        view = v
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
        actions.spacing = 14

        [avatar, name, subtitle, actions, infoCard, toggleCard, photosCard, membersCard].forEach(stack.addArrangedSubview)
        stack.setCustomSpacing(10, after: avatar)
        stack.setCustomSpacing(2, after: name)
        stack.setCustomSpacing(16, after: subtitle)
        stack.setCustomSpacing(20, after: actions)

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // The close button is a toolbar item tracking this panel (see MainWindowController).
        v.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: v.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 96),
            avatar.heightAnchor.constraint(equalToConstant: 96),
            name.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -28),
        ])
        for c in [infoCard, toggleCard, photosCard, membersCard] {
            c.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
    }

    func show(_ chatJID: String) {
        guard let c = store.chat(chatJID) else { return }
        jid = chatJID
        let token = UUID()
        loadToken = token
        avatar.configure(jid: c.jid, name: c.name, isGroup: c.isGroup, path: c.avatar, px: 192)
        name.stringValue = c.name
        subtitle.stringValue = c.isGroup ? "Group" : ""
        subtitle.isHidden = !c.isGroup
        buildActions(c)
        infoCard.setRows(c.isGroup ? [] : [Card.labeled("mobile", JID.phone(c.jid), selectable: true)])
        infoCard.isHidden = c.isGroup
        buildToggles(c)
        buildPhotos(c.jid)
        membersCard.setRows([])
        membersCard.isHidden = true
        scrollToTop()
        Task { [weak self] in
            let info = await Core.shared.callAsync("profile", ["chat": chatJID])
            guard let self, self.loadToken == token else { return }
            self.apply(info, chat: c)
            self.scrollToTop()
        }
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
        if let about = info["about"] as? String, !about.isEmpty { rows.append(Card.labeled("about", about)) }
        if let topic = info["topic"] as? String, !topic.isEmpty { rows.append(Card.labeled("description", topic)) }
        if let created = info["created"] as? Double, created > 0 {
            let f = DateFormatter()
            f.dateStyle = .long
            rows.append(Card.labeled("created", f.string(from: Date(timeIntervalSince1970: created / 1000))))
        }
        infoCard.setRows(rows)
        infoCard.isHidden = rows.isEmpty
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
    }

    private func refresh() {
        guard let j = jid else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.show(j) }
    }

    private func buildActions(_ c: Chat) {
        actions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let jid = c.jid
        let items: [(String, String, () -> Void)] = [
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
            actions.addArrangedSubview(CircleAction(symbol: sym, tip: tip, size: 46) { [weak self] in
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
