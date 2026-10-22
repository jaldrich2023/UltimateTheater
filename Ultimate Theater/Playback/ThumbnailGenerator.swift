//
//  ThumbnailGenerator.swift
//  Ultimate Theater
//
//  Still frames at a given time, for chapter tiles and timeline previews: the
//  Theater engine's own container readers find the nearest keyframe and
//  VideoToolbox decodes it at thumbnail size.
//

import Foundation
import CoreMedia
import VideoToolbox

actor ThumbnailGenerator {
    private let url: URL
    private let maximumWidth: Int
    /// Cached frames, keyed by 5-second bucket.
    private var cache: [Int: CGImage] = [:]

    // An independent reader so thumbnails never disturb playback.
    private var demuxer: (any MediaDemuxer)?
    private var formatter: TrackFormatter?
    private var session: VTDecompressionSession?
    private var sessionFormat: CMFormatDescription?
    private var isUnavailable = false

    init(url: URL, maximumWidth: Int = 320) {
        self.url = url
        self.maximumWidth = maximumWidth
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    func image(at seconds: Double) async -> CGImage? {
        let bucket = Int(max(seconds, 0) / 5)
        if let cached = cache[bucket] { return cached }
        let time = Double(bucket) * 5
        let image = decodeFrame(at: time)
        if let image { cache[bucket] = image }
        return image
    }

    private func decodeFrame(at seconds: Double) -> CGImage? {
        guard !isUnavailable else { return nil }
        do {
            if demuxer == nil {
                let reader = try Demuxers.open(url)
                guard let video = reader.tracks.first(where: { $0.kind == .video && $0.codec.isSupported }) else {
                    isUnavailable = true
                    return nil
                }
                reader.enabledTrackIDs = [video.id]
                demuxer = reader
                formatter = try TrackFormatter(track: video)
            }
            guard let demuxer, let formatter else { return nil }
            try demuxer.seek(to: seconds)
            formatter.reset()

            // The first keyframe at or after the seek point decodes on its own.
            for _ in 0..<600 {
                guard let packet = try demuxer.nextPacket() else { return nil }
                guard packet.isKeyframe else { continue }
                for sample in try formatter.sampleBuffers(for: packet) {
                    if let image = decode(sample) { return image }
                }
            }
        } catch {
            isUnavailable = true
        }
        return nil
    }

    private func decode(_ sample: CMSampleBuffer) -> CGImage? {
        // The engine's own decoders (VP8, Theora) hand over pictures that are already decoded.
        if let pixels = CMSampleBufferGetImageBuffer(sample) {
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
            return image
        }
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
        if session == nil || sessionFormat.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: format) }) == true {
            if let session { VTDecompressionSessionInvalidate(session) }
            session = makeSession(for: format)
            sessionFormat = format
        }
        guard let session else { return nil }

        let result = DecodedFrame()
        // Without the asynchronous flag, decoding finishes before this call returns.
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, buffer, _, _ in
            guard status == noErr, let buffer else { return }
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
            result.set(image)
        }
        return result.image
    }

    /// Carries the decoded frame out of VideoToolbox's callback.
    private final class DecodedFrame: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: CGImage?

        var image: CGImage? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func set(_ image: CGImage?) {
            lock.lock()
            stored = image
            lock.unlock()
        }
    }

    private func makeSession(for format: CMFormatDescription) -> VTDecompressionSession? {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let width = min(maximumWidth, Int(max(dimensions.width, 1)))
        let height = Int(Double(width) * Double(max(dimensions.height, 1)) / Double(max(dimensions.width, 1)))
        // Ask the decoder to scale for us.
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: max(height, 1),
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                                  imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
                                                  decompressionSessionOut: &session)
        return status == noErr ? session : nil
    }
}
