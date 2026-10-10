import AppKit

/// The little contact card a mention opens: a glass sheet that rises from the bottom of the
/// conversation over a dimmed chat, with the person's photo, name and About, and Message /
/// Contact Info. It follows the pointer when dragged (down to dismiss, a flick is enough;
/// up meets resistance), and a click outside or Esc puts it away.
final class ContactSheet: NSView {
    var onMessage: (() -> Void)?
    var onInfo: (() -> Void)?
    /// Gone (dismissed or chosen): the chat takes the keyboard back.
    var onDismissed: (() -> Void)?

    private let scrim = SheetScrim()
    private let card = NSView()
    private let glass = NSGlassEffectView()
    private let rim = GlassRim()
    private let grabber = NSView()
    private let avatar = AvatarView(frame: .zero)
    private let name = NSTextField(labelWithString: "")
    private let about = NSTextField(wrappingLabelWithString: "")
    private var dismissing = false
    /// The About line takes no room until there's one to show.
    private var aboutCollapsed: NSLayoutConstraint!
    private var drag: (start: CGFloat, offset: CGFloat, samples: [(t: TimeInterval, y: CGFloat)])?

    static let inset: CGFloat = 10
    static let radius: CGFloat = 26

    init(jid: String, name n: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        scrim.onClick = { [weak self] in self?.dismiss() }
        scrim.translatesAutoresizingMaskIntoConstraints = false

        card.wantsLayer = true
        card.translatesAutoresizingMaskIntoConstraints = false
        glass.cornerRadius = Self.radius
        glass.translatesAutoresizingMaskIntoConstraints = false
        rim.radius = Self.radius

        grabber.wantsLayer = true
        grabber.layer?.cornerRadius = 2.5
        grabber.translatesAutoresizingMaskIntoConstraints = false

        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.configure(jid: jid, name: n, isGroup: false, path: Avatars.shared.path(for: jid) ?? "-", px: 128)
        name.stringValue = n
        name.font = .systemFont(ofSize: 19, weight: .semibold)
        name.alignment = .center
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        about.font = .systemFont(ofSize: 13)
        about.textColor = .secondaryLabelColor
        about.alignment = .center
        about.maximumNumberOfLines = 2
        about.lineBreakMode = .byTruncatingTail
        about.translatesAutoresizingMaskIntoConstraints = false

        let message = SheetButton(symbol: "message.fill", title: "Message") { [weak self] in self?.choose(self?.onMessage) }
        let info = SheetButton(symbol: "person.crop.circle", title: "Contact Info") { [weak self] in self?.choose(self?.onInfo) }
        let buttons = NSStackView(views: [message, info])
        buttons.distribution = .fillEqually
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        [grabber, avatar, name, about, buttons].forEach(content.addSubview)
        glass.contentView = content
        [rim, glass].forEach(card.addSubview)
        [scrim, card].forEach(addSubview)

        NSLayoutConstraint.activate([
            scrim.leadingAnchor.constraint(equalTo: leadingAnchor), scrim.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrim.topAnchor.constraint(equalTo: topAnchor), scrim.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.widthAnchor.constraint(equalTo: widthAnchor, constant: -2 * Self.inset).withPriority(.defaultHigh),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset),
            glass.leadingAnchor.constraint(equalTo: card.leadingAnchor), glass.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            glass.topAnchor.constraint(equalTo: card.topAnchor), glass.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            rim.leadingAnchor.constraint(equalTo: card.leadingAnchor), rim.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            rim.topAnchor.constraint(equalTo: card.topAnchor), rim.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            grabber.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            grabber.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            grabber.widthAnchor.constraint(equalToConstant: 36), grabber.heightAnchor.constraint(equalToConstant: 5),
            avatar.topAnchor.constraint(equalTo: grabber.bottomAnchor, constant: 16),
            avatar.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 64), avatar.heightAnchor.constraint(equalToConstant: 64),
            name.topAnchor.constraint(equalTo: avatar.bottomAnchor, constant: 10),
            name.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            name.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            about.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 3),
            about.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            about.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            buttons.topAnchor.constraint(equalTo: about.bottomAnchor, constant: 16),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        aboutCollapsed = about.heightAnchor.constraint(equalToConstant: 0)
        aboutCollapsed.isActive = true
        setAccessibilityRole(.group)
        setAccessibilityLabel(n)
    }

    override func layout() {
        super.layout()
        about.preferredMaxLayoutWidth = max(0, card.frame.width - 48)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Their About, when the profile lookup lands (" " means none).
    func setAbout(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, about.stringValue != t, !dismissing else { return }
        about.alphaValue = 0
        about.stringValue = t
        aboutCollapsed.isActive = false
        // The card grows up to make room, then the line fades in.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = Theme.easeOut
            ctx.allowsImplicitAnimation = true
            layoutSubtreeIfNeeded()
            about.animator().alphaValue = 1
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            grabber.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.22).cgColor
        }
    }

    // MARK: presenting

    /// Rises from below the pane: critically damped (a click has no momentum to overshoot
    /// with), while the chat dims. Reduce Motion fades it instead.
    func present(in host: NSView) {
        host.addSubview(self)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: host.safeAreaLayoutGuide.leadingAnchor),
            trailingAnchor.constraint(equalTo: host.trailingAnchor),
            topAnchor.constraint(equalTo: host.topAnchor),
            bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        viewDidChangeEffectiveAppearance()
        host.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(self)
        scrim.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = Theme.easeOut
            scrim.animator().alphaValue = 1
        }
        guard let l = card.layer else { return }
        if Theme.reduceMotion {
            card.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                card.animator().alphaValue = 1
            }
            return
        }
        let rise = Theme.spring("transform", response: 0.36, damping: 1)
        rise.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0, -offscreen, 0))
        rise.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        l.add(rise, forKey: "rise")
    }

    /// Back down the way it came, faster than it rose.
    func dismiss(fromOffset start: CGFloat = 0) {
        guard !dismissing else { return }
        dismissing = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = Theme.easeOut
            scrim.animator().alphaValue = 0
            if Theme.reduceMotion { card.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.removeFromSuperview()
                self?.onDismissed?()
            }
        })
        guard !Theme.reduceMotion, let l = card.layer else { return }
        CATransaction.begin()
        let fall = CABasicAnimation(keyPath: "transform")
        fall.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0, -start, 0))
        fall.toValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0, -offscreen, 0))
        fall.duration = 0.2
        fall.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
        fall.fillMode = .forwards
        fall.isRemovedOnCompletion = false
        l.transform = CATransform3DMakeTranslation(0, -offscreen, 0)
        l.add(fall, forKey: "fall")
        CATransaction.commit()
    }

    private var offscreen: CGFloat { card.frame.height + Self.inset + 8 }

    private func choose(_ action: (() -> Void)?) {
        dismiss()
        action?()
    }

    // MARK: keys and dragging

    override var acceptsFirstResponder: Bool { true }
    override func cancelOperation(_ sender: Any?) { dismiss() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { dismiss() } else { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard card.frame.contains(p), !dismissing else { return super.mouseDown(with: event) }
        card.layer?.removeAllAnimations()
        drag = (p.y, 0, [(event.timestamp, p.y)])
    }

    override func mouseDragged(with event: NSEvent) {
        guard var d = drag else { return }
        let y = convert(event.locationInWindow, from: nil).y
        // Down follows the pointer 1:1; up resists more the further it goes.
        let raw = d.start - y
        d.offset = raw >= 0 ? raw : -Self.rubber(-raw, limit: card.frame.height)
        d.samples.append((event.timestamp, y))
        d.samples = Array(d.samples.suffix(5))
        drag = d
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.layer?.transform = CATransform3DMakeTranslation(0, -d.offset, 0)
        CATransaction.commit()
        scrim.alphaValue = 1 - min(1, max(0, d.offset) / max(card.frame.height, 1)) * 0.7
    }

    override func mouseUp(with event: NSEvent) {
        guard let d = drag else { return }
        drag = nil
        // Points per second downward over the last few events: a flick dismisses at any distance.
        var velocity: CGFloat = 0
        if let first = d.samples.first, let last = d.samples.last, last.t > first.t {
            velocity = (first.y - last.y) / CGFloat(last.t - first.t)
        }
        if d.offset > card.frame.height * 0.3 || velocity > 600 {
            dismiss(fromOffset: d.offset)
            return
        }
        guard let l = card.layer else { return }
        let back = Theme.spring("transform", response: 0.32, damping: 0.86)
        back.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0, -d.offset, 0))
        back.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.transform = CATransform3DIdentity
        CATransaction.commit()
        l.add(back, forKey: "back")
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            scrim.animator().alphaValue = 1
        }
    }

    /// Apple's rubber band: the further past the edge, the less it follows.
    static func rubber(_ overshoot: CGFloat, limit: CGFloat, c: CGFloat = 0.55) -> CGFloat {
        (overshoot * limit * c) / (limit + c * overshoot)
    }
}

