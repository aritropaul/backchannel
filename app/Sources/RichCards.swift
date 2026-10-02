import AppKit

/// Poll options from the core's `extra` JSON.
nonisolated struct PollInfo: Decodable, Sendable {
    var options: [String]
    var multi: Bool
}

/// Event details from the core's `extra` JSON.
nonisolated struct EventInfo: Decodable, Sendable {
    var desc: String?
    var loc: String?
    var link: String?
    var start: Int64
    var end: Int64?
    var canceled: Bool?
    var guests: Bool?

    var startDate: Date { Date(timeIntervalSince1970: TimeInterval(start)) }
    var endDate: Date? { end.flatMap { $0 > start ? Date(timeIntervalSince1970: TimeInterval($0)) : nil } }
    var isCanceled: Bool { canceled ?? false }
}

/// Shared contact cards from the core's `extra` JSON.
nonisolated struct ContactCards: Decodable, Sendable {
    struct Phone: Decodable, Sendable {
        var num: String
        var waid: String?
    }
    struct Card: Decodable, Sendable {
        var name: String
        var phones: [Phone]?
        /// The WhatsApp account behind the first number that has one.
        var jid: String? { phones?.first(where: { !($0.waid ?? "").isEmpty }).map { "\($0.waid ?? "")@s.whatsapp.net" } }
        var number: String { phones?.first?.num ?? "" }
    }
    var cards: [Card]
}

extension Message {
    var poll: PollInfo? {
        guard kind == .poll else { return nil }
        if let p = try? JSONDecoder().decode(PollInfo.self, from: Data(extra.utf8)), !p.options.isEmpty { return p }
        // Older rows kept the options as "○ option" lines under the question.
        let lines = text.split(separator: "\n").compactMap { $0.hasPrefix("○ ") ? String($0.dropFirst(2)) : nil }
        return lines.isEmpty ? nil : PollInfo(options: lines, multi: true)
    }

    var pollQuestion: String { text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text }

    var event: EventInfo? {
        guard kind == .event else { return nil }
        return try? JSONDecoder().decode(EventInfo.self, from: Data(extra.utf8))
    }

    var contactCards: ContactCards? {
        guard kind == .contact else { return nil }
        if let c = try? JSONDecoder().decode(ContactCards.self, from: Data(extra.utf8)), !c.cards.isEmpty { return c }
        // Cards stored before their numbers were kept: the name alone.
        return ContactCards(cards: [.init(name: text.isEmpty ? "Contact" : text, phones: nil)])
    }

    /// My current poll selection or event response.
    var myVote: Vote? { votes.first(where: \.isMine) }
}

/// The inside of a poll, event or contact-card bubble: laid out once, drawn into
/// the bubble, and hit-tested for its buttons. Coordinates are relative to its
/// top-left corner, flipped.
final class RichCard {
    enum Hit: Equatable {
        case pollOption(String), pollVotes
        case eventRespond(String), eventDetails
        case contactMessage(String), contactAdd(Int), contactAll
    }

    private struct Line {
        let block: TextBlock
        let origin: CGPoint
    }

    private struct Button {
        let title: String
        let rect: CGRect
        let hit: Hit?
        var selected = false
    }

    private struct OptionRow {
        let name: String
        let rect: CGRect
        let circle: CGRect
        let bar: CGRect
        let fraction: CGFloat
        let count: Int
        let picked: Bool
        let voters: [Vote]
        let countOrigin: CGPoint
    }

    let msg: Message
    private(set) var size = CGSize.zero
    private var lines: [Line] = []
    private var buttons: [Button] = []
    private var options: [OptionRow] = []
    private var dividers: [CGFloat] = []
    private var tile: CGRect?
    private var tileMonth: TextBlock?
    private var tileDay: TextBlock?
    private var avatars: [(jid: String, name: String, rect: CGRect)] = []
    private var detailsRect: CGRect?

