//
//  PESDemuxer.swift
//  Ultimate Theater
//
//  Shared reading for MPEG transport streams (TS/M2TS) and program streams (MPG/VOB):
//  PES headers and timestamps, splitting video byte streams into access units,
//  identifying codecs from their bitstreams, duration, and seeking by bisection.
//

import Foundation
import CoreMedia

/// One PES packet's payload, as read from a transport or program stream.
nonisolated struct PESPacket {
    /// Stream key: the TS PID, or the PS stream id (private-stream sub-ids as 0xBD00 | id).
    let stream: Int
    /// Raw 33-bit 90 kHz timestamps.
    let pts: Int64?
    let dts: Int64?
    var payload: Data
    /// Byte offset where this PES began, for seeking back to it.
    let offset: UInt64
}

/// What a packetized stream carries, as declared by stream tables or sniffed from its data.
nonisolated struct ElementaryStreamInfo {
    var kind: ContainerTrackKind
    var codec: MediaCodec
    var codecID: String
    var language: String?
    /// Bytes to drop from the front of every payload (Blu-ray LPCM headers).
    var payloadHeader = 0
    /// Dolby Digital frames are extracted from a stream that also carries other data.
    var extractsCore = false
    var name: String?
    /// DVD LPCM at 20 or 24 bits, whose samples are stored in groups (converted to plain 24-bit).
    var dvdLPCMBits: Int?
    /// Codec setup known from outside the stream (DVD subtitle palettes from the IFO).
    var codecPrivate: Data?
    var sampleRate: Double?
    var channels: Int?
}

/// Reads PES packets sequentially. Implemented by the transport and program stream readers.
nonisolated protocol PESReader: AnyObject {
    var size: UInt64 { get }
    /// Streams known so far, from tables (PMT, PSM) or discovered while reading.
    var streams: [Int: ElementaryStreamInfo] { get }
    /// When set, payloads of other streams are skipped without being assembled.
    var wantedStreams: Set<Int>? { get set }
    /// When set, reading stops (`nextPES` returns nil) once it reaches this byte offset.
    var readLimit: UInt64? { get set }
    func nextPES() throws -> PESPacket?
    /// Restarts reading at `offset`, resynchronizing to the next packet boundary.
    func reposition(to offset: UInt64) throws
}

nonisolated enum PES {
    /// Parses a complete PES packet (starting 00 00 01 id). Handles MPEG-2 and MPEG-1 headers.
    static func parse(_ data: Data, stream: Int, offset: UInt64) -> PESPacket? {
        let b = [UInt8](data.prefix(64))
        guard b.count >= 9, b[0] == 0, b[1] == 0, b[2] == 1 else { return nil }
        let id = b[3]
        // Streams without the optional header: padding, private stream 2, ECM/EMM, directory.
        if [0xBE, 0xBF, 0xF0, 0xF1, 0xF2, 0xF8, 0xFF].contains(id) {
            return PESPacket(stream: stream, pts: nil, dts: nil, payload: data.dropFirst(6), offset: offset)
        }
        var pts: Int64?
        var dts: Int64?
        var start: Int
        if b[6] & 0xC0 == 0x80 { // MPEG-2
            let flags = b[7] >> 6
            start = 9 + Int(b[8])
            if flags & 2 != 0, b.count >= 14 { pts = timestamp(b, 9) }
            if flags == 3, b.count >= 19 { dts = timestamp(b, 14) }
        } else { // MPEG-1: stuffing, optional STD buffer size, then timestamps.
            var i = 6
            while i < b.count, b[i] == 0xFF { i += 1 }
            if i < b.count, b[i] & 0xC0 == 0x40 { i += 2 }
            guard i < b.count else { return nil }
            switch b[i] >> 4 {
            case 2:
                pts = i + 5 <= b.count ? timestamp(b, i) : nil
                i += 5
            case 3:
                pts = i + 10 <= b.count ? timestamp(b, i) : nil
                dts = i + 10 <= b.count ? timestamp(b, i + 5) : nil
                i += 10
            default:
                i += 1
            }
            start = i
        }
        guard start <= data.count else { return nil }
        return PESPacket(stream: stream, pts: pts, dts: dts, payload: data.dropFirst(start), offset: offset)
    }

    static func timestamp(_ b: [UInt8], _ i: Int) -> Int64 {
        Int64((b[i] >> 1) & 0x07) << 30 | Int64(b[i + 1]) << 22 | Int64(b[i + 2] >> 1) << 15
            | Int64(b[i + 3]) << 7 | Int64(b[i + 4] >> 1)
    }
}

// MARK: - Demuxer

