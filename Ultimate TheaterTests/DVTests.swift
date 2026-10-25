//
//  DVTests.swift
//  Ultimate TheaterTests
//
//  DV frames from the system encoder, with a known tone written into their audio blocks,
//  read back by the raw DV reader and decoded again.
//

import Testing
import Foundation
import CoreMedia
import VideoToolbox
import os
@testable import Ultimate_Theater

struct DVTests {
    /// DV frames (NTSC, 120,000 bytes each) from VideoToolbox's DV encoder.
    private func encodeFrames(_ count: Int) throws -> [Data] {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: 720, height: 480, codecType: kCMVideoCodecType_DVCNTSC,
                                                encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw MediaFormatError.coreMedia(status) }
        defer { VTCompressionSessionInvalidate(session) }
        // The output handler runs on the encoder's threads.
        let frames = OSAllocatedUnfairLock(initialState: [Data]())
        for index in 0..<count {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 720, 480, kCVPixelFormatType_422YpCbCr8, nil, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(60 + index * 40), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 30),
                                            duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { _, _, sample in
                guard let sample, let block = CMSampleBufferGetDataBuffer(sample) else { return }
                var data = Data(count: CMBlockBufferGetDataLength(block))
                data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
                let frame = data
                frames.withLock { $0.append(frame) }
            }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        return frames.withLock { $0 }
    }

    /// Writes 16-bit stereo samples and an AAUX source pack (48 kHz, 1,600 samples) into a frame.
    private func addAudio(_ frame: inout [UInt8], left: (Int) -> Int16, right: (Int) -> Int16) {
        for sequence in 0..<10 {
            for block in 0..<9 {
                let at = (sequence * 150 + 6 + block * 16) * 80
                if block == 0 { frame.replaceSubrange((at + 3)..<(at + 8), with: [0x50, 0xD4, 0x30, 0xC0, 0x00]) } // 1580 + 20 samples, 48 kHz, 16-bit
                for k in 0..<36 {
                    let index = DVDemuxer.shuffledIndex(sequence: sequence, block: block, sample: k, isPAL: false)
                    guard index < 1600 else { continue }
                    let value = UInt16(bitPattern: sequence < 5 ? left(index) : right(index))
                    frame[at + 8 + k * 2] = UInt8(value >> 8)
                    frame[at + 8 + k * 2 + 1] = UInt8(value & 0xFF)
                }
            }
        }
    }

    @Test func rawDVPlaysVideoAndAudio() throws {
        let encoded: [Data]
        do { encoded = try encodeFrames(3) } catch {
            Issue.record("This Mac has no DV encoder to make test frames: \(error)")
            return
        }
        try #require(encoded.count == 3 && encoded.allSatisfy { $0.count == 120_000 })
        var file = Data()
        for frame in encoded {
            var bytes = [UInt8](frame)
            addAudio(&bytes, left: { Int16($0 * 10) }, right: { Int16(-$0 * 10) })
            file.append(contentsOf: bytes)
        }
        let url = Fixtures.temporaryURL("dv")
        try file.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let demuxer = try Demuxers.open(url)
        #expect(demuxer is DVDemuxer)
        let video = try #require(demuxer.tracks.first { $0.kind == .video })
        let audio = try #require(demuxer.tracks.first { $0.kind == .audio })
        #expect(video.width == 720 && video.height == 480 && audio.sampleRate == 48000)
        #expect(abs((demuxer.duration ?? 0) - 3 * 1001.0 / 30000) < 0.001)

        var packets: [MediaPacket] = []
        while let packet = try demuxer.nextPacket() { packets.append(packet) }
        let frames = packets.filter { $0.trackID == video.id }
        let formatter = try TrackFormatter(track: video)
        let samples = try frames.flatMap(formatter.sampleBuffers)
        #expect(DecodeCheck.decodedFrames(samples, format: try #require(formatter.format)) == 3)

        let pcm = try #require(packets.first { $0.trackID == audio.id }?.data)
        #expect(pcm.count == 1600 * 4)
        let values = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map { Int16(littleEndian: $0) }
        #expect(values[0] == 0 && values[2] == 10 && values[3] == -10 && values[3198] == 15990 && values[3199] == -15990)
    }
}
