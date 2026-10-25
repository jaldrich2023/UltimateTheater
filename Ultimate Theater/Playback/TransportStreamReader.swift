//
//  TransportStreamReader.swift
//  Ultimate Theater
//
//  MPEG transport streams: broadcast and camcorder TS (188-byte packets), Blu-ray and
//  AVCHD M2TS (192-byte packets with a timecode prefix), and 204-byte packets.
//

import Foundation

nonisolated final class TransportStreamReader: PESReader {
    let size: UInt64
    private(set) var streams: [Int: ElementaryStreamInfo] = [:]
    var wantedStreams: Set<Int>?
    var readLimit: UInt64?

    private let source: FileByteSource
    private let packetSize: Int
    /// Where the 0x47 sync byte sits within each packet (4 in M2TS).
    private let syncOffset: Int
    private let isBluRay: Bool
    private var position: UInt64 = 0
    private var programMapPID: Int?
    private var sections: [Int: Data] = [:]
    /// PES packets being assembled, by PID.
    private var partial: [Int: (offset: UInt64, data: Data)] = [:]
    private var ready: [PESPacket] = []
    private var flushedAtEnd = false
    private static let maxPESBytes = 16 << 20

    /// True when the file starts with transport stream packets.
    static func matches(_ head: Data) -> Bool {
        layout(of: [UInt8](head)) != nil
    }

    private static func layout(of b: [UInt8]) -> (size: Int, sync: Int)? {
        for (size, sync) in [(188, 0), (192, 4), (204, 0)] {
            for start in 0..<min(size, max(0, b.count - size * 4)) {
                let first = start + sync
                guard first < b.count, b[first] == 0x47 else { continue }
                if (1..<5).allSatisfy({ first + $0 * size < b.count && b[first + $0 * size] == 0x47 }) {
                    return (size, sync)
                }
            }
        }
        return nil
    }

    init(source: FileByteSource) throws {
        self.source = source
        size = source.size
        let head = [UInt8](try source.read(at: 0, count: 8192))
        guard let layout = Self.layout(of: head) else { throw ContainerError.unrecognizedFormat }
        packetSize = layout.size
        syncOffset = layout.sync
        isBluRay = layout.size == 192
        // Read until the program map describes the streams.
        var scanned = 0
        while streams.isEmpty, scanned < 60_000, try readPacket() { scanned += 1 }
        guard !streams.isEmpty else { throw ContainerError.corrupt("no program map in the transport stream") }
        try reposition(to: 0)
    }

    func nextPES() throws -> PESPacket? {
        while ready.isEmpty {
            guard try readPacket() else {
                guard !flushedAtEnd else { return nil }
                flushedAtEnd = true
                for pid in partial.keys.sorted() { finish(pid) }
                break
            }
        }
        return ready.isEmpty ? nil : ready.removeFirst()
    }

    func reposition(to offset: UInt64) throws {
        let aligned = offset - offset % UInt64(packetSize)
        position = min(aligned, size)
        partial = [:]
        ready = []
        sections = [:]
        flushedAtEnd = false
    }

    // MARK: Packets

    /// Reads one packet; returns false at end of file.
    private func readPacket() throws -> Bool {
        guard position + UInt64(packetSize) <= min(size, readLimit ?? size) else { return false }
        let packetOffset = position
        var b = [UInt8](try source.read(at: position, count: packetSize))
        guard b.count == packetSize else { return false }
        if b[syncOffset] != 0x47 {
            // Lost sync: find the next run of sync bytes.
            let window = [UInt8](try source.read(at: position, count: packetSize * 8))
            var found: Int?
            // Start past the sync offset so the packet start (found - syncOffset) is ahead.
            for i in (syncOffset + 1)..<max(syncOffset + 1, window.count - packetSize * 3) where window[i] == 0x47
                && window[i + packetSize] == 0x47 && window[i + packetSize * 2] == 0x47 {
                found = i
                break
            }
            guard let found else { position += UInt64(packetSize * 5); return position < size }
            position += UInt64(found - syncOffset)
            b = [UInt8](try source.read(at: position, count: packetSize))
            guard b.count == packetSize else { return false }
        }
        position += UInt64(packetSize)
        let p = syncOffset
        let unitStart = b[p + 1] & 0x40 != 0
        let pid = Int(b[p + 1] & 0x1F) << 8 | Int(b[p + 2])
        let control = (b[p + 3] >> 4) & 0x03
        guard control & 1 != 0 else { return true } // No payload.
        var start = p + 4
        if control & 2 != 0 { start += 1 + Int(b[p + 4]) }
        let end = p + 188
        guard start < end else { return true }
        let payload = b[start..<end]

        if pid == 0 || pid == programMapPID {
            readSection(pid: pid, payload, unitStart: unitStart)
        } else if streams[pid] != nil, wantedStreams?.contains(pid) ?? true {
            if unitStart {
                finish(pid)
                partial[pid] = (packetOffset, Data(payload))
            } else if partial[pid] != nil {
                partial[pid]?.data.append(contentsOf: payload)
                // A PES never grows this large; deliver what's there rather than grow forever.
                if let count = partial[pid]?.data.count, count > Self.maxPESBytes { finish(pid) }
            }
            // A PES with a declared length can be delivered as soon as it's complete.
            if let pes = partial[pid], pes.data.count >= 6 {
                let length = Int(pes.data[pes.data.startIndex + 4]) << 8 | Int(pes.data[pes.data.startIndex + 5])
                if length > 0, pes.data.count >= length + 6 { finish(pid) }
            }
        }
        return true
    }

    private func finish(_ pid: Int) {
        guard let pes = partial.removeValue(forKey: pid) else { return }
        var data = pes.data
        let length = data.count >= 6 ? Int(data[data.startIndex + 4]) << 8 | Int(data[data.startIndex + 5]) : 0
        if length > 0, data.count > length + 6 { data = data.prefix(length + 6) }
        if let packet = PES.parse(data, stream: pid, offset: pes.offset), !packet.payload.isEmpty {
            ready.append(packet)
        }
    }

    // MARK: Tables

    private func readSection(pid: Int, _ payload: ArraySlice<UInt8>, unitStart: Bool) {
        var bytes = Array(payload)
        if unitStart {
            guard let pointer = bytes.first, Int(pointer) + 1 <= bytes.count else { return }
            bytes.removeFirst(Int(pointer) + 1)
            sections[pid] = Data(bytes)
        } else if sections[pid] != nil {
            sections[pid]?.append(contentsOf: bytes)
        }
        guard let section = sections[pid].map({ [UInt8]($0) }), section.count >= 3 else { return }
        let length = Int(section[1] & 0x0F) << 8 | Int(section[2])
        guard section.count >= length + 3 else { return } // Continues in the next packet.
        sections[pid] = nil
        let body = Array(section[0..<(length + 3)])
        if pid == 0 { readProgramAssociation(body) } else { readProgramMap(body) }
    }

    private func readProgramAssociation(_ s: [UInt8]) {
        guard s.count >= 12, s[0] == 0x00 else { return }
        // Programs start at byte 8; the last 4 bytes are the CRC. Use the first real program.
        var i = 8
        while i + 4 <= s.count - 4 {
            let program = Int(s[i]) << 8 | Int(s[i + 1])
            let pid = Int(s[i + 2] & 0x1F) << 8 | Int(s[i + 3])
            if program != 0 { programMapPID = programMapPID ?? pid; return }
            i += 4
        }
    }

    private func readProgramMap(_ s: [UInt8]) {
        guard s.count >= 16, s[0] == 0x02 else { return }
        let infoLength = Int(s[10] & 0x0F) << 8 | Int(s[11])
        var i = 12 + infoLength
        var found: [Int: ElementaryStreamInfo] = [:]
        while i + 5 <= s.count - 4 {
            let type = Int(s[i])
            let pid = Int(s[i + 1] & 0x1F) << 8 | Int(s[i + 2])
            let length = Int(s[i + 3] & 0x0F) << 8 | Int(s[i + 4])
            let descriptors = Array(s[min(s.count, i + 5)..<min(s.count, i + 5 + length)])
            if let info = Self.streamInfo(type: type, descriptors: descriptors, isBluRay: isBluRay) {
                found[pid] = info
            }
            i += 5 + length
        }
        // Later maps (program changes) add their streams; known ones keep their description,
        // since tracks were built from it.
        streams.merge(found) { known, _ in known }
    }

    /// Maps a PMT stream type (and its descriptors) to a codec. Returns nil for streams
    /// that carry no playable media (metadata, 3D dependent views, and so on).
    static func streamInfo(type: Int, descriptors: [UInt8], isBluRay: Bool) -> ElementaryStreamInfo? {
        var language: String?
        var registration: String?
        var tags: Set<UInt8> = []
        var opusChannels: Int?
        var teletextPage: (magazine: Int, page: Int)?
        var i = 0
        while i + 2 <= descriptors.count {
            let tag = descriptors[i]
            let length = Int(descriptors[i + 1])
            let body = Array(descriptors[min(descriptors.count, i + 2)..<min(descriptors.count, i + 2 + length)])
            tags.insert(tag)
            switch tag {
            case 0x0A where body.count >= 3: language = String(decoding: body.prefix(3), as: UTF8.self) // ISO 639
            case 0x05 where body.count >= 4: registration = String(decoding: body.prefix(4), as: UTF8.self)
            case 0x7F where body.count >= 2 && body[0] == 0x80: // Opus channel configuration
                opusChannels = body[1] <= 8 ? max(Int(body[1]), 2) : 2
            case 0x59 where body.count >= 3:
                language = language ?? String(decoding: body.prefix(3), as: UTF8.self)
            case 0x56 where body.count >= 5:
                // Entries of language, type, magazine, and page: use the first subtitle page.
                for at in stride(from: 0, to: body.count - 4, by: 5) where [2, 5].contains(body[at + 3] >> 3) {
                    let magazine = Int(body[at + 3] & 0x07)
                    teletextPage = (magazine == 0 ? 8 : magazine, Int(body[at + 4]))
                    language = String(decoding: body[at..<(at + 3)], as: UTF8.self)
                    break
                }
            default: break
            }
            i += 2 + length
        }
        func video(_ codec: MediaCodec, _ id: String) -> ElementaryStreamInfo {
            ElementaryStreamInfo(kind: .video, codec: codec, codecID: id, language: nil)
        }
        func audio(_ codec: MediaCodec, _ id: String) -> ElementaryStreamInfo {
            ElementaryStreamInfo(kind: .audio, codec: codec, codecID: id, language: language)
        }
        func subtitle(_ codec: MediaCodec, _ id: String) -> ElementaryStreamInfo {
            ElementaryStreamInfo(kind: .subtitle, codec: codec, codecID: id, language: language)
        }
        switch type {
        case 0x01: return video(.mpeg1Video, "MPEG-1")
        case 0x02: return video(.mpeg2Video, "MPEG-2")
        case 0x10: return video(.mpeg4Part2, "MPEG-4")
        case 0x1B: return video(.h264, "H.264")
        case 0x24: return video(.hevc, "HEVC")
        case 0xEA: return video(.unsupported("VC-1"), "VC-1")
        case 0xD1: return video(.unsupported("Dirac"), "Dirac")
        case 0x03, 0x04: return audio(.mp2, "MPEG audio")
        case 0x0F: return audio(.aac, "ADTS")
        case 0x11: return audio(.aac, "LATM")
        case 0x81: return audio(.ac3, "AC-3")
        case 0x84, 0x87, 0xA1: return audio(.eac3, "E-AC-3")
        case 0x82, 0x85, 0x86: return audio(.dts, "DTS") // DTS, DTS-HD High Resolution, DTS-HD Master Audio (core)
        case 0xA2: return audio(.unsupported("DTS Express"), "DTS Express")
        case 0x83:
            // Blu-ray TrueHD (its Dolby Digital frames, carried in the same stream, are skipped).
            var info = audio(.trueHD, "TrueHD")
            info.name = "Dolby TrueHD"
            return info
        case 0x80 where isBluRay:
            var info = audio(.pcm(bits: 16, isFloat: false, isBigEndian: true), "LPCM")
            info.payloadHeader = 4
            return info
        case 0x90: return subtitle(.pgs, "PGS")
        case 0x92: return subtitle(.unsupported("Blu-ray Text"), "TextST")
        case 0x06:
            // Private data: the descriptors say what it really is.
            if tags.contains(0x6A) || registration == "AC-3" { return audio(.ac3, "AC-3") }
            if tags.contains(0x7A) || registration == "EAC3" { return audio(.eac3, "E-AC-3") }
            if tags.contains(0x7B) || registration?.hasPrefix("DTS") == true { return audio(.dts, "DTS") }
            if registration == "Opus" {
                var info = audio(.opus, "Opus-TS")
                info.channels = opusChannels ?? 2
                info.sampleRate = 48000
                return info
            }
            if tags.contains(0x59) { return subtitle(.dvbSubtitles, "DVB") }
            if let teletextPage {
                var info = subtitle(.teletext, "Teletext")
                info.codecPrivate = Data([UInt8(teletextPage.magazine), UInt8(teletextPage.page)])
                return info
            }
            if registration == "HEVC" { return video(.hevc, "HEVC") }
            if registration == "VC-1" { return video(.unsupported("VC-1"), "VC-1") }
            return nil
        default:
            return nil
        }
    }
}
