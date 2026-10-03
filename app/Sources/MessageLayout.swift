import AppKit

/// Geometry + drawing for one message row, Messages-style. Built once per
/// (message, width, flags); the table asks it for `height` and to `draw`.
final class MessageLayout {
    enum Hit { case link(URL), media, quote, readMore, file, retry, voice, card(RichCard.Hit), none }

    struct Flags: Equatable {
        var firstInRun = true
        var lastInRun = true
        var showSender = false
        var status: String?      // only on the newest outgoing message
        var expanded = false
        var gutter = false       // incoming in a group: room for sender avatars
        var showAvatar = false   // last bubble of an incoming group run
    }

    let msg: Message
    let width: CGFloat
    let flags: Flags

    private(set) var height: CGFloat = 0
    /// Text bubble (or caption bubble) in row coordinates.
    private(set) var bubble: CGRect?
    private(set) var mediaRect: CGRect?
    /// Where the tapback badge sits, in row coordinates.
    private(set) var reactionRect: CGRect?
    private var tail = false
    private var sender: TextBlock?
    private var senderOrigin = CGPoint.zero
    private var quoteRect: CGRect?
    private var quoteName: TextBlock?
    private var quoteText: TextBlock?
    private var fileRect: CGRect?
    private var fileTitle: TextBlock?
    private var fileSub: TextBlock?
    private var text: TextBlock?
    private var textOrigin = CGPoint.zero
    private var footer: TextBlock?
    private var footerOrigin = CGPoint.zero
    private(set) var failedRect: CGRect?
    private var thumbImage: NSImage?
    private var thumbDecoded = false
    private var playRect: CGRect?
    private var waveRect: CGRect?
    private var durationRect: CGRect?
    private(set) var cardRect: CGRect?
    private var cardBanner: CGRect?
    private var cardSquare: CGRect?
    private var cardTitle: TextBlock?
    private var cardDomain: TextBlock?
    private var cardTitleOrigin = CGPoint.zero
    private var cardDomainOrigin = CGPoint.zero
    private(set) var avatarRect: CGRect?
    /// A poll, event or contact card inside the bubble.
    private(set) var rich: RichCard?
    private var richOrigin = CGPoint.zero

    /// Leading x for incoming content; groups reserve a gutter for avatars.
    private var lead: CGFloat { flags.gutter ? 50 : Self.edge }

    static let readMoreURL = URL(string: "wa-internal:readmore")!
    private static let padH: CGFloat = 12
    private static let padV: CGFloat = 7
    private static let radius: CGFloat = 17
    private static let edge: CGFloat = 20

    init(msg: Message, width: CGFloat, flags: Flags) {
        self.msg = msg
        self.width = width
        self.flags = flags
        build()
    }

    /// The topmost visual block (where tapbacks attach).
    private var topBlock: CGRect? { mediaRect ?? bubble ?? cardRect }

    /// Union of everything clickable.
    var frame: CGRect {
        var r = bubble ?? mediaRect ?? cardRect ?? .zero
        if let m = mediaRect { r = r.union(m) }
        if let c = cardRect { r = r.union(c) }
        if let t = reactionRect { r = r.union(t) }
        return r
    }

    // MARK: build

