import Foundation
import AudioToolbox

/// Encodes a few seconds of live capture and reports what actually comes out,
/// so the wire format is proven before anything is built on top of it.
func runSelfTest(pid: pid_t?, seconds: Double) -> Never {
    let tap = ProcessTap()
    let encoder: PacketEncoder
    let collected = Collector()

    do {
        try tap.start(pid: pid, mute: false) { samples, frames, _ in
            collected.append(samples, frames: frames)
        }
    } catch {
        FileHandle.standardError.write("selftest: \(error)\n".data(using: .utf8)!)
        exit(1)
    }

    do {
        encoder = try PacketEncoder(sampleRate: tap.format.sampleRate, channels: tap.format.channels)
    } catch {
        FileHandle.standardError.write("selftest: \(error)\n".data(using: .utf8)!)
        tap.stop(); exit(1)
    }

    print("Format          \(Int(tap.format.sampleRate)) Hz, \(tap.format.channels) ch")
    print("framesPerPacket \(encoder.framesPerPacket)  (= \(String(format: "%.1f", Double(encoder.framesPerPacket) / tap.format.sampleRate * 1000)) ms)")
    print("collecting \(Int(seconds)) s ...")
    Thread.sleep(forTimeInterval: seconds)
    tap.stop()

    let (buf, frames) = collected.take()
    var packets: [Data] = []
    do {
        try buf.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return }
            packets = try encoder.encode(base, frames: frames)
        }
    } catch {
        FileHandle.standardError.write("selftest: \(error)\n".data(using: .utf8)!)
        exit(1)
    }

    let bytes = packets.reduce(0) { $0 + $1.count }
    let audioSeconds = Double(frames) / tap.format.sampleRate
    let sizes = packets.map(\.count).sorted()

    print("captured     \(String(format: "%.2f", audioSeconds)) s (\(frames) frames)")
    print("packets         \(packets.count)")
    if !packets.isEmpty {
        print("packet size     min \(sizes.first!) / median \(sizes[sizes.count/2]) / max \(sizes.last!) bytes")
        print("Bitrate         \(String(format: "%.0f", Double(bytes) * 8 / audioSeconds / 1000)) kbit/s")
        print("message rate    \(String(format: "%.0f", Double(packets.count) / audioSeconds)) /s")
        let expected = Int(audioSeconds * tap.format.sampleRate) / encoder.framesPerPacket
        print("completeness    \(packets.count)/\(expected) packets")
        print(packets.count >= expected - 1 ? "PASS  the encoder produces a gapless stream"
                                            : "FAIL  packets are missing")
        exit(packets.count >= expected - 1 ? 0 : 1)
    }
    print("FAIL  no packets produced")
    exit(1)
}

final class Collector: @unchecked Sendable {
    private var storage: [Float] = []
    private var frames = 0
    private let lock = NSLock()

    func append(_ src: UnsafePointer<Float>, frames n: Int) {
        lock.lock(); defer { lock.unlock() }
        storage.append(contentsOf: UnsafeBufferPointer(start: src, count: n * 2))
        frames += n
    }
    func take() -> ([Float], Int) {
        lock.lock(); defer { lock.unlock() }
        return (storage, frames)
    }
}

// ------------------------------------------------------------- lossless

/**
 The lossless signal, in 24-bit integers: a triangle on the left and LCG noise
 on the right. Integer-only on purpose -- `tests/flac-decode.test.ts` rebuilds
 it in JavaScript and must get identical samples, which a `sin()` in two
 languages cannot promise. The noise is also FLAC's worst case, so it doubles
 as the check that a packet never outgrows the encoder's buffer.
 */
func losslessTestSignal(frames: Int) -> [Int32] {
    var out = [Int32](repeating: 0, count: frames * 2)
    var x: UInt32 = 1
    for i in 0..<frames {
        let phase = Int32(i % 400)
        out[2 * i] = (phase < 200 ? phase : 400 - phase) * 41_943 - 4_194_300
        x = (x &* 1_103_515_245 &+ 12_345) & 0x7fff_ffff
        out[2 * i + 1] = Int32(x >> 8) - 4_194_304
    }
    return out
}

