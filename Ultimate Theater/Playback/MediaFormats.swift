//
//  MediaFormats.swift
//  Ultimate Theater
//
//  Turns container tracks and packets into Core Media format descriptions and
//  sample buffers that the system decoders (VideoToolbox / AudioToolbox) accept.
//

import Foundation
import CoreMedia
import AudioToolbox
import VideoToolbox

nonisolated enum MediaFormatError: LocalizedError {
    case unsupportedCodec(String)
    case missingConfiguration(String)
    case coreMedia(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unsupportedCodec(let name): "\(name) isn't supported yet."
        case .missingConfiguration(let name): "The \(name) stream is missing its setup data."
        case .coreMedia(let status): "Couldn't prepare the media (error \(status))."
        }
    }
}

/// Checks on container-supplied numbers before they become Core Media's fixed-width fields,
/// so a damaged header is reported instead of crashing the conversion.
nonisolated enum FormatValidation {
    /// Largest picture dimension accepted (16K).
    static let maximumDimension = 16_384
    static let maximumChannels = 64

    /// A picture dimension in Core Media's range; nil for negative or oversized values.
    static func dimension(_ value: Int) -> Int32? {
        (0...maximumDimension).contains(value) ? Int32(value) : nil
    }

    /// The channel count for an audio description: missing or zero counts as stereo/mono as before.
    static func channels(_ value: Int?) -> UInt32? {
        let channels = max(value ?? 2, 1)
        return channels <= maximumChannels ? UInt32(channels) : nil
    }

    /// A picture dimension stored as a number (FLV metadata), truncated; nil for non-finite,
    /// negative, or oversized values.
    static func dimension(_ value: Double) -> Int? {
        guard let whole = Int(exactly: value.rounded(.towardZero)), dimension(whole) != nil else { return nil }
        return whole
    }

    /// Longest duration or time accepted from a file (about 115 days); beyond it is damage.
    static let maximumDuration: Double = 1e7

    /// A usable duration in seconds: finite, non-negative, and at most `maximumDuration`.
    static func duration(_ seconds: Double?) -> Double? {
        guard let seconds, seconds.isFinite, seconds >= 0, seconds <= maximumDuration else { return nil }
        return seconds
    }

    /// A usable sample rate: finite, positive, and within a CMTimeScale.
    static func isValidSampleRate(_ rate: Double) -> Bool {
        rate.isFinite && rate >= 1 && rate <= Double(Int32.max)
    }

    /// The timescale counting one tick per sample, or nil for an unusable rate.
    static func timescale(forSampleRate rate: Double) -> CMTimeScale? {
        guard isValidSampleRate(rate) else { return nil }
        return CMTimeScale(clamping: Int(rate))
    }

    /// Frames in one ADPCM block. IMA blocks hold one header sample per channel plus two
    /// per byte after the 4-byte channel headers; Microsoft ADPCM two header samples plus two
    /// per byte after 7-byte headers. A declared `samplesPerBlock` wins when it's positive.
    static func adpcmFramesPerPacket(isIMA: Bool, blockAlign: Int, channels: Int, samplesPerBlock: Int?) -> UInt32? {
        guard blockAlign > 0, channels > 0 else { return nil }
        if let samplesPerBlock, samplesPerBlock > 0 { return UInt32(exactly: samplesPerBlock) }
        let header = (isIMA ? 4 : 7) * channels
        guard blockAlign >= header else { return nil }
        let frames = (blockAlign - header) * 2 / channels + (isIMA ? 1 : 2)
        return UInt32(exactly: frames)
    }
}

/// A gapless audio timeline. Each buffer starts exactly where the previous one ended,
/// unless the container's time jumps by more than `tolerance` (a seek, splice, or real gap).
nonisolated struct AudioClock {
    var next: Double
    var tolerance = 0.25

    mutating func place(_ containerTime: Double, duration: Double) -> Double {
        let time = abs(containerTime - next) <= tolerance ? next : containerTime
        next = time + duration
        return time
    }
}