    private var fromMe: Bool { msg.fromMe }
    private var ink: NSColor { Theme.ink(fromMe: fromMe) }
    private var soft: NSColor { Theme.secondaryInk(fromMe: fromMe) }
    private var rule: NSColor { fromMe ? Theme.faintOut.withAlphaComponent(0.5) : NSColor.separatorColor }

    static let buttonHeight: CGFloat = 34

    /// A card for this message, or nil when it renders as plain text.
    static func make(msg: Message, width: CGFloat) -> RichCard? {
        switch msg.kind {
        case .poll: msg.poll.map { RichCard(msg: msg, width: width, poll: $0) }
        case .event: msg.event.map { RichCard(msg: msg, width: width, event: $0) }
        case .contact: msg.contactCards.map { RichCard(msg: msg, width: width, contacts: $0) }
        default: nil
        }
    }

    private init(msg: Message) { self.msg = msg }

    private func text(_ s: String, _ font: NSFont, _ color: NSColor, width: CGFloat, lines: Int = 0, strike: Bool = false) -> TextBlock {
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return TextBlock(NSAttributedString(string: s, attributes: attrs), maxWidth: width, maxLines: lines)
    }

    private func add(_ b: TextBlock, x: CGFloat, y: CGFloat) {
        lines.append(Line(block: b, origin: CGPoint(x: x, y: y)))
    }

    /// A row of equal buttons under a rule, at `y`; returns the bottom.
    private func buttonRow(_ items: [(String, Hit?, Bool)], y: CGFloat, width: CGFloat) -> CGFloat {
        dividers.append(y)
        let w = width / CGFloat(items.count)
        for (i, item) in items.enumerated() {
            buttons.append(Button(title: item.0, rect: CGRect(x: CGFloat(i) * w, y: y, width: w, height: Self.buttonHeight),
                                  hit: item.1, selected: item.2))
        }
        return y + Self.buttonHeight
    }

    // MARK: poll

    private convenience init(msg: Message, width: CGFloat, poll: PollInfo) {
        self.init(msg: msg)
        let w = width
        var y: CGFloat = 3
        let q = text(msg.pollQuestion, .systemFont(ofSize: 15, weight: .semibold), ink, width: w)
        add(q, x: 0, y: y)
        y += q.size.height + 2
        let sub = text(poll.multi ? "Select one or more" : "Select one", .systemFont(ofSize: 12), soft, width: w, lines: 1)
        add(sub, x: 0, y: y)
        y += sub.size.height + 12

        let voters = msg.votes.filter { !$0.options.isEmpty }
        let mine = Set(msg.myVote?.options ?? [])
        for name in poll.options {
            let who = voters.filter { $0.options.contains(name) }
            let countText = text(who.isEmpty ? "" : "\(who.count)", .monospacedDigitSystemFont(ofSize: 13, weight: .medium), soft,
                                 width: 40, lines: 1)
            let label = text(name, .systemFont(ofSize: 14), ink, width: w - 30 - 30 - (who.isEmpty ? 0 : 34), lines: 3)
            let top = y
            add(label, x: 30, y: top + 1)
            let textBottom = top + max(label.size.height, 20)
            let bar = CGRect(x: 30, y: textBottom + 6, width: w - 30, height: 4)
            options.append(OptionRow(
                name: name, rect: CGRect(x: -6, y: top - 5, width: w + 12, height: bar.maxY - top + 10),
                circle: CGRect(x: 0, y: top, width: 20, height: 20), bar: bar,
                fraction: voters.isEmpty ? 0 : CGFloat(who.count) / CGFloat(voters.count), count: who.count,
                picked: mine.contains(name), voters: Array(who.prefix(3)),
                countOrigin: CGPoint(x: w - countText.size.width, y: top + 1)))
            add(countText, x: w - countText.size.width, y: top + 1)
            y = bar.maxY + 12
        }
        y -= 2
        let any = !voters.isEmpty
        y = buttonRow([("View votes", any ? .pollVotes : nil, false)], y: y, width: w)
        size = CGSize(width: w, height: y)
    }

