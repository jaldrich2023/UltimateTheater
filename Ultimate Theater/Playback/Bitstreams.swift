//
//  Bitstreams.swift
//  Ultimate Theater
//
//  Codec-level helpers: H.264/HEVC start-code streams, MPEG-4 Part 2 VOPs,
//  AAC configuration and ADTS, MPEG audio / AC-3 framing, and ESDS boxes.
//

import Foundation

// MARK: - H.264 / HEVC Annex B

nonisolated enum AnnexB {
    /// NAL units (without start codes) in a start-code-delimited buffer.
    static func nalUnits(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var start: Int?
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                if let begin = start {
                    var end = i
                    if end > begin, bytes[end - 1] == 0 { end -= 1 } // 4-byte start code
                    if end > begin { units.append(Data(bytes[begin..<end])) }
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if let begin = start, begin < bytes.count { units.append(Data(bytes[begin...])) }
        return units
    }

    /// Converts start codes to 4-byte big-endian length prefixes (the form decoders expect).
    static func lengthPrefixed(_ data: Data, dropping types: Set<UInt8> = [], isHEVC: Bool = false) -> Data {
        var output = Data()
        output.reserveCapacity(data.count + 16)
        for unit in nalUnits(in: data) where !unit.isEmpty {
            let type = isHEVC ? (unit[unit.startIndex] >> 1) & 0x3F : unit[unit.startIndex] & 0x1F
            guard !types.contains(type) else { continue }
            var length = UInt32(unit.count).bigEndian
            output.append(Data(bytes: &length, count: 4))
            output.append(unit)
        }
        return output
    }

    /// H.264 SPS (7) and PPS (8) from a keyframe, for building the format description.
    static func h264ParameterSets(in data: Data) -> (sps: Data, pps: Data)? {
        let units = nalUnits(in: data)
        guard let sps = units.first(where: { ($0.first ?? 0) & 0x1F == 7 }),
              let pps = units.first(where: { ($0.first ?? 0) & 0x1F == 8 }) else { return nil }
        return (sps, pps)
    }

    /// HEVC VPS (32), SPS (33), PPS (34).
    static func hevcParameterSets(in data: Data) -> [Data]? {
        let units = nalUnits(in: data)
        let sets = [32, 33, 34].compactMap { type in units.first { (($0.first ?? 0) >> 1) & 0x3F == type } }
        return sets.count == 3 ? sets : nil
    }

    /// True if an H.264 access unit's first slice is a B slice (for display-order reconstruction).
    static func h264IsBSlice(_ data: Data) -> Bool {
        for unit in nalUnits(in: data) {
            let type = (unit.first ?? 0) & 0x1F
            guard type == 1 || type == 5 else { continue }
            var bits = BitReader(unit.dropFirst())
            _ = bits.unsignedExpGolomb()          // first_mb_in_slice
            let sliceType = bits.unsignedExpGolomb() ?? 0
            return sliceType % 5 == 1
        }
        return false
    }
}

// MARK: - MPEG-4 Part 2 (Xvid / DivX)

nonisolated enum MPEG4Part2 {
    enum VOPType {
        case intra, predicted, bidirectional, sprite
    }

    private static let vopStartCode: [UInt8] = [0, 0, 1, 0xB6]

    /// Coding type of the first VOP in a chunk.
    static func vopType(in data: Data) -> VOPType? {
        guard let offset = startCodeOffsets(in: data).first else { return nil }
        let bytes = [UInt8](data)
        guard offset + 4 < bytes.count else { return nil }
        switch bytes[offset + 4] >> 6 {
        case 0: return .intra
        case 1: return .predicted
        case 2: return .bidirectional
        default: return .sprite
        }
    }

    /// Byte offsets of VOP start codes.
    static func startCodeOffsets(in data: Data) -> [Int] {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return [] }
        return (0...(bytes.count - 4)).filter { i in
            bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 && bytes[i + 3] == 0xB6
        }
    }

    /// Width of vop_time_increment, from the VOL header in a stream's setup data.
    static func timeIncrementBits(inConfiguration data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard let vol = (0..<max(bytes.count - 4, 0)).first(where: { i in
            bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 && (0x20...0x2F).contains(bytes[i + 3])
        }) else { return nil }
        var reader = ElementaryBits(Array(bytes[(vol + 4)...]))
        reader.skip(1 + 8)                              // random_accessible_vol, video_object_type_indication
        if reader.read(1) == 1 { reader.skip(4 + 3) }   // is_object_layer_identifier: verid, priority
        if reader.read(4) == 15 { reader.skip(16) }     // aspect_ratio_info, extended PAR
        if reader.read(1) == 1 {                        // vol_control_parameters
            reader.skip(2 + 1)                          // chroma_format, low_delay
            if reader.read(1) == 1 { reader.skip(79) }  // vbv_parameters
        }
        reader.skip(2 + 1)                              // video_object_layer_shape, marker
        let resolution = reader.read(16)
        guard resolution > 0 else { return nil }
        var bits = 1
        while (1 << bits) < resolution { bits += 1 }
        return bits
    }

    /// MSB-first reader for small header fields.
    private struct ElementaryBits {
        let bytes: [UInt8]
        var position = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        mutating func read(_ count: Int) -> Int {
            var value = 0
            for _ in 0..<count {
                let byte = position >> 3
                let bit = byte < bytes.count ? Int(bytes[byte] >> (7 - UInt8(position & 7))) & 1 : 0
                value = value << 1 | bit
                position += 1
            }
            return value
        }
        mutating func skip(_ count: Int) { position += count }
    }

    /// Configuration headers (visual object sequence through VOL) preceding the first VOP.
    static func configuration(in data: Data) -> Data? {
        guard let first = startCodeOffsets(in: data).first, first > 0 else { return nil }
        return data.prefix(first)
    }
}

