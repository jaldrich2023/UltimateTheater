//
//  TheaterEngineTests.swift
//  Ultimate TheaterTests
//
//  End-to-end checks for the Theater engine's container readers. Real H.264 and
//  AAC are encoded with VideoToolbox / AudioToolbox, wrapped in MKV and AVI files
//  by small test-only writers, read back by the demuxers, and decoded again by the
//  system decoders.
//

import Testing
import Foundation
import AVFoundation
import VideoToolbox
@testable import Ultimate_Theater

// MARK: - Fixture media

/// Encoded media shared by the tests.
nonisolated struct EncodedMedia: @unchecked Sendable {
    struct VideoFrame {
        let data: Data       // AVCC (length-prefixed) access unit
        let pts: Double
        let isKeyframe: Bool
    }
    var video: [VideoFrame] = []
    var avcC = Data()
    var sps = Data()
    var pps = Data()
    var width = 160
    var height = 120
    var frameDuration = 1.0 / 30
    var aac: [Data] = []
    var audioSpecificConfig = Data()
    var sampleRate = 44100.0
    var channels = 2
}

nonisolated enum Fixtures {
    static func encode(frames: Int = 45) async throws -> EncodedMedia {
        var media = EncodedMedia()
        try encodeVideo(into: &media, frames: frames)
        try encodeAudio(into: &media, seconds: Double(frames) / 30)
        return media
    }

    private static func encodeVideo(into media: inout EncodedMedia, frames: Int) throws {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(media.width), height: Int32(media.height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw MediaFormatError.coreMedia(status) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 15 as CFNumber)

        let collector = SampleCollector()
        for index in 0..<frames {
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, media.width, media.height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
            guard let pixelBuffer else { continue }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                memset(base, Int32(index * 5 % 255), CVPixelBufferGetDataSize(pixelBuffer))
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            let pts = CMTime(value: CMTimeValue(index), timescale: 30)
            VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                            duration: CMTime(value: 1, timescale: 30), frameProperties: nil,
                                            infoFlagsOut: nil) { status, _, sample in
                if status == noErr, let sample { collector.append(sample) }
            }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)

        for sample in collector.samples {
            guard let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { continue }
            if media.avcC.isEmpty,
               let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Data],
               let avcC = atoms["avcC"] {
                media.avcC = avcC
                media.sps = parameterSet(format, index: 0)
                media.pps = parameterSet(format, index: 1)
            }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            guard let pointer else { continue }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            media.video.append(.init(data: Data(bytes: pointer, count: length),
                                     pts: CMSampleBufferGetPresentationTimeStamp(sample).seconds, isKeyframe: !notSync))
        }
    }

    private static func parameterSet(_ format: CMFormatDescription, index: Int) -> Data {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                           parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                           nalUnitHeaderLengthOut: nil)
        return pointer.map { Data(bytes: $0, count: size) } ?? Data()
    }

    private static func encodeAudio(into media: inout EncodedMedia, seconds: Double) throws {
        let input = AVAudioFormat(standardFormatWithSampleRate: media.sampleRate, channels: AVAudioChannelCount(media.channels))!
        let output = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: media.sampleRate,
                                              AVNumberOfChannelsKey: media.channels])!
        let converter = AVAudioConverter(from: input, to: output)!
        let frameCount = AVAudioFrameCount(media.sampleRate * seconds)
        let pcm = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: frameCount)!
        pcm.frameLength = frameCount
        for channel in 0..<media.channels {
            for frame in 0..<Int(frameCount) {
                pcm.floatChannelData![channel][frame] = sinf(Float(frame) * 2 * .pi * 440 / Float(media.sampleRate)) * 0.3
            }
        }
        var supplied = false
        while true {
            let buffer = AVAudioCompressedBuffer(format: output, packetCapacity: 16, maximumPacketSize: converter.maximumOutputPacketSize)
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { _, inputStatus in
                if supplied { inputStatus.pointee = .endOfStream; return nil }
                supplied = true
                inputStatus.pointee = .haveData
                return pcm
            }
            for index in 0..<Int(buffer.packetCount) {
                guard let description = buffer.packetDescriptions?[index] else { continue }
                media.aac.append(Data(bytes: buffer.data.advanced(by: Int(description.mStartOffset)),
                                      count: Int(description.mDataByteSize)))
            }
            if status == .endOfStream || status == .error || (buffer.packetCount == 0 && supplied) { break }
        }
        media.audioSpecificConfig = AAC.audioSpecificConfig(sampleRate: media.sampleRate, channels: media.channels)
    }

    private final class SampleCollector: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var samples: [CMSampleBuffer] = []
        func append(_ sample: CMSampleBuffer) {
            lock.lock(); samples.append(sample); lock.unlock()
        }
    }

    static func temporaryURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "theater-\(UUID().uuidString).\(ext)")
    }
}

// MARK: - Test-only writers

