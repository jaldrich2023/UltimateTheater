//
//  TheoraDecoder.swift
//  Ultimate Theater
//
//  A from-scratch Theora video decoder written against the Xiph.Org "Theora Specification"
//  (Theora I, bitstream version 3.2.x). It parses the three header packets (identification,
//  comment, setup), then decodes intra and inter frames: run-length coded block flags,
//  macro block modes, motion vectors (including four-vector macro blocks), block-level qi
//  values, Huffman-coded DCT tokens, DC prediction, dequantization with interpolated
//  quantization matrices, the bit-exact integer inverse DCT, motion-compensated prediction,
//  the in-loop deblocking filter, and golden/previous reference frame bookkeeping. Output is
//  the cropped picture region, flipped from Theora's bottom-up layout to top-down rows, as
//  an 8-bit 4:2:0 `DecodedPicture` (4:2:2 and 4:4:4 streams have their chroma averaged down
//  to 4:2:0, since that is the only layout the renderer accepts).
//

import Foundation

// MARK: - Errors

/// Reasons a Theora packet could not be decoded.
nonisolated enum TheoraDecoderError: Error, Sendable {
    /// The packet violates a "MUST" of the specification (bad run lengths, coefficient
    /// tokens running past the end of a block, reserved bits set, ...).
    case corruptFrame(String)
}

// MARK: - Decoder

