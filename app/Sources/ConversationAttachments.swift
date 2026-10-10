import AppKit
import AVFoundation
import AVKit
import QuickLookThumbnailing
import Quartz
import UniformTypeIdentifiers

/// A non-photo attachment waiting in the composer: a video (re-encoded to mp4
/// with a thumbnail) or any other file, which goes as a document.
struct PendingFile {
    let path: String
    let name: String
    let mime: String
    var thumb: String?
    var width = 0
    var height = 0
    var seconds = 0
    /// Music sent as audio (the player bubble), not as a document.
    var isAudio = false
    var isVideo: Bool { mime.hasPrefix("video/") && thumb != nil }
}

/// A file waiting in the composer's tray. It's made ready for WhatsApp as soon as it's
/// added (photos re-encoded, videos made mp4), so sending doesn't wait on it, and it
/// carries its own caption.
final class Attachment {
    enum Kind { case photo, video, document, audio }
    enum Payload {
        case photo(path: String, thumb: String, w: Int, h: Int)
        case file(PendingFile)
    }

    let id = UUID()
    let url: URL
    var kind: Kind
    var caption = ""
    var image: NSImage?
    var payload: Payload?
    var task: Task<Payload?, Never>?
    /// What the line under the tray says when this one is selected.
    var info: String
    var badge: String?

    init(url: URL, kind: Kind, info: String) {
        self.url = url
        self.kind = kind
        self.info = info
    }

    var name: String { url.lastPathComponent.hasPrefix("paste-") ? "Pasted image" : url.lastPathComponent }
    var tray: TrayItem { TrayItem(id: id, image: image, preparing: payload == nil, badge: badge, name: name) }

    /// Ready to send: now, or once its preparation finishes (nil if that failed).
    func prepared() async -> Payload? {
        if let payload { return payload }
        return await task?.value
    }
}

extension ConversationViewController {
    /// WhatsApp sends up to 100 files at once.
    static let maxAttachments = 100

    /// Adds files to the tray after the ones already there: photos keep the photo flow,
    /// videos are prepared for WhatsApp, anything else goes as a document. `asDocuments`
    /// sends photos and videos as files at full quality (the Document picker).
    func attachMany(_ urls: [URL], asDocuments: Bool) {
        attachFiles(urls.map { url in
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
                ?? UTType(filenameExtension: url.pathExtension) ?? .data
            if asDocuments { return (url, .document) }
            if type.conforms(to: .image) { return (url, .photo) }
            if type.conforms(to: .movie) { return (url, .video) }
            return (url, .document)
        })
    }

    func attachFiles(_ files: [(URL, Attachment.Kind)]) {
        guard chat != nil, !files.isEmpty else { return }
        let room = Self.maxAttachments - attachments.count
        if files.count > room { NSSound.beep() }
        var added: [Attachment] = []
        for (url, kind) in files.prefix(max(0, room)) {
            if let a = prepare(url, kind) { added.append(a) }
        }
        guard !added.isEmpty else { return }
        attachments += added
        refreshTray()
        composer.focus()
    }