/// Assigns presentation times to frames that arrive in decode order with only
/// frame-rate timing (AVI). Anchor frames (I/P) display just before the next anchor;
/// B frames display immediately, one slot behind their decode position.
nonisolated struct DisplayOrderReconstructor {
    let frameDuration: Double
    var startTime: Double
    private var decodeIndex = 0
    private var heldAnchor: (packet: MediaPacket, index: Int)?
    private var heldBFrames: [MediaPacket] = []
    private var sawBFrames = false

    init(frameDuration: Double, startTime: Double) {
        self.frameDuration = frameDuration
        self.startTime = startTime
    }

    /// Feeds one frame; returns frames now ready, in decode order, with presentation times set.
    mutating func push(_ packet: MediaPacket, isBFrame: Bool) -> [MediaPacket] {
        defer { decodeIndex += 1 }
        if isBFrame {
            sawBFrames = true
            var frame = packet
            frame.pts = time(decodeIndex - 1)
            guard heldAnchor != nil else { return [frame] }
            heldBFrames.append(frame)
            return []
        }
        var ready: [MediaPacket] = []
        if var held = heldAnchor {
            // Without B frames the order is already display order.
            held.packet.pts = time(sawBFrames ? decodeIndex - 1 : held.index)
            ready = [held.packet] + heldBFrames
        }
        heldAnchor = (packet, decodeIndex)
        heldBFrames = []
        return ready
    }

    mutating func flush() -> [MediaPacket] {
        guard var held = heldAnchor else { return heldBFrames }
        held.packet.pts = time(sawBFrames ? decodeIndex - 1 : held.index)
        defer { heldAnchor = nil; heldBFrames = [] }
        return [held.packet] + heldBFrames
    }

    private func time(_ index: Int) -> Double {
        startTime + Double(max(index, 0)) * frameDuration
    }
}

// MARK: - AAC

