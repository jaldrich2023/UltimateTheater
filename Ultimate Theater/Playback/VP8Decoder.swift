//
//  VP8Decoder.swift
//  Ultimate Theater
//
//  A VP8 video decoder written from the normative description in RFC 6386 ("VP8 Data
//  Format and Decoding Guide"), because macOS ships none. Each compressed frame (an IVF
//  frame or a WebM/Matroska block) becomes an 8-bit 4:2:0 picture. Supports key and inter
//  frames, golden and alternate references with sign bias, segmentation, both loop
//  filters with mode/reference deltas, every intra and inter prediction mode including
//  split motion vectors, six-tap and bilinear interpolation (versions 0-3), multiple token
//  partitions, and persistent or one-frame probability updates. Damaged input throws or
//  yields nil; it never reads outside the frame data or the reconstruction buffers.
//

import Foundation
import simd

// MARK: - Errors

/// Why a VP8 frame couldn't be decoded.
nonisolated enum VP8DecodingError: LocalizedError {
    case truncatedFrame
    case invalidStartCode
    case invalidDimensions
    case unsupportedVersion(Int)
    case invalidPartitions

    var errorDescription: String? {
        switch self {
        case .truncatedFrame: "The VP8 frame is truncated."
        case .invalidStartCode: "The VP8 key frame has an invalid start code."
        case .invalidDimensions: "The VP8 key frame has invalid dimensions."
        case .unsupportedVersion(let version): "VP8 bitstream version \(version) isn't supported."
        case .invalidPartitions: "The VP8 frame's partition sizes are invalid."
        }
    }
}

// MARK: - Boolean entropy decoder

/// The boolean arithmetic decoder of RFC 6386 section 7. Bits are kept left-aligned in a
/// 64-bit window so the input is refilled several bytes at a time. Reading past the end
/// of the partition yields zero bits, as the format specifies.
nonisolated struct VP8BoolDecoder {
    private var position: UnsafePointer<UInt8>
    private let end: UnsafePointer<UInt8>
    /// The top 8 bits line up with `range`; below them are `bitCount` look-ahead bits.
    private var value: UInt64 = 0
    private var bitCount = -8
    private var range: UInt32 = 255

    init(start: UnsafePointer<UInt8>, count: Int) {
        position = start
        end = start + max(count, 0)
        refill()
    }

    @inline(__always)
    private mutating func refill() {
        if end - position >= 8 {
            // Load eight bytes; the bits beyond the whole bytes counted here are genuine
            // stream bits, so OR-ing them in again on the next refill is harmless.
            let word = UInt64(bigEndian: UnsafeRawPointer(position).loadUnaligned(as: UInt64.self))
            value |= word >> UInt64(bitCount + 8)
            let bytes = (56 - bitCount) >> 3
            position += bytes
            bitCount += bytes << 3
        } else {
            while bitCount <= 48 {
                if position < end {
                    value |= UInt64(position.pointee) << UInt64(48 - bitCount)
                    position += 1
                }
                bitCount += 8
            }
        }
    }

    /// Reads one bool whose probability of being zero is `probability / 256`.
    @inline(__always)
    mutating func readBool(_ probability: UInt8) -> Bool {
        if bitCount < 8 { refill() }
        let split = 1 + (((range - 1) * UInt32(probability)) >> 8)
        let bigSplit = UInt64(split) << 56
        let bit: Bool
        if value >= bigSplit {
            range -= split
            value -= bigSplit
            bit = true
        } else {
            range = split
            bit = false
        }
        let shift = range.leadingZeroBitCount - 24
        range <<= UInt32(shift)
        value <<= UInt64(shift)
        bitCount -= shift
        return bit
    }

    /// Reads one evenly distributed bit.
    @inline(__always)
    mutating func readFlag() -> Bool { readBool(128) }

    /// Reads an unsigned `bits`-wide literal, most significant bit first (L(n)).
    mutating func readLiteral(_ bits: Int) -> Int {
        var result = 0
        for _ in 0..<bits { result = (result << 1) | (readBool(128) ? 1 : 0) }
        return result
    }

    /// Reads a magnitude of `bits` bits followed by a sign bit (1 = negative).
    mutating func readSignedMagnitude(_ bits: Int) -> Int {
        let magnitude = readLiteral(bits)
        return readFlag() ? -magnitude : magnitude
    }

    /// An optional signed value: a flag, then (if set) magnitude and sign.
    mutating func readOptionalSigned(_ bits: Int) -> Int {
        readFlag() ? readSignedMagnitude(bits) : 0
    }
}

// MARK: - Supporting types

/// A motion vector in quarter-pixel luma units (eighth-pixel chroma units).
nonisolated struct VP8MotionVector: Equatable {
    var row: Int32 = 0
    var column: Int32 = 0

    static let zero = VP8MotionVector()
    var isZero: Bool { row == 0 && column == 0 }
}

/// Per-macroblock prediction record kept for the current frame. A one-macroblock border
/// of default (intra, zero-vector) records surrounds the frame for neighbour lookups.
nonisolated struct VP8MacroblockInfo {
    /// 0-4 are the intra luma modes (DC, V, H, TM, B); 5-9 the inter modes.
    var lumaMode: UInt8 = 0
    var chromaMode: UInt8 = 0
    /// 0 = intra, 1 = last, 2 = golden, 3 = alternate reference.
    var reference: UInt8 = 0
    /// Loop filter level after segment and delta adjustments.
    var filterLevel: UInt8 = 0
    /// Whether the edges between this macroblock's subblocks are loop filtered.
    var filtersInnerEdges = false
    var motionVector = VP8MotionVector.zero
}

/// One reconstruction buffer: three planes sized to whole macroblocks.
nonisolated final class VP8FrameBuffer {
    let lumaWidth: Int
    let lumaHeight: Int
    let chromaWidth: Int
    let chromaHeight: Int
    let y: UnsafeMutablePointer<UInt8>
    let u: UnsafeMutablePointer<UInt8>
    let v: UnsafeMutablePointer<UInt8>

    init(macroblockColumns: Int, macroblockRows: Int) {
        lumaWidth = macroblockColumns * 16
        lumaHeight = macroblockRows * 16
        chromaWidth = macroblockColumns * 8
        chromaHeight = macroblockRows * 8
        y = .allocate(capacity: lumaWidth * lumaHeight)
        u = .allocate(capacity: chromaWidth * chromaHeight)
        v = .allocate(capacity: chromaWidth * chromaHeight)
        y.initialize(repeating: 0, count: lumaWidth * lumaHeight)
        u.initialize(repeating: 128, count: chromaWidth * chromaHeight)
        v.initialize(repeating: 128, count: chromaWidth * chromaHeight)
    }

    deinit {
        y.deallocate()
        u.deallocate()
        v.deallocate()
    }
}

/// Mode numbering shared by the prediction code.
nonisolated private enum VP8Mode {
    static let dc = 0, vertical = 1, horizontal = 2, trueMotion = 3, subblocks = 4
    static let nearest = 5, near = 6, zero = 7, new = 8, split = 9
    // Subblock intra modes (section 11.2 numbering).
    static let bDC = 0, bTM = 1, bVE = 2, bHE = 3, bLD = 4, bRD = 5, bVR = 6, bVL = 7, bHD = 8, bHU = 9
}

/// Header values that apply to a single frame.
nonisolated private struct VP8FrameHeader {
    var isKeyFrame = false
    var version = 0
    var showFrame = true
    var simpleFilter = false
    var filterLevel = 0
    var sharpness = 0
    var updateSegmentMap = false
    var refreshGolden = false
    var refreshAlternate = false
    var copyToGolden = 0
    var copyToAlternate = 0
    var refreshLast = true
    var refreshEntropy = true
    var skipEnabled = false
    var skipProbability: UInt8 = 0
    var intraProbability: UInt8 = 0
    var lastProbability: UInt8 = 0
    var goldenProbability: UInt8 = 0
}

/// Dequantization factors for one segment (section 14.1).
nonisolated private struct VP8Dequantizer {
    var lumaDC = 0, lumaAC = 0, y2DC = 0, y2AC = 0, chromaDC = 0, chromaAC = 0
}

// MARK: - Decoder

