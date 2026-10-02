import AppKit
import AVFoundation
import AVKit
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
    var isVideo: Bool { mime.hasPrefix("video/") && thumb != nil }
}

extension ConversationViewController {
    /// Routes a picked or dropped file: photos keep the photo flow, videos are
    /// prepared for WhatsApp, anything else goes as a document.
    func attach(_ url: URL) {
        guard chat != nil else { return }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .image) {
            pendingFile = nil
            prepareImage(url)
        } else if type.conforms(to: .movie) {
            prepareVideo(url)
        } else {
            prepareDocument(url, type: type)
        }
    }

    private func prepareDocument(_ url: URL, type: UTType) {
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard size > 0, size <= 2_000_000_000 else { NSSound.beep(); return }   // WhatsApp's document limit is 2 GB
        pendingImage = nil
        pendingFile = PendingFile(path: url.path, name: url.lastPathComponent, mime: type.preferredMIMEType ?? "application/octet-stream")
        composer.showAttachment(NSWorkspace.shared.icon(forFile: url.path),
                                label: "\(url.lastPathComponent) · \(Fmt.bytes(size))")
        composer.focus()
    }

    private func prepareVideo(_ url: URL) {
        let jid = chat?.jid
        pendingImage = nil
        pendingFile = nil
        composer.showAttachment(NSImage(systemSymbolName: "video", accessibilityDescription: nil) ?? NSImage(), label: "Preparing video…")
        Task { [weak self] in
            let out = await Self.encodeVideo(url)
            guard let self, self.chat?.jid == jid else { return }
            guard let out else {
                NSSound.beep()
                self.composer.hideAttachment(animated: true)
                return
            }
            self.pendingFile = out
            let thumb = out.thumb.flatMap { NSImage(contentsOfFile: $0) }
                ?? NSImage(systemSymbolName: "video", accessibilityDescription: nil) ?? NSImage()
            self.composer.showAttachment(thumb, label: "Video · \(Fmt.duration(out.seconds))")
            self.composer.focus()
        }
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
    let loops: Bool
    var endObserver: NSObjectProtocol?

    init(id: String, view: AVPlayerView, player: AVPlayer, loops: Bool) {
        self.id = id
        self.view = view
        self.player = player
        self.loops = loops
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
        let iv = InlineVideo(id: m.id, view: v, player: player, loops: gif)
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
        if iv.loops {
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
        guard m.kind == .image || m.kind == .video, m.thumb == nil, m.hasMedia, !thumbRequested.contains(m.id),
              let jid = chat?.jid else { return }
        thumbRequested.insert(m.id)
        Core.shared.call("thumb", ["chat": jid, "id": m.id])
        if m.kind == .video, m.mediaPath.isEmpty, Prefs.autoVideoPosters {
            posterQueue.append((jid, m.id))
            pumpPosters()
        }
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
