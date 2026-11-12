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

/// What a link on screen is waiting for.
enum LinkJob {
    /// Its site's own card; `fallback` asks for a plain preview if the site has none.
    case site(fallback: Bool)
    case preview
}

extension ConversationViewController {
    /// A link to a site we know (X, YouTube, GitHub…) gets that site's card; a link that came
    /// without a preview (sent before the preview was ready, or from a device that doesn't
    /// make them) gets one here. Both are kept on this Mac only, and made only as the message
    /// loads on screen, two at a time: older messages are never swept through in advance.
    func previewLinkIfNeeded(_ m: Message) {
        guard m.kind == .text, !linkRequested.contains(m.id), let jid = chat?.jid, let url = m.cardLink else { return }
        let bare = m.linkTitle.isEmpty && m.linkURL.isEmpty
        if m.storedSite == nil || !m.siteFilesPresent, Sites.handles(url) {
            linkRequested.insert(m.id)
            linkQueue.append((jid, m.id, url, .site(fallback: bare)))
        } else if bare, m.siteCard == nil {
            linkRequested.insert(m.id)
            linkQueue.append((jid, m.id, url, .preview))
        } else {
            return
        }
        pumpLinks()
    }

    private func pumpLinks() {
        while linksInFlight < 2, !linkQueue.isEmpty {
            let next = linkQueue.removeFirst()
            linksInFlight += 1
            let finish: @Sendable () -> Void = {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.linksInFlight -= 1
                    self.pumpLinks()
                }
            }
            switch next.job {
            case .site(let fallback):
                Sites.fetch(next.url) { outcome in
                    DispatchQueue.main.async { [weak self] in
                        switch outcome {
                        case .card(let card):
                            Self.storeSite(card, chat: next.chat, id: next.id)
                        case .none:
                            Self.storeSite(.nothing(next.url.absoluteString), chat: next.chat, id: next.id)
                            if fallback { self?.linkQueue.append((next.chat, next.id, next.url, .preview)) }
                        case .failed:
                            if fallback { self?.linkQueue.append((next.chat, next.id, next.url, .preview)) }
                        }
                        finish()
                    }
                }
            case .preview:
                LinkPreviews.fetch(next.url) { outcome in
                    DispatchQueue.main.async {
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
                        finish()
                    }
                }
            }
        }
    }

    private static func storeSite(_ card: SiteCard, chat: String, id: String) {
        guard let data = try? JSONEncoder().encode(card), let json = String(data: data, encoding: .utf8) else { return }
        Core.shared.call("set_site", ["chat": chat, "id": id, "text": json])
    }
}
