import AppKit
import UniformTypeIdentifiers
import UserNotifications

/// Account-side settings, loaded from the core (the server is the source of truth).
@MainActor final class SettingsModel {
    static let shared = SettingsModel()

    var name = "", about = "", phone = "", picture = "", lid = "", platform = ""
    var defaultTimer = 0
    var securityNotices = false
    var privacy: [String: String] = [:]
    var blocked: [(jid: String, name: String, phone: String)] = []
    var otherDevices = 0
    var loaded: Set<String> = []
    var errors: [String: String] = [:]

    func loadProfile() async {
        let r = await Core.shared.callAsync("my_profile")
        if let e = r["error"] as? String { errors["profile"] = e; return }
        errors["profile"] = nil
        name = r["name"] as? String ?? ""
        about = r["about"] as? String ?? ""
        phone = r["phone"] as? String ?? ""
        picture = r["picture"] as? String ?? ""
        lid = r["lid"] as? String ?? ""
        platform = r["platform"] as? String ?? ""
        defaultTimer = Int(r["default_timer"] as? String ?? "") ?? 0
        securityNotices = r["security_notices"] as? Bool ?? false
        loaded.insert("profile")
    }

    func loadPrivacy() async {
        let r = await Core.shared.callAsync("privacy")
        if let e = r["error"] as? String { errors["privacy"] = e; return }
        errors["privacy"] = nil
        privacy = r.compactMapValues { $0 as? String }
        loaded.insert("privacy")
    }

    func loadBlocked() async {
        let r = await Core.shared.callAsync("blocklist")
        if let e = r["error"] as? String { errors["blocked"] = e; return }
        errors["blocked"] = nil
        blocked = (r["blocked"] as? [[String: Any]] ?? []).map {
            ($0["jid"] as? String ?? "", $0["name"] as? String ?? "", $0["phone"] as? String ?? "")
        }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        loaded.insert("blocked")
    }

    func loadDevices() async {
        let r = await Core.shared.callAsync("devices")
        let list = r["devices"] as? [[String: Any]] ?? []
        otherDevices = list.filter { ($0["primary"] as? Bool) != true }.count
        loaded.insert("devices")
    }
}

/// Builds each section's rows. Rebuilt whole on every change (they're small).
@MainActor struct SettingsPanes {
    let store: Store
    let reload: () -> Void
    private var model: SettingsModel { .shared }

    init(store: Store, reload: @escaping () -> Void) {
        self.store = store
        self.reload = reload
    }

    func build(_ s: SettingsSection) -> [NSView] {
        switch s {
        case .profile: profile()
        case .account: account()
        case .privacy: privacy()
        case .agents: agents()
        case .chats: chats()
        case .notifications: notifications()
        case .shortcuts: shortcuts()
        case .help: help()
        }
    }

    /// Loads `key` once, then rebuilds the pane.
    private func ensure(_ key: String, _ load: @escaping @MainActor () async -> Void) {
        guard !model.loaded.contains(key) else { return }
        let reload = reload
        Task { await load(); reload() }
    }

    private func loading(_ key: String) -> NSView? {
        if let e = model.errors[key] { return Form.note("Couldn't load this: \(e)") }
        return model.loaded.contains(key) ? nil : Form.note("Loading…")
    }

    private func run(_ op: String, _ args: [String: Any], then: (@MainActor () async -> Void)? = nil) {
        let reload = reload
        Task {
            let r = await Core.shared.callAsync(op, args)
            if let e = r["error"] as? String {
                let a = NSAlert()
                a.messageText = "That didn't go through"
                a.informativeText = e
                a.runModal()
            }
            await then?()
            reload()
        }
    }

    // MARK: Profile

