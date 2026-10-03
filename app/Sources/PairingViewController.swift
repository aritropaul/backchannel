import AppKit

/// First run: link this Mac as a companion device by QR (or phone-number code).
///
/// Opens with `PairingIntro`: the screen frosts over with a green glow that flows into this
/// window. The window is frosted and see-through too, tinted by the same green light
/// (`AuroraView`), and holds almost nothing: the code on a porcelain tile, one line of what
/// to do, where to find it on the phone, and a quiet way to use a phone number instead.
/// When the phone links, the tile turns into a check and the scene dissolves into the chats.
final class PairingViewController: NSViewController {
    private enum Mode { case qr, phone }

    static let porcelain = NSColor(hex: 0xF4F8F5)
    static let celadon = NSColor(hex: 0x97CCB3)
    static let ink = NSColor(hex: 0x0E1A16)

    private let aurora = AuroraView()
    private let card = PairingCard()
    private let line = NSTextField(labelWithString: "")
    private let path = NSTextField(labelWithString: "")
    private let modeToggle = NSButton(title: "", target: nil, action: nil)
    private let disclaimer = NSTextField(labelWithString: Brand.disclaimer)
    private var mode = Mode.qr
    private var entered = false
    private(set) var isCelebrating = false
    /// Set when `PairingIntro` has already brought the light up, so the window doesn't bloom it again.
    var lightIsUp = false

    override func loadView() {
        // The desktop behind, frosted. The aurora on top tints it green rather than hiding it.
        let v = NSVisualEffectView()
        v.material = .fullScreenUI
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        view = v

        aurora.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(aurora)

        card.onReload = { [weak self] in self?.reload() }
        card.onRequestCode = { [weak self] phone in self?.requestCode(phone) }

        line.font = .systemFont(ofSize: 15, weight: .medium)
        line.textColor = Self.porcelain.withAlphaComponent(0.92)
        line.alignment = .center
        line.setAccessibilityRole(.staticText)
        path.font = .systemFont(ofSize: 13)
        path.textColor = Self.porcelain.withAlphaComponent(0.56)
        path.alignment = .center

        modeToggle.isBordered = false
        modeToggle.target = self
        modeToggle.action = #selector(toggleMode)
        modeToggle.setButtonType(.momentaryChange)
        setToggleTitle("Use phone number instead")

        disclaimer.font = .systemFont(ofSize: 11)
        disclaimer.textColor = Self.porcelain.withAlphaComponent(0.36)
        disclaimer.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(disclaimer)

        let stack = NSStackView(views: [card, line, path, modeToggle])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 0
        stack.setCustomSpacing(30, after: card)
        stack.setCustomSpacing(6, after: line)
        stack.setCustomSpacing(26, after: path)
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)

