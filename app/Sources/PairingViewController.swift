import AppKit
import CoreImage

/// First run: link this Mac as a companion device by QR (or phone-number code).
final class PairingViewController: NSViewController {
    private let qrView = NSImageView()
    private let qrCard = NSView()
    private let status = NSTextField(labelWithString: "Generating code…")
    private let reloadButton = NSButton(title: "Reload QR Code", target: nil, action: nil)
    private let phoneToggle = NSButton(title: "Link with phone number instead", target: nil, action: nil)
    private let phoneField = NSTextField()
    private let phoneButton = NSButton(title: "Get Code", target: nil, action: nil)
    private let codeLabel = NSTextField(labelWithString: "")
    private let phoneStack = NSStackView()
    private static let ci = CIContext(options: [.useSoftwareRenderer: false])

    override func loadView() {
        let v = NSView()
        view = v

        let title = NSTextField(labelWithString: "Use WhatsApp on this Mac")
        title.font = .systemFont(ofSize: 26, weight: .semibold)

        let steps = NSTextField(wrappingLabelWithString: """
            1.  Open WhatsApp on your phone
            2.  Tap Settings (iPhone) or ⋮ Menu (Android)
            3.  Tap Linked devices, then Link a device
            4.  Point your phone at this screen
            """)
        steps.font = .systemFont(ofSize: 14)
        steps.textColor = .secondaryLabelColor
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 7
        steps.attributedStringValue = NSAttributedString(string: steps.stringValue, attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para])

        qrCard.wantsLayer = true
        qrCard.layer?.backgroundColor = NSColor.white.cgColor
        qrCard.layer?.cornerRadius = 16
        qrCard.translatesAutoresizingMaskIntoConstraints = false
        qrView.imageScaling = .scaleProportionallyUpOrDown
        qrView.translatesAutoresizingMaskIntoConstraints = false
        qrView.setAccessibilityLabel("Pairing QR code")
        qrCard.addSubview(qrView)

        status.font = .systemFont(ofSize: 12.5)
        status.textColor = .secondaryLabelColor

        reloadButton.target = self
        reloadButton.action = #selector(reload)
        reloadButton.bezelStyle = .glass
        reloadButton.isHidden = true

        phoneToggle.isBordered = false
        phoneToggle.contentTintColor = Theme.accent
        phoneToggle.target = self
        phoneToggle.action = #selector(togglePhone)

        phoneField.placeholderString = "Phone number with country code, e.g. +1 555 123 4567"
        phoneField.font = .systemFont(ofSize: 14)
        phoneField.widthAnchor.constraint(equalToConstant: 320).isActive = true
        phoneButton.target = self
        phoneButton.action = #selector(requestCode)
        phoneButton.bezelStyle = .glass
        codeLabel.font = .monospacedSystemFont(ofSize: 28, weight: .semibold)
        codeLabel.isSelectable = true
        phoneStack.orientation = .vertical
        phoneStack.spacing = 10
        let row = NSStackView(views: [phoneField, phoneButton])
        row.spacing = 8
        phoneStack.addArrangedSubview(row)
        phoneStack.addArrangedSubview(codeLabel)
        phoneStack.isHidden = true

        let left = NSStackView(views: [title, steps, phoneToggle, phoneStack])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 18
        left.setCustomSpacing(26, after: steps)

        let right = NSStackView(views: [qrCard, status, reloadButton])
        right.orientation = .vertical
        right.spacing = 12

        let main = NSStackView(views: [left, right])
        main.orientation = .horizontal
        main.alignment = .centerY
        main.spacing = 56
        main.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(main)

        NSLayoutConstraint.activate([
            main.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            main.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            main.leadingAnchor.constraint(greaterThanOrEqualTo: v.leadingAnchor, constant: 40),
            qrCard.widthAnchor.constraint(equalToConstant: 280),
            qrCard.heightAnchor.constraint(equalToConstant: 280),
            qrView.leadingAnchor.constraint(equalTo: qrCard.leadingAnchor, constant: 16),
            qrView.trailingAnchor.constraint(equalTo: qrCard.trailingAnchor, constant: -16),
            qrView.topAnchor.constraint(equalTo: qrCard.topAnchor, constant: 16),
            qrView.bottomAnchor.constraint(equalTo: qrCard.bottomAnchor, constant: -16),
        ])
    }

    func show(qr code: String) {
        qrView.image = Self.qrImage(code)
        qrView.alphaValue = 1
        status.stringValue = "Keep this window open while your phone links."
        reloadButton.isHidden = true
    }

    func show(state: String, message: String?) {
        switch state {
        case "qr_timeout":
            qrView.alphaValue = 0.15
            status.stringValue = "The code expired."
            reloadButton.isHidden = false
        case "pair_error":
            status.stringValue = message.map { "Couldn't link: \($0)" } ?? "Couldn't link."
            reloadButton.isHidden = false
        case "offline":
            status.stringValue = "Can't reach WhatsApp. Check your connection."
            reloadButton.isHidden = false
        case "syncing":
            status.stringValue = "Linked. Loading your chats…"
        default: break
        }
    }

    @objc private func reload() {
        status.stringValue = "Generating code…"
        reloadButton.isHidden = true
        Core.shared.call("repair")
    }

    @objc private func togglePhone() {
        phoneStack.isHidden.toggle()
        if !phoneStack.isHidden { view.window?.makeFirstResponder(phoneField) }
    }

    @objc private func requestCode() {
        let res = Core.shared.call("pair_phone", ["phone": phoneField.stringValue])
        if let code = res["code"] as? String {
            codeLabel.stringValue = code
            status.stringValue = "On your phone, choose “Link with phone number instead” and enter this code."
        } else {
            codeLabel.stringValue = ""
            status.stringValue = (res["error"] as? String).map { "Couldn't get a code: \($0)" } ?? "Couldn't get a code."
        }
    }

    static func qrImage(_ s: String) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(s.utf8), forKey: "inputMessage")
        f.setValue("L", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = ci.createCGImage(out, from: out.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
