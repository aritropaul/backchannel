import AppKit
import Synchronization

/// A chat's own look: wallpaper and bubble colour. Like WhatsApp's chat themes it
/// stays on this device and never syncs: the other person doesn't see it.
nonisolated struct ChatTheme: Equatable, Sendable {
    /// "default" (Settings › Chats wallpaper), an id from `Wallpaper.all` (solid),
    /// an id from `GradientWallpaper.all`, or "photo".
    var wallpaper = "default"
    /// File name of a photo in `ChatThemes.photoDir`, for `wallpaper == "photo"`.
    var photo = ""
    /// How far a photo is washed toward the canvas so text over it stays readable.
    var dim = 0.3
    /// An `AccentChoice` id for my bubbles, or "" for the app's accent.
    var bubble = ""

    var isDefault: Bool { self == ChatTheme() }
    /// Gradients and photos are pictures: text drawn straight on the canvas gets a chip.
    var isPicture: Bool { wallpaper == "photo" || GradientWallpaper.find(wallpaper) != nil }

    init() {}
    init(wallpaper: String, photo: String = "", dim: Double = 0.3, bubble: String) {
        self.wallpaper = wallpaper
        self.photo = photo
        self.dim = dim
        self.bubble = bubble
    }

    fileprivate init(_ d: [String: String]) {
        wallpaper = d["wallpaper"] ?? "default"
        photo = d["photo"] ?? ""
        dim = d["dim"].flatMap(Double.init) ?? 0.3
        bubble = d["bubble"] ?? ""
    }

    fileprivate var dict: [String: String] {
        ["wallpaper": wallpaper, "photo": photo, "dim": String(dim), "bubble": bubble]
    }
}

/// The open conversation's theme, readable from the dynamic colours (which AppKit may
/// resolve off the main thread), plus per-chat storage in UserDefaults.
enum ChatThemes {
    private nonisolated struct Active: Sendable {
        var theme = ChatTheme()
        /// Average colour of a picture wallpaper (light, dark), for the header fade and rings.
        var average: (light: NSColor, dark: NSColor)?
    }
    nonisolated private static let active = Mutex(Active())
    private static let key = "WA.chatThemes"
    private(set) static var activeJID: String?

    nonisolated static var current: ChatTheme { active.withLock { $0.theme } }

    static func theme(for jid: String) -> ChatTheme {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
        return all[jid].map(ChatTheme.init) ?? ChatTheme()
    }

    static func set(_ t: ChatTheme, for jid: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
        all[jid] = t.isDefault ? nil : t.dict
        UserDefaults.standard.set(all, forKey: key)
        if jid == activeJID { activate(jid) } else { NotificationCenter.default.post(name: Theme.didChange, object: nil) }
    }

    /// The conversation pane calls this whenever it opens a chat.
    static func activate(_ jid: String?) {
        activeJID = jid
        let t = jid.map(theme(for:)) ?? ChatTheme()
        var avg: (NSColor, NSColor)?
        if t.isPicture, let l = Wallpapers.image(for: t, dark: false), let d = Wallpapers.image(for: t, dark: true) {
            avg = (Wallpapers.average(l, wash: t, dark: false), Wallpapers.average(d, wash: t, dark: true))
        }
        let changed = active.withLock { a -> Bool in
            let was = a.theme
            a = Active(theme: t, average: avg)
            return was != t
        }
        if changed { NotificationCenter.default.post(name: Theme.didChange, object: nil) }
    }

    /// Dev hook: shows a theme on the open chat without saving it.
    static func preview(_ t: ChatTheme) {
        var avg: (NSColor, NSColor)?
        if t.isPicture, let l = Wallpapers.image(for: t, dark: false), let d = Wallpapers.image(for: t, dark: true) {
            avg = (Wallpapers.average(l, wash: t, dark: false), Wallpapers.average(d, wash: t, dark: true))
        }
        active.withLock { $0 = Active(theme: t, average: avg) }
        NotificationCenter.default.post(name: Theme.didChange, object: nil)
    }

    /// The canvas colour under a theme: a solid's own tone, a picture's average, or nil (global).
    nonisolated static func canvas(dark: Bool) -> NSColor? {
        active.withLock { a in
            if let avg = a.average { return dark ? avg.dark : avg.light }
            if let w = Wallpaper.all.first(where: { $0.id == a.theme.wallpaper }) {
                return w.id == "none" ? nil : NSColor(hex: dark ? w.dark : w.light)
            }
            return nil
        }
    }

    /// The accent my bubbles derive from in the open chat, or nil for the app's accent.
    nonisolated static func bubbleAccent() -> NSColor? {
        let id = current.bubble
        guard !id.isEmpty, let c = Theme.AccentChoice(rawValue: id) else { return nil }
        return c.color.usingColorSpace(.sRGB)
    }

