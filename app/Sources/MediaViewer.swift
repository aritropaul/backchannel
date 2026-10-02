import AppKit

/// A photo opened over the chat: it grows out of its bubble, the arrow keys step
/// through the chat's other photos, pinch or double-click zooms, and Escape, Space
/// or a click outside the photo puts it back.
final class MediaViewer: NSView {
    /// The bubble's photo rect for a message, in this view's coordinates, if it's on screen.
    var sourceRect: ((String) -> CGRect?)?
    var onDownload: ((Message) -> Void)?
    var onClose: (() -> Void)?
    var onReply: ((Message) -> Void)?
    var onShowInChat: ((Message) -> Void)?

    private var items: [Message] = []
    private var index = 0
    private var closing = false

    private let backdrop = NSView()
    private let scroll = ZoomScrollView()
    private let canvas = ViewerCanvas()
    private let photo = NSImageView()
    private let spinner = NSProgressIndicator()
    private let topBar = NSView()
    private let shade = CAGradientLayer()
    private let name = NSTextField(labelWithString: "")
    private let date = NSTextField(labelWithString: "")
    private let counter = NSTextField(labelWithString: "")
    private let close = ViewerButton(symbol: "xmark", tip: "Close (Esc)")
    private let reply = ViewerButton(symbol: "arrowshape.turn.up.left", tip: "Reply")
    private let find = ViewerButton(symbol: "text.bubble", tip: "Show in Chat")
    private let share = ViewerButton(symbol: "square.and.arrow.up", tip: "Share")
    private let save = ViewerButton(symbol: "arrow.down.to.line", tip: "Save to Downloads")
    private let prev = ViewerButton(symbol: "chevron.left", tip: "Previous (←)", size: 44)
    private let next = ViewerButton(symbol: "chevron.right", tip: "Next (→)", size: 44)

    private var current: Message? { items.indices.contains(index) ? items[index] : nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)

        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor(white: 0.04, alpha: 0.94).cgColor
        backdrop.autoresizingMask = [.width, .height]
        backdrop.frame = bounds
        addSubview(backdrop)

        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        // The chat runs under the sidebar and titlebar; the photo is placed against the
        // safe area by hand, so the scroll view mustn't shift it again.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.allowsMagnification = true
        scroll.minMagnification = 1
        scroll.maxMagnification = 5
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.contentView.drawsBackground = false
        canvas.frame = bounds
        canvas.autoresizingMask = [.width, .height]
        canvas.viewer = self
        scroll.documentView = canvas
        addSubview(scroll)

        photo.imageScaling = .scaleProportionallyUpOrDown
        photo.wantsLayer = true
        photo.layer?.cornerRadius = 4
        photo.layer?.masksToBounds = true
        canvas.addSubview(photo)
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isHidden = true
        addSubview(spinner)

