import AppKit

/// Someone a group message can @-mention: their JID and the name the text will show.
struct MentionCandidate {
    let jid: String
    let name: String
}

/// The @-mention list that floats over the composer in a group: glass, up to five rows
/// before it scrolls, the highlighted row in the sidebar's selection tone. The composer
/// drives it from the keyboard (↑ ↓, Return or Tab, Esc); the pointer works too.
final class MentionPicker: NSView {
    static let rowH: CGFloat = 40
    static let inset: CGFloat = 6
    static let maxRows = 5
    static let width: CGFloat = 300

    var onPick: ((MentionCandidate) -> Void)?
    private(set) var items: [MentionCandidate] = []
    private let glass = NSGlassEffectView()
    private let scroll = NSScrollView()
    private let list = MentionList()
    private var height: NSLayoutConstraint!

    var isShowing: Bool { !isHidden && alphaValue > 0 }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        isHidden = true
        glass.cornerRadius = 16
        glass.tintColor = Theme.glassTint
        glass.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentInsets = NSEdgeInsets(top: Self.inset, left: 0, bottom: Self.inset, right: 0)
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = list
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(scroll)
        glass.contentView = holder
        addSubview(glass)
        list.onPick = { [weak self] i in self?.pick(i) }
        height = heightAnchor.constraint(equalToConstant: Self.rowH + 2 * Self.inset)
        let preferred = widthAnchor.constraint(equalToConstant: Self.width)
        preferred.priority = .defaultHigh   // narrower when the field is (ConversationViewController caps it)
        NSLayoutConstraint.activate([
            preferred, height,
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: holder.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: holder.topAnchor), scroll.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
        ])
        setAccessibilityRole(.list)
        setAccessibilityLabel("Mention someone")
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Shows these people, the first highlighted. Empty hides the list.
    func show(_ people: [MentionCandidate]) {
        guard !people.isEmpty else { return hide() }
        let same = people.map(\.jid) == items.map(\.jid)
        items = people
        if !same {
            list.set(people)
            height.constant = CGFloat(min(people.count, Self.maxRows)) * Self.rowH + 2 * Self.inset
            list.frame = NSRect(x: 0, y: 0, width: Self.width, height: CGFloat(people.count) * Self.rowH)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: -Self.inset))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        guard isHidden || alphaValue < 1 else { return }
        isHidden = false
        layoutSubtreeIfNeeded()
        // Grows up out of the text it completes: a few points of scale from the bottom-left
        // corner and a fade, quick enough to keep up with typing.
        layer?.removeAllAnimations()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = Theme.easeOut
            animator().alphaValue = 1
        }
        if !Theme.reduceMotion, let l = layer {
            let s = CABasicAnimation(keyPath: "transform")
            let b = l.bounds
            var t = CATransform3DMakeTranslation(0, -b.height * 0.03, 0)
            t = CATransform3DScale(t, 0.97, 0.97, 1)
            s.fromValue = NSValue(caTransform3D: t)
            s.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            s.duration = 0.18
            s.timingFunction = Theme.easeOut
            l.add(s, forKey: "grow")
        }
    }

    func hide() {
        guard !isHidden else { return }
        items = []
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.alphaValue == 0 else { return }
                self.isHidden = true
            }
        })
    }

    func move(_ by: Int) {
        guard !items.isEmpty else { return }
        list.selected = (list.selected + by + items.count) % items.count
        list.scrollToVisible(list.rowRect(list.selected).insetBy(dx: 0, dy: -Self.inset))
    }

    func pickHighlighted() { pick(list.selected) }

    private func pick(_ i: Int) {
        guard items.indices.contains(i) else { return }
        onPick?(items[i])
    }
}

