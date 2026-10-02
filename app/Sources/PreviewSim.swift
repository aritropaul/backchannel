import Foundation
import SQLite3

private let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Stands in for the Go core when WA_PREVIEW_DIR is set: writes to the synthetic
/// store and emits the same events, so UI and motion can be exercised offline.
/// WA_PREVIEW_DEMO=1 plays a scripted conversation in whatever chat is open.
final class PreviewSim {
    static let shared = PreviewSim()
    private var db: OpaquePointer?
    private var seq = 0
    private let me = "15550000000@s.whatsapp.net"

    private init() {
        sqlite3_open_v2(Core.shared.dbPath, &db, SQLITE_OPEN_READWRITE, nil)
        sqlite3_busy_timeout(db, 2000)
    }

    private func exec(_ sql: String, _ args: [Any]) {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(s) }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case let v as String: sqlite3_bind_text(s, idx, v, -1, TRANSIENT)
            case let v as Int: sqlite3_bind_int64(s, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(s, idx, v)
            default: sqlite3_bind_null(s, idx)
            }
        }
        sqlite3_step(s)
    }

    private func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private func insert(chat: String, sender: String, text: String, status: Int) -> String {
        seq += 1
        let id = "SIM\(seq)-\(now())"
        let ts = now()
        exec("""
            INSERT INTO messages (chat, id, sender, push_name, from_me, ts, kind, text, status) VALUES (?,?,?,?,?,?,0,?,?)
            """, [chat, id, sender, "", sender == me ? 1 : 0, ts, text, status])
        exec("UPDATE chats SET last_id=?, last_ts=? WHERE jid=?", [id, ts, chat])
        return id
    }

    private func emit(_ e: CoreEvent) { Core.shared.dispatch(e) }

    func handle(_ op: String, _ args: [String: Any]) -> [String: Any] {
        let chat = args["chat"] as? String ?? ""
        switch op {
        case "send_text":
            let id = insert(chat: chat, sender: me, text: args["text"] as? String ?? "", status: MessageStatus.pending)
            emit(.messages(chat: chat, ids: [id]))
            emit(.chats)
            for (delay, st) in [(0.6, MessageStatus.sent), (1.4, MessageStatus.delivered), (2.6, MessageStatus.read)] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self.exec("UPDATE messages SET status=? WHERE chat=? AND id=?", [st, chat, id])
                    self.emit(.messages(chat: chat, ids: [id]))
                }
            }
            return ["id": id]
        case "react":
            let id = args["id"] as? String ?? ""
            let e = args["emoji"] as? String ?? ""
            exec("UPDATE messages SET reactions=? WHERE chat=? AND id=?", [e.isEmpty ? "" : "\(e)\t1\t\(e)", chat, id])
            emit(.messages(chat: chat, ids: [id]))
            return ["ok": true]
        case "mark_read":
            exec("UPDATE chats SET unread=0, marked_unread=0 WHERE jid=?", [chat])
            emit(.chats)
            return ["ok": true]
        default:
            return ["ok": true]
        }
    }

    /// Scripted beats: send → typing → reply → tapback on my message → another chat jumps to the top.
    func runDemo(chat: @escaping () -> String?) {
        let after = { (t: Double, f: @escaping () -> Void) in DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        var mine = ""
        after(2.0) {
            guard let c = chat() else { return }
            mine = (self.handle("send_text", ["chat": c, "text": "On my way! 🚲"])["id"] as? String) ?? ""
        }
        after(4.0) {
            guard let c = chat() else { return }
            self.emit(.typing(chat: c, sender: c, on: true))
        }
        after(6.5) {
            guard let c = chat() else { return }
            self.emit(.typing(chat: c, sender: c, on: false))
            let id = self.insert(chat: c, sender: c.hasSuffix("@g.us") ? "15550000002@s.whatsapp.net" : c, text: "Perfect, see you in 10", status: 0)
            self.emit(.messages(chat: c, ids: [id]))
            self.emit(.chats)
        }
        after(8.0) {
            guard let c = chat(), !mine.isEmpty else { return }
            self.exec("UPDATE messages SET reactions=? WHERE chat=? AND id=?", ["❤️\t1\t", c, mine])
            self.emit(.messages(chat: c, ids: [mine]))
        }
        after(9.5) {
            let other = "15550000007@s.whatsapp.net"
            _ = self.insert(chat: other, sender: other, text: "Are you around this weekend?", status: 0)
            self.exec("UPDATE chats SET unread=unread+1 WHERE jid=?", [other])
            self.emit(.chats)
        }
    }
}
