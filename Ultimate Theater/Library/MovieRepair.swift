//
//  MovieRepair.swift
//  Ultimate Theater
//
//  Rebuilds MP4/MOV files whose index ('moov' box) was never written, usually because a
//  copy or encode was interrupted. The media data is intact but nothing describes it, so:
//
//   1. A healthy reference file made by the same encoder with the same settings supplies
//      the decoder setup (H.264 parameter sets and the AAC configuration).
//   2. The raw media data is walked: H.264 units are recognized by their length prefixes
//      and headers and grouped into frames; AAC frames have no length markers, so each
//      one's size is found by asking the system AAC decoder for the shortest prefix it
//      decodes (shorter prefixes fail, the exact length and anything longer succeed).
//   3. Display order comes from each frame's picture order count, timing from the frame
//      rate (cross-checked against the audio length), and a new index is appended to a
//      copy of the file.
//

import Foundation
import AudioToolbox
import CoreMedia
import VideoToolbox
import os

nonisolated enum MovieRepairError: LocalizedError {
    case notDamaged
    case noMediaData
    case unsupportedReference(String)
    case noMatchingReference
    case nothingRecovered

    var errorDescription: String? {
        switch self {
        case .notDamaged: "This file isn't missing its index, so it doesn't need repair."
        case .noMediaData: "The file has no media data to recover."
        case .unsupportedReference(let reason): "The reference file can't be used: \(reason)."
        case .noMatchingReference:
            "No movie in your library was made with the same encoder settings, so the missing setup information can't be recovered. Add another movie from the same source and try again."
        case .nothingRecovered: "No video frames could be recovered from this file."
        }
    }
}

/// What a repair found.
nonisolated struct MovieRepairReport: Sendable {
    let referenceName: String
    let videoFrames: Int
    let keyframes: Int
    let audioFrames: [Int]
    let duration: Double
    let frameRate: Double
    /// Bytes that couldn't be identified as video or audio (usually a cut-off ending).
    let unrecoveredBytes: Int64
}