/// Decodes VP8 frames in decode order into `DecodedPicture`s.
nonisolated final class VP8Decoder: SoftwareVideoDecoder {
    /// Displayed size from the most recent key frame.
    private(set) var width = 0
    private(set) var height = 0
    /// Upscaling hints from the key frame header (0 = none, 1 = 5/4, 2 = 5/3, 3 = 2).
    /// Parsed for completeness; the picture is returned at its coded size.
    private(set) var horizontalScale = 0
    private(set) var verticalScale = 0

    // Probability layout inside `probabilities` (and its saved copy).
    private static let lumaModeOffset = 1056
    private static let chromaModeOffset = 1060
    private static let motionOffset = 1063
    private static let probabilityCount = 1101

    private let probabilities = UnsafeMutablePointer<UInt8>.allocate(capacity: probabilityCount)
    private let savedProbabilities = UnsafeMutablePointer<UInt8>.allocate(capacity: probabilityCount)

    // Constant tables copied into raw memory for the hot loops.
    private let bandOffsets = UnsafeMutablePointer<Int>.allocate(capacity: 16)
    private let zigzag = UnsafeMutablePointer<Int>.allocate(capacity: 16)
    private let sixTap = UnsafeMutablePointer<Int32>.allocate(capacity: 48)
    private let bilinear = UnsafeMutablePointer<Int32>.allocate(capacity: 48)
    private let keyFrameSubblockProbabilities = UnsafeMutablePointer<UInt8>.allocate(capacity: 900)

    // Scratch memory.
    private let coefficients = UnsafeMutablePointer<Int16>.allocate(capacity: 25 * 16)
    private let censusVectors = UnsafeMutablePointer<VP8MotionVector>.allocate(capacity: 4)
    private let censusCounts = UnsafeMutablePointer<Int>.allocate(capacity: 4)
    private let walshScratch = UnsafeMutablePointer<Int>.allocate(capacity: 16)
    private let lumaWork = UnsafeMutablePointer<UInt8>.allocate(capacity: 32 * 17)
    private let chromaEdges = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private let edgeScratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 32 * 24)
    private let filterScratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 16 * 24)
    private var input = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
    private var inputCapacity = 0

    // Geometry and per-macroblock state.
    private var macroblockColumns = 0
    private var macroblockRows = 0
    private var infoStride = 0
    private var macroblocks = UnsafeMutablePointer<VP8MacroblockInfo>.allocate(capacity: 1)
    private var blockVectors = UnsafeMutablePointer<VP8MotionVector>.allocate(capacity: 1)
    private var segmentMap = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
    private var aboveNonzero = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
    private var aboveSubblockModes = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
    private var allocatedMacroblocks = 0

    // Reference frames.
    private var pool: [VP8FrameBuffer] = []
    private var lastFrame: VP8FrameBuffer?
    private var goldenFrame: VP8FrameBuffer?
    private var alternateFrame: VP8FrameBuffer?
    private var hasKeyFrame = false

    // State that persists between frames.
    private var segmentationEnabled = false
    private var segmentAbsolute = false
    private var segmentQuantizer = [0, 0, 0, 0]
    private var segmentFilterLevel = [0, 0, 0, 0]
    private var segmentTreeProbabilities: [UInt8] = [255, 255, 255]
    private var filterDeltasEnabled = false
    private var referenceFilterDeltas = [0, 0, 0, 0]
    private var modeFilterDeltas = [0, 0, 0, 0]
    /// Sign bias per reference (index 2 golden, 3 alternate).
    private var signBias = [false, false, false, false]

    // Per-frame derived values.
    private var dequantizers = [VP8Dequantizer](repeating: VP8Dequantizer(), count: 4)
    private var segmentBaseFilterLevel = [0, 0, 0, 0]

    init() {
        for i in 0..<16 { bandOffsets[i] = VP8Tables.coefficientBands[i] * 33 }
        for i in 0..<16 { zigzag[i] = VP8Tables.zigzag[i] }
        for i in 0..<48 { sixTap[i] = VP8Tables.sixTapFilters[i] }
        for fraction in 0..<8 {
            for tap in 0..<6 { bilinear[fraction * 6 + tap] = 0 }
            bilinear[fraction * 6 + 2] = Int32(128 - 16 * fraction)
            bilinear[fraction * 6 + 3] = Int32(16 * fraction)
        }
        for i in 0..<900 { keyFrameSubblockProbabilities[i] = VP8Tables.keyFrameSubblockModeProbabilities[i] }
        coefficients.initialize(repeating: 0, count: 25 * 16)
        lumaWork.initialize(repeating: 0, count: 32 * 17)
        resetProbabilities()
    }

    deinit {
        probabilities.deallocate()
        savedProbabilities.deallocate()
        bandOffsets.deallocate()
        zigzag.deallocate()
        sixTap.deallocate()
        bilinear.deallocate()
        keyFrameSubblockProbabilities.deallocate()
        coefficients.deallocate()
        censusVectors.deallocate()
        censusCounts.deallocate()
        walshScratch.deallocate()
        lumaWork.deallocate()
        chromaEdges.deallocate()
        edgeScratch.deallocate()
        filterScratch.deallocate()
        input.deallocate()
        macroblocks.deallocate()
        blockVectors.deallocate()
        segmentMap.deallocate()
        aboveNonzero.deallocate()
        aboveSubblockModes.deallocate()
    }

    func reset() {
        lastFrame = nil
        goldenFrame = nil
        alternateFrame = nil
        hasKeyFrame = false
    }

    func decode(_ frame: Data) throws -> DecodedPicture? {
        let count = frame.count
        // A zero-length frame means "nothing new" in some muxers; show nothing.
        guard count > 0 else { return nil }
        if inputCapacity < count {
            input.deallocate()
            inputCapacity = count
            input = .allocate(capacity: inputCapacity)
        }
        frame.copyBytes(to: input, count: count)
        do {
            return try decodeFrame(UnsafePointer(input), count: count)
        } catch {
            // State may be half-updated: resynchronize at the next key frame.
            hasKeyFrame = false
            throw error
        }
    }

    // MARK: Frame level

    private func resetProbabilities() {
        for i in 0..<1056 { probabilities[i] = VP8Tables.defaultCoefficientProbabilities[i] }
        for i in 0..<4 { probabilities[Self.lumaModeOffset + i] = VP8Tables.defaultLumaModeProbabilities[i] }
        for i in 0..<3 { probabilities[Self.chromaModeOffset + i] = VP8Tables.defaultChromaModeProbabilities[i] }
        for i in 0..<38 { probabilities[Self.motionOffset + i] = VP8Tables.defaultMotionVectorProbabilities[i] }
    }

    /// Allocates the per-macroblock arrays and frame pool for a new frame size.
    private func configure(width newWidth: Int, height newHeight: Int) {
        width = newWidth
        height = newHeight
        macroblockColumns = (newWidth + 15) / 16
        macroblockRows = (newHeight + 15) / 16
        infoStride = macroblockColumns + 1
        let infoCount = infoStride * (macroblockRows + 1)
        macroblocks.deallocate()
        blockVectors.deallocate()
        segmentMap.deallocate()
        aboveNonzero.deallocate()
        aboveSubblockModes.deallocate()
        macroblocks = .allocate(capacity: infoCount)
        macroblocks.initialize(repeating: VP8MacroblockInfo(), count: infoCount)
        blockVectors = .allocate(capacity: infoCount * 16)
        blockVectors.initialize(repeating: .zero, count: infoCount * 16)
        segmentMap = .allocate(capacity: macroblockColumns * macroblockRows)
        segmentMap.initialize(repeating: 0, count: macroblockColumns * macroblockRows)
        aboveNonzero = .allocate(capacity: macroblockColumns * 9)
        aboveSubblockModes = .allocate(capacity: macroblockColumns * 4)
        allocatedMacroblocks = infoCount
        pool = []
        lastFrame = nil
        goldenFrame = nil
        alternateFrame = nil
    }

    private func decodeFrame(_ data: UnsafePointer<UInt8>, count: Int) throws -> DecodedPicture? {
        guard count >= 3 else { throw VP8DecodingError.truncatedFrame }
        let tag = Int(data[0]) | Int(data[1]) << 8 | Int(data[2]) << 16
        var header = VP8FrameHeader()
        header.isKeyFrame = tag & 1 == 0
        header.version = (tag >> 1) & 7
        header.showFrame = (tag >> 4) & 1 == 1
        let firstPartitionSize = (tag >> 5) & 0x7FFFF
        guard header.version <= 3 else { throw VP8DecodingError.unsupportedVersion(header.version) }

        var offset = 3
        if header.isKeyFrame {
            guard count >= 10 else { throw VP8DecodingError.truncatedFrame }
            guard data[3] == 0x9D, data[4] == 0x01, data[5] == 0x2A else { throw VP8DecodingError.invalidStartCode }
            let horizontal = Int(data[6]) | Int(data[7]) << 8
            let vertical = Int(data[8]) | Int(data[9]) << 8
            let newWidth = horizontal & 0x3FFF
            let newHeight = vertical & 0x3FFF
            guard newWidth > 0, newHeight > 0 else { throw VP8DecodingError.invalidDimensions }
            horizontalScale = horizontal >> 14
            verticalScale = vertical >> 14
            // Corrupt headers could otherwise ask for gigabytes; 8192x8192 covers 8K video.
            guard newWidth * newHeight <= 8192 * 8192 else { throw VP8DecodingError.invalidDimensions }
            if newWidth != width || newHeight != height || allocatedMacroblocks == 0 {
                configure(width: newWidth, height: newHeight)
            }
            offset = 10
        } else if !hasKeyFrame || allocatedMacroblocks == 0 {
            return nil
        }
        guard firstPartitionSize <= count - offset else { throw VP8DecodingError.truncatedFrame }

        var bd = VP8BoolDecoder(start: data + offset, count: firstPartitionSize)
        let partitionCount = parseHeader(&bd, &header)

        // Token partitions follow the first partition, preceded by a table of sizes.
        var partitions: [VP8BoolDecoder] = []
        var cursor = offset + firstPartitionSize
        let tableSize = 3 * (partitionCount - 1)
        guard count - cursor >= tableSize else { throw VP8DecodingError.invalidPartitions }
        let table = cursor
        cursor += tableSize
        for index in 0..<partitionCount {
            let size: Int
            if index < partitionCount - 1 {
                let entry = table + 3 * index
                size = Int(data[entry]) | Int(data[entry + 1]) << 8 | Int(data[entry + 2]) << 16
                guard size <= count - cursor else { throw VP8DecodingError.invalidPartitions }
            } else {
                size = count - cursor
            }
            partitions.append(VP8BoolDecoder(start: data + cursor, count: size))
            cursor += size
        }

        if !header.isKeyFrame {
            guard lastFrame != nil, goldenFrame != nil, alternateFrame != nil else { return nil }
        }
        // Reconstruct into a buffer no reference uses; at most four are ever needed.
        let current: VP8FrameBuffer
        if let free = pool.first(where: { $0 !== lastFrame && $0 !== goldenFrame && $0 !== alternateFrame }) {
            current = free
        } else {
            current = VP8FrameBuffer(macroblockColumns: macroblockColumns, macroblockRows: macroblockRows)
            pool.append(current)
        }

        decodeMacroblocks(header: header, modes: &bd, partitions: &partitions, frame: current)
        if header.filterLevel > 0 {
            loopFilter(frame: current, header: header)
        }

        // Reference updates (section 9.7), using the references as they were before this frame.
        let previousLast = lastFrame
        let previousGolden = goldenFrame
        let previousAlternate = alternateFrame
        if header.isKeyFrame {
            lastFrame = current
            goldenFrame = current
            alternateFrame = current
        } else {
            if header.copyToGolden == 1 { goldenFrame = previousLast }
            if header.copyToGolden == 2 { goldenFrame = previousAlternate }
            if header.copyToAlternate == 1 { alternateFrame = previousLast }
            if header.copyToAlternate == 2 { alternateFrame = previousGolden }
            if header.refreshGolden { goldenFrame = current }
            if header.refreshAlternate { alternateFrame = current }
            if header.refreshLast { lastFrame = current }
        }
        if !header.refreshEntropy {
            probabilities.update(from: savedProbabilities, count: Self.probabilityCount)
        }
        hasKeyFrame = true

        guard header.showFrame else { return nil }
        return picture(from: current)
    }

    /// Copies a reconstruction buffer into a picture (padded strides, real dimensions).
    private func picture(from frame: VP8FrameBuffer) -> DecodedPicture {
        let y = [UInt8](UnsafeBufferPointer(start: frame.y, count: frame.lumaWidth * frame.lumaHeight))
        let u = [UInt8](UnsafeBufferPointer(start: frame.u, count: frame.chromaWidth * frame.chromaHeight))
        let v = [UInt8](UnsafeBufferPointer(start: frame.v, count: frame.chromaWidth * frame.chromaHeight))
        return DecodedPicture(width: width, height: height, y: y, u: u, v: v,
                              yStride: frame.lumaWidth, chromaStride: frame.chromaWidth)
    }

    // MARK: Frame header (sections 9 and 19.2)

    /// Parses the frame header from the first partition and returns the token partition count.
    private func parseHeader(_ bd: inout VP8BoolDecoder, _ header: inout VP8FrameHeader) -> Int {
        if header.isKeyFrame {
            resetProbabilities()
            segmentAbsolute = false
            segmentQuantizer = [0, 0, 0, 0]
            segmentFilterLevel = [0, 0, 0, 0]
            referenceFilterDeltas = [0, 0, 0, 0]
            modeFilterDeltas = [0, 0, 0, 0]
            signBias = [false, false, false, false]
            _ = bd.readFlag()  // color space (0 = BT.601; 1 is reserved)
            _ = bd.readFlag()  // clamping type: reconstruction always clamps, which is valid either way
        }

        segmentationEnabled = bd.readFlag()
        if segmentationEnabled {
            header.updateSegmentMap = bd.readFlag()
            let updateData = bd.readFlag()
            if updateData {
                segmentAbsolute = bd.readFlag()
                for i in 0..<4 { segmentQuantizer[i] = bd.readOptionalSigned(7) }
                for i in 0..<4 { segmentFilterLevel[i] = bd.readOptionalSigned(6) }
            }
            if header.updateSegmentMap {
                for i in 0..<3 { segmentTreeProbabilities[i] = bd.readFlag() ? UInt8(bd.readLiteral(8)) : 255 }
            }
        }
        if header.isKeyFrame && !header.updateSegmentMap {
            segmentMap.update(repeating: 0, count: macroblockColumns * macroblockRows)
        }

        header.simpleFilter = bd.readFlag()
        header.filterLevel = bd.readLiteral(6)
        header.sharpness = bd.readLiteral(3)
        filterDeltasEnabled = bd.readFlag()
        if filterDeltasEnabled && bd.readFlag() {
            for i in 0..<4 where bd.readFlag() { referenceFilterDeltas[i] = bd.readSignedMagnitude(6) }
            for i in 0..<4 where bd.readFlag() { modeFilterDeltas[i] = bd.readSignedMagnitude(6) }
        }
        let partitionCount = 1 << bd.readLiteral(2)

        // Quantizer indices (section 9.6) and the per-segment factors they imply.
        let baseIndex = bd.readLiteral(7)
        let lumaDCDelta = bd.readOptionalSigned(4)
        let y2DCDelta = bd.readOptionalSigned(4)
        let y2ACDelta = bd.readOptionalSigned(4)
        let chromaDCDelta = bd.readOptionalSigned(4)
        let chromaACDelta = bd.readOptionalSigned(4)
        for segment in 0..<4 {
            var index = baseIndex
            if segmentationEnabled {
                index = segmentAbsolute ? segmentQuantizer[segment] : baseIndex + segmentQuantizer[segment]
            }
            index = min(max(index, 0), 127)
            func dc(_ delta: Int) -> Int { Int(VP8Tables.dcQuantizer[min(max(index + delta, 0), 127)]) }
            func ac(_ delta: Int) -> Int { Int(VP8Tables.acQuantizer[min(max(index + delta, 0), 127)]) }
            var factors = VP8Dequantizer()
            factors.lumaDC = dc(lumaDCDelta)
            factors.lumaAC = ac(0)
            factors.y2DC = dc(y2DCDelta) * 2
            factors.y2AC = max(ac(y2ACDelta) * 155 / 100, 8)
            factors.chromaDC = min(dc(chromaDCDelta), 132)
            factors.chromaAC = ac(chromaACDelta)
            dequantizers[segment] = factors

            var level = header.filterLevel
            if segmentationEnabled {
                level = segmentAbsolute ? segmentFilterLevel[segment] : level + segmentFilterLevel[segment]
                level = min(max(level, 0), 63)
            }
            segmentBaseFilterLevel[segment] = level
        }

        if header.isKeyFrame {
            header.refreshEntropy = bd.readFlag()
            header.refreshGolden = true
            header.refreshAlternate = true
            header.refreshLast = true
        } else {
            header.refreshGolden = bd.readFlag()
            header.refreshAlternate = bd.readFlag()
            if !header.refreshGolden { header.copyToGolden = bd.readLiteral(2) }
            if !header.refreshAlternate { header.copyToAlternate = bd.readLiteral(2) }
            signBias[2] = bd.readFlag()
            signBias[3] = bd.readFlag()
            header.refreshEntropy = bd.readFlag()
            header.refreshLast = bd.readFlag()
        }
        if !header.refreshEntropy {
            // These probabilities last for this frame only.
            savedProbabilities.update(from: probabilities, count: Self.probabilityCount)
        }

        // Coefficient probability updates (section 13.4).
        for i in 0..<1056 where bd.readBool(VP8Tables.coefficientUpdateProbabilities[i]) {
            probabilities[i] = UInt8(bd.readLiteral(8))
        }

        header.skipEnabled = bd.readFlag()
        if header.skipEnabled { header.skipProbability = UInt8(bd.readLiteral(8)) }
        if !header.isKeyFrame {
            header.intraProbability = UInt8(bd.readLiteral(8))
            header.lastProbability = UInt8(bd.readLiteral(8))
            header.goldenProbability = UInt8(bd.readLiteral(8))
            if bd.readFlag() {
                for i in 0..<4 { probabilities[Self.lumaModeOffset + i] = UInt8(bd.readLiteral(8)) }
            }
            if bd.readFlag() {
                for i in 0..<3 { probabilities[Self.chromaModeOffset + i] = UInt8(bd.readLiteral(8)) }
            }
            // Motion vector probability updates (section 17.2).
            for i in 0..<38 where bd.readBool(VP8Tables.motionVectorUpdateProbabilities[i]) {
                let value = bd.readLiteral(7)
                probabilities[Self.motionOffset + i] = value == 0 ? 1 : UInt8(value << 1)
            }
        }
        return partitionCount
    }

    // MARK: Macroblock loop

    private func decodeMacroblocks(header: VP8FrameHeader, modes bd: inout VP8BoolDecoder,
                                   partitions: inout [VP8BoolDecoder], frame: VP8FrameBuffer) {
        aboveNonzero.update(repeating: 0, count: macroblockColumns * 9)
        aboveSubblockModes.update(repeating: 0, count: macroblockColumns * 4)
        var leftNonzero: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0, 0, 0, 0, 0, 0)
        var leftModes: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
        var subblockModes = [UInt8](repeating: 0, count: 16)
        var eobs = [UInt8](repeating: 0, count: 25)

        withUnsafeMutableBytes(of: &leftNonzero) { leftNonzeroRaw in
            withUnsafeMutableBytes(of: &leftModes) { leftModesRaw in
                subblockModes.withUnsafeMutableBufferPointer { modesBuffer in
                    eobs.withUnsafeMutableBufferPointer { eobBuffer in
                        guard let left = leftNonzeroRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                              let leftSubblocks = leftModesRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                              let subblocks = modesBuffer.baseAddress,
                              let eob = eobBuffer.baseAddress else { return }
                        for mbRow in 0..<macroblockRows {
                            var tokens = partitions[mbRow % partitions.count]
                            left.update(repeating: 0, count: 9)
                            leftSubblocks.update(repeating: 0, count: 4)
                            for mbColumn in 0..<macroblockColumns {
                                decodeMacroblock(column: mbColumn, row: mbRow, header: header, modes: &bd,
                                                 tokens: &tokens, frame: frame, leftNonzero: left,
                                                 leftSubblockModes: leftSubblocks, subblockModes: subblocks, eobs: eob)
                            }
                            partitions[mbRow % partitions.count] = tokens
                        }
                    }
                }
            }
        }
    }

    /// Parses one macroblock's prediction record and residual, then reconstructs it.
    private func decodeMacroblock(column: Int, row: Int, header: VP8FrameHeader, modes bd: inout VP8BoolDecoder,
                                  tokens: inout VP8BoolDecoder, frame: VP8FrameBuffer,
                                  leftNonzero: UnsafeMutablePointer<UInt8>, leftSubblockModes: UnsafeMutablePointer<UInt8>,
                                  subblockModes: UnsafeMutablePointer<UInt8>, eobs: UnsafeMutablePointer<UInt8>) {
        let infoIndex = (row + 1) * infoStride + column + 1
        let info = macroblocks + infoIndex
        let vectors = blockVectors + infoIndex * 16
        let mapIndex = row * macroblockColumns + column

        // Segment and skip flag (section 19.3).
        if header.updateSegmentMap {
            let p = segmentTreeProbabilities
            let segment = bd.readBool(p[0]) ? 2 + (bd.readBool(p[2]) ? 1 : 0) : (bd.readBool(p[1]) ? 1 : 0)
            segmentMap[mapIndex] = UInt8(segment)
        }
        let segment = segmentationEnabled ? Int(segmentMap[mapIndex]) : 0
        let skip = header.skipEnabled ? bd.readBool(header.skipProbability) : false

        var record = VP8MacroblockInfo()
        if header.isKeyFrame {
            parseKeyFrameModes(&bd, record: &record, column: column, leftSubblockModes: leftSubblockModes,
                               subblockModes: subblockModes)
            for i in 0..<16 { vectors[i] = .zero }
        } else if bd.readBool(header.intraProbability) {
            parseInterModes(&bd, header: header, record: &record, column: column, row: row, vectors: vectors)
        } else {
            parseIntraModes(&bd, record: &record, subblockModes: subblockModes)
            for i in 0..<16 { vectors[i] = .zero }
        }

        // Residual tokens (section 13).
        let hasY2 = record.lumaMode != UInt8(VP8Mode.subblocks) && record.lumaMode != UInt8(VP8Mode.split)
        let above = aboveNonzero + column * 9
        var hasCoefficients = false
        if skip {
            for i in 0..<8 {
                above[i] = 0
                leftNonzero[i] = 0
            }
            if hasY2 {
                above[8] = 0
                leftNonzero[8] = 0
            }
        } else {
            hasCoefficients = readResidual(&tokens, factors: dequantizers[segment], hasY2: hasY2,
                                           above: above, left: leftNonzero, eobs: eobs)
        }

        // Loop filter level (section 9.3/9.4 deltas).
        var level = segmentBaseFilterLevel[segment]
        if filterDeltasEnabled {
            level += referenceFilterDeltas[Int(record.reference)]
            if record.reference == 0 {
                if record.lumaMode == UInt8(VP8Mode.subblocks) { level += modeFilterDeltas[0] }
            } else if record.lumaMode == UInt8(VP8Mode.zero) {
                level += modeFilterDeltas[1]
            } else if record.lumaMode == UInt8(VP8Mode.split) {
                level += modeFilterDeltas[3]
            } else {
                level += modeFilterDeltas[2]
            }
            level = min(max(level, 0), 63)
        }
        record.filterLevel = UInt8(level)
        record.filtersInnerEdges = !hasY2 || hasCoefficients
        info.pointee = record

        // Reconstruction.
        if record.reference == 0 {
            reconstructIntra(record: record, column: column, row: row, frame: frame, subblockModes: subblockModes,
                             residual: hasCoefficients, eobs: eobs)
        } else {
            let reference: VP8FrameBuffer?
            switch record.reference {
            case 1: reference = lastFrame
            case 2: reference = goldenFrame
            default: reference = alternateFrame
            }
            if let reference {
                predictInter(record: record, vectors: vectors, column: column, row: row, reference: reference,
                             frame: frame, version: header.version)
            }
            if hasCoefficients {
                addInterResidual(column: column, row: row, frame: frame, eobs: eobs)
            }
        }
        if hasCoefficients {
            coefficients.update(repeating: 0, count: 25 * 16)
        }
    }

    // MARK: VP8Mode parsing (sections 11, 16, 17)

    private func parseKeyFrameModes(_ bd: inout VP8BoolDecoder, record: inout VP8MacroblockInfo, column: Int,
                                    leftSubblockModes: UnsafeMutablePointer<UInt8>,
                                    subblockModes: UnsafeMutablePointer<UInt8>) {
        let p = VP8Tables.keyFrameLumaModeProbabilities
        let lumaMode: Int
        if !bd.readBool(p[0]) {
            lumaMode = VP8Mode.subblocks
        } else if !bd.readBool(p[1]) {
            lumaMode = bd.readBool(p[2]) ? VP8Mode.vertical : VP8Mode.dc
        } else {
            lumaMode = bd.readBool(p[3]) ? VP8Mode.trueMotion : VP8Mode.horizontal
        }
        record.lumaMode = UInt8(lumaMode)
        let aboveModes = aboveSubblockModes + column * 4
        if lumaMode == VP8Mode.subblocks {
            for b in 0..<16 {
                let aboveMode = b < 4 ? Int(aboveModes[b]) : Int(subblockModes[b - 4])
                let leftMode = b & 3 == 0 ? Int(leftSubblockModes[b >> 2]) : Int(subblockModes[b - 1])
                let probabilities = UnsafePointer(keyFrameSubblockProbabilities + (aboveMode * 10 + leftMode) * 9)
                subblockModes[b] = UInt8(readSubblockMode(&bd, probabilities))
            }
        } else {
            let implied: Int
            switch lumaMode {
            case VP8Mode.vertical: implied = VP8Mode.bVE
            case VP8Mode.horizontal: implied = VP8Mode.bHE
            case VP8Mode.trueMotion: implied = VP8Mode.bTM
            default: implied = VP8Mode.bDC
            }
            for b in 0..<16 { subblockModes[b] = UInt8(implied) }
        }
        for i in 0..<4 {
            aboveModes[i] = subblockModes[12 + i]
            leftSubblockModes[i] = subblockModes[i * 4 + 3]
        }
        let q = VP8Tables.keyFrameChromaModeProbabilities
        record.chromaMode = UInt8(readChromaMode(&bd, q[0], q[1], q[2]))
    }

    private func parseIntraModes(_ bd: inout VP8BoolDecoder, record: inout VP8MacroblockInfo,
                                 subblockModes: UnsafeMutablePointer<UInt8>) {
        let p = probabilities + Self.lumaModeOffset
        let lumaMode: Int
        if !bd.readBool(p[0]) {
            lumaMode = VP8Mode.dc
        } else if !bd.readBool(p[1]) {
            lumaMode = bd.readBool(p[2]) ? VP8Mode.horizontal : VP8Mode.vertical
        } else {
            lumaMode = bd.readBool(p[3]) ? VP8Mode.subblocks : VP8Mode.trueMotion
        }
        record.lumaMode = UInt8(lumaMode)
        if lumaMode == VP8Mode.subblocks {
            VP8Tables.subblockModeProbabilities.withUnsafeBufferPointer { fixed in
                guard let base = fixed.baseAddress else { return }
                for b in 0..<16 { subblockModes[b] = UInt8(readSubblockMode(&bd, base)) }
            }
        }
        let q = probabilities + Self.chromaModeOffset
        record.chromaMode = UInt8(readChromaMode(&bd, q[0], q[1], q[2]))
    }

    /// Reads a subblock intra mode with `bmode_tree` (section 11.2).
    private func readSubblockMode(_ bd: inout VP8BoolDecoder, _ p: UnsafePointer<UInt8>) -> Int {
        if !bd.readBool(p[0]) { return VP8Mode.bDC }
        if !bd.readBool(p[1]) { return VP8Mode.bTM }
        if !bd.readBool(p[2]) { return VP8Mode.bVE }
        if !bd.readBool(p[3]) {
            if !bd.readBool(p[4]) { return VP8Mode.bHE }
            return bd.readBool(p[5]) ? VP8Mode.bVR : VP8Mode.bRD
        }
        if !bd.readBool(p[6]) { return VP8Mode.bLD }
        if !bd.readBool(p[7]) { return VP8Mode.bVL }
        return bd.readBool(p[8]) ? VP8Mode.bHU : VP8Mode.bHD
    }

    /// Reads a chroma mode with `uv_mode_tree` (section 11.4).
    private func readChromaMode(_ bd: inout VP8BoolDecoder, _ p0: UInt8, _ p1: UInt8, _ p2: UInt8) -> Int {
        if !bd.readBool(p0) { return VP8Mode.dc }
        if !bd.readBool(p1) { return VP8Mode.vertical }
        return bd.readBool(p2) ? VP8Mode.trueMotion : VP8Mode.horizontal
    }

    /// Reads one motion vector component (section 17.1) using 19 probabilities at `p`.
    private func readVectorComponent(_ bd: inout VP8BoolDecoder, _ p: UnsafeMutablePointer<UInt8>) -> Int32 {
        var magnitude: Int32 = 0
        if bd.readBool(p[0]) {
            for i in 0..<3 where bd.readBool(p[9 + i]) { magnitude += 1 << Int32(i) }
            for i in stride(from: 9, to: 3, by: -1) where bd.readBool(p[9 + i]) { magnitude += 1 << Int32(i) }
            if magnitude & 0xFFF0 == 0 || bd.readBool(p[9 + 3]) { magnitude += 8 }
        } else if !bd.readBool(p[2]) {
            magnitude = !bd.readBool(p[3]) ? (bd.readBool(p[4]) ? 1 : 0) : (bd.readBool(p[5]) ? 3 : 2)
        } else {
            magnitude = !bd.readBool(p[6]) ? (bd.readBool(p[7]) ? 5 : 4) : (bd.readBool(p[8]) ? 7 : 6)
        }
        return magnitude != 0 && bd.readBool(p[1]) ? -magnitude : magnitude
    }

    private func readMotionVector(_ bd: inout VP8BoolDecoder) -> VP8MotionVector {
        let row = readVectorComponent(&bd, probabilities + Self.motionOffset)
        let column = readVectorComponent(&bd, probabilities + Self.motionOffset + 19)
        return VP8MotionVector(row: row, column: column)
    }

    /// Parses an inter-predicted macroblock: reference, mode, and motion vectors (section 16.2-16.4).
    private func parseInterModes(_ bd: inout VP8BoolDecoder, header: VP8FrameHeader, record: inout VP8MacroblockInfo,
                                 column: Int, row: Int, vectors: UnsafeMutablePointer<VP8MotionVector>) {
        let reference = bd.readBool(header.lastProbability) ? (bd.readBool(header.goldenProbability) ? 3 : 2) : 1
        record.reference = UInt8(reference)

        // Survey the above, left, and above-left neighbours (section 16.3).
        let here = (row + 1) * infoStride + column + 1
        let found = censusVectors
        let counts = censusCounts
        for i in 0..<4 {
            found[i] = .zero
            counts[i] = 0
        }
        var slot = 0
        for n in 0..<3 {
            // Above (weight 2), left (weight 2), then above-left (weight 1).
            let neighbour = macroblocks[n == 0 ? here - infoStride : (n == 1 ? here - 1 : here - infoStride - 1)]
            let weight = n == 2 ? 1 : 2
            guard neighbour.reference != 0 else { continue }
            var vector = neighbour.motionVector
            if vector.isZero {
                counts[0] += weight
                continue
            }
            if signBias[Int(neighbour.reference)] != signBias[reference] {
                vector.row = -vector.row
                vector.column = -vector.column
            }
            if vector != found[slot] {
                slot += 1
                found[slot] = vector
            }
            counts[slot] += weight
        }
        // With three distinct vectors, merge the above-left one into "nearest" if equal.
        if counts[3] > 0 && found[3] == found[1] { counts[1] += 1 }
        let a = macroblocks[here - infoStride], l = macroblocks[here - 1], al = macroblocks[here - infoStride - 1]
        let split = UInt8(VP8Mode.split)
        counts[3] = (a.lumaMode == split ? 2 : 0) + (l.lumaMode == split ? 2 : 0) + (al.lumaMode == split ? 1 : 0)
        if counts[2] > counts[1] {
            swap(&counts[1], &counts[2])
            swap(&found[1], &found[2])
        }
        if counts[1] >= counts[0] { found[0] = found[1] }

        // Clamp predictors so the block stays within 16 pixels of the frame (quarter pixels).
        let minColumn = Int32(-(column * 16 + 16) * 4), maxColumn = Int32(((macroblockColumns - 1 - column) * 16 + 16) * 4)
        let minRow = Int32(-(row * 16 + 16) * 4), maxRow = Int32(((macroblockRows - 1 - row) * 16 + 16) * 4)
        func clamped(_ v: VP8MotionVector) -> VP8MotionVector {
            VP8MotionVector(row: min(max(v.row, minRow), maxRow), column: min(max(v.column, minColumn), maxColumn))
        }
        let best = clamped(found[0])

        let p0 = VP8Tables.modeContexts[counts[0] * 4]
        let p1 = VP8Tables.modeContexts[counts[1] * 4 + 1]
        let p2 = VP8Tables.modeContexts[counts[2] * 4 + 2]
        let p3 = VP8Tables.modeContexts[counts[3] * 4 + 3]
        var mode: Int
        var vector = VP8MotionVector.zero
        if !bd.readBool(p0) {
            mode = VP8Mode.zero
        } else if !bd.readBool(p1) {
            mode = VP8Mode.nearest
            vector = clamped(found[1])
        } else if !bd.readBool(p2) {
            mode = VP8Mode.near
            vector = clamped(found[2])
        } else if !bd.readBool(p3) {
            mode = VP8Mode.new
            let delta = readMotionVector(&bd)
            vector = VP8MotionVector(row: best.row + delta.row, column: best.column + delta.column)
        } else {
            mode = VP8Mode.split
            parseSplit(&bd, best: best, column: column, row: row, vectors: vectors)
            vector = vectors[15]
        }
        record.lumaMode = UInt8(mode)
        record.motionVector = vector
        if mode != VP8Mode.split {
            for i in 0..<16 { vectors[i] = vector }
        }
    }

    /// Parses SPLITMV partitioning and per-partition vectors (section 16.4).
    private func parseSplit(_ bd: inout VP8BoolDecoder, best: VP8MotionVector, column: Int, row: Int,
                            vectors: UnsafeMutablePointer<VP8MotionVector>) {
        let p = VP8Tables.splitPartitionProbabilities
        // Partition layouts: 0 = top/bottom, 1 = left/right, 2 = quarters, 3 = sixteen.
        let layout: Int
        if !bd.readBool(p[0]) {
            layout = 3
        } else if !bd.readBool(p[1]) {
            layout = 2
        } else {
            layout = bd.readBool(p[2]) ? 1 : 0
        }
        let partCount = layout == 3 ? 16 : (layout == 2 ? 4 : 2)
        let here = (row + 1) * infoStride + column + 1
        let leftVectors = blockVectors + (here - 1) * 16
        let aboveVectors = blockVectors + (here - infoStride) * 16

        func part(of block: Int) -> Int {
            switch layout {
            case 0: return block >> 3
            case 1: return (block & 3) >> 1
            case 2: return (block >> 3) * 2 + ((block & 3) >> 1)
            default: return block
            }
        }
        for partIndex in 0..<partCount {
            var first = 0
            while part(of: first) != partIndex { first += 1 }
            let leftVector = first & 3 == 0 ? leftVectors[first + 3] : vectors[first - 1]
            let aboveVector = first < 4 ? aboveVectors[first + 12] : vectors[first - 4]
            let context: Int
            if leftVector == aboveVector {
                context = aboveVector.isZero ? 4 : 3
            } else if aboveVector.isZero {
                context = 2
            } else if leftVector.isZero {
                context = 1
            } else {
                context = 0
            }
            let q = context * 3
            let probabilities = VP8Tables.subblockReferenceProbabilities
            let vector: VP8MotionVector
            if !bd.readBool(probabilities[q]) {
                vector = leftVector
            } else if !bd.readBool(probabilities[q + 1]) {
                vector = aboveVector
            } else if !bd.readBool(probabilities[q + 2]) {
                vector = .zero
            } else {
                let delta = readMotionVector(&bd)
                vector = VP8MotionVector(row: best.row + delta.row, column: best.column + delta.column)
            }
            for block in first..<16 where part(of: block) == partIndex { vectors[block] = vector }
        }
    }

    // MARK: Residual tokens (section 13)

    /// Reads all coefficient blocks of a macroblock into `coefficients`, dequantized.
    /// Returns whether any block had a token other than an immediate end of block.
    private func readResidual(_ bd: inout VP8BoolDecoder, factors: VP8Dequantizer, hasY2: Bool,
                              above: UnsafeMutablePointer<UInt8>, left: UnsafeMutablePointer<UInt8>,
                              eobs: UnsafeMutablePointer<UInt8>) -> Bool {
        let coefficientProbabilities = UnsafePointer(probabilities)
        var any = false
        var lumaType = 3
        var first = 0
        if hasY2 {
            let context = Int(above[8]) + Int(left[8])
            let eob = readBlock(&bd, coefficientProbabilities + 1 * 264, first: 0, context: context,
                                dcFactor: factors.y2DC, acFactor: factors.y2AC, output: coefficients + 24 * 16)
            let flag: UInt8 = eob > 0 ? 1 : 0
            above[8] = flag
            left[8] = flag
            eobs[24] = UInt8(eob)
            any = eob > 0
            lumaType = 0
            first = 1
        }
        let lumaProbabilities = coefficientProbabilities + lumaType * 264
        for b in 0..<16 {
            let x = b & 3, y = b >> 2
            let context = Int(above[x]) + Int(left[y])
            let eob = readBlock(&bd, lumaProbabilities, first: first, context: context,
                                dcFactor: factors.lumaDC, acFactor: factors.lumaAC, output: coefficients + b * 16)
            let flag: UInt8 = eob > first ? 1 : 0
            above[x] = flag
            left[y] = flag
            eobs[b] = UInt8(eob)
            if eob > first { any = true }
        }
        let chromaProbabilities = coefficientProbabilities + 2 * 264
        for b in 16..<24 {
            let base = b < 20 ? 4 : 6
            let x = b & 1, y = (b >> 1) & 1
            let context = Int(above[base + x]) + Int(left[base + y])
            let eob = readBlock(&bd, chromaProbabilities, first: 0, context: context,
                                dcFactor: factors.chromaDC, acFactor: factors.chromaAC, output: coefficients + b * 16)
            let flag: UInt8 = eob > 0 ? 1 : 0
            above[base + x] = flag
            left[base + y] = flag
            eobs[b] = UInt8(eob)
            if eob > 0 { any = true }
        }
        return any
    }

    /// Decodes one block's tokens (section 13.2) and returns the scan position after the
    /// last token read (`first` if the block ended immediately).
    @inline(__always)
    private func readBlock(_ bd: inout VP8BoolDecoder, _ probabilities: UnsafePointer<UInt8>, first: Int, context: Int,
                           dcFactor: Int, acFactor: Int, output: UnsafeMutablePointer<Int16>) -> Int {
        var i = first
        var p = probabilities + bandOffsets[i] + context * 11
        if !bd.readBool(p[0]) { return i }
        while true {
            if !bd.readBool(p[1]) {
                // DCT_0: the next token can't be an end of block.
                i += 1
                if i == 16 { return 16 }
                p = probabilities + bandOffsets[i]
                continue
            }
            var value: Int
            let nextContext: Int
            if !bd.readBool(p[2]) {
                value = 1
                nextContext = 1
            } else {
                nextContext = 2
                if !bd.readBool(p[3]) {
                    if !bd.readBool(p[4]) {
                        value = 2
                    } else {
                        value = bd.readBool(p[5]) ? 4 : 3
                    }
                } else if !bd.readBool(p[6]) {
                    if !bd.readBool(p[7]) {
                        value = 5 + (bd.readBool(159) ? 1 : 0)
                    } else {
                        value = 7 + (bd.readBool(165) ? 2 : 0)
                        value += bd.readBool(145) ? 1 : 0
                    }
                } else {
                    let table: [UInt8]
                    let base: Int
                    if !bd.readBool(p[8]) {
                        if !bd.readBool(p[9]) {
                            table = VP8Tables.category3Probabilities
                            base = 11
                        } else {
                            table = VP8Tables.category4Probabilities
                            base = 19
                        }
                    } else if !bd.readBool(p[10]) {
                        table = VP8Tables.category5Probabilities
                        base = 35
                    } else {
                        table = VP8Tables.category6Probabilities
                        base = 67
                    }
                    var extra = 0
                    for probability in table { extra = extra << 1 | (bd.readBool(probability) ? 1 : 0) }
                    value = base + extra
                }
            }
            let level = bd.readFlag() ? -value : value
            output[zigzag[i]] = Int16(truncatingIfNeeded: level * (i > 0 ? acFactor : dcFactor))
            i += 1
            if i == 16 { return 16 }
            p = probabilities + bandOffsets[i] + nextContext * 11
            if !bd.readBool(p[0]) { return i }
        }
    }

    // MARK: Intra reconstruction (section 12)

    private func reconstructIntra(record: VP8MacroblockInfo, column: Int, row: Int, frame: VP8FrameBuffer,
                                  subblockModes: UnsafeMutablePointer<UInt8>, residual: Bool,
                                  eobs: UnsafeMutablePointer<UInt8>) {
        // Luma is built in a work area whose row above and column to the left hold the edge pixels.
        let stride = 32
        let origin = lumaWork + stride + 4
        let planeStride = frame.lumaWidth
        let destination = frame.y + row * 16 * planeStride + column * 16
        let aboveRow = origin - stride
        if row == 0 {
            for i in -1..<20 { aboveRow[i] = 127 }
        } else {
            let source = destination - planeStride
            for i in 0..<16 { aboveRow[i] = source[i] }
            aboveRow[-1] = column == 0 ? 129 : source[-1]
            if column < macroblockColumns - 1 {
                for i in 16..<20 { aboveRow[i] = source[i] }
            } else {
                for i in 16..<20 { aboveRow[i] = source[15] }
            }
        }
        for r in 0..<16 {
            origin[r * stride - 1] = column == 0 ? 129 : destination[r * planeStride - 1]
        }

        let lumaMode = Int(record.lumaMode)
        if lumaMode == VP8Mode.subblocks {
            // Subblocks on the right edge use the macroblock's above-right pixels at every row.
            for r in 0..<3 {
                for i in 16..<20 { origin[(r * 4 + 3) * stride + i] = aboveRow[i] }
            }
            for b in 0..<16 {
                let block = origin + (b >> 2) * 4 * stride + (b & 3) * 4
                VP8Prediction.predictSubblock(block, stride: stride, mode: Int(subblockModes[b]))
                if residual {
                    addBlock(coefficients + b * 16, eob: Int(eobs[b]), destination: block, stride: stride)
                }
            }
        } else {
            VP8Prediction.predictWholeBlock(origin, stride: stride, size: 16, mode: lumaMode, above: aboveRow,
                                            left: origin - 1, leftStride: stride,
                                            haveAbove: row > 0, haveLeft: column > 0)
            if residual {
                inverseWalsh()
                for b in 0..<16 {
                    let block = origin + (b >> 2) * 4 * stride + (b & 3) * 4
                    addBlock(coefficients + b * 16, eob: Int(eobs[b]), destination: block, stride: stride)
                }
            }
        }
        for r in 0..<16 {
            (destination + r * planeStride).update(from: origin + r * stride, count: 16)
        }

        // Chroma predicts straight into the frame from edge arrays.
        let chromaStride = frame.chromaWidth
        for plane in 0..<2 {
            let base = plane == 0 ? frame.u : frame.v
            let target = base + row * 8 * chromaStride + column * 8
            let above = chromaEdges + 1
            let left = chromaEdges + 16
            if row == 0 {
                for i in -1..<8 { above[i] = 127 }
            } else {
                let source = target - chromaStride
                for i in 0..<8 { above[i] = source[i] }
                above[-1] = column == 0 ? 129 : source[-1]
            }
            for r in 0..<8 {
                left[r] = column == 0 ? 129 : target[r * chromaStride - 1]
            }
            VP8Prediction.predictWholeBlock(target, stride: chromaStride, size: 8, mode: Int(record.chromaMode),
                                            above: above, left: left, leftStride: 1,
                                            haveAbove: row > 0, haveLeft: column > 0)
            if residual {
                let first = plane == 0 ? 16 : 20
                for b in 0..<4 {
                    let block = target + (b >> 1) * 4 * chromaStride + (b & 1) * 4
                    addBlock(coefficients + (first + b) * 16, eob: Int(eobs[first + b]), destination: block,
                             stride: chromaStride)
                }
            }
        }
    }

    // MARK: Inverse transforms (section 14)

    /// Inverts the Y2 Walsh-Hadamard block into the DC of each luma block.
    private func inverseWalsh() {
        let input = coefficients + 24 * 16
        let temp = walshScratch
        for i in 0..<4 {
            let a1 = Int(input[i]) + Int(input[12 + i])
            let b1 = Int(input[4 + i]) + Int(input[8 + i])
            let c1 = Int(input[4 + i]) - Int(input[8 + i])
            let d1 = Int(input[i]) - Int(input[12 + i])
            temp[i] = Int(Int16(truncatingIfNeeded: a1 + b1))
            temp[4 + i] = Int(Int16(truncatingIfNeeded: c1 + d1))
            temp[8 + i] = Int(Int16(truncatingIfNeeded: a1 - b1))
            temp[12 + i] = Int(Int16(truncatingIfNeeded: d1 - c1))
        }
        for i in 0..<4 {
            let a1 = temp[4 * i] + temp[4 * i + 3]
            let b1 = temp[4 * i + 1] + temp[4 * i + 2]
            let c1 = temp[4 * i + 1] - temp[4 * i + 2]
            let d1 = temp[4 * i] - temp[4 * i + 3]
            coefficients[(4 * i) * 16] = Int16(truncatingIfNeeded: (a1 + b1 + 3) >> 3)
            coefficients[(4 * i + 1) * 16] = Int16(truncatingIfNeeded: (c1 + d1 + 3) >> 3)
            coefficients[(4 * i + 2) * 16] = Int16(truncatingIfNeeded: (a1 - b1 + 3) >> 3)
            coefficients[(4 * i + 3) * 16] = Int16(truncatingIfNeeded: (d1 - c1 + 3) >> 3)
        }
    }

    /// Adds one block's inverse DCT to the prediction at `destination`.
    @inline(__always)
    private func addBlock(_ input: UnsafeMutablePointer<Int16>, eob: Int, destination: UnsafeMutablePointer<UInt8>,
                          stride: Int) {
        if eob > 1 {
            VP8Prediction.inverseDCTAdd(input, destination: destination, stride: stride)
        } else if input[0] != 0 {
            let dc = (Int(input[0]) + 4) >> 3
            for r in 0..<4 {
                let line = destination + r * stride
                for c in 0..<4 { line[c] = VP8Prediction.clampPixel(Int(line[c]) + dc) }
            }
        }
    }

    private func addInterResidual(column: Int, row: Int, frame: VP8FrameBuffer, eobs: UnsafeMutablePointer<UInt8>) {
        let lumaStride = frame.lumaWidth
        let luma = frame.y + row * 16 * lumaStride + column * 16
        let record = macroblocks[(row + 1) * infoStride + column + 1]
        if record.lumaMode != UInt8(VP8Mode.split) { inverseWalsh() }
        for b in 0..<16 {
            addBlock(coefficients + b * 16, eob: Int(eobs[b]),
                     destination: luma + (b >> 2) * 4 * lumaStride + (b & 3) * 4, stride: lumaStride)
        }
        let chromaStride = frame.chromaWidth
        for plane in 0..<2 {
            let target = (plane == 0 ? frame.u : frame.v) + row * 8 * chromaStride + column * 8
            let first = plane == 0 ? 16 : 20
            for b in 0..<4 {
                addBlock(coefficients + (first + b) * 16, eob: Int(eobs[first + b]),
                         destination: target + (b >> 1) * 4 * chromaStride + (b & 1) * 4, stride: chromaStride)
            }
        }
    }

    // MARK: Inter prediction (section 18)

    private func predictInter(record: VP8MacroblockInfo, vectors: UnsafeMutablePointer<VP8MotionVector>,
                              column: Int, row: Int, reference: VP8FrameBuffer, frame: VP8FrameBuffer, version: Int) {
        let filters = UnsafePointer(version == 0 ? sixTap : bilinear)
        let fullPixelChroma = version == 3
        let lumaStride = frame.lumaWidth
        let chromaStride = frame.chromaWidth
        let lumaX = column * 16, lumaY = row * 16
        let chromaX = column * 8, chromaY = row * 8
        let luma = frame.y + lumaY * lumaStride + lumaX

        if record.lumaMode != UInt8(VP8Mode.split) {
            let mv = record.motionVector
            let mvRow = Int(mv.row), mvColumn = Int(mv.column)
            predictBlock(source: reference.y, stride: lumaStride, planeWidth: reference.lumaWidth,
                         planeHeight: reference.lumaHeight, x: lumaX + (mvColumn >> 2), y: lumaY + (mvRow >> 2),
                         fractionX: (mvColumn & 3) * 2, fractionY: (mvRow & 3) * 2, width: 16, height: 16,
                         destination: luma, destinationStride: lumaStride, filters: filters)
            // Chroma uses the same vector at eighth-pixel chroma precision.
            var chromaRow = mvRow, chromaColumn = mvColumn
            if fullPixelChroma {
                chromaRow &= ~7
                chromaColumn &= ~7
            }
            for plane in 0..<2 {
                let source = plane == 0 ? reference.u : reference.v
                let target = (plane == 0 ? frame.u : frame.v) + chromaY * chromaStride + chromaX
                predictBlock(source: source, stride: chromaStride, planeWidth: reference.chromaWidth,
                             planeHeight: reference.chromaHeight, x: chromaX + (chromaColumn >> 3),
                             y: chromaY + (chromaRow >> 3), fractionX: chromaColumn & 7, fractionY: chromaRow & 7,
                             width: 8, height: 8, destination: target, destinationStride: chromaStride, filters: filters)
            }
            return
        }

        for b in 0..<16 {
            let mv = vectors[b]
            let mvRow = Int(mv.row), mvColumn = Int(mv.column)
            let bx = (b & 3) * 4, by = (b >> 2) * 4
            predictBlock(source: reference.y, stride: lumaStride, planeWidth: reference.lumaWidth,
                         planeHeight: reference.lumaHeight, x: lumaX + bx + (mvColumn >> 2),
                         y: lumaY + by + (mvRow >> 2), fractionX: (mvColumn & 3) * 2, fractionY: (mvRow & 3) * 2,
                         width: 4, height: 4, destination: luma + by * lumaStride + bx,
                         destinationStride: lumaStride, filters: filters)
        }
        // Each chroma 4x4 block averages the vectors of the four luma blocks it covers.
        for j in 0..<2 {
            for i in 0..<2 {
                let k = j * 8 + i * 2
                let sumRow = Int(vectors[k].row) + Int(vectors[k + 1].row) + Int(vectors[k + 4].row)
                    + Int(vectors[k + 5].row)
                let sumColumn = Int(vectors[k].column) + Int(vectors[k + 1].column) + Int(vectors[k + 4].column)
                    + Int(vectors[k + 5].column)
                // Doubling makes the vectors eighth-pixel luma units before averaging (section 18.1).
                func average(_ sum: Int) -> Int {
                    let s = sum * 2
                    return s >= 0 ? (s + 4) >> 3 : -((-s + 4) >> 3)
                }
                var chromaRow = average(sumRow), chromaColumn = average(sumColumn)
                if fullPixelChroma {
                    chromaRow &= ~7
                    chromaColumn &= ~7
                }
                for plane in 0..<2 {
                    let source = plane == 0 ? reference.u : reference.v
                    let target = (plane == 0 ? frame.u : frame.v) + (chromaY + j * 4) * chromaStride + chromaX + i * 4
                    predictBlock(source: source, stride: chromaStride, planeWidth: reference.chromaWidth,
                                 planeHeight: reference.chromaHeight, x: chromaX + i * 4 + (chromaColumn >> 3),
                                 y: chromaY + j * 4 + (chromaRow >> 3), fractionX: chromaColumn & 7,
                                 fractionY: chromaRow & 7, width: 4, height: 4, destination: target,
                                 destinationStride: chromaStride, filters: filters)
                }
            }
        }
    }

    /// Forms a motion-compensated block. `x`/`y` are the whole-pixel source position and
    /// the fractions are in eighths. Pixels outside the reference repeat its edge pixels.
    private func predictBlock(source: UnsafeMutablePointer<UInt8>, stride: Int, planeWidth: Int, planeHeight: Int,
                              x: Int, y: Int, fractionX: Int, fractionY: Int, width: Int, height: Int,
                              destination: UnsafeMutablePointer<UInt8>, destinationStride: Int,
                              filters: UnsafePointer<Int32>) {
        var origin = UnsafePointer(source + 0)
        var sourceStride = stride
        if x - 2 < 0 || y - 2 < 0 || x + width + 3 > planeWidth || y + height + 3 > planeHeight {
            // Gather the needed region with clamped coordinates.
            let scratchStride = 32
            for r in 0..<(height + 5) {
                let sy = min(max(y - 2 + r, 0), planeHeight - 1)
                let line = source + sy * stride
                let out = edgeScratch + r * scratchStride
                for c in 0..<(width + 5) {
                    out[c] = line[min(max(x - 2 + c, 0), planeWidth - 1)]
                }
            }
            origin = UnsafePointer(edgeScratch + 2 * scratchStride + 2)
            sourceStride = scratchStride
        } else {
            origin = UnsafePointer(source + y * stride + x)
        }
        VP8Prediction.interpolate(origin, stride: sourceStride, fractionX: fractionX, fractionY: fractionY,
                                  width: width, height: height, destination: destination,
                                  destinationStride: destinationStride, filters: filters, temp: filterScratch)
    }

    // MARK: Loop filter (section 15)

    private func loopFilter(frame: VP8FrameBuffer, header: VP8FrameHeader) {
        typealias Filter = VP8LoopFilter
        let lumaStride = frame.lumaWidth
        let chromaStride = frame.chromaWidth
        let sharpness = header.sharpness
        for row in 0..<macroblockRows {
            for column in 0..<macroblockColumns {
                let info = macroblocks[(row + 1) * infoStride + column + 1]
                let level = Int(info.filterLevel)
                guard level > 0 else { continue }
                // Control parameters (section 15.4).
                var interior = level
                if sharpness > 0 {
                    interior >>= sharpness > 4 ? 2 : 1
                    interior = min(interior, 9 - sharpness)
                }
                interior = max(interior, 1)
                let hevThreshold: Int
                if header.isKeyFrame {
                    hevThreshold = level >= 40 ? 2 : (level >= 15 ? 1 : 0)
                } else {
                    hevThreshold = level >= 40 ? 3 : (level >= 20 ? 2 : (level >= 15 ? 1 : 0))
                }
                let edgeLimits = Filter.Limits(edge: (level + 2) * 2 + interior, interior: interior,
                                               highVariance: hevThreshold)
                let innerLimits = Filter.Limits(edge: level * 2 + interior, interior: interior,
                                                highVariance: hevThreshold)
                let luma = frame.y + row * 16 * lumaStride + column * 16
                let lumaLower = luma + 8 * lumaStride
                let u = frame.u + row * 8 * chromaStride + column * 8
                let v = frame.v + row * 8 * chromaStride + column * 8
                let inner = info.filtersInnerEdges

                if header.simpleFilter {
                    // The simple filter touches luma only.
                    if column > 0 {
                        var s = Filter.loadVertical(luma, lumaLower, stride: lumaStride)
                        if Filter.simple(&s, edgeLimit: edgeLimits.edge) {
                            Filter.storeVertical(s, luma, lumaLower, stride: lumaStride)
                        }
                    }
                    if inner {
                        for edge in 1...3 {
                        let x = edge * 4
                            var s = Filter.loadVertical(luma + x, lumaLower + x, stride: lumaStride)
                            if Filter.simple(&s, edgeLimit: innerLimits.edge) {
                                Filter.storeVertical(s, luma + x, lumaLower + x, stride: lumaStride)
                            }
                        }
                    }
                    if row > 0 {
                        var s = Filter.loadHorizontal(luma, luma + 8, stride: lumaStride)
                        if Filter.simple(&s, edgeLimit: edgeLimits.edge) {
                            Filter.storeHorizontal(s, luma, luma + 8, stride: lumaStride)
                        }
                    }
                    if inner {
                        for edge in 1...3 {
                        let y = edge * 4
                            let line = luma + y * lumaStride
                            var s = Filter.loadHorizontal(line, line + 8, stride: lumaStride)
                            if Filter.simple(&s, edgeLimit: innerLimits.edge) {
                                Filter.storeHorizontal(s, line, line + 8, stride: lumaStride)
                            }
                        }
                    }
                    continue
                }

                // 1. Left macroblock edge (luma, then U and V together).
                if column > 0 {
                    var s = Filter.loadVertical(luma, lumaLower, stride: lumaStride)
                    if Filter.macroblockEdge(&s, edgeLimits) {
                        Filter.storeVertical(s, luma, lumaLower, stride: lumaStride)
                    }
                    var c = Filter.loadVertical(u, v, stride: chromaStride)
                    if Filter.macroblockEdge(&c, edgeLimits) {
                        Filter.storeVertical(c, u, v, stride: chromaStride)
                    }
                }
                // 2. Vertical subblock edges.
                if inner {
                    for edge in 1...3 {
                        let x = edge * 4
                        var s = Filter.loadVertical(luma + x, lumaLower + x, stride: lumaStride)
                        if Filter.subblockEdge(&s, innerLimits) {
                            Filter.storeVertical(s, luma + x, lumaLower + x, stride: lumaStride)
                        }
                    }
                    var c = Filter.loadVertical(u + 4, v + 4, stride: chromaStride)
                    if Filter.subblockEdge(&c, innerLimits) {
                        Filter.storeVertical(c, u + 4, v + 4, stride: chromaStride)
                    }
                }
                // 3. Top macroblock edge.
                if row > 0 {
                    var s = Filter.loadHorizontal(luma, luma + 8, stride: lumaStride)
                    if Filter.macroblockEdge(&s, edgeLimits) {
                        Filter.storeHorizontal(s, luma, luma + 8, stride: lumaStride)
                    }
                    var c = Filter.loadHorizontal(u, v, stride: chromaStride)
                    if Filter.macroblockEdge(&c, edgeLimits) {
                        Filter.storeHorizontal(c, u, v, stride: chromaStride)
                    }
                }
                // 4. Horizontal subblock edges.
                if inner {
                    for edge in 1...3 {
                        let y = edge * 4
                        let line = luma + y * lumaStride
                        var s = Filter.loadHorizontal(line, line + 8, stride: lumaStride)
                        if Filter.subblockEdge(&s, innerLimits) {
                            Filter.storeHorizontal(s, line, line + 8, stride: lumaStride)
                        }
                    }
                    let uLine = u + 4 * chromaStride, vLine = v + 4 * chromaStride
                    var c = Filter.loadHorizontal(uLine, vLine, stride: chromaStride)
                    if Filter.subblockEdge(&c, innerLimits) {
                        Filter.storeHorizontal(c, uLine, vLine, stride: chromaStride)
                    }
                }
            }
        }
    }
}

