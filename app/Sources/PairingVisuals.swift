import AppKit
import CoreImage

/// The QR screen's tint over the frosted desktop: translucent ink with slow-drifting pools
/// of celadon light and a fine grain, like the app icon's glass. Everything moves in the render server (Core Animation),
/// so it costs nothing on the main thread; it holds still under Reduce Motion and pauses
/// while the window is hidden.
final class AuroraView: NSView {
    private struct Pool {
        let rgb: UInt32
        let alpha: CGFloat
        let size: CGFloat        // diameter as a fraction of the longer side
        let center: CGPoint      // unit coordinates, y up
        let drift: CGVector      // unit offsets the pool wanders through
        let period: Double
    }

    private static let pools: [Pool] = [
        // Behind the code: the brightest green, so the tile sits in it.
        Pool(rgb: 0x3FAE7F, alpha: 0.78, size: 0.88, center: CGPoint(x: 0.5, y: 0.5), drift: CGVector(dx: 0.05, dy: 0.04), period: 26),
        Pool(rgb: 0x97CCB3, alpha: 0.5, size: 0.72, center: CGPoint(x: 0.12, y: 0.9), drift: CGVector(dx: 0.08, dy: -0.06), period: 34),
        Pool(rgb: 0x1F8A63, alpha: 0.66, size: 0.85, center: CGPoint(x: 0.94, y: 0.08), drift: CGVector(dx: -0.07, dy: 0.05), period: 40),
        Pool(rgb: 0xCFEEDB, alpha: 0.18, size: 0.5, center: CGPoint(x: 0.88, y: 0.9), drift: CGVector(dx: -0.05, dy: -0.04), period: 30),
    ]

    /// Pools rest below full strength so the success beat has somewhere to go.
    private static let rest: CGFloat = 0.72

    /// False for a pane whose size changes every frame: re-laying out would restart the drift.
    var drifts = true

    private let base = CAGradientLayer()
    private var poolLayers: [CAGradientLayer] = []
    private let vignette = CAGradientLayer()
    private let grain = CALayer()
    private var animatedSize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        let root = layer!

        // Translucent: the frosted desktop shows through, tinted ink.
        base.colors = [NSColor(hex: 0x0B2219, alpha: 0.46).cgColor, NSColor(hex: 0x071510, alpha: 0.6).cgColor]
        base.startPoint = CGPoint(x: 0.5, y: 1)
        base.endPoint = CGPoint(x: 0.5, y: 0)
        root.addSublayer(base)

        for p in Self.pools {
            let l = CAGradientLayer()
            l.type = .radial
            l.startPoint = CGPoint(x: 0.5, y: 0.5)
            l.endPoint = CGPoint(x: 1, y: 1)
            // A soft, roughly Gaussian falloff; a two-stop radial reads as a disc.
            let c = NSColor(hex: p.rgb)
            l.colors = [1, 0.74, 0.44, 0.2, 0.06, 0].map { c.withAlphaComponent(min(1, p.alpha / Self.rest) * $0).cgColor }
            l.locations = [0, 0.18, 0.4, 0.62, 0.82, 1]
            l.opacity = Float(Self.rest)
            root.addSublayer(l)
            poolLayers.append(l)
        }