    private func prepare(_ url: URL, _ kind: Attachment.Kind) -> Attachment? {
        switch kind {
        case .document:
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            guard size > 0, size <= 2_000_000_000 else { NSSound.beep(); return nil }   // WhatsApp's document limit is 2 GB
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension)
            let a = Attachment(url: url, kind: .document, info: "\(url.lastPathComponent) · \(Fmt.bytes(size))")
            a.payload = .file(PendingFile(path: url.path, name: url.lastPathComponent,
                                          mime: type?.preferredMIMEType ?? "application/octet-stream"))
            thumbnail(a)
            return a
        case .photo:
            let a = Attachment(url: url, kind: .photo, info: "Photo")
            a.info = a.name == "Pasted image" ? "Pasted image" : a.name
            a.task = Task { await Self.encodePhoto(url).map { .photo(path: $0.path, thumb: $0.thumb, w: $0.w, h: $0.h) } }
            thumbnail(a)
            finish(a) { a, p in
                if case .photo(_, _, let w, let h) = p { a.info += " · \(w)×\(h)" }
            }
            return a
        case .video:
            let a = Attachment(url: url, kind: .video, info: "\(url.lastPathComponent) · Preparing…")
            a.task = Task { await Self.encodeVideo(url).map { .file($0) } }
            thumbnail(a)
            finish(a) { a, p in
                guard case .file(let f) = p else { return }
                a.info = "\(a.name) · \(Fmt.duration(f.seconds))"
                a.badge = Fmt.duration(f.seconds)
                if let t = f.thumb.flatMap(NSImage.init(contentsOfFile:)), a.image == nil { a.image = t }
            }
            return a
        case .audio:
            let a = Attachment(url: url, kind: .audio, info: "\(url.deletingPathExtension().lastPathComponent) · Preparing…")
            a.image = Self.attachIcon("headphones", NSColor(hex: 0xFA6533), size: 112)
            a.task = Task {
                guard let out = await Self.encodeAudio(url) else { return nil }
                // Over 16 MB, music goes as a document.
                if out.size > 16_000_000 {
                    let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? .audio
                    return .file(PendingFile(path: url.path, name: url.lastPathComponent, mime: type.preferredMIMEType ?? "audio/mpeg"))
                }
                return .file(out.file)
            }
            finish(a) { a, p in
                guard case .file(let f) = p else { return }
                if f.isAudio {
                    a.info = "\(url.deletingPathExtension().lastPathComponent) · \(Fmt.duration(f.seconds))"
                    a.badge = Fmt.duration(f.seconds)
                } else {
                    a.kind = .document
                    a.info = "\(url.lastPathComponent) · \(Fmt.bytes(Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)))"
                }
            }
            return a
        }
    }

    /// Waits for a file's preparation, then shows the result; a file that can't be
    /// prepared leaves the tray with a beep.
    private func finish(_ a: Attachment, _ apply: @escaping (Attachment, Attachment.Payload) -> Void) {
        Task { [weak self] in
            let p = await a.task?.value
            guard let self, self.attachments.contains(where: { $0 === a }) else { return }
            guard let p else {
                NSSound.beep()
                if let i = self.attachments.firstIndex(where: { $0 === a }) { self.composerRemoveAttachment(i) }
                return
            }
            a.payload = p
            apply(a, p)
            self.refreshTray()
        }
    }

    /// The tile's picture: Quick Look's thumbnail (a PDF's first page, a photo, a video
    /// frame), or the file's icon.
    private func thumbnail(_ a: Attachment) {
        let px = AttachmentTray.side * 2
        let request = QLThumbnailGenerator.Request(fileAt: a.url, size: CGSize(width: px, height: px), scale: 1,
                                                   representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            let box = UncheckedBox(value: rep?.nsImage)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    a.image = box.value ?? NSWorkspace.shared.icon(forFile: a.url.path)
                    if self.attachments.contains(where: { $0 === a }) { self.refreshTray() }
                }
            }
        }
    }

    /// Shows the tray as the attachments are now, or hides it when there are none.
    func refreshTray() {
        guard !attachments.isEmpty else {
            selectedAttachment = 0
            composer.hideAttachments(animated: true)
            return
        }
        selectedAttachment = min(selectedAttachment, attachments.count - 1)
        let a = attachments[selectedAttachment]
        let info = attachments.count > 1 ? "\(a.info) · \(selectedAttachment + 1) of \(attachments.count)" : a.info
        composer.showAttachments(attachments.map(\.tray), selected: selectedAttachment, info: info,
                                 captionless: a.kind == .audio)
    }

    /// Empties the tray (switching chats, Esc).
    func clearAttachments(animated: Bool = true) {
        attachments.forEach { $0.task?.cancel() }
        attachments = []
        selectedAttachment = 0
        composer.hideAttachments(animated: animated)
    }

    /// Sends every file in the tray, in order, each with its own caption; the reply quote
    /// goes with the first. Audio has no caption, so its text follows as a message.
    func sendAttachments(caption: String) {
        guard let c = chat, !attachments.isEmpty else { return }
        attachments[selectedAttachment].caption = caption
        let items = attachments, quote = replyTo?.id ?? "", jid = c.jid
        Task { [weak self] in
            for (i, a) in items.enumerated() {
                guard let p = await a.prepared() else { continue }
                let text = a.caption.trimmingCharacters(in: .whitespacesAndNewlines)
                var args: [String: Any] = ["chat": jid, "quote": i == 0 ? quote : ""]
                let op: String
                var after = ""
                switch p {
                case .photo(let path, let thumb, let w, let h):
                    op = "send_image"
                    args.merge(["path": path, "thumb": thumb, "width": w, "height": h, "mime": "image/jpeg", "text": text]) { $1 }
                case .file(let f) where f.isAudio:
                    op = "send_audio"
                    args.merge(["path": f.path, "name": f.name, "mime": f.mime, "seconds": f.seconds]) { $1 }
                    after = text
                case .file(let f):
                    op = "send_file"
                    args.merge(["path": f.path, "name": f.name, "mime": f.mime, "text": text, "thumb": f.thumb ?? "",
                                "width": f.width, "height": f.height, "seconds": f.seconds]) { $1 }
                }
                let res = await Core.shared.callAsync(op, args)
                if let err = res["error"] as? String {
                    NSSound.beep()
                    NSLog("send failed: %@", err)
                    // Nothing went: give the files back rather than lose them.
                    if i == 0, let self, self.chat?.jid == jid, self.attachments.isEmpty {
                        self.attachments = items
                        self.selectedAttachment = 0
                        self.composer.text = items[0].caption
                        self.refreshTray()
                    }
                    return
                }
                if i == 0, Prefs.outgoingSound { NSSound(named: "Pop")?.play() }
                if !after.isEmpty { _ = await Core.shared.callAsync("send_text", ["chat": jid, "text": after]) }
            }
        }
        attachments = []
        selectedAttachment = 0
        composer.hideAttachments(animated: true)
    }

    // MARK: tray actions

    func composerSelectAttachment(_ index: Int) {
        guard attachments.indices.contains(index), index != selectedAttachment else { return }
        attachments[selectedAttachment].caption = composer.text
        selectedAttachment = index
        composer.text = attachments[index].caption
        refreshTray()
        composer.focus()
    }

    func composerRemoveAttachment(_ index: Int) {
        guard attachments.indices.contains(index) else { return }
        attachments[index].task?.cancel()
        attachments.remove(at: index)
        if index < selectedAttachment {
            selectedAttachment -= 1
        } else if index == selectedAttachment, !attachments.isEmpty {
            // The removed file's caption goes with it; the next one's comes up.
            selectedAttachment = min(index, attachments.count - 1)
            composer.text = attachments[selectedAttachment].caption
        }
        refreshTray()
    }

    func composerOpenAttachment(_ index: Int) {
        guard attachments.indices.contains(index) else { return }
        previewURL = attachments[index].url
        QLPreviewPanel.shared()?.makeKeyAndOrderFront(nil)
    }

    /// The tray's +: more of the same, documents after documents, photos and videos otherwise.
    func composerAddAttachments(from anchor: NSView) {
        if attachments.first?.kind == .document { pickDocuments() } else { pickMedia() }
    }

    /// Re-encodes to H.264 mp4 (fits 1280×720), which every WhatsApp client
    /// plays, and grabs a small JPEG thumbnail. Off the main actor.
    @concurrent nonisolated static func encodeVideo(_ url: URL) async -> PendingFile? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let shown = natural.applying(transform)
        let w = abs(shown.width), h = abs(shown.height)
        let seconds = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
        let dir = FileManager.default.temporaryDirectory, id = UUID().uuidString
        let out = dir.appendingPathComponent("\(id).mp4")
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else { return nil }
        do { try await export.export(to: out, as: .mp4) } catch { return nil }

        var thumbPath: String?
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 320, height: 320)
        if let frame = try? await gen.image(at: CMTime(seconds: min(0.5, seconds / 2), preferredTimescale: 600)).image {
            let thumbURL = dir.appendingPathComponent("\(id)-thumb.jpg")
            if let d = CGImageDestinationCreateWithURL(thumbURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(d, frame, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
                if CGImageDestinationFinalize(d) { thumbPath = thumbURL.path }
            }
        }
        // The preset fits the long side to 1280 and the short side to 720.
        let scale = min(1, 1280 / max(w, h, 1), 720 / max(min(w, h), 1))
        return PendingFile(path: out.path, name: url.lastPathComponent, mime: "video/mp4", thumb: thumbPath,
                           width: Int((w * scale).rounded()), height: Int((h * scale).rounded()), seconds: Int(seconds.rounded()))
    }
}