nonisolated enum AAC {
    static let sampleRates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    /// Two-byte AudioSpecificConfig for AAC-LC.
    static func audioSpecificConfig(sampleRate: Double, channels: Int, objectType: UInt8 = 2) -> Data {
        let rateIndex = UInt8(sampleRates.firstIndex(of: sampleRate) ?? 4)
        let channelConfig = UInt8(min(max(channels, 1), 7))
        return Data([objectType << 3 | rateIndex >> 1, (rateIndex & 1) << 7 | channelConfig << 3])
    }

    /// The core sampling rate from an AudioSpecificConfig (5-bit object type, 4-bit rate index).
    static func coreSampleRate(fromConfig config: Data) -> Double? {
        let bytes = [UInt8](config.prefix(5))
        guard bytes.count >= 2 else { return nil }
        var objectType = Int(bytes[0] >> 3)
        var bitOffset = 5
        if objectType == 31, bytes.count >= 3 { // Escaped object type.
            objectType = 32 + Int((bytes[0] & 0x07) << 3 | bytes[1] >> 5)
            bitOffset = 11
        }
        func bits(_ start: Int, _ count: Int) -> Int {
            (0..<count).reduce(0) { value, i in
                let bit = start + i
                guard bit / 8 < bytes.count else { return value << 1 }
                return value << 1 | Int(bytes[bit / 8] >> (7 - bit % 8)) & 1
            }
        }
        let index = bits(bitOffset, 4)
        if index == 15 { return Double(bits(bitOffset + 4, 24)) }
        return index < sampleRates.count ? sampleRates[index] : nil
    }

    struct ADTSHeader {
        let headerLength: Int
        let frameLength: Int
        let config: Data
        let sampleRate: Double
        let channels: Int
    }

    /// Parses an ADTS header (some files carry AAC with ADTS framing).
    static func adtsHeader(_ data: Data) -> ADTSHeader? {
        let b = [UInt8](data.prefix(9))
        guard b.count >= 7, b[0] == 0xFF, b[1] & 0xF0 == 0xF0 else { return nil }
        let protectionAbsent = b[1] & 1 == 1
        let objectType = (b[2] >> 6) + 1
        let rateIndex = Int((b[2] >> 2) & 0x0F)
        let channels = Int((b[2] & 1) << 2 | b[3] >> 6)
        let frameLength = Int(b[3] & 0x03) << 11 | Int(b[4]) << 3 | Int(b[5] >> 5)
        guard rateIndex < sampleRates.count else { return nil }
        return ADTSHeader(headerLength: protectionAbsent ? 7 : 9, frameLength: frameLength,
                          config: audioSpecificConfig(sampleRate: sampleRates[rateIndex], channels: channels, objectType: objectType),
                          sampleRate: sampleRates[rateIndex], channels: channels)
    }
}

// MARK: - MPEG audio and AC-3 framing

