import AppKit

/// Copies an attachment out of the app's media folder into ~/Downloads, named the way
/// WhatsApp names its downloads: a document keeps its own file name, everything else is
/// "WhatsApp Image 2026-10-09 at 23.01.51.jpg" and so on.
enum Downloads {
    @discardableResult
    static func save(_ m: Message) -> URL? {
        guard !m.mediaPath.isEmpty,
              let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return nil }
        let src = URL(fileURLWithPath: m.mediaPath)
        let (base, ext) = name(m, src)
        var dest = downloads.appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = downloads.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        do {
            try FileManager.default.copyItem(at: src, to: dest)
        } catch {
            NSSound.beep()
            return nil
        }
        // Bounces the Downloads stack in the Dock, as Safari's downloads do.
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: dest.path)
        return dest
    }

    private static func name(_ m: Message, _ src: URL) -> (String, String) {
        let fileName = m.fileName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if m.kind == .document, !fileName.isEmpty {
            let u = URL(fileURLWithPath: fileName)
            return (u.deletingPathExtension().lastPathComponent, u.pathExtension.isEmpty ? src.pathExtension : u.pathExtension)
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let label = switch m.kind {
        case .image: "Image"
        case .video: "Video"
        case .voice: "Ptt"
        case .audio: "Audio"
        case .sticker: "Sticker"
        default: "Document"
        }
        let fallback = m.kind == .image ? "jpg" : ""
        return ("WhatsApp \(label) \(f.string(from: m.date))", src.pathExtension.isEmpty ? fallback : src.pathExtension)
    }
}
