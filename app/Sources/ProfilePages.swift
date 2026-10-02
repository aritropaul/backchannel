import AppKit
import ImagePlayground
import UniformTypeIdentifiers

/// The pages behind the contact info rows, and the actions at the bottom of it.
extension ProfileViewController {

    // MARK: Media, links and docs

    func pushMedia() {
        guard let c = chat else { return }
        let page = ProfilePage(title: "Media, links and docs")
        let tabs = GlassSegmentedControl(labels: ["Media", "Links", "Docs"])
        page.add(tabs)
        let body = NSStackView()
        body.orientation = .vertical
        body.spacing = 4
        page.add(body)
        func fill(_ tab: Int) {
            body.arrangedSubviews.forEach { $0.removeFromSuperview() }
            switch tab {
            case 0: mediaGrid(c, into: body)
            case 1: messageList(store.linkItems(c.jid), empty: "No links", into: body) { [weak self] m in self?.linkRow(m, chat: c) }
            default: messageList(store.docItems(c.jid), empty: "No documents", into: body) { [weak self] m in self?.docRow(m, chat: c) }
            }
        }
        tabs.onChange = { fill($0) }
        fill(0)
        push(page)
    }

    private func mediaGrid(_ c: Chat, into body: NSStackView) {
        let items = store.mediaItems(c.jid)
        guard !items.isEmpty else {
            body.addArrangedSubview(ProfilePage.note("No photos or videos"))
            return
        }
        var row: NSStackView?
        for (i, m) in items.enumerated() {
            if i % 3 == 0 {
                let r = NSStackView()
                r.spacing = 4
                r.distribution = .fillEqually
                body.addArrangedSubview(r)
                r.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
                row = r
            }
            row?.addArrangedSubview(MediaThumb(m, chat: c.jid) { [weak self] in self?.onJump?(c.jid, m.id) })
        }
        if let r = row, items.count % 3 != 0 {
            for _ in 0..<(3 - items.count % 3) { r.addArrangedSubview(NSView()) }
        }
    }

    private func messageList(_ items: [Message], empty: String, into body: NSStackView, row: (Message) -> NSView?) {
        guard !items.isEmpty else {
            body.addArrangedSubview(ProfilePage.note(empty))
            return
        }
        let card = Card()
        card.setRows(items.compactMap(row))
        body.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
    }

    private func linkRow(_ m: Message, chat c: Chat) -> NSView? {
        let url = m.linkURL.isEmpty ? Self.firstURL(in: m.text) : URL(string: m.linkURL)
        let title = m.linkTitle.isEmpty ? (url?.absoluteString ?? m.text) : m.linkTitle
        let open = CircleAction(symbol: "arrow.up.right", tip: "Open link", size: 26) {
            if let url { NSWorkspace.shared.open(url) }
        }
        return NavRow(symbol: "link", title: title, subtitle: "\(url?.host() ?? "") · \(Fmt.listStamp(m.date))",
                      chevron: false, iconTint: .secondaryLabelColor, trailing: open) { [weak self] in
            self?.onJump?(c.jid, m.id)
        }
    }

