//
//  MediaRepairTests.swift
//  Ultimate TheaterTests
//
//  Each container is damaged the way real files get damaged (cut off, missing index,
//  garbage in the stream), diagnosed, repaired, and read back with the app's demuxers.
//

import Testing
import Foundation
import AVFoundation
@testable import Ultimate_Theater

@Suite(.serialized)
struct MediaRepairTests {
    private func truncate(_ url: URL, to fraction: Double) throws -> URL {
        let data = try Data(contentsOf: url)
        let cut = Fixtures.temporaryURL(url.pathExtension)
        try data.prefix(Int(Double(data.count) * fraction)).write(to: cut)
        return cut
    }

    private func repair(_ url: URL) throws -> (plan: RepairPlan, output: URL, notes: [String]) {
        let plan = try #require(try MediaRepair.diagnose(url))
        let output = Fixtures.temporaryURL(plan.fileExtension)
        let notes = try MediaRepair.repair(plan, source: url, to: output) { _ in }
        return (plan, output, notes)
    }

    private func readAll(_ url: URL) throws -> [MediaPacket] {
        let demuxer = try Demuxers.open(url)
        var packets: [MediaPacket] = []
        while let packet = try demuxer.nextPacket() { packets.append(packet) }
        return packets
    }

    @Test func cutOffMP4WithIndexIsTrimmed() async throws {
        let original = try await MovieFixture.write(.mp4, seconds: 4, fastStart: true)
        let damaged = try truncate(original, to: 0.6)
        defer { [original, damaged].forEach { try? FileManager.default.removeItem(at: $0) } }

        let (plan, output, _) = try repair(damaged)
        defer { try? FileManager.default.removeItem(at: output) }
        guard case .mp4Truncated = plan.kind else { Issue.record("Expected a cut-off MP4, got \(plan.kind)"); return }
        #expect(try MediaRepair.diagnose(output) == nil) // Nothing left to fix.

        let before = try Demuxers.open(original)
        let after = try readAll(output)
        let videoBefore = try readAll(original).filter { $0.trackID == before.tracks.first { $0.kind == .video }?.id }
        let videoAfter = after.filter { $0.trackID == before.tracks.first { $0.kind == .video }?.id }
        #expect(!videoAfter.isEmpty && videoAfter.count < videoBefore.count)
        #expect(zip(videoAfter, videoBefore).allSatisfy { $0.data == $1.data })
        #expect(try await AVURLAsset(url: output).load(.isPlayable))
    }

    @Test func cutOffMatroskaGetsCuesAndDuration() async throws {
        let media = try await Fixtures.encode()
        let original = try TestMKVWriter.write(media)
        let damaged = try truncate(original, to: 0.7)
        defer { [original, damaged].forEach { try? FileManager.default.removeItem(at: $0) } }

        let (_, output, notes) = try repair(damaged)
        defer { try? FileManager.default.removeItem(at: output) }
        #expect(!notes.isEmpty)
        #expect(try MediaRepair.diagnose(output) == nil)
        let demuxer = try Demuxers.open(output)
        #expect((demuxer.duration ?? 0) > 0.5)
        let packets = try readAll(output)
        let video = try #require(demuxer.tracks.first { $0.kind == .video })
        let frames = packets.filter { $0.trackID == video.id }
        #expect(frames.count > 10 && frames.count <= media.video.count)
        let formatter = try TrackFormatter(track: video)
        let samples = try frames.flatMap(formatter.sampleBuffers)
        #expect(DecodeCheck.decodedFrames(samples, format: try #require(formatter.format)) == frames.count)
        // The new Cues make seeking land at or before the target, on a keyframe.
        let landed = try demuxer.seek(to: 0.7)
        #expect(landed <= 0.7)
        var first: MediaPacket?
        while let packet = try demuxer.nextPacket() { if packet.trackID == video.id { first = packet; break } }
        #expect(first?.isKeyframe == true)
    }

