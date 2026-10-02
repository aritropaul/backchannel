import AVFoundation

/// WhatsApp voice notes are Opus in an Ogg container. AudioToolbox has an Opus
/// codec but no Ogg demuxer/muxer, so this handles the container by hand and
/// hands raw packets to AVAudioConverter.
nonisolated enum OggOpus {
    enum Failure: Error { case notOgg, noHead, codec(String) }

    static let sampleRate = 48_000.0

    // MARK: demux

    struct Stream {
        var channels: Int
        var preSkip: Int
        var packets: [Data]
    }

    static func demux(_ data: Data) throws -> Stream {
        let b = [UInt8](data)
        var i = 0
        var packets: [Data] = []
        var partial = Data()
        while i + 27 <= b.count {
            guard b[i] == 0x4F, b[i + 1] == 0x67, b[i + 2] == 0x67, b[i + 3] == 0x53 else { throw Failure.notOgg }
            let nsegs = Int(b[i + 26])
            let table = i + 27
            guard table + nsegs <= b.count else { break }
            var body = table + nsegs
            for s in 0..<nsegs {
                let len = Int(b[table + s])
                guard body + len <= b.count else { break }
                partial.append(contentsOf: b[body..<(body + len)])
                body += len
                if len < 255 {
                    packets.append(partial)
                    partial = Data()
                }
            }
            i = body
        }
        guard let head = packets.first, head.count >= 19, head.starts(with: Array("OpusHead".utf8)) else { throw Failure.noHead }
        let h = [UInt8](head)
        let channels = Int(h[9])
        let preSkip = Int(h[10]) | Int(h[11]) << 8
        // packets[1] is OpusTags.
        return Stream(channels: max(1, channels), preSkip: preSkip, packets: Array(packets.dropFirst(2)))
    }

    private static func opusFormat(channels: Int) -> AVAudioFormat? {
        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                               mBytesPerPacket: 0, mFramesPerPacket: 960, mBytesPerFrame: 0,
                                               mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &asbd)
    }

    // MARK: decode

    /// Decodes a whole voice note to 48 kHz float PCM (they're short).
    static func decode(_ url: URL) throws -> AVAudioPCMBuffer {
        let stream = try demux(Data(contentsOf: url))
        guard let inFmt = opusFormat(channels: stream.channels),
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(stream.channels), interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: outFmt) else { throw Failure.codec("converter") }
        let maxFrames = AVAudioFrameCount(stream.packets.count * 5760 + 5760)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: maxFrames),
              let chunk = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: 5760 * 4) else { throw Failure.codec("buffers") }
        var next = 0
        let maxPacket = stream.packets.map(\.count).max() ?? 1
        while true {
            chunk.frameLength = 0
            var err: NSError?
            let status = conv.convert(to: chunk, error: &err) { _, outStatus in
                guard next < stream.packets.count else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                let p = stream.packets[next]
                next += 1
                let buf = AVAudioCompressedBuffer(format: inFmt, packetCapacity: 1, maximumPacketSize: max(maxPacket, 1))
                p.withUnsafeBytes { raw in
                    if let base = raw.baseAddress { buf.data.copyMemory(from: base, byteCount: p.count) }
                }
                buf.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                                mDataByteSize: UInt32(p.count))
                buf.packetCount = 1
                buf.byteLength = UInt32(p.count)
                outStatus.pointee = .haveData
                return buf
            }
            if let err { throw Failure.codec(err.localizedDescription) }
            if chunk.frameLength > 0 { append(chunk, to: out) }
            if status == .endOfStream || status == .error { break }
            if chunk.frameLength == 0 && next >= stream.packets.count { break }
        }
        trimStart(out, frames: stream.preSkip)
        return out
    }

    private static func append(_ src: AVAudioPCMBuffer, to dst: AVAudioPCMBuffer) {
        let n = min(src.frameLength, dst.frameCapacity - dst.frameLength)
        guard n > 0, let s = src.floatChannelData, let d = dst.floatChannelData else { return }
        for c in 0..<Int(src.format.channelCount) {
            (d[c] + Int(dst.frameLength)).update(from: s[c], count: Int(n))
        }
        dst.frameLength += n
    }

    private static func trimStart(_ buf: AVAudioPCMBuffer, frames: Int) {
        let n = min(frames, Int(buf.frameLength))
        guard n > 0, let d = buf.floatChannelData else { return }
        let remaining = Int(buf.frameLength) - n
        for c in 0..<Int(buf.format.channelCount) {
            d[c].update(from: d[c] + n, count: remaining)
        }
        buf.frameLength = AVAudioFrameCount(remaining)
    }

    // MARK: encode

    /// Encodes mono float PCM (any rate) to an Ogg Opus voice note.
    static func encode(_ input: AVAudioPCMBuffer) throws -> Data {
        guard let pcm48 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let outFmt = opusFormat(channels: 1) else { throw Failure.codec("formats") }
        let source = try resample(input, to: pcm48)
        guard let conv = AVAudioConverter(from: pcm48, to: outFmt) else { throw Failure.codec("encoder") }
        conv.bitRate = 32_000
        var packets: [Data] = []
        var fed = false
        let maxPacket = max(conv.maximumOutputPacketSize, 1500)
        while true {
            let out = AVAudioCompressedBuffer(format: outFmt, packetCapacity: 32, maximumPacketSize: maxPacket)
            var err: NSError?
            let status = conv.convert(to: out, error: &err) { _, outStatus in
                if fed {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return source
            }
            if let err { throw Failure.codec(err.localizedDescription) }
            for k in 0..<Int(out.packetCount) {
                guard let desc = out.packetDescriptions?[k] else { continue }
                packets.append(Data(bytes: out.data.advanced(by: Int(desc.mStartOffset)), count: Int(desc.mDataByteSize)))
            }
            if status == .endOfStream || status == .error || (out.packetCount == 0 && fed) { break }
        }
        guard !packets.isEmpty else { throw Failure.codec("no packets") }
        let preSkip = 312
        return mux(packets, preSkip: preSkip, frameSize: 960)
    }

    private static func resample(_ buf: AVAudioPCMBuffer, to fmt: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buf.format.sampleRate == fmt.sampleRate && buf.format.channelCount == 1 && buf.format.commonFormat == .pcmFormatFloat32 {
            return buf
        }
        guard let conv = AVAudioConverter(from: buf.format, to: fmt) else { throw Failure.codec("resampler") }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * fmt.sampleRate / buf.format.sampleRate) + 4096
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { throw Failure.codec("resample buffer") }
        var done = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, st in
            if done { st.pointee = .endOfStream; return nil }
            done = true
            st.pointee = .haveData
            return buf
        }
        if let err { throw Failure.codec(err.localizedDescription) }
        return out
    }

    // MARK: mux

    private static func mux(_ packets: [Data], preSkip: Int, frameSize: Int) -> Data {
        let serial = UInt32.random(in: 1...UInt32.max)
        var out = Data()
        var seq: UInt32 = 0

        var head = Data("OpusHead".utf8)
        head.append(1)                                  // version
        head.append(1)                                  // channels
        head.append(contentsOf: le16(UInt16(preSkip)))
        head.append(contentsOf: le32(48_000))           // original rate
        head.append(contentsOf: le16(0))                // gain
        head.append(0)                                  // mapping family
        out.append(page([head], granule: 0, serial: serial, seq: &seq, flags: 0x02))

        var tags = Data("OpusTags".utf8)
        let vendor = Data("WA".utf8)
        tags.append(contentsOf: le32(UInt32(vendor.count)))
        tags.append(vendor)
        tags.append(contentsOf: le32(0))
        out.append(page([tags], granule: 0, serial: serial, seq: &seq, flags: 0))

        var granule = UInt64(preSkip)
        var batch: [Data] = []
        var lacing = 0
        for (k, p) in packets.enumerated() {
            batch.append(p)
            granule += UInt64(frameSize)
            lacing += p.count / 255 + 1
            let last = k == packets.count - 1
            if last || lacing > 200 || batch.count >= 50 {
                out.append(page(batch, granule: granule, serial: serial, seq: &seq, flags: last ? 0x04 : 0))
                batch = []
                lacing = 0
            }
        }
        return out
    }

    private static func page(_ packets: [Data], granule: UInt64, serial: UInt32, seq: inout UInt32, flags: UInt8) -> Data {
        var segs: [UInt8] = []
        var body = Data()
        for p in packets {
            var n = p.count
            while n >= 255 { segs.append(255); n -= 255 }
            segs.append(UInt8(n))
            body.append(p)
        }
        var h = Data("OggS".utf8)
        h.append(0)
        h.append(flags)
        h.append(contentsOf: le64(granule))
        h.append(contentsOf: le32(serial))
        h.append(contentsOf: le32(seq))
        h.append(contentsOf: le32(0))                    // CRC placeholder
        h.append(UInt8(segs.count))
        h.append(contentsOf: segs)
        var pageData = h + body
        let crc = crc32(pageData)
        pageData.replaceSubrange(22..<26, with: le32(crc))
        seq += 1
        return pageData
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var r = UInt32(i) << 24
        for _ in 0..<8 { r = (r & 0x8000_0000) != 0 ? (r << 1) ^ 0x04C1_1DB7 : r << 1 }
        return r
    }

    private static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0
        for byte in d { c = (c << 8) ^ crcTable[Int(((c >> 24) ^ UInt32(byte)) & 0xFF)] }
        return c
    }

    private static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
    private static func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }

    // MARK: waveform

    /// 64 bars, 0–100, as WhatsApp expects in AudioMessage.waveform.
    static func waveform(_ buf: AVAudioPCMBuffer, bars: Int = 64) -> [UInt8] {
        guard let d = buf.floatChannelData?[0], buf.frameLength > 0 else { return Array(repeating: 0, count: bars) }
        let n = Int(buf.frameLength), per = max(1, n / bars)
        var vals: [Float] = []
        for b in 0..<bars {
            let start = b * per
            guard start < n else { vals.append(0); continue }
            let end = min(n, start + per)
            var sum: Float = 0
            for k in start..<end { sum += d[k] * d[k] }
            vals.append(sqrt(sum / Float(end - start)))
        }
        let peak = max(vals.max() ?? 1, 0.0001)
        return vals.map { UInt8(min(100, max(0, ($0 / peak) * 100))) }
    }
}
