import AppKit
import AVFoundation
import CryptoKit
import UniformTypeIdentifiers

/// A sticker the panel can show and send: from a chat, Favorites, or made here.
struct StickerItem: Hashable {
    var path: String
    var mime: String
    var width: Int
    var height: Int
    var chat = ""
    var id = ""
    var hash = ""
}

enum StickerLibrary {
    /// The core's saved stickers changed (a Favorite synced from the phone, one made here).
    static let changed = Notification.Name("WA.stickersChanged")

    /// SHA-256 of the file, hex: the key Favorites are stored under.
    nonisolated static func hash(of path: String) -> String? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func isAnimated(_ path: String) -> Bool {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return false }
        return CGImageSourceGetCount(src) > 1
    }

    /// A sticker glyph (a square with a peeled corner) for the panel's switch.
    static let glyph: NSImage = {
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
            let p = NSBezierPath()
            p.move(to: CGPoint(x: 4.5, y: 1.5))
            p.line(to: CGPoint(x: 11.5, y: 1.5))
            p.appendArc(from: CGPoint(x: 14.5, y: 1.5), to: CGPoint(x: 14.5, y: 4.5), radius: 3)
            p.line(to: CGPoint(x: 14.5, y: 8.5))
            p.line(to: CGPoint(x: 8.5, y: 14.5))
            p.line(to: CGPoint(x: 4.5, y: 14.5))
            p.appendArc(from: CGPoint(x: 1.5, y: 14.5), to: CGPoint(x: 1.5, y: 11.5), radius: 3)
            p.line(to: CGPoint(x: 1.5, y: 4.5))
            p.appendArc(from: CGPoint(x: 1.5, y: 1.5), to: CGPoint(x: 4.5, y: 1.5), radius: 3)
            p.move(to: CGPoint(x: 14.5, y: 8.5))
            p.line(to: CGPoint(x: 11, y: 8.5))
            p.appendArc(from: CGPoint(x: 8.5, y: 8.5), to: CGPoint(x: 8.5, y: 11), radius: 2.5)
            p.line(to: CGPoint(x: 8.5, y: 14.5))
            p.lineWidth = 1.5
            p.lineJoinStyle = .round
            NSColor.black.setStroke()
            p.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }()
}

// MARK: - GIF search (GIPHY)

/// GIF search and trending through GIPHY. The API key is yours, in a private file in
/// WA's data folder (giphy.key, mode 600), or GIPHY_API_KEY in the environment; none
/// ships with the app. Not the Keychain: an ad-hoc signed app is a new app to the
/// Keychain after every build, so it asked for the password each launch.
enum GIFSearch {
    struct Result: Sendable {
        let id: String
        let preview: URL
        let mp4: URL
        let width: Int
        let height: Int
    }