// Its stored state is immutable except the source's read cache; a repair uses it from one
// task at a time (diagnose, then analyze, then write), never concurrently.
nonisolated final class MovieRepairer: @unchecked Sendable {
    /// Video and audio samples found in the damaged file, in file order.
    struct Analysis {
        var videoSamples: [(offset: UInt64, size: Int, isKeyframe: Bool, order: Int64)] = []
        /// Audio frames by family, in file order, with where each run between video chunks starts.
        var audio: [AudioFamily: AudioStream] = [:]
        var unrecoveredBytes: Int64 = 0
    }

    struct AudioStream {
        var frames: [(offset: UInt64, size: Int)] = []
        var runStarts: [Int] = []
    }

    let damagedURL: URL
    private let source: FileByteSource
    private let mediaData: Range<UInt64>
    private let ftyp: Data

    init(damaged url: URL) throws {
        damagedURL = url
        source = try FileByteSource(url: url)
        var offset: UInt64 = 0
        var media: Range<UInt64>?
        var ftyp = Data()
        while offset + 8 <= source.size {
            let header = try source.read(at: offset, count: 16)
            var size = UInt64(header.prefix(4).bigEndianUInt)
            let type = String(decoding: header[4..<8], as: UTF8.self)
            var headerLength: UInt64 = 8
            if size == 1, header.count >= 16 { size = UInt64(header[8..<16].bigEndianUInt); headerLength = 16 }
            if size == 0 || size > source.size - offset { size = source.size - offset } // Runs to the end (or was cut off).
            guard size >= headerLength else { break }
            if type == "moov" { throw MovieRepairError.notDamaged }
            if type == "ftyp" { ftyp = try source.read(at: offset, count: Int(size)) }
            if type == "mdat", media == nil { media = (offset + headerLength)..<(offset + size) }
            offset += size
        }
        guard let media, !media.isEmpty else { throw MovieRepairError.noMediaData }
        mediaData = media
        self.ftyp = ftyp
    }

    // MARK: Reference selection

    /// The x264 settings string from the start of the media data, when the encoder was x264.
    var encoderSettings: String? {
        (try? source.read(at: mediaData.lowerBound, count: 4096)).flatMap(Self.x264Settings)
    }

    static func x264Settings(in data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: "x264 - core ") else { return nil }
        let rest = text[range.lowerBound...]
        return rest.split(separator: "\0", maxSplits: 1).first.map(String.init)
    }

    /// The x264 settings of a healthy file, read from its first video frame.
    static func encoderSettings(ofHealthy url: URL) -> String? {
        guard let demuxer = try? Demuxers.open(url) as? MP4Demuxer,
              let video = demuxer.tracks.first(where: { $0.kind == .video && $0.codec == .h264 }) else { return nil }
        demuxer.enabledTrackIDs = [video.id]
        return (try? demuxer.nextPacket()).flatMap { $0.map { x264Settings(in: $0.data) } } ?? nil
    }

    /// Whether the reference's decoder setup decodes this file's first frames cleanly.
    func isCompatible(with reference: RepairReference) -> Bool {
        guard let opening = try? analyze(with: reference, stoppingAfter: 12, progress: { _ in }) else { return false }
        let frames = opening.videoSamples.compactMap { try? source.read(at: $0.offset, count: $0.size) }
        return !frames.isEmpty && Self.decodes(frames, format: reference.videoFormat)
    }

    /// The first candidate that can supply this file's decoder setup: same encoder settings,
    /// adjusted to the picture size that decodes this file's frames cleanly.
    func matchingReference(from candidates: [URL], progress: (String) -> Void = { _ in }) -> RepairReference? {
        let settings = encoderSettings
        for url in candidates where url.standardizedFileURL != damagedURL.standardizedFileURL {
            guard Self.encoderSettings(ofHealthy: url) == settings, let reference = try? RepairReference(url: url) else { continue }
            progress("Checking \(url.deletingPathExtension().lastPathComponent)…")
            if isCompatible(with: reference) { return reference }
            if let resized = searchPictureSize(reference) { return resized }
        }
        return nil
    }

    /// Picture sizes differ between movies (each is cropped differently), and the size is part
    /// of the decoder setup. Only the right size decodes the frames without errors.
    func searchPictureSize(_ reference: RepairReference) -> RepairReference? {
        let referenceWidth = reference.macroblockSize.width
        var widths = [referenceWidth]
        for width in [120, 80, 90, 45, 240, 160, 60] where !widths.contains(width) { widths.append(width) }
        for width in widths {
            let maximumHeight = max(1, Int(Double(width) * 0.75) + 1) // Up to 4:3.
            for height in stride(from: maximumHeight, through: max(1, width / 4), by: -1) {
                if let resized = reference.resized(widthInMacroblocks: width, heightInMapUnits: height), isCompatible(with: resized) {
                    return resized
                }
            }
        }
        return nil
    }

    private static func decodes(_ frames: [Data], format: CMFormatDescription) -> Bool {
        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                           imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session) == noErr,
              let session else { return false }
        defer { VTDecompressionSessionInvalidate(session) }
        // The output handler runs on VideoToolbox's threads.
        let counts = OSAllocatedUnfairLock(initialState: (good: 0, bad: 0))
        for frame in frames {
            let packet = MediaPacket(trackID: 0, pts: 0, isKeyframe: true, data: frame)
            guard let sample = try? TrackFormatter.videoSample(frame, format: format, packet: packet) else { return false }
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                let decoded = status == noErr && image != nil
                counts.withLock { if decoded { $0.good += 1 } else { $0.bad += 1 } }
            }
            if status != noErr { counts.withLock { $0.bad += 1 } }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        let result = counts.withLock { $0 }
        return result.bad == 0 && result.good > 0
    }

    // MARK: Analysis

    /// Walks the media data. With `stoppingAfter`, only that many video frames are collected.
    func analyze(with reference: RepairReference, stoppingAfter frameLimit: Int? = nil,
                 progress: (Double) -> Void) throws -> Analysis {
        var analysis = Analysis()
        var parser = VideoUnitParser(reference: reference)
        let probe = reference.audio.contains { $0.family == .aac } ? try AACFrameProbe(reference: reference) : nil
        let hasDolby = reference.audio.contains { $0.family == .dolby }
        var position = mediaData.lowerBound
        let total = Double(mediaData.count)
        var frameStart: UInt64?
        var frameSize = 0
        var frameIsKey = false
        var frameOrder: Int64 = 0
        var sawSlice = false
        var runFamily: AudioFamily?
        var lastReport = 0.0

        func appendAudio(_ family: AudioFamily, _ length: Int) {
            var stream = analysis.audio[family] ?? AudioStream()
            if runFamily != family { stream.runStarts.append(stream.frames.count); runFamily = family }
            stream.frames.append((position, length))
            analysis.audio[family] = stream
            position += UInt64(length)
        }

        func finishFrame() {
            if let start = frameStart, sawSlice {
                analysis.videoSamples.append((start, frameSize, frameIsKey, frameOrder))
            }
            frameStart = nil
            frameSize = 0
            frameIsKey = false
            sawSlice = false
        }

        while position < mediaData.upperBound {
            if let frameLimit, analysis.videoSamples.count >= frameLimit { break }
            let fraction = Double(position - mediaData.lowerBound) / total
            if fraction - lastReport > 0.002 { try Task.checkCancellation(); progress(fraction); lastReport = fraction }

            if let unit = parser.unit(at: position, in: source, limit: mediaData.upperBound) {
                runFamily = nil
                if unit.startsFrame, sawSlice { finishFrame() }
                if frameStart == nil { frameStart = position }
                frameSize += unit.totalLength
                if unit.isSlice {
                    sawSlice = true
                    frameIsKey = frameIsKey || unit.isKeyframe
                    if let order = unit.displayOrder { frameOrder = order }
                }
                position += UInt64(unit.totalLength)
                continue
            }
            finishFrame()
            if hasDolby, let length = DolbyFrame.verifiedLength(at: position, in: source, limit: mediaData.upperBound) {
                appendAudio(.dolby, length)
                continue
            }
            if let probe {
                let available = Int(min(UInt64(probe.maximumFrameLength), mediaData.upperBound - position))
                if available > 0, let length = probe.frameLength(at: position, in: source, available: available) {
                    appendAudio(.aac, length)
                    continue
                }
            }
            // Neither: skip to the next recognizable video unit.
            runFamily = nil
            let next = parser.nextUnit(after: position, in: source, limit: mediaData.upperBound) ?? mediaData.upperBound
            analysis.unrecoveredBytes += Int64(next - position)
            position = next
        }
        finishFrame()
        progress(1)
        guard !analysis.videoSamples.isEmpty else { throw MovieRepairError.nothingRecovered }
        return analysis
    }

    // MARK: Writing

    /// Writes a repaired copy: the original bytes followed by a rebuilt index.
    func write(_ analysis: Analysis, reference: RepairReference, to output: URL,
               progress: (Double) -> Void) throws -> MovieRepairReport {
        let plan = TimingPlan(analysis: analysis, reference: reference)
        let moov = MovieIndexWriter.movie(analysis: analysis, plan: plan, reference: reference)

        // Copy the file in chunks (so progress can be shown), then add the index.
        // A new file only: an existing one (the original included) is never removed or truncated.
        let writer = try RepairOutput.createNewFile(at: output)
        defer { try? writer.close() }
        let reader = try FileHandle(forReadingFrom: damagedURL)
        defer { try? reader.close() }
        let end = mediaData.upperBound
        var copied: UInt64 = 0
        while copied < end {
            try Task.checkCancellation()
            let chunk = try reader.read(upToCount: Int(min(UInt64(8 << 20), end - copied))) ?? Data()
            guard !chunk.isEmpty else { break }
            try writer.write(contentsOf: chunk)
            copied += UInt64(chunk.count)
            progress(Double(copied) / Double(end))
        }
        // The media data box must end exactly where the index begins.
        let mdatHeaderOffset = try mediaDataHeaderOffset()
        let mdatSize = end - mdatHeaderOffset
        try writer.seek(toOffset: mdatHeaderOffset)
        if mediaData.lowerBound - mdatHeaderOffset == 16 {
            try writer.write(contentsOf: Data([0, 0, 0, 1]) + Data("mdat".utf8) + MovieIndexWriter.u64(mdatSize))
        } else if mdatSize <= UInt64(UInt32.max) {
            try writer.write(contentsOf: MovieIndexWriter.u32(UInt32(mdatSize)) + Data("mdat".utf8))
        }
        try writer.seekToEnd()
        try writer.write(contentsOf: moov)
        _ = ftyp
        return MovieRepairReport(referenceName: reference.url.deletingPathExtension().lastPathComponent,
                                 videoFrames: analysis.videoSamples.count,
                                 keyframes: analysis.videoSamples.filter(\.isKeyframe).count,
                                 audioFrames: plan.audioTracks.map(\.frames.count),
                                 duration: plan.duration, frameRate: plan.frameRate,
                                 unrecoveredBytes: analysis.unrecoveredBytes)
    }

    private func mediaDataHeaderOffset() throws -> UInt64 {
        let probe = try source.read(at: mediaData.lowerBound - 16, count: 16)
        // A 64-bit header puts "mdat" 12 bytes before the data; a 32-bit one, 4 bytes.
        if probe.count == 16, probe[4..<8] == Data("mdat".utf8), probe.prefix(4) == Data([0, 0, 0, 1]) {
            return mediaData.lowerBound - 16
        }
        return mediaData.lowerBound - 8
    }
}

// MARK: - Reference

