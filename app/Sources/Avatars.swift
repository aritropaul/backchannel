import AppKit

/// Profile pictures for any JID (chats and group senders), with Apple
/// Contacts-style monograms while a photo is unknown or absent.
final class Avatars {
    static let shared = Avatars()
    var store: Store?
    private var requested = Set<String>()
    private var monograms: [String: NSImage] = [:]

    /// Photo path for a JID if we have one; asks the core to fetch it otherwise.
    func path(for jid: String) -> String? {
        guard let store else { return nil }
        let p = store.avatar(jid)
        if p.isEmpty, !requested.contains(jid) {
            requested.insert(jid)
            Core.shared.call("avatar", ["chat": jid])
        }
        return (p.isEmpty || p == "-") ? nil : p
    }

    /// Forget negative lookups so a newly arrived picture gets picked up.
    func refresh() { requested.removeAll() }

    func monogram(name: String, jid: String, isGroup: Bool) -> NSImage {
        let key = (isGroup ? "g:" : "p:") + Self.initials(name)
        if let m = monograms[key] { return m }
        let initials = Self.initials(name)
        let img = NSImage(size: NSSize(width: 64, height: 64), flipped: true) { rect in
            MainActor.assumeIsolated { Self.drawMonogram(in: rect, initials: initials, isGroup: isGroup) }
            return true
        }
        monograms[key] = img
        return img
    }

    /// First letters of the first and last words; empty if the name has no letters
    /// (e.g. a bare phone number), which falls back to the silhouette.
    static func initials(_ name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .filter { $0.first?.isLetter == true }
        guard let first = words.first?.first else { return "" }
        if words.count > 1, let last = words.last?.first { return String(first).uppercased() + String(last).uppercased() }
        return String(first).uppercased()
    }

    /// Contacts' grey gradient disc with white rounded initials, or a full-bleed silhouette.
    static func drawMonogram(in rect: NSRect, initials: String, isGroup: Bool) {
        let circle = NSBezierPath(ovalIn: rect)
        NSGraphicsContext.saveGraphicsState()
        circle.addClip()
        let g = NSGradient(starting: NSColor(hex: 0xA5ABB8), ending: NSColor(hex: 0x858994))
        g?.draw(in: rect, angle: 90)
        if !initials.isEmpty && !isGroup {
            let size = rect.height * (initials.count > 1 ? 0.40 : 0.46)
            var font = NSFont.systemFont(ofSize: size, weight: .semibold)
            if let d = font.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { font = f }
            let s = NSAttributedString(string: initials, attributes: [.font: font, .foregroundColor: NSColor.white])
            let sz = s.size()
            s.draw(at: CGPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
        } else {
            // Head-and-shoulders filling the lower disc, clipped by the circle (Contacts style).
            NSColor.white.withAlphaComponent(0.92).setFill()
            if isGroup, let img = NSImage(systemSymbolName: "person.2.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: rect.height * 0.34, weight: .medium).applying(.init(paletteColors: [.white]))) {
                let s = img.size
                img.draw(in: CGRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height),
                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                figure(in: rect, centerX: rect.midX, scale: 1)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func figure(in r: NSRect, centerX: CGFloat, scale: CGFloat) {
        let w = r.width * scale
        let head = w * 0.36
        NSBezierPath(ovalIn: CGRect(x: centerX - head / 2, y: r.minY + r.height * 0.22 + (1 - scale) * r.height * 0.18,
                                    width: head, height: head)).fill()
        let bodyW = w * 0.72
        let bodyTop = r.minY + r.height * 0.64 + (1 - scale) * r.height * 0.12
        NSBezierPath(ovalIn: CGRect(x: centerX - bodyW / 2, y: bodyTop, width: bodyW, height: r.height * 0.7)).fill()
    }
}