        vignette.type = .radial
        vignette.startPoint = CGPoint(x: 0.5, y: 0.5)
        vignette.endPoint = CGPoint(x: 1.15, y: 1.15)
        vignette.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor(hex: 0x050B08, alpha: 0.45).cgColor]
        vignette.locations = [0, 0.55, 1]
        root.addSublayer(vignette)

        grain.backgroundColor = NSColor(patternImage: Self.noise).cgColor
        grain.opacity = 1
        root.addSublayer(grain)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        base.frame = b
        vignette.frame = b
        grain.frame = b
        let long = max(b.width, b.height)
        for (p, l) in zip(Self.pools, poolLayers) {
            let d = long * p.size
            l.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            l.position = CGPoint(x: b.width * p.center.x, y: b.height * p.center.y)
        }
        CATransaction.commit()
        if abs(b.width - animatedSize.width) > 40 || abs(b.height - animatedSize.height) > 40 { startDrift() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let w = window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: w)
        startDrift()
    }

    @objc private func occlusionChanged() {
        guard let root = layer, let w = window else { return }
        let visible = w.occlusionState.contains(.visible)
        if visible, root.speed == 0 {
            let paused = root.timeOffset
            root.speed = 1
            root.timeOffset = 0
            root.beginTime = 0
            root.beginTime = root.convertTime(CACurrentMediaTime(), from: nil) - paused
        } else if !visible, root.speed != 0 {
            let now = root.convertTime(CACurrentMediaTime(), from: nil)
            root.speed = 0
            root.timeOffset = now
        }
    }

    /// Each pool wanders a slow figure-eight and breathes a little.
    private func startDrift() {
        animatedSize = bounds.size
        let long = max(bounds.width, bounds.height)
        for (i, (p, l)) in zip(Self.pools, poolLayers).enumerated() {
            l.removeAllAnimations()
            guard drifts, !Theme.reduceMotion, long > 0 else { continue }
            let dx = p.drift.dx * long, dy = p.drift.dy * long
            let move = CAKeyframeAnimation(keyPath: "transform")
            move.values = [(0, 0, 1), (dx, dy * 0.4, 1.04), (dx * 0.2, dy, 0.97), (-dx * 0.6, dy * 0.3, 1.02), (0, 0, 1)].map {
                NSValue(caTransform3D: CATransform3DScale(CATransform3DMakeTranslation($0.0, $0.1, 0), $0.2, $0.2, 1))
            }
            move.calculationMode = .cubic
            move.duration = p.period
            move.repeatCount = .infinity
            move.timeOffset = Double(i) * 7
            move.isRemovedOnCompletion = false
            l.add(move, forKey: "drift")
        }
    }

    /// The light comes up from the middle, where the card will land: the centre pool opens
    /// out from a small bright core while the others fade in, then everything drifts.
    func bloom() {
        guard let root = layer else { return }
        if Theme.reduceMotion {
            Motion.fade(root, duration: 0.2)
            return
        }
        let now = CACurrentMediaTime()
        for (i, l) in poolLayers.enumerated() {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = Self.rest
            fade.duration = i == 0 ? 0.5 : 1.2
            fade.beginTime = now + (i == 0 ? 0 : 0.25)
            fade.fillMode = .backwards
            fade.timingFunction = Theme.easeOut
            l.add(fade, forKey: "bloomFade")
        }
        // The centre pool's own drift owns "transform", so it opens up on its scale alone.
        let open = CABasicAnimation(keyPath: "transform.scale")
        open.fromValue = 0.18
        open.toValue = 1
        open.duration = 1.3
        open.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        open.isAdditive = false
        poolLayers.first?.add(open, forKey: "bloomOpen")
    }

    /// Lifts the light for a moment: the success beat.
    func brighten() {
        guard !Theme.reduceMotion else { return }
        for l in poolLayers {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = Self.rest
            a.toValue = 1
            a.duration = 0.6
            a.autoreverses = true
            a.timingFunction = Theme.easeOut
            l.add(a, forKey: "brighten")
        }
    }

    /// 2x luminance noise, tiled. It also dithers the gradients so they don't band.
    private static let noise: NSImage = {
        let px = 256
        var bytes = [UInt8](repeating: 0, count: px * px * 4)
        var seed: UInt32 = 0x9E3779B9
        for i in 0..<(px * px) {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            let v = UInt8(truncatingIfNeeded: seed)
            let light = v & 1 == 0
            let a = UInt8(Double(v >> 1) / 127 * 14)   // up to ~5.5% alpha
            let c: UInt8 = light ? 255 : 0
            bytes[i * 4] = UInt8(Int(c) * Int(a) / 255)       // premultiplied
            bytes[i * 4 + 1] = UInt8(Int(c) * Int(a) / 255)
            bytes[i * 4 + 2] = UInt8(Int(c) * Int(a) / 255)
            bytes[i * 4 + 3] = a
        }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bitmapFormat: [], bytesPerRow: px * 4, bitsPerPixel: 32)!
        bytes.withUnsafeBytes { _ = memcpy(rep.bitmapData!, $0.baseAddress!, px * px * 4) }
        rep.size = NSSize(width: px / 2, height: px / 2)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }()
}