    private func profile() -> [NSView] {
        ensure("profile") { await SettingsModel.shared.loadProfile() }
        let me = Core.shared.me
        let photo = ProfilePhotoRow(jid: me, name: model.name.isEmpty ? store.name(me) : model.name,
                                    path: model.picture.isEmpty ? store.avatar(me) : model.picture)
        photo.onChange = { [self] in changePhoto() }
        photo.onRemove = { [self] in
            confirm("Remove your profile photo?", "Your contacts will see your initials instead.", "Remove") {
                run("set_photo", ["path": ""]) { await SettingsModel.shared.loadProfile() }
            }
        }
        var out: [NSView] = [Form.group([photo])]
        if let l = loading("profile") { out.append(l) }
        out.append(Form.group([
            Form.field("Name", value: model.name, placeholder: "Your name", limit: 25) { [self] v in
                guard !v.isEmpty else { return }
                run("set_name", ["text": v]) { await SettingsModel.shared.loadProfile() }
            },
            Form.field("About", value: model.about.trimmingCharacters(in: .whitespaces), placeholder: "Add an About", limit: 139) { [self] v in
                run("set_about", ["text": v]) { await SettingsModel.shared.loadProfile() }
            },
        ], footer: "Your name shows in notifications to people who haven't saved your number. About is visible to whoever your privacy settings allow. WhatsApp doesn't send your current About to linked devices, so this shows what you last set here."))
        out.append(Form.group([
            Form.value("Phone", model.phone.isEmpty ? JID.phone(me) : model.phone),
            Form.value("Username", "Set on your phone", selectable: false),
        ], footer: "Usernames can only be created and changed in WhatsApp on your phone; linked devices can't set them."))
        return out
    }