/// A demuxer over PES packets: probes the streams, times and frames their data, and seeks.
nonisolated final class PESDemuxer: MediaDemuxer {
    let tracks: [ContainerTrack]
    let duration: Double?
    let chapters: [ContainerChapter] = []
    var enabledTrackIDs: Set<Int> {
        didSet { reader.wantedStreams = enabledTrackIDs }
    }

    private let reader: PESReader
    /// The 90 kHz origin: the earliest timestamp near the start of the file.
    private let origin: Int64
    private let videoID: Int?
    private var videoSplitter: AccessUnitSplitter?
    /// Audio and subtitle payloads held until the next timestamped PES of the same stream.
    private var held: [Int: MediaPacket] = [:]
    /// Leftover bytes of DVD LPCM sample groups, by stream.
    private var lpcmCarry: [Int: Data] = [:]
    /// Broadcast audio unwrapped here: LATM parsers and each stream's next packet time.
    private var latmParsers: [Int: LATMParser] = [:]
    private var nextAudioTime: [Int: Double] = [:]
    private var ready: [MediaPacket] = []
    private var isAtEnd = false

    private static let probeBytes: UInt64 = 24 << 20
    /// Most payload held for an audio or subtitle packet awaiting its successor.
    private static let maxHeldBytes = 8 << 20

    init(reader: PESReader) throws {
        self.reader = reader
        // Probe: gather the first payloads and timestamps of each stream.
        var firstData: [Int: Data] = [:]
        var firstTimes: [Int64] = []
        var order: [Int] = []
        var counts: [Int: Int] = [:]
        var probed: UInt64 = 0
        while let pes = try reader.nextPES(), probed < Self.probeBytes {
            probed = pes.offset
            guard reader.streams[pes.stream] != nil else { continue }
            if firstData[pes.stream] == nil { order.append(pes.stream) }
            counts[pes.stream, default: 0] += 1
            if (firstData[pes.stream]?.count ?? 0) < 512 << 10 { firstData[pes.stream, default: Data()].append(pes.payload) }
            // Playback starts at the first presentation time (decode times can be earlier).
            if let pts = pes.pts, firstTimes.count < 64 { firstTimes.append(pts) }
            let allSeen = Set(order) == Set(reader.streams.keys)
            if firstTimes.count >= 64, (allSeen && probed > 1 << 20) || probed > 6 << 20 { break }
        }
        guard !firstData.isEmpty else { throw ContainerError.unrecognizedFormat }
        origin = PESDemuxer.earliest(firstTimes) ?? 0

        var tracks: [ContainerTrack] = []
        // A stream seen only once is more likely a false start code in damaged data.
        let confirmed = order.filter { counts[$0, default: 0] > 1 || order.count == 1 }
        for key in confirmed.sorted() {
            guard var info = reader.streams[key], let data = firstData[key] else { continue }
            Self.refine(&info, sample: data)
            var track = ContainerTrack(id: key, kind: info.kind, codec: info.codec, codecID: info.codecID)
            track.language = info.language
            track.name = info.name
            track.needsFraming = info.kind == .audio && info.codecID != "LATM" && info.codecID != "Opus-TS"
            track.verifiesFrames = info.extractsCore
            if let setup = info.codecPrivate { track.codecPrivate = setup }
            track.sampleRate = info.sampleRate
            track.channels = info.channels
            Self.describe(&track, sample: data)
            tracks.append(track)
        }
        self.tracks = tracks
        let video = tracks.first { $0.kind == .video && $0.codec.isSupported } ?? tracks.first { $0.kind == .video }
        videoID = video?.id
        enabledTrackIDs = Set(tracks.map(\.id))

        // Duration: the latest timestamp near the end of the file.
        let tail = reader.size > Self.probeBytes / 4 ? reader.size - Self.probeBytes / 4 : 0
        try reader.reposition(to: tail)
        var latest: Double?
        while let pes = try reader.nextPES() {
            guard let pts = pes.pts, pes.stream == video?.id || video == nil else { continue }
            latest = max(latest ?? 0, Self.seconds(pts, from: origin))
        }
        let step = video?.frameDuration ?? 0
        duration = latest.map { $0 + step }
        try reader.reposition(to: 0)
        reader.wantedStreams = enabledTrackIDs
        resetAssembly()
    }

    /// Seconds from the file's origin, unwrapping the 33-bit clock (and tolerating
    /// timestamps slightly before the origin).
    private func seconds(_ ticks: Int64) -> Double {
        Self.seconds(ticks, from: origin)
    }

    private static func seconds(_ ticks: Int64, from origin: Int64) -> Double {
        var delta = (ticks - origin) & 0x1_FFFF_FFFF
        if delta > 0x1_0000_0000 { delta -= 0x2_0000_0000 }
        return Double(delta) / 90000
    }

    private static func earliest(_ times: [Int64]) -> Int64? {
        guard let first = times.first else { return nil }
        // Compare within the wrapped clock relative to the first timestamp.
        return times.min { a, b in
            func rel(_ t: Int64) -> Int64 { var d = (t - first) & 0x1_FFFF_FFFF; if d > 0x1_0000_0000 { d -= 0x2_0000_0000 }; return d }
            return rel(a) < rel(b)
        }
    }

    // MARK: Reading

    func nextPacket() throws -> MediaPacket? {
        while ready.isEmpty {
            guard !isAtEnd else { return nil }
            guard let pes = try reader.nextPES() else {
                isAtEnd = true
                ready += videoSplitter?.flush().map(videoPacket) ?? []
                ready += held.values.sorted { $0.pts < $1.pts }
                held = [:]
                break
            }
            route(pes)
        }
        return ready.isEmpty ? nil : ready.removeFirst()
    }

    private func route(_ pes: PESPacket) {
        guard enabledTrackIDs.contains(pes.stream), let track = tracks.first(where: { $0.id == pes.stream }) else { return }
        let info = reader.streams[pes.stream]
        var payload = Data(pes.payload.dropFirst(info?.payloadHeader ?? 0))
        if let bits = info?.dvdLPCMBits, let channels = info?.channels {
            payload = DVDLPCM.convert((lpcmCarry[pes.stream] ?? Data()) + payload, bits: bits, channels: channels,
                                      remainder: &lpcmCarry[pes.stream, default: Data()])
        }
        if track.id == videoID, track.kind == .video {
            if videoSplitter == nil { videoSplitter = AccessUnitSplitter(codec: track.codec, frameDuration: track.frameDuration) }
            let units = videoSplitter?.push(Data(payload), pts: pes.pts.map(seconds), dts: pes.dts.map(seconds), offset: pes.offset) ?? []
            ready += units.map(videoPacket)
            return
        }
        // Broadcast framings: split into codec packets here, timed from the PES timestamp.
        if track.codecID == "LATM" || track.codecID == "Opus-TS" {
            let frames: [(data: Data, duration: Double)]
            if track.codecID == "LATM" {
                var parser = latmParsers[pes.stream] ?? LATMParser()
                frames = parser.frames(in: payload).map { ($0, 1024 / (track.sampleRate ?? 48000)) }
                latmParsers[pes.stream] = parser
            } else {
                frames = OpusTS.packets(in: payload).map { ($0, Double(Opus.packetDuration($0) ?? 960) / 48000) }
            }
            var time = pes.pts.map(seconds) ?? nextAudioTime[pes.stream] ?? 0
            for frame in frames {
                ready.append(MediaPacket(trackID: pes.stream, pts: time, duration: frame.duration, isKeyframe: true, data: frame.data))
                time += frame.duration
            }
            nextAudioTime[pes.stream] = time
            return
        }
        // Audio and subtitles: a PES without a timestamp continues the previous one.
        guard let pts = pes.pts.map(seconds) else {
            // Untimed payloads beyond any real packet size are damage; drop them.
            if let count = held[pes.stream]?.data.count, count + payload.count <= Self.maxHeldBytes {
                held[pes.stream]?.data.append(payload)
            }
            return
        }
        if let previous = held[pes.stream] { ready.append(previous) }
        held[pes.stream] = MediaPacket(trackID: pes.stream, pts: pts, isKeyframe: true, data: Data(payload))
    }

    private func videoPacket(_ unit: AccessUnitSplitter.Unit) -> MediaPacket {
        MediaPacket(trackID: videoID ?? 0, pts: unit.pts, dts: unit.dts, duration: unit.duration, isKeyframe: unit.isKeyframe, data: unit.data)
    }

    private func resetAssembly() {
        videoSplitter = nil
        held = [:]
        lpcmCarry = [:]
        latmParsers = [:]
        nextAudioTime = [:]
        ready = []
        isAtEnd = false
    }

    // MARK: Seeking

    @discardableResult
    func seek(to target: Double) throws -> Double {
        resetAssembly()
        guard target > 0.5 else {
            try reader.reposition(to: 0)
            return 0
        }
        let reference = videoID ?? tracks.first(where: { $0.kind == .audio })?.id
        guard let reference else {
            try reader.reposition(to: 0)
            return 0
        }
        // Find a byte position a few seconds before the target, then the last keyframe at or before it.
        for lead in [3.0, 12.0, 40.0] {
            let position = try bisect(for: target - lead, stream: reference)
            if reference != videoID {
                try reader.reposition(to: position)
                return max(0, target - lead)
            }
            if let key = try lastKeyframe(from: position, before: target) {
                try reader.reposition(to: key.offset)
                resetAssembly()
                return key.time
            }
            if position == 0 { break }
        }
        try reader.reposition(to: 0)
        resetAssembly()
        return 0
    }

    /// The largest byte offset whose first timestamp on `stream` is before `time`.
    private func bisect(for time: Double, stream: Int) throws -> UInt64 {
        guard time > 0 else { return 0 }
        var low: UInt64 = 0
        var high = reader.size
        let saved = reader.wantedStreams
        reader.wantedStreams = [stream]
        defer {
            reader.wantedStreams = saved
            reader.readLimit = nil
        }
        while high - low > 512 << 10 {
            let middle = low + (high - low) / 2
            try reader.reposition(to: middle)
            // Each probe reads at most 4 MB, so a stream missing from part of the file can't
            // turn a probe into a scan to the end.
            reader.readLimit = middle + (4 << 20)
            var found: Double?
            while let pes = try reader.nextPES() {
                if pes.stream == stream, let pts = pes.pts { found = seconds(pts); break }
            }
            if let found, found < time { low = middle } else { high = middle }
        }
        return low
    }

    /// Scans forward from `offset` for video keyframes, returning the last one at or before `time`.
    private func lastKeyframe(from offset: UInt64, before time: Double) throws -> (offset: UInt64, time: Double)? {
        guard let videoID, let track = tracks.first(where: { $0.id == videoID }) else { return nil }
        try reader.reposition(to: offset)
        let saved = reader.wantedStreams
        reader.wantedStreams = [videoID]
        reader.readLimit = offset + (512 << 20) // Bounded even where the video stream is missing.
        defer {
            reader.wantedStreams = saved
            reader.readLimit = nil
        }
        var splitter = AccessUnitSplitter(codec: track.codec, frameDuration: track.frameDuration)
        var best: (offset: UInt64, time: Double)?
        var scanned: UInt64 = 0
        while let pes = try reader.nextPES() {
            guard pes.stream == videoID else { continue }
            scanned += UInt64(pes.payload.count)
            for unit in splitter.push(pes.payload, pts: pes.pts.map(seconds), dts: pes.dts.map(seconds), offset: pes.offset) {
                if unit.pts > time + 0.001 { return best }
                if unit.isKeyframe { best = (unit.offset, unit.pts) }
            }
            if scanned > 256 << 20 { break }
        }
        return best
    }

    // MARK: Stream identification

    /// Settles codecs that the stream tables leave ambiguous, from the data itself.
    private static func refine(_ info: inout ElementaryStreamInfo, sample: Data) {
        let b = [UInt8](sample.prefix(64 << 10))
        switch info.codec {
        case .mpeg2Video, .mpeg1Video:
            // Program streams don't say which video syntax they carry.
            if startCode(in: b, where: { $0 == 0xB3 }) == nil {
                if startCode(in: b, where: { $0 & 0x1F == 7 }) != nil { info.codec = .h264; info.codecID = "H.264" }
                else if startCode(in: b, where: { ($0 >> 1) & 0x3F == 33 }) != nil { info.codec = .hevc; info.codecID = "HEVC" }
            } else {
                // MPEG-2 sequences carry a sequence extension (00 00 01 B5, id 1).
                let isMPEG2 = startCodeOffsets(in: b).contains { at in b[at + 3] == 0xB5 && at + 4 < b.count && b[at + 4] >> 4 == 1 }
                info.codec = isMPEG2 ? .mpeg2Video : .mpeg1Video
                info.codecID = isMPEG2 ? "MPEG-2" : "MPEG-1"
            }
        case .pcm where info.payloadHeader == 4:
            // Blu-ray LPCM header: channel assignment, sampling rate, and sample size.
            guard b.count >= 4 else { break }
            let channels = [0, 1, 0, 2, 3, 3, 4, 4, 5, 6, 7, 8, 0, 0, 0, 0][Int(b[2] >> 4)]
            let bits = [0, 16, 24, 24][Int(b[3] >> 6)]
            let rates: [Int: Double] = [1: 48000, 4: 96000, 5: 192000]
            let rate = rates[Int(b[2] & 0x0F)] ?? 0
            guard channels > 0, bits > 0, rate > 0 else { info.codec = .unsupported("LPCM"); break }
            info.codec = .pcm(bits: bits, isFloat: false, isBigEndian: true)
            info.channels = (channels + 1) & ~1 // Stored with an even number of channels.
            info.sampleRate = rate
        case .mp2, .mp3:
            for i in 0..<max(0, b.count - 4) where b[i] == 0xFF && b[i + 1] & 0xE0 == 0xE0 {
                if b[i + 1] & 0xF6 == 0xF0 { // Layer bits 00: ADTS AAC in an MPEG audio stream.
                    info.codec = .aac
                    info.codecID = "ADTS"
                    break
                }
                guard AudioFramer.mpegFrameLength(b, at: i) != nil else { continue }
                info.codec = (b[i + 1] >> 1) & 0x03 == 1 ? .mp3 : .mp2
                break
            }
        default:
            break
        }
    }

    /// Fills in sampling, picture, and timing details from the first payloads.
    private static func describe(_ track: inout ContainerTrack, sample: Data) {
        let b = [UInt8](sample.prefix(512 << 10))
        switch track.codec {
        case .aac where track.codecID == "LATM":
            var parser = LATMParser()
            _ = parser.frames(in: Data(b))
            track.codecPrivate = parser.audioSpecificConfig
            track.sampleRate = parser.sampleRate
            track.channels = parser.channels
            if parser.audioSpecificConfig == nil { track.codec = .unsupported("AAC (LATM)") }
        case .aac:
            for i in 0..<max(0, b.count - 7) where b[i] == 0xFF && b[i + 1] & 0xF6 == 0xF0 {
                if let header = AAC.adtsHeader(Data(b[i...].prefix(9))) {
                    track.codecPrivate = header.config
                    track.sampleRate = header.sampleRate
                    track.channels = header.channels
                    break
                }
            }
        case .mp2, .mp3:
            for i in 0..<max(0, b.count - 4) where AudioFramer.mpegFrameLength(b, at: i) != nil {
                let version = (b[i + 1] >> 3) & 0x03
                let rate = [44100.0, 48000, 32000][Int((b[i + 2] >> 2) & 0x03)]
                track.sampleRate = version == 3 ? rate : rate / (version == 2 ? 2 : 4)
                track.channels = b[i + 3] >> 6 == 3 ? 1 : 2
                break
            }
        case .ac3, .eac3:
            for i in 0..<max(0, b.count - 8) where b[i] == 0x0B && b[i + 1] == 0x77 {
                if let info = AC3.info(b, at: i) {
                    track.codec = info.isEnhanced ? .eac3 : .ac3
                    track.sampleRate = info.sampleRate
                    track.channels = info.channels
                    break
                }
            }
        case .mpeg1Video, .mpeg2Video:
            if let size = MPEGVideo.dimensions(in: Data(b)) {
                track.width = size.width
                track.height = size.height
            }
            track.frameDuration = MPEGVideo.frameDuration(in: b)
        case .h264, .hevc:
            track.isAnnexB = true
            let data = Data(b)
            var format: CMFormatDescription?
            if track.codec == .h264, let sets = AnnexB.h264ParameterSets(in: data) {
                format = Self.parameterSetFormat([sets.sps, sets.pps], hevc: false)
            } else if track.codec == .hevc, let sets = AnnexB.hevcParameterSets(in: data) {
                format = Self.parameterSetFormat(sets, hevc: true)
            }
            if let format {
                let size = CMVideoFormatDescriptionGetPresentationDimensions(format, usePixelAspectRatio: false, useCleanAperture: true)
                track.width = Int(size.width)
                track.height = Int(size.height)
                let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
                if transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) { track.hdr = .hdr10 }
                if transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) { track.hdr = .hlg }
            }
        case .mpeg4Part2:
            track.isAnnexB = false
        default:
            break
        }
    }

    static func parameterSetFormat(_ sets: [Data], hevc: Bool) -> CMFormatDescription? {
        let arrays = sets.map { [UInt8]($0) }
        var format: CMFormatDescription?
        func create(_ pointers: [UnsafePointer<UInt8>]) -> OSStatus {
            let sizes = arrays.map(\.count)
            return hevc
                ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: pointers.count,
                                                                      parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                      nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
                : CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: pointers.count,
                                                                      parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                      nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        }
        // Keep every array alive while CoreMedia reads the pointers.
        func nest(_ index: Int, _ pointers: [UnsafePointer<UInt8>]) -> OSStatus {
            guard index < arrays.count else { return create(pointers) }
            return arrays[index].withUnsafeBufferPointer { nest(index + 1, pointers + [$0.baseAddress!]) }
        }
        return nest(0, []) == noErr ? format : nil
    }

    static func startCodeOffsets(in b: [UInt8]) -> [Int] {
        var offsets: [Int] = []
        var i = 0
        while i + 3 < b.count {
            if b[i + 2] > 1 { i += 3; continue }
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 { offsets.append(i); i += 3 } else { i += 1 }
        }
        return offsets
    }

    private static func startCode(in b: [UInt8], where match: (UInt8) -> Bool) -> Int? {
        startCodeOffsets(in: b).first { match(b[$0 + 3]) }
    }
}