    private func build() {
        let maxBubble = min(max(width * 0.66, 200), 520, width - 80 - (flags.gutter ? 30 : 0))
        let fromMe = msg.fromMe
        var y: CGFloat = flags.firstInRun ? 10 : 2
        if msg.reactions != nil { y += Self.reactionRise }

        if flags.showSender {
            let s = TextBlock(NSAttributedString(string: msg.senderName, attributes: [.font: Theme.small, .foregroundColor: Theme.meta]),
                              maxWidth: maxBubble, maxLines: 1)
            sender = s
            senderOrigin = CGPoint(x: lead + Self.padH, y: y)
            y += s.size.height + 2
        }

        let emojiCount = msg.kind == .text && msg.quoteID.isEmpty ? WAText.emojiOnlyCount(msg.text) : 0
        let visual = msg.kind == .image || msg.kind == .video || msg.kind == .sticker || (msg.kind == .location && msg.thumb != nil)

        if msg.kind == .notice {
            // A centred system line with a lock, no bubble (security code changes).
            let a = NSMutableAttributedString()
            if let lock = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [Theme.meta]))) {
                let att = NSTextAttachment()
                att.image = lock
                a.append(NSAttributedString(attachment: att))
                a.append(NSAttributedString(string: " "))
            }
            a.append(NSAttributedString(string: msg.text, attributes: [.font: Theme.small, .foregroundColor: Theme.meta]))
            let t = TextBlock(a, maxWidth: min(width - 120, 420))
            text = t
            textOrigin = CGPoint(x: (width - t.size.width) / 2, y: y + 4)
            mediaRect = nil
            bubble = nil
            sender = nil
            y += t.size.height + 8
        } else if emojiCount > 0 {
            let size: CGFloat = [40, 34, 28][min(emojiCount, 3) - 1]
            let t = TextBlock(NSAttributedString(string: msg.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                                 attributes: [.font: NSFont.systemFont(ofSize: size)]), maxWidth: maxBubble)
            text = t
            let x = fromMe ? width - Self.edge - t.size.width : lead
            textOrigin = CGPoint(x: x, y: y)
            mediaRect = nil
            bubble = nil
            y += t.size.height
            reactionAnchor(CGRect(origin: textOrigin, size: t.size))
        } else if visual {
            let r = mediaSize(maxBubble)
            let x = fromMe ? width - Self.edge - r.width : lead
            let m = CGRect(x: x, y: y, width: r.width, height: r.height)
            mediaRect = m
            reactionAnchor(m)
            y += r.height
            let caption = msg.kind == .location ? (msg.text.isEmpty ? "Location" : msg.text) : msg.text
            if !caption.isEmpty || !msg.quoteID.isEmpty {
                y += 2
                y = buildBubble(top: y, maxBubble: maxBubble, bodyOverride: caption)
            }
        } else if msg.kind == .voice || msg.kind == .audio {
            y = buildVoice(top: y, maxBubble: maxBubble)
            if let b = bubble { reactionAnchor(b) }
        } else if msg.hasLinkPreview {
            let bare = isBareLink && msg.quoteID.isEmpty
            if !bare {
                // Text first, card underneath; only the card carries the tail.
                y = buildBubble(top: y, maxBubble: maxBubble, bodyOverride: nil)
                tail = false
                y += 2
            }
            y = buildCard(top: y, maxBubble: maxBubble)
            if let b = bubble ?? cardRect { reactionAnchor(b) }
        } else {
            y = buildBubble(top: y, maxBubble: maxBubble, bodyOverride: nil)
            if let b = bubble { reactionAnchor(b) }
        }
        if flags.showAvatar {
            let bottom = [cardRect?.maxY, bubble?.maxY, mediaRect?.maxY, text.map { textOrigin.y + $0.size.height }]
                .compactMap { $0 }.max() ?? y
            avatarRect = CGRect(x: 14, y: bottom - 28, width: 28, height: 28)
        }

        // Footer: "Edited", delivery status, or "Not Delivered".
        var parts: [String] = []
        if msg.edited && msg.kind != .revoked { parts.append("Edited") }
        let failed = fromMe && msg.status == MessageStatus.failed
        if failed { parts.append("Not Delivered") } else if let s = flags.status { parts.append(s) }
        if !parts.isEmpty {
            var attrs: [NSAttributedString.Key: Any] = [.font: Theme.small, .foregroundColor: failed ? Theme.failed : Theme.metaOnCanvas]
            if let shadow = Theme.canvasTextShadow { attrs[.shadow] = shadow }
            let f = TextBlock(NSAttributedString(string: parts.joined(separator: " · "), attributes: attrs),
                              maxWidth: 300, maxLines: 1)
            footer = f
            y += 3
            let outer = fromMe ? width - Self.edge - 4 - f.size.width : lead + 4
            footerOrigin = CGPoint(x: outer, y: y)
            y += f.size.height
        }
        if failed, let anchor = bubble ?? mediaRect {
            failedRect = CGRect(x: anchor.minX - 26, y: anchor.midY - 9, width: 18, height: 18)
        }
        height = y + (flags.lastInRun ? 2 : 0)
    }

    /// How far a reaction badge rises above its bubble (and the room kept for it).
    static let reactionRise: CGFloat = 16

    private func reactionAnchor(_ block: CGRect) {
        guard let r = msg.reactions else { return }
        let size = ReactionBadgeView.size(for: r)
        let w = size.width, h = size.height
        // Incoming: top-right corner. Outgoing: top-left corner. Sat on the corner, about half
        // on the bubble as in Messages; a 10pt overlap read as detached past the 17pt corner radius.
        let x = msg.fromMe ? block.minX - w + 18 : block.maxX - 18
        reactionRect = CGRect(x: min(max(4, x), width - w - 4), y: block.minY - Self.reactionRise, width: w, height: h)
    }

    private func mediaSize(_ maxBubble: CGFloat) -> CGSize {
        if msg.kind == .sticker {
            let w = CGFloat(msg.width > 0 ? msg.width : 140), h = CGFloat(msg.height > 0 ? msg.height : 140)
            let s = min(140 / w, 140 / h, 1.5)
            return CGSize(width: round(w * s), height: round(h * s))
        }
        let maxW = min(maxBubble, 300)
        let aspect: CGFloat = (msg.width > 0 && msg.height > 0) ? CGFloat(msg.width) / CGFloat(msg.height) : (msg.kind == .location ? 1.7 : 4 / 3)
        var w = maxW
        if aspect < 1 { w = max(160, min(maxW, 360 * aspect)) }
        let h = max(100, min(360, round(w / aspect)))
        return CGSize(width: w, height: h)
    }

    /// Builds the text bubble starting at `top`; returns the y below it.
    private func buildBubble(top: CGFloat, maxBubble: CGFloat, bodyOverride: String?) -> CGFloat {
        let fromMe = msg.fromMe
        let maxText = maxBubble - 2 * Self.padH
        var contentW: CGFloat = 0
        var y = Self.padV
        var quoteH: CGFloat = 0

        if !msg.quoteID.isEmpty {
            quoteH = buildQuote(maxWidth: maxText - 6)
            contentW = max(contentW, min(max(quoteName?.size.width ?? 0, quoteText?.size.width ?? 0) + 6, maxText))
            y += quoteH + 5
        }

        var richY: CGFloat = 0
        if bodyOverride == nil, let rc = RichCard.make(msg: msg, width: min(maxText, 264)) {
            rich = rc
            richY = y
            contentW = max(contentW, rc.size.width)
            y += rc.size.height - Self.padV + 2
        }
        let isFile = rich == nil && (msg.kind == .document || msg.kind == .contact)
        var fileY: CGFloat = 0
        if isFile && bodyOverride == nil {
            let rowW = min(maxText, 240)
            fileY = y
            buildFile(width: rowW)
            contentW = max(contentW, rowW)
            y += 44
            if !msg.text.isEmpty && msg.kind != .contact { y += 5 }
        }

        let body: NSAttributedString? = {
            if let o = bodyOverride {
                if o.isEmpty { return nil }
                return msg.kind == .location ? locationText(o) : formatted(o)
            }
            if isFile { return (msg.kind == .contact || msg.text.isEmpty) ? nil : formatted(msg.text) }
            if rich != nil { return nil }
            return bodyText()
        }()
        if let body {
            let t = TextBlock(body, maxWidth: maxText)
            text = t
            textOrigin = CGPoint(x: Self.padH, y: y)
            contentW = max(contentW, t.size.width)
            y += t.size.height
        } else if !isFile || bodyOverride != nil {
            y += 0
        }
        if isFile && bodyOverride == nil && text == nil { y -= 0 }
        y += Self.padV
        let h = max(y, 32)
        let w = ceil(contentW) + 2 * Self.padH
        let x = fromMe ? width - Self.edge - w : lead
        let b = CGRect(x: x, y: top, width: w, height: h)
        bubble = b
        tail = flags.lastInRun
        // Convert inner coordinates to row coordinates.
        textOrigin = CGPoint(x: b.minX + textOrigin.x, y: b.minY + textOrigin.y + (h - y) / 2)
        if quoteH > 0 { quoteRect = CGRect(x: b.minX + 5, y: b.minY + 5, width: w - 10, height: quoteH) }
        if fileRect != nil { fileRect = CGRect(x: b.minX + 5, y: b.minY + fileY - 2, width: w - 10, height: 46) }
        if rich != nil { richOrigin = CGPoint(x: b.minX + Self.padH, y: b.minY + richY) }
        return b.maxY
    }

    private func formatted(_ s: String) -> NSAttributedString {
        var body = s
        var truncated = false
        if !flags.expanded && body.count > 1600 {
            body = String(body.prefix(1200)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
            truncated = true
        }
        let ink = Theme.ink(fromMe: msg.fromMe)
        let a = NSMutableAttributedString(attributedString: WAText.attributed(body, color: ink, linkColor: ink))
        if msg.fromMe {
            a.enumerateAttribute(.waLink, in: NSRange(location: 0, length: a.length)) { v, r, _ in
                if v != nil { a.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r) }
            }
        }
        if truncated {
            a.append(NSAttributedString(string: " Read More", attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                                                                            .foregroundColor: ink,
                                                                            .waLink: Self.readMoreURL]))
        }
        return a
    }

    private func bodyText() -> NSAttributedString {
        let fromMe = msg.fromMe
        let soft = Theme.secondaryInk(fromMe: fromMe)
        switch msg.kind {
        case .revoked:
            let s = NSMutableAttributedString(attributedString: Self.symbol("nosign", size: 12, color: soft))
            s.append(NSAttributedString(string: fromMe ? " You deleted this message" : " This message was deleted",
                                        attributes: [.font: Theme.bodyItalic, .foregroundColor: soft]))
            return s
        case .pending:
            return NSAttributedString(string: "Waiting for this message. This may take a while.",
                                      attributes: [.font: Theme.bodyItalic, .foregroundColor: soft])
        case .unsupported:
            return NSAttributedString(string: msg.text.isEmpty ? "This message isn't supported yet." : msg.text,
                                      attributes: [.font: Theme.bodyItalic, .foregroundColor: soft])
        case .location:
            return locationText(msg.text.isEmpty ? "Location" : msg.text)
        case .poll:
            let s = NSMutableAttributedString(attributedString: Self.symbol("chart.bar.fill", size: 12, color: soft))
            s.append(NSAttributedString(string: " " + msg.text, attributes: [.font: Theme.body, .foregroundColor: Theme.ink(fromMe: fromMe)]))
            return s
        default:
            return formatted(msg.text)
        }
    }

    private func locationText(_ label: String) -> NSAttributedString {
        let s = NSMutableAttributedString(attributedString: Self.symbol("mappin.and.ellipse", size: 13, color: Theme.secondaryInk(fromMe: msg.fromMe)))
        s.append(NSAttributedString(string: " " + label, attributes: [.font: Theme.body, .foregroundColor: Theme.ink(fromMe: msg.fromMe)]))
        if let url = mapsURL {
            s.addAttributes([.waLink: url, .underlineStyle: NSUnderlineStyle.single.rawValue],
                            range: NSRange(location: 2, length: (label as NSString).length))
        }
        return s
    }

    private func buildQuote(maxWidth: CGFloat) -> CGFloat {
        let fromMe = msg.fromMe
        let name = msg.isQuoteFromMe ? "You" : (msg.quoteSenderName.isEmpty ? "Message" : msg.quoteSenderName)
        quoteName = TextBlock(NSAttributedString(string: name, attributes: [.font: Theme.quoteName, .foregroundColor: Theme.ink(fromMe: fromMe)]),
                              maxWidth: maxWidth - 12, maxLines: 1)
        var body = msg.quoteText
        if body.isEmpty { body = msg.quoteKind.label.isEmpty ? "Message" : msg.quoteKind.label }
        let s = NSMutableAttributedString()
        if let sym = msg.quoteKind.symbol, msg.quoteKind != .text {
            s.append(Self.symbol(sym, size: 11, color: Theme.secondaryInk(fromMe: fromMe)))
            s.append(NSAttributedString(string: " "))
        }
        s.append(NSAttributedString(string: body.replacingOccurrences(of: "\n", with: " "),
                                    attributes: [.font: Theme.quoteText, .foregroundColor: Theme.secondaryInk(fromMe: fromMe)]))
        quoteText = TextBlock(s, maxWidth: maxWidth - 12, maxLines: 2)
        return 6 + (quoteName?.size.height ?? 15) + 1 + (quoteText?.size.height ?? 15) + 6
    }

    private func buildFile(width: CGFloat) {
        let fromMe = msg.fromMe
        let title: String
        var sub: String
        switch msg.kind {
        case .document:
            title = msg.fileName.isEmpty ? "Document" : msg.fileName
            let ext = (msg.fileName as NSString).pathExtension.uppercased()
            sub = [ext.isEmpty ? nil : ext, msg.fileSize > 0 ? Fmt.bytes(msg.fileSize) : nil].compactMap { $0 }.joined(separator: " · ")
        case .contact:
            title = msg.text.isEmpty ? "Contact" : msg.text
            sub = "Contact Card"
        default:
            title = msg.kind == .voice ? "Voice Message" : (msg.fileName.isEmpty ? "Audio" : msg.fileName)
            sub = msg.seconds > 0 ? Fmt.duration(msg.seconds) : ""
        }
        fileRect = .zero
        fileTitle = TextBlock(NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                                                              .foregroundColor: Theme.ink(fromMe: fromMe)]),
                              maxWidth: width - 44, maxLines: 1)
        fileSub = TextBlock(NSAttributedString(string: sub, attributes: [.font: Theme.small, .foregroundColor: Theme.secondaryInk(fromMe: fromMe)]),
                            maxWidth: width - 44, maxLines: 1)
    }

    var mapsURL: URL? {
        guard msg.kind == .location else { return nil }
        let p = msg.fileName.split(separator: ",")
        guard p.count == 2 else { return nil }
        return URL(string: "https://maps.apple.com/?ll=\(p[0]),\(p[1])&q=\(p[0]),\(p[1])")
    }

    static func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSAttributedString {
        symbol(name, size: size, palette: [color])
    }

    static func symbol(_ name: String, size: CGFloat, palette: [NSColor]) -> NSAttributedString {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular).applying(.init(paletteColors: palette))) else {
            return NSAttributedString()
        }
        let a = NSTextAttachment()
        a.image = img
        a.bounds = CGRect(x: 0, y: -2, width: img.size.width, height: img.size.height)
        return NSAttributedString(attachment: a)
    }

    // MARK: voice

    /// Messages-style audio bubble: play glyph, waveform bars, duration.
    private func buildVoice(top: CGFloat, maxBubble: CGFloat) -> CGFloat {
        let fromMe = msg.fromMe
        var y = Self.padV
        var quoteH: CGFloat = 0
        let w = min(maxBubble, 250)
        if !msg.quoteID.isEmpty {
            quoteH = buildQuote(maxWidth: w - 2 * Self.padH - 6)
            y += quoteH + 5
        }
        let rowH: CGFloat = 30
        let x = fromMe ? width - Self.edge - w : lead
        let h = y + rowH + Self.padV
        let b = CGRect(x: x, y: top, width: w, height: h)
        bubble = b
        tail = flags.lastInRun
        if quoteH > 0 { quoteRect = CGRect(x: b.minX + 5, y: b.minY + 5, width: w - 10, height: quoteH) }
        let rowY = b.minY + y
        playRect = CGRect(x: b.minX + 8, y: rowY, width: 30, height: rowH)
        let durW: CGFloat = 34
        waveRect = CGRect(x: playRect!.maxX + 6, y: rowY + 3, width: w - 30 - 8 - 6 - durW - 12, height: rowH - 6)
        durationRect = CGRect(x: b.maxX - Self.padH - durW, y: rowY, width: durW, height: rowH)
        return b.maxY
    }

    private var bars: [CGFloat] {
        let raw: [UInt8]
        if let w = msg.waveform, !w.isEmpty {
            raw = [UInt8](w)
        } else {
            // Stable placeholder shape when the sender didn't include a waveform.
            var h: UInt64 = 1469598103934665603
            for b in msg.id.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
            raw = (0..<64).map { i in
                h = h &* 6364136223846793005 &+ 1442695040888963407
                return UInt8(18 + Int(h >> 59) * 4 + (i % 7 == 0 ? 20 : 0))
            }
        }
        guard let wr = waveRect else { return [] }
        let n = max(8, Int(wr.width / 4.5))
        return (0..<n).map { i in
            let v = raw[min(raw.count - 1, i * raw.count / n)]
            return max(0.12, CGFloat(v) / 100)
        }
    }

    private func drawVoice() {
        guard let pr = playRect, let wr = waveRect, let dr = durationRect else { return }
        let fromMe = msg.fromMe
        let player = AudioPlayback.shared
        let playing = player.isPlaying(msg.id)
        let strong = fromMe ? Theme.inkOut : NSColor.labelColor
        let faint = fromMe ? Theme.faintOut : NSColor.tertiaryLabelColor
        let glyph: String
        if msg.mediaPath.isEmpty { glyph = "arrow.down.circle.fill" }
        else if player.isPreparing(msg.id) { glyph = "ellipsis" }
        else { glyph = playing ? "pause.fill" : "play.fill" }
        let sym = glyph.hasSuffix("circle.fill")
            ? Self.symbol(glyph, size: 20, palette: [fromMe ? Theme.bubbleOut : Theme.bubbleIn, strong])
            : Self.symbol(glyph, size: 17, color: strong)
        let ss = sym.size()
        sym.draw(at: CGPoint(x: pr.midX - ss.width / 2, y: pr.midY - ss.height / 2))

        let progress = CGFloat(player.progress(msg.id))
        let values = bars
        let step = wr.width / CGFloat(max(values.count, 1))
        let barW = max(2, step - 2)
        for (i, v) in values.enumerated() {
            let h = max(3, v * wr.height)
            let x = wr.minX + CGFloat(i) * step
            let r = CGRect(x: x, y: wr.midY - h / 2, width: barW, height: h)
            (CGFloat(i) / CGFloat(values.count) < progress ? strong : faint).setFill()
            NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2).fill()
        }
        let secs = player.elapsed(msg.id) ?? msg.seconds
        let t = NSAttributedString(string: Fmt.duration(secs), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: Theme.secondaryInk(fromMe: fromMe)])
        let ts = t.size()
        t.draw(at: CGPoint(x: dr.maxX - ts.width, y: dr.midY - ts.height / 2))
    }

    // MARK: link card

    /// True when the message is nothing but its link: show just the rich card.
    private var isBareLink: Bool {
        let t = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.contains(" ") && !t.contains("\n") && WAText.firstURL(t) != nil
    }

    private var cardURL: URL? {
        URL(string: msg.linkURL) ?? WAText.firstURL(msg.text)
    }

    /// iMessage rich link: optional banner image, then title and domain on grey.
    private func buildCard(top: CGFloat, maxBubble: CGFloat) -> CGFloat {
        let fromMe = msg.fromMe
        let w = min(maxBubble, 300)
        let x = fromMe ? width - Self.edge - w : lead
        if !thumbDecoded {
            thumbDecoded = true
            thumbImage = ImageCache.thumb(msg.thumb)
        }
        var y = top
        var banner: CGRect?
        var square: CGRect?
        if let img = thumbImage {
            let px = img.representations.first.map { CGFloat($0.pixelsWide) } ?? img.size.width
            if px >= 200 {
                let aspect = max(0.75, min(2.4, img.size.width / max(img.size.height, 1)))
                let h = min(200, max(110, round(w / aspect)))
                banner = CGRect(x: x, y: y, width: w, height: h)
                y += h
            } else {
                square = CGRect(x: x + 10, y: y + 10, width: 46, height: 46)
            }
        }
        let textX = (square != nil ? 66 : Self.padH)
        let maxText = w - textX - Self.padH
        let title = TextBlock(NSAttributedString(string: msg.linkTitle, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: Theme.inkIn]), maxWidth: maxText, maxLines: 2)
        var host = cardURL?.host() ?? msg.linkURL
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let domain = TextBlock(NSAttributedString(string: host, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: Theme.meta]), maxWidth: maxText, maxLines: 1)
        let footerH = max(square != nil ? 66 : 0, 9 + title.size.height + 2 + domain.size.height + 9)
        cardTitleOrigin = CGPoint(x: x + textX, y: y + (footerH - title.size.height - 2 - domain.size.height) / 2)
        cardDomainOrigin = CGPoint(x: x + textX, y: cardTitleOrigin.y + title.size.height + 2)
        cardTitle = title
        cardDomain = domain
        cardRect = CGRect(x: x, y: top, width: w, height: y - top + footerH)
        cardBanner = banner
        cardSquare = square
        return top + (y - top) + footerH
    }

    private func drawCard(_ r: CGRect) {
        let path = Self.bubblePath(r, fromMe: msg.fromMe, tail: flags.lastInRun)
        if !msg.fromMe && Theme.frostsOverWallpaper {
            Theme.glassTint.setFill()
            path.fill()
            Theme.glassRim.setStroke()
            path.lineWidth = 1
            path.stroke()
        } else {
            Theme.bubbleIn.setFill()
            path.fill()
        }
        if let img = thumbImage, let b = cardBanner ?? cardSquare {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            if cardSquare != nil { NSBezierPath(roundedRect: b, xRadius: 8, yRadius: 8).addClip() } else { NSBezierPath(rect: b).addClip() }
            let s = img.size
            let scale = max(b.width / max(s.width, 1), b.height / max(s.height, 1))
            let dw = s.width * scale, dh = s.height * scale
            img.draw(in: CGRect(x: b.midX - dw / 2, y: b.midY - dh / 2, width: dw, height: dh), from: .zero,
                     operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
        }
        cardTitle?.draw(at: cardTitleOrigin)
        cardDomain?.draw(at: cardDomainOrigin)
    }

    // MARK: group avatar

    private func drawAvatar(_ r: CGRect, onImageLoad: @escaping () -> Void) {
        let img: NSImage
        if let p = Avatars.shared.path(for: msg.sender) {
            if let cached = ImageCache.shared.cached(p, px: 56) {
                img = cached
            } else {
                ImageCache.shared.load(p, px: 56) { i in if i != nil { onImageLoad() } }
                img = Avatars.shared.monogram(name: msg.senderName, jid: msg.sender, isGroup: false)
            }
        } else {
            img = Avatars.shared.monogram(name: msg.senderName, jid: msg.sender, isGroup: false)
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: r).addClip()
        let s = img.size
        let scale = max(r.width / max(s.width, 1), r.height / max(s.height, 1))
        img.draw(in: CGRect(x: r.midX - s.width * scale / 2, y: r.midY - s.height * scale / 2, width: s.width * scale, height: s.height * scale),
                 from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: media

    /// Media fetched as soon as it's on screen, per Settings › Chats › Media auto-download.
    var wantsAutoDownload: Bool {
        guard msg.hasMedia, msg.mediaPath.isEmpty else { return false }
        switch msg.kind {
        case .sticker: return true   // tiny, and part of the conversation like text; WhatsApp always fetches them
        case .image: return Prefs.autoPhotos
        case .voice, .audio: return Prefs.autoAudio
        case .document: return Prefs.autoDocuments
        default: return false
        }
    }

    /// Full image if decoded, else the inline thumbnail. Kicks off decoding once.
    func image(onLoad: @escaping () -> Void) -> NSImage? {
        if !msg.mediaPath.isEmpty, msg.kind == .image || msg.kind == .sticker || msg.kind == .video, let r = mediaRect {
            let px = Int(max(r.width, r.height) * 2)
            if let img = ImageCache.shared.cached(msg.mediaPath, px: px) { return img }
            ImageCache.shared.load(msg.mediaPath, px: px) { img in if img != nil { onLoad() } }
        }
        if !thumbDecoded {
            thumbDecoded = true
            thumbImage = ImageCache.thumb(msg.thumb)
        }
        return thumbImage
    }

    // MARK: hit testing (row coordinates)

    func hit(_ p: CGPoint) -> Hit {
        if let f = failedRect, f.insetBy(dx: -4, dy: -4).contains(p) { return .retry }
        if let rc = rich, let h = rc.hit(CGPoint(x: p.x - richOrigin.x, y: p.y - richOrigin.y)) { return .card(h) }
        if let t = text {
            let tp = CGPoint(x: p.x - textOrigin.x, y: p.y - textOrigin.y)
            if let url = t.link(at: tp) { return url == Self.readMoreURL ? .readMore : .link(url) }
        }
        if let m = mediaRect, m.contains(p) { return .media }
        if let c = cardRect, c.contains(p), let u = cardURL { return .link(u) }
        if playRect != nil, let b = bubble, b.contains(p) { return .voice }
        if let f = fileRect, f.contains(p) { return .file }
        if let q = quoteRect, q.contains(p) { return .quote }
        return .none
    }

    /// A card's buttons and options, in row coordinates.
    var richClickRects: [CGRect] {
        rich?.clickableRects.map { $0.offsetBy(dx: richOrigin.x, dy: richOrigin.y) } ?? []
    }

    /// The other person's bubble and link card outlines, for the frosted glass behind them.
    var incomingShapes: [NSBezierPath] {
        guard !msg.fromMe else { return [] }
        var out: [NSBezierPath] = []
        if let b = bubble { out.append(Self.bubblePath(b, fromMe: false, tail: tail)) }
        if let c = cardRect { out.append(Self.bubblePath(c, fromMe: false, tail: flags.lastInRun)) }
        return out
    }

    func contains(_ p: CGPoint) -> Bool {
        if let b = bubble, b.contains(p) { return true }
        if let c = cardRect, c.contains(p) { return true }
        if let m = mediaRect, m.contains(p) { return true }
        if text != nil, bubble == nil, CGRect(origin: textOrigin, size: text?.size ?? .zero).contains(p) { return true }
        return false
    }

    // MARK: drawing

    func draw(highlight: Bool, onImageLoad: @escaping () -> Void) {
        let fromMe = msg.fromMe
        if let s = sender {
            Theme.drawChip(behind: CGRect(origin: senderOrigin, size: s.size))
            s.draw(at: senderOrigin)
        }

        if let m = mediaRect { drawMedia(m, onImageLoad: onImageLoad) }

        if let b = bubble {
            let path = Self.bubblePath(b, fromMe: fromMe, tail: tail)
            if !fromMe && Theme.frostsOverWallpaper {
                // The blur is a FrostView under this drawing; here its tint and edge.
                Theme.glassTint.setFill()
                path.fill()
                Theme.glassRim.setStroke()
                path.lineWidth = 1
                path.stroke()
            } else {
                (fromMe ? Theme.bubbleOut : Theme.bubbleIn).setFill()
                path.fill()
            }
            if highlight {
                NSColor.black.withAlphaComponent(fromMe ? 0.15 : 0.08).setFill()
                path.fill()
            }
        }

        if let q = quoteRect {
            let r = NSBezierPath(roundedRect: q, xRadius: 12, yRadius: 12)
            Theme.tint(fromMe: fromMe).setFill()
            r.fill()
            NSGraphicsContext.saveGraphicsState()
            r.addClip()
            (msg.isQuoteFromMe ? Theme.accent : (fromMe ? Theme.faintOut : NSColor.tertiaryLabelColor)).setFill()
            NSRect(x: q.minX, y: q.minY, width: 3, height: q.height).fill()
            NSGraphicsContext.restoreGraphicsState()
            quoteName?.draw(at: CGPoint(x: q.minX + 11, y: q.minY + 6))
            quoteText?.draw(at: CGPoint(x: q.minX + 11, y: q.minY + 7 + (quoteName?.size.height ?? 15)))
        }

        if let f = fileRect { drawFile(f) }
        if let rc = rich { rc.draw(at: richOrigin, onImageLoad: onImageLoad) }
        if playRect != nil { drawVoice() }
        if let t = text {
            if bubble == nil, msg.kind == .notice { Theme.drawChip(behind: CGRect(origin: textOrigin, size: t.size)) }
            t.draw(at: textOrigin)
        }
        if let c = cardRect { drawCard(c) }
        if let a = avatarRect { drawAvatar(a, onImageLoad: onImageLoad) }
        if let f = footer {
            f.draw(at: footerOrigin)   // plain text, coloured for the wallpaper behind it
        }
        if let fr = failedRect {
            let s = Self.symbol("exclamationmark.circle.fill", size: 16, color: Theme.failed)
            let sz = s.size()
            s.draw(at: CGPoint(x: fr.midX - sz.width / 2, y: fr.midY - sz.height / 2))
        }
    }

    /// Rounded bubble; the last bubble of a run curls into a tail at its bottom outer corner.
    static func bubblePath(_ r: CGRect, fromMe: Bool, tail: Bool) -> NSBezierPath {
        let rad = min(radius, r.height / 2)
        guard tail else { return NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad) }
        let p = NSBezierPath()
        if fromMe {
            p.move(to: CGPoint(x: r.minX + rad, y: r.minY))
            p.line(to: CGPoint(x: r.maxX - rad, y: r.minY))
            p.appendArc(from: CGPoint(x: r.maxX, y: r.minY), to: CGPoint(x: r.maxX, y: r.minY + rad), radius: rad)
            p.line(to: CGPoint(x: r.maxX, y: r.maxY - 11))
            p.curve(to: CGPoint(x: r.maxX + 5.5, y: r.maxY), controlPoint1: CGPoint(x: r.maxX, y: r.maxY - 3.5),
                    controlPoint2: CGPoint(x: r.maxX + 2.5, y: r.maxY - 0.6))
            p.curve(to: CGPoint(x: r.maxX - 9, y: r.maxY - 1.6), controlPoint1: CGPoint(x: r.maxX + 1, y: r.maxY + 0.6),
                    controlPoint2: CGPoint(x: r.maxX - 5, y: r.maxY + 0.2))
            p.curve(to: CGPoint(x: r.maxX - rad - 2, y: r.maxY), controlPoint1: CGPoint(x: r.maxX - 11, y: r.maxY - 0.6),
                    controlPoint2: CGPoint(x: r.maxX - 13, y: r.maxY))
            p.line(to: CGPoint(x: r.minX + rad, y: r.maxY))
            p.appendArc(from: CGPoint(x: r.minX, y: r.maxY), to: CGPoint(x: r.minX, y: r.maxY - rad), radius: rad)
            p.appendArc(from: CGPoint(x: r.minX, y: r.minY), to: CGPoint(x: r.minX + rad, y: r.minY), radius: rad)
        } else {
            p.move(to: CGPoint(x: r.maxX - rad, y: r.minY))
            p.line(to: CGPoint(x: r.minX + rad, y: r.minY))
            p.appendArc(from: CGPoint(x: r.minX, y: r.minY), to: CGPoint(x: r.minX, y: r.minY + rad), radius: rad)
            p.line(to: CGPoint(x: r.minX, y: r.maxY - 11))
            p.curve(to: CGPoint(x: r.minX - 5.5, y: r.maxY), controlPoint1: CGPoint(x: r.minX, y: r.maxY - 3.5),
                    controlPoint2: CGPoint(x: r.minX - 2.5, y: r.maxY - 0.6))
            p.curve(to: CGPoint(x: r.minX + 9, y: r.maxY - 1.6), controlPoint1: CGPoint(x: r.minX - 1, y: r.maxY + 0.6),
                    controlPoint2: CGPoint(x: r.minX + 5, y: r.maxY + 0.2))
            p.curve(to: CGPoint(x: r.minX + rad + 2, y: r.maxY), controlPoint1: CGPoint(x: r.minX + 11, y: r.maxY - 0.6),
                    controlPoint2: CGPoint(x: r.minX + 13, y: r.maxY))
            p.line(to: CGPoint(x: r.maxX - rad, y: r.maxY))
            p.appendArc(from: CGPoint(x: r.maxX, y: r.maxY), to: CGPoint(x: r.maxX, y: r.maxY - rad), radius: rad)
            p.appendArc(from: CGPoint(x: r.maxX, y: r.minY), to: CGPoint(x: r.maxX - rad, y: r.minY), radius: rad)
        }
        p.close()
        return p
    }

    private func drawMedia(_ m: CGRect, onImageLoad: @escaping () -> Void) {
        let sticker = msg.kind == .sticker
        let radius: CGFloat = sticker ? 0 : 16
        let clip = NSBezierPath(roundedRect: m, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        if let img = image(onLoad: onImageLoad) {
            if sticker {
                img.draw(in: m, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                         hints: [.interpolation: NSImageInterpolation.high.rawValue])
            } else {
                let s = img.size
                let scale = max(m.width / max(s.width, 1), m.height / max(s.height, 1))
                let dw = s.width * scale, dh = s.height * scale
                img.draw(in: CGRect(x: m.midX - dw / 2, y: m.midY - dh / 2, width: dw, height: dh), from: .zero,
                         operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            }
        } else if sticker {
            // Still downloading, or an animated (Lottie) sticker we can't draw: a quiet stand-in.
            let r = m.insetBy(dx: 18, dy: 18)
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: r, xRadius: 22, yRadius: 22).fill()
            let s = Self.symbol("face.smiling", size: 30, color: NSColor.tertiaryLabelColor)
            let sz = s.size()
            s.draw(at: CGPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
        } else {
            Theme.bubbleIn.setFill()
            m.fill()
            if let sym = msg.kind.symbol {
                let s = Self.symbol(sym, size: 26, color: Theme.meta)
                let sz = s.size()
                s.draw(at: CGPoint(x: m.midX - sz.width / 2, y: m.midY - sz.height / 2))
            }
        }
        if msg.kind == .video && msg.fileName == "GIF" {
            // A GIF (an mp4 WhatsApp plays silently on a loop): a "GIF" pill, not a play button.
            let t = NSAttributedString(string: "GIF", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold),
                                                                   .foregroundColor: NSColor.white])
            let ts = t.size()
            let pill = CGRect(x: m.midX - (ts.width + 20) / 2, y: m.midY - 15, width: ts.width + 20, height: 30)
            NSColor.black.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 15, yRadius: 15).fill()
            t.draw(at: CGPoint(x: pill.midX - ts.width / 2, y: pill.midY - ts.height / 2))
            // Credit for GIFs from a search service, bottom-left, as WhatsApp shows it.
            let credit = ["\"gif\":\"giphy\"": "GIPHY", "\"gif\":\"tenor\"": "Tenor", "\"gif\":\"klipy\"": "KLIPY"]
                .first { msg.extra.contains($0.key) }?.value
            if let credit {
                let c = NSAttributedString(string: credit, attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .heavy), .foregroundColor: NSColor.white.withAlphaComponent(0.85),
                    .shadow: Self.textShadow])
                c.draw(at: CGPoint(x: m.minX + 10, y: m.maxY - 22))
            }
        } else if msg.kind == .video {
            let d: CGFloat = 44
            let c = CGRect(x: m.midX - d / 2, y: m.midY - d / 2, width: d, height: d)
            NSColor.black.withAlphaComponent(0.4).setFill()
            NSBezierPath(ovalIn: c).fill()
            let play = Self.symbol("play.fill", size: 17, color: .white)
            let ps = play.size()
            play.draw(at: CGPoint(x: c.midX - ps.width / 2 + 2, y: c.midY - ps.height / 2 + 1))
            if msg.seconds > 0 {
                let s = NSAttributedString(string: Fmt.duration(msg.seconds), attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white, .shadow: Self.textShadow])
                s.draw(at: CGPoint(x: m.minX + 10, y: m.maxY - 22))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        if !sticker {
            NSColor.separatorColor.setStroke()
            clip.lineWidth = 0.5
            clip.stroke()
        }
    }

    private static let textShadow: NSShadow = {
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.6)
        s.shadowBlurRadius = 3
        s.shadowOffset = .zero
        return s
    }()

    private func drawFile(_ f: CGRect) {
        let fromMe = msg.fromMe
        let bg = NSBezierPath(roundedRect: f, xRadius: 12, yRadius: 12)
        Theme.tint(fromMe: fromMe).setFill()
        bg.fill()
        let icon: String
        switch msg.kind {
        case .document: icon = "doc.fill"
        case .contact: icon = "person.crop.circle.fill"
        default: icon = msg.mediaPath.isEmpty ? "arrow.down.circle.fill" : "play.circle.fill"
        }
        // Two-layer circle symbols need a glyph color and a disc color.
        let glyph: NSColor = .white
        let disc: NSColor = Theme.accent
        let sym = icon.hasSuffix("circle.fill") ? Self.symbol(icon, size: 22, palette: [glyph, disc])
            : Self.symbol(icon, size: 22, color: disc)
        let ss = sym.size()
        sym.draw(at: CGPoint(x: f.minX + 10, y: f.midY - ss.height / 2))
        if let t = fileTitle, let s = fileSub {
            let total = t.size.height + (s.size.height > 0 ? s.size.height + 1 : 0)
            t.draw(at: CGPoint(x: f.minX + 42, y: f.midY - total / 2))
            s.draw(at: CGPoint(x: f.minX + 42, y: f.midY - total / 2 + t.size.height + 1))
        }
    }
}