/// The pairing QR drawn by hand: rounded, joined modules and soft finder eyes, ink on
/// porcelain. Every module keeps its full square footprint where it touches a neighbour,
/// so the code scans like a plain one; only the free corners round off.
enum PairingQR {
    struct Matrix {
        let n: Int
        let bits: [Bool]
        func dark(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < n && y < n && bits[y * n + x] }
    }

    private static let ci = CIContext(options: [.useSoftwareRenderer: false])

    static func matrix(_ s: String, level: String = "M") -> Matrix? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(s.utf8), forKey: "inputMessage")
        f.setValue(level, forKey: "inputCorrectionLevel")
        guard let out = f.outputImage, let cg = ci.createCGImage(out, from: out.extent) else { return nil }
        // Core Image adds a one-module margin on every side.
        let full = cg.width, n = full - 2
        guard n > 20, let data = cg.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return nil }
        let bpr = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
        var bits = [Bool](repeating: false, count: n * n)
        for y in 0..<n {
            for x in 0..<n {
                bits[y * n + x] = p[(y + 1) * bpr + (x + 1) * bpp] < 128
            }
        }
        return Matrix(n: n, bits: bits)
    }

    /// Vector image, crisp at any backing scale. y runs down, like the matrix. With a
    /// `mark`, the code uses level Q (25% recoverable) and the mark covers about 4% of it,
    /// the way WhatsApp's and Signal's own codes carry their logos.
    static func image(_ s: String, side: CGFloat, ink: NSColor, mark: NSImage? = nil) -> NSImage? {
        guard let m = matrix(s, level: mark == nil ? "M" : "Q") else { return nil }
        let u = side / CGFloat(m.n)
        // An odd number of modules, so the hole sits on the grid around the centre module.
        var k = Int((CGFloat(m.n) * 0.2).rounded())
        if k % 2 == 0 { k += 1 }
        let lo = (m.n - k) / 2
        let hole = mark == nil ? nil : (lo..<(lo + k))
        return NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(ink.cgColor)
            ctx.addPath(path(m, side: side, hole: hole))
            ctx.fillPath(using: .evenOdd)
            if let mark, hole != nil {
                // macOS icons carry a margin round the squircle (about 10% a side); overdraw it.
                let r = CGRect(x: CGFloat(lo) * u, y: CGFloat(lo) * u, width: CGFloat(k) * u, height: CGFloat(k) * u)
                    .insetBy(dx: u * 0.35, dy: u * 0.35)
                mark.draw(in: r.insetBy(dx: -r.width * 0.115, dy: -r.height * 0.115))
            }
            return true
        }
    }

    static func path(_ m: Matrix, side: CGFloat, hole: Range<Int>? = nil) -> CGPath {
        let u = side / CGFloat(m.n)
        let p = CGMutablePath()
        func inFinder(_ x: Int, _ y: Int) -> Bool {
            (x < 7 && y < 7) || (x >= m.n - 7 && y < 7) || (x < 7 && y >= m.n - 7)
        }
        func cleared(_ x: Int, _ y: Int) -> Bool { hole.map { $0.contains(x) && $0.contains(y) } ?? false }
        func on(_ x: Int, _ y: Int) -> Bool { m.dark(x, y) && !cleared(x, y) }
        let r = u * 0.5
        for y in 0..<m.n {
            for x in 0..<m.n where m.dark(x, y) && !inFinder(x, y) && !cleared(x, y) {
                let l = on(x - 1, y), rt = on(x + 1, y), t = on(x, y - 1), b = on(x, y + 1)
                let rect = CGRect(x: CGFloat(x) * u, y: CGFloat(y) * u, width: u, height: u)
                // Round a corner only where both of its sides are open.
                let tl = !l && !t ? r : 0, tr = !rt && !t ? r : 0
                let br = !rt && !b ? r : 0, bl = !l && !b ? r : 0
                p.addPath(roundedRect(rect, tl: tl, tr: tr, br: br, bl: bl))
            }
        }
        for (fx, fy) in [(0, 0), (m.n - 7, 0), (0, m.n - 7)] {
            let o = CGRect(x: CGFloat(fx) * u, y: CGFloat(fy) * u, width: 7 * u, height: 7 * u)
            p.addPath(CGPath(roundedRect: o, cornerWidth: u * 2.3, cornerHeight: u * 2.3, transform: nil))
            p.addPath(CGPath(roundedRect: o.insetBy(dx: u, dy: u), cornerWidth: u * 1.5, cornerHeight: u * 1.5, transform: nil))
            p.addPath(CGPath(roundedRect: o.insetBy(dx: 2 * u, dy: 2 * u), cornerWidth: u * 1.05, cornerHeight: u * 1.05, transform: nil))
        }
        return p
    }

    private static func roundedRect(_ r: CGRect, tl: CGFloat, tr: CGFloat, br: CGFloat, bl: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX + tl, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY))
        if tr > 0 { p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + tr), radius: tr) }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br))
        if br > 0 { p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - br, y: r.maxY), radius: br) }
        p.addLine(to: CGPoint(x: r.minX + bl, y: r.maxY))
        if bl > 0 { p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - bl), radius: bl) }
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + tl))
        if tl > 0 { p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + tl, y: r.minY), radius: tl) }
        p.closeSubpath()
        return p
    }
}

