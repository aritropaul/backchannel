import AppKit

/// A laid-out paragraph: measured once, drawn many times, hit-testable for links.
/// TextKit 1 keeps measurement and drawing on the same glyphs, so bubbles fit exactly.
final class TextBlock {
    let storage: NSTextStorage
    private let layoutManager = NSLayoutManager()
    private let container: NSTextContainer
    let size: CGSize
    /// Width of the last line, for tucking the timestamp in beside it.
    let lastLineWidth: CGFloat

    init(_ text: NSAttributedString, maxWidth: CGFloat, maxLines: Int = 0) {
        storage = NSTextStorage(attributedString: text)
        container = NSTextContainer(size: CGSize(width: max(1, maxWidth), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        if maxLines > 0 {
            container.maximumNumberOfLines = maxLines
            container.lineBreakMode = .byTruncatingTail
        }
        layoutManager.usesFontLeading = true
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        size = CGSize(width: ceil(used.width), height: ceil(used.height))
        let glyphs = layoutManager.numberOfGlyphs
        if glyphs > 0 {
            let last = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphs - 1, effectiveRange: nil)
            lastLineWidth = ceil(last.maxX)
        } else {
            lastLineWidth = 0
        }
    }

    func draw(at p: CGPoint) {
        let range = layoutManager.glyphRange(for: container)
        layoutManager.drawBackground(forGlyphRange: range, at: p)
        layoutManager.drawGlyphs(forGlyphRange: range, at: p)
    }

    func link(at p: CGPoint) -> URL? {
        guard storage.length > 0 else { return nil }
        let idx = layoutManager.characterIndex(for: p, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        guard idx < storage.length else { return nil }
        let g = layoutManager.glyphIndexForCharacter(at: idx)
        let r = layoutManager.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: container)
        guard r.insetBy(dx: -3, dy: -3).contains(p) else { return nil }
        let v = storage.attribute(.waLink, at: idx, effectiveRange: nil) ?? storage.attribute(.link, at: idx, effectiveRange: nil)
        return (v as? URL) ?? (v as? String).flatMap(URL.init(string:))
    }
}