nonisolated enum TestMKVWriter {
    static func id(_ id: UInt32) -> Data {
        let bytes = withUnsafeBytes(of: id.bigEndian, Array.init)
        return Data(bytes.drop { $0 == 0 })
    }

    /// Fixed 8-byte size encoding, so layouts are predictable.
    static func size(_ value: Int) -> Data {
        Data([0x01] + withUnsafeBytes(of: UInt64(value).bigEndian, Array.init).dropFirst())
    }

    static func element(_ elementID: UInt32, _ payload: Data) -> Data {
        id(elementID) + size(payload.count) + payload
    }

    static func uint(_ elementID: UInt32, _ value: UInt64) -> Data {
        element(elementID, Data(withUnsafeBytes(of: value.bigEndian, Array.init)))
    }

    static func float(_ elementID: UInt32, _ value: Double) -> Data {
        element(elementID, Data(withUnsafeBytes(of: value.bitPattern.bigEndian, Array.init)))
    }

    static func string(_ elementID: UInt32, _ value: String) -> Data {
        element(elementID, Data(value.utf8))
    }

    static func simpleBlock(track: UInt8, relative: Int16, keyframe: Bool, frames: [Data]) -> Data {
        var payload = Data([0x80 | track])
        payload += withUnsafeBytes(of: relative.bigEndian) { Data($0) }
        if frames.count == 1 {
            payload.append(keyframe ? 0x80 : 0x00)
            payload += frames[0]
        } else {
            payload.append((keyframe ? 0x80 : 0x00) | 0x02) // Xiph lacing
            payload.append(UInt8(frames.count - 1))
            for frame in frames.dropLast() {
                var size = frame.count
                while size >= 255 { payload.append(255); size -= 255 }
                payload.append(UInt8(size))
            }
            for frame in frames { payload += frame }
        }
        return element(MatroskaDemuxer.ID.simpleBlock, payload)
    }

    /// One-second clusters, Xiph-laced audio in pairs, chapters, cues, and a SeekHead.
    static func write(_ media: EncodedMedia, subtitles: [(start: Double, end: Double, text: String)] = []) throws -> URL {
        typealias ID = MatroskaDemuxer.ID
        let audioStep = 1024 / media.sampleRate

        let info = element(ID.info, uint(ID.timecodeScale, 1_000_000)
                           + float(ID.duration, Double(media.video.count) * media.frameDuration * 1000))
        var trackEntries = element(ID.trackEntry,
            uint(ID.trackNumber, 1) + uint(ID.trackType, 1) + string(ID.codecID, "V_MPEG4/ISO/AVC")
            + element(ID.codecPrivate, media.avcC)
            + uint(ID.defaultDuration, UInt64(media.frameDuration * 1_000_000_000))
            + element(ID.video, uint(ID.pixelWidth, UInt64(media.width)) + uint(ID.pixelHeight, UInt64(media.height))))
        trackEntries += element(ID.trackEntry,
            uint(ID.trackNumber, 2) + uint(ID.trackType, 2) + string(ID.codecID, "A_AAC")
            + string(ID.language, "spa") + string(ID.name, "Spanish Stereo")
            + element(ID.codecPrivate, media.audioSpecificConfig)
            + element(ID.audio, float(ID.samplingFrequency, media.sampleRate) + uint(ID.channels, UInt64(media.channels))))
        if !subtitles.isEmpty {
            trackEntries += element(ID.trackEntry,
                uint(ID.trackNumber, 3) + uint(ID.trackType, 0x11) + string(ID.codecID, "S_TEXT/UTF8")
                + string(ID.language, "eng") + uint(ID.flagForced, 1))
        }
        let tracks = element(ID.tracks, trackEntries)
        let chapters = element(ID.chapters, element(ID.editionEntry,
            element(ID.chapterAtom, uint(ID.chapterTimeStart, 0) + uint(ID.chapterTimeEnd, 500_000_000)
                    + element(ID.chapterDisplay, string(ID.chapString, "Opening Credits")))))

        // Clusters: gather blocks by the second they start in.
        struct Block { let time: Double; let data: Data }
        var blocks: [Block] = []
        for frame in media.video {
            blocks.append(Block(time: frame.pts, data: Data())) // placeholder for ordering
        }
        var clusters = Data()
        var cuePositions: [(time: UInt64, position: Int)] = []
        let headerLength = 0 // positions are relative to segment data; computed below
        _ = headerLength

        let clusterSeconds = 1.0
        let totalDuration = Double(media.video.count) * media.frameDuration
        var clusterBodies: [(time: UInt64, body: Data)] = []
        var start = 0.0
        var videoIndex = 0
        var audioIndex = 0
        while start < totalDuration + 0.001 {
            let clusterTime = UInt64(start * 1000)
            var body = uint(ID.timecode, clusterTime)
            // Video frames are kept in decode order; a frame belongs to the cluster of its keyframe run.
            while videoIndex < media.video.count {
                let frame = media.video[videoIndex]
                if frame.isKeyframe && videoIndex > 0 && frame.pts >= start + clusterSeconds { break }
                let relative = Int16((frame.pts * 1000).rounded() - Double(clusterTime))
                body += simpleBlock(track: 1, relative: relative, keyframe: frame.isKeyframe, frames: [frame.data])
                videoIndex += 1
            }
            while audioIndex < media.aac.count, Double(audioIndex) * audioStep < start + clusterSeconds || videoIndex >= media.video.count {
                let pair = Array(media.aac[audioIndex..<min(audioIndex + 2, media.aac.count)])
                let relative = Int16((Double(audioIndex) * audioStep * 1000).rounded() - Double(clusterTime))
                body += simpleBlock(track: 2, relative: relative, keyframe: true, frames: pair)
                audioIndex += pair.count
            }
            for cue in subtitles where cue.start >= start && cue.start < start + clusterSeconds {
                let relative = Int16(cue.start * 1000 - Double(clusterTime))
                body += element(ID.blockGroup,
                                element(ID.block, Data([0x83]) + withUnsafeBytes(of: relative.bigEndian) { Data($0) } + Data([0]) + Data(cue.text.utf8))
                                + uint(ID.blockDuration, UInt64((cue.end - cue.start) * 1000)))
            }
            clusterBodies.append((clusterTime, body))
            start += clusterSeconds
            if videoIndex >= media.video.count && audioIndex >= media.aac.count { break }
        }

        // SeekHead has a fixed size thanks to fixed-width integers; lay out, then patch the cues position.
        func seekHead(cuesPosition: Int) -> Data {
            element(ID.seekHead, element(ID.seek, element(ID.seekID, id(ID.cues)) + uint(ID.seekPosition, UInt64(cuesPosition))))
        }
        let leading = seekHead(cuesPosition: 0).count + info.count + tracks.count + chapters.count
        var position = leading
        for (time, body) in clusterBodies {
            cuePositions.append((time, position))
            let cluster = element(ID.cluster, body)
            clusters += cluster
            position += cluster.count
        }
        let cues = element(ID.cues, cuePositions.map { cue in
            element(ID.cuePoint, uint(ID.cueTime, cue.time)
                    + element(ID.cueTrackPositions, uint(ID.cueTrack, 1) + uint(ID.cueClusterPosition, UInt64(cue.position))))
        }.reduce(Data(), +))
        let segmentBody = seekHead(cuesPosition: position) + info + tracks + chapters + clusters + cues

        let header = element(ID.ebml, string(0x4282, "matroska") + uint(0x4287, 4) + uint(0x4285, 2))
        let file = header + element(ID.segment, segmentBody)
        let url = Fixtures.temporaryURL("mkv")
        try file.write(to: url)
        return url
    }
}