/// Decodes a Theora video stream into 4:2:0 pictures.
///
/// Create it with the stream's three header packets, then feed every following packet,
/// in order, to `decode(_:)`. The decoder keeps the golden (last intra) and previous
/// reference frames internally. After `reset()` it waits for the next intra frame.
nonisolated final class TheoraDecoder: SoftwareVideoDecoder {

    /// Chroma subsampling of the coded stream (the `PF` field of the identification header).
    nonisolated enum PixelFormat: Int, Sendable {
        /// Chroma at half resolution in both directions.
        case yuv420 = 0
        /// Chroma at half horizontal resolution.
        case yuv422 = 2
        /// Chroma at full resolution.
        case yuv444 = 3
    }

    // MARK: Stream properties (identification header)

    /// Bitstream version (major, minor, revision); always 3.2.x for decodable streams.
    let version: (major: Int, minor: Int, revision: Int)
    /// Coded frame size in pixels (a multiple of 16 in each direction).
    let frameWidth: Int
    let frameHeight: Int
    /// Size of the displayed picture region in pixels; this is the size of every output picture.
    let pictureWidth: Int
    let pictureHeight: Int
    /// Offset of the picture region from the left edge of the frame.
    let pictureX: Int
    /// Offset of the picture region from the *bottom* edge of the frame (as in the header).
    let pictureY: Int
    /// Frame rate as a fraction: `frameRateNumerator / frameRateDenominator` frames per second.
    let frameRateNumerator: Int
    let frameRateDenominator: Int
    /// Pixel aspect ratio; both are zero if the encoder didn't know it.
    let aspectNumerator: Int
    let aspectDenominator: Int
    /// Color space: 0 undefined, 1 Rec. 470M, 2 Rec. 470BG.
    let colorSpace: Int
    /// Nominal bitrate hint in bits per second (0 if unspecified).
    let nominalBitrate: Int
    /// Number of low granule-position bits holding the frames since the last keyframe (KFGSHIFT).
    let keyframeGranuleShift: Int
    /// The coded chroma subsampling.
    let pixelFormat: PixelFormat

    /// True if `packet` is a Theora intra (key) frame: a data packet whose frame-type bit is 0.
    static func isKeyframe(_ packet: Data) -> Bool {
        guard let first = packet.first else { return false }
        return first & 0xC0 == 0
    }

    // MARK: Setup header state

    /// Loop filter limit per qi.
    private var loopFilterLimits = [Int](repeating: 0, count: 64)
    /// Dequantization factors, indexed `((qti * 3 + pli) * 64 + qi) * 64 + zigzagIndex`.
    private let dequant: TheoraBuffer<Int32>
    /// The 80 DCT token Huffman codes, in a flat fast-lookup form.
    private let huffman: TheoraHuffmanSet

    // MARK: Geometry

    private let planes: [TheoraPlaneGeometry]
    private let blockCount: Int          // NBS
    private let lumaBlockCount: Int      // NLBS
    private let superBlockCount: Int     // NSBS
    private let macroBlockCount: Int     // NMBS
    private let chromaBlocksPerMacroBlock: Int
    /// First coded-order block index of each plane, plus `blockCount` at the end.
    private let planeStart: [Int]
    /// Per super block: first coded block index and number of blocks (coded order).
    private let superBlockStart: TheoraBuffer<Int32>
    private let superBlockSize: TheoraBuffer<UInt8>
    /// Per block (coded order): pixel offset of its lower-left corner from its plane's origin.
    private let blockOffset: TheoraBuffer<Int32>
    /// Per block (coded order): coded index of the macro block containing it.
    private let blockMacroBlock: TheoraBuffer<Int32>
    /// Per plane raster position: coded block index. All planes concatenated.
    private let rasterToCoded: TheoraBuffer<Int32>
    /// Per macro block: coded indices of its luma blocks in raster order (A, B, C, D).
    private let macroBlockLuma: TheoraBuffer<Int32>
    /// Per macro block: coded indices of its chroma blocks, in the order 4MV uses them.
    private let macroBlockChroma: TheoraBuffer<Int32>

    // MARK: Per-frame scratch

    private let blockCoded: TheoraBuffer<UInt8>      // BCODED
    private let blockMode: TheoraBuffer<UInt8>       // coding mode of each block's macro block
    private let blockMVX: TheoraBuffer<Int8>         // MVECTS
    private let blockMVY: TheoraBuffer<Int8>
    private let blockQII: TheoraBuffer<UInt8>        // QIIS
    private let tokenIndex: TheoraBuffer<UInt8>      // TIS
    private let coefficientCount: TheoraBuffer<UInt8> // NCOEFFS
    private let coefficients: TheoraBuffer<Int16>    // COEFFS, 64 per block, zig-zag order
    private let codedList: TheoraBuffer<Int32>       // coded blocks in coded order
    private let activeList: TheoraBuffer<Int32>      // blocks still receiving tokens
    private let macroBlockMode: TheoraBuffer<UInt8>  // MBMODES
    private let runBits: TheoraBuffer<UInt8>         // decoded run-length bit strings
    private let superBlockPartial: TheoraBuffer<UInt8>
    private let superBlockFull: TheoraBuffer<UInt8>
    /// Raster-order DC reference tags for DC prediction: 0 = not coded, else rfi + 1.
    private let dcReference: TheoraBuffer<UInt8>
    /// Scratch for one block's dequantized coefficients / residual.
    private let residual = TheoraBuffer<Int32>(count: 64, value: 0)
    /// Loop filter response, `lflim(R, L)` at index `R + 256`, for `lflimL`.
    private var lflim = [Int16](repeating: 0, count: 512)
    private var lflimL = -1

    // MARK: Reference frames

    private var golden: TheoraFrame?
    private var previous: TheoraFrame?
    /// Spare buffers recycled for new frames.
    private var spareFrames: [TheoraFrame] = []
    /// The last picture returned, for zero-length "repeat" packets.
    private var lastPicture: DecodedPicture?

    // MARK: - Setup

    /// Parses the identification, comment and setup headers. Fails if any is missing or invalid,
    /// or if the stream uses features this specification doesn't define.
    init?(headers: [Data]) {
        guard headers.count >= 3 else { return nil }
        let identification = [UInt8](headers[0])
        let comment = [UInt8](headers[1])
        let setup = [UInt8](headers[2])
        guard Self.hasCommonHeader(identification, type: 0x80),
              Self.hasCommonHeader(comment, type: 0x81),
              Self.hasCommonHeader(setup, type: 0x82),
              identification.count >= 42 else { return nil }

        // Identification header (section 6.2): 7 + 35 bytes.
        guard let id = Self.withBits(identification, { bits -> [Int]? in
            bits.skip(56)
            // VMAJ VMIN VREV FMBW FMBH PICW PICH PICX PICY FRN FRD PARN PARD CS NOMBR QUAL KFGSHIFT PF reserved
            let widths = [8, 8, 8, 16, 16, 24, 24, 8, 8, 32, 32, 24, 24, 8, 24, 6, 5, 2, 3]
            let fields = widths.map { bits.read($0) }
            return bits.overrun ? nil : fields
        }) else { return nil }
        let (fmbw, fmbh, picw, pich, picx, picy) = (id[3], id[4], id[5], id[6], id[7], id[8])
        guard id[0] == 3, id[1] == 2, id[18] == 0, let format = PixelFormat(rawValue: id[17]),
              fmbw > 0, fmbh > 0, id[9] > 0, id[10] > 0,
              picw > 0, pich > 0, picx + picw <= fmbw * 16, picy + pich <= fmbh * 16,
              // Refuse absurd sizes rather than allocate gigabytes (8K is the practical limit).
              fmbw * 16 <= 16_384, fmbh * 16 <= 16_384, fmbw * fmbh * 256 <= 8192 * 4352
        else { return nil }

        // Setup header (section 6.4).
        guard let parsed = Self.withBits(setup, { bits -> (TheoraBuffer<Int32>, [Int], TheoraHuffmanSet)? in
            bits.skip(56)
            var limits = [Int](repeating: 0, count: 64)
            guard let quant = Self.parseSetup(&bits, loopFilterLimits: &limits),
                  let huffmanSet = TheoraHuffmanSet(&bits), !bits.overrun else { return nil }
            return (quant, limits, huffmanSet)
        }) else { return nil }

        version = (id[0], id[1], id[2])
        frameWidth = fmbw * 16
        frameHeight = fmbh * 16
        pictureWidth = picw
        pictureHeight = pich
        pictureX = picx
        pictureY = picy
        frameRateNumerator = id[9]
        frameRateDenominator = id[10]
        aspectNumerator = id[11]
        aspectDenominator = id[12]
        colorSpace = id[13]
        nominalBitrate = id[14]
        keyframeGranuleShift = id[16]
        pixelFormat = format
        dequant = parsed.0
        loopFilterLimits = parsed.1
        huffman = parsed.2

        let layout = TheoraLayout(macroBlocksWide: fmbw, macroBlocksHigh: fmbh, format: format)
        planes = layout.planes
        blockCount = layout.blockCount
        lumaBlockCount = layout.planeStart[1]
        macroBlockCount = fmbw * fmbh
        superBlockCount = layout.superBlockCount
        chromaBlocksPerMacroBlock = layout.chromaBlocksPerMacroBlock
        planeStart = layout.planeStart
        superBlockStart = layout.superBlockStart
        superBlockSize = layout.superBlockSize
        blockOffset = layout.blockOffset
        blockMacroBlock = layout.blockMacroBlock
        rasterToCoded = layout.rasterToCoded
        macroBlockLuma = layout.macroBlockLuma
        macroBlockChroma = layout.macroBlockChroma

        let n = layout.blockCount
        blockCoded = TheoraBuffer(count: n, value: 0)
        blockMode = TheoraBuffer(count: n, value: 0)
        blockMVX = TheoraBuffer(count: n, value: 0)
        blockMVY = TheoraBuffer(count: n, value: 0)
        blockQII = TheoraBuffer(count: n, value: 0)
        tokenIndex = TheoraBuffer(count: n, value: 0)
        coefficientCount = TheoraBuffer(count: n, value: 0)
        coefficients = TheoraBuffer(count: n * 64, value: 0)
        codedList = TheoraBuffer(count: n, value: 0)
        activeList = TheoraBuffer(count: n, value: 0)
        macroBlockMode = TheoraBuffer(count: fmbw * fmbh, value: 0)
        runBits = TheoraBuffer(count: n, value: 0)
        superBlockPartial = TheoraBuffer(count: layout.superBlockCount, value: 0)
        superBlockFull = TheoraBuffer(count: layout.superBlockCount, value: 0)
        dcReference = TheoraBuffer(count: n, value: 0)
    }

    /// Runs `body` with a bit reader over `bytes`.
    private static func withBits<R>(_ bytes: [UInt8], _ body: (inout TheoraBits) -> R?) -> R? {
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return nil }
            var bits = TheoraBits(base, count: buffer.count)
            return body(&bits)
        }
    }
    /// Checks the 7-byte common header: a type byte and "theora".
    private static func hasCommonHeader(_ packet: [UInt8], type: UInt8) -> Bool {
        packet.count >= 7 && packet[0] == type && Array(packet[1..<7]) == Array("theora".utf8)
    }

    /// Decodes the loop filter limits and quantization parameters (sections 6.4.1-6.4.3) and
    /// builds every dequantization matrix up front. Returns nil if the header is invalid.
    private static func parseSetup(_ bits: inout TheoraBits, loopFilterLimits: inout [Int]) -> TheoraBuffer<Int32>? {
        // 6.4.1: loop filter limits.
        let lfBits = bits.read(3)
        for qi in 0..<64 { loopFilterLimits[qi] = bits.read(lfBits) }

        // 6.4.2: scale tables, base matrices and quant ranges.
        var acScale = [Int](repeating: 0, count: 64)
        var dcScale = [Int](repeating: 0, count: 64)
        var nbits = bits.read(4) + 1
        for qi in 0..<64 { acScale[qi] = bits.read(nbits) }
        nbits = bits.read(4) + 1
        for qi in 0..<64 { dcScale[qi] = bits.read(nbits) }
        let baseMatrixCount = bits.read(9) + 1
        guard baseMatrixCount <= 384 else { return nil }
        var baseMatrices = [Int](repeating: 0, count: baseMatrixCount * 64)
        for i in 0..<(baseMatrixCount * 64) { baseMatrices[i] = bits.read(8) }
        if bits.overrun { return nil }

        // Quant ranges per (qti, pli): sizes and base matrix indices at each end-point.
        var rangeSizes = [[Int]](repeating: [], count: 6)
        var rangeMatrices = [[Int]](repeating: [], count: 6)
        let bmiBits = ilog(baseMatrixCount - 1)
        for qti in 0..<2 {
            for pli in 0..<3 {
                let set = qti * 3 + pli
                let newRanges = (qti > 0 || pli > 0) ? bits.read(1) : 1
                if newRanges == 0 {
                    let copyFromPreviousType = qti > 0 ? bits.read(1) : 0
                    let source: Int
                    if copyFromPreviousType == 1 {
                        source = (qti - 1) * 3 + pli
                    } else {
                        let qtj = (3 * qti + pli - 1) / 3
                        let plj = (pli + 2) % 3
                        source = qtj * 3 + plj
                    }
                    rangeSizes[set] = rangeSizes[source]
                    rangeMatrices[set] = rangeMatrices[source]
                } else {
                    var qi = 0
                    var sizes: [Int] = []
                    var matrices: [Int] = [bits.read(bmiBits)]
                    guard matrices[0] < baseMatrixCount else { return nil }
                    while qi < 63 {
                        let size = bits.read(ilog(62 - qi)) + 1
                        sizes.append(size)
                        qi += size
                        let bmi = bits.read(bmiBits)
                        guard bmi < baseMatrixCount else { return nil }
                        matrices.append(bmi)
                        if bits.overrun { return nil }
                    }
                    guard qi == 63 else { return nil }
                    rangeSizes[set] = sizes
                    rangeMatrices[set] = matrices
                }
            }
        }
        if bits.overrun { return nil }

        // 6.4.3: compute every matrix, stored in zig-zag order for direct use on coefficients.
        let table = TheoraBuffer<Int32>(count: 6 * 64 * 64, value: 0)
        for qti in 0..<2 {
            for pli in 0..<3 {
                let set = qti * 3 + pli
                let sizes = rangeSizes[set], matrices = rangeMatrices[set]
                guard !sizes.isEmpty, matrices.count == sizes.count + 1 else { return nil }
                for qi in 0..<64 {
                    // Find the quant range containing qi.
                    var qri = 0
                    var start = 0
                    while qri < sizes.count - 1 && qi > start + sizes[qri] {
                        start += sizes[qri]
                        qri += 1
                    }
                    let size = sizes[qri]
                    let end = start + size
                    let bmi = matrices[qri], bmj = matrices[qri + 1]
                    for ci in 0..<64 {
                        let bm = (2 * (end - qi) * baseMatrices[bmi * 64 + ci]
                                  + 2 * (qi - start) * baseMatrices[bmj * 64 + ci]
                                  + size) / (2 * size)
                        let qmin: Int
                        if ci == 0 { qmin = qti == 0 ? 16 : 32 } else { qmin = qti == 0 ? 8 : 16 }
                        let scale = ci == 0 ? dcScale[qi] : acScale[qi]
                        let q = max(qmin, min((scale * bm / 100) * 4, 4096))
                        let zz = TheoraTables.naturalToZigzag[ci]
                        table.pointer[(set * 64 + qi) * 64 + zz] = Int32(q)
                    }
                }
            }
        }
        return table
    }

    /// Bits needed to store `a` in two's complement (0 for non-positive values).
    private static func ilog(_ a: Int) -> Int {
        a <= 0 ? 0 : (Int.bitWidth - a.leadingZeroBitCount)
    }

    // MARK: - SoftwareVideoDecoder

    func reset() {
        golden = nil
        previous = nil
        lastPicture = nil
    }

    func decode(_ frame: Data) throws -> DecodedPicture? {
        // A zero-length packet is an inter frame with no coded blocks: a repeated frame.
        guard let first = frame.first else { return previous == nil ? nil : lastPicture }
        // Header packets (and reserved packet types) have the high bit set.
        if first & 0x80 != 0 { return nil }
        let isIntra = first & 0x40 == 0
        if !isIntra && (previous == nil || golden == nil) { return nil }

        let picture: DecodedPicture = try frame.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw TheoraDecoderError.corruptFrame("empty packet")
            }
            var bits = TheoraBits(base, count: raw.count)
            let current = try decodeFrame(&bits)
            let oldGolden = golden, oldPrevious = previous
            if isIntra { golden = current }
            previous = current
            // Recycle buffers that are no longer referenced.
            for old in [oldGolden, oldPrevious].compactMap({ $0 })
            where old !== golden && old !== previous && !spareFrames.contains(where: { $0 === old }) {
                spareFrames.append(old)
            }
            return makePicture(current)
        }
        lastPicture = picture
        return picture
    }

    // MARK: - Frame decode (section 7.11)

    /// Decodes one data packet into a new reconstructed, loop-filtered, edge-padded frame.
    /// Throws on corrupt data; the reference frames are left untouched in that case.
    private func decodeFrame(_ bits: inout TheoraBits) throws -> TheoraFrame {
        // 7.1 Frame header.
        _ = bits.read(1)
        let frameType = bits.read(1)
        var qis = [bits.read(6)]
        if bits.read(1) == 1 {
            qis.append(bits.read(6))
            if bits.read(1) == 1 { qis.append(bits.read(6)) }
        }
        let isIntra = frameType == 0
        if isIntra && bits.read(3) != 0 {
            throw TheoraDecoderError.corruptFrame("reserved intra frame bits set")
        }

        let codedCount: Int
        do {
            codedCount = try decodeCodedBlocks(&bits, isIntra: isIntra)
            if isIntra {
                memset(macroBlockMode.pointer, 1, macroBlockCount)
            } else {
                try decodeMacroBlockModes(&bits)
            }
            // Give every coded block its macro block's mode.
            let list = codedList.pointer, modes = blockMode.pointer
            let mbOf = blockMacroBlock.pointer, mbModes = macroBlockMode.pointer
            for i in 0..<codedCount {
                let bi = Int(list[i])
                modes[bi] = mbModes[Int(mbOf[bi])]
            }
            if !isIntra { decodeMotionVectors(&bits) }
            try decodeBlockQIs(&bits, qiCount: qis.count, codedCount: codedCount)
            try decodeCoefficients(&bits, codedCount: codedCount)
        } catch {
            // Leave the coefficient store zeroed for the next frame.
            memset(coefficients.pointer, 0, blockCount * 64 * MemoryLayout<Int16>.size)
            throw error
        }
        undoDCPrediction()

        let current = newFrame()
        if !isIntra, let previous {
            // Uncoded blocks are copies of the previous frame: start from a full copy.
            for pli in 0..<3 {
                memcpy(current.base[pli], previous.base[pli], planes[pli].allocation)
            }
        }
        reconstruct(into: current, codedCount: codedCount, qis: qis)
        loopFilter(current, limit: loopFilterLimits[qis[0]])
        for pli in 0..<3 { padEdges(current.origin[pli], planes[pli]) }
        return current
    }

    /// A frame buffer that is neither of the current references.
    private func newFrame() -> TheoraFrame {
        while let frame = spareFrames.popLast() {
            if frame !== golden && frame !== previous { return frame }
        }
        return TheoraFrame(planes)
    }

    // MARK: 7.2 Run-length bit strings

    /// Decodes `count` bits coded with the long-run code (Table 7.7) into `runBits`.
    private func decodeLongRun(_ bits: inout TheoraBits, count: Int) throws {
        guard count > 0 else { return }
        let out = runBits.pointer
        var length = 0
        var bit = bits.read(1)
        while true {
            let start: Int, extra: Int
            if bits.read(1) == 0 { start = 1; extra = 0 }
            else if bits.read(1) == 0 { start = 2; extra = 1 }
            else if bits.read(1) == 0 { start = 4; extra = 1 }
            else if bits.read(1) == 0 { start = 6; extra = 2 }
            else if bits.read(1) == 0 { start = 10; extra = 3 }
            else if bits.read(1) == 0 { start = 18; extra = 4 }
            else { start = 34; extra = 12 }
            let run = start + bits.read(extra)
            guard length + run <= count else { throw TheoraDecoderError.corruptFrame("long run overflow") }
            memset(out + length, Int32(bit), run)
            length += run
            if length == count { return }
            bit = run == 4129 ? bits.read(1) : bit ^ 1
        }
    }

    /// Decodes `count` bits coded with the short-run code (Table 7.11) into `runBits`.
    private func decodeShortRun(_ bits: inout TheoraBits, count: Int) throws {
        guard count > 0 else { return }
        let out = runBits.pointer
        var length = 0
        var bit = bits.read(1)
        while true {
            let start: Int, extra: Int
            if bits.read(1) == 0 { start = 1; extra = 1 }
            else if bits.read(1) == 0 { start = 3; extra = 1 }
            else if bits.read(1) == 0 { start = 5; extra = 1 }
            else if bits.read(1) == 0 { start = 7; extra = 2 }
            else if bits.read(1) == 0 { start = 11; extra = 2 }
            else { start = 15; extra = 4 }
            let run = start + bits.read(extra)
            guard length + run <= count else { throw TheoraDecoderError.corruptFrame("short run overflow") }
            memset(out + length, Int32(bit), run)
            length += run
            if length == count { return }
            bit ^= 1
        }
    }

    // MARK: 7.3 Coded block flags

    /// Fills `blockCoded` and `codedList`; returns the number of coded blocks.
    private func decodeCodedBlocks(_ bits: inout TheoraBits, isIntra: Bool) throws -> Int {
        let coded = blockCoded.pointer, list = codedList.pointer
        if isIntra {
            memset(coded, 1, blockCount)
            for bi in 0..<blockCount { list[bi] = Int32(bi) }
            return blockCount
        }
        let partial = superBlockPartial.pointer, full = superBlockFull.pointer
        let starts = superBlockStart.pointer, sizes = superBlockSize.pointer
        let run = runBits.pointer

        try decodeLongRun(&bits, count: superBlockCount)
        var notPartial = 0
        var partialBlocks = 0
        for sbi in 0..<superBlockCount {
            partial[sbi] = run[sbi]
            if run[sbi] == 0 { notPartial += 1 } else { partialBlocks += Int(sizes[sbi]) }
        }
        try decodeLongRun(&bits, count: notPartial)
        var next = 0
        for sbi in 0..<superBlockCount where partial[sbi] == 0 {
            full[sbi] = run[next]
            next += 1
        }
        try decodeShortRun(&bits, count: partialBlocks)
        next = 0
        var count = 0
        for sbi in 0..<superBlockCount {
            let start = Int(starts[sbi]), size = Int(sizes[sbi])
            if partial[sbi] == 0 {
                let flag = full[sbi]
                memset(coded + start, Int32(flag), size)
                if flag != 0 {
                    for bi in start..<(start + size) { list[count] = Int32(bi); count += 1 }
                }
            } else {
                for bi in start..<(start + size) {
                    let flag = run[next]
                    next += 1
                    coded[bi] = flag
                    if flag != 0 { list[count] = Int32(bi); count += 1 }
                }
            }
        }
        return count
    }

    // MARK: 7.4 Macro block modes

    private func decodeMacroBlockModes(_ bits: inout TheoraBits) throws {
        let scheme = bits.read(3)
        var alphabet = [0, 0, 0, 0, 0, 0, 0, 0]
        if scheme == 0 {
            for mode in 0..<8 { alphabet[bits.read(3)] = mode }
        } else if scheme != 7 {
            alphabet = TheoraTables.modeSchemes[scheme - 1]
        }
        let coded = blockCoded.pointer, luma = macroBlockLuma.pointer, modes = macroBlockMode.pointer
        for mbi in 0..<macroBlockCount {
            let l = mbi * 4
            let anyLuma = coded[Int(luma[l])] | coded[Int(luma[l + 1])] | coded[Int(luma[l + 2])] | coded[Int(luma[l + 3])]
            guard anyLuma != 0 else { modes[mbi] = 0; continue }
            if scheme == 7 {
                modes[mbi] = UInt8(bits.read(3))
            } else {
                // Unary code: up to seven 1s, terminated by a 0 unless there are seven.
                var mi = 0
                while mi < 7 && bits.read(1) == 1 { mi += 1 }
                modes[mbi] = UInt8(alphabet[mi])
            }
        }
    }

    // MARK: 7.5 Motion vectors

    /// Reads one motion vector component, with the Huffman code of Table 7.23 or as
    /// a 5-bit magnitude plus sign.
    @inline(__always)
    private func readMVComponent(_ bits: inout TheoraBits, raw: Bool) -> Int {
        if raw {
            let magnitude = bits.read(5)
            return bits.read(1) == 1 ? -magnitude : magnitude
        }
        // Table 7.23, organized by its first three bits.
        switch bits.read(3) {
        case 0: return 0
        case 1: return 1
        case 2: return -1
        case 3: return bits.read(1) == 1 ? -2 : 2
        case 4: return bits.read(1) == 1 ? -3 : 3
        case 5:
            let m = 4 + bits.read(2)
            return bits.read(1) == 1 ? -m : m
        case 6:
            let m = 8 + bits.read(3)
            return bits.read(1) == 1 ? -m : m
        default:
            let m = 16 + bits.read(4)
            return bits.read(1) == 1 ? -m : m
        }
    }

    /// Rounds `sum / divisor` to the nearest integer, ties away from zero.
    @inline(__always)
    private static func roundedDivide(_ sum: Int, _ divisor: Int) -> Int {
        sum >= 0 ? (sum + divisor / 2) / divisor : -((divisor / 2 - sum) / divisor)
    }

    private func decodeMotionVectors(_ bits: inout TheoraBits) {
        let raw = bits.read(1) == 1
        let coded = blockCoded.pointer, modes = macroBlockMode.pointer
        let luma = macroBlockLuma.pointer, chroma = macroBlockChroma.pointer
        let mvx = blockMVX.pointer, mvy = blockMVY.pointer
        let chromaCount = chromaBlocksPerMacroBlock
        var last1 = (0, 0), last2 = (0, 0)
        for mbi in 0..<macroBlockCount {
            let mode = modes[mbi]
            var vector = (0, 0)
            switch mode {
            case 7: // INTER_MV_FOUR
                var vx = SIMD4<Int>(), vy = SIMD4<Int>()
                for i in 0..<4 {
                    let bi = Int(luma[mbi * 4 + i])
                    if coded[bi] != 0 {
                        vx[i] = readMVComponent(&bits, raw: raw)
                        vy[i] = readMVComponent(&bits, raw: raw)
                        vector = (vx[i], vy[i])
                    }
                    mvx[bi] = Int8(vx[i])
                    mvy[bi] = Int8(vy[i])
                }
                let c = mbi * chromaCount
                switch pixelFormat {
                case .yuv420:
                    let x = Self.roundedDivide(vx[0] + vx[1] + vx[2] + vx[3], 4)
                    let y = Self.roundedDivide(vy[0] + vy[1] + vy[2] + vy[3], 4)
                    for k in 0..<2 { let b = Int(chroma[c + k]); mvx[b] = Int8(x); mvy[b] = Int8(y) }
                case .yuv422:
                    let bx = Self.roundedDivide(vx[0] + vx[1], 2), by = Self.roundedDivide(vy[0] + vy[1], 2)
                    let tx = Self.roundedDivide(vx[2] + vx[3], 2), ty = Self.roundedDivide(vy[2] + vy[3], 2)
                    for k in stride(from: 0, through: 2, by: 2) { let b = Int(chroma[c + k]); mvx[b] = Int8(bx); mvy[b] = Int8(by) }
                    for k in stride(from: 1, through: 3, by: 2) { let b = Int(chroma[c + k]); mvx[b] = Int8(tx); mvy[b] = Int8(ty) }
                case .yuv444:
                    for k in 0..<8 { let b = Int(chroma[c + k]); mvx[b] = Int8(vx[k & 3]); mvy[b] = Int8(vy[k & 3]) }
                }
                last2 = last1
                last1 = vector
                continue
            case 6: // INTER_GOLDEN_MV
                vector = (readMVComponent(&bits, raw: raw), readMVComponent(&bits, raw: raw))
            case 4: // INTER_MV_LAST2
                vector = last2
                last2 = last1
                last1 = vector
            case 3: // INTER_MV_LAST
                vector = last1
            case 2: // INTER_MV
                vector = (readMVComponent(&bits, raw: raw), readMVComponent(&bits, raw: raw))
                last2 = last1
                last1 = vector
            default: // INTER_NOMV, INTRA, INTER_GOLDEN_NOMV
                vector = (0, 0)
            }
            let x = Int8(vector.0), y = Int8(vector.1)
            for i in 0..<4 { let b = Int(luma[mbi * 4 + i]); mvx[b] = x; mvy[b] = y }
            for k in 0..<chromaCount { let b = Int(chroma[mbi * chromaCount + k]); mvx[b] = x; mvy[b] = y }
        }
    }

    // MARK: 7.6 Block-level qi

    private func decodeBlockQIs(_ bits: inout TheoraBits, qiCount: Int, codedCount: Int) throws {
        let qii = blockQII.pointer, list = codedList.pointer, run = runBits.pointer
        for i in 0..<codedCount { qii[Int(list[i])] = 0 }
        guard qiCount > 1 else { return }
        for pass in 0..<(qiCount - 1) {
            var count = 0
            for i in 0..<codedCount where qii[Int(list[i])] == pass { count += 1 }
            try decodeLongRun(&bits, count: count)
            var next = 0
            for i in 0..<codedCount {
                let bi = Int(list[i])
                if qii[bi] == pass {
                    qii[bi] += run[next]
                    next += 1
                }
            }
        }
    }

    // MARK: 7.7 DCT coefficients

    /// Decodes the tokens for all 64 token indices of every coded block.
    private func decodeCoefficients(_ bits: inout TheoraBits, codedCount: Int) throws {
        let tis = tokenIndex.pointer, ncoeffs = coefficientCount.pointer
        let coeffs = coefficients.pointer
        let active = activeList.pointer
        let lookup = huffman.lookup.pointer, nodes = huffman.nodes.pointer
        let lookupBits = TheoraHuffmanSet.lookupBits
        let nlbs = lumaBlockCount
        memcpy(active, codedList.pointer, codedCount * MemoryLayout<Int32>.size)
        for i in 0..<codedCount { tis[Int(active[i])] = 0 }
        var activeCount = codedCount
        var remaining = codedCount // coded blocks whose token index is below 64
        var eobRun = 0
        var lumaTable = 0, chromaTable = 0

        for ti in 0..<64 {
            if ti <= 1 {
                lumaTable = bits.read(4)
                chromaTable = bits.read(4)
            }
            let group = ti == 0 ? 0 : ti <= 5 ? 1 : ti <= 14 ? 2 : ti <= 27 ? 3 : 4
            let lumaHT = 16 * group + lumaTable, chromaHT = 16 * group + chromaTable
            var kept = 0
            for k in 0..<activeCount {
                let bi = Int(active[k])
                if Int(tis[bi]) != ti {
                    active[kept] = Int32(bi); kept += 1
                    continue
                }
                ncoeffs[bi] = UInt8(ti)
                if eobRun > 0 {
                    tis[bi] = 64
                    eobRun -= 1
                    remaining -= 1
                    continue
                }
                // Huffman token: fast table on the next `lookupBits` bits, then a tree walk.
                let hti = bi < nlbs ? lumaHT : chromaHT
                let entry = lookup[hti << lookupBits | bits.peek(lookupBits)]
                let token: Int
                if entry & 0x8000_0000 == 0 {
                    bits.skip(Int(entry & 0xFF))
                    token = Int((entry >> 8) & 0xFF)
                } else {
                    bits.skip(lookupBits)
                    var node = Int((entry >> 8) & 0xFFFF)
                    while true {
                        let child = Int(nodes[node * 2 + bits.read(1)])
                        if child < 0 { token = -child - 1; break }
                        node = child
                    }
                }

                if token < 7 {
                    // EOB run (Table 7.33), including this block.
                    switch token {
                    case 0, 1, 2: eobRun = token + 1
                    case 3: eobRun = bits.read(2) + 4
                    case 4: eobRun = bits.read(3) + 8
                    case 5: eobRun = bits.read(4) + 16
                    default:
                        eobRun = bits.read(12)
                        if eobRun == 0 { eobRun = remaining }
                    }
                    tis[bi] = 64
                    remaining -= 1
                    eobRun -= 1
                    continue
                }

                // Coefficient tokens (Table 7.38): `zeros` zero coefficients, then `value`
                // (or nothing, for pure zero runs).
                var zeros = 0
                var value = 0
                switch token {
                case 7, 8:
                    let run = bits.read(token == 7 ? 3 : 6) + 1
                    let next = ti + run
                    guard next <= 64 else { throw TheoraDecoderError.corruptFrame("zero run past end of block") }
                    tis[bi] = UInt8(next)
                    if next == 64 { remaining -= 1 } else { active[kept] = Int32(bi); kept += 1 }
                    continue
                case 9: value = 1
                case 10: value = -1
                case 11: value = 2
                case 12: value = -2
                case 13, 14, 15, 16:
                    value = bits.read(1) == 1 ? 10 - token : token - 10
                case 17, 18, 19, 20, 21, 22:
                    let sign = bits.read(1)
                    let magnitude: Int
                    switch token {
                    case 17: magnitude = bits.read(1) + 7
                    case 18: magnitude = bits.read(2) + 9
                    case 19: magnitude = bits.read(3) + 13
                    case 20: magnitude = bits.read(4) + 21
                    case 21: magnitude = bits.read(5) + 37
                    default: magnitude = bits.read(9) + 69
                    }
                    value = sign == 1 ? -magnitude : magnitude
                case 23, 24, 25, 26, 27:
                    zeros = token - 22
                    value = bits.read(1) == 1 ? -1 : 1
                case 28:
                    let sign = bits.read(1)
                    zeros = bits.read(2) + 6
                    value = sign == 1 ? -1 : 1
                case 29:
                    let sign = bits.read(1)
                    zeros = bits.read(3) + 10
                    value = sign == 1 ? -1 : 1
                case 30:
                    let sign = bits.read(1)
                    let magnitude = bits.read(1) + 2
                    zeros = 1
                    value = sign == 1 ? -magnitude : magnitude
                default: // 31
                    let sign = bits.read(1)
                    let magnitude = bits.read(1) + 2
                    zeros = bits.read(1) + 2
                    value = sign == 1 ? -magnitude : magnitude
                }
                let position = ti + zeros
                guard position < 64 else { throw TheoraDecoderError.corruptFrame("token past end of block") }
                coeffs[bi * 64 + position] = Int16(value)
                let next = position + 1
                tis[bi] = UInt8(next)
                ncoeffs[bi] = UInt8(next)
                if next == 64 { remaining -= 1 } else { active[kept] = Int32(bi); kept += 1 }
            }
            activeCount = kept
        }
        // A conforming stream ends every block; anything left over is corrupt. Tolerate it
        // (the remaining coefficients are zero) instead of discarding the frame.
    }

    // MARK: 7.8 DC prediction

    private func undoDCPrediction() {
        let coded = blockCoded.pointer, modes = blockMode.pointer
        let coeffs = coefficients.pointer, r2c = rasterToCoded.pointer
        let tags = dcReference.pointer
        let rfiOfMode: [UInt8] = [1, 0, 1, 1, 1, 2, 2, 1]
        // Raster-order reference tags: 0 for uncoded blocks, rfi + 1 for coded ones.
        for i in 0..<blockCount {
            let bi = Int(r2c[i])
            tags[i] = coded[bi] == 0 ? 0 : rfiOfMode[Int(modes[bi] & 7)] + 1
        }
        let weights = TheoraTables.dcWeights
        for pli in 0..<3 {
            let w = planes[pli].blocksWide, h = planes[pli].blocksHigh
            let base = planeStart[pli]
            var lastDC = [0, 0, 0]
            for y in 0..<h {
                for x in 0..<w {
                    let ri = base + y * w + x
                    let tag = tags[ri]
                    guard tag != 0 else { continue }
                    let rfi = Int(tag) - 1
                    // Neighbors that precede this block in raster order: L, DL, D, DR.
                    var mask = 0
                    var l = 0, dl = 0, d = 0, dr = 0
                    if x > 0, tags[ri - 1] == tag {
                        mask |= 1; l = Int(coeffs[Int(r2c[ri - 1]) * 64])
                    }
                    if y > 0 {
                        if x > 0, tags[ri - w - 1] == tag {
                            mask |= 2; dl = Int(coeffs[Int(r2c[ri - w - 1]) * 64])
                        }
                        if tags[ri - w] == tag {
                            mask |= 4; d = Int(coeffs[Int(r2c[ri - w]) * 64])
                        }
                        if x + 1 < w, tags[ri - w + 1] == tag {
                            mask |= 8; dr = Int(coeffs[Int(r2c[ri - w + 1]) * 64])
                        }
                    }
                    var prediction: Int
                    if mask == 0 {
                        prediction = lastDC[rfi]
                    } else {
                        let wt = weights[mask]
                        prediction = (wt.0 * l + wt.1 * dl + wt.2 * d + wt.3 * dr) / wt.4
                        if mask & 7 == 7 {
                            if abs(prediction - d) > 128 { prediction = d }
                            else if abs(prediction - l) > 128 { prediction = l }
                            else if abs(prediction - dl) > 128 { prediction = dl }
                        }
                    }
                    let index = Int(r2c[ri]) * 64
                    let dc = Int16(truncatingIfNeeded: Int(coeffs[index]) + prediction)
                    coeffs[index] = dc
                    lastDC[rfi] = Int(dc)
                }
            }
        }
    }

    // MARK: 7.9 Reconstruction

    private func reconstruct(into frame: TheoraFrame, codedCount: Int, qis: [Int]) {
        let list = codedList.pointer, modes = blockMode.pointer
        let mvxs = blockMVX.pointer, mvys = blockMVY.pointer
        let offsets = blockOffset.pointer, qii = blockQII.pointer
        let ncoeffs = coefficientCount.pointer, coeffs = coefficients.pointer
        let dq = dequant.pointer
        let res = residual.pointer
        let qi0 = qis[0]
        let qiList = qis + [qis[0], qis[0]]
        let rfiOfMode = [1, 0, 1, 1, 1, 2, 2, 1]
        let zigzag = TheoraTables.zigzagToNatural

        var i = 0
        for pli in 0..<3 {
            let plane = planes[pli]
            let stride = plane.stride
            let dst = frame.origin[pli]
            let prevPlane = previous?.origin[pli]
            let goldPlane = golden?.origin[pli]
            // Motion vectors are in half pixels; quarter pixels on subsampled chroma axes.
            let xShift = (pli > 0 && pixelFormat != .yuv444) ? 2 : 1
            let yShift = (pli > 0 && pixelFormat == .yuv420) ? 2 : 1
            let end = planeStart[pli + 1]
            zigzag.withUnsafeBufferPointer { zz in
                while i < codedCount, Int(list[i]) < end {
                    let bi = Int(list[i])
                    i += 1
                    let mode = Int(modes[bi] & 7)
                    let rfi = rfiOfMode[mode]
                    let qti = rfi == 0 ? 0 : 1
                    let out = dst + Int(offsets[bi])
                    let blockCoeffs = coeffs + bi * 64
                    let nc = Int(ncoeffs[bi])
                    let dcTable = dq + ((qti * 3 + pli) * 64 + qi0) * 64

                    // Residual: DC-only shortcut, or dequantize + inverse DCT.
                    var dcOnly = 0
                    let full = nc >= 2
                    if !full {
                        dcOnly = Int(Int16(truncatingIfNeeded: (Int(blockCoeffs[0]) * Int(dcTable[0]) + 15) >> 5))
                        blockCoeffs[0] = 0
                    } else {
                        let acTable = dq + ((qti * 3 + pli) * 64 + qiList[Int(qii[bi])]) * 64
                        for k in 0..<64 { res[k] = 0 }
                        var rows = 0
                        res[0] = Int32(Int16(truncatingIfNeeded: Int(blockCoeffs[0]) * Int(dcTable[0])))
                        if res[0] != 0 { rows = 1 }
                        blockCoeffs[0] = 0
                        for k in 1..<nc {
                            let c = Int(blockCoeffs[k])
                            if c != 0 {
                                let n = Int(zz[k])
                                res[n] = Int32(Int16(truncatingIfNeeded: c * Int(acTable[k])))
                                rows |= 1 << (n >> 3)
                                blockCoeffs[k] = 0
                            }
                        }
                        TheoraIDCT.inverse2D(res, rows: rows)
                    }

                    // Prediction plus residual, clamped to 0...255.
                    if rfi == 0 {
                        if full {
                            for by in 0..<8 {
                                let row = out + by * stride, r = res + by * 8
                                for bx in 0..<8 { row[bx] = UInt8(clamping: 128 + Int(r[bx])) }
                            }
                        } else {
                            let v = UInt8(clamping: 128 + dcOnly)
                            for by in 0..<8 { (out + by * stride).update(repeating: v, count: 8) }
                        }
                        continue
                    }
                    guard let refPlane = rfi == 1 ? prevPlane : goldPlane else { continue }
                    let mvx = Int(mvxs[bi]), mvy = Int(mvys[bi])
                    let divX = 1 << xShift, divY = 1 << yShift
                    let x1 = mvx / divX, y1 = mvy / divY
                    let x2 = x1 + (mvx % divX == 0 ? 0 : (mvx > 0 ? 1 : -1))
                    let y2 = y1 + (mvy % divY == 0 ? 0 : (mvy > 0 ? 1 : -1))
                    let ref1 = refPlane + Int(offsets[bi]) + y1 * stride + x1
                    if x1 == x2 && y1 == y2 {
                        if full {
                            for by in 0..<8 {
                                let row = out + by * stride, src = ref1 + by * stride, r = res + by * 8
                                for bx in 0..<8 { row[bx] = UInt8(clamping: Int(src[bx]) + Int(r[bx])) }
                            }
                        } else if dcOnly == 0 {
                            for by in 0..<8 { (out + by * stride).update(from: ref1 + by * stride, count: 8) }
                        } else {
                            for by in 0..<8 {
                                let row = out + by * stride, src = ref1 + by * stride
                                for bx in 0..<8 { row[bx] = UInt8(clamping: Int(src[bx]) + dcOnly) }
                            }
                        }
                    } else {
                        let ref2 = refPlane + Int(offsets[bi]) + y2 * stride + x2
                        for by in 0..<8 {
                            let row = out + by * stride, a = ref1 + by * stride, b = ref2 + by * stride
                            if full {
                                let r = res + by * 8
                                for bx in 0..<8 {
                                    row[bx] = UInt8(clamping: ((Int(a[bx]) + Int(b[bx])) >> 1) + Int(r[bx]))
                                }
                            } else {
                                for bx in 0..<8 {
                                    row[bx] = UInt8(clamping: ((Int(a[bx]) + Int(b[bx])) >> 1) + dcOnly)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: 7.10 Loop filter

    /// Applies the deblocking filter to the edges of every coded block, in raster order.
    private func loopFilter(_ frame: TheoraFrame, limit: Int) {
        guard limit > 0 else { return } // lflim is identically zero
        if limit != lflimL {
            for i in 0..<512 {
                let r = i - 256
                let v: Int
                if r <= -2 * limit { v = 0 }
                else if r <= -limit { v = -r - 2 * limit }
                else if r < limit { v = r }
                else if r < 2 * limit { v = -r + 2 * limit }
                else { v = 0 }
                lflim[i] = Int16(v)
            }
            lflimL = limit
        }
        let tags = dcReference.pointer // non-zero exactly for coded blocks, in raster order
        lflim.withUnsafeBufferPointer { table in
            guard let lf = table.baseAddress.map({ $0 + 256 }) else { return }
            for pli in 0..<3 {
                let plane = planes[pli]
                let stride = plane.stride
                let origin = frame.origin[pli]
                let w = plane.blocksWide, h = plane.blocksHigh
                let base = planeStart[pli]
                for y in 0..<h {
                    for x in 0..<w {
                        let ri = base + y * w + x
                        guard tags[ri] != 0 else { continue }
                        let block = origin + y * 8 * stride + x * 8
                        if x > 0 { Self.filterVerticalEdge(block - 2, stride, lf) }
                        if y > 0 { Self.filterHorizontalEdge(block - 2 * stride, stride, lf) }
                        if x + 1 < w && tags[ri + 1] == 0 { Self.filterVerticalEdge(block + 6, stride, lf) }
                        if y + 1 < h && tags[ri + w] == 0 { Self.filterHorizontalEdge(block + 6 * stride, stride, lf) }
                    }
                }
            }
        }
    }

    /// The "horizontal filter" of 7.10.1: filters across a vertical block edge, 8 rows tall.
    /// `p` points at FX, two pixels left of the edge.
    @inline(__always)
    private static func filterVerticalEdge(_ p: UnsafeMutablePointer<UInt8>, _ stride: Int, _ lf: UnsafePointer<Int16>) {
        var row = p
        for _ in 0..<8 {
            let r = (Int(row[0]) - 3 * Int(row[1]) + 3 * Int(row[2]) - Int(row[3]) + 4) >> 3
            let f = Int(lf[r])
            row[1] = UInt8(clamping: Int(row[1]) + f)
            row[2] = UInt8(clamping: Int(row[2]) - f)
            row += stride
        }
    }

    /// The "vertical filter" of 7.10.2: filters across a horizontal block edge, 8 columns wide.
    /// `p` points at row FY, two rows below the edge.
    @inline(__always)
    private static func filterHorizontalEdge(_ p: UnsafeMutablePointer<UInt8>, _ stride: Int, _ lf: UnsafePointer<Int16>) {
        let r0 = p, r1 = p + stride, r2 = p + 2 * stride, r3 = p + 3 * stride
        for x in 0..<8 {
            let r = (Int(r0[x]) - 3 * Int(r1[x]) + 3 * Int(r2[x]) - Int(r3[x]) + 4) >> 3
            let f = Int(lf[r])
            r1[x] = UInt8(clamping: Int(r1[x]) + f)
            r2[x] = UInt8(clamping: Int(r2[x]) - f)
        }
    }

    /// Replicates a plane's edge pixels into its padding, which makes motion vectors that point
    /// outside the frame read the clamped edge values the predictors specify (7.9.1.2-3).
    private func padEdges(_ origin: UnsafeMutablePointer<UInt8>, _ plane: TheoraPlaneGeometry) {
        let pad = TheoraPlaneGeometry.padding
        let stride = plane.stride, width = plane.width, height = plane.height
        for y in 0..<height {
            let row = origin + y * stride
            (row - pad).update(repeating: row[0], count: pad)
            (row + width).update(repeating: row[width - 1], count: pad)
        }
        let bottom = origin - pad, top = origin + (height - 1) * stride - pad
        for k in 1...pad {
            (bottom - k * stride).update(from: bottom, count: stride)
            (top + k * stride).update(from: top, count: stride)
        }
    }

    // MARK: - Output

    /// Crops the picture region out of a frame, flips it to top-down rows, and converts the
    /// chroma to 4:2:0. 4:2:2 chroma is averaged vertically in pairs of rows; 4:4:4 chroma is
    /// averaged over 2x2 squares. For subsampled formats each output chroma sample is the one
    /// the spec associates with the luma sample at its top-left (section 4.4.4).
    private func makePicture(_ frame: TheoraFrame) -> DecodedPicture {
        let w = pictureWidth, h = pictureHeight
        let cw = (w + 1) / 2, ch = (h + 1) / 2
        let px = pictureX, py = pictureY
        var lumaOut = [UInt8](repeating: 0, count: w * h)
        var cbOut = [UInt8](repeating: 128, count: cw * ch)
        var crOut = [UInt8](repeating: 128, count: cw * ch)
        let lumaStride = planes[0].stride, chromaStride = planes[1].stride
        let luma = frame.origin[0]
        lumaOut.withUnsafeMutableBufferPointer { out in
            guard let dst = out.baseAddress else { return }
            for r in 0..<h {
                (dst + r * w).update(from: luma + (py + h - 1 - r) * lumaStride + px, count: w)
            }
        }
        let format = pixelFormat
        for (pli, isCb) in [(1, true), (2, false)] {
            let src = frame.origin[pli]
            let fill: (inout UnsafeMutableBufferPointer<UInt8>) -> Void = { out in
                guard let dst = out.baseAddress else { return }
                for r in 0..<ch {
                    // Frame rows (bottom-up) of output luma rows 2r and 2r+1.
                    let ly = py + h - 1 - 2 * r
                    let ly2 = max(ly - 1, py)
                    let row = dst + r * cw
                    switch format {
                    case .yuv420:
                        let s = src + (ly >> 1) * chromaStride
                        for c in 0..<cw { row[c] = s[(px + 2 * c) >> 1] }
                    case .yuv422:
                        let s1 = src + ly * chromaStride, s2 = src + ly2 * chromaStride
                        for c in 0..<cw {
                            let x = (px + 2 * c) >> 1
                            row[c] = UInt8((Int(s1[x]) + Int(s2[x]) + 1) >> 1)
                        }
                    case .yuv444:
                        let s1 = src + ly * chromaStride, s2 = src + ly2 * chromaStride
                        for c in 0..<cw {
                            let x = px + 2 * c, x2 = min(x + 1, px + w - 1)
                            row[c] = UInt8((Int(s1[x]) + Int(s1[x2]) + Int(s2[x]) + Int(s2[x2]) + 2) >> 2)
                        }
                    }
                }
            }
            if isCb { cbOut.withUnsafeMutableBufferPointer(fill) } else { crOut.withUnsafeMutableBufferPointer(fill) }
        }
        return DecodedPicture(width: w, height: h, y: lumaOut, u: cbOut, v: crOut, yStride: w, chromaStride: cw)
    }
}

// MARK: - Inverse DCT (7.9.3)

/// The bit-exact integer inverse DCT of the specification.
private nonisolated enum TheoraIDCT {
    // 16-bit approximations of cos(i*pi/16) (Table 7.65); S(j) = C(8 - j).
    static let c1 = 64277, c2 = 60547, c3 = 54491, c4 = 46341, c5 = 36410, c6 = 25080, c7 = 12785

    /// Truncates to a signed 16-bit value.
    @inline(__always)
    static func t16(_ v: Int) -> Int { Int(Int16(truncatingIfNeeded: v)) }

    /// The 1D transform (7.9.3.1) on 8 values `stride` apart, in place. Intermediate values
    /// never exceed 32 bits for 16-bit inputs, so plain `Int` arithmetic matches the spec's
    /// 32-bit truncation; the explicit 16-bit truncations are reproduced exactly.
    @inline(__always)
    static func inverse1D(_ p: UnsafeMutablePointer<Int32>, _ s: Int) {
        let y0 = Int(p[0]), y1 = Int(p[s]), y2 = Int(p[2 * s]), y3 = Int(p[3 * s])
        let y4 = Int(p[4 * s]), y5 = Int(p[5 * s]), y6 = Int(p[6 * s]), y7 = Int(p[7 * s])
        var t0 = (c4 * t16(y0 + y4)) >> 16
        var t1 = (c4 * t16(y0 - y4)) >> 16
        var t2 = ((c6 * y2) >> 16) - ((c2 * y6) >> 16)     // S6 = C2
        var t3 = ((c2 * y2) >> 16) + ((c6 * y6) >> 16)
        var t4 = ((c7 * y1) >> 16) - ((c1 * y7) >> 16)     // S7 = C1
        var t5 = ((c3 * y5) >> 16) - ((c5 * y3) >> 16)     // S3 = C5
        var t6 = ((c5 * y5) >> 16) + ((c3 * y3) >> 16)
        var t7 = ((c1 * y1) >> 16) + ((c7 * y7) >> 16)
        var r = t4 + t5
        t5 = (c4 * t16(t4 - t5)) >> 16
        t4 = r
        r = t7 + t6
        t6 = (c4 * t16(t7 - t6)) >> 16
        t7 = r
        r = t0 + t3; t3 = t0 - t3; t0 = r
        r = t1 + t2; t2 = t1 - t2; t1 = r
        r = t6 + t5; t5 = t6 - t5; t6 = r
        p[0] = Int32(t16(t0 + t7))
        p[s] = Int32(t16(t1 + t6))
        p[2 * s] = Int32(t16(t2 + t5))
        p[3 * s] = Int32(t16(t3 + t4))
        p[4 * s] = Int32(t16(t3 - t4))
        p[5 * s] = Int32(t16(t2 - t5))
        p[6 * s] = Int32(t16(t1 - t6))
        p[7 * s] = Int32(t16(t0 - t7))
    }

    /// The 2D transform (7.9.3.2), in place on 64 coefficients in natural order; leaves the
    /// residual with row index = vertical pixel position (bottom-up). `rows` has bit `r` set
    /// if row `r` may contain a non-zero coefficient; all-zero rows transform to zero, so they
    /// are skipped without changing the result.
    static func inverse2D(_ block: UnsafeMutablePointer<Int32>, rows: Int) {
        if rows == 1 {
            // Only the first row is non-zero: after the row pass, each column's input is a
            // lone Y[0], for which the column transform yields C4 * Y[0] >> 16 everywhere.
            inverse1D(block, 1)
            for c in 0..<8 {
                let v = ((c4 * t16(Int(block[c]))) >> 16 + 8) >> 4
                for r in 0..<8 { block[r * 8 + c] = Int32(v) }
            }
            return
        }
        for r in 0..<8 where rows & (1 << r) != 0 { inverse1D(block + r * 8, 1) }
        for c in 0..<8 {
            inverse1D(block + c, 8)
            for r in 0..<8 { block[r * 8 + c] = (block[r * 8 + c] + 8) >> 4 }
        }
    }
}

// MARK: - Supporting types

/// Size and memory layout of one plane. Planes are stored bottom row first, with a border of
/// `padding` replicated pixels on every side.
private nonisolated struct TheoraPlaneGeometry {
    /// Border width: covers the largest motion vector reach (15.5 pixels, rounded away from
    /// zero) beyond a block at the frame edge.
    static let padding = 32
    let blocksWide: Int
    let blocksHigh: Int
    var width: Int { blocksWide * 8 }
    var height: Int { blocksHigh * 8 }
    var stride: Int { width + 2 * Self.padding }
    var allocation: Int { stride * (height + 2 * Self.padding) }
    var superBlocksWide: Int { (blocksWide + 3) / 4 }
    var superBlocksHigh: Int { (blocksHigh + 3) / 4 }
}

/// The block, super block and macro block layout of a frame, with the coded-order index
/// tables derived from it (sections 2.3, 2.4).
private nonisolated struct TheoraLayout {
    let planes: [TheoraPlaneGeometry]
    let blockCount: Int
    let superBlockCount: Int
    let chromaBlocksPerMacroBlock: Int
    let planeStart: [Int]
    let superBlockStart: TheoraBuffer<Int32>
    let superBlockSize: TheoraBuffer<UInt8>
    let blockOffset: TheoraBuffer<Int32>
    let blockMacroBlock: TheoraBuffer<Int32>
    let rasterToCoded: TheoraBuffer<Int32>
    let macroBlockLuma: TheoraBuffer<Int32>
    let macroBlockChroma: TheoraBuffer<Int32>

    init(macroBlocksWide fmbw: Int, macroBlocksHigh fmbh: Int, format: TheoraDecoder.PixelFormat) {
        // Luma has 2x2 blocks per macro block; chroma depends on the subsampling.
        let chromaWide = format == .yuv444 ? fmbw * 2 : fmbw
        let chromaHigh = format == .yuv420 ? fmbh : fmbh * 2
        let planes = [TheoraPlaneGeometry(blocksWide: fmbw * 2, blocksHigh: fmbh * 2),
                      TheoraPlaneGeometry(blocksWide: chromaWide, blocksHigh: chromaHigh),
                      TheoraPlaneGeometry(blocksWide: chromaWide, blocksHigh: chromaHigh)]
        let lumaBlocks = fmbw * fmbh * 4, chromaBlocks = chromaWide * chromaHigh
        let blockCount = lumaBlocks + 2 * chromaBlocks
        let planeStart = [0, lumaBlocks, lumaBlocks + chromaBlocks, blockCount]
        let superBlockCount = planes.reduce(0) { $0 + $1.superBlocksWide * $1.superBlocksHigh }
        let perMacroBlock = 2 * chromaBlocks / (fmbw * fmbh)
        self.planes = planes
        self.blockCount = blockCount
        self.superBlockCount = superBlockCount
        self.planeStart = planeStart
        chromaBlocksPerMacroBlock = perMacroBlock

        // Coded block order: planes in turn, super blocks in raster order, the blocks of a
        // super block along a Hilbert curve (Figure 2.4), skipping blocks outside the plane.
        let sbStart = TheoraBuffer<Int32>(count: superBlockCount, value: 0)
        let sbSize = TheoraBuffer<UInt8>(count: superBlockCount, value: 0)
        let offsets = TheoraBuffer<Int32>(count: blockCount, value: 0)
        let r2c = TheoraBuffer<Int32>(count: blockCount, value: 0)
        var codedIndex = 0
        var superBlock = 0
        for (pli, plane) in planes.enumerated() {
            for sby in 0..<plane.superBlocksHigh {
                for sbx in 0..<plane.superBlocksWide {
                    sbStart.pointer[superBlock] = Int32(codedIndex)
                    var size = 0
                    for h in 0..<16 {
                        let x = sbx * 4 + TheoraTables.hilbertX[h]
                        let y = sby * 4 + TheoraTables.hilbertY[h]
                        guard x < plane.blocksWide, y < plane.blocksHigh else { continue }
                        r2c.pointer[planeStart[pli] + y * plane.blocksWide + x] = Int32(codedIndex)
                        offsets.pointer[codedIndex] = Int32(y * 8 * plane.stride + x * 8)
                        codedIndex += 1
                        size += 1
                    }
                    sbSize.pointer[superBlock] = UInt8(size)
                    superBlock += 1
                }
            }
        }

        // Macro blocks in coded order: luma super blocks in raster order, the 2x2 macro blocks
        // of each along a small Hilbert curve (Figure 2.6). Record their member blocks.
        let mbLuma = TheoraBuffer<Int32>(count: fmbw * fmbh * 4, value: 0)
        let mbChroma = TheoraBuffer<Int32>(count: fmbw * fmbh * perMacroBlock, value: 0)
        let blockMB = TheoraBuffer<Int32>(count: blockCount, value: 0)
        func coded(_ pli: Int, _ x: Int, _ y: Int) -> Int32 {
            r2c.pointer[planeStart[pli] + y * planes[pli].blocksWide + x]
        }
        var mbi = 0
        for sby in 0..<((fmbh + 1) / 2) {
            for sbx in 0..<((fmbw + 1) / 2) {
                for h in 0..<4 {
                    let mx = sbx * 2 + TheoraTables.macroHilbertX[h]
                    let my = sby * 2 + TheoraTables.macroHilbertY[h]
                    guard mx < fmbw, my < fmbh else { continue }
                    // A, B, C, D: lower-left, lower-right, upper-left, upper-right.
                    let luma = [coded(0, 2 * mx, 2 * my), coded(0, 2 * mx + 1, 2 * my),
                                coded(0, 2 * mx, 2 * my + 1), coded(0, 2 * mx + 1, 2 * my + 1)]
                    var chroma: [Int32] = []
                    switch format {
                    case .yuv420:
                        chroma = [coded(1, mx, my), coded(2, mx, my)]
                    case .yuv422:
                        // E, F: Cb bottom, top; G, H: Cr bottom, top.
                        chroma = [coded(1, mx, 2 * my), coded(1, mx, 2 * my + 1),
                                  coded(2, mx, 2 * my), coded(2, mx, 2 * my + 1)]
                    case .yuv444:
                        // E-H: Cb in raster order; I-L: Cr in raster order.
                        for pli in 1...2 {
                            chroma += [coded(pli, 2 * mx, 2 * my), coded(pli, 2 * mx + 1, 2 * my),
                                       coded(pli, 2 * mx, 2 * my + 1), coded(pli, 2 * mx + 1, 2 * my + 1)]
                        }
                    }
                    for (i, b) in luma.enumerated() {
                        mbLuma.pointer[mbi * 4 + i] = b
                        blockMB.pointer[Int(b)] = Int32(mbi)
                    }
                    for (i, b) in chroma.enumerated() {
                        mbChroma.pointer[mbi * perMacroBlock + i] = b
                        blockMB.pointer[Int(b)] = Int32(mbi)
                    }
                    mbi += 1
                }
            }
        }
        superBlockStart = sbStart
        superBlockSize = sbSize
        blockOffset = offsets
        rasterToCoded = r2c
        macroBlockLuma = mbLuma
        macroBlockChroma = mbChroma
        blockMacroBlock = blockMB
    }
}

/// One decoded frame: three padded planes.
private nonisolated final class TheoraFrame {
    let base: [UnsafeMutablePointer<UInt8>]
    /// Pixel (0, 0) - the bottom-left corner - of each plane.
    let origin: [UnsafeMutablePointer<UInt8>]

    init(_ planes: [TheoraPlaneGeometry]) {
        var base: [UnsafeMutablePointer<UInt8>] = []
        var origin: [UnsafeMutablePointer<UInt8>] = []
        for plane in planes {
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: plane.allocation)
            p.initialize(repeating: 0, count: plane.allocation)
            base.append(p)
            origin.append(p + TheoraPlaneGeometry.padding * plane.stride + TheoraPlaneGeometry.padding)
        }
        self.base = base
        self.origin = origin
    }

    deinit { for p in base { p.deallocate() } }
}

/// A fixed-size heap buffer of a trivial type, for bounds-check-free access in hot loops.
private nonisolated final class TheoraBuffer<Element> {
    let pointer: UnsafeMutablePointer<Element>
    let count: Int

    init(count: Int, value: Element) {
        self.count = count
        pointer = .allocate(capacity: max(count, 1))
        pointer.initialize(repeating: value, count: max(count, 1))
    }

    deinit { pointer.deallocate() }
}

/// MSB-first bit reader over a packet (section 5.2). Reading past the end yields zero bits
/// and sets `overrun`; it never touches memory outside the packet.
private nonisolated struct TheoraBits {
    private let base: UnsafePointer<UInt8>
    private let count: Int
    private var next = 0          // next byte to load into the cache
    private var cache: UInt64 = 0 // unread bits, left-aligned
    private var cached = 0        // number of valid bits in `cache`

    /// A reader over `count` bytes at `base`, which must stay valid while it is used.
    init(_ base: UnsafePointer<UInt8>, count: Int) {
        self.base = base
        self.count = count
    }

    /// True once more bits have been consumed than the packet holds.
    var overrun: Bool { next * 8 - cached > count * 8 }

    @inline(__always)
    private mutating func refill() {
        while cached <= 56 {
            let byte: UInt64 = next < count ? UInt64(base[next]) : 0
            next += 1
            cache |= byte << UInt64(56 - cached)
            cached += 8
        }
    }

    /// Reads an `n`-bit unsigned integer, 0 <= n <= 32.
    @inline(__always)
    mutating func read(_ n: Int) -> Int {
        guard n > 0 else { return 0 }
        if cached < n { refill() }
        let value = Int(cache >> UInt64(64 - n))
        cache <<= UInt64(n)
        cached -= n
        return value
    }

    /// The next `n` bits (1 <= n <= 32) without consuming them.
    @inline(__always)
    mutating func peek(_ n: Int) -> Int {
        if cached < n { refill() }
        return Int(cache >> UInt64(64 - n))
    }

    /// Consumes `n` bits (0 <= n <= 56).
    @inline(__always)
    mutating func skip(_ n: Int) {
        guard n > 0 else { return }
        if cached < n { refill() }
        cache = n >= 64 ? 0 : cache << UInt64(n)
        cached -= n
    }
}

/// The 80 DCT token Huffman codes from the setup header (section 6.4.4), as binary trees
/// plus a direct lookup table on the next `lookupBits` bits of the stream.
private nonisolated final class TheoraHuffmanSet {
    static let lookupBits = 10
    /// Per table, `1 << lookupBits` entries. Bit 31 clear: bits 0-7 code length, bits 8-15
    /// token. Bit 31 set: the code is longer; bits 8-23 are the tree node to continue from
    /// after consuming `lookupBits` bits.
    let lookup: TheoraBuffer<UInt32>
    /// Internal nodes of all trees: two children each; a child >= 0 is a node index (global),
    /// a child < 0 is a leaf holding token `-child - 1`.
    let nodes: TheoraBuffer<Int16>

    init?(_ bits: inout TheoraBits) {
        var allNodes: [Int16] = []
        var roots: [Int] = []
        for _ in 0..<80 {
            var leaves = 0
            guard let root = Self.parseTree(&bits, depth: 0, nodes: &allNodes, leaves: &leaves),
                  !bits.overrun else { return nil }
            roots.append(root)
        }
        let size = 1 << Self.lookupBits
        let table = TheoraBuffer<UInt32>(count: 80 * size, value: 0)
        for (hti, root) in roots.enumerated() {
            for pattern in 0..<size {
                var entry: UInt32
                if root < 0 {
                    entry = UInt32(-root - 1) << 8 // a single token with an empty code
                } else {
                    var node = root
                    var depth = 0
                    entry = 0x8000_0000
                    while depth < Self.lookupBits {
                        let bit = (pattern >> (Self.lookupBits - 1 - depth)) & 1
                        let child = Int(allNodes[node * 2 + bit])
                        depth += 1
                        if child < 0 { entry = UInt32(-child - 1) << 8 | UInt32(depth); break }
                        node = child
                    }
                    if entry & 0x8000_0000 != 0 { entry |= UInt32(node) << 8 }
                }
                table.pointer[hti * size + pattern] = entry
            }
        }
        lookup = table
        let nodeBuffer = TheoraBuffer<Int16>(count: allNodes.count, value: 0)
        for (i, n) in allNodes.enumerated() { nodeBuffer.pointer[i] = n }
        nodes = nodeBuffer
    }

    /// Reads one (sub)tree; returns the node index, or `-(token + 1)` for a leaf.
    private static func parseTree(_ bits: inout TheoraBits, depth: Int, nodes: inout [Int16], leaves: inout Int) -> Int? {
        guard depth <= 32, !bits.overrun else { return nil }
        if bits.read(1) == 1 {
            leaves += 1
            guard leaves <= 32 else { return nil }
            return -bits.read(5) - 1
        }
        let index = nodes.count / 2
        guard index < Int(Int16.max) else { return nil }
        nodes.append(0)
        nodes.append(0)
        guard let zero = parseTree(&bits, depth: depth + 1, nodes: &nodes, leaves: &leaves) else { return nil }
        nodes[index * 2] = Int16(zero)
        guard let one = parseTree(&bits, depth: depth + 1, nodes: &nodes, leaves: &leaves) else { return nil }
        nodes[index * 2 + 1] = Int16(one)
        return index
    }
}

// MARK: - Constant tables (from the specification)

private nonisolated enum TheoraTables {
    /// Block positions (x, y from the bottom-left) in Hilbert order within a super block (Figure 2.4).
    static let hilbertX = [0, 1, 1, 0, 0, 0, 1, 1, 2, 2, 3, 3, 3, 2, 2, 3]
    static let hilbertY = [0, 0, 1, 1, 2, 3, 3, 2, 2, 3, 3, 2, 1, 1, 0, 0]
    /// Macro block positions in Hilbert order within a luma super block (Figure 2.6).
    static let macroHilbertX = [0, 0, 1, 1]
    static let macroHilbertY = [0, 1, 1, 0]

    /// Zig-zag index of each coefficient in natural (row-major) order (Figure 2.8).
    static let naturalToZigzag: [Int] = [
        0, 1, 5, 6, 14, 15, 27, 28,
        2, 4, 7, 13, 16, 26, 29, 42,
        3, 8, 12, 17, 25, 30, 41, 43,
        9, 11, 18, 24, 31, 40, 44, 53,
        10, 19, 23, 32, 39, 45, 52, 54,
        20, 22, 33, 38, 46, 51, 55, 60,
        21, 34, 37, 47, 50, 56, 59, 61,
        35, 36, 48, 49, 57, 58, 62, 63,
    ]
    /// Natural index of each zig-zag position.
    static let zigzagToNatural: [Int] = {
        var table = [Int](repeating: 0, count: 64)
        for (natural, zz) in naturalToZigzag.enumerated() { table[zz] = natural }
        return table
    }()

    /// Mode alphabets for schemes 1-6, indexed by Huffman code index mi (Table 7.19).
    static let modeSchemes: [[Int]] = [
        [3, 4, 2, 0, 1, 5, 6, 7],
        [3, 4, 0, 2, 1, 5, 6, 7],
        [3, 2, 4, 0, 1, 5, 6, 7],
        [3, 2, 0, 4, 1, 5, 6, 7],
        [0, 3, 4, 2, 1, 5, 6, 7],
        [0, 5, 3, 4, 2, 1, 6, 7],
    ]

    /// DC predictor weights (L, DL, D, DR) and divisor for each set of available neighbors,
    /// indexed by L | DL << 1 | D << 2 | DR << 3 (Table 7.47). Entry 0 is unused.
    static let dcWeights: [(Int, Int, Int, Int, Int)] = [
        (0, 0, 0, 0, 1),
        (1, 0, 0, 0, 1),     // L
        (0, 1, 0, 0, 1),     // DL
        (1, 0, 0, 0, 1),     // L, DL
        (0, 0, 1, 0, 1),     // D
        (1, 0, 1, 0, 2),     // L, D
        (0, 0, 1, 0, 1),     // DL, D
        (29, -26, 29, 0, 32), // L, DL, D
        (0, 0, 0, 1, 1),     // DR
        (75, 0, 0, 53, 128), // L, DR
        (0, 1, 0, 1, 2),     // DL, DR
        (75, 0, 0, 53, 128), // L, DL, DR
        (0, 0, 1, 0, 1),     // D, DR
        (75, 0, 0, 53, 128), // L, D, DR
        (0, 3, 10, 3, 16),   // DL, D, DR
        (29, -26, 29, 0, 32), // all four
    ]
}
