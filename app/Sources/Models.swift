import Foundation

/// Mirrors the K* constants in core/db.go.
enum MessageKind: Int, Sendable {
    case text, image, video, audio, voice, document, sticker, location, contact, poll, revoked, unsupported, pending
    case notice   // a system line, e.g. "security code changed"
    case event

    var isVisual: Bool { self == .image || self == .video || self == .sticker }

    var label: String {
        switch self {
        case .image: "Photo"
        case .video: "Video"
        case .audio: "Audio"
        case .voice: "Voice message"
        case .document: "Document"
        case .sticker: "Sticker"
        case .location: "Location"
        case .contact: "Contact"
        case .poll: "Poll"
        case .event: "Event"
        case .revoked: "This message was deleted"
        case .pending: "Waiting for this message"
        case .text, .unsupported, .notice: ""
        }
    }

    var symbol: String? {
        switch self {
        case .image: "camera.fill"
        case .video: "video.fill"
        case .audio: "headphones"
        case .voice: "mic.fill"
        case .document: "doc.fill"
        case .sticker: "face.smiling"
        case .location: "mappin.and.ellipse"
        case .contact: "person.crop.circle"
        case .poll: "chart.bar.fill"
        case .event: "calendar"
        case .revoked: "nosign"
        case .pending: "clock"
        default: nil
        }
    }
}

/// Mirrors St* in core/db.go.
enum MessageStatus {
    static let failed = -1, pending = 0, sent = 1, delivered = 2, read = 3, played = 4
}

struct Chat: Sendable, Equatable {
    struct Last: Sendable, Equatable {
        let kind: MessageKind
        let text: String
        let fromMe: Bool
        let status: Int
        let fileName: String
        let senderName: String
    }

    let jid: String
    let name: String
    let isGroup: Bool
    let lastTS: Int64
    let unread: Int
    let markedUnread: Bool
    let pinned: Bool
    let archived: Bool
    let mutedUntil: Int64
    let avatar: String
    let last: Last?
    /// Disappearing-message timer in seconds (0 = off).
    var ephemeral = 0
    /// "Advanced chat privacy".
    var limitSharing = false
    var favorite = false

    var isMuted: Bool { mutedUntil == -1 || mutedUntil > Int64(Date().timeIntervalSince1970) }
    var hasUnread: Bool { unread > 0 || markedUnread }
}

struct Reactions: Sendable, Equatable {
    let emoji: String   // up to 3 distinct, most popular first
    let total: Int
    let mine: String

    init?(_ s: String) {
        guard !s.isEmpty else { return nil }
        let p = s.split(separator: "\t", omittingEmptySubsequences: false)
        guard p.count >= 2, let n = Int(p[1]), n > 0 else { return nil }
        emoji = String(p[0])
        total = n
        mine = p.count > 2 ? String(p[2]) : ""
    }
}

struct Message: Sendable, Equatable {
    let rowid: Int64
    let id: String
    let sender: String
    let senderName: String
    let fromMe: Bool
    let ts: Int64          // unix ms
    let kind: MessageKind
    let text: String
    let status: Int
    let edited: Bool
    let quoteID: String
    let quoteSender: String
    let quoteSenderName: String
    let quoteText: String
    let quoteKind: MessageKind
    let reactions: Reactions?
    let mime: String
    let fileName: String
    let fileSize: Int64
    let seconds: Int
    let width: Int
    let height: Int
    let thumb: Data?
    let mediaPath: String
    let hasMedia: Bool
    let waveform: Data?
    let linkURL: String
    let linkTitle: String
    let linkDesc: String
    var starred = false
    /// Kind-specific JSON from the core: poll options, event details, contact cards.
    var extra = ""
    /// Poll votes or event responses, one per person.
    var votes: [Vote] = []

    var hasLinkPreview: Bool { kind == .text && !linkTitle.isEmpty }

    var date: Date { Date(timeIntervalSince1970: TimeInterval(ts) / 1000) }
    var isQuoteFromMe: Bool { !quoteSender.isEmpty && quoteSender == Core.shared.me }
}

/// One person's current poll vote or event response.
struct Vote: Sendable, Equatable {
    let voter: String
    let name: String
    /// Polls: the options picked. Events: going / not_going / maybe.
    let options: [String]
    let response: String
    let guests: Int
    let ts: Int64
    var isMine: Bool { voter == Core.shared.me }
}

enum JID {
    static func user(_ jid: String) -> String {
        String(jid.split(separator: "@").first ?? "")
    }

    static func isGroup(_ jid: String) -> Bool { jid.hasSuffix("@g.us") }

    /// "+15551234567" for phone JIDs; LIDs (no phone known yet) get a neutral label.
    static func phone(_ jid: String) -> String {
        if jid.hasSuffix("@lid") { return "Unknown" }
        let u = user(jid)
        return u.isEmpty ? "" : "+" + u
    }
}