// MARK: - Access units

/// Splits a video elementary stream (MPEG-1/2, MPEG-4 Part 2, H.264, HEVC) into access
/// units, and times each one from the PES timestamps that introduce it.
nonisolated struct AccessUnitSplitter {
    struct Unit {
        let data: Data
        let pts: Double
        let dts: Double
        let duration: Double
        let isKeyframe: Bool
        /// Offset of the PES in which this unit began.
        let offset: UInt64
    }

    private enum Syntax { case mpegVideo, mpeg4, h264, hevc }
    private struct Stamp { var at: Int; let pts: Double?; let dts: Double?; let offset: UInt64 }

    private let syntax: Syntax
    private var frameDuration: Double
    private let hasFixedRate: Bool
    private var buffer: [UInt8] = []
    /// Start of the unconsumed bytes in `buffer` (compacted once per push).
    private var head = 0
    private var scanned = 0
    /// Most unconsumed bytes held without completing a unit; beyond this the data is damage.
    private static let maxBufferedBytes = 16 << 20
    /// HEVC: whether the first random-access (IRAP) picture after (re)synchronizing was seen,
    /// and whether the RASL pictures associated with the latest IRAP picture (which reference
    /// pictures before it) are dropped.
    private var sawRandomAccess = false
    private var droppingRASL = false
    private var stamps: [Stamp] = []
    /// The stamp of the unit in progress, and whether its start was seen.
    private var current: Stamp?
    private var isSynchronized = false
    private var sawPicture = false
    private var lastDTS: Double?
    private var unitsSinceStamp = 0
    private var lastStampDTS: Double?
    /// MPEG-1/2: display time of temporal reference 0 in the current GOP.
    private var gopBase: Double?
    private var gopMaxReference = -1

    init(codec: MediaCodec, frameDuration: Double?) {
        syntax = switch codec {
        case .h264: .h264
        case .hevc: .hevc
        case .mpeg4Part2: .mpeg4
        default: .mpegVideo
        }
        self.frameDuration = frameDuration ?? 1.0 / 25
        hasFixedRate = frameDuration != nil
    }

    mutating func push(_ payload: Data, pts: Double?, dts: Double?, offset: UInt64) -> [Unit] {
        stamps.append(Stamp(at: buffer.count, pts: pts, dts: dts, offset: offset))
        buffer.append(contentsOf: payload)
        var units: [Unit] = []
        var i = scanned
        // Needs a few bytes past the start code to classify it.
        while i + 6 <= buffer.count {
            guard buffer[i] == 0, buffer[i + 1] == 0, buffer[i + 2] == 1 else {
                i += buffer[i + 2] > 1 ? 3 : 1
                continue
            }
            let role = classify(at: i)
            let startsUnit = role == .prefix || role == .firstSlice
            if !isSynchronized {
                // Data before the first unit start (after a seek) can't be decoded.
                if startsUnit {
                    head = i
                    isSynchronized = true
                    current = takeStamp(at: i)
                    sawPicture = role == .firstSlice
                    i += 3
                    continue
                }
            } else if startsUnit, sawPicture {
                if let unit = emit(upTo: i) { units.append(unit) }
                current = takeStamp(at: i)
                sawPicture = role == .firstSlice
                i += 3
                continue
            } else if role == .firstSlice || role == .slice {
                sawPicture = true
            }
            i += 3
        }
        scanned = i
        if !isSynchronized { head = max(head, min(i, buffer.count)) } // Undecodable lead-in.
        compact()
        if buffer.count > Self.maxBufferedBytes {
            // No unit boundary in far more data than any picture: start over at the next one.
            buffer = []
            stamps = []
            current = nil
            isSynchronized = false
            sawPicture = false
            sawRandomAccess = false // Pictures were lost: the next CRA starts decoding afresh.
            scanned = 0
        }
        return units
    }

    /// Drops consumed bytes, keeping stamps and the scan position relative to the buffer.
    private mutating func compact() {
        guard head > 0 else { return }
        buffer.removeFirst(head)
        shiftStamps(by: head)
        while stamps.count > 1, stamps[1].at == 0 { stamps.removeFirst() }
        scanned = max(0, scanned - head)
        head = 0
    }

    mutating func flush() -> [Unit] {
        guard isSynchronized, sawPicture, buffer.count > head, let unit = emit(upTo: buffer.count) else { return [] }
        compact()
        return [unit]
    }

    private enum Role { case prefix, firstSlice, slice, other }

    private func classify(at i: Int) -> Role {
        let code = buffer[i + 3]
        switch syntax {
        case .mpegVideo:
            switch code {
            case 0xB3, 0xB8: return .prefix       // sequence header, GOP
            case 0x00: return .firstSlice         // picture header
            case 0x01...0xAF: return .slice
            default: return .other
            }
        case .mpeg4:
            switch code {
            case 0xB0, 0xB3, 0x00...0x2F: return .prefix // VOS, GOV, VO/VOL
            case 0xB6: return .firstSlice                // VOP
            default: return .other
            }
        case .h264:
            switch code & 0x1F {
            case 6, 7, 8, 9, 14, 15, 16, 17, 18: return .prefix
            case 1, 5: return buffer[i + 4] & 0x80 != 0 ? .firstSlice : .slice // first_mb_in_slice == 0
            case 2, 3, 4: return .slice
            default: return .other
            }
        case .hevc:
            let type = (code >> 1) & 0x3F
            switch type {
            case 32, 33, 34, 35, 39, 41...44, 48...55: return .prefix
            case 0...31: return buffer[i + 5] & 0x80 != 0 ? .firstSlice : .slice // first_slice_segment_in_pic_flag
            default: return .other
            }
        }
    }

    /// Takes the timestamp that applies to a unit starting at `position`: the newest PES
    /// that began at or before it and hasn't been used yet.
    private mutating func takeStamp(at position: Int) -> Stamp? {
        while stamps.count > 1, stamps[1].at <= position { stamps.removeFirst() }
        guard let first = stamps.first, first.at <= position else { return nil }
        stamps.removeFirst()
        // Keep the PES offset available for later units in the same PES.
        if stamps.first.map({ $0.at > position }) ?? true {
            stamps.insert(Stamp(at: position, pts: nil, dts: nil, offset: first.offset), at: 0)
        }
        return first
    }

    private mutating func shiftStamps(by count: Int) {
        for index in stamps.indices { stamps[index].at = max(0, stamps[index].at - count) }
    }

    private mutating func emit(upTo end: Int) -> Unit? {
        let bytes = Array(buffer[head..<end])
        head = end
        let stamp = current
        let data = Data(bytes)
        let isKeyframe = Self.isKeyframe(bytes, syntax: syntax)

        // Timing: PES stamps when present; otherwise extrapolated from the frame rate.
        var dts: Double
        var pts: Double
        if let stampPTS = stamp?.pts {
            pts = stampPTS
            dts = stamp?.dts ?? stampPTS
            if !hasFixedRate, let previous = lastStampDTS, unitsSinceStamp > 0 {
                let estimate = (dts - previous) / Double(unitsSinceStamp)
                if estimate > 1.0 / 121, estimate < 0.2 { frameDuration = estimate }
            }
            lastStampDTS = dts
            unitsSinceStamp = 1
        } else {
            dts = (lastDTS ?? 0) + frameDuration
            pts = dts
            unitsSinceStamp += 1
        }
        if syntax == .mpegVideo, let reference = Self.temporalReference(bytes) {
            if bytes.indices.dropLast(3).contains(where: { bytes[$0] == 0 && bytes[$0 + 1] == 0 && bytes[$0 + 2] == 1 && bytes[$0 + 3] == 0xB8 }) {
                // A new GOP: its first display time follows the previous GOP's last picture.
                gopBase = gopBase.map { $0 + Double(gopMaxReference + 1) * frameDuration }
                gopMaxReference = -1
            }
            if stamp?.pts != nil { gopBase = pts - Double(reference) * frameDuration }
            else if let gopBase { pts = gopBase + Double(reference) * frameDuration }
            gopMaxReference = max(gopMaxReference, reference)
        }
        lastDTS = dts
        if syntax == .hevc, let type = Self.hevcPictureType(bytes) {
            // RASL pictures reference pictures before their associated IRAP picture (the latest
            // one in decode order). When decoding started at that picture (a CRA after a seek,
            // or mid-broadcast) or it's a BLA, those were never decoded: drop the RASL pictures
            // until the next IRAP picture, as the spec requires (H.265 8.1.3). RADL and other
            // leading pictures interleaved with them don't end the dropping.
            if (16...23).contains(type) {
                // BLA (16–18) always; a CRA (21) only when decoding starts at it; IDR has no RASL.
                droppingRASL = (16...18).contains(type) || (type == 21 && !sawRandomAccess)
                sawRandomAccess = true
            } else if sawRandomAccess, droppingRASL, type == 8 || type == 9 {
                return nil
            }
        }
        return Unit(data: data, pts: pts, dts: dts, duration: frameDuration, isKeyframe: isKeyframe, offset: stamp?.offset ?? 0)
    }

    /// NAL unit type of the first slice in an HEVC access unit.
    private static func hevcPictureType(_ b: [UInt8]) -> Int? {
        PESDemuxer.startCodeOffsets(in: b).lazy.map { Int((b[$0 + 3] >> 1) & 0x3F) }.first { $0 <= 31 }
    }

    private static func isKeyframe(_ b: [UInt8], syntax: Syntax) -> Bool {
        let codes = PESDemuxer.startCodeOffsets(in: b)
        switch syntax {
        case .mpegVideo:
            guard let picture = codes.first(where: { b[$0 + 3] == 0 }), picture + 5 < b.count else { return false }
            return (b[picture + 5] >> 3) & 0x07 == 1 // I picture
        case .mpeg4:
            guard let vop = codes.first(where: { b[$0 + 3] == 0xB6 }), vop + 4 < b.count else { return false }
            return b[vop + 4] >> 6 == 0
        case .h264:
            var hasSPS = false
            for at in codes where at + 4 < b.count {
                switch b[at + 3] & 0x1F {
                case 5: return true
                case 7: hasSPS = true
                case 1:
                    // Broadcast streams often use I slices with SPS/PPS instead of IDR pictures.
                    var bits = BitReader(b[(at + 4)...].prefix(16))
                    _ = bits.unsignedExpGolomb()
                    let type = (bits.unsignedExpGolomb() ?? 0) % 5
                    return hasSPS && (type == 2 || type == 4)
                default: break
                }
            }
            return false
        case .hevc:
            return codes.contains { at in (16...21).contains(Int((b[at + 3] >> 1) & 0x3F)) }
        }
    }

    private static func temporalReference(_ b: [UInt8]) -> Int? {
        guard let picture = PESDemuxer.startCodeOffsets(in: b).first(where: { b[$0 + 3] == 0 }), picture + 5 < b.count else { return nil }
        return Int(b[picture + 4]) << 2 | Int(b[picture + 5] >> 6)
    }
}

