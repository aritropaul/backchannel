import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// WhatsApp's "New sticker": the photo's subject lifted off its background, a white
/// outline around it, optional text, on a 512×512 transparent canvas.
final class StickerMakerViewController: FormSheetViewController, NSTextFieldDelegate {
    var onSend: ((URL) -> Void)?
    private let source: URL
    private var original: CGImage?
    private var cutout: CGImage?
    private var rendered: CGImage?
    private let preview = CheckerboardImageView()
    private let spinner = NSProgressIndicator()
    private let removeBackground = NSButton(checkboxWithTitle: "Remove background", target: nil, action: nil)
    private let outline = NSButton(checkboxWithTitle: "White outline", target: nil, action: nil)
    private var text: NSTextField!

    init(source: URL) {
        self.source = source
        super.init(title: "New Sticker", primary: "Send", width: 340)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func buildForm() {
        preview.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.translatesAutoresizingMaskIntoConstraints = false
        preview.addSubview(spinner)
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.widthAnchor.constraint(equalToConstant: 256),
            preview.heightAnchor.constraint(equalToConstant: 256),
            preview.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            preview.topAnchor.constraint(equalTo: holder.topAnchor),
            preview.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: preview.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: preview.centerYAnchor),
        ])
        addWide(holder)
        stack.setCustomSpacing(16, after: holder)
        for b in [removeBackground, outline] {
            b.state = .on
            b.target = self
            b.action = #selector(rerender)
        }
        removeBackground.isEnabled = false
        let toggles = NSStackView(views: [removeBackground, outline])
        toggles.spacing = 18
        stack.addArrangedSubview(toggles)
        text = field("Add text (optional)")
        addWide(text)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        primary.isEnabled = false
        spinner.startAnimation(nil)
        let url = source
        Task { [weak self] in
            let (img, lifted) = await Self.load(url)
            guard let self else { return }
            self.spinner.stopAnimation(nil)
            self.spinner.isHidden = true
            guard let img else { NSSound.beep(); self.dismiss(nil); return }
            self.original = img
            self.cutout = lifted
            self.removeBackground.isEnabled = lifted != nil
            if lifted == nil { self.removeBackground.state = .off }
            self.rerender()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(text)
    }

    /// The photo, and its subject cut out (nil when Vision finds none).
    @concurrent nonisolated static func load(_ url: URL) async -> (CGImage?, CGImage?) {
        guard let img = ImageCache.decode(url, px: 1024) else { return (nil, nil) }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: img, options: [:])
        guard (try? handler.perform([request])) != nil, let result = request.results?.first,
              let buffer = try? result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: true)
        else { return (img, nil) }
        let ci = CIImage(cvPixelBuffer: buffer)
        return (img, CIContext().createCGImage(ci, from: ci.extent))
    }

    func controlTextDidChange(_ obj: Notification) { rerender() }

    @objc private func rerender() {
        guard let base = removeBackground.state == .on ? (cutout ?? original) : original else { return }
        rendered = Self.render(base, outline: outline.state == .on, text: text.stringValue.trimmingCharacters(in: .whitespaces))
        preview.image = rendered.map { NSImage(cgImage: $0, size: NSSize(width: 256, height: 256)) }
        primary.isEnabled = rendered != nil
    }

    static let side: CGFloat = 512

    /// Fits the image on a 512×512 transparent canvas, outlines it, and sets the text
    /// along the bottom in white with a dark edge, as WhatsApp's sticker maker does.
    static func render(_ img: CGImage, outline: Bool, text: String) -> CGImage? {
        let pad: CGFloat = outline ? 26 : 12
        let textH: CGFloat = text.isEmpty ? 0 : 92
        let box = CGRect(x: pad, y: pad + textH * 0.55, width: side - 2 * pad, height: side - 2 * pad - textH * 0.55)
        let w = CGFloat(img.width), h = CGFloat(img.height)
        let s = min(box.width / w, box.height / h)
        let fit = CGRect(x: box.midX - w * s / 2, y: box.midY - h * s / 2, width: w * s, height: h * s)
        guard let canvas = CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        canvas.interpolationQuality = .high
        canvas.draw(img, in: fit)
        guard var out = canvas.makeImage() else { return nil }

        if outline {
            // Grow the subject's silhouette, paint it white, and put the subject back on top.
            let ci = CIImage(cgImage: out)
            let grow = CIFilter.morphologyMaximum()
            grow.inputImage = ci
            grow.radius = 11
            let white = CIFilter.colorMatrix()
            white.inputImage = grow.outputImage
            white.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            white.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            white.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            white.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            white.biasVector = CIVector(x: 1, y: 1, z: 1, w: 0)
            let over = CIFilter.sourceOverCompositing()
            over.inputImage = ci
            over.backgroundImage = white.outputImage
            if let composed = over.outputImage,
               let cg = CIContext().createCGImage(composed, from: CGRect(x: 0, y: 0, width: side, height: side)) {
                out = cg
            }
        }

        guard !text.isEmpty,
              let ctx = CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return out }
        ctx.draw(out, in: CGRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        var size: CGFloat = 64
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        func styled(_ extra: [NSAttributedString.Key: Any]) -> NSAttributedString {
            var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .heavy), .paragraphStyle: para]
            attrs.merge(extra) { $1 }
            return NSAttributedString(string: text, attributes: attrs)
        }
        while styled([:]).size().width > side - 56 && size > 22 { size -= 4 }
        // A wide dark edge first, then the white letters over it, so the edge sits outside them.
        let edge = styled([.strokeColor: NSColor.black.withAlphaComponent(0.8), .strokeWidth: 22, .foregroundColor: NSColor.clear])
        let fill = styled([.foregroundColor: NSColor.white])
        let ls = fill.boundingRect(with: NSSize(width: side - 40, height: 200), options: [.usesLineFragmentOrigin])
        let textBox = CGRect(x: 20, y: 22, width: side - 40, height: ceil(ls.height))
        edge.draw(with: textBox, options: [.usesLineFragmentOrigin])
        fill.draw(with: textBox, options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage() ?? out
    }

    override func confirm() {
        guard let rendered else { NSSound.beep(); return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sticker-\(UUID().uuidString).png")
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, rendered, nil)
        guard CGImageDestinationFinalize(d) else { NSSound.beep(); return }
        onSend?(url)
        dismiss(nil)
    }
}

/// An image over a light checkerboard, so transparency reads as transparency.
final class CheckerboardImageView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let clip = NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14)
        clip.addClip()
        let a = NSColor.labelColor.withAlphaComponent(0.05), b = NSColor.labelColor.withAlphaComponent(0.1)
        let cell: CGFloat = 16
        for row in 0..<Int(ceil(bounds.height / cell)) {
            for col in 0..<Int(ceil(bounds.width / cell)) {
                ((row + col) % 2 == 0 ? a : b).setFill()
                NSRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell).fill()
            }
        }
        image?.draw(in: bounds)
    }
}
