//
//  SoftwareVideo.swift
//  Ultimate Theater
//
//  Shared plumbing for the engine's own video decoders (VP8, Theora): a decoded 8-bit
//  4:2:0 picture, and its conversion to the pixel buffers the video renderer displays.
//

import Foundation
import CoreMedia
import CoreVideo

/// A decoded picture: three 8-bit planes, chroma at half resolution in both directions.
/// Rows are `stride` bytes apart; only the first `width` (or chroma width) bytes are image.
nonisolated struct DecodedPicture: Sendable {
    var width: Int
    var height: Int
    var y: [UInt8]
    var u: [UInt8]
    var v: [UInt8]
    var yStride: Int
    var chromaStride: Int

    var chromaWidth: Int { (width + 1) / 2 }
    var chromaHeight: Int { (height + 1) / 2 }

    /// A blank picture with tightly packed planes.
    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        yStride = width
        chromaStride = (width + 1) / 2
        y = [UInt8](repeating: 16, count: width * height)
        u = [UInt8](repeating: 128, count: chromaStride * ((height + 1) / 2))
        v = u
    }

    init(width: Int, height: Int, y: [UInt8], u: [UInt8], v: [UInt8], yStride: Int, chromaStride: Int) {
        self.width = width
        self.height = height
        self.y = y
        self.u = u
        self.v = v
        self.yStride = yStride
        self.chromaStride = chromaStride
    }

    /// The planes are large enough for the stated size and strides (a decoder bug or damaged
    /// header can't make the copy read past them).
    var hasValidPlanes: Bool {
        guard width > 0, height > 0, yStride >= width, chromaStride >= chromaWidth else { return false }
        return y.count >= (height - 1) * yStride + width
            && u.count >= (chromaHeight - 1) * chromaStride + chromaWidth
            && v.count >= (chromaHeight - 1) * chromaStride + chromaWidth
    }

    /// Copies the picture into a new bi-planar 4:2:0 video-range pixel buffer.
    func pixelBuffer() -> CVPixelBuffer? {
        guard hasValidPlanes else { return nil }
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let luma = lumaBase.assumingMemoryBound(to: UInt8.self)
        let chroma = chromaBase.assumingMemoryBound(to: UInt8.self)
        y.withUnsafeBufferPointer { source in
            for row in 0..<height {
                (luma + row * lumaRow).update(from: source.baseAddress! + row * yStride, count: width)
            }
        }
        u.withUnsafeBufferPointer { us in
            v.withUnsafeBufferPointer { vs in
                for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, 1) {
                    let target = chroma + row * chromaRow
                    let sourceRow = min(row, chromaHeight - 1) * chromaStride
                    for column in 0..<CVPixelBufferGetWidthOfPlane(buffer, 1) {
                        let x = min(column, chromaWidth - 1)
                        target[2 * column] = us[sourceRow + x]
                        target[2 * column + 1] = vs[sourceRow + x]
                    }
                }
            }
        }
        return buffer
    }

    /// A ready sample buffer for the video renderer.
    func sampleBuffer(pts: Double, duration: Double?) throws -> CMSampleBuffer {
        guard let pixels = pixelBuffer() else { throw MediaFormatError.coreMedia(-1) }
        var format: CMVideoFormatDescription?
        var status = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                                                                  formatDescriptionOut: &format)
        guard status == noErr, let format else { throw MediaFormatError.coreMedia(status) }
        var timing = CMSampleTimingInfo(duration: duration.map { CMTime(seconds: $0, preferredTimescale: 90_000) } ?? .invalid,
                                        presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 90_000),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                                                          formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw MediaFormatError.coreMedia(status) }
        return sample
    }
}

/// An engine-side video decoder. Frames arrive in decode order; neither VP8 nor Theora
/// reorders, so each shown frame is output immediately.
nonisolated protocol SoftwareVideoDecoder: AnyObject {
    /// Decodes one compressed frame. Returns the picture to show, or nil for frames that
    /// aren't displayed (VP8 alternate references, Theora header packets) or can't be
    /// decoded yet (no keyframe seen since `reset`).
    func decode(_ frame: Data) throws -> DecodedPicture?
    /// Forgets reference frames (after a seek); decoding resumes at the next keyframe.
    func reset()
}
