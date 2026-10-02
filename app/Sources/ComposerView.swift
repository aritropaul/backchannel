import AppKit
import LinkPresentation

protocol ComposerDelegate: AnyObject {
    func composerSend(_ text: String)
    func composerSendVoice(_ r: VoiceRecorder.Result)
    func composerDidChangeHeight()
    func composerDidType()
    func composerAttach()
    func composerCancelReply()
    func composerCancelAttachment()
    func composerPasteImage(_ image: NSImage) -> Bool
}

struct LinkPreview {
    let url: URL
    let title: String
    let image: NSImage?
    let thumbPath: String?
}

final class PlaceholderTextView: NSTextView {
    var placeholder = "Message"
    weak var composer: ComposerView?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let s = NSAttributedString(string: placeholder, attributes: [.font: font ?? Theme.body, .foregroundColor: NSColor.placeholderTextColor])
        s.draw(at: NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height))
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if !(pb.types?.contains(.string) ?? false) || (pb.types?.contains(.tiff) ?? false) || (pb.types?.contains(.png) ?? false),
           let img = NSImage(pasteboard: pb), composer?.delegate?.composerPasteImage(img) == true {
            return
        }
        pasteAsPlainText(sender)
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }
}

/// Live input level bars while recording.
final class LevelMeterView: NSView {
    private var levels: [CGFloat] = Array(repeating: 0.05, count: 48)
    override var isFlipped: Bool { true }

    func push(_ level: Float) {
        levels.removeFirst()
        levels.append(max(0.06, CGFloat(level)))
        needsDisplay = true
    }

    func reset() {
        levels = Array(repeating: 0.05, count: levels.count)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let step = bounds.width / CGFloat(levels.count)
        let w = max(2, step - 2)
        NSColor.secondaryLabelColor.setFill()
        for (i, v) in levels.enumerated() {
            let h = max(3, v * bounds.height)
            let r = CGRect(x: CGFloat(i) * step, y: bounds.midY - h / 2, width: w, height: h)
            NSBezierPath(roundedRect: r, xRadius: w / 2, yRadius: w / 2).fill()
        }
    }
}

/// Faint fill and hairline rim behind each glass piece, so the controls stay
/// legible on a flat canvas and in inactive windows (where glass flattens out).
final class GlassRim: NSView {
    var radius: CGFloat = 18 { didSet { needsDisplay = true } }
    /// Overrides the faint default fill (e.g. a near-opaque backing for text over content).
    var fill: NSColor? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        guard let layer else { return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        if let fill {
            effectiveAppearance.performAsCurrentDrawingAppearance { layer.backgroundColor = fill.cgColor }
        } else {
            layer.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.07) : NSColor.white.withAlphaComponent(0.7)).cgColor
        }
        layer.borderWidth = 0.5
        layer.borderColor = (dark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.12)).cgColor
    }
}

/// iMessage-style composer: (+)  [ Message…        ≋/↑ ]  (☺)
/// Reply, attachment and link-preview strips sit inside the capsule above the text.
final class ComposerView: NSView, NSTextViewDelegate {
    weak var delegate: ComposerDelegate?

    private let plusButton = NSButton()
    private let emojiButton = NSButton()
    private let plusGlass = NSGlassEffectView()
    private let emojiGlass = NSGlassEffectView()
    private let container = NSGlassEffectContainerView()
    private let field = NSGlassEffectView()
    /// Flat dark canvases give glass nothing to refract; a faint lift keeps the
    /// controls legible, as Messages does.
    private static let glassTint = NSColor(name: "composerGlass") { @Sendable ap in
        ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor.white.withAlphaComponent(0.10) : NSColor.white.withAlphaComponent(0.55)
    }
    private let stack = NSStackView()
    private let row = NSView()
    private let scroll = NSScrollView()
    let textView = PlaceholderTextView()
    private let actionButton = NSButton()
    private var textHeight: NSLayoutConstraint!

