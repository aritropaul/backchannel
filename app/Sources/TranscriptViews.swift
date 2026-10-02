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

/// Tapback capsule that sits on a bubble's top corner.
final class ReactionBadgeView: NSView {
    private var label = ""
    private var mine = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func configure(_ r: Reactions) {
        label = r.total > 1 ? "\(r.emoji) \(r.total)" : r.emoji
        mine = !r.mine.isEmpty
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let p = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        (mine ? Theme.accent : Theme.bubbleIn).setFill()
        p.fill()
        Theme.canvas.setStroke()
        p.lineWidth = 2
        p.stroke()
        let s = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 13),
                                                               .foregroundColor: mine ? NSColor.white : NSColor.labelColor])
        let sz = s.size()
        s.draw(at: CGPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2))
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// Draws one message from its precomputed layout. Layer-backed and redrawn only
/// when its content changes, so scrolling is pure compositing.
final class BubbleView: NSView {
    private let badge = ReactionBadgeView()
    var item: MessageLayout? {
        didSet { itemChanged(from: oldValue) }
    }
    var highlight = false { didSet { if highlight != oldValue { needsDisplay = true } } }
    weak var controller: ConversationViewController?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        badge.isHidden = true
        addSubview(badge)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    private func itemChanged(from old: MessageLayout?) {
        guard let item else { badge.isHidden = true; return }
        let sameMessage = old?.msg.id == item.msg.id && old !== item
        // Crossfade content swaps in place; if the geometry moved, a fade would ghost.
        if sameMessage, let old, old.msg != item.msg, old.bubble == item.bubble, old.mediaRect == item.mediaRect {
            Motion.crossfade(layer)
        }
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

    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        let shown = item
        item.draw(highlight: highlight) { [weak self] in
            guard let self, self.item === shown else { return }
            Motion.crossfade(self.layer, duration: 0.2)
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
        s.draw(at: CGPoint(x: (bounds.width - sz.width) / 2, y: bounds.height - sz.height - 4))
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
        s.draw(at: CGPoint(x: (bounds.width - sz.width) / 2, y: y - sz.height / 2))
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
