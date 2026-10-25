//
//  FLVDemuxer.swift
//  Ultimate Theater
//
//  Flash Video (FLV) and Enhanced RTMP FLV: H.264, HEVC, AV1, and VP9 video; AAC, MP3,
//  PCM, G.711, Opus, FLAC, AC-3, and E-AC-3 audio. Tags are indexed when the file opens,
//  which gives exact keyframe seeking and duration.
//

import Foundation
import CoreMedia

nonisolated final class FLVDemuxer: MediaDemuxer {
    let tracks: [ContainerTrack]
    let duration: Double?
    let chapters: [ContainerChapter] = []
    var enabledTrackIDs: Set<Int>

    private struct Tag {
        let offset: UInt64
        let type: UInt8
        let size: Int
        let time: Double
        let isKeyframe: Bool
    }

    private static let videoID = 1
    private static let audioID = 2

    private let source: FileByteSource
    private let tags: [Tag]
    private var cursor = 0

    static func matches(_ head: Data) -> Bool {
        head.count >= 9 && head.prefix(3) == Data("FLV".utf8)
    }

    init(source: FileByteSource) throws {
        self.source = source
        let header = [UInt8](try source.read(at: 0, count: 9))
        guard header.count == 9 else { throw ContainerError.truncated }
        var offset = UInt64(UInt32(header[5]) << 24 | UInt32(header[6]) << 16 | UInt32(header[7]) << 8 | UInt32(header[8])) + 4

        // Index every tag: type, size, timestamp, and the keyframe flag.
        var tags: [Tag] = []
        var video: ContainerTrack?
        var audio: ContainerTrack?
        var metadata: [String: Double] = [:]
        while offset + 11 <= source.size {
            let h = [UInt8](try source.read(at: offset, count: 16))
            guard h.count >= 12 else { break }
            let type = h[0] & 0x1F
            let size = Int(h[1]) << 16 | Int(h[2]) << 8 | Int(h[3])
            let milliseconds = Int32(bitPattern: UInt32(h[7]) << 24 | UInt32(h[4]) << 16 | UInt32(h[5]) << 8 | UInt32(h[6]))
            guard offset + 11 + UInt64(size) <= source.size, [8, 9, 18].contains(type) else {
                // A damaged tag: pick up at the next plausible tag header.
                guard let next = try Self.nextTag(in: source, from: offset + 1) else { break }
                offset = next
                continue
            }
            let body = offset + 11
            switch type {
            case 9:
                let flags = h[11]
                let isExtended = flags & 0x80 != 0
                let frameType = isExtended ? (flags >> 4) & 0x07 : flags >> 4
                tags.append(Tag(offset: body, type: 9, size: size, time: Double(milliseconds) / 1000, isKeyframe: frameType == 1))
                if video == nil || video?.codecPrivate == nil, size > 0 {
                    if let found = Self.videoTrack(try source.read(at: body, count: min(size, 1 << 16))) {
                        if video == nil || found.codecPrivate != nil { video = found }
                    }
                }
            case 8:
                tags.append(Tag(offset: body, type: 8, size: size, time: Double(milliseconds) / 1000, isKeyframe: true))
                if audio == nil || (audio?.codecPrivate == nil && [.aac, .opus, .flac].contains(audio?.codec)), size > 0 {
                    if let found = Self.audioTrack(try source.read(at: body, count: min(size, 1 << 16))) {
                        if audio == nil || found.codecPrivate != nil { audio = found }
                    }
                }
            default:
                if metadata.isEmpty { metadata = Self.metadata(try source.read(at: body, count: min(size, 1 << 16))) }
            }
            offset = body + UInt64(size) + 4
        }
        if var track = video {
            // Metadata numbers are doubles; NaN, infinite, or absurd values are ignored.
            track.width = track.width ?? metadata["width"].flatMap(FormatValidation.dimension)
            track.height = track.height ?? metadata["height"].flatMap(FormatValidation.dimension)
            if let rate = metadata["framerate"], rate > 0, rate.isFinite { track.frameDuration = 1 / rate }
            video = track
        }
        self.tags = tags
        tracks = [video, audio].compactMap { $0 }
        guard !tracks.isEmpty else { throw ContainerError.unrecognizedFormat }
        enabledTrackIDs = Set(tracks.map(\.id))
        let last = tags.map(\.time).max()
        duration = FormatValidation.duration(metadata["duration"]).flatMap { $0 > 0 ? $0 : nil } ?? last
    }

    /// Finds the next plausible tag header at or after `start`: a known type, a zero stream ID,
    /// and a matching PreviousTagSize after its body. Scans at most 32 MB.
    private static func nextTag(in source: FileByteSource, from start: UInt64) throws -> UInt64? {
        var position = start
        let limit = min(source.size, start + (32 << 20))
        while position + 15 <= limit {
            let window = [UInt8](try source.read(at: position, count: Int(min(1 << 20, limit - position))))
            guard window.count >= 15 else { return nil }
            for i in 0...(window.count - 15) where window[i] & 0xC0 == 0 && [8, 9, 18].contains(window[i] & 0x1F)
                && window[i + 8] == 0 && window[i + 9] == 0 && window[i + 10] == 0 {
                let size = UInt64(window[i + 1]) << 16 | UInt64(window[i + 2]) << 8 | UInt64(window[i + 3])
                let candidate = position + UInt64(i)
                guard candidate + 15 + size <= source.size else { continue }
                let trailer = [UInt8](try source.read(at: candidate + 11 + size, count: 4))
                guard trailer.count == 4 else { continue }
                let previous = UInt64(trailer[0]) << 24 | UInt64(trailer[1]) << 16 | UInt64(trailer[2]) << 8 | UInt64(trailer[3])
                if previous == size + 11 { return candidate }
            }
            position += UInt64(window.count - 14)
        }
        return nil
    }

    // MARK: Reading

    func nextPacket() throws -> MediaPacket? {
        while cursor < tags.count {
            let tag = tags[cursor]
            cursor += 1
            let id = tag.type == 9 ? Self.videoID : Self.audioID
            guard enabledTrackIDs.contains(id), tag.size > 0,
                  let track = tracks.first(where: { $0.id == id }), track.codec.isSupported else { continue }
            let data = try source.read(at: tag.offset, count: tag.size)
            if let packet = tag.type == 9 ? Self.videoPacket(data, tag: tag) : Self.audioPacket(data, tag: tag, codec: track.codec) {
                return packet
            }
        }
        return nil
    }

    @discardableResult
    func seek(to target: Double) throws -> Double {
        let hasVideo = tracks.contains { $0.id == Self.videoID }
        let candidates = tags.indices.filter { hasVideo ? tags[$0].type == 9 && tags[$0].isKeyframe : tags[$0].type == 8 }
        guard let index = candidates.last(where: { tags[$0].time <= target + 0.001 }) ?? candidates.first else {
            cursor = 0
            return 0
        }
        cursor = index
        // Video timestamps are decode times; the landing time is the keyframe's display time.
        let tag = tags[index]
        guard tag.type == 9, let packet = Self.videoPacket(try source.read(at: tag.offset, count: min(tag.size, 16)), tag: tag) else {
            return tag.time
        }
        return packet.pts
    }

    // MARK: Tags

    private static func videoPacket(_ d: Data, tag: Tag) -> MediaPacket? {
        let b = [UInt8](d.prefix(8))
        guard let flags = b.first else { return nil }
        var composition = 0
        var start: Int
        if flags & 0x80 != 0 { // Enhanced RTMP
            guard b.count >= 5 else { return nil }
            let packetType = flags & 0x0F
            let fourCC = String(decoding: b[1...4], as: UTF8.self)
            switch packetType {
            case 1 where fourCC == "avc1" || fourCC == "hvc1":
                guard b.count >= 8 else { return nil }
                composition = signed24(b, 5)
                start = 8
            case 1, 3:
                start = 5
            default:
                return nil // Sequence start/end, metadata, multitrack.
            }
        } else {
            let codec = flags & 0x0F
            guard codec == 7 || codec == 12, b.count >= 5, b[1] == 1 else { return nil } // NALU packets only.
            composition = signed24(b, 2)
            start = 5
        }
        guard d.count > start else { return nil }
        let isKeyframe = ((flags & 0x80 != 0) ? (flags >> 4) & 0x07 : flags >> 4) == 1
        return MediaPacket(trackID: videoID, pts: tag.time + Double(composition) / 1000, dts: tag.time,
                           isKeyframe: isKeyframe, data: d.dropFirst(start))
    }

    private static func audioPacket(_ d: Data, tag: Tag, codec: MediaCodec) -> MediaPacket? {
        guard let flags = d.first else { return nil }
        let format = flags >> 4
        let start: Int
        if format == 9 { // Enhanced RTMP ExHeader
            guard flags & 0x0F == 1, d.count > 5 else { return nil } // Coded frames only.
            start = 5
        } else if format == 10 {
            guard d.count > 2, d[d.startIndex + 1] == 1 else { return nil } // Raw AAC only.
            start = 2
        } else {
            start = 1
        }
        guard d.count > start else { return nil }
        return MediaPacket(trackID: audioID, pts: tag.time, isKeyframe: true, data: d.dropFirst(start))
    }

    private static func videoTrack(_ d: Data) -> ContainerTrack? {
        let b = [UInt8](d)
        guard let flags = b.first else { return nil }
        var track: ContainerTrack
        if flags & 0x80 != 0 {
            guard b.count >= 5 else { return nil }
            let fourCC = String(decoding: b[1...4], as: UTF8.self)
            let codec: MediaCodec = switch fourCC {
            case "avc1": .h264
            case "hvc1": .hevc
            case "av01": .av1
            case "vp09": .vp9
            default: .unsupported(fourCC.trimmingCharacters(in: .whitespaces).uppercased())
            }
            track = ContainerTrack(id: videoID, kind: .video, codec: codec, codecID: fourCC)
            if flags & 0x0F == 0, b.count > 5 { // Sequence start: the codec configuration record.
                // VP9 carries the bare configuration record; decoders take the vpcC payload with its version and flags.
                track.codecPrivate = codec == .vp9 ? Data([1, 0, 0, 0]) + Data(b[5...]) : Data(b[5...])
            }
        } else {
            let id = flags & 0x0F
            let codec: MediaCodec = switch id {
            case 7: .h264
            case 12: .hevc
            case 2: .unsupported("Sorenson Spark")
            case 3, 6: .unsupported("Screen Video")
            case 4, 5: .unsupported("On2 VP6")
            default: .unsupported("FLV video \(id)")
            }
            track = ContainerTrack(id: videoID, kind: .video, codec: codec, codecID: "FLV \(id)")
            if id == 7 || id == 12, b.count > 5, b[1] == 0 { track.codecPrivate = Data(b[5...]) }
        }
        if let config = track.codecPrivate, let size = configurationSize(config, codec: track.codec) {
            track.width = size.width
            track.height = size.height
        }
        return track
    }

    private static func audioTrack(_ d: Data) -> ContainerTrack? {
        let b = [UInt8](d)
        guard let flags = b.first else { return nil }
        let format = flags >> 4
        var track: ContainerTrack
        if format == 9 {
            guard b.count >= 5 else { return nil }
            let fourCC = String(decoding: b[1...4], as: UTF8.self)
            let codec: MediaCodec = switch fourCC {
            case "mp4a": .aac
            case "Opus": .opus
            case "fLaC": .flac
            case "ac-3": .ac3
            case "ec-3": .eac3
            case ".mp3": .mp3
            default: .unsupported(fourCC)
            }
            track = ContainerTrack(id: audioID, kind: .audio, codec: codec, codecID: fourCC)
            if flags & 0x0F == 0, b.count > 5 { track.codecPrivate = Data(b[5...]) }
            track.needsFraming = codec == .mp3
        } else {
            let rates = [5512.5, 11025, 22050, 44100]
            let bits = flags & 0x02 != 0 ? 16 : 8
            let codec: MediaCodec = switch format {
            case 0, 3: .pcm(bits: bits, isFloat: false, isBigEndian: false)
            case 2, 14: .mp3
            case 7: .aLaw
            case 8: .muLaw
            case 10: .aac
            case 1: .unsupported("Flash ADPCM")
            case 4, 5, 6: .unsupported("Nellymoser")
            case 11: .unsupported("Speex")
            default: .unsupported("FLV audio \(format)")
            }
            track = ContainerTrack(id: audioID, kind: .audio, codec: codec, codecID: "FLV \(format)")
            track.sampleRate = format == 14 ? 8000 : (format == 7 || format == 8 ? 8000 : rates[Int((flags >> 2) & 0x03)])
            track.channels = flags & 0x01 != 0 ? 2 : 1
            track.bitDepth = bits
            track.needsFraming = codec == .mp3
            if format == 10, b.count > 2, b[1] == 0 { track.codecPrivate = Data(b[2...]) }
        }
        // Channel and rate details from the configuration, where there is one.
        if let config = track.codecPrivate {
            switch track.codec {
            case .aac:
                let c = [UInt8](config.prefix(2))
                if c.count == 2 { track.channels = Int((c[1] >> 3) & 0x0F) }
                track.sampleRate = AAC.coreSampleRate(fromConfig: config)
            case .opus:
                let c = [UInt8](config.prefix(10))
                if c.count >= 10 { track.channels = Int(c[9]) }
                track.sampleRate = 48000
            case .flac:
                if let info = FLAC.streamInfo(in: config) {
                    track.sampleRate = info.sampleRate
                    track.channels = info.channels
                }
            default:
                break
            }
        }
        return track
    }

    private static func signed24(_ b: [UInt8], _ i: Int) -> Int {
        let value = Int(b[i]) << 16 | Int(b[i + 1]) << 8 | Int(b[i + 2])
        return value & 0x80_0000 != 0 ? value - 0x100_0000 : value
    }

    /// Picture size from an avcC or hvcC record.
    private static func configurationSize(_ config: Data, codec: MediaCodec) -> (width: Int, height: Int)? {
        let b = [UInt8](config)
        var sets: [Data] = []
        if codec == .h264, b.count > 6 {
            var i = 6
            var spsCount = Int(b[5] & 0x1F)
            var lists = 0
            while lists < 2, i + 2 <= b.count {
                for _ in 0..<spsCount {
                    guard i + 2 <= b.count else { break }
                    let length = Int(b[i]) << 8 | Int(b[i + 1])
                    guard i + 2 + length <= b.count else { break }
                    sets.append(Data(b[(i + 2)..<(i + 2 + length)]))
                    i += 2 + length
                }
                lists += 1
                guard i < b.count else { break }
                spsCount = Int(b[i])
                i += 1
            }
        } else if codec == .hevc, b.count > 23 {
            var i = 23
            for _ in 0..<Int(b[22]) {
                guard i + 3 <= b.count else { break }
                let count = Int(b[i + 1]) << 8 | Int(b[i + 2])
                i += 3
                for _ in 0..<count {
                    guard i + 2 <= b.count else { break }
                    let length = Int(b[i]) << 8 | Int(b[i + 1])
                    guard i + 2 + length <= b.count else { break }
                    sets.append(Data(b[(i + 2)..<(i + 2 + length)]))
                    i += 2 + length
                }
            }
        }
        guard !sets.isEmpty, let format = PESDemuxer.parameterSetFormat(sets, hevc: codec == .hevc) else { return nil }
        let size = CMVideoFormatDescriptionGetPresentationDimensions(format, usePixelAspectRatio: false, useCleanAperture: true)
        return (Int(size.width), Int(size.height))
    }

    /// Numeric fields of the onMetaData script tag (AMF0).
    private static func metadata(_ d: Data) -> [String: Double] {
        let b = [UInt8](d)
        var values: [String: Double] = [:]
        // Find the ECMA array (0x08) or object (0x03) that follows the "onMetaData" string.
        guard let marker = b.indices.first(where: { b[$0...].starts(with: Array("onMetaData".utf8)) }) else { return [:] }
        var i = marker + 10
        guard i < b.count else { return [:] }
        if b[i] == 0x08 { i += 5 } else if b[i] == 0x03 { i += 1 } else { return [:] }
        while i + 3 <= b.count {
            let length = Int(b[i]) << 8 | Int(b[i + 1])
            i += 2
            guard length > 0, i + length < b.count else { break }
            let key = String(decoding: b[i..<(i + length)], as: UTF8.self)
            i += length
            let type = b[i]
            i += 1
            switch type {
            case 0x00: // Number
                guard i + 8 <= b.count else { return values }
                values[key] = Double(bitPattern: b[i..<(i + 8)].reduce(0) { $0 << 8 | UInt64($1) })
                i += 8
            case 0x01: i += 1                                                     // Boolean
            case 0x02:                                                           // String
                guard i + 2 <= b.count else { return values }
                i += 2 + (Int(b[i]) << 8 | Int(b[i + 1]))
            default:
                return values // Nested values: the numbers we need come first in practice.
            }
        }
        return values
    }
}