/// The dimmed chat behind the sheet; a click on it puts the sheet away.
private final class SheetScrim: NSView {
    var onClick: (() -> Void)?
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = NSColor.black.withAlphaComponent(dark ? 0.32 : 0.16).cgColor
    }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func scrollWheel(with event: NSEvent) {}   // the chat stays put behind it
}

/// A wide sheet button: the glyph over its label on a faint fill; it gives under the pointer.
private final class SheetButton: NSView {
    private let action: () -> Void
    private let fill = NSView()
    private var pressed = false { didSet { press() } }

    init(symbol: String, title: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 14
        fill.layer?.cornerCurve = .continuous
        fill.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .medium)) ?? NSImage())
        icon.contentTintColor = Theme.accent
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        [fill, icon, label].forEach(addSubview)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 58),
            fill.leadingAnchor.constraint(equalTo: leadingAnchor), fill.trailingAnchor.constraint(equalTo: trailingAnchor),
            fill.topAnchor.constraint(equalTo: topAnchor), fill.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        tint()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tint()
    }

    private func tint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fill.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(pressed ? 0.12 : 0.07).cgColor
        }
    }

    private func press() {
        tint()
        // Gives a little on press, instantly; settles back on release.
        guard let l = layer, !Theme.reduceMotion else { return }
        let b = l.bounds
        var t = CATransform3DMakeTranslation(b.width * 0.015, b.height * 0.015, 0)
        t = CATransform3DScale(t, 0.97, 0.97, 1)
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = l.presentation()?.transform ?? l.transform
        a.toValue = pressed ? t : CATransform3DIdentity
        a.duration = pressed ? 0.1 : 0.16
        a.timingFunction = Theme.easeOut
        l.transform = pressed ? t : CATransform3DIdentity
        l.add(a, forKey: "press")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseDragged(with event: NSEvent) { pressed = bounds.contains(convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { action() }
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ p: NSLayoutConstraint.Priority) -> NSLayoutConstraint { priority = p; return self }
}

extension ConversationViewController {
    /// A mention in a bubble: that person's card, rising from the bottom of the chat.
    func showContactSheet(_ jid: String) {
        contactSheet?.removeFromSuperview()
        let sheet = ContactSheet(jid: jid, name: jid == Core.shared.me ? "You" : store.name(jid))
        sheet.onMessage = { [weak self] in self?.openPerson(jid, info: false) }
        sheet.onInfo = { [weak self] in self?.openPerson(jid, info: true) }
        sheet.onDismissed = { [weak self] in self?.composer.focus() }
        contactSheet = sheet
        sheet.present(in: view)
        Task { [weak sheet] in
            let info = await Core.shared.callAsync("profile", ["chat": jid])
            if let about = info["about"] as? String { sheet?.setAbout(about) }
        }
    }
}