// MARK: - Inline video

/// The one video playing inside its bubble.
final class InlineVideo {
    let id: String
    let view: AVPlayerView
    let player: AVPlayer
    /// Plays left, this one included.
    var plays: Int
    var endObserver: NSObjectProtocol?

    init(id: String, view: AVPlayerView, player: AVPlayer, plays: Int) {
        self.id = id
        self.view = view
        self.player = player
        self.plays = plays
    }
}

extension ConversationViewController {
    /// Plays a downloaded video in place, over its thumbnail, like Messages. GIFs
    /// (WhatsApp sends them as looping mp4s) loop muted without controls.
    func playInline(_ m: Message, url: URL) {
        stopInline()
        guard let row = rowIndex(of: m.id),
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? BubbleView,
              let rect = cell.item?.mediaRect else { return }
        let gif = m.fileName == "GIF"
        let player = AVPlayer(url: url)
        player.isMuted = gif
        let v = AVPlayerView(frame: rect)
        v.player = player
        v.controlsStyle = gif ? AVPlayerViewControlsStyle.none : AVPlayerViewControlsStyle.inline
        v.showsFullScreenToggleButton = !gif
        v.videoGravity = AVLayerVideoGravity.resizeAspectFill
        v.wantsLayer = true
        v.layer?.cornerRadius = 16
        v.layer?.masksToBounds = true
        v.setAccessibilityLabel(gif ? "GIF" : "Video")
        cell.addSubview(v)
        cell.playerView = v
        // GIFs play twice and stop, as in WhatsApp; click again for more.
        let iv = InlineVideo(id: m.id, view: v, player: player, plays: gif ? 2 : 1)
        let id = m.id
        iv.endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                                object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.inlineVideoEnded(id) }
        }
        inlineVideo = iv
        Motion.fade(v.layer, duration: 0.15)
        player.play()
    }

    private func inlineVideoEnded(_ id: String) {
        guard let iv = inlineVideo, iv.id == id else { return }
        iv.plays -= 1
        if iv.plays > 0 {
            iv.player.seek(to: .zero)
            iv.player.play()
        } else {
            stopInline()
        }
    }

    func stopInline() {
        guard let iv = inlineVideo else { return }
        inlineVideo = nil
        iv.player.pause()
        if let o = iv.endObserver { NotificationCenter.default.removeObserver(o) }
        (iv.view.superview as? BubbleView)?.playerView = nil
        iv.view.removeFromSuperview()
    }
}

