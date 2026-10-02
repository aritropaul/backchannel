import AppKit

/// Every emoji macOS can draw, in Unicode's order and WhatsApp's groups, with Apple's
/// English names for search (Resources/emoji.json, built from Unicode's emoji-test.txt
/// and CoreEmoji's AppleName.strings).
enum EmojiCatalog {
    struct Emoji: Hashable {
        let char: String
        let name: String
        let tones: Bool
    }

    struct Group {
        let title: String
        let symbol: String
        let emoji: [Emoji]
    }

    static let groups: [Group] = {
        guard let url = Bundle.main.url(forResource: "emoji", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let symbols = ["Smileys & People": "face.smiling", "Animals & Nature": "pawprint", "Food & Drink": "fork.knife",
                       "Activity": "soccerball", "Travel & Places": "car", "Objects": "lightbulb", "Symbols": "heart",
                       "Flags": "flag"]
        return raw.compactMap { g in
            guard let title = g["g"] as? String, let list = g["e"] as? [[Any]] else { return nil }
            let emoji = list.compactMap { e -> Emoji? in
                guard let c = e.first as? String, e.count > 1, let n = e[1] as? String else { return nil }
                return Emoji(char: c, name: n, tones: e.count > 2)
            }
            return Group(title: title, symbol: symbols[title] ?? "circle", emoji: emoji)
        }
    }()

    private static let recentKey = "WA.recentEmoji"

    static var recent: [String] { UserDefaults.standard.stringArray(forKey: recentKey) ?? [] }

    static func used(_ e: String) {
        var r = recent.filter { $0 != e }
        r.insert(e, at: 0)
        UserDefaults.standard.set(Array(r.prefix(32)), forKey: recentKey)
    }

    static func search(_ q: String) -> [Emoji] {
        let words = q.lowercased().split(separator: " ")
        guard !words.isEmpty else { return [] }
        return groups.flatMap(\.emoji).filter { e in words.allSatisfy { e.name.lowercased().contains($0) } }
    }

    /// The same emoji in each skin tone (on every person in it).
    static func toned(_ e: String) -> [String] {
        ["\u{1F3FB}", "\u{1F3FC}", "\u{1F3FD}", "\u{1F3FE}", "\u{1F3FF}"].map { tone in
            var out = String.UnicodeScalarView()
            let scalars = Array(e.unicodeScalars)
            var i = 0
            while i < scalars.count {
                let s = scalars[i]
                out.append(s)
                if s.properties.isEmojiModifierBase {
                    out.append(Unicode.Scalar(tone)!)
                    if i + 1 < scalars.count, scalars[i + 1] == "\u{FE0F}" { i += 1 }   // the tone replaces the presentation selector
                }
                i += 1
            }
            return String(out)
        }
    }
}

/// The emoji grid: one view that draws only the cells on screen, with section titles,
/// a hover highlight, click to insert and right-click for skin tones.
final class EmojiGridView: NSView {
    struct Section {
        let title: String
        let emoji: [EmojiCatalog.Emoji]
    }

    var onPick: ((String) -> Void)?
    /// The section whose title is nearest the top, as the view scrolls.
    var onSectionVisible: ((Int) -> Void)?
    private(set) var sections: [Section] = []
    private var sectionTops: [CGFloat] = []
    private var hover: (Int, Int)?
    private let columns = 9
    private let inset: CGFloat = 12   // wide glyphs (🫡) overhang their cell a little
    private let titleH: CGFloat = 26
    private var cell: CGFloat { floor((visibleWidth - 2 * inset) / CGFloat(columns)) }
    private var visibleWidth: CGFloat { enclosingScrollView?.contentView.bounds.width ?? bounds.width }
    private static let font = NSFont(name: "Apple Color Emoji", size: 24) ?? .systemFont(ofSize: 24)

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ s: [Section]) {
        sections = s
        hover = nil
        relayout()
        needsDisplay = true
    }

    /// Top of a section, for the category tabs.
    func top(of section: Int) -> CGFloat { sectionTops.indices.contains(section) ? sectionTops[section] : 0 }

    private func relayout() {
        let width = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        let c = floor((width - 2 * inset) / CGFloat(columns))
        var y: CGFloat = 4
        sectionTops = []
        for s in sections {
            sectionTops.append(y)
            y += titleH + CGFloat((s.emoji.count + columns - 1) / columns) * c + 6
        }
        let h = max(y + 8, enclosingScrollView?.contentView.bounds.height ?? 0)
        setFrameSize(NSSize(width: width, height: h))
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        relayout()
    }

    override func layout() {
        super.layout()
        if abs(frame.width - visibleWidth) > 0.5 { relayout() }
    }

    private func rect(_ section: Int, _ i: Int) -> CGRect {
        let c = cell
        let col = i % columns, row = i / columns
        return CGRect(x: inset + CGFloat(col) * c, y: sectionTops[section] + titleH + CGFloat(row) * c, width: c, height: c)
    }

    private func index(at p: CGPoint) -> (Int, Int)? {
        let c = cell
        for (s, top) in sectionTops.enumerated().reversed() where p.y >= top + titleH {
            let col = Int((p.x - inset) / c), row = Int((p.y - top - titleH) / c)
            guard col >= 0, col < columns else { return nil }
            let i = row * columns + col
            return i < sections[s].emoji.count ? (s, i) : nil
        }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                         .foregroundColor: NSColor.secondaryLabelColor]
        for (s, sec) in sections.enumerated() {
            let top = sectionTops[s]
            let bottom = s + 1 < sectionTops.count ? sectionTops[s + 1] : bounds.height
            guard bottom >= dirtyRect.minY, top <= dirtyRect.maxY else { continue }
            NSAttributedString(string: sec.title, attributes: titleAttrs).draw(at: CGPoint(x: inset + 4, y: top + 7))
            for (i, e) in sec.emoji.enumerated() {
                let r = rect(s, i)
                guard r.intersects(dirtyRect) else { continue }
                if let h = hover, h == (s, i) {
                    NSColor.labelColor.withAlphaComponent(0.08).setFill()
                    NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
                }
                let a = NSAttributedString(string: e.char, attributes: [.font: Self.font])
                let sz = a.size()
                a.draw(at: CGPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let h = index(at: convert(event.locationInWindow, from: nil))
        guard h?.0 != hover?.0 || h?.1 != hover?.1 else { return }
        if let old = hover { setNeedsDisplay(rect(old.0, old.1)) }
        hover = h
        if let h { setNeedsDisplay(rect(h.0, h.1)) }
        toolTip = h.map { sections[$0.0].emoji[$0.1].name }
    }

    override func mouseExited(with event: NSEvent) {
        if let old = hover { setNeedsDisplay(rect(old.0, old.1)) }
        hover = nil
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard let (s, i) = index(at: convert(event.locationInWindow, from: nil)) else { return }
        onPick?(sections[s].emoji[i].char)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let (s, i) = index(at: convert(event.locationInWindow, from: nil)) else { return nil }
        let e = sections[s].emoji[i]
        guard e.tones else { return nil }
        let m = NSMenu()
        for v in [e.char] + EmojiCatalog.toned(e.char) {
            m.addItem(ClosureMenuItem(title: v) { [weak self] in self?.onPick?(v) })
        }
        return m
    }

    override func resetCursorRects() { addCursorRect(visibleRect, cursor: .pointingHand) }

    /// Reports the section at the top as the user scrolls.
    func scrolled() {
        let y = visibleRect.minY + 8
        let s = sectionTops.lastIndex(where: { $0 <= y }) ?? 0
        onSectionVisible?(s)
    }
}
