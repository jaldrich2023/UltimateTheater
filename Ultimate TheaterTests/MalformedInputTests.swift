//
//  MalformedInputTests.swift
//  Ultimate TheaterTests
//
//  Hand-built damaged files (impossible sizes, zero timescales, lost sync, oversized
//  bitmaps, cut-off headers): each must fail gracefully or play its valid parts.
//

import Testing
import Foundation
import CoreGraphics
@testable import Ultimate_Theater

struct MalformedInputTests {
    // MARK: Helpers

    private func temporaryFile(_ bytes: [UInt8], ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "malformed-\(UUID().uuidString).\(ext)")
        try Data(bytes).write(to: url)
        return url
    }

    /// Reads packets until the end, an error, or `limit` packets.
    private func drain(_ demuxer: any MediaDemuxer, limit: Int = 1000) -> [MediaPacket] {
        drainReportingError(demuxer, limit: limit).packets
    }

    /// Like `drain`, but tells a clean end of file (nil error) from reading that stopped on
    /// an error, for files whose damage must be skipped rather than end playback.
    private func drainReportingError(_ demuxer: any MediaDemuxer, limit: Int = 1000) -> (packets: [MediaPacket], error: (any Error)?) {
        var packets: [MediaPacket] = []
        while packets.count < limit {
            do {
                guard let packet = try demuxer.nextPacket() else { return (packets, nil) }
                packets.append(packet)
            } catch {
                return (packets, error)
            }
        }
        return (packets, nil)
    }

    private func zeros(_ count: Int) -> [UInt8] { [UInt8](repeating: 0, count: count) }
    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }

    private func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    private func be64(_ v: UInt64) -> [UInt8] { be32(UInt32(v >> 32)) + be32(UInt32(v & 0xFFFF_FFFF)) }

    // MARK: MP4

    private func box(_ type: String, _ body: [UInt8]) -> [UInt8] {
        be32(UInt32(body.count + 8)) + Array(type.utf8) + body
    }

    /// A box whose 64-bit size claims nearly the whole address space.
    private func hugeBox(_ type: String) -> [UInt8] {
        be32(1) + Array(type.utf8) + be64(UInt64.max - 15) + [1, 2, 3, 4]
    }

    /// One 16-bit stereo PCM track with a single 16-frame chunk (64 bytes) in 'mdat'.
    private func movie(mvhdTimescale: UInt32 = 1000, elst: [UInt8]? = nil, stcoCount: UInt32 = 1,
                       extraMoov: [UInt8] = [], trailing: [UInt8] = []) -> [UInt8] {
        let ftyp = box("ftyp", Array("isom".utf8) + be32(0) + Array("isom".utf8))
        let mdat = box("mdat", [UInt8](repeating: 0x11, count: 64))
        let dataOffset = UInt32(ftyp.count + 8)
        let mvhd = box("mvhd", be32(0) + be32(0) + be32(0) + be32(mvhdTimescale) + be32(1000) + [UInt8](repeating: 0, count: 80))
        let tkhd = box("tkhd", be32(1) + be32(0) + be32(0) + be32(1) + [UInt8](repeating: 0, count: 68))
        let mdhd = box("mdhd", be32(0) + be32(0) + be32(0) + be32(44100) + be32(16) + [0x55, 0xC4, 0, 0])
        let hdlr = box("hdlr", be32(0) + be32(0) + Array("soun".utf8) + [UInt8](repeating: 0, count: 13))
        var sowt = [UInt8](repeating: 0, count: 28)
        sowt[17] = 2            // channels
        sowt[19] = 16           // bits
        sowt[24] = 0xAC         // 44100 Hz (16.16)
        sowt[25] = 0x44
        let stsd = box("stsd", be32(0) + be32(1) + box("sowt", sowt))
        let stts = box("stts", be32(0) + be32(1) + be32(16) + be32(1))
        let stsc = box("stsc", be32(0) + be32(1) + be32(1) + be32(16) + be32(1))
        let stsz = box("stsz", be32(0) + be32(1) + be32(16)) // Size 1: implied by the format.
        let stco = box("stco", be32(0) + be32(stcoCount) + be32(dataOffset))
        let stbl = box("stbl", stsd + stts + stsc + stsz + stco)
        let minf = box("minf", box("smhd", be32(0) + be32(0)) + stbl)
        let mdia = box("mdia", mdhd + hdlr + minf)
        let edts = elst.map { box("edts", box("elst", $0)) } ?? []
        let trak = box("trak", tkhd + edts + mdia)
        let moov = box("moov", mvhd + trak + extraMoov)
        return ftyp + mdat + moov + trailing
    }

    @Test func mp4WithZeroMovieTimescaleAndEmptyEdit() throws {
        // An empty edit (media time −1) is measured in the movie timescale, which is zero here.
        let elst = be32(0) + be32(2)
            + be32(1000) + be32(0xFFFF_FFFF) + be32(0x0001_0000)
            + be32(1000) + be32(0) + be32(0x0001_0000)
        let url = try temporaryFile(movie(mvhdTimescale: 0, elst: elst), ext: "mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let demuxer = try Demuxers.open(url)
        #expect(demuxer.tracks.count == 1)
        let packets = drain(demuxer)
        #expect(packets.count == 1 && packets.first?.data.count == 64)
        #expect(packets.allSatisfy { $0.pts.isFinite })
    }

    @Test func mp4WithImpossibleChunkOffsetCount() throws {
        // 'stco' claims four billion entries but holds one.
        let url = try temporaryFile(movie(stcoCount: 0xFFFF_FFFF), ext: "mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let demuxer = try Demuxers.open(url)
        let result = drainReportingError(demuxer)
        #expect(result.packets.count == 1)
        #expect(result.error == nil)
    }

    /// A fragment whose track run lists four billion samples using only the defaults.
    private func movieWithDefaultOnlyRun(defaultSize: UInt32) -> [UInt8] {
        let trex = box("trex", be32(0) + be32(1) + be32(1) + be32(0) + be32(0) + be32(0))
        let tfhd = box("tfhd", be32(0x10) + be32(1) + be32(defaultSize)) // default-sample-size present
        let trun = box("trun", be32(0) + be32(0xFFFF_FFFF))
        let moof = box("moof", box("mfhd", be32(0) + be32(1)) + box("traf", tfhd + trun))
        return movie(extraMoov: box("mvex", trex), trailing: moof)
    }

    @Test func mp4FragmentRunOfZeroSizeSamplesIsSkipped() throws {
        let url = try temporaryFile(movieWithDefaultOnlyRun(defaultSize: 0), ext: "mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = drainReportingError(try Demuxers.open(url), limit: 10_000)
        #expect(result.packets.count == 1) // Only the movie's own sample.
        #expect(result.error == nil)
    }

    @Test func mp4FragmentRunIsLimitedToTheBytesLeft() throws {
        let bytes = movieWithDefaultOnlyRun(defaultSize: 1)
        let url = try temporaryFile(bytes, ext: "mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let packets = drain(try Demuxers.open(url), limit: 100_000)
        #expect(packets.count <= bytes.count + 1)
    }

    /// Two AC-3 tracks of ten 4-byte, half-second samples: alternating in the file, or all of
    /// track 1 before all of track 2.
    private func twoTrackMovie(interleaved: Bool) -> [UInt8] {
        let ftyp = box("ftyp", Array("isom".utf8) + be32(0) + Array("isom".utf8))
        let base = UInt32(ftyp.count + 8)
        let order: [(track: Int, index: Int)] = interleaved
            ? (0..<10).flatMap { [(0, $0), (1, $0)] }
            : (0..<2).flatMap { track in (0..<10).map { (track, $0) } }
        var offsets: [[UInt32]] = [[], []]
        for (position, item) in order.enumerated() { offsets[item.track].append(base + UInt32(position * 4)) }
        let mdat = box("mdat", order.flatMap { [UInt8(0x10 + $0.track), UInt8($0.index), 0, 0] })
        func trak(_ id: UInt32) -> [UInt8] {
            let tkhd = box("tkhd", be32(1) + be32(0) + be32(0) + be32(id) + zeros(68))
            let mdhd = box("mdhd", be32(0) + be32(0) + be32(0) + be32(1000) + be32(5000) + [0x55, 0xC4, 0, 0])
            let hdlr = box("hdlr", be32(0) + be32(0) + Array("soun".utf8) + zeros(13))
            var entry = zeros(28)
            entry[17] = 2            // channels
            entry[19] = 16           // bits
            entry[24] = 0xBB         // 48000 Hz (16.16)
            entry[25] = 0x80
            let stsd = box("stsd", be32(0) + be32(1) + box("ac-3", entry))
            let stts = box("stts", be32(0) + be32(1) + be32(10) + be32(500))
            let stsc = box("stsc", be32(0) + be32(1) + be32(1) + be32(1) + be32(1))
            let stsz = box("stsz", be32(0) + be32(4) + be32(10))
            let stco = box("stco", be32(0) + be32(10) + offsets[Int(id) - 1].flatMap(be32))
            let stbl = box("stbl", stsd + stts + stsc + stsz + stco)
            let minf = box("minf", box("smhd", be32(0) + be32(0)) + stbl)
            return box("trak", tkhd + box("mdia", mdhd + hdlr + minf))
        }
        let mvhd = box("mvhd", be32(0) + be32(0) + be32(0) + be32(1000) + be32(5000) + zeros(80))
        return ftyp + mdat + box("moov", mvhd + trak(1) + trak(2))
    }

    @Test func mp4InterleavedTracksReadInFileOrder() throws {
        let url = try temporaryFile(twoTrackMovie(interleaved: true), ext: "mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let packets = drain(try Demuxers.open(url))
        #expect(packets.map(\.trackID) == (0..<10).flatMap { _ in [1, 2] })
    }

    @Test func mp4TrackStoredApartIsReadWhenItFallsBehind() throws {
        let url = try temporaryFile(twoTrackMovie(interleaved: false), ext: "mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let packets = drain(try Demuxers.open(url))
        #expect(packets.count == 20)
        // File order until track 2 is more than 1.5 s behind, then track 2 catches up.
        #expect(packets.prefix(4).allSatisfy { $0.trackID == 1 })
        #expect(packets[4].trackID == 2)
        // Neither track ever runs more than two seconds ahead of the other.
        var latest: [Int: Double] = [:]
        for packet in packets {
            latest[packet.trackID] = packet.pts
            if let one = latest[1], let two = latest[2] { #expect(abs(one - two) <= 2) }
        }
    }

    @Test func mp4SampleTablesWithHugeCountsForRepair() {
        // A uniform size and chunk tables claiming four billion entries, in a 1,000-byte file.
        let stsz = box("stsz", be32(0) + be32(1) + be32(0xFFFF_FFFF))
        let stsc = box("stsc", be32(0) + be32(1) + be32(1) + be32(0xFFFF_FFFF) + be32(1))
        let stco = box("stco", be32(0) + be32(0xFFFF_FFFF) + be32(0xFFFF_FFF0))
        let stts = box("stts", be32(0) + be32(0xFFFF_FFFF) + be32(0xFFFF_FFFF) + be32(0xFFFF_FFFF))
        let ctts = box("ctts", be32(0) + be32(0xFFFF_FFFF))
        let stss = box("stss", be32(0) + be32(0xFFFF_FFFF) + [0, 0])
        let tables = MP4Fixer.tables(fromSampleTable: Data(stsz + stsc + stco + stts + ctts + stss), fileSize: 1000)
        #expect(tables != nil)
        #expect((tables?.samples.count ?? .max) <= 1000)
        #expect(tables?.durations.count == 1)
        #expect(tables?.compositionOffsets?.isEmpty == true)
        #expect(tables?.syncSamples?.isEmpty == true)
        // Offsets near the top of the range don't overflow when checked against the file.
        #expect(tables?.keptCount(fileSize: 1000) == 0)
    }

    @Test func mp4WithSixtyFourBitSizesNearTheMaximum() throws {
        // One inside 'moov' (after the track) and one at the top level after it.
        let url = try temporaryFile(movie(extraMoov: hugeBox("udta"), trailing: hugeBox("free")), ext: "mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let demuxer = try Demuxers.open(url)
        #expect(demuxer.tracks.count == 1)
        #expect(drain(demuxer).count == 1)
    }

    // MARK: Matroska

    /// An EBML element with an 8-byte size.
    private func element(_ id: [UInt8], _ body: [UInt8]) -> [UInt8] {
        id + [0x01] + Array(be64(UInt64(body.count)).dropFirst()) + body
    }

    @Test func matroskaWithZeroTimecodeScaleAndHugeSeekPositions() throws {
        let header = element([0x1A, 0x45, 0xDF, 0xA3], element([0x42, 0x82], Array("matroska".utf8)))
        // The SeekHead points the (absent) Chapters element far past the end of the file.
        let seek = element([0x4D, 0xBB], element([0x53, 0xAB], [0x10, 0x43, 0xA7, 0x70])
                                     + element([0x53, 0xAC], [UInt8](repeating: 0xFF, count: 8)))
        let seekHead = element([0x11, 0x4D, 0x9B, 0x74], seek)
        let info = element([0x15, 0x49, 0xA9, 0x66], element([0x2A, 0xD7, 0xB1], [0])
                                                     + element([0x44, 0x89], [0x44, 0x7A, 0, 0])) // 1000.0
        let entry = element([0xAE], element([0xD7], [1]) + element([0x83], [2]) + element([0x86], Array("A_AC3".utf8)))
        let tracks = element([0x16, 0x54, 0xAE, 0x6B], entry)
        let cuePoint = element([0xBB], element([0xB3], [0])
                                   + element([0xB7], element([0xF7], [1]) + element([0xF1], [UInt8](repeating: 0xFF, count: 8))))
        let cues = element([0x1C, 0x53, 0xBB, 0x6B], cuePoint)
        let block = element([0xA3], [0x81, 0x00, 0x00, 0x80, 0x0B, 0x77, 1, 2, 3, 4])
        let cluster = element([0x1F, 0x43, 0xB6, 0x75], element([0xE7], [0]) + block)
        let segment = element([0x18, 0x53, 0x80, 0x67], seekHead + info + tracks + cues + cluster)
        let url = try temporaryFile(header + segment, ext: "mkv")
        defer { try? FileManager.default.removeItem(at: url) }

        let demuxer = try Demuxers.open(url)
        #expect(demuxer.tracks.count == 1)
        #expect(demuxer.duration == 1) // 1000 ticks at the default 1 ms scale.
        for target in [0.5, 1e300, .infinity, .nan, -5] {
            _ = try? demuxer.seek(to: target)
        }
        _ = try demuxer.seek(to: 0)
        let packets = drain(demuxer)
        #expect(packets.count == 1 && packets.first?.pts == 0)
    }

    /// A Matroska file with one A_AC3 track (number 1) and one cluster holding `blocks`.
    private func matroska(info: [UInt8] = [], blocks: [[UInt8]]) -> [UInt8] {
        let header = element([0x1A, 0x45, 0xDF, 0xA3], element([0x42, 0x82], Array("matroska".utf8)))
        let entry = element([0xAE], element([0xD7], [1]) + element([0x83], [2]) + element([0x86], Array("A_AC3".utf8)))
        let tracks = element([0x16, 0x54, 0xAE, 0x6B], entry)
        let infoElement = info.isEmpty ? [] : element([0x15, 0x49, 0xA9, 0x66], info)
        let cluster = element([0x1F, 0x43, 0xB6, 0x75], element([0xE7], [0]) + blocks.flatMap { element([0xA3], $0) })
        return header + element([0x18, 0x53, 0x80, 0x67], infoElement + tracks + cluster)
    }

    @Test func matroskaBadlyLacedBlockIsSkippedNotTheEnd() throws {
        // Xiph lacing whose lace sizes run past the block, then a good block at 10 ms.
        let bad: [UInt8] = [0x81, 0x00, 0x00, 0x82, 0x02, 0xFF, 0xFF]
        let good: [UInt8] = [0x81, 0x00, 0x0A, 0x80, 0x0B, 0x77, 1, 2, 3, 4]
        let url = try temporaryFile(matroska(blocks: [bad, good]), ext: "mkv")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = drainReportingError(try Demuxers.open(url))
        #expect(result.error == nil)
        #expect(result.packets.count == 1)
        #expect(abs((result.packets.first?.pts ?? 0) - 0.01) < 1e-9)
    }

    @Test func matroskaNonFiniteOrAbsurdDurationIsUnknown() throws {
        for value in [Double.nan, .infinity, 1e300, -5] {
            let info = element([0x44, 0x89], be64(value.bitPattern))
            let url = try temporaryFile(matroska(info: info, blocks: [[0x81, 0x00, 0x00, 0x80, 0x0B, 0x77]]), ext: "mkv")
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(try Demuxers.open(url).duration == nil)
        }
    }

    // MARK: FLV

    private func flvTag(_ type: UInt8, _ body: [UInt8]) -> [UInt8] {
        let size = UInt32(body.count)
        return [type, UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF), 0, 0, 0, 0, 0, 0, 0] + body + be32(size + 11)
    }

    private func amfNumber(_ key: String, _ value: Double) -> [UInt8] {
        [0, UInt8(key.utf8.count)] + Array(key.utf8) + [0x00] + be64(value.bitPattern)
    }

    @Test func flvWithNonFiniteMetadataNumbers() throws {
        let script = [0x02, 0x00, 0x0A] + Array("onMetaData".utf8) + [0x08] + be32(4)
            + amfNumber("width", .nan) + amfNumber("height", 1e300) + amfNumber("duration", .infinity)
            + amfNumber("framerate", .infinity) + [0, 0, 9]
        let video: [UInt8] = [0x17, 0x01, 0, 0, 0, 0, 0, 0, 1, 0x65, 0x88]
        let bytes = Array("FLV".utf8) + [1, 0x01] + be32(9) + be32(0) + flvTag(18, script) + flvTag(9, video)
        let url = try temporaryFile(bytes, ext: "flv")
        defer { try? FileManager.default.removeItem(at: url) }
        let demuxer = try Demuxers.open(url)
        let track = try #require(demuxer.tracks.first)
        #expect(track.width == nil)
        #expect(track.height == nil)
        #expect(demuxer.duration == 0) // From the tags, since the metadata's is infinite.
        #expect(drain(demuxer).count == 1)
    }

    // MARK: AVI

    private func riffChunk(_ id: String, _ body: [UInt8]) -> [UInt8] {
        Array(id.utf8) + le32(UInt32(body.count)) + body + (body.count % 2 == 1 ? [0] : [])
    }

    private func riffList(_ type: String, _ body: [UInt8]) -> [UInt8] {
        riffChunk("LIST", Array(type.utf8) + body)
    }

    /// An OpenDML AVI whose super index lists the same ix00 chunk `repeats` times.
    private func aviWithRepeatedIndex(repeats: Int) -> [UInt8] {
        var strh = zeros(56)
        strh.replaceSubrange(0..<4, with: Array("vids".utf8))
        strh.replaceSubrange(4..<8, with: Array("MJPG".utf8))
        strh.replaceSubrange(20..<24, with: le32(1))     // scale
        strh.replaceSubrange(24..<28, with: le32(25))    // rate
        strh.replaceSubrange(32..<36, with: le32(1))     // length
        var strf = zeros(40)
        strf.replaceSubrange(0..<4, with: le32(40))
        strf.replaceSubrange(4..<8, with: le32(16))
        strf.replaceSubrange(8..<12, with: le32(16))
        strf.replaceSubrange(16..<20, with: Array("MJPG".utf8))
        func hdrl(ixOffset: UInt32) -> [UInt8] {
            var indx = le16(4) + [0, 0] + le32(UInt32(repeats)) + Array("00dc".utf8) + zeros(12)
            for _ in 0..<repeats { indx += le32(ixOffset) + le32(0) + le32(32) + le32(1) }
            return riffList("hdrl", riffList("strl", riffChunk("strh", strh) + riffChunk("strf", strf) + riffChunk("indx", indx)))
        }
        let headerLength = 12 + hdrl(ixOffset: 0).count
        let dataChunk = UInt32(headerLength + 12)       // After LIST, size, 'movi'.
        let ixOffset = dataChunk + 16                   // After the 8-byte data chunk.
        let ix00 = le16(2) + [0, 1] + le32(1) + Array("00dc".utf8) + le32(0) + le32(0) + le32(0)
            + le32(dataChunk + 8) + le32(8)
        let movi = riffList("movi", riffChunk("00dc", [0xFF, 0xD8, 1, 2, 3, 4, 0xFF, 0xD9]) + riffChunk("ix00", ix00))
        let body = Array("AVI ".utf8) + hdrl(ixOffset: ixOffset) + movi
        return Array("RIFF".utf8) + le32(UInt32(body.count)) + body
    }

    @Test func aviSuperIndexListingOneChunkRepeatedlyReadsItOnce() throws {
        let url = try temporaryFile(aviWithRepeatedIndex(repeats: 500), ext: "avi")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = drainReportingError(try Demuxers.open(url))
        #expect(result.error == nil)
        #expect(result.packets.count == 1)
    }

    // MARK: M2TS

    /// A 192-byte M2TS packet: a 4-byte timecode prefix, then a 188-byte TS packet.
    private func m2tsPacket(pid: Int, unitStart: Bool, counter: Int, payload: [UInt8]) -> [UInt8] {
        let header: [UInt8] = [0x47, UInt8(unitStart ? 0x40 : 0) | UInt8(pid >> 8), UInt8(pid & 0xFF), 0x10 | UInt8(counter & 0x0F)]
        let body = Array((payload + [UInt8](repeating: 0xFF, count: 184)).prefix(184))
        return [0, 0, 0, 0] + header + body
    }

    private func pts(_ t: Int64) -> [UInt8] {
        [0x21 | UInt8((t >> 29) & 0x0E), UInt8((t >> 22) & 0xFF), UInt8((t >> 14) & 0xFE) | 1, UInt8((t >> 7) & 0xFF), UInt8((t << 1) & 0xFE) | 1]
    }

    @Test func m2tsWithTwoMissingBytesResynchronizes() throws {
        let pat: [UInt8] = [0x00, 0x00, 0xB0, 13, 0x00, 0x01, 0xC1, 0, 0, 0x00, 0x01, 0xE1, 0x00, 0, 0, 0, 0]
        let pmt: [UInt8] = [0x00, 0x02, 0xB0, 18, 0x00, 0x01, 0xC1, 0, 0, 0xE1, 0x01, 0xF0, 0x00,
                            0x0F, 0xE1, 0x01, 0xF0, 0x00, 0, 0, 0, 0]
        var bytes = m2tsPacket(pid: 0, unitStart: true, counter: 0, payload: pat)
            + m2tsPacket(pid: 0x100, unitStart: true, counter: 0, payload: pmt)
        for index in 0..<38 {
            let pes: [UInt8] = [0, 0, 1, 0xC0, 0, 178, 0x80, 0x80, 0x05] + pts(Int64(index) * 1920)
                + [UInt8](repeating: 0, count: 170)
            bytes += m2tsPacket(pid: 0x101, unitStart: true, counter: index, payload: pes)
        }
        // Drop two bytes from the middle of packet 20: the next packet starts two bytes early,
        // so its sync byte sits before the expected 4-byte prefix offset.
        bytes.removeSubrange((20 * 192 + 100)..<(20 * 192 + 102))
        let url = try temporaryFile(bytes, ext: "m2ts")
        defer { try? FileManager.default.removeItem(at: url) }

        let demuxer = try Demuxers.open(url)
        #expect(demuxer.tracks.count == 1)
        _ = drain(demuxer) // Must not trap.
        _ = try? demuxer.seek(to: 0.3)
        _ = drain(demuxer)
    }

    // MARK: PGS

    private func segment(_ type: UInt8, _ body: [UInt8]) -> [UInt8] {
        [type, UInt8(body.count >> 8), UInt8(body.count & 0xFF)] + body
    }

    @Test func pgsObjectOfImpossibleSizeIsIgnored() {
        let composition = segment(0x16, [0x07, 0x80, 0x04, 0x38, 0x10, 0, 1, 0x80, 0, 0, 1,
                                         0, 0, 0, 0, 0, 100, 0x03, 0x84])
        let palette = segment(0x14, [0, 0, 1, 235, 128, 128, 255])
        let rle: [UInt8] = [1, 1, 0, 0]
        let object = segment(0x15, [0, 0, 0, 0xC0, 0, 0, UInt8(rle.count + 4), 0xFF, 0xFF, 0xFF, 0xFF] + rle) // 65535×65535
        let events = PGSDecoder().decode(Data(composition + palette + object + segment(0x80, [])), pts: 1)
        guard case .clear(let time)? = events.first else {
            Issue.record("Expected the display set to clear, not show a bitmap")
            return
        }
        #expect(time == 1)
    }

    @Test func pgsCompositionWithZeroPlaneKeepsThePreviousPlane() {
        // Width and height 0 in the composition; the object still lands at finite fractions.
        let composition = segment(0x16, [0, 0, 0, 0, 0x10, 0, 1, 0x80, 0, 0, 1,
                                         0, 0, 0, 0, 0, 100, 0x03, 0x84])
        let palette = segment(0x14, [0, 0, 1, 235, 128, 128, 255])
        let rle: [UInt8] = [1, 1, 0, 0, 1, 1, 0, 0]
        let object = segment(0x15, [0, 0, 0, 0xC0, 0, 0, UInt8(rle.count + 4), 0, 2, 0, 2] + rle)
        let events = PGSDecoder().decode(Data(composition + palette + object + segment(0x80, [])), pts: 2)
        guard case .show(_, _, let bitmaps)? = events.first, let frame = bitmaps.first?.frame else {
            Issue.record("Expected a bitmap")
            return
        }
        #expect(frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite)
    }

    // MARK: Movie repair

    @Test func movieRepairRejectsATruncatedBoxHeader() throws {
        // A 64-bit box size whose header is cut off after 12 bytes.
        let url = try temporaryFile(be32(1) + Array("mdat".utf8) + [0, 0, 0, 0], ext: "mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) { try RepairReference(url: url) }
        #expect(throws: (any Error).self) { try MovieRepairer(damaged: url) }
    }
}