    private func docRow(_ m: Message, chat c: Chat) -> NSView? {
        let ext = (m.fileName as NSString).pathExtension
        let icon = NSImageView(image: NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let size = m.fileSize > 0 ? Fmt.bytes(m.fileSize) + " · " : ""
        let row = NavRow(symbol: nil, title: m.fileName.isEmpty ? "Document" : m.fileName, subtitle: size + Fmt.listStamp(m.date),
                         chevron: false, trailing: nil) { [weak self] in
            if !m.mediaPath.isEmpty, FileManager.default.fileExists(atPath: m.mediaPath) {
                NSWorkspace.shared.open(URL(fileURLWithPath: m.mediaPath))
            } else {
                self?.onJump?(c.jid, m.id)
            }
        }
        let wrap = NSStackView(views: [icon, row])
        wrap.spacing = 10
        wrap.alignment = .centerY
        return wrap
    }

    static func firstURL(in text: String) -> URL? {
        let d = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return d?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.url
    }

    // MARK: Manage storage

    func pushStorage() {
        guard let c = chat else { return }
        let page = ProfilePage(title: "Manage storage")
        func build() {
            page.clear()
            var sizes: [String: Int64] = [:]
            var total: Int64 = 0
            for d in store.downloads(c.jid) {
                let n = Fmt.fileSize(d.path)
                total += n
                let bucket: String = switch d.kind {
                case .image, .sticker: "Photos"
                case .video: "Videos"
                case .voice, .audio: "Voice messages and audio"
                case .document: "Documents"
                default: "Other"
                }
                sizes[bucket, default: 0] += n
            }
            let big = NSTextField(labelWithString: Fmt.bytes(total))
            big.font = .systemFont(ofSize: 28, weight: .semibold)
            page.add(big)
            page.add(ProfilePage.note("Downloaded to this Mac from this chat. Deleting them frees the space; the messages stay, and anything you open again downloads again."))
            let order = ["Photos", "Videos", "Voice messages and audio", "Documents", "Other"]
            let card = Card()
            card.setRows(order.compactMap { k in
                guard let n = sizes[k], n > 0 else { return nil }
                return NavRow(symbol: nil, title: k, detail: Fmt.bytes(n), chevron: false, action: nil)
            })
            if !sizes.isEmpty { page.add(card) }
            if total > 0 {
                let del = Card()
                del.setRows([actionRow("Delete downloaded media…", color: .systemRed) { [weak self] in
                    self?.confirm("Delete \(Fmt.bytes(total)) of downloaded media?",
                                  "The photos, videos, voice messages and documents from this chat are removed from this Mac. The messages stay in the chat.",
                                  "Delete") {
                        Task { @MainActor in
                            _ = await Core.shared.callAsync("clear_media", ["chat": c.jid])
                            build()
                        }
                    }
                }])
                page.add(del)
            }
        }
        build()
        push(page)
    }

    // MARK: Starred

    func pushStarred() {
        guard let c = chat else { return }
        let page = ProfilePage(title: "Starred")
        func build() {
            page.clear()
            let items = store.starred(c.jid)
            guard !items.isEmpty else {
                page.add(ProfilePage.note("No starred messages. Star one from its menu (right-click a message) to find it here."))
                return
            }
            let card = Card()
            card.setRows(items.map { m in
                let who = m.fromMe ? "You" : m.senderName
                let text = m.text.isEmpty ? Fmt.preview(kind: m.kind, text: m.text, fileName: m.fileName) : m.text
                let row = NavRow(symbol: "star.fill", title: who, subtitle: text, detail: Fmt.listStamp(m.date), chevron: false,
                                 iconTint: .systemYellow) { [weak self] in self?.onJump?(c.jid, m.id) }
                let menu = NSMenu()
                menu.addItem(ClosureMenuItem(title: "Unstar") {
                    Task { @MainActor in
                        _ = await Core.shared.callAsync("star", ["chat": c.jid, "id": m.id, "on": false])
                        build()
                    }
                })
                row.menu = menu
                return row
            })
            page.add(card)
        }
        build()
        push(page)
    }

    // MARK: Notifications

    func pushNotifications() {
        guard let c0 = chat else { return }
        let page = ProfilePage(title: "Notifications")
        func build() {
            page.clear()
            let c = store.chat(c0.jid) ?? c0
            let jid = c.jid
            page.add(ProfilePage.note("MUTE", size: 11, weight: .semibold))
            let forever = c.mutedUntil == -1
            let mute = Card()
            func set(_ on: Bool, _ hours: Int) {
                Core.shared.call("mute", ["chat": jid, "on": on, "hours": hours])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { build() }
            }
            var until = ""
            if c.isMuted && !forever {
                until = "Until " + Fmt.tooltip(Date(timeIntervalSince1970: TimeInterval(c.mutedUntil)))
            }
            mute.setRows([
                choiceRow("Off", checked: !c.isMuted) { set(false, 0) },
                choiceRow("8 hours", checked: false) { set(true, 8) },
                choiceRow("1 week", checked: false) { set(true, 168) },
                choiceRow("Always", checked: forever) { set(true, 0) },
            ])
            page.add(mute)
            if !until.isEmpty { page.add(ProfilePage.note(until)) }

            page.add(ProfilePage.note("SOUND", size: 11, weight: .semibold))
            let popup = NSPopUpButton()
            popup.controlSize = .small
            let current = ChatPrefs.sound(jid)
            let global = Prefs.notifySound == "default" ? "Default" : Prefs.notifySound == "none" ? "None" : Prefs.notifySound
            let options = [("", "Same as Settings (\(global))"), ("default", "Default"), ("none", "None")] + Prefs.alertSounds.map { ($0, $0) }
            for (v, t) in options {
                popup.addItem(withTitle: t)
                popup.lastItem?.representedObject = v
                if v == current { popup.select(popup.lastItem) }
            }
            popup.target = SoundPicker.shared
            popup.action = #selector(SoundPicker.picked(_:))
            SoundPicker.shared.jid = jid
            let sound = Card()
            sound.setRows([NavRow(symbol: "speaker.wave.2", title: "Tone", chevron: false, trailing: popup, action: nil)])
            page.add(sound)
            page.add(ProfilePage.note("A muted chat stays silent and doesn't count toward the Dock badge. The tone plays only on this Mac."))
        }
        build()
        push(page)
    }

    // MARK: Save to Photos

    func pushSaveToPhotos() {
        guard let c = chat else { return }
        let page = ProfilePage(title: "Save to Photos")
        func build() {
            page.clear()
            let mode = ChatPrefs.saveMode(c.jid)
            let card = Card()
            func set(_ m: ChatPrefs.SaveMode) {
                ChatPrefs.setSaveMode(c.jid, m)
                build()
            }
            card.setRows([
                choiceRow("Default (\(Prefs.saveToPhotos ? "On" : "Off"))", checked: mode == .default) { set(.default) },
                choiceRow("Always", checked: mode == .always) { set(.always) },
                choiceRow("Never", checked: mode == .never) { set(.never) },
            ])
            page.add(card)
            page.add(ProfilePage.note("Photos and videos you receive in this chat are added to your Photos library as they download. Default follows Settings › Chats."))
        }
        build()
        push(page)
    }

    // MARK: Disappearing messages

    func pushDisappearing() {
        guard let c0 = chat else { return }
        let page = ProfilePage(title: "Disappearing messages")
        func build() {
            page.clear()
            let c = store.chat(c0.jid) ?? c0
            page.add(Self.hero("timer"))
            page.add(ProfilePage.note("Make messages in this chat disappear. New messages vanish from everyone's devices after the time you pick. Anyone in the chat can change this.", size: 13))
            let card = Card()
            func set(_ secs: Int) {
                Task { @MainActor [weak self] in
                    let r = await Core.shared.callAsync("set_timer", ["chat": c.jid, "seconds": secs])
                    if self?.showError(r) == false { build() }
                }
            }
            card.setRows([
                choiceRow("24 hours", checked: c.ephemeral == 86_400) { set(86_400) },
                choiceRow("7 days", checked: c.ephemeral == 604_800) { set(604_800) },
                choiceRow("90 days", checked: c.ephemeral == 7_776_000) { set(7_776_000) },
                choiceRow("Off", checked: c.ephemeral == 0) { set(0) },
            ])
            page.add(card)
            page.add(ProfilePage.note("Messages already in the chat stay. Anyone can still forward, copy or screenshot a message before it disappears."))
        }
        build()
        push(page)
    }

    // MARK: Advanced chat privacy

    func pushAdvancedPrivacy() {
        guard let c0 = chat else { return }
        let page = ProfilePage(title: "Advanced chat privacy")
        func build() {
            page.clear()
            let c = store.chat(c0.jid) ?? c0
            page.add(Self.hero("checkerboard.shield"))
            page.add(ProfilePage.note("Keep what's said in this chat inside it. When this is on, everyone in the chat is stopped from:", size: 13))
            let list = Card()
            list.setRows([
                NavRow(symbol: "square.and.arrow.up", title: "Exporting the chat", chevron: false, action: nil),
                NavRow(symbol: "arrow.down.circle", title: "Auto-downloading media to their phone", chevron: false, action: nil),
                NavRow(symbol: "sparkles", title: "Using messages for AI features", chevron: false, action: nil),
            ])
            page.add(list)
            let sw = NSSwitch()
            sw.state = c.limitSharing ? .on : .off
            let toggle = Card()
            let flip: () -> Void = {
                Task { @MainActor [weak self] in
                    let r = await Core.shared.callAsync("limit_sharing", ["chat": c.jid, "on": !c.limitSharing])
                    if self?.showError(r) == false { build() }
                }
            }
            sw.target = ClosureTarget.shared
            sw.action = #selector(ClosureTarget.fire(_:))
            ClosureTarget.shared.register(sw, flip)
            toggle.setRows([NavRow(symbol: nil, title: "Advanced chat privacy", chevron: false, trailing: sw) { flip() }])
            page.add(toggle)
            page.add(ProfilePage.note("Everyone in the chat sees when it's turned on or off."))
        }
        build()
        push(page)
    }

    // MARK: Encryption

    func pushEncryption() {
        guard let c = chat else { return }
        let page = ProfilePage(title: "Encryption")
        page.add(Self.hero("lock.fill"))
        page.add(ProfilePage.note(c.isGroup
            ? "Messages in this group are end-to-end encrypted. They stay between the people in it; not even WhatsApp can read them."
            : "Messages and calls with \(c.name) are end-to-end encrypted. They stay between you; not even WhatsApp can read or listen to them.", size: 13))
        page.add(ProfilePage.note("To compare security codes, open this chat's encryption screen on your phone. This Mac can't show the code yet. If a code changes, Settings › Account › Security notifications can put a notice in the chat."))
        let card = Card()
        card.setRows([actionRow("Learn more", color: Theme.accent) {
            if let u = URL(string: "https://faq.whatsapp.com/820124435853543") { NSWorkspace.shared.open(u) }
        }])
        page.add(card)
        push(page)
    }

    // MARK: Contact details

    func pushContactDetails() {
        guard let c = chat else { return }
        let page = ProfilePage(title: "Contact details")
        let names = store.contactNames(c.jid)
        var rows: [NSView] = []
        if !names.saved.isEmpty { rows.append(Card.labeled("name", names.saved)) }
        if !names.push.isEmpty { rows.append(Card.labeled("WhatsApp name", "~" + names.push)) }
        rows.append(Card.labeled("mobile", JID.phone(c.jid), selectable: true))
        if let about = (lastInfo["about"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !about.isEmpty {
            rows.append(Card.labeled("about", about))
        }
        if let biz = lastInfo["business"] as? String, !biz.isEmpty { rows.append(Card.labeled("business", biz)) }
        let info = Card()
        info.setRows(rows)
        page.add(info)
        let actions = Card()
        actions.setRows([
            actionRow("Copy phone number", color: Theme.accent) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(JID.phone(c.jid), forType: .string)
            },
            actionRow("Add to Contacts", color: Theme.accent) { Self.openVCard(name: names.saved.isEmpty ? c.name : names.saved, jid: c.jid) },
        ])
        page.add(actions)
        push(page)
    }

    /// Hands a vCard to Contacts, which offers to add it (no Contacts permission needed).
    static func openVCard(name: String, jid: String) {
        let digits = JID.user(jid)
        let card = "BEGIN:VCARD\nVERSION:3.0\nFN:\(name)\nTEL;type=CELL;waid=\(digits):+\(digits)\nEND:VCARD\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name.replacingOccurrences(of: "/", with: "-")).vcf")
        try? card.write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(url)
    }

    // MARK: Groups

    func pushCommonGroups() {
        guard let c = chat else { return }
        let page = ProfilePage(title: "Groups in common")
        let card = Card()
        card.setRows(store.commonGroups(with: c.jid).map { g in
            PersonRow(jid: g.jid, name: g.name, subtitle: g.members.joined(separator: ", "), isGroup: true, avatar: g.avatar) { [weak self] in
                self?.onOpenChat?(g.jid)
            }
        })
        page.add(card)
        push(page)
    }

    func pushAddToGroup() {
        guard let c = chat else { return }
        let page = ProfilePage(title: "Add to group")
        let groups = store.groupsICanAdd(c.jid)
        if groups.isEmpty {
            page.add(ProfilePage.note("You're not an admin of any group \(c.name) isn't already in."))
        } else {
            page.add(ProfilePage.note("Groups you're an admin of", size: 11, weight: .semibold))
            let card = Card()
            card.setRows(groups.map { g in
                PersonRow(jid: g.jid, name: g.name, subtitle: "", isGroup: true, avatar: g.avatar, chevron: false) { [weak self] in
                    self?.confirm("Add \(c.name) to “\(g.name)”?", "Everyone in the group sees that you added them.", "Add") {
                        Task { @MainActor [weak self] in
                            let r = await Core.shared.callAsync("add_to_group", ["chat": g.jid, "phone": c.jid])
                            guard let self, !self.showError(r) else { return }
                            self.pop()
                        }
                    }
                }
            })
            page.add(card)
        }
        push(page)
    }

    func createGroup(with c: Chat) {
        guard let window = view.window else { return }
        let a = NSAlert()
        a.messageText = "New group with \(c.name)"
        a.informativeText = "Give the group a name. You can add more people later."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Group name"
        a.accessoryView = field
        a.addButton(withTitle: "Create")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        a.beginSheetModal(for: window) { resp in
            guard resp == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor [weak self] in
                let r = await Core.shared.callAsync("create_group", ["name": name, "jids": [c.jid]])
                guard let self, !self.showError(r), let jid = r["jid"] as? String else { return }
                self.onOpenChat?(jid)
            }
        }
    }

