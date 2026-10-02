import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Read-only view of the core's database. Every query is indexed and small,
/// so reads run synchronously on the main thread: no hops, no spinners.
final class Store {
    private var db: OpaquePointer?
    private var cache: [String: OpaquePointer] = [:]

    init?(path: String) {
        var h: OpaquePointer?
        guard sqlite3_open_v2(path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let h else {
            return nil
        }
        db = h
        sqlite3_busy_timeout(h, 2000)
        sqlite3_exec(h, "PRAGMA query_only=ON; PRAGMA mmap_size=268435456; PRAGMA cache_size=-16000;", nil, nil, nil)
    }

    private func stmt(_ sql: String) -> OpaquePointer? {
        if let s = cache[sql] { return s }
        var s: OpaquePointer?
        guard sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &s, nil) == SQLITE_OK, let s else {
            NSLog("sqlite prepare: %s", sqlite3_errmsg(db))
            return nil
        }
        cache[sql] = s
        return s
    }

    /// Runs a query; always resets so no read snapshot outlives the call
    /// (a held snapshot would stall the writer's WAL checkpoints).
    private func query(_ sql: String, _ args: [Any], _ row: (Row) -> Void) {
        guard let s = stmt(sql) else { return }
        defer { sqlite3_reset(s); sqlite3_clear_bindings(s) }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case let v as String: sqlite3_bind_text(s, idx, v, -1, SQLITE_TRANSIENT)
            case let v as Int: sqlite3_bind_int64(s, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(s, idx, v)
            case let v as Bool: sqlite3_bind_int64(s, idx, v ? 1 : 0)
            default: sqlite3_bind_null(s, idx)
            }
        }
        let r = Row(s: s)
        while sqlite3_step(s) == SQLITE_ROW { row(r) }
    }

    struct Row {
        let s: OpaquePointer
        func str(_ i: Int32) -> String {
            guard let c = sqlite3_column_text(s, i) else { return "" }
            return String(cString: c)
        }
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(s, i) }
        func blob(_ i: Int32) -> Data? {
            let n = Int(sqlite3_column_bytes(s, i))
            guard n > 0, let p = sqlite3_column_blob(s, i) else { return nil }
            return Data(bytes: p, count: n)
        }
    }

    // MARK: chats

    private static let chatSQL = """
        SELECT c.jid, c.name, c.is_group, c.last_ts, c.unread, c.marked_unread, c.pinned, c.archived, c.muted_until, c.avatar,
               ct.name, ct.push_name,
               m.kind, m.text, m.from_me, m.status, m.file_name, sc.name, sc.push_name, m.push_name, m.sender
        FROM chats c
        LEFT JOIN contacts ct ON ct.jid = c.jid
        LEFT JOIN messages m ON m.chat = c.jid AND m.id = c.last_id
        LEFT JOIN contacts sc ON sc.jid = m.sender
        """

    func chats(archived: Bool) -> [Chat] {
        var out: [Chat] = []
        out.reserveCapacity(512)
        query(Store.chatSQL + " WHERE c.archived = ? AND c.last_ts > 0 ORDER BY c.pinned DESC, c.last_ts DESC", [archived]) {
            out.append(Store.chat(from: $0))
        }
        return out
    }

    func chat(_ jid: String) -> Chat? {
        var c: Chat?
        query(Store.chatSQL + " WHERE c.jid = ?", [jid]) { c = Store.chat(from: $0) }
        return c
    }

    func archivedSummary() -> (count: Int, unread: Int) {
        var r = (0, 0)
        query("SELECT COUNT(*), SUM(unread > 0 OR marked_unread) FROM chats WHERE archived = 1 AND last_ts > 0", []) {
            r = (Int($0.int(0)), Int($0.int(1)))
        }
        return r
    }

    func unreadChatCount() -> Int {
        var n = 0
        let now = Int64(Date().timeIntervalSince1970)
        query("""
            SELECT COUNT(*) FROM chats WHERE archived = 0 AND (unread > 0 OR marked_unread = 1)
              AND NOT (muted_until = -1 OR muted_until > ?)
            """, [now]) { n = Int($0.int(0)) }
        return n
    }

    /// Profile picture path for any JID: "" unknown, "-" none.
    func avatar(_ jid: String) -> String {
        var out = ""
        // Pictures fetched before the avatars table existed live on chat rows.
        query("SELECT COALESCE((SELECT path FROM avatars WHERE jid = ?), (SELECT avatar FROM chats WHERE jid = ?), '')", [jid, jid]) {
            out = $0.str(0)
        }
        return out
    }

    /// Most recent distinct senders in a group (for the iMessage-style collage).
    func recentSenders(_ chat: String, limit: Int = 3) -> [String] {
        var out: [String] = []
        query("SELECT sender FROM messages WHERE chat = ? AND from_me = 0 AND sender != '' GROUP BY sender ORDER BY MAX(ts) DESC LIMIT ?",
              [chat, limit]) { out.append($0.str(0)) }
        return out
    }

    struct Person { let jid: String; let name: String; let isGroup: Bool; let subtitle: String }

    /// People and groups for the New Message picker: chats first, then contacts.
    func people(matching q: String, limit: Int = 40) -> [Person] {
        var out: [Person] = []
        var seen = Set<String>()
        let like = "%\(q)%"
        let filter = " WHERE c.last_ts > 0 AND (? = '' OR COALESCE(NULLIF(ct.name,''), NULLIF(ct.push_name,''), NULLIF(c.name,''), c.jid) LIKE ?) ORDER BY c.last_ts DESC LIMIT ?"
        query(Store.chatSQL + filter, [q, like, limit]) {
            let c = Store.chat(from: $0)
            seen.insert(c.jid)
            out.append(Person(jid: c.jid, name: c.name, isGroup: c.isGroup, subtitle: c.isGroup ? "Group" : JID.phone(c.jid)))
        }
        guard !q.isEmpty else { return out }
        let sql = "SELECT jid, CASE WHEN name != '' THEN name ELSE push_name END FROM contacts WHERE jid LIKE '%@s.whatsapp.net' AND (name LIKE ? OR push_name LIKE ? OR jid LIKE ?) LIMIT ?"
        query(sql, [like, like, like, limit]) {
            let jid = $0.str(0)
            guard !seen.contains(jid) else { return }
            out.append(Person(jid: jid, name: $0.str(1), isGroup: false, subtitle: JID.phone(jid)))
        }
        return out
    }

    /// Recent photos in a chat for the profile panel.
    func recentPhotos(_ chat: String, limit: Int) -> [(thumb: Data?, path: String)] {
        var out: [(Data?, String)] = []
        query("SELECT thumb, media_path FROM messages WHERE chat = ? AND kind = 1 ORDER BY ts DESC LIMIT ?", [chat, limit]) {
            out.append(($0.blob(0), $0.str(1)))
        }
        return out
    }

    /// Display name for a person: saved contact, then push name, then number.
    func name(_ jid: String) -> String {
        var out = ""
        query("SELECT name, push_name FROM contacts WHERE jid = ?", [jid]) {
            out = $0.str(0).isEmpty ? $0.str(1) : $0.str(0)
        }
        return out.isEmpty ? JID.phone(jid) : out
    }

    private static func chat(from r: Row) -> Chat {
        let jid = r.str(0)
        let isGroup = r.int(2) == 1
        let contactName = r.str(10), push = r.str(11), chatName = r.str(1)
        var name: String
        if isGroup {
            name = chatName.isEmpty ? "Group" : chatName
        } else if !contactName.isEmpty {
            name = contactName
        } else if !push.isEmpty {
            name = push
        } else if !chatName.isEmpty {
            name = chatName
        } else {
            name = JID.phone(jid)
        }
        if jid == Core.shared.me { name = "\(name) (You)" }
        var last: Chat.Last?
        if sqlite3_column_type(r.s, 12) != SQLITE_NULL {
            var sender = r.str(17)
            if sender.isEmpty { sender = r.str(18) }
            if sender.isEmpty { sender = r.str(19) }
            if sender.isEmpty { sender = JID.phone(r.str(20)) }
            last = .init(kind: MessageKind(rawValue: Int(r.int(12))) ?? .unsupported, text: r.str(13),
                         fromMe: r.int(14) == 1, status: Int(r.int(15)), fileName: r.str(16),
                         senderName: sender)
        }
        return Chat(jid: jid, name: name, isGroup: isGroup, lastTS: r.int(3), unread: Int(r.int(4)),
                    markedUnread: r.int(5) == 1, pinned: r.int(6) != 0, archived: r.int(7) == 1,
                    mutedUntil: r.int(8), avatar: r.str(9), last: last)
    }

    // MARK: search

    struct SearchHit: Equatable {
        let chat: String
        let id: String
        let ts: Int64
        let fromMe: Bool
        let senderName: String
        /// Matched text with the hits wrapped in \u{2}…\u{3}.
        let snippet: String
        var date: Date { Date(timeIntervalSince1970: TimeInterval(ts) / 1000) }
    }

    /// Full-text search over every chat's messages (text and file names), newest first.
    /// Each word matches as a prefix; all words must match. The FTS rowid is the
    /// message's rowid (the triggers insert it that way), so the join is an integer
    /// lookup: a one-letter query (~24k matches) takes ~8ms instead of ~45ms.
    func searchMessages(_ q: String, limit: Int = 60) -> [SearchHit] {
        let words = q.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let match = words.map { "\"\($0)\"*" }.joined(separator: " ")
        var out: [SearchHit] = []
        query("""
            SELECT m.chat, m.id, m.ts, m.from_me, m.sender, snippet(messages_fts, -1, char(2), char(3), '…', 14),
                   sc.name, sc.push_name, m.push_name
            FROM messages_fts f
            JOIN messages m ON m.rowid = f.rowid
            LEFT JOIN contacts sc ON sc.jid = m.sender
            WHERE messages_fts MATCH ? AND m.kind != 10
            ORDER BY m.ts DESC LIMIT ?
            """, [match, limit]) { r in
            let fromMe = r.int(3) == 1
            var sender = r.str(6)
            if sender.isEmpty { sender = r.str(7) }
            if sender.isEmpty { sender = r.str(8) }
            if sender.isEmpty { sender = JID.phone(r.str(4)) }
            out.append(SearchHit(chat: r.str(0), id: r.str(1), ts: r.int(2), fromMe: fromMe,
                                 senderName: fromMe ? "You" : sender, snippet: r.str(5)))
        }
        return out
    }

    // MARK: messages

    private static let msgSQL = """
        SELECT m.rowid, m.id, m.sender, m.push_name, m.from_me, m.ts, m.kind, m.text, m.status, m.edited,
               m.quote_id, m.quote_sender, m.quote_text, m.quote_kind, m.reactions, m.mime, m.file_name, m.file_size,
               m.seconds, m.width, m.height, m.thumb, m.media_path, m.media != '',
               sc.name, sc.push_name, qc.name, qc.push_name, m.waveform, m.link_url, m.link_title, m.link_desc
        FROM messages m
        LEFT JOIN contacts sc ON sc.jid = m.sender
        LEFT JOIN contacts qc ON qc.jid = m.quote_sender
        """

    /// Newest `limit` messages before the cursor, returned oldest-first.
    func messages(chat: String, before: Message? = nil, limit: Int) -> [Message] {
        var out: [Message] = []
        out.reserveCapacity(limit)
        if let b = before {
            query(Store.msgSQL + " WHERE m.chat = ? AND (m.ts < ? OR (m.ts = ? AND m.rowid < ?)) ORDER BY m.ts DESC, m.rowid DESC LIMIT ?",
                  [chat, b.ts, b.ts, b.rowid, limit]) { out.append(Store.message(from: $0)) }
        } else {
            query(Store.msgSQL + " WHERE m.chat = ? ORDER BY m.ts DESC, m.rowid DESC LIMIT ?", [chat, limit]) {
                out.append(Store.message(from: $0))
            }
        }
        return out.reversed()
    }

    /// Everything at or after `from` (inclusive), oldest-first. Used to refresh the loaded window.
    func messages(chat: String, since from: Message, limit: Int) -> [Message] {
        var out: [Message] = []
        query(Store.msgSQL + " WHERE m.chat = ? AND (m.ts > ? OR (m.ts = ? AND m.rowid >= ?)) ORDER BY m.ts ASC, m.rowid ASC LIMIT ?",
              [chat, from.ts, from.ts, from.rowid, limit]) { out.append(Store.message(from: $0)) }
        return out
    }

    func message(chat: String, id: String) -> Message? {
        var m: Message?
        query(Store.msgSQL + " WHERE m.chat = ? AND m.id = ?", [chat, id]) { m = Store.message(from: $0) }
        return m
    }

    /// Newest message of a kind in a chat (dev hooks).
    func latestID(chat: String, kind: MessageKind) -> String? {
        var id: String?
        query("SELECT id FROM messages WHERE chat = ? AND kind = ? ORDER BY ts DESC LIMIT 1", [chat, kind.rawValue]) { id = $0.str(0) }
        return id
    }

    func unreadIncoming(chat: String, limit: Int) -> [String] {
        var ids: [String] = []
        query("SELECT id FROM messages WHERE chat = ? AND from_me = 0 ORDER BY ts DESC, rowid DESC LIMIT ?", [chat, limit]) {
            ids.append($0.str(0))
        }
        return ids
    }

    private static func message(from r: Row) -> Message {
        func name(_ a: Int32, _ b: Int32, fallback: String, jid: String) -> String {
            let n = r.str(a)
            if !n.isEmpty { return n }
            let p = r.str(b)
            if !p.isEmpty { return p }
            if !fallback.isEmpty { return fallback }
            return JID.phone(jid)
        }
        let sender = r.str(2)
        let quoteSender = r.str(11)
        let kind = MessageKind(rawValue: Int(r.int(6))) ?? .unsupported
        let linkTitle = r.str(30)
        let hasThumb = kind.isVisual || kind == .document || kind == .location || (kind == .text && !linkTitle.isEmpty)
        return Message(
            rowid: r.int(0), id: r.str(1), sender: sender,
            senderName: name(24, 25, fallback: r.str(3), jid: sender),
            fromMe: r.int(4) == 1, ts: r.int(5), kind: kind, text: r.str(7),
            status: Int(r.int(8)), edited: r.int(9) == 1,
            quoteID: r.str(10), quoteSender: quoteSender,
            quoteSenderName: quoteSender.isEmpty ? "" : name(26, 27, fallback: "", jid: quoteSender),
            quoteText: r.str(12), quoteKind: MessageKind(rawValue: Int(r.int(13))) ?? .text,
            reactions: Reactions(r.str(14)), mime: r.str(15), fileName: r.str(16), fileSize: r.int(17),
            seconds: Int(r.int(18)), width: Int(r.int(19)), height: Int(r.int(20)),
            thumb: hasThumb ? r.blob(21) : nil, mediaPath: r.str(22), hasMedia: r.int(23) == 1,
            waveform: (kind == .voice || kind == .audio) ? r.blob(28) : nil,
            linkURL: r.str(29), linkTitle: linkTitle, linkDesc: r.str(31))
    }
}
