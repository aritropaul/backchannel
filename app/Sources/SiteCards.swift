import AppKit
import CryptoKit
import ImageIO
import LinkPresentation
import MapKit
import UniformTypeIdentifiers

/// A link drawn the way its own site draws it: an X post as X embeds it, a repository as
/// GitHub pins it, a song as Spotify's player shows it. Made on this Mac from the site's own
/// data (`Sites`) and kept in the message's extra JSON under "site"; images are files in
/// `Sites.dir`, named here by file name only. `SiteCardLayout` draws each site its own way.
nonisolated struct SiteCard: Codable, Sendable, Equatable {
    /// Cards made before this version are made again (they lack what the site designs need).
    static let version = 3
    var v: Int?

    /// The link this card is for. A different link (the message was edited) gets a new card.
    var url: String
    /// The site had nothing to show (deleted, private, not found): don't ask again.
    var none: Bool?
    /// Which site's design: x, youtube, tiktok, instagram, reddit, linkedin, airbnb, github,
    /// spotify, applemusic, podcasts, appstore, bluesky, wikipedia, hackernews, maps.
    var site: String?
    /// The site's own sort of thing: short, repo, issue, pull, user, commit, release, gist,
    /// track, album, playlist, artist, episode, show, song, app, story, comment, ask…
    var kind: String?

    /// A video's, song's, article's, listing's or repository's name.
    var title: String?
    /// A post's words, a description, an extract.
    var body: String?
    /// Who posted it: the display name, channel, artist or developer.
    var name: String?
    /// Their handle or username, without the @; a subreddit's name.
    var handle: String?
    var verified: Bool?
    /// Their photo, a channel's or community's icon, the artwork or the app icon.
    var avatar: String?
    /// The avatar is a rounded square (an organisation on X, an app icon), not a circle.
    var square: Bool?

    var media: String?
    /// The same picture drawn for dark mode (maps).
    var mediaDark: String?
    /// Width over height of the media.
    var aspect: Double?
    var play: Bool?
    /// A video's length, "LIVE", or "3 photos", on its frame.
    var badge: String?

    /// When it was posted, in seconds since 1970.
    var date: Double?
    /// The site's own counts: likes, replies, reposts, views, comments, points, stars, forks,
    /// followers, ratings…
    var stats: [String: Int]?
    /// A colour the site draws with, as hex: a GitHub language's dot.
    var color: String?
    /// Colours taken from the artwork, as hex: Spotify's backdrop, tint and subdued text;
    /// a podcast's or app's background.
    var palette: [String]?
    /// A short tag: a language, an issue's state, "E" for explicit, "Guest favourite".
    var label: String?
    /// A second line: an address, an album, a listing's rooms, a repository on an issue.
    var detail: String?
    var rating: Double?
    var price: String?
    var host: String?

    init(url: String = "", site: String? = nil, kind: String? = nil) {
        self.v = Self.version
        self.url = url
        self.site = site
        self.kind = kind
    }

    static func nothing(_ url: String) -> SiteCard {
        var c = SiteCard(url: url)
        c.none = true
        return c
    }

    func stat(_ key: String) -> Int? { stats?[key] }

    mutating func count(_ key: String, _ n: Int?) {
        guard let n else { return }
        stats = (stats ?? [:]).merging([key: n]) { $1 }
    }
}

private nonisolated struct SiteExtra: Decodable { var site: SiteCard? }

extension Message {
    /// The link a preview or site card is made for: the preview's own URL, else the first
    /// link in the text.
    var cardLink: URL? {
        guard kind == .text else { return nil }
        if !linkURL.isEmpty, let u = URL(string: linkURL), u.scheme?.hasPrefix("http") == true { return u }
        guard let u = WAText.firstURL(text), u.scheme?.hasPrefix("http") == true else { return nil }
        return u
    }

    /// What's stored for this message's link: a card, a "nothing to show" marker, or nil
    /// when nothing has been made for the link it has now.
    var storedSite: SiteCard? {
        guard kind == .text, extra.contains("\"site\""), let d = extra.data(using: .utf8),
              let c = (try? JSONDecoder().decode(SiteExtra.self, from: d))?.site,
              c.url == cardLink?.absoluteString, c.v == SiteCard.version else { return nil }
        return c
    }

    /// True when a stored card's pictures are on this Mac (they can be cleared away).
    var siteFilesPresent: Bool {
        guard let c = storedSite else { return true }
        return [c.media, c.mediaDark, c.avatar].allSatisfy { f in Sites.path(f).map { FileManager.default.fileExists(atPath: $0) } ?? true }
    }

    /// The site card to draw, if there is one.
    var siteCard: SiteCard? {
        guard let c = storedSite, c.none != true, c.site != nil,
              !(c.title ?? "").isEmpty || !(c.body ?? "").isEmpty || !(c.name ?? "").isEmpty else { return nil }
        return c
    }
}

// MARK: - fetching

