import AppKit

final class MainWindowController: NSWindowController, NSWindowDelegate, ChatListDelegate, NSToolbarDelegate, NSMenuDelegate {
    let store: Store
    let list: ChatListViewController
    let convo: ConversationViewController
    private let split = MainSplitViewController()
    private var pairing: PairingViewController?
    private var connectionNote: String?
    private var syncNote: String?

    private static let chatMenuID = NSToolbarItem.Identifier("chatMenu")
    private static let composeID = NSToolbarItem.Identifier("compose")
    private static let headerID = NSToolbarItem.Identifier("header")
    private static let closeProfileID = NSToolbarItem.Identifier("closeProfile")
    private static let contentMinWidth: CGFloat = 320
    private var composeItem: NSToolbarItem?
    private let headerAvatar = HeaderAvatarButton()
    private var profile: ProfileViewController!
    private var profileItem: NSSplitViewItem!

    init(store: Store) {
        self.store = store
        list = ChatListViewController(store: store)
        convo = ConversationViewController(store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = Brand.name
        window.titleVisibility = .hidden   // the conversation header replaces the title
        // The sidebar folds to the compact column, so the window can get as narrow as Messages'.
        window.minSize = NSSize(width: MainSplitViewController.compactPosition + Self.contentMinWidth, height: 480)
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self

        let side = NSSplitViewItem(sidebarWithViewController: list)
        // Never closes: narrower than the full list, it snaps to the compact avatar column.
        side.minimumThickness = ChatListViewController.compactWidth
        side.maximumThickness = 440
        side.canCollapse = false
        side.preferredThicknessFraction = 0.3
        let content = NSSplitViewItem(viewController: convo)
        content.minimumThickness = Self.contentMinWidth
        // Let the transcript canvas run under the floating glass sidebar.
        content.automaticallyAdjustsSafeAreaInsets = true
        profile = ProfileViewController(store: store)
        profileItem = NSSplitViewItem(inspectorWithViewController: profile)
        profileItem.minimumThickness = 280
        profileItem.maximumThickness = 360
        profileItem.canCollapse = true
        profileItem.isCollapsed = true
        split.addSplitViewItem(side)
        split.addSplitViewItem(content)
        split.addSplitViewItem(profileItem)
        split.splitView.autosaveName = "WA.MainSplit"

        list.delegate = self
        convo.onHeader = { [weak self] title, sub in
            guard let self else { return }
            self.window?.title = title.isEmpty ? "WA" : title
            if let c = self.convo.chat {
                self.headerAvatar.isHidden = false
                self.headerAvatar.avatar.configure(jid: c.jid, name: c.name, isGroup: c.isGroup, path: c.avatar, px: 80)
                if self.profile.jid != nil, self.profile.jid != c.jid, !self.profileItem.isCollapsed { self.profile.show(c.jid) }
            } else {
                self.headerAvatar.isHidden = true
            }
        }
        convo.onProfile = { [weak self] in self?.toggleProfile(nil) }
        profile.onJump = { [weak self] chat, id in
            guard let self else { return }
            if self.convo.chat?.jid != chat { self.list.select(jid: chat) }
            self.convo.jump(to: id)
        }
        profile.onOpenChat = { [weak self] jid in self?.list.select(jid: jid) }
        convo.onOpenChat = { [weak self] jid in self?.list.select(jid: jid) }
        // The viewer covers the chat; the header avatar floats above it in the toolbar.
        convo.onViewer = { [weak self] open in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                self?.headerAvatar.animator().alphaValue = open ? 0 : 1
            }
        }
        profile.onSearchInChat = { [weak self] c in
            guard let self else { return }
            if self.list.compact { self.toggleCompactSidebar(nil) }
            self.list.searchIn(c)
        }
        headerAvatar.onClick = { [weak self] in self?.toggleProfile(nil) }
        headerAvatar.isHidden = true
        // The name capsule tucks under the avatar, so its top edge sits in the toolbar band
        // where the titlebar would swallow the click (and start a window drag).
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            guard let self, e.window === self.window, self.isShowingMain,
                  let frame = self.window?.contentView?.superview else { return e }
            if let hit = frame.hitTest(e.locationInWindow), hit.isDescendant(of: self.convo.view) || hit.isDescendant(of: self.headerAvatar) {
                return e
            }
            return self.convo.capsuleTakesClick(at: e.locationInWindow) ? nil : e
        }
        // Changing the accent (System Settings › Appearance) recolors the whole app, bubbles included.
        for name in [NSColor.systemColorsDidChangeNotification, Theme.didChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isShowingMain else { return }
                    self.list.reload()
                    self.window?.contentView?.superview?.redisplayTree()
                }
            }
        }

        let toolbar = NSToolbar(identifier: "WA.main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [Self.headerID]
        window.toolbar = toolbar

        window.setContentSize(NSSize(width: 1120, height: 760))
        window.center()
        window.setFrameAutosaveName("WA.Main")
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: modes

    func showMain() {
        guard window?.contentViewController !== split else { return }
        let leaving = pairing
        pairing = nil
        let frame = window?.frame
        window?.contentViewController = split
        if leaving != nil { setPairingChrome(false) }
        // The split autosave would restore an open (empty) profile panel; always start closed.
        profileItem.isCollapsed = true
        setCloseProfileShown(false)
        window?.toolbar?.isVisible = true
        if let frame { window?.setFrame(frame, display: true) }
        list.reload()
        let env = ProcessInfo.processInfo.environment["WA_OPEN_CHAT"]
        if let last = env ?? UserDefaults.standard.string(forKey: "WA.lastChat"), store.chat(last) != nil,
           env != nil || !ChatPrefs.isLocked(last) {
            list.select(jid: last)
        }
        // The QR screen fades away over the chats rather than cutting to them.
        leaving?.dissolve(over: split.view)
    }

    /// While the QR screen's intro plays, the window waits offscreen; the intro shows it.
    private var intro: PairingIntro?

    func showPairing() {
        if pairing == nil {
            let p = PairingViewController()
            pairing = p
            let frame = window?.frame
            convo.open(nil)
            window?.contentViewController = p
            window?.toolbar?.isVisible = false
            window?.title = Brand.name
            window?.subtitle = ""
            if let frame { window?.setFrame(frame, display: true) }
            setPairingChrome(true)
            // The screen frosts over and the light flows into this window (see PairingIntro).
            guard let w = window, !Theme.reduceMotion, ProcessInfo.processInfo.environment["WA_NO_INTRO"] == nil else { return }
            w.orderOut(nil)
            p.lightIsUp = true
            let i = PairingIntro(target: w.frame, screen: w.screen ?? NSScreen.main)
            intro = i
            i.play(handOff: {
                NSApp.activate()
                w.makeKeyAndOrderFront(nil)
            }, done: { [weak self] in self?.intro = nil })
        }
    }

    override func showWindow(_ sender: Any?) {
        guard intro == nil else { return }
        super.showWindow(sender)
    }

    private var mainMinSize: NSSize?

    /// The QR screen runs edge to edge in this window: no title bar fill, draggable
    /// anywhere, and at least big enough for the card and the steps.
    private func setPairingChrome(_ on: Bool) {
        guard let w = window else { return }
        w.titlebarAppearsTransparent = on
        w.isMovableByWindowBackground = on
        if on {
            mainMinSize = w.minSize
            let need = NSSize(width: 900, height: 720)
            w.contentMinSize = need
            let content = w.contentRect(forFrameRect: w.frame).size
            if content.width < need.width || content.height < need.height {
                let grow = NSSize(width: max(0, need.width - content.width), height: max(0, need.height - content.height))
                let f = NSRect(x: w.frame.minX - grow.width / 2, y: w.frame.minY - grow.height / 2,
                               width: w.frame.width + grow.width, height: w.frame.height + grow.height)
                w.setFrame(w.constrainFrameRect(f, to: w.screen), display: true)
            }
        } else if let m = mainMinSize {
            w.contentMinSize = .zero
            w.minSize = m
        }
    }

    var isShowingMain: Bool { window?.contentViewController === split }

    /// Dev (WA_PAIRING_PREVIEW=screen or flow, preview mode only): the QR screen in this
    /// window with a sample code; with `linkAfter`, then the linked beat and the dissolve into
    /// the chats. Nothing touches the account.
    func previewPairingFlow(code: String, linkAfter delay: Double? = nil) {
        showPairing()
        pairing?.show(qr: code)
        guard let delay else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.pairing?.celebrate { [weak self] in self?.showMain() }
        }
    }

    // MARK: core events

    func handle(_ e: CoreEvent) {
        switch e {
        case .state(let s, _, let msg):
            switch s {
            case "connected":
                connectionNote = nil
                if let p = pairing, Core.shared.isPaired, !p.isCelebrating { showMain() }
            case "syncing":
                // Just linked: let the first-run screen land its success beat, then the chats.
                if let p = pairing {
                    p.celebrate { [weak self] in self?.showMain() }
                } else {
                    showMain()
                }
                syncNote = "Loading your chats…"
            case "connecting":
                connectionNote = "Connecting…"
            case "offline":
                if pairing != nil { pairing?.show(state: s, message: msg) } else { connectionNote = "Offline. Retrying…" }
            case "replaced":
                connectionNote = "WhatsApp is open on another computer"
            case "banned":
                connectionNote = "WhatsApp temporarily restricted this account"
            case "logged_out":
                showPairing()
            case "qr_timeout", "pair_error":
                showPairing()
                pairing?.show(state: s, message: msg)
            default: break
            }
            updateStatus()
        case .qr(let code):
            if Core.shared.isPaired { return }
            showPairing()
            pairing?.show(qr: code)
        case .chats:
            Avatars.shared.refresh()
            list.setNeedsReload()
            if let jid = convo.chat?.jid, let c = store.chat(jid) { convo.chatUpdated(c) }
            convo.refreshAvatars()
        case .messages(let chat, let ids):
            if chat == convo.chat?.jid { convo.messagesChanged(ids: ids) }
        case .reload(let chat):
            list.setNeedsReload()
            if chat == "*" || chat == convo.chat?.jid { convo.reloadWindow() }
        case .typing(let chat, let sender, let on):
            list.setTyping(chat: chat, on: on)
            if chat == convo.chat?.jid { convo.typingChanged(sender: sender, name: store.name(sender), on: on) }
        case .presence(let jid, let online, let lastSeen):
            if jid == convo.chat?.jid { convo.presenceChanged(online: online, lastSeen: lastSeen) }
        case .sync(let p):
            syncNote = p < 100 && p > 0 ? "Syncing history… \(p)%" : nil
            updateStatus()
        case .media(let chat, let id, let status):
            if status == "downloaded" {
                NotificationCenter.default.post(name: MediaThumb.downloaded, object: nil, userInfo: ["chat": chat, "id": id])
            } else if chat == convo.chat?.jid {
                convo.mediaFailed(id: id, status: status)
            }
        case .notify, .error:
            break
        }
    }

    private func updateStatus() {
        list.setStatus(connectionNote ?? syncNote)
    }

    // MARK: selection

    func chatList(didSelect chat: Chat?) {
        guard chat?.jid != convo.chat?.jid || convo.isComposing else { return }
        convo.open(chat)
        if !Core.shared.isPreview { UserDefaults.standard.set(chat?.jid, forKey: "WA.lastChat") }
    }

    func chatList(didSelectMessage id: String, in chat: Chat) {
        if chat.jid != convo.chat?.jid || convo.isComposing { convo.open(chat) }
        convo.jump(to: id)
    }

    func open(chat jid: String) {
        showMain()
        list.select(jid: jid)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, Self.composeID, .flexibleSpace, Self.headerID, .flexibleSpace, Self.chatMenuID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.inspectorTrackingSeparator, Self.closeProfileID]
    }

    /// The panel's separator + ✕ only exist while it's open: a collapsed inspector's
    /// tracking separator still reserves width and would push ••• off the trailing edge.
    private func setCloseProfileShown(_ shown: Bool) {
        guard let toolbar = window?.toolbar else { return }
        let ids = toolbar.items.map(\.itemIdentifier)
        if shown, !ids.contains(Self.closeProfileID) {
            toolbar.insertItem(withItemIdentifier: .inspectorTrackingSeparator, at: ids.count)
            toolbar.insertItem(withItemIdentifier: Self.closeProfileID, at: ids.count + 1)
        } else if !shown {
            for i in toolbar.items.indices.reversed()
            where [Self.closeProfileID, .inspectorTrackingSeparator].contains(toolbar.items[i].itemIdentifier) {
                toolbar.removeItem(at: i)
            }
        }
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == Self.closeProfileID {
            // Sits over the profile panel's top-left, in the toolbar band like Messages.
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Profile")
            item.label = "Close"
            item.toolTip = "Close profile"
            item.isBordered = true
            item.target = self
            item.action = #selector(toggleProfile(_:))
            return item
        }
        if id == Self.headerID {
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = headerAvatar
            item.isBordered = false
            item.label = "Profile"
            return item
        }
        if id == Self.composeID {
            let item = NSToolbarItem(itemIdentifier: id)
            item.isBordered = true
            item.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "New Message")
            item.label = "New Message"
            item.toolTip = "New Message (⌘N)"
            item.target = self
            item.action = #selector(newMessage(_:))
            composeItem = item
            return item
        }
        guard id == Self.chatMenuID else { return nil }
        let item = NSMenuToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Chat options")
        item.label = "Chat"
        item.toolTip = "Chat options"
        item.showsIndicator = false
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let c = convo.chat.flatMap({ store.chat($0.jid) }) else {
            menu.addItem(withTitle: "No chat selected", action: nil, keyEquivalent: "")
            return
        }
        for i in ChatListViewController.actions(for: c) { menu.addItem(i) }
    }

    /// Dev hook: opens the profile panel and pushes a page inside it.
    func debugProfilePage(_ name: String) {
        if profileItem.isCollapsed { toggleProfile(nil) }
        // "a,b,c": one page every 3 s, popping back to the panel's root in between.
        for (i, page) in name.split(separator: ",").enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8 + Double(i) * 3) { [weak self] in
                self?.profile.popToRoot(animated: false)
                self?.profile.debugPush(String(page))
            }
        }
    }

    // MARK: sidebar

    /// Divider position before ⌃⌘S folded the sidebar to the compact column.
    private var fullSidebarPosition: CGFloat = 0

    private var sidebarPosition: CGFloat { split.splitView.arrangedSubviews.first?.frame.maxX ?? 0 }

    /// ⌃⌘S: fold the sidebar to the compact column or open it back out. Keyboard-driven,
    /// so it snaps without animating (DESIGN.md).
    @objc func toggleCompactSidebar(_ sender: Any?) {
        guard isShowingMain else { return }
        if list.compact {
            split.splitView.setPosition(max(fullSidebarPosition, MainSplitViewController.fullMinPosition), ofDividerAt: 0)
        } else {
            fullSidebarPosition = sidebarPosition
            split.splitView.setPosition(MainSplitViewController.compactPosition, ofDividerAt: 0)
        }
    }

    /// Narrowing the window squeezes the sidebar once the conversation is at its minimum.
    /// When the resize ends, a sidebar caught between the two layouts settles on one:
    /// the full list if the window still has room for it, otherwise the compact column.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard isShowingMain else { return }
        let p = sidebarPosition
        let lo = MainSplitViewController.compactPosition, hi = MainSplitViewController.fullMinPosition
        guard p > lo + 0.5, p < hi - 0.5 else { return }
        let room = split.splitView.bounds.width - Self.contentMinWidth - (profileItem.isCollapsed ? 0 : profileItem.minimumThickness)
        split.splitView.setPosition(room >= hi ? MainSplitViewController.snap(p) : lo, ofDividerAt: 0)
    }

    // MARK: new message

    private var composePopover: NSPopover?

    @objc func newMessage(_ sender: Any?) {
        guard isShowingMain else { return }
        list.select(jid: nil)
        convo.startCompose { [weak self] jid in self?.open(chat: jid) }
    }

    /// Window frame from before the panel opened, if opening it had to widen the window.
    private var frameBeforeProfile: NSRect?

    @objc func toggleProfile(_ sender: Any?) {
        let opening = profileItem.isCollapsed
        if opening {
            guard let c = convo.chat else { return }
            profile.show(c.jid)
            frameBeforeProfile = window?.frame
        }
        if opening { setCloseProfileShown(true) }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Theme.reduceMotion ? 0 : 0.25
            ctx.allowsImplicitAnimation = true
            profileItem.animator().isCollapsed = !opening
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                if opening {
                    // Only remember the old frame if AppKit actually had to grow the window.
                    if let before = self.frameBeforeProfile, abs(window.frame.width - before.width) < 1 { self.frameBeforeProfile = nil }
                } else {
                    self.setCloseProfileShown(false)
                    if let before = self.frameBeforeProfile {
                        self.frameBeforeProfile = nil
                        window.setFrame(before, display: true, animate: !Theme.reduceMotion)
                    }
                }
            }
        })
    }

    // MARK: window

    func windowDidBecomeKey(_ notification: Notification) {
        if let c = convo.chat, let fresh = store.chat(c.jid), fresh.hasUnread, NSApp.isActive {
            Core.shared.call("mark_read", ["chat": c.jid])
        }
    }
}

