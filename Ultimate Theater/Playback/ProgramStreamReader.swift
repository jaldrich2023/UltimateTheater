//
//  ProgramStreamReader.swift
//  Ultimate Theater
//
//  MPEG program streams: MPEG-1 system streams (.mpg), MPEG-2 program streams,
//  DVD video objects (.vob), and camcorder .mod files.
//

import Foundation

nonisolated final class ProgramStreamReader: PESReader {
    let size: UInt64
    private(set) var streams: [Int: ElementaryStreamInfo] = [:]
    var wantedStreams: Set<Int>?

    private let source: FileByteSource
    private var position: UInt64 = 0
    /// Stream types from the program stream map, by stream id.
    private var mapped: [Int: Int] = [:]
    /// Languages, picture size, and subtitle palette from a DVD's IFO file, when present.
    private let disc: DVDTitleSetInfo?

    /// True when the file starts with a pack header (00 00 01 BA).
    static func matches(_ head: Data) -> Bool {
        let b = [UInt8](head.prefix(4))
        return b == [0, 0, 1, 0xBA]
    }

    init(source: FileByteSource, url: URL? = nil) {
        self.source = source
        size = source.size
        disc = url.flatMap(DVDTitleSetInfo.init(vob:))
    }

    func reposition(to offset: UInt64) throws {
        position = min(offset, size)
    }

    func nextPES() throws -> PESPacket? {
        while position + 4 <= size {
            let head = [UInt8](try source.read(at: position, count: 16))
            guard head.count >= 4 else { return nil }
            guard head[0] == 0, head[1] == 0, head[2] == 1 else {
                try resynchronize()
                continue
            }
            let id = head[3]
            switch id {
            case 0xBA: // Pack header.
                guard head.count >= 14 else { return nil }
                position += head[4] & 0xC0 == 0x40 ? 14 + UInt64(head[13] & 0x07) : 12
            case 0xB9: // End of program stream.
                position += 4
            case 0xBB, 0xBC, 0xBE, 0xBF, 0xF0...0xFF:
                guard head.count >= 6 else { return nil }
                let length = Int(head[4]) << 8 | Int(head[5])
                if id == 0xBC { readStreamMap(try source.read(at: position, count: length + 6)) }
                position += UInt64(length + 6)
            case 0xBD, 0xC0...0xEF, 0xFD:
                guard head.count >= 6 else { return nil }
                let offset = position
                let length = Int(head[4]) << 8 | Int(head[5])
                guard length > 0 else { try resynchronize(); continue }
                position += UInt64(length + 6)
                if let packet = try packet(id: id, at: offset, length: length) { return packet }
            default:
                try resynchronize()
            }
        }
        return nil
    }

    /// Skips forward to the next pack or PES start code.
    private func resynchronize() throws {
        position += 1
        while position + 4 <= size {
            let window = [UInt8](try source.read(at: position, count: 64 << 10))
            guard window.count >= 4 else { break }
            for i in 0..<(window.count - 3) where window[i] == 0 && window[i + 1] == 0 && window[i + 2] == 1
                && (window[i + 3] == 0xBA || window[i + 3] >= 0xBD) {
                position += UInt64(i)
                return
            }
            position += UInt64(window.count - 3)
        }
        position = size
    }

    private func packet(id: UInt8, at offset: UInt64, length: Int) throws -> PESPacket? {
        let data = try source.read(at: offset, count: length + 6)
        guard var pes = PES.parse(data, stream: Int(id), offset: offset), !pes.payload.isEmpty else { return nil }
        var key = Int(id)
        if id == 0xBD {
            // Private stream 1 (DVD): a sub-stream id, then a codec-specific header.
            let sub = pes.payload[pes.payload.startIndex]
            key = 0xBD00 | Int(sub)
            let skip: Int
            switch sub {
            case 0x20...0x3F: skip = 1                 // Subpictures
            case 0x80...0x8F, 0xC0...0xCF: skip = 4    // AC-3, DTS, E-AC-3
            case 0xA0...0xA7: skip = 7                 // LPCM
            default: return nil
            }
            if streams[key] == nil { register(key, sub: sub, payload: pes.payload) }
            guard pes.payload.count > skip else { return nil }
            pes = PESPacket(stream: key, pts: pes.pts, dts: pes.dts, payload: pes.payload.dropFirst(skip), offset: offset)
        } else if streams[key] == nil {
            register(key, sub: 0, payload: pes.payload)
        }
        guard wantedStreams?.contains(key) ?? true else { return nil }
        return pes
    }

    private func register(_ key: Int, sub: UInt8, payload: Data) {
        let id = key & 0xFF
        if key < 0x100, let type = mapped[id],
           let info = TransportStreamReader.streamInfo(type: type, descriptors: [], isBluRay: false) {
            streams[key] = info
            return
        }
        if key >= 0xBD00 {
            switch sub {
            case 0x20...0x3F:
                var info = ElementaryStreamInfo(kind: .subtitle, codec: .vobSub, codecID: "VobSub")
                info.language = disc?.subtitleLanguages[safe: Int(sub - 0x20)] ?? nil
                info.codecPrivate = disc?.subtitleSetup
                streams[key] = info
            case 0x80...0x87:
                streams[key] = ElementaryStreamInfo(kind: .audio, codec: .ac3, codecID: "AC-3",
                                                    language: disc?.audioLanguages[safe: Int(sub - 0x80)] ?? nil)
            case 0x88...0x8F:
                streams[key] = ElementaryStreamInfo(kind: .audio, codec: .dts, codecID: "DTS",
                                                    language: disc?.audioLanguages[safe: Int(sub - 0x88)] ?? nil)
            case 0xC0...0xCF:
                streams[key] = ElementaryStreamInfo(kind: .audio, codec: .eac3, codecID: "E-AC-3")
            case 0xA0...0xA7:
                // DVD LPCM: quantization, sampling rate, and channels in the 6th header byte.
                let b = [UInt8](payload.prefix(7))
                guard b.count == 7 else { return }
                let bits = [16, 20, 24, 0][Int(b[5] >> 6)]
                guard bits > 0 else { return }
                // 20- and 24-bit samples are regrouped into plain 24-bit PCM.
                var info = ElementaryStreamInfo(kind: .audio, codec: .pcm(bits: bits == 16 ? 16 : 24, isFloat: false, isBigEndian: true),
                                                codecID: "LPCM", language: disc?.audioLanguages[safe: Int(sub - 0xA0)] ?? nil)
                if bits != 16 { info.dvdLPCMBits = bits }
                info.sampleRate = [48000, 96000, 44100, 32000][Int((b[5] >> 4) & 0x03)]
                info.channels = Int(b[5] & 0x07) + 1
                streams[key] = info
            default:
                break
            }
            return
        }
        switch id {
        case 0xE0...0xEF:
            streams[key] = ElementaryStreamInfo(kind: .video, codec: .mpeg2Video, codecID: "MPEG video")
        case 0xC0...0xDF:
            streams[key] = ElementaryStreamInfo(kind: .audio, codec: .mp2, codecID: "MPEG audio",
                                                language: disc?.audioLanguages[safe: id - 0xC0] ?? nil)
        case 0xFD:
            streams[key] = ElementaryStreamInfo(kind: .video, codec: .unsupported("VC-1"), codecID: "VC-1")
        default:
            break
        }
    }

    /// Program stream map: stream types for each elementary stream id.
    private func readStreamMap(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 12 else { return }
        let infoLength = Int(b[8]) << 8 | Int(b[9])
        var i = 10 + infoLength
        guard i + 2 <= b.count else { return }
        let mapLength = Int(b[i]) << 8 | Int(b[i + 1])
        i += 2
        let end = min(b.count, i + mapLength)
        while i + 4 <= end {
            let type = Int(b[i])
            let id = Int(b[i + 1])
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            mapped[id] = type
            i += 4 + length
        }
    }
}