    private static var keyFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WA/giphy.key")
    }

    static var key: String? {
        if let k = ProcessInfo.processInfo.environment["GIPHY_API_KEY"], !k.isEmpty { return k }
        guard let k = try? String(contentsOf: keyFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !k.isEmpty else { return nil }
        return k
    }

    @discardableResult
    static func saveKey(_ k: String) -> Bool {
        let path = keyFile.path
        guard FileManager.default.createFile(atPath: path, contents: Data(k.utf8), attributes: [.posixPermissions: 0o600]) else {
            return false
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return true
    }

    /// Search results, or what's trending for an empty query.
    static func fetch(_ q: String, key: String) async -> [Result]? {
        var c = URLComponents(string: q.isEmpty ? "https://api.giphy.com/v1/gifs/trending" : "https://api.giphy.com/v1/gifs/search")
        var items = [URLQueryItem(name: "api_key", value: key), URLQueryItem(name: "limit", value: "30"),
                     URLQueryItem(name: "rating", value: "pg-13")]
        if !q.isEmpty { items.append(URLQueryItem(name: "q", value: q)) }
        c?.queryItems = items
        guard let url = c?.url, let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["data"] as? [[String: Any]] else { return nil }
        return results.compactMap { r in
            guard let id = r["id"] as? String, let images = r["images"] as? [String: [String: Any]],
                  let small = images["fixed_width_downsampled"] ?? images["fixed_width"],
                  let p = (small["url"] as? String).flatMap(URL.init(string:)),
                  let m = ((images["original_mp4"]?["mp4"] ?? images["original"]?["mp4"]) as? String).flatMap(URL.init(string:))
            else { return nil }
            return Result(id: id, preview: p, mp4: m, width: Int(small["width"] as? String ?? "") ?? 0,
                          height: Int(small["height"] as? String ?? "") ?? 0)
        }
    }
}

// MARK: - The panel

/// Emoji · GIF · Stickers, like WhatsApp's expression panel.
final class ExpressionPanelViewController: NSViewController {
    enum Mode: Int { case emoji, gif, stickers }
    enum StickerTab: Int { case recent, favorites, mine }
    enum GIFChoice {
        case giphy(GIFSearch.Result)
        case chat(Message)
    }

    var onSendSticker: ((StickerItem) -> Void)?
    var onSendGIF: ((GIFChoice) -> Void)?
    var onCreateSticker: (() -> Void)?
    var onInsertEmoji: ((String) -> Void)?
    var onFavorite: ((StickerItem, Bool) -> Void)?
    var onDownload: ((String, String) -> Void)?
    /// A saved sticker listed before its file arrived (key "wa:…").
    var onFetchSaved: ((String) -> Void)?

    private let store: Store
    private let switcher = NSSegmentedControl()
    private let emojiPane = NSView()
    private let emojiSearch = NSSearchField()
    private var emojiTabs: [NSButton] = []
    private let emojiMark = NSView()
    private var emojiMarkX: NSLayoutConstraint?
    private let emojiScroll = NSScrollView()
    private let emojiGrid = EmojiGridView()
    /// Which grid section each emoji tab jumps to (Recent is only there when there's history).
    private var emojiTabSection: [Int] = []
    private let stickerPane = NSView()
    private let gifPane = NSView()
    private var tabButtons: [NSButton] = []
    private let tabMark = NSView()
    private let createButton = NSButton()
    private let stickerScroll = NSScrollView()
    private let stickerGrid = PanelGrid()
    private let gifScroll = NSScrollView()
    private let gifGrid = PanelGrid()
    private let search = NSSearchField()
    private let keyNote = NSStackView()
    /// GIPHY's terms ask for its credit wherever its search shows.
    private let poweredBy = NSTextField(labelWithString: "Powered by GIPHY")
    private var tab: StickerTab = .recent
    private var favorites: Set<String> = []
    private var searchTask: Task<Void, Never>?
    private var requested: Set<String> = []
    /// Recent tiles by message id, to fill in as their files arrive.
    private var stickerCells: [String: StickerCell] = [:]

    private static let modeKey = "WA.expressionMode"
    static let size = NSSize(width: 372, height: 440)

    init(store: Store) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: Self.size))
        switcher.segmentStyle = .automatic
        switcher.segmentCount = 3
        switcher.setImage(NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "Emoji"), forSegment: 0)
        switcher.setLabel("GIF", forSegment: 1)
        switcher.setImage(StickerLibrary.glyph, forSegment: 2)
        for i in 0..<3 { switcher.setWidth(64, forSegment: i) }
        switcher.setToolTip("Emoji", forSegment: 0)
        switcher.setToolTip("GIFs", forSegment: 1)
        switcher.setToolTip("Stickers", forSegment: 2)
        switcher.trackingMode = .selectOne
        switcher.target = self
        switcher.action = #selector(switchMode)

        buildEmojiPane()
        buildStickerPane()
        buildGIFPane()
        for v in [emojiPane, stickerPane, gifPane, switcher] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            switcher.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            switcher.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            stickerPane.topAnchor.constraint(equalTo: root.topAnchor),
            stickerPane.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stickerPane.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stickerPane.bottomAnchor.constraint(equalTo: switcher.topAnchor, constant: -10),
            gifPane.topAnchor.constraint(equalTo: root.topAnchor),
            gifPane.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            gifPane.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            gifPane.bottomAnchor.constraint(equalTo: switcher.topAnchor, constant: -10),
            emojiPane.topAnchor.constraint(equalTo: root.topAnchor),
            emojiPane.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            emojiPane.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            emojiPane.bottomAnchor.constraint(equalTo: switcher.topAnchor, constant: -10),
        ])
        view = root
        let saved = Mode(rawValue: UserDefaults.standard.integer(forKey: Self.modeKey)) ?? .stickers
        show(Mode(rawValue: UserDefaults.standard.integer(forKey: Self.modeKey)) ?? .emoji)

        NotificationCenter.default.addObserver(forName: StickerLibrary.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stickerPane.isHidden, self.tab != .recent else { return }
                self.fillStickers()
            }
        }
        // A sticker or GIF arrived: fill in its tile instead of rebuilding the grid.
        NotificationCenter.default.addObserver(forName: MediaThumb.downloaded, object: nil, queue: .main) { [weak self] n in
            let chat = n.userInfo?["chat"] as? String ?? "", id = n.userInfo?["id"] as? String ?? ""
            MainActor.assumeIsolated {
                guard let self else { return }
                if let cell = self.stickerCells[id], let m = self.store.message(chat: chat, id: id) {
                    cell.fill(path: m.mediaPath)
                } else if !self.gifPane.isHidden {
                    self.fillGIFs()
                }
            }
        }
    }

    private func show(_ mode: Mode) {
        switcher.selectedSegment = mode.rawValue
        stickerPane.isHidden = mode != .stickers
        emojiPane.isHidden = mode != .emoji
        gifPane.isHidden = mode != .gif
        UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
        refresh()
    }

    @objc private func switchMode() {
        guard let mode = Mode(rawValue: switcher.selectedSegment) else { return }
        show(mode)
    }

    private func refresh() {
        if !emojiPane.isHidden { fillEmoji() }
        if !stickerPane.isHidden { fillStickers() }
        if !gifPane.isHidden { fillGIFs() }
    }

    // MARK: emoji

    private func buildEmojiPane() {
        emojiSearch.placeholderString = "Search emoji"
        emojiSearch.sendsSearchStringImmediately = true
        emojiSearch.target = self
        emojiSearch.action = #selector(emojiSearchChanged)
        let titles = ["Recent"] + EmojiCatalog.groups.map(\.title)
        let symbols = ["clock"] + EmojiCatalog.groups.map(\.symbol)
        for (i, s) in symbols.enumerated() {
            let b = NSButton()
            b.isBordered = false
            b.image = NSImage(systemSymbolName: s, accessibilityDescription: titles[i])?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
            b.imagePosition = .imageOnly
            b.toolTip = titles[i]
            b.tag = i
            b.target = self
            b.action = #selector(pickEmojiTab(_:))
            b.widthAnchor.constraint(equalToConstant: 34).isActive = true
            b.heightAnchor.constraint(equalToConstant: 30).isActive = true
            emojiTabs.append(b)
        }
        let tabs = NSStackView(views: emojiTabs)
        tabs.spacing = 4
        tabs.distribution = .equalSpacing
        emojiMark.wantsLayer = true
        emojiMark.layer?.backgroundColor = Theme.accent.cgColor
        emojiMark.layer?.cornerRadius = 1.5
        emojiScroll.documentView = emojiGrid
        emojiScroll.hasVerticalScroller = true
        // Overlay scrollers even with "always show scroll bars": a classic one eats
        // a column of the grid in a panel this narrow.
        emojiScroll.scrollerStyle = .overlay
        emojiScroll.drawsBackground = false
        emojiScroll.automaticallyAdjustsContentInsets = false
        emojiScroll.contentView.postsBoundsChangedNotifications = true
        emojiGrid.autoresizingMask = [.width]
        emojiGrid.onPick = { [weak self] e in
            EmojiCatalog.used(e)
            self?.onInsertEmoji?(e)
        }
        emojiGrid.onSectionVisible = { [weak self] s in self?.markEmojiTab(forSection: s) }
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: emojiScroll.contentView,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.emojiGrid.scrolled() }
        }
        let rule = NSBox()
        rule.boxType = .separator
        for v in [emojiSearch, tabs, emojiMark, rule, emojiScroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            emojiPane.addSubview(v)
        }
        NSLayoutConstraint.activate([
            emojiSearch.topAnchor.constraint(equalTo: emojiPane.topAnchor, constant: 12),
            emojiSearch.leadingAnchor.constraint(equalTo: emojiPane.leadingAnchor, constant: 12),
            emojiSearch.trailingAnchor.constraint(equalTo: emojiPane.trailingAnchor, constant: -12),
            tabs.topAnchor.constraint(equalTo: emojiSearch.bottomAnchor, constant: 6),
            tabs.leadingAnchor.constraint(equalTo: emojiPane.leadingAnchor, constant: 10),
            tabs.trailingAnchor.constraint(equalTo: emojiPane.trailingAnchor, constant: -10),
            rule.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 2),
            rule.leadingAnchor.constraint(equalTo: emojiPane.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: emojiPane.trailingAnchor),
            emojiMark.heightAnchor.constraint(equalToConstant: 3),
            emojiMark.widthAnchor.constraint(equalToConstant: 20),
            emojiMark.bottomAnchor.constraint(equalTo: rule.topAnchor, constant: 1),
            emojiScroll.topAnchor.constraint(equalTo: rule.bottomAnchor),
            emojiScroll.leadingAnchor.constraint(equalTo: emojiPane.leadingAnchor),
            emojiScroll.trailingAnchor.constraint(equalTo: emojiPane.trailingAnchor),
            emojiScroll.bottomAnchor.constraint(equalTo: emojiPane.bottomAnchor),
        ])
    }

    @objc private func emojiSearchChanged() { fillEmoji() }

    private func fillEmoji() {
        let q = emojiSearch.stringValue.trimmingCharacters(in: .whitespaces)
        var sections: [EmojiGridView.Section] = []
        emojiTabSection = []
        if !q.isEmpty {
            sections = [.init(title: "Results", emoji: EmojiCatalog.search(q))]
        } else {
            let byChar = Dictionary(EmojiCatalog.groups.flatMap(\.emoji).map { ($0.char, $0) }, uniquingKeysWith: { a, _ in a })
            let recent = EmojiCatalog.recent.map { byChar[$0] ?? .init(char: $0, name: "", tones: false) }
            if !recent.isEmpty {
                sections.append(.init(title: "Recently Used", emoji: recent))
                emojiTabSection.append(0)
            } else {
                emojiTabSection.append(-1)
            }
            for g in EmojiCatalog.groups {
                emojiTabSection.append(sections.count)
                sections.append(.init(title: g.title, emoji: g.emoji))
            }
        }
        for (i, b) in emojiTabs.enumerated() { b.isEnabled = q.isEmpty && (emojiTabSection.indices.contains(i) && emojiTabSection[i] >= 0) }
        emojiGrid.frame.size.width = emojiScroll.contentView.bounds.width
        emojiGrid.set(sections)
        emojiScroll.contentView.scroll(to: .zero)
        emojiScroll.reflectScrolledClipView(emojiScroll.contentView)
        markEmojiTab(forSection: 0)
    }

    @objc private func pickEmojiTab(_ b: NSButton) {
        guard emojiTabSection.indices.contains(b.tag), emojiTabSection[b.tag] >= 0 else { return }
        let y = emojiGrid.top(of: emojiTabSection[b.tag])
        emojiScroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        emojiScroll.reflectScrolledClipView(emojiScroll.contentView)
    }

    private func markEmojiTab(forSection s: Int) {
        let tab = emojiTabSection.lastIndex(where: { $0 >= 0 && $0 <= s }) ?? 0
        for (i, b) in emojiTabs.enumerated() { b.contentTintColor = i == tab ? Theme.accent : .secondaryLabelColor }
        emojiMarkX?.isActive = false
        emojiMarkX = emojiMark.centerXAnchor.constraint(equalTo: emojiTabs[tab].centerXAnchor)
        emojiMarkX?.isActive = true
        emojiMark.isHidden = !emojiSearch.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: stickers

    private func buildStickerPane() {
        let symbols = [("clock", "Recent"), ("star", "Favorites"), ("person.crop.square", "My Stickers")]
        for (i, s) in symbols.enumerated() {
            let b = NSButton()
            b.isBordered = false
            b.image = NSImage(systemSymbolName: s.0, accessibilityDescription: s.1)?
                .withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
            b.imagePosition = .imageOnly
            b.toolTip = s.1
            b.tag = i
            b.target = self
            b.action = #selector(pickTab(_:))
            b.translatesAutoresizingMaskIntoConstraints = false
            tabButtons.append(b)
        }
        createButton.isBordered = false
        createButton.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: "Create Sticker")?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        createButton.contentTintColor = .secondaryLabelColor
        createButton.toolTip = "Create Sticker"
        createButton.target = self
        createButton.action = #selector(create)
        tabMark.wantsLayer = true
        tabMark.layer?.backgroundColor = Theme.accent.cgColor
        tabMark.layer?.cornerRadius = 1.5

        let bar = NSStackView(views: tabButtons + [NSView(), createButton])
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        for b in tabButtons {
            b.widthAnchor.constraint(equalToConstant: 44).isActive = true
            b.heightAnchor.constraint(equalToConstant: 34).isActive = true
        }
        stickerScroll.documentView = stickerGrid
        stickerScroll.hasVerticalScroller = true
        stickerScroll.scrollerStyle = .overlay
        stickerScroll.drawsBackground = false
        stickerScroll.automaticallyAdjustsContentInsets = false
        stickerScroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
        let rule = NSBox()
        rule.boxType = .separator
        for v in [bar, tabMark, rule, stickerScroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            stickerPane.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: stickerPane.topAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: stickerPane.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: stickerPane.trailingAnchor),
            rule.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 4),
            rule.leadingAnchor.constraint(equalTo: stickerPane.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: stickerPane.trailingAnchor),
            tabMark.heightAnchor.constraint(equalToConstant: 3),
            tabMark.widthAnchor.constraint(equalToConstant: 24),
            tabMark.bottomAnchor.constraint(equalTo: rule.topAnchor, constant: 1),
            stickerScroll.topAnchor.constraint(equalTo: rule.bottomAnchor),
            stickerScroll.leadingAnchor.constraint(equalTo: stickerPane.leadingAnchor),
            stickerScroll.trailingAnchor.constraint(equalTo: stickerPane.trailingAnchor),
            stickerScroll.bottomAnchor.constraint(equalTo: stickerPane.bottomAnchor),
        ])
    }

    private var tabMarkX: NSLayoutConstraint?

    @objc private func pickTab(_ b: NSButton) {
        tab = StickerTab(rawValue: b.tag) ?? .recent
        fillStickers()
        stickerScroll.contentView.scroll(to: NSPoint(x: 0, y: -stickerScroll.contentInsets.top))
    }

    @objc private func create() { onCreateSticker?() }

    /// Dev hook: searches GIPHY.
    func debugGIFSearch(_ q: String) {
        search.stringValue = q
        fillGIFs()
    }

    /// Dev hook: shows a sticker tab.
    func debugTab(_ i: Int) {
        tab = StickerTab(rawValue: i) ?? .recent
        fillStickers()
    }

    private func fillStickers() {
        for b in tabButtons {
            b.contentTintColor = b.tag == tab.rawValue ? Theme.accent : .secondaryLabelColor
        }
        tabMarkX?.isActive = false
        tabMarkX = tabMark.centerXAnchor.constraint(equalTo: tabButtons[tab.rawValue].centerXAnchor)
        tabMarkX?.isActive = true

        favorites = Set(store.savedStickers(favorites: true).compactMap { $0.hash.isEmpty ? nil : $0.hash })
        var cells: [NSView] = []
        let items: [StickerItem]
        switch tab {
        case .recent:
            items = store.recentStickers()
            cells.append(CreateCell { [weak self] in self?.onCreateSticker?() })
        case .favorites:
            items = store.savedStickers(favorites: true)
        case .mine:
            items = store.savedStickers(favorites: false)
            cells.append(CreateCell { [weak self] in self?.onCreateSticker?() })
        }
        stickerCells = [:]
        for s in items {
            let cell = StickerCell(item: s)
            cell.onClick = { [weak self] in
                guard let self, let live = cell.current, !live.path.isEmpty else { return }
                self.onSendSticker?(live)
            }
            cell.menuProvider = { [weak self] in cell.current.flatMap { $0.path.isEmpty ? nil : self?.menu(for: $0) } }
            // Not here yet: fetch it the first time its tile is on screen (from the
            // phone when the server no longer has it).
            cell.onNeedsFile = { [weak self] in
                guard let self, !self.requested.contains(s.id + s.hash) else { return }
                self.requested.insert(s.id + s.hash)
                if s.hash.hasPrefix("wa:") { self.onFetchSaved?(s.hash) } else if !s.id.isEmpty { self.onDownload?(s.chat, s.id) }
            }
            if !s.id.isEmpty { stickerCells[s.id] = cell }
            cells.append(cell)
        }
        let empty: String? = items.isEmpty ? {
            switch tab {
            case .recent: return "Stickers sent in your chats show up here."
            case .favorites: return "Favorites from your phone, and stickers you star here, show up here. Click a sticker in a chat to add it."
            case .mine: return "Stickers you make show up here."
            }
        }() : nil
        stickerGrid.set(cells: cells, columns: 5, cell: 62, spacing: 8, inset: 12, empty: empty)
    }

    private func menu(for s: StickerItem) -> NSMenu {
        let m = NSMenu()
        let hash = s.hash.isEmpty ? (StickerLibrary.hash(of: s.path) ?? "") : s.hash
        let fav = favorites.contains(hash)
        m.addItem(ClosureMenuItem(title: fav ? "Remove from Favorites" : "Add to Favorites") { [weak self] in
            self?.onFavorite?(s, !fav)
        })
        return m
    }

    // MARK: GIFs

    private func buildGIFPane() {
        search.placeholderString = "Search GIPHY"
        search.sendsSearchStringImmediately = false
        search.sendsWholeSearchString = false
        search.target = self
        search.action = #selector(searchChanged)
        let note = NSTextField(wrappingLabelWithString: "GIF search uses GIPHY and needs an API key of your own (free at developers.giphy.com).")
        note.font = .systemFont(ofSize: 11.5)
        note.textColor = .secondaryLabelColor
        let add = NSButton(title: "Add Key…", target: self, action: #selector(addKey))
        add.controlSize = .small
        keyNote.orientation = .horizontal
        keyNote.alignment = .centerY
        keyNote.spacing = 8
        keyNote.addArrangedSubview(note)
        keyNote.addArrangedSubview(add)
        gifScroll.documentView = gifGrid
        gifScroll.hasVerticalScroller = true
        gifScroll.scrollerStyle = .overlay
        gifScroll.drawsBackground = false
        gifScroll.automaticallyAdjustsContentInsets = false
        gifScroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
        poweredBy.font = .systemFont(ofSize: 10.5, weight: .medium)
        poweredBy.textColor = .tertiaryLabelColor
        // The key note or GIPHY's credit, whichever applies; hidden ones take no room.
        let info = NSStackView(views: [keyNote, poweredBy])
        info.orientation = .vertical
        info.alignment = .leading
        info.detachesHiddenViews = true
        for v in [search, info, gifScroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            gifPane.addSubview(v)
        }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: gifPane.topAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: gifPane.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: gifPane.trailingAnchor, constant: -12),
            info.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6),
            info.leadingAnchor.constraint(equalTo: gifPane.leadingAnchor, constant: 16),
            info.trailingAnchor.constraint(equalTo: gifPane.trailingAnchor, constant: -12),
            keyNote.widthAnchor.constraint(equalTo: info.widthAnchor),
            gifScroll.topAnchor.constraint(equalTo: info.bottomAnchor, constant: 4),
            gifScroll.leadingAnchor.constraint(equalTo: gifPane.leadingAnchor),
            gifScroll.trailingAnchor.constraint(equalTo: gifPane.trailingAnchor),
            gifScroll.bottomAnchor.constraint(equalTo: gifPane.bottomAnchor),
        ])
    }

    @objc private func searchChanged() { fillGIFs() }

    @objc private func addKey() {
        guard let window = view.window else { return }
        let a = NSAlert()
        a.messageText = "GIPHY API key"
        a.informativeText = "Create one at developers.giphy.com (free). It's kept in a private file in WA's data folder."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        a.accessoryView = field
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        a.beginSheetModal(for: window) { [weak self] resp in
            let k = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard resp == .alertFirstButtonReturn, !k.isEmpty else { return }
            MainActor.assumeIsolated {
                GIFSearch.saveKey(k)
                self?.fillGIFs()
            }
        }
    }

    private func fillGIFs() {
        let key = GIFSearch.key
        keyNote.isHidden = key != nil
        poweredBy.isHidden = key == nil
        search.isEnabled = key != nil
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        var sections: [(String?, [NSView])] = []
        if q.isEmpty {
            let recent = store.recentGIFs()
            for g in recent where g.msg.mediaPath.isEmpty && !requested.contains(g.msg.id) {
                requested.insert(g.msg.id)
                onDownload?(g.chat, g.msg.id)
            }
            let cells: [NSView] = recent.filter { !$0.msg.mediaPath.isEmpty }.map { g in
                let c = GIFCell(poster: g.msg.mediaPath)
                c.onClick = { [weak self] in self?.onSendGIF?(.chat(g.msg)) }
                return c
            }
            if !cells.isEmpty { sections.append(("Recent", cells)) }
        }
        gifGrid.set(sections: sections, columns: 3, cell: 108, spacing: 6, inset: 12,
                    empty: key == nil && sections.isEmpty ? "GIFs from your chats show up here." : nil)
        guard let key else { return }
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            let results = await GIFSearch.fetch(q, key: key)
            guard let self, !Task.isCancelled else { return }
            let cells: [NSView] = (results ?? []).map { r in
                let c = GIFCell(remote: r.preview)
                c.onClick = { [weak self] in self?.onSendGIF?(.giphy(r)) }
                return c
            }
            var all = q.isEmpty ? sections : []
            if !cells.isEmpty { all.append((q.isEmpty ? "Trending" : nil, cells)) }
            self.gifGrid.set(sections: all, columns: 3, cell: 108, spacing: 6, inset: 12,
                             empty: results == nil ? "GIPHY didn't answer. Check the key and your connection." : (all.isEmpty ? "No GIFs found." : nil))
        }
    }
}