/// Re-frames byte streams whose container chunks don't align to codec frames
/// (MP3, MP2, AC-3, and E-AC-3 in AVI; those and ADTS AAC in MPEG streams).
nonisolated struct AudioFramer {
    let codec: MediaCodec
    /// Only frames whose checksum verifies are returned (AC-3 inside other streams).
    let verifiesFrames: Bool
    /// Pending bytes; `head` is where unconsumed data starts (compacted once per push), and
    /// positions before `searched` are known not to start a frame.
    private var buffer: [UInt8] = []
    private var head = 0
    private var searched = 0

    init(codec: MediaCodec, verifiesFrames: Bool = false) {
        self.codec = codec
        self.verifiesFrames = verifiesFrames
    }

    /// Appends bytes and returns every complete frame now available.
    mutating func push(_ data: Data) -> [Data] {
        buffer.append(contentsOf: data)
        var frames: [Data] = []
        while let (offset, length) = nextFrame() {
            guard offset + length <= buffer.count else {
                searched = offset // Incomplete: wait for more data.
                break
            }
            let frame = buffer[offset..<(offset + length)]
            if verifiesFrames, !AC3.isIntact(frame) {
                head = offset + 1 // A false sync word: keep looking.
                searched = head
                continue
            }
            frames.append(Data(frame))
            head = offset + length
            searched = head
        }
        if head > 0 {
            buffer.removeFirst(head)
            searched = max(0, searched - head)
            head = 0
        }
        if buffer.count > 1 << 20 { reset() } // Garbage; resynchronize.
        return frames
    }

    mutating func reset() {
        buffer.removeAll()
        head = 0
        searched = 0
    }

    /// Offset and length of the next sync'd frame in the buffer.
    private mutating func nextFrame() -> (Int, Int)? {
        var i = max(head, searched)
        while i + 6 < buffer.count {
            if let length = frameLength(buffer, at: i), length > 0 {
                return (i, length)
            }
            i += 1
        }
        searched = i
        return nil
    }

    private func frameLength(_ b: [UInt8], at i: Int) -> Int? {
        switch codec {
        case .mp3, .mp2:
            return Self.mpegFrameLength(b, at: i)
        case .aac:
            guard b[i] == 0xFF, b[i + 1] & 0xF6 == 0xF0 else { return nil }
            let length = Int(b[i + 3] & 0x03) << 11 | Int(b[i + 4]) << 3 | Int(b[i + 5] >> 5)
            return length >= 7 ? length : nil
        case .ac3, .eac3:
            guard b[i] == 0x0B, b[i + 1] == 0x77 else { return nil }
            let bsid = b[i + 5] >> 3
            if bsid > 10 { // E-AC-3: frmsiz in words.
                return ((Int(b[i + 2] & 0x07) << 8 | Int(b[i + 3])) + 1) * 2
            }
            return Self.ac3FrameLength(fscod: Int(b[i + 4] >> 6), frmsizecod: Int(b[i + 4] & 0x3F))
        default:
            return nil
        }
    }

    static func mpegFrameLength(_ b: [UInt8], at i: Int) -> Int? {
        guard b[i] == 0xFF, b[i + 1] & 0xE0 == 0xE0 else { return nil }
        let version = (b[i + 1] >> 3) & 0x03   // 3 = MPEG-1, 2 = MPEG-2, 0 = MPEG-2.5
        let layer = (b[i + 1] >> 1) & 0x03     // 1 = Layer III, 2 = Layer II
        let bitrateIndex = Int(b[i + 2] >> 4)
        let rateIndex = Int((b[i + 2] >> 2) & 0x03)
        let padding = Int((b[i + 2] >> 1) & 1)
        guard version != 1, layer == 1 || layer == 2, bitrateIndex > 0, bitrateIndex < 15, rateIndex < 3 else { return nil }
        let mpeg1 = version == 3
        let bitrates: [Int] = layer == 1
            ? (mpeg1 ? [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
                     : [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160])
            : (mpeg1 ? [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384]
                     : [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160])
        let baseRates = [44100, 48000, 32000]
        let sampleRate = baseRates[rateIndex] / (mpeg1 ? 1 : (version == 2 ? 2 : 4))
        let samples = layer == 1 && !mpeg1 ? 576 : 1152
        return samples / 8 * bitrates[bitrateIndex] * 1000 / sampleRate + padding
    }

    static func ac3FrameLength(fscod: Int, frmsizecod: Int) -> Int? {
        let table: [[Int]] = [ // 16-bit words per frame for 48 / 44.1 / 32 kHz.
            [64, 69, 96], [64, 70, 96], [80, 87, 120], [80, 88, 120], [96, 104, 144], [96, 105, 144],
            [112, 121, 168], [112, 122, 168], [128, 139, 192], [128, 140, 192], [160, 174, 240], [160, 175, 240],
            [192, 208, 288], [192, 209, 288], [224, 243, 336], [224, 244, 336], [256, 278, 384], [256, 279, 384],
            [320, 348, 480], [320, 349, 480], [384, 417, 576], [384, 418, 576], [448, 487, 672], [448, 488, 672],
            [512, 557, 768], [512, 558, 768], [640, 696, 960], [640, 697, 960], [768, 835, 1152], [768, 836, 1152],
            [896, 975, 1344], [896, 976, 1344], [1024, 1114, 1536], [1024, 1115, 1536], [1152, 1253, 1728],
            [1152, 1254, 1728], [1280, 1393, 1920], [1280, 1394, 1920],
        ]
        guard fscod < 3, frmsizecod < table.count else { return nil }
        return table[frmsizecod][fscod] * 2
    }
}

// MARK: - ESDS

nonisolated enum ESDS {
    /// An `esds` box payload (version/flags + ES_Descriptor) wrapping decoder-specific info.
    /// Used as the AAC magic cookie and the MPEG-4 Part 2 sample description extension.
    static func box(objectType: UInt8, streamType: UInt8, decoderSpecificInfo: Data) -> Data {
        Data([0, 0, 0, 0]) + esDescriptor(objectType: objectType, streamType: streamType, decoderSpecificInfo: decoderSpecificInfo)
    }

    /// The bare ES_Descriptor, as AudioToolbox expects for an AAC magic cookie.
    static func esDescriptor(objectType: UInt8, streamType: UInt8, decoderSpecificInfo: Data) -> Data {
        let specific = descriptor(tag: 0x05, payload: decoderSpecificInfo)
        var config = Data([objectType, streamType << 2 | 0x01, 0, 0, 0])
        config.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0]) // max / average bitrate (unknown)
        config.append(specific)
        let decoderConfig = descriptor(tag: 0x04, payload: config)
        let slConfig = descriptor(tag: 0x06, payload: Data([0x02]))
        return descriptor(tag: 0x03, payload: Data([0, 1, 0]) + decoderConfig + slConfig)
    }

    /// Reads the object type and decoder-specific info from an `esds` box payload.
    static func parse(_ box: Data) -> (objectType: UInt8, decoderSpecificInfo: Data?)? {
        let bytes = [UInt8](box)
        var objectType: UInt8?
        var specific: Data?

        /// Tag, payload start, and payload end of the descriptor at `index`.
        func descriptor(at index: Int) -> (tag: UInt8, start: Int, end: Int)? {
            guard index < bytes.count else { return nil }
            var at = index + 1
            var length = 0
            for _ in 0..<4 {
                guard at < bytes.count else { return nil }
                let byte = bytes[at]
                at += 1
                length = length << 7 | Int(byte & 0x7F)
                if byte & 0x80 == 0 { break }
            }
            return (bytes[index], at, min(at + length, bytes.count))
        }

        func walk(_ start: Int, _ end: Int) {
            var at = start
            while at < end, let item = descriptor(at: at) {
                switch item.tag {
                case 0x03: // ES_Descriptor: ES_ID, flags, optional fields, then children.
                    var inner = item.start + 2
                    guard inner < item.end else { break }
                    let flags = bytes[inner]
                    inner += 1
                    if flags & 0x80 != 0 { inner += 2 }
                    if flags & 0x40 != 0, inner < item.end { inner += 1 + Int(bytes[inner]) }
                    if flags & 0x20 != 0 { inner += 2 }
                    walk(inner, item.end)
                case 0x04: // DecoderConfigDescriptor: 13 fixed bytes, then children.
                    if item.start < item.end { objectType = bytes[item.start] }
                    walk(item.start + 13, item.end)
                case 0x05:
                    specific = Data(bytes[item.start..<item.end])
                default:
                    break
                }
                at = item.end
            }
        }

        walk(4, bytes.count) // Skip the box's version and flags.
        return objectType.map { ($0, specific) }
    }

    private static func descriptor(tag: UInt8, payload: Data) -> Data {
        // Four-byte expandable length, as written by most muxers.
        let length = payload.count
        return Data([tag, UInt8(0x80 | (length >> 21) & 0x7F), UInt8(0x80 | (length >> 14) & 0x7F),
                     UInt8(0x80 | (length >> 7) & 0x7F), UInt8(length & 0x7F)]) + payload
    }
}