        NSLayoutConstraint.activate([
            aurora.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            aurora.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            aurora.topAnchor.constraint(equalTo: v.topAnchor),
            aurora.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: v.centerYAnchor, constant: 10),
            disclaimer.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            disclaimer.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -18),
        ])
        say("Getting a code…", path: Self.qrPath)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !entered else { return }
        entered = true
        enter()
    }

    private static let qrPath = "WhatsApp › Linked devices › Link a device"
    private static let phonePath = "Link a device › Link with phone number instead"

    // MARK: - Core events

    func show(qr code: String) {
        guard !isCelebrating else { return }
        card.show(code: code)
        if mode == .qr { say("Scan with WhatsApp on your phone", path: Self.qrPath) }
    }

    func show(state: String, message: String?) {
        guard !isCelebrating else { return }
        switch state {
        case "qr_timeout":
            card.expire()
            say("This code expired", path: Self.qrPath)
        case "pair_error":
            card.expire()
            say(message.map { "Couldn't link: \($0)" } ?? "Couldn't link. Try a new code.", path: Self.qrPath)
        case "offline":
            card.expire()
            say("Can't reach WhatsApp. Check your connection.", path: Self.qrPath)
        default: break
        }
    }

    @objc private func reload() {
        say("Getting a code…", path: Self.qrPath)
        card.showPlaceholder()
        Core.shared.call("repair")
    }

    // MARK: - Phone number

    @objc private func toggleMode() {
        guard !isCelebrating else { return }
        mode = mode == .qr ? .phone : .qr
        let phone = mode == .phone
        card.flip(toPhone: phone)
        setToggleTitle(phone ? "Use QR code instead" : "Use phone number instead")
        if phone {
            say("Enter your number to get a code", path: Self.phonePath)
        } else {
            say(card.hasCode ? "Scan with WhatsApp on your phone" : "Getting a code…", path: Self.qrPath)
        }
    }

    private func requestCode(_ phone: String) {
        say("Getting a code…", path: Self.phonePath)
        // Let the line draw before the (synchronous) request.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let res = Core.shared.call("pair_phone", ["phone": phone])
            if let code = res["code"] as? String, !code.isEmpty {
                card.showPhoneCode(code)
                say("Enter this code in WhatsApp on your phone", path: Self.phonePath)
            } else {
                let why = (res["error"] as? String).map { "Couldn't get a code: \($0)" } ?? "Couldn't get a code."
                card.showPhoneError(why)
                say("Check the number, including the country code", path: Self.phonePath)
            }
        }
    }

    // MARK: - Linked

    /// The phone linked: the tile turns into a check, the light lifts, and after a beat
    /// `then` swaps in the chats.
    func celebrate(then done: @escaping () -> Void) {
        guard !isCelebrating else { return }
        isCelebrating = true
        view.window?.makeFirstResponder(nil)
        say("Linked. Loading your chats…", path: "")
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = Theme.easeOut
            modeToggle.animator().alphaValue = 0
        }
        card.celebrate()
        aurora.brighten()
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "Linked. Loading your chats.", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        DispatchQueue.main.asyncAfter(deadline: .now() + (Theme.reduceMotion ? 0.9 : 1.4), execute: done)
    }

    /// Fades the scene out over whatever replaced it as the window's content.
    func dissolve(over host: NSView) {
        let v = view
        v.removeFromSuperview()
        v.frame = host.bounds
        v.autoresizingMask = [.width, .height]
        host.addSubview(v)
        guard let l = v.layer else { v.removeFromSuperview(); return }
        let reduce = Theme.reduceMotion
        CATransaction.begin()
        CATransaction.setCompletionBlock { v.removeFromSuperview() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = reduce ? 0.25 : 0.55
        fade.timingFunction = Theme.easeOut
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        l.add(fade, forKey: "dissolve")
        if !reduce {
            let grow = CABasicAnimation(keyPath: "transform")
            grow.fromValue = CATransform3DIdentity
            grow.toValue = Motion.scale(1.04, in: v.bounds.size)
            grow.duration = 0.55
            grow.timingFunction = Theme.easeOut
            grow.fillMode = .forwards
            grow.isRemovedOnCompletion = false
            l.add(grow, forKey: "grow")
        }
        CATransaction.commit()
    }

    // MARK: - Entrance

    /// The tile rises into the light and comes into focus; the words follow.
    private func enter() {
        let reduce = Theme.reduceMotion
        if !lightIsUp { aurora.bloom() }
        let parts: [(NSView, Double, CGFloat, CGFloat)] = [   // view, delay, rise, start scale
            (card, 0.05, 22, 0.95), (line, 0.22, 8, 1), (path, 0.28, 6, 1), (modeToggle, 0.34, 6, 1),
        ]
        for (v, delay, dy, scale) in parts {
            if reduce { fadeIn(v, delay: delay * 0.5, duration: 0.2); continue }
            rise(v, delay: delay, by: dy, scale: scale)
        }
        fadeIn(disclaimer, delay: reduce ? 0 : 0.5, duration: 0.5)
    }

    private func fadeIn(_ v: NSView, delay: Double, duration: Double) {
        v.wantsLayer = true
        guard let l = v.layer else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0
        a.toValue = 1
        a.duration = duration
        a.beginTime = CACurrentMediaTime() + delay
        a.fillMode = .backwards
        a.timingFunction = Theme.easeOut
        l.add(a, forKey: "enterFade")
    }

    private func rise(_ v: NSView, delay: Double, by dy: CGFloat, scale: CGFloat) {
        v.wantsLayer = true
        v.layerUsesCoreImageFilters = true
        guard let l = v.layer else { return }
        let begin = CACurrentMediaTime() + delay
        let move = Theme.spring("transform", response: scale < 1 ? 0.75 : 0.6, damping: scale < 1 ? 0.86 : 1)
        var from = CATransform3DMakeTranslation(0, -dy, 0)
        if scale < 1 { from = CATransform3DConcat(Motion.scale(scale, in: v.bounds.size), from) }
        move.fromValue = from
        move.toValue = CATransform3DIdentity
        move.beginTime = begin
        move.fillMode = .backwards
        l.add(move, forKey: "enterMove")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.45
        fade.beginTime = begin
        fade.fillMode = .backwards
        fade.timingFunction = Theme.easeOut
        l.add(fade, forKey: "enterFade")
        // Blur resolves as it lands, so each part comes into focus rather than popping.
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.name = "enterBlur"
            blur.setValue(0, forKey: kCIInputRadiusKey)
            l.filters = [blur]
            let b = CABasicAnimation(keyPath: "filters.enterBlur.inputRadius")
            b.fromValue = 8
            b.toValue = 0
            b.duration = 0.5
            b.beginTime = begin
            b.fillMode = .backwards
            b.timingFunction = Theme.easeOut
            l.add(b, forKey: "enterBlur")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.6) { l.filters = nil }
        }
    }

    // MARK: - Helpers

    /// The one line of status, and where to go on the phone under it.
    private func say(_ text: String, path p: String) {
        if line.stringValue != text, !line.stringValue.isEmpty {
            line.wantsLayer = true
            Motion.crossfade(line.layer, duration: 0.2)
        }
        if path.stringValue != p, !path.stringValue.isEmpty {
            path.wantsLayer = true
            Motion.crossfade(path.layer, duration: 0.2)
        }
        line.stringValue = text
        path.stringValue = p
        line.setAccessibilityLabel(text)
    }

    private func setToggleTitle(_ s: String) {
        let c = Self.porcelain.withAlphaComponent(0.62)
        modeToggle.attributedTitle = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: c])
        modeToggle.attributedAlternateTitle = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: c.withAlphaComponent(0.35)])
    }
}

