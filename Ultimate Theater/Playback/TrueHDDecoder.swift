//
//  TrueHDDecoder.swift
//  Ultimate Theater
//
//  A lossless decoder for Dolby TrueHD and MLP (Meridian Lossless Packing), which
//  macOS doesn't decode. Access units become float PCM that the audio renderer plays
//  directly, bit-exact with the encoder's 24-bit input.
//
//  The access unit, major sync, substream directory and restart header follow Dolby's
//  "Dolby TrueHD (MLP) high-level bitstream description". That document stops short of
//  the block header and block data. For those (decoding parameters, primitive matrices,
//  FIR/IIR prediction filters, entropy codebooks, noise generation, output shifts and the
//  lossless check), FFmpeg's LGPL-2.1+ MLP decoder (libavcodec mlpdec.c, mlp.c, mlpdsp.c,
//  mlp_parse.c) served as the specification; this is an independent implementation. The
//  codebooks and noise table in TrueHDTables.swift are transcribed from it.
//  See THIRD_PARTY_NOTICES.md.
//
//  The decoder outputs the presentation with the most channels (up to eight). In Dolby
//  Atmos streams that's the 7.1 or 5.1 bed in substreams 0 to 2; substream 3 (objects) is
//  skipped. MLP is self-checking: restart headers carry a parity over all output since the
//  previous restart, and substreams carry a CRC. Failures are counted for diagnostics.
//

import CoreAudioTypes
import Foundation

// MARK: - Framing

/// Splits a byte stream (Matroska packets, or MPEG-TS / M2TS PES payloads) into TrueHD
/// or MLP access units. Synchronizes on a major sync (0xF8726FBA TrueHD, 0xF8726FBB
/// MLP), then follows the access unit lengths, checking each header's parity nibble.
/// The Dolby Digital frames that Blu-ray interleaves with TrueHD are skipped.
nonisolated struct TrueHDFramer {
    private var buffer: [UInt8] = []
    /// Substream count from the latest major sync, needed to check minor sync parity.
    private var substreams = 0
    private var synced = false

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        substreams = 0
        synced = false
    }

    /// Appends bytes and returns every complete access unit now available.
    mutating func push(_ data: Data) -> [Data] {
        buffer.append(contentsOf: data)
        var units: [Data] = []
        var position = 0
        buffer.withUnsafeBufferPointer { bytes in
            let count = bytes.count
            guard let base = bytes.baseAddress else { return }
            while true {
                if !synced {
                    switch Self.findMajorSync(base, count: count, from: position) {
                    case .found(let start):
                        position = start
                        synced = true
                    case .needMore(let start):
                        position = start
                        return
                    case .none:
                        position = max(position, count - 7)
                        return
                    }
                }
                guard position + 8 <= count else { return }
                let p = base + position
                if p[0] == 0x0B, p[1] == 0x77 {
                    // A Dolby Digital frame. No real access unit is long enough to start 0x0B77.
                    guard let length = Self.ac3FrameLength(p), length > 0 else {
                        synced = false
                        position += 1
                        continue
                    }
                    guard position + length <= count else { return }
                    position += length
                    continue
                }
                let length = (Int(p[0] & 0x0F) << 8 | Int(p[1])) * 2
                var headerSize = 0
                if TrueHDMajorSync.hasSync(p + 4, available: count - position - 4) {
                    guard let size = TrueHDMajorSync.size(p + 4, available: count - position - 4) else { return }
                    guard position + 4 + size <= count else { return }
                    guard let sync = TrueHDMajorSync(p + 4, available: size) else {
                        synced = false
                        position += 1
                        continue
                    }
                    substreams = sync.substreamCount
                    headerSize = size
                }
                guard substreams > 0, length >= 4 + headerSize + 2 * substreams else {
                    synced = false
                    position += 1
                    continue
                }
                guard position + length <= count else { return }
                guard TrueHDDecoder.headerParity(p, length: length, majorSyncSize: headerSize, substreams: substreams) else {
                    synced = false
                    position += 1
                    continue
                }
                units.append(Data(UnsafeBufferPointer(start: p, count: length)))
                position += length
            }
        }
        buffer.removeFirst(min(position, buffer.count))
        if buffer.count > 1 << 20 { buffer.removeAll() } // Garbage; resynchronize.
        return units
    }

    private enum Search { case found(Int), needMore(Int), none }

    /// Finds the next access unit that starts with a major sync whose CRC verifies.
    private static func findMajorSync(_ base: UnsafePointer<UInt8>, count: Int, from start: Int) -> Search {
        var index = start
        while index + 8 <= count {
            let p = base + index
            if TrueHDMajorSync.hasSync(p + 4, available: count - index - 4) {
                guard let size = TrueHDMajorSync.size(p + 4, available: count - index - 4),
                      index + 4 + size <= count else { return .needMore(index) }
                if TrueHDMajorSync(p + 4, available: size) != nil { return .found(index) }
            }
            index += 1
        }
        return .none
    }

    /// Length of the (E-)AC-3 frame at `p`, which has at least 8 readable bytes.
    private static func ac3FrameLength(_ p: UnsafePointer<UInt8>) -> Int? {
        if p[5] >> 3 > 10 { // E-AC-3: frmsiz in 16-bit words, minus one.
            return ((Int(p[2] & 0x07) << 8 | Int(p[3])) + 1) * 2
        }
        return AudioFramer.ac3FrameLength(fscod: Int(p[4] >> 6), frmsizecod: Int(p[4] & 0x3F))
    }
}

// MARK: - Major sync