        topBar.wantsLayer = true
        shade.colors = [NSColor.black.withAlphaComponent(0.55).cgColor, NSColor.clear.cgColor]
        shade.startPoint = CGPoint(x: 0.5, y: 1)
        shade.endPoint = CGPoint(x: 0.5, y: 0)
        topBar.layer?.addSublayer(shade)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.textColor = .white
        date.font = .systemFont(ofSize: 11.5)
        date.textColor = NSColor.white.withAlphaComponent(0.7)
        counter.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        counter.textColor = NSColor.white.withAlphaComponent(0.7)
        counter.alignment = .center
        let who = NSStackView(views: [name, date])
        who.orientation = .vertical
        who.alignment = .leading
        who.spacing = 1
        let actions = NSStackView(views: [reply, find, share, save])
        actions.spacing = 6
        for v in [close, who, actions] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            topBar.addSubview(v)
        }
        for v in [topBar, prev, next, counter] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: topAnchor),
            topBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBar.bottomAnchor.constraint(equalTo: close.bottomAnchor, constant: 28),
            close.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 14),
            close.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 6),
            who.leadingAnchor.constraint(equalTo: close.trailingAnchor, constant: 12),
            who.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            who.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -12),
            actions.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -14),
            actions.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            prev.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 14),
            prev.centerYAnchor.constraint(equalTo: safeAreaLayoutGuide.centerYAnchor),
            next.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -14),
            next.centerYAnchor.constraint(equalTo: safeAreaLayoutGuide.centerYAnchor),
            counter.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor),
            counter.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
        ])
        close.target = self
        close.action = #selector(dismissViewer)
        prev.target = self
        prev.action = #selector(showPrevious)
        next.target = self
        next.action = #selector(showNext)
        share.target = self
        share.action = #selector(sharePhoto)
        save.target = self
        save.action = #selector(savePhoto)
        reply.target = self
        reply.action = #selector(replyToPhoto)
        find.target = self
        find.action = #selector(showInChat)

        NotificationCenter.default.addObserver(forName: MediaThumb.downloaded, object: nil, queue: .main) { [weak self] n in
            let id = n.userInfo?["id"] as? String
            MainActor.assumeIsolated { if let id { self?.downloaded(id) } }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Fresh copies of messages after a download, from the controller.
    var reload: ((String) -> Message?)?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    // MARK: open and close

    func present(_ list: [Message], at i: Int) {
        items = list
        index = max(0, min(i, list.count - 1))
        window?.makeFirstResponder(self)
        guard let m = current else { return }
        show(m)
        let target = fitRect()
        let reduce = Theme.reduceMotion
        if !reduce, let from = sourceRect?(m.id) {
            photo.frame = from
            backdrop.alphaValue = 0
            chrome(alpha: 0)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.34
                ctx.timingFunction = Theme.easeOut
                ctx.allowsImplicitAnimation = true
                photo.animator().frame = target
                backdrop.animator().alphaValue = 1
                chromeAnimator(alpha: 1)
            }
        } else {
            photo.frame = target
            alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = Theme.easeOut
                animator().alphaValue = 1
            }
        }
    }

    @objc func dismissViewer() {
        guard !closing else { return }
        closing = true
        let done = { [weak self] in
            guard let self else { return }
            self.removeFromSuperview()
            self.onClose?()
        }
        if scroll.magnification > 1 { scroll.magnification = 1 }
        if !Theme.reduceMotion, let m = current, let to = sourceRect?(m.id) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.26
                ctx.timingFunction = Theme.easeOut
                ctx.allowsImplicitAnimation = true
                photo.animator().frame = to
                backdrop.animator().alphaValue = 0
                chromeAnimator(alpha: 0)
            }, completionHandler: { MainActor.assumeIsolated { done() } })
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                ctx.timingFunction = Theme.easeOut
                animator().alphaValue = 0
            }, completionHandler: { MainActor.assumeIsolated { done() } })
        }
    }

    private func chrome(alpha: CGFloat) {
        for v in [topBar, prev, next, counter] { v.alphaValue = alpha }
    }

    private func chromeAnimator(alpha: CGFloat) {
        for v in [topBar, prev, next, counter] { v.animator().alphaValue = alpha }
    }

    // MARK: showing a photo

    private func show(_ m: Message) {
        let full = m.mediaPath.isEmpty ? nil : NSImage(contentsOfFile: m.mediaPath)
        photo.image = full ?? ImageCache.thumb(m.thumb)
        let waiting = full == nil
        spinner.isHidden = !waiting
        if waiting {
            spinner.startAnimation(nil)
            onDownload?(m)
        } else {
            spinner.stopAnimation(nil)
        }
        name.stringValue = m.fromMe ? "You" : m.senderName
        date.stringValue = Fmt.dayLabel(m.date) + " at " + Fmt.time(m.date)
        counter.stringValue = items.count > 1 ? "\(index + 1) of \(items.count)" : ""
        prev.isHidden = index == 0
        next.isHidden = index >= items.count - 1
        share.isEnabled = !waiting
        save.isEnabled = !waiting
        needsLayout = true
    }

    private func downloaded(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }), let fresh = reload?(id) else { return }
        items[i] = fresh
        if i == index {
            show(fresh)
            photo.frame = fitRect()
        }
    }

    /// The photo's size at its natural aspect, fitted inside the window with room for the bar.
    private func fitRect() -> CGRect {
        // Clear of the sidebar and titlebar (safe area), the top bar, the arrows and the counter.
        let area = safeAreaRect.insetBy(dx: 64, dy: 0).divided(atDistance: 50, from: .minYEdge).remainder
            .divided(atDistance: 44, from: .maxYEdge).remainder
        guard let m = current else { return area }
        var size = photo.image?.size ?? .zero
        if m.width > 0, m.height > 0 { size = CGSize(width: m.width, height: m.height) }
        guard size.width > 0, size.height > 0 else { return area }
        let s = min(area.width / size.width, area.height / size.height, max(1, 900 / max(size.width, size.height)) * 4)
        let w = size.width * s, h = size.height * s
        return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h).integral
    }

    override func layout() {
        super.layout()
        shade.frame = topBar.bounds
        spinner.frame = CGRect(x: safeAreaRect.midX - 16, y: safeAreaRect.midY - 16, width: 32, height: 32)
        if !closing, photo.layer?.animation(forKey: "frameOrigin") == nil, scroll.magnification == 1 {
            photo.frame = fitRect()
        }
    }

    @objc private func showPrevious() { step(-1) }
    @objc private func showNext() { step(1) }

    private func step(_ d: Int) {
        let i = index + d
        guard items.indices.contains(i) else { NSSound.beep(); return }
        index = i
        scroll.magnification = 1
        show(items[i])
        photo.frame = fitRect()
        if !Theme.reduceMotion { Motion.crossfade(photo.layer, duration: 0.18) }
    }

    // MARK: input

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53, 49: dismissViewer()       // Escape, Space
        case 123: showPrevious()
        case 124: showNext()
        default:
            if event.modifierFlags.contains(.command), let c = event.charactersIgnoringModifiers {
                if c == "=" || c == "+" { zoom(by: 1.5, at: nil); return }
                if c == "-" { zoom(by: 1 / 1.5, at: nil); return }
                if c == "0" { scroll.animator().magnification = 1; return }
            }
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { dismissViewer() }

    fileprivate func canvasClicked(at p: CGPoint, count: Int) {
        if photo.frame.contains(p) {
            if count == 2 { zoom(by: scroll.magnification > 1 ? 0 : 2.5, at: p) }
        } else if count == 1 {
            dismissViewer()
        }
    }

    private func zoom(by factor: CGFloat, at p: CGPoint?) {
        let target = factor == 0 ? 1 : min(scroll.maxMagnification, max(1, scroll.magnification * factor))
        let center = p ?? CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.reduceMotion ? 0 : 0.25
            ctx.timingFunction = Theme.easeOut
            scroll.animator().setMagnification(target, centeredAt: center)
        }
    }

    // MARK: actions

    private var currentURL: URL? {
        guard let m = current, !m.mediaPath.isEmpty else { return nil }
        return URL(fileURLWithPath: m.mediaPath)
    }

    @objc private func sharePhoto() {
        guard let url = currentURL else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: share.bounds, of: share, preferredEdge: .minY)
    }

    /// Copies the photo into Downloads, named like WhatsApp's own saves.
    @objc private func savePhoto() {
        guard let url = currentURL, let m = current,
              let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        var dest = downloads.appendingPathComponent("WhatsApp Image \(f.string(from: m.date)).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = downloads.appendingPathComponent("WhatsApp Image \(f.string(from: m.date)) (\(n)).\(ext)")
            n += 1
        }
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            // Bounces the Downloads stack in the Dock, as Safari's downloads do.
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: dest.path)
            save.flash(symbol: "checkmark")
        } catch {
            NSSound.beep()
        }
    }

    @objc private func replyToPhoto() {
        guard let m = current else { return }
        onReply?(m)
        dismissViewer()
    }

    @objc private func showInChat() {
        guard let m = current else { return }
        onShowInChat?(m)
        dismissViewer()
    }
}