    private let replyStrip = NSView()
    private let replyBar = NSView()
    private let replyName = NSTextField(labelWithString: "")
    private let replyText = NSTextField(labelWithString: "")
    private let replyClose = NSButton()

    private let attachStrip = NSView()
    private let attachImage = NSImageView()
    private let attachLabel = NSTextField(labelWithString: "")
    private let attachClose = NSButton()

    private let linkStrip = NSView()
    private let linkImage = NSImageView()
    private let linkTitle = NSTextField(labelWithString: "")
    private let linkHost = NSTextField(labelWithString: "")
    private let linkClose = NSButton()
    private(set) var linkPreview: LinkPreview?
    private var linkFetching: URL?
    private var linkDismissed: URL?
    private var linkDebounce: DispatchWorkItem?

    private let recordRow = NSView()
    private let recordDot = NSView()
    private let recordTime = NSTextField(labelWithString: "0:00")
    private let meter = LevelMeterView()
    private let recordCancel = NSButton()
    private let recordSend = NSButton()
    private var recorder: VoiceRecorder?
    private var recordTimer: Timer?

    private static let font = NSFont.systemFont(ofSize: 14)
    private static let maxLines: CGFloat = 6
    private static let control: CGFloat = 36

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func plain(_ b: NSButton, _ symbol: String, _ label: String, _ action: Selector, size: CGFloat, tint: NSColor = .secondaryLabelColor) {
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.contentTintColor = tint
        b.target = self
        b.action = action
        b.toolTip = label
        b.translatesAutoresizingMaskIntoConstraints = false
        b.setAccessibilityLabel(label)
    }

    private func glassCircle(_ g: NSGlassEffectView, _ b: NSButton, _ symbol: String, _ label: String, _ action: Selector) {
        plain(b, symbol, label, action, size: 16, tint: .labelColor)
        g.cornerRadius = Self.control / 2
        g.tintColor = Self.glassTint
        g.translatesAutoresizingMaskIntoConstraints = false
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(b)
        g.contentView = holder
        NSLayoutConstraint.activate([
            g.widthAnchor.constraint(equalToConstant: Self.control),
            g.heightAnchor.constraint(equalToConstant: Self.control),
            b.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            b.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            b.widthAnchor.constraint(equalToConstant: Self.control),
            b.heightAnchor.constraint(equalToConstant: Self.control),
        ])
    }

