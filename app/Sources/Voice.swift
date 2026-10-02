import AVFoundation
import AppKit

/// Plays voice notes and audio. Ogg Opus is decoded once to a cached CAF next
/// to the original; everything else plays directly.
final class AudioPlayback: NSObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayback()
    private(set) var currentID: String?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var preparing: String?
    /// Called ~30×/s with the playing message id so its bubble can redraw.
    var onTick: ((String) -> Void)?

    func isPlaying(_ id: String) -> Bool { currentID == id && (player?.isPlaying ?? false) }
    func isPreparing(_ id: String) -> Bool { preparing == id }

    func progress(_ id: String) -> Double {
        guard currentID == id, let p = player, p.duration > 0 else { return 0 }
        return p.currentTime / p.duration
    }

    func elapsed(_ id: String) -> Int? {
        guard currentID == id, let p = player else { return nil }
        return Int(p.currentTime.rounded(.down))
    }

    func toggle(_ m: Message) {
        if currentID == m.id, let p = player {
            if p.isPlaying { p.pause(); stopTimer() } else { p.play(); startTimer() }
            onTick?(m.id)
            return
        }
        stop()
        guard !m.mediaPath.isEmpty else { return }
        let id = m.id
        preparing = id
        onTick?(id)
        let src = URL(fileURLWithPath: m.mediaPath)
        DispatchQueue.global(qos: .userInitiated).async {
            let url = AudioPlayback.playableURL(src)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.preparing == id else { return }
                    self.preparing = nil
                    guard let url, let p = try? AVAudioPlayer(contentsOf: url) else { NSSound.beep(); self.onTick?(id); return }
                    p.delegate = self
                    p.prepareToPlay()
                    p.play()
                    self.player = p
                    self.currentID = id
                    self.startTimer()
                    self.onTick?(id)
                }
            }
        }
    }

    func stop() {
        let old = currentID
        player?.stop()
        player = nil
        currentID = nil
        stopTimer()
        if let old { onTick?(old) }
    }

    nonisolated private static func playableURL(_ src: URL) -> URL? {
        let isOgg = src.pathExtension.lowercased() == "ogg" || (try? Data(contentsOf: src, options: .mappedIfSafe).prefix(4)) == Data("OggS".utf8)
        guard isOgg else { return src }
        let caf = src.deletingPathExtension().appendingPathExtension("caf")
        if FileManager.default.fileExists(atPath: caf.path) { return caf }
        guard let pcm = try? OggOpus.decode(src),
              let file = try? AVAudioFile(forWriting: caf, settings: pcm.format.settings,
                                          commonFormat: .pcmFormatFloat32, interleaved: false) else { return nil }
        do { try file.write(from: pcm) } catch { return nil }
        return caf
    }

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let id = self.currentID else { return }
                self.onTick?(id)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.stop() }
        }
    }
}

/// Records a voice note from the default input, then encodes it to Ogg Opus.
nonisolated final class VoiceRecorder: @unchecked Sendable {
    struct Result: Sendable { let url: URL; let seconds: Int; let waveform: [UInt8] }

    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private var rate: Double = 48_000
    private(set) var isRecording = false
    private(set) var started = Date()
    /// Latest input level 0–1, for the live meter.
    private(set) var level: Float = 0
    private let lock = NSLock()

    static func requestPermission(_ done: @escaping @MainActor (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: DispatchQueue.main.async { done(true) }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { done(ok) }
            }
        default: DispatchQueue.main.async { done(false) }
        }
    }

    func start() throws {
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        rate = fmt.sampleRate
        samples.removeAll(keepingCapacity: true)
        let box = UncheckedBox(value: self)
        input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { buf, _ in
            guard let ch = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength)
            var sum: Float = 0
            for k in 0..<n { sum += ch[k] * ch[k] }
            let rms = sqrt(sum / Float(max(n, 1)))
            let r = box.value
            r.lock.lock()
            r.samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: n))
            r.level = min(1, rms * 6)
            r.lock.unlock()
        }
        engine.prepare()
        try engine.start()
        started = Date()
        isRecording = true
    }

    func cancel() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
    }

    var currentLevel: Float {
        lock.lock(); defer { lock.unlock() }
        return level
    }

    /// Stops and encodes off the main thread.
    func finish(_ done: @escaping @MainActor (Result?) -> Void) {
        guard isRecording else { DispatchQueue.main.async { done(nil) }; return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        lock.lock()
        let pcm = samples
        lock.unlock()
        let rate = self.rate
        DispatchQueue.global(qos: .userInitiated).async {
            let result = VoiceRecorder.encode(pcm, rate: rate)
            DispatchQueue.main.async { done(result) }
        }
    }

    private static func encode(_ pcm: [Float], rate: Double) -> Result? {
        guard pcm.count > Int(rate * 0.4),
              let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(pcm.count)),
              let dst = buf.floatChannelData?[0] else { return nil }
        pcm.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { dst.update(from: base, count: pcm.count) }
        }
        buf.frameLength = AVAudioFrameCount(pcm.count)
        guard let ogg = try? OggOpus.encode(buf) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).ogg")
        guard (try? ogg.write(to: url)) != nil else { return nil }
        return Result(url: url, seconds: max(1, Int((Double(pcm.count) / rate).rounded())), waveform: OggOpus.waveform(buf))
    }
}