/// Encodes the test signal as FLAC, decodes it back through Apple's decoder
/// and demands every sample survive exactly. `--dump <file>` writes the
/// packets for the browser-side test.
func runLosslessSelfTest(dump: String?) -> Never {
    let frames = 960 * 25   // half a second, 25 packets
    let ints = losslessTestSignal(frames: frames)
    // k / 2^23 is exact in Float32, so the encoder's float-to-24-bit step is too.
    // One packet of trailing silence pushes out the packet the encoder holds back.
    let floats = ints.map { Float($0) / 8_388_608 } + [Float](repeating: 0, count: 960 * 2)

    let encoder: PacketEncoder
    do { encoder = try PacketEncoder(sampleRate: 48_000, channels: 2, codec: .flac24) }
    catch { die("selftest: \(error)") }

    var packets: [Data] = []
    do {
        try floats.withUnsafeBufferPointer { p in
            packets = try encoder.encode(p.baseAddress!, frames: frames + 960)
        }
    } catch { die("selftest: \(error)") }
    packets = Array(packets.prefix(frames / 960))

    let bytes = packets.reduce(0) { $0 + $1.count }
    let sizes = packets.map(\.count).sorted()
    print("codec           \(encoder.codec.label)")
    print("framesPerPacket \(encoder.framesPerPacket)")
    print("packets         \(packets.count)/\(frames / encoder.framesPerPacket)")
    if !packets.isEmpty {
        print("packet size     min \(sizes.first!) / median \(sizes[sizes.count/2]) / max \(sizes.last!) bytes")
        print("Bitrate         \(bytes * 8 * 48_000 / frames / 1000) kbit/s (noise channel: worst case)")
    }
    let synced = packets.allSatisfy { $0.count > 2 && $0[0] == 0xFF && ($0[1] & 0xFE) == 0xF8 }
    print("frame sync      \(synced ? "every packet starts with 0xFFF8" : "MISSING")")

    let decoded = decodeFLAC(packets, channels: 2)
    var mismatches = 0
    for i in 0..<min(decoded.count, ints.count) where decoded[i] != ints[i] { mismatches += 1 }
    print("round trip      \(decoded.count / 2) frames back, \(mismatches) samples differ")

    if let dump {
        var file = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { file.append(contentsOf: $0) } }
        u32(packets.count)
        for p in packets { u32(p.count); file.append(p) }
        do { try file.write(to: URL(fileURLWithPath: dump)) } catch { die("selftest: \(error)") }
        print("dumped          \(dump) (\(file.count) bytes)")
    }

    let ok = packets.count == frames / encoder.framesPerPacket && encoder.framesPerPacket == 960
        && synced && decoded.count == ints.count && mismatches == 0
    print(ok ? "PASS  bit-exact 24-bit FLAC in 20 ms packets" : "FAIL")
    exit(ok ? 0 : 1)
}

/// Apple's FLAC decoder, packet by packet, to interleaved 24-bit integers.
private func decodeFLAC(_ packets: [Data], channels: Int) -> [Int32] {
    var input = AudioStreamBasicDescription(
        mSampleRate: 48_000, mFormatID: kAudioFormatFLAC,
        mFormatFlags: kAppleLosslessFormatFlag_24BitSourceData,
        mBytesPerPacket: 0, mFramesPerPacket: 960, mBytesPerFrame: 0,
        mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
    var output = AudioStreamBasicDescription(
        mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1,
        mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels),
        mBitsPerChannel: 32, mReserved: 0)
    var converter: AudioConverterRef?
    guard AudioConverterNew(&input, &output, &converter) == noErr, let converter else { return [] }
    defer { AudioConverterDispose(converter) }

    var result: [Int32] = []
    for packet in packets {
        var ctx = DecodeContext(packet: packet)
        var out = [Int32](repeating: 0, count: 960 * channels)
        var frames: UInt32 = 960
        let st: OSStatus = out.withUnsafeMutableBytes { raw in
            var abl = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: UInt32(channels),
                                      mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            return withUnsafeMutablePointer(to: &ctx) { c in
                AudioConverterFillComplexBuffer(converter, decodeProc, c, &frames, &abl, nil)
            }
        }
        guard st == noErr || st == kDecodeDone else { return result }
        // 24-bit audio comes back left-justified in 32-bit words.
        result.append(contentsOf: out[0..<Int(frames) * channels].map { $0 >> 8 })
    }
    return result
}

private let kDecodeDone: OSStatus = 1_000_002

private final class DecodeContext {
    let packet: Data
    var bytes: UnsafeMutableRawPointer?
    /// Handed to the converter by address, so it must not move.
    let desc = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
    var consumed = false
    init(packet: Data) { self.packet = packet }
    deinit { bytes?.deallocate(); desc.deallocate() }
}

private let decodeProc: AudioConverterComplexInputDataProc = {
    _, ioPackets, ioData, outDesc, userData in
    let ctx = userData!.assumingMemoryBound(to: DecodeContext.self).pointee
    if ctx.consumed { ioPackets.pointee = 0; return kDecodeDone }
    ctx.consumed = true
    let raw = UnsafeMutableRawPointer.allocate(byteCount: ctx.packet.count, alignment: 1)
    ctx.packet.copyBytes(to: raw.assumingMemoryBound(to: UInt8.self), count: ctx.packet.count)
    ctx.bytes = raw
    ctx.desc.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                    mDataByteSize: UInt32(ctx.packet.count))
    ioPackets.pointee = 1
    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers.mData = raw
    ioData.pointee.mBuffers.mDataByteSize = UInt32(ctx.packet.count)
    outDesc?.pointee = ctx.desc
    return noErr
}
