//
//  MovieRepairTests.swift
//  Ultimate TheaterTests
//
//  The repair engine against a known answer: a movie written by AVAssetWriter has its
//  index removed, is repaired using the original as the reference, and must come back
//  with identical frames, keyframes, display times, and audio.
//

import Testing
import Foundation
import AVFoundation
@testable import Ultimate_Theater

@Suite(.serialized)
struct MovieRepairTests {
    /// Copies every top-level box except 'moov', as an interrupted copy or encode would leave it.
    private func stripIndex(_ url: URL) throws -> URL {
        let data = try Data(contentsOf: url)
        var output = Data()
        var at = 0
        while at + 8 <= data.count {
            var size = Int(data[at..<(at + 4)].bigEndianUInt)
            if size == 1 { size = Int(data[(at + 8)..<(at + 16)].bigEndianUInt) }
            if size == 0 { size = data.count - at }
            if data[(at + 4)..<(at + 8)] != Data("moov".utf8) { output.append(data[at..<(at + size)]) }
            at += size
        }
        let damaged = Fixtures.temporaryURL("mp4")
        try output.write(to: damaged)
        return damaged
    }

    private func packets(_ url: URL) throws -> (video: [MediaPacket], audio: [MediaPacket]) {
        let demuxer = try Demuxers.open(url)
        let video = try #require(demuxer.tracks.first { $0.kind == .video }).id
        var result: (video: [MediaPacket], audio: [MediaPacket]) = ([], [])
        while let packet = try demuxer.nextPacket() {
            if packet.trackID == video { result.video.append(packet) } else { result.audio.append(packet) }
        }
        return result
    }

    @Test func rebuildsAMissingIndexExactly() async throws {
        let original = try await MovieFixture.write(.mp4, seconds: 4)
        let damaged = try stripIndex(original)
        let repaired = Fixtures.temporaryURL("mp4")
        defer { [original, damaged, repaired].forEach { try? FileManager.default.removeItem(at: $0) } }

        #expect(throws: (any Error).self) { try Demuxers.open(damaged) } // Unplayable before repair.
        let repairer = try MovieRepairer(damaged: damaged)
        let reference = try #require(repairer.matchingReference(from: [original]))
        let analysis = try repairer.analyze(with: reference) { _ in }
        let report = try repairer.write(analysis, reference: reference, to: repaired) { _ in }
        #expect(report.videoFrames == 120 && report.unrecoveredBytes == 0)

        let before = try packets(original)
        let after = try packets(repaired)
        #expect(after.video.count == before.video.count)
        #expect(after.video.map(\.data) == before.video.map(\.data))
        #expect(after.video.map(\.isKeyframe) == before.video.map(\.isKeyframe))
        #expect(zip(after.video, before.video).allSatisfy { abs($0.pts - $1.pts) < 0.001 })
        #expect(after.audio.map(\.data) == before.audio.map(\.data))

        let asset = AVURLAsset(url: repaired)
        #expect(try await asset.load(.isPlayable))
    }

    @Test func resizedSequenceParametersKeepEverythingElse() throws {
        // SPS for 1920×816 High profile (from a real x264 encode), resized to 1920×1040.
        let reference = try RepairReference(url: try #require(fixtureReference))
        let resized = try #require(reference.resized(widthInMacroblocks: 120, heightInMapUnits: 65))
        #expect(resized.width == 1920 && resized.height == 1040)
        #expect(resized.sps.totalMacroblocks == 120 * 65)
        #expect(resized.sps.pocType == reference.sps.pocType && resized.sps.log2MaxFrameNum == reference.sps.log2MaxFrameNum)
    }

    /// A small movie written once for the resize test.
    private var fixtureReference: URL? {
        get throws {
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var url: URL?
            Task.detached {
                url = try? await MovieFixture.write(.mp4, seconds: 1, width: 1920, height: 816)
                semaphore.signal()
            }
            semaphore.wait()
            return url
        }
    }
}
