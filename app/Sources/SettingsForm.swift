import AppKit

/// Building blocks for Settings panes, shaped like macOS System Settings: a large
/// title, then grouped rounded boxes of rows (title on the left, control on the
/// right) with an optional header above and footnote below each group.
enum Form {
    static func title(_ s: String) -> NSView {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 22, weight: .bold)
        return l
    }

    static func group(_ rows: [NSView], header: String? = nil, footer: String? = nil) -> NSView {
        let box = GroupBox(rows: rows)
        var views: [NSView] = []
        if let header {
            let h = NSTextField(labelWithString: header)
            h.font = .systemFont(ofSize: 13, weight: .semibold)
            views.append(h)
        }
        views.append(box)
        if let footer {
            let f = NSTextField(wrappingLabelWithString: footer)
            f.font = .systemFont(ofSize: 11)
            f.textColor = .secondaryLabelColor
            views.append(f)
        }
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 6
        for v in views { v.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true }
        if header != nil { s.setCustomSpacing(8, after: views[0]) }
        return s
    }

    static func toggle(_ title: String, detail: String? = nil, on: Bool, _ change: @escaping (Bool) -> Void) -> FormRow {
        let sw = NSSwitch()
        sw.state = on ? .on : .off
        sw.controlSize = .small
        let row = FormRow(title: title, detail: detail, accessory: sw)
        row.bind(sw) { change(sw.state == .on) }
        return row
    }

    /// A pop-up of (value, label) options.
    static func popup(_ title: String, detail: String? = nil, options: [(String, String)], selected: String,
                      _ change: @escaping (String) -> Void) -> FormRow {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.controlSize = .regular
        for (value, label) in options {
            p.addItem(withTitle: label)
            p.lastItem?.representedObject = value
        }
        if let i = options.firstIndex(where: { $0.0 == selected }) { p.selectItem(at: i) }
        let row = FormRow(title: title, detail: detail, accessory: p)
        row.bind(p) { if let v = p.selectedItem?.representedObject as? String { change(v) } }
        return row
    }

    static func value(_ title: String, _ value: String, selectable: Bool = true) -> FormRow {
        let v = NSTextField(labelWithString: value)
        v.textColor = .secondaryLabelColor
        v.isSelectable = selectable
        v.alignment = .right
        v.lineBreakMode = .byTruncatingMiddle
        return FormRow(title: title, detail: nil, accessory: v)
    }

    static func button(_ title: String, detail: String? = nil, label: String, destructive: Bool = false,
                       _ action: @escaping () -> Void) -> FormRow {
        let b = NSButton(title: label, target: nil, action: nil)
        b.bezelStyle = .push
        b.controlSize = .regular
        if destructive { b.hasDestructiveAction = true; b.contentTintColor = .systemRed }
        let row = FormRow(title: title, detail: detail, accessory: b)
        row.bind(b, action)
        return row
    }

    /// A row that opens something: chevron on the right, the whole row clickable.
    static func link(_ title: String, detail: String? = nil, symbol: String = "chevron.right", _ action: @escaping () -> Void) -> FormRow {
        let i = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) ?? NSImage())
        i.contentTintColor = .tertiaryLabelColor
        let row = FormRow(title: title, detail: detail, accessory: i)
        row.onClick = action
        return row
    }

    /// Inline-editable text: commits on Return or when focus leaves.
    static func field(_ title: String, value: String, placeholder: String, limit: Int, _ commit: @escaping (String) -> Void) -> FormRow {
        let f = LimitedField(limit: limit)
        f.stringValue = value
        f.placeholderString = placeholder
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.alignment = .right
        f.font = .systemFont(ofSize: 13)
        f.lineBreakMode = .byTruncatingTail
        f.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        let row = FormRow(title: title, detail: nil, accessory: f)
        var last = value
        f.onCommit = { v in
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t != last else { return }
            last = t
            commit(t)
        }
        return row
    }

    static func note(_ s: String) -> NSView {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabelColor
        return l
    }
}

/// One settings row: title (and optional detail line) on the left, a control on the right.
final class FormRow: NSView {
    var onClick: (() -> Void)? { didSet { setAccessibilityRole(onClick == nil ? .group : .button) } }
    private var handler: (() -> Void)?
    let titleLabel: NSTextField

    init(title: String, detail: String?, accessory: NSView) {
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [titleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        if let detail {
            let d = NSTextField(wrappingLabelWithString: detail)
            d.font = .systemFont(ofSize: 11)
            d.textColor = .secondaryLabelColor
            text.addArrangedSubview(d)
        }
        text.translatesAutoresizingMaskIntoConstraints = false
        accessory.translatesAutoresizingMaskIntoConstraints = false
        accessory.setContentHuggingPriority(.required, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        [text, accessory].forEach(addSubview)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
            accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
            accessory.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 12),
            heightAnchor.constraint(greaterThanOrEqualToConstant: detail == nil ? 38 : 50),
        ])
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    func bind(_ control: NSControl, _ action: @escaping () -> Void) {
        handler = action
        control.target = self
        control.action = #selector(fire)
    }

    @objc private func fire() { handler?() }

    override func mouseDown(with event: NSEvent) { if onClick == nil { super.mouseDown(with: event) } }
    override func mouseUp(with event: NSEvent) {
        if let onClick, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }
    override func resetCursorRects() { if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) } }
}

/// The rounded box behind a group of rows, with hairlines between them.
final class GroupBox: NSView {
    init(rows: [NSView]) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for (i, r) in rows.enumerated() {
            if i > 0 {
                let line = Hairline()
                stack.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
            }
            stack.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.05) : NSColor.black.withAlphaComponent(0.03)).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.06)).cgColor
    }
}

final class Hairline: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        let h = 1 / (window?.backingScaleFactor ?? 2)
        NSRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h).fill()
    }
}

/// Text field with a character limit that reports its value on Return or blur.
final class LimitedField: NSTextField, NSTextFieldDelegate {
    let limit: Int
    var onCommit: ((String) -> Void)?

    init(limit: Int) {
        self.limit = limit
        super.init(frame: .zero)
        delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    func controlTextDidChange(_ obj: Notification) {
        if stringValue.count > limit { stringValue = String(stringValue.prefix(limit)) }
    }
    func controlTextDidEndEditing(_ obj: Notification) { onCommit?(stringValue) }
}
