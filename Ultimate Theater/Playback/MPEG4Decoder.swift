//
//  MPEG4Decoder.swift
//  Ultimate Theater
//
//  The engine's own MPEG-4 Part 2 (ISO/IEC 14496-2) video decoder, for the Simple and
//  Advanced Simple profiles that XviD, DivX 4-6 and similar encoders produce. VideoToolbox
//  only decodes Simple Profile without B-VOPs, so AVI/MKV/MP4 files from those encoders
//  are decoded here instead.
//
//  Supported: I/P/B/S(GMC) VOPs, H.263 and MPEG quantisation (default and custom matrices),
//  intra AC/DC prediction, 4MV, unrestricted motion vectors, half- and quarter-sample motion,
//  rounding control, B-VOP direct/forward/backward/interpolated modes, interlaced tools
//  (field DCT, field motion, field direct mode, alternate scan), global motion compensation
//  with 0-3 warping points, resync markers, data partitioning, reversible VLCs, the H.263
//  "short video header", DivX packed bitstreams and N-VOP placeholders.
//  Not supported (refused with an error): arbitrary shape, static sprites, scalability,
//  NEWPRED, reduced-resolution VOPs and bit depths other than 8. OBMC (which no MPEG-4
//  visual profile in use enables) is decoded as plain motion compensation.
//
//  The ISO/IEC 14496-5 reference software served as the documentation of the bitstream
//  syntax and decoding process (see THIRD_PARTY_NOTICES.md); this is an independent
//  implementation.
//

import Foundation

// MARK: - Errors

/// Why a frame couldn't be decoded.
nonisolated enum MPEG4DecoderError: Error, CustomStringConvertible {
    /// No video object layer header has been seen yet.
    case missingConfiguration
    /// The stream uses a tool this decoder doesn't implement.
    case unsupported(String)
    /// Header data is malformed.
    case invalidData(String)

    var description: String {
        switch self {
        case .missingConfiguration: "MPEG-4 video: no VOL header"
        case .unsupported(let what): "MPEG-4 video: unsupported \(what)"
        case .invalidData(let what): "MPEG-4 video: invalid data (\(what))"
        }
    }
}

// MARK: - Bit reader

/// MSB-first reader over a byte buffer that is followed by at least 8 readable zero bytes.
/// Reading past the end yields zeros; `isExhausted` reports it so callers can stop.
nonisolated struct MPEG4BitReader {
    private let base: UnsafePointer<UInt8>
    /// Number of real data bytes.
    let byteCount: Int
    /// Current position in bits from `base`.
    var position: Int

    init(base: UnsafePointer<UInt8>, byteCount: Int, position: Int = 0) {
        self.base = base
        self.byteCount = byteCount
        self.position = position
    }

    var bitsLeft: Int { byteCount * 8 - position }
    var isExhausted: Bool { position > byteCount * 8 }
    var isByteAligned: Bool { position & 7 == 0 }

    /// The next `count` bits (1...32) without consuming them.
    @inline(__always) func peek(_ count: Int) -> Int {
        let byte = position >> 3
        guard count > 0, byte <= byteCount, position >= 0 else { return 0 }
        let word = UInt64(bigEndian: UnsafeRawPointer(base + byte).loadUnaligned(as: UInt64.self))
        return Int(truncatingIfNeeded: (word << UInt64(position & 7)) >> UInt64(64 - count))
    }

    @inline(__always) mutating func skip(_ count: Int) { position += count }

    @inline(__always) mutating func read(_ count: Int) -> Int {
        let value = peek(count)
        position += count
        return value
    }

    @inline(__always) mutating func bit() -> Bool { read(1) == 1 }

    /// Reads one codeword from `vlc` and returns its symbol.
    @inline(__always) mutating func decode(_ vlc: MPEG4VLC) throws -> Int {
        let entry = vlc.table[peek(vlc.bits)]
        guard entry != 0 else { throw MPEG4DecoderError.invalidData("variable-length code") }
        position += Int(entry & 0xFF)
        return Int(entry >> 8)
    }

    /// Skips a marker bit (tolerating a wrong value, as many encoders get them wrong).
    @inline(__always) mutating func marker() { position += 1 }
}

// MARK: - Stream parameters

/// Which complexity-estimation fields VOP headers carry (only parsed, to skip them).
nonisolated struct MPEG4ComplexityEstimation {
    var method = 0
    var shapeFields = 0          // opaque, transparent, intra_cae, inter_cae, no_update, upsampling
    var intraBlocks = false, interBlocks = false, inter4vBlocks = false, notCodedBlocks = false
    var dctCoefs = false, dctLines = false, vlcSymbols = false, vlcBits = false
    var apm = false, npm = false, interpolateMCQ = false, forwBackMCQ = false, halfpel2 = false, halfpel4 = false
    var sadct = false, quarterpel = false
}

/// Parameters from the video object layer header.
nonisolated struct MPEG4VideoObjectLayer {
    var width = 0
    var height = 0
    var timeResolution = 1
    var timeIncrementBits = 1
    var interlaced = false
    var obmcDisabled = true
    /// 0 = none, 2 = GMC (static sprites are refused).
    var spriteMode = 0
    var warpPoints = 0
    var warpAccuracy = 0
    var mpegQuant = false
    var intraMatrix = MPEG4Tables.defaultIntraMatrix
    var interMatrix = MPEG4Tables.defaultInterMatrix
    var quarterSample = false
    var complexity: MPEG4ComplexityEstimation?
    var resyncDisabled = true
    var dataPartitioned = false
    var reversibleVLC = false
    var shortHeader = false
    var pixelAspect = (width: 1, height: 1)
}

/// Picture coding types.
nonisolated enum MPEG4VOPType: Int {
    case intra = 0, predicted, bidirectional, sprite
}

/// Parameters from one VOP header.
nonisolated struct MPEG4VOPHeader {
    var type = MPEG4VOPType.intra
    var coded = true
    var time = 0
    var rounding = 0
    var intraDCThreshold = 0
    var topFieldFirst = false
    var alternateScan = false
    var quant = 1
    var fcodeForward = 1
    var fcodeBackward = 1
    var warp: MPEG4Warp?
    /// Short header only: macroblock rows per group of blocks, and the GOB count.
    var gobRows = 0
    var gobCount = 0
}

// MARK: - Global motion compensation

/// The sprite warp of a GMC S-VOP, reduced to affine maps from sample positions to reference
/// positions (in 1/s sample units, s = 2^(warping_accuracy + 1), relative to a 16-sample luma /
/// 8-sample chroma margin around the picture, as in the standard's derivation).
nonisolated struct MPEG4Warp {
    let points: Int
    /// warping_accuracy + 1.
    let shift: Int
    // Luma: X = (cx + ax*x + bx*y) >> lumaShift, Y = (cy + ay*x + by*y) >> lumaShift.
    var cx = 0, ax = 0, bx = 0, cy = 0, ay = 0, by = 0, lumaShift = 0
    // Chroma, in chroma sample coordinates.
    var ccx = 0, cax = 0, cbx = 0, ccy = 0, cay = 0, cby = 0, chromaShift = 0
    /// Per-MB average vector inputs (luma map without the margin), for 2/3 points.
    var motionRounding = 0
    /// The translation for 1 point, in half (or quarter) samples.
    var translation = (x: 0, y: 0)

    /// Builds the warp from the decoded trajectory deltas (half-sample units).
    init(points: Int, accuracy: Int, du: [Int], dv: [Int], width: Int, height: Int) throws {
        self.points = points
        shift = accuracy + 1
        guard points <= 3 else { throw MPEG4DecoderError.unsupported("GMC with \(points) warping points") }
        guard points > 0 else { return }
        // Reconstruct the warped corner positions (half-sample units, 2 * position).
        var u = [0, 0, 0], v = [0, 0, 0]
        u[0] = du[0]; v[0] = dv[0]
        if points > 1 { u[1] = du[1] + u[0]; v[1] = dv[1] + v[0] }
        if points > 2 { u[2] = du[2] + u[0]; v[2] = dv[2] + v[0] }
        let sourceX = [0, width, 0], sourceY = [0, 0, height]
        let dstX = (0..<3).map { u[$0] + 2 * sourceX[$0] }
        let dstY = (0..<3).map { v[$0] + 2 * sourceY[$0] }
        let s = 1 << shift

        if points == 1 {
            // Pure translation.
            cx = (dstX[0] + 32) << accuracy; ax = s; bx = 0
            cy = (dstY[0] + 32) << accuracy; ay = 0; by = s
            lumaShift = 0
            let x0 = dstX[0] << accuracy, y0 = dstY[0] << accuracy
            ccx = ((x0 >> 1) | (x0 & 1)) + (8 << shift); cax = s; cbx = 0
            ccy = ((y0 >> 1) | (y0 & 1)) + (8 << shift); cay = 0; cby = s
            chromaShift = 0
            translation = (dstX[0], dstY[0])
            return
        }

        // Two or three points: positions in 1/16 sample, extrapolated to power-of-two spans.
        let x0 = dstX[0] << 3, y0 = dstY[0] << 3, x1 = dstX[1] << 3, y1 = dstY[1] << 3
        var vw = 1, vwShift = 0
        while vw < width { vw <<= 1; vwShift += 1 }
        var vh = 1, vhShift = 0
        if points == 3 {
            while vh < height { vh <<= 1; vhShift += 1 }
        }
        let x1e = Self.extrapolate(0, width, x0, x1, width, vw) + (vw << 4)
        let y1e = Self.extrapolate(0, 0, y0, y1, width, vw)
        var x2e = 0, y2e = 0
        if points == 3 {
            let x2 = dstX[2] << 3, y2 = dstY[2] << 3
            x2e = Self.extrapolate(0, 0, x0, x2, height, vh)
            y2e = Self.extrapolate(0, height, y0, y2, height, vh) + (vh << 4)
        }
        // Positions relative to the 16-sample margin.
        let mx0 = x0 + 256, my0 = y0 + 256, mx1 = x1e + 256, my1 = y1e + 256, mx2 = x2e + 256, my2 = y2e + 256
        var vwh = vw * vh, vwhShift = vwShift + vhShift
        if points == 3 {
            if vwShift <= vhShift {
                vh /= vw; vwh /= vw; vw = 1; vhShift -= vwShift; vwhShift -= vwShift; vwShift = 0
            } else {
                vw /= vh; vwh /= vh; vh = 1; vwShift -= vhShift; vwhShift -= vhShift; vhShift = 0
            }
        }
        let rShift = 4 - shift
        let rat = 1 << rShift
        var a: Int, b: Int, c: Int, d: Int, e: Int, f: Int, span: Int, spanShift: Int
        if points == 2 {
            a = mx1 - mx0; b = -(my1 - my0); c = mx0 * vw
            d = -b; e = a; f = my0 * vw
            span = vw; spanShift = vwShift
        } else {
            a = (mx1 - mx0) * vh; b = (mx2 - mx0) * vw; c = mx0 * vwh
            d = (my1 - my0) * vh; e = (my2 - my0) * vw; f = my0 * vwh
            span = vwh; spanShift = vwhShift
        }
        lumaShift = rShift + spanShift
        cx = c + rat * span / 2; ax = a; bx = b
        cy = f + rat * span / 2; ay = d; by = e
        motionRounding = rat * span / 2
        // Chroma (sample-siting offset and doubled precision).
        chromaShift = lumaShift + 2
        ccx = a + b + (2 * span * mx0 - 16 * span) + 2 * rat * span; cax = 4 * a; cbx = 4 * b
        ccy = d + e + (2 * span * my0 - 16 * span) + 2 * rat * span; cay = 4 * d; cby = 4 * e
    }

    /// Floor division with a non-negative remainder.
    private static func divide(_ num: Int, _ denom: Int) -> (quot: Int, res: Int) {
        var quot = num / denom
        if quot * denom == num { return (quot, 0) }
        if num < 0 { quot -= 1 }
        return (quot, num - denom * quot)
    }

    /// Extrapolates a corner position from span `w` to the power-of-two span `vw`, rounding
    /// exactly as the standard specifies.
    private static func extrapolate(_ x0: Int, _ x1: Int, _ x0p: Int, _ x1p: Int, _ w: Int, _ vw: Int) -> Int {
        guard w > 0 else { return 0 }
        var (quot, res) = divide(x0p - (x0 << 4), w)
        var result = quot * (w - vw)
        (quot, res) = divide(res * (w - vw), w)
        result += quot
        var resSum = res
        (quot, res) = divide(x1p - (x1 << 4), w)
        result += quot * vw + res
        (quot, res) = divide(res * (vw - w), w)
        result += quot
        resSum += res
        (quot, res) = divide(resSum, w)
        result += quot
        if result >= 0 {
            if res >= (w + 1) / 2 { result += 1 }
        } else if res > w / 2 {
            result += 1
        }
        return result
    }
}

// MARK: - Pictures

/// One 8-bit plane with a replicated border, so motion vectors may point outside the picture.
nonisolated final class MPEG4Plane {
    /// Macroblock-aligned size.
    let width: Int
    let height: Int
    let pad: Int
    let stride: Int
    private let storage: UnsafeMutablePointer<UInt8>
    private let storageCount: Int
    /// Sample (0, 0).
    let origin: UnsafeMutablePointer<UInt8>

    init(width: Int, height: Int, pad: Int, fill: UInt8) {
        self.width = width
        self.height = height
        self.pad = pad
        stride = width + 2 * pad
        storageCount = stride * (height + 2 * pad)
        storage = .allocate(capacity: storageCount)
        storage.initialize(repeating: fill, count: storageCount)
        origin = storage + pad * stride + pad
    }

    deinit { storage.deallocate() }

    /// Replicates the outermost samples into the border.
    func extendEdges() {
        for row in 0..<height {
            let line = origin + row * stride
            let left = line[0], right = line[width - 1]
            (line - pad).update(repeating: left, count: pad)
            (line + width).update(repeating: right, count: pad)
        }
        let top = origin - pad
        let bottom = origin + (height - 1) * stride - pad
        for row in 1...pad {
            (top - row * stride).update(from: top, count: stride)
            (bottom + row * stride).update(from: bottom, count: stride)
        }
    }

    func copy(from other: MPEG4Plane) {
        guard other.storageCount == storageCount else { return }
        storage.update(from: other.storage, count: storageCount)
    }
}

/// Macroblock coding modes kept with a decoded anchor (for B-VOP direct mode and skipping).
nonisolated struct MPEG4MacroblockMode: Sendable {
    var intra = false
    var notCoded = false
    var gmc = false
    var fourMV = false
    var fieldMotion = false
    /// Field references of field-predicted macroblocks (true = bottom field).
    var topFromBottom = false
    var bottomFromBottom = false
}

/// A motion vector in half- or quarter-sample units (vertical in frame units for field vectors).
nonisolated struct MPEG4Vector: Equatable, Sendable {
    var x = 0
    var y = 0
    static let zero = MPEG4Vector()
}

/// A decoded picture plus the macroblock information later VOPs refer to.
nonisolated final class MPEG4Frame {
    let luma: MPEG4Plane
    let cb: MPEG4Plane
    let cr: MPEG4Plane
    /// Presentation time in vop_time_increment ticks.
    var time = 0
    var modes: [MPEG4MacroblockMode]
    /// Four block vectors per macroblock (all equal for one-vector macroblocks).
    var vectors: [MPEG4Vector]
    /// Top and bottom field vectors per field-predicted macroblock.
    var fieldVectors: [MPEG4Vector]

    init(mbColumns: Int, mbRows: Int) {
        luma = MPEG4Plane(width: mbColumns * 16, height: mbRows * 16, pad: 32, fill: 16)
        cb = MPEG4Plane(width: mbColumns * 8, height: mbRows * 8, pad: 16, fill: 128)
        cr = MPEG4Plane(width: mbColumns * 8, height: mbRows * 8, pad: 16, fill: 128)
        let count = mbColumns * mbRows
        modes = Array(repeating: MPEG4MacroblockMode(), count: count)
        vectors = Array(repeating: .zero, count: count * 4)
        fieldVectors = Array(repeating: .zero, count: count * 2)
    }

    func extendEdges() {
        luma.extendEdges()
        cb.extendEdges()
        cr.extendEdges()
    }
}