// MARK: - Prediction and transform kernels

/// Pixel kernels: intra predictors (section 12), the inverse DCT (section 14.4), and
/// sub-pixel interpolation (section 18.3).
nonisolated enum VP8Prediction {
    @inline(__always)
    static func clampPixel(_ value: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: value < 0 ? 0 : (value > 255 ? 255 : value))
    }

    /// One of the whole-block modes (DC, V, H, TM) for a 16x16 luma or 8x8 chroma block.
    /// `above[-1]` is the corner pixel; `left` steps by `leftStride`.
    static func predictWholeBlock(_ destination: UnsafeMutablePointer<UInt8>, stride: Int, size: Int, mode: Int,
                                  above: UnsafePointer<UInt8>, left: UnsafePointer<UInt8>, leftStride: Int,
                                  haveAbove: Bool, haveLeft: Bool) {
        switch mode {
        case VP8Mode.vertical:
            for r in 0..<size { (destination + r * stride).update(from: above, count: size) }
        case VP8Mode.horizontal:
            for r in 0..<size { (destination + r * stride).update(repeating: left[r * leftStride], count: size) }
        case VP8Mode.trueMotion:
            let corner = Int(above[-1])
            for r in 0..<size {
                let line = destination + r * stride
                let offset = Int(left[r * leftStride]) - corner
                for c in 0..<size { line[c] = clampPixel(Int(above[c]) + offset) }
            }
        default:
            let shift = size == 16 ? 3 : 2
            var sum = 0
            var value = 128
            if haveAbove && haveLeft {
                for i in 0..<size { sum += Int(above[i]) + Int(left[i * leftStride]) }
                value = (sum + size) >> (shift + 2)
            } else if haveAbove {
                for i in 0..<size { sum += Int(above[i]) }
                value = (sum + size / 2) >> (shift + 1)
            } else if haveLeft {
                for i in 0..<size { sum += Int(left[i * leftStride]) }
                value = (sum + size / 2) >> (shift + 1)
            }
            for r in 0..<size { (destination + r * stride).update(repeating: UInt8(value), count: size) }
        }
    }

    /// Predicts a 4x4 luma subblock in place. The row above (8 pixels plus the corner at
    /// index -1) and the column to the left must already be present around `block`.
    static func predictSubblock(_ block: UnsafeMutablePointer<UInt8>, stride: Int, mode: Int) {
        let a = block - stride
        let p = Int(a[-1])
        let a0 = Int(a[0]), a1 = Int(a[1]), a2 = Int(a[2]), a3 = Int(a[3])
        let a4 = Int(a[4]), a5 = Int(a[5]), a6 = Int(a[6]), a7 = Int(a[7])
        let l0 = Int(block[-1]), l1 = Int(block[stride - 1]), l2 = Int(block[2 * stride - 1]), l3 = Int(block[3 * stride - 1])
        @inline(__always) func avg3(_ x: Int, _ y: Int, _ z: Int) -> UInt8 { UInt8(truncatingIfNeeded: (x + 2 * y + z + 2) >> 2) }
        @inline(__always) func avg2(_ x: Int, _ y: Int) -> UInt8 { UInt8(truncatingIfNeeded: (x + y + 1) >> 1) }
        @inline(__always) func put(_ r: Int, _ c: Int, _ value: UInt8) { block[r * stride + c] = value }

        switch mode {
        case VP8Mode.bTM:
            for r in 0..<4 {
                let left = Int(block[r * stride - 1]) - p
                for c in 0..<4 { put(r, c, clampPixel(Int(a[c]) + left)) }
            }
        case VP8Mode.bVE:
            for c in 0..<4 {
                let value = avg3(Int(a[c - 1]), Int(a[c]), Int(a[c + 1]))
                for r in 0..<4 { put(r, c, value) }
            }
        case VP8Mode.bHE:
            block.update(repeating: avg3(p, l0, l1), count: 4)
            (block + stride).update(repeating: avg3(l0, l1, l2), count: 4)
            (block + 2 * stride).update(repeating: avg3(l1, l2, l3), count: 4)
            (block + 3 * stride).update(repeating: avg3(l2, l3, l3), count: 4)
        case VP8Mode.bLD:
            // Diagonal k = row + column is the smoothed above(-right) pixel k + 1.
            for r in 0..<4 {
                for c in 0..<4 {
                    let k = r + c
                    put(r, c, k < 6 ? avg3(Int(a[k]), Int(a[k + 1]), Int(a[k + 2])) : avg3(a6, a7, a7))
                }
            }
        case VP8Mode.bRD, VP8Mode.bVR, VP8Mode.bHD:
            // Edge pixels from bottom-left, through the corner, to top-right.
            withUnsafeTemporaryAllocation(of: Int.self, capacity: 9) { buffer in
                guard let e = buffer.baseAddress else { return }
                e[0] = l3; e[1] = l2; e[2] = l1; e[3] = l0; e[4] = p
                e[5] = a0; e[6] = a1; e[7] = a2; e[8] = a3
                @inline(__always) func s3(_ k: Int) -> UInt8 { avg3(e[k - 1], e[k], e[k + 1]) }
                @inline(__always) func s2(_ k: Int) -> UInt8 { avg2(e[k], e[k + 1]) }
                switch mode {
                case VP8Mode.bRD:
                    for r in 0..<4 { for c in 0..<4 { put(r, c, s3(4 - r + c)) } }
                case VP8Mode.bVR:
                    put(3, 0, s3(2))
                    put(2, 0, s3(3))
                    put(3, 1, s3(4)); put(1, 0, s3(4))
                    put(2, 1, s2(4)); put(0, 0, s2(4))
                    put(3, 2, s3(5)); put(1, 1, s3(5))
                    put(2, 2, s2(5)); put(0, 1, s2(5))
                    put(3, 3, s3(6)); put(1, 2, s3(6))
                    put(2, 3, s2(6)); put(0, 2, s2(6))
                    put(1, 3, s3(7))
                    put(0, 3, s2(7))
                default:
                    put(3, 0, s2(0))
                    put(3, 1, s3(1))
                    put(2, 0, s2(1)); put(3, 2, s2(1))
                    put(2, 1, s3(2)); put(3, 3, s3(2))
                    put(2, 2, s2(2)); put(1, 0, s2(2))
                    put(2, 3, s3(3)); put(1, 1, s3(3))
                    put(1, 2, s2(3)); put(0, 0, s2(3))
                    put(1, 3, s3(4)); put(0, 1, s3(4))
                    put(0, 2, s3(5))
                    put(0, 3, s3(6))
                }
            }
        case VP8Mode.bVL:
            put(0, 0, avg2(a0, a1))
            put(1, 0, avg3(a0, a1, a2))
            put(2, 0, avg2(a1, a2)); put(0, 1, avg2(a1, a2))
            put(1, 1, avg3(a1, a2, a3)); put(3, 0, avg3(a1, a2, a3))
            put(2, 1, avg2(a2, a3)); put(0, 2, avg2(a2, a3))
            put(3, 1, avg3(a2, a3, a4)); put(1, 2, avg3(a2, a3, a4))
            put(2, 2, avg2(a3, a4)); put(0, 3, avg2(a3, a4))
            put(3, 2, avg3(a3, a4, a5)); put(1, 3, avg3(a3, a4, a5))
            put(2, 3, avg3(a4, a5, a6))
            put(3, 3, avg3(a5, a6, a7))
        case VP8Mode.bHU:
            put(0, 0, avg2(l0, l1))
            put(0, 1, avg3(l0, l1, l2))
            put(0, 2, avg2(l1, l2)); put(1, 0, avg2(l1, l2))
            put(0, 3, avg3(l1, l2, l3)); put(1, 1, avg3(l1, l2, l3))
            put(1, 2, avg2(l2, l3)); put(2, 0, avg2(l2, l3))
            put(1, 3, avg3(l2, l3, l3)); put(2, 1, avg3(l2, l3, l3))
            let last = UInt8(truncatingIfNeeded: l3)
            put(2, 2, last); put(2, 3, last)
            (block + 3 * stride).update(repeating: last, count: 4)
        default:
            var sum = 4
            for i in 0..<4 { sum += Int(a[i]) + Int(block[i * stride - 1]) }
            let value = UInt8(truncatingIfNeeded: sum >> 3)
            for r in 0..<4 { (block + r * stride).update(repeating: value, count: 4) }
        }
    }

    /// The exact-integer inverse DCT of section 14.4, added to the prediction with clamping.
    static func inverseDCTAdd(_ input: UnsafePointer<Int16>, destination: UnsafeMutablePointer<UInt8>, stride: Int) {
        // sqrt(2) * cos(pi / 8) - 1 and sqrt(2) * sin(pi / 8) in 16-bit fixed point.
        let c1k = 20091, s1k = 35468
        withUnsafeTemporaryAllocation(of: Int.self, capacity: 16) { buffer in
            guard let temp = buffer.baseAddress else { return }
            // Vertical pass: intermediate results are kept to 16 bits.
            for i in 0..<4 {
                let i0 = Int(input[i]), i4 = Int(input[4 + i]), i8 = Int(input[8 + i]), i12 = Int(input[12 + i])
                let a1 = i0 + i8
                let b1 = i0 - i8
                let c1 = ((i4 * s1k) >> 16) - (i12 + ((i12 * c1k) >> 16))
                let d1 = (i4 + ((i4 * c1k) >> 16)) + ((i12 * s1k) >> 16)
                temp[i] = Int(Int16(truncatingIfNeeded: a1 + d1))
                temp[12 + i] = Int(Int16(truncatingIfNeeded: a1 - d1))
                temp[4 + i] = Int(Int16(truncatingIfNeeded: b1 + c1))
                temp[8 + i] = Int(Int16(truncatingIfNeeded: b1 - c1))
            }
            // Horizontal pass, rounding, and reconstruction.
            for r in 0..<4 {
                let row = temp + 4 * r
                let i0 = row[0], i1 = row[1], i2 = row[2], i3 = row[3]
                let a1 = i0 + i2
                let b1 = i0 - i2
                let c1 = ((i1 * s1k) >> 16) - (i3 + ((i3 * c1k) >> 16))
                let d1 = (i1 + ((i1 * c1k) >> 16)) + ((i3 * s1k) >> 16)
                let line = destination + r * stride
                line[0] = clampPixel(Int(line[0]) + ((a1 + d1 + 4) >> 3))
                line[3] = clampPixel(Int(line[3]) + ((a1 - d1 + 4) >> 3))
                line[1] = clampPixel(Int(line[1]) + ((b1 + c1 + 4) >> 3))
                line[2] = clampPixel(Int(line[2]) + ((b1 - c1 + 4) >> 3))
            }
        }
    }

    /// Two-pass separable interpolation (horizontal, then vertical) with six-tap or
    /// bilinear taps, each pass rounded and clamped to 8 bits. `source` points at the
    /// block origin and must have 2 pixels before and 3 after it in both directions.
    /// A pass whose fraction is zero is the identity, so it is skipped.
    static func interpolate(_ source: UnsafePointer<UInt8>, stride: Int, fractionX: Int, fractionY: Int,
                            width: Int, height: Int, destination: UnsafeMutablePointer<UInt8>, destinationStride: Int,
                            filters: UnsafePointer<Int32>, temp: UnsafeMutablePointer<UInt8>) {
        switch width {
        case 16:
            interpolate(VP8Row16.self, source, stride: stride, fractionX: fractionX, fractionY: fractionY, height: height,
                        destination: destination, destinationStride: destinationStride, filters: filters, temp: temp)
        case 8:
            interpolate(VP8Row8.self, source, stride: stride, fractionX: fractionX, fractionY: fractionY, height: height,
                        destination: destination, destinationStride: destinationStride, filters: filters, temp: temp)
        default:
            interpolate(VP8Row4.self, source, stride: stride, fractionX: fractionX, fractionY: fractionY, height: height,
                        destination: destination, destinationStride: destinationStride, filters: filters, temp: temp)
        }
    }

    @inline(__always)
    private static func interpolate<Row: VP8RowKernel>(_ row: Row.Type, _ source: UnsafePointer<UInt8>, stride: Int,
                                                       fractionX: Int, fractionY: Int, height: Int,
                                                       destination: UnsafeMutablePointer<UInt8>, destinationStride: Int,
                                                       filters: UnsafePointer<Int32>, temp: UnsafeMutablePointer<UInt8>) {
        if fractionX == 0 && fractionY == 0 {
            for r in 0..<height { Row.copy(source + r * stride, into: destination + r * destinationStride) }
        } else if fractionY == 0 {
            let taps = filters + fractionX * 6
            for r in 0..<height {
                Row.filter(source + r * stride, step: 1, taps: taps, into: destination + r * destinationStride)
            }
        } else if fractionX == 0 {
            let taps = filters + fractionY * 6
            for r in 0..<height {
                Row.filter(source + r * stride, step: stride, taps: taps, into: destination + r * destinationStride)
            }
        } else {
            // The first pass covers 2 rows above and 3 below the block for the vertical taps.
            let horizontal = filters + fractionX * 6
            let vertical = filters + fractionY * 6
            let tempStride = 16
            for r in 0..<(height + 5) {
                Row.filter(source + (r - 2) * stride, step: 1, taps: horizontal, into: temp + r * tempStride)
            }
            let middle = UnsafePointer(temp + 2 * tempStride)
            for r in 0..<height {
                Row.filter(middle + r * tempStride, step: tempStride, taps: vertical,
                           into: destination + r * destinationStride)
            }
        }
    }
}