nonisolated enum TestAVIWriter {
    private static func join(_ parts: Data...) -> Data { parts.reduce(into: Data()) { $0.append($1) } }
    private static func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
    private static func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
    private static func chunk(_ id: String, _ payload: Data) -> Data {
        Data(id.utf8) + le32(payload.count) + payload + (payload.count % 2 == 1 ? Data([0]) : Data())
    }
    private static func list(_ type: String, _ payload: Data) -> Data { chunk("LIST", Data(type.utf8) + payload) }

    /// H.264 (Annex B) video plus 16-bit PCM audio, with an idx1 index.
    static func write(_ media: EncodedMedia) throws -> URL {
        let startCode = Data([0, 0, 0, 1])
        let videoChunks = media.video.map { frame -> Data in
            var annexB = frame.isKeyframe ? startCode + media.sps + startCode + media.pps : Data()
            var reader = ByteReader(frame.data)
            while reader.remaining >= 4 {
                let length = (try? reader.take(4)).map { $0.reduce(0) { $0 << 8 | Int($1) } } ?? 0
                guard let unit = try? reader.take(length) else { break }
                annexB += startCode + Data(unit)
            }
            return annexB
        }
        let pcmRate = 8000, pcmChannels = 1
        let bytesPerFrameChunk = Int(Double(pcmRate) * media.frameDuration) * 2

        func strh(_ type: String, _ handler: String, scale: Int, rate: Int, length: Int, sampleSize: Int) -> Data {
            join(Data(type.utf8), Data(handler.utf8), le32(0), le16(0), le16(0), le32(0),
                 le32(scale), le32(rate), le32(0), le32(length), le32(0), le32(0), le32(sampleSize), Data(count: 8))
        }
        let videoFormat = join(le32(40), le32(media.width), le32(media.height), le16(1), le16(24), Data("H264".utf8), Data(count: 20))
        let audioFormat = join(le16(1), le16(pcmChannels), le32(pcmRate), le32(pcmRate * 2), le16(2), le16(16), le16(0))
        let avih = join(le32(Int(media.frameDuration * 1_000_000)), Data(count: 12), le32(media.video.count), le32(0), le32(2),
                        le32(0), le32(media.width), le32(media.height), Data(count: 16))
        let hdrl = list("hdrl", chunk("avih", avih)
            + list("strl", chunk("strh", strh("vids", "H264", scale: 1, rate: 30, length: media.video.count, sampleSize: 0))
                   + chunk("strf", videoFormat))
            + list("strl", chunk("strh", strh("auds", "\0\0\0\0", scale: 2, rate: pcmRate * 2, length: 0, sampleSize: 2))
                   + chunk("strf", audioFormat) + chunk("strn", Data("Commentary\0".utf8))))

        var movi = Data("movi".utf8)
        var index = Data()
        for (i, video) in videoChunks.enumerated() {
            index += join(Data("00dc".utf8), le32(media.video[i].isKeyframe ? 0x10 : 0), le32(movi.count), le32(video.count))
            movi += chunk("00dc", video)
            let audio = Data(count: bytesPerFrameChunk)
            index += join(Data("01wb".utf8), le32(0x10), le32(movi.count), le32(audio.count))
            movi += chunk("01wb", audio)
        }
        let body = Data("AVI ".utf8) + hdrl + chunk("LIST", movi) + chunk("idx1", index)
        let url = Fixtures.temporaryURL("avi")
        try (Data("RIFF".utf8) + le32(body.count) + body).write(to: url)
        return url
    }
}

