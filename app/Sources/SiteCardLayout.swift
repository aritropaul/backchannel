import AppKit

/// A link to a site we know, drawn as that site's own message: the post (or title) as the
/// message's words, then a row with its picture, who it's from and the site's address, the
/// whole bubble in the site's colours. Each site's words, picture and colours are in
/// SiteDesigns.swift.
final class SiteCardLayout {
    let card: SiteCard
    var size = CGSize.zero
    /// The bubble's colour, or the stops of a gradient run from its top-left corner.
    var fill: [NSColor] = [.darkGray]
    var border: NSColor?
    /// The text colour; the elevation leans away from it.
    var ink: NSColor = .white
    private(set) var ops: [Op] = []
    /// The picture across the top, edge to edge.
    private var hero: CGRect?

    enum Op {
        case text(TextBlock, CGPoint)
        /// A downloaded picture (the dark-mode one when there is one), cropped to fill.
        case picture(String?, dark: String?, CGRect, radius: CGFloat)
        /// One of the bundled SVGs (SiteArt), drawn as it is.
        case art(String, CGRect, radius: CGFloat)
        /// A video's play button over its frame; YouTube's own red one on YouTube.
        case play(CGRect, youtube: Bool)
        /// A video's length on a dark pill.
        case duration(TextBlock, CGRect)
        case fill(CGRect, NSColor)
        /// An app icon standing on its own colour, with an app icon's shadow.
        case icon(String?, CGRect, radius: CGFloat)
    }

    private static let padH: CGFloat = 12
    private static let padTop: CGFloat = 9
    private static let padBottom: CGFloat = 11
    private static let thumb: CGFloat = 32
    /// The even inset around a compact message's row.
    private static let padRow: CGFloat = 10

    init(card: SiteCard, maxWidth: CGFloat) {
        self.card = card
        let look = Self.look(card.site)
        fill = look.fill
        border = look.border
        ink = look.ink
        let m = Self.message(card)
        var w = min(maxWidth, 320)
        var inner = w - 2 * Self.padH
        // With nothing above it, the row is the whole message: a picture, the name and the link.
        let compact = m.words.isEmpty && m.media == nil
        var y = compact ? Self.padRow : Self.padTop
        var width: CGFloat = 0

        // The photo or video frame across the top, edge to edge, at its own shape: wide ones up to
        // 2:1 across the bubble, tall ones up to 9:16, narrowing the bubble rather than cropping.
        if case .picture(let file, let dark)? = m.media {
            let a = min(2, max(9 / 16, m.aspect))
            if a < 0.8 { w = (w * 1.25 * a).rounded() }
            inner = w - 2 * Self.padH
            let frame = CGRect(x: 0, y: 0, width: w, height: (w / a).rounded())
            hero = frame
            if m.icon {
                // An app icon isn't a photo: it stands, masked, on the colour around its edge.
                ops.append(.fill(frame, m.backdrop.map { NSColor(hex: $0) } ?? NSColor(white: 0, alpha: 0.15)))
                let s = (frame.height * 0.6).rounded()
                ops.append(.icon(file, CGRect(x: frame.midX - s / 2, y: frame.midY - s / 2, width: s, height: s), radius: (s * 0.225).rounded()))
            } else {
                ops.append(.picture(file, dark: dark, frame, radius: 0))
            }
            if m.video {
                let youtube = card.site == "youtube"
                let s = youtube ? CGSize(width: 54, height: 38) : CGSize(width: 44, height: 44)
                ops.append(.play(CGRect(x: frame.midX - s.width / 2, y: frame.midY - s.height / 2, width: s.width, height: s.height), youtube: youtube))
            }
            if let d = m.duration {
                let t = TextBlock(Self.string(d, .monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .white, line: 14), maxWidth: w, maxLines: 1)
                let pill = CGRect(x: frame.maxX - 8 - t.size.width - 10, y: frame.maxY - 8 - 18, width: t.size.width + 10, height: 18)
                ops.append(.duration(t, pill))
            }
            y += frame.height
            width = inner
        }

        if !m.words.isEmpty {
            let t = TextBlock(Self.string(m.words, Theme.body, look.ink, line: 19), maxWidth: inner, maxLines: m.lines)
            ops.append(.text(t, CGPoint(x: Self.padH, y: y)))
            y += t.size.height + 10
            width = max(width, t.size.width)
        }

        // The row: a picture, then the thing's name, who it's from, and the site's address.
        // A compact message is two lines, its name and its link.
        let side: CGFloat = m.thumb == nil ? 0 : Self.thumb
        let tx = side > 0 ? side + 10 : 0
        let tw = inner - tx
        var lines: [TextBlock] = []
        if let title = m.title {
            lines.append(TextBlock(Self.string(title, .systemFont(ofSize: 14, weight: .semibold), look.ink, line: 18), maxWidth: tw, maxLines: compact ? 1 : m.titleLines))
            if !compact, let from = m.from, !from.isEmpty {
                lines.append(TextBlock(Self.string(from, .systemFont(ofSize: 12), look.ink, line: 16), maxWidth: tw, maxLines: m.fromLines))
            }
        } else if let from = m.from, !from.isEmpty {
            lines.append(TextBlock(Self.string(from, .systemFont(ofSize: 12, weight: .semibold), look.ink, line: 16), maxWidth: tw, maxLines: 2))
        }
        lines.append(TextBlock(Self.string(m.site, .systemFont(ofSize: 12), look.muted, line: 16), maxWidth: tw, maxLines: 1))
        let block = lines.reduce(0) { $0 + $1.size.height }
        let row = max(side, block)
        // Beside a much taller block the picture sits at the top, as it does in a list.
        let r = CGRect(x: Self.padH, y: block > side + 8 ? y : y + (row - side) / 2, width: side, height: side)
        let radius = (side * 0.16).rounded()
        switch m.thumb {
        case .picture(let file, let dark)?: ops.append(.picture(file, dark: dark, r, radius: radius))
        case .art(let name)?: ops.append(.art(name, r, radius: radius))
        case nil: break
        }
        var ty = y + (row - block) / 2
        for line in lines {
            ops.append(.text(line, CGPoint(x: Self.padH + tx, y: ty)))
            ty += line.size.height
            width = max(width, tx + line.size.width)
        }
        y += row + (compact ? Self.padRow : Self.padBottom)
        size = CGSize(width: ceil(width + 2 * Self.padH), height: ceil(y))
    }