/// One row of an interpolated block, computed with SIMD lanes. `filter` applies six taps
/// at offsets -2...3 (times `step`) around each pixel: (sum + 64) >> 7, clamped to 0...255.
nonisolated protocol VP8RowKernel {
    static func copy(_ source: UnsafePointer<UInt8>, into destination: UnsafeMutablePointer<UInt8>)
    static func filter(_ source: UnsafePointer<UInt8>, step: Int, taps: UnsafePointer<Int32>,
                       into destination: UnsafeMutablePointer<UInt8>)
}

nonisolated enum VP8Row16: VP8RowKernel {
    @inline(__always)
    static func copy(_ source: UnsafePointer<UInt8>, into destination: UnsafeMutablePointer<UInt8>) {
        UnsafeMutableRawPointer(destination).storeBytes(of: UnsafeRawPointer(source).loadUnaligned(as: SIMD16<UInt8>.self),
                                                        as: SIMD16<UInt8>.self)
    }

    @inline(__always)
    static func filter(_ source: UnsafePointer<UInt8>, step: Int, taps: UnsafePointer<Int32>,
                       into destination: UnsafeMutablePointer<UInt8>) {
        let raw = UnsafeRawPointer(source)
        @inline(__always) func at(_ k: Int) -> simd_int16 {
            simd_int(raw.loadUnaligned(fromByteOffset: k * step, as: SIMD16<UInt8>.self))
        }
        var sum = at(-2) &* taps[0] &+ at(-1) &* taps[1] &+ at(0) &* taps[2]
        sum &+= at(1) &* taps[3] &+ at(2) &* taps[4] &+ at(3) &* taps[5]
        let value = simd_clamp((sum &+ 64) &>> 7, simd_int16(repeating: 0), simd_int16(repeating: 255))
        UnsafeMutableRawPointer(destination).storeBytes(of: simd_uchar(value), as: SIMD16<UInt8>.self)
    }
}