/// The sidebar never closes, as in Messages. Dragged narrower than the full list it
/// snaps to the compact avatar column, and back out once dragged past halfway.
final class MainSplitViewController: NSSplitViewController {
    // NSSplitViewController declares this but doesn't implement it, so there's no super to call.
    override func splitView(_ splitView: NSSplitView, constrainSplitPosition proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        index == 0 ? Self.snap(proposed) : proposed
    }

    /// The floating glass sidebar sits 8pt in from the window edge, so the divider's
    /// position is the sidebar's thickness + 8 (measured: setPosition(94) arrives as 102).
    static let sidebarInset: CGFloat = 8
    static var compactPosition: CGFloat { ChatListViewController.compactWidth + sidebarInset }
    static var fullMinPosition: CGFloat { ChatListViewController.fullMinWidth + sidebarInset }

    /// Divider positions between the compact column and the full list's minimum go to
    /// whichever is nearer.
    static func snap(_ p: CGFloat) -> CGFloat {
        let lo = compactPosition, hi = fullMinPosition
        guard p > lo, p < hi else { return p }
        return p < (lo + hi) / 2 ? lo : hi
    }
}

extension NSView {
    /// Marks this view and every descendant for redraw, so draw-time colors re-resolve.
    func redisplayTree() {
        needsDisplay = true
        subviews.forEach { $0.redisplayTree() }
    }
}
