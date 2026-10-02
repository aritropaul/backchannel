import AppKit

/// Per-device preferences from the Chats and Notifications sections. WhatsApp
/// keeps these on each device rather than on the server, so they live here.
enum Prefs {
    static let changed = Notification.Name("WA.prefsChanged")

    nonisolated private static func bool(_ k: String, _ def: Bool) -> Bool {
        UserDefaults.standard.object(forKey: k) as? Bool ?? def
    }
    nonisolated private static func string(_ k: String, _ def: String) -> String {
        UserDefaults.standard.string(forKey: k) ?? def
    }

    static func set(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
        if key == "WA.theme" { applyTheme() }
        NotificationCenter.default.post(name: changed, object: key)
        if key == "WA.wallpaper" { NotificationCenter.default.post(name: Theme.didChange, object: nil) }
    }

    // MARK: Chats

    /// system | light | dark
    static var theme: String { string("WA.theme", "system") }
    /// One of `Wallpaper.all`'s ids.
    nonisolated static var wallpaper: String { string("WA.wallpaper", "none") }
    static var enterSends: Bool { bool("WA.enterSends", true) }
    static var spellCheck: Bool { bool("WA.spellCheck", true) }
    static var emojiReplace: Bool { bool("WA.emojiReplace", false) }
    nonisolated static var autoPhotos: Bool { bool("WA.auto.photos", true) }
    nonisolated static var autoAudio: Bool { bool("WA.auto.audio", true) }
    nonisolated static var autoVideoPosters: Bool { bool("WA.auto.videoPosters", true) }
    nonisolated static var autoDocuments: Bool { bool("WA.auto.documents", false) }

    // MARK: Notifications

    static var notifyMessages: Bool { bool("WA.notify.messages", true) }
    static var notifyGroups: Bool { bool("WA.notify.groups", true) }
    static var notifyPreviews: Bool { bool("WA.notify.previews", true) }
    static var notifyReactions: Bool { bool("WA.notify.reactions", true) }
    static var notifyGroupReactions: Bool { bool("WA.notify.groupReactions", true) }
    static var outgoingSound: Bool { bool("WA.sound.outgoing", false) }

    /// "Reset notification settings": back to WhatsApp's defaults.
    static func resetNotifications() {
        for k in ["WA.notify.messages", "WA.notify.groups", "WA.notify.previews", "WA.notify.reactions",
                  "WA.notify.groupReactions", "WA.notify.sound", "WA.sound.outgoing", "WA.badge"] {
            UserDefaults.standard.removeObject(forKey: k)
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }
    /// default | none | a macOS alert sound name
    static var notifySound: String { string("WA.notify.sound", "default") }
    static var badge: Bool { bool("WA.badge", true) }

    static func applyTheme() {
        switch theme {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    /// macOS's alert sounds, for the notification sound picker.
    static var alertSounds: [String] {
        let dir = URL(fileURLWithPath: "/System/Library/Sounds")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".aiff") }.map { String($0.dropLast(5)) }.sorted()
    }
}

/// Chat canvas colours: none (the system text background) or a soft solid, each
/// with a light and dark tone. Bubbles and text stay legible on all of them.
enum Wallpaper {
    nonisolated static let all: [(id: String, title: String, light: UInt32, dark: UInt32)] = [
        ("none", "Default", 0, 0),
        ("sand", "Sand", 0xF3EDE4, 0x1F1C18),
        ("mint", "Mint", 0xE7F3EC, 0x16201B),
        ("sky", "Sky", 0xE6EFF7, 0x151C24),
        ("lilac", "Lilac", 0xEEE9F5, 0x1C1924),
        ("blush", "Blush", 0xF6E9EA, 0x231A1B),
        ("slate", "Slate", 0xE9ECEF, 0x1B1E21),
    ]

    nonisolated static func color(dark: Bool) -> NSColor? {
        guard let w = all.first(where: { $0.id == Prefs.wallpaper }), w.id != "none" else { return nil }
        return NSColor(hex: dark ? w.dark : w.light)
    }
}

/// ":)" → 🙂 and friends, for "Replace text with emoji".
enum Emoticons {
    private static let map: [(String, String)] = [
        (":-)", "🙂"), (":)", "🙂"), (":-(", "🙁"), (":(", "🙁"), (":-D", "😀"), (":D", "😀"), (";-)", "😉"), (";)", "😉"),
        (":-P", "😛"), (":P", "😛"), (":p", "😛"), (":'(", "😢"), (":-O", "😮"), (":O", "😮"), (":o", "😮"), ("<3", "❤️"),
        (":-*", "😘"), (":*", "😘"), ("B-)", "😎"), (":-|", "😐"), (":|", "😐"),
    ]

    /// Replaces emoticons that stand alone (at the ends or between spaces), so
    /// URLs and code like "http://" stay intact.
    static func replace(_ text: String) -> String {
        var words = text.components(separatedBy: " ")
        for i in words.indices {
            if let hit = map.first(where: { $0.0 == words[i] }) { words[i] = hit.1 }
        }
        return words.joined(separator: " ")
    }
}