nonisolated enum VP8Row8: VP8RowKernel {
    @inline(__always)
    static func copy(_ source: UnsafePointer<UInt8>, into destination: UnsafeMutablePointer<UInt8>) {
        UnsafeMutableRawPointer(destination).storeBytes(of: UnsafeRawPointer(source).loadUnaligned(as: UInt64.self),
                                                        as: UInt64.self)
    }

    @inline(__always)
    static func filter(_ source: UnsafePointer<UInt8>, step: Int, taps: UnsafePointer<Int32>,
                       into destination: UnsafeMutablePointer<UInt8>) {
        let raw = UnsafeRawPointer(source)
        @inline(__always) func at(_ k: Int) -> simd_int8 {
            simd_int(raw.loadUnaligned(fromByteOffset: k * step, as: SIMD8<UInt8>.self))
        }
        var sum = at(-2) &* taps[0] &+ at(-1) &* taps[1] &+ at(0) &* taps[2]
        sum &+= at(1) &* taps[3] &+ at(2) &* taps[4] &+ at(3) &* taps[5]
        let value = simd_clamp((sum &+ 64) &>> 7, simd_int8(repeating: 0), simd_int8(repeating: 255))
        UnsafeMutableRawPointer(destination).storeBytes(of: simd_uchar(value), as: SIMD8<UInt8>.self)
    }
}

