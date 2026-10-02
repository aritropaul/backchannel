import AppKit

enum Fmt {
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return f
    }()
    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()
    private static let longDate: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMMM yyyy")
        return f
    }()
    private static let cal = Calendar.current

    static func time(_ d: Date) -> String { time.string(from: d) }

    /// Chat list rule: time today, "Yesterday", weekday within a week, else date.
    static func listStamp(_ d: Date) -> String {
        if cal.isDateInToday(d) { return time.string(from: d) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day, days < 7 {
            return weekday.string(from: d)
        }
        return shortDate.string(from: d)
    }

    /// Date separator chip in the transcript.
    static func dayChip(_ d: Date) -> String {
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day, days < 7 {
            return weekday.string(from: d)
        }
        return longDate.string(from: d)
    }

    /// Separator day label: "Today", "Yesterday", weekday this week, else a date.
    static func dayLabel(_ d: Date) -> String {
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day, days < 7 {
            return weekday.string(from: d)
        }
        return longDate.string(from: d)
    }

    static func tooltip(_ d: Date) -> String { "\(dayLabel(d)) at \(time.string(from: d))" }

    static func lastSeen(_ d: Date) -> String {
        if cal.isDateInToday(d) { return "last seen today at \(time.string(from: d))" }
        if cal.isDateInYesterday(d) { return "last seen yesterday at \(time.string(from: d))" }
        return "last seen \(shortDate.string(from: d)) at \(time.string(from: d))"
    }

    static func duration(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }

    /// Size of a file on disk, 0 when it's gone.
    static func fileSize(_ path: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// A disappearing-message timer as WhatsApp words it.
    static func timer(_ seconds: Int) -> String {
        switch seconds {
        case 0: "Off"
        case 86_400: "24 hours"
        case 604_800: "7 days"
        case 7_776_000: "90 days"
        default:
            seconds % 86_400 == 0 ? "\(seconds / 86_400) days" : seconds % 3600 == 0 ? "\(seconds / 3600) hours" : "\(seconds / 60) minutes"
        }
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func sameDay(_ a: Date, _ b: Date) -> Bool { cal.isDate(a, inSameDayAs: b) }

    /// One-line preview for the chat list ("Photo", caption, text…).
    static func preview(kind: MessageKind, text: String, fileName: String) -> String {
        let first = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        switch kind {
        case .text, .unsupported, .pending: return kind == .pending ? "Waiting for this message" : first
        case .revoked: return "This message was deleted"
        case .document: return first.isEmpty ? (fileName.isEmpty ? "Document" : fileName) : first
        case .poll: return first.isEmpty ? "Poll" : first
        case .contact: return first.isEmpty ? "Contact" : first
        default: return first.isEmpty ? kind.label : first
        }
    }
}

// MARK: - WhatsApp text formatting

extension NSAttributedString.Key {
    /// Our own link attribute. AppKit restyles `.link` in its system blue, which is
    /// unreadable on a green bubble; this one leaves color and underline to us.
    static let waLink = NSAttributedString.Key("waLink")
}

enum WAText {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Markers must hug non-space text and sit on word boundaries, as WhatsApp does.
    private static func inline(_ m: String) -> NSRegularExpression {
        let e = NSRegularExpression.escapedPattern(for: m)
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}\(e)])\(e)(?![\\s\(e)])([^\\n]*?[^\\s\(e)])\(e)(?![\\p{L}\\p{N}\(e)])")
    }
    private static let monoBlock = try? NSRegularExpression(pattern: "```([\\s\\S]+?)```")
    private static let code = inline("`")
    private static let bold = inline("*")
    private static let italic = inline("_")
    private static let strike = inline("~")

    /// First URL in a string, for link previews.
    static func firstURL(_ text: String) -> URL? {
        guard text.contains("."), let d = detector else { return nil }
        return d.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))?.url
    }

    static func attributed(_ text: String, color: NSColor, linkColor: NSColor, font: NSFont = Theme.body) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.lineSpacing = 1
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        let s = NSMutableAttributedString(string: text, attributes: base)
        guard text.count < 20_000 else { return s }

        // ```blocks``` first; their contents are literal.
        var literal: [NSRange] = []
        if let monoBlock, text.contains("```") {
            for m in monoBlock.matches(in: s.string, range: NSRange(location: 0, length: s.length)).reversed() {
                let inner = s.attributedSubstring(from: m.range(at: 1)).mutableCopy() as! NSMutableAttributedString
                inner.addAttribute(.font, value: Theme.mono, range: NSRange(location: 0, length: inner.length))
                s.replaceCharacters(in: m.range, with: inner)
            }
            // Recompute literal spans after replacement by font.
            s.enumerateAttribute(.font, in: NSRange(location: 0, length: s.length)) { v, r, _ in
                if (v as? NSFont) == Theme.mono { literal.append(r) }
            }
        }
        func outsideLiteral(_ r: NSRange) -> Bool { !literal.contains { NSIntersectionRange($0, r).length > 0 } }

        func apply(_ re: NSRegularExpression, _ marker: Character, _ style: (NSMutableAttributedString, NSRange) -> Void) {
            guard text.contains(marker) else { return }
            for m in re.matches(in: s.string, range: NSRange(location: 0, length: s.length)).reversed() where outsideLiteral(m.range) {
                let inner = s.attributedSubstring(from: m.range(at: 1)).mutableCopy() as! NSMutableAttributedString
                style(inner, NSRange(location: 0, length: inner.length))
                s.replaceCharacters(in: m.range, with: inner)
                // Shift literal ranges that sit after this edit.
                let removed = m.range.length - inner.length
                literal = literal.map { $0.location > m.range.location ? NSRange(location: $0.location - removed, length: $0.length) : $0 }
            }
        }
        apply(code, "`") { a, r in a.addAttribute(.font, value: Theme.mono, range: r) }
        apply(bold, "*") { a, r in convert(a, r, .boldFontMask) }
        apply(italic, "_") { a, r in convert(a, r, .italicFontMask) }
        apply(strike, "~") { a, r in a.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r) }

        if let detector, s.string.contains(".") {
            for m in detector.matches(in: s.string, range: NSRange(location: 0, length: s.length)) {
                guard let url = m.url else { continue }
                s.addAttributes([.waLink: url, .foregroundColor: linkColor,
                                 .underlineStyle: NSUnderlineStyle.single.rawValue], range: m.range)
            }
        }
        return s
    }

    private static func convert(_ a: NSMutableAttributedString, _ r: NSRange, _ trait: NSFontTraitMask) {
        a.enumerateAttribute(.font, in: r) { v, sub, _ in
            guard let f = v as? NSFont else { return }
            a.addAttribute(.font, value: NSFontManager.shared.convert(f, toHaveTrait: trait), range: sub)
        }
    }

    /// 1–3 emoji and nothing else renders large, without a bubble.
    static func emojiOnlyCount(_ text: String) -> Int {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 3 else { return 0 }
        for ch in t where !ch.isWhitespace {
            guard let f = ch.unicodeScalars.first, f.properties.isEmoji,
                  f.properties.isEmojiPresentation || ch.unicodeScalars.count > 1 else { return 0 }
        }
        return t.filter { !$0.isWhitespace }.count
    }
}