    // MARK: Share contact

    func pushShareContact() {
        guard let c = chat else { return }
        let page = ProfilePage(title: "Share contact")
        let field = NSSearchField()
        field.placeholderString = "Send \(c.name) to…"
        page.add(field)
        let results = Card()
        page.add(results)
        func fill() {
            let people = store.people(matching: field.stringValue.trimmingCharacters(in: .whitespaces), limit: 30).filter { $0.jid != c.jid }
            results.setRows(people.map { p in
                PersonRow(jid: p.jid, name: p.name, subtitle: p.subtitle, isGroup: p.isGroup, avatar: store.avatar(p.jid), chevron: false) { [weak self] in
                    self?.confirm("Send \(c.name)'s contact to \(p.name)?", "They'll get a contact card with \(c.name)'s name and number.", "Send") {
                        Task { @MainActor [weak self] in
                            let r = await Core.shared.callAsync("send_contact", ["chat": p.jid, "name": c.name, "phone": JID.user(c.jid)])
                            guard let self, !self.showError(r) else { return }
                            self.onOpenChat?(p.jid)
                        }
                    }
                }
            })
        }
        field.target = ClosureTarget.shared
        field.action = #selector(ClosureTarget.fire(_:))
        ClosureTarget.shared.register(field, fill)
        fill()
        push(page)
        view.window?.makeFirstResponder(field)
    }

