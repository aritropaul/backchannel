import AppKit

/// The transcript: building rows from messages, applying them to the table with the
/// entrance animations, keeping the scroll position, paging older messages in.
extension ConversationViewController: NSTableViewDataSource, NSTableViewDelegate {
    // MARK: rows

    private static func statusText(_ m: Message) -> String? {
        switch m.status {
        case MessageStatus.pending: return "Sending…"
        case MessageStatus.sent: return "Sent"
        case MessageStatus.delivered: return "Delivered"
        case MessageStatus.read: return "Read"
        case MessageStatus.played: return m.kind == .voice ? "Played" : "Read"
        default: return nil
        }
    }

    func buildRows() -> [Row] {
        guard let c = chat else { return [.spacer] }
        let width = tableWidth
        var out: [Row] = [.spacer]
        var next: [String: MessageLayout] = [:]
        var total: CGFloat = 0
        let lastOutgoing = msgs.last { $0.fromMe && $0.kind != .revoked }?.id

        // A run breaks on a separator, a sender change, a 5-minute gap, the unread
        // divider, or around stickers/emoji-only messages.
        func separatorBefore(_ i: Int) -> Bool {
            guard i > 0 else { return true }
            let p = msgs[i - 1], m = msgs[i]
            return !Fmt.sameDay(p.date, m.date) || m.ts - p.ts > 45 * 60 * 1000
        }
        func breakBefore(_ i: Int) -> Bool {
            guard i > 0 else { return true }
            let p = msgs[i - 1], m = msgs[i]
            if separatorBefore(i) || m.id == unreadAnchorID { return true }
            return p.fromMe != m.fromMe || p.sender != m.sender || m.ts - p.ts > 5 * 60 * 1000
                || p.kind == .sticker || m.kind == .sticker
        }

        for (i, m) in msgs.enumerated() {
            if separatorBefore(i) {
                out.append(.separator(m.date))
                total += 30
            }
            if m.id == unreadAnchorID && unreadCount > 0 {
                out.append(.unread(unreadCount))
                total += 34
            }
            var flags = MessageLayout.Flags()
            flags.firstInRun = breakBefore(i)
            flags.lastInRun = i == msgs.count - 1 || breakBefore(i + 1)
            flags.showSender = c.isGroup && !m.fromMe && flags.firstInRun
            flags.gutter = c.isGroup && !m.fromMe
            flags.showAvatar = flags.gutter && flags.lastInRun
            flags.status = m.id == lastOutgoing ? Self.statusText(m) : nil
            flags.expanded = expanded.contains(m.id)
            flags.transcript = Transcripts.shared.phase(m.id)
            let l: MessageLayout
            if let old = layouts[m.id], old.msg == m, abs(old.width - width) < 0.5, old.flags == flags {
                l = old
            } else {
                l = MessageLayout(msg: m, width: width, flags: flags)
            }
            next[m.id] = l
            out.append(.message(l))
            total += l.height
        }
        if !typing.isEmpty {
            out.append(.typing)
            total += 48
        }
        layouts = next
        contentHeight = total + 8
        return out
    }

    func rebuildAndReload(_ scroll: Scroll) {
        reloading = true
        defer { reloading = false }
        let anchor = captureAnchor()
        rows = buildRows()
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()
        restore(scroll, anchor: anchor)
    }