/// The stream parameters of a major sync (`major_sync_info`, Dolby section 4.2).
nonisolated struct TrueHDMajorSync {
    var isMLP: Bool
    var sampleRate: Int
    /// Samples per access unit, and the next power of two (the noise buffer length).
    var accessUnitSize: Int
    var accessUnitSizePow2: Int
    /// Source word length: 16, 20 or 24 for MLP; TrueHD doesn't signal it (24).
    var bitDepth: Int
    var substreamCount: Int
    var substreamInfo: Int
    var flags: Int
    /// TrueHD 6- and 8-channel presentation channel assignments (tables 7 and 10).
    var sixChannelAssignment = 0
    var eightChannelAssignment = 0
    /// MLP channel arrangement (index into `TrueHDTables.mlpArrangements`).
    var mlpArrangement = 0
    /// Bytes of `major_sync_info`, including its CRC.
    var size: Int

    /// Whether `p` begins with the TrueHD or MLP format sync.
    static func hasSync(_ p: UnsafePointer<UInt8>, available: Int) -> Bool {
        available >= 4 && p[0] == 0xF8 && p[1] == 0x72 && p[2] == 0x6F && (p[3] == 0xBA || p[3] == 0xBB)
    }

    /// Size of the major sync at `p`, or nil if not enough bytes are available to tell.
    static func size(_ p: UnsafePointer<UInt8>, available: Int) -> Int? {
        guard available >= 28 else { return nil }
        // TrueHD may extend channel_meaning() (extra_channel_meaning_present, length).
        if p[3] == 0xBA, p[25] & 1 != 0 { return 28 + 2 + Int(p[26] >> 4) * 2 }
        return 28
    }

    /// Whether the major sync at `p` is complete and its `major_sync_info_CRC` (a CRC-16,
    /// x^16 + x^5 + x^3 + x^2 + 1, over everything before it) verifies.
    static func checksumMatches(_ p: UnsafePointer<UInt8>, available: Int) -> Bool {
        guard hasSync(p, available: available), let size = size(p, available: available), available >= size else {
            return false
        }
        return TrueHDCRC.crc16(p, count: size - 2) == UInt16(p[size - 2]) << 8 | UInt16(p[size - 1])
    }

    /// Parses a major sync, returning nil if it is malformed, unsupported, or its CRC fails.
    init?(_ p: UnsafePointer<UInt8>, available: Int) {
        guard Self.checksumMatches(p, available: available), let size = Self.size(p, available: available) else {
            return nil
        }
        var reader = TrueHDBitReader(p, bitOffset: 32, bitEnd: size * 8, byteCount: size)
        let rateCode: Int
        if p[3] == 0xBB {
            isMLP = true
            bitDepth = TrueHDTables.mlpWordLengths[reader.read(4)]
            let group2Depth = TrueHDTables.mlpWordLengths[reader.read(4)]
            rateCode = reader.read(4)
            let group2Rate = reader.read(4)
            reader.skip(11)
            mlpArrangement = reader.read(5)
            guard bitDepth > 0, group2Depth <= bitDepth, group2Rate == 0xF || group2Rate == rateCode,
                  mlpArrangement < TrueHDTables.mlpArrangements.count else { return nil }
        } else {
            isMLP = false
            bitDepth = 24
            rateCode = reader.read(4)
            reader.skip(4)                       // 6ch/8ch_multichannel_type, reserved
            reader.skip(2 + 2)                   // 2ch/6ch_presentation_channel_modifier
            sixChannelAssignment = reader.read(5)
            reader.skip(2)                       // 8ch_presentation_channel_modifier
            eightChannelAssignment = reader.read(13)
        }
        // Table 3: bit 3 selects the 44.1 kHz family; bits 0-2 double the rate.
        guard rateCode & 7 <= 2, rateCode != 0xF else { return nil }
        sampleRate = (rateCode & 8 != 0 ? 44_100 : 48_000) << (rateCode & 7)
        accessUnitSize = 40 << (rateCode & 7)
        accessUnitSizePow2 = 64 << (rateCode & 7)
        reader.skip(16)                          // signature (0xB752)
        flags = reader.read(16)
        reader.skip(16 + 1 + 15)                 // reserved, variable_rate, peak_data_rate
        substreamCount = reader.read(4)
        reader.skip(2 + 2)                       // reserved, extended_substream_info
        substreamInfo = reader.read(8)
        self.size = size
        guard substreamCount > 0, substreamCount <= (isMLP ? 2 : 4) else { return nil }
    }
}

// MARK: - Bit reading and checksums

/// A big-endian bit reader over a buffer that has at least 8 readable bytes past
/// `byteCount` (reads past the end of the data return padding, never other memory).
nonisolated struct TrueHDBitReader {
    let base: UnsafePointer<UInt8>
    var position: Int
    /// Bit position where the current segment ends.
    let end: Int
    private let lastByte: Int

    init(_ base: UnsafePointer<UInt8>, bitOffset: Int, bitEnd: Int, byteCount: Int) {
        self.base = base
        position = bitOffset
        end = bitEnd
        lastByte = byteCount
    }

    /// The next 57+ bits, left-aligned.
    @inline(__always) private func window() -> UInt64 {
        let byte = min(position >> 3, lastByte)
        let word = UnsafeRawPointer(base + byte).loadUnaligned(as: UInt64.self).bigEndian
        return word << UInt64(position & 7)
    }

    /// Peeks at the next `count` (1...32) bits without consuming them.
    @inline(__always) func peek(_ count: Int) -> Int {
        Int(truncatingIfNeeded: window() >> UInt64(64 - count))
    }

    /// Reads `count` (0...32) bits as an unsigned value.
    @inline(__always) mutating func read(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        let value = Int(truncatingIfNeeded: window() >> UInt64(64 - count))
        position += count
        return value
    }

    /// Reads `count` (1...32) bits as a two's complement value.
    @inline(__always) mutating func readSigned(_ count: Int) -> Int {
        let value = Int(truncatingIfNeeded: Int64(bitPattern: window()) >> Int64(64 - count))
        position += count
        return value
    }

    @inline(__always) mutating func bit() -> Bool { read(1) != 0 }
    @inline(__always) mutating func skip(_ count: Int) { position += count }
}

/// The checksums of the MLP syntax.
nonisolated enum TrueHDCRC {
    /// x^16 + x^5 + x^3 + x^2 + 1: `table[i]` is i·x^16 mod P.
    private static let table16: [UInt16] = (0..<256).map { index in
        var crc = UInt16(index) << 8
        for _ in 0..<8 { crc = crc & 0x8000 != 0 ? crc << 1 ^ 0x002D : crc << 1 }
        return crc
    }

    /// x^8 + x^6 + x^5 + x + 1: `table[i]` is i·x^8 mod P.
    private static let table8: [UInt8] = (0..<256).map { index in
        var crc = UInt8(index)
        for _ in 0..<8 { crc = crc & 0x80 != 0 ? crc << 1 ^ 0x63 : crc << 1 }
        return crc
    }

    /// The major sync CRC: each byte is shifted into a cleared 16-bit register (Dolby 4.2.10).
    static func crc16(_ p: UnsafePointer<UInt8>, count: Int) -> UInt16 {
        table16.withUnsafeBufferPointer { table in
            var crc: UInt16 = 0
            for index in 0..<count {
                crc = (crc << 8 | UInt16(p[index])) ^ table[Int(crc >> 8)]
            }
            return crc
        }
    }

    /// substream_CRC: the segment's bits shifted into a register preset to 0xA2 (Dolby 4.6.7).
    static func substreamCRC(_ p: UnsafePointer<UInt8>, count: Int) -> UInt8 {
        table8.withUnsafeBufferPointer { table in
            var crc: UInt8 = 0xA2
            for index in 0..<count { crc = table[Int(crc)] ^ p[index] }
            return crc
        }
    }

    /// restart_header_CRC: the header's bits shifted into a cleared register,
    /// modulo x^8 + x^4 + x^3 + x^2 + 1 (Dolby 4.7.2).
    static func restartCRC(_ p: UnsafePointer<UInt8>, bitOffset: Int, bitCount: Int) -> Int {
        var crc = 0
        for bit in bitOffset..<(bitOffset + bitCount) {
            crc = crc << 1 | Int(p[bit >> 3] >> (7 - UInt8(bit & 7)) & 1)
            if crc & 0x100 != 0 { crc ^= 0x11D }
        }
        return crc
    }

    /// Exclusive-OR of all the bytes.
    static func parity(_ p: UnsafePointer<UInt8>, count: Int) -> UInt8 {
        var value: UInt8 = 0
        for index in 0..<count { value ^= p[index] }
        return value
    }
}

