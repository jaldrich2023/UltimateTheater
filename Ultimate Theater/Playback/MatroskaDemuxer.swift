//
//  MatroskaDemuxer.swift
//  Ultimate Theater
//
//  Reads Matroska / WebM (EBML) files: tracks, chapters, cues, and packets.
//  Spec: https://www.matroska.org/technical/elements.html
//

import Foundation

nonisolated final class MatroskaDemuxer: MediaDemuxer {
    // Element IDs (with their length-marker bits, as they appear in the file).
    enum ID {
        static let ebml: UInt32 = 0x1A45DFA3
        static let segment: UInt32 = 0x18538067
        static let seekHead: UInt32 = 0x114D9B74
        static let seek: UInt32 = 0x4DBB
        static let seekID: UInt32 = 0x53AB
        static let seekPosition: UInt32 = 0x53AC
        static let info: UInt32 = 0x1549A966
        static let timecodeScale: UInt32 = 0x2AD7B1
        static let duration: UInt32 = 0x4489
        static let tracks: UInt32 = 0x1654AE6B
        static let trackEntry: UInt32 = 0xAE
        static let trackNumber: UInt32 = 0xD7
        static let trackType: UInt32 = 0x83
        static let codecID: UInt32 = 0x86
        static let codecPrivate: UInt32 = 0x63A2
        static let language: UInt32 = 0x22B59C
        static let languageIETF: UInt32 = 0x22B59D
        static let name: UInt32 = 0x536E
        static let flagDefault: UInt32 = 0x88
        static let flagForced: UInt32 = 0x55AA
        static let defaultDuration: UInt32 = 0x23E383
        static let video: UInt32 = 0xE0
        static let pixelWidth: UInt32 = 0xB0
        static let pixelHeight: UInt32 = 0xBA
        static let colour: UInt32 = 0x55B0
        static let transferCharacteristics: UInt32 = 0x55BA
        static let blockAdditionMapping: UInt32 = 0x41E4
        static let blockAddIDType: UInt32 = 0x41E7
        static let blockAddIDExtraData: UInt32 = 0x41ED
        static let audio: UInt32 = 0xE1
        static let samplingFrequency: UInt32 = 0xB5
        static let channels: UInt32 = 0x9F
        static let bitDepth: UInt32 = 0x6264
        static let contentEncodings: UInt32 = 0x6D80
        static let contentEncoding: UInt32 = 0x6240
        static let contentCompression: UInt32 = 0x5034
        static let contentCompAlgo: UInt32 = 0x4254
        static let contentCompSettings: UInt32 = 0x4255
        static let cues: UInt32 = 0x1C53BB6B
        static let cuePoint: UInt32 = 0xBB
        static let cueTime: UInt32 = 0xB3
        static let cueTrackPositions: UInt32 = 0xB7
        static let cueTrack: UInt32 = 0xF7
        static let cueClusterPosition: UInt32 = 0xF1
        static let chapters: UInt32 = 0x1043A770
        static let editionEntry: UInt32 = 0x45B9
        static let chapterAtom: UInt32 = 0xB6
        static let chapterTimeStart: UInt32 = 0x91
        static let chapterTimeEnd: UInt32 = 0x92
        static let chapterFlagHidden: UInt32 = 0x98
        static let chapterDisplay: UInt32 = 0x80
        static let chapString: UInt32 = 0x85
        static let cluster: UInt32 = 0x1F43B675
        static let timecode: UInt32 = 0xE7
        static let simpleBlock: UInt32 = 0xA3
        static let blockGroup: UInt32 = 0xA0
        static let block: UInt32 = 0xA1
        static let blockDuration: UInt32 = 0x9B
        static let referenceBlock: UInt32 = 0xFB
    }

    private(set) var tracks: [ContainerTrack] = []
    private(set) var duration: Double?
    private(set) var chapters: [ContainerChapter] = []
    var enabledTrackIDs: Set<Int> = []

    private let source: FileByteSource
    private var segmentStart: UInt64 = 0
    private var segmentEnd: UInt64 = 0
    private var firstCluster: UInt64?
    private var timecodeScale: Double = 1_000_000 // nanoseconds per tick
    private var cues: [(time: UInt64, position: UInt64)] = []
    private var encodings: [Int: ContentEncoding] = [:]

    // Packet cursor state.
    private var cursor: UInt64 = 0
    private var clusterTimecode: Int64 = 0
    private var pending: [MediaPacket] = []

    private enum ContentEncoding {
        case headerStripping(Data)
        case zlib
    }

    init(source: FileByteSource) throws {
        self.source = source
        try parseHeaders()
        enabledTrackIDs = Set(tracks.map(\.id))
        cursor = firstCluster ?? segmentEnd
    }

    // MARK: Packets

    func nextPacket() throws -> MediaPacket? {
        do {
            return try readNextPacket()
        } catch ContainerError.truncated {
            // A file that was cut off ends at its last complete block.
            cursor = segmentEnd
            return nil
        }
    }

    private func readNextPacket() throws -> MediaPacket? {
        if !pending.isEmpty { return pending.removeFirst() }
        while cursor < segmentEnd {
            let header = try readHeader(at: cursor)
            switch header.id {
            case ID.cluster:
                // Descend: cluster children are read by this same flat loop, which also
                // handles clusters of unknown size.
                clusterTimecode = 0
                cursor = header.dataOffset
                continue
            case ID.timecode:
                clusterTimecode = Int64(try payload(header).bigEndianUInt)
            case ID.simpleBlock:
                if let packets = try readBlock(header, isSimple: true, groupDuration: nil, hasReference: false) {
                    cursor = try end(of: header)
                    pending = Array(packets.dropFirst())
                    return packets.first
                }
            case ID.blockGroup:
                if let packets = try readBlockGroup(header) {
                    cursor = try end(of: header)
                    pending = Array(packets.dropFirst())
                    return packets.first
                }
            default:
                guard header.size != nil else { return nil } // Unknown-size non-cluster: can't continue.
            }
            cursor = try end(of: header)
        }
        return nil
    }

    @discardableResult
    func seek(to seconds: Double) throws -> Double {
        pending = []
        let target = UInt64(max(seconds, 0) * 1_000_000_000 / timecodeScale)
        if let cue = cues.last(where: { $0.time <= target }) ?? cues.first {
            cursor = segmentStart + cue.position
            return Double(cue.time) * timecodeScale / 1_000_000_000
        }
        // No cues: walk cluster headers, which carry their timecode as the first child.
        guard var position = firstCluster else { return 0 }
        var best = (position: position, time: UInt64(0))
        while position < segmentEnd {
            let header = try readHeader(at: position)
            guard header.id == ID.cluster, let size = header.size else { break }
            let first = try readHeader(at: header.dataOffset)
            if first.id == ID.timecode {
                let time = try payload(first).bigEndianUInt
                if time > target { break }
                best = (position, time)
            }
            position = header.dataOffset + size
        }
        cursor = best.position
        return Double(best.time) * timecodeScale / 1_000_000_000
    }

    // MARK: Header parsing

    private func parseHeaders() throws {
        let ebml = try readHeader(at: 0)
        guard ebml.id == ID.ebml else { throw ContainerError.unrecognizedFormat }
        let segment = try readHeader(at: try end(of: ebml))
        guard segment.id == ID.segment else { throw ContainerError.corrupt("missing segment") }
        segmentStart = segment.dataOffset
        segmentEnd = segment.size.map { min(segmentStart + $0, source.size) } ?? source.size

        var seekPositions: [UInt32: UInt64] = [:]
        var parsed = Set<UInt32>()
        var position = segmentStart
        while position < segmentEnd {
            let header = try readHeader(at: position)
            if header.id == ID.cluster {
                firstCluster = position
                break
            }
            try parseTopLevel(header, seekPositions: &seekPositions)
            parsed.insert(header.id)
            guard header.size != nil else { break }
            position = try end(of: header)
        }
        // Cues and chapters often live after the clusters; the SeekHead says where.
        // In a file that was cut off they may be missing; it still plays up to where it ends.
        for id in [ID.info, ID.tracks, ID.cues, ID.chapters] where !parsed.contains(id) {
            guard let relative = seekPositions[id], segmentStart + relative < source.size,
                  let header = try? readHeader(at: segmentStart + relative), header.id == id else { continue }
            if id == ID.cues || id == ID.chapters {
                try? parseTopLevel(header, seekPositions: &seekPositions)
            } else {
                try parseTopLevel(header, seekPositions: &seekPositions)
            }
        }
        guard !tracks.isEmpty else { throw ContainerError.corrupt("no tracks") }
    }

    private func parseTopLevel(_ header: ElementHeader, seekPositions: inout [UInt32: UInt64]) throws {
        switch header.id {
        case ID.seekHead:
            for seek in EBML.children(try bytes(header)) where seek.id == ID.seek {
                let fields = EBML.children(seek.data)
                guard let id = fields.first(where: { $0.id == ID.seekID }),
                      let position = fields.first(where: { $0.id == ID.seekPosition }) else { continue }
                seekPositions[UInt32(truncatingIfNeeded: EBML.uint(id.data))] = EBML.uint(position.data)
            }
        case ID.info:
            let fields = EBML.children(try bytes(header))
            if let scale = fields.first(where: { $0.id == ID.timecodeScale }) {
                timecodeScale = Double(EBML.uint(scale.data))
            }
            if let value = fields.first(where: { $0.id == ID.duration }) {
                duration = EBML.float(value.data) * timecodeScale / 1_000_000_000
            }
        case ID.tracks:
            tracks = EBML.children(try bytes(header)).filter { $0.id == ID.trackEntry }.compactMap(parseTrack)
        case ID.cues:
            cues = EBML.children(try bytes(header)).filter { $0.id == ID.cuePoint }.compactMap { point in
                let fields = EBML.children(point.data)
                guard let time = fields.first(where: { $0.id == ID.cueTime }),
                      let positions = fields.first(where: { $0.id == ID.cueTrackPositions }),
                      let cluster = EBML.children(positions.data).first(where: { $0.id == ID.cueClusterPosition }) else { return nil }
                return (EBML.uint(time.data), EBML.uint(cluster.data))
            }
            .sorted { $0.time < $1.time }
        case ID.chapters:
            let editions = EBML.children(try bytes(header)).filter { $0.id == ID.editionEntry }
            if let edition = editions.first {
                chapters = parseChapters(edition.data).sorted { $0.start < $1.start }
            }
        default:
            break
        }
    }

    private func parseTrack(_ entry: EBML.Element) -> ContainerTrack? {
        let fields = EBML.children(entry.data)
        func field(_ id: UInt32) -> ArraySlice<UInt8>? { fields.first { $0.id == id }?.data }

        guard let number = field(ID.trackNumber).map(EBML.uint), let type = field(ID.trackType).map(EBML.uint),
              let codecID = field(ID.codecID).map(EBML.string) else { return nil }
        let kind: ContainerTrackKind
        switch type {
        case 1: kind = .video
        case 2: kind = .audio
        case 0x11: kind = .subtitle
        default: return nil
        }
        let video = field(ID.video).map(EBML.children) ?? []
        let audio = field(ID.audio).map(EBML.children) ?? []
        let id = Int(number)

        var track = ContainerTrack(id: id, kind: kind, codec: Self.codec(for: codecID, kind: kind), codecID: codecID)
        track.codecPrivate = field(ID.codecPrivate).map { Data($0) }
        track.language = field(ID.languageIETF).map(EBML.string) ?? field(ID.language).map(EBML.string) ?? "eng"
        track.name = field(ID.name).map(EBML.string)
        track.isDefault = field(ID.flagDefault).map { EBML.uint($0) != 0 } ?? true
        track.isForced = field(ID.flagForced).map { EBML.uint($0) != 0 } ?? false
        track.frameDuration = field(ID.defaultDuration).map { Double(EBML.uint($0)) / 1_000_000_000 }
        track.width = video.first { $0.id == ID.pixelWidth }.map { Int(EBML.uint($0.data)) }
        track.height = video.first { $0.id == ID.pixelHeight }.map { Int(EBML.uint($0.data)) }
        track.sampleRate = audio.first { $0.id == ID.samplingFrequency }.map { EBML.float($0.data) } ?? (kind == .audio ? 8000 : nil)
        track.channels = audio.first { $0.id == ID.channels }.map { Int(EBML.uint($0.data)) } ?? (kind == .audio ? 1 : nil)
        track.bitDepth = audio.first { $0.id == ID.bitDepth }.map { Int(EBML.uint($0.data)) }
        if let transfer = video.first(where: { $0.id == ID.colour }).flatMap({ EBML.children($0.data).first { $0.id == ID.transferCharacteristics } }) {
            track.hdr = HDRFormat(transferCharacteristics: Int(EBML.uint(transfer.data)))
        }
        // Dolby Vision configuration ('dvcC' / 'dvvC') rides in a block addition mapping.
        for mapping in fields where mapping.id == ID.blockAdditionMapping {
            let parts = EBML.children(mapping.data)
            guard let type = parts.first(where: { $0.id == ID.blockAddIDType }).map({ EBML.uint($0.data) }),
                  let extra = parts.first(where: { $0.id == ID.blockAddIDExtraData }) else { continue }
            if type == 0x6476_6343 || type == 0x6476_7643 {
                track.extraAtoms[type == 0x6476_6343 ? "dvcC" : "dvvC"] = Data(extra.data)
                track.hdr = .dolbyVision
            }
        }
        if case .pcm(_, let isFloat, let isBigEndian) = track.codec {
            track.codec = .pcm(bits: track.bitDepth ?? (isFloat ? 32 : 16), isFloat: isFloat, isBigEndian: isBigEndian)
        }
        // "Video for Windows" / "ACM" compatibility tracks wrap AVI headers.
        if codecID == "V_MS/VFW/FOURCC", let header = track.codecPrivate, header.count >= 20 {
            track.codec = AVIDemuxer.videoCodec(String(decoding: header.subdata(in: (header.startIndex + 16)..<(header.startIndex + 20)), as: UTF8.self))
            track.codecPrivate = header.count > 40 ? header.dropFirst(40) : nil
            track.isAnnexB = track.codec == .h264 || track.codec == .hevc
        } else if codecID == "A_MS/ACM", let format = track.codecPrivate, format.count >= 16 {
            let tag = Int(AVIDemuxer.le16(format, 0))
            track.codec = AVIDemuxer.audioCodec(tag, bits: Int(AVIDemuxer.le16(format, 14)))
            track.blockAlign = Int(AVIDemuxer.le16(format, 12))
            track.samplesPerBlock = format.count >= 20 ? Int(AVIDemuxer.le16(format, 18)) : nil
            track.codecPrivate = format.count > 18 ? format.dropFirst(18) : nil
        }

        // Content encoding: header stripping (common) or zlib (mostly subtitles).
        if let encodingList = field(ID.contentEncodings),
           let encoding = EBML.children(encodingList).first(where: { $0.id == ID.contentEncoding }),
           let compression = EBML.children(encoding.data).first(where: { $0.id == ID.contentCompression }) {
            let settings = EBML.children(compression.data)
            let algorithm = settings.first { $0.id == ID.contentCompAlgo }.map { EBML.uint($0.data) } ?? 0
            if algorithm == 3, let stripped = settings.first(where: { $0.id == ID.contentCompSettings }) {
                encodings[id] = .headerStripping(Data(stripped.data))
            } else if algorithm == 0 {
                encodings[id] = .zlib
            }
        }
        return track
    }

    private func parseChapters(_ data: ArraySlice<UInt8>) -> [ContainerChapter] {
        EBML.children(data).filter { $0.id == ID.chapterAtom }.flatMap { atom -> [ContainerChapter] in
            let fields = EBML.children(atom.data)
            let nested = parseChapters(atom.data)
            guard fields.first(where: { $0.id == ID.chapterFlagHidden }).map({ EBML.uint($0.data) }) != 1,
                  let start = fields.first(where: { $0.id == ID.chapterTimeStart }) else { return nested }
            let end = fields.first { $0.id == ID.chapterTimeEnd }.map { Double(EBML.uint($0.data)) / 1_000_000_000 }
            let title = fields.first { $0.id == ID.chapterDisplay }
                .flatMap { EBML.children($0.data).first { $0.id == ID.chapString } }
                .map { EBML.string($0.data) } ?? "Chapter"
            // Chapter times are in nanoseconds regardless of the timecode scale.
            return [ContainerChapter(title: title, start: Double(EBML.uint(start.data)) / 1_000_000_000, end: end)] + nested
        }
    }

    static func codec(for id: String, kind: ContainerTrackKind) -> MediaCodec {
        switch id {
        case "V_MPEG4/ISO/AVC": .h264
        case "V_MPEGH/ISO/HEVC": .hevc
        case "V_AV1": .av1
        case "V_MPEG4/ISO/ASP", "V_MPEG4/ISO/SP", "V_MPEG4/ISO/AP": .mpeg4Part2
        case "V_VP9": .vp9
        case "V_VP8": .vp8
        case "V_THEORA": .theora
        case "V_MPEG1": .mpeg1Video
        case "V_MPEG2": .mpeg2Video
        case "V_MJPEG": .mjpeg
        case let aac where aac.hasPrefix("A_AAC"): .aac
        case "A_AC3", "A_AC3/BSID9", "A_AC3/BSID10": .ac3
        case "A_EAC3": .eac3
        case "A_MPEG/L3": .mp3
        case "A_MPEG/L2": .mp2
        case "A_PCM/INT/LIT": .pcm(bits: 16, isFloat: false, isBigEndian: false)
        case "A_PCM/INT/BIG": .pcm(bits: 16, isFloat: false, isBigEndian: true)
        case "A_PCM/FLOAT/IEEE": .pcm(bits: 32, isFloat: true, isBigEndian: false)
        case "S_TEXT/UTF8", "S_TEXT/ASCII": .textUTF8
        case "S_TEXT/ASS", "S_TEXT/SSA", "S_ASS", "S_SSA": .textASS
        case "A_DTS", "A_DTS/LOSSLESS": .dts
        case "A_DTS/EXPRESS": .unsupported("DTS Express")
        case "A_TRUEHD": .unsupported("Dolby TrueHD")
        case "A_FLAC": .flac
        case "A_OPUS": .opus
        case "A_VORBIS": .vorbis
        case "S_HDMV/PGS": .pgs
        case "S_VOBSUB": .vobSub
        default: .unsupported(id)
        }
    }

    // MARK: Blocks

    private func readBlockGroup(_ header: ElementHeader) throws -> [MediaPacket]? {
        let fields = EBML.children(try bytes(header))
        guard let block = fields.first(where: { $0.id == ID.block }) else { return nil }
        let duration = fields.first { $0.id == ID.blockDuration }.map { EBML.uint($0.data) }
        let hasReference = fields.contains { $0.id == ID.referenceBlock }
        return try parseBlock(block.data, isSimple: false, groupDuration: duration, hasReference: hasReference)
    }

    private func readBlock(_ header: ElementHeader, isSimple: Bool, groupDuration: UInt64?, hasReference: Bool) throws -> [MediaPacket]? {
        // Peek the track number before reading the (possibly large) payload.
        let peek = try source.read(at: header.dataOffset, count: 8)
        var reader = ByteReader(peek)
        let track = Int(try EBML.readSize(&reader).value)
        guard enabledTrackIDs.contains(track) else { return nil }
        return try parseBlock(try bytes(header)[...], isSimple: isSimple, groupDuration: groupDuration, hasReference: hasReference)
    }

    private func parseBlock(_ data: ArraySlice<UInt8>, isSimple: Bool, groupDuration: UInt64?, hasReference: Bool) throws -> [MediaPacket]? {
        var reader = ByteReader(Array(data))
        let trackNumber = Int(try EBML.readSize(&reader).value)
        guard enabledTrackIDs.contains(trackNumber), let track = tracks.first(where: { $0.id == trackNumber }) else { return nil }
        let relative = Int16(bitPattern: try reader.u16be())
        let flags = try reader.u8()
        let isKeyframe = isSimple ? (flags & 0x80) != 0 : !hasReference

        let frames = try Self.splitLaced(&reader, lacing: (flags >> 1) & 0x03)
        let start = Double(clusterTimecode + Int64(relative)) * timecodeScale / 1_000_000_000
        let step = track.frameDuration
            ?? track.codec.samplesPerFrame.flatMap { samples in track.sampleRate.map { Double(samples) / $0 } }
            ?? 0
        let blockDuration = groupDuration.map { Double($0) * timecodeScale / 1_000_000_000 }

        return frames.enumerated().map { index, frame in
            MediaPacket(trackID: trackNumber,
                        pts: start + Double(index) * step,
                        duration: frames.count == 1 ? (blockDuration ?? track.frameDuration) : step,
                        isKeyframe: isKeyframe,
                        data: decode(Data(frame), track: trackNumber))
        }
    }

    /// Splits a block's payload into frames according to its lacing mode.
    static func splitLaced(_ reader: inout ByteReader, lacing: UInt8) throws -> [ArraySlice<UInt8>] {
        guard lacing != 0 else { return [try reader.take(reader.remaining)] }
        let count = Int(try reader.u8()) + 1
        var sizes: [Int] = []
        switch lacing {
        case 1: // Xiph
            for _ in 0..<(count - 1) {
                var size = 0
                var byte: UInt8
                repeat {
                    byte = try reader.u8()
                    size += Int(byte)
                } while byte == 255
                sizes.append(size)
            }
        case 3: // EBML: first size, then signed differences.
            var size = Int(try EBML.readSize(&reader).value)
            sizes.append(size)
            for _ in 1..<max(count - 1, 1) where count > 2 {
                let (raw, length) = try EBML.readSize(&reader)
                let bias = (1 << (7 * length - 1)) - 1
                size += Int(raw) - bias
                sizes.append(size)
            }
        case 2: // Fixed: equal sizes.
            let each = reader.remaining / count
            sizes = Array(repeating: each, count: count - 1)
        default:
            break
        }
        var frames = try sizes.map { try reader.take($0) }
        frames.append(try reader.take(reader.remaining))
        return frames
    }

    private func decode(_ frame: Data, track: Int) -> Data {
        switch encodings[track] {
        case .headerStripping(let header): header + frame
        case .zlib: (try? (frame.dropFirst(2) as NSData).decompressed(using: .zlib) as Data) ?? frame
        case nil: frame
        }
    }

    // MARK: Element access

    struct ElementHeader {
        let id: UInt32
        let dataOffset: UInt64
        let size: UInt64?
    }

    private func readHeader(at offset: UInt64) throws -> ElementHeader {
        var reader = ByteReader(try source.read(at: offset, count: 12))
        let id = try EBML.readID(&reader)
        let (size, length) = try EBML.readSize(&reader)
        let isUnknown = size == (UInt64(1) << (7 * UInt64(length))) - 1
        return ElementHeader(id: id, dataOffset: offset + UInt64(reader.position), size: isUnknown ? nil : size)
    }

    private func end(of header: ElementHeader) throws -> UInt64 {
        guard let size = header.size else { throw ContainerError.corrupt("unexpected unknown-size element") }
        return header.dataOffset + size
    }

    private func payload(_ header: ElementHeader) throws -> Data {
        guard let size = header.size else { throw ContainerError.corrupt("unknown-size element") }
        let data = try source.read(at: header.dataOffset, count: Int(size))
        guard data.count == Int(size) else { throw ContainerError.truncated }
        return data
    }

    private func bytes(_ header: ElementHeader) throws -> ArraySlice<UInt8> {
        ArraySlice(try payload(header))
    }
}