    /// Applies new rows with the smallest table change: in-place updates
    /// crossfade, inserts animate in, removals fade. Large or prepended changes
    /// fall back to a plain reload so paging never animates.
    func apply(_ newRows: [Row], animateIn: Set<String>, scroll: Scroll) {
        let oldKeys = rows.map(\.key), newKeys = newRows.map(\.key)
        let diff = newKeys.difference(from: oldKeys)
        let prepended = diff.insertions.contains { if case .insert(let o, _, _) = $0 { return o == 1 && !oldKeys.isEmpty }; return false }
            && oldKeys.count > 1
        if diff.count > 40 || prepended {
            rows = newRows
            reloading = true
            let anchor = captureAnchor()
            tableView.reloadData()
            tableView.layoutSubtreeIfNeeded()
            restore(scroll == .bottomAnimated ? .bottom : scroll, anchor: anchor)
            reloading = false
            return
        }
        reloading = true
        defer { reloading = false }
        let anchor = captureAnchor()
        var removed = IndexSet(), inserted = IndexSet()
        for change in diff {
            switch change {
            case .remove(let o, _, _): removed.insert(o)
            case .insert(let o, _, _): inserted.insert(o)
            }
        }
        let oldRows = rows
        rows = newRows
        if !removed.isEmpty || !inserted.isEmpty {
            tableView.beginUpdates()
            if !removed.isEmpty { tableView.removeRows(at: removed, withAnimation: .effectFade) }
            if !inserted.isEmpty { tableView.insertRows(at: inserted, withAnimation: []) }
            tableView.endUpdates()
        }
        // In-place: same key, different layout object → rebind the live view.
        var heightChanged = IndexSet(integer: 0)
        var oldByKey: [String: Row] = [:]
        for r in oldRows { oldByKey[r.key] = r }
        for (i, r) in newRows.enumerated() where !inserted.contains(i) {
            guard case .message(let l) = r, case .message(let old)? = oldByKey[r.key], old !== l else { continue }
            if abs(old.height - l.height) > 0.1 { heightChanged.insert(i) }
            if let v = tableView.view(atColumn: 0, row: i, makeIfNecessary: false) as? BubbleView { v.item = l }
        }
        tableView.noteHeightOfRows(withIndexesChanged: heightChanged)
        tableView.layoutSubtreeIfNeeded()

        for i in inserted {
            guard i < rows.count else { continue }
            switch rows[i] {
            case .message(let l) where animateIn.contains(l.msg.id):
                if let v = tableView.view(atColumn: 0, row: i, makeIfNecessary: false) { animateEntrance(v, sent: l.msg.fromMe) }
            case .typing:
                (tableView.view(atColumn: 0, row: i, makeIfNecessary: false) as? TypingBubbleView)?.animateIn()
            default:
                if let v = tableView.view(atColumn: 0, row: i, makeIfNecessary: false) { Motion.fade(v.layer, duration: 0.2) }
            }
        }
        restore(scroll, anchor: anchor)
    }

    /// Sent bubbles rise out of the composer; received ones slide up into place.
    func animateEntrance(_ v: NSView, sent: Bool) {
        v.wantsLayer = true
        guard let layer = v.layer else { return }
        if Theme.reduceMotion {
            Motion.fade(layer)
            return
        }
        let down: CGFloat = (v.superview?.isFlipped ?? true) ? 1 : -1
        let t = Theme.spring("transform", response: sent ? 0.32 : 0.3, damping: sent ? 0.86 : 1)
        t.fromValue = CATransform3DMakeTranslation(0, down * (sent ? 28 : 10), 0)
        t.toValue = CATransform3DIdentity
        layer.add(t, forKey: "enter")
        Motion.fade(layer, from: sent ? 0.4 : 0, duration: 0.2)
        (v as? BubbleView)?.beatIfHeart()
    }

    func restore(_ scroll: Scroll, anchor: (id: String, offset: CGFloat)?) {
        switch scroll {
        case .none:
            break
        case .bottom:
            scrollToBottom(animated: false)
        case .bottomAnimated:
            scrollToBottom(animated: !Theme.reduceMotion)
        case .anchor:
            if let a = anchor, let row = rowIndex(of: a.id) {
                scrollTo(y: tableView.rect(ofRow: row).minY - a.offset)
            } else {
                scrollToBottom(animated: false)
            }
        case .unread:
            if let row = rows.firstIndex(where: { if case .unread = $0 { return true }; return false }) {
                scrollTo(y: tableView.rect(ofRow: row).minY - 24 - insets.top)
            } else {
                scrollToBottom(animated: false)
            }
        case .message(let id):
            if let row = rowIndex(of: id) {
                let r = tableView.rect(ofRow: row)
                scrollTo(y: r.midY - (clip.bounds.height + insets.top - insets.bottom) / 2 - insets.top / 2, animated: true)
            }
        }
        updateJump()
    }

    func rowIndex(of id: String) -> Int? {
        rows.firstIndex { if case .message(let l) = $0 { return l.msg.id == id }; return false }
    }

    private func captureAnchor() -> (id: String, offset: CGFloat)? {
        guard !rows.isEmpty, tableView.numberOfRows == rows.count else { return nil }
        let visible = clip.bounds
        let top = visible.minY + insets.top
        let range = tableView.rows(in: visible)
        guard range.length > 0 else { return nil }
        for i in range.location..<min(rows.count, range.location + range.length) {
            guard case .message(let l) = rows[i] else { continue }
            let r = tableView.rect(ofRow: i)
            if r.maxY > top { return (l.msg.id, r.minY - visible.minY) }
        }
        return nil
    }

    /// Bottom-anchored if we're there, or an animated scroll is already taking us there.
    var isAtBottom: Bool {
        let maxY = tableView.frame.height + insets.bottom - 40
        if let t = scrollTarget, t + clip.bounds.height >= maxY { return true }
        return clip.bounds.maxY >= maxY
    }