nonisolated enum VP8Row4: VP8RowKernel {
    @inline(__always)
    static func copy(_ source: UnsafePointer<UInt8>, into destination: UnsafeMutablePointer<UInt8>) {
        UnsafeMutableRawPointer(destination).storeBytes(of: UnsafeRawPointer(source).loadUnaligned(as: UInt32.self),
                                                        as: UInt32.self)
    }

    @inline(__always)
    static func filter(_ source: UnsafePointer<UInt8>, step: Int, taps: UnsafePointer<Int32>,
                       into destination: UnsafeMutablePointer<UInt8>) {
        let raw = UnsafeRawPointer(source)
        @inline(__always) func at(_ k: Int) -> simd_int4 {
            simd_int(raw.loadUnaligned(fromByteOffset: k * step, as: SIMD4<UInt8>.self))
        }
        var sum = at(-2) &* taps[0] &+ at(-1) &* taps[1] &+ at(0) &* taps[2]
        sum &+= at(1) &* taps[3] &+ at(2) &* taps[4] &+ at(3) &* taps[5]
        let value = simd_clamp((sum &+ 64) &>> 7, simd_int4(repeating: 0), simd_int4(repeating: 255))
        UnsafeMutableRawPointer(destination).storeBytes(of: simd_uchar(value), as: SIMD4<UInt8>.self)
    }
}

