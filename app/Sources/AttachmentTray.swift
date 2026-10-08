import AppKit

/// One file in the composer's tray, as the tray draws it.
struct TrayItem {
    let id: UUID
    var image: NSImage?
    /// Still being made ready for WhatsApp (a video re-encoding, say).
    var preparing: Bool
    /// A video's or song's length, on the tile's bottom-left.
    var badge: String?
    var name: String
}

/// Files waiting in the composer: WhatsApp's thumbnail row, without its modal. Square
/// tiles, the selected one ringed in the accent (its caption is in the text field), a ✕
/// on the tile under the pointer, and a + tile for more. The selected file's name and
/// size sit under the row.
final class AttachmentTray: NSView {
    var onSelect: ((Int) -> Void)?
    var onRemove: ((Int) -> Void)?
    var onAdd: ((NSView) -> Void)?
    var onOpen: ((Int) -> Void)?

    /// The picture inside a tile; the tile is a ring's width bigger on every side.
    static let side: CGFloat = 56
    static let frameSide = side + 2 * TrayTile.margin
    private static let gap: CGFloat = 6
    /// Lines the pictures up with the text below (14pt in, like the field's text).
    private static let lead: CGFloat = 14 - TrayTile.margin
    private static let top: CGFloat = 8

    private let scroll = NSScrollView()
    private let row = FlippedRow()
    private var tiles: [TrayTile] = []
    private let add = TrayAddTile()
    private let info = NSTextField(labelWithString: "")
    /// The row's own width; the window's width wins when they disagree, so the tiles
    /// scroll rather than widen anything.
    private var rowWidth: NSLayoutConstraint!
    private(set) var selected = 0
    private var selectedID: UUID?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .allowed
        scroll.documentView = row
        scroll.translatesAutoresizingMaskIntoConstraints = false
        add.onClick = { [weak self] in
            guard let self else { return }
            self.onAdd?(self.add)
        }
        add.translatesAutoresizingMaskIntoConstraints = false
        info.font = .systemFont(ofSize: 11.5)
        info.textColor = .secondaryLabelColor
        info.lineBreakMode = .byTruncatingMiddle
        info.translatesAutoresizingMaskIntoConstraints = false
        // Truncates instead of widening the composer (and the window with it).
        info.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        [scroll, add, info].forEach(addSubview)
        rowWidth = scroll.widthAnchor.constraint(equalToConstant: 0)
        rowWidth.priority = .init(200)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.lead),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: Self.top),
            scroll.heightAnchor.constraint(equalToConstant: Self.frameSide),
            rowWidth,
            // The + follows the last tile and stays in reach when the tiles scroll.
            add.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: Self.gap),
            add.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            add.topAnchor.constraint(equalTo: scroll.topAnchor),
            add.widthAnchor.constraint(equalToConstant: Self.frameSide),
            add.heightAnchor.constraint(equalToConstant: Self.frameSide),
            info.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            info.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            info.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 2),
            info.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Puts the row in step with `items`: new tiles pop in, removed ones shrink away and
    /// the rest slide to their places.
    func set(_ items: [TrayItem], selected: Int, info text: String, animated: Bool) {
        self.selected = selected
        info.stringValue = text
        let animate = animated && !Theme.reduceMotion && window != nil
        let keep = Set(items.map(\.id))
        for t in tiles where !keep.contains(t.id) {
            if animate {
                t.shrinkAway()
            } else {
                t.removeFromSuperview()
            }
        }
        var next: [TrayTile] = []
        var added: [TrayTile] = []
        for (i, item) in items.enumerated() {
            let t = tiles.first { $0.id == item.id } ?? {
                let t = TrayTile(id: item.id)
                t.onClick = { [weak self, weak t] in
                    guard let self, let t, let i = self.tiles.firstIndex(of: t) else { return }
                    self.onSelect?(i)
                }
                t.onDoubleClick = { [weak self, weak t] in
                    guard let self, let t, let i = self.tiles.firstIndex(of: t) else { return }
                    self.onOpen?(i)
                }
                t.onRemove = { [weak self, weak t] in
                    guard let self, let t, let i = self.tiles.firstIndex(of: t) else { return }
                    self.onRemove?(i)
                }
                row.addSubview(t)
                added.append(t)
                return t
            }()
            t.update(item, selected: i == selected)
            next.append(t)
        }
        tiles = next
        layoutRow(animated: animate, placing: Set(added.map(\.id)))
        for t in added where animate {
            Motion.pop(t.layer, size: t.bounds.size, from: 0.9, response: 0.3, damping: 1)
        }
        // Once laid out: files added later come into view, or a newly selected one does.
        // A thumbnail arriving leaves the row where it's been scrolled to.
        let selectedTile = tiles.indices.contains(selected) ? tiles[selected] : nil
        let reselected = selectedTile?.id != selectedID
        selectedID = selectedTile?.id
        guard !added.isEmpty || reselected else { return }
        let reveal = added.contains { $0 === selectedTile } || added.isEmpty ? selectedTile : added.last
        DispatchQueue.main.async { [weak self] in
            guard let self, let reveal, self.tiles.contains(reveal) else { return }
            self.row.scrollToVisible(reveal.frame)
        }
    }

    private func layoutRow(animated: Bool, placing: Set<UUID>) {
        let s = Self.frameSide
        var x: CGFloat = 0
        func place(_ v: NSView, _ fresh: Bool) {
            let f = CGRect(x: x, y: 0, width: s, height: s)
            if animated && !fresh { v.animator().frame = f } else { v.frame = f }
            x += s + Self.gap
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = Theme.easeOut
            for t in tiles { place(t, placing.contains(t.id)) }
        }
        let width = max(0, x - Self.gap)
        row.setFrameSize(CGSize(width: width, height: s))
        rowWidth.constant = width
    }
}