// MARK: - Decoder

/// Decodes MPEG-4 Part 2 video frames (in decode order) into pictures (in display order).
nonisolated final class MPEG4Decoder {
    /// Display size from the VOL (or short header).
    var width: Int { vol?.width ?? 0 }
    var height: Int { vol?.height ?? 0 }
    /// Pixel aspect ratio from the VOL.
    var pixelAspectRatio: (width: Int, height: Int) { vol?.pixelAspect ?? (1, 1) }
    /// Macroblocks reconstructed by error concealment since creation (diagnostics).
    private(set) var concealedMacroblocks = 0
    /// The last error recovered from inside a VOP (diagnostics).
    private(set) var lastConcealedError: Error?
    /// A one-line description of the stream's coding tools (diagnostics).
    var streamSummary: String {
        guard let vol else { return "no VOL" }
        var tools: [String] = []
        if vol.shortHeader { tools.append("short header") }
        if vol.mpegQuant { tools.append("MPEG quant") }
        if vol.intraMatrix != MPEG4Tables.defaultIntraMatrix || vol.interMatrix != MPEG4Tables.defaultInterMatrix {
            tools.append("custom matrices")
        }
        if vol.quarterSample { tools.append("qpel") }
        if vol.interlaced { tools.append("interlaced") }
        if vol.spriteMode == 2 { tools.append("GMC(\(vol.warpPoints) points)") }
        if !vol.obmcDisabled { tools.append("OBMC") }
        if !vol.resyncDisabled { tools.append("resync") }
        if vol.dataPartitioned { tools.append(vol.reversibleVLC ? "data partitioning+RVLC" : "data partitioning") }
        if packedBitstream { tools.append("packed") }
        return String(format: "%dx%d profile 0x%02X time %d/%d bits: ", vol.width, vol.height, profileLevel,
                      vol.timeResolution, vol.timeIncrementBits) + (tools.isEmpty ? "plain" : tools.joined(separator: ", "))
    }

    // Stream state
    private var vol: MPEG4VideoObjectLayer?
    private var vop = MPEG4VOPHeader()
    private var profileLevel = 0
    private var packedBitstream = false
    private var moduloBaseDecode = 0
    private var moduloBaseDisplay = 0
    private var waitingForIntra = true
    /// vop_time_increment width found to fit the VOPs when the VOL's doesn't.
    private var timeIncrementOverride: Int?
    /// Added to VOP times to repair streams without modulo_time_base (see `unwrapTime`).
    private var timeOffset = 0
    /// Pictures to return ahead of the next decode result (a held picture flushed by a size change).
    private var pendingOutput: [DecodedPicture] = []

    // Reference pictures: `future` is the newest anchor, held until the next anchor arrives.
    private var past: MPEG4Frame?
    private var future: MPEG4Frame?
    private var futureHeld = false
    private var spare: MPEG4Frame?
    private var bidirectional: MPEG4Frame?

    // Geometry
    private var mbColumns = 0
    private var mbRows = 0
    private var mbCount: Int { mbColumns * mbRows }

    // Per-VOP macroblock state
    private var quantiser = 1
    private var packetStart = 0
    private var dcRestart = true
    private var mbIntra: [Bool] = []
    private var mbQuant: [Int] = []
    /// Intra prediction memory: 15 values per block (reconstructed DC, first row, first column).
    private var predictionMemory: UnsafeMutablePointer<Int32>
    private var predictionMemoryCount = 0
    private var forwardPredictors = [MPEG4Vector](repeating: .zero, count: 2)
    private var backwardPredictors = [MPEG4Vector](repeating: .zero, count: 2)

    // Scratch buffers
    private let coefficients: UnsafeMutablePointer<Int32>
    private let residual: UnsafeMutablePointer<Int32>
    private let residualBlocks: UnsafeMutablePointer<Int32>   // 6 × 64
    private let predictionY: UnsafeMutablePointer<UInt8>       // 16 × 16
    private let predictionU: UnsafeMutablePointer<UInt8>       // 8 × 8
    private let predictionV: UnsafeMutablePointer<UInt8>
    private let backwardY: UnsafeMutablePointer<UInt8>
    private let backwardU: UnsafeMutablePointer<UInt8>
    private let backwardV: UnsafeMutablePointer<UInt8>
    private let edgeBuffer: UnsafeMutablePointer<UInt8>        // edge-emulated MC source
    private let filterBuffer: UnsafeMutablePointer<UInt8>      // quarter-sample intermediate
    private let idctBasis: UnsafeMutablePointer<SIMD8<Float>>

    // Tables (copied once so lookups don't go through lazy statics)
    private let coefficientVLC = MPEG4Tables.coefficientVLC
    private let intraEvents = MPEG4Tables.intraCoefficientEventsWide
    private let interEvents = MPEG4Tables.interCoefficientEvents
    private let motionVLC = MPEG4Tables.motionVLC
    private let mcbpcIntraVLC = MPEG4Tables.mcbpcIntraVLC
    private let mcbpcInterVLC = MPEG4Tables.mcbpcInterVLC
    private let cbpyVLC = MPEG4Tables.cbpyVLC
    private let dcLumaVLC = MPEG4Tables.dcSizeLumaVLC
    private let dcChromaVLC = MPEG4Tables.dcSizeChromaVLC
    private let zigzag = MPEG4Tables.zigzag
    private let alternateHorizontal = MPEG4Tables.alternateHorizontal
    private let alternateVertical = MPEG4Tables.alternateVertical

    /// `configuration`: VOS/VO/VOL headers when known (AVI first frame, MP4 esds, MKV codec
    /// private). They may also arrive in-band inside a keyframe.
    init(configuration: Data?) {
        coefficients = .allocate(capacity: 64)
        residual = .allocate(capacity: 64)
        residualBlocks = .allocate(capacity: 6 * 64)
        predictionY = .allocate(capacity: 256)
        predictionU = .allocate(capacity: 64)
        predictionV = .allocate(capacity: 64)
        backwardY = .allocate(capacity: 256)
        backwardU = .allocate(capacity: 64)
        backwardV = .allocate(capacity: 64)
        edgeBuffer = .allocate(capacity: 32 * 32)
        filterBuffer = .allocate(capacity: 32 * 32)
        idctBasis = .allocate(capacity: 8)
        predictionMemory = .allocate(capacity: 1)
        coefficients.initialize(repeating: 0, count: 64)
        residual.initialize(repeating: 0, count: 64)
        residualBlocks.initialize(repeating: 0, count: 6 * 64)
        for buffer in [predictionY, backwardY] { buffer.initialize(repeating: 0, count: 256) }
        for buffer in [predictionU, predictionV, backwardU, backwardV] { buffer.initialize(repeating: 0, count: 64) }
        edgeBuffer.initialize(repeating: 0, count: 32 * 32)
        filterBuffer.initialize(repeating: 0, count: 32 * 32)
        predictionMemory.initialize(to: 0)
        // Column u of the 8-point inverse DCT matrix: C(u)/2 · cos((2x + 1)uπ/16), x = 0...7.
        for u in 0..<8 {
            var column = SIMD8<Float>()
            let scale = u == 0 ? 1 / (2 * 2.0.squareRoot()) : 0.5
            for x in 0..<8 { column[x] = Float(scale * cos(Double((2 * x + 1) * u) * Double.pi / 16)) }
            (idctBasis + u).initialize(to: column)
        }
        if let configuration {
            _ = try? process(configuration, headersOnly: true)
        }
    }

    deinit {
        coefficients.deallocate()
        residual.deallocate()
        residualBlocks.deallocate()
        predictionY.deallocate()
        predictionU.deallocate()
        predictionV.deallocate()
        backwardY.deallocate()
        backwardU.deallocate()
        backwardV.deallocate()
        edgeBuffer.deallocate()
        filterBuffer.deallocate()
        idctBasis.deallocate()
        predictionMemory.deallocate()
    }

    // MARK: Public interface

    /// Decodes one container frame (in decode order). It may hold several VOPs (DivX packed
    /// bitstream) or be an N-VOP placeholder. Returns the pictures now ready, in display order:
    /// anchors (I/P/S) are held until the next anchor; B-VOPs are returned immediately.
    func decode(_ frame: Data) throws -> [DecodedPicture] {
        let pictures = try process(frame, headersOnly: false)
        guard !pendingOutput.isEmpty else { return pictures }
        defer { pendingOutput.removeAll() }
        return pendingOutput + pictures
    }

    /// The remaining held picture at the end of the stream.
    func flush() -> [DecodedPicture] {
        var output = pendingOutput
        pendingOutput.removeAll()
        if futureHeld, let future {
            futureHeld = false
            output.append(picture(from: future))
        }
        return output
    }

    /// Drops references (after a seek); decoding resumes at the next I-VOP.
    func reset() {
        if let past { spare = past }
        past = nil
        if let future, spare == nil { spare = future }
        future = nil
        futureHeld = false
        waitingForIntra = true
    }

    // MARK: Start codes

    /// Walks the start codes in `data`, parsing headers and (unless `headersOnly`) decoding VOPs.
    private func process(_ data: Data, headersOnly: Bool) throws -> [DecodedPicture] {
        var bytes = [UInt8](data)
        let count = bytes.count
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 16))
        return try bytes.withUnsafeBufferPointer { buffer -> [DecodedPicture] in
            guard let base = buffer.baseAddress else { return [] }
            // A short video header (H.263 picture start code) instead of MPEG-4 start codes.
            if count >= 4, base[0] == 0, base[1] == 0, base[2] & 0xFC == 0x80 {
                return headersOnly ? [] : try decodeShortHeaderPicture(base: base, count: count)
            }
            var starts: [Int] = []
            var index = 0
            while index + 3 < count {
                if base[index + 2] > 1 { index += 3; continue }
                if base[index] == 0, base[index + 1] == 0, base[index + 2] == 1 {
                    starts.append(index)
                    index += 3
                } else {
                    index += 1
                }
            }
            var output: [DecodedPicture] = []
            let vopCount = starts.filter { base[$0 + 3] == 0xB6 }.count
            if vopCount > 1 { packedBitstream = true }
            for (number, start) in starts.enumerated() {
                let end = number + 1 < starts.count ? starts[number + 1] : count
                let code = base[start + 3]
                var reader = MPEG4BitReader(base: base, byteCount: end, position: (start + 4) * 8)
                switch code {
                case 0xB0:
                    profileLevel = reader.read(8)
                case 0x20...0x2F:
                    try parseVideoObjectLayer(&reader)
                case 0xB2:
                    parseUserData(base + start + 4, count: end - start - 4)
                case 0xB3:
                    parseGroupOfVOP(&reader)
                case 0xB6:
                    guard !headersOnly else { continue }
                    output += try decodeVOP(&reader)
                default:
                    continue
                }
            }
            return output
        }
    }

    /// Notes DivX "packed bitstream" streams (user data like "DivX503b1393p").
    private func parseUserData(_ data: UnsafePointer<UInt8>, count: Int) {
        guard count >= 5 else { return }
        let text = String(decoding: UnsafeBufferPointer(start: data, count: min(count, 64)), as: UTF8.self)
        guard text.hasPrefix("DivX") else { return }
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
        if trimmed.hasSuffix("p") { packedBitstream = true }
    }

    private func parseGroupOfVOP(_ reader: inout MPEG4BitReader) {
        let hours = reader.read(5), minutes = reader.read(6)
        reader.marker()
        let seconds = reader.read(6)
        let timeCode = hours * 3600 + minutes * 60 + seconds
        moduloBaseDecode = timeCode
        moduloBaseDisplay = timeCode
    }

    // MARK: VOL header

    private func parseVideoObjectLayer(_ reader: inout MPEG4BitReader) throws {
        var layer = MPEG4VideoObjectLayer()
        reader.skip(1)                                  // random_accessible_vol
        reader.skip(8)                                  // video_object_type_indication
        var verid = 1
        if reader.bit() {                               // is_object_layer_identifier
            verid = reader.read(4)
            reader.skip(3)
        }
        let aspect = reader.read(4)
        switch aspect {
        case 2: layer.pixelAspect = (12, 11)
        case 3: layer.pixelAspect = (10, 11)
        case 4: layer.pixelAspect = (16, 11)
        case 5: layer.pixelAspect = (40, 33)
        case 15:
            let w = reader.read(8), h = reader.read(8)
            if w > 0, h > 0 { layer.pixelAspect = (w, h) }
        default: break
        }
        if reader.bit() {                               // vol_control_parameters
            reader.skip(2)                              // chroma_format
            reader.skip(1)                              // low_delay
            if reader.bit() { reader.skip(79) }         // vbv_parameters
        }
        let shape = reader.read(2)
        guard shape == 0 else { throw MPEG4DecoderError.unsupported("arbitrary-shape video objects") }
        reader.marker()
        layer.timeResolution = max(reader.read(16), 1)
        reader.marker()
        var bits = 1
        while (1 << bits) < layer.timeResolution { bits += 1 }
        layer.timeIncrementBits = bits
        if reader.bit() { reader.skip(bits) }           // fixed_vop_rate, fixed_vop_time_increment
        reader.marker()
        layer.width = reader.read(13)
        reader.marker()
        layer.height = reader.read(13)
        reader.marker()
        guard layer.width > 0, layer.height > 0, layer.width <= 4096, layer.height <= 4096 else {
            throw MPEG4DecoderError.invalidData("picture size \(layer.width)x\(layer.height)")
        }
        layer.interlaced = reader.bit()
        layer.obmcDisabled = reader.bit()
        layer.spriteMode = verid == 1 ? reader.read(1) : reader.read(2)
        if layer.spriteMode == 1 || layer.spriteMode == 3 {
            throw MPEG4DecoderError.unsupported("static sprites")
        }
        if layer.spriteMode == 2 {
            layer.warpPoints = reader.read(6)
            layer.warpAccuracy = reader.read(2)
            if reader.bit() { throw MPEG4DecoderError.unsupported("sprite brightness change") }
            guard layer.warpPoints <= 3 else { throw MPEG4DecoderError.unsupported("GMC with \(layer.warpPoints) points") }
        }
        if reader.bit() {                               // not_8_bit
            let precision = reader.read(4), depth = reader.read(4)
            guard precision == 5, depth == 8 else { throw MPEG4DecoderError.unsupported("\(depth)-bit video") }
        }
        layer.mpegQuant = reader.bit()
        if layer.mpegQuant {
            if reader.bit() { layer.intraMatrix = readMatrix(&reader) }
            if reader.bit() { layer.interMatrix = readMatrix(&reader) }
        }
        if verid != 1 { layer.quarterSample = reader.bit() }
        if !reader.bit() {                              // complexity_estimation_disable
            layer.complexity = try readComplexityEstimation(&reader)
        }
        layer.resyncDisabled = reader.bit()
        layer.dataPartitioned = reader.bit()
        if layer.dataPartitioned { layer.reversibleVLC = reader.bit() }
        if verid != 1 {
            // Early version-2 encoders (OpenDivX) omit newpred_enable and
            // reduced_resolution_vop_enable; if reading them leaves no valid end of header but
            // skipping them does, they aren't there.
            var withoutVersion2Flags = reader
            let skippedFits = !withoutVersion2Flags.bit() && Self.endsHeader(withoutVersion2Flags)
            var withFlags = reader
            let newpred = withFlags.bit(), reduced = withFlags.bit(), scalable = withFlags.bit()
            if (newpred || reduced || scalable || !Self.endsHeader(withFlags)) && skippedFits {
                reader = withoutVersion2Flags
                reader.skip(-1)
            } else {
                if reader.bit() { throw MPEG4DecoderError.unsupported("NEWPRED") }
                if reader.bit() { throw MPEG4DecoderError.unsupported("reduced-resolution VOPs") }
            }
        }
        if reader.bit() { throw MPEG4DecoderError.unsupported("scalability") }
        if layer.dataPartitioned && layer.interlaced {
            throw MPEG4DecoderError.unsupported("interlaced data partitioning")
        }
        guard !reader.isExhausted else { throw MPEG4DecoderError.invalidData("truncated VOL header") }
        configure(layer)
    }

    /// Whether only next_start_code() stuffing ('0' then '1's to the byte boundary) remains.
    private static func endsHeader(_ reader: MPEG4BitReader) -> Bool {
        let stuffing = 8 - (reader.position & 7)
        guard reader.peek(stuffing) == (1 << (stuffing - 1)) - 1 else { return false }
        return reader.bitsLeft - stuffing < 8
    }

    /// Reads a downloaded quantiser matrix (zigzag order, a 0 repeats the last value).
    private func readMatrix(_ reader: inout MPEG4BitReader) -> [Int] {
        var matrix = [Int](repeating: 0, count: 64)
        var last = 16
        var index = 0
        while index < 64 {
            let value = reader.read(8)
            if value == 0 { break }
            matrix[zigzag[index]] = value
            last = value
            index += 1
        }
        while index < 64 {
            matrix[zigzag[index]] = last
            index += 1
        }
        return matrix
    }

    private func readComplexityEstimation(_ reader: inout MPEG4BitReader) throws -> MPEG4ComplexityEstimation {
        var c = MPEG4ComplexityEstimation()
        c.method = reader.read(2)
        guard c.method <= 1 else { throw MPEG4DecoderError.unsupported("complexity estimation method \(c.method)") }
        if !reader.bit() {
            for _ in 0..<6 where reader.bit() { c.shapeFields += 1 }
        }
        if !reader.bit() {
            c.intraBlocks = reader.bit(); c.interBlocks = reader.bit()
            c.inter4vBlocks = reader.bit(); c.notCodedBlocks = reader.bit()
        }
        reader.marker()
        if !reader.bit() {
            c.dctCoefs = reader.bit(); c.dctLines = reader.bit()
            c.vlcSymbols = reader.bit(); c.vlcBits = reader.bit()
        }
        if !reader.bit() {
            c.apm = reader.bit(); c.npm = reader.bit(); c.interpolateMCQ = reader.bit()
            c.forwBackMCQ = reader.bit(); c.halfpel2 = reader.bit(); c.halfpel4 = reader.bit()
        }
        reader.marker()
        if c.method == 1, !reader.bit() {
            c.sadct = reader.bit(); c.quarterpel = reader.bit()
        }
        return c
    }

    /// Adopts new stream parameters; a size change drops the reference pictures.
    private func configure(_ layer: MPEG4VideoObjectLayer) {
        let columns = (layer.width + 15) / 16, rows = (layer.height + 15) / 16
        if columns != mbColumns || rows != mbRows || layer.width != vol?.width || layer.height != vol?.height {
            // Show the held picture before dropping the references.
            if futureHeld, let future, vol != nil { pendingOutput.append(picture(from: future)) }
            futureHeld = false
        }
        if columns != mbColumns || rows != mbRows {
            mbColumns = columns
            mbRows = rows
            past = nil; future = nil; spare = nil; bidirectional = nil
            futureHeld = false
            waitingForIntra = true
            predictionMemory.deallocate()
            predictionMemoryCount = columns * rows * 6 * 15
            predictionMemory = .allocate(capacity: predictionMemoryCount)
            predictionMemory.initialize(repeating: 0, count: predictionMemoryCount)
            mbIntra = Array(repeating: false, count: columns * rows)
            timeIncrementOverride = nil
            mbQuant = Array(repeating: 1, count: columns * rows)
        }
        vol = layer
    }

    // MARK: VOP header

    private func decodeVOP(_ reader: inout MPEG4BitReader) throws -> [DecodedPicture] {
        guard let layer = vol else { throw MPEG4DecoderError.missingConfiguration }
        var header = MPEG4VOPHeader()
        guard let type = MPEG4VOPType(rawValue: reader.read(2)) else { throw MPEG4DecoderError.invalidData("VOP type") }
        header.type = type
        var moduloIncrement = 0
        while reader.bit() {
            moduloIncrement += 1
            guard moduloIncrement < 1 << 16, !reader.isExhausted else { throw MPEG4DecoderError.invalidData("time base") }
        }
        reader.marker()
        // Some files carry a VOL whose vop_time_increment_resolution doesn't match their VOPs;
        // if the marker after the increment is missing, find the width that fits.
        var incrementBits = timeIncrementOverride ?? layer.timeIncrementBits
        if !headerFits(reader, bits: incrementBits, type: type) {
            if let width = (1...16).first(where: { headerFits(reader, bits: $0, type: type) }) {
                incrementBits = width
                timeIncrementOverride = width
            }
        }
        let increment = reader.read(incrementBits)
        reader.marker()
        let seconds: Int
        if type == .bidirectional {
            seconds = moduloBaseDisplay + moduloIncrement
        } else {
            seconds = moduloBaseDecode + moduloIncrement
            moduloBaseDisplay = moduloBaseDecode
            moduloBaseDecode = seconds
        }
        header.time = seconds * layer.timeResolution + increment
        header.coded = reader.bit()
        guard header.coded else { return notCodedVOP(type) }

        if type == .sprite {
            guard layer.spriteMode == 2 else { throw MPEG4DecoderError.invalidData("S-VOP without GMC") }
        }
        if type == .predicted || type == .sprite { header.rounding = reader.read(1) }
        if let complexity = layer.complexity { skipComplexityFields(&reader, complexity, type: type) }
        header.intraDCThreshold = reader.read(3)
        if layer.interlaced {
            header.topFieldFirst = reader.bit()
            header.alternateScan = reader.bit()
        }
        if type == .sprite, layer.warpPoints > 0 {
            header.warp = try readWarp(&reader, layer: layer)
        } else if type == .sprite {
            header.warp = try MPEG4Warp(points: 0, accuracy: layer.warpAccuracy, du: [], dv: [],
                                        width: mbColumns * 16, height: mbRows * 16)
        }
        header.quant = reader.read(5)
        guard header.quant > 0 else { throw MPEG4DecoderError.invalidData("quantiser 0") }
        if type != .intra {
            header.fcodeForward = reader.read(3)
            guard header.fcodeForward > 0 else { throw MPEG4DecoderError.invalidData("fcode 0") }
        }
        if type == .bidirectional {
            header.fcodeBackward = reader.read(3)
            guard header.fcodeBackward > 0 else { throw MPEG4DecoderError.invalidData("fcode 0") }
        }
        guard !reader.isExhausted else { throw MPEG4DecoderError.invalidData("truncated VOP header") }
        vop = header
        return try decodePicture(&reader)
    }

    /// Whether a VOP header continues plausibly with a `bits`-wide vop_time_increment: a marker
    /// bit, and for coded VOPs an intra_dc_vlc_thr of 0 (what encoders use).
    private func headerFits(_ reader: MPEG4BitReader, bits: Int, type: MPEG4VOPType) -> Bool {
        var ahead = reader
        ahead.skip(bits)
        guard ahead.bit() else { return false }
        guard ahead.bit() else { return true }            // not coded
        if type == .predicted || type == .sprite { ahead.skip(1) }
        if vol?.complexity != nil { return true }
        return ahead.read(3) == 0 || bits == (vol?.timeIncrementBits ?? 0)
    }

    /// vop_coded = 0: nothing new to show. In ordinary streams an N-VOP in anchor position
    /// repeats the previous picture; DivX packed-bitstream placeholders show nothing.
    private func notCodedVOP(_ type: MPEG4VOPType) -> [DecodedPicture] {
        guard !packedBitstream, type != .bidirectional, futureHeld, let future, !waitingForIntra else { return [] }
        return [picture(from: future)]
    }

    private func skipComplexityFields(_ reader: inout MPEG4BitReader, _ c: MPEG4ComplexityEstimation, type: MPEG4VOPType) {
        let ipb = type != .sprite
        if ipb { reader.skip(8 * c.shapeFields) }
        if c.intraBlocks { reader.skip(8) }
        if c.notCodedBlocks { reader.skip(8) }
        if c.dctCoefs { reader.skip(8) }
        if c.dctLines { reader.skip(8) }
        if c.vlcSymbols { reader.skip(8) }
        if c.vlcBits { reader.skip(4) }
        if type != .intra {
            if c.interBlocks { reader.skip(8) }
            if c.inter4vBlocks { reader.skip(8) }
            if c.apm { reader.skip(8) }
            if c.npm { reader.skip(8) }
            if c.forwBackMCQ { reader.skip(8) }
            if c.halfpel2 { reader.skip(8) }
            if c.halfpel4 { reader.skip(8) }
        }
        if type == .bidirectional, c.interpolateMCQ { reader.skip(8) }
        if ipb, c.sadct { reader.skip(8) }
        if type != .intra, c.quarterpel { reader.skip(8) }
    }

    /// sprite_trajectory(): the warping-point deltas of a GMC S-VOP.
    private func readWarp(_ reader: inout MPEG4BitReader, layer: MPEG4VideoObjectLayer) throws -> MPEG4Warp {
        var du = [Int](), dv = [Int]()
        for _ in 0..<layer.warpPoints {
            var pair = [0, 0]
            for axis in 0..<2 {
                let length = try reader.decode(MPEG4Tables.warpLengthVLC)
                if length > 0 {
                    let value = reader.read(length)
                    pair[axis] = value >> (length - 1) == 1 ? value : value - (1 << length) + 1
                }
                reader.marker()
            }
            du.append(pair[0])
            dv.append(pair[1])
        }
        return try MPEG4Warp(points: layer.warpPoints, accuracy: layer.warpAccuracy, du: du, dv: dv,
                             width: mbColumns * 16, height: mbRows * 16)
    }

    // MARK: Picture management

    /// Decodes the VOP body into a new picture and returns what's ready for display.
    private func decodePicture(_ reader: inout MPEG4BitReader) throws -> [DecodedPicture] {
        unwrapTime()
        if vop.type == .bidirectional {
            guard !waitingForIntra, let past, let future else { return [] }
            // A B-VOP must lie between its anchors; otherwise one is missing (cut or damaged
            // stream) and its macroblocks can't even be parsed correctly.
            guard vop.time >= past.time, vop.time <= future.time else { return [] }
            let target = bidirectional ?? MPEG4Frame(mbColumns: mbColumns, mbRows: mbRows)
            bidirectional = target
            target.time = vop.time
            decodeBody(&reader, target: target, forward: past, backward: future)
            return [picture(from: target)]
        }
        if vop.type != .intra {
            guard !waitingForIntra, future != nil else { return [] }
        }
        // Recycle the oldest picture for the new anchor.
        let target = past ?? spare ?? MPEG4Frame(mbColumns: mbColumns, mbRows: mbRows)
        if spare === target { spare = nil }
        past = nil
        target.time = vop.time
        decodeBody(&reader, target: target, forward: future, backward: nil)
        target.extendEdges()
        var output: [DecodedPicture] = []
        if futureHeld, let future { output.append(picture(from: future)) }
        past = future
        future = target
        futureHeld = true
        waitingForIntra = false
        return output
    }

    /// Keeps VOP times increasing when an encoder forgets modulo_time_base (times then wrap
    /// within one second): anchors must follow the previous anchor, and B-VOPs lie between theirs.
    private func unwrapTime() {
        let second = vol?.timeResolution ?? 1
        if vop.type == .bidirectional {
            guard let past, let future else { return }
            let time = vop.time + timeOffset
            for candidate in [time, time - second, time + second] where candidate >= past.time && candidate <= future.time {
                vop.time = candidate
                return
            }
            vop.time = time
        } else {
            var time = vop.time + timeOffset
            if let future, time <= future.time {
                let behind = future.time - time
                timeOffset += (behind / second + 1) * second
                time = vop.time + timeOffset
            }
            vop.time = time
        }
    }

    /// Decodes the macroblocks of the current VOP, concealing whatever can't be decoded.
    private func decodeBody(_ reader: inout MPEG4BitReader, target: MPEG4Frame, forward: MPEG4Frame?, backward: MPEG4Frame?) {
        resetVOPState()
        var decoded = 0
        do {
            if vol?.shortHeader == true {
                try decodeShortHeaderMacroblocks(&reader, target: target, forward: forward, decoded: &decoded)
            } else if vop.type == .bidirectional {
                guard let forward, let backward else { return }
                try decodeBidirectionalMacroblocks(&reader, target: target, forward: forward, backward: backward,
                                                   decoded: &decoded)
            } else if vol?.dataPartitioned == true {
                try decodePartitionedMacroblocks(&reader, target: target, forward: forward, decoded: &decoded)
            } else {
                try decodeMacroblocks(&reader, target: target, forward: forward, decoded: &decoded)
            }
        } catch {
            lastConcealedError = error
        }
        if decoded < mbCount {
            conceal(from: decoded, target: target, reference: forward)
        }
    }

    private func resetVOPState() {
        quantiser = vop.quant
        packetStart = 0
        dcRestart = true
        for index in mbIntra.indices { mbIntra[index] = false }
        forwardPredictors = [.zero, .zero]
        backwardPredictors = [.zero, .zero]
    }

    /// Fills macroblocks from `first` on with the co-located reference samples.
    private func conceal(from first: Int, target: MPEG4Frame, reference: MPEG4Frame?) {
        guard first < mbCount else { return }
        concealedMacroblocks += mbCount - first
        for mb in first..<mbCount {
            let mbx = mb % mbColumns, mby = mb / mbColumns
            if let reference {
                copyBlock(from: reference.luma, to: target.luma, x: mbx * 16, y: mby * 16, size: 16)
                copyBlock(from: reference.cb, to: target.cb, x: mbx * 8, y: mby * 8, size: 8)
                copyBlock(from: reference.cr, to: target.cr, x: mbx * 8, y: mby * 8, size: 8)
            }
            if vop.type != .bidirectional {
                target.modes[mb] = MPEG4MacroblockMode(intra: reference == nil, notCoded: reference != nil)
                for block in 0..<4 { target.vectors[mb * 4 + block] = .zero }
            }
        }
    }

    private func copyBlock(from source: MPEG4Plane, to target: MPEG4Plane, x: Int, y: Int, size: Int) {
        for row in 0..<size {
            (target.origin + (y + row) * target.stride + x).update(from: source.origin + (y + row) * source.stride + x, count: size)
        }
    }

    /// Copies the visible part of a frame into a picture for display.
    private func picture(from frame: MPEG4Frame) -> DecodedPicture {
        let w = width, h = height, cw = (w + 1) / 2, ch = (h + 1) / 2
        var y = [UInt8](repeating: 0, count: w * h)
        var u = [UInt8](repeating: 0, count: cw * ch)
        var v = [UInt8](repeating: 0, count: cw * ch)
        y.withUnsafeMutableBufferPointer { out in
            guard let base = out.baseAddress else { return }
            for row in 0..<min(h, frame.luma.height) {
                (base + row * w).update(from: frame.luma.origin + row * frame.luma.stride, count: min(w, frame.luma.width))
            }
        }
        for (plane, target) in [(frame.cb, 0), (frame.cr, 1)] {
            let copyRows = { (out: inout UnsafeMutableBufferPointer<UInt8>) in
                guard let base = out.baseAddress else { return }
                for row in 0..<min(ch, plane.height) {
                    (base + row * cw).update(from: plane.origin + row * plane.stride, count: min(cw, plane.width))
                }
            }
            if target == 0 { u.withUnsafeMutableBufferPointer(copyRows) } else { v.withUnsafeMutableBufferPointer(copyRows) }
        }
        return DecodedPicture(width: w, height: h, y: y, u: u, v: v, yStride: w, chromaStride: cw)
    }

    // MARK: Video packets

    /// Length of the resync marker for the current VOP.
    private var resyncMarkerLength: Int {
        switch vop.type {
        case .intra: 17
        case .predicted, .sprite: 16 + vop.fcodeForward
        case .bidirectional: 16 + max(vop.fcodeForward, vop.fcodeBackward)
        }
    }

    /// True if stuffing to the next byte boundary is followed by a resync marker.
    private func atResyncMarker(_ reader: MPEG4BitReader) -> Bool {
        let stuffing = 8 - (reader.position & 7)
        guard reader.peek(stuffing) == (1 << (stuffing - 1)) - 1 else { return false }
        var ahead = reader
        ahead.skip(stuffing)
        return ahead.peek(resyncMarkerLength) == 1
    }

    /// Skips macroblock stuffing codes that may precede a resync marker.
    private func skipStuffing(_ reader: inout MPEG4BitReader) {
        if vop.type == .intra {
            while reader.peek(9) == 1, !reader.isExhausted { reader.skip(9) }
        } else if vop.type != .bidirectional {
            while reader.peek(10) == 1, !reader.isExhausted { reader.skip(10) }
        }
    }

    /// Reads a video packet header and returns the number of its first macroblock.
    private func readVideoPacketHeader(_ reader: inout MPEG4BitReader, current: Int) throws -> Int {
        let stuffing = 8 - (reader.position & 7)
        reader.skip(stuffing + resyncMarkerLength)
        var numberBits = 0
        while (1 << numberBits) < mbCount { numberBits += 1 }
        let number = mbCount > 1 ? reader.read(numberBits) : 0
        let quant = reader.read(5)
        guard quant > 0 else { throw MPEG4DecoderError.invalidData("packet quantiser") }
        if reader.bit() {                               // header_extension_code
            var guardCount = 0
            while reader.bit() {
                guardCount += 1
                guard guardCount < 1 << 16, !reader.isExhausted else { throw MPEG4DecoderError.invalidData("packet header") }
            }
            reader.marker()
            reader.skip(vol?.timeIncrementBits ?? 1)
            reader.marker()
            reader.skip(2)                              // vop_coding_type
            reader.skip(3)                              // intra_dc_vlc_thr
            if vop.type == .sprite, let layer = vol, layer.warpPoints > 0 { _ = try readWarp(&reader, layer: layer) }
            if vop.type != .intra { reader.skip(3) }
            if vop.type == .bidirectional { reader.skip(3) }
        }
        guard number >= current, number < mbCount, !reader.isExhausted else {
            throw MPEG4DecoderError.invalidData("video packet macroblock number")
        }
        quantiser = quant
        packetStart = number
        dcRestart = true
        forwardPredictors = [.zero, .zero]
        backwardPredictors = [.zero, .zero]
        return number
    }

    // MARK: I-, P- and S-VOP macroblocks

    private func decodeMacroblocks(_ reader: inout MPEG4BitReader, target: MPEG4Frame, forward: MPEG4Frame?,
                                   decoded: inout Int) throws {
        var mb = 0
        while mb < mbCount {
            skipStuffing(&reader)
            if atResyncMarker(reader) {
                let next = try readVideoPacketHeader(&reader, current: mb)
                if next > mb {
                    conceal(from: mb, upTo: next, target: target, reference: forward)
                    mb = next
                }
            }
            if vop.type == .intra {
                try decodeIntraMacroblockHeader(&reader, mb: mb, target: target)
            } else {
                guard let forward else { throw MPEG4DecoderError.invalidData("missing reference") }
                try decodeInterMacroblock(&reader, mb: mb, target: target, reference: forward)
            }
            guard !reader.isExhausted else { throw MPEG4DecoderError.invalidData("truncated VOP") }
            mb += 1
            decoded = mb
        }
    }

    /// Conceals a range of macroblocks skipped over by a video packet header.
    private func conceal(from first: Int, upTo end: Int, target: MPEG4Frame, reference: MPEG4Frame?) {
        let saved = mbCount
        guard first < end, end <= saved else { return }
        concealedMacroblocks += end - first
        for mb in first..<end {
            let mbx = mb % mbColumns, mby = mb / mbColumns
            if let reference {
                copyBlock(from: reference.luma, to: target.luma, x: mbx * 16, y: mby * 16, size: 16)
                copyBlock(from: reference.cb, to: target.cb, x: mbx * 8, y: mby * 8, size: 8)
                copyBlock(from: reference.cr, to: target.cr, x: mbx * 8, y: mby * 8, size: 8)
            }
            if vop.type != .bidirectional {
                target.modes[mb] = MPEG4MacroblockMode(intra: reference == nil, notCoded: reference != nil)
                for block in 0..<4 { target.vectors[mb * 4 + block] = .zero }
            }
        }
    }

    private static let dquantSteps = [-1, -2, 1, 2]

    private func applyDquant(_ reader: inout MPEG4BitReader) {
        quantiser = min(max(quantiser + Self.dquantSteps[reader.read(2)], 1), 31)
    }

    /// intra_dc_vlc_thr: whether intra DC is coded with the AC table, judged from the running
    /// quantiser (the previous macroblock's, except at the start of a VOP or packet).
    private func dcCodedAsAC(previousQuant: Int) -> Bool {
        let q = dcRestart ? quantiser : previousQuant
        dcRestart = false
        switch vop.intraDCThreshold {
        case 0: return false
        case 7: return true
        default: return q >= 2 * vop.intraDCThreshold + 11
        }
    }

    private func decodeIntraMacroblockHeader(_ reader: inout MPEG4BitReader, mb: Int, target: MPEG4Frame) throws {
        var mcbpc: Int
        repeat {
            mcbpc = try reader.decode(mcbpcIntraVLC)
        } while mcbpc == 8 && !reader.isExhausted
        guard mcbpc < 8 else { throw MPEG4DecoderError.invalidData("MCBPC") }
        let previousQuant = quantiser
        let acPrediction = reader.bit()
        let cbpy = try reader.decode(cbpyVLC)
        if mcbpc > 3 { applyDquant(&reader) }
        let fieldDCT = vol?.interlaced == true ? reader.bit() : false
        let dcAsAC = dcCodedAsAC(previousQuant: previousQuant)
        let cbp = cbpy << 2 | (mcbpc & 3)
        try decodeIntraBlocks(&reader, mb: mb, cbp: cbp, acPrediction: acPrediction, dcAsAC: dcAsAC,
                              fieldDCT: fieldDCT, partitionedDC: nil, target: target)
        target.modes[mb] = MPEG4MacroblockMode(intra: true)
        for block in 0..<4 { target.vectors[mb * 4 + block] = .zero }
    }

    /// One macroblock of a P- or S-VOP (not data-partitioned).
    private func decodeInterMacroblock(_ reader: inout MPEG4BitReader, mb: Int, target: MPEG4Frame,
                                       reference: MPEG4Frame) throws {
        let gmcVOP = vop.type == .sprite
        var notCoded = false
        var mcbpc = 0
        repeat {
            notCoded = reader.bit()
            if !notCoded { mcbpc = try reader.decode(mcbpcInterVLC) }
        } while !notCoded && mcbpc == 20 && !reader.isExhausted
        if notCoded {
            try reconstructNotCoded(mb: mb, target: target, reference: reference, gmc: gmcVOP)
            return
        }
        guard mcbpc < 20 else { throw MPEG4DecoderError.invalidData("MCBPC") }
        let kind = mcbpc / 4
        let intra = kind >= 3
        var mode = MPEG4MacroblockMode(intra: intra, fourMV: kind == 2)
        if gmcVOP, kind < 2 { mode.gmc = reader.bit() }
        let previousQuant = quantiser
        let acPrediction = intra ? reader.bit() : false
        var cbpy = try reader.decode(cbpyVLC)
        if !intra { cbpy = 15 - cbpy }
        if kind == 1 || kind == 4 { applyDquant(&reader) }
        let cbp = cbpy << 2 | (mcbpc & 3)
        var fieldDCT = false
        if vol?.interlaced == true {
            if intra || cbp != 0 { fieldDCT = reader.bit() }
            if !intra, kind != 2, !mode.gmc {
                mode.fieldMotion = reader.bit()
                if mode.fieldMotion {
                    mode.topFromBottom = reader.bit()
                    mode.bottomFromBottom = reader.bit()
                }
            }
        }
        let dcAsAC = dcCodedAsAC(previousQuant: previousQuant)
        if intra {
            try decodeIntraBlocks(&reader, mb: mb, cbp: cbp, acPrediction: acPrediction, dcAsAC: dcAsAC,
                                  fieldDCT: fieldDCT, partitionedDC: nil, target: target)
            target.modes[mb] = mode
            for block in 0..<4 { target.vectors[mb * 4 + block] = .zero }
            return
        }
        try decodeMotion(&reader, mb: mb, mode: mode, target: target)
        target.modes[mb] = mode
        let coded = try decodeResidualBlocks(&reader, cbp: cbp, rvlc: false)
        reconstructInter(mb: mb, mode: mode, target: target, reference: reference, coded: coded, fieldDCT: fieldDCT)
    }

    /// A not_coded macroblock: a copy of the reference, or the global-motion prediction in S-VOPs.
    private func reconstructNotCoded(mb: Int, target: MPEG4Frame, reference: MPEG4Frame, gmc: Bool) throws {
        let mode = MPEG4MacroblockMode(notCoded: true, gmc: gmc)
        target.modes[mb] = mode
        let vector = gmc ? globalMotionVector(mb: mb) : .zero
        for block in 0..<4 { target.vectors[mb * 4 + block] = vector }
        mbIntra[mb] = false
        if gmc {
            reconstructInter(mb: mb, mode: mode, target: target, reference: reference, coded: 0, fieldDCT: false)
        } else {
            let mbx = mb % mbColumns, mby = mb / mbColumns
            copyBlock(from: reference.luma, to: target.luma, x: mbx * 16, y: mby * 16, size: 16)
            copyBlock(from: reference.cb, to: target.cb, x: mbx * 8, y: mby * 8, size: 8)
            copyBlock(from: reference.cr, to: target.cr, x: mbx * 8, y: mby * 8, size: 8)
        }
    }

    // MARK: Motion vectors

    /// One differential motion vector component (motion_code and motion_residual).
    @inline(__always)
    private func readMotionComponent(_ reader: inout MPEG4BitReader, fcode: Int) throws -> Int {
        let code = try reader.decode(motionVLC) - 32
        guard code != 0, fcode > 1 else { return code }
        let residual = reader.read(fcode - 1)
        let magnitude = (abs(code) - 1) << (fcode - 1) + residual + 1
        return code < 0 ? -magnitude : magnitude
    }

    @inline(__always)
    private func wrap(_ value: Int, fcode: Int) -> Int {
        let range = 16 << fcode
        if value < -range { return value + 2 * range }
        if value >= range { return value - 2 * range }
        return value
    }

    @inline(__always)
    private func median(_ a: Int, _ b: Int, _ c: Int) -> Int {
        max(min(a, b), min(max(a, b), c))
    }

    /// Whether neighbouring macroblock (mbx, mby) can be used for prediction (inside the
    /// picture and in the current video packet).
    @inline(__always)
    private func available(_ mbx: Int, _ mby: Int) -> Bool {
        mbx >= 0 && mby >= 0 && mbx < mbColumns && mby * mbColumns + mbx >= packetStart
    }

    /// The motion vector predictor for `block` (0-3), or for the whole macroblock (`block` = -1).
    private func vectorPredictor(mb: Int, block: Int, frame: MPEG4Frame, shortHeader: Bool = false,
                                 gobTop: Bool = false) -> MPEG4Vector {
        let mbx = mb % mbColumns, mby = mb / mbColumns
        if shortHeader {
            // H.263: outside the picture/GOB the left candidate is zero; above ones repeat it.
            let left = mbx > 0 ? frame.vectors[(mb - 1) * 4 + 1] : .zero
            if mby == 0 || gobTop { return left }
            let above = frame.vectors[(mb - mbColumns) * 4 + 2]
            let aboveRight = mbx + 1 < mbColumns ? frame.vectors[(mb - mbColumns + 1) * 4 + 2] : .zero
            return MPEG4Vector(x: median(left.x, above.x, aboveRight.x), y: median(left.y, above.y, aboveRight.y))
        }
        // Candidates (macroblock offset, block): left, above, above-right.
        let candidates = Self.vectorCandidates[max(block, 0)]
        var values = (MPEG4Vector.zero, MPEG4Vector.zero, MPEG4Vector.zero)
        var valid = 0
        var lastValid = MPEG4Vector.zero
        for index in 0..<3 {
            let candidate = candidates[index]
            let nx = mbx + candidate.dx, ny = mby + candidate.dy
            guard (candidate.dx == 0 && candidate.dy == 0) || available(nx, ny) else { continue }
            let vector = frame.vectors[(ny * mbColumns + nx) * 4 + candidate.block]
            switch index {
            case 0: values.0 = vector
            case 1: values.1 = vector
            default: values.2 = vector
            }
            valid += 1
            lastValid = vector
        }
        if valid == 1 { return lastValid }
        return MPEG4Vector(x: median(values.0.x, values.1.x, values.2.x),
                           y: median(values.0.y, values.1.y, values.2.y))
    }

    /// Motion vector predictor candidates per block (the macroblock vector uses block 0's).
    private static let vectorCandidates: [[(dx: Int, dy: Int, block: Int)]] = [
        [(-1, 0, 1), (0, -1, 2), (1, -1, 2)],
        [(0, 0, 0), (0, -1, 3), (1, -1, 2)],
        [(-1, 0, 3), (0, 0, 0), (0, 0, 1)],
        [(0, 0, 2), (0, 0, 0), (0, 0, 1)],
    ]

    /// Decodes the motion vectors of an inter macroblock in a P/S-VOP into `target`.
    private func decodeMotion(_ reader: inout MPEG4BitReader, mb: Int, mode: MPEG4MacroblockMode, target: MPEG4Frame,
                              shortHeader: Bool = false, gobTop: Bool = false) throws {
        let fcode = vop.fcodeForward
        if mode.gmc {
            let vector = globalMotionVector(mb: mb)
            for block in 0..<4 { target.vectors[mb * 4 + block] = vector }
            return
        }
        if mode.fourMV {
            for block in 0..<4 {
                let predictor = vectorPredictor(mb: mb, block: block, frame: target)
                let dx = try readMotionComponent(&reader, fcode: fcode)
                let dy = try readMotionComponent(&reader, fcode: fcode)
                target.vectors[mb * 4 + block] = MPEG4Vector(x: wrap(predictor.x + dx, fcode: fcode),
                                                             y: wrap(predictor.y + dy, fcode: fcode))
            }
            return
        }
        let predictor = vectorPredictor(mb: mb, block: -1, frame: target, shortHeader: shortHeader, gobTop: gobTop)
        if mode.fieldMotion {
            var fields = [MPEG4Vector]()
            for _ in 0..<2 {
                let dx = try readMotionComponent(&reader, fcode: fcode)
                let dy = try readMotionComponent(&reader, fcode: fcode)
                fields.append(MPEG4Vector(x: wrap(predictor.x + dx, fcode: fcode),
                                          y: 2 * wrap(predictor.y / 2 + dy, fcode: fcode)))
            }
            target.fieldVectors[mb * 2] = fields[0]
            target.fieldVectors[mb * 2 + 1] = fields[1]
            // Neighbours predict from the average of the two field vectors.
            let sx = fields[0].x + fields[1].x, sy = fields[0].y + fields[1].y
            let average = MPEG4Vector(x: sx & 3 != 0 ? (sx >> 1) | 1 : sx >> 1,
                                      y: sy & 3 != 0 ? (sy >> 1) | 1 : sy >> 1)
            for block in 0..<4 { target.vectors[mb * 4 + block] = average }
            return
        }
        let dx = try readMotionComponent(&reader, fcode: fcode)
        let dy = try readMotionComponent(&reader, fcode: fcode)
        let vector = MPEG4Vector(x: wrap(predictor.x + dx, fcode: fcode), y: wrap(predictor.y + dy, fcode: fcode))
        for block in 0..<4 { target.vectors[mb * 4 + block] = vector }
    }

    /// The vector a GMC macroblock contributes to motion vector prediction: the rounded mean
    /// displacement of its 256 luma samples, clipped to the f_code range.
    private func globalMotionVector(mb: Int) -> MPEG4Vector {
        guard let warp = vop.warp, warp.points > 0 else { return .zero }
        let quarter = vol?.quarterSample == true
        // Clipped to the f_code range (the reference software halves it in quarter-sample
        // mode, which mispredicts XviD's GMC+qpel streams).
        let range = 16 << vop.fcodeForward
        func clip(_ v: Int) -> Int { min(max(v, -range), range - 1) }
        if warp.points == 1 {
            let scale = quarter ? 2 : 1
            return MPEG4Vector(x: clip(warp.translation.x * scale), y: clip(warp.translation.y * scale))
        }
        let mbx = (mb % mbColumns) * 16, mby = (mb / mbColumns) * 16
        let margin = 16 << warp.shift
        var sumX = 0, sumY = 0
        for j in 0..<16 {
            let y = mby + j
            for i in 0..<16 {
                let x = mbx + i
                let rx = ((warp.cx + warp.ax * x + warp.bx * y) >> warp.lumaShift) - margin
                let ry = ((warp.cy + warp.ay * x + warp.by * y) >> warp.lumaShift) - margin
                sumX += rx - (x << warp.shift)
                sumY += ry - (y << warp.shift)
            }
        }
        let shift = (quarter ? 6 : 7) + warp.shift
        let half = 1 << (shift - 1)
        let vx = (sumX + (sumX < 0 ? half - 1 : half)) >> shift
        let vy = (sumY + (sumY < 0 ? half - 1 : half)) >> shift
        return MPEG4Vector(x: clip(vx), y: clip(vy))
    }

    // MARK: Data partitioning

    private func decodePartitionedMacroblocks(_ reader: inout MPEG4BitReader, target: MPEG4Frame,
                                              forward: MPEG4Frame?, decoded: inout Int) throws {
        let intraVOP = vop.type == .intra
        let rvlc = vol?.reversibleVLC == true
        var mb = 0
        /// A macroblock whose first two partitions have been read.
        struct Pending {
            var mb: Int
            var mcbpc: Int
            var mode: MPEG4MacroblockMode
            var cbp = 0
            var acPrediction = false
            var dcAsAC = false
            var dc = [Int](repeating: 0, count: 6)
        }
        while mb < mbCount {
            if atResyncMarker(reader) {
                let next = try readVideoPacketHeader(&reader, current: mb)
                if next > mb {
                    conceal(from: mb, upTo: next, target: target, reference: forward)
                    mb = next
                    decoded = mb
                }
            }
            var pending: [Pending] = []
            // First partition: modes, DC (I) or motion (P/S), up to the DC / motion marker.
            if intraVOP {
                while reader.peek(19) != 0x6B001 {
                    guard !reader.isExhausted else { throw MPEG4DecoderError.invalidData("DC partition") }
                    let mcbpc = try reader.decode(mcbpcIntraVLC)
                    if mcbpc == 8 { continue }
                    guard mb + pending.count < mbCount else { throw MPEG4DecoderError.invalidData("DC partition overrun") }
                    var item = Pending(mb: mb + pending.count, mcbpc: mcbpc, mode: MPEG4MacroblockMode(intra: true))
                    let previousQuant = quantiser
                    if mcbpc > 3 { applyDquant(&reader) }
                    mbQuant[item.mb] = quantiser
                    item.dcAsAC = dcCodedAsAC(previousQuant: previousQuant)
                    if !item.dcAsAC {
                        for block in 0..<6 { item.dc[block] = try readIntraDC(&reader, luma: block < 4) }
                    }
                    pending.append(item)
                }
                reader.skip(19)
                for index in pending.indices {
                    pending[index].acPrediction = reader.bit()
                    let cbpy = try reader.decode(cbpyVLC)
                    pending[index].cbp = cbpy << 2 | (pending[index].mcbpc & 3)
                }
            } else {
                guard forward != nil else { throw MPEG4DecoderError.invalidData("missing reference") }
                while reader.peek(17) != 0x1F001 {
                    guard !reader.isExhausted else { throw MPEG4DecoderError.invalidData("motion partition") }
                    let current = mb + pending.count
                    let notCoded = reader.bit()
                    var mcbpc = 0
                    var mode = MPEG4MacroblockMode()
                    if notCoded {
                        mode.notCoded = true
                        mode.gmc = vop.type == .sprite
                    } else {
                        mcbpc = try reader.decode(mcbpcInterVLC)
                        if mcbpc == 20 { continue }
                        mode.intra = mcbpc / 4 >= 3
                        mode.fourMV = mcbpc / 4 == 2
                        if vop.type == .sprite, mcbpc / 4 < 2 { mode.gmc = reader.bit() }
                    }
                    guard current < mbCount else { throw MPEG4DecoderError.invalidData("motion partition overrun") }
                    target.modes[current] = mode
                    if mode.intra {
                        for block in 0..<4 { target.vectors[current * 4 + block] = .zero }
                    } else if mode.notCoded {
                        let vector = mode.gmc ? globalMotionVector(mb: current) : .zero
                        for block in 0..<4 { target.vectors[current * 4 + block] = vector }
                    } else {
                        try decodeMotion(&reader, mb: current, mode: mode, target: target)
                    }
                    pending.append(Pending(mb: current, mcbpc: mcbpc, mode: mode))
                }
                reader.skip(17)
                for index in pending.indices {
                    var item = pending[index]
                    guard !item.mode.notCoded else { continue }
                    let previousQuant = quantiser
                    if item.mode.intra {
                        item.acPrediction = reader.bit()
                        item.cbp = try reader.decode(cbpyVLC) << 2 | (item.mcbpc & 3)
                    } else {
                        item.cbp = (15 - (try reader.decode(cbpyVLC))) << 2 | (item.mcbpc & 3)
                    }
                    let kind = item.mcbpc / 4
                    if kind == 1 || kind == 4 { applyDquant(&reader) }
                    mbQuant[item.mb] = quantiser
                    item.dcAsAC = dcCodedAsAC(previousQuant: previousQuant)
                    if item.mode.intra, !item.dcAsAC {
                        for block in 0..<6 { item.dc[block] = try readIntraDC(&reader, luma: block < 4) }
                    }
                    pending[index] = item
                }
            }
            // Third partition: texture.
            for item in pending {
                if item.mode.intra {
                    quantiser = mbQuant[item.mb]
                    try decodeIntraBlocks(&reader, mb: item.mb, cbp: item.cbp, acPrediction: item.acPrediction,
                                          dcAsAC: item.dcAsAC, fieldDCT: false,
                                          partitionedDC: item.dcAsAC ? nil : item.dc, target: target, rvlc: rvlc)
                } else if let forward {
                    mbIntra[item.mb] = false
                    if item.mode.notCoded {
                        try reconstructNotCoded(mb: item.mb, target: target, reference: forward, gmc: item.mode.gmc)
                    } else {
                        quantiser = mbQuant[item.mb]
                        let coded = try decodeResidualBlocks(&reader, cbp: item.cbp, rvlc: rvlc)
                        reconstructInter(mb: item.mb, mode: item.mode, target: target, reference: forward,
                                         coded: coded, fieldDCT: false)
                    }
                }
                guard !reader.isExhausted else { throw MPEG4DecoderError.invalidData("truncated VOP") }
                decoded = item.mb + 1
            }
            mb += pending.count
            if pending.isEmpty { break }
        }
    }

    // MARK: B-VOP macroblocks

    private enum BidirectionalMode: Int {
        case direct = 0, interpolate, backward, forward
    }

    private func decodeBidirectionalMacroblocks(_ reader: inout MPEG4BitReader, target: MPEG4Frame, forward: MPEG4Frame,
                                                backward: MPEG4Frame, decoded: inout Int) throws {
        let fcodeF = vop.fcodeForward, fcodeB = vop.fcodeBackward
        let interlaced = vol?.interlaced == true
        let quarter = vol?.quarterSample == true
        var mb = 0
        while mb < mbCount {
            let mbx = mb % mbColumns
            if mbx == 0 {
                forwardPredictors = [.zero, .zero]
                backwardPredictors = [.zero, .zero]
            }
            let colocated = backward.modes[mb]
            if colocated.notCoded && !colocated.gmc {
                // Skipped in the future anchor: a plain copy of the past anchor.
                let mby = mb / mbColumns
                copyBlock(from: forward.luma, to: target.luma, x: mbx * 16, y: mby * 16, size: 16)
                copyBlock(from: forward.cb, to: target.cb, x: mbx * 8, y: mby * 8, size: 8)
                copyBlock(from: forward.cr, to: target.cr, x: mbx * 8, y: mby * 8, size: 8)
                mb += 1
                decoded = mb
                continue
            }
            if atResyncMarker(reader) {
                let next = try readVideoPacketHeader(&reader, current: mb)
                if next > mb {
                    conceal(from: mb, upTo: next, target: target, reference: forward)
                    mb = next
                    decoded = mb
                    continue
                }
            }
            var kind = BidirectionalMode.direct
            var cbp = 0
            var skipped = false
            if reader.bit() {
                skipped = true
            } else {
                let hasCBP = !reader.bit()
                guard let parsed = BidirectionalMode(rawValue: try reader.decode(MPEG4Tables.bModeVLC)) else {
                    throw MPEG4DecoderError.invalidData("B mb_type")
                }
                kind = parsed
                if hasCBP { cbp = reader.read(6) }
                if hasCBP, kind != .direct {
                    if reader.bit() { quantiser = min(max(quantiser + (reader.bit() ? 2 : -2), 1), 31) }
                }
            }
            var fieldDCT = false
            var field = false
            var forwardSelect = (top: false, bottom: false), backwardSelect = (top: false, bottom: false)
            if interlaced {
                if cbp != 0 { fieldDCT = reader.bit() }
                if kind != .direct {
                    field = reader.bit()
                    if field {
                        if kind != .backward { forwardSelect = (reader.bit(), reader.bit()) }
                        if kind != .forward { backwardSelect = (reader.bit(), reader.bit()) }
                    }
                }
            }
            // Motion vectors.
            var forwardVectors: [MPEG4Vector] = []
            var backwardVectors: [MPEG4Vector] = []
            func readVectors(_ predictors: inout [MPEG4Vector], fcode: Int) throws -> [MPEG4Vector] {
                if field {
                    var result: [MPEG4Vector] = []
                    for f in 0..<2 {
                        let dx = try readMotionComponent(&reader, fcode: fcode)
                        let dy = try readMotionComponent(&reader, fcode: fcode)
                        let v = MPEG4Vector(x: wrap(predictors[f].x + dx, fcode: fcode),
                                            y: 2 * wrap(predictors[f].y / 2 + dy, fcode: fcode))
                        predictors[f] = v
                        result.append(v)
                    }
                    return result
                }
                let dx = try readMotionComponent(&reader, fcode: fcode)
                let dy = try readMotionComponent(&reader, fcode: fcode)
                let v = MPEG4Vector(x: wrap(predictors[0].x + dx, fcode: fcode), y: wrap(predictors[0].y + dy, fcode: fcode))
                predictors = [v, v]
                return [v]
            }
            var delta = MPEG4Vector.zero
            switch kind {
            case .forward:
                forwardVectors = try readVectors(&forwardPredictors, fcode: fcodeF)
            case .backward:
                backwardVectors = try readVectors(&backwardPredictors, fcode: fcodeB)
            case .interpolate:
                forwardVectors = try readVectors(&forwardPredictors, fcode: fcodeF)
                backwardVectors = try readVectors(&backwardPredictors, fcode: fcodeB)
            case .direct:
                if !skipped {
                    delta.x = try reader.decode(motionVLC) - 32
                    delta.y = try reader.decode(motionVLC) - 32
                }
            }
            let coded = cbp != 0 ? try decodeResidualBlocks(&reader, cbp: cbp, rvlc: false) : 0
            // Prediction.
            switch kind {
            case .forward:
                predictOneDirection(mb: mb, vectors: forwardVectors, field: field, select: forwardSelect,
                                    reference: forward, y: predictionY, u: predictionU, v: predictionV)
            case .backward:
                predictOneDirection(mb: mb, vectors: backwardVectors, field: field, select: backwardSelect,
                                    reference: backward, y: predictionY, u: predictionU, v: predictionV)
            case .interpolate:
                predictOneDirection(mb: mb, vectors: forwardVectors, field: field, select: forwardSelect,
                                    reference: forward, y: predictionY, u: predictionU, v: predictionV)
                predictOneDirection(mb: mb, vectors: backwardVectors, field: field, select: backwardSelect,
                                    reference: backward, y: backwardY, u: backwardU, v: backwardV)
                averagePredictions()
            case .direct:
                predictDirect(mb: mb, delta: delta, forward: forward, backward: backward, quarter: quarter)
                averagePredictions()
            }
            storeMacroblock(mb: mb, target: target, coded: coded, fieldDCT: fieldDCT)
            guard !reader.isExhausted else { throw MPEG4DecoderError.invalidData("truncated VOP") }
            mb += 1
            decoded = mb
        }
    }

    /// Averages the forward (prediction) and backward buffers into the prediction buffers.
    private func averagePredictions() {
        for i in 0..<256 { predictionY[i] = UInt8((Int(predictionY[i]) + Int(backwardY[i]) + 1) >> 1) }
        for i in 0..<64 {
            predictionU[i] = UInt8((Int(predictionU[i]) + Int(backwardU[i]) + 1) >> 1)
            predictionV[i] = UInt8((Int(predictionV[i]) + Int(backwardV[i]) + 1) >> 1)
        }
    }

    /// Direct mode: vectors scaled from the co-located macroblock of the future anchor.
    private func predictDirect(mb: Int, delta: MPEG4Vector, forward: MPEG4Frame, backward: MPEG4Frame, quarter: Bool) {
        let colocated = backward.modes[mb]
        let trd = backward.time - forward.time
        let trb = vop.time - forward.time
        if colocated.fieldMotion, vol?.interlaced == true {
            predictFieldDirect(mb: mb, delta: delta, colocated: colocated, forward: forward, backward: backward,
                               trb: trb, trd: trd, quarter: quarter)
            return
        }
        let mbx = mb % mbColumns, mby = mb / mbColumns
        var forwardVectors = [MPEG4Vector](), backwardVectors = [MPEG4Vector]()
        for block in 0..<4 {
            let reference = colocated.intra ? .zero : backward.vectors[mb * 4 + block]
            var f = MPEG4Vector(), b = MPEG4Vector()
            if trd != 0 {
                f.x = reference.x * trb / trd + delta.x
                f.y = reference.y * trb / trd + delta.y
                b.x = delta.x != 0 ? f.x - reference.x : reference.x * (trb - trd) / trd
                b.y = delta.y != 0 ? f.y - reference.y : reference.y * (trb - trd) / trd
            } else {
                f = delta
                b = MPEG4Vector(x: delta.x != 0 ? f.x - reference.x : 0, y: delta.y != 0 ? f.y - reference.y : 0)
            }
            forwardVectors.append(f)
            backwardVectors.append(b)
        }
        predictBlocks(mbx: mbx, mby: mby, vectors: forwardVectors, reference: forward, y: predictionY,
                      u: predictionU, v: predictionV, rounding: 0)
        predictBlocks(mbx: mbx, mby: mby, vectors: backwardVectors, reference: backward, y: backwardY,
                      u: backwardU, v: backwardV, rounding: 0)
    }

    /// Interlaced direct mode for a field-predicted co-located macroblock.
    private func predictFieldDirect(mb: Int, delta: MPEG4Vector, colocated: MPEG4MacroblockMode, forward: MPEG4Frame,
                                    backward: MPEG4Frame, trb: Int, trd: Int, quarter: Bool) {
        let offsetTop = [0, 0, 1, 1, 0, 0, -1, -1]
        let offsetBottom = [-1, 0, -1, 0, 1, 0, 1, 0]
        let code = (vop.topFieldFirst ? 4 : 0) | (colocated.topFromBottom ? 2 : 0) | (colocated.bottomFromBottom ? 1 : 0)
        let mbx = mb % mbColumns, mby = mb / mbColumns
        for f in 0..<2 {
            let offset = f == 0 ? offsetTop[code] : offsetBottom[code]
            let fieldTRD = 2 * trd + offset, fieldTRB = 2 * trb + offset
            let reference = backward.fieldVectors[mb * 2 + f]
            var fv = MPEG4Vector(), bv = MPEG4Vector()
            if fieldTRD != 0 {
                fv = MPEG4Vector(x: reference.x * fieldTRB / fieldTRD + delta.x, y: reference.y * fieldTRB / fieldTRD + delta.y)
                bv.x = delta.x != 0 ? fv.x - reference.x : reference.x * (fieldTRB - fieldTRD) / fieldTRD
                bv.y = delta.y != 0 ? fv.y - reference.y : reference.y * (fieldTRB - fieldTRD) / fieldTRD
            }
            let forwardParity = f == 0 ? (colocated.topFromBottom ? 1 : 0) : (colocated.bottomFromBottom ? 1 : 0)
            predictField(mbx: mbx, mby: mby, field: f, vector: fv, parity: forwardParity, reference: forward,
                         y: predictionY, u: predictionU, v: predictionV, quarter: quarter, maskVertical: true)
            predictField(mbx: mbx, mby: mby, field: f, vector: bv, parity: f, reference: backward,
                         y: backwardY, u: backwardU, v: backwardV, quarter: quarter, maskVertical: true)
        }
    }

    /// Forward-only or backward-only prediction of a B-VOP macroblock (frame or field).
    private func predictOneDirection(mb: Int, vectors: [MPEG4Vector], field: Bool, select: (top: Bool, bottom: Bool),
                                     reference: MPEG4Frame, y: UnsafeMutablePointer<UInt8>,
                                     u: UnsafeMutablePointer<UInt8>, v: UnsafeMutablePointer<UInt8>) {
        let mbx = mb % mbColumns, mby = mb / mbColumns
        let quarter = vol?.quarterSample == true
        if field, vectors.count == 2 {
            predictField(mbx: mbx, mby: mby, field: 0, vector: vectors[0], parity: select.top ? 1 : 0,
                         reference: reference, y: y, u: u, v: v, quarter: quarter, maskVertical: false)
            predictField(mbx: mbx, mby: mby, field: 1, vector: vectors[1], parity: select.bottom ? 1 : 0,
                         reference: reference, y: y, u: u, v: v, quarter: quarter, maskVertical: false)
            return
        }
        let vector = vectors.first ?? .zero
        predictWhole(mbx: mbx, mby: mby, vector: vector, reference: reference, y: y, u: u, v: v, rounding: 0)
    }

    // MARK: Intra blocks

    private func dcScaler(luma: Bool, quant: Int) -> Int {
        if quant <= 4 { return 8 }
        if luma { return quant <= 8 ? 2 * quant : (quant <= 24 ? quant + 8 : 2 * quant - 16) }
        return quant <= 24 ? (quant + 13) / 2 : quant - 6
    }

    @inline(__always)
    private func divideRounded(_ value: Int, _ divisor: Int) -> Int {
        value >= 0 ? (value + (divisor >> 1)) / divisor : (value - (divisor >> 1)) / divisor
    }

    /// dct_dc_size and dct_dc_differential.
    private func readIntraDC(_ reader: inout MPEG4BitReader, luma: Bool) throws -> Int {
        let size = try reader.decode(luma ? dcLumaVLC : dcChromaVLC)
        guard size > 0 else { return 0 }
        let bits = reader.read(size)
        let value = bits >> (size - 1) == 1 ? bits : bits - (1 << size) + 1
        if size > 8 { reader.marker() }
        return value
    }

    /// For each block, the blocks (macroblock offset, block) to its left, above-left and above
    /// that intra AC/DC prediction looks at.
    private static let intraNeighbours: [[(dx: Int, dy: Int, block: Int)]] = [
        [(-1, 0, 1), (-1, -1, 3), (0, -1, 2)],
        [(0, 0, 0), (0, -1, 2), (0, -1, 3)],
        [(-1, 0, 3), (-1, 0, 1), (0, 0, 0)],
        [(0, 0, 2), (0, 0, 0), (0, 0, 1)],
        [(-1, 0, 4), (-1, -1, 4), (0, -1, 4)],
        [(-1, 0, 5), (-1, -1, 5), (0, -1, 5)],
    ]

    /// Decodes and reconstructs the six blocks of an intra macroblock, with AC/DC prediction.
    private func decodeIntraBlocks(_ reader: inout MPEG4BitReader, mb: Int, cbp: Int, acPrediction: Bool, dcAsAC: Bool,
                                   fieldDCT: Bool, partitionedDC: [Int]?, target: MPEG4Frame,
                                   rvlc: Bool = false) throws {
        let mbx = mb % mbColumns, mby = mb / mbColumns
        let shortHeader = vol?.shortHeader == true
        let quant = quantiser
        mbIntra[mb] = true
        mbQuant[mb] = quant
        for block in 0..<6 {
            let luma = block < 4
            let scaler = shortHeader ? 8 : dcScaler(luma: luma, quant: quant)
            let memory = predictionMemory + (mb * 6 + block) * 15
            // Choose the prediction direction from the DC gradients of the neighbours.
            var predictor: UnsafeMutablePointer<Int32>?
            var predictorQuant = quant
            var fromLeft = true
            if !shortHeader {
                let neighbours = Self.intraNeighbours[block]
                /// Prediction memory and quantiser of neighbour `index` (left, above-left, above),
                /// if it is an intra block of this VOP and video packet.
                func neighbour(_ index: Int) -> (memory: UnsafeMutablePointer<Int32>, quant: Int)? {
                    let n = neighbours[index]
                    let nx = mbx + n.dx, ny = mby + n.dy
                    let same = n.dx == 0 && n.dy == 0
                    guard same || (available(nx, ny) && mbIntra[ny * mbColumns + nx]) else { return nil }
                    let nmb = ny * mbColumns + nx
                    return (predictionMemory + (nmb * 6 + n.block) * 15, same ? quant : mbQuant[nmb])
                }
                let left = neighbour(0), aboveLeft = neighbour(1), above = neighbour(2)
                let dcLeft = left.map { Int($0.memory[0]) } ?? 1024
                let dcAboveLeft = aboveLeft.map { Int($0.memory[0]) } ?? 1024
                let dcAbove = above.map { Int($0.memory[0]) } ?? 1024
                // |left - above-left| < |above-left - above| → predict from above.
                if abs(dcLeft - dcAboveLeft) < abs(dcAboveLeft - dcAbove) {
                    fromLeft = false
                    predictor = above?.memory
                    predictorQuant = above?.quant ?? quant
                } else {
                    predictor = left?.memory
                    predictorQuant = left?.quant ?? quant
                }
            }
            // Coefficients.
            coefficients.update(repeating: 0, count: 64)
            var start = 0
            if shortHeader {
                var level = reader.read(8)
                if level == 255 { level = 128 }
                coefficients[0] = Int32(level)
                start = 1
            } else if !dcAsAC {
                coefficients[0] = Int32(try partitionedDC?[block] ?? readIntraDC(&reader, luma: luma))
                start = 1
            }
            if (cbp >> (5 - block)) & 1 == 1 {
                let scan: [Int]
                if vop.alternateScan {
                    scan = alternateVertical
                } else if acPrediction {
                    scan = fromLeft ? alternateVertical : alternateHorizontal
                } else {
                    scan = zigzag
                }
                if shortHeader {
                    try readH263Coefficients(&reader, start: start, scan: scan)
                } else if rvlc {
                    try readReversibleCoefficients(&reader, start: start, scan: scan, intra: true)
                } else {
                    try readCoefficients(&reader, start: start, scan: scan, intra: true)
                }
            }
            if !shortHeader {
                // DC prediction, then AC prediction from the first row or column.
                if let predictor {
                    let dc = Int(coefficients[0]) + divideRounded(Int(predictor[0]), scaler)
                    coefficients[0] = Int32(min(max(dc, -2048), 2047))
                    if acPrediction {
                        for i in 1..<8 {
                            let position = fromLeft ? i * 8 : i
                            let stored = Int(predictor[fromLeft ? i + 7 : i])
                            let scaled = predictorQuant == quant ? stored : divideRounded(stored * predictorQuant, quant)
                            let value = Int(coefficients[position]) + scaled
                            coefficients[position] = Int32(min(max(value, -2048), 2047))
                        }
                    }
                } else {
                    coefficients[0] += Int32(divideRounded(1024, scaler))
                }
                memory[0] = coefficients[0] * Int32(scaler)
                for i in 1..<8 {
                    memory[i] = coefficients[i]
                    memory[i + 7] = coefficients[i * 8]
                }
            }
            dequantiseIntra(scaler: scaler, quant: quant)
            inverseTransform()
            // Store.
            let (plane, x, y, step) = intraDestination(target: target, mbx: mbx, mby: mby, block: block, fieldDCT: fieldDCT)
            var out = plane.origin + y * plane.stride + x
            let stride = plane.stride * step
            for row in 0..<8 {
                for column in 0..<8 {
                    out[column] = UInt8(clamping: residual[row * 8 + column])
                }
                out += stride
            }
        }
    }

    /// Where intra block `block` goes: plane, position and row step (2 for field DCT).
    private func intraDestination(target: MPEG4Frame, mbx: Int, mby: Int, block: Int,
                                  fieldDCT: Bool) -> (MPEG4Plane, Int, Int, Int) {
        switch block {
        case 4: return (target.cb, mbx * 8, mby * 8, 1)
        case 5: return (target.cr, mbx * 8, mby * 8, 1)
        default:
            let x = mbx * 16 + (block & 1) * 8
            if fieldDCT { return (target.luma, x, mby * 16 + (block >> 1), 2) }
            return (target.luma, x, mby * 16 + (block >> 1) * 8, 1)
        }
    }

    private func dequantiseIntra(scaler: Int, quant: Int) {
        let dc = Int(coefficients[0]) * scaler
        coefficients[0] = Int32(min(max(dc, -2048), 2047))
        if vol?.mpegQuant == true, vol?.shortHeader != true {
            let matrix = vol?.intraMatrix ?? MPEG4Tables.defaultIntraMatrix
            var sum = dc
            var nonzero = dc != 0
            for i in 1..<64 where coefficients[i] != 0 {
                let value = min(max(quant * Int(coefficients[i]) * matrix[i] / 8, -2048), 2047)
                coefficients[i] = Int32(value)
                sum ^= value
                nonzero = true
            }
            if nonzero, sum & 1 == 0 { coefficients[63] ^= 1 }
        } else {
            dequantiseH263(from: 1, quant: quant)
        }
    }

    @inline(__always)
    private func dequantiseH263(from first: Int, quant: Int) {
        let odd = quant & 1 == 1 ? 0 : 1
        for i in first..<64 where coefficients[i] != 0 {
            let level = Int(coefficients[i])
            let magnitude = quant * (2 * abs(level) + 1) - odd
            coefficients[i] = Int32(min(max(level < 0 ? -magnitude : magnitude, -2048), 2047))
        }
    }

    private func dequantiseInter(quant: Int) {
        if vol?.mpegQuant == true, vol?.shortHeader != true {
            let matrix = vol?.interMatrix ?? MPEG4Tables.defaultInterMatrix
            var sum = 0
            var nonzero = false
            for i in 0..<64 where coefficients[i] != 0 {
                let level = Int(coefficients[i])
                let value = min(max(quant * (2 * level + (level < 0 ? -1 : 1)) * matrix[i] / 16, -2048), 2047)
                coefficients[i] = Int32(value)
                sum ^= value
                nonzero = true
            }
            if nonzero, sum & 1 == 0 { coefficients[63] ^= 1 }
        } else {
            dequantiseH263(from: 0, quant: quant)
        }
    }

    // MARK: Coefficient VLCs

    /// Reads TCOEF events (MPEG-4 tables with the three escape modes) into `coefficients`.
    private func readCoefficients(_ reader: inout MPEG4BitReader, start: Int, scan: [Int], intra: Bool) throws {
        let events = intra ? intraEvents : interEvents
        let maxLevel = intra ? MPEG4Tables.intraMaxLevel : MPEG4Tables.interMaxLevel
        let maxRun = intra ? MPEG4Tables.intraMaxRun : MPEG4Tables.interMaxRun
        var position = start
        var last = false
        while !last {
            var symbol = try reader.decode(coefficientVLC)
            var level: Int, run: Int
            if symbol != 102 {
                let event = events[symbol]
                level = event & 31
                run = (event >> 5) & 63
                last = event >> 11 != 0
                if reader.bit() { level = -level }
            } else if !reader.bit() {
                // Escape type 1: level offset.
                symbol = try reader.decode(coefficientVLC)
                guard symbol != 102 else { throw MPEG4DecoderError.invalidData("escape") }
                let event = events[symbol]
                run = (event >> 5) & 63
                last = event >> 11 != 0
                level = (event & 31) + maxLevel[run + (last ? 64 : 0)]
                if reader.bit() { level = -level }
            } else if !reader.bit() {
                // Escape type 2: run offset.
                symbol = try reader.decode(coefficientVLC)
                guard symbol != 102 else { throw MPEG4DecoderError.invalidData("escape") }
                let event = events[symbol]
                level = event & 31
                last = event >> 11 != 0
                run = ((event >> 5) & 63) + maxRun[level + (last ? 32 : 0)]
                if reader.bit() { level = -level }
            } else {
                // Escape type 3: fixed-length last, run and 12-bit level.
                last = reader.bit()
                run = reader.read(6)
                reader.marker()
                level = reader.read(12)
                reader.marker()
                // Level 0 is forbidden, but some encoders (Samsung cameras) write it for empty
                // coded blocks; it's harmless, so accept it.
                if level >= 2048 { level -= 4096 }
            }
            position += run
            guard position < 64 else { throw MPEG4DecoderError.invalidData("coefficient overrun") }
            coefficients[scan[position]] = Int32(level)
            position += 1
        }
    }

    /// TCOEF with the H.263 escape (short video header).
    private func readH263Coefficients(_ reader: inout MPEG4BitReader, start: Int, scan: [Int]) throws {
        var position = start
        var last = false
        while !last {
            let symbol = try reader.decode(coefficientVLC)
            var level: Int, run: Int
            if symbol != 102 {
                let event = interEvents[symbol]
                level = event & 31
                run = (event >> 5) & 63
                last = event >> 11 != 0
                if reader.bit() { level = -level }
            } else {
                last = reader.bit()
                run = reader.read(6)
                level = reader.read(8)
                if level >= 128 { level -= 256 }      // 0 and -128 are reserved; tolerated
            }
            position += run
            guard position < 64 else { throw MPEG4DecoderError.invalidData("coefficient overrun") }
            coefficients[scan[position]] = Int32(level)
            position += 1
        }
    }

    /// TCOEF with reversible VLCs (data-partitioned VOPs), read forwards.
    private func readReversibleCoefficients(_ reader: inout MPEG4BitReader, start: Int, scan: [Int], intra: Bool) throws {
        let vlc = intra ? MPEG4Tables.intraRVLC : MPEG4Tables.interRVLC
        let events = intra ? MPEG4Tables.intraRVLCEvents : MPEG4Tables.interRVLCEvents
        var position = start
        var last = false
        while !last {
            let symbol = try reader.decode(vlc)
            var level: Int, run: Int
            if symbol != 169 {
                let event = events[symbol]
                level = event & 31
                run = (event >> 5) & 63
                last = (event >> 11) & 1 != 0
                if reader.bit() { level = -level }
            } else {
                guard reader.bit() else { throw MPEG4DecoderError.invalidData("RVLC escape") }
                last = reader.bit()
                run = reader.read(6)
                reader.marker()
                level = reader.read(11)
                reader.marker()
                guard try reader.decode(vlc) == 169 else { throw MPEG4DecoderError.invalidData("RVLC escape") }
                if reader.bit() { level = -level }
            }
            position += run
            guard position < 64 else { throw MPEG4DecoderError.invalidData("coefficient overrun") }
            coefficients[scan[position]] = Int32(level)
            position += 1
        }
    }

    // MARK: Inverse DCT

    /// 8×8 inverse DCT of `coefficients` into `residual` (rounded to nearest), separable and in
    /// single precision, which comfortably meets the IEEE 1180 accuracy requirements.
    private func inverseTransform() {
        var rowMask = 0
        for row in 0..<8 {
            let base = coefficients + row * 8
            if base[0] | base[1] | base[2] | base[3] | base[4] | base[5] | base[6] | base[7] != 0 { rowMask |= 1 << row }
        }
        if rowMask == 0 {
            residual.update(repeating: 0, count: 64)
            return
        }
        if rowMask == 1, coefficients[1] | coefficients[2] | coefficients[3] | coefficients[4]
            | coefficients[5] | coefficients[6] | coefficients[7] == 0 {
            let value = (coefficients[0] + 4) >> 3
            residual.update(repeating: value, count: 64)
            return
        }
        let basis = idctBasis
        var t0 = SIMD8<Float>(), t1 = SIMD8<Float>(), t2 = SIMD8<Float>(), t3 = SIMD8<Float>()
        var t4 = SIMD8<Float>(), t5 = SIMD8<Float>(), t6 = SIMD8<Float>(), t7 = SIMD8<Float>()
        // Vertical pass: each output row is a combination of the input rows.
        for v in 0..<8 where rowMask & (1 << v) != 0 {
            let row = SIMD8<Float>(UnsafeRawPointer(coefficients + v * 8).loadUnaligned(as: SIMD8<Int32>.self))
            let c = basis[v]
            t0 += c[0] * row; t1 += c[1] * row; t2 += c[2] * row; t3 += c[3] * row
            t4 += c[4] * row; t5 += c[5] * row; t6 += c[6] * row; t7 += c[7] * row
        }
        // Horizontal pass on each row, then round.
        let b0 = basis[0], b1 = basis[1], b2 = basis[2], b3 = basis[3]
        let b4 = basis[4], b5 = basis[5], b6 = basis[6], b7 = basis[7]
        @inline(__always) func horizontal(_ t: SIMD8<Float>) -> SIMD8<Int32> {
            var acc = b0 * t[0]
            acc += b1 * t[1]; acc += b2 * t[2]; acc += b3 * t[3]
            acc += b4 * t[4]; acc += b5 * t[5]; acc += b6 * t[6]; acc += b7 * t[7]
            return SIMD8<Int32>((acc + 0.5).rounded(.down))
        }
        let out = UnsafeMutableRawPointer(residual)
        out.storeBytes(of: horizontal(t0), toByteOffset: 0, as: SIMD8<Int32>.self)
        out.storeBytes(of: horizontal(t1), toByteOffset: 32, as: SIMD8<Int32>.self)
        out.storeBytes(of: horizontal(t2), toByteOffset: 64, as: SIMD8<Int32>.self)
        out.storeBytes(of: horizontal(t3), toByteOffset: 96, as: SIMD8<Int32>.self)
        out.storeBytes(of: horizontal(t4), toByteOffset: 128, as: SIMD8<Int32>.self)
        out.storeBytes(of: horizontal(t5), toByteOffset: 160, as: SIMD8<Int32>.self)
        out.storeBytes(of: horizontal(t6), toByteOffset: 192, as: SIMD8<Int32>.self)
        out.storeBytes(of: horizontal(t7), toByteOffset: 224, as: SIMD8<Int32>.self)
    }

    // MARK: Inter residual and reconstruction

    /// Decodes the coded inter blocks of a macroblock into `residualBlocks`; returns the cbp.
    private func decodeResidualBlocks(_ reader: inout MPEG4BitReader, cbp: Int, rvlc: Bool) throws -> Int {
        let shortHeader = vol?.shortHeader == true
        let scan = vop.alternateScan ? alternateVertical : zigzag
        for block in 0..<6 where (cbp >> (5 - block)) & 1 == 1 {
            coefficients.update(repeating: 0, count: 64)
            if shortHeader {
                try readH263Coefficients(&reader, start: 0, scan: scan)
            } else if rvlc {
                try readReversibleCoefficients(&reader, start: 0, scan: scan, intra: false)
            } else {
                try readCoefficients(&reader, start: 0, scan: scan, intra: false)
            }
            dequantiseInter(quant: quantiser)
            inverseTransform()
            (residualBlocks + block * 64).update(from: residual, count: 64)
        }
        return cbp
    }

    /// Prediction plus residual for a P/S-VOP inter macroblock.
    private func reconstructInter(mb: Int, mode: MPEG4MacroblockMode, target: MPEG4Frame, reference: MPEG4Frame,
                                  coded: Int, fieldDCT: Bool) {
        let mbx = mb % mbColumns, mby = mb / mbColumns
        mbIntra[mb] = false
        mbQuant[mb] = quantiser
        let rounding = vop.rounding
        let quarter = vol?.quarterSample == true
        if mode.gmc {
            predictGlobal(mbx: mbx, mby: mby, reference: reference)
        } else if mode.fieldMotion {
            for f in 0..<2 {
                let parity = f == 0 ? (mode.topFromBottom ? 1 : 0) : (mode.bottomFromBottom ? 1 : 0)
                predictField(mbx: mbx, mby: mby, field: f, vector: target.fieldVectors[mb * 2 + f], parity: parity,
                             reference: reference, y: predictionY, u: predictionU, v: predictionV, quarter: quarter,
                             maskVertical: false, rounding: rounding)
            }
        } else if mode.fourMV {
            let vectors = (0..<4).map { target.vectors[mb * 4 + $0] }
            predictBlocks(mbx: mbx, mby: mby, vectors: vectors, reference: reference, y: predictionY,
                          u: predictionU, v: predictionV, rounding: rounding)
        } else {
            predictWhole(mbx: mbx, mby: mby, vector: target.vectors[mb * 4], reference: reference,
                         y: predictionY, u: predictionU, v: predictionV, rounding: rounding)
        }
        storeMacroblock(mb: mb, target: target, coded: coded, fieldDCT: fieldDCT)
    }

    /// Writes prediction (+ residual for coded blocks) into the target picture.
    private func storeMacroblock(mb: Int, target: MPEG4Frame, coded: Int, fieldDCT: Bool) {
        let mbx = mb % mbColumns, mby = mb / mbColumns
        for block in 0..<6 {
            let hasResidual = (coded >> (5 - block)) & 1 == 1
            let plane: MPEG4Plane
            var source: UnsafeMutablePointer<UInt8>
            let sourceStride: Int
            var x: Int, y: Int, step = 1
            switch block {
            case 4:
                plane = target.cb; source = predictionU; sourceStride = 8; x = mbx * 8; y = mby * 8
            case 5:
                plane = target.cr; source = predictionV; sourceStride = 8; x = mbx * 8; y = mby * 8
            default:
                plane = target.luma
                x = mbx * 16 + (block & 1) * 8
                let column = (block & 1) * 8
                if fieldDCT {
                    y = mby * 16 + (block >> 1); step = 2
                    source = predictionY + (block >> 1) * 16 + column
                    sourceStride = 32
                } else {
                    y = mby * 16 + (block >> 1) * 8
                    source = predictionY + (block >> 1) * 128 + column
                    sourceStride = 16
                }
            }
            var out = plane.origin + y * plane.stride + x
            let outStride = plane.stride * step
            if hasResidual {
                let res = residualBlocks + block * 64
                for row in 0..<8 {
                    for column in 0..<8 {
                        out[column] = UInt8(clamping: Int32(source[column]) + res[row * 8 + column])
                    }
                    out += outStride
                    source += sourceStride
                }
            } else {
                for _ in 0..<8 {
                    out.update(from: source, count: 8)
                    out += outStride
                    source += sourceStride
                }
            }
        }
    }

    // MARK: Motion compensation

    /// Pointer and row stride for a `columns`×`rows` source region at (x, y) whose rows are
    /// `rowStep` picture rows apart; regions reaching past the border are edge-clamped copies.
    @inline(__always)
    private func fetch(_ plane: MPEG4Plane, x: Int, y: Int, columns: Int, rows: Int, rowStep: Int) -> (UnsafePointer<UInt8>, Int) {
        let lastRow = y + (rows - 1) * rowStep
        if x >= -plane.pad, x + columns <= plane.width + plane.pad, y >= -plane.pad, lastRow < plane.height + plane.pad {
            return (UnsafePointer(plane.origin + y * plane.stride + x), plane.stride * rowStep)
        }
        let maxX = plane.width - 1, maxY = plane.height - 1
        for row in 0..<rows {
            let sy = min(max(y + row * rowStep, 0), maxY)
            let line = plane.origin + sy * plane.stride
            for column in 0..<columns {
                edgeBuffer[row * columns + column] = line[min(max(x + column, 0), maxX)]
            }
        }
        return (UnsafePointer(edgeBuffer), columns)
    }

    /// Half-sample prediction of a `width`×`height` block from integer position (x, y).
    private func predictHalf(_ plane: MPEG4Plane, x: Int, y: Int, halfX: Bool, halfY: Bool, width: Int, height: Int,
                             rowStep: Int, rounding: Int, into dst: UnsafeMutablePointer<UInt8>, dstStride: Int) {
        let (src, stride) = fetch(plane, x: x, y: y, columns: width + 1, rows: height + 1, rowStep: rowStep)
        var s = src, d = dst
        switch (halfX, halfY) {
        case (false, false):
            for _ in 0..<height {
                d.update(from: s, count: width)
                s += stride; d += dstStride
            }
        case (true, false):
            let r = 1 - rounding
            for _ in 0..<height {
                for i in 0..<width { d[i] = UInt8((Int(s[i]) + Int(s[i + 1]) + r) >> 1) }
                s += stride; d += dstStride
            }
        case (false, true):
            let r = 1 - rounding
            for _ in 0..<height {
                let below = s + stride
                for i in 0..<width { d[i] = UInt8((Int(s[i]) + Int(below[i]) + r) >> 1) }
                s += stride; d += dstStride
            }
        case (true, true):
            let r = 2 - rounding
            for _ in 0..<height {
                let below = s + stride
                for i in 0..<width {
                    d[i] = UInt8((Int(s[i]) + Int(s[i + 1]) + Int(below[i]) + Int(below[i + 1]) + r) >> 2)
                }
                s += stride; d += dstStride
            }
        }
    }

    /// Quarter-sample luma prediction (8-tap filter, mirrored at the block edges) of a
    /// `width`×`height` block whose integer position is (x, y) and fraction (fx, fy) in quarters.
    private func predictQuarter(_ plane: MPEG4Plane, x: Int, y: Int, fx: Int, fy: Int, width: Int, height: Int,
                                rowStep: Int, rounding: Int, into dst: UnsafeMutablePointer<UInt8>, dstStride: Int) {
        if fx == 0 && fy == 0 {
            predictHalf(plane, x: x, y: y, halfX: false, halfY: false, width: width, height: height, rowStep: rowStep,
                        rounding: rounding, into: dst, dstStride: dstStride)
            return
        }
        let (src, stride) = fetch(plane, x: x, y: y, columns: width + 1, rows: height + 1, rowStep: rowStep)
        let tmp = filterBuffer                // width × (height + 1)
        @inline(__always) func mirror(_ k: Int, _ n: Int) -> Int { k < 0 ? -1 - k : (k > n ? 2 * n + 1 - k : k) }
        @inline(__always) func lowpass(_ sample: (Int) -> Int, _ i: Int, _ n: Int) -> Int {
            var u = 160 * (sample(mirror(i, n)) + sample(mirror(i + 1, n)))
            u -= 48 * (sample(mirror(i - 1, n)) + sample(mirror(i + 2, n)))
            u += 24 * (sample(mirror(i - 2, n)) + sample(mirror(i + 3, n)))
            u -= 8 * (sample(mirror(i - 3, n)) + sample(mirror(i + 4, n)))
            return min(max((u + 128 - rounding) >> 8, 0), 255)
        }
        // Horizontal pass over height + 1 rows.
        for row in 0...height {
            let line = src + row * stride
            let out = tmp + row * width
            switch fx {
            case 0:
                for i in 0..<width { out[i] = line[i] }
            case 2:
                for i in 0..<width { out[i] = UInt8(lowpass({ Int(line[$0]) }, i, width)) }
            default:
                let offset = fx == 1 ? 0 : 1
                for i in 0..<width {
                    let h = lowpass({ Int(line[$0]) }, i, width)
                    out[i] = UInt8((Int(line[i + offset]) + h + 1 - rounding) >> 1)
                }
            }
        }
        // Vertical pass.
        for column in 0..<width {
            let sample = { (k: Int) -> Int in Int(tmp[k * width + column]) }
            var d = dst + column
            for j in 0..<height {
                let value: Int
                switch fy {
                case 0: value = sample(j)
                case 2: value = lowpass(sample, j, height)
                default:
                    let v = lowpass(sample, j, height)
                    value = (sample(j + (fy == 1 ? 0 : 1)) + v + 1 - rounding) >> 1
                }
                d.pointee = UInt8(value)
                d += dstStride
            }
        }
    }

    /// Luma prediction of a block from a frame vector (half or quarter samples).
    private func predictLuma(_ plane: MPEG4Plane, x: Int, y: Int, vector: MPEG4Vector, size: Int, rounding: Int,
                             into dst: UnsafeMutablePointer<UInt8>) {
        if vol?.quarterSample == true {
            let qx = x * 4 + vector.x, qy = y * 4 + vector.y
            predictQuarter(plane, x: qx >> 2, y: qy >> 2, fx: qx & 3, fy: qy & 3, width: size, height: size,
                           rowStep: 1, rounding: rounding, into: dst, dstStride: 16)
        } else {
            let hx = x * 2 + vector.x, hy = y * 2 + vector.y
            predictHalf(plane, x: hx >> 1, y: hy >> 1, halfX: hx & 1 != 0, halfY: hy & 1 != 0, width: size,
                        height: size, rowStep: 1, rounding: rounding, into: dst, dstStride: 16)
        }
    }

    /// Chroma prediction of the 8×8 blocks from a chroma vector in half samples.
    private func predictChroma(reference: MPEG4Frame, mbx: Int, mby: Int, vector: MPEG4Vector, rounding: Int,
                               u: UnsafeMutablePointer<UInt8>, v: UnsafeMutablePointer<UInt8>) {
        let hx = mbx * 16 + vector.x, hy = mby * 16 + vector.y
        predictHalf(reference.cb, x: hx >> 1, y: hy >> 1, halfX: hx & 1 != 0, halfY: hy & 1 != 0, width: 8, height: 8,
                    rowStep: 1, rounding: rounding, into: u, dstStride: 8)
        predictHalf(reference.cr, x: hx >> 1, y: hy >> 1, halfX: hx & 1 != 0, halfY: hy & 1 != 0, width: 8, height: 8,
                    rowStep: 1, rounding: rounding, into: v, dstStride: 8)
    }

    /// The luma vector component used for chroma (halved and truncated in quarter-sample mode).
    @inline(__always)
    private func chromaSource(_ value: Int) -> Int {
        vol?.quarterSample == true ? value / 2 : value
    }

    /// Chroma vector from one luma vector component.
    @inline(__always)
    private func chromaFromOne(_ value: Int) -> Int {
        let v = chromaSource(value)
        let magnitude = MPEG4Tables.chromaRound4[abs(v) % 4] + (abs(v) / 4) * 2
        return v < 0 ? -magnitude : magnitude
    }

    /// Chroma vector component from the sum of four luma vector components.
    @inline(__always)
    private func chromaFromSum(_ sum: Int) -> Int {
        let magnitude = MPEG4Tables.chromaRound16[abs(sum) % 16] + (abs(sum) / 16) * 2
        return sum < 0 ? -magnitude : magnitude
    }

    /// One-vector (16×16) prediction.
    private func predictWhole(mbx: Int, mby: Int, vector: MPEG4Vector, reference: MPEG4Frame,
                              y: UnsafeMutablePointer<UInt8>, u: UnsafeMutablePointer<UInt8>,
                              v: UnsafeMutablePointer<UInt8>, rounding: Int) {
        predictLuma(reference.luma, x: mbx * 16, y: mby * 16, vector: vector, size: 16, rounding: rounding, into: y)
        let chroma = MPEG4Vector(x: chromaFromOne(vector.x), y: chromaFromOne(vector.y))
        predictChroma(reference: reference, mbx: mbx, mby: mby, vector: chroma, rounding: rounding, u: u, v: v)
    }

    /// Four-vector (8×8) prediction, also used by direct mode.
    private func predictBlocks(mbx: Int, mby: Int, vectors: [MPEG4Vector], reference: MPEG4Frame,
                               y: UnsafeMutablePointer<UInt8>, u: UnsafeMutablePointer<UInt8>,
                               v: UnsafeMutablePointer<UInt8>, rounding: Int) {
        var sumX = 0, sumY = 0
        for block in 0..<4 {
            let bx = mbx * 16 + (block & 1) * 8, by = mby * 16 + (block >> 1) * 8
            predictLuma(reference.luma, x: bx, y: by, vector: vectors[block], size: 8, rounding: rounding,
                        into: y + (block >> 1) * 128 + (block & 1) * 8)
            sumX += chromaSource(vectors[block].x)
            sumY += chromaSource(vectors[block].y)
        }
        let chroma = MPEG4Vector(x: chromaFromSum(sumX), y: chromaFromSum(sumY))
        predictChroma(reference: reference, mbx: mbx, mby: mby, vector: chroma, rounding: rounding, u: u, v: v)
    }

    /// Field prediction of one field (`field` 0 = top rows, 1 = bottom rows) of a macroblock from
    /// field `parity` of the reference, with a field vector (vertical component in frame units).
    private func predictField(mbx: Int, mby: Int, field: Int, vector: MPEG4Vector, parity: Int, reference: MPEG4Frame,
                              y: UnsafeMutablePointer<UInt8>, u: UnsafeMutablePointer<UInt8>,
                              v: UnsafeMutablePointer<UInt8>, quarter: Bool, maskVertical: Bool, rounding: Int = 0) {
        let x0 = mbx * 16, y0 = mby * 16
        var chromaX: Int, chromaY: Int
        if quarter {
            chromaX = vector.x / 2
            chromaY = vector.y / 2
            let vy = maskVertical ? vector.y & ~1 : vector.y
            let qx = x0 * 4 + vector.x
            let fieldQ = (y0 * 4 + vy) >> 1           // field rows, quarter samples
            predictQuarter(reference.luma, x: qx >> 2, y: 2 * (fieldQ >> 2) + parity, fx: qx & 3, fy: fieldQ & 3,
                           width: 16, height: 8, rowStep: 2, rounding: rounding, into: y + field * 16, dstStride: 32)
        } else {
            chromaX = vector.x
            chromaY = vector.y
            let hx = x0 * 2 + vector.x, hy = y0 * 2 + vector.y
            predictHalf(reference.luma, x: hx >> 1, y: ((hy >> 1) & ~1) + parity, halfX: hx & 1 != 0, halfY: hy & 2 != 0,
                        width: 16, height: 8, rowStep: 2, rounding: rounding, into: y + field * 16, dstStride: 32)
        }
        let cx = chromaX & 3 != 0 ? (chromaX >> 1) | 1 : chromaX >> 1
        let cy = chromaY & 6 != 0 ? (chromaY >> 1) | 2 : chromaY >> 1
        let px = x0 + cx                                // chroma half samples
        let row = y0 / 2 + ((cy >> 1) & ~1) + parity
        for (plane, dst) in [(reference.cb, u), (reference.cr, v)] {
            predictHalf(plane, x: px >> 1, y: row, halfX: px & 1 != 0, halfY: cy & 2 != 0, width: 8, height: 4,
                        rowStep: 2, rounding: rounding, into: dst + field * 8, dstStride: 16)
        }
    }

    /// Global motion compensation of one macroblock (luma and chroma) by warping.
    private func predictGlobal(mbx: Int, mby: Int, reference: MPEG4Frame) {
        guard let warp = vop.warp, warp.points > 0 else {
            predictWhole(mbx: mbx, mby: mby, vector: .zero, reference: reference, y: predictionY, u: predictionU,
                         v: predictionV, rounding: vop.rounding)
            return
        }
        let s = 1 << warp.shift, mask = s - 1
        let bias = (1 << (2 * warp.shift - 1)) - vop.rounding
        let resultShift = 2 * warp.shift
        let lumaMaxX = (reference.luma.width + 31) << warp.shift
        let lumaMaxY = (reference.luma.height + 31) << warp.shift
        let luma = reference.luma
        for j in 0..<16 {
            let y = mby * 16 + j
            for i in 0..<16 {
                let x = mbx * 16 + i
                let px = min(max((warp.cx + warp.ax * x + warp.bx * y) >> warp.lumaShift, 0), lumaMaxX)
                let py = min(max((warp.cy + warp.ay * x + warp.by * y) >> warp.lumaShift, 0), lumaMaxY)
                predictionY[j * 16 + i] = interpolate(luma, x: (px >> warp.shift) - 16, y: (py >> warp.shift) - 16,
                                                      rx: px & mask, ry: py & mask, s: s, bias: bias, shift: resultShift)
            }
        }
        let chromaMaxX = (reference.cb.width + 15) << warp.shift
        let chromaMaxY = (reference.cb.height + 15) << warp.shift
        for j in 0..<8 {
            let y = mby * 8 + j
            for i in 0..<8 {
                let x = mbx * 8 + i
                let px = min(max((warp.ccx + warp.cax * x + warp.cbx * y) >> warp.chromaShift, 0), chromaMaxX)
                let py = min(max((warp.ccy + warp.cay * x + warp.cby * y) >> warp.chromaShift, 0), chromaMaxY)
                let sx = (px >> warp.shift) - 8, sy = (py >> warp.shift) - 8
                predictionU[j * 8 + i] = interpolate(reference.cb, x: sx, y: sy, rx: px & mask, ry: py & mask, s: s,
                                                     bias: bias, shift: resultShift)
                predictionV[j * 8 + i] = interpolate(reference.cr, x: sx, y: sy, rx: px & mask, ry: py & mask, s: s,
                                                     bias: bias, shift: resultShift)
            }
        }
    }

    /// Bilinear sample at integer (x, y) plus fraction (rx, ry)/s, reading clamped positions.
    @inline(__always)
    private func interpolate(_ plane: MPEG4Plane, x: Int, y: Int, rx: Int, ry: Int, s: Int, bias: Int, shift: Int) -> UInt8 {
        let maxX = plane.width + plane.pad - 2, maxY = plane.height + plane.pad - 2
        let cx = min(max(x, -plane.pad), maxX), cy = min(max(y, -plane.pad), maxY)
        let p = plane.origin + cy * plane.stride + cx
        let top = (s - rx) * Int(p[0]) + rx * Int(p[1])
        let bottom = (s - rx) * Int(p[plane.stride]) + rx * Int(p[plane.stride + 1])
        return UInt8(clamping: ((s - ry) * top + ry * bottom + bias) >> shift)
    }

    // MARK: Short video header (H.263)

    private func decodeShortHeaderPicture(base: UnsafePointer<UInt8>, count: Int) throws -> [DecodedPicture] {
        var reader = MPEG4BitReader(base: base, byteCount: count)
        reader.skip(22)
        let temporalReference = reader.read(8)
        reader.skip(5)                                  // marker, zero, split screen, document camera, freeze
        let format = reader.read(3)
        let sizes = [1: (128, 96), 2: (176, 144), 3: (352, 288), 4: (704, 576), 5: (1408, 1152)]
        guard let size = sizes[format] else { throw MPEG4DecoderError.unsupported("H.263 source format \(format)") }
        let predicted = reader.bit()
        reader.skip(4)
        let quant = reader.read(5)
        reader.skip(1)
        while reader.bit() {                            // PEI / PSPARE
            reader.skip(8)
            guard !reader.isExhausted else { throw MPEG4DecoderError.invalidData("short header") }
        }
        guard quant > 0 else { throw MPEG4DecoderError.invalidData("quantiser 0") }
        if vol?.shortHeader != true || vol?.width != size.0 || vol?.height != size.1 {
            var layer = MPEG4VideoObjectLayer()
            layer.width = size.0
            layer.height = size.1
            layer.timeResolution = 30
            layer.shortHeader = true
            layer.pixelAspect = (12, 11)
            configure(layer)
        }
        var header = MPEG4VOPHeader()
        header.type = predicted ? .predicted : .intra
        header.time = temporalReference
        header.quant = quant
        header.gobCount = format == 1 ? 6 : (format == 2 ? 9 : 18)
        header.gobRows = max(mbRows / header.gobCount, 1)
        vop = header
        return try decodePicture(&reader)
    }

    private func decodeShortHeaderMacroblocks(_ reader: inout MPEG4BitReader, target: MPEG4Frame, forward: MPEG4Frame?,
                                              decoded: inout Int) throws {
        for gob in 0..<vop.gobCount {
            var gobTop = false
            if gob > 0 {
                skipStuffing(&reader)
                // GOB header: a 17-bit start code (byte-aligned with zero stuffing, or not),
                // gob_number, gob_frame_id and quantiser.
                let stuffing = (8 - (reader.position & 7)) & 7
                var headerBits = 0
                if reader.peek(17) == 1 {
                    headerBits = 17
                } else if stuffing > 0, reader.peek(stuffing) == 0, reader.peek(stuffing + 17) & 0x1FFFF == 1 {
                    headerBits = stuffing + 17
                }
                if headerBits > 0 {
                    reader.skip(headerBits)
                    _ = reader.read(5)
                    reader.skip(2)
                    let quant = reader.read(5)
                    if quant > 0 { quantiser = quant }
                    gobTop = true
                }
            }
            for rowInGOB in 0..<vop.gobRows {
                let mby = gob * vop.gobRows + rowInGOB
                guard mby < mbRows else { break }
                for mbx in 0..<mbColumns {
                    let mb = mby * mbColumns + mbx
                    if vop.type == .intra {
                        var mcbpc: Int
                        repeat { mcbpc = try reader.decode(mcbpcIntraVLC) } while mcbpc == 8 && !reader.isExhausted
                        guard mcbpc < 8 else { throw MPEG4DecoderError.invalidData("MCBPC") }
                        let cbpy = try reader.decode(cbpyVLC)
                        if mcbpc > 3 { applyDquant(&reader) }
                        try decodeIntraBlocks(&reader, mb: mb, cbp: cbpy << 2 | (mcbpc & 3), acPrediction: false,
                                              dcAsAC: false, fieldDCT: false, partitionedDC: nil, target: target)
                        target.modes[mb] = MPEG4MacroblockMode(intra: true)
                        for block in 0..<4 { target.vectors[mb * 4 + block] = .zero }
                    } else {
                        guard let forward else { throw MPEG4DecoderError.invalidData("missing reference") }
                        var notCoded = false
                        var mcbpc = 0
                        repeat {
                            notCoded = reader.bit()
                            if !notCoded { mcbpc = try reader.decode(mcbpcInterVLC) }
                        } while !notCoded && mcbpc == 20 && !reader.isExhausted
                        if notCoded {
                            try reconstructNotCoded(mb: mb, target: target, reference: forward, gmc: false)
                        } else {
                            guard mcbpc < 20, mcbpc / 4 != 2 else { throw MPEG4DecoderError.invalidData("MCBPC") }
                            let intra = mcbpc / 4 >= 3
                            var cbpy = try reader.decode(cbpyVLC)
                            if !intra { cbpy = 15 - cbpy }
                            if mcbpc / 4 == 1 || mcbpc / 4 == 4 { applyDquant(&reader) }
                            let cbp = cbpy << 2 | (mcbpc & 3)
                            if intra {
                                try decodeIntraBlocks(&reader, mb: mb, cbp: cbp, acPrediction: false, dcAsAC: false,
                                                      fieldDCT: false, partitionedDC: nil, target: target)
                                target.modes[mb] = MPEG4MacroblockMode(intra: true)
                                for block in 0..<4 { target.vectors[mb * 4 + block] = .zero }
                            } else {
                                let mode = MPEG4MacroblockMode()
                                try decodeMotion(&reader, mb: mb, mode: mode, target: target, shortHeader: true,
                                                 gobTop: gobTop && rowInGOB == 0)
                                target.modes[mb] = mode
                                let coded = try decodeResidualBlocks(&reader, cbp: cbp, rvlc: false)
                                reconstructInter(mb: mb, mode: mode, target: target, reference: forward, coded: coded,
                                                 fieldDCT: false)
                            }
                        }
                    }
                    guard !reader.isExhausted else { throw MPEG4DecoderError.invalidData("truncated picture") }
                    decoded = mb + 1
                }
            }
        }
    }
}
