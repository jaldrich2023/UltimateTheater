//
//  BroadcastAudio.swift
//  Ultimate Theater
//
//  Audio framings used in broadcast transport streams: AAC in LOAS/LATM (common in
//  DVB-T2 and ISDB) and Opus in MPEG-TS. Both are unwrapped into plain codec packets.
//

import Foundation

/// Reads bits most-significant first, tracking the position for byte-aligned payloads.
nonisolated struct BitCursor {
    let bytes: [UInt8]
    private(set) var position = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { bytes.count * 8 - position }

    mutating func read(_ count: Int) -> Int? {
        guard count <= remaining else { return nil }
        var value = 0
        for _ in 0..<count {
            value = value << 1 | Int(bytes[position / 8] >> (7 - UInt8(position % 8))) & 1
            position += 1
        }
        return value
    }

    mutating func skip(_ count: Int) { position = min(position + count, bytes.count * 8) }

    /// `count` whole bytes starting at the current (possibly unaligned) bit position.
    mutating func readBytes(_ count: Int) -> [UInt8]? {
        guard count * 8 <= remaining else { return nil }
        return (0..<count).map { _ in UInt8(read(8)!) }
    }

    /// Bits from `start` to the current position, packed into bytes (zero-padded).
    func bits(from start: Int) -> [UInt8] {
        var copy = BitCursor(bytes)
        copy.position = start
        var out: [UInt8] = []
        var left = position - start
        while left > 0 {
            let take = min(8, left)
            out.append(UInt8(copy.read(take)! << (8 - take)))
            left -= take
        }
        return out
    }
}

// MARK: - AAC in LOAS/LATM

