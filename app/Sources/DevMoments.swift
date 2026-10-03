import AppKit

/// Dev (`WA_MOMENTS`): plays the motion moments in the running app so they can be recorded
/// without anything reaching WhatsApp: no reaction, reply or message is sent. Steps run
/// 3.5 s apart, comma separated:
///
///   jump:<id>             scroll to a message in the open chat; it nudges, the highlight fades
///   heart:<id>            replay a message's arrival (a lone heart beats)
///   beat:<id>             the heartbeat on any message, for where no lone heart is on screen
///   flight:<id>:<emoji>   a reaction flies in from where the menu would be and lands on the badge
///   swipe:<id>            a two-finger swipe to reply (the reply is cancelled after)
///   pull                  pull the chat list down past its top until Archived shows
///   dot                   a read chat's unread dot pops in for two seconds
@MainActor
enum DevMoments {
    typealias Step = (phase: Phase, dx: Double, dy: Double)

    enum Phase: Int64 {
        // CGScrollPhase values.
        case began = 1, changed = 2, ended = 4, cancelled = 8, mayBegin = 128
    }

    static func run(_ spec: String, main: MainWindowController) {
        ReactionFlight.logLandings = true
        for (i, step) in spec.split(separator: ",").enumerated() {
            let p = step.split(separator: ":", maxSplits: 2).map(String.init)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3 + Double(i) * 3.5 * Motion.slow) { [weak main] in
                guard let main else { return }
                NSLog("WA moments: %@", String(step))
                switch p[0] {
                case "jump" where p.count > 1: main.convo.jump(to: p[1])
                case "heart" where p.count > 1: main.convo.debugEntrance(id: p[1])
                case "beat" where p.count > 1: main.convo.debugBeat(id: p[1])
                case "flight" where p.count > 2: main.convo.debugFlight(id: p[1], emoji: p[2])
                case "swipe" where p.count > 1: main.convo.debugSwipe(id: p[1])
                case "pull": main.list.debugPull()
                case "dot": main.list.debugDot()
                default: NSLog("WA moments: unknown step %@", String(step))
                }
            }
        }
    }

    /// Dev (`WA_BADGES=<png>`): sample reaction badges (one, two and three emoji, with and
    /// without "+N") drawn on a dark canvas, to check the pill's geometry.
    static func renderBadges(to path: String) {
        let samples = ["❤️\t1\t", "😂\t2\t", "❤️💙\t2\t", "❤️💙\t6\t", "👍😂🙏\t12\t"].compactMap(Reactions.init)
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: CGFloat(samples.count) * 44 + 12))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        for (i, r) in samples.enumerated() {
            let b = ReactionBadgeView(frame: NSRect(origin: CGPoint(x: 16, y: 12 + CGFloat(i) * 44), size: ReactionBadgeView.size(for: r)))
            b.configure(r)
            canvas.addSubview(b)
        }
        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return }
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        NSLog("WA badges: %@", path)
    }

    /// A trackpad scroll event with a phase, at a point in screen coordinates.
    static func scroll(_ phase: Phase, dx: Double, dy: Double, at p: CGPoint) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                               wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return nil }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
        // Quartz's global space has its origin at the top left of the main screen.
        cg.location = CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y)
        return NSEvent(cgEvent: cg)
    }

    /// Feeds the steps to `handler` at 120 Hz, like a trackpad.
    static func play(_ steps: [Step], at p: CGPoint, into handler: @escaping (NSEvent) -> Void, done: (() -> Void)? = nil) {
        let start = DispatchTime.now()
        for (i, s) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: start + .milliseconds(Int(Double(i * 1000 / 120) * Motion.slow))) {
                guard let e = scroll(s.phase, dx: s.dx, dy: s.dy, at: p) else { return }
                if i < 2 || i == steps.count - 1 {
                    NSLog("WA moments: phase %lu dx %.1f dy %.1f precise %d", e.phase.rawValue, e.scrollingDeltaX, e.scrollingDeltaY,
                          e.hasPreciseScrollingDeltas ? 1 : 0)
                }
                handler(e)
                if i == steps.count - 1 { done?() }
            }
        }
    }
}
