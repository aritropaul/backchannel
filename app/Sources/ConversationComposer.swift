import AppKit
import UniformTypeIdentifiers

/// The composer's delegate: sending text, edits, voice and attachments, typing state,
/// and preparing pasted or dropped images.
extension ConversationViewController: ComposerDelegate {
    // MARK: composer

    func composerSend(_ text: String) {
        guard let c = chat else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let e = editing {
            if !trimmed.isEmpty && trimmed != e.text {
                Core.shared.call("edit", ["chat": c.jid, "id": e.id, "text": trimmed])
            }
            editing = nil
            composer.hideReply(animated: true)
            composer.text = ""
            return
        }
        var res: [String: Any]
        var textAfter = ""
        if let f = pendingFile, f.isAudio {
            // Audio has no caption; any text goes after it as its own message.
            res = Core.shared.call("send_audio", ["chat": c.jid, "path": f.path, "name": f.name, "mime": f.mime,
                                                  "seconds": f.seconds, "quote": replyTo?.id ?? ""])
            textAfter = trimmed
        } else if let f = pendingFile {
            res = Core.shared.call("send_file", ["chat": c.jid, "path": f.path, "name": f.name, "mime": f.mime, "text": trimmed,
                                                 "thumb": f.thumb ?? "", "width": f.width, "height": f.height,
                                                 "seconds": f.seconds, "quote": replyTo?.id ?? ""])
        } else if let img = pendingImage {
            res = Core.shared.call("send_image", ["chat": c.jid, "path": img.path, "thumb": img.thumb, "width": img.w, "height": img.h,
                                                  "mime": "image/jpeg", "text": trimmed, "quote": replyTo?.id ?? ""])
        } else {
            let text = Prefs.emojiReplace ? Emoticons.replace(text) : text
            var args: [String: Any] = ["chat": c.jid, "text": text, "quote": replyTo?.id ?? ""]
            if let p = composer.linkPreview, text.contains(p.url.absoluteString) || WAText.firstURL(text) == p.url {
                args["link_url"] = p.url.absoluteString
                args["link_title"] = p.title
                args["thumb"] = p.thumbPath ?? ""
            }
            res = Core.shared.call("send_text", args)
        }
        if let err = res["error"] as? String {
            NSSound.beep()
            NSLog("send failed: %@", err)
            return
        }
        if Prefs.outgoingSound { NSSound(named: "Pop")?.play() }
        if !textAfter.isEmpty { _ = Core.shared.call("send_text", ["chat": c.jid, "text": textAfter]) }
        sendQueuedAttachments()
        composer.text = ""
        drafts[c.jid] = nil
        replyTo = nil
        pendingImage = nil
        pendingFile = nil
        composer.hideReply(animated: true)
        composer.hideAttachment(animated: true)
        typingStop?.cancel()
        lastTypingSent = .distantPast
    }

    func composerSendVoice(_ r: VoiceRecorder.Result) {
        guard let c = chat else { return }
        let res = Core.shared.call("send_voice", ["chat": c.jid, "path": r.url.path, "seconds": r.seconds,
                                                  "waveform": Data(r.waveform).base64EncodedString(), "quote": replyTo?.id ?? ""])
        if res["error"] != nil { NSSound.beep() }
        replyTo = nil
        composer.hideReply(animated: true)
    }

    func composerDidChangeHeight() {
        view.layoutSubtreeIfNeeded()
        updateInsets()
    }

    func composerDidType() {
        guard let c = chat else { return }
        if Date().timeIntervalSince(lastTypingSent) > 8 {
            lastTypingSent = Date()
            Core.shared.call("typing", ["chat": c.jid, "on": true])
        }
        typingStop?.cancel()
        let jid = c.jid
        let stop = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                Core.shared.call("typing", ["chat": jid, "on": false])
                self?.lastTypingSent = .distantPast
            }
        }
        typingStop = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: stop)
    }

    func composerAttach(from anchor: NSView) {
        showAttachMenu(from: anchor)
    }

    func composerExpressions(from anchor: NSView) {
        showExpressions(from: anchor)
    }

    /// The composer's ☺ button (dev hook).
    var expressionAnchor: NSView { composer.expressionAnchor }

    func composerCancelReply() {
        if editing != nil { composer.text = "" }
        replyTo = nil
        editing = nil
        composer.hideReply(animated: true)
    }

    func composerCancelAttachment() {
        pendingImage = nil
        pendingFile = nil
        queuedAttachments = []
        composer.hideAttachment(animated: true)
    }

    func composerPasteImage(_ image: NSImage) -> Bool {
        guard chat != nil, let tiff = image.tiffRepresentation else { return false }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("paste-\(UUID().uuidString).tiff")
        guard (try? tiff.write(to: url)) != nil else { return false }
        prepareImage(url)
        return true
    }

    /// Re-encodes to JPEG (≤2560px) plus a small inline thumbnail, off the main thread.
    func prepareImage(_ url: URL) {
        guard chat != nil else { return }
        let jid = chat?.jid
        DispatchQueue.global(qos: .userInitiated).async {
            let out = ConversationViewController.encode(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let out, self.chat?.jid == jid else { NSSound.beep(); return }
                    self.pendingImage = (out.path, out.thumb, out.w, out.h)
                    if let img = NSImage(contentsOfFile: out.thumb) {
                        self.composer.showAttachment(img, label: "Photo · \(out.w)×\(out.h)\(self.queuedSuffix). Add a caption, then press Return.")
                    }
                    self.composer.focus()
                }
            }
        }
    }

    @concurrent nonisolated static func encodePhoto(_ url: URL) async -> (path: String, thumb: String, w: Int, h: Int)? {
        encode(url)
    }

    nonisolated private static func encode(_ url: URL) -> (path: String, thumb: String, w: Int, h: Int)? {
        guard let full = ImageCache.decode(url, px: 2560), let small = ImageCache.decode(url, px: 96) else { return nil }
        let dir = FileManager.default.temporaryDirectory
        let id = UUID().uuidString
        let path = dir.appendingPathComponent("\(id).jpg"), thumb = dir.appendingPathComponent("\(id)-thumb.jpg")
        func write(_ img: CGImage, _ to: URL, _ q: Double) -> Bool {
            guard let d = CGImageDestinationCreateWithURL(to as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
            CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
            return CGImageDestinationFinalize(d)
        }
        guard write(full, path, 0.85), write(small, thumb, 0.6) else { return nil }
        return (path.path, thumb.path, full.width, full.height)
    }
}