/// Decoder setup and sample descriptions taken from a healthy file.
nonisolated struct RepairReference {
    struct AudioTrack {
        let family: AudioFamily
        let sampleDescription: Data   // whole 'stsd' box
        let handler: Data              // whole 'hdlr' box
        let language: UInt16
        let sampleRate: UInt32
        let channels: Int
        /// AAC only.
        let audioSpecificConfig: Data

        var samplesPerFrame: UInt32 { family == .aac ? 1024 : 1536 }
    }

    let url: URL
    private(set) var videoSampleDescription: Data  // whole 'stsd' box
    let videoHandler: Data
    let videoLanguage: UInt16
    let videoTimescale: UInt32
    let frameDuration: UInt32
    private(set) var width: Int
    private(set) var height: Int
    let nalLengthSize: Int
    private(set) var sps: H264SequenceParameters
    private(set) var videoFormat: CMFormatDescription
    /// The H.264 configuration record (avcC payload).
    private(set) var avcC: Data
    let audio: [AudioTrack]

    init(url: URL) throws {
        self.url = url
        let source = try FileByteSource(url: url)
        var offset: UInt64 = 0
        var moov: Data?
        while offset + 8 <= source.size {
            let header = try source.read(at: offset, count: 16)
            guard header.count >= 8 else { break }
            var size = UInt64(header.prefix(4).bigEndianUInt)
            if size == 1 {
                guard header.count >= 16 else { break }
                size = UInt64(header[8..<16].bigEndianUInt)
            }
            // Missing or cut-off sizes run to the end of the file.
            if size == 0 || size > source.size - offset { size = source.size - offset }
            guard size >= 8 else { break }
            if header[4..<8] == Data("moov".utf8) {
                moov = try source.read(at: offset, count: Int(clamping: size), limit: FileByteSource.maxIndexSize)
                break
            }
            offset += size
        }
        guard let moov else { throw MovieRepairError.unsupportedReference("it has no index either") }
        let tracks = MP4Boxes.children(of: moov.dropFirst(8)).filter { $0.type == "trak" }.map(\.body)

        var video: (stsd: Data, hdlr: Data, language: UInt16, timescale: UInt32, delta: UInt32, width: Int, height: Int, avcC: Data)?
        var audio: [AudioTrack] = []
        for trak in tracks {
            guard let mdia = MP4Boxes.child("mdia", of: trak), let hdlr = MP4Boxes.box("hdlr", in: mdia),
                  let mdhd = MP4Boxes.child("mdhd", of: mdia), let minf = MP4Boxes.child("minf", of: mdia),
                  let stbl = MP4Boxes.child("stbl", of: minf), let stsd = MP4Boxes.box("stsd", in: stbl) else { continue }
            let handler = String(decoding: hdlr.dropFirst(16).prefix(4), as: UTF8.self)
            let version = mdhd.first ?? 0
            let timescale = UInt32((version == 1 ? mdhd.dropFirst(20) : mdhd.dropFirst(12)).prefix(4).bigEndianUInt)
            let language = UInt16((version == 1 ? mdhd.dropFirst(32) : mdhd.dropFirst(20)).prefix(2).bigEndianUInt)
            let entry = stsd.dropFirst(8 + 8) // box header, version/flags, count
            let format = String(decoding: entry.dropFirst(4).prefix(4), as: UTF8.self)
            if handler == "vide", video == nil {
                guard format == "avc1" || format == "avc3" else { throw MovieRepairError.unsupportedReference("its video isn't H.264") }
                let visual = entry.dropFirst(8 + 78) // entry header + VisualSampleEntry fields
                guard let avcC = MP4Boxes.child("avcC", of: visual) else { throw MovieRepairError.unsupportedReference("no H.264 configuration") }
                let width = Int(entry.dropFirst(8 + 24).prefix(2).bigEndianUInt)
                let height = Int(entry.dropFirst(8 + 26).prefix(2).bigEndianUInt)
                // Average frame duration over the whole track (the first entries can differ).
                let stts = [UInt8](MP4Boxes.child("stts", of: stbl) ?? Data())
                var frames: UInt64 = 0
                var ticks: UInt64 = 0
                if stts.count >= 8 {
                    // Only the entries the box holds; a damaged count can't loop billions of times.
                    let declared = Int(UInt32(stts[4]) << 24 | UInt32(stts[5]) << 16 | UInt32(stts[6]) << 8 | UInt32(stts[7]))
                    let entries = min(declared, (stts.count - 8) / 8)
                    for index in 0..<entries {
                        let at = 8 + index * 8
                        let count = UInt64(stts[at]) << 24 | UInt64(stts[at + 1]) << 16 | UInt64(stts[at + 2]) << 8 | UInt64(stts[at + 3])
                        let delta = UInt64(stts[at + 4]) << 24 | UInt64(stts[at + 5]) << 16 | UInt64(stts[at + 6]) << 8 | UInt64(stts[at + 7])
                        // Saturating: damaged counts and deltas can't overflow the totals.
                        let (product, productOverflow) = count.multipliedReportingOverflow(by: delta)
                        let (sum, sumOverflow) = ticks.addingReportingOverflow(product)
                        ticks = productOverflow || sumOverflow ? .max : sum
                        frames = frames.addingReportingOverflow(count).overflow ? .max : frames + count
                    }
                }
                let average = frames > 0 ? (Double(ticks) / Double(frames)).rounded() : 0
                let delta = average.isFinite && average < Double(UInt32.max) ? UInt32(max(average, 0)) : 0
                video = (stsd, hdlr, language, timescale, delta, width, height, avcC)
            } else if handler == "soun", timescale == 0 {
                continue // A damaged sound track without a sample rate can't be timed.
            } else if handler == "soun", format == "mp4a" {
                let sound = entry.dropFirst(8 + 28)
                guard let esds = MP4Boxes.child("esds", of: sound) ?? MP4Boxes.child("wave", of: sound).flatMap({ MP4Boxes.child("esds", of: $0) }),
                      let config = ESDS.parse(Data(esds))?.decoderSpecificInfo else { continue }
                let channels = Int(entry.dropFirst(8 + 16).prefix(2).bigEndianUInt)
                audio.append(AudioTrack(family: .aac, sampleDescription: stsd, handler: hdlr, language: language,
                                        sampleRate: timescale, channels: max(1, channels), audioSpecificConfig: config))
            } else if handler == "soun", format == "ac-3" || format == "ec-3" {
                let channels = Int(entry.dropFirst(8 + 16).prefix(2).bigEndianUInt)
                audio.append(AudioTrack(family: .dolby, sampleDescription: stsd, handler: hdlr, language: language,
                                        sampleRate: timescale, channels: max(1, channels), audioSpecificConfig: Data()))
            }
        }
        guard let video else { throw MovieRepairError.unsupportedReference("it has no H.264 video") }
        let avcC = [UInt8](video.avcC)
        guard avcC.count > 8 else { throw MovieRepairError.unsupportedReference("its H.264 configuration is damaged") }
        nalLengthSize = Int(avcC[4] & 0x03) + 1
        let spsLength = Int(avcC[6]) << 8 | Int(avcC[7])
        guard avcC.count >= 8 + spsLength, let sps = H264SequenceParameters(Data(avcC[8..<(8 + spsLength)])) else {
            throw MovieRepairError.unsupportedReference("its H.264 settings can't be read")
        }
        self.sps = sps
        self.avcC = video.avcC
        videoSampleDescription = video.stsd
        videoHandler = video.hdlr
        videoLanguage = video.language
        videoTimescale = video.timescale
        frameDuration = video.delta
        width = video.width
        height = video.height
        self.audio = audio

        var format: CMFormatDescription?
        let atoms = ["avcC": video.avcC] as CFDictionary
        let extensions = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms] as CFDictionary
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264, width: Int32(video.width),
                                       height: Int32(video.height), extensions: extensions, formatDescriptionOut: &format)
        guard let format else { throw MovieRepairError.unsupportedReference("its H.264 configuration is invalid") }
        videoFormat = format
    }

    /// The same setup for a different picture size (in macroblocks): the SPS is rewritten
    /// and the sample description updated to match.
    func resized(widthInMacroblocks: Int, heightInMapUnits: Int) -> RepairReference? {
        let record = [UInt8](avcC)
        guard record.count > 8 else { return nil }
        let spsLength = Int(record[6]) << 8 | Int(record[7])
        guard record.count >= 8 + spsLength,
              let newSPS = H264SequenceParameters.resized(Data(record[8..<(8 + spsLength)]), widthInMacroblocks: widthInMacroblocks,
                                                          heightInMapUnits: heightInMapUnits),
              let parsed = H264SequenceParameters(newSPS) else { return nil }
        var newRecord = Data(record[0..<6])
        newRecord.append(MovieIndexWriter.u16(UInt16(newSPS.count)))
        newRecord.append(newSPS)
        newRecord.append(Data(record[(8 + spsLength)...]))
        let pixelWidth = widthInMacroblocks * 16
        let pixelHeight = heightInMapUnits * 16 * (parsed.frameMbsOnly ? 1 : 2)

        var format: CMFormatDescription?
        let atoms = ["avcC": newRecord] as CFDictionary
        let extensions = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms] as CFDictionary
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264, width: Int32(pixelWidth),
                                       height: Int32(pixelHeight), extensions: extensions, formatDescriptionOut: &format)
        guard let format else { return nil }

        // Rebuild the sample description: same entry, new size and configuration box.
        let entry = videoSampleDescription.dropFirst(16) // box header, version/flags, entry count
        guard entry.count > 86 else { return nil }
        let fields = Data(entry[(entry.startIndex + 8)..<(entry.startIndex + 86)]) // VisualSampleEntry fields
        var visual = fields
        visual.replaceSubrange(24..<26, with: MovieIndexWriter.u16(UInt16(pixelWidth)))
        visual.replaceSubrange(26..<28, with: MovieIndexWriter.u16(UInt16(pixelHeight)))
        var children = MovieIndexWriter.box("avcC", newRecord)
        for child in MP4Boxes.children(of: entry.dropFirst(86)) where child.type != "avcC" {
            children.append(child.whole)
        }
        let format4 = Data(entry[(entry.startIndex + 4)..<(entry.startIndex + 8)])
        let newEntry = MovieIndexWriter.u32(UInt32(8 + visual.count + children.count)) + format4 + visual + children
        let description = MovieIndexWriter.fullBox("stsd", MovieIndexWriter.u32(1) + newEntry)

        var copy = self
        copy.avcC = newRecord
        copy.sps = parsed
        copy.videoFormat = format
        copy.width = pixelWidth
        copy.height = pixelHeight
        copy.videoSampleDescription = description
        return copy
    }

    /// Picture width and height in macroblocks.
    var macroblockSize: (width: Int, heightInMapUnits: Int) {
        (width: (width + 15) / 16, heightInMapUnits: ((height + 15) / 16) / (sps.frameMbsOnly ? 1 : 2))
    }
}

