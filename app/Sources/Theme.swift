import AppKit
import QuartzCore

/// DESIGN.md tokens: system colors first. Dynamic colors resolve at draw time.
enum Theme {
    // nonisolated: AppKit may resolve dynamic colors off the main thread.
    private nonisolated static func dyn(_ name: String, _ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: name) { @Sendable ap in
            NSColor(hex: ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        }
    }

    private nonisolated static func dynA(_ name: String, _ light: UInt32, _ la: CGFloat, _ dark: UInt32, _ da: CGFloat) -> NSColor {
        NSColor(name: name) { @Sendable ap in
            let d = ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: d ? dark : light, alpha: d ? da : la)
        }
    }

    static var canvas: NSColor { .textBackgroundColor }
    /// Outgoing bubble follows the accent color (System Settings › Appearance; "Multicolor"
    /// means the app's AccentColor, WhatsApp green). On WhatsApp green it's WhatsApp's exact
    /// pair (pale green / deep green); any other accent gets the same lightness and relative
    /// chroma at the accent's hue, so the ink colors below stay legible.
    static let bubbleOut = NSColor(name: "bubbleOut") { @Sendable ap in
        let dark = ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        var accent: NSColor?
        ap.performAsCurrentDrawingAppearance { accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) }
        return OKLCH.bubble(accent: accent, dark: dark)
    }
    /// Large selected fills (sidebar rows, pinned tiles) wear the bubble tone with bubble ink,
    /// as WhatsApp does for its selected chips; the solid accent is kept for small marks.
    static var selection: NSColor { bubbleOut }
    static var onSelection: NSColor { inkOut }
    static var onSelectionSecondary: NSColor { secondaryOut }
    static let bubbleIn = dyn("bubbleIn", 0xE9E9EB, 0x3B3B3D)
    static let inkOut = dyn("inkOut", 0x111B21, 0xE9EDEF)
    static let secondaryOut = dynA("secondaryOut", 0x111B21, 0.55, 0xE9EDEF, 0.62)
    static let tintOut = dynA("tintOut", 0x0B141A, 0.06, 0xFFFFFF, 0.10)
    static let faintOut = dynA("faintOut", 0x111B21, 0.28, 0xE9EDEF, 0.38)
    static var inkIn: NSColor { .labelColor }
    static var meta: NSColor { .secondaryLabelColor }
    /// The one app color: unread dots, send arrow, "You" quotes, selection, switches, and
    /// (via bubbleOut) my messages. The AccentColor asset makes it WhatsApp green by default.
    static var accent: NSColor { .controlAccentColor }
    static var failed: NSColor { .systemRed }

    static func ink(fromMe: Bool) -> NSColor { fromMe ? inkOut : inkIn }
    static func secondaryInk(fromMe: Bool) -> NSColor { fromMe ? secondaryOut : .secondaryLabelColor }
    static func tint(fromMe: Bool) -> NSColor { fromMe ? tintOut : NSColor.labelColor.withAlphaComponent(0.06) }

    // Type
    static let body = NSFont.systemFont(ofSize: 14)
    static let bodyItalic = NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)
    static let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let small = NSFont.systemFont(ofSize: 11)
    static let smallBold = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let quoteName = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let quoteText = NSFont.systemFont(ofSize: 12)

    // Motion
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static let easeOut = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)

    /// Apple-style spring from response/damping (the WWDC "Designing Fluid Interfaces" parameters).
    static func spring(_ keyPath: String, response: Double, damping: Double) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: keyPath)
        a.mass = 1
        let omega = 2 * Double.pi / response
        a.stiffness = omega * omega
        a.damping = 2 * damping * omega
        a.duration = a.settlingDuration
        return a
    }
}

/// Perceptual color math for deriving tints from the accent.
nonisolated enum OKLCH {
    /// WhatsApp green is one value in both modes (its brighter dark-mode variant read as neon).
    private static let whatsApp: (accent: UInt32, bubble: UInt32, darkAccent: UInt32, darkBubble: UInt32) =
        (0x1DAA61, 0xD9FDD3, 0x1DAA61, 0x144D37)

    static func bubble(accent: NSColor?, dark: Bool) -> NSColor {
        let fallback = NSColor(hex: dark ? whatsApp.darkBubble : whatsApp.bubble)
        guard let accent else { return fallback }
        if accent.matches(hex: dark ? whatsApp.darkAccent : whatsApp.accent) { return fallback }
        // WhatsApp's pair measured against its accent (#1DAA61, C 0.157): light L 0.957 at 0.43×
        // the accent's chroma, dark L 0.377 at 0.45×.
        let (_, c, h) = lch(accent)
        return color(l: dark ? 0.377 : 0.957, c: c * (dark ? 0.45 : 0.43), h: h)
    }

    static func lch(_ color: NSColor) -> (Double, Double, Double) {
        func lin(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let r = lin(color.redComponent), g = lin(color.greenComponent), b = lin(color.blueComponent)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        return (L, hypot(A, B), atan2(B, A))
    }

    /// sRGB color for L/C/hue(radians), lowering chroma until it fits the gamut.
    static func color(l: Double, c: Double, h: Double) -> NSColor {
        func rgb(_ c: Double) -> (Double, Double, Double) {
            let a = c * cos(h), b = c * sin(h)
            let l_ = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
            let m_ = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
            let s_ = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
            return (4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_,
                    -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_,
                    -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_)
        }
        func fits(_ v: (Double, Double, Double)) -> Bool { [v.0, v.1, v.2].allSatisfy { $0 >= -0.0001 && $0 <= 1.0001 } }
        var lo = 0.0, hi = c
        if !fits(rgb(hi)) {
            for _ in 0..<20 { let mid = (lo + hi) / 2; if fits(rgb(mid)) { lo = mid } else { hi = mid } }
            hi = lo
        }
        func enc(_ v: Double) -> CGFloat {
            let v = min(max(v, 0), 1)
            return CGFloat(v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055)
        }
        let v = rgb(hi)
        return NSColor(srgbRed: enc(v.0), green: enc(v.1), blue: enc(v.2), alpha: 1)
    }
}

nonisolated extension NSColor {
    func matches(hex: UInt32) -> Bool {
        let t = NSColor(hex: hex)
        return abs(redComponent - t.redComponent) < 0.02 && abs(greenComponent - t.greenComponent) < 0.02
            && abs(blueComponent - t.blueComponent) < 0.02
    }

    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
