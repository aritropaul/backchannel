import AppKit
import UserNotifications

/// Settings (⌘,): the accent color that drives the whole app, and whether macOS
/// lets WA post notifications.
final class SettingsWindowController: NSWindowController {
    private let swatches = NSStackView()
    private let accentName = NSTextField(labelWithString: "")
    private let notifyStatus = NSTextField(wrappingLabelWithString: "")
    private let notifyButton = NSButton(title: "", target: nil, action: nil)
    private let testButton = NSButton(title: "Send Test Notification", target: nil, action: nil)
    private var notifyState: UNAuthorizationStatus = .notDetermined

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 220), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Settings"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        build()
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        refreshNotifications()
    }

    private func build() {
        guard let content = window?.contentView else { return }
        swatches.orientation = .horizontal
        swatches.spacing = 10
        for choice in Theme.AccentChoice.allCases {
            let s = AccentSwatch(choice: choice)
            s.onPick = { [weak self] c in self?.pick(c) }
            swatches.addArrangedSubview(s)
        }
        accentName.font = .systemFont(ofSize: 11)
        accentName.textColor = .secondaryLabelColor
        let accentColumn = NSStackView(views: [swatches, accentName])
        accentColumn.orientation = .vertical
        accentColumn.alignment = .leading
        accentColumn.spacing = 6

        notifyStatus.font = .systemFont(ofSize: 13)
        notifyStatus.preferredMaxLayoutWidth = 300
        notifyButton.bezelStyle = .push
        notifyButton.target = self
        notifyButton.action = #selector(notifyAction)
        testButton.bezelStyle = .push
        testButton.target = self
        testButton.action = #selector(sendTest)
        let buttons = NSStackView(views: [notifyButton, testButton])
        buttons.spacing = 8
        let notifyColumn = NSStackView(views: [notifyStatus, buttons])
        notifyColumn.orientation = .vertical
        notifyColumn.alignment = .leading
        notifyColumn.spacing = 8

        let grid = NSGridView(views: [
            [label("Accent color:"), accentColumn],
            [label("Notifications:"), notifyColumn],
        ])
        grid.rowSpacing = 22
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        for r in 0..<grid.numberOfRows { grid.row(at: r).yPlacement = .top }
        grid.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -28),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -26),
        ])
        syncAccent()
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 13)
        return l
    }

    // MARK: accent

    private func pick(_ c: Theme.AccentChoice) {
        Theme.setAccent(c)
        syncAccent()
    }

    private func syncAccent() {
        let current = Theme.accentChoice
        for case let s as AccentSwatch in swatches.arrangedSubviews { s.isSelected = s.choice == current }
        accentName.stringValue = current.title
    }

    // MARK: notifications

    private func refreshNotifications() {
        Task { [weak self] in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            self?.showNotificationState(settings.authorizationStatus)
        }
    }

    private func showNotificationState(_ s: UNAuthorizationStatus) {
        notifyState = s
        switch s {
        case .authorized, .provisional, .ephemeral:
            notifyStatus.stringValue = "On. New messages show a banner unless the chat is open or muted."
            notifyButton.title = "Notification Settings…"
            testButton.isHidden = false
        case .denied:
            notifyStatus.stringValue = "Off. macOS is blocking WA's notifications."
            notifyButton.title = "Open Notification Settings…"
            testButton.isHidden = true
        default:
            notifyStatus.stringValue = "Not set up yet."
            notifyButton.title = "Allow Notifications…"
            testButton.isHidden = true
        }
    }

    @objc private func notifyAction() {
        if notifyState == .notDetermined {
            Task { [weak self] in
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                self?.refreshNotifications()
            }
        } else {
            let id = Bundle.main.bundleIdentifier ?? ""
            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func sendTest() {
        Self.postTestNotification()
    }

    static func postTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "WA"
        content.body = "Notifications are working."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "wa-test", content: content, trigger: nil))
    }
}

/// One round accent swatch, like System Settings › Appearance. "Match System"
/// is drawn as a multicolor wheel.
final class AccentSwatch: NSView {
    let choice: Theme.AccentChoice
    var onPick: ((Theme.AccentChoice) -> Void)?
    var isSelected = false { didSet { needsDisplay = true; setAccessibilitySelected(isSelected) } }

    init(choice: Theme.AccentChoice) {
        self.choice = choice
        super.init(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        toolTip = choice.title
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(choice.title)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 26, height: 26) }

    override func draw(_ dirtyRect: NSRect) {
        let dot = bounds.insetBy(dx: 4, dy: 4)
        if choice == .system {
            let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .systemPink, .systemRed]
            NSGradient(colors: colors)?.draw(in: NSBezierPath(ovalIn: dot), angle: 90)
        } else {
            choice.color.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
        NSColor.black.withAlphaComponent(0.12).setStroke()
        let rim = NSBezierPath(ovalIn: dot.insetBy(dx: 0.25, dy: 0.25))
        rim.lineWidth = 0.5
        rim.stroke()
        if isSelected {
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - 3, y: bounds.midY - 3, width: 6, height: 6)).fill()
            NSColor.secondaryLabelColor.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPick?(choice) }
    }
}
