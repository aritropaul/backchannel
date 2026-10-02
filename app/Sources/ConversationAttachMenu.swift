import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// The composer's + menu (Messages' look, WhatsApp's items) and what each item does,
/// plus the buttons inside poll, event and contact-card bubbles.
extension ConversationViewController {
    private struct AttachItem {
        let title: String
        let symbol: String
        let color: NSColor
        let action: @MainActor (ConversationViewController) -> Void
    }

    private static let attachItems: [AttachItem] = [
        AttachItem(title: "Document", symbol: "doc.fill", color: NSColor(hex: 0x7F66FF)) { $0.pickDocuments() },
        AttachItem(title: "Photos & videos", symbol: "photo.on.rectangle.angled", color: NSColor(hex: 0x007BFC)) { $0.pickMedia() },
        AttachItem(title: "Camera", symbol: "camera.fill", color: NSColor(hex: 0xFF2E74)) { $0.openCamera() },
        AttachItem(title: "Audio", symbol: "headphones", color: NSColor(hex: 0xFA6533)) { $0.pickAudio() },
        AttachItem(title: "Contact", symbol: "person.fill", color: NSColor(hex: 0x009DE2)) { $0.pickContacts() },
        AttachItem(title: "Poll", symbol: "poll", color: NSColor(hex: 0xFFBC38)) { $0.newPoll() },
        AttachItem(title: "Event", symbol: "calendar", color: NSColor(hex: 0xFF3B6B)) { $0.newEvent() },
        AttachItem(title: "New sticker", symbol: "plus.square.on.square", color: NSColor(hex: 0x02A698)) { $0.newSticker() },
    ]

