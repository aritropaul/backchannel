import AppKit
import ImagePlayground
import UniformTypeIdentifiers

/// Chat theme, like WhatsApp's: preset themes (wallpaper + bubble colour), then
/// Chat bubble and Wallpaper on their own. Everything here stays on this Mac.
extension ProfileViewController: ImagePlaygroundViewController.Delegate {

    /// WhatsApp-style themes: each pairs a wallpaper with a bubble colour.
    private static var presets: [ChatTheme] {
        var out = [ChatTheme()]
        out += GradientWallpaper.all.map { ChatTheme(wallpaper: $0.id, bubble: $0.bubble.rawValue) }
        let solids: [(String, Theme.AccentChoice)] = [("sand", .orange), ("mint", .whatsapp), ("sky", .blue),
                                                      ("lilac", .purple), ("blush", .pink), ("slate", .graphite)]
        out += solids.map { ChatTheme(wallpaper: $0.0, bubble: $0.1.rawValue) }
        return out
    }

    func pushTheme() {
        guard let c = chat else { return }
        let page = ProfilePage(title: "Chat theme")
        func build() {
            page.clear()
            let t = ChatThemes.theme(for: c.jid)
            page.add(ProfilePage.note("THEMES", size: 11, weight: .semibold))
            var tiles: [NSView] = []
            if ImagePlaygroundViewController.isAvailable {
                tiles.append(ThemeTile(kind: .ai, selected: false) { [weak self] in self?.createWithAI() })
            }
            if t.wallpaper == "photo" {
                tiles.append(ThemeTile(kind: .theme(t), selected: true) {})
            }
            for p in Self.presets {
                tiles.append(ThemeTile(kind: .theme(p), selected: t.wallpaper != "photo" && p == ChatTheme(wallpaper: t.wallpaper, bubble: t.bubble)) {
                    ChatThemes.set(p, for: c.jid)
                    build()
                })
            }
            page.add(Self.grid(tiles, columns: 3))
            page.add(ProfilePage.note("The chat bubble and wallpaper both change. Only you see this, and only on this Mac."))

            page.add(ProfilePage.note("CUSTOMIZE", size: 11, weight: .semibold))
            let dot = ColorDot(color: ChatThemes.bubbleColor(t))
            let thumb = ThemeTile(kind: .wallpaperOnly(t), selected: false, mini: true) {}
            let card = Card()
            card.setRows([
                NavRow(symbol: "bubble.left", title: "Chat bubble", trailing: dot) { [weak self] in self?.pushBubble(onChange: build) },
                NavRow(symbol: "photo.artframe", title: "Wallpaper", trailing: thumb) { [weak self] in self?.pushWallpaper(onChange: build) },
            ])
            page.add(card)
            if !t.isDefault {
                let reset = Card()
                reset.setRows([actionRow("Reset to default", color: .systemRed) {
                    ChatThemes.set(ChatTheme(), for: c.jid)
                    build()
                }])
                page.add(reset)
            }
        }
        themePageBuild = build
        build()
        push(page)
    }

    private func pushBubble(onChange: @escaping () -> Void) {
        guard let c = chat else { return }
        let page = ProfilePage(title: "Chat bubble")
        func build() {
            page.clear()
            var t = ChatThemes.theme(for: c.jid)
            let card = Card()
            let choices: [(String, String)] = [("", "Default (\(Theme.accentChoice.title))")]
                + Theme.AccentChoice.allCases.filter { $0 != .system }.map { ($0.rawValue, $0.title) }
            card.setRows(choices.map { id, title in
                var probe = t
                probe.bubble = id
                let row = choiceRow(title, checked: t.bubble == id) {
                    t.bubble = id
                    ChatThemes.set(t, for: c.jid)
                    build()
                    onChange()
                }
                let dot = ColorDot(color: ChatThemes.bubbleColor(probe))
                let wrap = NSStackView(views: [dot, row])
                wrap.spacing = 10
                wrap.alignment = .centerY
                return wrap
            })
            page.add(card)
            page.add(ProfilePage.note("Your messages in this chat take this colour, in a tone that keeps text readable in light and dark."))
        }
        build()
        push(page)
    }