// MARK: - Decoding helpers

nonisolated enum DecodeCheck {
    /// Decodes video sample buffers with VideoToolbox; returns how many produced images.
    static func decodedFrames(_ samples: [CMSampleBuffer], format: CMFormatDescription) -> Int {
        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                           imageBufferAttributes: nil, outputCallback: nil,
                                           decompressionSessionOut: &session) == noErr, let session else { return 0 }
        defer { VTDecompressionSessionInvalidate(session) }
        let counter = Counter()
        for sample in samples {
            VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                if status == noErr, image != nil { counter.increment() }
            }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return counter.value
    }

    /// Decodes compressed audio sample buffers to PCM; returns the decoded frame count.
    static func decodedAudioFrames(_ samples: [CMSampleBuffer], format: CMFormatDescription) -> Int {
        guard let input = AVAudioFormat(formatDescription: format),
              let output = AVAudioFormat(standardFormatWithSampleRate: input.sampleRate, channels: input.channelCount),
              let converter = AVAudioConverter(from: input, to: output) else { return 0 }
        var queue = samples
        var total = 0
        while true {
            let pcm = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 4096)!
            var error: NSError?
            let status = converter.convert(to: pcm, error: &error) { _, inputStatus in
                guard !queue.isEmpty else { inputStatus.pointee = .endOfStream; return nil }
                let sample = queue.removeFirst()
                guard let block = CMSampleBufferGetDataBuffer(sample) else { inputStatus.pointee = .noDataNow; return nil }
                let length = CMBlockBufferGetDataLength(block)
                let compressed = AVAudioCompressedBuffer(format: input, packetCapacity: 1, maximumPacketSize: length)
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: compressed.data)
                compressed.packetCount = 1
                compressed.byteLength = UInt32(length)
                compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                                      mDataByteSize: UInt32(length))
                inputStatus.pointee = .haveData
                return compressed
            }
            total += Int(pcm.frameLength)
            if status == .endOfStream || status == .error || error != nil { break }
        }
        return total
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); count += 1; lock.unlock() }
    }
}

// MARK: - Tests

@Suite(.serialized)
struct TheaterEngineTests {
    @Test func matroskaRoundTripDecodesWithSystemDecoders() async throws {
        let media = try await Fixtures.encode()
        #expect(media.video.count == 45)
        #expect(!media.aac.isEmpty)
        let url = try TestMKVWriter.write(media, subtitles: [(0.2, 0.9, "Hello, theater."), (1.1, 1.4, "<i>Second</i> line")])
        defer { try? FileManager.default.removeItem(at: url) }

        let demuxer = try Demuxers.open(url)
        #expect(demuxer is MatroskaDemuxer)
        #expect(abs((demuxer.duration ?? 0) - 1.5) < 0.01)
        #expect(demuxer.chapters.first?.title == "Opening Credits")
        #expect(demuxer.chapters.first?.end == 0.5)

        let video = try #require(demuxer.tracks.first { $0.kind == .video })
        let audio = try #require(demuxer.tracks.first { $0.kind == .audio })
        let text = try #require(demuxer.tracks.first { $0.kind == .subtitle })
        #expect(video.codec == .h264 && video.width == 160 && video.height == 120)
        #expect(audio.codec == .aac && audio.language == "spa" && audio.name == "Spanish Stereo" && audio.channels == 2)
        #expect(text.codec == .textUTF8 && text.isForced)

        var packets: [MediaPacket] = []
        while let packet = try demuxer.nextPacket() { packets.append(packet) }
        let videoPackets = packets.filter { $0.trackID == video.id }
        let audioPackets = packets.filter { $0.trackID == audio.id }
        let textPackets = packets.filter { $0.trackID == text.id }

        // Every frame comes back byte-for-byte, in decode order, with its timestamp and sync flag.
        #expect(videoPackets.map(\.data) == media.video.map(\.data))
        #expect(videoPackets.map(\.isKeyframe) == media.video.map(\.isKeyframe))
        for (packet, frame) in zip(videoPackets, media.video) {
            #expect(abs(packet.pts - frame.pts) < 0.002)
        }
        // Laced audio is split back into individual AAC frames.
        #expect(audioPackets.map(\.data) == media.aac)
        #expect(textPackets.map { String(decoding: $0.data, as: UTF8.self) } == ["Hello, theater.", "<i>Second</i> line"])
        #expect(abs((textPackets.first?.duration ?? 0) - 0.7) < 0.002)

        // The system decoders accept what the formatter produces.
        let videoFormatter = try TrackFormatter(track: video)
        let videoSamples = try videoPackets.flatMap(videoFormatter.sampleBuffers)
        let videoFormat = try #require(videoFormatter.format)
        #expect(DecodeCheck.decodedFrames(videoSamples, format: videoFormat) == media.video.count)

        let audioFormatter = try TrackFormatter(track: audio)
        let audioSamples = try audioPackets.flatMap(audioFormatter.sampleBuffers)
        let audioFormat = try #require(audioFormatter.format)
        #expect(DecodeCheck.decodedAudioFrames(audioSamples, format: audioFormat) > 40_000)
    }