    private func changePhoto() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.message = "Choose a photo. It's cropped to a square."
        guard p.runModal() == .OK, let url = p.url, let jpeg = Self.squareJPEG(url) else { return }
        run("set_photo", ["path": jpeg.path]) { await SettingsModel.shared.loadProfile() }
    }

    /// Centre-cropped 640px square JPEG, which WhatsApp expects for profile photos.
    nonisolated static func squareJPEG(_ url: URL) -> URL? {
        guard let img = ImageCache.decode(url, px: 1280) else { return nil }
        let side = min(img.width, img.height)
        guard let crop = img.cropping(to: CGRect(x: (img.width - side) / 2, y: (img.height - side) / 2, width: side, height: side)),
              let ctx = CGContext(data: nil, width: 640, height: 640, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 640, height: 640))
        guard let out = ctx.makeImage() else { return nil }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("profile-\(UUID().uuidString).jpg")
        guard let d = CGImageDestinationCreateWithURL(dest as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(d, out, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(d) ? dest : nil
    }

    // MARK: Account

    private func account() -> [NSView] {
        ensure("profile") { await SettingsModel.shared.loadProfile() }
        ensure("devices") { await SettingsModel.shared.loadDevices() }
        let me = Core.shared.me
        var out: [NSView] = []
        out.append(Form.group([
            Form.toggle("Show security notifications on this computer",
                        detail: "Adds a note in the chat when a contact's security code changes, for example after they reinstall WhatsApp or change phones.",
                        on: model.securityNotices) { on in
                Core.shared.call("security_notices", ["on": on])
                SettingsModel.shared.securityNotices = on
            },
        ], footer: "Messages and calls stay end-to-end encrypted either way."))
        let devices = model.loaded.contains("devices")
            ? (model.otherDevices == 0 ? "This Mac only" : "This Mac and \(model.otherDevices) more")
            : "…"
        out.append(Form.group([
            Form.value("Phone number", model.phone.isEmpty ? JID.phone(me) : model.phone),
            Form.value("Linked devices", devices, selectable: false),
            Form.value("WhatsApp ID", me),
        ] + (model.lid.isEmpty ? [] : [Form.value("Linked ID", model.lid)]), header: "Account info"))
        out.append(Form.group([
            Form.button("Log out", detail: "Removes this Mac from your linked devices and deletes its copy of your chats.",
                        label: "Log Out…", destructive: true) {
                NSApp.sendAction(#selector(AppDelegate.logOut(_:)), to: nil, from: nil)
            },
        ]))
        return out
    }

    // MARK: Privacy

    private static let audience: [(String, String)] = [("all", "Everyone"), ("contacts", "My contacts"), ("none", "Nobody")]

    private func privacy() -> [NSView] {
        ensure("privacy") { await SettingsModel.shared.loadPrivacy() }
        ensure("blocked") { await SettingsModel.shared.loadBlocked() }
        ensure("profile") { await SettingsModel.shared.loadProfile() }
        var out: [NSView] = []
        if let l = loading("privacy") { out.append(l) }
        let p = model.privacy
        func audience(_ title: String, _ key: String) -> FormRow {
            var opts = Self.audience
            // "My contacts except…" lists are edited on the phone; keep showing it if that's what's set.
            if p[key] == "contact_blacklist" { opts.insert(("contact_blacklist", "My contacts except…"), at: 2) }
            return Form.popup(title, options: opts, selected: p[key] ?? "all") { [self] v in
                run("set_privacy", ["name": key, "value": v]) { await SettingsModel.shared.loadPrivacy() }
            }
        }
        out.append(Form.group([
            audience("Last seen", "last"),
            Form.popup("Online", options: [("all", "Everyone"), ("match_last_seen", "Same as last seen")],
                       selected: p["online"] ?? "all") { [self] v in
                run("set_privacy", ["name": "online", "value": v]) { await SettingsModel.shared.loadPrivacy() }
            },
            audience("Profile photo", "profile"),
            audience("About", "status"),
            audience("Groups", "groupadd"),
        ], header: "Who can see my personal info", footer: "If you don't share your last seen or online, you won't see other people's either."))
        out.append(Form.group([
            Form.toggle("Read receipts", detail: "If this is off, you won't send or receive read receipts. Group chats always send them.",
                        on: (p["readreceipts"] ?? "all") == "all") { [self] on in
                run("set_privacy", ["name": "readreceipts", "value": on ? "all" : "none"]) { await SettingsModel.shared.loadPrivacy() }
            },
            Form.toggle("Silence unknown callers", detail: "Calls from people you haven't saved are silenced but still show up.",
                        on: p["calladd"] == "known") { [self] on in
                run("set_privacy", ["name": "calladd", "value": on ? "known" : "all"]) { await SettingsModel.shared.loadPrivacy() }
            },
        ]))
        out.append(Form.group([
            Form.popup("Default message timer",
                       options: [("0", "Off"), ("86400", "24 hours"), ("604800", "7 days"), ("7776000", "90 days")],
                       selected: String(model.defaultTimer)) { [self] v in
                run("set_default_timer", ["seconds": Int(v) ?? 0]) { await SettingsModel.shared.loadProfile() }
            },
        ], header: "Disappearing messages", footer: "New one-to-one chats start with this timer. Existing chats keep theirs."))
        var blockedRows: [NSView] = model.blocked.map { b in
            // Some blocked contacts come back as privacy IDs with no number we can show.
            let title = !b.name.isEmpty ? b.name : (!b.phone.isEmpty ? b.phone : "Contact with hidden number")
            let detail = !b.name.isEmpty && !b.phone.isEmpty ? b.phone : nil
            return Form.button(title, detail: detail, label: "Unblock") { [self] in
                run("block", ["chat": b.jid, "on": false]) { await SettingsModel.shared.loadBlocked() }
            }
        }
        if model.loaded.contains("blocked") && model.blocked.isEmpty {
            blockedRows.append(Form.value("No blocked contacts", "", selectable: false))
        }
        blockedRows.append(Form.button("Block a contact", label: "Block…") { [self] in pickContactToBlock() })
        out.append(Form.group(blockedRows, header: "Blocked contacts",
                              footer: "Blocked contacts can't call you or send you messages."))
        return out
    }

    private func pickContactToBlock() {
        guard let window = NSApp.keyWindow else { return }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 440), styleMask: [.titled], backing: .buffered, defer: false)
        let picker = NewMessageViewController(store: store) { [self] jid in
            window.endSheet(sheet)
            let name = store.name(jid)
            confirm("Block \(name)?", "They won't be able to call you or send you messages.", "Block") {
                run("block", ["chat": jid, "on": true]) { await SettingsModel.shared.loadBlocked() }
            }
        }
        picker.onCancel = { window.endSheet(sheet) }
        sheet.contentViewController = picker
        window.beginSheet(sheet)
    }

    // MARK: Agents

    private func agents() -> [NSView] {
        [
            Form.group([Form.value("Agents", "Managed on your phone", selectable: false)]),
            Form.note("Agents connect third-party AI assistants and bots to your account, each as its own chat. You create them in WhatsApp on your phone (up to five) and give the API key to the service that runs the agent. Linked devices can't list or manage them yet; their chats show up in your chat list like any other."),
        ]
    }

    // MARK: Chats

    private func chats() -> [NSView] {
        let accent = SwatchRow(items: Theme.AccentChoice.allCases.map { ($0.rawValue, $0.title, $0 == .system ? nil : $0.color) },
                               selected: Theme.accentChoice.rawValue, round: true) { id in
            if let c = Theme.AccentChoice(rawValue: id) { Theme.setAccent(c) }
        }
        // Each wallpaper swatch shows its light and dark tone, split diagonally.
        let wallpapers = SwatchRow(items: Wallpaper.all.map { w in
            (w.id, w.title, w.id == "none" ? nil : NSColor(hex: w.light))
        }, selected: Prefs.wallpaper, round: false, darkTones: Dictionary(uniqueKeysWithValues: Wallpaper.all.map {
            ($0.id, $0.id == "none" ? NSColor(hex: 0x1E1E1E) : NSColor(hex: $0.dark))
        })) { id in Prefs.set("WA.wallpaper", id) }
        return [
            Form.group([
                Form.popup("Theme", options: [("system", "System default"), ("light", "Light"), ("dark", "Dark")],
                           selected: Prefs.theme) { v in Prefs.set("WA.theme", v) },
                FormRow(title: "Accent color", detail: nil, accessory: accent),
                FormRow(title: "Wallpaper", detail: nil, accessory: wallpapers),
            ], header: "Display", footer: "The accent colours your messages, selection and controls."),
            Form.group([
                Form.toggle("Enter is send", detail: Prefs.enterSends ? "Shift-Return starts a new line." : "Return starts a new line; ⌘-Return sends.",
                            on: Prefs.enterSends) { [self] on in Prefs.set("WA.enterSends", on); reload() },
                Form.toggle("Spell check", on: Prefs.spellCheck) { on in Prefs.set("WA.spellCheck", on) },
                Form.toggle("Replace text with emoji", detail: "Turns :) into 🙂 when you send.",
                            on: Prefs.emojiReplace) { on in Prefs.set("WA.emojiReplace", on) },
            ], header: "Chat settings"),
            Form.group([
                Form.toggle("Photos", on: Prefs.autoPhotos) { on in Prefs.set("WA.auto.photos", on) },
                Form.toggle("Voice messages and audio", on: Prefs.autoAudio) { on in Prefs.set("WA.auto.audio", on) },
                Form.toggle("Video previews", detail: "Fetches only the start of each video for its first frame. Full videos download when you play them.",
                            on: Prefs.autoVideoPosters) { on in Prefs.set("WA.auto.videoPosters", on) },
                Form.toggle("Documents", on: Prefs.autoDocuments) { on in Prefs.set("WA.auto.documents", on) },
            ], header: "Media auto-download", footer: "Downloads start when the message comes on screen."),
            Form.group([
                Form.button("Archive all chats", detail: "Moves every chat to Archived, on all your devices.", label: "Archive All…") { [self] in
                    confirm("Archive all chats?", "Every chat moves to Archived on all your devices. New messages bring a chat back.", "Archive All") {
                        run("archive_all", [:])
                    }
                },
            ], header: "Chat history"),
        ]
    }

    // MARK: Notifications

    private func notifications() -> [NSView] {
        let permission = NotificationPermissionRow()
        let sounds = [("default", "Default"), ("none", "None")] + Prefs.alertSounds.map { ($0, $0) }
        return [
            Form.group([permission]),
            Form.group([
                Form.toggle("Show notifications", on: Prefs.notifyMessages) { on in Prefs.set("WA.notify.messages", on) },
                Form.toggle("Reaction notifications", detail: "When someone reacts to a message you sent.",
                            on: Prefs.notifyReactions) { on in Prefs.set("WA.notify.reactions", on) },
                Form.toggle("Show previews", detail: "Shows the message text in the banner. Off shows “New message”.",
                            on: Prefs.notifyPreviews) { on in Prefs.set("WA.notify.previews", on) },
            ], header: "Messages"),
            Form.group([
                Form.toggle("Show notifications", on: Prefs.notifyGroups) { on in Prefs.set("WA.notify.groups", on) },
                Form.toggle("Reaction notifications", on: Prefs.notifyGroupReactions) { on in Prefs.set("WA.notify.groupReactions", on) },
            ], header: "Groups", footer: "Muted chats never notify."),
            Form.group([
                Form.popup("Notification sound", options: sounds, selected: Prefs.notifySound) { v in
                    Prefs.set("WA.notify.sound", v)
                    if v != "default" && v != "none" { NSSound(named: NSSound.Name(v))?.play() }
                },
                Form.toggle("Play sound for outgoing messages", on: Prefs.outgoingSound) { on in Prefs.set("WA.sound.outgoing", on) },
                Form.toggle("Unread count on the Dock icon", on: Prefs.badge) { on in Prefs.set("WA.badge", on) },
            ], header: "Sounds and badges"),
            Form.group([
                Form.button("Reset notification settings", label: "Reset") { [self] in
                    confirm("Reset notification settings?", "Notifications, previews, reactions, sounds and the Dock badge go back to their defaults.", "Reset") {
                        Prefs.resetNotifications()
                        reload()
                    }
                },
            ]),
        ]
    }

    // MARK: Keyboard shortcuts

    private func shortcuts() -> [NSView] {
        func keys(_ rows: [(String, String)]) -> NSView {
            Form.group(rows.map { Form.value($0.0, $0.1, selectable: false) })
        }
        return [
            keys([("New message", "⌘N"), ("Search chats", "⌘F"), ("Settings", "⌘,"), ("Message field", "⌘L")]),
            keys([("Next chat", "⌃⇥"), ("Previous chat", "⌃⇧⇥"), ("Go to chat 1–9", "⌘1 – ⌘9"), ("Chats", "⌘0"),
                  ("Archived chats", "⇧⌘A")]),
            keys([("Mark as read or unread", "⇧⌘U"), ("Pin or unpin", "⇧⌘P"), ("Mute or unmute", "⇧⌘M"), ("Archive or unarchive", "⌘E")]),
            keys([("Send", Prefs.enterSends ? "Return" : "⌘Return"), ("New line", Prefs.enterSends ? "⇧Return" : "Return"),
                  ("Cancel reply or attachment", "Esc"), ("Reply to a message", "Double-click it"), ("Emoji", "⌃⌘Space")]),
            keys([("Toggle sidebar", "⌃⌘S"), ("Full screen", "⌃⌘F")]),
        ]
    }

    // MARK: Help

    private func help() -> [NSView] {
        func open(_ s: String) -> () -> Void { { if let u = URL(string: s) { NSWorkspace.shared.open(u) } } }
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return [
            Form.group([
                Form.link("Help Center", detail: "Answers from WhatsApp", symbol: "arrow.up.right", open("https://faq.whatsapp.com")),
                Form.link("Contact us", detail: "Questions about your account", symbol: "arrow.up.right", open("https://www.whatsapp.com/contact")),
                Form.link("Terms and Privacy Policy", symbol: "arrow.up.right", open("https://www.whatsapp.com/legal")),
            ]),
            Form.group([
                Form.value("Version", "\(v) (\(b))"),
                Form.link("Licenses", detail: "whatsmeow (MPL-2.0) and its dependencies", symbol: "arrow.up.right",
                          open("https://github.com/tulir/whatsmeow")),
            ], header: "About WA", footer: "WA is an independent Mac client. It isn't made or endorsed by WhatsApp or Meta."),
        ]
    }

    // MARK: helpers

    private func confirm(_ title: String, _ text: String, _ action: String, _ go: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: action)
        a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        if let w = NSApp.keyWindow {
            a.beginSheetModal(for: w) { r in if r == .alertFirstButtonReturn { MainActor.assumeIsolated { go() } } }
        } else if a.runModal() == .alertFirstButtonReturn {
            go()
        }
    }
}