// MARK: - Backfill for history imported before waveforms were stored

extension ConversationViewController {
    /// A voice note whose sender sent no waveform gets one computed from the
    /// downloaded audio, once, and stored by the core.
    func fillWaveformIfNeeded(_ m: Message) {
        guard m.kind == .voice, m.waveform == nil, !m.mediaPath.isEmpty, !waveformTried.contains(m.id), let jid = chat?.jid else { return }
        waveformTried.insert(m.id)
        let url = URL(fileURLWithPath: m.mediaPath), id = m.id
        Task {
            guard let wave = await Self.computeWaveform(url) else { return }
            Core.shared.call("set_waveform", ["chat": jid, "id": id, "waveform": Data(wave).base64EncodedString()])
        }
    }

    @concurrent nonisolated static func computeWaveform(_ url: URL) async -> [UInt8]? {
        guard let buf = try? OggOpus.decode(url) else { return nil }
        return OggOpus.waveform(buf)
    }
}

// MARK: - Thumbnails

extension ConversationViewController {
    /// Photos and videos that arrived without an inline thumbnail: the core fetches
    /// WhatsApp's separate thumbnail (downloaded videos also get a poster frame).
    func requestThumbIfNeeded(_ m: Message) {
        if m.kind == .document { return requestDocumentPreview(m) }
        guard m.kind == .image || m.kind == .video, m.thumb == nil, m.hasMedia, !thumbRequested.contains(m.id),
              let jid = chat?.jid else { return }
        thumbRequested.insert(m.id)
        Core.shared.call("thumb", ["chat": jid, "id": m.id])
        if m.kind == .video, m.mediaPath.isEmpty, Prefs.autoVideoPosters {
            posterQueue.append((jid, m.id))
            pumpPosters()
        }
    }

