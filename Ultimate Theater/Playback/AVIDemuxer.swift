//
//  AVIDemuxer.swift
//  Ultimate Theater
//
//  Reads AVI (RIFF) files: stream headers, the idx1 index, and movi chunks, plus
//  OpenDML (AVI 2.0) extensions for files over 1 GB: AVIX chunks and indx/ix## indexes.
//

import Foundation

nonisolated final class AVIDemuxer: MediaDemuxer {
    private(set) var tracks: [ContainerTrack] = []
    private(set) var duration: Double?
    let chapters: [ContainerChapter] = []
    var enabledTrackIDs: Set<Int> = []

    private let source: FileByteSource
    private var streams: [Stream] = []
    private var moviStart: UInt64 = 0
    private var moviEnd: UInt64 = 0
    /// Every 'movi' list: the first RIFF's, then one per OpenDML 'RIFF AVIX' chunk.
    /// `start` points at the 'movi' FourCC.
    private var moviRanges: [(start: UInt64, end: UInt64)] = []
    /// OpenDML total frame count ('dmlh'), which covers every RIFF chunk.
    private var totalFrames: Double?
    /// All chunks in file order with precomputed timestamps (from idx1 or OpenDML indexes).
    private var index: [IndexEntry] = []
    private var nextIndex = 0
    /// Sequential reading: the fallback when there's no index, and the continuation into
    /// AVIX chunks an idx1 doesn't cover.
    private var scanRange = 0
    private var scanCursor: UInt64 = 0
    private var scanCounters: [Int: (frames: Int, bytes: Int)] = [:]
    /// Where scanning resumes once the index runs out, and the stream counters at that point.
    private var scanResumeRange: Int?
    private var indexEndCounters: [Int: (frames: Int, bytes: Int)] = [:]

    private struct Stream {
        let type: String
        let handler: String
        let scale: Double
        let rate: Double
        let start: Double
        let length: Double
        let sampleSize: Int
        var format = Data()
        var name: String?
        /// OpenDML super index ('indx' body), listing this stream's ix## chunks.
        var superIndex: Data?

        var secondsPerUnit: Double { rate > 0 ? scale / rate : 0 }
    }

    private struct IndexEntry {
        let stream: Int
        let offset: UInt64
        let size: Int
        let isKeyframe: Bool
        let pts: Double
    }

    init(source: FileByteSource) throws {
        self.source = source
        try parse()
        try loadMPEG4Configuration()
        enabledTrackIDs = Set(tracks.map(\.id))
        restartScan()
    }

    /// Positions sequential reading where it begins: the first movi list without an index,
    /// or the first AVIX movi list past what idx1 covers.
    private func restartScan() {
        if index.isEmpty {
            scanRange = 0
            scanCounters = [:]
        } else {
            scanRange = scanResumeRange ?? moviRanges.count
            scanCounters = indexEndCounters
        }
        scanCursor = scanRange < moviRanges.count ? moviRanges[scanRange].start + 4 : 0
    }

    // MARK: Packets

    func nextPacket() throws -> MediaPacket? {
        if !index.isEmpty {
            while nextIndex < index.count {
                let entry = index[nextIndex]
                nextIndex += 1
                guard enabledTrackIDs.contains(entry.stream), entry.size > 0,
                      entry.size <= FileByteSource.maxPayloadSize else { continue }
                let data = try source.read(at: entry.offset, count: entry.size)
                return MediaPacket(trackID: entry.stream, pts: entry.pts, duration: frameDuration(entry.stream),
                                   isKeyframe: entry.isKeyframe, data: data)
            }
            // idx1 covers only the first RIFF chunk; AVIX chunks after it are read in order.
            guard scanResumeRange != nil else { return nil }
        }
        return try nextScannedPacket()
    }

    @discardableResult
    func seek(to seconds: Double) throws -> Double {
        guard !index.isEmpty else {
            // Without an index only a restart is possible.
            restartScan()
            return 0
        }
        restartScan() // Reading continues past the index again after the seek.
        let video = tracks.first { $0.kind == .video }?.id
        let candidate = index.indices.last { i in
            let entry = index[i]
            return entry.pts <= seconds && entry.isKeyframe && (video == nil || entry.stream == video)
        } ?? 0
        // Start from that frame; audio within the same interleave window follows naturally.
        nextIndex = candidate
        return index[candidate].pts
    }

    /// XviD and DivX write their stream setup (VOS/VOL headers) only into the first frame.
    /// Keeping it with the track lets decoding start at any keyframe, after a seek or resume.
    private func loadMPEG4Configuration() throws {
        for (position, track) in tracks.enumerated() where track.codec == .mpeg4Part2 && track.codecPrivate == nil {
            guard let first = index.first(where: { $0.stream == track.id && $0.size > 0 }) else { continue }
            let data = try source.read(at: first.offset, count: first.size)
            if let config = MPEG4Part2.configuration(in: data) { tracks[position].codecPrivate = config }
        }
    }

    // MARK: Parsing

    private func parse() throws {
        let header = try source.read(at: 0, count: 12)
        guard header.count == 12 else { throw ContainerError.truncated }
        var position: UInt64 = 12
        let riffEnd = min(UInt64(Self.le32(header, 4)) + 8, source.size)

        var idx1: (offset: UInt64, size: Int)?
        var isFirstMovi = true
        while position + 8 <= riffEnd {
            let chunk = try source.read(at: position, count: 12)
            guard chunk.count >= 8 else { break }
            let id = String(decoding: chunk.prefix(4), as: UTF8.self)
            let size = UInt64(Self.le32(chunk, 4))
            if id == "LIST", chunk.count >= 12 {
                let type = String(decoding: chunk.subdata(in: 8..<12), as: UTF8.self)
                if type == "hdrl" {
                    try parseHeaderList(at: position + 12, end: position + 8 + size)
                } else if type == "movi", isFirstMovi {
                    isFirstMovi = false
                    moviStart = position + 8 // Points at the 'movi' FourCC.
                    moviEnd = min(position + 8 + size, source.size)
                }
            } else if id == "idx1" {
                idx1 = (position + 8, Int(size))
            }
            position += 8 + size + (size & 1)
        }
        guard !streams.isEmpty, moviStart > 0 else { throw ContainerError.corrupt("missing AVI headers") }
        moviRanges = [(moviStart, moviEnd)]
        try findExtendedChunks(after: riffEnd + (riffEnd & 1))

        tracks = streams.enumerated().compactMap { index, stream in makeTrack(index, stream) }
        // OpenDML indexes cover the whole file; idx1 only the first RIFF chunk.
        let indexed = tracks.map(\.id)
        if !indexed.isEmpty, indexed.allSatisfy({ streams[$0].superIndex != nil }) {
            try buildOpenDMLIndex(streams: indexed)
        }
        // An idx1 too large to read in one go comes from damage (or an absurd chunk count);
        // reading the movi list in order still plays the file.
        if index.isEmpty, let idx1, idx1.size <= FileByteSource.maxReadSize {
            try buildIndex(at: idx1.offset, size: idx1.size)
            if !index.isEmpty, moviRanges.count > 1 {
                scanResumeRange = 1
                indexEndCounters = indexCounters
            }
        }

        let videoStream = streams.first { $0.type == "vids" }
        // Damaged length, scale, or rate fields can give absurd durations; those count as unknown.
        if let videoStream {
            duration = FormatValidation.duration(max(videoStream.length, totalFrames ?? 0) * videoStream.secondsPerUnit)
        } else {
            duration = FormatValidation.duration(index.last?.pts)
        }
    }

    /// Stream counters after the last idx1 entry, so AVIX chunks continue its timeline.
    private var indexCounters: [Int: (frames: Int, bytes: Int)] = [:]

    /// OpenDML: each 'RIFF AVIX' chunk after the first RIFF holds another 'movi' list.
    private func findExtendedChunks(after start: UInt64) throws {
        var position = start
        while position + 12 <= source.size {
            let chunk = try source.read(at: position, count: 12)
            guard chunk.count == 12, chunk.prefix(4) == Data("RIFF".utf8),
                  chunk.subdata(in: 8..<12) == Data("AVIX".utf8) else { break }
            let size = UInt64(Self.le32(chunk, 4))
            let end = min(position + 8 + size, source.size)
            var inner = position + 12
            while inner + 12 <= end {
                let head = try source.read(at: inner, count: 12)
                guard head.count == 12 else { break }
                let innerSize = UInt64(Self.le32(head, 4))
                if head.prefix(4) == Data("LIST".utf8), head.subdata(in: 8..<12) == Data("movi".utf8) {
                    moviRanges.append((inner + 8, min(inner + 8 + innerSize, end)))
                }
                inner += 8 + innerSize + (innerSize & 1)
            }
            position += 8 + size + (size & 1)
        }
    }

    /// Builds the index from each stream's OpenDML super index and its ix## chunks.
    private func buildOpenDMLIndex(streams ids: [Int]) throws {
        var perStream: [[(offset: UInt64, size: Int, isKeyframe: Bool)]] = []
        // A chunk needs at least its 8-byte header, which bounds how many entries can be real.
        let entryLimit = Int(clamping: source.size / 8)
        var total = 0
        for stream in ids {
            guard let indx = streams[stream].superIndex, indx.count >= 24 else { return }
            let longsPerEntry = Int(Self.le16(indx, 0))
            guard longsPerEntry == 4, indx[indx.startIndex + 3] == 0 else { return } // AVI_INDEX_OF_INDEXES
            let count = min(Int(Self.le32(indx, 4)), (indx.count - 24) / 16)
            var entries: [(offset: UInt64, size: Int, isKeyframe: Bool)] = []
            // A damaged super index may list the same ix## chunk over and over; read each once.
            var visited = Set<UInt64>()
            for i in 0..<count {
                let at = 24 + i * 16
                let chunkOffset = UInt64(Self.le32(indx, at)) | UInt64(Self.le32(indx, at + 4)) << 32
                guard chunkOffset < source.size, visited.insert(chunkOffset).inserted else { continue }
                let chunks = try readStandardIndex(at: chunkOffset)
                guard total + chunks.count <= entryLimit else { break }
                total += chunks.count
                entries += chunks
            }
            guard !entries.isEmpty else { return }
            perStream.append(entries)
        }
        // Timestamps follow each stream's order; the merged index follows file order.
        var counters = [Int: (frames: Int, bytes: Int)]()
        var merged: [IndexEntry] = []
        merged.reserveCapacity(perStream.reduce(0) { $0 + $1.count })
        for (position, stream) in ids.enumerated() {
            for chunk in perStream[position] {
                let pts = timestamp(stream: stream, counters: &counters, size: chunk.size)
                merged.append(IndexEntry(stream: stream, offset: chunk.offset, size: chunk.size,
                                         isKeyframe: chunk.isKeyframe || streams[stream].type != "vids", pts: pts))
            }
        }
        index = merged.sorted { $0.offset < $1.offset }
    }

    /// Entries of one OpenDML standard index ('ix##', AVI_INDEX_OF_CHUNKS): data offsets
    /// relative to a base, and sizes whose top bit marks non-keyframes.
    private func readStandardIndex(at offset: UInt64) throws -> [(offset: UInt64, size: Int, isKeyframe: Bool)] {
        let head = try source.read(at: offset, count: 8)
        guard head.count == 8 else { return [] }
        let size = Int(Self.le32(head, 4))
        guard size >= 24, size <= FileByteSource.maxPayloadSize else { return [] }
        let body = try source.read(at: offset + 8, count: size)
        guard body.count >= 24, body[body.startIndex + 3] == 1 else { return [] } // AVI_INDEX_OF_CHUNKS
        let stride = max(Int(Self.le16(body, 0)), 2) * 4
        let count = min(Int(Self.le32(body, 4)), (body.count - 24) / stride)
        let base = UInt64(Self.le32(body, 12)) | UInt64(Self.le32(body, 16)) << 32
        guard base < source.size else { return [] }
        var entries: [(offset: UInt64, size: Int, isKeyframe: Bool)] = []
        entries.reserveCapacity(count)
        for i in 0..<count {
            let at = 24 + i * stride
            let chunkOffset = base + UInt64(Self.le32(body, at))
            let rawSize = Self.le32(body, at + 4)
            guard chunkOffset < source.size else { continue }
            entries.append((chunkOffset, Int(rawSize & 0x7FFF_FFFF), rawSize & 0x8000_0000 == 0))
        }
        return entries
    }

    private func parseHeaderList(at start: UInt64, end: UInt64) throws {
        var position = start
        while position + 8 <= end {
            let chunk = try source.read(at: position, count: 12)
            guard chunk.count >= 8 else { break }
            let id = String(decoding: chunk.prefix(4), as: UTF8.self)
            let size = UInt64(Self.le32(chunk, 4))
            if id == "LIST", chunk.count >= 12, String(decoding: chunk.subdata(in: 8..<12), as: UTF8.self) == "strl" {
                try parseStreamList(at: position + 12, end: position + 8 + size)
            } else if id == "LIST", chunk.count >= 12, String(decoding: chunk.subdata(in: 8..<12), as: UTF8.self) == "odml" {
                // OpenDML header: 'dmlh' starts with the total frame count of every RIFF chunk.
                let dmlh = try source.read(at: position + 12, count: 12)
                if dmlh.count == 12, dmlh.prefix(4) == Data("dmlh".utf8), Self.le32(dmlh, 8) > 0 {
                    totalFrames = Double(Self.le32(dmlh, 8))
                }
            }
            position += 8 + size + (size & 1)
        }
    }

    private func parseStreamList(at start: UInt64, end: UInt64) throws {
        var position = start
        var stream: Stream?
        while position + 8 <= end {
            let head = try source.read(at: position, count: 8)
            guard head.count == 8 else { break }
            let id = String(decoding: head.prefix(4), as: UTF8.self)
            let size = Int(Self.le32(head, 4))
            // Header chunks are small; a giant size is damage, so its body is skipped.
            let body = size <= FileByteSource.maxPayloadSize ? try source.read(at: position + 8, count: size) : Data()
            switch id {
            case "strh" where body.count >= 48:
                stream = Stream(
                    type: String(decoding: body.prefix(4), as: UTF8.self),
                    handler: String(decoding: body.subdata(in: 4..<8), as: UTF8.self),
                    scale: Double(Self.le32(body, 20)),
                    rate: Double(Self.le32(body, 24)),
                    start: Double(Self.le32(body, 28)),
                    length: Double(Self.le32(body, 32)),
                    sampleSize: Int(Self.le32(body, 44))
                )
            case "strf":
                stream?.format = body
            case "strn":
                stream?.name = String(decoding: body.prefix { $0 != 0 }, as: UTF8.self)
            case "indx":
                stream?.superIndex = body
            default:
                break
            }
            position += 8 + UInt64(size) + UInt64(size & 1)
        }
        if let stream { streams.append(stream) }
    }

    private func makeTrack(_ index: Int, _ stream: Stream) -> ContainerTrack? {
        let format = stream.format
        switch stream.type {
        case "vids":
            guard format.count >= 20 else { return nil }
            let fourCC = String(decoding: format.subdata(in: 16..<20), as: UTF8.self)
            var track = ContainerTrack(id: index, kind: .video, codec: Self.videoCodec(fourCC.isEmpty ? stream.handler : fourCC),
                                       codecID: fourCC)
            track.width = Int(Int32(bitPattern: Self.le32(format, 4)))
            track.height = abs(Int(Int32(bitPattern: Self.le32(format, 8))))
            if case .dv(let codec) = track.codec, track.height == 576 {
                track.codec = .dv(codec == 0x6476_356E ? 0x6476_3570 : 0x6476_6370) // PAL: 'dv5p' / 'dvcp'
            }
            track.frameDuration = stream.secondsPerUnit
            track.isAnnexB = track.codec == .h264 || track.codec == .hevc
            // Codec setup data (e.g. an H.264 avcC or MPEG-4 VOL) may follow the header.
            if format.count > 40 { track.codecPrivate = format.subdata(in: 40..<format.count) }
            track.name = stream.name
            return track
        case "auds":
            guard format.count >= 16 else { return nil }
            var tag = Int(Self.le16(format, 0))
            let bits = Int(Self.le16(format, 14))
            // WAVE_FORMAT_EXTENSIBLE: the real tag is the first two bytes of the sub-format GUID.
            if tag == 0xFFFE, format.count >= 26 { tag = Int(Self.le16(format, 24)) }
            var track = ContainerTrack(id: index, kind: .audio, codec: Self.audioCodec(tag, bits: bits),
                                       codecID: String(format: "0x%04X", tag))
            track.needsFraming = [.mp3, .mp2, .ac3, .eac3, .dts].contains(track.codec) // Chunks don't align to frames.
            track.channels = Int(Self.le16(format, 2))
            track.sampleRate = Double(Self.le32(format, 4))
            track.bitDepth = bits
            track.blockAlign = Int(Self.le16(format, 12))
            if format.count >= 20 { track.samplesPerBlock = Int(Self.le16(format, 18)) }
            let extraSize = format.count >= 18 ? Int(Self.le16(format, 16)) : 0
            if extraSize > 0, format.count >= 18 + extraSize, tag != 0xFFFE {
                track.codecPrivate = format.subdata(in: 18..<(18 + extraSize))
            }
            track.name = stream.name
            return track
        default:
            return nil
        }
    }

    private func buildIndex(at offset: UInt64, size: Int) throws {
        let data = try source.read(at: offset, count: size)
        let count = data.count / 16
        guard count > 0 else { return }

        // idx1 offsets are relative to the 'movi' FourCC in most files, absolute in some.
        let firstOffset = UInt64(Self.le32(data, 8))
        let firstID = data.prefix(4)
        let relativeProbe = try source.read(at: moviStart + firstOffset, count: 4)
        let base: UInt64 = relativeProbe == firstID ? moviStart : 0

        var counters = [Int: (frames: Int, bytes: Int)]()
        index.reserveCapacity(count)
        for i in 0..<count {
            let entry = i * 16
            let id = data.subdata(in: entry..<(entry + 4))
            guard let stream = Self.streamNumber(id), stream < streams.count else { continue }
            let flags = Self.le32(data, entry + 4)
            let chunkOffset = base + UInt64(Self.le32(data, entry + 8)) + 8
            let chunkSize = Int(Self.le32(data, entry + 12))
            let pts = timestamp(stream: stream, counters: &counters, size: chunkSize)
            index.append(IndexEntry(stream: stream, offset: chunkOffset, size: chunkSize,
                                    isKeyframe: (flags & 0x10) != 0 || streams[stream].type != "vids", pts: pts))
        }
        indexCounters = counters
    }

    private func nextScannedPacket() throws -> MediaPacket? {
        while scanRange < moviRanges.count {
            guard scanCursor + 8 <= moviRanges[scanRange].end else {
                // On to the next AVIX chunk's movi list.
                scanRange += 1
                if scanRange < moviRanges.count { scanCursor = moviRanges[scanRange].start + 4 }
                continue
            }
            let head = try source.read(at: scanCursor, count: 12)
            guard head.count >= 8 else { return nil }
            let id = head.prefix(4)
            let size = UInt64(Self.le32(head, 4))
            if id == Data("LIST".utf8) {
                scanCursor += 12 // Descend into 'rec ' lists.
                continue
            }
            let dataOffset = scanCursor + 8
            scanCursor += 8 + size + (size & 1)
            guard let stream = Self.streamNumber(id), stream < streams.count else { continue }
            let pts = timestamp(stream: stream, counters: &scanCounters, size: Int(size))
            guard enabledTrackIDs.contains(stream), size > 0, size <= UInt64(FileByteSource.maxPayloadSize) else { continue }
            let data = try source.read(at: dataOffset, count: Int(size))
            let isKeyframe = streams[stream].type != "vids" || Self.looksLikeKeyframe(data, codec: tracks.first { $0.id == stream }?.codec)
            return MediaPacket(trackID: stream, pts: pts, duration: frameDuration(stream), isKeyframe: isKeyframe, data: data)
        }
        return nil
    }

    /// Timestamp for the next chunk of a stream, advancing its counters.
    private func timestamp(stream: Int, counters: inout [Int: (frames: Int, bytes: Int)], size: Int) -> Double {
        let info = streams[stream]
        var counter = counters[stream] ?? (0, 0)
        defer { counters[stream] = counter }
        if info.type == "auds", info.sampleSize > 0 {
            // Constant-size samples: time follows bytes.
            let units = Double(counter.bytes) / Double(info.sampleSize)
            counter.bytes += size
            return (info.start + units) * info.secondsPerUnit
        }
        let pts = (info.start + Double(counter.frames)) * info.secondsPerUnit
        counter.frames += 1
        return pts
    }

    private func frameDuration(_ stream: Int) -> Double? {
        let info = streams[stream]
        return info.type == "vids" ? info.secondsPerUnit : nil
    }

    // MARK: Codec mapping

    static func videoCodec(_ fourCC: String) -> MediaCodec {
        switch fourCC.uppercased() {
        case "H264", "X264", "AVC1", "DAVC", "VSSH": .h264
        case "HEVC", "H265", "HEV1", "HVC1", "X265": .hevc
        case "XVID", "DIVX", "DX50", "FMP4", "MP4V", "M4S2", "3IV2", "MP4S": .mpeg4Part2
        case "MPG1", "PIM1", "MPEG": .mpeg1Video
        case "MPG2", "MPEG2", "EM2V", "MMES", "PIM2", "DVR ": .mpeg2Video
        case "H263", "U263", "S263", "X263": .h263
        case "VP90": .vp9
        case "VP80": .vp8
        case "MJPG", "AVRN", "JPEG", "DMB1": .mjpeg
        case "DVSD", "DV25", "CDVC", "DVC ": .dv(0x6476_6320)   // 'dvc ' (PAL is chosen from the height)
        case "DV50", "DV5N": .dv(0x6476_356E)                   // 'dv5n'
        case "DIV3", "MP43", "MP42": .unsupported("DivX 3 (MS-MPEG4)")
        case "WMV1", "WMV2", "WMV3", "WVC1": .unsupported("Windows Media Video")
        default: .unsupported(fourCC.trimmingCharacters(in: .whitespaces))
        }
    }

    static func audioCodec(_ tag: Int, bits: Int) -> MediaCodec {
        switch tag {
        case 0x0001: .pcm(bits: bits, isFloat: false, isBigEndian: false)
        case 0x0002: .adpcmMS
        case 0x0006: .aLaw
        case 0x0007: .muLaw
        case 0x0011: .adpcmIMA
        case 0xF1AC: .flac
        case 0x704F: .opus
        case 0x566F: .vorbis
        case 0x0003: .pcm(bits: bits, isFloat: true, isBigEndian: false)
        case 0x0050: .mp2
        case 0x0055: .mp3
        case 0x2000: .ac3
        case 0x00FF, 0x1610, 0x706D, 0x4143: .aac
        case 0x2001: .dts
        case 0x0161, 0x0162, 0x0163: .unsupported("Windows Media Audio")
        default: .unsupported(String(format: "audio format 0x%04X", tag))
        }
    }

    /// Stream number from a chunk ID like "00dc" or "01wb".
    private static func streamNumber(_ id: Data) -> Int? {
        guard id.count == 4, let tens = Character(UnicodeScalar(id[id.startIndex])).wholeNumberValue,
              let ones = Character(UnicodeScalar(id[id.startIndex + 1])).wholeNumberValue else { return nil }
        return tens * 10 + ones
    }

    private static func looksLikeKeyframe(_ data: Data, codec: MediaCodec?) -> Bool {
        switch codec {
        case .mpeg4Part2: MPEG4Part2.vopType(in: data) == .intra
        case .h264: AnnexB.nalUnits(in: data).contains { ($0.first ?? 0) & 0x1F == 5 }
        default: true
        }
    }

    // MARK: Little-endian helpers

    static func le16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        let start = data.startIndex + offset
        return UInt16(data[start]) | UInt16(data[start + 1]) << 8
    }

    static func le32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let start = data.startIndex + offset
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[start + $1]) << (8 * $1) }
    }
}