// MARK: - Decoder

/// Decodes TrueHD and MLP access units (as `TrueHDFramer` returns them) into float PCM.
nonisolated final class TrueHDDecoder {
    /// Interleaved float PCM (±1.0 is 24-bit full scale) in `channels` order.
    struct Output {
        var samples: [Float]
        var frameCount: Int
        var sampleRate: Double
        var channels: [Speaker]
    }

    /// Output speakers. Samples are interleaved in ascending raw value order, so 5.1 is
    /// L R C LFE Ls Rs and 7.1 is L R C LFE Ls Rs Lrs Rrs (the SMPTE / CoreAudio
    /// `MPEG_7_1_C` order). Ls/Rs are the side surrounds of 5.1 and 7.1; Lrs/Rrs the rear.
    enum Speaker: Int, Comparable, CaseIterable {
        case left, right, center, lfe, leftSurround, rightSurround, leftRearSurround, rightRearSurround
        case centerSurround, leftCenter, rightCenter, leftWide, rightWide, leftSurroundDirect, rightSurroundDirect
        case topFrontLeft, topFrontRight, topFrontCenter, topCenter, topSideLeft, topSideRight, lfe2

        static func < (a: Speaker, b: Speaker) -> Bool { a.rawValue < b.rawValue }

        /// Short label, as Dolby and WAVE documentation write it.
        var label: String {
            switch self {
            case .left: "L"
            case .right: "R"
            case .center: "C"
            case .lfe: "LFE"
            case .leftSurround: "Ls"
            case .rightSurround: "Rs"
            case .leftRearSurround: "Lrs"
            case .rightRearSurround: "Rrs"
            case .centerSurround: "Cs"
            case .leftCenter: "Lc"
            case .rightCenter: "Rc"
            case .leftWide: "Lw"
            case .rightWide: "Rw"
            case .leftSurroundDirect: "Lsd"
            case .rightSurroundDirect: "Rsd"
            case .topFrontLeft: "Tfl"
            case .topFrontRight: "Tfr"
            case .topFrontCenter: "Tfc"
            case .topCenter: "Tc"
            case .topSideLeft: "Tsl"
            case .topSideRight: "Tsr"
            case .lfe2: "LFE2"
            }
        }

        /// The CoreAudio label for an `AudioChannelLayout` channel description.
        var channelLabel: AudioChannelLabel {
            switch self {
            case .left: kAudioChannelLabel_Left
            case .right: kAudioChannelLabel_Right
            case .center: kAudioChannelLabel_Center
            case .lfe: kAudioChannelLabel_LFEScreen
            case .leftSurround: kAudioChannelLabel_LeftSurround
            case .rightSurround: kAudioChannelLabel_RightSurround
            case .leftRearSurround: kAudioChannelLabel_RearSurroundLeft
            case .rightRearSurround: kAudioChannelLabel_RearSurroundRight
            case .centerSurround: kAudioChannelLabel_CenterSurround
            case .leftCenter: kAudioChannelLabel_LeftCenter
            case .rightCenter: kAudioChannelLabel_RightCenter
            case .leftWide: kAudioChannelLabel_LeftWide
            case .rightWide: kAudioChannelLabel_RightWide
            case .leftSurroundDirect: kAudioChannelLabel_LeftSurroundDirect
            case .rightSurroundDirect: kAudioChannelLabel_RightSurroundDirect
            case .topFrontLeft: kAudioChannelLabel_VerticalHeightLeft
            case .topFrontRight: kAudioChannelLabel_VerticalHeightRight
            case .topFrontCenter: kAudioChannelLabel_VerticalHeightCenter
            case .topCenter: kAudioChannelLabel_TopCenterSurround
            case .topSideLeft: kAudioChannelLabel_LeftTopMiddle
            case .topSideRight: kAudioChannelLabel_RightTopMiddle
            case .lfe2: kAudioChannelLabel_LFE2
            }
        }
    }

    /// Restart headers whose `lossless_check` disagreed with the decoded output.
    private(set) var losslessCheckFailures = 0
    /// Restart headers whose `lossless_check` was compared (passes plus failures).
    private(set) var losslessChecks = 0
    /// Failed checksums: major sync CRC, access unit header parity, restart header CRC,
    /// substream parity and CRC, and block length checks.
    private(set) var crcFailures = 0
    /// Checksums of those kinds that verified.
    private(set) var checksumsVerified = 0
    /// Access units that couldn't be decoded and were replaced with silence.
    private(set) var damagedUnits = 0

    /// Limits from the syntax: eight channels, 160 samples per access unit (40 at 48 kHz).
    private static let maxChannels = 8
    private static let maxBlockSize = 160
    private static let maxNoiseBuffer = 256

    private struct DecodeError: Error {}

    private var stream: TrueHDMajorSync?
    /// The substream whose output is the presentation, and which substreams it needs.
    private var target = 0
    private var decodedSubstreams = 0
    private let substreams = (0..<4).map { _ in TrueHDSubstream() }
    /// Output speakers (sorted) and the interleaved column of each output position.
    private var speakers: [Speaker] = []
    private var columnOfPosition = [Int](repeating: 0, count: maxChannels)
    private var layoutKey: [Int] = []

    /// Working buffers: samples [position][channel], bypassed LSBs [position][matrix],
    /// the 0x31EB noise buffer, and the prediction filter histories.
    private let sampleBuffer = UnsafeMutablePointer<Int32>.allocate(capacity: maxBlockSize * maxChannels)
    private let bypassBuffer = UnsafeMutablePointer<Int8>.allocate(capacity: maxBlockSize * maxChannels)
    private let noiseBuffer = UnsafeMutablePointer<Int8>.allocate(capacity: maxNoiseBuffer)
    private let firHistory = UnsafeMutablePointer<Int32>.allocate(capacity: maxBlockSize + 8)
    private let iirHistory = UnsafeMutablePointer<Int32>.allocate(capacity: maxBlockSize + 8)
    private let huffmanLookup = UnsafeMutablePointer<UInt16>.allocate(capacity: 3 << TrueHDTables.huffmanLookupBits)
    /// Per-block channel constants: codebook, LSB count and quantizer step (8 each), and offsets.
    private let blockConstants = UnsafeMutablePointer<Int>.allocate(capacity: 3 * maxChannels)
    private let blockOffsets = UnsafeMutablePointer<Int32>.allocate(capacity: maxChannels)
    private var unitBytes: [UInt8] = []
    /// Per access unit: how often the matrices and each filter changed (at most twice).
    private var matrixChanges = 0
    private var filterChanges = [Int](repeating: 0, count: 2 * maxChannels)

    init() {
        sampleBuffer.initialize(repeating: 0, count: Self.maxBlockSize * Self.maxChannels)
        bypassBuffer.initialize(repeating: 0, count: Self.maxBlockSize * Self.maxChannels)
        noiseBuffer.initialize(repeating: 0, count: Self.maxNoiseBuffer)
        firHistory.initialize(repeating: 0, count: Self.maxBlockSize + 8)
        iirHistory.initialize(repeating: 0, count: Self.maxBlockSize + 8)
        blockConstants.initialize(repeating: 0, count: 3 * Self.maxChannels)
        blockOffsets.initialize(repeating: 0, count: Self.maxChannels)
        for (book, table) in TrueHDTables.huffmanLookup.enumerated() {
            (huffmanLookup + book << TrueHDTables.huffmanLookupBits).initialize(from: table, count: table.count)
        }
    }

    deinit {
        sampleBuffer.deallocate()
        bypassBuffer.deallocate()
        noiseBuffer.deallocate()
        firHistory.deallocate()
        iirHistory.deallocate()
        huffmanLookup.deallocate()
        blockConstants.deallocate()
        blockOffsets.deallocate()
    }

    /// Forgets the stream (after a seek); decoding resumes at the next major sync.
    func reset() {
        stream = nil
        for substream in substreams {
            substream.restartSeen = false
            substream.losslessKnown = false
            substream.endOfStream = false
        }
    }

    /// Decodes one access unit. Returns nil before the first major sync (or restart) and
    /// for units that can't be interpreted; damaged units of a known stream come back as
    /// silence of the right length so timing holds.
    func decode(_ accessUnit: Data) -> Output? {
        let count = accessUnit.count
        unitBytes.removeAll(keepingCapacity: true)
        unitBytes.append(contentsOf: accessUnit)
        unitBytes.append(contentsOf: repeatElement(0, count: 16)) // Padding for the bit reader.
        return unitBytes.withUnsafeBufferPointer { bytes in
            guard let base = bytes.baseAddress else { return nil }
            do {
                return try decodeUnit(base, count: count)
            } catch {
                return damaged()
            }
        }
    }

    /// Silence for a damaged unit; decoding resumes at the next restart.
    private func damaged() -> Output? {
        damagedUnits += 1
        for substream in substreams {
            substream.restartSeen = false
            substream.losslessKnown = false
        }
        guard let stream, !speakers.isEmpty else { return nil }
        return Output(samples: [Float](repeating: 0, count: stream.accessUnitSize * speakers.count),
                      frameCount: stream.accessUnitSize, sampleRate: Double(stream.sampleRate), channels: speakers)
    }

    /// The access unit header's check nibble: the nibbles of the minor sync and the
    /// substream directory exclusive-OR to 0xF (Dolby 4.1.1).
    static func headerParity(_ p: UnsafePointer<UInt8>, length: Int, majorSyncSize: Int, substreams: Int) -> Bool {
        var parity = p[0] ^ p[1] ^ p[2] ^ p[3]
        var offset = 4 + majorSyncSize
        for _ in 0..<substreams {
            guard offset + 2 <= length else { return false }
            let extraWord = p[offset] & 0x80 != 0
            let size = extraWord ? 4 : 2
            guard offset + size <= length else { return false }
            parity ^= TrueHDCRC.parity(p + offset, count: size)
            offset += size
        }
        return (parity >> 4 ^ parity) & 0xF == 0xF
    }

    // MARK: Access unit

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func decodeUnit(_ p: UnsafePointer<UInt8>, count: Int) throws -> Output? {
        guard count >= 4 else {
            guard stream != nil else { return nil }
            throw DecodeError()
        }
        let length = (Int(p[0] & 0x0F) << 8 | Int(p[1])) * 2
        guard length >= 4, length <= count else { throw DecodeError() }

        var headerSize = 4
        let isMajorSync = TrueHDMajorSync.hasSync(p + 4, available: length - 4)
        if isMajorSync {
            let intact = TrueHDMajorSync.checksumMatches(p + 4, available: length - 4)
            if intact { checksumsVerified += 1 } else { crcFailures += 1 }
            guard let sync = TrueHDMajorSync(p + 4, available: length - 4) else {
                guard stream != nil else { return nil }
                throw DecodeError()
            }
            adopt(sync)
            headerSize += sync.size
        }
        guard let stream else { return nil }

        // Substream directory (Dolby 4.5).
        var ends = [Int](repeating: 0, count: stream.substreamCount)
        var crcPresent = [Bool](repeating: false, count: stream.substreamCount)
        var offset = headerSize
        for index in 0..<stream.substreamCount {
            guard offset + 2 <= length else { throw DecodeError() }
            let word = Int(p[offset]) << 8 | Int(p[offset + 1])
            offset += 2
            if word & 0x8000 != 0 { // extra_substream_word (dynamic range control)
                guard !stream.isMLP else { throw DecodeError() }
                offset += 2
            }
            // A major sync unit restarts every substream; other units restart none.
            guard (word & 0x4000 != 0) != isMajorSync else { throw DecodeError() }
            crcPresent[index] = word & 0x2000 != 0
            ends[index] = (word & 0xFFF) * 2
        }
        guard offset <= length else { throw DecodeError() }
        guard Self.headerParity(p, length: length, majorSyncSize: headerSize - 4, substreams: stream.substreamCount) else {
            crcFailures += 1
            throw DecodeError()
        }
        checksumsVerified += 1

        // Substream segments, each from the previous end to its own end.
        let dataStart = offset
        var segmentStart = 0
        for index in 0..<stream.substreamCount {
            let segmentEnd = min(ends[index], length - dataStart)
            guard segmentEnd >= segmentStart else { throw DecodeError() }
            defer { segmentStart = segmentEnd }
            guard index <= target else { break }
            guard decodedSubstreams & 1 << index != 0 else { continue }
            try decodeSubstream(index, p, start: dataStart + segmentStart, end: dataStart + segmentEnd,
                                byteCount: count, crcPresent: crcPresent[index], stream: stream)
        }

        let output = try outputPresentation(stream)
        for substream in substreams where substream.endOfStream {
            // The stream ends here; the next one starts with a fresh major sync.
            substream.endOfStream = false
            substream.losslessKnown = false
            self.stream = nil
        }
        return output
    }

    /// Takes the parameters of a major sync and chooses the presentation to decode.
    private func adopt(_ sync: TrueHDMajorSync) {
        stream = sync
        for substream in substreams { substream.restartSeen = false }
        let count = sync.substreamCount
        let info = sync.substreamInfo
        let eight = info >> 4 & 7, six = info >> 2 & 3
        if sync.isMLP {
            target = count - 1
            decodedSubstreams = (1 << count) - 1
        } else if count >= 3 && eight >= 4 {
            // Table 15: bits 4, 5 and 6 flag substreams 0, 1 and 2 of the 8-ch presentation.
            target = 2
            decodedSubstreams = eight & 3 | 4
        } else if count >= 2 && six >= 2 {
            // Table 14: the 6-ch presentation is substream 1, or substreams 0 and 1.
            target = 1
            decodedSubstreams = six == 3 ? 3 : 2
        } else if count == 1 || six == 1 {
            target = 0
            decodedSubstreams = 1
        } else {
            // Illegal substream_info: decode everything up to the third substream.
            target = min(count - 1, 2)
            decodedSubstreams = (1 << (target + 1)) - 1
        }
    }

    // MARK: Substream segment

    // swiftlint:disable:next function_body_length cyclomatic_complexity function_parameter_count
    private func decodeSubstream(_ index: Int, _ p: UnsafePointer<UInt8>, start: Int, end: Int, byteCount: Int,
                                 crcPresent: Bool, stream: TrueHDMajorSync) throws {
        let s = substreams[index]
        var reader = TrueHDBitReader(p, bitOffset: start * 8, bitEnd: end * 8, byteCount: byteCount)
        matrixChanges = 0
        for channel in filterChanges.indices { filterChanges[channel] = 0 }
        s.blockPosition = 0

        repeat { // block() (Dolby 4.7)
            if reader.bit() { // block_header_exists
                if reader.bit() { // restart_header_exists
                    try readRestartHeader(&reader, s, index: index, stream: stream)
                    s.restartSeen = true
                }
                guard s.restartSeen else { return }
                try readDecodingParameters(&reader, s, stream: stream)
            }
            guard s.restartSeen else { return }
            // An earlier substream whose channels the presentation's substream recodes.
            if index != target, s.codedChannels & substreams[target].codedChannels != 0 { return }
            try readBlockData(&reader, s, stream: stream)
            guard reader.position < reader.end else { throw DecodeError() }
        } while !reader.bit() // last_block_in_segment

        reader.skip((start * 8 - reader.position) & 15) // pad to 16 bits
        if reader.end - reader.position >= 32 {
            // The stream's last access unit: terminatorA, then the zero-sample count.
            guard reader.read(16) == 0xD234 else { throw DecodeError() }
            let terminator = reader.read(16)
            if !stream.isMLP, terminator & 0x2000 != 0 {
                s.blockPosition -= min(terminator & 0x1FFF, s.blockPosition)
            } else if stream.isMLP, terminator != 0xD234 {
                throw DecodeError()
            }
            s.endOfStream = true
        }
        if crcPresent {
            guard reader.end - reader.position == 16 else { throw DecodeError() }
            let segment = end - start - 2
            let parity = TrueHDCRC.parity(p + start, count: segment)
            let crc = TrueHDCRC.substreamCRC(p + start, count: segment)
            guard UInt8(reader.read(8)) ^ parity == 0xA9, UInt8(reader.read(8)) == crc else {
                crcFailures += 1
                throw DecodeError()
            }
            checksumsVerified += 1
        }
        guard reader.position == reader.end else { throw DecodeError() }
    }

    /// restart_header() (Dolby 4.7.2): channel ranges, noise seed, lossless check and
    /// channel assignment. Decoding parameters return to their defaults.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func readRestartHeader(_ reader: inout TrueHDBitReader, _ s: TrueHDSubstream, index: Int,
                                   stream: TrueHDMajorSync) throws {
        let start = reader.position
        // 0x31EA, 0x31EB (noise type 1) or 0x31EC (Atmos objects, never decoded here).
        guard reader.read(13) == 0x31EA >> 1 else { throw DecodeError() }
        let noiseType = reader.read(1)
        guard !(stream.isMLP && noiseType != 0) else { throw DecodeError() }
        reader.skip(16)                                  // output_timing
        let minChannel = reader.read(4)
        let maxChannel = reader.read(4)
        let maxMatrixChannel = reader.read(4)
        guard maxMatrixChannel <= (stream.isMLP ? 5 : 7),
              noiseType == 1 || maxMatrixChannel <= 5,    // two noise channels must fit
              minChannel <= maxChannel + 1,               // a substream may code no channels
              maxChannel < Self.maxChannels else { throw DecodeError() }
        let noiseShift = reader.read(4)
        let noiseSeed = UInt32(reader.read(23))
        reader.skip(4 + 5 + 5 + 5)                       // max_shift, max_lsbs, max_bits ×2
        let errorProtect = reader.bit()
        let losslessCheck = reader.read(8)
        reader.skip(16)
        var assignment = [Int](repeating: 0, count: Self.maxChannels)
        for channel in 0...maxMatrixChannel {
            let position = reader.read(6)
            guard position <= maxMatrixChannel else { throw DecodeError() }
            assignment[position] = channel
        }
        let crc = TrueHDCRC.restartCRC(reader.base, bitOffset: start, bitCount: reader.position - start)
        guard reader.read(8) == crc else {
            crcFailures += 1
            throw DecodeError()
        }
        checksumsVerified += 1

        // The check covers everything output since the previous restart.
        if index == target, s.losslessKnown {
            losslessChecks += 1
            var folded = s.losslessData
            folded ^= folded >> 16
            folded ^= folded >> 8
            if Int(folded & 0xFF) != losslessCheck { losslessCheckFailures += 1 }
        }

        s.noiseType = noiseType
        s.minChannel = minChannel
        s.maxChannel = maxChannel
        s.codedChannels = ((1 << (maxChannel - minChannel + 1)) - 1) << minChannel
        s.maxMatrixChannel = maxMatrixChannel
        s.noiseShift = noiseShift
        s.noiseSeed = noiseSeed
        s.errorProtect = errorProtect
        s.assignment = assignment
        s.parameterPresence = 0xFF
        s.matrixCount = 0
        s.blockSize = 8
        s.losslessData = 0
        s.losslessKnown = true
        for channel in 0..<Self.maxChannels {
            s.outputShift[channel] = 0
            s.quantStep[channel] = 0
        }
        for channel in minChannel..<(maxChannel + 1) {
            s.firOrder[channel] = 0
            s.iirOrder[channel] = 0
            s.firShift[channel] = 0
            s.iirShift[channel] = 0
            s.huffOffset[channel] = 0
            s.signHuffOffset[channel] = -(1 << 23)
            s.codebook[channel] = 0
            s.huffLSBs[channel] = 24 // Raw 24-bit PCM.
        }
        if index == target { updateLayout(s, stream: stream) }
    }

    /// The block header: which parameters changed, then the new values.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func readDecodingParameters(_ reader: inout TrueHDBitReader, _ s: TrueHDSubstream,
                                        stream: TrueHDMajorSync) throws {
        let presence = 0x01, huffOffset = 0x02, iir = 0x04, fir = 0x08
        let quantStep = 0x10, outputShift = 0x20, matrix = 0x40, blockSize = 0x80
        if s.parameterPresence & presence != 0, reader.bit() {
            s.parameterPresence = reader.read(8)
        }
        if s.parameterPresence & blockSize != 0, reader.bit() {
            let size = reader.read(9)
            guard size >= 8, size <= stream.accessUnitSize else { throw DecodeError() }
            s.blockSize = size
        }
        if s.parameterPresence & matrix != 0, reader.bit() {
            try readMatrixParameters(&reader, s, stream: stream)
        }
        if s.parameterPresence & outputShift != 0, reader.bit() {
            for channel in 0...s.maxMatrixChannel {
                s.outputShift[channel] = max(0, reader.readSigned(4)) // Negative shifts are unknown.
            }
        }
        var changed = 0
        if s.parameterPresence & quantStep != 0, reader.bit() {
            for channel in 0...s.maxChannel {
                s.quantStep[channel] = reader.read(4)
                changed |= 1 << channel
            }
        }
        for channel in s.minChannel..<(s.maxChannel + 1) {
            guard reader.bit() else { continue }
            changed |= 1 << channel
            // Channel parameters: filters, Huffman offset, codebook and LSB count.
            if s.parameterPresence & fir != 0, reader.bit() {
                try readFilter(&reader, s, channel: channel, isIIR: false)
            }
            if s.parameterPresence & iir != 0, reader.bit() {
                try readFilter(&reader, s, channel: channel, isIIR: true)
            }
            guard s.firOrder[channel] + s.iirOrder[channel] <= 8,
                  s.firOrder[channel] == 0 || s.iirOrder[channel] == 0
                    || s.firShift[channel] == s.iirShift[channel] else { throw DecodeError() }
            if s.parameterPresence & huffOffset != 0, reader.bit() {
                s.huffOffset[channel] = reader.readSigned(15)
            }
            s.codebook[channel] = reader.read(2)
            s.huffLSBs[channel] = reader.read(5)
            guard s.codebook[channel] == 0 || s.huffLSBs[channel] <= 24 else { throw DecodeError() }
        }
        // The offset that recentres each residual, given its codebook and LSB count.
        for channel in 0...s.maxChannel where changed & 1 << channel != 0 {
            let codebook = s.codebook[channel]
            guard codebook == 0 || s.huffLSBs[channel] >= s.quantStep[channel] else { throw DecodeError() }
            let lsbBits = s.huffLSBs[channel] - s.quantStep[channel]
            let signShift = lsbBits + (codebook > 0 ? 2 - codebook : -1)
            var offset = s.huffOffset[channel]
            if codebook > 0 { offset -= 7 << lsbBits }
            if signShift >= 0 { offset -= 1 << signShift }
            s.signHuffOffset[channel] = Int32(truncatingIfNeeded: offset)
        }
    }

    /// Primitive matrices: each replaces one channel by a weighted sum of all channels
    /// (2.14 fixed point), plus noise and optionally a bypassed LSB from the stream.
    private func readMatrixParameters(_ reader: inout TrueHDBitReader, _ s: TrueHDSubstream,
                                      stream: TrueHDMajorSync) throws {
        matrixChanges += 1
        guard matrixChanges <= 2 else { throw DecodeError() }
        let count = reader.read(4)
        guard count <= (stream.isMLP ? 6 : 8) else {
            s.matrixCount = 0
            throw DecodeError()
        }
        let inputs = s.maxMatrixChannel + (s.noiseType == 0 ? 2 : 0)
        for matrix in 0..<count {
            let outputChannel = reader.read(4)
            let fractionBits = reader.read(4)
            s.lsbBypass[matrix] = reader.bit()
            guard outputChannel <= s.maxMatrixChannel, fractionBits <= 14 else {
                s.matrixCount = 0
                throw DecodeError()
            }
            s.matrixOutput[matrix] = outputChannel
            for channel in 0..<Self.maxChannels {
                var coefficient = 0
                if channel <= inputs, reader.bit() {
                    coefficient = reader.readSigned(fractionBits + 2) << (14 - fractionBits)
                }
                s.matrixCoefficients[matrix * Self.maxChannels + channel] = Int32(coefficient)
            }
            s.matrixNoiseShift[matrix] = s.noiseType != 0 ? reader.read(4) : 0
        }
        s.matrixCount = count
    }

    /// A FIR (up to 8 taps) or IIR (up to 4 taps) prediction filter.
    private func readFilter(_ reader: inout TrueHDBitReader, _ s: TrueHDSubstream, channel: Int, isIIR: Bool) throws {
        let slot = channel * 2 + (isIIR ? 1 : 0)
        filterChanges[slot] += 1
        guard filterChanges[slot] <= 2 else { throw DecodeError() }
        let order = reader.read(4)
        guard order <= (isIIR ? 4 : 8) else { throw DecodeError() }
        if isIIR { s.iirOrder[channel] = order } else { s.firOrder[channel] = order }
        guard order > 0 else { return }
        let shift = reader.read(4)
        let coefficientBits = reader.read(5)
        let coefficientShift = reader.read(3)
        guard coefficientBits >= 1, coefficientBits <= 16, coefficientBits + coefficientShift <= 16 else {
            throw DecodeError()
        }
        if isIIR { s.iirShift[channel] = shift } else { s.firShift[channel] = shift }
        for tap in 0..<order {
            let coefficient = Int32(reader.readSigned(coefficientBits) << coefficientShift)
            if isIIR {
                s.iirCoefficients[channel * 4 + tap] = coefficient
            } else {
                s.firCoefficients[channel * 8 + tap] = coefficient
            }
        }
        if reader.bit() { // Initial filter state (IIR only).
            guard isIIR else { throw DecodeError() }
            let stateBits = reader.read(4)
            let stateShift = reader.read(4)
            for tap in 0..<order {
                s.iirState[channel * 4 + tap] = stateBits > 0 ? Int32(reader.readSigned(stateBits) << stateShift) : 0
            }
        }
    }

    // MARK: Block data

    /// Reads a block of residuals (Huffman-coded MSBs and plain LSBs per channel) and
    /// runs each channel's prediction filter over it.
    // swiftlint:disable:next function_body_length
    private func readBlockData(_ reader: inout TrueHDBitReader, _ s: TrueHDSubstream, stream: TrueHDMajorSync) throws {
        var expectedEnd = 0
        if s.errorProtect { expectedEnd = reader.position + reader.read(16) } // block_data_bits
        let blockSize = s.blockSize, first = s.blockPosition
        guard first + blockSize <= stream.accessUnitSize else { throw DecodeError() }
        let stride = Self.maxChannels
        let samples = sampleBuffer, bypass = bypassBuffer, lookup = huffmanLookup
        (bypass + first * stride).update(repeating: 0, count: blockSize * stride)

        // Per-channel decoding constants, gathered once per block.
        let minChannel = s.minChannel, maxChannel = s.maxChannel
        let book = blockConstants, lsb = blockConstants + 8, quant = blockConstants + 16, offset = blockOffsets
        for channel in minChannel..<(maxChannel + 1) {
            book[channel] = s.codebook[channel]
            lsb[channel] = s.huffLSBs[channel] - s.quantStep[channel]
            quant[channel] = s.quantStep[channel]
            offset[channel] = s.signHuffOffset[channel]
        }
        var bypassMask = 0
        for matrix in 0..<s.matrixCount where s.lsbBypass[matrix] { bypassMask |= 1 << matrix }
        let matrixCount = s.matrixCount
        var failed = false
        for position in first..<(first + blockSize) {
            let row = position * stride
            if bypassMask != 0 {
                for matrix in 0..<matrixCount where bypassMask & 1 << matrix != 0 {
                    bypass[row + matrix] = Int8(reader.read(1))
                }
            }
            for channel in minChannel..<(maxChannel + 1) {
                var value: Int32 = 0
                let codebook = book[channel]
                if codebook > 0 {
                    let entry = lookup[(codebook - 1) << TrueHDTables.huffmanLookupBits + reader.peek(9)]
                    if entry == 0 { failed = true }
                    reader.skip(Int(entry & 15))
                    value = Int32(entry >> 4)
                }
                let bits = lsb[channel]
                if bits > 0 { value = value << Int32(bits) | Int32(truncatingIfNeeded: reader.read(bits)) }
                samples[row + channel] = (value &+ offset[channel]) &<< Int32(quant[channel])
            }
        }
        guard !failed else { throw DecodeError() }

        for channel in minChannel..<(maxChannel + 1) { filter(s, channel: channel, first: first, count: blockSize) }
        s.blockPosition += blockSize

        if s.errorProtect {
            // FFmpeg measures block_data_bits from before the field itself; accept either reading.
            if reader.position != expectedEnd, reader.position != expectedEnd + 16 {
                crcFailures += 1
            } else {
                checksumsVerified += 1
            }
            reader.skip(8) // block_header_CRC (algorithm unpublished; not verified)
        }
    }

    /// Prediction: each sample is its residual plus a FIR filter over previous output
    /// and an IIR filter over previous prediction errors, quantized to the channel's step.
    private func filter(_ s: TrueHDSubstream, channel: Int, first: Int, count: Int) {
        let firOrder = s.firOrder[channel], iirOrder = s.iirOrder[channel]
        let shift = Int64(firOrder > 0 ? s.firShift[channel] : s.iirShift[channel])
        let mask = Int32(truncatingIfNeeded: -1 << s.quantStep[channel])
        let stride = Self.maxChannels
        let fir = firHistory, iir = iirHistory, base = 8
        // History runs forward in time: index base - 1 is the newest sample before the block.
        for tap in 0..<8 { fir[base - 1 - tap] = s.firState[channel * 8 + tap] }
        for tap in 0..<4 { iir[base - 1 - tap] = s.iirState[channel * 4 + tap] }
        s.firCoefficients.withUnsafeBufferPointer { firCoefficients in
            s.iirCoefficients.withUnsafeBufferPointer { iirCoefficients in
                let a = firCoefficients.baseAddress! + channel * 8
                let b = iirCoefficients.baseAddress! + channel * 4
                var sample = sampleBuffer + first * stride + channel
                for index in 0..<count {
                    var accumulator: Int64 = 0
                    let newest = base + index - 1
                    for tap in 0..<firOrder { accumulator &+= Int64(fir[newest - tap]) &* Int64(a[tap]) }
                    for tap in 0..<iirOrder { accumulator &+= Int64(iir[newest - tap]) &* Int64(b[tap]) }
                    accumulator >>= shift
                    let result = Int32(truncatingIfNeeded: accumulator &+ Int64(sample.pointee)) & mask
                    fir[base + index] = result
                    iir[base + index] = Int32(truncatingIfNeeded: Int64(result) &- accumulator)
                    sample.pointee = result
                    sample += stride
                }
            }
        }
        for tap in 0..<8 { s.firState[channel * 8 + tap] = fir[base + count - 1 - tap] }
        for tap in 0..<4 { s.iirState[channel * 4 + tap] = iir[base + count - 1 - tap] }
    }

    // MARK: Output

    /// Rematrixes the presentation's substream and interleaves its channels as float.
    // swiftlint:disable:next function_body_length
    private func outputPresentation(_ stream: TrueHDMajorSync) throws -> Output? {
        let s = substreams[target]
        guard s.restartSeen else {
            // Joined mid-stream: wait for a restart. After damage, keep time with silence.
            guard !speakers.isEmpty else { return nil }
            throw DecodeError()
        }
        let frames = s.blockPosition
        guard frames > 0, speakers.count == s.maxMatrixChannel + 1 else { throw DecodeError() }
        let stride = Self.maxChannels
        let samples = sampleBuffer
        var inputs = s.maxMatrixChannel

        if s.noiseType == 0 {
            // Two pseudo-random noise channels above the matrix channels.
            var seed = s.noiseSeed
            let shift = Int32(s.noiseShift)
            for position in 0..<frames {
                let shifted = seed >> 7
                samples[position * stride + inputs + 1] = Int32(Int8(truncatingIfNeeded: seed >> 15)) << shift
                samples[position * stride + inputs + 2] = Int32(Int8(truncatingIfNeeded: shifted)) << shift
                seed = seed << 16 ^ (shifted & 0xFFFF) ^ (shifted & 0xFFFF) << 5
            }
            s.noiseSeed = seed
            inputs += 2
        } else {
            // A buffer of table noise, read with a different stride by each matrix.
            var seed = s.noiseSeed
            TrueHDTables.noise.withUnsafeBufferPointer { table in
                for index in 0..<stream.accessUnitSizePow2 {
                    let shifted = seed >> 15 & 0xFF
                    noiseBuffer[index] = table[Int(shifted)]
                    seed = seed << 8 ^ shifted ^ shifted << 5
                }
            }
            s.noiseSeed = seed
        }

        // Primitive matrices, in order.
        let noiseMask = stream.accessUnitSizePow2 - 1
        s.matrixCoefficients.withUnsafeBufferPointer { allCoefficients in
            for matrix in 0..<s.matrixCount {
                let coefficients = allCoefficients.baseAddress! + matrix * stride
                let output = s.matrixOutput[matrix]
                let mask = Int64(-1 << s.quantStep[output])
                let noiseShift = s.matrixNoiseShift[matrix]
                var noiseIndex = s.matrixCount - matrix
                let noiseStep = 2 * noiseIndex + 1
                for position in 0..<frames {
                    let row = samples + position * stride
                    var accumulator: Int64 = 0
                    for channel in 0...inputs { accumulator &+= Int64(row[channel]) &* Int64(coefficients[channel]) }
                    if noiseShift != 0 {
                        noiseIndex &= noiseMask
                        accumulator &+= Int64(noiseBuffer[noiseIndex]) << (noiseShift + 7)
                        noiseIndex += noiseStep
                    }
                    row[output] = Int32(truncatingIfNeeded: (accumulator >> 14) & mask)
                        &+ Int32(bypassBuffer[position * stride + matrix])
                }
            }
        }

        // Interleave, applying output shifts and accumulating the lossless check.
        let channelCount = speakers.count
        var pcm = [Float](repeating: 0, count: frames * channelCount)
        var check = s.losslessData
        let scale = Float(1) / Float(1 << 23)
        pcm.withUnsafeMutableBufferPointer { out in
            for position in 0...s.maxMatrixChannel {
                let channel = s.assignment[position]
                let shift = Int32(s.outputShift[channel])
                let column = columnOfPosition[position]
                var source = samples + channel
                var destination = out.baseAddress! + column
                for _ in 0..<frames {
                    let sample = source.pointee &<< shift
                    check ^= (UInt32(bitPattern: sample) & 0xFF_FFFF) << UInt32(channel)
                    destination.pointee = Float(sample) * scale
                    source += stride
                    destination += channelCount
                }
            }
        }
        s.losslessData = check
        return Output(samples: pcm, frameCount: frames, sampleRate: Double(stream.sampleRate), channels: speakers)
    }

    /// Works out the speaker at each output position of the presentation's substream:
    /// Dolby's channel assignment fields list speakers in bitstream order, and the restart
    /// header's `ch_assign` maps each matrix channel to one of those positions.
    private func updateLayout(_ s: TrueHDSubstream, stream: TrueHDMajorSync) {
        let count = s.maxMatrixChannel + 1
        let key = [count, target, stream.isMLP ? 1 : 0, stream.mlpArrangement, stream.sixChannelAssignment,
                   stream.eightChannelAssignment, stream.flags]
        guard key != layoutKey else { return }
        layoutKey = key

        func assigned(_ bits: Int) -> [Speaker] {
            var list: [Speaker] = []
            for (bit, group) in TrueHDTables.assignmentSpeakers.enumerated() where bits & 1 << bit != 0 {
                if bit == 4, stream.flags & 0x0800 != 0 { list += [.topSideLeft, .topSideRight] } else { list += group }
            }
            return list
        }
        let fallback: [[Speaker]] = [
            [.center], [.left, .right], [.left, .right, .center], [.left, .right, .leftSurround, .rightSurround],
            [.left, .right, .center, .leftSurround, .rightSurround],
            [.left, .right, .center, .lfe, .leftSurround, .rightSurround],
            [.left, .right, .center, .lfe, .leftSurround, .rightSurround, .centerSurround],
            [.left, .right, .center, .lfe, .leftSurround, .rightSurround, .leftRearSurround, .rightRearSurround],
        ]
        var candidates: [[Speaker]]
        if stream.isMLP {
            // With two MLP substreams, the first is a stereo downmix.
            candidates = target == 0 && stream.substreamCount > 1
                ? [[.left, .right]] : [TrueHDTables.mlpArrangements[stream.mlpArrangement]]
        } else {
            let six = assigned(stream.sixChannelAssignment), eight = assigned(stream.eightChannelAssignment)
            switch target {
            case 0: candidates = [fallback[min(count, 2) - 1], six, eight]
            case 1: candidates = [six, eight]
            default: candidates = [eight, six]
            }
        }
        let layout = candidates.first { $0.count == count } ?? fallback[count - 1]
        // Interleave in ascending speaker order (stable for any repeated speaker).
        let order = layout.indices.sorted { (layout[$0], $0) < (layout[$1], $1) }
        speakers = order.map { layout[$0] }
        for (column, position) in order.enumerated() { columnOfPosition[position] = column }
    }
}