// MARK: - Bitstream details

nonisolated enum AC3 {
    /// CRC-16 (x^16 + x^15 + x^2 + 1) as used by AC-3; zero over an intact frame after its sync word.
    static func crc16<C: Collection>(_ bytes: C) -> UInt16 where C.Element == UInt8 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x8005 : crc << 1 }
        }
        return crc
    }

    /// Whether a complete AC-3 or E-AC-3 frame (starting at its sync word) is intact.
    static func isIntact<C: Collection>(_ frame: C) -> Bool where C.Element == UInt8 {
        frame.count > 4 && crc16(frame.dropFirst(2)) == 0
    }

    struct Info {
        let isEnhanced: Bool
        let sampleRate: Double
        let channels: Int
    }

    /// Sampling rate and channel count from an AC-3 or E-AC-3 sync frame.
    static func info(_ b: [UInt8], at i: Int) -> Info? {
        guard i + 7 < b.count, b[i] == 0x0B, b[i + 1] == 0x77 else { return nil }
        let bsid = b[i + 5] >> 3
        let channelCounts = [2, 1, 2, 3, 3, 4, 4, 5]
        if bsid > 10 {
            guard bsid <= 16 else { return nil }
            let fscod = Int(b[i + 4] >> 6)
            let rate = fscod == 3 ? [24000.0, 22050, 16000, 0][Int((b[i + 4] >> 4) & 0x03)] : [48000.0, 44100, 32000][fscod]
            let acmod = Int((b[i + 4] >> 1) & 0x07)
            return Info(isEnhanced: true, sampleRate: rate, channels: channelCounts[acmod] + Int(b[i + 4] & 1))
        }
        let fscod = Int(b[i + 4] >> 6)
        guard fscod < 3 else { return nil }
        var bits = BitReader(rawBytes: Array(b[(i + 6)...].prefix(2)))
        let acmod = bits.read(3) ?? 2
        if acmod & 1 != 0, acmod != 1 { _ = bits.read(2) } // cmixlev
        if acmod & 4 != 0 { _ = bits.read(2) }              // surmixlev
        if acmod == 2 { _ = bits.read(2) }                  // dsurmod
        let lfe = bits.read(1) ?? 0
        return Info(isEnhanced: false, sampleRate: [48000.0, 44100, 32000][fscod], channels: channelCounts[acmod] + lfe)
    }
}

