import Foundation

/// Events pushed from the Go core. Everything heavy (messages, chats) is read
/// from SQLite; events only say *what changed*.
enum CoreEvent {
    case state(String, me: String?, message: String?)
    case qr(String)
    case chats
    case messages(chat: String, ids: [String])
    case reload(chat: String)
    case typing(chat: String, sender: String, on: Bool)
    case presence(jid: String, online: Bool, lastSeen: Date?)
    case notify(chat: String, id: String, title: String, body: String, muted: Bool, reaction: Bool)
    case sync(progress: Int)
    case media(chat: String, id: String, status: String)
    case error(String)
}

/// Called by Go on arbitrary threads. The buffer is only valid during the call.
nonisolated func coreEventCallback(_ json: UnsafePointer<CChar>?, _ len: Int64) {
    guard let json, len > 0 else { return }
    let data = Data(bytes: json, count: Int(len))
    DispatchQueue.main.async {
        MainActor.assumeIsolated { Core.shared.receive(data) }
    }
}

final class Core {
    static let shared = Core()

    let dataDir: URL
    /// WA_PREVIEW_DIR=<dir> renders a synthetic store (tools/make_preview_db.py)
    /// with no network, for UI work without touching a real account.
    let isPreview: Bool
    private(set) var me: String = ""
    private(set) var state: String = "starting"
    private var observers: [(CoreEvent) -> Void] = []

    private init() {
        if let dir = ProcessInfo.processInfo.environment["WA_PREVIEW_DIR"], !dir.isEmpty {
            dataDir = URL(fileURLWithPath: dir, isDirectory: true)
            isPreview = true
            return
        }
        isPreview = false
        dataDir = AppPaths.dataDir
    }

    var dbPath: String { dataDir.appendingPathComponent("app.db").path }
    var isPaired: Bool { !me.isEmpty }

    /// Opens local storage synchronously and starts connecting in the background.
    func start() {
        if isPreview {
            me = "15550000000@s.whatsapp.net"
            return
        }
        let res = dataDir.path.withCString { dir in
            Core.decode(WAStart(UnsafeMutablePointer(mutating: dir), coreEventCallback))
        }
        if let err = res["error"] as? String {
            NSLog("WA core start failed: %@", err)
        }
        me = res["me"] as? String ?? ""
    }

    func observe(_ fn: @escaping (CoreEvent) -> Void) {
        observers.append(fn)
    }

    @discardableResult
    func call(_ op: String, _ args: [String: Any] = [:]) -> [String: Any] {
        if isPreview { return PreviewSim.shared.handle(op, args) }
        var body = args
        body["op"] = op
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return [:] }
        let out = data.withUnsafeBytes { raw -> UnsafeMutablePointer<CChar>? in
            guard let base = raw.baseAddress else { return nil }
            return WACall(UnsafeMutablePointer(mutating: base.assumingMemoryBound(to: CChar.self)), Int64(data.count))
        }
        return Core.decode(out)
    }

    /// Same as `call`, but runs the core off the main thread (for network-bound ops).
    func callAsync(_ op: String, _ args: [String: Any] = [:]) async -> [String: Any] {
        if isPreview { return PreviewSim.shared.handle(op, args) }
        var body = args
        body["op"] = op
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return [:] }
        let box = await withCheckedContinuation { (cont: CheckedContinuation<UncheckedBox<[String: Any]>, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let out = data.withUnsafeBytes { raw -> UnsafeMutablePointer<CChar>? in
                    guard let base = raw.baseAddress else { return nil }
                    return WACall(UnsafeMutablePointer(mutating: base.assumingMemoryBound(to: CChar.self)), Int64(data.count))
                }
                cont.resume(returning: UncheckedBox(value: Core.decode(out)))
            }
        }
        return box.value
    }

    nonisolated private static func decode(_ p: UnsafeMutablePointer<CChar>?) -> [String: Any] {
        guard let p else { return [:] }
        defer { WAFree(p) }
        let data = Data(bytes: p, count: strlen(p))
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    fileprivate func receive(_ data: Data) {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let t = o["t"] as? String else { return }
        let s = { (k: String) in o[k] as? String ?? "" }
        let event: CoreEvent
        switch t {
        case "state":
            state = s("s")
            if let m = o["me"] as? String, !m.isEmpty { me = m }
            if state == "logged_out" { me = "" }
            event = .state(state, me: o["me"] as? String, message: o["msg"] as? String)
        case "qr": event = .qr(s("code"))
        case "chats": event = .chats
        case "msgs": event = .messages(chat: s("chat"), ids: o["ids"] as? [String] ?? [])
        case "reload": event = .reload(chat: s("chat"))
        case "typing": event = .typing(chat: s("chat"), sender: s("sender"), on: o["on"] as? Bool ?? false)
        case "presence":
            let ls = (o["last_seen"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            event = .presence(jid: s("jid"), online: o["online"] as? Bool ?? false, lastSeen: ls)
        case "notify":
            event = .notify(chat: s("chat"), id: s("id"), title: s("title"), body: s("body"), muted: o["muted"] as? Bool ?? false,
                            reaction: o["reaction"] as? Bool ?? false)
        case "sync": event = .sync(progress: (o["progress"] as? Int) ?? Int(o["progress"] as? Double ?? 0))
        case "media": event = .media(chat: s("chat"), id: s("id"), status: s("status"))
        case "avatar": return // the core follows up with a "chats" event
        case "stickers":
            NotificationCenter.default.post(name: StickerLibrary.changed, object: nil)
            return
        case "error": event = .error(s("msg"))
        default: return
        }
        dispatch(event)
    }

    func dispatch(_ event: CoreEvent) {
        for fn in observers { fn(event) }
    }
}