// MARK: - Grid and cells

/// Fixed-size cells in rows, with optional section titles; the scroll view's document.
private final class PanelGrid: NSView {
    override var isFlipped: Bool { true }
    private var sections: [(String?, [NSView])] = []
    private var columns = 4
    private var cellSize: CGFloat = 60
    private var spacing: CGFloat = 8
    private var inset: CGFloat = 12
    private var emptyLabel: NSTextField?

    func set(cells: [NSView], columns: Int, cell: CGFloat, spacing: CGFloat, inset: CGFloat, empty: String?) {
        set(sections: [(nil, cells)], columns: columns, cell: cell, spacing: spacing, inset: inset, empty: empty)
    }

    func set(sections: [(String?, [NSView])], columns: Int, cell: CGFloat, spacing: CGFloat, inset: CGFloat, empty: String?) {
        subviews.forEach { $0.removeFromSuperview() }
        self.sections = sections
        self.columns = columns
        cellSize = cell
        self.spacing = spacing
        self.inset = inset
        emptyLabel = nil
        if let empty {
            let l = NSTextField(wrappingLabelWithString: empty)
            l.alignment = .center
            l.font = .systemFont(ofSize: 12.5)
            l.textColor = .secondaryLabelColor
            emptyLabel = l
            addSubview(l)
        }
        for (title, cells) in sections {
            if let title {
                let t = NSTextField(labelWithString: title)
                t.font = .systemFont(ofSize: 11, weight: .semibold)
                t.textColor = .secondaryLabelColor
                t.identifier = .init("title")
                addSubview(t)
            }
            cells.forEach(addSubview)
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        let width = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        let side = floor((width - 2 * inset - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        var y: CGFloat = 4
        var titles = subviews.filter { $0.identifier?.rawValue == "title" }.makeIterator()
        for (title, cells) in sections {
            if title != nil, let t = titles.next() as? NSTextField {
                t.sizeToFit()
                t.frame.origin = CGPoint(x: inset + 2, y: y + 2)
                y += 22
            }
            for (i, c) in cells.enumerated() {
                let col = i % columns, row = i / columns
                c.frame = CGRect(x: inset + CGFloat(col) * (side + spacing), y: y + CGFloat(row) * (side + spacing), width: side, height: side)
            }
            let rows = (cells.count + columns - 1) / columns
            y += CGFloat(rows) * (side + spacing) + 6
        }
        if let l = emptyLabel {
            l.preferredMaxLayoutWidth = width - 60
            let s = l.fittingSize
            l.frame = CGRect(x: (width - s.width) / 2, y: max(y, 70), width: s.width, height: s.height)
            y = l.frame.maxY + 20
        }
        let h = max(y, (enclosingScrollView?.contentView.bounds.height ?? 0) - 12)
        if frame.size != CGSize(width: width, height: h) { setFrameSize(CGSize(width: width, height: h)) }
    }
}

/// A clickable square with a soft hover fill.
private class PanelCell: NSView {
    var onClick: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    private var hovering = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; hoverChanged(true) }
    override func mouseExited(with event: NSEvent) { hovering = false; hoverChanged(false) }
    func hoverChanged(_ on: Bool) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func mouseDown(with event: NSEvent) {}
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A sticker: still at rest, playing while the pointer is on it (animated ones).
private final class StickerCell: PanelCell {
    private let imageView = NSImageView()
    private var item: StickerItem
    /// The sticker as it is now (its file may have arrived since the grid was built).
    var current: StickerItem? { item }
    var onNeedsFile: (() -> Void)?

    init(item: StickerItem) {
        self.item = item
        super.init(frame: .zero)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = false
        imageView.autoresizingMask = [.width, .height]
        imageView.wantsLayer = true
        addSubview(imageView)
        toolTip = nil
        if !item.path.isEmpty {
            ImageCache.shared.load(item.path, px: 128) { [weak self] img in self?.imageView.image = img }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The file arrived.
    func fill(path: String) {
        guard !path.isEmpty else { return }
        item.path = path
        ImageCache.shared.load(path, px: 128) { [weak self] img in
            guard let self, let img else { return }
            self.imageView.image = img
            if !Theme.reduceMotion { Motion.fade(self.imageView.layer, duration: 0.2) }
            self.needsDisplay = true
        }
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        // Only tiles actually on screen ask (each may mean a re-upload from the phone).
        if item.path.isEmpty, window?.isVisible == true, !visibleRect.isEmpty { onNeedsFile?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard item.path.isEmpty else { return }
        // Still on its way: the same quiet stand-in the chat uses.
        let r = bounds.insetBy(dx: 7, dy: 7)
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12).fill()
        let glyph = MessageLayout.symbol("face.smiling", size: 18, color: .tertiaryLabelColor)
        let gs = glyph.size()
        glyph.draw(at: CGPoint(x: r.midX - gs.width / 2, y: r.midY - gs.height / 2 + (isFlipped ? 2 : -2)))
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds.insetBy(dx: 4, dy: 4)
    }

    override func hoverChanged(_ on: Bool) {
        guard item.mime != "application/was", !item.path.isEmpty else { return }
        if on, let full = NSImage(contentsOfFile: item.path) {
            imageView.animates = true
            imageView.image = full
        } else if !on {
            imageView.animates = false
            ImageCache.shared.load(item.path, px: 128) { [weak self] img in self?.imageView.image = img }
        }
    }
}

/// "Create" as the first tile, like WhatsApp's.
private final class CreateCell: PanelCell {
    init(_ action: @escaping () -> Void) {
        super.init(frame: .zero)
        onClick = action
        toolTip = "Create a sticker from a photo"
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 3, dy: 3)
        let p = NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14)
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        p.fill()
        NSColor.labelColor.withAlphaComponent(0.12).setStroke()
        p.lineWidth = 1
        p.stroke()
        let plus = MessageLayout.symbol("plus", size: 17, color: .secondaryLabelColor)
        let ps = plus.size()
        plus.draw(at: CGPoint(x: r.midX - ps.width / 2, y: r.midY - ps.height + 4))
        let t = NSAttributedString(string: "Create", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                                   .foregroundColor: NSColor.secondaryLabelColor])
        let ts = t.size()
        t.draw(at: CGPoint(x: r.midX - ts.width / 2, y: r.midY + 4))
    }
    override var isFlipped: Bool { true }
}

/// A GIF: a chat GIF's first frame, or a GIPHY preview playing.
private final class GIFCell: PanelCell {
    private let imageView = NSImageView()

    init(poster path: String) {
        super.init(frame: .zero)
        setUp()
        ImageCache.shared.load(path, px: 240) { [weak self] img in self?.imageView.image = img }
    }

    init(remote url: URL) {
        super.init(frame: .zero)
        setUp()
        imageView.animates = true
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url), let img = NSImage(data: data) else { return }
            self?.imageView.image = img
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
    }
}

// MARK: - A sticker in a chat

/// Clicking a sticker in a chat: a closer look, Favorite and Send.
final class StickerCardViewController: NSViewController {
    var onFavorite: ((Bool) -> Void)?
    var onSend: (() -> Void)?
    private let item: StickerItem
    private var favorite: Bool
    let imageView = NSImageView()
    static let side: CGFloat = 180
    /// The card on screen (dev hook draws it).
    static weak var shown: StickerCardViewController?