// MARK: - Loop filter kernels

/// The simple and normal edge filters of section 15, applied to 16 segments at once.
/// A segment is the 8 pixels p3 p2 p1 p0 | q0 q1 q2 q3 straddling an edge; lanes 0-7 and
/// 8-15 come from two separate 8-pixel runs (the two halves of a luma edge, or the U and
/// V edges of a macroblock), which lets chroma be filtered in the same pass.
nonisolated enum VP8LoopFilter {
    typealias Lanes = SIMD16<Int16>

    /// The eight pixel rows (or columns) of 16 segments, as unsigned values.
    struct Segments {
        var p3 = Lanes(), p2 = Lanes(), p1 = Lanes(), p0 = Lanes()
        var q0 = Lanes(), q1 = Lanes(), q2 = Lanes(), q3 = Lanes()
    }

    /// Thresholds for one macroblock, broadcast to every lane.
    struct Limits {
        var edge: Lanes
        var interior: Lanes
        var highVariance: Lanes

        init(edge: Int, interior: Int, highVariance: Int) {
            self.edge = Lanes(repeating: Int16(edge))
            self.interior = Lanes(repeating: Int16(interior))
            self.highVariance = Lanes(repeating: Int16(highVariance))
        }
    }

    // MARK: Loading and storing

    @inline(__always)
    private static func load(_ first: UnsafeMutablePointer<UInt8>, _ second: UnsafeMutablePointer<UInt8>) -> Lanes {
        let low = UnsafeRawPointer(first).loadUnaligned(as: SIMD8<UInt8>.self)
        let high = UnsafeRawPointer(second).loadUnaligned(as: SIMD8<UInt8>.self)
        return simd_short(SIMD16<UInt8>(lowHalf: low, highHalf: high))
    }

    @inline(__always)
    private static func store(_ lanes: Lanes, _ first: UnsafeMutablePointer<UInt8>, _ second: UnsafeMutablePointer<UInt8>) {
        let bytes = simd_uchar(lanes)
        UnsafeMutableRawPointer(first).storeBytes(of: bytes.lowHalf, as: SIMD8<UInt8>.self)
        UnsafeMutableRawPointer(second).storeBytes(of: bytes.highHalf, as: SIMD8<UInt8>.self)
    }

    /// Segments across a horizontal edge: `first`/`second` point at the q0 row of each half.
    @inline(__always)
    static func loadHorizontal(_ first: UnsafeMutablePointer<UInt8>, _ second: UnsafeMutablePointer<UInt8>,
                               stride: Int) -> Segments {
        var s = Segments()
        s.p3 = load(first - 4 * stride, second - 4 * stride)
        s.p2 = load(first - 3 * stride, second - 3 * stride)
        s.p1 = load(first - 2 * stride, second - 2 * stride)
        s.p0 = load(first - stride, second - stride)
        s.q0 = load(first, second)
        s.q1 = load(first + stride, second + stride)
        s.q2 = load(first + 2 * stride, second + 2 * stride)
        s.q3 = load(first + 3 * stride, second + 3 * stride)
        return s
    }

    @inline(__always)
    static func storeHorizontal(_ s: Segments, _ first: UnsafeMutablePointer<UInt8>, _ second: UnsafeMutablePointer<UInt8>,
                                stride: Int) {
        store(s.p2, first - 3 * stride, second - 3 * stride)
        store(s.p1, first - 2 * stride, second - 2 * stride)
        store(s.p0, first - stride, second - stride)
        store(s.q0, first, second)
        store(s.q1, first + stride, second + stride)
        store(s.q2, first + 2 * stride, second + 2 * stride)
    }

    /// Transposes two 8x8 byte matrices at once: lane 0 of `r[i]` holds row i of the first
    /// matrix (byte k = column k), lane 1 row i of the second. Afterwards `r[k]` holds column k.
    /// Each step swaps the off-diagonal blocks of the next smaller size (4x4, 2x2, 1x1).
    @inline(__always)
    private static func transpose(_ r: inout (SIMD2<UInt64>, SIMD2<UInt64>, SIMD2<UInt64>, SIMD2<UInt64>,
                                              SIMD2<UInt64>, SIMD2<UInt64>, SIMD2<UInt64>, SIMD2<UInt64>)) {
        @inline(__always) func swap(_ a: inout SIMD2<UInt64>, _ b: inout SIMD2<UInt64>, _ shift: UInt64, _ mask: UInt64) {
            let t = ((a &>> shift) ^ b) & SIMD2(repeating: mask)
            b ^= t
            a ^= t &<< shift
        }
        swap(&r.0, &r.4, 32, 0x0000_0000_FFFF_FFFF)
        swap(&r.1, &r.5, 32, 0x0000_0000_FFFF_FFFF)
        swap(&r.2, &r.6, 32, 0x0000_0000_FFFF_FFFF)
        swap(&r.3, &r.7, 32, 0x0000_0000_FFFF_FFFF)
        swap(&r.0, &r.2, 16, 0x0000_FFFF_0000_FFFF)
        swap(&r.1, &r.3, 16, 0x0000_FFFF_0000_FFFF)
        swap(&r.4, &r.6, 16, 0x0000_FFFF_0000_FFFF)
        swap(&r.5, &r.7, 16, 0x0000_FFFF_0000_FFFF)
        swap(&r.0, &r.1, 8, 0x00FF_00FF_00FF_00FF)
        swap(&r.2, &r.3, 8, 0x00FF_00FF_00FF_00FF)
        swap(&r.4, &r.5, 8, 0x00FF_00FF_00FF_00FF)
        swap(&r.6, &r.7, 8, 0x00FF_00FF_00FF_00FF)
    }

    @inline(__always)
    private static func rowPair(_ first: UnsafeMutablePointer<UInt8>, _ second: UnsafeMutablePointer<UInt8>,
                                _ offset: Int) -> SIMD2<UInt64> {
        SIMD2(UnsafeRawPointer(first + offset).loadUnaligned(as: UInt64.self),
              UnsafeRawPointer(second + offset).loadUnaligned(as: UInt64.self))
    }

    @inline(__always)
    private static func lanes(_ column: SIMD2<UInt64>) -> Lanes { simd_short(unsafeBitCast(column, to: SIMD16<UInt8>.self)) }

    @inline(__always)
    private static func column(_ lanes: Lanes) -> SIMD2<UInt64> { unsafeBitCast(simd_uchar(lanes), to: SIMD2<UInt64>.self) }

    /// Segments across a vertical edge: 8 rows from `first` then 8 from `second`, each
    /// pointing at the q0 column.
    @inline(__always)
    static func loadVertical(_ first: UnsafeMutablePointer<UInt8>, _ second: UnsafeMutablePointer<UInt8>,
                             stride: Int) -> Segments {
        var r = (rowPair(first, second, -4), rowPair(first, second, stride - 4),
                 rowPair(first, second, 2 * stride - 4), rowPair(first, second, 3 * stride - 4),
                 rowPair(first, second, 4 * stride - 4), rowPair(first, second, 5 * stride - 4),
                 rowPair(first, second, 6 * stride - 4), rowPair(first, second, 7 * stride - 4))
        transpose(&r)
        return Segments(p3: lanes(r.0), p2: lanes(r.1), p1: lanes(r.2), p0: lanes(r.3),
                        q0: lanes(r.4), q1: lanes(r.5), q2: lanes(r.6), q3: lanes(r.7))
    }

    @inline(__always)
    static func storeVertical(_ s: Segments, _ first: UnsafeMutablePointer<UInt8>, _ second: UnsafeMutablePointer<UInt8>,
                              stride: Int) {
        var r = (column(s.p3), column(s.p2), column(s.p1), column(s.p0),
                 column(s.q0), column(s.q1), column(s.q2), column(s.q3))
        transpose(&r)
        @inline(__always) func put(_ pair: SIMD2<UInt64>, _ offset: Int) {
            UnsafeMutableRawPointer(first + offset).storeBytes(of: pair[0], as: UInt64.self)
            UnsafeMutableRawPointer(second + offset).storeBytes(of: pair[1], as: UInt64.self)
        }
        put(r.0, -4)
        put(r.1, stride - 4)
        put(r.2, 2 * stride - 4)
        put(r.3, 3 * stride - 4)
        put(r.4, 4 * stride - 4)
        put(r.5, 5 * stride - 4)
        put(r.6, 6 * stride - 4)
        put(r.7, 7 * stride - 4)
    }

    // MARK: Arithmetic
    //
    // Masks are all-ones / all-zeros lanes so selection compiles to bitwise selects.

    @inline(__always)
    private static func difference(_ a: Lanes, _ b: Lanes) -> Lanes { simd_abs(a &- b) }

    /// Clamps to the signed 8-bit range (the RFC's `c()`).
    @inline(__always)
    private static func clamp(_ v: Lanes) -> Lanes {
        simd_clamp(v, Lanes(repeating: -128), Lanes(repeating: 127))
    }

    @inline(__always)
    private static func lanes(_ mask: SIMDMask<Lanes.MaskStorage>) -> Lanes { unsafeBitCast(mask, to: Lanes.self) }

    /// `mask ? replacement : original` per lane.
    @inline(__always)
    private static func select(_ original: Lanes, _ replacement: Lanes, _ mask: Lanes) -> Lanes {
        simd_bitselect(original, replacement, mask)
    }

    /// The normal filter's enable test (`filter_yes`).
    @inline(__always)
    private static func enabled(_ s: Segments, _ limits: Limits) -> Lanes {
        let edge = lanes(difference(s.p0, s.q0) &* 2 &+ (difference(s.p1, s.q1) &>> 1) .<= limits.edge)
        let interior = simd_max(simd_max(simd_max(difference(s.p3, s.p2), difference(s.p2, s.p1)),
                                         simd_max(difference(s.p1, s.p0), difference(s.q1, s.q0))),
                                simd_max(difference(s.q3, s.q2), difference(s.q2, s.q1)))
        return edge & lanes(interior .<= limits.interior)
    }

    @inline(__always)
    private static func highVariance(_ s: Segments, _ limits: Limits) -> Lanes {
        lanes(simd_max(difference(s.p1, s.p0), difference(s.q1, s.q0)) .> limits.highVariance)
    }

    // MARK: Filters

    /// The simple filter (section 15.2); only p0 and q0 change. Returns false if no lane changed.
    @inline(__always)
    static func simple(_ s: inout Segments, edgeLimit: Lanes) -> Bool {
        let mask = lanes(difference(s.p0, s.q0) &* 2 &+ (difference(s.p1, s.q1) &>> 1) .<= edgeLimit)
        guard simd_any(mask) else { return false }
        let sp1 = s.p1 &- 128, sp0 = s.p0 &- 128, sq0 = s.q0 &- 128, sq1 = s.q1 &- 128
        let a = clamp(clamp(sp1 &- sq1) &+ 3 &* (sq0 &- sp0))
        let f1 = clamp(a &+ 4) &>> 3
        let f2 = clamp(a &+ 3) &>> 3
        s.q0 = select(s.q0, clamp(sq0 &- f1) &+ 128, mask)
        s.p0 = select(s.p0, clamp(sp0 &+ f2) &+ 128, mask)
        return true
    }

    /// The normal macroblock-edge filter (section 15.3, `MBfilter`).
    @inline(__always)
    static func macroblockEdge(_ s: inout Segments, _ limits: Limits) -> Bool {
        let mask = enabled(s, limits)
        guard simd_any(mask) else { return false }
        let hev = highVariance(s, limits)
        let sp2 = s.p2 &- 128, sp1 = s.p1 &- 128, sp0 = s.p0 &- 128
        let sq0 = s.q0 &- 128, sq1 = s.q1 &- 128, sq2 = s.q2 &- 128
        let w = clamp(clamp(sp1 &- sq1) &+ 3 &* (sq0 &- sp0))
        // High edge variance: adjust only the two edge pixels, as in the simple filter.
        let f1 = clamp(w &+ 4) &>> 3
        let f2 = clamp(w &+ 3) &>> 3
        // Otherwise spread roughly 3/7, 2/7, and 1/7 of the difference over three pixels per side.
        let a0 = clamp((27 &* w &+ 63) &>> 7)
        let a1 = clamp((18 &* w &+ 63) &>> 7)
        let a2 = clamp((9 &* w &+ 63) &>> 7)
        let wide = mask & ~hev
        let q0 = select(clamp(sq0 &- a0), clamp(sq0 &- f1), hev)
        let p0 = select(clamp(sp0 &+ a0), clamp(sp0 &+ f2), hev)
        s.q0 = select(s.q0, q0 &+ 128, mask)
        s.p0 = select(s.p0, p0 &+ 128, mask)
        s.q1 = select(s.q1, clamp(sq1 &- a1) &+ 128, wide)
        s.p1 = select(s.p1, clamp(sp1 &+ a1) &+ 128, wide)
        s.q2 = select(s.q2, clamp(sq2 &- a2) &+ 128, wide)
        s.p2 = select(s.p2, clamp(sp2 &+ a2) &+ 128, wide)
        return true
    }

    /// The normal subblock-edge filter (section 15.3, `subblock_filter`).
    @inline(__always)
    static func subblockEdge(_ s: inout Segments, _ limits: Limits) -> Bool {
        let mask = enabled(s, limits)
        guard simd_any(mask) else { return false }
        let hev = highVariance(s, limits)
        let sp1 = s.p1 &- 128, sp0 = s.p0 &- 128, sq0 = s.q0 &- 128, sq1 = s.q1 &- 128
        let outerTaps = clamp(sp1 &- sq1) & hev
        let a = clamp(outerTaps &+ 3 &* (sq0 &- sp0))
        let f1 = clamp(a &+ 4) &>> 3
        let f2 = clamp(a &+ 3) &>> 3
        s.q0 = select(s.q0, clamp(sq0 &- f1) &+ 128, mask)
        s.p0 = select(s.p0, clamp(sp0 &+ f2) &+ 128, mask)
        let outer = (f1 &+ 1) &>> 1
        let inner = mask & ~hev
        s.q1 = select(s.q1, clamp(sq1 &- outer) &+ 128, inner)
        s.p1 = select(s.p1, clamp(sp1 &+ outer) &+ 128, inner)
        return true
    }
}

