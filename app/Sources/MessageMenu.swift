import AppKit

/// The top of a message's right-click menu, as in Messages: two rows of reactions inside
/// the native menu. The first row is WhatsApp's six quick reactions, the second the emoji
/// used most recently here, ending in a button for any other emoji. The reaction already
/// sent is ringed in the accent; clicking it again takes it back.
final class ReactionStripView: NSView {
    static let quick = ["👍", "❤️", "😂", "😮", "😢", "🙏"]
    private static let fill = ["🔥", "🎉", "👏", "😍", "🤣", "💯", "😊", "👀"]
    private static let cell: CGFloat = 38
    private static let padX: CGFloat = 12
    private static let padTop: CGFloat = 6
    private static let padBottom: CGFloat = 4
    private static let columns = 6
    /// 21pt draws a glyph about 25pt tall, leaving an even ring of disc around a chosen one.
    private static let font = NSFont(name: "Apple Color Emoji", size: glyphSize) ?? .systemFont(ofSize: glyphSize)
    static let glyphSize: CGFloat = 21

    /// nil is the "any emoji" button.
    private let cells: [String?]
    private let mine: String?
    /// The emoji, and its cell on screen (where it flies to the message from).
    private let onPick: (String, CGRect?) -> Void
    private let onMore: () -> Void
    private var hover: Int? { didSet { if hover != oldValue { needsDisplay = true } } }

    init(recent: [String], mine: String?, onPick: @escaping (String, CGRect?) -> Void, onMore: @escaping () -> Void) {
        var second = recent.filter { !Self.quick.contains($0) }
        for e in Self.fill where second.count < Self.columns - 1 && !second.contains(e) { second.append(e) }
        cells = Self.quick + Array(second.prefix(Self.columns - 1)) + [nil]
        self.mine = mine
        self.onPick = onPick
        self.onMore = onMore
        let rows = CGFloat((cells.count + Self.columns - 1) / Self.columns)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.padX * 2 + CGFloat(Self.columns) * Self.cell,
                                 height: Self.padTop + rows * Self.cell + Self.padBottom))
        // Menus track in their own run loop mode; only .activeAlways areas see the mouse there.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Reactions")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func rect(_ i: Int) -> CGRect {
        CGRect(x: Self.padX + CGFloat(i % Self.columns) * Self.cell, y: Self.padTop + CGFloat(i / Self.columns) * Self.cell,
               width: Self.cell, height: Self.cell)
    }

    private func index(at p: CGPoint) -> Int? { cells.indices.first { rect($0).contains(p) } }

    /// The smiley's grey, resolved for this view's appearance: a dynamic colour baked into a
    /// symbol image can resolve for the wrong one and vanish on a dark menu.
    private var moreTint: NSColor {
        var c = NSColor.secondaryLabelColor
        effectiveAppearance.performAsCurrentDrawingAppearance { c = NSColor.secondaryLabelColor.usingColorSpace(.sRGB) ?? c }
        return c
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, e) in cells.enumerated() {
            let r = rect(i)
            if let e, e == mine {
                // Sent already: a soft accent disc with a hairline ring, like Messages' selected tapback.
                let disc = NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5))
                Theme.accent.withAlphaComponent(0.28).setFill()
                disc.fill()
                Theme.accent.withAlphaComponent(0.7).setStroke()
                disc.lineWidth = 1
                disc.stroke()
            } else if i == hover {
                NSColor.labelColor.withAlphaComponent(0.1).setFill()
                NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5)).fill()
            }
            if let e {
                let s = NSAttributedString(string: e, attributes: [.font: Self.font])
                let sz = s.size()
                // Emoji sit a hair high in their line box; nudge down to centre optically.
                s.draw(at: CGPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2 + 1))
            } else if let img = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "More reactions")?
                .withSymbolConfiguration(.init(pointSize: 19, weight: .regular).applying(.init(paletteColors: [moreTint]))) {
                let sz = img.size
                img.draw(in: CGRect(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2, width: sz.width, height: sz.height))
            }
        }
    }

    override func mouseMoved(with event: NSEvent) { hover = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { hover = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hover = nil }

    override func mouseUp(with event: NSEvent) {
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        choose(i)
    }

    private func choose(_ i: Int) {
        let pick = cells[i]
        // Read while the menu is still on screen; the emoji takes off from here.
        var r = rect(i)
        r.origin.y += 1   // the glyph's optical nudge in draw(_:)
        let from = window.map { $0.convertToScreen(convert(r, to: nil)) }
        enclosingMenuItem?.menu?.cancelTracking()
        // Act once the menu has closed, so a popover or the transcript update isn't fighting it.
        DispatchQueue.main.async { [onPick, onMore] in
            if let pick { onPick(pick, from) } else { onMore() }
        }
    }

    // MARK: Accessibility: one button per cell.

    override func accessibilityChildren() -> [Any]? {
        let names = Self.names
        return cells.enumerated().map { i, e in
            let el = CellElement(index: i) { [weak self] in self?.choose(i) }
            el.setAccessibilityParent(self)
            el.setAccessibilityRole(.button)
            el.setAccessibilityLabel(e.map { e in (e == mine ? "Remove " : "") + (names[e] ?? e) } ?? "More reactions")
            el.setAccessibilityFrameInParentSpace(rect(i))
            return el
        }
    }

    private static let names: [String: String] = Dictionary(EmojiCatalog.groups.flatMap(\.emoji).map { ($0.char, $0.name) },
                                                            uniquingKeysWith: { a, _ in a })

    // NSAccessibilityElement isn't main-actor isolated, so neither is this (like ClosureMenuItem).
    private nonisolated final class CellElement: NSAccessibilityElement {
        let index: Int
        private let press: @MainActor () -> Void
        init(index: Int, press: @escaping @MainActor () -> Void) {
            self.index = index
            self.press = press
            super.init()
        }
        override func accessibilityPerformPress() -> Bool {
            let p = press
            MainActor.assumeIsolated { p() }
            return true
        }
    }
}

/// Any emoji as a reaction: the composer's emoji grid in a popover, with search and the
/// recently used ones first.
final class ReactionPickerViewController: NSViewController, NSSearchFieldDelegate {
    static let size = NSSize(width: 340, height: 380)
    var onPick: ((String) -> Void)?
    private let search = NSSearchField()
    private let scroll = NSScrollView()
    private let grid = EmojiGridView()

    override func loadView() {
        let v = NSView(frame: NSRect(origin: .zero, size: Self.size))
        search.placeholderString = "Search emoji"
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        grid.autoresizingMask = [.width]
        grid.onPick = { [weak self] e in self?.onPick?(e) }
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.grid.scrolled() }
        }
        v.addSubview(search)
        v.addSubview(scroll)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: v.topAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        view = v
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.layoutSubtreeIfNeeded()
        reload()
        view.window?.makeFirstResponder(search)
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    private func reload() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        var sections: [EmojiGridView.Section] = []
        if !q.isEmpty {
            sections = [.init(title: "Results", emoji: EmojiCatalog.search(q))]
        } else {
            let byChar = Dictionary(EmojiCatalog.groups.flatMap(\.emoji).map { ($0.char, $0) }, uniquingKeysWith: { a, _ in a })
            let recent = EmojiCatalog.recent.map { byChar[$0] ?? .init(char: $0, name: "", tones: false) }
            if !recent.isEmpty { sections.append(.init(title: "Recently Used", emoji: recent)) }
            sections += EmojiCatalog.groups.map { .init(title: $0.title, emoji: $0.emoji) }
        }
        grid.frame.size.width = scroll.contentView.bounds.width
        grid.set(sections)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
