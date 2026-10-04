import AppKit

/// What can be done to a message: reply, jump, open its media, the message menu with
/// the tapback bar, reactions (and their flight), edit and delete for everyone.
extension ConversationViewController {
    // MARK: message actions

    func reply(to m: Message) {
        guard m.kind != .revoked, m.kind != .pending else { return }
        editing = nil
        replyTo = m
        let name = m.fromMe ? "You" : m.senderName
        composer.showReply(name: name, text: Fmt.preview(kind: m.kind, text: m.text, fileName: m.fileName),
                           color: Theme.accent)
        composer.focus()
    }

    func toggleVoice(_ m: Message) {
        if m.mediaPath.isEmpty {
            pendingOpen = m.id
            Core.shared.call("download", ["chat": chat?.jid ?? "", "id": m.id, "retry": true])
            return
        }
        AudioPlayback.shared.toggle(m)
    }

    /// Redraws one message's bubble in place (voice progress ticks, avatar arrivals).
    func redraw(id: String) {
        guard let row = rowIndex(of: id),
              let v = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? BubbleView else { return }
        v.needsDisplay = true
    }

    /// Group sender pictures arrive asynchronously; repaint what's on screen.
    func refreshAvatars() {
        guard chat?.isGroup == true else { return }
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.length > 0 else { return }
        for i in range.location..<min(rows.count, range.location + range.length) {
            (tableView.view(atColumn: 0, row: i, makeIfNecessary: false) as? BubbleView)?.needsDisplay = true
        }
    }

    func expand(_ m: Message) {
        expanded.insert(m.id)
        apply(buildRows(), animateIn: [], scroll: .anchor)
    }

    func retry(_ m: Message) {
        Core.shared.call("retry", ["chat": chat?.jid ?? "", "id": m.id])
    }