    private func pushWallpaper(onChange: @escaping () -> Void) {
        guard let c = chat else { return }
        let page = ProfilePage(title: "Wallpaper")
        func build() {
            page.clear()
            var t = ChatThemes.theme(for: c.jid)
            func pick(_ w: String) {
                t.wallpaper = w
                ChatThemes.set(t, for: c.jid)
                build()
                onChange()
            }
            var tiles: [NSView] = [ThemeTile(kind: .wallpaperOnly(ChatTheme(wallpaper: "default", bubble: t.bubble)), selected: t.wallpaper == "default", title: "Default") { pick("default") }]
            if !t.photo.isEmpty {
                var p = t
                p.wallpaper = "photo"
                tiles.append(ThemeTile(kind: .wallpaperOnly(p), selected: t.wallpaper == "photo", title: "Photo") { pick("photo") })
            }
            tiles += GradientWallpaper.all.map { g in
                ThemeTile(kind: .wallpaperOnly(ChatTheme(wallpaper: g.id, bubble: t.bubble)), selected: t.wallpaper == g.id, title: g.title) { pick(g.id) }
            }
            tiles += Wallpaper.all.filter { $0.id != "none" }.map { w in
                ThemeTile(kind: .wallpaperOnly(ChatTheme(wallpaper: w.id, bubble: t.bubble)), selected: t.wallpaper == w.id, title: w.title) { pick(w.id) }
            }
            page.add(Self.grid(tiles, columns: 3))

            let own = Card()
            var rows: [NSView] = [actionRow("Choose a Photo…", color: Theme.accent) { [weak self] in self?.choosePhoto(onChange: { build(); onChange() }) }]
            if ImagePlaygroundViewController.isAvailable {
                rows.append(actionRow("Create with AI…", color: Theme.accent) { [weak self] in self?.createWithAI() })
            }
            own.setRows(rows)
            page.add(own)

            if t.wallpaper == "photo" {
                page.add(ProfilePage.note("DIMMING", size: 11, weight: .semibold))
                let slider = NSSlider(value: t.dim, minValue: 0, maxValue: 0.8, target: ClosureTarget.shared, action: #selector(ClosureTarget.fire(_:)))
                slider.isContinuous = false
                ClosureTarget.shared.register(slider) {
                    t.dim = slider.doubleValue
                    ChatThemes.set(t, for: c.jid)
                    onChange()
                }
                let card = Card()
                card.setRows([NavRow(symbol: "sun.min", title: "", chevron: false, trailing: slider, action: nil)])
                page.add(card)
                page.add(ProfilePage.note("Washes the photo toward the background so messages stay easy to read."))
            }
        }
        wallpaperPageBuild = { build(); onChange() }
        build()
        push(page)
    }

    private func choosePhoto(onChange: @escaping () -> Void) {
        guard let c = chat, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a wallpaper for \(c.name)"
        panel.beginSheetModal(for: window) { resp in
            guard resp == .OK, let url = panel.url, let name = ChatThemes.importPhoto(url) else { return }
            var t = ChatThemes.theme(for: c.jid)
            t.wallpaper = "photo"
            t.photo = name
            ChatThemes.set(t, for: c.jid)
            onChange()
        }
    }

    /// Image Playground (Apple Intelligence) makes the picture; it becomes this chat's wallpaper.
    func createWithAI() {
        guard ImagePlaygroundViewController.isAvailable else { return }
        let vc = ImagePlaygroundViewController()
        vc.delegate = self
        if let c = chat { vc.concepts = [.text("A wallpaper for my chat with \(c.name)")] }
        presentAsSheet(vc)
    }

    func imagePlaygroundViewController(_ vc: ImagePlaygroundViewController, didCreateImageAt imageURL: URL) {
        dismiss(vc)
        guard let c = chat, let name = ChatThemes.importPhoto(imageURL) else { return }
        var t = ChatThemes.theme(for: c.jid)
        t.wallpaper = "photo"
        t.photo = name
        ChatThemes.set(t, for: c.jid)
        themePageBuild?()
        wallpaperPageBuild?()
    }

    func imagePlaygroundViewControllerDidCancel(_ vc: ImagePlaygroundViewController) {
        dismiss(vc)
    }

    static func grid(_ views: [NSView], columns: Int) -> NSView {
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.spacing = 8
        var row: NSStackView?
        for (i, v) in views.enumerated() {
            if i % columns == 0 {
                let r = NSStackView()
                r.spacing = 8
                r.distribution = .fillEqually
                r.alignment = .top
                grid.addArrangedSubview(r)
                r.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
                row = r
            }
            row?.addArrangedSubview(v)
        }
        if let r = row, views.count % columns != 0 {
            for _ in 0..<(columns - views.count % columns) { r.addArrangedSubview(NSView()) }
        }
        return grid
    }
}

extension ChatThemes {
    /// The bubble colour a theme gives my messages, in the current appearance.
    static func bubbleColor(_ t: ChatTheme) -> NSColor {
        NSColor(name: nil) { ap in
            let accent = Theme.AccentChoice(rawValue: t.bubble).flatMap { $0.color.usingColorSpace(.sRGB) }
                ?? Theme.AccentChoice.whatsapp.color
            var base = accent
            if t.bubble.isEmpty {
                ap.performAsCurrentDrawingAppearance { base = Theme.accentChoice.color.usingColorSpace(.sRGB) ?? accent }
            }
            return OKLCH.bubble(accent: base, dark: ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        }
    }
}

/// A filled circle of a colour, for the Chat bubble row and its choices.
final class ColorDot: NSView {
    private let color: NSColor
    init(color: NSColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 18).isActive = true
        heightAnchor.constraint(equalToConstant: 18).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        let p = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        p.fill()
        NSColor.separatorColor.setStroke()
        p.lineWidth = 0.5
        p.stroke()
    }
}

/// A theme or wallpaper preview: the wallpaper with a grey bubble and one of mine,
/// like WhatsApp's theme cards.
final class ThemeTile: NSView {
    enum Kind {
        case theme(ChatTheme)
        case wallpaperOnly(ChatTheme)
        case ai
    }
    private let kind: Kind
    private let selected: Bool
    private let mini: Bool
    private let title: String?
    private let action: () -> Void