nonisolated enum Sites {
    enum Outcome: Sendable {
        case card(SiteCard)
        case none        // the site answered with nothing to show: remember that
        case failed      // offline, rate-limited, or the site changed: try another time
    }

    /// Where card images live: ~/Library/Application Support/Backchannel/links.
    static var dir: URL { AppPaths.dataDir.appendingPathComponent("links", isDirectory: true) }

    static func path(_ file: String?) -> String? {
        guard let file, !file.isEmpty else { return nil }
        return dir.appendingPathComponent(file).path
    }

    /// True for links some site below knows how to draw.
    static func handles(_ url: URL) -> Bool { target(url) != nil }

    /// Fetches the card off the main thread and calls back with the outcome.
    static func fetch(_ url: URL, _ done: @escaping @Sendable (Outcome) -> Void) {
        Task.detached(priority: .utility) {
            done(await card(for: url))
        }
    }

    static func card(for url: URL) async -> Outcome {
        guard let t = target(url) else { return .none }
        do {
            var c = try await t.fetch(url)
            c.url = url.absoluteString
            if c.host == nil { c.host = displayHost(url) }
            return .card(c)
        } catch Failure.gone {
            return .none
        } catch {
            return .failed
        }
    }

    enum Failure: Error { case gone, failed }

    // MARK: which site

    enum Target {
        case x(String)
        case youtube(String, short: Bool)
        case tiktok
        case instagram
        case reddit
        case linkedin
        case airbnb
        case github([String], gist: Bool)
        case spotify
        case apple
        case bluesky(actor: String, rkey: String)
        case wikipedia(lang: String, title: String)
        case hackerNews(Int)
        case maps

        func fetch(_ url: URL) async throws -> SiteCard {
            switch self {
            case .x(let id): try await Sites.x(id)
            case .youtube(let id, let short): try await Sites.youtube(id, short: short)
            case .tiktok: try await Sites.tiktok(url)
            case .instagram: try await Sites.instagram(url)
            case .reddit: try await Sites.reddit(url)
            case .linkedin: try await Sites.linkedin(url)
            case .airbnb: try await Sites.airbnb(url)
            case .github(let parts, let gist): try await Sites.github(parts, gist: gist)
            case .spotify: try await Sites.spotify(url)
            case .apple: try await Sites.apple(url)
            case .bluesky(let actor, let rkey): try await Sites.bluesky(actor, rkey)
            case .wikipedia(let lang, let title): try await Sites.wikipedia(lang, title)
            case .hackerNews(let id): try await Sites.hackerNews(id)
            case .maps: try await Sites.maps(url)
            }
        }
    }

    static func target(_ url: URL) -> Target? {
        guard let rawHost = url.host()?.lowercased() else { return nil }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        let parts = url.pathComponents.filter { $0 != "/" }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String? { query.first { $0.name == name }?.value }

        switch host {
        case "x.com", "twitter.com", "mobile.twitter.com", "fxtwitter.com", "fixupx.com", "vxtwitter.com", "fixvx.com":
            // /<user>/status/<id>, /i/status/<id>, /i/web/status/<id>; a trailing /photo/1 is ignored.
            if let i = parts.firstIndex(where: { $0 == "status" || $0 == "statuses" }), i + 1 < parts.count,
               let id = parts[i + 1].split(separator: "?").first, id.allSatisfy(\.isNumber) {
                return .x(String(id))
            }
        case "youtube.com", "m.youtube.com", "music.youtube.com":
            if parts.first == "watch", let v = q("v"), v.count == 11 { return .youtube(v, short: false) }
            if parts.count >= 2, ["shorts", "live", "embed"].contains(parts[0]), parts[1].count == 11 {
                return .youtube(parts[1], short: parts[0] == "shorts")
            }
        case "youtu.be":
            if let id = parts.first, id.count == 11 { return .youtube(id, short: false) }
        case "tiktok.com", "m.tiktok.com", "vm.tiktok.com", "vt.tiktok.com":
            if host != "tiktok.com" || parts.contains("video") || parts.contains("photo") || parts.first == "t" { return .tiktok }
        case "instagram.com", "instagr.am":
            if parts.contains(where: { ["p", "reel", "reels", "tv"].contains($0) }) { return .instagram }
        case "reddit.com", "old.reddit.com", "new.reddit.com", "np.reddit.com", "redd.it":
            if host == "redd.it" || parts.contains("comments") || (parts.count >= 4 && parts[2] == "s") { return .reddit }
        case "linkedin.com":
            if parts.first == "posts" || (parts.first == "feed" && parts.dropFirst().first == "update") { return .linkedin }
        case "airbnb.com", "airbnb.co.uk", "airbnb.ca", "airbnb.co.in", "airbnb.com.au", "airbnb.de", "airbnb.fr":
            if parts.first == "rooms", parts.count >= 2 { return .airbnb }
        case "github.com":
            if parts.count >= 1, !githubReserved.contains(parts[0].lowercased()) { return .github(parts, gist: false) }
        case "gist.github.com":
            if let last = parts.last, last.count >= 20 { return .github([last], gist: true) }
        case "open.spotify.com", "spotify.link":
            if host == "spotify.link" || spotifyKind(parts) != nil { return .spotify }
        case "music.apple.com", "podcasts.apple.com", "apps.apple.com":
            if parts.contains(where: { ["album", "song", "music-video", "artist", "playlist", "podcast", "app"].contains($0) }) { return .apple }
        case "bsky.app":
            if parts.count == 4, parts[0] == "profile", parts[2] == "post" { return .bluesky(actor: parts[1], rkey: parts[3]) }
        case "news.ycombinator.com":
            if parts.first == "item", let id = q("id").flatMap(Int.init) { return .hackerNews(id) }
        case "maps.app.goo.gl", "share.google":
            return .maps
        case "goo.gl":
            if parts.first == "maps" { return .maps }
        case "google.com", "maps.google.com":
            if host == "maps.google.com" || parts.first == "maps" { return .maps }
        default:
            // <lang>.wikipedia.org/wiki/<Title> and the mobile <lang>.m.wikipedia.org.
            if host.hasSuffix(".wikipedia.org"), parts.first == "wiki", parts.count >= 2 {
                let lang = String(host.split(separator: ".").first ?? "en")
                guard lang != "www" else { return nil }
                let title = parts.dropFirst().joined(separator: "/")
                return .wikipedia(lang: lang, title: title)
            }
        }
        return nil
    }

    /// First path segments on github.com that aren't people or organisations.
    private static let githubReserved: Set<String> = [
        "settings", "orgs", "organizations", "marketplace", "topics", "features", "about", "pricing", "sponsors",
        "explore", "notifications", "login", "logout", "join", "signup", "sessions", "new", "pulls", "issues",
        "search", "trending", "collections", "apps", "codespaces", "copilot", "enterprise", "security", "readme",
        "customer-stories", "solutions", "resources", "events", "site", "contact", "stars", "watching", "account",
        "dashboard", "users", "tos", "downloads", "education", "team", "premium-support", "mobile", "models",
        "gist", "support", "discussions", "home", "sitemap", "git-guides",
    ]

    static func displayHost(_ url: URL) -> String {
        var h = url.host()?.lowercased() ?? ""
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    // MARK: X

    static func x(_ id: String) async throws -> SiteCard {
        // X's own embed data first; it cuts long posts short, so those (and failures) go to fxtwitter.
        var tweet: J?
        do {
            let j = try await Net.json("https://cdn.syndication.twimg.com/tweet-result?id=\(id)&token=\(xToken(id))&lang=en")
            if j["__typename"].string == "TweetTombstone" { throw Failure.gone }
            if j["__typename"].string == "Tweet" { tweet = j }
        } catch Failure.gone {
            throw Failure.gone
        } catch {}
        if let t = tweet, !t["note_tweet"].exists { return await xCard(t) }
        do {
            let f = try await Net.json("https://api.fxtwitter.com/i/status/\(id)")["tweet"]
            if f.exists, f["type"].string != "tombstone" { return await fxCard(f) }
        } catch Failure.gone where tweet == nil {
            throw Failure.gone
        } catch {}
        guard let t = tweet else { throw Failure.failed }
        return await xCard(t)
    }

    private static func xCard(_ t: J) async -> SiteCard {
        var text = t["text"].string ?? ""
        for u in t["entities"]["urls"].array {
            if let short = u["url"].string { text = text.replacingOccurrences(of: short, with: u["display_url"].string ?? u["expanded_url"].string ?? "") }
        }
        for m in t["entities"]["media"].array {
            if let short = m["url"].string { text = text.replacingOccurrences(of: short, with: "") }
        }
        text = decodeEntities(text)
        // A reply starts with the handles it answers; the post doesn't show them.
        if t["in_reply_to_screen_name"].exists {
            while text.hasPrefix("@"), let space = text.firstIndex(where: { $0 == " " || $0 == "\n" }) {
                text = String(text[space...]).trimmingCharacters(in: .whitespaces)
            }
        }
        var c = SiteCard(site: "x")
        c.body = nonEmpty(tidy(text))
        let media = t["mediaDetails"][0]
        if media["type"].string == "video" || media["type"].string == "animated_gif" {
            let poster = t["video"]["poster"].string ?? media["media_url_https"].string
            let shot = await image(poster, px: 900)
            c.media = shot?.file
            c.aspect = ratio(t["video"]["aspectRatio"][0].double, t["video"]["aspectRatio"][1].double) ?? shot?.aspect
            c.play = true
            if media["type"].string == "video", let ms = t["video"]["durationMs"].int ?? media["video_info"]["duration_millis"].int {
                c.badge = duration(ms / 1000)
            }
        } else if let photo = t["photos"][0]["url"].string {
            let shot = await image(photo + "?name=small", px: 900)
            c.media = shot?.file
            c.aspect = ratio(t["photos"][0]["width"].double, t["photos"][0]["height"].double) ?? shot?.aspect
        }
        let user = t["user"]
        c.avatar = await image(user["profile_image_url_https"].string?.replacingOccurrences(of: "_normal.", with: "_400x400."), px: 120)?.file
        c.square = user["profile_image_shape"].string == "Square"
        c.name = user["name"].string
        c.handle = user["screen_name"].string
        c.verified = user["is_blue_verified"].bool == true || user["verified"].bool == true
        c.label = user["verified_type"].string?.lowercased()
        c.date = t["created_at"].string.flatMap(isoDate)?.timeIntervalSince1970
        c.count("likes", t["favorite_count"].int)
        c.count("replies", t["conversation_count"].int)
        return c
    }

    private static func fxCard(_ t: J) async -> SiteCard {
        var c = SiteCard(site: "x")
        c.body = nonEmpty(tidy(t["text"].string ?? ""))
        if let v = t["media"]["videos"][0].nonEmpty {
            let shot = await image(v["thumbnail_url"].string, px: 900)
            c.media = shot?.file
            c.aspect = ratio(v["width"].double, v["height"].double) ?? shot?.aspect
            c.play = true
            if let s = v["duration"].double, s > 0 { c.badge = duration(Int(s.rounded())) }
        } else if let p = t["media"]["photos"][0].nonEmpty {
            let shot = await image(p["url"].string.map { $0.replacingOccurrences(of: "?name=orig", with: "") + "?name=small" }, px: 900)
            c.media = shot?.file
            c.aspect = ratio(p["width"].double, p["height"].double) ?? shot?.aspect
        }
        let a = t["author"]
        c.avatar = await image(a["avatar_url"].string?.replacingOccurrences(of: "_normal.", with: "_400x400."), px: 120)?.file
        c.name = a["name"].string
        c.handle = a["screen_name"].string
        c.verified = a["verification"]["verified"].bool
        c.label = a["verification"]["type"].string?.lowercased()
        c.date = t["created_timestamp"].double
        c.count("likes", t["likes"].int)
        c.count("replies", t["replies"].int)
        return c
    }

    /// The token X's embed script sends: (id / 1e15 × π) in base 36, zeros and point removed.
    static func xToken(_ id: String) -> String {
        guard let n = Double(id) else { return "a" }
        return radix36(n / 1e15 * Double.pi).filter { $0 != "0" && $0 != "." }
    }

    /// JavaScript's Number.prototype.toString(36): fraction digits only as far as the
    /// double's own precision, rounded the way V8 rounds them.
    static func radix36(_ value: Double) -> String {
        let chars = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        var integer = value.rounded(.down)
        var fraction = value - integer
        var delta = max(0.5 * (value.nextUp - value), Double.leastNonzeroMagnitude)
        var digits: [Character] = []
        if fraction >= delta {
            repeat {
                fraction *= 36
                delta *= 36
                let d = Int(fraction)
                digits.append(chars[d])
                fraction -= Double(d)
                if fraction > 0.5 || (fraction == 0.5 && d & 1 == 1), fraction + delta > 1 {
                    while true {
                        guard let last = digits.popLast() else { integer += 1; break }
                        let v = chars.firstIndex(of: last) ?? 0
                        if v + 1 < 36 { digits.append(chars[v + 1]); break }
                    }
                    break
                }
            } while fraction >= delta
        }
        var whole: [Character] = []
        repeat {
            let r = Int(integer.truncatingRemainder(dividingBy: 36))
            whole.insert(chars[r], at: 0)
            integer = ((integer - Double(r)) / 36).rounded(.down)
        } while integer > 0
        return String(whole) + (digits.isEmpty ? "" : "." + String(digits))
    }

    // MARK: YouTube

    static func youtube(_ id: String, short: Bool) async throws -> SiteCard {
        let watch = "https://www.youtube.com/watch?v=\(id)"
        let o = try await Net.json("https://www.youtube.com/oembed?format=json&url=" + escape(watch))
        let client: [String: Any] = ["context": ["client": ["clientName": "WEB", "clientVersion": "2.20250101.00.00", "hl": "en", "gl": "US"]],
                                     "videoId": id]
        let player = try? await Net.json("https://www.youtube.com/youtubei/v1/player?prettyPrint=false&fields="
            + "videoDetails(lengthSeconds,viewCount,author,isLive,isUpcoming),microformat(playerMicroformatRenderer(publishDate,isShortsEligible))",
                                         body: client)
        let details = player?["videoDetails"] ?? J(nil)
        guard let title = o["title"].string ?? details["title"].string else { throw Failure.gone }
        let isShort = short || player?["microformat"]["playerMicroformatRenderer"]["isShortsEligible"].bool == true
            || (o["height"].double ?? 0) > (o["width"].double ?? 1)

        var c = SiteCard(site: "youtube", kind: isShort ? "short" : "video")
        c.title = title
        c.play = true
        let shot: Picture? = if isShort {
            await image("https://i.ytimg.com/vi/\(id)/oardefault.jpg", px: 720)
        } else {
            await image("https://i.ytimg.com/vi/\(id)/maxresdefault.jpg", px: 900)
        }
        var frame = shot
        if frame == nil { frame = await image(o["thumbnail_url"].string, px: 900) }
        c.media = frame?.file
        c.aspect = isShort ? 9.0 / 16 : 16.0 / 9
        if details["isLive"].bool == true {
            c.badge = "LIVE"
        } else if let s = details["lengthSeconds"].int, s > 0, !isShort {
            c.badge = duration(s)
        }

        // The channel's photo, from the watch page's own data.
        let next = try? await Net.json("https://www.youtube.com/youtubei/v1/next?prettyPrint=false&fields="
            + "contents(twoColumnWatchNextResults(results(results(contents(videoSecondaryInfoRenderer(owner(videoOwnerRenderer(thumbnail))))))))",
                                       body: client)
        let rows = next?["contents"]["twoColumnWatchNextResults"]["results"]["results"]["contents"].array ?? []
        let owner = rows.map { $0["videoSecondaryInfoRenderer"]["owner"]["videoOwnerRenderer"] }.first { $0.exists }
        if let thumbs = owner?["thumbnail"]["thumbnails"].array, let u = thumbs.last?["url"].string {
            c.avatar = await image(u.hasPrefix("//") ? "https:" + u : u, px: 120)?.file
        }
        c.name = o["author_name"].string ?? details["author"].string
        c.count(details["isLive"].bool == true ? "watching" : "views", details["viewCount"].int)
        c.date = player?["microformat"]["playerMicroformatRenderer"]["publishDate"].string.flatMap(isoDate)?.timeIntervalSince1970
        c.host = "youtube.com"
        return c
    }

    // MARK: TikTok

    static func tiktok(_ url: URL) async throws -> SiteCard {
        // Short links redirect to the post; a photo post's data is on its /video/ page.
        var page = clean(url)
        if let r = page.absoluteString.range(of: "/photo/") { page = URL(string: page.absoluteString.replacingCharacters(in: r, with: "/video/")) ?? page }
        let (html, final) = try await Net.page(page)
        guard final.path().contains("/video/") || final.path().contains("/photo/") else { throw Failure.gone }
        guard let blob = between(html, "<script id=\"__UNIVERSAL_DATA_FOR_REHYDRATION__\" type=\"application/json\">", "</script>"),
              let root = J.parse(blob) ?? J.parse(blob.unicodeScalars.map { $0.value < 0x20 ? " " : String($0) }.joined()) else {
            throw Failure.failed
        }
        let detail = root["__DEFAULT_SCOPE__"]["webapp.video-detail"]
        guard detail.exists else { throw Failure.failed }
        let item = detail["itemInfo"]["itemStruct"]
        guard item.exists else { throw Failure.gone }

        var c = SiteCard(site: "tiktok")
        c.play = true
        let photos = item["imagePost"]["images"].array.count
        let cover = item["video"]["originCover"].string ?? item["video"]["cover"].string
            ?? item["imagePost"]["cover"]["imageURL"]["urlList"][0].string
        let shot = await image(cover, px: 720)
        c.media = shot?.file
        c.aspect = shot?.aspect ?? 9.0 / 16
        if photos > 0 {
            c.play = nil
            c.badge = photos == 1 ? "1 photo" : "\(photos) photos"
        } else if let s = item["video"]["duration"].int, s > 0 {
            c.badge = duration(s)
        }
        let caption = tidy(item["desc"].string ?? "")
        c.body = caption.isEmpty ? nil : caption
        let a = item["author"]
        c.avatar = await image(a["avatarMedium"].string ?? a["avatarThumb"].string, px: 120)?.file
        c.name = a["nickname"].string
        c.handle = a["uniqueId"].string
        c.verified = a["verified"].bool
        let s = item["stats"]
        c.count("likes", s["diggCount"].int)
        c.count("comments", s["commentCount"].int)
        c.count("shares", s["shareCount"].int)
        c.count("views", s["playCount"].int)
        let music = item["music"]
        if let t = music["title"].string.flatMap(nonEmpty) {
            c.detail = [t, music["authorName"].string.flatMap(nonEmpty)].compactMap { $0 }.joined(separator: " - ")
        }
        c.date = item["createTime"].double ?? item["createTime"].string.flatMap(Double.init)
        c.host = "tiktok.com"
        return c
    }

    // MARK: Instagram, Reddit, LinkedIn, Airbnb (what Apple's link previews read from the page)

    static func instagram(_ url: URL) async throws -> SiteCard {
        // The public embed page (as on any blog that embeds the post) has the author, counts and caption.
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let i = parts.firstIndex(where: { ["p", "reel", "reels", "tv"].contains($0) }), i + 1 < parts.count else { throw Failure.gone }
        let code = parts[i + 1]
        let (html, _) = try await Net.page(URL(string: "https://www.instagram.com/p/\(code)/embed/captioned/")!)
        if html.contains("EmbedBrokenMedia") { throw Failure.gone }
        func text(_ s: String?) -> String? {
            guard let s else { return nil }
            let t = decodeEntities(s.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: .regularExpression)
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
            return nonEmpty(t)
        }
        func src(_ s: String?) -> String? {
            s.flatMap { $0.firstMatch(of: /src="([^"]+)"/).map { decodeEntities(String($0.1)) } }
        }
        guard let user = text(between(html, "class=\"UsernameText\">", "<")) else { throw Failure.failed }
        var c = SiteCard(site: "instagram", kind: parts[i] == "p" ? "post" : "reel")
        c.handle = user
        let header = between(html, "class=\"Header\"", "class=\"EmbeddedMedia\"") ?? ""
        c.verified = header.contains("VerifiedSprite")
        c.detail = text(between(header, "class=\"HeaderSecondaryContent", "</div>").map { s in s.drop { $0 != ">" }.dropFirst().description })
        c.avatar = await image(src(between(header, "class=\"Avatar", "</a>")), px: 120)?.file
        if let shot = await image(src(between(html, "<img class=\"EmbeddedMediaImage\"", ">")), px: 900) {
            c.media = shot.file
            c.aspect = shot.aspect
        }
        let proof = text(between(html, "class=\"SocialProof\">", "</div>")) ?? ""
        if let m = proof.firstMatch(of: /([\d,]+) likes?/) { c.count("likes", Int(m.1.replacingOccurrences(of: ",", with: ""))) }
        if var caption = between(html, "class=\"Caption\">", "<div class=\"CaptionComments\"") {
            if let r = caption.range(of: "</a>") { caption = String(caption[r.upperBound...]) }   // the username link
            c.body = text(caption).map { tidy($0) }
        }
        if let m = html.firstMatch(of: /View all ([\d,]+) comments/) { c.count("comments", Int(m.1.replacingOccurrences(of: ",", with: ""))) }
        c.host = "instagram.com"
        return c
    }

    static func reddit(_ url: URL) async throws -> SiteCard {
        let m = try await Preview.fetch(clean(url))
        // "From the <sub> community on Reddit: <title>"
        let summary = m.summary ?? ""
        var sub: String?
        var title = summary
        if let match = summary.firstMatch(of: /^From the (\S+) community on Reddit: (.+)$/.dotMatchesNewlines()) {
            sub = String(match.1)
            title = String(match.2)
        } else if let t = m.title, t != "Reddit" {
            title = t.replacingOccurrences(of: #" : r/\S+$"#, with: "", options: .regularExpression)
        }
        if sub == nil, let i = url.pathComponents.firstIndex(of: "r"), i + 1 < url.pathComponents.count { sub = url.pathComponents[i + 1] }
        guard !title.isEmpty, let sub else { throw Failure.gone }
        var c = SiteCard(site: "reddit")
        c.title = tidy(title)
        if let p = m.image {
            // A wide picture is the post's; a small square one is the community's icon.
            if p.px >= 300 || abs(p.aspect - 1) > 0.05 {
                c.media = p.file
                c.aspect = p.aspect
            } else {
                c.avatar = p.file
            }
        }
        c.handle = sub.hasPrefix("r/") ? String(sub.dropFirst(2)) : sub
        c.host = "reddit.com"
        return c
    }

    static func linkedin(_ url: URL) async throws -> SiteCard {
        let m = try await Preview.fetch(clean(url))
        // "<first line> | <Name> | 171 comments" or "<headline> | <Name> posted on the topic | LinkedIn"
        guard let title = m.title else { throw Failure.gone }
        var parts = title.components(separatedBy: " | ")
        if parts.last == "LinkedIn" { parts.removeLast() }
        guard parts.count >= 2 else { throw Failure.gone }
        var c = SiteCard(site: "linkedin")
        let comments = parts.last.flatMap { $0.hasSuffix(" comments") || $0.hasSuffix(" comment") ? $0 : nil }
        if let comments {
            parts.removeLast()
            c.count("comments", Int(comments.filter(\.isNumber)))
        }
        c.name = parts[parts.count - 1].replacingOccurrences(of: " posted on the topic", with: "")
        var body = tidy(m.summary ?? "")
        if body.isEmpty { body = parts.dropLast().joined(separator: " | ") }
        c.body = body.isEmpty ? nil : body
        if let p = m.image {
            if p.px >= 300 || abs(p.aspect - 1) > 0.05 {
                c.media = p.file
                c.aspect = p.aspect
            } else {
                c.avatar = p.file
            }
        }
        c.host = "linkedin.com"
        return c
    }

    static func airbnb(_ url: URL) async throws -> SiteCard {
        let m = try await Preview.fetch(clean(url))
        // "Rental unit in Culver City · ★4.67 · 2 bedrooms · 6 beds · 2 baths", the listing's name as the summary.
        guard let title = m.title, title.contains(" · ") || !(m.summary ?? "").isEmpty else { throw Failure.gone }
        var bits = title.components(separatedBy: " · ")
        var c = SiteCard(site: "airbnb")
        c.title = bits.removeFirst()
        // "★4.67" (or "★New") sits among the rooms.
        if let i = bits.firstIndex(where: { $0.hasPrefix("★") }) {
            let r = bits.remove(at: i).dropFirst()
            c.rating = Double(r)
            if c.rating == nil { c.label = String(r) }
        }
        c.body = nonEmpty(tidy(m.summary ?? ""))
        c.detail = bits.isEmpty ? nil : bits.joined(separator: " · ")
        if let p = m.image {
            c.media = p.file
            c.aspect = p.aspect
        }
        c.host = "airbnb.com"
        return c
    }

    // MARK: GitHub

    private nonisolated(unsafe) static var githubBackoff = Date.distantPast
    private static let githubLock = NSLock()

    static func github(_ parts: [String], gist: Bool) async throws -> SiteCard {
        let paused = githubLock.withLock { githubBackoff > Date() }
        if paused { throw Failure.failed }
        do {
            return try await githubCard(parts, gist: gist)
        } catch Failure.failed {
            // Unauthenticated calls get 60 an hour; after a refusal, wait it out.
            githubLock.withLock { githubBackoff = Date().addingTimeInterval(15 * 60) }
            throw Failure.failed
        }
    }

    private static func githubCard(_ parts: [String], gist: Bool) async throws -> SiteCard {
        let api = "https://api.github.com"
        func avatar(_ u: J) async -> String? {
            await image(u["avatar_url"].string.map { $0 + ($0.contains("?") ? "&" : "?") + "s=120" }, px: 120)?.file
        }
        if gist {
            let g = try await Net.json("\(api)/gists/\(parts[0])", accept: "application/vnd.github+json")
            let file = g["files"].object?.keys.sorted().first
            var c = SiteCard(site: "github", kind: "gist")
            c.title = file
            c.body = g["description"].string.flatMap(nonEmpty)
            c.label = file.flatMap { g["files"][$0]["language"].string }
            c.color = c.label.flatMap { GitHubColors.language[$0] }
            c.name = g["owner"]["login"].string
            c.avatar = await avatar(g["owner"])
            c.date = g["created_at"].string.flatMap(isoDate)?.timeIntervalSince1970
            c.count("comments", g["comments"].int)
            return c
        }
        let owner = parts[0]
        guard parts.count >= 2 else {
            let u = try await Net.json("\(api)/users/\(owner)", accept: "application/vnd.github+json")
            var c = SiteCard(site: "github", kind: u["type"].string == "Organization" ? "org" : "user")
            c.handle = u["login"].string ?? owner
            c.name = u["name"].string.flatMap(nonEmpty)
            c.body = (u["bio"].string ?? u["description"].string).flatMap(nonEmpty)
            c.avatar = await avatar(u)
            c.square = c.kind == "org"
            c.detail = u["location"].string.flatMap(nonEmpty)
            c.count("followers", u["followers"].int)
            c.count("following", u["following"].int)
            c.count("repos", u["public_repos"].int)
            return c
        }
        let repo = "\(owner)/\(parts[1])"
        let kind = parts.count >= 4 ? parts[2] : ""
        let ref = parts.count >= 4 ? parts[3] : ""
        switch kind {
        case "issues" where Int(ref) != nil, "pull" where Int(ref) != nil:
            let j = try await Net.json("\(api)/repos/\(repo)/\(kind == "pull" ? "pulls" : "issues")/\(ref)", accept: "application/vnd.github+json")
            let isPull = kind == "pull" || j["pull_request"].exists
            var c = SiteCard(site: "github", kind: isPull ? "pull" : "issue")
            c.title = j["title"].string
            c.detail = repo
            c.handle = ref
            if isPull {
                c.label = j["merged"].bool == true || j["merged_at"].string != nil || j["pull_request"]["merged_at"].string != nil ? "merged"
                    : j["state"].string == "closed" ? "closed" : j["draft"].bool == true ? "draft" : "open"
            } else {
                c.label = j["state"].string == "closed" ? (j["state_reason"].string == "not_planned" ? "not_planned" : "closed") : "open"
            }
            c.name = j["user"]["login"].string
            c.avatar = await avatar(j["user"])
            c.date = j["created_at"].string.flatMap(isoDate)?.timeIntervalSince1970
            c.count("comments", (j["comments"].int ?? 0) + (j["review_comments"].int ?? 0))
            c.count("additions", j["additions"].int)
            c.count("deletions", j["deletions"].int)
            return c
        case "commit":
            let j = try await Net.json("\(api)/repos/\(repo)/commits/\(ref)", accept: "application/vnd.github+json")
            var c = SiteCard(site: "github", kind: "commit")
            let message = j["commit"]["message"].string ?? ""
            c.title = message.components(separatedBy: "\n").first
            c.detail = repo
            c.handle = String((j["sha"].string ?? ref).prefix(7))
            c.name = j["author"]["login"].string ?? j["commit"]["author"]["name"].string
            c.avatar = await avatar(j["author"])
            c.date = j["commit"]["author"]["date"].string.flatMap(isoDate)?.timeIntervalSince1970
            c.count("additions", j["stats"]["additions"].int)
            c.count("deletions", j["stats"]["deletions"].int)
            return c
        case "releases" where parts.count >= 5 && parts[3] == "tag":
            let tag = parts[4...].joined(separator: "/")
            let j = try await Net.json("\(api)/repos/\(repo)/releases/tags/\(escape(tag))", accept: "application/vnd.github+json")
            var c = SiteCard(site: "github", kind: "release")
            c.title = j["name"].string.flatMap(nonEmpty) ?? tag
            c.detail = repo
            c.handle = tag
            c.label = j["prerelease"].bool == true ? "Pre-release" : "Latest"
            c.name = j["author"]["login"].string
            c.avatar = await avatar(j["author"])
            c.date = j["published_at"].string.flatMap(isoDate)?.timeIntervalSince1970
            return c
        default:
            let j = try await Net.json("\(api)/repos/\(repo)", accept: "application/vnd.github+json")
            var c = SiteCard(site: "github", kind: "repo")
            c.title = j["full_name"].string ?? repo
            c.body = j["description"].string.flatMap(nonEmpty)
            c.label = j["language"].string
            c.color = c.label.flatMap { GitHubColors.language[$0] }
            c.badge = j["archived"].bool == true ? "Public archive" : j["is_template"].bool == true ? "Public template" : "Public"
            c.detail = j["fork"].bool == true ? j["parent"]["full_name"].string.map { "Forked from \($0)" } : nil
            c.name = j["owner"]["login"].string
            c.avatar = await avatar(j["owner"])
            c.square = j["owner"]["type"].string == "Organization"
            c.count("stars", j["stargazers_count"].int)
            c.count("forks", j["forks_count"].int)
            return c
        }
    }

    // MARK: Spotify

    static func spotifyKind(_ parts: [String]) -> (kind: String, id: String)? {
        let p = parts.first?.hasPrefix("intl-") == true ? Array(parts.dropFirst()) : parts
        guard p.count >= 2, ["track", "album", "playlist", "artist", "episode", "show"].contains(p[0]), p[1].count == 22 else { return nil }
        return (p[0], p[1])
    }

    static func spotify(_ url: URL) async throws -> SiteCard {
        var link = clean(url)
        if link.host() == "spotify.link" { link = try await Net.resolve(link) }
        guard let found = spotifyKind(link.pathComponents.filter { $0 != "/" }) else { throw Failure.gone }
        let (kind, id) = found
        // The embed player's own data: names, artwork, and the colours it paints itself with.
        let (html, _) = try await Net.page(URL(string: "https://open.spotify.com/embed/\(kind)/\(id)")!)
        guard let e = between(html, "<script id=\"__NEXT_DATA__\" type=\"application/json\">", "</script>")
            .flatMap(J.parse)?["props"]["pageProps"]["state"]["data"]["entity"], e.exists else { throw Failure.failed }
        var c = SiteCard(site: "spotify", kind: kind)
        c.title = e["name"].string ?? e["title"].string
        guard c.title != nil else { throw Failure.gone }
        let artists = e["artists"].array.compactMap { $0["name"].string }
        c.name = artists.isEmpty ? e["subtitle"].string : artists.joined(separator: ", ")
        c.label = e["isExplicit"].bool == true ? "E" : nil
        c.date = e["releaseDate"]["isoString"].string.flatMap(isoDate)?.timeIntervalSince1970
        if let ms = e["duration"].int, ms > 0 { c.badge = duration(ms / 1000) }
        let v = e["visualIdentity"]
        func hex(_ j: J) -> String? {
            guard let r = j["red"].int, let g = j["green"].int, let b = j["blue"].int else { return nil }
            return String(format: "%02X%02X%02X", r, g, b)
        }
        let colors = [hex(v["backgroundBase"]), hex(v["backgroundTintedBase"]), hex(v["textSubdued"])]
        if colors.allSatisfy({ $0 != nil }) { c.palette = colors.compactMap { $0 } }
        let pictures = v["image"].array.isEmpty ? e["coverArt"]["sources"].array : v["image"].array
        let picture = pictures.max { ($0["maxWidth"].int ?? $0["width"].int ?? 0) < ($1["maxWidth"].int ?? $1["width"].int ?? 0) }?["url"].string
        c.avatar = await image(picture, px: 640)?.file
        // An album, playlist or artist lists its first tracks beside the cover.
        let tracks = e["trackList"].array.prefix(3).compactMap { t -> String? in
            guard let name = t["title"].string else { return nil }
            return [name, t["subtitle"].string ?? "", t["isExplicit"].bool == true ? "E" : ""].joined(separator: "\t")
        }
        if !tracks.isEmpty { c.body = tracks.joined(separator: "\n") }
        c.count("tracks", e["trackList"].array.isEmpty ? nil : e["trackList"].array.count)
        c.host = "spotify.com"
        return c
    }

    // MARK: Apple Music, Podcasts, App Store

    static func apple(_ url: URL) async throws -> SiteCard {
        let parts = url.pathComponents.filter { $0 != "/" }
        let cc = parts.first.flatMap { $0.count == 2 && $0.allSatisfy(\.isLetter) ? $0.lowercased() : nil } ?? "us"
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let item = query.first { $0.name == "i" }?.value
        let lastID = parts.last.map { $0.hasPrefix("id") ? String($0.dropFirst(2)) : $0 }
        let host = url.host() ?? ""
        let isPodcast = host.hasPrefix("podcasts."), isApp = host.hasPrefix("apps.")
        let kind = parts.first { ["album", "song", "music-video", "artist", "playlist", "podcast", "app"].contains($0) } ?? ""

        func lookup(_ id: String, _ extra: String = "") async throws -> [J] {
            try await Net.json("https://itunes.apple.com/lookup?id=\(id)&country=\(cc)\(extra)")["results"].array
        }
        func square(_ art: String?, _ suffix: String = "600x600bb.jpg") -> String? {
            guard let art, let slash = art.lastIndex(of: "/") else { return art }
            return String(art[...slash]) + suffix
        }

        if isApp, let id = lastID, let a = try await lookup(id).first {
            var c = SiteCard(site: "appstore", kind: "app")
            c.title = a["trackName"].string
            c.name = a["artistName"].string ?? a["sellerName"].string
            c.detail = a["primaryGenreName"].string
            c.price = a["formattedPrice"].string
            if let r = a["averageUserRating"].double, r > 0, let n = a["userRatingCount"].int, n > 0 {
                c.rating = r
                c.count("ratings", n)
            }
            let icon = await image(square(a["artworkUrl512"].string ?? a["artworkUrl100"].string, "512x512bb.png"), px: 256)
            c.avatar = icon?.file
            c.palette = icon.flatMap { edgeColor($0.file) }.map { [$0] }
            c.host = "apps.apple.com"
            return c
        }
        if isPodcast, let show = lastID {
            if let ep = item {
                let rows = (try? await lookup(show, "&entity=podcastEpisode&limit=200")) ?? []
                if let e = rows.first(where: { $0["trackId"].int.map(String.init) == ep }) {
                    var c = SiteCard(site: "podcasts", kind: "episode")
                    c.title = e["trackName"].string
                    c.name = e["collectionName"].string
                    c.date = e["releaseDate"].string.flatMap(isoDate)?.timeIntervalSince1970
                    if let ms = e["trackTimeMillis"].int, ms > 0 {
                        let m = ms / 60000
                        c.badge = m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(max(1, m))m"
                    }
                    let art = await image(square(e["artworkUrl600"].string ?? rows.first?["artworkUrl600"].string, "1000x1000bb.jpg"), px: 640)
                    c.avatar = art?.file
                    c.palette = art.flatMap { edgeColor($0.file) }.map { [$0] }
                    c.host = "podcasts.apple.com"
                    return c
                }
                return try await appleFromPage(url, site: "podcasts", kind: "episode", square: "1000x1000bb.jpg")
            }
            guard let s = try await lookup(show).first else { throw Failure.gone }
            var c = SiteCard(site: "podcasts", kind: "show")
            c.title = s["collectionName"].string
            c.name = s["artistName"].string
            c.detail = s["primaryGenreName"].string
            let art = await image(square(s["artworkUrl600"].string, "1000x1000bb.jpg"), px: 640)
            c.avatar = art?.file
            c.palette = art.flatMap { edgeColor($0.file) }.map { [$0] }
            c.host = "podcasts.apple.com"
            return c
        }
        switch kind {
        case "playlist", "artist":
            return try await appleFromPage(url, site: "applemusic", kind: kind, square: "1000x1000cc.jpg")
        default:
            guard let id = item ?? lastID, let r = try await lookup(id).first else { throw Failure.gone }
            let year = r["releaseDate"].string.map { String($0.prefix(4)) }
            var c = SiteCard(site: "applemusic")
            if r["wrapperType"].string == "collection" {
                c.kind = "album"
                c.title = r["collectionName"].string
                c.name = r["artistName"].string
                c.detail = ["Album", year, r["trackCount"].int.map { count($0, "Song", "Songs") }].compactMap { $0 }.joined(separator: " · ")
                c.label = r["collectionExplicitness"].string == "explicit" ? "E" : nil
            } else {
                let isVideo = r["kind"].string == "music-video"
                c.kind = isVideo ? "music-video" : "song"
                c.title = r["trackName"].string
                c.name = r["artistName"].string
                c.detail = [isVideo ? "Music Video" : "Song", year, r["trackTimeMillis"].int.map { duration($0 / 1000) }].compactMap { $0 }.joined(separator: " · ")
                c.label = r["trackExplicitness"].string == "explicit" ? "E" : nil
            }
            c.avatar = await image(square(r["artworkUrl100"].string, r["kind"].string == "music-video" ? "1000x1000cc.jpg" : "1000x1000bb.jpg"), px: 640)?.file
            c.host = "music.apple.com"
            return c
        }
    }

    /// Playlists, artists and older episodes aren't in the lookup API; their pages say enough.
    private static func appleFromPage(_ url: URL, site: String, kind: String, square: String) async throws -> SiteCard {
        let (html, _) = try await Net.page(clean(url), until: "</head>")
        let meta = Meta(html)
        guard var title = meta["og:title"] else { throw Failure.gone }
        for suffix in [" on Apple Music", " on Apple Podcasts", " - Apple Music"] where title.hasSuffix(suffix) {
            title = String(title.dropLast(suffix.count))
        }
        var c = SiteCard(site: site, kind: kind)
        c.title = title
        var desc = (meta["og:description"] ?? "").components(separatedBy: " · ")
        // "Podcast Episode · The Daily · November 11 · 48m"; "Playlist · 50 Songs"
        if desc.first == "Podcast Episode", desc.count >= 2 {
            c.name = desc[1]
            if let last = desc.last, last.last == "m" || last.last == "h" { c.badge = last }
            desc = []
        }
        c.detail = desc.count > 1 || (desc.first?.count ?? 0) < 40 ? nonEmpty(desc.joined(separator: " · ")) : nil
        if var art = meta["og:image"], let slash = art.lastIndex(of: "/") {
            if let q = art.firstIndex(of: "?") { art = String(art[..<q]) }
            let pic = await image(String(art[...slash]) + square, px: 640)
            c.avatar = pic?.file
            if site == "podcasts" { c.palette = pic.flatMap { edgeColor($0.file) }.map { [$0] } }
        }
        c.host = displayHost(url)
        return c
    }

    /// The colour around a picture's edge, as hex: what Apple tints a podcast's or app's card with.
    static func edgeColor(_ file: String) -> String? {
        guard let path = path(file), let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let n = 16
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: n, height: n))
        var sum = [0, 0, 0], k = 0
        for y in 0..<n { for x in 0..<n where x < 2 || y < 2 || x >= n - 2 || y >= n - 2 {
            let i = (y * n + x) * 4
            sum[0] += Int(px[i]); sum[1] += Int(px[i + 1]); sum[2] += Int(px[i + 2]); k += 1
        } }
        guard k > 0 else { return nil }
        return String(format: "%02X%02X%02X", sum[0] / k, sum[1] / k, sum[2] / k)
    }

    // MARK: Bluesky

    static func bluesky(_ actor: String, _ rkey: String) async throws -> SiteCard {
        let uri = "at://\(actor)/app.bsky.feed.post/\(rkey)"
        let j = try await Net.json("https://public.api.bsky.app/xrpc/app.bsky.feed.getPostThread?depth=0&parentHeight=0&uri=" + escape(uri))
        let post = j["thread"]["post"]
        guard post.exists else { throw Failure.gone }
        var c = SiteCard(site: "bluesky")
        c.body = nonEmpty(tidy(post["record"]["text"].string ?? ""))
        var embed = post["embed"]
        if embed["$type"].string == "app.bsky.embed.recordWithMedia#view" { embed = embed["media"] }
        switch embed["$type"].string {
        case "app.bsky.embed.images#view":
            let first = embed["images"][0]
            let shot = await image(first["fullsize"].string ?? first["thumb"].string, px: 900)
            c.media = shot?.file
            c.aspect = ratio(first["aspectRatio"]["width"].double, first["aspectRatio"]["height"].double) ?? shot?.aspect
        case "app.bsky.embed.video#view":
            let shot = await image(embed["thumbnail"].string, px: 900)
            c.media = shot?.file
            c.aspect = ratio(embed["aspectRatio"]["width"].double, embed["aspectRatio"]["height"].double) ?? shot?.aspect
            c.play = true
        case "app.bsky.embed.gallery#view":
            let first = embed["items"][0]
            let shot = await image(first["fullsize"].string ?? first["thumbnail"].string, px: 900)
            c.media = shot?.file
            c.aspect = shot?.aspect
        default:
            break
        }
        let a = post["author"]
        let handle = a["handle"].string ?? actor
        c.avatar = await image(a["avatar"].string, px: 120)?.file
        c.name = a["displayName"].string.flatMap(nonEmpty) ?? handle
        c.handle = handle
        // Verified accounts, and the verifiers themselves (Bluesky badges both).
        c.verified = a["verification"]["verifiedStatus"].string == "valid" || a["verification"]["trustedVerifierStatus"].string == "valid"
        c.count("likes", post["likeCount"].int)
        c.count("replies", post["replyCount"].int)
        c.count("reposts", post["repostCount"].int)
        c.date = (post["indexedAt"].string ?? post["record"]["createdAt"].string).flatMap(isoDate)?.timeIntervalSince1970
        c.host = "bsky.app"
        return c
    }

    // MARK: Wikipedia

    static func wikipedia(_ lang: String, _ title: String) async throws -> SiteCard {
        let encoded = escapePath(title)
        let j = try await Net.json("https://\(lang).wikipedia.org/api/rest_v1/page/summary/\(encoded)")
        guard j["type"].string == "standard", let name = j["titles"]["normalized"].string ?? j["title"].string else { throw Failure.gone }
        var c = SiteCard(site: "wikipedia")
        c.body = nonEmpty(tidy(j["extract"].string ?? ""))
        // Page Previews put a landscape picture on top and a tall or square one at the side.
        // Wikimedia serves thumbnails in set widths; 960 is enough for the bubble at 2x.
        let thumb = j["thumbnail"]["source"].string
        var shot = await image(thumb.map { $0.replacingOccurrences(of: #"/\d+px-"#, with: "/960px-", options: .regularExpression) }, px: 1000)
        if shot == nil { shot = await image(thumb, px: 1000) }
        c.media = shot?.file
        c.aspect = ratio(j["originalimage"]["width"].double, j["originalimage"]["height"].double) ?? shot?.aspect
        c.title = name
        c.detail = j["description"].string.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        c.host = "\(lang).wikipedia.org"
        return c
    }

    // MARK: Hacker News

    static func hackerNews(_ id: Int) async throws -> SiteCard {
        let j = try await Net.json("https://hacker-news.firebaseio.com/v0/item/\(id).json")
        guard j.exists, j["deleted"].bool != true, j["dead"].bool != true else { throw Failure.gone }
        let by = j["by"].string ?? ""
        var c = SiteCard(site: "hackernews", kind: j["type"].string == "comment" ? "comment" : "story")
        c.name = nonEmpty(by)
        c.date = j["time"].double
        c.body = j["text"].string.map { nonEmpty(tidy(htmlText($0))) } ?? nil
        c.host = "news.ycombinator.com"
        if c.kind == "comment" { return c }
        c.title = j["title"].string
        // HN shows the host without "www.", and GitHub's with the account after it.
        if let u = j["url"].string.flatMap(URL.init(string:)) {
            var site = displayHost(u)
            if site == "github.com", let account = u.pathComponents.dropFirst().first { site += "/" + account }
            c.detail = site
        }
        c.count("points", j["score"].int)
        c.count("comments", j["descendants"].int ?? 0)
        return c
    }

    // MARK: Google Maps

    static func maps(_ url: URL) async throws -> SiteCard {
        var link = url
        let host = displayHost(url)
        if host == "maps.app.goo.gl" || host == "share.google" || host == "goo.gl" {
            link = try await Net.resolve(url)
        }
        guard let lh = link.host()?.lowercased(), lh.contains("google."), link.path().hasPrefix("/maps") || lh.hasPrefix("maps.") else {
            throw Failure.gone
        }
        let s = link.absoluteString.removingPercentEncoding ?? link.absoluteString
        let comps = link.pathComponents
        var name: String?
        if let i = comps.firstIndex(of: "place"), i + 1 < comps.count {
            name = comps[i + 1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        }
        let q = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" || $0.name == "query" }?.value
        var coordinate: CLLocationCoordinate2D?
        if let m = s.firstMatch(of: /!3d(-?\d+\.\d+)!4d(-?\d+\.\d+)/), let la = Double(m.1), let lo = Double(m.2) {
            coordinate = CLLocationCoordinate2D(latitude: la, longitude: lo)
        } else if let q, let m = q.firstMatch(of: /^(-?\d+\.\d+),\s*(-?\d+\.\d+)$/), let la = Double(m.1), let lo = Double(m.2) {
            coordinate = CLLocationCoordinate2D(latitude: la, longitude: lo)
        } else if let m = s.firstMatch(of: /@(-?\d+\.\d+),(-?\d+\.\d+)/), let la = Double(m.1), let lo = Double(m.2) {
            coordinate = CLLocationCoordinate2D(latitude: la, longitude: lo)
        }
        var address: String?
        if name == nil, let q, coordinate == nil || !q.contains(",") || q.first?.isLetter == true {
            let bits = q.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            name = bits.first
            address = bits.count > 1 ? bits.dropFirst().joined(separator: ", ") : nil
        }
        if coordinate == nil, let lookFor = q ?? name {
            coordinate = await MapsLookup.find(lookFor)
        }
        guard let coordinate else { throw Failure.gone }
        if address == nil { address = await MapsLookup.address(coordinate) }
        let shots = await MapsLookup.snapshots(coordinate)
        var c = SiteCard(site: "maps")
        c.media = shots.light
        c.mediaDark = shots.dark
        c.aspect = MapsLookup.aspect
        c.title = name ?? address ?? "Dropped pin"
        c.detail = name == nil ? nil : address
        c.host = "maps.google.com"
        return c
    }

    // MARK: helpers

    /// Without tracking or share parameters (igsh, utm_*, si): only the page itself is asked for.
    static func clean(_ url: URL) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.query = nil
        c.fragment = nil
        return c.url ?? url
    }

    static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s
    }

    static func escapePath(_ s: String) -> String {
        s.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~()!*'_,"))) ?? s
    }

    static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func ratio(_ w: Double?, _ h: Double?) -> Double? {
        guard let w, let h, w > 0, h > 0 else { return nil }
        return w / h
    }

    /// Trimmed, no runs of blank lines, and at most 1,200 characters.
    static func tidy(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        if t.count > 1200 { t = String(t.prefix(1200)).trimmingCharacters(in: .whitespacesAndNewlines) + "…" }
        return t
    }

    static func between(_ s: String, _ start: String, _ end: String) -> String? {
        guard let a = s.range(of: start), let b = s.range(of: end, range: a.upperBound..<s.endIndex) else { return nil }
        return String(s[a.upperBound..<b.lowerBound])
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var t = s
        for (k, v) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&#x2F;", "/"), ("&nbsp;", " ")] {
            t = t.replacingOccurrences(of: k, with: v)
        }
        t = t.replacing(/&#(\d+);/) { m in Int(m.1).flatMap(UnicodeScalar.init).map { String(Character($0)) } ?? "" }
        t = t.replacing(/&#x([0-9a-fA-F]+);/) { m in Int(m.1, radix: 16).flatMap(UnicodeScalar.init).map { String(Character($0)) } ?? "" }
        return t.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// HTML from a comment or post body as plain text: paragraphs become blank lines.
    static func htmlText(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<p>", with: "\n\n").replacingOccurrences(of: "<br>", with: "\n")
        t = t.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return decodeEntities(t)
    }

    static func isoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withFullDate]
        return f.date(from: String(s.prefix(10)))
    }

    static func mediumDate(_ d: Date) -> String {
        d.formatted(.dateTime.month(.abbreviated).day().year())
    }

    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = seconds / 60 % 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// 54 → "54", 55,849 → "55.8K", 1,836,242,788 → "1.8B": rounded down, so never one place too many.
    static func compact(_ n: Int) -> String {
        func short(_ v: Double, _ unit: String) -> String {
            if v >= 100 { return "\(Int(v))\(unit)" }
            let t = (v * 10).rounded(.down) / 10
            return (t == t.rounded() ? "\(Int(t))" : String(format: "%.1f", t)) + unit
        }
        switch n {
        case ..<1000: return "\(n)"
        case ..<1_000_000: return short(Double(n) / 1e3, "K")
        case ..<1_000_000_000: return short(Double(n) / 1e6, "M")
        default: return short(Double(n) / 1e9, "B")
        }
    }

    static func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(compact(n)) \(n == 1 ? one : many)"
    }

    /// "55.8K likes · 54 replies", leaving out what the site didn't say.
    static func counts(_ items: [(Int?, String, String)]) -> String? {
        let bits = items.compactMap { n, one, many in n.map { count($0, one, many) } }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    // MARK: images

    struct Picture: Sendable {
        let file: String
        let aspect: Double
        /// The longest side, in pixels.
        let px: Int
    }

    /// Downloads a picture and keeps it downsampled to `px` in `dir`, named for its address.
    static func image(_ address: String?, px: Int) async -> Picture? {
        guard let address, let url = URL(string: address), url.scheme?.hasPrefix("http") == true else { return nil }
        let name = Insecure.SHA1.hash(data: Data("\(address)#\(px)".utf8)).map { String(format: "%02x", $0) }.joined()
        if let p = existing(name) { return p }
        guard let (data, response) = try? await Net.session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: px,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        // YouTube answers a missing frame size with a 120×90 grey placeholder.
        if cg.width <= 120 && cg.height <= 90 && px > 200 { return nil }
        return save(cg, name: name)
    }

    static func save(_ cg: CGImage, name: String) -> Picture? {
        let alpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(cg.alphaInfo)
        let file = name + (alpha ? ".png" : ".jpg")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(file)
        guard let out = CGImageDestinationCreateWithURL(dest as CFURL, (alpha ? UTType.png : UTType.jpeg).identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(out, cg, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(out) else { return nil }
        return Picture(file: file, aspect: Double(cg.width) / Double(max(cg.height, 1)), px: max(cg.width, cg.height))
    }

    private static func existing(_ name: String) -> Picture? {
        for ext in [".jpg", ".png"] {
            let u = dir.appendingPathComponent(name + ext)
            guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { continue }
            return Picture(file: name + ext, aspect: Double(w) / Double(max(h, 1)), px: max(w, h))
        }
        return nil
    }
}

// MARK: - network

nonisolated enum Net {
    /// No cookies, no cache: every site sees a plain request with the system's own user agent.
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 25
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCache = nil
        c.httpAdditionalHeaders = ["Accept-Language": "en"]
        return URLSession(configuration: c)
    }()

    private static func check(_ response: URLResponse) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 || code == 410 || code == 400 || code == 401 { throw Sites.Failure.gone }
        guard (200..<300).contains(code) else { throw Sites.Failure.failed }
    }

    static func json(_ address: String, body: [String: Any]? = nil, accept: String? = nil) async throws -> J {
        guard let url = URL(string: address) else { throw Sites.Failure.failed }
        var r = URLRequest(url: url)
        if let accept { r.setValue(accept, forHTTPHeaderField: "Accept") }
        if let body {
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: r) } catch { throw Sites.Failure.failed }
        try check(response)
        guard let j = J.parse(data) else { throw Sites.Failure.failed }
        return j
    }

    /// A page's text and where it ended up after redirects; with `until`, only up to that
    /// marker (the head, where the meta tags are), so big pages aren't read whole.
    static func page(_ url: URL, until marker: String? = nil, limit: Int = 3_000_000) async throws -> (String, URL) {
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do { (bytes, response) = try await session.bytes(from: url) } catch { throw Sites.Failure.failed }
        try check(response)
        var data = Data()
        let tail = marker.map { Data($0.utf8) }
        do {
            for try await b in bytes {
                data.append(b)
                if data.count >= limit { break }
                if let tail, b == tail.last, data.count >= tail.count, data.suffix(tail.count) == tail { break }
            }
        } catch {
            if data.isEmpty { throw Sites.Failure.failed }
        }
        return (String(decoding: data, as: UTF8.self), response.url ?? url)
    }

    /// Where a short link leads, without reading the page.
    static func resolve(_ url: URL) async throws -> URL {
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do { (bytes, response) = try await session.bytes(from: url) } catch { throw Sites.Failure.failed }
        bytes.task.cancel()
        try check(response)
        return response.url ?? url
    }
}

/// A light reader for JSON whose shape we only partly know: every step may be missing.
nonisolated struct J {
    let value: Any?
    init(_ v: Any?) { value = v is NSNull ? nil : v }

    static func parse(_ data: Data) -> J? {
        (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])).map(J.init)
    }
    static func parse(_ s: String) -> J? { parse(Data(s.utf8)) }

    subscript(_ key: String) -> J { J((value as? [String: Any])?[key]) }
    subscript(_ i: Int) -> J {
        guard let a = value as? [Any], i >= 0, i < a.count else { return J(nil) }
        return J(a[i])
    }
    var exists: Bool { value != nil }
    var nonEmpty: J? {
        if let d = value as? [String: Any], !d.isEmpty { return self }
        return nil
    }
    var object: [String: Any]? { value as? [String: Any] }
    var array: [J] { (value as? [Any])?.map(J.init) ?? [] }
    var string: String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.stringValue }
        return nil
    }
    var int: Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) ?? Double(s).map { Int($0) } }
        return nil
    }
    var double: Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        return (value as? String).flatMap(Double.init)
    }
    var bool: Bool? { (value as? NSNumber)?.boolValue }
}