    @Test func matroskaSeeksToKeyframesUsingCues() async throws {
        let media = try await Fixtures.encode()
        let url = try TestMKVWriter.write(media)
        defer { try? FileManager.default.removeItem(at: url) }
        let demuxer = try Demuxers.open(url)
        demuxer.enabledTrackIDs = [1]

        let landed = try demuxer.seek(to: 1.2)
        #expect(abs(landed - 1.0) < 0.001)
        let first = try #require(try demuxer.nextPacket())
        #expect(first.isKeyframe)
        #expect(abs(first.pts - 1.0) < 0.002)
    }

    @Test func aviRoundTripConvertsAnnexBAndDecodes() async throws {
        let media = try await Fixtures.encode()
        let url = try TestAVIWriter.write(media)
        defer { try? FileManager.default.removeItem(at: url) }

        let demuxer = try Demuxers.open(url)
        #expect(demuxer is AVIDemuxer)
        let video = try #require(demuxer.tracks.first { $0.kind == .video })
        let audio = try #require(demuxer.tracks.first { $0.kind == .audio })
        #expect(video.codec == .h264 && video.isAnnexB && video.width == 160)
        #expect(audio.codec == .pcm(bits: 16, isFloat: false, isBigEndian: false) && audio.name == "Commentary")
        #expect(abs((demuxer.duration ?? 0) - 1.5) < 0.01)

        var packets: [MediaPacket] = []
        while let packet = try demuxer.nextPacket() { packets.append(packet) }
        let videoPackets = packets.filter { $0.trackID == video.id }
        let audioPackets = packets.filter { $0.trackID == audio.id }
        #expect(videoPackets.count == media.video.count)
        #expect(videoPackets.map(\.isKeyframe) == media.video.map(\.isKeyframe))
        #expect(abs((audioPackets.last?.pts ?? 0) - Double(media.video.count - 1) / 30) < 0.01)

        let formatter = try TrackFormatter(track: video)
        let samples = try videoPackets.flatMap(formatter.sampleBuffers)
        let format = try #require(formatter.format)
        #expect(DecodeCheck.decodedFrames(samples, format: format) == media.video.count)

        let landed = try demuxer.seek(to: 0.8)
        #expect(abs(landed - 0.5) < 0.001) // Keyframes every 15 frames.
    }

    @Test func displayOrderReconstruction() {
        // Decode order I0 P3 B1 B2 P6 B4 B5 → display times 0 3 1 2 6 4 5.
        var reconstructor = DisplayOrderReconstructor(frameDuration: 1, startTime: 0)
        let frames: [(String, Bool)] = [("I0", false), ("P3", false), ("B1", true), ("B2", true), ("P6", false), ("B4", true), ("B5", true)]
        var output: [MediaPacket] = []
        for (name, isB) in frames {
            output += reconstructor.push(MediaPacket(trackID: 0, pts: 0, duration: 1, isKeyframe: name.hasPrefix("I"),
                                                     data: Data(name.utf8)), isBFrame: isB)
        }
        output += reconstructor.flush()
        #expect(output.map { String(decoding: $0.data, as: UTF8.self) } == frames.map(\.0))
        #expect(output.map(\.pts) == [0, 3, 1, 2, 6, 4, 5])
    }