    init(kind: Kind, selected: Bool, mini: Bool = false, title: String? = nil, action: @escaping () -> Void) {
        self.kind = kind
        self.selected = selected
        self.mini = mini
        self.title = title
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        if mini {
            widthAnchor.constraint(equalToConstant: 22).isActive = true
            heightAnchor.constraint(equalToConstant: 30).isActive = true
        } else {
            heightAnchor.constraint(equalTo: widthAnchor, multiplier: 1.35).isActive = true
        }
        setAccessibilityRole(.button)
        switch kind {
        case .ai: setAccessibilityLabel("Create with AI")
        case .theme(let t), .wallpaperOnly(let t): setAccessibilityLabel(title ?? Self.name(t))
        }
        setAccessibilitySelected(selected)
        toolTip = title
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private static func name(_ t: ChatTheme) -> String {
        if t.isDefault { return "Default" }
        if t.wallpaper == "photo" { return "Photo" }
        return GradientWallpaper.find(t.wallpaper)?.title ?? Wallpaper.all.first { $0.id == t.wallpaper }?.title ?? "Theme"
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: selected ? 3 : 1, dy: selected ? 3 : 1)
        let radius: CGFloat = mini ? 5 : 12
        let shape = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        switch kind {
        case .ai:
            NSGradient(colors: [NSColor(hex: 0x1B2A4A), NSColor(hex: 0x3B1E4A)])?.draw(in: r, angle: -60)
            let sym = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 22, weight: .regular).applying(.init(paletteColors: [.white])))
            let label = NSAttributedString(string: "Create\nwith AI", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white,
                .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = .center; return p }()])
            let ls = label.boundingRect(with: NSSize(width: r.width, height: 100), options: .usesLineFragmentOrigin).size
            if let sym {
                sym.draw(in: NSRect(x: r.midX - sym.size.width / 2, y: r.midY - ls.height / 2 - sym.size.height - 4,
                                    width: sym.size.width, height: sym.size.height), from: .zero, operation: .sourceOver, fraction: 1,
                         respectFlipped: true, hints: nil)
            }
            label.draw(with: NSRect(x: r.minX, y: r.midY - ls.height / 2 + 6, width: r.width, height: ls.height), options: .usesLineFragmentOrigin)
        case .theme(let t), .wallpaperOnly(let t):
            drawWallpaper(t, in: r, dark: dark)
            if !mini { drawBubbles(t, in: r, dark: dark, ownBubble: { if case .theme = kind { return true }; return false }()) }
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
        if selected {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: radius + 2, yRadius: radius + 2)
            NSColor.labelColor.setStroke()
            ring.lineWidth = 2
            ring.stroke()
            let d: CGFloat = 20
            let check = NSRect(x: r.midX - d / 2, y: r.maxY - d - 8, width: d, height: d)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: check).fill()
            if let mark = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .bold).applying(.init(paletteColors: [.black]))) {
                mark.draw(in: NSRect(x: check.midX - mark.size.width / 2, y: check.midY - mark.size.height / 2,
                                     width: mark.size.width, height: mark.size.height), from: .zero, operation: .sourceOver,
                          fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        if let title, !mini {
            let s = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
                                                                   .foregroundColor: dark ? NSColor.white : NSColor.black.withAlphaComponent(0.75)])
            let sz = s.size()
            s.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.maxY - sz.height - (selected ? 32 : 8)))
        }
    }

    private func drawWallpaper(_ t: ChatTheme, in r: NSRect, dark: Bool) {
        if t.isPicture, let img = Wallpapers.image(for: t, dark: dark) {
            let iw = CGFloat(img.width), ih = CGFloat(img.height)
            let s = max(r.width / iw, r.height / ih)
            let dst = NSRect(x: r.midX - iw * s / 2, y: r.midY - ih * s / 2, width: iw * s, height: ih * s)
            NSImage(cgImage: img, size: NSSize(width: iw, height: ih)).draw(in: dst, from: .zero, operation: .sourceOver,
                                                                           fraction: 1, respectFlipped: true, hints: nil)
            let wash = Wallpapers.wash(t)
            if wash > 0 {
                (dark ? NSColor.black : NSColor.white).withAlphaComponent(wash).setFill()
                r.fill(using: .sourceOver)
            }
            return
        }
        if let w = Wallpaper.all.first(where: { $0.id == t.wallpaper }), w.id != "none" {
            NSColor(hex: dark ? w.dark : w.light).setFill()
        } else {
            (Wallpaper.color(dark: dark) ?? NSColor.textBackgroundColor).setFill()
        }
        r.fill()
    }

    private func drawBubbles(_ t: ChatTheme, in r: NSRect, dark: Bool, ownBubble: Bool) {
        let h = r.height * 0.13
        let incoming = NSRect(x: r.minX + r.width * 0.12, y: r.minY + r.height * 0.24, width: r.width * 0.5, height: h)
        let mine = NSRect(x: r.maxX - r.width * 0.12 - r.width * 0.5, y: incoming.maxY + 8, width: r.width * 0.5, height: h)
        Theme.bubbleIn.setFill()
        NSBezierPath(roundedRect: incoming, xRadius: h / 2, yRadius: h / 2).fill()
        let probe = ownBubble ? t : ChatTheme(wallpaper: t.wallpaper, bubble: ChatThemes.current.bubble)
        ChatThemes.bubbleColor(probe).setFill()
        NSBezierPath(roundedRect: mine, xRadius: h / 2, yRadius: h / 2).fill()
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
}