/// The rows, drawn in one view: avatar and name.
private final class MentionList: NSView {
    var onPick: ((Int) -> Void)?
    var selected = 0 { didSet { if selected != oldValue { needsDisplay = true } } }
    private var people: [MentionCandidate] = []
    private var faces: [String: NSImage] = [:]
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    func set(_ p: [MentionCandidate]) {
        people = p
        selected = 0
        for c in p where faces[c.jid] == nil {
            faces[c.jid] = Avatars.shared.monogram(name: c.name, jid: c.jid, isGroup: false)
            if let path = Avatars.shared.path(for: c.jid) {
                ImageCache.shared.load(path, px: 56) { [weak self] img in
                    guard let self, let img else { return }
                    self.faces[c.jid] = img
                    self.needsDisplay = true
                }
            }
        }
        needsDisplay = true
    }

    func rowRect(_ i: Int) -> NSRect { NSRect(x: 0, y: CGFloat(i) * MentionPicker.rowH, width: bounds.width, height: MentionPicker.rowH) }

    override func draw(_ dirtyRect: NSRect) {
        let nameFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        for (i, p) in people.enumerated() {
            let r = rowRect(i)
            guard r.intersects(dirtyRect) else { continue }
            let on = i == selected
            if on {
                Theme.selection.setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: MentionPicker.inset, dy: 2), xRadius: 9, yRadius: 9).fill()
            }
            let face = NSRect(x: r.minX + 14, y: r.midY - 13, width: 26, height: 26)
            if let img = faces[p.jid] {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(ovalIn: face).addClip()
                img.draw(in: face, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            }
            let ink: NSColor = on ? Theme.onSelection : .labelColor
            let trailing = r.maxX - 16
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            NSAttributedString(string: p.name, attributes: [.font: nameFont, .foregroundColor: ink, .paragraphStyle: para])
                .draw(with: NSRect(x: face.maxX + 10, y: r.midY - 8.5, width: max(0, trailing - face.maxX - 10), height: 17),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    private func row(at e: NSEvent) -> Int? {
        let i = Int(convert(e.locationInWindow, from: nil).y / MentionPicker.rowH)
        return people.indices.contains(i) ? i : nil
    }

    override func mouseMoved(with event: NSEvent) { if let i = row(at: event) { selected = i } }
    // Never takes focus from the composer: the click picks and typing carries on.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { if let i = row(at: event) { selected = i } }
    override func mouseUp(with event: NSEvent) { if let i = row(at: event), i == selected { onPick?(i) } }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The open group's members by every name they go by, so a mention in a message stored
/// before mentions were recorded (its "@Name" is plain text by then) still gets marked.
final class MentionDirectory {
    static let shared = MentionDirectory()
    private var people: [(jid: String, name: String)] = []

    func set(_ p: [(jid: String, name: String)]) {
        people = p.filter { $0.name.count >= 2 }.sorted { $0.name.count > $1.name.count }
    }

    /// The members whose "@Name" appears in the text as a whole name, longest names first.
    func find(in text: String) -> [(jid: String, name: String)] {
        guard !people.isEmpty, text.contains("@") else { return [] }
        let ns = text as NSString
        var found: [(jid: String, name: String)] = []
        var taken: [NSRange] = []
        for p in people {
            var from = 0
            while from < ns.length {
                let r = ns.range(of: "@" + p.name, range: NSRange(location: from, length: ns.length - from))
                guard r.location != NSNotFound else { break }
                from = NSMaxRange(r)
                guard Self.endsWord(ns, at: NSMaxRange(r)), !taken.contains(where: { NSIntersectionRange($0, r).length > 0 }) else { continue }
                taken.append(r)
                if !found.contains(where: { $0.jid == p.jid && $0.name == p.name }) { found.append(p) }
            }
        }
        return found
    }

    /// True when nothing word-like follows: the end, a space or punctuation.
    static func endsWord(_ ns: NSString, at i: Int) -> Bool {
        guard i < ns.length else { return true }
        let c = ns.substring(with: ns.rangeOfComposedCharacterSequence(at: i))
        return c.rangeOfCharacter(from: .alphanumerics) == nil
    }
}
