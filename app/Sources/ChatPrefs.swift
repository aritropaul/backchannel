import AppKit
import LocalAuthentication
import Photos

/// Per-chat settings that WhatsApp keeps on each device: lock, sound, Save to Photos.
enum ChatPrefs {
    // MARK: Lock chat

    private static let lockedKey = "WA.lockedChats"

    static var locked: Set<String> { Set(UserDefaults.standard.stringArray(forKey: lockedKey) ?? []) }
    static func isLocked(_ jid: String) -> Bool { locked.contains(jid) }

    static func setLocked(_ jid: String, _ on: Bool) {
        var s = locked
        if on { s.insert(jid) } else { s.remove(jid) }
        UserDefaults.standard.set(Array(s).sorted(), forKey: lockedKey)
        NotificationCenter.default.post(name: Prefs.changed, object: lockedKey)
    }

    /// Touch ID, or the Mac's password where there's no sensor.
    static func authenticate(_ reason: String, _ done: @escaping @MainActor (Bool) -> Void) {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            done(false)
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { done(ok) } }
        }
    }

    // MARK: Notification sound

    /// "" follows Settings › Notifications; otherwise a tone's name, "default" or "none" (Tones).
    static func sound(_ jid: String) -> String { UserDefaults.standard.string(forKey: "WA.chatSound." + jid) ?? "" }
    static func setSound(_ jid: String, _ v: String) {
        UserDefaults.standard.set(v.isEmpty ? nil : v, forKey: "WA.chatSound." + jid)
    }

    // MARK: Save to Photos

    enum SaveMode: String { case `default`, always, never }

    static func saveMode(_ jid: String) -> SaveMode {
        UserDefaults.standard.string(forKey: "WA.chatSaveToPhotos." + jid).flatMap(SaveMode.init) ?? .default
    }
    static func setSaveMode(_ jid: String, _ m: SaveMode) {
        UserDefaults.standard.set(m == .default ? nil : m.rawValue, forKey: "WA.chatSaveToPhotos." + jid)
    }
    static func savesToPhotos(_ jid: String) -> Bool {
        switch saveMode(jid) {
        case .always: true
        case .never: false
        case .default: Prefs.saveToPhotos
        }
    }
}

/// Saves photos and videos I receive in Save to Photos chats into the Photos library,
/// once each, as soon as they finish downloading.
@MainActor
final class PhotoSaver {
    static let shared = PhotoSaver()
    private let store: () -> Store?
    private var saved: Set<String>
    private static let savedKey = "WA.savedToPhotos"

    private init() {
        store = { Avatars.shared.store }
        saved = Set(UserDefaults.standard.stringArray(forKey: Self.savedKey) ?? [])
    }

    /// A new message arrived: fetch it now if this chat saves to Photos.
    func incoming(chat: String, id: String) {
        guard ChatPrefs.savesToPhotos(chat), let m = store()?.message(chat: chat, id: id),
              !m.fromMe, m.kind == .image || m.kind == .video, m.mediaPath.isEmpty else { return }
        Core.shared.call("download", ["chat": chat, "id": id])
    }

    /// A download finished.
    func downloaded(chat: String, id: String) {
        let key = chat + "/" + id
        guard ChatPrefs.savesToPhotos(chat), !saved.contains(key), let m = store()?.message(chat: chat, id: id),
              !m.fromMe, m.kind == .image || m.kind == .video, !m.mediaPath.isEmpty else { return }
        // Only what arrives from now on; opening an old photo later doesn't save it.
        guard m.date > Date().addingTimeInterval(-24 * 3600) else { return }
        let url = URL(fileURLWithPath: m.mediaPath)
        let video = m.kind == .video
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                if video {
                    PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } else {
                    PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
            }) { ok, _ in
                guard ok else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { PhotoSaver.shared.remember(key) }
                }
            }
        }
    }

    private func remember(_ key: String) {
        saved.insert(key)
        UserDefaults.standard.set(Array(saved.suffix(2000)), forKey: Self.savedKey)
    }
}
