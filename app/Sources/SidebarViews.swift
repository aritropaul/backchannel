import AppKit

/// Circular avatar: photo when we have one; otherwise a Contacts-style monogram,
/// or for groups without a picture, a cluster of recent members like iMessage.
final class AvatarView: NSView {
    private var photo: NSImage?
    private var fallback: NSImage?
    private var members: [NSImage] = []
    private var token = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    var image: NSImage? {
        get { photo }
        set { photo = newValue; needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let photo {
            drawCircle(photo, in: bounds)
        } else if members.count >= 2 {
            drawCluster()
        } else if let fallback {
            fallback.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    private func drawCircle(_ img: NSImage, in r: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: r).addClip()
        let s = img.size
        let scale = max(r.width / max(s.width, 1), r.height / max(s.height, 1))
        let w = s.width * scale, h = s.height * scale
        img.draw(in: CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h), from: .zero,
                 operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Two or three member circles, each ringed in the background so they read as separate.
    private func drawCluster() {
        let b = bounds
        let frames: [CGRect]
        if members.count == 2 {
            let d = b.width * 0.62
            frames = [CGRect(x: b.minX, y: b.minY, width: d, height: d),
                      CGRect(x: b.maxX - d, y: b.maxY - d, width: d, height: d)]
        } else {
            let d = b.width * 0.54
            frames = [CGRect(x: b.midX - d / 2, y: b.minY, width: d, height: d),
                      CGRect(x: b.minX, y: b.maxY - d, width: d, height: d),
                      CGRect(x: b.maxX - d, y: b.maxY - d, width: d, height: d)]
        }
        for (img, f) in zip(members, frames).reversed() {
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(ovalIn: f.insetBy(dx: -1.5, dy: -1.5)).fill()
            drawCircle(img, in: f)
        }
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    func load(_ c: Chat, px: Int) {
        configure(jid: c.jid, name: c.name, isGroup: c.isGroup, path: c.avatar, px: px)
    }

    func configure(jid: String, name: String, isGroup: Bool, path: String, px: Int) {
        token = jid
        fallback = Avatars.shared.monogram(name: name, jid: jid, isGroup: isGroup)
        members = []
        photo = nil
        if path.isEmpty { Core.shared.call("avatar", ["chat": jid]) }
        if !path.isEmpty, path != "-" {
            if let img = ImageCache.shared.cached(path, px: px) {
                photo = img
            } else {
                ImageCache.shared.load(path, px: px) { [weak self] img in
                    guard let self, self.token == jid, let img else { return }
                    Motion.crossfade(self.layer, duration: 0.2)
                    self.photo = img
                    self.needsDisplay = true
                }
            }
        } else if isGroup, let store = Avatars.shared.store {
            loadMembers(store.recentSenders(jid, limit: 3), store: store, px: px / 2 + 16)
        }
        needsDisplay = true
    }

    private func loadMembers(_ jids: [String], store: Store, px: Int) {
        guard jids.count >= 2 else { return }
        let want = token
        members = jids.map { Avatars.shared.monogram(name: store.name($0), jid: $0, isGroup: false) }
        for (i, j) in jids.enumerated() {
            guard let p = Avatars.shared.path(for: j) else { continue }
            if let img = ImageCache.shared.cached(p, px: px) {
                members[i] = img
            } else {
                ImageCache.shared.load(p, px: px) { [weak self] img in
                    guard let self, self.token == want, let img, i < self.members.count else { return }
                    self.members[i] = img
                    self.needsDisplay = true
                }
            }
        }
    }
}

/// Glass segmented tabs with a thumb that springs between segments.
final class GlassSegmentedControl: NSView {
    var onChange: ((Int) -> Void)?
    private(set) var selected = 0
    private let glass = NSGlassEffectView()
    private let thumb = NSView()
    private var buttons: [NSButton] = []
    private static let thumbFill = NSColor(name: "segThumb") { @Sendable ap in
        ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor.white.withAlphaComponent(0.16) : NSColor.white.withAlphaComponent(0.95)
    }

    init(labels: [String]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        glass.cornerRadius = 15
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        let content = NSView()
        glass.contentView = content
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 12
        thumb.layer?.shadowOpacity = 0.12
        thumb.layer?.shadowRadius = 2
        thumb.layer?.shadowOffset = CGSize(width: 0, height: -1)
        content.addSubview(thumb)
        for (i, l) in labels.enumerated() {
            let b = NSButton(title: l, target: self, action: #selector(tap(_:)))
            b.isBordered = false
            b.tag = i
            b.font = .systemFont(ofSize: 12, weight: .medium)
            b.setAccessibilityRole(.radioButton)
            content.addSubview(b)
            buttons.append(b)
        }
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        setAccessibilityRole(.radioGroup)
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func segmentRect(_ i: Int) -> CGRect {
        let b = glass.bounds
        let w = (b.width - 6) / CGFloat(max(1, buttons.count))
        return CGRect(x: 3 + CGFloat(i) * w, y: 3, width: w, height: b.height - 6)
    }

    override func layout() {
        super.layout()
        glass.contentView?.frame = glass.bounds
        for (i, b) in buttons.enumerated() { b.frame = segmentRect(i) }
        if thumb.layer?.animation(forKey: "slide") == nil { thumb.frame = segmentRect(selected) }
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            thumb.layer?.backgroundColor = Self.thumbFill.cgColor
        }
        for (i, b) in buttons.enumerated() {
            b.contentTintColor = i == selected ? .labelColor : .secondaryLabelColor
            b.attributedTitle = NSAttributedString(string: b.title, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: i == selected ? .semibold : .medium),
                .foregroundColor: i == selected ? NSColor.labelColor : NSColor.secondaryLabelColor])
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    func select(_ i: Int, animated: Bool) {
        guard i != selected || !animated else { return }
        let from = thumb.frame
        selected = i
        let to = segmentRect(i)
        thumb.frame = to
        updateColors()
        guard animated, !Theme.reduceMotion, let layer = thumb.layer else { return }
        let s = Theme.spring("position", response: 0.32, damping: 0.78)
        s.fromValue = NSValue(point: from.origin)
        s.toValue = NSValue(point: to.origin)
        layer.add(s, forKey: "slide")
    }

    @objc private func tap(_ b: NSButton) {
        select(b.tag, animated: true)
        onChange?(b.tag)
    }
}

/// Messages-style conversation row: unread dot, avatar, name/time, 2-line preview.
final class ChatCellView: NSTableCellView {
    let dot = NSView()
    /// Where the name/preview column starts; the row separator starts here too.
    static let textX: CGFloat = 64
    let avatar = AvatarView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
    let name = NSTextField(labelWithString: "")
    let time = NSTextField(labelWithString: "")
    let preview = NSTextField(wrappingLabelWithString: "")
    let muted = NSImageView()
    private(set) var chat: Chat?
    private var typing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4.5
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        time.font = .systemFont(ofSize: 13)
        time.alignment = .right
        preview.font = .systemFont(ofSize: 13)
        preview.maximumNumberOfLines = 2
        preview.lineBreakMode = .byWordWrapping
        preview.cell?.truncatesLastVisibleLine = true
        muted.image = NSImage(systemSymbolName: "bell.slash.fill", accessibilityDescription: "Muted")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        [dot, avatar, name, time, preview, muted].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let w = bounds.width
        dot.frame = NSRect(x: 1, y: (bounds.height - 9) / 2, width: 9, height: 9)
        avatar.frame = NSRect(x: 14, y: (bounds.height - 40) / 2, width: 40, height: 40)
        // Name + two preview lines as one block, centred in the row like Messages.
        let x = Self.textX, top = (bounds.height - 52) / 2
        time.sizeToFit()
        let tw = time.frame.width
        time.frame = NSRect(x: w - 12 - tw, y: top + 1, width: tw, height: 17)
        var right = w - 12 - tw - 6
        if !muted.isHidden {
            muted.frame = NSRect(x: right - 12, y: top + 2, width: 12, height: 14)
            right -= 16
        }
        name.frame = NSRect(x: x, y: top, width: max(0, right - x), height: 18)
        preview.frame = NSRect(x: x, y: top + 19, width: w - 12 - x, height: 34)
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        name.textColor = selected ? Theme.onSelection : .labelColor
        time.textColor = selected ? Theme.onSelectionSecondary : .secondaryLabelColor
        preview.textColor = selected ? Theme.onSelectionSecondary : .secondaryLabelColor
        muted.contentTintColor = selected ? Theme.onSelectionSecondary : .tertiaryLabelColor
        if let c = chat {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                dot.layer?.backgroundColor = (c.isMuted ? NSColor.tertiaryLabelColor : Theme.accent).cgColor
            }
        }
    }

    func configure(_ c: Chat, typing: Bool) {
        let changed = chat?.jid == c.jid && (chat != c || self.typing != typing)
        if changed { Motion.crossfade(layer) }
        chat = c
        self.typing = typing
        name.stringValue = c.name
        time.stringValue = c.lastTS > 0 ? Fmt.listStamp(Date(timeIntervalSince1970: TimeInterval(c.lastTS) / 1000)) : ""
        dot.isHidden = !c.hasUnread
        muted.isHidden = !c.isMuted
        preview.stringValue = Self.previewText(c, typing: typing)
        avatar.load(c, px: 80)
        applyColors()
        setAccessibilityLabel("\(c.name), \(c.hasUnread ? "unread, " : "")\(preview.stringValue)")
        needsLayout = true
    }

    static func previewText(_ c: Chat, typing: Bool) -> String {
        if typing { return "typing…" }
        guard let l = c.last else { return "" }
        let text = Fmt.preview(kind: l.kind, text: l.text, fileName: l.fileName)
        if l.kind == .revoked { return text }
        if c.isGroup && !l.fromMe && !l.senderName.isEmpty { return "\(l.senderName): \(text)" }
        if l.fromMe && (l.kind != .text) { return "You: \(text)" }
        return text
    }
}

/// One pinned conversation: big avatar, name underneath, unread dot.
final class PinnedTile: NSView {
    static let avatarSize: CGFloat = 72
    let avatar = AvatarView(frame: NSRect(x: 0, y: 0, width: avatarSize, height: avatarSize))
    private let name = NSTextField(labelWithString: "")
    private let dot = NSView()
    private(set) var chat: Chat?
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true; applyColors() } } }
    var onClick: ((Chat) -> Void)?
    var onMenu: ((Chat) -> NSMenu)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        name.font = .systemFont(ofSize: 12)
        name.alignment = .center
        name.lineBreakMode = .byTruncatingTail
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 7
        dot.layer?.borderWidth = 2
        [avatar, name, dot].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }   // the selected fill must match the bubbles exactly

    override func layout() {
        super.layout()
        let size = min(Self.avatarSize, bounds.width - 12)
        avatar.frame = NSRect(x: (bounds.width - size) / 2, y: 8, width: size, height: size)
        dot.frame = NSRect(x: avatar.frame.maxX - 14, y: avatar.frame.minY + 1, width: 14, height: 14)
        name.frame = NSRect(x: 4, y: avatar.frame.maxY + 7, width: bounds.width - 8, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        Theme.selection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 12, yRadius: 12).fill()
    }

    private func applyColors() {
        name.textColor = isSelected ? Theme.onSelection : .secondaryLabelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.layer?.backgroundColor = (chat?.isMuted ?? false ? NSColor.tertiaryLabelColor : Theme.accent).cgColor
            dot.layer?.borderColor = (isSelected ? Theme.selection : NSColor.windowBackgroundColor).cgColor
        }
    }

    func configure(_ c: Chat) {
        if chat?.jid == c.jid, chat != c { Motion.crossfade(layer) }
        chat = c
        name.stringValue = c.name
        dot.isHidden = !c.hasUnread
        avatar.load(c, px: 144)
        applyColors()
        setAccessibilityRole(.button)
        setAccessibilityLabel("Pinned: \(c.name)\(c.hasUnread ? ", unread" : "")")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    // Press feedback: dip on mouse-down, spring back on release.
    override func mouseDown(with event: NSEvent) {
        press(true)
    }

    override func mouseUp(with event: NSEvent) {
        press(false)
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p), let chat { onClick?(chat) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        chat.flatMap { onMenu?($0) }
    }

    private func press(_ down: Bool) {
        guard let layer, !Theme.reduceMotion else { return }
        let to = down ? Motion.scale(0.96, in: bounds.size) : CATransform3DIdentity
        let a = Theme.spring("transform", response: down ? 0.18 : 0.3, damping: down ? 1 : 0.7)
        a.fromValue = layer.presentation()?.transform ?? layer.transform
        a.toValue = to
        layer.transform = to
        layer.add(a, forKey: "press")
    }
}

