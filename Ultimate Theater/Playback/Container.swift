//
//  Container.swift
//  Ultimate Theater
//
//  Shared types for the Theater engine's container readers (Matroska, AVI, MP4, MPEG, Ogg, FLV):
//  tracks, codecs, packets, chapters, and buffered file access.
//

import Foundation

nonisolated enum ContainerTrackKind: String, Sendable {
    case video
    case audio
    case subtitle
}

/// Codecs the engine recognizes. Supported ones are decoded by the system
/// (VideoToolbox / AudioToolbox); others are reported with a clear message.
nonisolated enum MediaCodec: Hashable, Sendable {
    case h264
    case hevc
    case av1
    case vp9
    /// VP8 and Theora are decoded by the engine itself (`VP8Decoder`, `TheoraDecoder`).
    case vp8
    case theora
    case mpeg1Video
    case mpeg2Video
    case h263
    case mpeg4Part2
    case mjpeg
    /// Apple ProRes; the value is the sample entry FourCC ('apch', 'apcn', …).
    case prores(UInt32)
    /// DV and DVCPRO; the value is the codec FourCC ('dvc ', 'dvcp', 'dv5n', 'dv5p').
    case dv(UInt32)
    case aac
    case alac
    case ac3
    case eac3
    /// DTS Coherent Acoustics, decoded by the engine's own core decoder (`DTSCoreDecoder`).
    case dts
    case mp3
    case mp2
    case flac
    case opus
    case vorbis
    /// IMA (DVI) ADPCM in AVI/WAV blocks.
    case adpcmIMA
    /// Microsoft ADPCM.
    case adpcmMS
    case muLaw
    case aLaw
    /// QuickTime IMA 4:1 ('ima4').
    case appleIMA4
    case amrNB
    case amrWB
    case pcm(bits: Int, isFloat: Bool, isBigEndian: Bool)
    case textUTF8
    case textASS
    /// 3GPP timed text (MP4/MOV subtitles): a 16-bit length, then UTF-8.
    case tx3g
    /// Blu-ray presentation graphics (image subtitles).
    case pgs
    /// DVD subpictures (image subtitles).
    case vobSub
    /// DVB broadcast subtitles (image subtitles).
    case dvbSubtitles
    /// Teletext subtitles (text).
    case teletext
    case unsupported(String)

    var isSupported: Bool {
        if case .unsupported = self { return false }
        return true
    }

    var displayName: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .av1: "AV1"
        case .vp9: "VP9"
        case .vp8: "VP8"
        case .theora: "Theora"
        case .mpeg1Video: "MPEG-1"
        case .mpeg2Video: "MPEG-2"
        case .h263: "H.263"
        case .mpeg4Part2: "MPEG-4 Part 2"
        case .mjpeg: "Motion JPEG"
        case .prores: "Apple ProRes"
        case .dv: "DV"
        case .aac: "AAC"
        case .alac: "Apple Lossless"
        case .ac3: "Dolby Digital"
        case .eac3: "Dolby Digital Plus"
        case .dts: "DTS"
        case .mp3: "MP3"
        case .mp2: "MP2"
        case .flac: "FLAC"
        case .opus: "Opus"
        case .vorbis: "Vorbis"
        case .adpcmIMA: "IMA ADPCM"
        case .adpcmMS: "Microsoft ADPCM"
        case .muLaw: "µ-law"
        case .aLaw: "A-law"
        case .appleIMA4: "IMA 4:1"
        case .amrNB: "AMR"
        case .amrWB: "AMR-WB"
        case .pcm: "PCM"
        case .textUTF8: "Text"
        case .textASS: "Styled Text"
        case .tx3g: "Text"
        case .pgs: "PGS"
        case .vobSub: "DVD Subtitles"
        case .dvbSubtitles: "DVB Subtitles"
        case .teletext: "Teletext"
        case .unsupported(let name): name
        }
    }

    /// Samples per compressed audio frame, for timing laced or repacketized audio.
    var samplesPerFrame: Int? {
        switch self {
        case .aac: 1024
        case .ac3, .eac3: 1536
        case .mp3, .mp2: 1152
        case .amrNB: 160
        case .appleIMA4: 64
        case .amrWB: 320
        default: nil
        }
    }
}

