import Foundation
import AudioToolbox

/// What goes on the wire. Opus is the default; FLAC is `downbeat host lossless`.
enum Codec: Sendable, Equatable {
    case opus(bitrate: Int)
    /// 24-bit FLAC: lossless from the Mac's output mix onwards.
    case flac24

    /// The bitrates macOS's Opus encoder actually offers in the useful range
    /// (`kAudioConverterApplicableEncodeBitRates`). It accepts any number, but
    /// 128 or 192 silently become a neighboring step -- so the ladder is these.
    static let opusLadder = [64_000, 100_000, 120_000, 160_000, 256_000, 512_000]
    static let defaultOpus = Codec.opus(bitrate: 120_000)

    /// `codec` as announced in `liveStart`.
    var wireName: String {
        switch self {
        case .opus: "opus"
        case .flac24: "flac"
        }
    }

    var label: String {
        switch self {
        case .opus(let b): "Opus \(b / 1000) kbit/s"
        case .flac24: "FLAC 24-bit lossless"
        }
    }
}

/**
 Opus or FLAC encoding via AudioToolbox.

 macOS ships both encoders (they appear in `kAudioFormatProperty_EncodeFormatIDs`),
 so the CLI needs no libopus, no libFLAC, no Homebrew, and stays a
 self-contained binary. Both are asked for 20 ms packets, so the wire carries
 the same 50 packets a second either way and nothing downstream of the encoder
 -- headers, sample indices, relay, worklet -- knows which codec is running.
 */
final class PacketEncoder {
    private var converter: AudioConverterRef?
    private let inputChannels: Int
    let codec: Codec
    private(set) var framesPerPacket: Int = 0
    private var maxPacketBytes = 4000

    /// Interleaved Float32 waiting to be consumed by the converter callback.
    private var pending: UnsafeMutablePointer<Float>
    private var pendingFrames = 0
    private var pendingCapacity: Int

    enum EncoderError: Error, CustomStringConvertible {
        case createFailed(String, OSStatus)
        case bitrateFailed(OSStatus)
        case encodeFailed(OSStatus)
        var description: String {
            switch self {
            case .createFailed(let name, let s): "\(name) encoder unavailable (OSStatus \(s))"
            case .bitrateFailed(let s): "could not set the bitrate (OSStatus \(s))"
            case .encodeFailed(let s): "encoding failed (OSStatus \(s))"
            }
        }
    }

    init(sampleRate: Double, channels: Int, codec: Codec = .defaultOpus) throws {
        self.codec = codec
        inputChannels = channels
        pendingCapacity = 48_000 * channels
        pending = .allocate(capacity: pendingCapacity)

        var input = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0)