    private func label(_ f: NSTextField, _ font: NSFont, _ color: NSColor) {
        f.font = font
        f.textColor = color
        f.lineBreakMode = .byTruncatingTail
        f.translatesAutoresizingMaskIntoConstraints = false
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        glassCircle(plusGlass, plusButton, "plus", "Attach photo", #selector(attach))
        glassCircle(emojiGlass, emojiButton, "face.smiling", "Emoji", #selector(emoji))

        field.translatesAutoresizingMaskIntoConstraints = false
        field.cornerRadius = Self.control / 2
        field.tintColor = Self.glassTint
        let content = NSView()
        glass(field, content)

        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        buildReply()
        buildAttach()
        buildLink()
        buildRow()
        buildRecord()

        for v in [replyStrip, attachStrip, linkStrip, row, recordRow] {
            stack.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        replyStrip.isHidden = true
        attachStrip.isHidden = true
        linkStrip.isHidden = true
        recordRow.isHidden = true

        // One container so the three pieces render as a single glass system.
        container.spacing = 10
        container.translatesAutoresizingMaskIntoConstraints = false
        let row3 = NSView()
        row3.translatesAutoresizingMaskIntoConstraints = false
        container.contentView = row3
        let rims = [GlassRim(), GlassRim(), GlassRim()]
        for (rim, g) in zip(rims, [plusGlass, field, emojiGlass]) {
            rim.radius = Self.control / 2
            row3.addSubview(rim)
            row3.addSubview(g)
            NSLayoutConstraint.activate([
                rim.leadingAnchor.constraint(equalTo: g.leadingAnchor),
                rim.trailingAnchor.constraint(equalTo: g.trailingAnchor),
                rim.topAnchor.constraint(equalTo: g.topAnchor),
                rim.bottomAnchor.constraint(equalTo: g.bottomAnchor),
            ])
        }
        addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            row3.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            row3.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            row3.topAnchor.constraint(equalTo: container.topAnchor),
            row3.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            plusGlass.leadingAnchor.constraint(equalTo: row3.leadingAnchor),
            plusGlass.bottomAnchor.constraint(equalTo: row3.bottomAnchor),
            field.leadingAnchor.constraint(equalTo: plusGlass.trailingAnchor, constant: 10),
            field.topAnchor.constraint(equalTo: row3.topAnchor),
            field.bottomAnchor.constraint(equalTo: row3.bottomAnchor),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.control),
            emojiGlass.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 10),
            emojiGlass.trailingAnchor.constraint(equalTo: row3.trailingAnchor),
            emojiGlass.bottomAnchor.constraint(equalTo: row3.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func glass(_ g: NSGlassEffectView, _ content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        g.contentView = content
    }

    private func buildRow() {
        row.translatesAutoresizingMaskIntoConstraints = false
        textView.composer = self
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.delegate = self
        textView.setAccessibilityLabel("Message")
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false

        plain(actionButton, "waveform", "Record voice message", #selector(action), size: 15)
        [scroll, actionButton].forEach(row.addSubview)
        textHeight = scroll.heightAnchor.constraint(equalToConstant: lineHeight)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            scroll.topAnchor.constraint(equalTo: row.topAnchor, constant: (Self.control - lineHeight) / 2),
            scroll.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -(Self.control - lineHeight) / 2),
            textHeight,
            actionButton.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 6),
            actionButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -6),
            actionButton.centerYAnchor.constraint(equalTo: row.bottomAnchor, constant: -Self.control / 2),
            actionButton.widthAnchor.constraint(equalToConstant: 28),
            actionButton.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func buildRecord() {
        recordRow.translatesAutoresizingMaskIntoConstraints = false
        recordDot.wantsLayer = true
        recordDot.layer?.cornerRadius = 4.5
        recordDot.layer?.backgroundColor = NSColor.systemRed.cgColor
        recordDot.translatesAutoresizingMaskIntoConstraints = false
        label(recordTime, .monospacedDigitSystemFont(ofSize: 13, weight: .medium), .labelColor)
        meter.translatesAutoresizingMaskIntoConstraints = false
        plain(recordCancel, "xmark.circle.fill", "Cancel recording", #selector(cancelRecording), size: 18, tint: .secondaryLabelColor)
        plain(recordSend, "arrow.up.circle.fill", "Send voice message", #selector(finishRecording), size: 24, tint: Theme.accent)
        [recordCancel, recordDot, recordTime, meter, recordSend].forEach(recordRow.addSubview)
        NSLayoutConstraint.activate([
            recordRow.heightAnchor.constraint(equalToConstant: Self.control),
            recordCancel.leadingAnchor.constraint(equalTo: recordRow.leadingAnchor, constant: 6),
            recordCancel.centerYAnchor.constraint(equalTo: recordRow.centerYAnchor),
            recordCancel.widthAnchor.constraint(equalToConstant: 26),
            recordDot.leadingAnchor.constraint(equalTo: recordCancel.trailingAnchor, constant: 6),
            recordDot.centerYAnchor.constraint(equalTo: recordRow.centerYAnchor),
            recordDot.widthAnchor.constraint(equalToConstant: 9),
            recordDot.heightAnchor.constraint(equalToConstant: 9),
            recordTime.leadingAnchor.constraint(equalTo: recordDot.trailingAnchor, constant: 8),
            recordTime.centerYAnchor.constraint(equalTo: recordRow.centerYAnchor),
            meter.leadingAnchor.constraint(equalTo: recordTime.trailingAnchor, constant: 12),
            meter.centerYAnchor.constraint(equalTo: recordRow.centerYAnchor),
            meter.heightAnchor.constraint(equalToConstant: 20),
            recordSend.leadingAnchor.constraint(equalTo: meter.trailingAnchor, constant: 10),
            recordSend.trailingAnchor.constraint(equalTo: recordRow.trailingAnchor, constant: -5),
            recordSend.centerYAnchor.constraint(equalTo: recordRow.centerYAnchor),
            recordSend.widthAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func strip(_ strip: NSView, bar: NSView?, image: NSImageView?, title: NSTextField, sub: NSTextField, close: NSButton, closeAction: Selector) {
        strip.translatesAutoresizingMaskIntoConstraints = false
        plain(close, "xmark", "Remove", closeAction, size: 10)
        var lead = strip.leadingAnchor
        var leadInset: CGFloat = 14
        if let bar {
            bar.wantsLayer = true
            bar.layer?.cornerRadius = 1.5
            bar.translatesAutoresizingMaskIntoConstraints = false
            strip.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 14),
                bar.topAnchor.constraint(equalTo: strip.topAnchor, constant: 10),
                bar.bottomAnchor.constraint(equalTo: strip.bottomAnchor, constant: -2),
                bar.widthAnchor.constraint(equalToConstant: 3),
            ])
            lead = bar.trailingAnchor
            leadInset = 8
        }
        if let image {
            image.imageScaling = .scaleProportionallyUpOrDown
            image.wantsLayer = true
            image.layer?.cornerRadius = 6
            image.layer?.masksToBounds = true
            image.translatesAutoresizingMaskIntoConstraints = false
            strip.addSubview(image)
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 12),
                image.topAnchor.constraint(equalTo: strip.topAnchor, constant: 10),
                image.bottomAnchor.constraint(equalTo: strip.bottomAnchor, constant: -2),
                image.widthAnchor.constraint(equalToConstant: 40),
                image.heightAnchor.constraint(equalToConstant: 40),
            ])
            lead = image.trailingAnchor
            leadInset = 10
        }
        [title, sub, close].forEach(strip.addSubview)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: lead, constant: leadInset),
            title.topAnchor.constraint(equalTo: strip.topAnchor, constant: image != nil ? 13 : 10),
            title.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -8),
            sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            sub.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -8),
            close.trailingAnchor.constraint(equalTo: strip.trailingAnchor, constant: -12),
            close.centerYAnchor.constraint(equalTo: title.bottomAnchor),
            close.widthAnchor.constraint(equalToConstant: 18),
        ])
        if bar != nil {
            sub.bottomAnchor.constraint(equalTo: strip.bottomAnchor, constant: -2).isActive = true
        }
    }

    private func buildReply() {
        label(replyName, Theme.quoteName, .labelColor)
        label(replyText, Theme.quoteText, .secondaryLabelColor)
        strip(replyStrip, bar: replyBar, image: nil, title: replyName, sub: replyText, close: replyClose, closeAction: #selector(cancelReply))
    }

    private func buildAttach() {
        label(attachLabel, .systemFont(ofSize: 12.5, weight: .medium), .labelColor)
        let sub = NSTextField(labelWithString: "Add a caption, then press Return")
        label(sub, .systemFont(ofSize: 11.5), .secondaryLabelColor)
        strip(attachStrip, bar: nil, image: attachImage, title: attachLabel, sub: sub, close: attachClose, closeAction: #selector(cancelAttachment))
    }

    private func buildLink() {
        label(linkTitle, .systemFont(ofSize: 12.5, weight: .semibold), .labelColor)
        label(linkHost, .systemFont(ofSize: 11.5), .secondaryLabelColor)
        strip(linkStrip, bar: nil, image: linkImage, title: linkTitle, sub: linkHost, close: linkClose, closeAction: #selector(dismissLink))
    }

    private var lineHeight: CGFloat { ceil(Self.font.ascender - Self.font.descender + Self.font.leading) }

    var text: String {
        get { textView.string }
        set {
            textView.string = newValue
            textChanged()
        }
    }

    func focus() { window?.makeFirstResponder(textView) }

    // MARK: strips

    func showReply(name: String, text: String, color: NSColor) {
        replyName.stringValue = name
        replyBar.layer?.backgroundColor = color.cgColor
        replyText.stringValue = text
        setStrip(replyStrip, visible: true, animated: true)
    }

    func hideReply(animated: Bool) { setStrip(replyStrip, visible: false, animated: animated) }

    func showAttachment(_ image: NSImage, label: String) {
        attachImage.image = image
        attachLabel.stringValue = label
        setStrip(attachStrip, visible: true, animated: true)
        updateAction()
    }

    func hideAttachment(animated: Bool) {
        setStrip(attachStrip, visible: false, animated: animated)
        attachImage.image = nil
        updateAction()
    }

    var hasAttachment: Bool { !attachStrip.isHidden }

    private func setStrip(_ strip: NSView, visible: Bool, animated: Bool) {
        guard strip.isHidden == visible else { return }
        strip.wantsLayer = true
        if !animated || Theme.reduceMotion {
            strip.isHidden = !visible
            delegate?.composerDidChangeHeight()
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = Theme.easeOut
            ctx.allowsImplicitAnimation = true
            strip.isHidden = !visible
            superview?.layoutSubtreeIfNeeded()
        }
        if visible { Motion.fade(strip.layer, duration: 0.2) }
        delegate?.composerDidChangeHeight()
    }

    // MARK: send / record button

    private var actionIsSend = false

    /// Waveform when empty (record), green send arrow once there's something to send.
    private func updateAction() {
        let has = !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasAttachment
        guard has != actionIsSend else { return }
        actionIsSend = has
        let sym = has ? "arrow.up.circle.fill" : "waveform"
        actionButton.image = NSImage(systemSymbolName: sym, accessibilityDescription: has ? "Send" : "Record voice message")?
            .withSymbolConfiguration(.init(pointSize: has ? 24 : 15, weight: .medium))
        actionButton.contentTintColor = has ? Theme.accent : .secondaryLabelColor
        actionButton.toolTip = has ? "Send" : "Record voice message"
        actionButton.wantsLayer = true
        Motion.pop(actionButton.layer, size: actionButton.bounds.size, from: 0.6, response: 0.25, damping: 0.8)
    }

    @objc private func action() {
        if actionIsSend { send() } else { startRecording() }
    }

    private func textChanged() {
        updateAction()
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc).height
        let h = min(max(used, lineHeight), lineHeight * Self.maxLines)
        if abs(textHeight.constant - h) > 0.5 {
            textHeight.constant = h
            delegate?.composerDidChangeHeight()
        }
        textView.needsDisplay = true
        scheduleLinkCheck()
    }

    func textDidChange(_ notification: Notification) {
        textChanged()
        if !textView.string.isEmpty { delegate?.composerDidType() }
    }

    func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                send()
            }
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            if !linkStrip.isHidden { dismissLink(); return true }
            if !replyStrip.isHidden { cancelReply(); return true }
            if hasAttachment { cancelAttachment(); return true }
        }
        return false
    }

    private func send() {
        let t = textView.string
        guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasAttachment else { return }
        delegate?.composerSend(t)
        if textView.string.isEmpty { clearLink() }
    }

    @objc private func attach() { delegate?.composerAttach() }
    @objc private func emoji() {
        focus()
        NSApp.orderFrontCharacterPalette(nil)
    }
    @objc private func cancelReply() { delegate?.composerCancelReply() }
    @objc private func cancelAttachment() { delegate?.composerCancelAttachment() }

    // MARK: voice recording

    private func startRecording() {
        VoiceRecorder.requestPermission { [weak self] ok in
            guard let self else { return }
            guard ok else {
                let a = NSAlert()
                a.messageText = "Microphone access is off"
                a.informativeText = "Allow WA in System Settings → Privacy & Security → Microphone to record voice messages."
                if let w = self.window { a.beginSheetModal(for: w) } else { a.runModal() }
                return
            }
            let r = VoiceRecorder()
            do { try r.start() } catch { NSSound.beep(); return }
            self.recorder = r
            self.meter.reset()
            self.row.isHidden = true
            self.recordRow.isHidden = false
            self.pulseDot(true)
            let t = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let r = self.recorder else { return }
                    let s = Int(Date().timeIntervalSince(r.started))
                    self.recordTime.stringValue = Fmt.duration(s)
                    self.meter.push(r.currentLevel)
                }
            }
            RunLoop.main.add(t, forMode: .common)
            self.recordTimer = t
        }
    }

    private func endRecordingUI() {
        recordTimer?.invalidate()
        recordTimer = nil
        pulseDot(false)
        recordRow.isHidden = true
        row.isHidden = false
        recordTime.stringValue = "0:00"
        focus()
    }

    @objc private func cancelRecording() {
        recorder?.cancel()
        recorder = nil
        endRecordingUI()
    }

    @objc private func finishRecording() {
        guard let r = recorder else { return }
        recorder = nil
        endRecordingUI()
        r.finish { [weak self] result in
            guard let result else { NSSound.beep(); return }
            self?.delegate?.composerSendVoice(result)
        }
    }

    var isRecording: Bool { recorder != nil }

    private func pulseDot(_ on: Bool) {
        recordDot.layer?.removeAnimation(forKey: "pulse")
        guard on, !Theme.reduceMotion else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1
        a.toValue = 0.25
        a.duration = 0.6
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        recordDot.layer?.add(a, forKey: "pulse")
    }

    // MARK: link preview

    private func scheduleLinkCheck() {
        linkDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.checkLink() }
        }
        linkDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func checkLink() {
        guard let url = WAText.firstURL(textView.string), url.scheme?.hasPrefix("http") == true else {
            clearLink()
            return
        }
        if url == linkPreview?.url || url == linkFetching || url == linkDismissed { return }
        linkFetching = url
        let provider = LPMetadataProvider()
        provider.timeout = 6
        provider.startFetchingMetadata(for: url) { meta, _ in
            let title = meta?.title ?? ""
            let imageProvider = meta?.imageProvider ?? meta?.iconProvider
            let finish = { (img: NSImage?) in
                let thumb = img.flatMap(ComposerView.writeThumb)
                let box = UncheckedBox(value: img)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.showLink(LinkPreview(url: url, title: title, image: box.value, thumbPath: thumb)) }
                }
            }
            guard !title.isEmpty else {
                DispatchQueue.main.async { MainActor.assumeIsolated { if self.linkFetching == url { self.linkFetching = nil } } }
                return
            }
            if let ip = imageProvider, ip.canLoadObject(ofClass: NSImage.self) {
                _ = ip.loadObject(ofClass: NSImage.self) { obj, _ in finish(obj as? NSImage) }
            } else {
                finish(nil)
            }
        }
    }

    private func showLink(_ p: LinkPreview) {
        guard linkFetching == p.url, WAText.firstURL(textView.string) == p.url else { return }
        linkFetching = nil
        linkPreview = p
        linkTitle.stringValue = p.title
        var host = p.url.host() ?? p.url.absoluteString
        if host.hasPrefix("www.") { host.removeFirst(4) }
        linkHost.stringValue = host
        linkImage.image = p.image ?? NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        setStrip(linkStrip, visible: true, animated: true)
    }

    @objc private func dismissLink() {
        linkDismissed = linkPreview?.url ?? linkFetching
        clearLink()
    }

    private func clearLink() {
        linkFetching = nil
        guard linkPreview != nil || !linkStrip.isHidden else { return }
        linkPreview = nil
        setStrip(linkStrip, visible: false, animated: true)
    }

    /// WhatsApp wants a small JPEG thumbnail embedded in the message.
    nonisolated private static func writeThumb(_ img: NSImage) -> String? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let maxSide: CGFloat = 300
        let s = min(1, maxSide / CGFloat(max(cg.width, cg.height)))
        let w = Int(CGFloat(cg.width) * s), h = Int(CGFloat(cg.height) * s)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("link-\(UUID().uuidString).jpg")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, small, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? url.path : nil
    }
}
