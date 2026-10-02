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
        let width: CGFloat = 440
        for dark in [false, true] {
            let ap = NSAppearance(named: dark ? .darkAqua : .aqua)!
            var layouts: [MessageLayout] = []
            ap.performAsCurrentDrawingAppearance {
                layouts = samples.map { MessageLayout(msg: $0, width: width, flags: .init()) }
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