        var output = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 0,   // Opus picks 960 (20 ms at 48 kHz) itself
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0)
        if codec == .flac24 {
            // Left alone, the FLAC encoder makes 4608-frame packets (~96 ms).
            // Asking for 960 keeps the wire at Opus's cadence, which is what
            // the relay's cost and the receiver's buffering are sized for.
            output.mFormatID = kAudioFormatFLAC
            output.mFormatFlags = kAppleLosslessFormatFlag_24BitSourceData
            output.mFramesPerPacket = 960
        }

        let status = AudioConverterNew(&input, &output, &converter)
        guard status == noErr, converter != nil else {
            throw EncoderError.createFailed(codec.wireName, status)
        }

        if case .opus(let bitrate) = codec { setBitrate(bitrate) }

        var actual = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioConverterGetProperty(converter!, kAudioConverterCurrentOutputStreamDescription, &size, &actual)
        framesPerPacket = Int(actual.mFramesPerPacket)
        if framesPerPacket == 0 { framesPerPacket = 960 }  // 20 ms at 48 kHz

        // A 24-bit FLAC packet of noise-like audio can exceed the fixed buffer
        // Opus never comes close to; ask the converter for its real worst case.
        var maxOut: UInt32 = 0
        var maxSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioConverterGetProperty(converter!, kAudioConverterPropertyMaximumOutputPacketSize,
                                     &maxSize, &maxOut) == noErr, maxOut > 0 {
            maxPacketBytes = max(maxPacketBytes, Int(maxOut))
        }
    }

    /// Opus only; takes effect from the next packet. Opus packets stand alone,
    /// so a change mid-stream needs nothing from the receivers.
    @discardableResult
    func setBitrate(_ bitrate: Int) -> Bool {
        guard let converter, case .opus = codec else { return false }
        var rate = UInt32(bitrate)
        let st = AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate,
                                           UInt32(MemoryLayout<UInt32>.size), &rate)
        // Not every encoder accepts an explicit bitrate; its default is fine.
        if st != noErr { NSLog("downbeat: bitrate not set (\(st)), using the default") }
        return st == noErr
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        pending.deallocate()
    }

    /**
     Feed interleaved Float32 and receive whole packets.

     Returns one `Data` per packet, each covering exactly `framesPerPacket`
     frames, so the caller can label packets by absolute sample index and never
     has to trust a per-packet timestamp. Packets come out in order but may lag
     the input (FLAC by one packet): the n-th packet ever returned starts at
     frame `n * framesPerPacket`, whichever call returned it.
     */
    func encode(_ samples: UnsafePointer<Float>, frames: Int) throws -> [Data] {
        guard let converter else { return [] }

        if pendingFrames + frames > pendingCapacity / inputChannels {
            let needed = (pendingFrames + frames) * inputChannels * 2
            let grown = UnsafeMutablePointer<Float>.allocate(capacity: needed)
            grown.update(from: pending, count: pendingFrames * inputChannels)
            pending.deallocate()
            pending = grown
            pendingCapacity = needed
        }
        pending.advanced(by: pendingFrames * inputChannels)
            .update(from: samples, count: frames * inputChannels)
        pendingFrames += frames

        var packets: [Data] = []
        var buffer = [UInt8](repeating: 0, count: maxPacketBytes)

        while pendingFrames >= framesPerPacket {
            var context = FillContext(source: pending, frames: framesPerPacket,
                                      channels: inputChannels, consumed: false)
            var packetCount: UInt32 = 1
            var desc = AudioStreamPacketDescription()

            let status: OSStatus = buffer.withUnsafeMutableBytes { raw in
                var abl = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: UInt32(inputChannels),
                                          mDataByteSize: UInt32(raw.count),
                                          mData: raw.baseAddress))
                return withUnsafeMutablePointer(to: &context) { ctx in
                    AudioConverterFillComplexBuffer(converter, fillProc, ctx, &packetCount, &abl, &desc)
                }
            }
            guard status == noErr || status == kFillDone else { throw EncoderError.encodeFailed(status) }
            if packetCount > 0 {
                packets.append(Data(buffer[0..<Int(desc.mDataByteSize)]))
            }
            // The FLAC encoder holds one packet back: the first call swallows
            // its input and returns nothing, every later call returns the
            // previous packet. Input the converter took is gone either way,
            // and must not be fed to it a second time.
            guard context.consumed else { break }

            let leftover = pendingFrames - framesPerPacket
            if leftover > 0 {
                pending.update(from: pending.advanced(by: framesPerPacket * inputChannels),
                               count: leftover * inputChannels)
            }
            pendingFrames = leftover
        }
        return packets
    }
}

private let kFillDone: OSStatus = 1_000_001

private struct FillContext {
    var source: UnsafeMutablePointer<Float>
    var frames: Int
    var channels: Int
    var consumed: Bool
}

private let fillProc: AudioConverterComplexInputDataProc = {
    _, ioNumberDataPackets, ioData, outDesc, userData in
    guard let userData else { ioNumberDataPackets.pointee = 0; return kFillDone }
    let ctx = userData.assumingMemoryBound(to: FillContext.self)
    if ctx.pointee.consumed {
        ioNumberDataPackets.pointee = 0
        return kFillDone
    }
    ctx.pointee.consumed = true
    let frames = ctx.pointee.frames
    let channels = ctx.pointee.channels
    ioNumberDataPackets.pointee = UInt32(frames)
    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers.mNumberChannels = UInt32(channels)
    ioData.pointee.mBuffers.mDataByteSize = UInt32(frames * channels * 4)
    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(ctx.pointee.source)
    outDesc?.pointee = nil
    return noErr
}