// MARK: - Card

/// The porcelain tile: the QR code on the front, linking by phone number on the back.
final class PairingCard: NSView {
    static let side: CGFloat = 264
    static let qrSide: CGFloat = 224
    var onReload: (() -> Void)?
    var onRequestCode: ((String) -> Void)?
    private(set) var hasCode = false

    private let face = NSView()
    private let front = NSView()
    private let back = NSView()
    private let qr = NSImageView()
    private let reloadButton = NSButton(title: "Get a New Code", target: nil, action: nil)
    private let expiredStack = NSStackView()
    private let check = CAShapeLayer()
    private var showingPhone = false

    private let phoneTitle = NSTextField(labelWithString: "Link with your number")
    private let phoneNote = NSTextField(wrappingLabelWithString: "")
    private let phoneField = NSTextField()
    private let getCode = NSButton(title: "Get Code", target: nil, action: nil)
    private let codeLabel = NSTextField(labelWithString: "")
    private let changeNumber = NSButton(title: "Use a different number", target: nil, action: nil)
    private let entryStack = NSStackView()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        translatesAutoresizingMaskIntoConstraints = false
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        let l = layer!
        l.cornerRadius = 24
        l.cornerCurve = .continuous
        l.backgroundColor = PairingViewController.porcelain.cgColor
        l.shadowColor = NSColor.black.cgColor
        l.shadowOpacity = 0.32
        l.shadowRadius = 30
        l.shadowOffset = CGSize(width: 0, height: -12)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
        ])

        for v in [front, back] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
                v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        back.isHidden = true

        // Front: the code, and what to do when it's no longer good.
        qr.imageScaling = .scaleProportionallyUpOrDown
        qr.translatesAutoresizingMaskIntoConstraints = false
        qr.wantsLayer = true
        qr.layerUsesCoreImageFilters = true
        qr.setAccessibilityLabel("Pairing QR code. Scan it with WhatsApp on your phone.")
        front.addSubview(qr)

        reloadButton.bezelStyle = .glass
        reloadButton.controlSize = .large
        reloadButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        reloadButton.imagePosition = .imageLeading
        reloadButton.target = self
        reloadButton.action = #selector(reload)
        expiredStack.setViews([reloadButton], in: .center)
        expiredStack.orientation = .vertical
        expiredStack.spacing = 12
        expiredStack.translatesAutoresizingMaskIntoConstraints = false
        expiredStack.isHidden = true
        front.addSubview(expiredStack)

        NSLayoutConstraint.activate([
            qr.centerXAnchor.constraint(equalTo: front.centerXAnchor),
            qr.centerYAnchor.constraint(equalTo: front.centerYAnchor),
            qr.widthAnchor.constraint(equalToConstant: Self.qrSide),
            qr.heightAnchor.constraint(equalToConstant: Self.qrSide),
            expiredStack.centerXAnchor.constraint(equalTo: front.centerXAnchor),
            expiredStack.centerYAnchor.constraint(equalTo: front.centerYAnchor),
        ])

        // Back: a number in, a code out.
        phoneTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        phoneTitle.textColor = PairingViewController.ink
        phoneNote.font = .systemFont(ofSize: 12.5)
        phoneNote.textColor = NSColor(hex: 0x0E1A16, alpha: 0.6)
        phoneNote.alignment = .center
        phoneNote.preferredMaxLayoutWidth = 236
        phoneField.placeholderString = "+1 555 123 4567"
        phoneField.font = .systemFont(ofSize: 16)
        phoneField.alignment = .center
        phoneField.bezelStyle = .roundedBezel
        phoneField.controlSize = .large
        phoneField.widthAnchor.constraint(equalToConstant: 236).isActive = true
        phoneField.target = self
        phoneField.action = #selector(requestCode)
        phoneField.setAccessibilityLabel("Phone number with country code")
        getCode.bezelStyle = .glass
        getCode.controlSize = .large
        getCode.keyEquivalent = "\r"
        getCode.target = self
        getCode.action = #selector(requestCode)
        codeLabel.font = .monospacedSystemFont(ofSize: 34, weight: .semibold)
        codeLabel.textColor = PairingViewController.ink
        codeLabel.isSelectable = true
        codeLabel.isHidden = true
        changeNumber.isBordered = false
        changeNumber.attributedTitle = NSAttributedString(string: changeNumber.title, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: NSColor(hex: 0x2F7A5B)])
        changeNumber.target = self
        changeNumber.action = #selector(differentNumber)
        changeNumber.isHidden = true
        entryStack.setViews([phoneTitle, phoneNote, phoneField, codeLabel, getCode, changeNumber], in: .center)
        entryStack.orientation = .vertical
        entryStack.spacing = 10
        entryStack.setCustomSpacing(18, after: phoneNote)
        entryStack.setCustomSpacing(16, after: phoneField)
        entryStack.setCustomSpacing(16, after: codeLabel)
        entryStack.translatesAutoresizingMaskIntoConstraints = false
        back.addSubview(entryStack)
        NSLayoutConstraint.activate([
            entryStack.centerXAnchor.constraint(equalTo: back.centerXAnchor),
            entryStack.centerYAnchor.constraint(equalTo: back.centerYAnchor),
        ])
        resetPhone()

        check.fillColor = nil
        check.strokeColor = PairingViewController.ink.cgColor
        check.lineWidth = 10
        check.lineCap = .round
        check.lineJoin = .round
        check.strokeEnd = 0
        l.addSublayer(check)

        showPlaceholder()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 24, cornerHeight: 24, transform: nil)
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: c.x - 33, y: c.y + 2))
        p.addLine(to: CGPoint(x: c.x - 10, y: c.y - 22))
        p.addLine(to: CGPoint(x: c.x + 37, y: c.y + 26))
        check.frame = bounds
        check.path = p
    }

    // MARK: QR side

    func show(code: String) {
        let first = !hasCode
        hasCode = true
        expiredStack.isHidden = true
        qr.layer?.removeAnimation(forKey: "loading")
        qr.layer?.filters = nil
        qr.alphaValue = 1
        qr.image = PairingQR.image(code, side: Self.qrSide, ink: PairingViewController.ink, mark: NSApp.applicationIconImage)
        guard let l = qr.layer, !showingPhone else { return }
        if Theme.reduceMotion || first {
            Motion.crossfade(l, duration: first ? 0.35 : 0.2)
        } else {
            // A fresh code develops in: a soft blur that resolves, so the swap reads as one code.
            Motion.crossfade(l, duration: 0.35)
            if let blur = CIFilter(name: "CIGaussianBlur") {
                blur.name = "dev"
                blur.setValue(0, forKey: kCIInputRadiusKey)
                l.filters = [blur]
                let b = CABasicAnimation(keyPath: "filters.dev.inputRadius")
                b.fromValue = 5
                b.toValue = 0
                b.duration = 0.4
                b.timingFunction = Theme.easeOut
                l.add(b, forKey: "develop")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak l] in l?.filters = nil }
            }
        }
    }

    /// Before the first code: a faint code that breathes, so the card isn't an empty box.
    func showPlaceholder() {
        hasCode = false
        expiredStack.isHidden = true
        qr.layer?.filters = nil
        qr.image = PairingQR.image(Self.sampleCode, side: Self.qrSide, ink: PairingViewController.ink, mark: NSApp.applicationIconImage)
        qr.alphaValue = 0.07
        guard !Theme.reduceMotion, let l = qr.layer else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0.05
        a.toValue = 0.16
        a.duration = 1.1
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        l.add(a, forKey: "loading")
    }

    func expire() {
        hasCode = false
        qr.layer?.removeAnimation(forKey: "loading")
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = Theme.easeOut
            qr.animator().alphaValue = 0.12
        }
        // Out of focus, so the message on top reads cleanly and the old code can't be scanned.
        if let l = qr.layer, let blur = CIFilter(name: "CIGaussianBlur") {
            blur.name = "stale"
            blur.setValue(4, forKey: kCIInputRadiusKey)
            l.filters = [blur]
            if !Theme.reduceMotion {
                let b = CABasicAnimation(keyPath: "filters.stale.inputRadius")
                b.fromValue = 0
                b.toValue = 4
                b.duration = 0.3
                b.timingFunction = Theme.easeOut
                l.add(b, forKey: "stale")
            }
        }
        expiredStack.isHidden = false
        expiredStack.wantsLayer = true
        Motion.pop(expiredStack.layer, size: expiredStack.bounds.size, from: 0.9, response: 0.35, damping: 0.9)
    }

    @objc private func reload() { onReload?() }

    // MARK: Phone side

    func flip(toPhone: Bool) {
        guard toPhone != showingPhone else { return }
        showingPhone = toPhone
        let swap = {
            self.front.isHidden = toPhone
            self.back.isHidden = !toPhone
            if toPhone { self.window?.makeFirstResponder(self.phoneField) } else { self.window?.makeFirstResponder(nil) }
        }
        guard let l = layer, !Theme.reduceMotion else {
            Motion.crossfade(layer, duration: 0.2)
            swap()
            return
        }
        // A real turn of the card about its vertical axis: away, swap at the edge, back.
        let size = bounds.size
        func turned(_ angle: CGFloat) -> CATransform3D {
            var t = CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0)
            t.m34 = -1 / 900
            t = CATransform3DRotate(t, angle, 0, 1, 0)
            return CATransform3DTranslate(t, -size.width / 2, -size.height / 2, 0)
        }
        let dir: CGFloat = toPhone ? 1 : -1
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            swap()
            l.removeAnimation(forKey: "flipOut")
            let back = Theme.spring("transform", response: 0.42, damping: 0.82)
            back.fromValue = turned(-dir * .pi / 2)
            back.toValue = CATransform3DIdentity
            l.add(back, forKey: "flipIn")
        }
        let away = CABasicAnimation(keyPath: "transform")
        away.fromValue = CATransform3DIdentity
        away.toValue = turned(dir * .pi / 2)
        away.duration = 0.16
        away.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 1, 1)
        away.fillMode = .forwards
        away.isRemovedOnCompletion = false
        l.add(away, forKey: "flipOut")
        CATransaction.commit()
    }

    @objc private func requestCode() {
        let phone = phoneField.stringValue.trimmingCharacters(in: .whitespaces)
        guard phone.filter(\.isNumber).count >= 7 else {
            showPhoneError("Enter the full number, starting with the country code.")
            return
        }
        getCode.isEnabled = false
        onRequestCode?(phone)
    }

    func showPhoneCode(_ code: String) {
        getCode.isEnabled = true
        codeLabel.attributedStringValue = NSAttributedString(string: code, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 34, weight: .semibold),
            .foregroundColor: PairingViewController.ink, .kern: 3])
        Motion.crossfade(back.layer ?? layer, duration: 0.25)
        phoneTitle.stringValue = "Your code"
        phoneNote.stringValue = "Enter it on your phone when WhatsApp asks for it."
        phoneNote.textColor = NSColor(hex: 0x0E1A16, alpha: 0.6)
        phoneField.isHidden = true
        getCode.isHidden = true
        codeLabel.isHidden = false
        changeNumber.isHidden = false
        window?.makeFirstResponder(nil)
    }

    func showPhoneError(_ message: String) {
        getCode.isEnabled = true
        phoneNote.stringValue = message
        phoneNote.textColor = .systemRed
        Motion.crossfade(phoneNote.layer, duration: 0.15)
    }

    @objc private func differentNumber() {
        Motion.crossfade(back.layer ?? layer, duration: 0.2)
        resetPhone()
        window?.makeFirstResponder(phoneField)
    }

    private func resetPhone() {
        phoneTitle.stringValue = "Link with your number"
        phoneNote.stringValue = "The number your WhatsApp uses, starting with the country code."
        phoneNote.textColor = NSColor(hex: 0x0E1A16, alpha: 0.6)
        phoneField.isHidden = false
        getCode.isHidden = false
        getCode.isEnabled = true
        codeLabel.isHidden = true
        changeNumber.isHidden = true
    }

    // MARK: Linked

    /// The code dissolves, the card fills with celadon and a check draws itself.
    func celebrate() {
        let reduce = Theme.reduceMotion
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = Theme.easeOut
            front.animator().alphaValue = 0
            back.animator().alphaValue = 0
        }
        guard let l = layer else { return }
        let fill = CABasicAnimation(keyPath: "backgroundColor")
        fill.fromValue = l.backgroundColor
        fill.toValue = PairingViewController.celadon.cgColor
        fill.duration = 0.35
        fill.timingFunction = Theme.easeOut
        l.backgroundColor = PairingViewController.celadon.cgColor
        l.add(fill, forKey: "fill")

        check.strokeEnd = 1
        if reduce {
            Motion.fade(check, duration: 0.25)
            return
        }
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 0.42
        draw.beginTime = CACurrentMediaTime() + 0.16
        draw.fillMode = .backwards
        draw.timingFunction = CAMediaTimingFunction(controlPoints: 0.6, 0, 0.2, 1)
        check.add(draw, forKey: "draw")

        // One rare moment, so it may overshoot a touch.
        let pop = Theme.spring("transform", response: 0.5, damping: 0.62)
        pop.fromValue = Motion.scale(0.94, in: bounds.size)
        pop.toValue = CATransform3DIdentity
        pop.beginTime = CACurrentMediaTime() + 0.08
        pop.fillMode = .backwards
        l.add(pop, forKey: "pop")
    }

    /// A stand-in the length of a real pairing code, for the loading state only.
    private static let sampleCode = "2@" + String(repeating: "Q3vN8xKpL0aR", count: 7) + ","
        + String(repeating: "m4Tz", count: 11) + "," + String(repeating: "Hc7w", count: 11) + "," + String(repeating: "pB2y", count: 11)
}