/// The scroll view's document: passes clicks to the viewer, which decides between
/// zooming (double-click on the photo) and closing (a click beside it).
private final class ViewerCanvas: NSView {
    weak var viewer: MediaViewer?
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) {
        viewer?.canvasClicked(at: convert(event.locationInWindow, from: nil), count: event.clickCount)
    }
}

/// Keeps the zoomed photo centred when it's smaller than the window.
private final class ZoomScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        // Unzoomed, a scroll does nothing; zoomed, it pans.
        if magnification > 1 { super.scrollWheel(with: event) }
    }
}

/// A round Liquid Glass button, the same circle as the composer's + and the header's ⋯.
private final class ViewerButton: NSGlassEffectView {
    private let button = NSButton()
    private let symbol: String
    private let side: CGFloat

    var target: AnyObject? {
        get { button.target }
        set { button.target = newValue }
    }
    var action: Selector? {
        get { button.action }
        set { button.action = newValue }
    }
    var isEnabled: Bool {
        get { button.isEnabled }
        set {
            button.isEnabled = newValue
            alphaValue = newValue ? 1 : 0.45
        }
    }

    init(symbol: String, tip: String, size: CGFloat = 36) {
        self.symbol = symbol
        side = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        cornerRadius = size / 2
        tintColor = NSColor.white.withAlphaComponent(0.10)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .labelColor
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        button.translatesAutoresizingMaskIntoConstraints = false
        let holder = NSView()
        holder.addSubview(button)
        contentView = holder
        setGlyph(symbol)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            button.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: size),
            button.heightAnchor.constraint(equalToConstant: size),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setGlyph(_ s: String) {
        button.image = NSImage(systemSymbolName: s, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: side * 0.42, weight: .medium))
    }

    /// Swaps the glyph briefly to confirm an action (Save → ✓).
    func flash(symbol s: String) {
        setGlyph(s)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.setGlyph(self.symbol)
        }
    }
}