    func jump(to id: String) {
        guard let c = chat, !id.isEmpty else { return }
        if rowIndex(of: id) == nil {
            guard let target = store.message(chat: c.jid, id: id) else { NSSound.beep(); return }
            msgs = store.messages(chat: c.jid, since: target, limit: 5000)
            hasMoreLocal = true
        }
        highlighted = id
        rebuildAndReload(.none)
        restore(.message(id), anchor: nil)
        // Once the scroll has brought it to the middle, the message says "here".
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.highlighted == id, let row = self.rowIndex(of: id) else { return }
            (self.tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? BubbleView)?.nudge()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.highlighted == id else { return }
            self.highlighted = nil
            if let row = self.rowIndex(of: id), let v = self.tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? BubbleView {
                v.fadeHighlight()
            }
        }
    }


    func open(media m: Message) {
        if m.kind == .voice || m.kind == .audio {
            toggleVoice(m)
            return
        }
        if m.kind == .location, let l = layouts[m.id]?.mapsURL {
            NSWorkspace.shared.open(l)
            return
        }
        guard m.hasMedia || !m.mediaPath.isEmpty else { return }
        if m.kind == .image {
            showViewer(m)   // shows the thumbnail and fetches the photo if it isn't here yet
            return
        }
        if m.kind == .sticker {
            if !m.mediaPath.isEmpty, FileManager.default.fileExists(atPath: m.mediaPath) {
                openStickerCard(m)
            } else {
                // Not here yet: fetch it (from the phone if the server dropped it), then open.
                pendingOpen = m.id
                Core.shared.call("download", ["chat": chat?.jid ?? "", "id": m.id, "retry": true])
            }
            return
        }
        if !m.mediaPath.isEmpty, FileManager.default.fileExists(atPath: m.mediaPath) {
            let url = URL(fileURLWithPath: m.mediaPath)
            if m.kind == .video {
                playInline(m, url: url)
            } else if m.kind == .image {
                showViewer(m)
            } else if m.kind == .sticker {
                return   // a sticker is part of the conversation, not a photo to open
            } else {
                NSWorkspace.shared.open(url)
            }
            return
        }
        pendingOpen = m.id
        Core.shared.call("download", ["chat": chat?.jid ?? "", "id": m.id, "retry": true])
    }

    /// A sticker's card, anchored on its bubble.
    func openStickerCard(_ m: Message) {
        guard let row = rowIndex(of: m.id),
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? BubbleView,
              let r = cell.item?.mediaRect else { return }
        showStickerCard(m, from: cell, at: r)
    }

    /// The message menu, laid out like Messages': reactions on top, then what you can do
    /// with the message, then what you can do to it, then deleting.
    func menu(for m: Message) -> NSMenu {
        let menu = NSMenu()
        var group: [NSMenuItem] = []
        func item(_ title: String, _ symbol: String?, _ action: @escaping @MainActor () -> Void) {
            let i = ClosureMenuItem(title: title, action: action)
            if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            group.append(i)
        }
        func endGroup() {
            guard !group.isEmpty else { return }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            group.forEach(menu.addItem)
            group = []
        }
        let live = m.kind != .revoked && m.kind != .pending

        if live {
            let mine = m.reactions?.mine
            let strip = ReactionStripView(recent: EmojiCatalog.recent, mine: mine?.isEmpty == false ? mine : nil,
                                          onPick: { [weak self] e, from in
                                              EmojiCatalog.used(e)
                                              if e == mine { self?.react(m, "") } else { self?.react(m, e, from: from, size: ReactionStripView.glyphSize) }
                                          },
                                          onMore: { [weak self] in self?.pickReaction(for: m) })
            let header = NSMenuItem()
            header.view = strip
            menu.addItem(header)
        }

        if live { item("Reply…", "arrowshape.turn.up.left") { [weak self] in self?.reply(to: m) } }
        if m.fromMe && live && m.kind == .text && Date().timeIntervalSince(m.date) < 15 * 60 {
            item("Edit…", "pencil") { [weak self] in self?.beginEdit(m) }
        }
        if live {
            item(m.starred ? "Unstar" : "Star", m.starred ? "star.slash" : "star") { [weak self] in
                guard let chat = self?.chat?.jid else { return }
                Task { _ = await Core.shared.callAsync("star", ["chat": chat, "id": m.id, "on": !m.starred]) }
            }
        }
        if m.fromMe && m.status == MessageStatus.failed {
            item("Try Again", "arrow.clockwise") { [weak self] in self?.retry(m) }
        }
        endGroup()

        if !m.text.isEmpty && live {
            item("Copy", "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(m.text, forType: .string)
            }
        }
        if m.hasMedia || !m.mediaPath.isEmpty {
            item(m.mediaPath.isEmpty ? "Download" : "Open", m.mediaPath.isEmpty ? "arrow.down.circle" : "eye") { [weak self] in self?.open(media: m) }
            if !m.mediaPath.isEmpty {
                item("Show in Finder", "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: m.mediaPath)]) }
            }
        }
        if m.kind == .sticker, !m.mediaPath.isEmpty {
            let sticker = StickerItem(path: m.mediaPath, mime: m.mime, width: m.width, height: m.height)
            let fav = StickerLibrary.hash(of: m.mediaPath).map { store.isFavoriteSticker(hash: $0) } ?? false
            item(fav ? "Remove from Favorites" : "Add to Favorites", fav ? "star.slash" : "star") {
                ConversationViewController.setFavorite(sticker, !fav)
            }
        }
        endGroup()

        if m.fromMe && live && Date().timeIntervalSince(m.date) < 2 * 24 * 3600 {
            item("Delete for Everyone…", "trash") { [weak self] in self?.confirmRevoke(m) }
        }
        endGroup()
        return menu
    }

    /// The menu's smiley: any emoji as the reaction, from a picker on the message.
    private func pickReaction(for m: Message) {
        guard let row = rowIndex(of: m.id),
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? BubbleView,
              let item = cell.item, let anchor = item.bubble ?? item.mediaRect ?? item.cardRect else { return }
        let picker = ReactionPickerViewController()
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = picker
        pop.contentSize = ReactionPickerViewController.size
        picker.onPick = { [weak self, weak pop] e in
            EmojiCatalog.used(e)
            // From the cell that was clicked, which is under the pointer.
            let at = NSEvent.mouseLocation
            self?.react(m, e, from: NSRect(x: at.x - 14, y: at.y - 14, width: 28, height: 28), size: 26)
            pop?.performClose(nil)
        }
        pop.show(relativeTo: anchor, of: cell, preferredEdge: .maxY)
    }

    /// `from` (screen coordinates) is where the emoji was picked; it flies from there to
    /// the message and lands as the badge.
    private func react(_ m: Message, _ emoji: String, from: CGRect? = nil, size: CGFloat = 0) {
        if let from, !emoji.isEmpty { flyReaction(m.id, emoji, from: from, size: size) }
        Core.shared.call("react", ["chat": chat?.jid ?? "", "id": m.id, "emoji": emoji])
    }

    func flyReaction(_ id: String, _ emoji: String, from: CGRect, size: CGFloat) {
        guard !Theme.reduceMotion, let window = view.window else { return }
        landing[id] = emoji
        ReactionFlight.fly(emoji, from: from, size: size, over: window, to: { [weak self] in
            guard let self, let row = self.rowIndex(of: id),
                  let cell = self.tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? BubbleView,
                  let r = cell.reactionLanding(for: emoji) else { return nil }
            return window.convertToScreen(r)
        }, landed: { [weak self] in
            guard let self else { return }
            self.landing[id] = nil
            if let row = self.rowIndex(of: id) {
                (self.tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? BubbleView)?.landReaction()
            }
        })
    }

    private func beginEdit(_ m: Message) {
        replyTo = nil
        editing = m
        composer.showReply(name: "Edit message", text: m.text, color: Theme.accent)
        composer.text = m.text
        composer.focus()
    }

    private func confirmRevoke(_ m: Message) {
        guard let window = view.window else { return }
        let a = NSAlert()
        a.messageText = "Delete this message for everyone?"
        a.informativeText = "It will be replaced with “This message was deleted” for everyone in the chat."
        a.addButton(withTitle: "Delete for Everyone")
        a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        a.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                _ = Core.shared.call("revoke", ["chat": self?.chat?.jid ?? "", "id": m.id])
            }
        }
    }
}