/// Unwraps AAC from LOAS/LATM (ISO/IEC 14496-3 §1.7): each sync frame carries an
/// AudioMuxElement whose StreamMuxConfig holds the AudioSpecificConfig.
nonisolated struct LATMParser {
    private(set) var audioSpecificConfig: Data?
    private(set) var sampleRate: Double?
    private(set) var channels: Int?
    private var muxVersion = 0
    private var muxVersionA = 0
    private var subFrames = 0
    private var buffer: [UInt8] = []

    /// Raw AAC frames from the bytes so far; partial sync frames wait for more data.
    mutating func frames(in data: Data) -> [Data] {
        buffer += data
        var frames: [Data] = []
        var i = 0
        while i + 3 <= buffer.count {
            guard buffer[i] == 0x56, buffer[i + 1] & 0xE0 == 0xE0 else { i += 1; continue }
            let length = Int(buffer[i + 1] & 0x1F) << 8 | Int(buffer[i + 2])
            guard i + 3 + length <= buffer.count else { break }
            frames += audioMuxElement(Array(buffer[(i + 3)..<(i + 3 + length)]))
            i += 3 + length
        }
        buffer.removeFirst(i)
        if buffer.count > 1 << 16 { buffer.removeAll() }
        return frames
    }

    mutating func reset() { buffer.removeAll() }

    private mutating func audioMuxElement(_ element: [UInt8]) -> [Data] {
        var r = BitCursor(element)
        guard let useSame = r.read(1) else { return [] }
        if useSame == 0 {
            guard streamMuxConfig(&r) else { return [] }
        }
        guard audioSpecificConfig != nil, muxVersionA == 0 else { return [] }
        var payloads: [Data] = []
        for _ in 0...subFrames {
            var length = 0
            while let value = r.read(8) {
                length += value
                if value != 255 { break }
            }
            guard let payload = r.readBytes(length) else { break }
            payloads.append(Data(payload))
        }
        return payloads
    }

    private static func latmValue(_ r: inout BitCursor) -> Int {
        let bytes = r.read(2) ?? 0
        var value = 0
        for _ in 0...bytes { value = value << 8 | (r.read(8) ?? 0) }
        return value
    }

    private mutating func streamMuxConfig(_ r: inout BitCursor) -> Bool {
        muxVersion = r.read(1) ?? 0
        muxVersionA = muxVersion == 1 ? (r.read(1) ?? 0) : 0
        guard muxVersionA == 0 else { return false }
        if muxVersion == 1 { _ = Self.latmValue(&r) } // taraBufferFullness
        _ = r.read(1) // allStreamsSameTimeFraming
        subFrames = r.read(6) ?? 0
        let programs = (r.read(4) ?? 0) + 1
        for program in 0..<programs {
            let layers = (r.read(3) ?? 0) + 1
            for layer in 0..<layers {
                let useSameConfig = program == 0 && layer == 0 ? 0 : (r.read(1) ?? 1)
                if useSameConfig == 0 {
                    if muxVersion == 0 {
                        guard parseConfig(&r) else { return false }
                    } else {
                        let length = Self.latmValue(&r)
                        let start = r.position
                        guard parseConfig(&r) else { return false }
                        r.skip(max(0, length - (r.position - start)))
                    }
                }
                let frameLengthType = r.read(3) ?? 0
                switch frameLengthType {
                case 0: _ = r.read(8) // latmBufferFullness
                case 1: _ = r.read(9)
                case 3, 4, 5: _ = r.read(6)
                case 6, 7: _ = r.read(1)
                default: break
                }
            }
        }
        if r.read(1) == 1 { // otherDataPresent
            if muxVersion == 1 {
                _ = Self.latmValue(&r)
            } else {
                var escape = 1
                while escape == 1, r.remaining > 9 { escape = r.read(1) ?? 0; _ = r.read(8) }
            }
        }
        if r.read(1) == 1 { _ = r.read(8) } // crcCheckSum
        return true
    }

    /// Parses an AudioSpecificConfig and keeps its bits as the decoder configuration.
    private mutating func parseConfig(_ r: inout BitCursor) -> Bool {
        let start = r.position
        func objectType() -> Int {
            let type = r.read(5) ?? 0
            return type == 31 ? 32 + (r.read(6) ?? 0) : type
        }
        func frequency() -> Double {
            let index = r.read(4) ?? 0
            if index == 15 { return Double(r.read(24) ?? 0) }
            let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
            return index < rates.count ? rates[index] : 0
        }
        var type = objectType()
        let rate = frequency()
        let channelConfiguration = r.read(4) ?? 0
        if type == 5 || type == 29 { // Explicit SBR / PS: the extension rate, then the core type.
            _ = frequency()
            type = objectType()
        }
        guard [1, 2, 3, 4, 6, 7, 17, 19, 20, 21, 22, 23].contains(type), channelConfiguration > 0 else { return false }
        _ = r.read(1) // frameLengthFlag
        if r.read(1) == 1 { _ = r.read(14) } // dependsOnCoreCoder
        let extensionFlag = r.read(1) ?? 0
        if type == 6 || type == 20 { _ = r.read(3) }
        if extensionFlag == 1 {
            if type == 22 { _ = r.read(16) }
            if [17, 19, 20, 23].contains(type) { _ = r.read(3) }
            _ = r.read(1)
        }
        audioSpecificConfig = Data(r.bits(from: start))
        sampleRate = rate
        channels = channelConfiguration == 7 ? 8 : channelConfiguration
        return true
    }
}

// MARK: - Opus in MPEG-TS

nonisolated enum OpusTS {
    /// Opus packets from a PES payload: each has a control header (0x7FE…), a size, and
    /// optional trim and extension fields.
    static func packets(in data: Data) -> [Data] {
        let b = [UInt8](data)
        var packets: [Data] = []
        var i = 0
        while i + 2 <= b.count, b[i] == 0x7F, b[i + 1] & 0xE0 == 0xE0 {
            let flags = b[i + 1]
            i += 2
            var size = 0
            while i < b.count {
                let value = Int(b[i])
                i += 1
                size += value
                if value != 255 { break }
            }
            if flags & 0x10 != 0 { i += 2 } // start trim
            if flags & 0x08 != 0 { i += 2 } // end trim
            if flags & 0x04 != 0, i < b.count { i += 1 + Int(b[i]) } // control extension
            guard i + size <= b.count else { break }
            packets.append(Data(b[i..<(i + size)]))
            i += size
        }
        return packets
    }
}