    private func scrollTo(y: CGFloat, animated: Bool = false) {
        let maxY = max(-insets.top, tableView.frame.height - clip.bounds.height + insets.bottom)
        let target = NSPoint(x: 0, y: min(max(-insets.top, y), maxY))
        if animated && abs(target.y - clip.bounds.minY) < clip.bounds.height * 2.5 {
            scrollTarget = target.y
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.32
                ctx.timingFunction = Theme.easeOut
                clip.animator().setBoundsOrigin(target)
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.scrollTarget == target.y else { return }
                    self.scrollTarget = nil
                    // Content may have grown during the animation: settle at the true bottom.
                    if target.y >= self.tableView.frame.height - self.clip.bounds.height + self.insets.bottom - 40 {
                        self.scrollToBottom(animated: false)
                    }
                }
            })
        } else {
            scrollTarget = nil
            clip.scroll(to: target)
        }
        scrollView.reflectScrolledClipView(clip)
    }

    func scrollToBottom(animated: Bool) {
        scrollTo(y: .greatestFiniteMagnitude, animated: animated)
    }

    @objc func jumpToLatest() {
        if msgs.count > Self.pageSize * 3, let c = chat {
            msgs = store.messages(chat: c.jid, limit: Self.pageSize)
            hasMoreLocal = true
            rebuildAndReload(.bottom)
            return
        }
        scrollToBottom(animated: !Theme.reduceMotion)
    }

    @objc func boundsChanged() {
        updateJump()
        guard !reloading, chat != nil else { return }
        if clip.bounds.minY + insets.top < 900 { loadOlder() }
    }

    private func loadOlder() {
        guard let c = chat, let first = msgs.first else { return }
        if hasMoreLocal {
            let older = store.messages(chat: c.jid, before: first, limit: Self.pageSize)
            if older.count < Self.pageSize { hasMoreLocal = false }
            if !older.isEmpty {
                msgs.insert(contentsOf: older, at: 0)
                rebuildAndReload(.anchor)
                return
            }
        }
        if !askedPhone {
            askedPhone = true
            Core.shared.call("older", ["chat": c.jid])
        }
    }

    private func updateJump() {
        let far = tableView.frame.height + insets.bottom - clip.bounds.maxY > 600
        guard far != jumpVisible, chat != nil else { return }
        jumpVisible = far
        guard let layer = jumpButton.layer else { jumpButton.isHidden = !far; return }
        if far {
            jumpButton.isHidden = false
            Motion.pop(layer, size: jumpButton.bounds.size, from: 0.85, response: 0.25, damping: 0.85)
        } else {
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.jumpVisible else { return }
                    self.jumpButton.isHidden = true
                    self.jumpButton.layer?.opacity = 1
                }
            }
            let o = CABasicAnimation(keyPath: "opacity")
            o.fromValue = 1
            o.toValue = 0
            o.duration = 0.12
            o.timingFunction = Theme.easeOut
            layer.opacity = 0
            layer.add(o, forKey: "fadeOut")
            CATransaction.commit()
        }
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return 1 }
        if case .spacer = rows[row] {
            let visible = clip.bounds.height - insets.top - insets.bottom
            return max(1, visible - contentHeight)
        }
        return rows[row].height
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("row")
        let v = tableView.makeView(withIdentifier: id, owner: nil) as? PlainRowView ?? PlainRowView()
        v.identifier = id
        return v
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .spacer:
            return nil
        case .separator(let d):
            let id = NSUserInterfaceItemIdentifier("sep")
            let v = tableView.makeView(withIdentifier: id, owner: nil) as? SeparatorView ?? SeparatorView()
            v.identifier = id
            v.date = d
            return v
        case .unread(let n):
            let id = NSUserInterfaceItemIdentifier("unread")
            let v = tableView.makeView(withIdentifier: id, owner: nil) as? UnreadBarView ?? UnreadBarView()
            v.identifier = id
            v.count = n
            return v
        case .typing:
            let id = NSUserInterfaceItemIdentifier("typing")
            let v = tableView.makeView(withIdentifier: id, owner: nil) as? TypingBubbleView ?? TypingBubbleView()
            v.identifier = id
            return v
        case .message(let l):
            let id = NSUserInterfaceItemIdentifier("msg")
            let v = tableView.makeView(withIdentifier: id, owner: nil) as? BubbleView ?? BubbleView()
            v.identifier = id
            v.controller = self
            v.item = l
            if v.playerView != nil, inlineVideo?.id != l.msg.id { stopInline() }   // its cell was reused
            v.highlight = l.msg.id == highlighted
            if l.wantsAutoDownload { Core.shared.call("download", ["chat": chat?.jid ?? "", "id": l.msg.id]) }
            if let jid = chat?.jid { Transcripts.shared.shown(l.msg, in: jid) }
            fillWaveformIfNeeded(l.msg)
            requestThumbIfNeeded(l.msg)
            return v
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}