    @Test func audioFramerSplitsMPEGAndAC3Streams() {
        // MPEG-1 Layer III, 128 kbps, 44.1 kHz, no padding → 417-byte frames.
        let mp3Header: [UInt8] = [0xFF, 0xFB, 0x90, 0x00]
        let mp3Frame = Data(mp3Header + [UInt8](repeating: 0, count: 413))
        var framer = AudioFramer(codec: .mp3)
        let first = framer.push(mp3Frame + mp3Frame.prefix(100))
        #expect(first.count == 1 && first[0].count == 417)
        // The 100 carried-over bytes complete the second frame, plus one more whole frame.
        let rest = framer.push(mp3Frame.dropFirst(100) + mp3Frame)
        #expect(rest.count == 2 && rest.allSatisfy { $0.count == 417 })

        // AC-3, 48 kHz, frmsizecod 28 (384 kbps) → 768 words = 1536 bytes.
        #expect(AudioFramer.ac3FrameLength(fscod: 0, frmsizecod: 28) == 1536)
    }

    @Test func ebmlLacingModes() throws {
        // EBML lacing: 3 frames of 5, 7, and 4 bytes.
        var payload: [UInt8] = [2, 0x85, 0x80 + 63 + 2] // count-1, first size 5 (VINT), diff +2 (biased by 63)
        payload += [UInt8](repeating: 1, count: 5) + [UInt8](repeating: 2, count: 7) + [UInt8](repeating: 3, count: 4)
        var reader = ByteReader(payload)
        let frames = try MatroskaDemuxer.splitLaced(&reader, lacing: 3)
        #expect(frames.map(\.count) == [5, 7, 4])

        var fixed = ByteReader([1] + [UInt8](repeating: 9, count: 8))
        #expect(try MatroskaDemuxer.splitLaced(&fixed, lacing: 2).map(\.count) == [4, 4])
    }

    @Test func esdsWrapsDecoderConfiguration() {
        let config = Data([0x12, 0x10])
        let descriptor = ESDS.esDescriptor(objectType: 0x40, streamType: 0x05, decoderSpecificInfo: config)
        #expect(descriptor.first == 0x03)
        #expect(descriptor.suffix(3) == Data([0x06, 0x80, 0x80]) || descriptor.range(of: config) != nil)
        #expect(ESDS.box(objectType: 0x40, streamType: 0x05, decoderSpecificInfo: config).prefix(4) == Data([0, 0, 0, 0]))
    }
}

// MARK: - Live playback

@MainActor
@Suite(.serialized)
struct TheaterPlaybackTests {
    @Test func enginePlaysMP4InRealTime() async throws {
        let url = try await MovieFixture.write(.mp4, seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = TheaterEngine()
        await engine.load(url, start: 0, selection: nil)
        #expect(engine.failure == nil, "\(engine.failure ?? "")")
        #expect(engine.isPlaying)
        try await Task.sleep(for: .milliseconds(1200))
        #expect(engine.currentTime > 0.8 && engine.currentTime < 1.6, "clock at \(engine.currentTime)")
        engine.shutdown()
    }

    @Test func enginePlaysMatroskaInRealTime() async throws {
        let media = try await Fixtures.encode(frames: 90) // 3 seconds
        let url = try TestMKVWriter.write(media, subtitles: [(0.1, 2.5, "Forced line")])
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = TheaterEngine()
        await engine.load(url, start: 0, selection: nil)
        #expect(engine.failure == nil)
        #expect(engine.hasStarted)
        #expect(engine.isPlaying)
        #expect(abs(engine.duration - 3) < 0.05)
        #expect(engine.trackList.audio.first?.title == "Spanish — Spanish Stereo")
        #expect(engine.trackList.audio.first?.format == "AAC Stereo")
        // The forced subtitle track is picked automatically only when it matches the audio language.
        #expect(engine.selectedSubtitleID == nil)
        engine.selectSubtitle(engine.trackList.subtitles.first?.id)

        try await Task.sleep(for: .milliseconds(1200))
        #expect(engine.currentTime > 0.8 && engine.currentTime < 1.6, "clock advanced \(engine.currentTime)s")
        #expect(engine.subtitleText == "Forced line")

        engine.seek(to: 2.2)
        try await Task.sleep(for: .milliseconds(400))
        #expect(engine.currentTime >= 2.0, "seeked to \(engine.currentTime)s")

        try await Task.sleep(for: .milliseconds(1500))
        #expect(!engine.isPlaying, "stops at end of file")
        #expect(engine.failure == nil, "\(engine.failure ?? "")")
        engine.shutdown()
    }
}

// MARK: - Thumbnails

@Suite(.serialized)
struct ThumbnailTests {
    @Test func theaterThumbnailsDecodeAKeyframe() async throws {
        let media = try await Fixtures.encode(frames: 90)
        let url = try TestMKVWriter.write(media)
        defer { try? FileManager.default.removeItem(at: url) }

        let generator = ThumbnailGenerator(url: url, maximumWidth: 80)
        let image = try #require(await generator.image(at: 1.2))
        #expect(image.width == 80)
        #expect(image.height == 60) // Keeps the 4:3 aspect ratio.
        // Cached by 5-second bucket.
        let again = await generator.image(at: 2.5)
        #expect(again === image)
    }