// MARK: - Bits

nonisolated struct BitReader {
    private let bytes: [UInt8]
    private var bitPosition = 0

    init<S: Sequence>(_ data: S, removingEmulationPrevention: Bool = true) where S.Element == UInt8 {
        guard removingEmulationPrevention else {
            bytes = Array(data)
            return
        }
        // Remove H.264/HEVC emulation-prevention bytes (00 00 03).
        var clean: [UInt8] = []
        var zeros = 0
        for byte in data {
            if zeros >= 2, byte == 3 { zeros = 0; continue }
            zeros = byte == 0 ? zeros + 1 : 0
            clean.append(byte)
        }
        bytes = clean
    }

    mutating func bit() -> Int? {
        guard bitPosition < bytes.count * 8 else { return nil }
        defer { bitPosition += 1 }
        return Int(bytes[bitPosition / 8] >> (7 - bitPosition % 8)) & 1
    }

    mutating func unsignedExpGolomb() -> Int? {
        var zeros = 0
        while let bit = bit(), bit == 0 {
            zeros += 1
            if zeros > 31 { return nil }
        }
        var value = 0
        for _ in 0..<zeros {
            guard let bit = bit() else { return nil }
            value = value << 1 | bit
        }
        return (1 << zeros) - 1 + value
    }
}

// MARK: - VP9