// MARK: - Boxes

nonisolated enum MP4Boxes {
    struct Box {
        let type: String
        let body: Data
        let whole: Data
    }

    static func children(of data: Data) -> [Box] {
        var boxes: [Box] = []
        var at = data.startIndex
        while at + 8 <= data.endIndex {
            let remaining = data.endIndex - at
            var size = Int(data[at..<(at + 4)].bigEndianUInt)
            var header = 8
            if size == 1, remaining >= 16 {
                // Compare 64-bit sizes against the bytes left before converting.
                let large = data[(at + 8)..<(at + 16)].bigEndianUInt
                guard large <= UInt64(remaining) else { break }
                size = Int(large)
                header = 16
            }
            if size == 0 { size = remaining }
            guard size >= header, at + size <= data.endIndex else { break }
            boxes.append(Box(type: String(decoding: data[(at + 4)..<(at + 8)], as: UTF8.self),
                             body: data[(at + header)..<(at + size)], whole: data[at..<(at + size)]))
            at += size
        }
        return boxes
    }

    static func child(_ type: String, of data: Data) -> Data? {
        children(of: data).first { $0.type == type }?.body
    }

    /// The whole child box, header included.
    static func box(_ type: String, in data: Data) -> Data? {
        children(of: data).first { $0.type == type }.map { Data($0.whole) }
    }
}

// MARK: - H.264

/// The sequence parameters needed to read slice headers.
nonisolated struct H264SequenceParameters {
    let profile: UInt8
    let separateColourPlane: Bool
    let log2MaxFrameNum: Int
    let pocType: Int
    let log2MaxPocLsb: Int
    let frameMbsOnly: Bool
    let totalMacroblocks: Int

    init?(_ nal: Data) {
        var bits = BitReader(nal.dropFirst())
        guard let profile = bits.read(8) else { return nil }
        self.profile = UInt8(profile)
        _ = bits.read(16)
        _ = bits.unsignedExpGolomb()
        var separate = false
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            let chroma = bits.unsignedExpGolomb() ?? 1
            if chroma == 3 { separate = bits.bit() == 1 }
            _ = bits.unsignedExpGolomb()
            _ = bits.unsignedExpGolomb()
            _ = bits.bit()
            if bits.bit() == 1 {
                for index in 0..<(chroma == 3 ? 12 : 8) where bits.bit() == 1 {
                    var last = 8
                    var next = 8
                    for _ in 0..<(index < 6 ? 16 : 64) where next != 0 {
                        next = (last + (bits.signedExpGolomb() ?? 0) + 256) % 256
                        last = next == 0 ? last : next
                    }
                }
            }
        }
        separateColourPlane = separate
        guard let frameNum = bits.unsignedExpGolomb(), let pocType = bits.unsignedExpGolomb() else { return nil }
        log2MaxFrameNum = frameNum + 4
        self.pocType = pocType
        var lsb = 0
        if pocType == 0 {
            lsb = (bits.unsignedExpGolomb() ?? 0) + 4
        } else if pocType == 1 {
            _ = bits.bit()
            _ = bits.signedExpGolomb()
            _ = bits.signedExpGolomb()
            for _ in 0..<(bits.unsignedExpGolomb() ?? 0) { _ = bits.signedExpGolomb() }
        }
        log2MaxPocLsb = lsb
        _ = bits.unsignedExpGolomb()
        _ = bits.bit()
        guard let widthMbs = bits.unsignedExpGolomb(), let heightUnits = bits.unsignedExpGolomb(), let mbsOnly = bits.bit() else { return nil }
        frameMbsOnly = mbsOnly == 1
        totalMacroblocks = (widthMbs + 1) * (heightUnits + 1) * (frameMbsOnly ? 1 : 2)
    }
}