    /// A document's preview: the sharp first page the sender uploaded (the core fetches it,
    /// no download of the document), or, for a file already on this Mac, a Quick Look
    /// thumbnail of it. Icons don't count: a file Quick Look can't draw keeps its plain row.
    private func requestDocumentPreview(_ m: Message) {
        guard let jid = chat?.jid else { return }
        if m.hasMedia, !thumbRequested.contains(m.id) {
            thumbRequested.insert(m.id)
            Core.shared.call("thumb", ["chat": jid, "id": m.id])
        }
        // Once the file is here (downloaded later, or one I sent), Quick Look draws it.
        let local = "ql:" + m.id
        guard m.thumb == nil, !m.mediaPath.isEmpty, !thumbRequested.contains(local),
              FileManager.default.fileExists(atPath: m.mediaPath), Self.previewable(m.mediaPath) else { return }
        thumbRequested.insert(local)
        let req = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: m.mediaPath), size: CGSize(width: 300, height: 400),
                                               scale: 2, representationTypes: .thumbnail)
        let id = m.id
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            guard let rep, rep.type == .thumbnail,
                  let jpeg = NSBitmapImageRep(cgImage: rep.cgImage).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
            else { return }
            let b64 = jpeg.base64EncodedString()
            DispatchQueue.main.async { Core.shared.call("set_thumb", ["chat": jid, "id": id, "thumb": b64]) }
        }
    }

    /// Files Quick Look draws the content of (a page, a cover, a sheet); for the rest it
    /// draws an icon-like picture that would only repeat the row's own icon.
    static func previewable(_ path: String) -> Bool {
        guard let t = UTType(filenameExtension: (path as NSString).pathExtension),
              !t.conforms(to: .calendarEvent), !t.conforms(to: .vCard) else { return false }
        return [UTType.pdf, .image, .epub, .presentation, .spreadsheet, .compositeContent, .text].contains { t.conforms(to: $0) }
    }

    /// The phone's history has no video thumbnails, so frame 1 comes from the start of
    /// the file only (512 KB, then 2 MB if the index sits further in). Two at a time.
    private func pumpPosters() {
        while postersInFlight < 2, !posterQueue.isEmpty {
            let (jid, id) = posterQueue.removeFirst()
            postersInFlight += 1
            Task { [weak self] in
                for bytes in [512 << 10, 2 << 20] {
                    let res = await Core.shared.callAsync("video_prefix", ["chat": jid, "id": id, "bytes": bytes])
                    guard let path = res["path"] as? String else { break }
                    let jpeg = await Self.firstFrameJPEG(URL(fileURLWithPath: path))
                    try? FileManager.default.removeItem(atPath: path)
                    if let jpeg {
                        Core.shared.call("set_thumb", ["chat": jid, "id": id, "thumb": jpeg.base64EncodedString()])
                        break
                    }
                }
                guard let self else { return }
                self.postersInFlight -= 1
                self.pumpPosters()
            }
        }
    }

    @concurrent nonisolated static func firstFrameJPEG(_ url: URL) async -> Data? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 640)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .positiveInfinity   // the first decodable frame
        guard let frame = try? await gen.image(at: .zero).image else { return nil }
        let out = NSMutableData()
        guard let d = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(d, frame, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        return CGImageDestinationFinalize(d) ? out as Data : nil
    }
}
