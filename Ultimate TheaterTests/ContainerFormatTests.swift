//
//  ContainerFormatTests.swift
//  Ultimate TheaterTests
//
//  Round trips for the MPEG transport/program stream and FLV readers: the shared
//  H.264 + AAC fixture is written by small test-only muxers that follow each spec,
//  read back by the app's demuxers, and decoded by the system decoders.
//

import Testing
import Foundation
import CoreMedia
@testable import Ultimate_Theater

// MARK: - Test muxers

nonisolated enum TestMPEGWriter {
    private static func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

    /// Streams start 10 s in, like broadcast captures, to exercise the time origin.
    private static func ticks(_ seconds: Double) -> Int64 { Int64((seconds * 90000).rounded()) + 900_000 }

    private static func stamp(_ prefix: UInt8, _ t: Int64) -> [UInt8] {
        [prefix << 4 | UInt8((t >> 29) & 0x0E) | 1, UInt8((t >> 22) & 0xFF), UInt8((t >> 14) & 0xFE) | 1,
         UInt8((t >> 7) & 0xFF), UInt8((t << 1) & 0xFE) | 1]
    }

    private static func pes(id: UInt8, pts: Int64, dts: Int64? = nil, payload: [UInt8], bounded: Bool) -> [UInt8] {
        var header: [UInt8] = dts == nil ? [0x80, 0x80, 5] + stamp(2, pts) : [0x80, 0xC0, 10] + stamp(3, pts)
        if let dts { header += stamp(1, dts) }
        let length = header.count + payload.count
        return [0, 0, 1, id] + be16(bounded && length <= 65535 ? length : 0) + header + payload
    }

    static func annexB(_ media: EncodedMedia, _ frame: EncodedMedia.VideoFrame) -> [UInt8] {
        var out: [UInt8] = [0, 0, 0, 1, 0x09, 0xF0] // Access unit delimiter
        if frame.isKeyframe { out += [0, 0, 0, 1] + media.sps + [0, 0, 0, 1] + media.pps }
        let b = [UInt8](frame.data)
        var i = 0
        while i + 4 <= b.count {
            let n = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
            out += [0, 0, 1] + b[(i + 4)..<min(b.count, i + 4 + n)]
            i += 4 + n
        }
        return out
    }

    static func adts(_ media: EncodedMedia, _ frame: Data) -> [UInt8] {
        let config = [UInt8](media.audioSpecificConfig)
        let rateIndex = Int((config[0] & 7) << 1 | config[1] >> 7)
        let length = frame.count + 7
        return [0xFF, 0xF1, UInt8(1 << 6 | rateIndex << 2 | media.channels >> 2),
                UInt8((media.channels & 3) << 6 | length >> 11), UInt8((length >> 3) & 0xFF), UInt8((length & 7) << 5 | 0x1F), 0xFC]
            + [UInt8](frame)
    }

    /// Decode times for the fixture's frames (stored in decode order with B-frame reordering):
    /// the sorted display times, shifted so no frame decodes after it displays.
    static func decodeTimes(_ media: EncodedMedia) -> [Double] {
        let sorted = media.video.map(\.pts).sorted()
        let delay = zip(sorted, media.video).map { $0 - $1.pts }.max() ?? 0
        return sorted.map { $0 - max(0, delay) }
    }

    /// Video access units (decode order) and groups of three AAC frames, interleaved by decode time.
    private static func units(_ media: EncodedMedia) -> [(isVideo: Bool, time: Double, pts: Double, dts: Double?, bytes: [UInt8])] {
        var list = zip(media.video, decodeTimes(media)).map { (true, $1, $0.pts, Optional($1), annexB(media, $0)) }
        let step = 1024 / media.sampleRate
        for start in stride(from: 0, to: media.aac.count, by: 3) {
            let group = media.aac[start..<min(media.aac.count, start + 3)]
            let time = Double(start) * step
            list.append((false, time, time, nil, group.flatMap { adts(media, $0) }))
        }
        return list.enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map(\.element)
    }

    static func writeTransportStream(_ media: EncodedMedia, packetSize: Int = 188) throws -> URL {
        var out = Data()
        var counters: [Int: UInt8] = [:]
        func packets(pid: Int, _ payload: [UInt8]) {
            var at = 0
            while at < payload.count {
                let chunk = payload[at..<min(payload.count, at + 184)]
                var packet: [UInt8] = [0x47, UInt8((at == 0 ? 0x40 : 0) | pid >> 8), UInt8(pid & 0xFF)]
                let counter = counters[pid, default: 0]
                counters[pid] = (counter + 1) & 0x0F
                if chunk.count < 184 { // Pad the last packet with an adaptation field.
                    let stuffing = 184 - chunk.count
                    packet += [0x30 | counter, UInt8(stuffing - 1)]
                    if stuffing > 1 { packet += [0x00] + [UInt8](repeating: 0xFF, count: stuffing - 2) }
                } else {
                    packet.append(0x10 | counter)
                }
                if packetSize == 192 { out.append(contentsOf: [0, 0, 0, 0]) }
                out.append(contentsOf: packet + chunk)
                at += chunk.count
            }
        }
        let pat: [UInt8] = [0, 0x00, 0xB0, 13, 0, 1, 0xC1, 0, 0, 0, 1, 0xF0, 0, 0, 0, 0, 0]
        let language: [UInt8] = [0x0A, 4] + Array("fra".utf8) + [0]
        let streams: [UInt8] = [0x1B, 0xE1, 0x00, 0xF0, 0x00, 0x0F, 0xE1, 0x01, 0xF0, UInt8(language.count)] + language
        var pmt: [UInt8] = [0x02, 0, 0, 0, 1, 0xC1, 0, 0, 0xE1, 0x00, 0xF0, 0x00] + streams + [0, 0, 0, 0]
        pmt[1] = 0xB0 | UInt8((pmt.count - 3) >> 8)
        pmt[2] = UInt8((pmt.count - 3) & 0xFF)
        for (index, unit) in units(media).enumerated() {
            if index % 50 == 0 { packets(pid: 0, pat); packets(pid: 0x1000, [0] + pmt) }
            packets(pid: unit.isVideo ? 0x100 : 0x101,
                    pes(id: unit.isVideo ? 0xE0 : 0xC0, pts: ticks(unit.pts), dts: unit.dts.map(ticks), payload: unit.bytes,
                        bounded: !unit.isVideo))
        }
        let url = Fixtures.temporaryURL(packetSize == 192 ? "m2ts" : "ts")
        try out.write(to: url)
        return url
    }

    /// A DVD-style program stream: units are split into PES packets of at most 2 KB, and
    /// only the first piece of each unit carries a timestamp.
    static func writeProgramStream(_ media: EncodedMedia) throws -> URL {
        var out: [UInt8] = []
        let pack: [UInt8] = [0, 0, 1, 0xBA, 0x44, 0, 0x04, 0, 0x04, 0x01, 0x01, 0x89, 0xC3, 0xF8]
        let map: [UInt8] = [0x80, 0x01, 0, 0, 0, 8, 0x1B, 0xE0, 0, 0, 0x0F, 0xC0, 0, 0, 0, 0, 0, 0]
        out += pack + [0, 0, 1, 0xBC] + be16(map.count) + map
        for unit in units(media) {
            let id: UInt8 = unit.isVideo ? 0xE0 : 0xC0
            var at = 0
            while at < unit.bytes.count {
                let chunk = Array(unit.bytes[at..<min(unit.bytes.count, at + 2016)])
                out += pack
                out += at == 0 ? pes(id: id, pts: ticks(unit.pts), dts: unit.dts.map(ticks), payload: chunk, bounded: true)
                               : [0, 0, 1, id] + be16(3 + chunk.count) + [0x80, 0, 0] + chunk
                at += chunk.count
            }
        }
        out += [0, 0, 1, 0xB9]
        let url = Fixtures.temporaryURL("mpg")
        try Data(out).write(to: url)
        return url
    }
}