    // MARK: Favorites and lists

    func toggleFavorite(_ c: Chat) {
        Task { @MainActor [weak self] in
            let r = await Core.shared.callAsync("favorite", ["chat": c.jid, "on": !c.favorite])
            guard let self, !self.showError(r) else { return }
            self.refreshSections()
        }
    }

    func pushLists() {
        guard let c = chat else { return }
        let page = ProfilePage(title: "Change list")
        func build() {
            page.clear()
            let lists = store.customLists()
            guard !lists.isEmpty else {
                page.add(ProfilePage.note("No lists yet. Lists you make in WhatsApp on your phone show up here."))
                return
            }
            let mine = store.lists(of: c.jid)
            let card = Card()
            card.setRows(lists.map { l in
                choiceRow(l.name, checked: mine.contains(l.id)) {
                    Task { @MainActor [weak self] in
                        let r = await Core.shared.callAsync("label_chat", ["chat": c.jid, "label": l.id, "on": !mine.contains(l.id)])
                        if self?.showError(r) == false { build() }
                    }
                }
            })
            page.add(card)
            page.add(ProfilePage.note("Lists sync with your phone and other devices."))
        }
        build()
        push(page)
    }

    // MARK: Export, clear, block

    func exportChat(_ c: Chat) {
        guard let window = view.window else { return }
        let a = NSAlert()
        a.messageText = "Export chat with \(c.name)"
        a.informativeText = "Attaching media makes a larger export: a .zip with the chat text and every photo, video and document downloaded to this Mac."
        a.addButton(withTitle: "Without Media")
        a.addButton(withTitle: "Attach Media")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { [weak self] resp in
            guard resp != .alertThirdButtonReturn else { return }
            DispatchQueue.main.async { self?.saveExport(c, media: resp == .alertSecondButtonReturn) }
        }
    }