/// EBML variable-length integers and in-memory element trees.
nonisolated enum EBML {
    struct Element {
        let id: UInt32
        let data: ArraySlice<UInt8>
    }

    /// Element IDs keep their length-marker bits.
    static func readID(_ reader: inout ByteReader) throws -> UInt32 {
        let first = try reader.u8()
        let length = first.leadingZeroBitCount + 1
        guard length <= 4 else { throw ContainerError.corrupt("invalid element ID") }
        var value = UInt32(first)
        for _ in 1..<length { value = value << 8 | UInt32(try reader.u8()) }
        return value
    }

    /// Sizes (and track numbers) drop the marker bit. Returns the value and its byte length.
    static func readSize(_ reader: inout ByteReader) throws -> (value: UInt64, length: Int) {
        let first = try reader.u8()
        let length = first.leadingZeroBitCount + 1
        guard length <= 8 else { throw ContainerError.corrupt("invalid size") }
        var value = UInt64(first) & ((1 << (8 - length)) - 1)
        for _ in 1..<length { value = value << 8 | UInt64(try reader.u8()) }
        return (value, length)
    }

    static func children(_ data: ArraySlice<UInt8>) -> [Element] {
        var reader = ByteReader(Array(data))
        var elements: [Element] = []
        while !reader.isAtEnd {
            guard let id = try? readID(&reader), let (size, _) = try? readSize(&reader),
                  let payload = try? reader.take(Int(min(size, UInt64(reader.remaining)))) else { break }
            elements.append(Element(id: id, data: payload))
        }
        return elements
    }

    static func uint(_ data: ArraySlice<UInt8>) -> UInt64 {
        data.reduce(0) { $0 << 8 | UInt64($1) }
    }

    static func float(_ data: ArraySlice<UInt8>) -> Double {
        let bits = uint(data)
        switch data.count {
        case 4: return Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits)))
        case 8: return Double(bitPattern: bits)
        default: return 0
        }
    }

    static func string(_ data: ArraySlice<UInt8>) -> String {
        String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
    }
}
