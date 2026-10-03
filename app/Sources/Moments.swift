import AppKit
import QuartzCore

/// Trackpad haptics, kept to two meanings so they stay legible: `arm` when a pull or a
/// swipe crosses the point where letting go will act, `snap` when something lands or
/// locks into place. They're only felt while a finger is on a Force Touch trackpad.
enum Haptic {
    static func arm() { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
    static func snap() { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
}

extension Motion {
    /// Dev: `WA_SLOWMO=<n>` slows the window's layer animations n× (AppDelegate); this
    /// stretches the display-linked motion to match.
    static let slow: Double = ProcessInfo.processInfo.environment["WA_SLOWMO"].flatMap(Double.init).map { max(1, $0) } ?? 1

    /// WhatsApp's beating heart: a lone heart sent or received live beats twice
    /// (lub-dub, lub-dub, the second softer) once it has risen into place.
    static func heartbeat(_ layer: CALayer?, about p: CGPoint, delay: Double) {
        guard let layer, !Theme.reduceMotion else { return }
        let a = CAKeyframeAnimation(keyPath: "transform")
        a.values = [1, 1.2, 1, 1.1, 1, 1.12, 1, 1.05, 1].map { NSValue(caTransform3D: scale($0, about: p)) }
        a.keyTimes = [0, 0.11, 0.24, 0.33, 0.48, 0.59, 0.72, 0.81, 1]
        a.timingFunctions = Array(repeating: CAMediaTimingFunction(controlPoints: 0.3, 0, 0.3, 1), count: 8)
        a.duration = 1.3
        // Composes with the rise that's still settling instead of cutting it off.
        a.isAdditive = true
        // In the layer's own time, which runs apart from the media clock under a slowed tree.
        a.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        layer.add(a, forKey: "heartbeat")
    }

    static func isHeart(_ text: String) -> Bool {
        hearts.contains(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static let hearts: Set<String> = [
        "❤️", "❤", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎", "🩷", "🩵", "🩶", "♥️",
        "❤️‍🔥", "❤️‍🩹", "💖", "💗", "💓", "💞", "💕", "💘", "💝",
    ]

    /// A new unread dot springs in rather than appearing: a chat just got a message.
    static func popDot(_ dot: NSView) {
        guard dot.bounds.width > 0 else { return }
        pop(dot.layer, size: dot.bounds.size, from: 0.3, response: 0.38, damping: 0.55)
    }

    /// A quick "here it is" for a message something pointed at (a quote, a search result):
    /// it swells a few percent and springs back.
    static func nudge(_ layer: CALayer?, about p: CGPoint) {
        guard let layer, !Theme.reduceMotion else { return }
        let s = Theme.spring("transform", response: 0.42, damping: 0.5)
        s.fromValue = scale(1.05, about: p)
        s.toValue = CATransform3DIdentity
        layer.add(s, forKey: "nudge")
    }
}

/// A reaction picked in the message menu lifts out of its cell and arcs onto the bubble's
/// corner, where the badge lands with a tick. The landing spot is looked up every frame,
/// so once the reaction's echo has laid the row out again the emoji homes in on where the
/// badge really is, however the transcript moved.
final class ReactionFlight: NSObject {
    private static var flying: Set<ReactionFlight> = []
    private static var duration: Double { 0.48 * Motion.slow }
    /// Dev (`WA_MOMENTS`): logs where each flight ended and what it was aiming at.
    static var logLandings = false
    /// The iOS drawer curve: a quick lift out of the menu, a soft arrival.
    private static let ease = CubicBezier(0.32, 0.72, 0, 1)
    /// The emoji is drawn once this large and scaled down, so it stays sharp all the way.
    private static let drawSize: CGFloat = 64

    private let panel: NSPanel
    private let glyph = CALayer()
    private let start: CGPoint
    private let startScale: CGFloat
    private let endScale: CGFloat
    private let target: () -> CGRect?
    private let landed: () -> Void
    private var end: CGPoint
    private var link: CADisplayLink?
    private var began: CFTimeInterval = 0

    /// `from` is the picked cell in screen coordinates, drawn at `size` points; `target`
    /// returns the badge circle it lands in (screen coordinates), or nil once that's gone.
    static func fly(_ emoji: String, from: CGRect, size: CGFloat, over window: NSWindow,
                    to target: @escaping () -> CGRect?, landed: @escaping () -> Void) {
        let f = ReactionFlight(emoji, from: from, size: size, screen: window.screen ?? NSScreen.main, target: target, landed: landed)
        flying.insert(f)
        f.run()
    }

    private init(_ emoji: String, from: CGRect, size: CGFloat, screen: NSScreen?, target: @escaping () -> CGRect?, landed: @escaping () -> Void) {
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1, height: 1)
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        start = CGPoint(x: from.midX, y: from.midY)
        end = start
        startScale = size / Self.drawSize
        // Lands a little larger than the badge's 12pt emoji; the badge settles from there.
        endScale = 12 * 1.3 / Self.drawSize
        self.target = target
        self.landed = landed
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
        let host = NSView(frame: NSRect(origin: .zero, size: frame.size))
        host.wantsLayer = true
        panel.contentView = host

        let font = NSFont(name: "Apple Color Emoji", size: Self.drawSize) ?? .systemFont(ofSize: Self.drawSize)
        let s = NSAttributedString(string: emoji, attributes: [.font: font])
        let sz = s.size()
        let scale = screen?.backingScaleFactor ?? 2
        let image = NSImage(size: sz, flipped: false) { _ in s.draw(at: .zero); return true }
        glyph.contents = image.layerContents(forContentsScale: scale)
        glyph.contentsScale = scale
        glyph.bounds = CGRect(origin: .zero, size: sz)
        // Lifted off the window: a soft shadow under the emoji while it's in the air.
        glyph.shadowColor = NSColor.black.cgColor
        glyph.shadowOpacity = 0.22
        glyph.shadowRadius = 6
        glyph.shadowOffset = CGSize(width: 0, height: -3)
        host.layer?.addSublayer(glyph)
        place(start, scale: startScale)
    }

    private func run() {
        panel.orderFrontRegardless()
        began = CACurrentMediaTime()
        let l = panel.contentView!.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func place(_ p: CGPoint, scale k: CGFloat) {
        let o = panel.frame.origin
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyph.position = CGPoint(x: p.x - o.x, y: p.y - o.y)
        glyph.transform = CATransform3DMakeScale(k, k, 1)
        CATransaction.commit()
    }

    @objc private func tick(_ l: CADisplayLink) {
        let raw = min(1, (CACurrentMediaTime() - began) / Self.duration)
        let e = CGFloat(Self.ease.value(at: raw))
        if let t = target() { end = CGPoint(x: t.midX, y: t.midY) }
        // A toss: a quadratic arc whose control point sits above the higher end.
        let lift = min(90, max(36, hypot(end.x - start.x, end.y - start.y) * 0.3))
        let c = CGPoint(x: (start.x + end.x) / 2, y: max(start.y, end.y) + lift)
        let u = 1 - e
        let p = CGPoint(x: u * u * start.x + 2 * u * e * c.x + e * e * end.x,
                        y: u * u * start.y + 2 * u * e * c.y + e * e * end.y)
        place(p, scale: startScale + (endScale - startScale) * e)
        guard raw >= 1 else { return }
        l.invalidate()
        link = nil
        if Self.logLandings {
            NSLog("WA flight: from %@ landed at %@, target %@", NSStringFromPoint(start), NSStringFromPoint(p),
                  target().map { NSStringFromRect($0) } ?? "none")
        }
        landed()
        // The badge takes over on this frame; the emoji in the air hands off to it.
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.1
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panel.orderOut(nil)
                Self.flying.remove(self)
            }
        }
        glyph.opacity = 0
        glyph.add(fade, forKey: "out")
        CATransaction.commit()
    }
}

/// The Archived pull's progress: an archive box in a ring that fills with the fingers'
/// travel, riding in the gap the rubber band opens above the list. It completes and turns
/// the accent as the pull arms (with the haptic tick), so a pull says what letting go will
/// do before it does it.
final class PullIndicator: NSView {
    static let side: CGFloat = 26
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private let icon = CALayer()
    private var armed = false

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        wantsLayer = true
        alphaValue = 0
        for l in [track, arc] {
            l.fillColor = nil
            l.lineWidth = 2
            l.lineCap = .round
            layer?.addSublayer(l)
        }
        arc.strokeEnd = 0
        icon.contentsGravity = .center
        layer?.addSublayer(icon)
        layoutLayers()
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func layoutLayers() {
        let b = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        let c = CGPoint(x: b.midX, y: b.midY)
        // From twelve o'clock, clockwise (layer space is y-up).
        let path = CGMutablePath()
        path.addArc(center: c, radius: Self.side / 2 - 1.5, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [track, arc] {
            l.frame = b
            l.path = path
        }
        icon.frame = b
        CATransaction.commit()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.strokeColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.35).cgColor
            arc.strokeColor = (armed ? Theme.accent : NSColor.secondaryLabelColor).cgColor
            let tint = armed ? Theme.accent : NSColor.secondaryLabelColor
            let symbol = NSImage(systemSymbolName: armed ? "archivebox.fill" : "archivebox", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold).applying(.init(paletteColors: [tint])))
            let scale = window?.backingScaleFactor ?? 2
            icon.contents = symbol?.layerContents(forContentsScale: scale)
            icon.contentsScale = scale
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// `stretch` is how far the list is pulled past its top (the gap this sits in),
    /// `progress` the share of the travel that arms the pull.
    func update(stretch: CGFloat, progress: CGFloat, armed: Bool) {
        let shown = min(1, max(0, (stretch - 6) / 10))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        alphaValue = shown
        arc.strokeEnd = armed ? 1 : min(1, max(0, progress))
        CATransaction.commit()
        guard armed != self.armed else { return }
        self.armed = armed
        applyColors()
        // Arming clicks: the ring swells and springs back on the tick's frame.
        guard armed, let layer, !Theme.reduceMotion else { return }
        let s = Theme.spring("transform", response: 0.32, damping: 0.5)
        s.fromValue = Motion.scale(1.25, in: bounds.size)
        s.toValue = CATransform3DIdentity
        layer.add(s, forKey: "arm")
    }
}