    init(item: StickerItem, favorite: Bool) {
        self.item = item
        self.favorite = favorite
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        imageView.image = NSImage(contentsOfFile: item.path)
        let fav = NSButton(title: favorite ? "Favorited" : "Favorite", target: self, action: #selector(toggle))
        fav.image = NSImage(systemSymbolName: favorite ? "star.fill" : "star", accessibilityDescription: nil)
        fav.imagePosition = .imageLeading
        fav.contentTintColor = favorite ? .systemYellow : nil
        fav.toolTip = favorite ? "Remove from Favorites" : "Add to Favorites"
        let send = NSButton(title: "Send", target: self, action: #selector(sendIt))
        send.keyEquivalent = "\r"
        for b in [fav, send] {
            b.bezelStyle = .push
            b.controlSize = .large
        }
        let buttons = NSStackView(views: [fav, send])
        buttons.distribution = .fillEqually
        buttons.spacing = 8
        for v in [imageView, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        let pad: CGFloat = 20
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: root.topAnchor, constant: pad),
            imageView.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            imageView.widthAnchor.constraint(equalToConstant: Self.side),
            imageView.heightAnchor.constraint(equalToConstant: Self.side),
            buttons.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 16),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            root.widthAnchor.constraint(equalToConstant: Self.side + 2 * 34),
        ])
        view = root
        Self.shown = self
    }