/// A page's <meta property|name="…" content="…"> tags.
nonisolated struct Meta {
    private var tags: [String: String] = [:]

    init(_ html: String) {
        for m in html.matches(of: #/<meta\s+([^>]+?)\/?>/#) {
            let attrs = String(m.1)
            guard let key = Self.attr(attrs, "property") ?? Self.attr(attrs, "name") ?? Self.attr(attrs, "itemprop"),
                  let content = Self.attr(attrs, "content"), tags[key] == nil else { continue }
            tags[key] = Sites.decodeEntities(content)
        }
    }

    subscript(_ key: String) -> String? { tags[key] }

    private static func attr(_ s: String, _ name: String) -> String? {
        let pattern = "\(name)\\s*=\\s*\"([^\"]*)\""
        guard let r = s.range(of: pattern, options: .regularExpression) else { return nil }
        let m = String(s[r])
        guard let q = m.firstIndex(of: "\"") else { return nil }
        return String(m[m.index(after: q)..<m.index(before: m.endIndex)])
    }
}

/// Apple's link previews (the composer's method): the page's title, its description and
/// its picture, for sites whose data is only on the page.
nonisolated enum Preview {
    struct Result: Sendable {
        var title: String?
        var summary: String?
        var image: Sites.Picture?
    }

    static func fetch(_ url: URL) async throws -> Result {
        let box: UncheckedBox<LPLinkMetadata> = try await withCheckedThrowingContinuation { cont in
            Task { @MainActor in
                let p = LPMetadataProvider()
                p.timeout = 10
                p.startFetchingMetadata(for: url) { m, e in
                    if let m { cont.resume(returning: UncheckedBox(value: m)) } else { cont.resume(throwing: e == nil ? Sites.Failure.gone : Sites.Failure.failed) }
                }
            }
        }
        let meta = box.value
        var r = Result(title: meta.title)
        // The description isn't public API on LPLinkMetadata; read it only where it's there.
        if meta.responds(to: NSSelectorFromString("summary")) { r.summary = meta.value(forKey: "summary") as? String }
        if let ip = meta.imageProvider, ip.canLoadObject(ofClass: NSImage.self) {
            let box: UncheckedBox<NSImage?> = await withCheckedContinuation { cont in
                _ = ip.loadObject(ofClass: NSImage.self) { obj, _ in cont.resume(returning: UncheckedBox(value: obj as? NSImage)) }
            }
            if let img = box.value, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let name = Insecure.SHA1.hash(data: Data("lp:\(url.absoluteString)".utf8)).map { String(format: "%02x", $0) }.joined()
                r.image = Sites.save(Self.downsample(cg, px: 900), name: name)
            }
        }
        return r
    }

    private static func downsample(_ cg: CGImage, px: Int) -> CGImage {
        let s = min(1, CGFloat(px) / CGFloat(max(cg.width, cg.height)))
        guard s < 1 else { return cg }
        let w = Int(CGFloat(cg.width) * s), h = Int(CGFloat(cg.height) * s)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return cg }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? cg
    }
}

