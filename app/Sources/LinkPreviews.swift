import AppKit
import LinkPresentation

/// Link previews made on this Mac with LinkPresentation: the page's title and a small JPEG.
enum LinkPreviews {
    enum Outcome: Sendable {
        case found(title: String, thumbPath: String?)
        case none        // the page answered but has no title: nothing to show, don't ask again
        case failed      // offline or timed out: try again another time
    }

    nonisolated static func fetch(_ url: URL, _ done: @escaping @Sendable (Outcome) -> Void) {
        let provider = LPMetadataProvider()
        provider.timeout = 8
        provider.startFetchingMetadata(for: url) { meta, error in
            guard let meta else { return done(error == nil ? .none : .failed) }
            let title = meta.title ?? ""
            guard !title.isEmpty else { return done(.none) }
            guard let ip = meta.imageProvider ?? meta.iconProvider, ip.canLoadObject(ofClass: NSImage.self) else {
                return done(.found(title: title, thumbPath: nil))
            }
            _ = ip.loadObject(ofClass: NSImage.self) { obj, _ in
                done(.found(title: title, thumbPath: (obj as? NSImage).flatMap(ComposerView.writeThumb)))
            }
        }
    }
}

extension ConversationViewController {
    /// A link that came without a preview (sent before the preview was ready, or from a device
    /// that doesn't make them) gets one here, kept on this Mac only. Only as its message loads
    /// on screen, two at a time: older messages are never swept through in advance.
    func previewLinkIfNeeded(_ m: Message) {
        guard m.kind == .text, m.linkTitle.isEmpty, m.linkURL.isEmpty, !linkRequested.contains(m.id),
              let jid = chat?.jid, let url = WAText.firstURL(m.text), url.scheme?.hasPrefix("http") == true else { return }
        linkRequested.insert(m.id)
        linkQueue.append((jid, m.id, url))
        pumpLinks()
    }

    private func pumpLinks() {
        while linksInFlight < 2, !linkQueue.isEmpty {
            let next = linkQueue.removeFirst()
            linksInFlight += 1
            LinkPreviews.fetch(next.url) { outcome in
                DispatchQueue.main.async { [weak self] in
                    switch outcome {
                    case .found(let title, let thumb):
                        Core.shared.call("set_link_preview", ["chat": next.chat, "id": next.id, "link_url": next.url.absoluteString,
                                                              "link_title": title, "thumb": thumb ?? ""])
                    case .none:
                        Core.shared.call("set_link_preview", ["chat": next.chat, "id": next.id, "link_url": next.url.absoluteString,
                                                              "link_title": ""])
                    case .failed:
                        break
                    }
                    guard let self else { return }
                    self.linksInFlight -= 1
                    self.pumpLinks()
                }
            }
        }
    }
}