    @Test func aviThumbnailsUseAnnexBParameterSets() async throws {
        let media = try await Fixtures.encode()
        let url = try TestAVIWriter.write(media)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = await ThumbnailGenerator(url: url, maximumWidth: 80).image(at: 0)
        #expect(image != nil)
    }
}

// MARK: - Audio timeline

struct AudioTimelineTests {
    /// Reproduces 10 Cloverfield Lane: 48 kHz AAC in Matroska with millisecond-rounded block times.
    @Test func roundedContainerTimesBecomeGapless() throws {
        var track = ContainerTrack(id: 2, kind: .audio, codec: .aac, codecID: "A_AAC")
        track.sampleRate = 48000
        track.channels = 2
        track.codecPrivate = AAC.audioSpecificConfig(sampleRate: 48000, channels: 2)
        let formatter = try TrackFormatter(track: track)
        let frame = 1024.0 / 48000

        var times: [Double] = []
        for index in 0..<500 {
            let rounded = (Double(index) * frame * 1000).rounded() / 1000 // 0, 0.021, 0.043, 0.064 …
            let packet = MediaPacket(trackID: 2, pts: rounded, duration: nil, isKeyframe: true, data: Data(repeating: 0x21, count: 8))
            times += try formatter.sampleBuffers(for: packet).map { CMSampleBufferGetPresentationTimeStamp($0).seconds }
        }
        let worst = zip(times, times.dropFirst()).map { abs(($1 - $0) - frame) }.max() ?? 1
        #expect(worst < 0.000_02, "largest deviation from a gapless timeline: \(worst * 1000) ms")

        // A real jump (e.g. after a seek) re-syncs instead of drifting.
        let jumped = try formatter.sampleBuffers(for: MediaPacket(trackID: 2, pts: 120, duration: nil, isKeyframe: true, data: Data([0x21])))
        #expect(abs(CMSampleBufferGetPresentationTimeStamp(jumped[0]).seconds - 120) < 0.001)
    }

    @Test func heAACFrameTimingUsesTheCoreRate() {
        // HE-AAC signalled with a 24 kHz core while the container says 48 kHz.
        let config = AAC.audioSpecificConfig(sampleRate: 24000, channels: 2, objectType: 5)
        #expect(AAC.coreSampleRate(fromConfig: config) == 24000)
        #expect(AAC.coreSampleRate(fromConfig: AAC.audioSpecificConfig(sampleRate: 48000, channels: 2)) == 48000)
    }

    @Test func audioClockToleratesJitterButFollowsJumps() {
        var clock = AudioClock(next: 0)
        #expect(clock.place(0, duration: 0.0213) == 0)
        #expect(clock.place(0.021, duration: 0.0213) == 0.0213)
        #expect(clock.place(5, duration: 0.0213) == 5)
    }
}

// MARK: - MP4 / MOV

nonisolated enum MovieFixture {
    /// Writes a real MP4 or MOV with AVAssetWriter: H.264 (with B-frames) and AAC.
    static func write(_ fileType: AVFileType, seconds: Double = 2, width: Int = 160, height: Int = 120,
                      fastStart: Bool = false) async throws -> URL {
        let url = Fixtures.temporaryURL(fileType == .mov ? "mov" : "mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = fastStart // Index before the media data.
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: true, AVVideoMaxKeyFrameIntervalKey: 15],
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 96000,
        ])
        audio.expectsMediaDataInRealTime = false
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else { throw writer.error ?? MediaFormatError.coreMedia(-1) }
        writer.startSession(atSourceTime: .zero)

        let rate = 44100.0
        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var audioFormat: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &audioFormat)
        guard let audioFormat else { throw MediaFormatError.coreMedia(-3) }

        /// Feeds audio up to `time`. Mid-movie it yields to video when the writer wants that
        /// first (waiting would deadlock); at the end it waits for the writer.
        func appendAudio(until time: Double, frame: inout Int, waits: Bool = false) async throws {
            while Double(frame) / rate < min(time, seconds) {
                while !audio.isReadyForMoreMediaData {
                    guard waits else { return }
                    try await Task.sleep(for: .milliseconds(2))
                }
                let count = 1024
                var samples = [Float](repeating: 0, count: count * 2)
                for i in 0..<count {
                    let value = sinf(Float(frame + i) * 2 * .pi * 440 / Float(rate)) * 0.3
                    samples[i * 2] = value
                    samples[i * 2 + 1] = value
                }
                let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
                var block: CMBlockBuffer?
                CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
                                                   customBlockSource: nil, offsetToData: 0, dataLength: data.count,
                                                   flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
                guard let block else { return }
                data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
                var sample: CMSampleBuffer?
                CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                    allocator: nil, dataBuffer: block, formatDescription: audioFormat, sampleCount: count,
                    presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(rate)),
                    packetDescriptions: nil, sampleBufferOut: &sample)
                if let sample { audio.append(sample) }
                frame += count
            }
        }

        // AVAssetWriter needs interleaved input: it stops taking video until audio catches up,
        // and the encoder holds frames back for reordering, so keep audio flowing while waiting.
        var audioFrame = 0
        for index in 0..<Int(seconds * 30) {
            try await appendAudio(until: Double(index) / 30 + 0.5, frame: &audioFrame)
            while !video.isReadyForMoreMediaData {
                if audio.isReadyForMoreMediaData, Double(audioFrame) / rate < seconds {
                    try await appendAudio(until: Double(audioFrame + 1024) / rate, frame: &audioFrame)
                } else {
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) { memset(base, Int32(index * 7 % 255), CVPixelBufferGetDataSize(buffer)) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30))
        }
        video.markAsFinished()
        try await appendAudio(until: seconds, frame: &audioFrame, waits: true)
        audio.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? MediaFormatError.coreMedia(-2) }
        return url
    }
}