    /// Where the sticker sits on screen, fitted to its own shape (for the flight in).
    var imageScreenRect: CGRect? {
        guard let window = imageView.window, let img = imageView.image, img.size.width > 0, img.size.height > 0 else { return nil }
        let b = imageView.bounds
        let s = min(b.width / img.size.width, b.height / img.size.height)
        let fit = CGRect(x: b.midX - img.size.width * s / 2, y: b.midY - img.size.height * s / 2,
                         width: img.size.width * s, height: img.size.height * s)
        return window.convertToScreen(imageView.convert(fit, to: nil))
    }

    @objc private func toggle() {
        onFavorite?(!favorite)
        dismiss(nil)
    }

    @objc private func sendIt() {
        onSend?()
        dismiss(nil)
    }
}

/// The sticker lifting out of its bubble and settling into the card: a borderless
/// window above everything, moved from one screen rect to the other.
@MainActor
enum StickerFlight {
    static func fly(_ image: NSImage, from: CGRect, to: CGRect, done: @escaping () -> Void) {
        let panel = NSPanel(contentRect: from, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.collectionBehavior = [.transient, .ignoresCycle]
        let v = NSImageView(frame: CGRect(origin: .zero, size: from.size))
        v.image = image
        v.imageScaling = .scaleAxesIndependently
        v.autoresizingMask = [.width, .height]
        panel.contentView = v
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = Theme.easeOut
            panel.animator().setFrame(to, display: true)
        }, completionHandler: {
            MainActor.assumeIsolated {
                done()
                panel.orderOut(nil)
            }
        })
    }
}