nonisolated struct ContainerTrack: Identifiable, Hashable, Sendable {
    /// Container track number (Matroska) or stream index (AVI).
    let id: Int
    let kind: ContainerTrackKind
    var codec: MediaCodec
    /// Raw codec identifier from the file ("V_MPEG4/ISO/AVC", "XVID", "0x2000", …).
    let codecID: String
    /// avcC / hvcC / av1C / AudioSpecificConfig / VOL header, depending on codec.
    var codecPrivate: Data?
    /// Video payloads use start codes instead of length prefixes (H.264/HEVC in AVI).
    var isAnnexB = false
    var language: String?
    var name: String?
    var isDefault = true
    var isForced = false
    var width: Int?
    var height: Int?
    var sampleRate: Double?
    var channels: Int?
    var bitDepth: Int?
    /// Nominal frame duration in seconds, when the container declares one.
    var frameDuration: Double?
    /// Extra sample-description atoms for the decoder (colr, pasp, dvcC, …).
    var extraAtoms: [String: Data] = [:]
    var hdr: HDRFormat?
    /// Fixed packet size and frames per packet for block-based audio (ADPCM).
    var blockAlign: Int?
    var samplesPerBlock: Int?
    /// Audio arrives as a byte stream (AVI chunks, MPEG PES payloads) rather than whole
    /// codec frames, so it must be re-framed before decoding.
    var needsFraming = false
    /// Re-framed frames must pass their checksum (when extracting a core from another
    /// stream, such as the Dolby Digital frames inside Blu-ray TrueHD).
    var verifiesFrames = false
}

nonisolated enum HDRFormat: String, Sendable {
    case hdr10
    case hlg
    case dolbyVision

    /// From a transfer-characteristics code (ITU-T H.273): 16 = PQ, 18 = HLG.
    init?(transferCharacteristics code: Int) {
        switch code {
        case 16: self = .hdr10
        case 18: self = .hlg
        default: return nil
        }
    }
}

nonisolated struct MediaPacket: Sendable {
    let trackID: Int
    /// Presentation time in seconds.
    var pts: Double
    /// Decode time in seconds, when the container records it (MP4); otherwise decode order.
    var dts: Double? = nil
    var duration: Double?
    var isKeyframe: Bool
    var data: Data
}

nonisolated struct ContainerChapter: Hashable, Sendable {
    let title: String
    let start: Double
    let end: Double?
}

/// A container reader. Not thread-safe; owned by a single playback pipeline.
nonisolated protocol MediaDemuxer: AnyObject {
    var tracks: [ContainerTrack] { get }
    var duration: Double? { get }
    var chapters: [ContainerChapter] { get }
    /// Tracks whose packets `nextPacket()` returns. Others are skipped cheaply.
    var enabledTrackIDs: Set<Int> { get set }
    func nextPacket() throws -> MediaPacket?
    /// Moves to the nearest keyframe at or before `seconds`. Returns the landing time.
    @discardableResult func seek(to seconds: Double) throws -> Double
}

nonisolated enum ContainerError: LocalizedError {
    case unrecognizedFormat
    case truncated
    /// An MP4/MOV whose index ('moov') was never written, usually an interrupted copy or encode.
    case incomplete
    case corrupt(String)

    var errorDescription: String? {
        switch self {
        case .unrecognizedFormat: "This file isn't in a container format Ultimate Theater can read."
        case .truncated: "The file ended unexpectedly. It may be incomplete."
        case .incomplete: "This file is incomplete: its index was never written, which usually means a copy or encode was interrupted. Copy or export it again."
        case .corrupt(let detail): "The file appears to be damaged (\(detail))."
        }
    }
}