nonisolated enum VP9 {
    /// Builds a `vpcC` box payload (version 1) from a keyframe's uncompressed header,
    /// for containers that don't store one (WebM usually doesn't).
    static func configuration(fromKeyframe data: Data, width: Int, height: Int) -> Data? {
        var bits = BitReader(rawBytes: [UInt8](data.prefix(32)))
        guard bits.read(2) == 2 else { return nil } // frame_marker
        let profileLow = bits.read(1) ?? 0
        let profileHigh = bits.read(1) ?? 0
        let profile = profileHigh << 1 | profileLow
        if profile == 3 { _ = bits.read(1) }
        guard bits.read(1) == 0, bits.read(1) == 0 else { return nil } // show_existing_frame, frame_type == KEY
        _ = bits.read(2) // show_frame, error_resilient_mode
        guard bits.read(24) == 0x49_83_42 else { return nil } // sync code

        var bitDepth = 8
        if profile >= 2 { bitDepth = bits.read(1) == 1 ? 12 : 10 }
        let colorSpace = bits.read(3) ?? 0
        var fullRange = 0
        var subsampling = 1 // 4:2:0, chroma co-located with luma
        if colorSpace != 7 {
            fullRange = bits.read(1) ?? 0
            if profile == 1 || profile == 3 {
                let x = bits.read(1) ?? 1
                let y = bits.read(1) ?? 1
                subsampling = x == 1 && y == 0 ? 2 : (x == 0 && y == 0 ? 3 : 1)
            }
        } else {
            fullRange = 1
            subsampling = 3
        }
        // Color space → matrix coefficients (ITU-T H.273); primaries/transfer follow.
        let matrix: UInt8 = switch colorSpace {
        case 1, 3: 6
        case 2: 1
        case 4: 7
        case 5: 9
        case 7: 0
        default: 2
        }
        let primaries: UInt8 = matrix == 9 ? 9 : (matrix == 6 ? 6 : 1)
        let level: UInt8 = max(width, height) > 2048 ? 51 : (max(width, height) > 1280 ? 41 : 31)
        return Data([1, 0, 0, 0, UInt8(profile), level,
                     UInt8(bitDepth << 4 | subsampling << 1 | fullRange),
                     primaries, primaries == 9 ? 16 : 1, matrix, 0, 0])
    }
}

// MARK: - FLAC

nonisolated enum FLAC {
    struct StreamInfo {
        let minBlockSize: Int
        let maxBlockSize: Int
        let sampleRate: Double
        let channels: Int
        let bitsPerSample: Int
    }

    /// The 34-byte STREAMINFO block from Matroska ("fLaC" + blocks) or MP4 (dfLa payload).
    static func streamInfoBlock(in config: Data) -> Data? {
        var bytes = [UInt8](config)
        if bytes.starts(with: Array("fLaC".utf8)) { bytes.removeFirst(4) }
        else if bytes.count > 4, bytes[0] == 0, bytes[1] == 0, bytes[2] == 0, bytes[3] == 0 { bytes.removeFirst(4) } // version/flags
        guard bytes.count >= 38, bytes[0] & 0x7F == 0 else { return nil } // block type 0 = STREAMINFO
        return Data(bytes[4..<38])
    }

    static func streamInfo(in config: Data) -> StreamInfo? {
        guard let block = streamInfoBlock(in: config) else { return nil }
        let b = [UInt8](block)
        let sampleRate = Int(b[10]) << 12 | Int(b[11]) << 4 | Int(b[12]) >> 4
        return StreamInfo(minBlockSize: Int(b[0]) << 8 | Int(b[1]), maxBlockSize: Int(b[2]) << 8 | Int(b[3]),
                          sampleRate: Double(sampleRate), channels: Int((b[12] >> 1) & 0x07) + 1,
                          bitsPerSample: Int((b[12] & 1) << 4 | b[13] >> 4) + 1)
    }

    /// The `dfLa` box AudioToolbox expects as the FLAC magic cookie.
    static func cookie(from config: Data) -> Data? {
        guard let block = streamInfoBlock(in: config) else { return nil }
        var payload = Data([0, 0, 0, 0])            // version / flags
        payload += Data([0x80, 0, 0, 34]) + block   // last-metadata-block flag, STREAMINFO, length 34
        let size = UInt32(8 + payload.count).bigEndian
        return withUnsafeBytes(of: size) { Data($0) } + Data("dfLa".utf8) + payload
    }

    /// Samples in a FLAC frame, from its header.
    static func blockSize(ofFrame data: Data, streamInfo: StreamInfo?) -> Int? {
        let b = [UInt8](data.prefix(16))
        guard b.count >= 5, b[0] == 0xFF, b[1] & 0xFE == 0xF8 else { return nil }
        let code = Int(b[2] >> 4)
        // Skip the UTF-8 coded frame/sample number to reach any explicit block size.
        var at = 4
        var lead = b[4]
        while lead & 0x80 != 0, at + 1 < b.count { at += 1; lead <<= 1 }
        at += 1
        switch code {
        case 1: return 192
        case 2...5: return 576 << (code - 2)
        case 6: return at < b.count ? Int(b[at]) + 1 : nil
        case 7: return at + 1 < b.count ? (Int(b[at]) << 8 | Int(b[at + 1])) + 1 : nil
        case 8...15: return 256 << (code - 8)
        default: return streamInfo?.maxBlockSize
        }
    }
}