/// Recognizes length-prefixed H.264 units in raw media data and tracks display order.
nonisolated struct VideoUnitParser {
    struct Unit {
        let totalLength: Int
        let isSlice: Bool
        let startsFrame: Bool
        let isKeyframe: Bool
        /// Display position (picture order count, made absolute across IDR periods).
        let displayOrder: Int64?
    }

    private let lengthSize: Int
    private let sps: H264SequenceParameters
    private let profile: UInt8
    private var previousPocMsb = 0
    private var previousPocLsb = 0
    private var periodBase: Int64 = 0
    private var highestOrder: Int64 = -2
    private var frameCount: Int64 = 0

    init(reference: RepairReference) {
        lengthSize = reference.nalLengthSize
        sps = reference.sps
        profile = reference.sps.profile
    }

    /// A unit starting exactly at `position`, or nil if the bytes there don't look like one.
    mutating func unit(at position: UInt64, in source: FileByteSource, limit: UInt64) -> Unit? {
        guard let header = try? source.read(at: position, count: lengthSize + 24), header.count >= lengthSize + 2 else { return nil }
        let length = Int(header.prefix(lengthSize).bigEndianUInt)
        guard length >= 2, length <= 16 << 20, position + UInt64(lengthSize + length) <= limit else { return nil }
        let nal = header.dropFirst(lengthSize)
        let first = nal[nal.startIndex]
        guard first & 0x80 == 0 else { return nil }
        let type = Int(first & 0x1F)
        let refIdc = Int(first >> 5)
        let total = lengthSize + length
        switch type {
        case 9: // Access unit delimiter
            return length <= 4 ? Unit(totalLength: total, isSlice: false, startsFrame: true, isKeyframe: false, displayOrder: nil) : nil
        case 6: // SEI: must be followed by another recognizable unit.
            guard refIdc == 0, length < 1 << 16 else { return nil }
            var probe = self
            guard probe.unit(at: position + UInt64(total), in: source, limit: limit) != nil else { return nil }
            return Unit(totalLength: total, isSlice: false, startsFrame: true, isKeyframe: false, displayOrder: nil)
        case 7, 8:
            // In-band parameter sets: must match the reference's profile (SPS) and be followed
            // by another unit, since short runs of audio can look like them.
            guard refIdc != 0, length < 1024, type == 8 || nal.dropFirst().first == profile else { return nil }
            var probe = self
            guard probe.unit(at: position + UInt64(total), in: source, limit: limit) != nil else { return nil }
            return Unit(totalLength: total, isSlice: false, startsFrame: true, isKeyframe: false, displayOrder: nil)
        case 1, 5:
            guard type == 1 || refIdc != 0 else { return nil }
            var bits = BitReader(nal.dropFirst())
            guard let firstMb = bits.unsignedExpGolomb(), firstMb < sps.totalMacroblocks,
                  let sliceType = bits.unsignedExpGolomb(), sliceType <= 9,
                  let pps = bits.unsignedExpGolomb(), pps == 0 else { return nil }
            if sps.separateColourPlane { _ = bits.read(2) }
            guard let frameNum = bits.read(sps.log2MaxFrameNum), type == 1 || frameNum == 0 else { return nil }
            if !sps.frameMbsOnly, bits.bit() == 1 { _ = bits.bit() }
            if type == 5 { _ = bits.unsignedExpGolomb() }
            let startsFrame = firstMb == 0
            var order: Int64?
            if startsFrame {
                order = displayOrder(isIDR: type == 5, isReference: refIdc != 0, pocLsb: sps.pocType == 0 ? bits.read(sps.log2MaxPocLsb) : nil)
            }
            return Unit(totalLength: total, isSlice: true, startsFrame: startsFrame,
                        isKeyframe: type == 5, displayOrder: order)
        default:
            return nil
        }
    }

    /// The next position within `limit` where a unit begins, scanning byte by byte.
    func nextUnit(after position: UInt64, in source: FileByteSource, limit: UInt64) -> UInt64? {
        var probe = self
        var at = position + 1
        while at + UInt64(lengthSize + 2) < limit {
            // Lengths of real units have zero high bytes; skip quickly otherwise.
            if let byte = try? source.read(at: at, count: 1).first, byte != 0, lengthSize == 4 {
                at += 1
                continue
            }
            if probe.unit(at: at, in: source, limit: limit)?.startsFrame == true { return at }
            at += 1
        }
        return nil
    }

    /// Picture order count (type 0) made absolute across IDR periods; decode order otherwise.
    private mutating func displayOrder(isIDR: Bool, isReference: Bool, pocLsb: Int?) -> Int64 {
        defer { frameCount += 1 }
        guard let lsb = pocLsb else { return frameCount * 2 }
        let maxLsb = 1 << sps.log2MaxPocLsb
        if isIDR {
            periodBase = highestOrder + 2
            previousPocMsb = 0
            previousPocLsb = 0
        }
        var msb = previousPocMsb
        if lsb < previousPocLsb, previousPocLsb - lsb >= maxLsb / 2 { msb += maxLsb }
        else if lsb > previousPocLsb, lsb - previousPocLsb > maxLsb / 2 { msb -= maxLsb }
        if isReference {
            previousPocMsb = msb
            previousPocLsb = lsb
        }
        let order = periodBase + Int64(msb + lsb)
        highestOrder = max(highestOrder, order)
        return order
    }
}

// MARK: - AAC