/// The QR screen's opening, after Arc's and Dia's first launch, taken slowly: it plays once,
/// on first run, so it can afford to. The whole screen frosts over in the same drifting green
/// light as the window; a soft green sun rises from below the screen and breathes; the mark
/// comes into focus in it, holds, and dissolves back into the light; then the screen's frost
/// dissolves while a window-shaped pane condenses into place, and the real window takes over
/// underneath. About 7.5s. Skipped under Reduce Motion.
final class PairingIntro: NSObject {
    private let overlay: NSWindow
    private let target: NSRect        // the window's frame, in the overlay's coordinates
    private let frost = NSVisualEffectView()     // the whole screen, frosted; dissolves during the flow
    private let field = NSView()                 // its green light
    private let light = AuroraView()             // the window's own tint, full screen
    private let paneFrost = NSVisualEffectView() // the window-shaped frost that condenses into place
    private let pane = NSView()                  // its light, clipped to the same rounded shape
    private let paneLight = AuroraView()
    private let dawnHost = NSView()   // hosts for hand-made layers, so AppKit never reorders them
    private let orbHost = NSView()
    private let dawn = CAGradientLayer()
    private let orb = CAGradientLayer()
    private let mark = NSStackView()

    /// Gentle in-out for things that materialise; expo-out for arrivals.
    private static let materialize = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.2, 1)
    private static let arrive = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)

    init(target windowFrame: NSRect, screen: NSScreen?) {
        let s = screen?.frame ?? NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        target = windowFrame.offsetBy(dx: -s.minX, dy: -s.minY)
        overlay = NSWindow(contentRect: s, styleMask: [.borderless], backing: .buffered, defer: false)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.level = .floating
        overlay.ignoresMouseEvents = true
        overlay.isReleasedWhenClosed = false
        overlay.animationBehavior = .none
        overlay.appearance = NSAppearance(named: .darkAqua)
        overlay.setFrame(s, display: false)
        super.init()

        let root = NSView(frame: NSRect(origin: .zero, size: s.size))
        root.wantsLayer = true
        overlay.contentView = root
        let b = root.bounds

        frost.frame = b
        frost.material = .fullScreenUI
        frost.blendingMode = .behindWindow
        frost.state = .active
        root.addSubview(frost)
        field.frame = b
        field.wantsLayer = true
        light.frame = b
        field.addSubview(light)
        // Dawn: green glowing up from the bottom edge while the sun is low.
        dawnHost.frame = b
        dawnHost.wantsLayer = true
        dawn.frame = b
        dawn.colors = [NSColor(hex: 0x3FAE7F, alpha: 0.55).cgColor, NSColor(hex: 0x1F7A53, alpha: 0.28).cgColor,
                       NSColor(hex: 0x0B2219, alpha: 0).cgColor]
        dawn.locations = [0, 0.22, 0.6]
        dawn.startPoint = CGPoint(x: 0.5, y: 0)
        dawn.endPoint = CGPoint(x: 0.5, y: 1)
        dawn.opacity = 0
        dawnHost.layer?.addSublayer(dawn)
        field.addSubview(dawnHost)
        root.addSubview(field)

        // The pane: hidden until the flow. Behind-window blur is drawn by the window server and
        // ignores layer masks, so it's shaped by its frame and a stretchable rounded mask image.
        paneFrost.material = .fullScreenUI
        paneFrost.blendingMode = .behindWindow
        paneFrost.state = .active
        paneFrost.maskImage = Self.roundedMask(Self.radius)
        paneFrost.alphaValue = 0
        root.addSubview(paneFrost)
        pane.wantsLayer = true
        pane.layer?.cornerRadius = Self.radius
        pane.layer?.cornerCurve = .continuous
        pane.layer?.masksToBounds = true
        pane.alphaValue = 0
        paneLight.drifts = false
        paneLight.autoresizingMask = [.width, .height]
        pane.addSubview(paneLight)
        root.addSubview(pane)

        // The sun: a soft green glow with a pale core.
        orbHost.frame = b
        orbHost.wantsLayer = true
        let d = min(b.width, b.height) * 0.9
        orb.type = .radial
        orb.startPoint = CGPoint(x: 0.5, y: 0.5)
        orb.endPoint = CGPoint(x: 1, y: 1)
        orb.colors = [NSColor(hex: 0x8FDDB3, alpha: 0.72), NSColor(hex: 0x5CC08C, alpha: 0.56), NSColor(hex: 0x2E9466, alpha: 0.36),
                      NSColor(hex: 0x1B6A48, alpha: 0.14), NSColor(hex: 0x1B6A48, alpha: 0)].map(\.cgColor)
        orb.locations = [0, 0.12, 0.32, 0.6, 1]
        orb.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        orb.position = CGPoint(x: b.midX, y: b.midY)
        orb.opacity = 0
        orbHost.layer?.addSublayer(orb)
        root.addSubview(orbHost)

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 112).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 112).isActive = true
        let word = NSTextField(labelWithAttributedString: Brand.wordmark(size: 40, color: PairingViewController.porcelain))
        let glow = NSShadow()
        glow.shadowColor = NSColor(hex: 0x04100A, alpha: 0.6)
        glow.shadowBlurRadius = 20
        word.shadow = glow
        mark.setViews([icon, word], in: .center)
        mark.orientation = .vertical
        mark.spacing = 14
        // Generous padding: a blurred layer is clipped to its own bounds, and a tight box
        // shows as a hard-edged rectangle while the mark blurs in and out.
        mark.edgeInsets = NSEdgeInsets(top: 60, left: 80, bottom: 60, right: 80)
        mark.wantsLayer = true
        mark.layerUsesCoreImageFilters = true
        mark.frame.size = mark.fittingSize
        mark.frame.origin = CGPoint(x: b.midX - mark.frame.width / 2, y: b.midY - mark.frame.height / 2 + 6)
        mark.alphaValue = 0
        root.addSubview(mark)
    }

    func play(handOff: @escaping () -> Void, done: @escaping () -> Void) {
        overlay.alphaValue = 0
        overlay.orderFrontRegardless()
        let b = overlay.contentView!.bounds
        let t0 = CACurrentMediaTime()

        // 0.0–1.6s: the frost forms over the whole screen.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 1.6
            ctx.timingFunction = Self.materialize
            overlay.animator().alphaValue = 1
        }

        // 0.5–3.4s: dawn glows up from the bottom edge as the sun rises through it.
        dawn.opacity = 1
        dawn.add(basic("opacity", from: 0, to: 1, at: t0 + 0.5, for: 1.8, Self.materialize), forKey: "dawn")
        orb.opacity = 1
        orb.add(basic("position", from: CGPoint(x: b.midX, y: -orb.bounds.height * 0.3), to: orb.position,
                      at: t0 + 0.5, for: 2.9, Self.arrive), forKey: "rise")
        orb.add(basic("transform.scale", from: 0.6, to: 1, at: t0 + 0.5, for: 2.9, Self.arrive), forKey: "open")
        orb.add(basic("opacity", from: 0, to: 1, at: t0 + 0.5, for: 1.4, Self.materialize), forKey: "lightUp")
        // Then it breathes, once in and out, slower than any loop should be.
        let breathe = basic("transform.scale", from: 1, to: 1.035, at: t0 + 3.4, for: 2.2, CAMediaTimingFunction(name: .easeInEaseOut))
        breathe.autoreverses = true
        breathe.fillMode = .removed   // no back-fill, or it would cancel the rise's opening scale
        orb.add(breathe, forKey: "breathe")

        // 2.2–3.6s: the mark comes into focus in the light, rising a little as it sharpens.
        if let l = mark.layer, let blur = CIFilter(name: "CIGaussianBlur") {
            blur.name = "focus"
            blur.setValue(0, forKey: kCIInputRadiusKey)
            l.filters = [blur]
            l.add(basic("filters.focus.inputRadius", from: 16, to: 0, at: t0 + 2.2, for: 1.4, Self.arrive), forKey: "focus")
            let size = mark.bounds.size
            var from = CATransform3DMakeTranslation(0, -14, 0)
            from = CATransform3DConcat(Motion.scale(0.97, in: size), from)
            l.add(basic("transform", from: from, to: CATransform3DIdentity, at: t0 + 2.2, for: 1.4, Self.arrive), forKey: "settle")
        }
        after(2.2) {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 1.2
                ctx.timingFunction = Self.arrive
                self.mark.animator().alphaValue = 1
            }
        }

        // 5.0–5.8s: it holds, then dissolves back into the light.
        after(5.0) {
            if let l = self.mark.layer {
                l.add(self.basic("filters.focus.inputRadius", from: 0, to: 10, at: CACurrentMediaTime(), for: 0.8, Self.materialize),
                      forKey: "unfocus")
                l.add(self.basic("transform", from: CATransform3DIdentity, to: Motion.scale(1.03, in: self.mark.bounds.size),
                                 at: CACurrentMediaTime(), for: 0.8, Self.materialize), forKey: "lift")
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.8
                ctx.timingFunction = Self.materialize
                self.mark.animator().alphaValue = 0
            }
        }

        // 5.3–6.8s: the blur flows into the window, the way Dia's window forms: the full-screen
        // frost dissolves while a window-shaped pane condenses from 12% larger into place, and
        // the sun settles behind where the code will sit. No hard edge sweeps across the screen.
        // One display-linked clock drives all of it, so nothing drifts apart.
        after(5.3) {
            self.dawn.opacity = 0
            self.dawn.add(self.basic("opacity", from: 1, to: 0, at: CACurrentMediaTime(), for: 1.2, Self.materialize), forKey: "dusk")
            let grow: CGFloat = 1.12
            self.flowFrom = NSRect(x: self.target.midX - self.target.width * grow / 2, y: self.target.midY - self.target.height * grow / 2,
                                   width: self.target.width * grow, height: self.target.height * grow)
            self.orbFrom = self.orb.presentation()?.position ?? self.orb.position
            self.flowStart = CACurrentMediaTime()
            self.onFlowEnd = { [weak self] in self?.handOver(handOff, done) }
            let link = self.overlay.contentView!.displayLink(target: self, selector: #selector(self.tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    // MARK: Flow

    private static let radius: CGFloat = 16
    private static let flowDuration: Double = 1.5
    private static let flowEase = CubicBezier(0.16, 1, 0.3, 1)    // expo-out: the pane arrives and settles
    private static let fadeEase = CubicBezier(0.45, 0, 0.2, 1)    // gentle in-out for the dissolve
    private var link: CADisplayLink?
    private var flowStart: CFTimeInterval = 0
    private var flowFrom: NSRect = .zero
    private var orbFrom: CGPoint = .zero
    private var onFlowEnd: (() -> Void)?

    @objc private func tick(_ link: CADisplayLink) {
        let raw = min(1, (CACurrentMediaTime() - flowStart) / Self.flowDuration)
        let e = CGFloat(Self.flowEase.value(at: raw))          // the pane settling
        let fade = CGFloat(Self.fadeEase.value(at: raw))       // the screen's frost letting go
        let appear = fade   // the pane takes over exactly as the screen's frost lets go, so no box pops in
        func mix(_ a: CGFloat, _ b: CGFloat, _ k: CGFloat) -> CGFloat { a + (b - a) * k }
        let r = NSRect(x: mix(flowFrom.minX, target.minX, e), y: mix(flowFrom.minY, target.minY, e),
                       width: mix(flowFrom.width, target.width, e), height: mix(flowFrom.height, target.height, e))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        paneFrost.frame = r
        pane.frame = r
        paneLight.frame = pane.bounds
        paneFrost.alphaValue = appear
        pane.alphaValue = appear
        frost.alphaValue = 1 - fade
        field.alphaValue = 1 - fade
        orb.position = CGPoint(x: mix(orbFrom.x, target.midX, e), y: mix(orbFrom.y, target.midY, e))
        orb.opacity = Float(mix(1, 0.4, fade))
        CATransaction.commit()
        // Hand over while the last of the frost is still dissolving, so the code arrives
        // without a pause on an empty pane.
        if raw >= 0.75, let end = onFlowEnd {
            onFlowEnd = nil
            end()
        }
        guard raw >= 1 else { return }
        link.invalidate()
        self.link = nil
    }

    /// The real window appears exactly under the pane. A beat later, once it has drawn, the
    /// pane's frost goes (the window has the same frost, so nothing changes), and the light
    /// fades off it. Fading the overlay's blur over the window would blur the code as it arrives.
    private func handOver(_ handOff: () -> Void, _ done: @escaping () -> Void) {
        handOff()
        overlay.orderFrontRegardless()
        after(0.06) {
            self.paneFrost.isHidden = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.7
                ctx.timingFunction = Self.materialize
                self.overlay.animator().alphaValue = 0
            }, completionHandler: {
                self.overlay.orderOut(nil)
                done()
            })
        }
    }

    private static func roundedMask(_ r: CGFloat) -> NSImage {
        let side = r * 2 + 1
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }

    private func basic(_ keyPath: String, from: Any, to: Any, at begin: CFTimeInterval, for duration: Double,
                       _ curve: CAMediaTimingFunction) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from
        a.toValue = to
        a.beginTime = begin
        a.duration = duration
        a.timingFunction = curve
        a.fillMode = .backwards
        return a
    }

    private func after(_ t: Double, _ f: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f)
    }
}

/// Evaluates a CSS-style cubic-bezier timing curve, for motion driven frame by frame.
struct CubicBezier {
    let x1, y1, x2, y2: Double
    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) { (self.x1, self.y1, self.x2, self.y2) = (x1, y1, x2, y2) }

    func value(at x: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        var t = x
        for _ in 0..<8 {   // Newton's method on x(t) = x
            let dx = sample(t, x1, x2) - x
            if abs(dx) < 1e-6 { return sample(t, y1, y2) }
            let d = slope(t, x1, x2)
            if abs(d) < 1e-6 { break }
            t -= dx / d
        }
        var lo = 0.0, hi = 1.0   // bisection fallback
        t = x
        for _ in 0..<40 {
            let v = sample(t, x1, x2)
            if abs(v - x) < 1e-6 { break }
            if v < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return sample(t, y1, y2)
    }

    private func sample(_ t: Double, _ a: Double, _ b: Double) -> Double { ((1 - 3 * b + 3 * a) * t + (3 * b - 6 * a)) * t * t + 3 * a * t }
    private func slope(_ t: Double, _ a: Double, _ b: Double) -> Double { 3 * (1 - 3 * b + 3 * a) * t * t + 2 * (3 * b - 6 * a) * t + 3 * a }
}