// MARK: - Opus

nonisolated enum Opus {
    /// Samples (at 48 kHz) in an Opus packet, from its TOC byte and frame count code.
    static func packetDuration(_ data: Data) -> Int? {
        guard let toc = data.first else { return nil }
        let config = Int(toc >> 3)
        let frameSamples: Int
        switch config {
        case 0...11: frameSamples = [480, 960, 1920, 2880][config % 4]  // SILK: 10/20/40/60 ms
        case 12...15: frameSamples = [480, 960][config % 2]             // Hybrid: 10/20 ms
        default: frameSamples = [120, 240, 480, 960][config % 4]        // CELT: 2.5/5/10/20 ms
        }
        let frames: Int
        switch toc & 0x03 {
        case 0: frames = 1
        case 1, 2: frames = 2
        default:
            guard data.count > 1 else { return nil }
            frames = Int(data[data.startIndex + 1] & 0x3F)
        }
        return frameSamples * frames
    }
}

// MARK: - AMR

nonisolated enum AMR {
    /// Payload bytes per frame type (after the 1-byte header); nil = invalid / no data.
    private static let narrowband: [Int?] = [12, 13, 15, 17, 19, 20, 26, 31, 5, nil, nil, nil, nil, nil, nil, 0]
    private static let wideband: [Int?] = [17, 23, 32, 36, 40, 46, 50, 58, 60, 5, nil, nil, nil, nil, 0, 0]

    /// Splits a sample holding several storage-format frames into single frames.
    static func frames(in data: Data, wideband isWideband: Bool) -> [Data] {
        let table = isWideband ? wideband : narrowband
        var frames: [Data] = []
        var at = data.startIndex
        while at < data.endIndex {
            let type = Int(data[at] >> 3) & 0x0F
            guard let size = table[type] else { break }
            let end = at + 1 + size
            guard end <= data.endIndex else { break }
            frames.append(data.subdata(in: at..<end))
            at = end
        }
        return frames
    }
}

// MARK: - MPEG-1/2 video

nonisolated enum MPEGVideo {
    /// Picture size from a sequence header (00 00 01 B3).
    static func dimensions(in data: Data) -> (width: Int, height: Int)? {
        let b = [UInt8](data.prefix(4096))
        guard b.count >= 8 else { return nil }
        for i in 0..<(b.count - 7) where b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1 && b[i + 3] == 0xB3 {
            let width = Int(b[i + 4]) << 4 | Int(b[i + 5]) >> 4
            let height = Int(b[i + 5] & 0x0F) << 8 | Int(b[i + 6])
            return (width, height)
        }
        return nil
    }
}

nonisolated extension BitReader {
    /// A reader over bytes without H.264 emulation-prevention removal.
    init(rawBytes: [UInt8]) {
        self.init(rawBytes, removingEmulationPrevention: false)
    }

    mutating func read(_ count: Int) -> Int? {
        var value = 0
        for _ in 0..<count {
            guard let bit = bit() else { return nil }
            value = value << 1 | bit
        }
        return value
    }
}

// MARK: - Vorbis