extension ConversationViewController {
    /// Opens a photo in the viewer, with the chat's other photos a keypress away.
    func showViewer(_ m: Message) {
        guard let c = chat else { return }
        if let v = viewer { v.removeFromSuperview() }
        var photos = Array(store.mediaItems(c.jid, limit: 500).filter { $0.kind == .image }.reversed())
        if !photos.contains(where: { $0.id == m.id }) { photos.append(m) }
        let i = photos.firstIndex { $0.id == m.id } ?? 0
        let v = MediaViewer(frame: view.bounds)
        v.autoresizingMask = [.width, .height]
        v.sourceRect = { [weak self, weak v] id in
            guard let self, let v else { return nil }
            return self.photoRect(for: id, in: v)
        }
        v.onDownload = { m in Core.shared.call("download", ["chat": c.jid, "id": m.id, "retry": true]) }
        v.reload = { [weak self] id in self?.store.message(chat: c.jid, id: id) }
        v.onReply = { [weak self] m in self?.reply(to: m) }
        v.onShowInChat = { [weak self] m in self?.jump(to: m.id) }
        v.onClose = { [weak self] in
            guard let self else { return }
            self.viewer = nil
            self.onViewer?(false)
            self.composer.focus()
        }
        view.addSubview(v)
        viewer = v
        onViewer?(true)
        v.present(photos, at: i)
    }

    /// Where a message's photo sits on screen, in `target`'s coordinates; nil when
    /// it's scrolled out of view.
    func photoRect(for id: String, in target: NSView) -> CGRect? {
        guard let row = rowIndex(of: id),
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? BubbleView,
              let r = cell.item?.mediaRect else { return nil }
        let rect = cell.convert(r, to: target)
        let visible = tableView.enclosingScrollView.map { $0.convert($0.bounds, to: target) } ?? target.bounds
        return visible.intersects(rect) ? rect : nil
    }
}