// MARK: - Pane views

/// My photo with Change and Remove.
final class ProfilePhotoRow: NSView {
    var onChange: (() -> Void)?
    var onRemove: (() -> Void)?
    private let avatar = AvatarView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))

    init(jid: String, name: String, path: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        avatar.configure(jid: jid, name: name, isGroup: false, path: path, px: 128)
        avatar.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "Profile photo")
        title.font = .systemFont(ofSize: 13)
        let change = NSButton(title: "Change…", target: self, action: #selector(changeTapped))
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeTapped))
        remove.isHidden = path.isEmpty || path == "-"
        let buttons = NSStackView(views: [change, remove])
        buttons.spacing = 8
        let col = NSStackView(views: [title, buttons])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 8
        col.translatesAutoresizingMaskIntoConstraints = false
        [avatar, col].forEach(addSubview)
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            avatar.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            avatar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            avatar.widthAnchor.constraint(equalToConstant: 64),
            avatar.heightAnchor.constraint(equalToConstant: 64),
            col.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 16),
            col.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func changeTapped() { onChange?() }
    @objc private func removeTapped() { onRemove?() }
}

/// macOS notification permission: status plus the one action that fits it.
final class NotificationPermissionRow: NSView {
    private let status = NSTextField(wrappingLabelWithString: "Checking…")
    private let button = NSButton(title: "", target: nil, action: nil)
    private let test = NSButton(title: "Send Test", target: nil, action: nil)
    private var state: UNAuthorizationStatus = .notDetermined

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "macOS notifications")
        title.font = .systemFont(ofSize: 13)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let text = NSStackView(views: [title, status])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        button.target = self
        button.action = #selector(act)
        test.target = self
        test.action = #selector(sendTest)
        let buttons = NSStackView(views: [test, button])
        buttons.spacing = 8
        [text, buttons].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 12),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        Task { [weak self] in
            let s = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            self?.show(s)
        }
    }

    private func show(_ s: UNAuthorizationStatus) {
        state = s
        switch s {
        case .authorized, .provisional, .ephemeral:
            status.stringValue = "Allowed. Banners show unless the chat is open or muted."
            button.title = "Open Settings…"
            test.isHidden = false
        case .denied:
            status.stringValue = "Blocked in System Settings."
            button.title = "Open Settings…"
            test.isHidden = true
        default:
            status.stringValue = "Not set up yet."
            button.title = "Allow…"
            test.isHidden = true
        }
    }

    @objc private func act() {
        if state == .notDetermined {
            Task { [weak self] in
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                self?.refresh()
            }
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func sendTest() { SettingsWindowController.postTestNotification() }
}

/// A row of colour swatches (round for accents, rounded squares for wallpapers).
final class SwatchRow: NSStackView {
    private let onPick: (String) -> Void
    private var swatches: [Swatch] = []

    init(items: [(id: String, title: String, color: NSColor?)], selected: String, round: Bool,
         darkTones: [String: NSColor] = [:], onPick: @escaping (String) -> Void) {
        self.onPick = onPick
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        for item in items {
            let s = Swatch(id: item.id, title: item.title, color: item.color, round: round, dark: darkTones[item.id])
            s.isSelected = item.id == selected
            s.onPick = { [weak self] id in
                self?.swatches.forEach { $0.isSelected = $0.id == id }
                self?.onPick(id)
            }
            swatches.append(s)
            addArrangedSubview(s)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class Swatch: NSView {
    let id: String
    private let color: NSColor?
    private let dark: NSColor?
    private let round: Bool
    var onPick: ((String) -> Void)?
    var isSelected = false { didSet { needsDisplay = true; setAccessibilitySelected(isSelected) } }

    /// With `dark`, the swatch is split: `color` top-left (light tone), `dark` bottom-right.
    init(id: String, title: String, color: NSColor?, round: Bool, dark: NSColor? = nil) {
        self.id = id
        self.color = color
        self.dark = dark
        self.round = round
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        toolTip = title
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 24, height: 24) }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 4, dy: 4)
        let shape = round ? NSBezierPath(ovalIn: r) : NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
        if let dark {
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            (color ?? NSColor(hex: 0xFFFFFF)).setFill()
            r.fill()
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: r.maxX, y: r.minY))
            tri.line(to: NSPoint(x: r.maxX, y: r.maxY))
            tri.line(to: NSPoint(x: r.minX, y: r.minY))
            tri.close()
            dark.setFill()
            tri.fill()
            NSGraphicsContext.restoreGraphicsState()
        } else if let color {
            color.setFill()
            shape.fill()
        } else {
            let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .systemPink, .systemRed]
            NSGradient(colors: colors)?.draw(in: shape, angle: 90)
        }
        NSColor.separatorColor.setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
        if isSelected {
            let ring = round ? NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
                             : NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            NSColor.secondaryLabelColor.setStroke()
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPick?(id) }
    }
}
