import AVFoundation
import Speech

/// Voice-note transcripts made on this Mac with Speech's SpeechAnalyzer (macOS 26). The
/// audio never leaves the Mac, and there's no permission prompt: it's a file, not the
/// microphone. Macs without the 16-core Neural Engine SpeechTranscriber needs fall back
/// to DictationTranscriber, the engine behind system dictation.
nonisolated enum Transcriber {
    enum Failure: LocalizedError {
        case language(String)
        case nothingHeard
        var errorDescription: String? {
            switch self {
            case .language(let name): "\(name) isn't available for transcripts on this Mac."
            case .nothingHeard: "No speech was heard."
            }
        }
    }

    /// The language a transcript is made in: Settings › Chats, otherwise the first of the
    /// Mac's preferred languages that can be transcribed.
    static func locale(preferred: String) async -> Locale? {
        let wanted = preferred.isEmpty ? Locale.preferredLanguages : [preferred]
        for id in wanted {
            let l = Locale(identifier: id)
            if SpeechTranscriber.isAvailable, let s = await SpeechTranscriber.supportedLocale(equivalentTo: l) { return s }
            if let d = await DictationTranscriber.supportedLocale(equivalentTo: l) { return d }
        }
        return nil
    }

    /// Every language this Mac can transcribe, for the Settings picker.
    static func languages() async -> [Locale] {
        let all = SpeechTranscriber.isAvailable ? await SpeechTranscriber.supportedLocales : await DictationTranscriber.supportedLocales
        return all.sorted { name($0.identifier).localizedCaseInsensitiveCompare(name($1.identifier)) == .orderedAscending }
    }

    static func name(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    /// A word's place in the transcript (UTF-16, as NSString counts) and when it's said.
    struct Word: Sendable {
        let start: Double
        let end: Double
        let location: Int
        let length: Int
    }

    /// Transcribes an audio file, with each word's timing so playback can follow along.
    /// `preparing` is called with the language's name if its model has to be downloaded
    /// first (the first transcript in that language).
    static func transcribe(_ url: URL, preferred: String,
                           preparing: @escaping @Sendable (String) -> Void) async throws -> (text: String, locale: String, words: [Word]) {
        guard let locale = await locale(preferred: preferred) else {
            throw Failure.language(preferred.isEmpty ? "Your language" : name(preferred))
        }
        let modern = SpeechTranscriber.isAvailable
        let module: any SpeechModule = modern
            ? SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
            : DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                   reportingOptions: [], attributeOptions: [.audioTimeRange])
        if await AssetInventory.status(forModules: [module]) != .installed,
           let install = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            preparing(name(locale.identifier))
            try await install.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [module])
        async let heard = collect(module)
        if let end = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let (text, words) = try await heard
        guard !text.isEmpty else { throw Failure.nothingHeard }
        return (text, locale.identifier, words)
    }

    /// The final results, in order, joined into one paragraph, and where each timed run
    /// of it lands in that paragraph.
    private static func collect(_ module: any SpeechModule) async throws -> (String, [Word]) {
        var texts: [AttributedString] = []
        if let m = module as? SpeechTranscriber {
            for try await r in m.results where r.isFinal { texts.append(r.text) }
        } else if let m = module as? DictationTranscriber {
            for try await r in m.results where r.isFinal { texts.append(r.text) }
        }
        var out = "", words: [Word] = []
        for t in texts {
            let piece = String(t.characters)
            let lead = piece.prefix { $0.isWhitespace }.utf16.count
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !out.isEmpty { out += " " }
            let base = out.utf16.count - lead
            for run in t.runs {
                guard let range = run.audioTimeRange else { continue }
                let word = String(t[run.range].characters)
                let start = String(t[t.startIndex..<run.range.lowerBound].characters).utf16.count + base
                // Runs carry their own spacing; keep just the word.
                let pad = word.prefix { $0.isWhitespace }.utf16.count
                let core = word.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count
                guard core > 0, start + pad >= out.utf16.count else { continue }
                words.append(Word(start: range.start.seconds, end: range.end.seconds, location: start + pad, length: core))
            }
            out += trimmed
        }
        let total = out.utf16.count
        return (out, words.filter { $0.location + $0.length <= total })
    }
}

/// What's happening to a voice note's transcript before it's saved: the bubble shows it.
enum TranscriptPhase: Equatable {
    case working
    case preparing(String)   // downloading the language's model
    case failed(String)
}

extension Message {
    /// The saved transcript of a voice note (on this Mac only).
    var transcript: String {
        guard extra.contains("\"transcript\""), let d = extra.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return "" }
        return o["transcript"] as? String ?? ""
    }

    /// When each of the transcript's words is said (start seconds, and where it sits in the text).
    var transcriptWords: [(start: Double, range: NSRange)] {
        guard extra.contains("\"transcript_times\""), let d = extra.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let ts = o["transcript_times"] as? [[NSNumber]] else { return [] }
        return ts.compactMap { t in
            t.count == 4 ? (t[0].doubleValue, NSRange(location: t[2].intValue, length: t[3].intValue)) : nil
        }
    }
}

