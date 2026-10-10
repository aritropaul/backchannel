import AppKit

/// Dev only (WA_CARDS): sample poll, event and contact bubbles drawn to images, for
/// checking their layout without sending anything.
enum DevCards {
    private static func message(_ id: String, kind: MessageKind, fromMe: Bool, text: String, extra: String, votes: [Vote] = []) -> Message {
        var m = Message(rowid: 0, id: id, sender: fromMe ? Core.shared.me : "15550001111@s.whatsapp.net", senderName: "Sam Rivera",
                        fromMe: fromMe, ts: Int64(Date().timeIntervalSince1970 * 1000), kind: kind, text: text, status: 3,
                        edited: false, quoteID: "", quoteSender: "", quoteSenderName: "", quoteText: "", quoteKind: .text,
                        reactions: nil, mime: "", fileName: "", fileSize: 0, seconds: 0, width: 0, height: 0, thumb: nil,
                        mediaPath: "", hasMedia: false, waveform: nil, linkURL: "", linkTitle: "", linkDesc: "")
        m.extra = extra
        m.votes = votes
        return m
    }

    private static func file(_ id: String, kind: MessageKind, fromMe: Bool, text: String = "", extra: String = "",
                             fileName: String = "", size: Int64 = 0, seconds: Int = 0, thumb: Data? = nil) -> Message {
        var m = Message(rowid: 0, id: id, sender: fromMe ? Core.shared.me : "15550001111@s.whatsapp.net", senderName: "Sam Rivera",
                        fromMe: fromMe, ts: Int64(Date().timeIntervalSince1970 * 1000), kind: kind, text: text, status: 3,
                        edited: false, quoteID: "", quoteSender: "", quoteSenderName: "", quoteText: "", quoteKind: .text,
                        reactions: nil, mime: "", fileName: fileName, fileSize: size, seconds: seconds, width: 0, height: 0, thumb: thumb,
                        mediaPath: kind == .voice ? "/dev/null" : "", hasMedia: true, waveform: nil, linkURL: "", linkTitle: "", linkDesc: "")
        m.extra = extra
        return m
    }

