import AppKit
import AudioToolbox
import UserNotifications

/// Notification tones: Backchannel's own (app/Sounds, synthesized by tools/sounds/tones.py)
/// and macOS's classic alert sounds. A preference holds a tone's name, "default" (the alert
/// sound chosen in System Settings) or "none".
///
/// Tones play through the system sound server rather than NSSound, so they follow the Alert
/// volume slider and the "Play sound effects through" device like every other Mac alert,
/// instead of the media volume. They aren't attached to the notification itself: macOS
/// plays its default alert in place of a custom notification sound (FB11642483).
enum Tones {
    /// Backchannel's tones, in menu order. Nudge is the default.
    static let bundled = ["Nudge", "Tine", "Chime", "Glow", "Drop", "Hush", "Tap"]
    static let standard = "Nudge"

    /// A burst (an album, a busy group) chimes once rather than once per message.
    private static let quiet: TimeInterval = 2
    private static var lastChime = Date.distantPast
    private static var ids: [String: SystemSoundID] = [:]

    static func title(_ value: String) -> String {
        switch value {
        case "default": "Alert Sound"
        case "none": "None"
        default: value
        }
    }

    /// Plays a tone straight away: the pickers' preview.
    static func preview(_ value: String) {
        switch value {
        case "none": break
        case "default": AudioServicesPlayAlertSoundWithCompletion(kSystemSoundID_UserPreferredAlert, nil)
        default: if let id = soundID(value) { AudioServicesPlaySystemSoundWithCompletion(id, nil) }
        }
    }

    /// The sound for an incoming message. Returns what the notification itself should carry:
    /// the system default, or nothing while Backchannel plays its tone alongside.
    static func chime(_ value: String) -> UNNotificationSound? {
        guard value != "none", Date().timeIntervalSince(lastChime) > quiet else { return nil }
        lastChime = Date()
        if value == "default" { return .default }
        Task {
            // System Settings › Notifications › Backchannel › "Play sound for notifications".
            let s = await UNUserNotificationCenter.current().notificationSettings()
            guard s.authorizationStatus == .authorized, s.soundSetting == .enabled else { return }
            preview(value)
        }
        return nil
    }

    /// The tone menu both pickers share: `leading` first (a chat's "Same as Settings"),
    /// then None, Backchannel's tones and macOS's.
    static func popup(selected: String, leading: [(String, String)] = []) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.autoenablesItems = false
        guard let menu = p.menu else { return p }
        func add(_ value: String, _ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = value
            menu.addItem(item)
            if value == selected { p.select(item) }
        }
        leading.forEach { add($0.0, $0.1) }
        add("none", title("none"))
        menu.addItem(.sectionHeader(title: Brand.name))
        bundled.forEach { add($0, $0) }
        menu.addItem(.sectionHeader(title: "macOS"))
        add("default", title("default"))
        Prefs.alertSounds.forEach { add($0, $0) }
        return p
    }

    private static func soundID(_ name: String) -> SystemSoundID? {
        if let id = ids[name] { return id }
        let system = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        guard let url = Bundle.main.url(forResource: name, withExtension: "aiff")
                ?? (FileManager.default.fileExists(atPath: system.path) ? system : nil) else { return nil }
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == noErr else { return nil }
        // An alert, not an interface effect: still heard with "Play user interface sound effects" off.
        var ui: UInt32 = 0
        AudioServicesSetProperty(kAudioServicesPropertyIsUISound, UInt32(MemoryLayout<SystemSoundID>.size), &id,
                                 UInt32(MemoryLayout<UInt32>.size), &ui)
        ids[name] = id
        return id
    }
}
