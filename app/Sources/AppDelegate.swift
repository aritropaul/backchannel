import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var wc: MainWindowController?
    private var store: Store?
    private var badgeScheduled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let core = Core.shared
        core.start()
        guard let store = Store(path: core.dbPath) else {
            let a = NSAlert()
            a.messageText = "Couldn't open the local database"
            a.informativeText = core.dbPath
            a.runModal()
            NSApp.terminate(nil)
            return
        }
        self.store = store
        Avatars.shared.store = store
        let main = MainWindowController(store: store)
        self.wc = main
        core.observe { [weak self] e in self?.handle(e) }

        // Paired: paint straight from the local store, before the network.
        if core.isPaired { main.showMain() } else { main.showPairing() }
        main.showWindow(nil)
        updateBadge()
        // Dev affordances: WA_SLOWMO=<n> slows every animation n×; WA_PREVIEW_DEMO plays a scripted chat.
        let env = ProcessInfo.processInfo.environment
        if let slow = env["WA_SLOWMO"].flatMap(Float.init), slow > 1, let root = main.window?.contentView?.superview {
            root.wantsLayer = true
            root.layer?.speed = 1 / slow
        }
        if env["WA_PREVIEW_PROFILE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak main] in main?.toggleProfile(nil) }
            if env["WA_TEST_CLOSE"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak main] in main?.toggleProfile(nil) }
            }
        }
        if env["WA_FOCUS_LIST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak main] in main?.list.focusList() }
        }
        if env["WA_PREVIEW_COMPOSE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak main] in main?.newMessage(nil) }
        }
        if core.isPreview, env["WA_PREVIEW_DEMO"] != nil {
            PreviewSim.shared.runDemo { [weak main] in main?.convo.chat?.jid }
        }

        let nc = UNUserNotificationCenter.current()
        nc.delegate = self
        if core.isPaired { requestNotifications() }
    }

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { wc?.showWindow(nil) }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        focusChanged()
    }

    func applicationDidResignActive(_ notification: Notification) {
        focusChanged()
    }

    private func focusChanged() {
        let chat = wc?.convo.chat?.jid ?? ""
        let active = NSApp.isActive && (wc?.window?.isVisible ?? false)
        Core.shared.call("focus", ["chat": chat, "active": active])
        if active, !chat.isEmpty, let c = store?.chat(chat), c.hasUnread {
            Core.shared.call("mark_read", ["chat": chat])
        }
    }

    private func handle(_ e: CoreEvent) {
        wc?.handle(e)
        switch e {
        case .chats, .reload:
            scheduleBadge()
        case .notify(let chat, _, let title, let body, let muted):
            notify(chat: chat, title: title, body: body, muted: muted)
        case .state(let s, _, _):
            if s == "syncing" { requestNotifications() }
            if s == "connected" { focusChanged() }
        default: break
        }
    }

    // MARK: dock badge

    private func scheduleBadge() {
        guard !badgeScheduled else { return }
        badgeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.badgeScheduled = false
            self?.updateBadge()
        }
    }

    private func updateBadge() {
        let n = store?.unreadChatCount() ?? 0
        NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    // MARK: notifications

    private func notify(chat: String, title: String, body: String, muted: Bool) {
        guard !muted else { return }
        if NSApp.isActive, wc?.convo.chat?.jid == chat { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = chat
        content.userInfo = ["chat": chat]
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let chat = response.notification.request.content.userInfo["chat"] as? String else { return }
        let id = response.notification.request.identifier
        await MainActor.run {
            NSApp.activate()
            self.wc?.open(chat: chat)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        }
    }

    // MARK: menu actions

    @objc func newMessage(_ sender: Any?) { wc?.newMessage(sender) }
    @objc func nextChat(_ sender: Any?) { wc?.list.selectRelative(1) }
    @objc func previousChat(_ sender: Any?) { wc?.list.selectRelative(-1) }
    @objc func searchChats(_ sender: Any?) { wc?.list.focusSearch() }
    @objc func showArchived(_ sender: Any?) { wc?.list.showArchive(true) }
    @objc func showChats(_ sender: Any?) { wc?.list.showArchive(false) }
    @objc func goToChat(_ sender: NSMenuItem) { wc?.list.selectNth(sender.tag) }
    @objc func focusComposer(_ sender: Any?) { wc?.convo.composer.focus() }

    private var current: Chat? { wc?.convo.chat.flatMap { store?.chat($0.jid) } }

    @objc func toggleUnread(_ sender: Any?) {
        guard let c = current else { return }
        Core.shared.call(c.hasUnread ? "mark_read" : "mark_unread", ["chat": c.jid])
    }
    @objc func togglePin(_ sender: Any?) {
        guard let c = current else { return }
        Core.shared.call("pin", ["chat": c.jid, "on": !c.pinned])
    }
    @objc func toggleMute(_ sender: Any?) {
        guard let c = current else { return }
        Core.shared.call("mute", ["chat": c.jid, "on": !c.isMuted, "hours": 8])
    }
    @objc func toggleArchive(_ sender: Any?) {
        guard let c = current else { return }
        Core.shared.call("archive", ["chat": c.jid, "on": !c.archived])
    }

    @objc func logOut(_ sender: Any?) {
        let a = NSAlert()
        a.messageText = "Log out of WhatsApp on this Mac?"
        a.informativeText = "This removes this Mac from your phone's linked devices and deletes the local copy of your chats."
        a.addButton(withTitle: "Log Out")
        a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        if a.runModal() == .alertFirstButtonReturn {
            Core.shared.call("logout")
        }
    }

    // MARK: menu

    private func buildMenu() {
        let bar = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = m
            bar.addItem(top)
            return m
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }

        _ = menu("WA", [
            item("About WA", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Log Out of WhatsApp…", #selector(logOut(_:)), target: self),
            .separator(),
            item("Hide WA", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit WA", #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = menu("File", [
            item("New Message", #selector(newMessage(_:)), "n", target: self),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ])
        _ = menu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Search Chats", #selector(searchChats(_:)), "f", target: self),
            item("Emoji & Symbols", #selector(NSApplication.orderFrontCharacterPalette(_:)), " ", [.command, .control]),
        ])
        var goItems: [NSMenuItem] = []
        for n in 1...9 {
            let i = item("Chat \(n)", #selector(goToChat(_:)), "\(n)", target: self)
            i.tag = n - 1
            goItems.append(i)
        }
        let goTo = NSMenuItem(title: "Go to Chat", action: nil, keyEquivalent: "")
        goTo.submenu = NSMenu(title: "Go to Chat")
        goItems.forEach { goTo.submenu?.addItem($0) }
        _ = menu("Chat", [
            item("Next Chat", #selector(nextChat(_:)), "\t", .control, target: self),
            item("Previous Chat", #selector(previousChat(_:)), "\t", [.control, .shift], target: self),
            item("Next Chat", #selector(nextChat(_:)), "]", [.command, .shift], target: self).hiddenAlternate(),
            item("Previous Chat", #selector(previousChat(_:)), "[", [.command, .shift], target: self).hiddenAlternate(),
            goTo,
            .separator(),
            item("Message Field", #selector(focusComposer(_:)), "l", target: self),
            .separator(),
            item("Mark as Read/Unread", #selector(toggleUnread(_:)), "u", [.command, .shift], target: self),
            item("Pin/Unpin", #selector(togglePin(_:)), "p", [.command, .shift], target: self),
            item("Mute/Unmute", #selector(toggleMute(_:)), "m", [.command, .shift], target: self),
            item("Archive/Unarchive", #selector(toggleArchive(_:)), "e", target: self),
            .separator(),
            item("Chats", #selector(showChats(_:)), "0", target: self),
            item("Archived Chats", #selector(showArchived(_:)), "a", [.command, .shift], target: self),
        ])
        _ = menu("View", [
            item("Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        let window = menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.mainMenu = bar
        NSApp.windowsMenu = window
    }
}

private extension NSMenuItem {
    /// A second key equivalent for the same command, kept out of sight.
    func hiddenAlternate() -> NSMenuItem {
        isHidden = true
        allowsKeyEquivalentWhenHidden = true
        return self
    }
}