// MARK: - Controller

extension ConversationViewController {
    @discardableResult
    func showExpressions(from anchor: NSView) -> ExpressionPanelViewController? {
        guard chat != nil else { return nil }
        let panel = ExpressionPanelViewController(store: store)
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = panel
        pop.contentSize = ExpressionPanelViewController.size
        panel.onInsertEmoji = { [weak self] e in self?.composer.insertEmoji(e) }
        panel.onSendSticker = { [weak self] s in self?.sendSticker(s) }
        panel.onSendGIF = { [weak self, weak pop] g in
            pop?.close()
            self?.sendGIF(g)
        }
        panel.onCreateSticker = { [weak self, weak pop] in
            pop?.close()
            self?.newSticker()
        }
        panel.onFavorite = { s, on in Self.setFavorite(s, on) }
        panel.onDownload = { chat, id in Core.shared.call("download", ["chat": chat, "id": id, "retry": true]) }
        panel.onFetchSaved = { hash in Core.shared.call("sticker_fetch", ["id": hash]) }
        pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        return panel
    }

    static func setFavorite(_ s: StickerItem, _ on: Bool) {
        Task { @MainActor in
            let r = await Core.shared.callAsync("sticker_favorite", ["path": s.path, "on": on, "mime": s.mime,
                                                                     "width": s.width, "height": s.height,
                                                                     "animated": StickerLibrary.isAnimated(s.path)])
            if r["error"] != nil { NSSound.beep() }
        }
    }