/// DVD LPCM at 20 and 24 bits stores samples in groups of two frames: the top 16 bits of
/// every sample first, then the remaining bits. Converts groups to plain 24-bit big-endian.
nonisolated enum DVDLPCM {
    static func convert(_ data: Data, bits: Int, channels: Int, remainder: inout Data) -> Data {
        let groupSize = bits == 24 ? 6 * channels : 5 * channels
        let groups = data.count / groupSize
        let b = [UInt8](data)
        var out = [UInt8]()
        out.reserveCapacity(groups * 6 * channels)
        for group in 0..<groups {
            let base = group * groupSize
            let lows = base + 4 * channels
            for sample in 0..<(2 * channels) {
                let high0 = b[base + sample * 2]
                let high1 = b[base + sample * 2 + 1]
                let low: UInt8
                if bits == 24 {
                    low = b[lows + sample]
                } else {
                    let packed = b[lows + sample / 2]
                    low = sample % 2 == 0 ? packed & 0xF0 : packed << 4
                }
                out += [high0, high1, low]
            }
        }
        remainder = data.suffix(data.count - groups * groupSize)
        return Data(out)
    }
}

nonisolated extension MPEGVideo {
    /// Frame duration from a sequence header's frame_rate_code.
    static func frameDuration(in b: [UInt8]) -> Double? {
        guard let at = PESDemuxer.startCodeOffsets(in: b).first(where: { b[$0 + 3] == 0xB3 }), at + 7 < b.count else { return nil }
        let rates = [0, 24000.0 / 1001, 24, 25, 30000.0 / 1001, 30, 50, 60000.0 / 1001, 60]
        let code = Int(b[at + 7] & 0x0F)
        return code > 0 && code < rates.count ? 1 / rates[code] : nil
    }
}