    /// A made-up first page for the document preview samples: a title, a rule and text lines.
    private static func page() -> Data? {
        let img = NSImage(size: NSSize(width: 600, height: 800), flipped: true) { r in
            NSColor.white.setFill(); r.fill()
            NSAttributedString(string: "Spring Offsite", attributes: [.font: NSFont.systemFont(ofSize: 54, weight: .bold),
                                                                      .foregroundColor: NSColor(white: 0.1, alpha: 1)]).draw(at: CGPoint(x: 56, y: 70))
            NSAttributedString(string: "Agenda and travel", attributes: [.font: NSFont.systemFont(ofSize: 28),
                                                                         .foregroundColor: NSColor(white: 0.45, alpha: 1)]).draw(at: CGPoint(x: 58, y: 146))
            NSColor(srgbRed: 0.11, green: 0.67, blue: 0.38, alpha: 1).setFill()
            NSRect(x: 58, y: 206, width: 90, height: 6).fill()
            NSColor(white: 0.86, alpha: 1).setFill()
            for i in 0..<14 { NSRect(x: 58, y: 250 + CGFloat(i) * 34, width: i % 4 == 3 ? 300 : 484, height: 12).fill() }
            return true
        }
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    private static func vote(_ who: String, _ name: String, _ options: [String] = [], response: String = "", guests: Int = 0) -> Vote {
        Vote(voter: who, name: name, options: options, response: response, guests: guests, ts: 1)
    }

    static func render(to out: String) {
        let me = Core.shared.me
        let start = Int64(Date().addingTimeInterval(3 * 86400).timeIntervalSince1970)
        let samples: [Message] = [
            message("p1", kind: .poll, fromMe: false, text: "Where should we go for dinner Saturday?",
                    extra: #"{"options":["Thai Diner","Lilia","Via Carota"],"multi":false}"#,
                    votes: [vote(me, "You", ["Lilia"]), vote("a@s.whatsapp.net", "Priya", ["Lilia"]),
                            vote("b@s.whatsapp.net", "Jordan", ["Thai Diner"])]),
            message("p2", kind: .poll, fromMe: true, text: "Movie night pick",
                    extra: #"{"options":["Dune","Arrival"],"multi":true}"#,
                    votes: [vote("a@s.whatsapp.net", "Priya", ["Dune", "Arrival"])]),
            message("e1", kind: .event, fromMe: false, text: "Roommate dinner",
                    extra: #"{"desc":"Bring a dish if you can.","loc":"Our place","start":\#(start),"end":\#(start + 7200),"guests":true}"#,
                    votes: [vote(me, "You", response: "going"), vote("a@s.whatsapp.net", "Priya", response: "going", guests: 1),
                            vote("b@s.whatsapp.net", "Maya", response: "maybe")]),
            message("e2", kind: .event, fromMe: true, text: "Football Sunday",
                    extra: #"{"loc":"Soccerroof WTC","start":\#(start)}"#,
                    votes: [vote("a@s.whatsapp.net", "Nick", response: "going")]),
            message("e3", kind: .event, fromMe: false, text: "Book club",
                    extra: #"{"start":\#(start),"canceled":true}"#),
            message("c1", kind: .contact, fromMe: false, text: "Jordan Lee",
                    extra: #"{"cards":[{"name":"Jordan Lee","phones":[{"num":"+1 555 0101","waid":"15550000101"}]}]}"#),
            message("c2", kind: .contact, fromMe: true, text: "3 contacts",
                    extra: #"{"cards":[{"name":"Priya Shah","phones":[{"num":"+1 555 0102","waid":"15550000102"}]},{"name":"Maya Chen","phones":[{"num":"+1 555 0100"}]},{"name":"Mum","phones":[{"num":"+1 555 0103","waid":"15550000103"}]}]}"#),
        ]
        // Mentions, voice transcripts (and their progress), document previews.
        let mentions = #"{"mentions":[{"jid":"15550000102@s.whatsapp.net","name":"Priya Shah"},{"jid":"15550000101@s.whatsapp.net","name":"Jordan"}]}"#
        let words = "Hey, it's me. I'm running about 10 minutes late, so start without me. I'll grab coffee on the way."
        var working = MessageLayout.Flags(), preparing = MessageLayout.Flags(), failed = MessageLayout.Flags()
        working.transcript = .working
        preparing.transcript = .preparing("English (United States)")
        failed.transcript = .failed("Hindi isn't available for transcripts on this Mac.")
        let more: [(Message, MessageLayout.Flags)] = [
            (message("m1", kind: .text, fromMe: false, text: "@Priya Shah can you send the deck tonight? cc @Jordan", extra: mentions), .init()),
            (message("m2", kind: .text, fromMe: true, text: "On it @Priya Shah, and @Jordan the venue's booked", extra: mentions), .init()),
            // An older message: no recorded mentions, so the group's names find them (not "@Priyanka").
            (message("m3", kind: .text, fromMe: false, text: "Thanks @Priya Shah! @Priyanka is on the list too, mail jordan@example.com", extra: ""), .init()),
            (file("v1", kind: .voice, fromMe: false, extra: #"{"transcript":"\#(words)"}"#, seconds: 6), .init()),
            (file("v2", kind: .voice, fromMe: true, extra: #"{"transcript":"Sounds good, see you there."}"#, seconds: 2), .init()),
            (file("v3", kind: .voice, fromMe: false, seconds: 14), working),
            (file("v4", kind: .voice, fromMe: false, seconds: 9), preparing),
            (file("v5", kind: .voice, fromMe: true, seconds: 21), failed),
            (file("d1", kind: .document, fromMe: false, extra: #"{"pages":12}"#, fileName: "Spring Offsite.pdf", size: 2_400_000, thumb: page()), .init()),
            (file("d2", kind: .document, fromMe: true, text: "Here's the plan", extra: #"{"pages":1}"#, fileName: "Spring Offsite.pdf", size: 310_000, thumb: page()), .init()),
            (file("d3", kind: .document, fromMe: false, fileName: "photos.zip", size: 48_000_000), .init()),
        ]
        MentionDirectory.shared.set([("15550000102@s.whatsapp.net", "Priya Shah"), ("15550000106@s.whatsapp.net", "Priya"),
                                     ("15550000101@s.whatsapp.net", "Jordan")])
        defer { MentionDirectory.shared.set([]) }
        let width: CGFloat = 440
        for dark in [false, true] {
            let ap = NSAppearance(named: dark ? .darkAqua : .aqua)!
            var layouts: [MessageLayout] = []
            ap.performAsCurrentDrawingAppearance {
                layouts = samples.map { MessageLayout(msg: $0, width: width, flags: .init()) }
                    + more.map { MessageLayout(msg: $0.0, width: width, flags: $0.1) }
            }
            let total = layouts.reduce(0) { $0 + $1.height + 8 }
            let img = NSImage(size: NSSize(width: width, height: total), flipped: true) { r in
                ap.performAsCurrentDrawingAppearance {
                    Theme.canvas.setFill()
                    r.fill()
                    var y: CGFloat = 0
                    for l in layouts {
                        NSGraphicsContext.saveGraphicsState()
                        let t = NSAffineTransform()
                        t.translateX(by: 0, yBy: y)
                        t.concat()
                        l.draw(highlight: false) {}
                        NSGraphicsContext.restoreGraphicsState()
                        y += l.height + 8
                    }
                }
                return true
            }
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: out + (dark ? "-dark.png" : "-light.png")))
            }
        }
    }
}