/// Map pictures and place lookups for Google Maps links, drawn by MapKit on this Mac.
nonisolated enum MapsLookup {
    static let aspect = 2.0
    private static let size = CGSize(width: 300, height: 150)

    static func find(_ query: String) async -> CLLocationCoordinate2D? {
        await withCheckedContinuation { cont in
            Task { @MainActor in
                let r = MKLocalSearch.Request()
                r.naturalLanguageQuery = query
                let search = MKLocalSearch(request: r)
                search.start { res, _ in
                    _ = search
                    cont.resume(returning: res?.mapItems.first?.location.coordinate)
                }
            }
        }
    }

    static func address(_ c: CLLocationCoordinate2D) async -> String? {
        await withCheckedContinuation { cont in
            Task { @MainActor in
                guard let req = MKReverseGeocodingRequest(location: CLLocation(latitude: c.latitude, longitude: c.longitude)) else {
                    return cont.resume(returning: nil)
                }
                req.getMapItems { items, _ in
                    _ = req   // kept alive until it answers
                    let item = items?.first
                    cont.resume(returning: item?.address?.shortAddress ?? item?.addressRepresentations?.cityWithContext)
                }
            }
        }
    }

    /// The place with a pin, once for light mode and once for dark.
    static func snapshots(_ c: CLLocationCoordinate2D) async -> (light: String?, dark: String?) {
        let key = String(format: "map-google-pin:%.6f,%.6f", c.latitude, c.longitude)
        let name = Insecure.SHA1.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        async let light = snapshot(c, dark: false, name: name + "-l")
        async let dark = snapshot(c, dark: true, name: name + "-d")
        return await (light, dark)
    }

    private static func snapshot(_ c: CLLocationCoordinate2D, dark: Bool, name: String) async -> String? {
        let box: UncheckedBox<CGImage?> = await withCheckedContinuation { cont in
            Task { @MainActor in
                let o = MKMapSnapshotter.Options()
                o.region = MKCoordinateRegion(center: c, latitudinalMeters: 700, longitudinalMeters: 1400)
                o.size = size
                o.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                o.pointOfInterestFilter = .includingAll
                let snapshotter = MKMapSnapshotter(options: o)
                snapshotter.start { snap, _ in
                    _ = snapshotter   // kept alive until it answers
                    cont.resume(returning: UncheckedBox(value: snap.flatMap { Self.render($0, pin: c) }))
                }
            }
        }
        guard let cg = box.value else { return nil }
        return Sites.save(cg, name: name)?.file
    }

    /// The map with its pin, drawn into a bitmap here on the main thread, where MapKit
    /// hands the snapshot over (drawing it later, off the main thread, traps).
    @MainActor private static func render(_ snap: MKMapSnapshotter.Snapshot, pin c: CLLocationCoordinate2D) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.scaleBy(x: 2, y: 2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        snap.image.draw(in: CGRect(origin: .zero, size: size))
        let p = snap.point(for: c)
        pin(at: CGPoint(x: p.x, y: size.height - p.y))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// Google Maps' red pin (from Google's own marker), its point on the place.
    @MainActor private static func pin(at p: CGPoint) {
        guard let img = SiteArt.image("maps-pin") else { return }
        img.draw(in: CGRect(x: p.x - 13, y: p.y, width: 26, height: 37))
    }
}

/// GitHub's language colours (github-linguist's languages.yml), for a repository's dot.
nonisolated enum GitHubColors {
    static let language: [String: String] = [
        "JavaScript": "f1e05a", "TypeScript": "3178c6", "Python": "3572A5", "Swift": "F05138", "Go": "00ADD8",
        "Rust": "dea584", "C": "555555", "C++": "f34b7d", "C#": "7355dd", "Java": "b07219", "Kotlin": "A97BFF",
        "Ruby": "701516", "PHP": "4F5D95", "Shell": "89e051", "HTML": "e34c26", "CSS": "663399", "Objective-C": "438eff",
        "Dart": "00B4AB", "Lua": "000080", "Zig": "ec915c", "Vue": "41b883", "Svelte": "ff3e00",
        "Jupyter Notebook": "DA5B0B", "Scala": "c22d40", "Elixir": "8847B9",
    ]
}