    // MARK: event

    private convenience init(msg: Message, width: CGFloat, event: EventInfo) {
        self.init(msg: msg)
        let w = width
        var y: CGFloat = 3
        let t = CGRect(x: 0, y: y, width: 46, height: 50)
        tile = t
        let month = Self.monthFormatter.string(from: event.startDate).uppercased()
        tileMonth = text(month, .systemFont(ofSize: 10.5, weight: .bold), event.isCanceled ? soft : .systemRed, width: 46, lines: 1)
        tileDay = text(Self.dayFormatter.string(from: event.startDate), .systemFont(ofSize: 21, weight: .semibold), ink, width: 46, lines: 1)

        let x: CGFloat = 58
        var ty = y + 1
        let name = text(msg.text.isEmpty ? "Event" : msg.text, .systemFont(ofSize: 15, weight: .semibold), ink,
                        width: w - x, lines: 3, strike: event.isCanceled)
        add(name, x: x, y: ty)
        ty += name.size.height + 2
        let when = text(Self.when(event), .systemFont(ofSize: 12.5), soft, width: w - x, lines: 2)
        add(when, x: x, y: ty)
        ty += when.size.height
        if event.isCanceled {
            let c = text("Cancelled", .systemFont(ofSize: 12, weight: .semibold), .systemRed, width: w - x, lines: 1)
            add(c, x: x, y: ty + 2)
            ty += c.size.height + 2
        }
        y = max(t.maxY, ty) + 10

        if let loc = event.loc, !loc.isEmpty {
            let pin = NSMutableAttributedString(attributedString: MessageLayout.symbol("mappin", size: 12, color: soft))
            pin.append(NSAttributedString(string: " " + loc, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: ink]))
            let b = TextBlock(pin, maxWidth: w, maxLines: 2)
            add(b, x: 0, y: y)
            y += b.size.height + 6
        }
        if let d = event.desc, !d.isEmpty {
            let b = text(d, .systemFont(ofSize: 13), ink, width: w, lines: 4)
            add(b, x: 0, y: y)
            y += b.size.height + 6
        }
        let going = msg.votes.filter { $0.response == "going" }
        let maybe = msg.votes.filter { $0.response == "maybe" }
        var tally: [String] = []
        let goingCount = going.reduce(0) { $0 + 1 + $1.guests }
        if goingCount > 0 { tally.append("\(goingCount) going") }
        if !maybe.isEmpty { tally.append("\(maybe.count) maybe") }
        if !tally.isEmpty || fromMe {
            var ax: CGFloat = 0
            for v in going.prefix(3) {
                avatars.append((v.voter, v.name, CGRect(x: ax, y: y, width: 18, height: 18)))
                ax += 13
            }
            if !avatars.isEmpty { ax += 9 }
            let s = text(tally.isEmpty ? "No responses yet" : tally.joined(separator: " · "), .systemFont(ofSize: 12.5), soft,
                         width: w - ax, lines: 1)
            add(s, x: ax, y: y + (18 - s.size.height) / 2)
            y += 18 + 8
        }
        detailsRect = CGRect(x: -6, y: 0, width: w + 12, height: y)
        if !event.isCanceled {
            if fromMe {
                y = buttonRow([("View responses", .eventDetails, false)], y: y, width: w)
            } else {
                let mine = msg.myVote?.response ?? ""
                y = buttonRow([("Going", .eventRespond("going"), mine == "going"),
                               ("Maybe", .eventRespond("maybe"), mine == "maybe"),
                               ("Not going", .eventRespond("not_going"), mine == "not_going")], y: y, width: w)
            }
        } else {
            y -= 4
        }
        size = CGSize(width: w, height: y)
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM")
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d")
        return f
    }()

    /// "Fri, Oct 3 at 7:00 PM", or a range: "Fri, Oct 3, 7:00 – 9:00 PM".
    static func when(_ e: EventInfo) -> String {
        let day = DateFormatter()
        day.setLocalizedDateFormatFromTemplate("EEE MMM d")
        let time = DateFormatter()
        time.timeStyle = .short
        time.dateStyle = .none
        guard let end = e.endDate else { return "\(day.string(from: e.startDate)) at \(time.string(from: e.startDate))" }
        if Fmt.sameDay(e.startDate, end) {
            return "\(day.string(from: e.startDate)), \(time.string(from: e.startDate)) – \(time.string(from: end))"
        }
        return "\(day.string(from: e.startDate)), \(time.string(from: e.startDate)) – \(day.string(from: end)), \(time.string(from: end))"
    }

    // MARK: contacts

    private convenience init(msg: Message, width: CGFloat, contacts: ContactCards) {
        self.init(msg: msg)
        let w = min(width, 250)
        let cards = contacts.cards
        var ax: CGFloat = 0
        for c in cards.prefix(3) {
            avatars.append((c.jid ?? "", c.name, CGRect(x: ax, y: 3, width: 40, height: 40)))
            ax += 16
        }
        let x = ax + 24 + 10
        let titleText = cards.count == 1 ? cards[0].name
            : "\(cards[0].name) and \(cards.count - 1) other\(cards.count == 2 ? "" : "s")"
        let title = text(titleText.isEmpty ? "Contact" : titleText, .systemFont(ofSize: 14.5, weight: .semibold), ink, width: w - x, lines: 2)
        let subText = cards.count == 1 ? cards[0].number : "\(cards.count) contacts"
        let sub = text(subText, .systemFont(ofSize: 12), soft, width: w - x, lines: 1)
        let blockH = title.size.height + (subText.isEmpty ? 0 : sub.size.height + 1)
        let ty = 3 + max(0, (40 - blockH) / 2)
        add(title, x: x, y: ty)
        if !subText.isEmpty { add(sub, x: x, y: ty + title.size.height + 1) }
        var y: CGFloat = 3 + max(40, blockH) + 10
        if cards.count > 1 {
            y = buttonRow([("View All", .contactAll, false)], y: y, width: w)
        } else if let jid = cards[0].jid {
            y = buttonRow([("Message", .contactMessage(jid), false), ("Add Contact", .contactAdd(0), false)], y: y, width: w)
        } else if !cards[0].number.isEmpty {
            y = buttonRow([("Add Contact", .contactAdd(0), false)], y: y, width: w)
        } else {
            y -= 6
        }
        size = CGSize(width: w, height: y)
    }

    // MARK: hit testing

    func hit(_ p: CGPoint) -> Hit? {
        for b in buttons where b.rect.contains(p) { return b.hit }
        if !msg.fromMe || msg.kind == .poll {
            for o in options where o.rect.contains(p) { return .pollOption(o.name) }
        }
        if let d = detailsRect, d.contains(p), msg.kind == .event { return .eventDetails }
        return nil
    }

    /// Button and option rects, for pointing-hand cursors.
    var clickableRects: [CGRect] {
        buttons.filter { $0.hit != nil }.map(\.rect) + options.map(\.rect)
    }

    // MARK: drawing

    func draw(at o: CGPoint, onImageLoad: @escaping () -> Void) {
        let accent = Theme.accent
        if let t = tile {
            let r = t.offsetBy(dx: o.x, dy: o.y)
            Theme.tint(fromMe: fromMe).setFill()
            NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill()
            if let m = tileMonth {
                m.draw(at: CGPoint(x: r.midX - m.size.width / 2, y: r.minY + 7))
            }
            if let d = tileDay {
                d.draw(at: CGPoint(x: r.midX - d.size.width / 2, y: r.minY + 20))
            }
        }
        for row in options {
            let c = row.circle.offsetBy(dx: o.x, dy: o.y)
            if row.picked {
                accent.setFill()
                NSBezierPath(ovalIn: c).fill()
                let check = MessageLayout.symbol("checkmark", size: 10, palette: [.white])
                let s = check.size()
                // The symbol's attachment sits 2pt low; nudge it back to centre.
                check.draw(at: CGPoint(x: c.midX - s.width / 2, y: c.midY - s.height / 2 + 2))
            } else {
                soft.withAlphaComponent(0.7).setStroke()
                let ring = NSBezierPath(ovalIn: c.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                ring.stroke()
            }
            let bar = row.bar.offsetBy(dx: o.x, dy: o.y)
            (fromMe ? Theme.faintOut.withAlphaComponent(0.35) : NSColor.quaternaryLabelColor).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
            if row.fraction > 0 {
                let fill = CGRect(x: bar.minX, y: bar.minY, width: max(4, bar.width * row.fraction), height: bar.height)
                accent.setFill()
                NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
            }
            // Up to three voters' faces beside the count.
            var ax = o.x + row.countOrigin.x - 8 - 16
            for v in row.voters.reversed() {
                drawAvatar(jid: v.voter, name: v.name, in: CGRect(x: ax, y: o.y + row.circle.minY + 1, width: 18, height: 18),
                           onImageLoad: onImageLoad)
                ax -= 11
            }
        }
        // Stacked faces: the first person on top.
        for a in avatars.reversed() {
            drawAvatar(jid: a.jid, name: a.name, in: a.rect.offsetBy(dx: o.x, dy: o.y), onImageLoad: onImageLoad)
        }
        for l in lines {
            l.block.draw(at: CGPoint(x: o.x + l.origin.x, y: o.y + l.origin.y))
        }
        rule.setFill()
        for y in dividers {
            NSRect(x: o.x - 12, y: o.y + y, width: size.width + 24, height: 0.5).fill()
        }
        let sep = buttons.count > 1
        for (i, b) in buttons.enumerated() {
            let r = b.rect.offsetBy(dx: o.x, dy: o.y)
            if sep && i > 0 {
                rule.setFill()
                NSRect(x: r.minX, y: r.minY + 7, width: 0.5, height: r.height - 14).fill()
            }
            let color: NSColor = b.hit == nil ? soft : (b.selected ? .white : accent)
            if b.selected {
                let pill = r.insetBy(dx: 5, dy: 5)
                accent.setFill()
                NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            }
            let t = NSAttributedString(string: b.title, attributes: [.font: NSFont.systemFont(ofSize: 13.5, weight: .medium),
                                                                      .foregroundColor: color])
            let s = t.size()
            t.draw(at: CGPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2))
        }
    }

    private func drawAvatar(jid: String, name: String, in r: CGRect, onImageLoad: @escaping () -> Void) {
        let px = Int(r.width * 2)
        var img: NSImage?
        if !jid.isEmpty, let p = Avatars.shared.path(for: jid) {
            img = ImageCache.shared.cached(p, px: px)
            if img == nil { ImageCache.shared.load(p, px: px) { i in if i != nil { onImageLoad() } } }
        }
        let face = img ?? Avatars.shared.monogram(name: name, jid: jid.isEmpty ? name : jid, isGroup: false)
        NSGraphicsContext.saveGraphicsState()
        let ring = NSBezierPath(ovalIn: r.insetBy(dx: -1.5, dy: -1.5))
        (fromMe ? Theme.bubbleOut : (Theme.frostsOverWallpaper ? NSColor.clear : Theme.bubbleIn)).setFill()
        ring.fill()
        NSBezierPath(ovalIn: r).addClip()
        let s = face.size
        let scale = max(r.width / max(s.width, 1), r.height / max(s.height, 1))
        face.draw(in: CGRect(x: r.midX - s.width * scale / 2, y: r.midY - s.height * scale / 2, width: s.width * scale, height: s.height * scale),
                  from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
    }
}