/// Works out Vorbis packet durations, which depend on the block size of each packet and the
/// one before it. Block sizes come from the identification header and the mode table at the
/// end of the setup header.
nonisolated struct VorbisParser {
    private let blockSizes: (short: Int, long: Int)
    /// Whether each mode uses the long block.
    private let modeIsLong: [Bool]
    private let modeBits: Int
    private var previousBlock: Int?

    /// From the three header packets (identification, comment, setup).
    init?(headers: [Data]) {
        guard headers.count == 3 else { return nil }
        let id = [UInt8](headers[0])
        guard id.count >= 30, id[0] == 1, id[1...6].elementsEqual("vorbis".utf8) else { return nil }
        blockSizes = (1 << Int(id[28] & 0x0F), 1 << Int(id[28] >> 4))
        guard let modes = Self.modes(inSetup: [UInt8](headers[2])), !modes.isEmpty else { return nil }
        modeIsLong = modes
        var bits = 0
        while (1 << bits) < modes.count { bits += 1 }
        modeBits = bits
    }

    /// From Matroska-style codec private data (Xiph-laced headers).
    init?(xiphLaced data: Data) {
        guard let headers = Self.unlace(data) else { return nil }
        self.init(headers: headers)
    }

    /// Samples this audio packet completes; 0 for the first packet after a reset.
    mutating func duration(of packet: Data) -> Int? {
        guard let first = packet.first, first & 1 == 0 else { return nil } // Audio packets start with a 0 bit.
        let mode = modeBits == 0 ? 0 : Int(first >> 1) & ((1 << modeBits) - 1)
        guard mode < modeIsLong.count else { return nil }
        let block = modeIsLong[mode] ? blockSizes.long : blockSizes.short
        defer { previousBlock = block }
        guard let previousBlock else { return 0 }
        return (previousBlock + block) / 4
    }

    mutating func reset() {
        previousBlock = nil
    }

    /// Splits Xiph lacing: a count-minus-one byte, laced sizes for all but the last, then data.
    static func unlace(_ data: Data) -> [Data]? {
        let b = [UInt8](data)
        guard let first = b.first else { return nil }
        let count = Int(first) + 1
        var at = 1
        var sizes: [Int] = []
        for _ in 0..<(count - 1) {
            var size = 0
            while at < b.count {
                size += Int(b[at])
                at += 1
                if b[at - 1] != 255 { break }
            }
            sizes.append(size)
        }
        var headers: [Data] = []
        for size in sizes {
            guard at + size <= b.count else { return nil }
            headers.append(Data(b[at..<(at + size)]))
            at += size
        }
        headers.append(Data(b[at...]))
        return headers
    }

    /// Xiph lacing for a list of packets (the inverse of `unlace`).
    static func lace(_ packets: [Data]) -> Data {
        var out = Data([UInt8(packets.count - 1)])
        for packet in packets.dropLast() {
            var size = packet.count
            while size >= 255 { out.append(255); size -= 255 }
            out.append(UInt8(size))
        }
        for packet in packets { out.append(packet) }
        return out
    }

    /// Reads the mode block flags by walking the setup header backwards from its framing bit:
    /// each mode is 1 block flag, 16 + 16 zero bits, and an 8-bit mapping; the mode count
    /// (6 bits) precedes them.
    private static func modes(inSetup setup: [UInt8]) -> [Bool]? {
        // Vorbis packs bits LSB-first, so reversing the bytes and reading MSB-first walks the
        // stream backwards bit by bit.
        var reversed = BitReader(rawBytes: setup.reversed())
        var skipped = 0
        while let bit = reversed.bit() {
            skipped += 1
            if bit == 1 { break } // Framing bit.
        }
        var count = 0
        var lastValid = 0
        var probe = reversed
        while true {
            guard let mapping = probe.read(8), mapping < 64,
                  probe.read(16) == 0, probe.read(16) == 0, probe.read(1) != nil else { break }
            count += 1
            if count > 64 { break }
            var header = probe
            if let declared = header.read(6), declared + 1 == count { lastValid = count }
        }
        guard lastValid > 0 else { return nil }
        var flags = [Bool](repeating: false, count: lastValid)
        var walk = reversed
        for index in stride(from: lastValid - 1, through: 0, by: -1) {
            _ = walk.read(40)
            flags[index] = walk.read(1) == 1
        }
        _ = skipped
        return flags
    }
}
