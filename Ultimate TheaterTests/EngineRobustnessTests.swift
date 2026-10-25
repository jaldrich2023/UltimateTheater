//
//  EngineRobustnessTests.swift
//  Ultimate TheaterTests
//
//  Engine safeguards against damaged or unusual files: bounded packet queues, the sorted
//  subtitle cue store, numeric validation of container fields, and seeking without a duration.
//

import Testing
import Foundation
import CoreGraphics
import CoreMedia
@testable import Ultimate_Theater

struct PacketQueueTests {
    private func packet(_ pts: Double, bytes: Int = 10, key: Bool = true) -> MediaPacket {
        MediaPacket(trackID: 1, pts: pts, duration: nil, isKeyframe: key, data: Data(count: bytes))
    }

    @Test func keepsOrderAcrossCompaction() {
        var queue = PacketQueue()
        for index in 0..<3000 { queue.append(packet(Double(index))) }
        for index in 0..<2500 { #expect(queue.popFirst()?.pts == Double(index)) }
        queue.append(packet(3000))
        #expect(queue.count == 501)
        #expect(queue.byteCount == 5010)
        for index in 2500...3000 { #expect(queue.popFirst()?.pts == Double(index)) }
        #expect(queue.isEmpty)
        #expect(queue.byteCount == 0)
        #expect(queue.popFirst() == nil)
    }

    @Test func fillsAtPacketOrByteLimit() {
        var byCount = PacketQueue(packetLimit: 3, byteLimit: 1_000)
        byCount.append(contentsOf: [packet(0), packet(1)])
        #expect(!byCount.isFull)
        byCount.append(packet(2))
        #expect(byCount.isFull)
        _ = byCount.popFirst()
        #expect(!byCount.isFull)

        var byBytes = PacketQueue(packetLimit: 100, byteLimit: 25)
        byBytes.append(packet(0, bytes: 20))
        #expect(!byBytes.isFull)
        byBytes.append(packet(1, bytes: 5))
        #expect(byBytes.isFull)
    }

    @Test func fillsAtItsTimeSpan() {
        var queue = PacketQueue(byteLimit: 1_000_000, spanLimit: 2)
        queue.append(contentsOf: [packet(10), packet(11)])
        #expect(queue.span == 1)
        #expect(!queue.isFull)
        queue.append(packet(12))
        #expect(queue.isFull)
        _ = queue.popFirst()
        #expect(!queue.isFull)
        // Packets without usable timestamps don't count toward the span.
        queue.append(packet(.nan))
        #expect(queue.span == 1)
        queue.removeAll()
        #expect(queue.span == 0)
    }

    @Test func manySmallPacketsDontFillTheDefaultQueue() {
        // TrueHD sends about 1,200 packets a second; ten seconds of it must still fit.
        var queue = PacketQueue()
        for index in 0..<12_000 { queue.append(packet(Double(index) / 1_200)) }
        #expect(!queue.isFull)
        for index in 12_000..<24_100 { queue.append(packet(Double(index) / 1_200)) }
        #expect(queue.isFull) // Past 20 seconds.
    }

    @Test func dropsToNextKeyframe() {
        var queue = PacketQueue()
        queue.append(contentsOf: [packet(0, key: false), packet(1, key: false), packet(2), packet(3, key: false)])
        #expect(queue.dropUntilKeyframe() == 2)
        #expect(queue.first?.pts == 2)
        #expect(queue.count == 2)

        var none = PacketQueue()
        none.append(contentsOf: [packet(0, key: false), packet(1, key: false)])
        none.dropUntilKeyframe()
        #expect(none.isEmpty)
    }
}

@MainActor
struct SubtitleCueStoreTests {
    private func text(_ start: Double, _ end: Double, _ line: String) -> SubtitleCue {
        SubtitleCue(start: start, end: end, text: line)
    }

    @Test func findsShowingCueByBinarySearch() {
        var store = SubtitleCueStore()
        // Out of order on purpose: the store keeps them sorted.
        store.insert(text(10, 12, "b"))
        store.insert(text(0, 2, "a"))
        store.insert(text(20, 25, "c"))
        #expect(store.cues.map(\.start) == [0, 10, 20])
        #expect(store.cue(at: 1)?.text == "a")
        #expect(store.cue(at: 2) == nil) // End is exclusive.
        #expect(store.cue(at: 11.5)?.text == "b")
        #expect(store.cue(at: 15) == nil)
        #expect(store.cue(at: -1) == nil)
    }

    @Test func overlappingCuesShowTheLatestAndLongCuesStillFound() {
        var store = SubtitleCueStore()
        store.insert(text(0, 100, "long"))
        for index in 1...50 { store.insert(text(Double(index), Double(index) + 0.5, "short \(index)")) }
        #expect(store.cue(at: 10.2)?.text == "short 10")
        #expect(store.cue(at: 60)?.text == "long")
    }

    @Test func sameStartReplaces() {
        var store = SubtitleCueStore()
        store.insert(text(5, 6, "old"))
        store.insert(text(5, 7, "new"))
        #expect(store.count == 1)
        #expect(store.cue(at: 6.5)?.text == "new")
    }

    @Test func openCuesEndAtTheNextDisplaySet() {
        var store = SubtitleCueStore()
        store.insert(SubtitleCue(start: 10, end: .infinity, text: "open"))
        #expect(store.cue(at: 500)?.text == "open")
        store.end(at: 30)
        #expect(store.cue(at: 29)?.text == "open")
        #expect(store.cue(at: 30) == nil)
        store.end(at: 40) // Nothing open: no change.
        #expect(store.cues.first?.end == 30)
    }

    @Test func evictsOnlyImageCuesFarFromThePlayhead() throws {
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let bitmap = SubtitleBitmap(image: image, frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        var store = SubtitleCueStore()
        store.insert(SubtitleCue(start: 0, end: 5, text: "", bitmaps: [bitmap]))
        store.insert(SubtitleCue(start: 100, end: 105, text: "", bitmaps: [bitmap]))
        store.insert(SubtitleCue(start: 2000, end: .infinity, text: "", bitmaps: [bitmap]))
        store.insert(text(1, 3, "text stays"))
        store.evictImages(around: 120)
        #expect(store.cues.map(\.start) == [1, 100])
        #expect(store.cue(at: 102)?.bitmaps == [bitmap])
        #expect(store.cue(at: 3000) == nil)
    }
}

struct FormatValidationTests {
    @Test func adpcmFramesPerPacket() {
        // A 2-channel 2048-byte IMA block: one header sample plus 2040 more per channel.
        #expect(FormatValidation.adpcmFramesPerPacket(isIMA: true, blockAlign: 2048, channels: 2, samplesPerBlock: nil) == 2041)
        #expect(FormatValidation.adpcmFramesPerPacket(isIMA: false, blockAlign: 2048, channels: 2, samplesPerBlock: nil) == 2036)
        #expect(FormatValidation.adpcmFramesPerPacket(isIMA: true, blockAlign: 2048, channels: 2, samplesPerBlock: 2041) == 2041)
        // Blocks too small for their channel headers are rejected rather than going negative.
        #expect(FormatValidation.adpcmFramesPerPacket(isIMA: true, blockAlign: 6, channels: 2, samplesPerBlock: nil) == nil)
        #expect(FormatValidation.adpcmFramesPerPacket(isIMA: false, blockAlign: 13, channels: 2, samplesPerBlock: nil) == nil)
        #expect(FormatValidation.adpcmFramesPerPacket(isIMA: true, blockAlign: 0, channels: 2, samplesPerBlock: nil) == nil)
        #expect(FormatValidation.adpcmFramesPerPacket(isIMA: true, blockAlign: 512, channels: 0, samplesPerBlock: nil) == nil)
    }

    @Test func sampleRatesAndTimescales() {
        #expect(FormatValidation.timescale(forSampleRate: 48_000) == 48_000)
        #expect(FormatValidation.timescale(forSampleRate: 44_100.5) == 44_100)
        #expect(FormatValidation.timescale(forSampleRate: 0) == nil)
        #expect(FormatValidation.timescale(forSampleRate: -8_000) == nil)
        #expect(FormatValidation.timescale(forSampleRate: .nan) == nil)
        #expect(FormatValidation.timescale(forSampleRate: .infinity) == nil)
        #expect(FormatValidation.timescale(forSampleRate: 3e9) == nil)
    }

    @Test func channelsAndDimensions() {
        #expect(FormatValidation.channels(nil) == 2)
        #expect(FormatValidation.channels(0) == 1)
        #expect(FormatValidation.channels(6) == 6)
        #expect(FormatValidation.channels(1 << 40) == nil)
        #expect(FormatValidation.dimension(1920) == 1920)
        #expect(FormatValidation.dimension(0) == 0)
        #expect(FormatValidation.dimension(-1) == nil)
        #expect(FormatValidation.dimension(20_000) == nil)
    }

    @Test func durationsAndNumericDimensions() {
        #expect(FormatValidation.duration(5_400) == 5_400)
        #expect(FormatValidation.duration(0) == 0)
        #expect(FormatValidation.duration(nil) == nil)
        #expect(FormatValidation.duration(.nan) == nil)
        #expect(FormatValidation.duration(.infinity) == nil)
        #expect(FormatValidation.duration(-1) == nil)
        #expect(FormatValidation.duration(1e300) == nil)
        #expect(FormatValidation.dimension(1920.0) == 1920)
        #expect(FormatValidation.dimension(Double.nan) == nil)
        #expect(FormatValidation.dimension(Double.infinity) == nil)
        #expect(FormatValidation.dimension(1e300) == nil)
        #expect(FormatValidation.dimension(-2.0) == nil)
    }

    @Test func damagedAudioHeadersThrowInsteadOfTrapping() {
        var adpcm = ContainerTrack(id: 1, kind: .audio, codec: .adpcmIMA, codecID: "ima")
        adpcm.channels = 2
        adpcm.blockAlign = 4
        #expect(throws: MediaFormatError.self) { try TrackFormatter(track: adpcm) }

        var pcm = ContainerTrack(id: 2, kind: .audio, codec: .pcm(bits: 16, isFloat: false, isBigEndian: false), codecID: "pcm")
        pcm.channels = Int(UInt32.max) + 1
        #expect(throws: MediaFormatError.self) { try TrackFormatter(track: pcm) }

        pcm.channels = 2
        pcm.sampleRate = .nan
        #expect(throws: MediaFormatError.self) { try TrackFormatter(track: pcm) }
    }
}

struct SeekTargetTests {
    @Test func clampsToKnownDuration() {
        #expect(TheaterEngine.seekTarget(50, duration: 100) == 50)
        #expect(TheaterEngine.seekTarget(200, duration: 100) == 99.5)
        #expect(TheaterEngine.seekTarget(-5, duration: 100) == 0)
    }

    @Test func seeksWithoutADuration() {
        // Live WebM and broadcast recordings often don't know their length.
        #expect(TheaterEngine.seekTarget(300, duration: 0) == 300)
        #expect(TheaterEngine.seekTarget(-3, duration: 0) == 0)
        #expect(TheaterEngine.seekTarget(.nan, duration: 0) == 0)
        #expect(TheaterEngine.seekTarget(.infinity, duration: 0) == 0)
        #expect(TheaterEngine.seekTarget(300, duration: .nan) == 300)
        // Huge targets in a file of unknown length stay within a representable time.
        #expect(TheaterEngine.seekTarget(1e300, duration: 0) == FormatValidation.maximumDuration)
    }

    @Test func sanitizesTimesForDisplayAndCoreMedia() {
        #expect(TheaterEngine.sanitizedTime(12.5) == 12.5)
        #expect(TheaterEngine.sanitizedTime(.nan) == 0)
        #expect(TheaterEngine.sanitizedTime(.infinity) == 0)
        #expect(TheaterEngine.sanitizedTime(-.infinity) == 0)
        #expect(TheaterEngine.sanitizedTime(1e300) == 0)
        #expect(TheaterEngine.sanitizedTime(-3) == 0)
    }
}
