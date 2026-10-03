import AppKit
import CoreText
import SQLite3

/// The app's public identity: Backchannel, an unofficial Mac app for WhatsApp.
/// "WhatsApp" never goes in the name, the icon or the domain (Meta's brand rules).
enum Brand {
    static let name = "Backchannel"
    static let descriptor = "A native Mac app for WhatsApp."
    static let disclaimer = "Unofficial. Not affiliated with WhatsApp or Meta."

    /// The wordmark face: Instrument Sans (SIL Open Font License, Resources/Fonts/OFL.txt).
    /// The UI stays in SF; this is only for the name itself.
    static func wordmarkFont(size: CGFloat, weight: CGFloat = 620) -> NSFont {
        _ = registerFonts
        let wght = 0x77676874   // 'wght'
        let d = NSFontDescriptor(fontAttributes: [
            .family: "Instrument Sans",
            .variation: [NSNumber(value: wght): NSNumber(value: Double(weight))],
        ])
        return NSFont(descriptor: d, size: size) ?? .systemFont(ofSize: size, weight: .semibold)
    }

    /// The name set as the wordmark: tracked tight, like the brand sheet.
    static func wordmark(size: CGFloat, color: NSColor = .labelColor) -> NSAttributedString {
        NSAttributedString(string: name, attributes: [
            .font: wordmarkFont(size: size),
            .foregroundColor: color,
            .kern: -0.035 * size,
        ])
    }

    private static let registerFonts: Void = {
        if let url = Bundle.main.url(forResource: "InstrumentSans", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()
}

/// Where the app keeps its data: ~/Library/Application Support/Backchannel. Builds before
/// the rename used ".../WA"; that folder is moved here once (see Migration). If the move
/// ever failed, the old folder keeps being used, so nobody lands on a fresh, unpaired app.
enum AppPaths {
    nonisolated static var base: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }
    nonisolated static var current: URL { base.appendingPathComponent("Backchannel", isDirectory: true) }
    nonisolated static var legacy: URL { base.appendingPathComponent("WA", isDirectory: true) }

    nonisolated static var dataDir: URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: current.path), fm.fileExists(atPath: legacy.path) { return legacy }
        return current
    }
}

/// One-time move from the old identity (WA, com.aritropaul.wa) to Backchannel: every
/// setting, and the data folder with the link keys, chats and media. Runs before
/// anything reads defaults or opens a database.
enum Migration {
    static let legacyBundleID = "com.aritropaul.wa"
    private static let doneKey = "Backchannel.migratedFromWA"

    static func run() {
        guard ProcessInfo.processInfo.environment["WA_PREVIEW_DIR"] == nil else { return }
        let d = UserDefaults.standard
        guard !d.bool(forKey: doneKey) else { return }
        let fm = FileManager.default
        let hasLegacyData = fm.fileExists(atPath: AppPaths.legacy.path)
        let legacyDefaults = d.persistentDomain(forName: legacyBundleID)
        guard hasLegacyData || legacyDefaults != nil else {
            d.set(true, forKey: doneKey)
            return
        }
        // The old app holds the databases open; moving them under it could corrupt them.
        if !NSRunningApplication.runningApplications(withBundleIdentifier: legacyBundleID).isEmpty {
            let a = NSAlert()
            a.messageText = "Quit WA first"
            a.informativeText = "\(Brand.name) brings over your chats and settings from WA. Quit WA, then open \(Brand.name) again."
            a.runModal()
            exit(0)
        }
        if let old = legacyDefaults {
            for (k, v) in old where d.object(forKey: k) == nil { d.set(v, forKey: k) }
        }
        if hasLegacyData, !fm.fileExists(atPath: AppPaths.current.path) {
            backUpDatabases()
            do {
                try fm.moveItem(at: AppPaths.legacy, to: AppPaths.current)
                NSLog("Backchannel: moved data folder from WA")
            } catch {
                // AppPaths keeps using the old folder; try again next launch.
                NSLog("Backchannel: couldn't move the data folder: %@", String(describing: error))
                return
            }
        }
        d.set(true, forKey: doneKey)
    }

    /// Builds before the rename stored absolute paths under ".../WA/" (avatars, chat
    /// pictures, downloaded media, stickers). After the move they point at the new folder.
    /// Runs once, before the core opens the database, in one transaction.
    static func rewritePaths() {
        guard ProcessInfo.processInfo.environment["WA_PREVIEW_DIR"] == nil else { return }
        let d = UserDefaults.standard
        let key = "Backchannel.rewrotePaths"
        guard !d.bool(forKey: key), AppPaths.dataDir == AppPaths.current else { return }
        let path = AppPaths.current.appendingPathComponent("app.db").path
        guard FileManager.default.fileExists(atPath: path) else { d.set(true, forKey: key); return }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            NSLog("Backchannel: couldn't open app.db to move paths")
            sqlite3_close(db)
            return
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)
        func lit(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
        let old = lit(AppPaths.legacy.path + "/"), new = lit(AppPaths.current.path + "/")
        var sql = "BEGIN;"
        for (table, column) in [("avatars", "path"), ("chats", "avatar"), ("messages", "media_path"), ("stickers", "path")] {
            sql += " UPDATE \(table) SET \(column) = \(new) || substr(\(column), length(\(old)) + 1)"
                + " WHERE substr(\(column), 1, length(\(old))) = \(old);"
        }
        sql += " COMMIT;"
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK {
            NSLog("Backchannel: moved %d stored paths to the new folder", sqlite3_total_changes(db))
            d.set(true, forKey: key)
        } else {
            NSLog("Backchannel: couldn't move stored paths: %@", err.map { String(cString: $0) } ?? "?")
            sqlite3_free(err)
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
        }
    }

    /// A copy of the keys and the message store (not media) beside the data folder.
    private static func backUpDatabases() {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = AppPaths.base.appendingPathComponent("Backchannel backup \(stamp)", isDirectory: true)
        try? fm.createDirectory(at: backup, withIntermediateDirectories: true)
        for f in ["session.db", "session.db-wal", "session.db-shm", "app.db", "app.db-wal", "app.db-shm", "giphy.key"] {
            let src = AppPaths.legacy.appendingPathComponent(f)
            if fm.fileExists(atPath: src.path) { try? fm.copyItem(at: src, to: backup.appendingPathComponent(f)) }
        }
    }
}