/// Finds AAC frame lengths: the system decoder fails on a truncated frame and succeeds on
/// the exact length or anything longer, so the shortest decodable prefix is the frame.
nonisolated final class AACFrameProbe {
    let maximumFrameLength: Int
    private let converter: AudioConverterRef
    private let channels: UInt32

    private final class Feed {
        var data = Data()
        var given = false
        var buffer: UnsafeMutableRawPointer?
        var description = AudioStreamPacketDescription()
        deinit { buffer?.deallocate() }
    }

    init(reference: RepairReference) throws {
        guard let track = reference.audio.first(where: { $0.family == .aac }) else {
            throw MovieRepairError.unsupportedReference("it has no AAC audio")
        }
        channels = UInt32(track.channels)
        // AAC allows at most 6144 bits per channel per frame.
        maximumFrameLength = 768 * track.channels + 16
        var input = AudioStreamBasicDescription(mSampleRate: Double(track.sampleRate), mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
                                                mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                                                mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
        var output = AudioStreamBasicDescription(mSampleRate: Double(track.sampleRate), mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                 mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
                                                 mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        var converter: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &converter) == noErr, let converter else {
            throw MovieRepairError.unsupportedReference("its audio can't be decoded")
        }
        self.converter = converter
        let cookie = ESDS.esDescriptor(objectType: 0x40, streamType: 0x05, decoderSpecificInfo: track.audioSpecificConfig)
        cookie.withUnsafeBytes { raw in
            _ = AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie, UInt32(raw.count), raw.baseAddress!)
        }
    }

    deinit {
        AudioConverterDispose(converter)
    }

    func frameLength(at position: UInt64, in source: FileByteSource, available: Int) -> Int? {
        guard let bytes = try? source.read(at: position, count: available), bytes.count == available,
              decodes(bytes) else { return nil }
        var low = 1
        var high = available
        while low < high {
            let middle = (low + high) / 2
            if decodes(bytes.prefix(middle)) { high = middle } else { low = middle + 1 }
        }
        return low
    }

    private func decodes(_ packet: Data) -> Bool {
        AudioConverterReset(converter)
        let feed = Feed()
        feed.data = packet
        var frames: UInt32 = 1024
        var pcm = [Float](repeating: 0, count: 1024 * Int(channels))
        let status = pcm.withUnsafeMutableBytes { raw -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: UInt32(raw.count),
                                                                                  mData: raw.baseAddress))
            return AudioConverterFillComplexBuffer(converter, { _, count, data, description, user in
                let feed = Unmanaged<Feed>.fromOpaque(user!).takeUnretainedValue()
                guard !feed.given else { count.pointee = 0; return 1 }
                feed.given = true
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(1, feed.data.count), alignment: 16)
                feed.data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: feed.data.count)
                feed.buffer = buffer
                count.pointee = 1
                data.pointee.mBuffers.mData = buffer
                data.pointee.mBuffers.mDataByteSize = UInt32(feed.data.count)
                feed.description = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(feed.data.count))
                if let description { withUnsafeMutablePointer(to: &feed.description) { description.pointee = $0 } }
                return noErr
            }, Unmanaged.passUnretained(feed).toOpaque(), &frames, &list, nil)
        }
        return (status == noErr || status == 1) && frames > 0
    }
}

// MARK: - Timing

/// Frame rate, display offsets, and which audio frames belong to which track.
nonisolated struct TimingPlan {
    let timescale: UInt32
    let frameDuration: UInt32
    /// Composition offsets (display minus decode time), in frame durations, non-negative.
    let compositionOffsets: [Int]
    /// The shift that makes the first displayed frame start at zero, in frame durations.
    let initialDelay: Int
    /// Audio frames for each reference audio track that has any.
    let audioTracks: [(referenceIndex: Int, frames: [(offset: UInt64, size: Int)])]
    let duration: Double
    let frameRate: Double

    init(analysis: MovieRepairer.Analysis, reference: RepairReference) {
        let count = analysis.videoSamples.count
        // Display order: rank of each frame's order value.
        let ranked = analysis.videoSamples.indices.sorted { analysis.videoSamples[$0].order < analysis.videoSamples[$1].order }
        var displayIndex = [Int](repeating: 0, count: count)
        for (rank, index) in ranked.enumerated() { displayIndex[index] = rank }
        let delay = (0..<count).map { $0 - displayIndex[$0] }.max() ?? 0
        compositionOffsets = (0..<count).map { displayIndex[$0] - $0 + max(0, delay) }
        initialDelay = max(0, delay)

        // Audio: each family's length should match the video's, which reveals how many tracks
        // of that family are interleaved and confirms (or corrects) the frame rate.
        let standards: [(scale: UInt32, delta: UInt32)] = [(24000, 1001), (24000, 1000), (25000, 1000), (30000, 1001),
                                                            (30000, 1000), (50000, 1000), (60000, 1001), (60000, 1000)]
        func nearestStandard(_ rate: Double) -> (scale: UInt32, delta: UInt32) {
            standards.min { abs(Double($0.scale) / Double($0.delta) - rate) < abs(Double($1.scale) / Double($1.delta) - rate) }!
        }
        var timescale = reference.videoTimescale
        var delta = reference.frameDuration
        if timescale == 0 || delta == 0 { timescale = 24000; delta = 1001 }
        // Encoders write standard rates; snap the reference's measured rate to the one it rounds from.
        let referenceRate = Double(timescale) / Double(delta)
        let snapped = nearestStandard(referenceRate)
        if abs(Double(snapped.scale) / Double(snapped.delta) - referenceRate) / referenceRate < 0.002 {
            timescale = snapped.scale
            delta = snapped.delta
        }
        var videoSeconds = Double(count) * Double(delta) / Double(timescale)

        struct FamilyPlan { let family: AudioFamily; let trackIndexes: [Int]; let stream: MovieRepairer.AudioStream; let trackCount: Int; let secondsPerTrack: Double }
        var families: [FamilyPlan] = []
        for family in [AudioFamily.aac, .dolby] {
            let indexes = reference.audio.indices.filter { reference.audio[$0].family == family }
            guard let first = indexes.first, let stream = analysis.audio[family], !stream.frames.isEmpty else { continue }
            let track = reference.audio[first]
            let seconds = Double(stream.frames.count) * Double(track.samplesPerFrame) / Double(track.sampleRate)
            let trackCount = max(1, min(indexes.count, Int((seconds / max(videoSeconds, 1)).rounded())))
            families.append(FamilyPlan(family: family, trackIndexes: indexes, stream: stream, trackCount: trackCount,
                                       secondsPerTrack: seconds / Double(trackCount)))
        }
        if let longest = families.max(by: { $0.secondsPerTrack < $1.secondsPerTrack }), longest.secondsPerTrack > 10,
           abs(longest.secondsPerTrack - videoSeconds) / longest.secondsPerTrack > 0.01 {
            // The reference's frame rate doesn't fit; use the standard rate closest to the audio.
            let best = nearestStandard(Double(count) / longest.secondsPerTrack)
            timescale = best.scale
            delta = best.delta
            videoSeconds = Double(count) * Double(delta) / Double(timescale)
        }
        self.timescale = timescale
        frameDuration = delta
        frameRate = Double(timescale) / Double(delta)

        // Split each run of a family's frames evenly between its tracks, keeping each track's
        // total as level as possible when a run doesn't divide evenly.
        var planned: [(referenceIndex: Int, frames: [(offset: UInt64, size: Int)])] = []
        var longestAudio = 0.0
        for plan in families {
            var tracks = [[(offset: UInt64, size: Int)]](repeating: [], count: plan.trackCount)
            let starts = plan.stream.runStarts + [plan.stream.frames.count]
            for (start, end) in zip(starts, starts.dropFirst()) where end > start {
                let run = end - start
                var shares = [Int](repeating: run / plan.trackCount, count: plan.trackCount)
                let byTotal = tracks.indices.sorted { tracks[$0].count < tracks[$1].count }
                for index in byTotal.prefix(run % plan.trackCount) { shares[index] += 1 }
                var at = start
                for track in 0..<plan.trackCount {
                    tracks[track] += plan.stream.frames[at..<(at + shares[track])]
                    at += shares[track]
                }
            }
            for (offset, frames) in tracks.enumerated() {
                let index = plan.trackIndexes[offset]
                planned.append((index, frames))
                let track = reference.audio[index]
                longestAudio = max(longestAudio, Double(frames.count) * Double(track.samplesPerFrame) / Double(track.sampleRate))
            }
        }
        audioTracks = planned.sorted { $0.referenceIndex < $1.referenceIndex }
        duration = max(videoSeconds, longestAudio)
    }
}

