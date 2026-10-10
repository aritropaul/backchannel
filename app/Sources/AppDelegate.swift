import AppKit
import Quartz
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var wc: MainWindowController?
    private var settings: SettingsWindowController?
    private var store: Store?
    private var badgeScheduled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.applyTheme()
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
        NotificationCenter.default.addObserver(forName: Prefs.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateBadge() }
        }
        let main = MainWindowController(store: store)
        self.wc = main
        core.observe { [weak self] e in self?.handle(e) }

        // Paired: paint straight from the local store, before the network.
        // Dev: WA_PAIRING_PREVIEW=screen opens straight into the QR screen (preview mode only).
        let qrPreview = core.isPreview && ProcessInfo.processInfo.environment["WA_PAIRING_PREVIEW"] == "screen"
        if core.isPaired && !qrPreview { main.showMain() } else { main.showPairing() }
        main.showWindow(nil)
        updateBadge()
        Updates.start()
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
        if let q = env["WA_SEARCH"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak main] in main?.list.setSearch(q) }
            if env["WA_SEARCH_PICK"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak main] in main?.list.pickFirstHit() }
            }
        }
        if let w = env["WA_SIDEBAR_WIDTH"].flatMap(Double.init) {
            // Dev hook: drags the sidebar divider to `w` through the same snapping a drag uses.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak main] in
                guard let main else { return }
                let snapped = MainSplitViewController.snap(CGFloat(w))
                NSLog("WA sidebar: proposed %.0f -> %.0f", w, snapped)
                (main.contentViewController as? NSSplitViewController)?.splitView.setPosition(snapped, ofDividerAt: 0)
            }
        }
        if let out = env["WA_BADGES"] { DevMoments.renderBadges(to: out) }
        if let spec = env["WA_MOMENTS"] {
            // Dev: plays the motion moments locally, nothing sent (DevMoments.swift).
            DevMoments.run(spec, main: main)
        }
        if env["WA_PULL"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak main] in main?.list.revealArchive() }
        }
        if let steps = env["WA_SCROLL_TEST"] {
            // Dev: scrolls the transcript up by each amount (pt), 2 s apart, as a trackpad would.
            for (i, dy) in steps.split(separator: ",").compactMap({ Double($0) }).enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5 + Double(i) * 2) { [weak main] in
                    guard let sv = main?.convo.tableView.enclosingScrollView else { return }
                    let clip = sv.contentView
                    clip.scroll(to: NSPoint(x: 0, y: max(-sv.contentInsets.top, clip.bounds.minY - CGFloat(dy))))
                    sv.reflectScrolledClipView(clip)
                }
            }
        }
        if env["WA_ATTACH_MENU"] != nil {
            // Dev: opens the + menu, then closes it 4 s later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak main] in
                guard let c = main?.convo else { return }
                let t = Timer(timeInterval: 4, repeats: false) { _ in
                    MainActor.assumeIsolated { ConversationViewController.openAttachMenu?.cancelTracking() }
                }
                RunLoop.main.add(t, forMode: .common)
                c.showAttachMenu(from: c.composer.attachAnchor)
            }
        }
        if let size = env["WA_WINDOW_SIZE"], let w = main.window {
            // Dev: e.g. WA_WINDOW_SIZE=1240x780, for screenshots (preview mode only; nothing is saved).
            let p = size.split(separator: "x").compactMap { Double($0) }
            if p.count == 2 { w.setContentSize(NSSize(width: p[0], height: p[1])); w.center() }
        }
        if let n = env["WA_OPEN_INDEX"].flatMap(Int.init) {
            // Dev: opens the nth chat in the list (0-based), like ⌘1…⌘9.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak main] in main?.list.selectNth(n) }
        }
        if env["WA_ABOUT"] != nil {
            // Dev: the About window, opened at launch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { AboutWindowController.shared.present() }
        }
        if let stage = env["WA_PAIRING_PREVIEW"], stage == "flow" || stage == "screen", core.isPreview {
            let fake = { (n: Int) in String((0..<n).map { _ in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".randomElement()! }) }
            let code = "2@" + fake(78) + "," + fake(43) + "=," + fake(43) + "=," + fake(43) + "="
            if stage == "screen" {
                main.previewPairingFlow(code: code)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak main] in main?.previewPairingFlow(code: code, linkAfter: 7) }
            }
        } else if let stage = env["WA_PAIRING_PREVIEW"] {
            // Dev: the first-run screen in its own window, without logging out. The code has a
            // real code's length but random keys, so it links nothing. Stages: loading, qr
            // (default), rotate, expired, offline, phone, linked.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let vc = PairingViewController()
                let w = NSWindow(contentViewController: vc)
                w.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
                w.titlebarAppearsTransparent = true
                w.titleVisibility = .hidden
                w.isMovableByWindowBackground = true
                w.setContentSize(NSSize(width: 1120, height: 760))
                w.title = "Pairing preview"
                let fake = { (n: Int) in String((0..<n).map { _ in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".randomElement()! }) }
                let code = { "2@" + fake(78) + "," + fake(43) + "=," + fake(43) + "=," + fake(43) + "=" }
                if stage != "loading" { vc.show(qr: code()) }
                w.center()
                w.makeKeyAndOrderFront(nil)
                objc_setAssociatedObject(NSApp as Any, "pairingPreview", w, .OBJC_ASSOCIATION_RETAIN)
                let later = { (t: Double, f: @escaping () -> Void) in DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
                switch stage {
                case "rotate": later(2.5) { vc.show(qr: code()) }
                case "expired": later(1.6) { vc.show(state: "qr_timeout", message: nil) }
                case "offline": later(1.6) { vc.show(state: "offline", message: nil) }
                case "phone": later(1.6) { vc.perform(Selector(("toggleMode"))) }
                case "linked": later(1.6) { vc.celebrate {} }
                default: break
                }
            }
        }
        if let which = env["WA_SHEET"] {
            // Dev: poll, event, contacts or sticker:<image>; shown for 5 s.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak main] in
                guard let c = main?.convo else { return }
                switch which {
                case "poll": c.newPoll()
                case "event": c.newEvent()
                case "contacts": c.pickContacts()
                default:
                    if which.hasPrefix("sticker:") {
                        c.presentAsSheet(StickerMakerViewController(source: URL(fileURLWithPath: String(which.dropFirst(8)))))
                    }
                }
                if let out = env["WA_SHEET_OUT"] {
                    // Sheets on another Space can't be screen-captured; draw the view instead.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak c] in
                        guard let v = c?.presentedViewControllers?.first?.view,
                              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak c] in
                    c?.presentedViewControllers?.forEach { c?.dismiss($0) }
                }
            }
        }
        if env["WA_VIEWER"] != nil {
            // Dev: opens the newest photo in the open chat, then presses Space 4 s later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak main] in
                guard let c = main?.convo, let jid = c.chat?.jid,
                      let m = c.store.mediaItems(jid, limit: 50).first(where: { $0.kind == .image && !$0.mediaPath.isEmpty })
                else { return }
                c.jump(to: m.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak c] in
                    c?.showViewer(m)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak c] in
                        guard let w = c?.view.window, let e = NSEvent.keyEvent(
                            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: w.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                            isARepeat: false, keyCode: 49) else { return }
                        w.sendEvent(e)
                    }
                }
            }
        }
        if env["WA_FAV_TEST"] != nil {
            let store = main.convo.store
            // Dev: stars the newest downloaded sticker on this Mac, and un-stars it 10 s later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let s = store.recentStickers().first(where: { !$0.path.isEmpty }) else { return }
                ConversationViewController.setFavorite(s, true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { ConversationViewController.setFavorite(s, false) }
            }
        }
        if let out = env["WA_STICKER_CARD"] {
            let store = main.convo.store
            // Dev: draws the card a sticker click opens, for the newest downloaded sticker.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard let s = store.recentStickers().first(where: { !$0.path.isEmpty }) else { return }
                let card = StickerCardViewController(item: s, favorite: false)
                let v = card.view
                v.frame.size = v.fittingSize
                v.layoutSubtreeIfNeeded()
                guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            }
        }
        if env["WA_CLICK_STICKER"] != nil {
            // Dev: scrolls to the newest downloaded sticker in the open chat and clicks it
            // with real mouse events, then reports what's on screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak main] in
                guard let c = main?.convo, let jid = c.chat?.jid,
                      let sid = env["WA_CLICK_STICKER"], let s = c.store.message(chat: jid, id: sid) else {
                    NSLog("WA click: no sticker"); return
                }
                c.jump(to: s.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak c] in
                    guard let c, let w = c.view.window, let row = c.rowIndex(of: s.id),
                          let cell = c.tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? BubbleView,
                          let r = cell.item?.mediaRect else { NSLog("WA click: sticker not on screen"); return }
                    let p = cell.convert(CGPoint(x: r.midX, y: r.midY), to: nil)
                    NSLog("WA click: sticker %@ at %@ hit=%@", s.id, NSStringFromPoint(p), String(describing: w.contentView?.superview?.hitTest(p)))
                    // Straight to the bubble: a window that isn't active swallows a first click.
                    if let e = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        cell.mouseDown(with: e)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        for win in NSApp.windows where win.isVisible { NSLog("WA click: window %@ %@", win.className, NSStringFromRect(win.frame)) }
                        // Draws the card (a popover on another Space can't be screen-captured).
                        if let out = env["WA_CARD_OUT"], let v = StickerCardViewController.shown?.view.window?.contentView,
                           let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                            v.cacheDisplay(in: v.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                        }
                    }
                }
            }
        }
        if env["WA_CLICK_EMOJI"] != nil {
            // Dev: clicks ☺ through its real target/action, then reports what's on screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak main] in
                guard let b = main?.convo.expressionAnchor as? NSButton else { NSLog("WA click: no button"); return }
                NSLog("WA click: target=%@ action=%@ enabled=%d window=%@", String(describing: b.target), String(describing: b.action),
                      b.isEnabled ? 1 : 0, String(describing: b.window))
                b.performClick(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    for w in NSApp.windows where w.isVisible { NSLog("WA click: window %@ %@", w.className, NSStringFromRect(w.frame)) }
                }
            }
        }
        if let spec = env["WA_PANEL"] {
            // Dev: "<gif|stickers>[:<tab>]|<out.png>": opens the ☺ panel and draws it 3 s later.
            let p = spec.split(separator: "|").map(String.init)
            let mode = p[0].split(separator: ":").map(String.init)
            UserDefaults.standard.set(["emoji": 0, "gif": 1][mode[0]] ?? 2, forKey: "WA.expressionMode")
            func open(_ tries: Int) {
                guard let c = main.convo as ConversationViewController?, tries > 0 else { return }
                guard c.chat != nil, c.view.window?.isVisible == true else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { open(tries - 1) }
                    return
                }
                show(c)
            }
            func show(_ c: ConversationViewController) {
                guard let panel = c.showExpressions(from: c.expressionAnchor) else { return }
                if mode.count > 1, let t = Int(mode[1]) { panel.debugTab(t) }
                if mode[0] == "gif", let q = env["WA_GIF_SEARCH"] { panel.debugGIFSearch(q) }
                if mode[0] == "emoji", env["WA_EMOJI_INSERT"] != nil {
                    // Inserting goes through the same path as a click (it lands in the draft).
                    c.composer.insertEmoji("😀")
                    NSLog("WA emoji: composer text now %@", c.composer.text)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    let v = panel.view
                    NSLog("WA panel hook: bounds %@ parts %d", NSStringFromRect(v.bounds), p.count)
                    guard p.count > 1, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { NSLog("WA panel hook: no rep"); return }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    do {
                        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: p[1]))
                    } catch { NSLog("WA panel hook: %@", String(describing: error)) }
                    panel.dismiss(nil)
                    panel.view.window?.close()
                }
            }
            // The chat opens a moment after launch; wait for it (up to 15 s).
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { open(30) }
        }
        if let id = env["WA_JUMP"] {
            // Dev: scrolls the open chat to a message.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak main] in main?.convo.jump(to: id) }
        }
        if let out = env["WA_CARDS"] {
            // Dev: sample poll, event and contact bubbles drawn to <out>-light/-dark.png.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { DevCards.render(to: out) }
        }
        if let out = env["WA_MENU_PREVIEW"] {
            for dark in [false, true] {
                let img = ConversationViewController.attachMenuPreview(dark: dark)
                if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: out + (dark ? "-dark.png" : "-light.png")))
                }
            }
        }
        if let spec = env["WA_STICKER_TEST"] {
            // Dev: "<image>|<out.png>": renders a sticker (cutout, outline, text) to a file.
            let p = spec.split(separator: "|").map(String.init)
            if p.count == 2 {
                Task { @MainActor in
                    let (img, cut) = await StickerMakerViewController.load(URL(fileURLWithPath: p[0]))
                    guard let base = cut ?? img, let out = StickerMakerViewController.render(base, outline: true, text: "hello"),
                          let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: p[1]) as CFURL, "public.png" as CFString, 1, nil)
                    else { return }
                    CGImageDestinationAddImage(d, out, nil)
                    CGImageDestinationFinalize(d)
                }
            }
        }
        if let spec = env["WA_SEARCH_IN"] {
            // "<chat jid>|<query>": the contact panel's Search, then typing the query.
            let p = spec.split(separator: "|", maxSplits: 1).map(String.init)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak main] in
                guard let main, let c = main.store.chat(p[0]) else { return }
                main.list.searchIn(c)
                if p.count > 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { main.list.setSearch(p[1]) }
                }
            }
        }
        if let page = env["WA_PROFILE_PAGE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak main] in main?.debugProfilePage(page) }
        }
        if let spec = env["WA_THEME_TRY"] {
            // "<wallpaper>:<bubble>[:<photo file>]", shown on the open chat without saving.
            let p = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            let t = ChatTheme(wallpaper: p[0], photo: p.count > 2 ? p[2] : "", bubble: p.count > 1 ? p[1] : "")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { ChatThemes.preview(t) }
        }
        if env["WA_SHOW_ARCHIVE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak main] in main?.list.showArchive(true) }
        }
        if let f = env["WA_FILTER"].flatMap(Int.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak main] in main?.list.pickFilter(f) }
        }
        if let paths = env["WA_ATTACH"] {
            // Dev: files for the composer's tray, several separated by "|".
            let urls = paths.split(separator: "|").map { URL(fileURLWithPath: String($0)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak main] in main?.convo.attachMany(urls, asDocuments: false) }
        }
        if let id = env["WA_JUMP"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak main] in main?.convo.jump(to: id) }
        }
        if env["WA_PLAY_LATEST_VIDEO"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak main] in main?.convo.playLatestVideo() }
        }
        if env["WA_PREVIEW_SETTINGS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showSettings(nil)
                if let s = env["WA_SETTINGS_SECTION"].flatMap(SettingsSection.init) { self?.settings?.show(s) }
            }
        }
        if env["WA_DEMO_OPEN"] != nil || env["WA_MENTION_DEMO"] != nil || env["WA_SHEET_DEMO"] != nil {
            // Dev demos run in my own chat only: select it first, whatever chat was open last.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.wc?.list.select(jid: Core.shared.me) }
        }
        if let id = env["WA_DEMO_OPEN"] {
            // Dev: opens a message's attachment as a click does (downloading it first if needed),
            // at WA_DEMO_OPEN_AT seconds; Quick Look closes 12 s later.
            let at = env["WA_DEMO_OPEN_AT"].flatMap(Double.init) ?? 2.2
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                guard let c = self?.wc?.convo, c.chat?.jid == Core.shared.me,
                      let m = self?.store?.message(chat: Core.shared.me, id: id) else { return }
                c.open(media: m)
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) { QLPreviewPanel.shared()?.orderOut(nil) }
            }
        }
        if let secs = env["WA_SETTINGS_TONES"].flatMap(Double.init) {
            // Dev hook (with WA_SETTINGS_SECTION=notifications): opens the notification sound menu
            // for a screenshot and closes it after `secs`.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                @MainActor func find(_ v: NSView) -> NSPopUpButton? {
                    if let p = v as? NSPopUpButton, p.itemArray.contains(where: { $0.representedObject as? String == Tones.standard }) { return p }
                    return v.subviews.lazy.compactMap(find).first
                }
                guard let view = self?.settings?.window?.contentView, let popup = find(view), let menu = popup.menu else { return }
                menu.perform(#selector(NSMenu.cancelTracking), with: nil, afterDelay: secs, inModes: [.common])
                popup.performClick(nil)
            }
        }
        if env["WA_TEST_NOTIFY"] != nil {
            // Verifies notifications end to end: logs the permission, posts one, then logs what macOS delivered.
            Task {
                let nc = UNUserNotificationCenter.current()
                NSLog("WA notify: authorization before = %ld", (await nc.notificationSettings()).authorizationStatus.rawValue)
                SettingsWindowController.postTestNotification()
                try? await Task.sleep(for: .seconds(2))
                let s = await nc.notificationSettings()
                let delivered = await nc.deliveredNotifications()
                NSLog("WA notify: authorization = %ld, alert = %ld, delivered = %ld", s.authorizationStatus.rawValue,
                      s.alertSetting.rawValue, delivered.count)
            }
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
        case .notify(let chat, let id, let title, let body, let muted, let reaction):
            if !reaction { PhotoSaver.shared.incoming(chat: chat, id: id) }
            notify(chat: chat, title: title, body: body, muted: muted, reaction: reaction)
        case .media(let chat, let id, let status) where status == "downloaded":
            PhotoSaver.shared.downloaded(chat: chat, id: id)
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
        let n = Prefs.badge ? (store?.unreadChatCount() ?? 0) : 0
        NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    // MARK: notifications

    private func notify(chat: String, title: String, body: String, muted: Bool, reaction: Bool) {
        guard !muted else { return }
        if NSApp.isActive, wc?.convo.chat?.jid == chat { return }
        // Settings › Notifications: per-kind switches, previews, sound.
        let group = chat.hasSuffix("@g.us")
        guard group ? Prefs.notifyGroups : Prefs.notifyMessages else { return }
        if reaction, !(group ? Prefs.notifyGroupReactions : Prefs.notifyReactions) { return }
        let content = UNMutableNotificationContent()
        // A locked chat never shows who or what, only that something arrived.
        let locked = ChatPrefs.isLocked(chat)
        content.title = locked ? Brand.name : title
        content.body = Prefs.notifyPreviews && !locked ? body : "New message"
        content.threadIdentifier = locked ? "locked" : chat
        content.userInfo = ["chat": locked ? "" : chat]
        let chatSound = ChatPrefs.sound(chat)
        content.sound = Tones.chime(chatSound.isEmpty ? Prefs.notifySound : chatSound)
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
    @objc private func showAbout(_ sender: Any?) {
        AboutWindowController.shared.present()
    }

    @objc func showSettings(_ sender: Any?) {
        guard let store else { return }
        if settings == nil { settings = SettingsWindowController(store: store) }
        settings?.showWindow(sender)
        settings?.window?.makeKeyAndOrderFront(sender)
    }
    @objc func nextChat(_ sender: Any?) { wc?.list.selectRelative(1) }
    @objc func previousChat(_ sender: Any?) { wc?.list.selectRelative(-1) }
    @objc func searchChats(_ sender: Any?) { wc?.list.focusSearch() }
    @objc func showArchived(_ sender: Any?) { wc?.list.showArchive(true) }
    @objc func showChats(_ sender: Any?) { wc?.list.showArchive(false) }
    @objc func goToChat(_ sender: NSMenuItem) { wc?.list.selectNth(sender.tag) }
    @objc func toggleCompactSidebar(_ sender: Any?) { wc?.toggleCompactSidebar(sender) }
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

        _ = menu(Brand.name, [
            item("About \(Brand.name)", #selector(showAbout(_:)), target: self),
            Updates.menuItem(),
            .separator(),
            item("Settings…", #selector(showSettings(_:)), ",", target: self),
            .separator(),
            item("Log Out of WhatsApp…", #selector(logOut(_:)), target: self),
            .separator(),
            item("Hide \(Brand.name)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit \(Brand.name)", #selector(NSApplication.terminate(_:)), "q"),
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
            item("Compact Sidebar", #selector(toggleCompactSidebar(_:)), "s", [.command, .control], target: self),
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
