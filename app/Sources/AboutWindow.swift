import AppKit

/// About Backchannel: the icon, the wordmark, what it is, the version, the
/// non-affiliation line and the acknowledgements for everything linked into the app.
final class AboutWindowController: NSWindowController {
    static let shared = AboutWindowController()

    private init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 380),
                            styleMask: [.titled, .closable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.title = "About \(Brand.name)"
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: panel)

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 112).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 112).isActive = true

        let name = NSTextField(labelWithAttributedString: Brand.wordmark(size: 30))
        let what = label(Brand.descriptor, 13, .secondaryLabelColor)

        let info = Bundle.main.infoDictionary ?? [:]
        let version = label("Version \(info["CFBundleShortVersionString"] as? String ?? "") (\(info["CFBundleVersion"] as? String ?? ""))",
                            11, .tertiaryLabelColor)
        version.isSelectable = true
        version.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)

        let disclaimer = label(Brand.disclaimer, 11, .tertiaryLabelColor)
        let thanks = NSButton(title: "Acknowledgements", target: self, action: #selector(showAcknowledgements))
        thanks.bezelStyle = .glass
        thanks.controlSize = .small

        let stack = NSStackView(views: [icon, name, what, version, disclaimer, thanks])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(14, after: icon)
        stack.setCustomSpacing(2, after: name)
        stack.setCustomSpacing(12, after: what)
        stack.setCustomSpacing(26, after: version)
        stack.setCustomSpacing(14, after: disclaimer)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 44),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 24),
            content.widthAnchor.constraint(equalToConstant: 320),
        ])
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func label(_ s: String, _ size: CGFloat, _ color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: size)
        l.textColor = color
        l.alignment = .center
        return l
    }

    func present() {
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Acknowledgements

    private lazy var acknowledgements: NSPanel = {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        p.title = "Acknowledgements"
        p.isReleasedWhenClosed = false
        p.minSize = NSSize(width: 360, height: 280)
        let scroll = NSTextView.scrollableTextView()
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.textContainerInset = NSSize(width: 18, height: 16)
        text.textStorage?.setAttributedString(Self.credits)
        p.contentView = scroll
        return p
    }()

    @objc private func showAcknowledgements() {
        if !acknowledgements.isVisible { acknowledgements.center() }
        acknowledgements.makeKeyAndOrderFront(nil)
    }

    /// Everything linked into the app, with its licence.
    private static let entries: [(String, String, String)] = [
        ("whatsmeow", "Tulir Asokan and contributors. The WhatsApp multi-device protocol.", "Mozilla Public License 2.0"),
        ("libsignal (go.mau.fi)", "The Signal protocol in Go.", "GNU General Public License v3.0"),
        ("go.mau.fi/util", "Tulir Asokan.", "Mozilla Public License 2.0"),
        ("libwebp", "Google. Sticker encoding.", "BSD 3-Clause License"),
        ("Sparkle", "Andy Matuschak and the Sparkle Project. Updates.", "MIT License"),
        ("Instrument Sans", "The Instrument Sans Project Authors. The wordmark.", "SIL Open Font License 1.1"),
        ("go-sqlite3", "Yasuhiro Matsumoto.", "MIT License"),
        ("protobuf-go", "The Go Authors.", "BSD 3-Clause License"),
        ("Go x/crypto, x/net, x/sync, x/sys, x/text, x/exp", "The Go Authors.", "BSD 3-Clause License"),
        ("edwards25519", "Filippo Valsorda and the Go Authors.", "BSD 3-Clause License"),
        ("uuid", "Google.", "BSD 3-Clause License"),
        ("zerolog", "Olivier Poitrey.", "MIT License"),
        ("websocket", "Coder.", "ISC License"),
        ("gqlparser", "Adam Scarr and contributors.", "MIT License"),
        ("argo-go", "Beeper.", "MIT License"),
        ("orderedmap", "Elliot Chance.", "MIT License"),
        ("go-colorable, go-isatty", "Yasuhiro Matsumoto.", "MIT License"),
        ("goid", "Peter Mattis.", "Apache License 2.0"),
        ("Emoji names", "From Unicode's emoji-test.txt.", "Unicode License v3"),
    ]

    private static var credits: NSAttributedString {
        let out = NSMutableAttributedString()
        func add(_ s: String, _ font: NSFont, _ color: NSColor = .labelColor, after: CGFloat = 0) {
            let para = NSMutableParagraphStyle()
            para.paragraphSpacing = after
            out.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para]))
        }
        add("\(Brand.name) is built on open-source software. Thank you.\n", .systemFont(ofSize: 13), .secondaryLabelColor, after: 14)
        for (name, who, licence) in entries {
            add(name, .systemFont(ofSize: 13, weight: .semibold))
            add("  \(licence)\n", .systemFont(ofSize: 12), .secondaryLabelColor, after: 2)
            add("\(who)\n", .systemFont(ofSize: 12), .secondaryLabelColor, after: 12)
        }
        add("\nGIF search is powered by GIPHY.\n\(Brand.disclaimer) WhatsApp is a trademark of WhatsApp LLC.\n",
            .systemFont(ofSize: 12), .tertiaryLabelColor)
        return out
    }
}