private final class FlippedRow: NSView {
    override var isFlipped: Bool { true }
}

/// One file: its thumbnail with a hairline rim, the accent ring when selected, a ✕ while
/// the pointer is on it, a small spinner while it's being prepared.
final class TrayTile: NSView {
    /// Room around the picture for the ring and a hair of space inside it.
    static let margin: CGFloat = 3.5
    private static let radius: CGFloat = 10

    let id: UUID
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onRemove: (() -> Void)?

    /// The picture, rim and ring live in their own view, so AppKit never reorders them
    /// over the badge, spinner and ✕.
    private let art = NSView()
    private let picture = CALayer()
    private let rim = CALayer()
    private let ring = CALayer()
    private var shown: NSImage?
    private let badge = NSTextField(labelWithString: "")
    private let close = NSButton()
    private let spinner = NSProgressIndicator()
    private var hovering = false { didSet { showClose(hovering) } }
    private var isSelected = false

    override var isFlipped: Bool { true }

    init(id: UUID) {
        self.id = id
        super.init(frame: CGRect(x: 0, y: 0, width: AttachmentTray.frameSide, height: AttachmentTray.frameSide))
        wantsLayer = true
        art.frame = bounds
        art.wantsLayer = true
        addSubview(art)
        let inner = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        picture.frame = inner
        picture.cornerRadius = Self.radius
        picture.cornerCurve = .continuous
        picture.masksToBounds = true
        picture.contentsGravity = .resizeAspectFill
        rim.frame = inner
        rim.cornerRadius = Self.radius
        rim.cornerCurve = .continuous
        rim.borderWidth = 0.5
        // Concentric with the picture: its radius grows by the gap it sits out.
        ring.frame = bounds.insetBy(dx: 0.25, dy: 0.25)
        ring.cornerRadius = Self.radius + Self.margin - 0.25
        ring.cornerCurve = .continuous
        ring.borderWidth = 2
        ring.isHidden = true
        [picture, rim, ring].forEach { art.layer?.addSublayer($0) }

        badge.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        badge.textColor = .white
        badge.wantsLayer = true
        badge.layer?.shadowOpacity = 0.6
        badge.layer?.shadowRadius = 2
        badge.layer?.shadowOffset = .zero
        badge.isHidden = true
        addSubview(badge)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.frame = CGRect(x: bounds.midX - 8, y: bounds.midY - 8, width: 16, height: 16)
        addSubview(spinner)

        let cfg = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold).applying(.init(paletteColors: [.white]))
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove")?.withSymbolConfiguration(cfg)
        close.isBordered = false
        close.imagePosition = .imageOnly
        close.target = self
        close.action = #selector(remove)
        close.wantsLayer = true
        close.layer?.cornerRadius = 9
        close.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        close.layer?.borderWidth = 0.5
        close.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        close.frame = CGRect(x: inner.maxX - 18 - 3, y: inner.minY + 3, width: 18, height: 18)
        close.alphaValue = 0
        close.isHidden = true
        addSubview(close)

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ item: TrayItem, selected: Bool) {
        if item.image !== shown {
            if shown != nil { Motion.crossfade(picture, duration: 0.15) }
            shown = item.image
            picture.contents = item.image.flatMap { $0.layerContents(forContentsScale: window?.backingScaleFactor ?? 2) }
        }
        picture.opacity = item.preparing ? 0.45 : 1
        if item.preparing { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        badge.stringValue = item.badge ?? ""
        badge.isHidden = item.badge == nil
        badge.sizeToFit()
        let inner = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        badge.frame.origin = CGPoint(x: inner.minX + 5, y: inner.maxY - badge.frame.height - 3)
        isSelected = selected
        ring.isHidden = !selected
        toolTip = item.name
        setAccessibilityLabel(item.name)
        close.setAccessibilityLabel("Remove \(item.name)")
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        effectiveAppearance.performAsCurrentDrawingAppearance {
            rim.borderColor = (dark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.12)).cgColor
            picture.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
            ring.borderColor = Theme.accent.cgColor
        }
    }

    private func showClose(_ on: Bool) {
        if on { close.isHidden = false }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = on ? 0.12 : 0.1
            ctx.timingFunction = Theme.easeOut
            close.animator().alphaValue = on ? 1 : 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.hovering else { return }
                self.close.isHidden = true
            }
        })
    }

    /// Leaves the row: shrinks a little as it fades, then goes.
    func shrinkAway() {
        guard let layer else { removeFromSuperview(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in MainActor.assumeIsolated { self?.removeFromSuperview() } }
        let s = CABasicAnimation(keyPath: "transform")
        s.toValue = Motion.scale(0.9, in: bounds.size)
        let o = CABasicAnimation(keyPath: "opacity")
        o.toValue = 0
        for a in [s, o] {
            a.duration = 0.14
            a.timingFunction = Theme.easeOut
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
            layer.add(a, forKey: a.keyPath)
        }
        CATransaction.commit()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if event.clickCount == 2 { onDoubleClick?() } else { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    @objc private func remove() { onRemove?() }
}

/// The + after the tiles: a hairline square that adds more files.
final class TrayAddTile: NSView {
    var onClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        toolTip = "Add more"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Add more files")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: TrayTile.margin + 0.5, dy: TrayTile.margin + 0.5)
        let p = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        if hovering || pressed {
            NSColor.labelColor.withAlphaComponent(pressed ? 0.12 : 0.06).setFill()
            p.fill()
        }
        NSColor.labelColor.withAlphaComponent(0.28).setStroke()
        p.lineWidth = 1
        p.stroke()
        let cfg = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
            .applying(.init(paletteColors: [.secondaryLabelColor]))
        if let g = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let s = g.size
            g.draw(in: CGRect(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2, width: s.width, height: s.height))
        }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