nonisolated enum Demuxers {
    /// Every container the Theater engine reads.
    static let supportedExtensions: Set<String> = [
        "mkv", "mk3d", "webm", "avi", "mp4", "m4v", "mov", "3gp", "3g2",
        "ts", "m2ts", "mts", "m2t", "tp", "trp", "tod", "mpg", "mpeg", "m1v", "m2v", "m2p", "vob", "mod",
        "ogv", "ogg", "ogm", "flv", "f4v", "dv", "dif",
    ]

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Opens the right reader for a file, by content signature.
    static func open(_ url: URL) throws -> any MediaDemuxer {
        let source = try FileByteSource(url: url)
        let magic = try source.read(at: 0, count: 8192)
        if magic.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) {
            return try MatroskaDemuxer(source: source)
        }
        if magic.count >= 12, magic.prefix(4) == Data("RIFF".utf8), magic.subdata(in: 8..<12) == Data("AVI ".utf8) {
            return try AVIDemuxer(source: source)
        }
        if magic.count >= 8, ["ftyp", "moov", "mdat", "free", "wide", "skip", "pnot"].contains(String(decoding: magic.subdata(in: 4..<8), as: UTF8.self)) {
            return try MP4Demuxer(source: source)
        }
        if DVDemuxer.matches(magic) {
            return try DVDemuxer(source: source)
        }
        if OggDemuxer.matches(magic) {
            return try OggDemuxer(source: source)
        }
        if FLVDemuxer.matches(magic) {
            return try FLVDemuxer(source: source)
        }
        if ProgramStreamReader.matches(magic) {
            return try PESDemuxer(reader: ProgramStreamReader(source: source, url: url))
        }
        if TransportStreamReader.matches(magic) {
            return try PESDemuxer(reader: TransportStreamReader(source: source))
        }
        throw ContainerError.unrecognizedFormat
    }
}

// MARK: - File access

/// Random-access file reads with a read-ahead cache, for sequential packet parsing.
nonisolated final class FileByteSource {
    let size: UInt64
    private let handle: FileHandle
    private var cache = Data()
    private var cacheOffset: UInt64 = 0
    private let chunkSize = 1 << 20

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = try handle.seekToEnd()
    }

    deinit {
        try? handle.close()
    }

    /// Reads up to `count` bytes at `offset`; returns fewer only at end of file.
    func read(at offset: UInt64, count: Int) throws -> Data {
        guard count > 0, offset < size else { return Data() }
        let end = offset + UInt64(count)
        if offset >= cacheOffset, end <= cacheOffset + UInt64(cache.count) {
            let start = Int(offset - cacheOffset)
            return cache.subdata(in: start..<(start + count))
        }
        try handle.seek(toOffset: offset)
        if count > chunkSize {
            return Data(try handle.read(upToCount: count) ?? Data())
        }
        cache = Data(try handle.read(upToCount: chunkSize) ?? Data())
        cacheOffset = offset
        return cache.prefix(count)
    }
}

// MARK: - Byte parsing

/// Cursor over an in-memory byte buffer.
nonisolated struct ByteReader {
    let bytes: [UInt8]
    var position: Int

    init(_ data: Data) {
        bytes = [UInt8](data)
        position = 0
    }

    init(_ bytes: [UInt8], position: Int = 0) {
        self.bytes = bytes
        self.position = position
    }

    var remaining: Int { bytes.count - position }
    var isAtEnd: Bool { position >= bytes.count }

    mutating func u8() throws -> UInt8 {
        guard position < bytes.count else { throw ContainerError.truncated }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, position + count <= bytes.count else { throw ContainerError.truncated }
        defer { position += count }
        return bytes[position..<(position + count)]
    }

    mutating func skip(_ count: Int) throws {
        guard position + count <= bytes.count else { throw ContainerError.truncated }
        position += count
    }

    mutating func u16be() throws -> UInt16 {
        let b = try take(2)
        return UInt16(b[b.startIndex]) << 8 | UInt16(b[b.startIndex + 1])
    }

    mutating func u16le() throws -> UInt16 {
        let b = try take(2)
        return UInt16(b[b.startIndex]) | UInt16(b[b.startIndex + 1]) << 8
    }

    mutating func u32le() throws -> UInt32 {
        let b = try take(4)
        var value: UInt32 = 0
        for (index, byte) in b.enumerated() { value |= UInt32(byte) << (8 * index) }
        return value
    }

    mutating func fourCC() throws -> String {
        String(decoding: try take(4), as: UTF8.self)
    }
}

nonisolated extension Data {
    /// Big-endian unsigned integer from up to 8 bytes.
    var bigEndianUInt: UInt64 {
        reduce(0) { $0 << 8 | UInt64($1) }
    }
}