    static var photoDir: URL {
        let d = Core.shared.dataDir.appendingPathComponent("wallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Copies a picked or generated image in (downscaled to 2560px JPEG) and returns its file name.
    static func importPhoto(_ url: URL) -> String? {
        guard let img = NSImage(contentsOf: url), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, 2560 / CGFloat(max(cg.width, cg.height)))
        let w = Int(CGFloat(cg.width) * scale), h = Int(CGFloat(cg.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: out)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88]) else { return nil }
        let name = UUID().uuidString + ".jpg"
        do { try data.write(to: photoDir.appendingPathComponent(name)) } catch { return nil }
        return name
    }
}

/// Soft multi-blob gradients drawn on the device: WhatsApp's own wallpapers are its
/// artwork, so these are ours. Each pairs with a bubble colour, like WhatsApp's themes.
nonisolated struct GradientWallpaper: Sendable {
    let id: String
    let title: String
    /// Hues in degrees for the blobs; the base takes the first.
    let hues: [Double]
    let chroma: Double
    let bubble: Theme.AccentChoice

    nonisolated static let all: [GradientWallpaper] = [
        .init(id: "lagoon", title: "Lagoon", hues: [215, 190, 245, 170], chroma: 0.09, bubble: .blue),
        .init(id: "orchid", title: "Orchid", hues: [305, 330, 280, 350], chroma: 0.10, bubble: .purple),
        .init(id: "ember", title: "Ember", hues: [45, 20, 70, 0], chroma: 0.11, bubble: .orange),
        .init(id: "blossom", title: "Blossom", hues: [355, 15, 330, 40], chroma: 0.09, bubble: .pink),
        .init(id: "meadow", title: "Meadow", hues: [150, 120, 175, 95], chroma: 0.09, bubble: .whatsapp),
        .init(id: "dusk", title: "Dusk", hues: [270, 30, 300, 230], chroma: 0.10, bubble: .blue),
        .init(id: "sunlit", title: "Sunlit", hues: [85, 60, 105, 40], chroma: 0.10, bubble: .yellow),
        .init(id: "graphite", title: "Graphite", hues: [250, 230, 270, 210], chroma: 0.015, bubble: .graphite),
    ]

    nonisolated static func find(_ id: String) -> GradientWallpaper? { all.first { $0.id == id } }

    /// Renders the gradient at `size` pixels: a base tone with four large soft blobs.
    nonisolated func render(dark: Bool, size: CGSize = CGSize(width: 1400, height: 1400)) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        func color(_ hue: Double, l: Double, c: Double, a: CGFloat = 1) -> CGColor {
            OKLCH.color(l: l, c: c, h: hue * .pi / 180).withAlphaComponent(a).cgColor
        }
        let baseL = dark ? 0.24 : 0.93
        ctx.setFillColor(color(hues[0], l: baseL, c: chroma * 0.5))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let spots: [(x: CGFloat, y: CGFloat, r: CGFloat)] = [(0.15, 0.85, 0.75), (0.85, 0.75, 0.65), (0.25, 0.15, 0.7), (0.9, 0.2, 0.6)]
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        for (i, s) in spots.enumerated() where i < hues.count {
            let l = dark ? 0.30 + Double(i % 2) * 0.04 : 0.88 - Double(i % 2) * 0.03
            let inner = color(hues[i], l: l, c: chroma, a: 0.95), outer = color(hues[i], l: l, c: chroma, a: 0)
            guard let g = CGGradient(colorsSpace: space, colors: [inner, outer] as CFArray, locations: [0, 1]) else { continue }
            let center = CGPoint(x: s.x * CGFloat(w), y: s.y * CGFloat(h))
            ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center,
                                   endRadius: s.r * CGFloat(max(w, h)), options: [])
        }
        return ctx.makeImage()
    }
}

/// Wallpaper images, cached per theme and appearance.
enum Wallpapers {
    nonisolated private static let cache = Mutex([String: CGImage]())

    static func image(for t: ChatTheme, dark: Bool) -> CGImage? {
        let key = "\(t.wallpaper)/\(t.photo)/\(dark)"
        if let hit = cache.withLock({ $0[key] }) { return hit }
        var img: CGImage?
        if let g = GradientWallpaper.find(t.wallpaper) {
            img = g.render(dark: dark)
        } else if t.wallpaper == "photo", !t.photo.isEmpty,
                  let ns = NSImage(contentsOf: ChatThemes.photoDir.appendingPathComponent(t.photo)) {
            img = ns.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        if let img { cache.withLock { $0[key] = img } }
        return img
    }

    /// The colour a picture averages to after its wash, for the header fade and badge rings.
    static func average(_ img: CGImage, wash t: ChatTheme, dark: Bool) -> NSColor {
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return dark ? .black : .white
        }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let base = NSColor(srgbRed: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
        guard t.wallpaper == "photo" else { return base }
        return base.blended(withFraction: wash(t), of: dark ? .black : .white) ?? base
    }

    /// How much of the canvas colour lies over a photo.
    static func wash(_ t: ChatTheme) -> CGFloat { t.wallpaper == "photo" ? CGFloat(min(max(t.dim, 0), 0.8)) : 0 }
}