    func sendSticker(_ s: StickerItem) {
        guard let c = chat, !s.path.isEmpty else { return }
        let quote = replyTo?.id ?? ""
        replyTo = nil
        composer.hideReply(animated: true)
        Task { @MainActor in
            let r = await Core.shared.callAsync("send_sticker", ["chat": c.jid, "path": s.path, "mime": s.mime,
                                                                 "width": s.width, "height": s.height,
                                                                 "animated": StickerLibrary.isAnimated(s.path), "quote": quote])
            if r["error"] != nil { NSSound.beep() } else if Prefs.outgoingSound { NSSound(named: "Pop")?.play() }
        }
    }

    /// Sends a GIF the way WhatsApp does: GIPHY's own mp4 (WhatsApp's GIF format, not
    /// image/gif, which arrives as a still), flagged gifPlayback so it plays silently on
    /// a loop, credited to GIPHY. Not re-encoded.
    func sendGIF(_ g: ExpressionPanelViewController.GIFChoice) {
        guard let c = chat else { return }
        Task { @MainActor in
            var local: URL?
            var source = ""
            switch g {
            case .giphy(let r):
                source = "giphy"
                if let (tmp, _) = try? await URLSession.shared.download(from: r.mp4) {
                    let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(r.id).mp4")
                    try? FileManager.default.removeItem(at: dest)
                    if (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil { local = dest }
                }
            case .chat(let m):
                local = m.mediaPath.isEmpty ? nil : URL(fileURLWithPath: m.mediaPath)
            }
            guard let local, let f = await Self.gifInfo(local) else { NSSound.beep(); return }
            let r = await Core.shared.callAsync("send_file", ["chat": c.jid, "path": f.path, "name": "GIF.mp4", "mime": "video/mp4",
                                                              "thumb": f.thumb ?? "", "width": f.width, "height": f.height,
                                                              "seconds": f.seconds, "gif": true, "gif_source": source])
            if r["error"] != nil { NSSound.beep() } else if Prefs.outgoingSound { NSSound(named: "Pop")?.play() }
        }
    }

    /// A GIF mp4's size, length and first frame (for the thumbnail), without re-encoding it.
    @concurrent nonisolated static func gifInfo(_ url: URL) async -> PendingFile? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let shown = natural.applying(transform)
        let seconds = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 320, height: 320)
        var thumb: String?
        if let frame = try? await gen.image(at: .zero).image {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-thumb.jpg")
            if let d = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(d, frame, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
                if CGImageDestinationFinalize(d) { thumb = out.path }
            }
        }
        return PendingFile(path: url.path, name: "GIF.mp4", mime: "video/mp4", thumb: thumb,
                           width: Int(abs(shown.width).rounded()), height: Int(abs(shown.height).rounded()),
                           seconds: max(1, Int(seconds.rounded())))
    }

    /// Clicking a sticker in a chat: the card opens beside it and the sticker flies in.
    func showStickerCard(_ m: Message, from source: NSView, at rect: CGRect) {
        guard !m.mediaPath.isEmpty else { return }
        let item = StickerItem(path: m.mediaPath, mime: m.mime, width: m.width, height: m.height)
        let fav = StickerLibrary.hash(of: m.mediaPath).map { store.isFavoriteSticker(hash: $0) } ?? false
        let card = StickerCardViewController(item: item, favorite: fav)
        card.onFavorite = { on in Self.setFavorite(item, on) }
        card.onSend = { [weak self] in self?.sendSticker(item) }
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = card
        let flies = !Theme.reduceMotion
        if flies { card.imageView.alphaValue = 0 }
        pop.show(relativeTo: rect, of: source, preferredEdge: m.fromMe ? .minX : .maxX)
        guard flies else { return }
        // Once the card is laid out, fly a copy from the bubble to where the card shows it.
        DispatchQueue.main.async {
            guard let window = source.window, let image = card.imageView.image, let to = card.imageScreenRect else {
                card.imageView.alphaValue = 1
                return
            }
            let from = window.convertToScreen(source.convert(rect, to: nil))
            StickerFlight.fly(image, from: from, to: to) { card.imageView.alphaValue = 1 }
        }
    }
}
