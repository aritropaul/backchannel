import AppKit

/// What each site's message says and the colours it wears.
extension SiteCardLayout {
    struct Look {
        /// One colour, or a gradient's stops from the top-left corner.
        var fill: [NSColor]
        var ink: NSColor
        /// The site's address under the name.
        var muted: NSColor
        var border: NSColor?
    }

    enum Thumb {
        case picture(String?, dark: String?)
        case art(String)
    }

    struct Words {
        /// What someone wrote: a post, a caption, a comment. Shown only when there is some.
        var words = ""
        var lines: Int = 12
        var thumb: Thumb?
        /// The name of the thing linked: a video, song, app, article, place. It leads the row.
        var title: String?
        var titleLines = 2
        var from: String?
        var fromLines = 1
        var site: String
        /// The post's photo or video frame, shown across the top of the bubble.
        var media: Thumb?
        var aspect: CGFloat = 1
        var video = false
        /// A video's length, on its frame.
        var duration: String?
        /// The picture is an app icon, shown on `backdrop` (the colour around its edge).
        var icon = false
        var backdrop: UInt32?
    }

    /// Each site in its brand colour with white text. Where white doesn't reach 4.5:1 on the
    /// brand's own colour, the colour is deepened just enough (same OKLCH hue and chroma, lower
    /// lightness), and the address stays solid; it fades only where the fill leaves room.
    nonisolated static func look(_ site: String?) -> Look {
        func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor { NSColor(hex: v, alpha: a) }
        func look(_ stops: [UInt32], address a: CGFloat = 1) -> Look {
            Look(fill: stops.map { hex($0) }, ink: hex(0xFFFFFF), muted: hex(0xFFFFFF, a))
        }
        switch site {
        case "x": return look([0x000000], address: 0.7)
        case "youtube": return look([0xED012F])                         // #FF0033
        case "tiktok": return look([0xEB0446])                          // #FE2C55
        case "instagram": return look([0x833AB4, 0xDD2C69, 0xD54222])   // #833AB4 #E1306C #F56040
        case "reddit": return look([0xDB3B04])                          // #FF4500
        case "linkedin": return look([0x0A66C2], address: 0.9)
        case "airbnb": return look([0xE8154A])                          // #FF385C
        case "github": return look([0x1F2328], address: 0.7)
        case "spotify": return look([0x008938])                         // #1ED760
        case "applemusic": return look([0xED0330, 0xD83A58])            // #FA233B #FB5C74
        case "podcasts": return look([0xCA1AD6, 0x832BC1])              // #F452FF #832BC1
        case "appstore": return look([0x0880A7, 0x1970F1])              // #1AC3FC #1C73F4
        case "bluesky": return look([0x0175E4])                         // #1185FE
        case "hackernews": return look([0xCA5004])                      // #FF6600
        case "maps": return look([0x1A73E8])
        case "wikipedia":
            // Wikipedia's dark theme, with a rule so it holds its edge on a dark chat.
            var l = look([0x101418], address: 0.7)
            l.border = hex(0x54595D)
            return l
        default: return look([0x3A3A3C], address: 0.75)
        }
    }

    /// The message: the picture, what was written, then a row with the thing's name, who it's from and where.
    nonisolated static func message(_ c: SiteCard) -> Words {
        let at = c.handle.map { "@" + $0 }
        // "Eric Hu (@_EricHu)"
        let who: String? = {
            if let n = c.name, let at { return "\(n) (\(at))" }
            return c.name ?? at
        }()
        let avatar = c.avatar.map { Thumb.picture($0, dark: nil) }
        let media = c.media.map { Thumb.picture($0, dark: c.mediaDark) }
        let host = c.host ?? URL(string: c.url)?.host ?? ""
        var m = words(c, who: who, at: at, avatar: avatar, media: media, host: host)
        if m.media != nil {
            let video = c.play == true || c.site == "youtube" || c.site == "tiktok" || c.kind == "reel"
            m.video = video
            m.duration = video ? c.badge : nil
            m.aspect = c.aspect.map { CGFloat($0) } ?? (video ? 16 / 9 : m.aspect)
        }
        return m
    }

    private nonisolated static func words(_ c: SiteCard, who: String?, at: String?, avatar: Thumb?, media: Thumb?, host: String) -> Words {
        switch c.site {
        case "x":
            return Words(words: c.body ?? "", thumb: avatar, from: who, site: "x.com", media: media)
        case "bluesky":
            return Words(words: c.body ?? "", thumb: avatar, from: who, site: "bsky.app", media: media)
        case "tiktok":
            return Words(words: c.body ?? "", lines: 4, thumb: avatar, from: who, site: "tiktok.com", media: media)
        case "instagram":
            return Words(words: c.body ?? "", lines: 6, thumb: avatar, from: at ?? c.name, site: "instagram.com", media: media)
        case "linkedin":
            return Words(words: c.body ?? "", lines: 8, thumb: avatar, from: c.name, site: "linkedin.com", media: media)
        case "youtube":
            return Words(thumb: avatar, title: c.title, from: c.name, site: "youtube.com", media: media)
        case "reddit":
            return Words(words: c.body ?? "", lines: 8, thumb: avatar, title: c.title, from: c.handle.map { "r/" + $0 }, site: "reddit.com", media: media)
        case "airbnb":
            return Words(title: c.body ?? c.title, from: c.body == nil ? nil : c.title, site: "airbnb.com", media: media)
        case "github":
            switch c.kind {
            case "issue", "pull":
                return Words(thumb: avatar, title: c.title, titleLines: 3, from: [c.detail, c.handle.map { "#" + $0 }].compactMap { $0 }.joined(separator: " "), site: "github.com")
            case "commit", "release":
                return Words(thumb: avatar, title: c.title, titleLines: 3, from: [c.detail, c.handle].compactMap { $0 }.joined(separator: " "), site: "github.com")
            case "user", "org":
                return Words(thumb: avatar, title: c.name.map { n in at.map { "\(n) (\($0))" } ?? n } ?? at, from: c.body, fromLines: 2, site: "github.com")
            case "gist":
                return Words(thumb: avatar, title: c.title, from: c.body ?? c.name, fromLines: 2, site: "gist.github.com")
            default:
                return Words(thumb: avatar, title: c.title ?? c.name, from: c.body, fromLines: 2, site: "github.com")
            }
        // The artwork across the top, then two lines: the name and the link.
        case "spotify":
            return Words(title: c.title, titleLines: 1, site: "open.spotify.com", media: avatar)
        case "applemusic":
            return Words(title: c.title, titleLines: 1, site: "music.apple.com", media: avatar)
        case "podcasts":
            return Words(title: c.title, titleLines: 1, site: "podcasts.apple.com", media: avatar)
        case "appstore":
            return Words(title: c.title, titleLines: 1, site: "apps.apple.com", media: avatar, aspect: 1.6, icon: true,
                         backdrop: c.palette?.first.flatMap { UInt32($0, radix: 16) })
        case "wikipedia":
            // The article's picture, its name and the link; the extract stays on Wikipedia.
            return Words(title: c.title, titleLines: 1, site: host, media: media)
        case "hackernews":
            return Words(words: c.body ?? "", lines: 8, thumb: .art("hn-y18"), title: c.title, titleLines: 3, from: c.name, site: "news.ycombinator.com")
        case "maps":
            return Words(title: c.title, from: c.detail, fromLines: 2, site: "google.com/maps", media: media)
        default:
            return Words(thumb: avatar ?? media, title: c.title ?? c.body, from: who, site: host)
        }
    }
}