/// Audio codecs the repair recognizes: AAC (found with the decoder) and Dolby Digital /
/// Dolby Digital Plus (self-describing sync frames).
nonisolated enum AudioFamily: Hashable {
    case aac
    case dolby
}

/// AC-3 and E-AC-3 sync frames, accepted only when their CRC checks out.
nonisolated enum DolbyFrame {
    static func verifiedLength(at position: UInt64, in source: FileByteSource, limit: UInt64) -> Int? {
        guard let head = try? source.read(at: position, count: 8), head.count == 8 else { return nil }
        let b = [UInt8](head)
        guard b[0] == 0x0B, b[1] == 0x77 else { return nil }
        let length: Int
        if b[5] >> 3 > 10 {
            length = ((Int(b[2] & 0x07) << 8 | Int(b[3])) + 1) * 2
        } else {
            guard let ac3 = AudioFramer.ac3FrameLength(fscod: Int(b[4] >> 6), frmsizecod: Int(b[4] & 0x3F)) else { return nil }
            length = ac3
        }
        guard length > 8, position + UInt64(length) <= limit,
              let frame = try? source.read(at: position, count: length), frame.count == length else { return nil }
        return AC3.isIntact([UInt8](frame)) ? length : nil
    }
}

// MARK: - Index writer

nonisolated enum MovieIndexWriter {
    static func u32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    static func u64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    static func u16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }

    static func join(_ parts: [Data]) -> Data {
        parts.reduce(into: Data()) { $0.append($1) }
    }

    static func box(_ type: String, _ parts: Data...) -> Data {
        let body = parts.reduce(into: Data()) { $0.append($1) }
        return u32(UInt32(8 + body.count)) + Data(type.utf8) + body
    }

    static func fullBox(_ type: String, version: UInt8 = 0, flags: UInt32 = 0, _ parts: Data...) -> Data {
        let body = parts.reduce(into: Data()) { $0.append($1) }
        return box(type, Data([version]) + u32(flags).dropFirst(), body)
    }

    private static let matrix: Data = [0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x4000_0000].reduce(into: Data()) { $0.append(u32(UInt32($1))) }

    static func movie(analysis: MovieRepairer.Analysis, plan: TimingPlan, reference: RepairReference) -> Data {
        let movieTimescale: UInt32 = 1000
        let videoDuration = UInt64(analysis.videoSamples.count) * UInt64(plan.frameDuration)
        let videoMovieDuration = ticks(Double(videoDuration) / Double(plan.timescale) * Double(movieTimescale))
        var traks = Data()
        traks.append(videoTrack(analysis: analysis, plan: plan, reference: reference, movieDuration: videoMovieDuration))
        var longest = videoMovieDuration
        for (index, planned) in plan.audioTracks.enumerated() where !planned.frames.isEmpty {
            let audio = reference.audio[planned.referenceIndex]
            let frames = planned.frames
            let duration = UInt64(frames.count) * UInt64(audio.samplesPerFrame)
            let movieDuration = ticks(Double(duration) / Double(audio.sampleRate) * Double(movieTimescale))
            longest = max(longest, movieDuration)
            traks.append(audioTrack(id: UInt32(index + 2), frames: frames, track: audio,
                                    duration: duration, movieDuration: movieDuration, isEnabled: index == 0))
        }
        let mvhd = fullBox("mvhd", join([u32(0), u32(0), u32(movieTimescale), u32(UInt32(clamping: longest)), u32(0x0001_0000), u16(0x0100),
                                         Data(count: 10), matrix, Data(count: 24), u32(UInt32(clamping: plan.audioTracks.count + 2))]))
        return box("moov", mvhd, traks)
    }

    /// A duration in whole ticks; non-finite or out-of-range values (from damaged timing)
    /// saturate rather than trap.
    static func ticks(_ value: Double) -> UInt64 {
        guard value.isFinite, value > 0 else { return 0 }
        return value >= 1.8e19 ? .max : UInt64(value.rounded())
    }

    private static func trackHeader(id: UInt32, duration: UInt64, isAudio: Bool, isEnabled: Bool, width: Int, height: Int) -> Data {
        fullBox("tkhd", flags: isEnabled ? 3 : 2,
                join([u32(0), u32(0), u32(id), u32(0), u32(UInt32(clamping: duration)), Data(count: 8),
                      u16(0), u16(isAudio ? 1 : 0), u16(isAudio ? 0x0100 : 0), u16(0), matrix,
                      u32(UInt32(clamping: width) &<< 16), u32(UInt32(clamping: height) &<< 16)]))
    }

    private static func dataInformation() -> Data {
        box("dinf", fullBox("dref", u32(1) + fullBox("url ", flags: 1)))
    }

    private static func chunkTables(offsets: [UInt64], sizes: [Int]) -> Data {
        // One sample per chunk keeps the tables simple and works with any interleaving.
        let stsc = fullBox("stsc", join([u32(1), u32(1), u32(1), u32(1)]))
        var sizeTable = u32(0) + u32(UInt32(clamping: sizes.count))
        sizeTable.reserveCapacity(8 + sizes.count * 4)
        for size in sizes { sizeTable.append(u32(UInt32(clamping: size))) }
        var offsetTable = u32(UInt32(clamping: offsets.count))
        offsetTable.reserveCapacity(4 + offsets.count * 8)
        for offset in offsets { offsetTable.append(u64(offset)) }
        return stsc + fullBox("stsz", sizeTable) + fullBox("co64", offsetTable)
    }

    private static func videoTrack(analysis: MovieRepairer.Analysis, plan: TimingPlan, reference: RepairReference,
                                   movieDuration: UInt64) -> Data {
        let samples = analysis.videoSamples
        let mediaDuration = UInt64(samples.count) * UInt64(plan.frameDuration)
        let stts = fullBox("stts", u32(1) + u32(UInt32(clamping: samples.count)) + u32(plan.frameDuration))
        // Composition offsets, run-length encoded.
        var runs: [(count: UInt32, offset: UInt32)] = []
        for offset in plan.compositionOffsets.map({ UInt32(clamping: $0) &* plan.frameDuration }) {
            if let last = runs.last, last.offset == offset { runs[runs.count - 1].count += 1 } else { runs.append((1, offset)) }
        }
        var ctts = u32(UInt32(clamping: runs.count))
        for run in runs { ctts.append(u32(run.count) + u32(run.offset)) }
        let syncSamples = samples.indices.filter { samples[$0].isKeyframe }
        var stss = u32(UInt32(clamping: syncSamples.count))
        for index in syncSamples { stss.append(u32(UInt32(clamping: index + 1))) }
        let stbl = box("stbl", reference.videoSampleDescription, stts, fullBox("ctts", ctts), fullBox("stss", stss),
                       chunkTables(offsets: samples.map(\.offset), sizes: samples.map(\.size)))
        let minf = box("minf", fullBox("vmhd", flags: 1, Data(count: 8)), dataInformation(), stbl)
        let mdhd = fullBox("mdhd", join([u32(0), u32(0), u32(plan.timescale), u32(UInt32(clamping: mediaDuration)), u16(reference.videoLanguage), u16(0)]))
        // The edit list hides the reordering delay so the first frame shows at time zero.
        let edit = fullBox("elst", join([u32(1), u32(UInt32(clamping: movieDuration)), u32(UInt32(clamping: plan.initialDelay) &* plan.frameDuration),
                                         u32(0x0001_0000)]))
        return box("trak", trackHeader(id: 1, duration: movieDuration, isAudio: false, isEnabled: true,
                                       width: reference.width, height: reference.height),
                   box("edts", edit), box("mdia", mdhd, reference.videoHandler, minf))
    }

    private static func audioTrack(id: UInt32, frames: [(offset: UInt64, size: Int)], track: RepairReference.AudioTrack,
                                   duration: UInt64, movieDuration: UInt64, isEnabled: Bool) -> Data {
        let stts = fullBox("stts", join([u32(1), u32(UInt32(clamping: frames.count)), u32(track.samplesPerFrame)]))
        let stbl = box("stbl", track.sampleDescription, stts, chunkTables(offsets: frames.map(\.offset), sizes: frames.map(\.size)))
        let minf = box("minf", fullBox("smhd", Data(count: 4)), dataInformation(), stbl)
        let mdhd = fullBox("mdhd", join([u32(0), u32(0), u32(track.sampleRate), u32(UInt32(clamping: duration)), u16(track.language), u16(0)]))
        return box("trak", trackHeader(id: id, duration: movieDuration, isAudio: true, isEnabled: isEnabled, width: 0, height: 0),
                   box("mdia", mdhd, track.handler, minf))
    }
}