@Suite(.serialized)
struct MP4DemuxerTests {
    // Separate tests rather than one parameterized test: Xcode's parallel runners can split
    // a parameterized test's cases across processes and end one before its case finishes.
    @Test func readsAndDecodesMP4WrittenByAVFoundation() async throws {
        try await readsAndDecodesMovieWrittenByAVFoundation(.mp4)
    }

    @Test func readsAndDecodesMOVWrittenByAVFoundation() async throws {
        try await readsAndDecodesMovieWrittenByAVFoundation(.mov)
    }

    private func readsAndDecodesMovieWrittenByAVFoundation(_ fileType: AVFileType) async throws {
        let url = try await MovieFixture.write(fileType)
        defer { try? FileManager.default.removeItem(at: url) }

        let demuxer = try Demuxers.open(url)
        #expect(demuxer is MP4Demuxer)
        #expect(abs((demuxer.duration ?? 0) - 2) < 0.1)
        let video = try #require(demuxer.tracks.first { $0.kind == .video })
        let audio = try #require(demuxer.tracks.first { $0.kind == .audio })
        #expect(video.codec == .h264 && video.width == 160 && video.height == 120)
        #expect(audio.codec == .aac && audio.channels == 2 && audio.sampleRate == 44100)

        var packets: [MediaPacket] = []
        while let packet = try demuxer.nextPacket() { packets.append(packet) }
        let videoPackets = packets.filter { $0.trackID == video.id }
        let audioPackets = packets.filter { $0.trackID == audio.id }
        #expect(videoPackets.count == 60)

        // The edit list maps the first displayed frame to time zero; frames land on the 1/30 s grid.
        let presented = videoPackets.map(\.pts).sorted()
        #expect(abs(presented[0]) < 0.001, "first frame at \(presented[0])")
        for (index, time) in presented.enumerated() { #expect(abs(time - Double(index) / 30) < 0.001) }
        // Real decode timestamps come through for B-frames, and never run ahead of presentation.
        #expect(videoPackets.allSatisfy { ($0.dts ?? .infinity) <= $0.pts + 0.0001 })
        #expect(videoPackets.first?.isKeyframe == true)

        let videoFormatter = try TrackFormatter(track: video)
        let videoSamples = try videoPackets.flatMap(videoFormatter.sampleBuffers)
        #expect(DecodeCheck.decodedFrames(videoSamples, format: try #require(videoFormatter.format)) == 60)

        let audioFormatter = try TrackFormatter(track: audio)
        let audioSamples = try audioPackets.flatMap(audioFormatter.sampleBuffers)
        #expect(DecodeCheck.decodedAudioFrames(audioSamples, format: try #require(audioFormatter.format)) > 80_000)

        // Seeking lands on a sync frame at or before the target.
        let landed = try demuxer.seek(to: 1.2)
        #expect(landed <= 1.2 && landed >= 0.5)
        demuxer.enabledTrackIDs = [video.id]
        #expect(try demuxer.nextPacket()?.isKeyframe == true)
    }

    @Test func neroChaptersAndTimedText() {
        // version 1, flags, 4 reserved, count 2; entries: 8-byte start (100 ns), length, title.
        var chpl: [UInt8] = [1, 0, 0, 0, 0, 0, 0, 0, 2]
        chpl += [0, 0, 0, 0, 0, 0, 0, 0, 5] + Array("Intro".utf8)
        chpl += withUnsafeBytes(of: UInt64(900_000_000).bigEndian, Array.init) + [7] + Array("Credits".utf8)
        let chapters = MP4Demuxer.neroChapters(ArraySlice(chpl))
        #expect(chapters.map(\.title) == ["Intro", "Credits"])
        #expect(chapters[1].start == 90)
        #expect(chapters[0].end == 90)
        #expect(MP4Demuxer.timedText(Data([0, 5]) + Data("Hello".utf8)) == "Hello")
        #expect(MP4Demuxer.timedText(Data([0, 0])) == nil)
        #expect(MP4Demuxer.language(packed: 0x15C7) == "eng")
    }
}