// MARK: - DVD title set information

/// What a DVD's VTS_nn_0.IFO says about the title set's streams: audio and subtitle
/// languages, the picture standard, and the subtitle color palette.
nonisolated struct DVDTitleSetInfo {
    var audioLanguages: [String?] = []
    var subtitleLanguages: [String?] = []
    var pictureSize = (width: 720, height: 480)
    /// 16 RGB colors.
    var palette: [UInt32] = []

    /// The setup text VobSub decoding expects (size and palette, as in a .idx file).
    var subtitleSetup: Data? {
        guard palette.count == 16 else { return nil }
        let colors = palette.map { String(format: "%06x", $0) }.joined(separator: ", ")
        return Data("size: \(pictureSize.width)x\(pictureSize.height)\npalette: \(colors)\n".utf8)
    }

    /// Finds the IFO next to a VOB named like VTS_01_1.VOB.
    init?(vob url: URL) {
        let name = url.deletingPathExtension().lastPathComponent.uppercased()
        let parts = name.split(separator: "_")
        guard parts.count == 3, parts[0] == "VTS" else { return nil }
        let folder = url.deletingLastPathComponent()
        let candidates = ["VTS_\(parts[1])_0.IFO", "VTS_\(parts[1])_0.ifo", "VTS_\(parts[1])_0.BUP"]
        guard let ifo = candidates.lazy.map({ folder.appending(path: $0) }).first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let data = try? Data(contentsOf: ifo) else { return nil }
        self.init(ifo: data)
    }

    init?(ifo data: Data) {
        let b = [UInt8](data)
        guard b.count > 0x400, b.starts(with: Array("DVDVIDEO-VTS".utf8)) else { return nil }
        func u16(_ at: Int) -> Int { Int(b[at]) << 8 | Int(b[at + 1]) }
        func u32(_ at: Int) -> Int { u16(at) << 16 | u16(at + 2) }
        func language(_ at: Int) -> String? {
            guard b[at] >= 0x61, b[at] <= 0x7A, b[at + 1] >= 0x61, b[at + 1] <= 0x7A else { return nil }
            return String(decoding: b[at...(at + 1)], as: UTF8.self)
        }
        let video = u16(0x200)
        pictureSize = (video >> 12) & 0x03 == 1 ? (720, 576) : (720, 480)
        let audioCount = min(8, u16(0x202))
        audioLanguages = (0..<audioCount).map { language(0x204 + $0 * 8 + 2) }
        let subtitleCount = min(32, u16(0x254))
        subtitleLanguages = (0..<subtitleCount).map { language(0x256 + $0 * 6 + 2) }

        // The first program chain's palette: 16 entries of (0, Y, Cr, Cb).
        let pgcit = u32(0xCC) * 2048
        guard pgcit + 16 <= b.count, u16(pgcit) > 0 else { return }
        let pgc = pgcit + u32(pgcit + 12)
        guard pgc + 0xA4 + 64 <= b.count else { return }
        palette = (0..<16).map { index in
            let at = pgc + 0xA4 + index * 4
            let y = Double(b[at + 1]), cr = Double(b[at + 2]) - 128, cb = Double(b[at + 3]) - 128
            func clamp(_ v: Double) -> UInt32 { UInt32(max(0, min(255, v.rounded()))) }
            return clamp(y + 1.402 * cr) << 16 | clamp(y - 0.344 * cb - 0.714 * cr) << 8 | clamp(y + 1.772 * cb)
        }
    }
}