/// Voice-note transcripts for the whole app: a note that arrives (any chat, muted too)
/// downloads straight away and transcribes; older notes transcribe as they come on screen;
/// the message menu makes one on request. Progress is kept here so the bubble can show it
/// whichever chat is open.
final class Transcripts {
    static let shared = Transcripts()
    var store: Store?
    /// Redraws a message's bubble when its transcript starts, progresses or fails (chat, id).
    var onChange: ((String, String) -> Void)?
    private(set) var phases: [String: TranscriptPhase] = [:]
    /// Notes downloading before they can be transcribed (id → chat).
    private var waiting: [String: String] = [:]

    func phase(_ id: String) -> TranscriptPhase? { phases[id] }

    /// A message just arrived: if it's a voice note, transcribe it now.
    func arrived(chat: String, id: String) {
        guard Prefs.autoTranscribe, let m = store?.message(chat: chat, id: id), m.kind == .voice, !m.fromMe,
              m.transcript.isEmpty else { return }
        transcribe(m, in: chat)
    }

    /// An older note came on screen, already downloaded. One transcribed before word timings
    /// were kept is made again, quietly, so playback can follow its words.
    func shown(_ m: Message, in chat: String) {
        guard Prefs.autoTranscribe, m.kind == .voice, !m.mediaPath.isEmpty, phases[m.id] == nil, !retimed.contains(m.id) else { return }
        if m.transcript.isEmpty { return transcribe(m, in: chat) }
        guard m.transcriptWords.isEmpty, FileManager.default.fileExists(atPath: m.mediaPath) else { return }
        retimed.insert(m.id)
        run(m, in: chat, quietly: true)
    }

    /// Notes being re-made for their timings this session (once each).
    private var retimed: Set<String> = []

    /// The core finished (or gave up on) a download.
    func media(chat: String, id: String, status: String) {
        guard waiting[id] != nil else { return }
        if status == "downloaded" {
            waiting[id] = nil
            if let m = store?.message(chat: chat, id: id), !m.mediaPath.isEmpty { run(m, in: chat) }
        } else if status != "retrying" {
            waiting[id] = nil
            set(.failed("The voice message couldn't be downloaded."), chat: chat, id: id)
        }
    }

    /// Makes a note's transcript, downloading the note first if it isn't on this Mac.
    func transcribe(_ m: Message, in chat: String) {
        guard phases[m.id] != .working, waiting[m.id] == nil else { return }
        if !m.mediaPath.isEmpty, FileManager.default.fileExists(atPath: m.mediaPath) { return run(m, in: chat) }
        waiting[m.id] = chat
        set(.working, chat: chat, id: m.id)
        Core.shared.call("download", ["chat": chat, "id": m.id, "retry": true])
    }

    private func run(_ m: Message, in chat: String, quietly: Bool = false) {
        if !quietly { set(.working, chat: chat, id: m.id) }
        let src = URL(fileURLWithPath: m.mediaPath), id = m.id, preferred = Prefs.transcriptLanguage
        let preparing: @Sendable (String) -> Void = { [weak self] language in
            if quietly { return }
            Task { @MainActor in self?.set(.preparing(language), chat: chat, id: id) }
        }
        Task { [weak self] in
            do {
                guard let url = await Task.detached(priority: .userInitiated, operation: { AudioPlayback.playableURL(src) }).value else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let result = try await Transcriber.transcribe(url, preferred: preferred, preparing: preparing)
                let times = result.words.map { [$0.start, $0.end, Double($0.location), Double($0.length)] }
                let res = await Core.shared.callAsync("set_transcript", ["chat": chat, "id": id, "text": result.text,
                                                                         "label": result.locale, "times": times])
                if let err = res["error"] as? String { throw NSError(domain: "Backchannel", code: 1, userInfo: [NSLocalizedDescriptionKey: err]) }
                self?.set(nil, chat: chat, id: id)
            } catch {
                // A quiet re-make keeps the transcript it already has.
                if !quietly { self?.set(.failed(error.localizedDescription), chat: chat, id: id) }
            }
        }
    }

    private func set(_ p: TranscriptPhase?, chat: String, id: String) {
        guard phases[id] != p else { return }
        phases[id] = p
        onChange?(chat, id)
    }
}

extension ConversationViewController {
    /// The message menu's Transcribe.
    func transcribe(_ m: Message) {
        guard let c = chat else { return }
        Transcripts.shared.transcribe(m, in: c.jid)
    }

    /// A transcript started, moved on or failed: re-lay its bubble if it's on screen.
    func transcriptChanged(_ id: String) {
        guard rowIndex(of: id) != nil else { return }
        apply(buildRows(), animateIn: [], scroll: isAtBottom ? .bottom : .anchor)
    }
}