    @Test func aviWithoutIndexGetsANewOne() async throws {
        let media = try await Fixtures.encode()
        let original = try TestAVIWriter.write(media)
        defer { try? FileManager.default.removeItem(at: original) }
        // Remove the idx1 chunk (and fix the RIFF size), as many broken tools leave files.
        var data = try Data(contentsOf: original)
        let index = try #require(data.range(of: Data("idx1".utf8)))
        data = data.prefix(index.lowerBound - data.startIndex)
        data.replaceSubrange(4..<8, with: withUnsafeBytes(of: UInt32(data.count - 8).littleEndian) { Data($0) })
        let damaged = Fixtures.temporaryURL("avi")
        try data.write(to: damaged)
        defer { try? FileManager.default.removeItem(at: damaged) }

        let (plan, output, _) = try repair(damaged)
        defer { try? FileManager.default.removeItem(at: output) }
        #expect(plan.findings.contains { $0.contains("index") })
        #expect(try MediaRepair.diagnose(output) == nil)
        #expect(try Data(contentsOf: output).range(of: Data("idx1".utf8)) != nil)
        let video = try readAll(output).filter { $0.trackID == 0 }
        #expect(video.count == media.video.count)
    }

    @Test func damagedTransportStreamIsCleaned() async throws {
        let media = try await Fixtures.encode()
        let original = try TestMPEGWriter.writeTransportStream(media)
        defer { try? FileManager.default.removeItem(at: original) }
        // Garbage in the middle and a partial packet at the end.
        var data = try Data(contentsOf: original)
        let middle = (data.count / 2 / 188) * 188 + 50
        data.insert(contentsOf: [UInt8](repeating: 0xAB, count: 333), at: middle)
        data.append(contentsOf: [0x47, 0x01, 0x00])
        let damaged = Fixtures.temporaryURL("ts")
        try data.write(to: damaged)
        defer { try? FileManager.default.removeItem(at: damaged) }

        let (_, output, _) = try repair(damaged)
        defer { try? FileManager.default.removeItem(at: output) }
        let cleaned = try Data(contentsOf: output)
        #expect(cleaned.count % 188 == 0)
        #expect(stride(from: 0, to: cleaned.count, by: 188).allSatisfy { cleaned[$0] == 0x47 })
        #expect(try MediaRepair.diagnose(output) == nil)
        #expect(try readAll(output).count > 20)
    }

    @Test func cutOffFLVKeepsCompleteTags() async throws {
        let media = try await Fixtures.encode()
        let original = try TestFLVWriter.write(media)
        let damaged = try truncate(original, to: 0.8)
        defer { [original, damaged].forEach { try? FileManager.default.removeItem(at: $0) } }

        let (_, output, _) = try repair(damaged)
        defer { try? FileManager.default.removeItem(at: output) }
        #expect(try MediaRepair.diagnose(output) == nil)
        let packets = try readAll(output)
        #expect(packets.count > 10)
    }

    @Test func oggPagesAreVerifiedAndClosed() throws {
        // Three pages of one stream, then damage the middle one.
        func page(_ sequence: UInt32, _ flags: UInt8, _ body: [UInt8]) -> [UInt8] {
            var bytes: [UInt8] = Array("OggS".utf8) + [0, flags] + [UInt8](repeating: 0, count: 8)
            bytes += [1, 0, 0, 0] + withUnsafeBytes(of: sequence.littleEndian) { Array($0) } + [0, 0, 0, 0]
            bytes += [1, UInt8(body.count)] + body
            let crc = OggFixer.crc(bytes)
            bytes.replaceSubrange(22..<26, with: withUnsafeBytes(of: crc.littleEndian) { Array($0) })
            return bytes
        }
        var file = page(0, 2, Array("OpusHead".utf8) + [1, 2, 0, 0, 0x80, 0xBB, 0, 0, 0, 0, 0])
        var damagedPage = page(1, 0, [1, 2, 3, 4])
        damagedPage[30] ^= 0xFF
        file += damagedPage + page(2, 0, [5, 6, 7, 8])
        let url = Fixtures.temporaryURL("ogg")
        try Data(file).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let (plan, output, _) = try repair(url)
        defer { try? FileManager.default.removeItem(at: output) }
        #expect(plan.findings.contains { $0.contains("checksums") })
        let repaired = [UInt8](try Data(contentsOf: output))
        #expect(repaired.count == file.count - damagedPage.count)
        #expect(try MediaRepair.diagnose(output) == nil) // Valid checksums, stream properly ended.
    }
}