nonisolated enum TestFLVWriter {
    static func write(_ media: EncodedMedia) throws -> URL {
        var out: [UInt8] = Array("FLV".utf8) + [1, 5, 0, 0, 0, 9, 0, 0, 0, 0]
        func be24(_ v: Int) -> [UInt8] { [UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func tag(_ type: UInt8, _ seconds: Double, _ body: [UInt8]) {
            let ms = Int((seconds * 1000).rounded())
            let header: [UInt8] = [type] + be24(body.count) + be24(ms & 0xFF_FFFF) + [UInt8(ms >> 24 & 0xFF), 0, 0, 0]
            out += header + body
            let size = header.count + body.count
            out += [UInt8(size >> 24), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)]
        }
        tag(9, 0, [0x17, 0, 0, 0, 0] + media.avcC)
        tag(8, 0, [0xAF, 0] + media.audioSpecificConfig)
        // Video tags carry decode times, with the display offset in the composition time field.
        var events: [(Double, UInt8, [UInt8])] = zip(media.video, TestMPEGWriter.decodeTimes(media)).map { frame, dts in
            (dts, 9, [frame.isKeyframe ? 0x17 : 0x27, 1] + be24(Int(((frame.pts - dts) * 1000).rounded())) + frame.data)
        }
        events += media.aac.enumerated().map { (Double($0.offset) * 1024 / media.sampleRate, 8, [0xAF, 1] + $0.element) }
        for event in events.enumerated().sorted(by: { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }) {
            tag(event.element.1, event.element.0, event.element.2)
        }
        let url = Fixtures.temporaryURL("flv")
        try Data(out).write(to: url)
        return url
    }
}

// MARK: - Tests

@Suite(.serialized)
struct ContainerFormatTests {
    /// Reads every packet, checks video timing and keyframes against the source, and
    /// decodes everything with the system decoders.
    private func verifyRoundTrip(_ url: URL, media: EncodedMedia, reader: (any MediaDemuxer) -> Bool) throws -> any MediaDemuxer {
        let demuxer = try Demuxers.open(url)
        #expect(reader(demuxer))
        let video = try #require(demuxer.tracks.first { $0.kind == .video })
        let audio = try #require(demuxer.tracks.first { $0.kind == .audio })
        #expect(video.codec == .h264 && video.width == media.width && video.height == media.height)
        #expect(audio.codec == .aac && audio.sampleRate == media.sampleRate && audio.channels == media.channels)

        var packets: [MediaPacket] = []
        while let packet = try demuxer.nextPacket() { packets.append(packet) }
        let videoPackets = packets.filter { $0.trackID == video.id }
        #expect(videoPackets.count == media.video.count)
        #expect(videoPackets.map(\.isKeyframe) == media.video.map(\.isKeyframe))
        #expect(zip(videoPackets, media.video).allSatisfy { abs($0.pts - $1.pts) < 0.0015 })

        let videoFormatter = try TrackFormatter(track: video)
        let videoSamples = try videoPackets.flatMap(videoFormatter.sampleBuffers)
        #expect(DecodeCheck.decodedFrames(videoSamples, format: try #require(videoFormatter.format)) == media.video.count)

        let audioFormatter = try TrackFormatter(track: audio)
        let audioSamples = try packets.filter { $0.trackID == audio.id }.flatMap(audioFormatter.sampleBuffers)
        #expect(audioSamples.count == media.aac.count)
        #expect(DecodeCheck.decodedAudioFrames(audioSamples, format: try #require(audioFormatter.format)) > 0)
        return demuxer
    }

    @Test func transportStreamRoundTrip() async throws {
        let media = try await Fixtures.encode()
        let url = try TestMPEGWriter.writeTransportStream(media)
        defer { try? FileManager.default.removeItem(at: url) }
        let demuxer = try verifyRoundTrip(url, media: media) { $0 is PESDemuxer }
        #expect(demuxer.tracks.first { $0.kind == .audio }?.language == "fra")
        #expect(abs((demuxer.duration ?? 0) - 1.5) < 0.05)
        let landed = try demuxer.seek(to: 0.8)
        #expect(abs(landed - 0.5) < 0.002) // Keyframes every 15 frames.
        #expect(try demuxer.nextPacket().map { $0.isKeyframe || $0.trackID != 0x100 } == true)
    }

    @Test func blurayTransportStreamRoundTrip() async throws {
        let media = try await Fixtures.encode()
        let url = try TestMPEGWriter.writeTransportStream(media, packetSize: 192)
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try verifyRoundTrip(url, media: media) { $0 is PESDemuxer }
    }

    @Test func programStreamRoundTripReassemblesSplitUnits() async throws {
        let media = try await Fixtures.encode()
        let url = try TestMPEGWriter.writeProgramStream(media)
        defer { try? FileManager.default.removeItem(at: url) }
        let demuxer = try verifyRoundTrip(url, media: media) { $0 is PESDemuxer }
        let landed = try demuxer.seek(to: 1.2)
        #expect(abs(landed - 1.0) < 0.002)
    }

    @Test func flvRoundTrip() async throws {
        let media = try await Fixtures.encode()
        let url = try TestFLVWriter.write(media)
        defer { try? FileManager.default.removeItem(at: url) }
        let demuxer = try verifyRoundTrip(url, media: media) { $0 is FLVDemuxer }
        let landed = try demuxer.seek(to: 0.8)
        #expect(abs(landed - 0.5) < 0.002)
    }

    @Test func accessUnitSplitterFindsH264Boundaries() {
        var splitter = AccessUnitSplitter(codec: .h264, frameDuration: 1.0 / 25)
        let aud: [UInt8] = [0, 0, 0, 1, 0x09, 0xF0]
        let idr: [UInt8] = [0, 0, 1, 0x67, 0x42, 0, 0, 1, 0x68, 0xCE, 0, 0, 1, 0x65, 0x88, 0x84]
        let p: [UInt8] = [0, 0, 1, 0x41, 0x9A, 0x22]
        // Units split across payloads, and a payload holding two units.
        var units = splitter.push(Data(aud + idr.prefix(9)), pts: 1, dts: 1, offset: 0)
        units += splitter.push(Data(idr.dropFirst(9) + aud + p), pts: 1.04, dts: 1.04, offset: 100)
        units += splitter.push(Data(aud + p + aud + p), pts: 1.08, dts: 1.08, offset: 200)
        units += splitter.flush()
        #expect(units.count == 4)
        #expect(units.map(\.isKeyframe) == [true, false, false, false])
        #expect(zip(units.map(\.pts), [1, 1.04, 1.08, 1.12]).allSatisfy { abs($0 - $1) < 1e-9 })
        #expect(units.map(\.offset) == [0, 100, 200, 200])
    }

    @Test func bitstreamHeaders() {
        // Opus TOC: config 3 (SILK 60 ms) code 0, and CELT 20 ms with a 3-frame code-3 packet.
        #expect(Opus.packetDuration(Data([3 << 3])) == 2880)
        #expect(Opus.packetDuration(Data([31 << 3 | 3, 3])) == 2880)
        // AC-3 at 48 kHz, 3/2 + LFE (acmod 7): fscod 0, bsid 8.
        let ac3: [UInt8] = [0x0B, 0x77, 0, 0, 0x00 | 0x1E, 8 << 3, 0xE0 | 0x01, 0x40]
        let info = AC3.info(ac3, at: 0)
        #expect(info?.sampleRate == 48000 && info?.channels == 6 && info?.isEnhanced == false)
        // Xiph lacing round trip.
        let packets = [Data(repeating: 1, count: 300), Data([2, 3]), Data(repeating: 4, count: 10)]
        #expect(VorbisParser.unlace(VorbisParser.lace(packets)) == packets)
    }
}