    private func saveExport(_ c: Chat, media: Bool) {
        guard let window = view.window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "WhatsApp Chat - \(c.name).\(media ? "zip" : "txt")"
        panel.allowedContentTypes = [media ? .zip : .plainText]
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            let msgs = self.store.allMessages(c.jid)
            do {
                try ChatExport.write(msgs, chat: c, media: media, to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                self.alert("Couldn't export the chat", error.localizedDescription)
            }
        }
    }

    func clearChat(_ c: Chat) {
        guard let window = view.window else { return }
        let a = NSAlert()
        a.messageText = "Clear this chat?"
        a.informativeText = "Every message in the chat with \(c.name) is deleted on all your devices. The chat stays in your list."
        let keep = NSButton(checkboxWithTitle: "Keep starred messages", target: nil, action: nil)
        keep.state = .on
        a.accessoryView = keep
        a.addButton(withTitle: "Clear Chat")
        a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        a.beginSheetModal(for: window) { resp in
            guard resp == .alertFirstButtonReturn else { return }
            Task { @MainActor [weak self] in
                let r = await Core.shared.callAsync("clear_chat", ["chat": c.jid, "on": keep.state == .on])
                guard let self, !self.showError(r) else { return }
                self.refreshSections()
            }
        }
    }

    func toggleBlock(_ c: Chat, block: Bool) {
        let text = block
            ? "Blocked contacts can't call you or send you messages. They aren't told you blocked them."
            : "\(c.name) will be able to call you and send you messages again."
        confirm(block ? "Block \(c.name)?" : "Unblock \(c.name)?", text, block ? "Block" : "Unblock", destructive: block) {
            Task { @MainActor [weak self] in
                let r = await Core.shared.callAsync("block", ["chat": c.jid, "on": block])
                guard let self, !self.showError(r) else { return }
                self.blocked = block
                if let fresh = self.chat { self.buildDanger(fresh) }
            }
        }
    }

