import AppKit
import QuartzCore

enum Motion {
    /// Scale about a view's center. AppKit view layers anchor at (0,0), so build the
    /// matrix explicitly instead of fighting anchorPoint.
    static func scale(_ s: CGFloat, in size: CGSize) -> CATransform3D {
        var t = CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0)
        t = CATransform3DScale(t, s, s, 1)
        return CATransform3DTranslate(t, -size.width / 2, -size.height / 2, 0)
    }

    static func scale(_ s: CGFloat, about p: CGPoint) -> CATransform3D {
        var t = CATransform3DMakeTranslation(p.x, p.y, 0)
        t = CATransform3DScale(t, s, s, 1)
        return CATransform3DTranslate(t, -p.x, -p.y, 0)
    }

    static func fade(_ layer: CALayer?, from: Float = 0, duration: Double = 0.15) {
        let o = CABasicAnimation(keyPath: "opacity")
        o.fromValue = from
        o.toValue = 1
        o.duration = duration
        o.timingFunction = Theme.easeOut
        layer?.add(o, forKey: "fadeIn")
    }

    /// Crossfade whatever the layer draws next (content swaps in place).
    static func crossfade(_ layer: CALayer?, duration: Double = 0.15) {
        let t = CATransition()
        t.type = .fade
        t.duration = duration
        t.timingFunction = Theme.easeOut
        layer?.add(t, forKey: "crossfade")
    }

    /// Spring "pop" from `from` scale about the layer's center, with a quick fade.
    static func pop(_ layer: CALayer?, size: CGSize, from: CGFloat, response: Double, damping: Double) {
        guard let layer else { return }
        if Theme.reduceMotion { fade(layer); return }
        let s = Theme.spring("transform", response: response, damping: damping)
        s.fromValue = scale(from, in: size)
        s.toValue = CATransform3DIdentity
        layer.add(s, forKey: "pop")
        fade(layer, duration: 0.12)
    }
}

/// Reactions on a bubble's top corner, in dark frosted glass like Messages' tapbacks: a
/// circle for a single reaction, a pill for several (the emoji side by side, then "+N" for
/// the people beyond them).
final class ReactionBadgeView: NSView {
    /// Room for a 12pt emoji with about 10pt of glass around it; the pill's height too.
    static let side: CGFloat = 32
    /// The pill's ends match the circle's glass around an emoji.
    private static let padX: CGFloat = 10
    private static let gap: CGFloat = 2
    private static let countGap: CGFloat = 5
    private static let emojiFont = NSFont.systemFont(ofSize: 12)
    private static let countFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

    static func glyphs(_ r: Reactions) -> [String] { r.emoji.map(String.init) }
    /// People who reacted beyond the emoji shown.
    static func extra(_ r: Reactions) -> Int { max(0, r.total - glyphs(r).count) }

    private static func items(_ r: Reactions) -> [(text: String, font: NSFont)] {
        var out = glyphs(r).map { (text: $0, font: emojiFont) }
        if extra(r) > 0 { out.append((text: "+\(extra(r))", font: countFont)) }
        return out
    }

    /// Where each item sits (the emoji in order, then the count), in badge coordinates.
    static func slots(for r: Reactions) -> [CGRect] {
        let items = items(r)
        guard items.count > 1 else { return [CGRect(x: 0, y: 0, width: side, height: side)] }
        var x = padX
        var out: [CGRect] = []
        for (i, it) in items.enumerated() {
            if i > 0 { x += i == items.count - 1 && extra(r) > 0 ? countGap : gap }
            let w = ceil(NSAttributedString(string: it.text, attributes: [.font: it.font]).size().width)
            out.append(CGRect(x: x, y: 0, width: w, height: side))
            x += w
        }
        return out
    }

    static func size(for r: Reactions) -> CGSize {
        let s = slots(for: r)
        return CGSize(width: s.count > 1 ? s[s.count - 1].maxX + padX : side, height: side)
    }

    private let frost = FrostView()
    private let ink = Ink()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Dark glass in light mode too, like Messages' tapbacks over a photo.
        frost.appearance = NSAppearance(named: .darkAqua)
        frost.lockMaterial(.hudWindow)
        ink.autoresizingMask = [.width, .height]
        addSubview(frost)
        addSubview(ink)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func configure(_ r: Reactions) {
        let size = Self.size(for: r)
        ink.items = Array(zip(Self.items(r), Self.slots(for: r))).map { (text: $0.0.text, font: $0.0.font, slot: $0.1) }
        ink.frame = bounds
        ink.needsDisplay = true
        frost.shape(Self.shape(CGRect(origin: .zero, size: size)))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        ink.frame = bounds
    }