/// Up to nine pinned conversations, three per row, like Messages.
final class PinnedGridView: NSView {
    private var tiles: [PinnedTile] = []
    var onSelect: ((Chat) -> Void)?
    var onMenu: ((Chat) -> NSMenu)?
    static let tileH: CGFloat = 114

    override var isFlipped: Bool { true }

    static func height(for n: Int) -> CGFloat {
        n == 0 ? 0 : CGFloat((min(n, 9) + 2) / 3) * tileH + 12
    }

    func configure(_ chats: [Chat], selected: String?) {
        let list = Array(chats.prefix(9))
        while tiles.count < list.count {
            let t = PinnedTile()
            t.onClick = { [weak self] c in self?.onSelect?(c) }
            t.onMenu = { [weak self] c in self?.onMenu?(c) ?? NSMenu() }
            addSubview(t)
            tiles.append(t)
        }
        while tiles.count > list.count { tiles.removeLast().removeFromSuperview() }
        for (t, c) in zip(tiles, list) {
            t.configure(c)
            t.isSelected = c.jid == selected
        }
        needsLayout = true
    }

    func setSelected(_ jid: String?) {
        for t in tiles { t.isSelected = t.chat?.jid == jid }
    }

    override func layout() {
        super.layout()
        let w = (bounds.width - 16) / 3
        for (i, t) in tiles.enumerated() {
            t.frame = NSRect(x: 8 + CGFloat(i % 3) * w, y: 4 + CGFloat(i / 3) * Self.tileH, width: w, height: Self.tileH)
        }
    }
}

/// "Archived" entry and the back row inside the archive.
final class ListLinkCellView: NSTableCellView {
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    let count = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        count.font = .systemFont(ofSize: 12)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        [icon, label, count].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 23, y: (bounds.height - 20) / 2, width: 22, height: 20)
        count.sizeToFit()
        count.frame = NSRect(x: bounds.width - 14 - count.frame.width, y: (bounds.height - 16) / 2, width: count.frame.width, height: 16)
        label.frame = NSRect(x: 65, y: (bounds.height - 18) / 2, width: count.frame.minX - 73, height: 18)
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let sel = backgroundStyle == .emphasized
            label.textColor = sel ? Theme.onSelection : .labelColor
            icon.contentTintColor = sel ? Theme.onSelectionSecondary : .secondaryLabelColor
        }
    }
}