    /// A filled circle with a white glyph, like the icons in Messages' + menu.
    static func attachIcon(_ symbol: String, _ color: NSColor, size: CGFloat = 26) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            color.setFill()
            NSBezierPath(ovalIn: r).fill()
            if symbol == "poll" {
                // Three left-aligned bars, the poll glyph WhatsApp and Messages share.
                NSColor.white.setFill()
                let h = size * 0.09, gap = size * 0.07, x = r.minX + size * 0.29
                for (i, len) in [0.30, 0.44, 0.22].enumerated() {
                    let y = r.midY + h * 1.5 + gap - CGFloat(i) * (h + gap) - h
                    let bar = CGRect(x: x, y: y, width: size * CGFloat(len), height: h)
                    NSBezierPath(roundedRect: bar, xRadius: h / 2, yRadius: h / 2).fill()
                }
                return true
            }
            let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .semibold)
                .applying(.init(paletteColors: [.white]))
            if let g = (NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "doc.fill", accessibilityDescription: nil))?.withSymbolConfiguration(cfg) {
                let s = g.size
                g.draw(in: CGRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height))
            }
            return true
        }
    }

    /// Dev: the menu's rows drawn to an image (menus on another Space can't be captured).
    static func attachMenuPreview(dark: Bool) -> NSImage {
        let rowH: CGFloat = 34, w: CGFloat = 200
        let img = NSImage(size: NSSize(width: w, height: rowH * CGFloat(attachItems.count) + 12), flipped: true) { r in
            (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.97, alpha: 1)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12).fill()
            for (i, item) in attachItems.enumerated() {
                let y = 6 + CGFloat(i) * rowH
                attachIcon(item.symbol, item.color).draw(in: CGRect(x: 12, y: y + 4, width: 26, height: 26))
                NSAttributedString(string: item.title, attributes: [.font: NSFont.menuFont(ofSize: 13),
                    .foregroundColor: dark ? NSColor.white : NSColor.black]).draw(at: CGPoint(x: 48, y: y + 8))
            }
            return true
        }
        return img
    }

    /// The + menu while it's open (dev hook closes it).
    static weak var openAttachMenu: NSMenu?

    func showAttachMenu(from anchor: NSView) {
        guard chat != nil else { return }
        let menu = NSMenu()
        for item in Self.attachItems {
            let i = ClosureMenuItem(title: item.title) { [weak self] in
                guard let self else { return }
                item.action(self)
            }
            i.image = Self.attachIcon(item.symbol, item.color)
            menu.addItem(i)
        }
        Self.openAttachMenu = menu
        // Opens upward from the button, its bottom edge just above it, as in Messages.
        // The point is the menu's top-left; buttons are flipped (y grows downward).
        let gap: CGFloat = 8
        let top = anchor.isFlipped ? -(menu.size.height + gap) : anchor.bounds.height + menu.size.height + gap
        menu.popUp(positioning: nil, at: NSPoint(x: -4, y: top), in: anchor)
    }

    // MARK: Document, Photos & videos

    func pickDocuments() {
        guard let window = view.window else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = [.item]
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.message = "Files go as documents, at full quality."
        p.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK else { return }
            let urls = p.urls
            MainActor.assumeIsolated { self?.attachMany(urls, asDocuments: true) }
        }
    }

    func pickMedia() {
        guard let window = view.window else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image, .movie]
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK else { return }
            let urls = p.urls
            MainActor.assumeIsolated { self?.attachMany(urls, asDocuments: false) }
        }
    }

    /// The first file waits in the composer for a caption; the rest follow it when it's sent.
    func attachMany(_ urls: [URL], asDocuments: Bool) {
        guard let first = urls.first else { return }
        queuedAttachments = Array(urls.dropFirst())
        queueAsDocuments = asDocuments
        if asDocuments {
            let type = (try? first.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? .data
            prepareDocument(first, type: type)
        } else {
            attach(first)
        }
    }

    /// " · 3 more" after the attachment label when several files were picked.
    var queuedSuffix: String { queuedAttachments.isEmpty ? "" : " · \(queuedAttachments.count) more" }

    /// Sends the files picked along with the one that carried the caption, in order.
    func sendQueuedAttachments() {
        guard let c = chat, !queuedAttachments.isEmpty else { return }
        let urls = queuedAttachments, docs = queueAsDocuments
        queuedAttachments = []
        Task { @MainActor in
            for url in urls {
                let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
                    ?? UTType(filenameExtension: url.pathExtension) ?? .data
                if docs || !(type.conforms(to: .image) || type.conforms(to: .movie)) {
                    _ = await Core.shared.callAsync("send_file", ["chat": c.jid, "path": url.path, "name": url.lastPathComponent,
                                                                  "mime": type.preferredMIMEType ?? "application/octet-stream"])
                } else if type.conforms(to: .movie) {
                    guard let f = await Self.encodeVideo(url) else { continue }
                    _ = await Core.shared.callAsync("send_file", ["chat": c.jid, "path": f.path, "name": f.name, "mime": f.mime,
                                                                  "thumb": f.thumb ?? "", "width": f.width, "height": f.height,
                                                                  "seconds": f.seconds])
                } else {
                    guard let out = await Self.encodePhoto(url) else { continue }
                    _ = await Core.shared.callAsync("send_image", ["chat": c.jid, "path": out.path, "thumb": out.thumb,
                                                                   "width": out.w, "height": out.h, "mime": "image/jpeg"])
                }
            }
        }
    }

    // MARK: Camera

    func openCamera() {
        let cam = CameraViewController()
        cam.onPhoto = { [weak self] url in self?.prepareImage(url) }
        presentAsSheet(cam)
    }

    // MARK: Audio

    func pickAudio() {
        guard let window = view.window else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio]
        p.allowsMultipleSelection = false
        p.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = p.url else { return }
            MainActor.assumeIsolated { self?.prepareAudio(url) }
        }
    }

    /// Music goes as audio (the player bubble). WhatsApp plays MP3, AAC/M4A, OGG/Opus and
    /// AMR; anything else is converted to M4A. Over 16 MB it goes as a document instead.
    func prepareAudio(_ url: URL) {
        guard let c = chat else { return }
        pendingImage = nil
        pendingFile = nil
        queuedAttachments = []
        composer.showAttachment(Self.attachIcon("headphones", NSColor(hex: 0xFA6533), size: 40), label: "Preparing audio…")
        Task { [weak self] in
            let out = await Self.encodeAudio(url)
            guard let self, self.chat?.jid == c.jid else { return }
            guard let out else {
                NSSound.beep()
                self.composer.hideAttachment(animated: true)
                return
            }
            if out.size > 16_000_000 {
                self.prepareDocument(url, type: (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? .audio)
                return
            }
            self.pendingFile = out.file
            self.composer.showAttachment(Self.attachIcon("headphones", NSColor(hex: 0xFA6533), size: 40),
                                         label: "\(url.deletingPathExtension().lastPathComponent) · \(Fmt.duration(out.file.seconds)). Press Return to send.")
            self.composer.focus()
        }
    }

    @concurrent nonisolated static func encodeAudio(_ url: URL) async -> (file: PendingFile, size: Int64)? {
        let asset = AVURLAsset(url: url)
        let seconds = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
        guard seconds.isFinite, seconds > 0 else { return nil }
        let ext = url.pathExtension.lowercased()
        let native: [String: String] = ["mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/aac", "ogg": "audio/ogg",
                                        "opus": "audio/ogg; codecs=opus", "amr": "audio/amr"]
        var path = url, mime = native[ext] ?? ""
        if mime.isEmpty {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
            guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
            do { try await export.export(to: out, as: .m4a) } catch { return nil }
            path = out
            mime = "audio/mp4"
        }
        let size = Int64((try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        var f = PendingFile(path: path.path, name: url.deletingPathExtension().lastPathComponent, mime: mime)
        f.seconds = Int(seconds.rounded())
        f.isAudio = true
        return (f, size)
    }

    // MARK: Contact

    func pickContacts() {
        let picker = ContactPickerViewController(store: store, exclude: chat?.jid)
        picker.onSend = { [weak self] people in
            guard let self, let c = self.chat else { return }
            Task { @MainActor in
                let r = await Core.shared.callAsync("send_contacts", ["chat": c.jid, "contacts": people.map {
                    ["name": $0.name, "phone": JID.user($0.jid)]
                }])
                if r["error"] != nil { NSSound.beep() }
            }
        }
        presentAsSheet(picker)
    }

    // MARK: Poll

    func newPoll() {
        let sheet = PollComposerViewController()
        sheet.onSend = { [weak self] question, options, multi in
            guard let c = self?.chat else { return }
            Task { @MainActor in
                let r = await Core.shared.callAsync("send_poll", ["chat": c.jid, "text": question, "options": options, "multi": multi])
                if r["error"] != nil { NSSound.beep() }
            }
        }
        presentAsSheet(sheet)
    }

    // MARK: Event

    func newEvent() {
        let sheet = EventComposerViewController()
        sheet.onSend = { [weak self] e in
            guard let c = self?.chat else { return }
            Task { @MainActor in
                var args: [String: Any] = ["chat": c.jid, "text": e.name, "start": Int64(e.start.timeIntervalSince1970),
                                           "desc": e.desc, "location": e.location, "allow_guests": e.allowGuests]
                if let end = e.end { args["end"] = Int64(end.timeIntervalSince1970) }
                let r = await Core.shared.callAsync("send_event", args)
                if r["error"] != nil { NSSound.beep() }
            }
        }
        presentAsSheet(sheet)
    }

    // MARK: New sticker

    func newSticker() {
        guard let window = view.window else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = false
        p.message = "Pick a photo to make into a sticker."
        p.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = p.url else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                let maker = StickerMakerViewController(source: url)
                maker.onSend = { [weak self] png in
                    guard let c = self?.chat else { return }
                    Task { @MainActor in
                        let r = await Core.shared.callAsync("send_sticker", ["chat": c.jid, "path": png.path])
                        if r["error"] != nil { NSSound.beep() }
                    }
                }
                self.presentAsSheet(maker)
            }
        }
    }

    // MARK: Card buttons

    func cardAction(_ m: Message, _ hit: RichCard.Hit, from source: NSView) {
        guard let c = chat else { return }
        switch hit {
        case .pollOption(let name):
            guard let poll = m.poll else { return }
            var picked = Set(m.myVote?.options ?? [])
            if poll.multi {
                if picked.contains(name) { picked.remove(name) } else { picked.insert(name) }
            } else {
                picked = picked == [name] ? [] : [name]
            }
            let ordered = poll.options.filter { picked.contains($0) }
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            Task { @MainActor in
                let r = await Core.shared.callAsync("vote_poll", ["chat": c.jid, "id": m.id, "options": ordered])
                if r["error"] != nil { NSSound.beep() }
            }
        case .pollVotes:
            showDetails(VotesView(message: m), for: m, from: source)
        case .eventRespond(let response):
            guard m.myVote?.response != response else { return }
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            Task { @MainActor in
                let r = await Core.shared.callAsync("respond_event", ["chat": c.jid, "id": m.id, "response": response])
                if r["error"] != nil { NSSound.beep() }
            }
        case .eventDetails:
            let details = VotesView(message: m)
            details.onCancelEvent = { [weak self] in self?.confirmCancelEvent(m) }
            showDetails(details, for: m, from: source)
        case .contactMessage(let jid):
            openChat(jid: jid)
        case .contactAdd(let i):
            guard let cards = m.contactCards?.cards, i < cards.count else { return }
            Self.openVCard(cards[i])
        case .contactAll:
            guard let cards = m.contactCards?.cards else { return }
            let menu = NSMenu()
            for card in cards {
                let item = NSMenuItem(title: card.name.isEmpty ? card.number : card.name, action: nil, keyEquivalent: "")
                item.image = Avatars.shared.monogram(name: card.name, jid: card.jid ?? card.name, isGroup: false).resized(to: 20)
                let sub = NSMenu()
                if let jid = card.jid {
                    sub.addItem(ClosureMenuItem(title: "Message") { [weak self] in self?.openChat(jid: jid) })
                }
                sub.addItem(ClosureMenuItem(title: "Add to Contacts") { Self.openVCard(card) })
                item.submenu = sub
                menu.addItem(item)
            }
            let p = source.convert(NSEvent.mouseLocation.convertedFromScreen(in: source.window), from: nil)
            menu.popUp(positioning: nil, at: p, in: source)
        }
    }

    private func openChat(jid: String) {
        Task { @MainActor [weak self] in
            let r = await Core.shared.callAsync("resolve", ["phone": JID.user(jid)])
            guard let self else { return }
            if let err = r["error"] as? String {
                let a = NSAlert()
                a.messageText = "Couldn't open this chat"
                a.informativeText = err
                if let w = self.view.window { a.beginSheetModal(for: w, completionHandler: nil) }
                return
            }
            self.onOpenChat?((r["jid"] as? String) ?? jid)
        }
    }

    /// Hands a contact card to Contacts, which offers to add it.
    static func openVCard(_ card: ContactCards.Card) {
        var lines = ["BEGIN:VCARD", "VERSION:3.0", "FN:\(card.name)"]
        for p in card.phones ?? [] {
            lines.append(p.waid.map { "TEL;type=CELL;waid=\($0):\(p.num)" } ?? "TEL;type=CELL:\(p.num)")
        }
        lines.append("END:VCARD")
        let name = (card.name.isEmpty ? "Contact" : card.name).replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).vcf")
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(url)
    }

    private func showDetails(_ content: NSView, for m: Message, from source: NSView) {
        let vc = NSViewController()
        vc.view = content
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = vc
        pop.contentSize = content.fittingSize
        let anchor = (source as? BubbleView)?.item?.frame ?? source.bounds
        pop.show(relativeTo: anchor, of: source, preferredEdge: m.fromMe ? .minX : .maxX)
    }

    private func confirmCancelEvent(_ m: Message) {
        guard let window = view.window, let c = chat else { return }
        let a = NSAlert()
        a.messageText = "Cancel “\(m.text)”?"
        a.informativeText = "Everyone in this chat sees that the event was cancelled. You can't undo this."
        a.addButton(withTitle: "Cancel Event").hasDestructiveAction = true
        a.addButton(withTitle: "Keep Event")
        a.beginSheetModal(for: window) { resp in
            guard resp == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                let r = await Core.shared.callAsync("cancel_event", ["chat": c.jid, "id": m.id])
                if r["error"] != nil { NSSound.beep() }
            }
        }
    }
}

extension NSPoint {
    /// A screen point in a window's coordinates.
    @MainActor func convertedFromScreen(in window: NSWindow?) -> NSPoint {
        guard let window else { return self }
        return window.convertPoint(fromScreen: self)
    }
}

extension NSImage {
    func resized(to side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
            NSBezierPath(ovalIn: r).addClip()
            self.draw(in: r)
            return true
        }
    }
}