    /// A circle, or a capsule with the circle's round ends.
    static func shape(_ r: CGRect) -> NSBezierPath {
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
    }

    /// The glass's tint, rim and contents, above the blur.
    private final class Ink: NSView {
        var items: [(text: String, font: NSFont, slot: CGRect)] = []
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            let glass = ReactionBadgeView.shape(bounds.insetBy(dx: 0.5, dy: 0.5))
            NSColor.black.withAlphaComponent(0.32).setFill()
            glass.fill()
            // A faint edge where the glass meets what's behind it, the same for everyone's.
            NSColor.white.withAlphaComponent(0.1).setStroke()
            glass.lineWidth = 1
            glass.stroke()
            for it in items {
                let s = NSAttributedString(string: it.text, attributes: [.font: it.font, .foregroundColor: NSColor.white])
                let sz = s.size()
                s.draw(at: CGPoint(x: it.slot.midX - sz.width / 2, y: it.slot.midY - sz.height / 2))
            }
        }
    }
}

/// Frosted glass: a strong blur of whatever is behind it in the window (the wallpaper,
/// the transcript), dark in dark mode. Clicks pass through to the view it decorates.
final class FrostView: NSVisualEffectView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        blendingMode = .withinWindow
        state = .active
        applyMaterial()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyMaterial()
    }

    private var fixed: NSVisualEffectView.Material?

    /// Pins a material instead of following light and dark.
    func lockMaterial(_ m: NSVisualEffectView.Material) {
        fixed = m
        material = m
    }

    private func applyMaterial() {
        if let fixed { material = fixed; return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        material = dark ? .hudWindow : .popover
    }

    /// Cuts the glass to a shape given in the superview's (flipped) coordinates.
    func shape(_ path: NSBezierPath?) {
        guard let path, !path.isEmpty else { isHidden = true; return }
        let r = path.bounds.insetBy(dx: -1, dy: -1).integral
        frame = r
        let local = path.copy() as! NSBezierPath
        local.transform(using: AffineTransform(translationByX: -r.minX, byY: -r.minY))
        maskImage = NSImage(size: r.size, flipped: true) { _ in
            NSColor.black.setFill()
            local.fill()
            return true
        }
        isHidden = false
    }

    /// A rounded rectangle that stretches (capsules, panels).
    func rounded(_ radius: CGFloat) {
        let d = radius * 2 + 1
        let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { r in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        maskImage = img
    }
}

/// Draws the message itself, above the frosted glass behind the other person's bubbles.
/// Hosts its own layer, redrawn whenever the bubble asks or its size changes.
final class BubbleContentView: NSView {
    private nonisolated final class DrawLayer: CALayer {
        weak var owner: BubbleView?
        /// Drawn on the main thread: the layer never draws asynchronously.
        override func draw(in ctx: CGContext) {
            guard let owner else { return }
            // Message layouts are in flipped (top-down) coordinates.
            if !contentsAreFlipped() {
                ctx.translateBy(x: 0, y: bounds.height)
                ctx.scaleBy(x: 1, y: -1)
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            MainActor.assumeIsolated {
                owner.effectiveAppearance.performAsCurrentDrawingAppearance { owner.drawContent() }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private let drawLayer = DrawLayer()

    init(owner: BubbleView) {
        super.init(frame: .zero)
        drawLayer.owner = owner
        drawLayer.needsDisplayOnBoundsChange = true
        drawLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        // Reused rows jump between messages; the old contents must not animate into the new.
        drawLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer = drawLayer
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func redraw() { drawLayer.setNeedsDisplay() }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let w = window, drawLayer.contentsScale != w.backingScaleFactor {
            drawLayer.contentsScale = w.backingScaleFactor
            redraw()
        }
    }
}

/// Draws one message from its precomputed layout. Layer-backed and redrawn only
/// when its content changes, so scrolling is pure compositing.
final class BubbleView: NSView {
    private let badge = ReactionBadgeView()
    /// The other person's bubble and link card as frosted glass when the chat has a wallpaper.
    private let frost = FrostView()
    private let cardFrost = FrostView()
    private lazy var content = BubbleContentView(owner: self)
    var item: MessageLayout? {
        didSet { itemChanged(from: oldValue) }
    }
    var highlight = false { didSet { if highlight != oldValue { needsDisplay = true } } }
    weak var controller: ConversationViewController?
    /// A video playing in place over this bubble's thumbnail.
    weak var playerView: NSView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        badge.isHidden = true
        frost.isHidden = true
        cardFrost.isHidden = true
        // Reused rows change height without a layout pass: the content must follow the
        // frame itself, or it keeps the old row's size and clips what it draws.
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        [frost, cardFrost, content, badge].forEach(addSubview)
        NotificationCenter.default.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateFrost() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// Everything that marks this view for redraw means its content. Goes by the value
    /// set: this view draws nothing itself, so AppKit reads its own flag back as false.
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            super.needsDisplay = newValue
            if newValue { content.redraw() }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        content.frame = bounds
        updateFrost()
    }

    override func layout() {
        super.layout()
        content.frame = bounds
        updateFrost()
    }

    private func updateFrost() {
        let shapes = Theme.frostsOverWallpaper ? (item?.incomingShapes ?? []) : []
        frost.shape(shapes.first)
        cardFrost.shape(shapes.count > 1 ? shapes[1] : nil)
    }

    private func itemChanged(from old: MessageLayout?) {
        guard let item else { badge.isHidden = true; updateFrost(); return }
        if let p = playerView, let r = item.mediaRect, old?.msg.id == item.msg.id { p.frame = r }
        let sameMessage = old?.msg.id == item.msg.id && old !== item
        // Crossfade content swaps in place; if the geometry moved, a fade would ghost.
        if sameMessage, let old, old.msg != item.msg, old.bubble == item.bubble, old.mediaRect == item.mediaRect {
            Motion.crossfade(content.layer)
        }
        updateFrost()
        needsDisplay = true
        toolTip = Fmt.tooltip(item.msg.date)
        if let rr = item.reactionRect, let r = item.msg.reactions {
            badge.frame = rr
            badge.configure(r)
            let appeared = badge.isHidden || (sameMessage && old?.msg.reactions != r)
            badge.isHidden = false
            if sameMessage && appeared {
                Motion.pop(badge.layer, size: rr.size, from: 0.5, response: 0.35, damping: 0.62)
            }
        } else {
            badge.isHidden = true
        }
        window?.invalidateCursorRects(for: self)
    }

    func drawContent() {
        guard let item else { return }
        let shown = item
        item.draw(highlight: highlight) { [weak self] in
            guard let self, self.item === shown else { return }
            Motion.crossfade(self.content.layer, duration: 0.2)
            self.needsDisplay = true
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let item else { return super.mouseDown(with: event) }
        let p = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, item.contains(p) {
            controller?.reply(to: item.msg)
            return
        }
        switch item.hit(p) {
        case .link(let url): NSWorkspace.shared.open(url)
        case .readMore: controller?.expand(item.msg)
        case .media, .file: controller?.open(media: item.msg)
        case .quote: controller?.jump(to: item.msg.quoteID)
        case .retry: controller?.retry(item.msg)
        case .voice: controller?.toggleVoice(item.msg)
        case .card(let h): controller?.cardAction(item.msg, h, from: self)
        case .none: super.mouseDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let item else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        guard item.contains(p) else { return nil }
        return controller?.menu(for: item.msg)
    }

    override func resetCursorRects() {
        guard let item else { return }
        if let m = item.mediaRect { addCursorRect(m, cursor: .pointingHand) }
        if let c = item.cardRect { addCursorRect(c, cursor: .pointingHand) }
        if let f = item.failedRect { addCursorRect(f, cursor: .pointingHand) }
        for r in item.richClickRects { addCursorRect(r, cursor: .pointingHand) }
    }
}

/// "Today 6:33 PM" between runs, Messages-style.
final class SeparatorView: NSView {
    var date = Date() { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let s = NSMutableAttributedString(string: Fmt.dayLabel(date), attributes: [.font: Theme.smallBold, .foregroundColor: Theme.meta])
        s.append(NSAttributedString(string: " " + Fmt.time(date), attributes: [.font: Theme.small, .foregroundColor: Theme.meta]))
        let sz = s.size()
        let at = CGPoint(x: (bounds.width - sz.width) / 2, y: bounds.height - sz.height - 4)
        Theme.drawChip(behind: CGRect(origin: at, size: sz))
        s.draw(at: at)
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// Divider where unread messages begin.
final class UnreadBarView: NSView {
    var count = 0 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let s = NSAttributedString(string: count == 1 ? "1 Unread Message" : "\(count) Unread Messages",
                                   attributes: [.font: Theme.smallBold, .foregroundColor: Theme.accent])
        let sz = s.size()
        let y = bounds.midY + 2
        let gap: CGFloat = 10
        Theme.accent.withAlphaComponent(0.35).setFill()
        NSRect(x: 20, y: y, width: max(0, (bounds.width - sz.width) / 2 - gap - 20), height: 1).fill()
        NSRect(x: (bounds.width + sz.width) / 2 + gap, y: y, width: max(0, (bounds.width - sz.width) / 2 - gap - 20), height: 1).fill()
        let at = CGPoint(x: (bounds.width - sz.width) / 2, y: y - sz.height / 2)
        Theme.drawChip(behind: CGRect(origin: at, size: sz))
        s.draw(at: at)
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The grey "…" bubble while someone is typing; dots pulse in sequence.
final class TypingBubbleView: NSView {
    private let bubble = CAShapeLayer()
    private let trail = CAShapeLayer()
    private var dots: [CALayer] = []
    static let bubbleRect = CGRect(x: 20, y: 8, width: 58, height: 34)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        guard let layer else { return }
        layer.addSublayer(trail)
        layer.addSublayer(bubble)
        for _ in 0..<3 {
            let d = CALayer()
            d.cornerRadius = 4
            layer.addSublayer(d)
            dots.append(d)
        }
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let b = Self.bubbleRect
        // Layer coordinates follow the view's flipped geometry.
        bubble.path = CGPath(roundedRect: b, cornerWidth: 17, cornerHeight: 17, transform: nil)
        let trailPath = CGMutablePath()
        trailPath.addEllipse(in: CGRect(x: b.minX - 3, y: b.maxY - 9, width: 11, height: 11))
        trailPath.addEllipse(in: CGRect(x: b.minX - 8, y: b.maxY + 1, width: 5, height: 5))
        trail.path = trailPath
        for (i, d) in dots.enumerated() {
            d.frame = CGRect(x: b.minX + 14 + CGFloat(i) * 11, y: b.midY - 4, width: 8, height: 8)
        }
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bubble.fillColor = Theme.bubbleIn.cgColor
            trail.fillColor = Theme.bubbleIn.cgColor
            for d in dots { d.backgroundColor = NSColor.secondaryLabelColor.cgColor }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        startPulse()
    }

    func startPulse() {
        for (i, d) in dots.enumerated() {
            d.removeAnimation(forKey: "pulse")
            if Theme.reduceMotion { d.opacity = 0.7; continue }
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = [0.3, 1, 0.3]
            a.keyTimes = [0, 0.4, 1]
            a.duration = 1.2
            a.repeatCount = .infinity
            a.beginTime = CACurrentMediaTime() + Double(i) * 0.2
            a.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            d.opacity = 0.3
            d.add(a, forKey: "pulse")
        }
    }

    func animateIn() {
        let b = Self.bubbleRect
        if Theme.reduceMotion { Motion.fade(layer); return }
        let s = Theme.spring("transform", response: 0.25, damping: 0.8)
        s.fromValue = Motion.scale(0.85, about: CGPoint(x: b.minX, y: b.maxY))
        s.toValue = CATransform3DIdentity
        layer?.add(s, forKey: "pop")
        Motion.fade(layer, duration: 0.15)
    }
}

/// Transcript rows never show the system selection.
final class PlainRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override var isOpaque: Bool { false }
}

/// Soft fade under the header (toolbar band + name capsule). It uses the canvas's own
/// color, so there's no grey material band and no hard edge; messages dissolve as
/// they pass beneath the name capsule.
final class EdgeBlurView: NSView {
    private let fade = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.addSublayer(fade)
        // Layer space is unflipped: strongest at the top edge, gone at the bottom.
        fade.startPoint = CGPoint(x: 0.5, y: 1)
        fade.endPoint = CGPoint(x: 0.5, y: 0)
        fade.locations = [0, 0.5, 1]
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let c = Theme.canvas
            fade.colors = [c.withAlphaComponent(0.88).cgColor, c.withAlphaComponent(0.6).cgColor, c.withAlphaComponent(0).cgColor]
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = bounds
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