nonisolated extension BitReader {
    mutating func signedExpGolomb() -> Int? {
        guard let value = unsignedExpGolomb() else { return nil }
        return value % 2 == 1 ? (value + 1) / 2 : -(value / 2)
    }
}

// MARK: - Picture size search

/// Writes bits most-significant first.
nonisolated struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var bitCount = 0

    mutating func write(_ value: Int, bits: Int) {
        for shift in stride(from: bits - 1, through: 0, by: -1) { writeBit((value >> shift) & 1) }
    }

    mutating func writeBit(_ bit: Int) {
        if bitCount % 8 == 0 { bytes.append(0) }
        if bit != 0 { bytes[bytes.count - 1] |= 0x80 >> UInt8(bitCount % 8) }
        bitCount += 1
    }

    mutating func writeUnsignedExpGolomb(_ value: Int) {
        let coded = value + 1
        let length = Int.bitWidth - coded.leadingZeroBitCount
        write(0, bits: length - 1)
        write(coded, bits: length)
    }
}

nonisolated extension H264SequenceParameters {
    /// Returns the SPS NAL unit (with header) rewritten for a different picture size, keeping
    /// every other setting. Cropping is cleared, since the damaged file's crop isn't known.
    static func resized(_ nal: Data, widthInMacroblocks: Int, heightInMapUnits: Int) -> Data? {
        // Work on the raw bits with emulation prevention removed.
        var raw: [UInt8] = []
        var zeros = 0
        for byte in nal.dropFirst() {
            if zeros >= 2, byte == 3 { zeros = 0; continue }
            zeros = byte == 0 ? zeros + 1 : 0
            raw.append(byte)
        }
        var reader = BitReader(rawBytes: raw)
        var position = 0
        func read(_ count: Int) -> Int? { defer { position += count }; return reader.read(count) }
        func ue() -> Int? {
            var zeros = 0
            while let bit = reader.bit() { position += 1; if bit == 1 { break }; zeros += 1 }
            guard let value = reader.read(zeros) else { return nil }
            position += zeros
            return (1 << zeros) - 1 + value
        }
        func se() -> Int? { ue().map { $0 % 2 == 1 ? ($0 + 1) / 2 : -($0 / 2) } }

        guard let profile = read(8) else { return nil }
        _ = read(16); _ = ue()
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            let chroma = ue() ?? 1
            if chroma == 3 { _ = read(1) }
            _ = ue(); _ = ue(); _ = read(1)
            if read(1) == 1 {
                for index in 0..<(chroma == 3 ? 12 : 8) where read(1) == 1 {
                    var last = 8, next = 8
                    for _ in 0..<(index < 6 ? 16 : 64) where next != 0 {
                        next = (last + (se() ?? 0) + 256) % 256
                        last = next == 0 ? last : next
                    }
                }
            }
        }
        _ = ue()
        let pocType = ue() ?? 0
        if pocType == 0 { _ = ue() } else if pocType == 1 {
            _ = read(1); _ = se(); _ = se()
            for _ in 0..<(ue() ?? 0) { _ = se() }
        }
        _ = ue(); _ = read(1)
        let sizeStart = position
        _ = ue(); _ = ue()
        let afterSize = position
        guard let mbsOnly = read(1) else { return nil }
        if mbsOnly == 0 { _ = read(1) }
        _ = read(1) // direct_8x8_inference
        let cropFlagPosition = position
        if read(1) == 1 { _ = ue(); _ = ue(); _ = ue(); _ = ue() }
        let afterCrop = position
        let totalBits = raw.count * 8

        func bit(_ index: Int) -> Int { Int(raw[index / 8] >> (7 - UInt8(index % 8))) & 1 }
        var writer = BitWriter()
        for index in 0..<sizeStart { writer.writeBit(bit(index)) }
        writer.writeUnsignedExpGolomb(widthInMacroblocks - 1)
        writer.writeUnsignedExpGolomb(heightInMapUnits - 1)
        for index in afterSize..<cropFlagPosition { writer.writeBit(bit(index)) }
        writer.writeBit(0) // no cropping
        // The rest (VUI and the RBSP stop bit), without the old byte-alignment padding.
        var lastOne = totalBits - 1
        while lastOne > afterCrop, bit(lastOne) == 0 { lastOne -= 1 }
        for index in afterCrop...lastOne { writer.writeBit(bit(index)) }
        var rbsp = writer.bytes
        // Re-insert emulation prevention.
        var escaped: [UInt8] = [nal.first ?? 0x67]
        var run = 0
        for byte in rbsp {
            if run >= 2, byte <= 3 { escaped.append(3); run = 0 }
            escaped.append(byte)
            run = byte == 0 ? run + 1 : 0
        }
        rbsp = escaped
        return Data(rbsp)
    }
}
