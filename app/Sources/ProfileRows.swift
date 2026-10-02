import AppKit

/// One row in a profile card, laid out like WhatsApp's contact info: icon, title
/// (and a subtitle), value, chevron. The whole row is the click target.
final class NavRow: NSView {
    private let action: (() -> Void)?
    private let highlight = NSView()
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")

    init(symbol: String?, title: String, subtitle: String? = nil, detail: String? = nil, chevron: Bool = true,
         tint: NSColor? = nil, iconTint: NSColor? = nil, trailing: NSView? = nil, action: (() -> Void)?) {
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 8
        highlight.isHidden = true
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)

        var views: [NSView] = []
        if let symbol {
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) ?? NSImage())
            icon.contentTintColor = iconTint ?? tint ?? .labelColor
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
            views.append(icon)
        }
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = tint ?? .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [titleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        if let subtitle, !subtitle.isEmpty {
            let s = NSTextField(wrappingLabelWithString: subtitle)
            s.font = .systemFont(ofSize: 11.5)
            s.textColor = .secondaryLabelColor
            s.maximumNumberOfLines = 2
            s.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            text.addArrangedSubview(s)
        }
        // The text column takes the slack, so values, checkmarks and switches sit on the trailing edge.
        text.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        views.append(text)
        if let detail {
            detailLabel.stringValue = detail
            detailLabel.font = .systemFont(ofSize: 13)
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            views.append(detailLabel)
        }
        if let trailing { views.append(trailing) }
        if chevron {
            let c = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) ?? NSImage())
            c.contentTintColor = .tertiaryLabelColor
            views.append(c)
        }
        let row = NSStackView(views: views)
        row.spacing = 10
        row.alignment = .centerY
        // .fill, not the default gravity areas: the text column (lowest hugging) takes the
        // slack every time, or a rebuilt row can leave its chevron beside the title.
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        if symbol != nil { row.setCustomSpacing(12, after: views[0]) }
        addSubview(row)
        NSLayoutConstraint.activate([
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -8),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 8),
            highlight.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])
        setAccessibilityRole(action == nil ? .staticText : .button)
        setAccessibilityLabel([title, subtitle, detail].compactMap { $0 }.joined(separator: ", "))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            highlight.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard action != nil else { return super.mouseDown(with: event) }
        viewDidChangeEffectiveAppearance()
        highlight.isHidden = false
    }

    override func mouseUp(with event: NSEvent) {
        guard let action else { return super.mouseUp(with: event) }
        highlight.isHidden = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }

    override func accessibilityPerformPress() -> Bool {
        action?()
        return action != nil
    }
}

/// A plain text action, WhatsApp's coloured rows at the bottom ("Share contact",
/// "Clear chat", "Block").
func actionRow(_ title: String, color: NSColor, _ action: @escaping () -> Void) -> NavRow {
    NavRow(symbol: nil, title: title, chevron: false, tint: color, action: action)
}

/// A choice in a list where one is picked (Mute for…, Disappearing messages, Save to Photos).
func choiceRow(_ title: String, subtitle: String? = nil, checked: Bool, _ action: @escaping () -> Void) -> NavRow {
    let mark = NSImageView(image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: checked ? "Selected" : nil)?
        .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold)) ?? NSImage())
    mark.contentTintColor = Theme.accent
    mark.isHidden = !checked
    return NavRow(symbol: nil, title: title, subtitle: subtitle, chevron: false, trailing: mark, action: action)
}

/// Avatar, name, and a line under it, for groups and people in the panel.
final class PersonRow: NSView {
    private let action: () -> Void

    init(jid: String, name: String, subtitle: String, isGroup: Bool, avatar path: String, chevron: Bool = true,
         action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let av = AvatarView(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
        av.translatesAutoresizingMaskIntoConstraints = false
        av.configure(jid: jid, name: name, isGroup: isGroup, path: path, px: 72)
        let n = NSTextField(labelWithString: name)
        n.font = .systemFont(ofSize: 13)
        n.lineBreakMode = .byTruncatingTail
        let s = NSTextField(labelWithString: subtitle)
        s.font = .systemFont(ofSize: 11.5)
        s.textColor = .secondaryLabelColor
        s.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [n, s])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        s.isHidden = subtitle.isEmpty
        [n, s].forEach { $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        text.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        var views: [NSView] = [av, text]
        if chevron {
            let c = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) ?? NSImage())
            c.contentTintColor = .tertiaryLabelColor
            views.append(c)
        }
        let row = NSStackView(views: views)
        row.spacing = 10
        row.alignment = .centerY
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            av.widthAnchor.constraint(equalToConstant: 36),
            av.heightAnchor.constraint(equalToConstant: 36),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(subtitle.isEmpty ? name : "\(name), \(subtitle)")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
}

/// A page pushed inside the profile panel: back button and centred title, then
/// scrolling cards. The panel keeps a stack of these over its root page.
final class ProfilePage: NSView {
    let stack = NSStackView()
    let scroll = NSScrollView()
    var onBack: (() -> Void)?
    private let titleLabel = NSTextField(labelWithString: "")

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        let back = CircleAction(symbol: "chevron.backward", tip: "Back", size: 30) { [weak self] in self?.onBack?() }
        back.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 24, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        [scroll, back, titleLabel].forEach(addSubview)
        NSLayoutConstraint.activate([
            back.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            back.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: back.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: back.trailingAnchor, constant: 8),
            scroll.topAnchor.constraint(equalTo: back.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Adds a view at the content width (the panel minus its 14pt margins).
    func add(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
    }

    func clear() { stack.arrangedSubviews.forEach { $0.removeFromSuperview() } }

    /// Small grey text, for footnotes and section headers.
    static func note(_ s: String, size: CGFloat = 11.5, weight: NSFont.Weight = .regular) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = .secondaryLabelColor
        return l
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onBack?() } else { super.keyDown(with: event) }
    }
}
