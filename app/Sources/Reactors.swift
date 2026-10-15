import AppKit

/// Who reacted to a message, from a click on its tapback badge: a popover on the badge with
/// a row per person (photo, name, the emoji they picked), me first as "You", then the
/// latest. Six rows show; more scroll, with half of the seventh in sight to say so.
final class ReactorsViewController: NSViewController {
    /// `photo` is a picture's path, "-" for none.
    struct Person { let jid: String; let name: String; let emoji: String; let photo: String }

    static let width: CGFloat = 264
    static let rowH: CGFloat = 40
    static let inset: CGFloat = 6
    static let maxRows = 6

    let messageID: String
    private let scroll = NSScrollView()
    private let list = FlippedView()

    init(messageID: String) {
        self.messageID = messageID
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = list
        scroll.setAccessibilityRole(.list)
        scroll.setAccessibilityLabel("Reactions")
        view = scroll
    }

    /// Lays out these people and returns the popover's size for them.
    func set(_ people: [Person]) -> NSSize {
        _ = view
        list.subviews.forEach { $0.removeFromSuperview() }
        let w = Self.width
        for (i, p) in people.enumerated() {
            let row = ReactorRow(p)
            row.frame = NSRect(x: 0, y: Self.inset + CGFloat(i) * Self.rowH, width: w, height: Self.rowH)
            list.addSubview(row)
        }
        let full = CGFloat(people.count) * Self.rowH + 2 * Self.inset
        list.frame = NSRect(x: 0, y: 0, width: w, height: full)
        let shown = people.count > Self.maxRows ? (CGFloat(Self.maxRows) + 0.5) * Self.rowH + Self.inset : full
        return NSSize(width: w, height: shown)
    }
}

/// A 26pt photo at 14pt, the name in 13pt medium, and the emoji at 17pt, 14pt from the end.
private final class ReactorRow: NSView {
    init(_ p: ReactorsViewController.Person) {
        super.init(frame: .zero)
        let avatar = AvatarView(frame: .zero)
        avatar.configure(jid: p.jid, name: p.name, isGroup: false, path: p.photo, px: 52)
        let name = NSTextField(labelWithString: p.name)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        let emoji = NSTextField(labelWithString: p.emoji)
        emoji.font = .systemFont(ofSize: 17)
        emoji.alignment = .center
        for v in [avatar, name, emoji] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.setAccessibilityElement(false)
            addSubview(v)
        }
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 26), avatar.heightAnchor.constraint(equalToConstant: 26),
            name.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 10),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: emoji.leadingAnchor, constant: -10),
            emoji.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            emoji.centerYAnchor.constraint(equalTo: centerYAnchor),
            emoji.widthAnchor.constraint(equalToConstant: 24),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(p.name), \(p.emoji)")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
}

extension ConversationViewController {
    /// The badge's click: everyone who reacted, and with what, in a popover on the badge.
    func showReactors(_ m: Message, from cell: BubbleView, people given: [ReactorsViewController.Person]? = nil) {
        guard let c = chat, let badge = cell.item?.reactionRect else { return }
        let people = given ?? reactorRows(c, m.id)
        guard !people.isEmpty else { return }
        reactors?.close()
        let vc = ReactorsViewController(messageID: m.id)
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = vc
        pop.contentSize = vc.set(people)
        pop.show(relativeTo: badge, of: cell, preferredEdge: .minY)
        reactors = pop
    }

    /// A reaction arrived or was taken back while its list is open: the list follows, and
    /// closes once nobody's left.
    func refreshReactors(_ l: MessageLayout) {
        guard let pop = reactors, pop.isShown, let vc = pop.contentViewController as? ReactorsViewController,
              vc.messageID == l.msg.id, let c = chat else { return }
        let people = reactorRows(c, l.msg.id)
        guard !people.isEmpty, let rect = l.reactionRect else { return pop.close() }
        pop.contentSize = vc.set(people)
        pop.positioningRect = rect
    }

    private func reactorRows(_ c: Chat, _ id: String) -> [ReactorsViewController.Person] {
        store.reactors(chat: c.jid, id: id).map { r in
            let name = r.jid == Core.shared.me ? "You" : !c.isGroup && r.jid == c.jid ? c.name : store.name(r.jid)
            return .init(jid: r.jid, name: name, emoji: r.emoji, photo: Avatars.shared.path(for: r.jid) ?? "-")
        }
    }
}