    // MARK: helpers

    static func hero(_ symbol: String) -> NSView {
        let iv = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 40, weight: .light)) ?? NSImage())
        iv.contentTintColor = Theme.accent
        iv.alignment = .center
        return iv
    }

    func confirm(_ title: String, _ text: String, _ button: String, destructive: Bool = true, _ go: @escaping () -> Void) {
        guard let window = view.window else { return }
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = destructive
        a.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { go() } }
    }

    func alert(_ title: String, _ text: String) {
        guard let window = view.window else { return }
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.beginSheetModal(for: window)
    }

    /// Shows a core error as an alert; true when there was one.
    @discardableResult
    func showError(_ r: [String: Any]) -> Bool {
        guard let e = r["error"] as? String else { return false }
        alert("That didn't work", e == "not connected" ? "WA isn't connected to WhatsApp right now. Try again in a moment." : e)
        return true
    }
}

/// A square photo or video in the Media grid. History photos carry no thumbnail, so a
/// photo that comes on screen downloads (like the transcript, per Settings › Chats).
final class MediaThumb: NSView {
    static let downloaded = Notification.Name("WA.mediaDownloaded")
    private let action: () -> Void
    private let image = NSImageView()
    private let chat: String
    private let msg: Message
    private var asked = false

    init(_ m: Message, chat: String, action: @escaping () -> Void) {
        self.action = action
        self.chat = chat
        msg = m
        super.init(frame: .zero)
        NotificationCenter.default.addObserver(forName: Self.downloaded, object: nil, queue: .main) { [weak self] n in
            let id = n.userInfo?["id"] as? String
            MainActor.assumeIsolated {
                guard let self, id == self.msg.id, let path = Avatars.shared.store?.message(chat: self.chat, id: self.msg.id)?.mediaPath,
                      !path.isEmpty else { return }
                ImageCache.shared.load(path, px: 240) { [weak self] img in
                    guard let self, let img else { return }
                    Motion.crossfade(self.image.layer, duration: 0.2)
                    self.image.image = img
                }
            }
        }
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        image.image = ImageCache.thumb(m.thumb)
        addSubview(image)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalTo: widthAnchor),
            image.leadingAnchor.constraint(equalTo: leadingAnchor),
            image.trailingAnchor.constraint(equalTo: trailingAnchor),
            image.topAnchor.constraint(equalTo: topAnchor),
            image.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        if m.kind == .image, !m.mediaPath.isEmpty {
            ImageCache.shared.load(m.mediaPath, px: 240) { [weak self] img in if let img { self?.image.image = img } }
        }
        if m.kind == .video {
            let badge = NSTextField(labelWithString: m.seconds > 0 ? Fmt.duration(m.seconds) : "")
            badge.font = .systemFont(ofSize: 10.5, weight: .semibold)
            badge.textColor = .white
            badge.shadow = { let s = NSShadow(); s.shadowBlurRadius = 3; s.shadowColor = .black.withAlphaComponent(0.6); return s }()
            let glyph = NSImageView(image: NSImage(systemSymbolName: "video.fill", accessibilityDescription: "Video")?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold)) ?? NSImage())
            glyph.contentTintColor = .white
            let row = NSStackView(views: [glyph, badge])
            row.spacing = 3
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
                row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            ])
        }
        setAccessibilityRole(.button)
        setAccessibilityLabel(m.kind == .video ? "Video" : "Photo")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewWillDraw() {
        super.viewWillDraw()
        // Only drawn when on screen: fetch the photo then, not all 300 at once.
        guard !asked, msg.kind == .image, msg.mediaPath.isEmpty, msg.thumb == nil, msg.hasMedia, Prefs.autoPhotos else { return }
        asked = true
        Core.shared.call("download", ["chat": chat, "id": msg.id])
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
}