    // MARK: drawing

    /// Draws the bubble filling `path` (the message bubble's own shape, tail and all), its
    /// contents placed from `r`'s corner.
    func draw(in r: CGRect, path: NSBezierPath, highlight: Bool, onImageLoad: @escaping () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if fill.count > 1, let g = NSGradient(colors: fill) {
            g.draw(in: path.bounds, angle: 45)
        } else {
            fill.first?.setFill()
            path.fill()
        }
        // Lit from above, only ever away from the text so it never costs contrast: under dark
        // text the top lightens, under light text the bottom deepens.
        let darkInk = (ink.usingColorSpace(.sRGB)?.brightnessComponent ?? 1) < 0.5
        (darkInk ? Self.lift : Self.shade)?.draw(in: path.bounds, angle: 90)
        let o = r.origin
        for op in ops {
            switch op {
            case .text(let t, let p):
                t.draw(at: CGPoint(x: o.x + p.x, y: o.y + p.y))
            case .picture(let file, let dark, let rect, let rad):
                let isDark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                drawPicture(isDark ? (dark ?? file) : file, in: rect.offsetBy(dx: o.x, dy: o.y), radius: rad, onImageLoad: onImageLoad)
            case .art(let name, let rect, let rad):
                let a = rect.offsetBy(dx: o.x, dy: o.y)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: a, xRadius: rad, yRadius: rad).addClip()
                SiteArt.image(name)?.draw(in: a, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            case .play(let rect, let youtube):
                let p = rect.offsetBy(dx: o.x, dy: o.y)
                if youtube {
                    SiteArt.image("yt-play")?.draw(in: p, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                } else {
                    NSColor.black.withAlphaComponent(0.45).setFill()
                    NSBezierPath(ovalIn: p).fill()
                    // Nudged toward its point so it sits optically centred.
                    let t = p.insetBy(dx: p.width * 0.34, dy: p.height * 0.3).offsetBy(dx: p.width * 0.04, dy: 0)
                    let tri = NSBezierPath()
                    tri.move(to: CGPoint(x: t.minX, y: t.minY))
                    tri.line(to: CGPoint(x: t.maxX, y: t.midY))
                    tri.line(to: CGPoint(x: t.minX, y: t.maxY))
                    tri.close()
                    NSColor.white.setFill()
                    tri.fill()
                }
            case .fill(let rect, let color):
                color.setFill()
                rect.offsetBy(dx: o.x, dy: o.y).fill()
            case .icon(let file, let rect, let rad):
                let a = rect.offsetBy(dx: o.x, dy: o.y)
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
                shadow.shadowBlurRadius = 14
                shadow.shadowOffset = NSSize(width: 0, height: -5)
                shadow.set()
                NSColor.white.setFill()
                NSBezierPath(roundedRect: a, xRadius: rad, yRadius: rad).fill()
                NSGraphicsContext.restoreGraphicsState()
                drawPicture(file, in: a, radius: rad, onImageLoad: onImageLoad)
            case .duration(let t, let rect):
                let p = rect.offsetBy(dx: o.x, dy: o.y)
                NSColor.black.withAlphaComponent(0.6).setFill()
                NSBezierPath(roundedRect: p, xRadius: 4, yRadius: 4).fill()
                t.draw(at: CGPoint(x: p.midX - t.size.width / 2, y: p.midY - t.size.height / 2))
            }
        }
        // The photo's edge in pure black or white at 10%, so a white photo keeps the bubble's
        // shape on a white chat (and a black one on a black chat).
        if let frame = hero {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: frame.offsetBy(dx: o.x, dy: o.y)).addClip()
            let isDark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            NSColor(white: isDark ? 1 : 0, alpha: 0.1).setStroke()
            path.lineWidth = 2
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
        if let border {
            // Inside the edge only: the clip keeps the outer half of a 2pt stroke off.
            border.setStroke()
            path.lineWidth = 2
            path.stroke()
        }
        if highlight {
            NSColor.black.withAlphaComponent(0.08).setFill()
            path.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// White 14% at the top fading out by the bottom.
    private static let lift = NSGradient(starting: NSColor(white: 1, alpha: 0.14), ending: NSColor(white: 1, alpha: 0))
    /// Clear at the top deepening to black 14% at the bottom.
    private static let shade = NSGradient(starting: NSColor(white: 0, alpha: 0), ending: NSColor(white: 0, alpha: 0.14))

    private func drawPicture(_ file: String?, in r: CGRect, radius: CGFloat, onImageLoad: @escaping () -> Void) {
        let shape = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        var img: NSImage?
        if let path = Sites.path(file) {
            let px = Int(max(r.width, r.height) * 2)
            img = ImageCache.shared.cached(path, px: px)
            if img == nil { ImageCache.shared.load(path, px: px) { i in if i != nil { onImageLoad() } } }
        }
        guard let img else {
            NSColor(white: 0.5, alpha: 0.25).setFill()
            shape.fill()
            return
        }
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let s = img.size
        let scale = max(r.width / max(s.width, 1), r.height / max(s.height, 1))
        let dw = s.width * scale, dh = s.height * scale
        img.draw(in: CGRect(x: r.midX - dw / 2, y: r.midY - dh / 2, width: dw, height: dh), from: .zero,
                 operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func string(_ s: String, _ font: NSFont, _ color: NSColor, line: CGFloat) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.minimumLineHeight = line
        para.maximumLineHeight = line
        return NSAttributedString(string: s, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: para,
            // TextKit sets glyphs on the line's floor; lift them by half the leading.
            .baselineOffset: max(0, (line - (font.ascender - font.descender)) / 2),
        ])
    }
}

/// The bundled SVGs (app/SiteArt) the site messages and map pins draw.
enum SiteArt {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String) -> NSImage? {
        if let i = cache[name] { return i }
        guard let u = Bundle.main.url(forResource: name, withExtension: "svg"), let i = NSImage(contentsOf: u) else { return nil }
        cache[name] = i
        return i
    }
}