// MARK: - Substream state

/// Decoding state of one substream: restart header values and current parameters.
nonisolated private final class TrueHDSubstream {
    var restartSeen = false
    var endOfStream = false
    /// 0: restart sync 0x31EA, two generated noise channels; 1: 0x31EB, table noise.
    var noiseType = 0
    var minChannel = 0
    var maxChannel = 0
    var maxMatrixChannel = 0
    var codedChannels = 0
    var noiseShift = 0
    var noiseSeed: UInt32 = 0
    var errorProtect = false
    /// Matrix channel for each output position.
    var assignment = [Int](repeating: 0, count: 8)
    var parameterPresence = 0xFF
    var blockSize = 8
    var blockPosition = 0
    /// Running exclusive-OR of the output since the restart (`losslessKnown` once seen).
    var losslessData: UInt32 = 0
    var losslessKnown = false

    var matrixCount = 0
    var matrixOutput = [Int](repeating: 0, count: 8)
    var lsbBypass = [Bool](repeating: false, count: 8)
    var matrixCoefficients = [Int32](repeating: 0, count: 64)
    var matrixNoiseShift = [Int](repeating: 0, count: 8)
    var quantStep = [Int](repeating: 0, count: 8)
    var outputShift = [Int](repeating: 0, count: 8)

    // Per channel.
    var firOrder = [Int](repeating: 0, count: 8)
    var iirOrder = [Int](repeating: 0, count: 8)
    var firShift = [Int](repeating: 0, count: 8)
    var iirShift = [Int](repeating: 0, count: 8)
    var firCoefficients = [Int32](repeating: 0, count: 64)
    var iirCoefficients = [Int32](repeating: 0, count: 32)
    var firState = [Int32](repeating: 0, count: 64)
    var iirState = [Int32](repeating: 0, count: 32)
    var huffOffset = [Int](repeating: 0, count: 8)
    var signHuffOffset = [Int32](repeating: 0, count: 8)
    var codebook = [Int](repeating: 0, count: 8)
    var huffLSBs = [Int](repeating: 24, count: 8)
}