/// Target/action for controls built inline in pages, keyed by the control.
final class ClosureTarget: NSObject {
    static let shared = ClosureTarget()
    private var actions: [ObjectIdentifier: () -> Void] = [:]

    func register(_ control: NSControl, _ action: @escaping () -> Void) {
        actions[ObjectIdentifier(control)] = action
    }

    @objc func fire(_ sender: NSControl) { actions[ObjectIdentifier(sender)]?() }
}

/// The per-chat notification tone popup.
final class SoundPicker: NSObject {
    static let shared = SoundPicker()
    var jid = ""

    @objc func picked(_ sender: NSPopUpButton) {
        let v = sender.selectedItem?.representedObject as? String ?? ""
        ChatPrefs.setSound(jid, v)
        if !v.isEmpty, v != "none", v != "default" { NSSound(named: NSSound.Name(v))?.play() }
    }
}

/// Export chat: WhatsApp's text format ("[date, time] Name: text"), optionally zipped
/// with the media downloaded to this Mac.
enum ChatExport {
    static func write(_ msgs: [Message], chat c: Chat, media: Bool, to url: URL) throws {
        let f = DateFormatter()
        f.dateFormat = "M/d/yy, h:mm:ss a"
        var lines: [String] = []
        var files: [URL] = []
        for m in msgs where m.kind != .notice {
            let who = m.fromMe ? "You" : (c.isGroup ? m.senderName : c.name)
            var body = m.kind == .text ? m.text : Fmt.preview(kind: m.kind, text: m.text, fileName: m.fileName)
            if media, !m.mediaPath.isEmpty, FileManager.default.fileExists(atPath: m.mediaPath) {
                let file = URL(fileURLWithPath: m.mediaPath)
                files.append(file)
                body = "<attached: \(file.lastPathComponent)>" + (m.text.isEmpty || m.kind == .text ? "" : " " + m.text)
            } else if m.kind == .revoked {
                body = "This message was deleted"
            }
            lines.append("[\(f.string(from: m.date))] \(who): \(body)")
        }
        let text = lines.joined(separator: "\n") + "\n"
        guard media else {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("WA-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try text.write(to: dir.appendingPathComponent("_chat.txt"), atomically: true, encoding: .utf8)
        for file in files {
            try? FileManager.default.copyItem(at: file, to: dir.appendingPathComponent(file.lastPathComponent))
        }
        try? FileManager.default.removeItem(at: url)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--sequesterRsrc", dir.path, url.path]
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw NSError(domain: "WA", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Zipping the export failed."])
        }
    }
}