/// Per-track conversion state: the format description plus any stream rewriting.
nonisolated final class TrackFormatter {
    let track: ContainerTrack
    private(set) var format: CMFormatDescription?
    private var framer: AudioFramer?
    /// Vorbis packet durations depend on the previous packet's block size.
    private var vorbis: VorbisParser?
    /// Sample-accurate audio timeline (see `continuousTime`).
    private var audioClock: AudioClock?
    /// VP8 and Theora have no system decoder: frames are decoded here into pixel buffers.
    private var softwareVideo: (any SoftwareVideoDecoder)?
    /// DTS has no system decoder: frames are decoded here and passed on as float PCM.
    private var dtsFramer: DTSFramer?
    private var dtsDecoder: DTSCoreDecoder?
    private var dtsLayout: (speakers: [DTSCoreDecoder.Speaker], sampleRate: Double)?
    /// TrueHD has no system decoder either: lossless decoding to float PCM here.
    private var trueHDFramer: TrueHDFramer?
    private var trueHDDecoder: TrueHDDecoder?
    private var trueHDLayout: (speakers: [TrueHDDecoder.Speaker], sampleRate: Double)?
    /// MPEG-4 Part 2 is decoded here too (VideoToolbox can't decode B-VOPs or Advanced Simple
    /// Profile). Pictures come out in display order; they take the input times in sorted order.
    private var mpeg4Decoder: MPEG4Decoder?
    private var pendingTimes: [Double] = []
    /// True when video payloads must be rewritten from start codes to length prefixes.
    private var convertsAnnexB = false

    init(track: ContainerTrack) throws {
        self.track = track
        guard track.codec.isSupported else { throw MediaFormatError.unsupportedCodec(track.codec.displayName) }
        switch track.kind {
        case .video:
            if track.codec == .vp8 {
                softwareVideo = VP8Decoder()
                break
            }
            if track.codec == .mpeg4Part2 {
                mpeg4Decoder = MPEG4Decoder(configuration: track.codecPrivate)
                break
            }
            if track.codec == .theora {
                guard let headers = track.codecPrivate.flatMap(VorbisParser.unlace), let decoder = TheoraDecoder(headers: headers) else {
                    throw MediaFormatError.missingConfiguration("Theora")
                }
                softwareVideo = decoder
                break
            }
            convertsAnnexB = track.isAnnexB && !Self.hasConfigurationRecord(track)
            // Start-code streams (and MPEG-4 without a stored VOL) carry their setup in the
            // first keyframe, so those formats are built lazily in `sampleBuffers`.
            if track.codec == .vp9 {
                // VP9 decodes through VideoToolbox's supplemental decoder, registered on demand.
                VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
            }
            let needsKeyframe = convertsAnnexB
                || (track.codec == .mpeg4Part2 && track.codecPrivate == nil)
                || (track.codec == .vp9 && track.codecPrivate == nil)
                || ([.mpeg1Video, .mpeg2Video].contains(track.codec) && (track.width ?? 0) == 0)
            if !needsKeyframe {
                format = try Self.videoFormat(for: track, keyframe: nil)
            }
        case .audio:
            if track.codec == .dts {
                // The PCM format follows the first decoded frame's channel arrangement.
                dtsFramer = DTSFramer()
                dtsDecoder = DTSCoreDecoder()
                break
            }
            if track.codec == .trueHD {
                trueHDFramer = TrueHDFramer()
                trueHDDecoder = TrueHDDecoder()
                break
            }
            format = try Self.audioFormat(for: track, firstPacket: nil)
            if track.needsFraming, [.mp3, .mp2, .ac3, .eac3, .aac].contains(track.codec) {
                framer = AudioFramer(codec: track.codec, verifiesFrames: track.verifiesFrames)
            }
            if track.codec == .vorbis { vorbis = track.codecPrivate.flatMap { VorbisParser(xiphLaced: $0) } }
        case .subtitle:
            break
        }
    }

    /// Resets per-stream state after a seek.
    func reset() {
        framer?.reset()
        vorbis?.reset()
        dtsFramer?.reset()
        softwareVideo?.reset()
        trueHDFramer?.reset()
        trueHDDecoder?.reset()
        mpeg4Decoder?.reset()
        pendingTimes.removeAll()
        dtsDecoder?.reset()
        audioClock = nil
    }

    /// Seconds per compressed audio frame. For AAC this uses the core sampling rate from
    /// the AudioSpecificConfig, which stays correct for HE-AAC when a container declares
    /// the doubled output rate.
    private var audioFrameDuration: Double? {
        guard let samples = track.codec.samplesPerFrame else { return nil }
        if track.codec == .aac, let config = track.codecPrivate, let coreRate = AAC.coreSampleRate(fromConfig: config) {
            return Double(samples) / coreRate
        }
        return track.sampleRate.map { Double(samples) / $0 }
    }

    /// Containers round timestamps (Matroska usually to the millisecond), so consecutive
    /// audio frames appear 21 or 22 ms apart instead of exactly 21.333 ms. Feeding those to
    /// the audio renderer makes it insert or drop samples at every frame, which is heard as
    /// crackling and makes the shared playback clock jitter. Audio therefore runs on its own
    /// continuous clock, re-syncing to the container only on a real jump.
    private func continuousTime(_ containerTime: Double, duration: Double) -> Double {
        var clock = audioClock ?? AudioClock(next: containerTime)
        let time = clock.place(containerTime, duration: duration)
        audioClock = clock
        return time
    }

    /// Converts a packet into zero or more sample buffers.
    func sampleBuffers(for packet: MediaPacket) throws -> [CMSampleBuffer] {
        switch track.kind {
        case .video:
            if let mpeg4Decoder { return try decodedMPEG4(packet, decoder: mpeg4Decoder) }
            if let softwareVideo {
                // A damaged frame is skipped; the decoder resumes at the next keyframe.
                guard let picture = try? softwareVideo.decode(packet.data) else { return [] }
                let sample = try picture.sampleBuffer(pts: packet.pts, duration: packet.duration ?? track.frameDuration)
                format = CMSampleBufferGetFormatDescription(sample)
                return [sample]
            }
            var data = packet.data
            if convertsAnnexB {
                if format == nil {
                    guard packet.isKeyframe else { return [] }
                    format = try Self.videoFormat(for: track, keyframe: packet.data)
                }
                // Parameter sets travel in the format description; drop them and access delimiters.
                data = AnnexB.lengthPrefixed(packet.data, dropping: track.codec == .hevc ? [32, 33, 34, 35] : [7, 8, 9],
                                             isHEVC: track.codec == .hevc)
            } else if format == nil {
                guard packet.isKeyframe else { return [] }
                format = try Self.videoFormat(for: track, keyframe: packet.data)
            }
            guard let format, !data.isEmpty else { return [] }
            return [try Self.videoSample(data, format: format, packet: packet)]

        case .audio:
            if let dtsDecoder { return try decodedDTS(packet, decoder: dtsDecoder) }
            if let trueHDDecoder { return try decodedTrueHD(packet, decoder: trueHDDecoder) }
            guard let format else { return [] }
            if var framer {
                // Chunks don't align to frames: the chunk time anchors the first frame only.
                let frames = framer.push(packet.data)
                self.framer = framer
                let step = audioFrameDuration ?? 1152.0 / (track.sampleRate ?? 48000)
                return try frames.enumerated().map { index, frame in
                    let time = index == 0 ? continuousTime(packet.pts, duration: step)
                                          : continuousTime(audioClock?.next ?? packet.pts, duration: step)
                    let payload = track.codec == .aac ? frame.dropFirst(AAC.adtsHeader(frame)?.headerLength ?? 0) : frame
                    return try Self.compressedAudioSample(Data(payload), format: format, pts: time)
                }
            }
            let sampleRate = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mSampleRate ?? (track.sampleRate ?? 48000)
            switch track.codec {
            case .pcm, .muLaw, .aLaw:
                // One byte-aligned frame per packet: sent as plain frames, like PCM.
                let bytesPerFrame = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mBytesPerFrame ?? 0
                let frames = bytesPerFrame > 0 ? packet.data.count / Int(bytesPerFrame) : 0
                let duration = Double(frames) / (track.sampleRate ?? 48000)
                return [try Self.pcmSample(packet.data, format: format, pts: continuousTime(packet.pts, duration: duration))]
            case .flac, .opus:
                // Variable-length packets: the frame count comes from each packet's own header.
                let frames = track.codec == .opus
                    ? Opus.packetDuration(packet.data)
                    : FLAC.blockSize(ofFrame: packet.data, streamInfo: track.codecPrivate.flatMap(FLAC.streamInfo))
                let duration = frames.map { Double($0) / sampleRate } ?? packet.duration ?? 0
                return [try Self.compressedAudioSample(packets: [packet.data], variableFrames: frames.map { [$0] },
                                                       format: format, pts: continuousTime(packet.pts, duration: duration))]
            case .amrNB, .amrWB:
                let frames = AMR.frames(in: packet.data, wideband: track.codec == .amrWB)
                guard !frames.isEmpty else { return [] }
                let duration = Double(frames.count * (track.codec.samplesPerFrame ?? 160)) / sampleRate
                return [try Self.compressedAudioSample(packets: frames, variableFrames: nil, format: format,
                                                       pts: continuousTime(packet.pts, duration: duration))]
            case .adpcmIMA, .adpcmMS, .appleIMA4:
                // Constant-size packets: split the chunk into whole packets.
                guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee, asbd.mBytesPerPacket > 0 else { return [] }
                let size = Int(asbd.mBytesPerPacket)
                let count = packet.data.count / size
                guard count > 0 else { return [] }
                let packets = (0..<count).map { packet.data.subdata(in: (packet.data.startIndex + $0 * size)..<(packet.data.startIndex + ($0 + 1) * size)) }
                let duration = Double(count) * Double(asbd.mFramesPerPacket) / sampleRate
                return [try Self.compressedAudioSample(packets: packets, variableFrames: nil, format: format,
                                                       pts: continuousTime(packet.pts, duration: duration))]
            case .vorbis:
                let frames = vorbis?.duration(of: packet.data)
                let duration = frames.map { Double($0) / sampleRate } ?? packet.duration ?? 0
                return [try Self.compressedAudioSample(packets: [packet.data], variableFrames: frames.map { [$0] }, format: format,
                                                       pts: continuousTime(packet.pts, duration: duration))]
            default:
                break
            }
            var data = packet.data
            if track.codec == .aac, let adts = AAC.adtsHeader(data), adts.frameLength == data.count {
                data = data.dropFirst(adts.headerLength)
            }
            let step = audioFrameDuration ?? packet.duration ?? 0
            return [try Self.compressedAudioSample(Data(data), format: format, pts: continuousTime(packet.pts, duration: step))]

        case .subtitle:
            return []
        }
    }

    /// Decodes TrueHD access units to float PCM buffers.
    private func decodedTrueHD(_ packet: MediaPacket, decoder: TrueHDDecoder) throws -> [CMSampleBuffer] {
        guard var framer = trueHDFramer else { return [] }
        let units = framer.push(packet.data)
        trueHDFramer = framer
        var buffers: [CMSampleBuffer] = []
        for (index, unit) in units.enumerated() {
            guard let output = decoder.decode(unit), output.frameCount > 0 else { continue }
            if format == nil || trueHDLayout?.speakers != output.channels || trueHDLayout?.sampleRate != output.sampleRate {
                format = try Self.floatPCMFormat(sampleRate: output.sampleRate, labels: output.channels.map(\.channelLabel))
                trueHDLayout = (output.channels, output.sampleRate)
            }
            guard let format else { continue }
            let duration = Double(output.frameCount) / output.sampleRate
            let time = index == 0 ? continuousTime(packet.pts, duration: duration)
                                  : continuousTime(audioClock?.next ?? packet.pts, duration: duration)
            let data = output.samples.withUnsafeBytes { Data($0) }
            buffers.append(try Self.pcmSample(data, format: format, pts: time))
        }
        return buffers
    }

    /// Decodes an MPEG-4 Part 2 frame (or DivX packed pair) into display-order pictures.
    private func decodedMPEG4(_ packet: MediaPacket, decoder: MPEG4Decoder) throws -> [CMSampleBuffer] {
        // Each container frame is one display slot (AVI placeholders included), so the
        // pictures take the packets' times in ascending order.
        pendingTimes.append(packet.pts)
        pendingTimes.sort()
        if pendingTimes.count > 16 { pendingTimes.removeFirst(pendingTimes.count - 16) }
        guard let pictures = try? decoder.decode(packet.data) else { return [] }
        return try pictureSamples(pictures)
    }

    private func pictureSamples(_ pictures: [DecodedPicture]) throws -> [CMSampleBuffer] {
        try pictures.compactMap { picture in
            guard !pendingTimes.isEmpty else { return nil }
            let time = pendingTimes.removeFirst()
            let sample = try picture.sampleBuffer(pts: time, duration: track.frameDuration)
            format = CMSampleBufferGetFormatDescription(sample)
            return sample
        }
    }

    /// Decodes the DTS frames in a packet (or byte-stream chunk) to float PCM buffers.
    private func decodedDTS(_ packet: MediaPacket, decoder: DTSCoreDecoder) throws -> [CMSampleBuffer] {
        guard var framer = dtsFramer else { return [] }
        let frames = framer.push(packet.data)
        dtsFramer = framer
        var buffers: [CMSampleBuffer] = []
        for (index, frame) in frames.enumerated() {
            guard let output = decoder.decode(frame) else { continue }
            if format == nil || dtsLayout?.speakers != output.channels || dtsLayout?.sampleRate != output.sampleRate {
                format = try Self.floatPCMFormat(sampleRate: output.sampleRate, speakers: output.channels)
                dtsLayout = (output.channels, output.sampleRate)
            }
            guard let format else { continue }
            let duration = Double(output.frameCount) / output.sampleRate
            let time = index == 0 ? continuousTime(packet.pts, duration: duration)
                                  : continuousTime(audioClock?.next ?? packet.pts, duration: duration)
            let data = output.samples.withUnsafeBytes { Data($0) }
            buffers.append(try Self.pcmSample(data, format: format, pts: time))
        }
        return buffers
    }

    // MARK: Video formats

    private static func hasConfigurationRecord(_ track: ContainerTrack) -> Bool {
        // avcC / hvcC records start with configurationVersion = 1.
        track.codecPrivate?.first == 1
    }

    static func videoFormat(for track: ContainerTrack, keyframe: Data?) throws -> CMFormatDescription {
        let width = track.width ?? 0
        let height = track.height ?? 0
        switch track.codec {
        case .h264:
            if hasConfigurationRecord(track), let avcC = track.codecPrivate {
                return try atomFormat(kCMVideoCodecType_H264, width, height, track.extraAtoms.merging(["avcC": avcC]) { $1 })
            }
            guard let keyframe, let sets = AnnexB.h264ParameterSets(in: keyframe) else {
                throw MediaFormatError.missingConfiguration("H.264")
            }
            return try parameterSetFormat([sets.sps, sets.pps], hevc: false)
        case .hevc:
            if hasConfigurationRecord(track), let hvcC = track.codecPrivate {
                // Dolby Vision keeps its configuration so the system can render it; other HEVC
                // (including HDR10 and HLG) is plain hvc1 with its color atoms.
                let isDolbyVision = track.hdr == .dolbyVision && (track.extraAtoms["dvcC"] != nil || track.extraAtoms["dvvC"] != nil)
                return try atomFormat(isDolbyVision ? kCMVideoCodecType_DolbyVisionHEVC : kCMVideoCodecType_HEVC, width, height,
                                      track.extraAtoms.merging(["hvcC": hvcC]) { $1 })
            }
            guard let keyframe, let sets = AnnexB.hevcParameterSets(in: keyframe) else {
                throw MediaFormatError.missingConfiguration("HEVC")
            }
            return try parameterSetFormat(sets, hevc: true)
        case .av1:
            guard let av1C = track.codecPrivate else { throw MediaFormatError.missingConfiguration("AV1") }
            return try atomFormat(kCMVideoCodecType_AV1, width, height, track.extraAtoms.merging(["av1C": av1C]) { $1 })
        case .mpeg4Part2:
            guard let config = track.codecPrivate ?? keyframe.flatMap(MPEG4Part2.configuration(in:)) else {
                throw MediaFormatError.missingConfiguration("MPEG-4")
            }
            let esds = ESDS.box(objectType: 0x20, streamType: 0x04, decoderSpecificInfo: config)
            return try atomFormat(kCMVideoCodecType_MPEG4Video, width, height, track.extraAtoms.merging(["esds": esds]) { $1 })
        case .vp9:
            guard var config = track.codecPrivate ?? keyframe.flatMap({ VP9.configuration(fromKeyframe: $0, width: width, height: height) }),
                  config.count >= 12 else {
                throw MediaFormatError.missingConfiguration("VP9")
            }
            // Containers know about HDR transfer functions that the VP9 header can't express.
            if config.first == 1, let hdr = track.hdr {
                config[config.startIndex + 8] = hdr == .hlg ? 18 : 16
            }
            return try atomFormat(kCMVideoCodecType_VP9, width, height, track.extraAtoms.merging(["vpcC": config]) { $1 })
        case .mpeg1Video, .mpeg2Video, .h263:
            var size = (width: width, height: height)
            if size.width == 0, let found = (keyframe ?? track.codecPrivate).flatMap(MPEGVideo.dimensions(in:)) { size = found }
            let codec: CMVideoCodecType = switch track.codec {
            case .mpeg1Video: kCMVideoCodecType_MPEG1Video
            case .mpeg2Video: kCMVideoCodecType_MPEG2Video
            default: kCMVideoCodecType_H263
            }
            return try atomFormat(codec, size.width, size.height, track.extraAtoms)
        case .mjpeg:
            return try atomFormat(kCMVideoCodecType_JPEG, width, height, track.extraAtoms)
        case .prores(let fourCC), .dv(let fourCC):
            return try atomFormat(CMVideoCodecType(fourCC), width, height, track.extraAtoms)
        default:
            throw MediaFormatError.unsupportedCodec(track.codec.displayName)
        }
    }

    private static func atomFormat(_ codec: CMVideoCodecType, _ width: Int, _ height: Int,
                                   _ atoms: [String: Data]) throws -> CMFormatDescription {
        var extensions: [CFString: Any] = [:]
        if !atoms.isEmpty {
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = atoms.mapValues { $0 as NSData }
        }
        var description: CMFormatDescription?
        guard let codedWidth = FormatValidation.dimension(width), let codedHeight = FormatValidation.dimension(height) else {
            throw MediaFormatError.unsupportedCodec("\(width)×\(height) video")
        }
        let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: codec,
                                                    width: codedWidth, height: codedHeight,
                                                    extensions: extensions.isEmpty ? nil : extensions as CFDictionary,
                                                    formatDescriptionOut: &description)
        guard status == noErr, let description else { throw MediaFormatError.coreMedia(status) }
        return description
    }

    private static func parameterSetFormat(_ sets: [Data], hevc: Bool) throws -> CMFormatDescription {
        let buffers = sets.map { data -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
            data.copyBytes(to: pointer, count: data.count)
            return pointer
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        var description: CMFormatDescription?
        let status = pointers.withUnsafeBufferPointer { pointerList in
            sizes.withUnsafeBufferPointer { sizeList in
                hevc
                    ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                        parameterSetPointers: pointerList.baseAddress!, parameterSetSizes: sizeList.baseAddress!,
                        nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
                    : CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                        parameterSetPointers: pointerList.baseAddress!, parameterSetSizes: sizeList.baseAddress!,
                        nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let description else { throw MediaFormatError.coreMedia(status) }
        return description
    }

    // MARK: Audio formats

    static func audioFormat(for track: ContainerTrack, firstPacket: Data?) throws -> CMFormatDescription {
        let sampleRate = track.sampleRate ?? 48000
        guard let channels = FormatValidation.channels(track.channels) else {
            throw MediaFormatError.missingConfiguration(track.codec.displayName)
        }
        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: 0, mFormatFlags: 0,
                                               mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0,
                                               mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
        var cookie: Data?
        switch track.codec {
        case .aac:
            asbd.mFormatID = kAudioFormatMPEG4AAC
            asbd.mFramesPerPacket = 1024
            let config = track.codecPrivate.flatMap { $0.isEmpty ? nil : $0 }
                ?? AAC.audioSpecificConfig(sampleRate: sampleRate, channels: Int(channels),
                                           objectType: track.codecID.contains("SBR") ? 5 : 2)
            cookie = ESDS.esDescriptor(objectType: 0x40, streamType: 0x05, decoderSpecificInfo: config)
        case .ac3:
            asbd.mFormatID = kAudioFormatAC3
            asbd.mFramesPerPacket = 1536
        case .eac3:
            asbd.mFormatID = kAudioFormatEnhancedAC3
            asbd.mFramesPerPacket = 1536
        case .alac:
            guard let config = track.codecPrivate, config.count >= 24 else { throw MediaFormatError.missingConfiguration("Apple Lossless") }
            asbd.mFormatID = kAudioFormatAppleLossless
            asbd.mFramesPerPacket = UInt32(config.prefix(4).bigEndianUInt)
            asbd.mFormatFlags = switch track.bitDepth ?? Int(config[config.startIndex + 5]) {
            case 20: kAppleLosslessFormatFlag_20BitSourceData
            case 24: kAppleLosslessFormatFlag_24BitSourceData
            case 32: kAppleLosslessFormatFlag_32BitSourceData
            default: kAppleLosslessFormatFlag_16BitSourceData
            }
            cookie = config
        case .flac:
            guard let config = track.codecPrivate, let info = FLAC.streamInfo(in: config), let flacCookie = FLAC.cookie(from: config) else {
                throw MediaFormatError.missingConfiguration("FLAC")
            }
            asbd.mFormatID = kAudioFormatFLAC
            asbd.mSampleRate = info.sampleRate
            asbd.mChannelsPerFrame = UInt32(info.channels)
            asbd.mFramesPerPacket = info.minBlockSize == info.maxBlockSize ? UInt32(info.maxBlockSize) : 0
            asbd.mFormatFlags = switch info.bitsPerSample {
            case 20: kAppleLosslessFormatFlag_20BitSourceData
            case 24: kAppleLosslessFormatFlag_24BitSourceData
            case 32: kAppleLosslessFormatFlag_32BitSourceData
            default: kAppleLosslessFormatFlag_16BitSourceData
            }
            cookie = flacCookie
        case .opus:
            asbd.mFormatID = kAudioFormatOpus
            asbd.mSampleRate = 48000 // Opus always decodes at 48 kHz.
        case .vorbis:
            guard let config = track.codecPrivate else { throw MediaFormatError.missingConfiguration("Vorbis") }
            asbd.mFormatID = 0x766F_7262 // 'vorb'
            cookie = config
        case .adpcmIMA, .adpcmMS:
            guard let blockAlign = track.blockAlign, let bytesPerPacket = UInt32(exactly: blockAlign),
                  let frames = FormatValidation.adpcmFramesPerPacket(isIMA: track.codec == .adpcmIMA, blockAlign: blockAlign,
                                                                      channels: Int(channels), samplesPerBlock: track.samplesPerBlock) else {
                throw MediaFormatError.missingConfiguration(track.codec.displayName)
            }
            asbd.mFormatID = track.codec == .adpcmIMA ? 0x6D73_0011 : 0x6D73_0002 // 'ms\0\x11' / 'ms\0\x02'
            asbd.mBytesPerPacket = bytesPerPacket
            asbd.mFramesPerPacket = frames
            if track.codec == .adpcmMS { cookie = track.codecPrivate }
        case .appleIMA4:
            asbd.mFormatID = kAudioFormatAppleIMA4
            asbd.mBytesPerPacket = 34 * channels
            asbd.mFramesPerPacket = 64
        case .muLaw, .aLaw:
            asbd.mFormatID = track.codec == .muLaw ? kAudioFormatULaw : kAudioFormatALaw
            asbd.mBytesPerPacket = channels
            asbd.mFramesPerPacket = 1
            asbd.mBytesPerFrame = channels
            asbd.mBitsPerChannel = 8
        case .amrNB, .amrWB:
            asbd.mFormatID = track.codec == .amrNB ? kAudioFormatAMR : kAudioFormatAMR_WB
            asbd.mSampleRate = track.codec == .amrNB ? 8000 : 16000
            asbd.mChannelsPerFrame = 1
            asbd.mFramesPerPacket = track.codec == .amrNB ? 160 : 320
        case .mp3:
            asbd.mFormatID = kAudioFormatMPEGLayer3
            asbd.mFramesPerPacket = 1152
        case .mp2:
            asbd.mFormatID = kAudioFormatMPEGLayer2
            asbd.mFramesPerPacket = 1152
        case .pcm(let bits, let isFloat, let isBigEndian):
            guard (8...64).contains(bits) else { throw MediaFormatError.unsupportedCodec("\(bits)-bit PCM") }
            asbd.mFormatID = kAudioFormatLinearPCM
            asbd.mFormatFlags = kAudioFormatFlagIsPacked
                | (isFloat ? kAudioFormatFlagIsFloat : (bits > 8 ? kAudioFormatFlagIsSignedInteger : 0))
                | (isBigEndian ? kAudioFormatFlagIsBigEndian : 0)
            asbd.mBitsPerChannel = UInt32(bits)
            asbd.mBytesPerFrame = channels * UInt32(bits / 8)
            asbd.mBytesPerPacket = asbd.mBytesPerFrame
            asbd.mFramesPerPacket = 1
        default:
            throw MediaFormatError.unsupportedCodec(track.codec.displayName)
        }
        // Some codecs take their rate from the stream setup rather than the container.
        guard FormatValidation.isValidSampleRate(asbd.mSampleRate) else {
            throw MediaFormatError.missingConfiguration(track.codec.displayName)
        }

        var description: CMFormatDescription?
        let status: OSStatus
        if let cookie {
            status = cookie.withUnsafeBytes { bytes in
                CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                               magicCookieSize: cookie.count, magicCookie: bytes.baseAddress,
                                               extensions: nil, formatDescriptionOut: &description)
            }
        } else {
            status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                                    magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                                    formatDescriptionOut: &description)
        }
        guard status == noErr, let description else { throw MediaFormatError.coreMedia(status) }
        return description
    }

    /// Interleaved 32-bit float PCM with an explicit speaker layout.
    static func floatPCMFormat(sampleRate: Double, speakers: [DTSCoreDecoder.Speaker]) throws -> CMFormatDescription {
        let labels: [AudioChannelLabel] = speakers.map { speaker in
            switch speaker {
            case .left: kAudioChannelLabel_Left
            case .right: kAudioChannelLabel_Right
            case .center: kAudioChannelLabel_Center
            case .lfe: kAudioChannelLabel_LFEScreen
            case .leftSurround: kAudioChannelLabel_LeftSurround
            case .rightSurround: kAudioChannelLabel_RightSurround
            case .surround: kAudioChannelLabel_CenterSurround
            }
        }
        return try floatPCMFormat(sampleRate: sampleRate, labels: labels)
    }

    /// Interleaved 32-bit float PCM whose channels carry these speaker labels, in order.
    static func floatPCMFormat(sampleRate: Double, labels: [AudioChannelLabel]) throws -> CMFormatDescription {
        let channels = UInt32(labels.count)
        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
                                               mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        // AudioChannelLayout ends in a variable-length array of channel descriptions.
        let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions) ?? 12
        let size = offset + labels.count * MemoryLayout<AudioChannelDescription>.stride
        let storage = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let layout = storage.bindMemory(to: AudioChannelLayout.self, capacity: 1)
        layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
        layout.pointee.mNumberChannelDescriptions = channels
        let descriptions = (storage + offset).bindMemory(to: AudioChannelDescription.self, capacity: labels.count)
        for (index, label) in labels.enumerated() {
            descriptions[index] = AudioChannelDescription(mChannelLabel: label, mChannelFlags: [], mCoordinates: (0, 0, 0))
        }
        var description: CMFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: size, layout: layout,
                                                    magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                                    formatDescriptionOut: &description)
        guard status == noErr, let description else { throw MediaFormatError.coreMedia(status) }
        return description
    }

    // MARK: Sample buffers

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 90_000)
    }

    private static func blockBuffer(_ data: Data) throws -> CMBlockBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block)
        guard status == noErr, let block else { throw MediaFormatError.coreMedia(status) }
        status = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: data.count)
        }
        guard status == noErr else { throw MediaFormatError.coreMedia(status) }
        return block
    }

    static func videoSample(_ data: Data, format: CMFormatDescription, packet: MediaPacket) throws -> CMSampleBuffer {
        let block = try blockBuffer(data)
        var timing = CMSampleTimingInfo(duration: packet.duration.map(time) ?? .invalid,
                                        presentationTimeStamp: time(packet.pts),
                                        decodeTimeStamp: packet.dts.map(time) ?? .invalid)
        var size = data.count
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                               sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                               sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw MediaFormatError.coreMedia(status) }
        if !packet.isKeyframe, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    static func compressedAudioSample(_ data: Data, format: CMFormatDescription, pts: Double) throws -> CMSampleBuffer {
        try compressedAudioSample(packets: [data], variableFrames: nil, format: format, pts: pts)
    }

    /// One sample buffer holding consecutive compressed packets. `variableFrames` gives each
    /// packet's frame count for codecs whose packets vary in length (Opus, FLAC).
    static func compressedAudioSample(packets: [Data], variableFrames: [Int]?, format: CMFormatDescription,
                                      pts: Double) throws -> CMSampleBuffer {
        var data = Data()
        var descriptions: [AudioStreamPacketDescription] = []
        for (index, packet) in packets.enumerated() {
            descriptions.append(AudioStreamPacketDescription(
                mStartOffset: Int64(data.count),
                mVariableFramesInPacket: UInt32(clamping: variableFrames.map { index < $0.count ? $0[index] : 0 } ?? 0),
                mDataByteSize: UInt32(clamping: packet.count)))
            data.append(packet)
        }
        let block = try blockBuffer(data)
        var sample: CMSampleBuffer?
        let status = descriptions.withUnsafeBufferPointer { list in
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: packets.count,
                presentationTimeStamp: time(pts), packetDescriptions: list.baseAddress, sampleBufferOut: &sample)
        }
        guard status == noErr, let sample else { throw MediaFormatError.coreMedia(status) }
        return sample
    }

    static func pcmSample(_ data: Data, format: CMFormatDescription, pts: Double) throws -> CMSampleBuffer {
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee, asbd.mBytesPerFrame > 0,
              let timescale = FormatValidation.timescale(forSampleRate: asbd.mSampleRate) else {
            throw MediaFormatError.coreMedia(-1)
        }
        let frames = data.count / Int(asbd.mBytesPerFrame)
        let block = try blockBuffer(data.prefix(frames * Int(asbd.mBytesPerFrame)))
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: timescale),
                                        presentationTimeStamp: time(pts), decodeTimeStamp: .invalid)
        var size = Int(asbd.mBytesPerFrame)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                               sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                               sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw MediaFormatError.coreMedia(status) }
        return sample
    }
}
