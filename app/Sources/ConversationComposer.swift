import AppKit
import UniformTypeIdentifiers

/// The composer's delegate: sending text, edits, voice and attachments, typing state,
/// and preparing pasted or dropped images.
extension ConversationViewController: ComposerDelegate {
    // MARK: composer

    func composerSend(_ text: String) {
        guard let c = chat else { return }
        if let e = editing {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed != e.text {
                Core.shared.call("edit", ["chat": c.jid, "id": e.id, "text": trimmed])
            }
            editing = nil
            composer.hideReply(animated: true)
            composer.text = ""
            return
        }
        if !attachments.isEmpty {
            // The tray's files, each with its caption; the field holds the selected one's.
            sendAttachments(caption: text)
        } else {
            let text = Prefs.emojiReplace ? Emoticons.replace(text) : text
            var args: [String: Any] = ["chat": c.jid, "text": text, "quote": replyTo?.id ?? ""]
            if c.isGroup, case let ms = composer.mentions, !ms.isEmpty {
                args["mentions"] = ms.map { ["jid": $0.jid, "name": $0.name] }
            }
            if let p = composer.linkPreview, text.contains(p.url.absoluteString) || WAText.firstURL(text) == p.url {
                args["link_url"] = p.url.absoluteString
                args["link_title"] = p.title
                args["thumb"] = p.thumbPath ?? ""
            }
            let res = Core.shared.call("send_text", args)
            if let err = res["error"] as? String {
                NSSound.beep()
                NSLog("send failed: %@", err)
                return
            }
            if Prefs.outgoingSound { NSSound(named: "Pop")?.play() }
        }
        composer.text = ""
        drafts[c.jid] = nil
        replyTo = nil
        composer.hideReply(animated: true)
        typingStop?.cancel()
        lastTypingSent = .distantPast
    }

    // MARK: mentions

    func composerMentionQuery(_ query: String?) {
        guard let query, let c = chat, c.isGroup || Self.mentionDemo, editing == nil else { return mentionPicker.hide() }
        if mentionPeople == nil {
            mentionPeople = store.mentionable(c.jid).map { MentionCandidate(jid: $0.jid, name: $0.name) }
            // Members this Mac hasn't seen yet: fetch the group and try again.
            if mentionPeople?.isEmpty == true {
                let jid = c.jid
                Task { [weak self] in
                    _ = await Core.shared.callAsync("profile", ["chat": jid])
                    guard let self, self.chat?.jid == jid else { return }
                    self.mentionPeople = nil
                    self.composerMentionQuery(query)
                }
            }
        }
        mentionPicker.show(Self.matches(mentionPeople ?? [], query))
    }

    /// Dev (WA_MENTION_DEMO): types "@pr" into the open chat's composer against made-up
    /// people, picks the first after 8 s, and clears the field after 14 s. Nothing is sent,
    /// typing indicators included.
    static var mentionDemo = false
    func devMentionDemo() {
        // Only ever in my own chat ("Message yourself").
        guard let c = chat, c.jid == Core.shared.me else { return NSLog("WA mention demo: not the self chat, skipped") }
        Self.mentionDemo = true
        mentionPeople = [("Priya Shah", "15550000102"), ("Pranav Rao", "15550000104"), ("Jordan Lee", "15550000101"),
                         ("Maya Chen", "15550000100"), ("Prof. Okafor", "15550000105")].map {
            MentionCandidate(jid: $0.1 + "@s.whatsapp.net", name: $0.0)
        }
        composer.focus()
        composer.textView.insertText("Can you send the deck @pr", replacementRange: composer.textView.selectedRange())
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.mentionPicker.pickHighlighted() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 14) { [weak self] in
            self?.composer.text = ""
            Self.mentionDemo = false
        }
    }

    /// Members whose name has a word starting with what's typed (accents and case aside),
    /// or whose number contains its digits; names that start with it first.
    static func matches(_ people: [MentionCandidate], _ query: String) -> [MentionCandidate] {
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return Array(people.prefix(50)) }
        let digits = query.filter(\.isNumber)
        var first: [MentionCandidate] = [], rest: [MentionCandidate] = []
        for p in people {
            let name = fold(p.name)
            if name.hasPrefix(q) {
                first.append(p)
            } else if name.split(whereSeparator: { $0 == " " || $0 == "-" }).contains(where: { $0.hasPrefix(q) })
                        || (!digits.isEmpty && JID.user(p.jid).contains(digits)) {
                rest.append(p)
            }
        }
        return Array((first + rest).prefix(50))
    }

    func composerMentionCommand(_ sel: Selector) -> Bool {
        guard mentionPicker.isShowing else { return false }
        switch sel {
        case #selector(NSResponder.moveUp(_:)): mentionPicker.move(-1)
        case #selector(NSResponder.moveDown(_:)): mentionPicker.move(1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)): mentionPicker.pickHighlighted()
        case #selector(NSResponder.cancelOperation(_:)): mentionPicker.hide()
        default: return false
        }
        return true
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
        guard let c = chat, !Self.mentionDemo else { return }   // the dev demo types silently
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
        clearAttachments()
    }

    func composerPasteImage(_ image: NSImage) -> Bool {
        guard chat != nil, let tiff = image.tiffRepresentation else { return false }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("paste-\(UUID().uuidString).tiff")
        guard (try? tiff.write(to: url)) != nil else { return false }
        attachFiles([(url, .photo)])
        return true
    }

    func composerPasteFiles(_ urls: [URL]) -> Bool {
        guard chat != nil else { return false }
        attachMany(urls, asDocuments: false)
        return true
    }

    /// Re-encodes to JPEG (≤2560px) plus a small inline thumbnail, off the main thread.
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
