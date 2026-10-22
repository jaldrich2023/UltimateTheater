//
//  DTSDecoder.swift
//  Ultimate Theater
//
//  A decoder for the DTS Coherent Acoustics core (ETSI TS 102 114, clause 5 and
//  Annex C), which macOS doesn't decode. Frames become float PCM that the audio
//  renderer plays directly. Extensions (DTS-ES, 96/24, DTS-HD) are skipped; every
//  DTS stream carries a full core, so those still play at core quality.
//
//  The public specification omits two vector codebooks (clause D.10). In their place,
//  ADPCM-predicted subbands use a predictor estimated from the subband's recent output,
//  and high-frequency VQ subbands are filled with noise at their transmitted level. Film
//  soundtracks at DVD and Blu-ray bit rates use either for only a few percent of subbands.
//

import Foundation

// MARK: - Framing

/// Finds DTS core frames in a byte stream. Accepts all four word packings (16-bit or
/// 14-bit, big- or little-endian) and returns each core as big-endian 16-bit data.
/// Extension substreams after the core (DTS-HD) are skipped.
nonisolated struct DTSFramer {
    private var buffer = Data()

    mutating func reset() { buffer.removeAll() }

    enum Packing { case big16, little16, big14, little14 }

    static func packing(at bytes: UnsafeRawBufferPointer, _ index: Int) -> Packing? {
        guard index + 6 <= bytes.count else { return nil }
        let b0 = bytes[index], b1 = bytes[index + 1], b2 = bytes[index + 2], b3 = bytes[index + 3]
        switch (b0, b1, b2, b3) {
        case (0x7F, 0xFE, 0x80, 0x01): return .big16
        case (0xFE, 0x7F, 0x01, 0x80): return .little16
        case (0x1F, 0xFF, 0xE8, 0x00) where bytes[index + 4] == 0x07 && bytes[index + 5] & 0xF0 == 0xF0: return .big14
        case (0xFF, 0x1F, 0x00, 0xE8) where bytes[index + 5] == 0x07 && bytes[index + 4] & 0xF0 == 0xF0: return .little14
        default: return nil
        }
    }

    /// Rewrites `wire` bytes into a big-endian 16-bit stream.
    static func normalize(_ wire: Data, packing: Packing) -> Data {
        switch packing {
        case .big16:
            return wire
        case .little16:
            var out = Data(count: wire.count & ~1)
            wire.withUnsafeBytes { source in
                out.withUnsafeMutableBytes { target in
                    for index in stride(from: 0, to: target.count, by: 2) {
                        target[index] = source[index + 1]
                        target[index + 1] = source[index]
                    }
                }
            }
            return out
        case .big14, .little14:
            // Each 16-bit word carries 14 payload bits.
            var out = [UInt8]()
            out.reserveCapacity(wire.count)
            var accumulator: UInt32 = 0
            var bits = 0
            wire.withUnsafeBytes { source in
                for index in stride(from: 0, to: source.count - 1, by: 2) {
                    let word = packing == .big14
                        ? UInt32(source[index]) << 8 | UInt32(source[index + 1])
                        : UInt32(source[index + 1]) << 8 | UInt32(source[index])
                    accumulator = accumulator << 14 | (word & 0x3FFF)
                    bits += 14
                    while bits >= 8 {
                        bits -= 8
                        out.append(UInt8(truncatingIfNeeded: accumulator >> UInt32(bits)))
                    }
                    accumulator &= (1 << UInt32(bits)) - 1
                }
            }
            return Data(out)
        }
    }

    /// Core frame size in bytes (FSIZE + 1), from normalized header bytes.
    static func coreSize(_ header: Data) -> Int? {
        guard header.count >= 10 else { return nil }
        var reader = DTSBitReader(header)
        reader.skip(32 + 1 + 5 + 1)
        let blocks = reader.read(7) + 1
        let size = reader.read(14) + 1
        reader.skip(6)
        let rate = reader.read(4)
        guard size >= 96, blocks >= 6, DTSCoreDecoder.sampleRates[rate] > 0 else { return nil }
        return size
    }

    mutating func push(_ data: Data) -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        var consumed = 0
        buffer.withUnsafeBytes { bytes in
            var index = 0
            var partial: Int?
            while index + 16 <= bytes.count {
                guard let packing = Self.packing(at: bytes, index) else { index += 1; continue }
                let is14 = packing == .big14 || packing == .little14
                let headerWire = Data(bytes[index..<(index + 16)])
                guard let size = Self.coreSize(Self.normalize(headerWire, packing: packing)) else { index += 1; continue }
                // In 14-bit packings every 14 payload bits take 16 bits on the wire.
                let wireSize = is14 ? ((size * 8 + 13) / 14) * 2 : size
                guard index + wireSize <= bytes.count else { partial = index; break }
                frames.append(Self.normalize(Data(bytes[index..<(index + wireSize)]), packing: packing))
                index += wireSize
            }
            // Keep a partial frame, or the last few bytes that may begin one, for the next push.
            consumed = partial ?? index
        }
        if consumed > 0 { buffer.removeFirst(consumed) }
        // A runaway buffer means this isn't DTS; never hold more than a few frames.
        if buffer.count > 1 << 18 { buffer.removeFirst(buffer.count - 16) }
        return frames
    }
}

// MARK: - Bit reading

nonisolated struct DTSBitReader {
    private let bytes: [UInt8]
    private(set) var position = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var bitsLeft: Int { bytes.count * 8 - position }

    mutating func read(_ count: Int) -> Int {
        var value = 0
        for _ in 0..<count {
            let byte = position >> 3
            let bit = byte < bytes.count ? Int(bytes[byte] >> (7 - UInt8(position & 7))) & 1 : 0
            value = value << 1 | bit
            position += 1
        }
        return value
    }

    mutating func readBit() -> Int {
        let byte = position >> 3
        let bit = byte < bytes.count ? Int(bytes[byte] >> (7 - UInt8(position & 7))) & 1 : 0
        position += 1
        return bit
    }

    /// A two's-complement value of `count` bits.
    mutating func readSigned(_ count: Int) -> Int {
        let value = read(count)
        return value >= 1 << (count - 1) ? value - (1 << count) : value
    }

    mutating func skip(_ count: Int) { position += count }
}

// MARK: - Huffman codebooks

/// A prefix-code decoder built from the specification's (level, length, code) triples.
nonisolated struct DTSHuffmanBook {
    /// Pairs of children. A child ≥ 1 is a node index; ≤ 0 is a leaf holding −(level + bias).
    private var nodes: [Int32] = [0, 0]
    private static let bias: Int32 = 1 << 20

    init(_ triples: [Int32]) {
        for index in stride(from: 0, to: triples.count, by: 3) {
            let level = triples[index], length = Int(triples[index + 1]), code = Int(triples[index + 2])
            var node = 0
            for depth in stride(from: length - 1, through: 0, by: -1) {
                let slot = node * 2 + (code >> depth) & 1
                if depth == 0 {
                    nodes[slot] = -(level + Self.bias)
                } else {
                    if nodes[slot] <= 0 {
                        nodes.append(contentsOf: [0, 0])
                        nodes[slot] = Int32(nodes.count / 2 - 1)
                    }
                    node = Int(nodes[slot])
                }
            }
        }
    }

    /// The decoded level, or nil for a code that isn't in the book.
    func decode(_ reader: inout DTSBitReader) -> Int? {
        var node = 0
        for _ in 0..<24 {
            let child = nodes[node * 2 + reader.readBit()]
            if child < 0 { return Int(-child - Self.bias) }
            if child == 0 { return nil }
            node = Int(child)
        }
        return nil
    }
}

nonisolated enum DTSBooks {
    typealias T = DTSTables
    static let transientMode = [T.huffmanA4, T.huffmanB4, T.huffmanC4, T.huffmanD4].map(DTSHuffmanBook.init)
    static let bitAllocation = [T.huffmanA12, T.huffmanB12, T.huffmanC12, T.huffmanD12, T.huffmanE12].map(DTSHuffmanBook.init)
    static let scales = [T.huffmanSA129, T.huffmanSB129, T.huffmanSC129, T.huffmanSD129, T.huffmanSE129].map(DTSHuffmanBook.init)
    /// Subband sample codebooks for ABITS 1…10, indexed by SEL.
    static let samples: [[DTSHuffmanBook]] = [
        [T.huffmanA3],
        [T.huffmanA5, T.huffmanB5, T.huffmanC5],
        [T.huffmanA7, T.huffmanB7, T.huffmanC7],
        [T.huffmanA9, T.huffmanB9, T.huffmanC9],
        [T.huffmanA13, T.huffmanB13, T.huffmanC13],
        [T.huffmanA17, T.huffmanB17, T.huffmanC17, T.huffmanD17, T.huffmanE17, T.huffmanF17, T.huffmanG17],
        [T.huffmanA25, T.huffmanB25, T.huffmanC25, T.huffmanD25, T.huffmanE25, T.huffmanF25, T.huffmanG25],
        [T.huffmanA33, T.huffmanB33, T.huffmanC33, T.huffmanD33, T.huffmanE33, T.huffmanF33, T.huffmanG33],
        [T.huffmanA65, T.huffmanB65, T.huffmanC65, T.huffmanD65, T.huffmanE65, T.huffmanF65, T.huffmanG65],
        [T.huffmanA129, T.huffmanB129, T.huffmanC129, T.huffmanD129, T.huffmanE129, T.huffmanF129, T.huffmanG129],
    ].map { $0.map(DTSHuffmanBook.init) }
}

// MARK: - Core decoder

nonisolated final class DTSCoreDecoder {
    /// Interleaved float PCM in `channels` order.
    struct Output {
        var samples: [Float]
        var frameCount: Int
        var sampleRate: Double
        var channels: [Speaker]
    }

    /// Output speakers, in the order samples are interleaved (WAVE order).
    enum Speaker: Int, Comparable {
        case left, right, center, lfe, leftSurround, rightSurround, surround
        static func < (a: Speaker, b: Speaker) -> Bool { a.rawValue < b.rawValue }
    }

    static let sampleRates: [Double] = [0, 8000, 16000, 32000, 0, 0, 11025, 22050, 44100, 0, 0, 12000, 24000, 48000, 0, 0]

    /// Primary channel arrangement for each AMODE (Table 5-4), in bitstream order.
    static let arrangements: [[Speaker]] = [
        [.center], [.left, .right], [.left, .right], [.left, .right], [.left, .right],
        [.center, .left, .right], [.left, .right, .surround], [.center, .left, .right, .surround],
        [.left, .right, .leftSurround, .rightSurround], [.center, .left, .right, .leftSurround, .rightSurround],
    ]

    /// Diagnostics: subbands that needed the codebooks missing from the public spec.
    private(set) var predictedSubbands = 0
    private(set) var vectorSubbands = 0
    private(set) var codedSubbands = 0
    private(set) var damagedFrames = 0

    private var banks: [SynthesisBank] = []
    private var lfeHistory = [Double](repeating: 0, count: 8)
    /// Recent reconstructed samples of every subband, [channel][band], oldest first.
    private var subbandHistory: [[[Double]]] = []
    /// Fills VQ-coded high subbands with noise at their transmitted level (instead of silence).
    var fillsVectorSubbands = true

    func reset() {
        banks.removeAll()
        lfeHistory = [Double](repeating: 0, count: 8)
        subbandHistory.removeAll()
    }

    private struct DecodeError: Error {}

    /// Decodes one core frame (big-endian 16-bit packing, as `DTSFramer` returns).
    /// Damaged frames come back as silence of the right length so timing holds.
    func decode(_ frame: Data) -> Output? {
        var reader = DTSBitReader(frame)
        guard reader.read(32) == 0x7FFE_8001 else { return nil }
        // Bit stream header (Table 5-1).
        reader.skip(1 + 5)                       // FTYPE, SHORT
        let crcPresent = reader.read(1) == 1     // CPF
        let blocks = reader.read(7) + 1          // NBLKS
        reader.skip(14)                          // FSIZE
        let amode = reader.read(6)
        let sampleRate = Self.sampleRates[reader.read(4)]
        let rate = reader.read(5)
        reader.skip(1)                           // FixedBit
        let hasDynamicRange = reader.read(1) == 1
        reader.skip(1 + 1 + 1 + 3 + 1)           // TIMEF, AUXF, HDCD, EXT_AUDIO_ID, EXT_AUDIO
        let syncEverySubsubframe = reader.read(1) == 1
        let lfeMode = reader.read(2)
        reader.skip(1)                           // HFLAG
        if crcPresent { reader.skip(16) }
        let perfectFilter = reader.read(1) == 1
        reader.skip(4 + 2 + 3)                   // VERNUM, CHIST, PCMR
        let frontSumDifference = reader.read(1) == 1
        let surroundSumDifference = reader.read(1) == 1
        reader.skip(4)                           // DIALNORM / UNSPEC
        guard sampleRate > 0, amode < Self.arrangements.count, lfeMode != 3 else { return nil }

        let arrangement = Self.arrangements[amode]
        let hasLFE = lfeMode > 0
        var speakers = arrangement + (hasLFE ? [.lfe] : [])
        speakers.sort()
        let frameCount = blocks * 32
        var output = Output(samples: [Float](repeating: 0, count: frameCount * speakers.count),
                            frameCount: frameCount, sampleRate: sampleRate, channels: speakers)
        if banks.count != arrangement.count {
            banks = Array(repeating: SynthesisBank(), count: arrangement.count)
            subbandHistory = Array(repeating: Array(repeating: [Double](repeating: 0, count: Self.historyLength), count: 32),
                                   count: arrangement.count)
        }
        do {
            try decodeAudio(&reader, output: &output, arrangement: arrangement, crcPresent: crcPresent,
                            lossless: rate == 0x1F, hasDynamicRange: hasDynamicRange,
                            syncEverySubsubframe: syncEverySubsubframe, lfeMode: lfeMode,
                            perfectFilter: perfectFilter,
                            sumDifference: (front: frontSumDifference || amode == 3, surround: surroundSumDifference))
        } catch {
            damagedFrames += 1
            reset()
            output.samples = [Float](repeating: 0, count: frameCount * speakers.count)
        }
        return output
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func decodeAudio(_ reader: inout DTSBitReader, output: inout Output, arrangement: [Speaker], crcPresent: Bool,
                             lossless: Bool, hasDynamicRange: Bool, syncEverySubsubframe: Bool, lfeMode: Int,
                             perfectFilter: Bool, sumDifference: (front: Bool, surround: Bool)) throws {
        // Primary audio coding header (Table 5-21).
        let subframes = reader.read(4) + 1
        let channels = reader.read(3) + 1
        guard channels <= arrangement.count else { throw DecodeError() }
        let subbands = (0..<channels).map { _ in min(reader.read(5) + 2, 32) }
        let vqStart = (0..<channels).map { ch in min(reader.read(5) + 1, subbands[ch]) }
        let joint = (0..<channels).map { _ in reader.read(3) }
        let transientBook = (0..<channels).map { _ in reader.read(2) }
        let scaleBook = (0..<channels).map { _ in reader.read(3) }
        let allocationBook = (0..<channels).map { _ in reader.read(3) }
        var select = [[Int]](repeating: [Int](repeating: 0, count: 26), count: channels)
        for ch in 0..<channels { select[ch][0] = reader.read(1) }
        for n in 1..<5 { for ch in 0..<channels { select[ch][n] = reader.read(2) } }
        for n in 5..<10 { for ch in 0..<channels { select[ch][n] = reader.read(3) } }
        let adjustments: [Double] = [1.0, 1.125, 1.25, 1.4375]
        var adjust = [[Double]](repeating: [Double](repeating: 1, count: 26), count: channels)
        for ch in 0..<channels where select[ch][0] == 0 { adjust[ch][0] = adjustments[reader.read(2)] }
        for n in 1..<5 { for ch in 0..<channels where select[ch][n] < 3 { adjust[ch][n] = adjustments[reader.read(2)] } }
        for n in 5..<10 { for ch in 0..<channels where select[ch][n] < 7 { adjust[ch][n] = adjustments[reader.read(2)] } }
        if crcPresent { reader.skip(16) }
        for ch in 0..<channels where joint[ch] > 0 && joint[ch] - 1 >= ch { throw DecodeError() }
        guard !scaleBook.contains(7), !allocationBook.contains(7) else { throw DecodeError() }

        let stepTable = lossless ? DTSTables.losslessStep : DTSTables.lossyStep
        let speakerIndex = output.channels
        let outputChannels = speakerIndex.count
        var written = 0

        for _ in 0..<subframes {
            // Side information (Table 5-28).
            let subsubframes = reader.read(2) + 1
            reader.skip(3)                                  // PSC
            var prediction = [[Bool]](repeating: [Bool](repeating: false, count: 32), count: channels)
            for ch in 0..<channels { for n in 0..<subbands[ch] { prediction[ch][n] = reader.read(1) == 1 } }
            // Prediction coefficient VQ addresses; the codebook (D.10.1) isn't public.
            for ch in 0..<channels { for n in 0..<subbands[ch] where prediction[ch][n] { reader.skip(12) } }
            var abits = [[Int]](repeating: [Int](repeating: 0, count: 32), count: channels)
            for ch in 0..<channels {
                for n in 0..<vqStart[ch] {
                    let book = allocationBook[ch]
                    let value: Int
                    if book < 5 {
                        guard let decoded = DTSBooks.bitAllocation[book].decode(&reader) else { throw DecodeError() }
                        value = decoded
                    } else {
                        value = reader.read(book - 1)       // 4- or 5-bit linear
                    }
                    guard value <= 26 else { throw DecodeError() }
                    abits[ch][n] = value
                }
            }
            var transient = [[Int]](repeating: [Int](repeating: 0, count: 32), count: channels)
            if subsubframes > 1 {
                for ch in 0..<channels {
                    for n in 0..<vqStart[ch] where abits[ch][n] > 0 {
                        guard let mode = DTSBooks.transientMode[transientBook[ch]].decode(&reader) else { throw DecodeError() }
                        transient[ch][n] = mode
                    }
                }
            }
            var scales = [[(Double, Double)]](repeating: [(Double, Double)](repeating: (0, 0), count: 32), count: channels)
            for ch in 0..<channels {
                let book = scaleBook[ch]
                let table = book == 6 ? DTSTables.scale7 : DTSTables.scale6
                var sum = 0
                func nextScale() throws -> Double {
                    if book < 5 {
                        guard let delta = DTSBooks.scales[book].decode(&reader) else { throw DecodeError() }
                        sum += delta
                    } else {
                        sum = reader.read(book == 6 ? 7 : 6)
                    }
                    guard sum >= 0, sum < table.count else { throw DecodeError() }
                    return Double(table[sum])
                }
                for n in 0..<vqStart[ch] where abits[ch][n] > 0 {
                    let first = try nextScale()
                    scales[ch][n] = (first, transient[ch][n] > 0 ? try nextScale() : first)
                }
                for n in vqStart[ch]..<subbands[ch] {
                    let value = try nextScale()
                    scales[ch][n] = (value, value)
                }
            }
            var jointBook = [Int](repeating: 0, count: channels)
            for ch in 0..<channels where joint[ch] > 0 { jointBook[ch] = reader.read(3) }
            var jointScales = [[Double]](repeating: [Double](repeating: 0, count: 32), count: channels)
            for ch in 0..<channels where joint[ch] > 0 {
                let source = joint[ch] - 1
                let book = jointBook[ch]
                guard book != 7 else { throw DecodeError() }
                for n in subbands[ch]..<subbands[source] {
                    var index: Int
                    if book < 5 {
                        guard let value = DTSBooks.scales[book].decode(&reader) else { throw DecodeError() }
                        index = value
                    } else {
                        index = reader.read(book == 6 ? 7 : 6)
                    }
                    index += 64
                    guard index >= 0, index < DTSTables.jointScale.count else { throw DecodeError() }
                    jointScales[ch][n] = DTSTables.jointScale[index]
                }
            }
            if hasDynamicRange { reader.skip(8) }           // RANGE (applied only on request; ignored here)
            if crcPresent { reader.skip(16) }

            // Audio data (Table 5-29). Subband samples for this subframe: [channel][band][sample].
            let length = subsubframes * 8
            var samples = [[[Double]]](repeating: [[Double]](repeating: [Double](repeating: 0, count: length), count: 32),
                                       count: channels)
            for ch in 0..<channels {
                // High-frequency VQ (D.10.2 isn't public): noise at the transmitted level stands in
                // for the codebook vector, the same vector for the same address.
                for n in vqStart[ch]..<subbands[ch] {
                    let address = reader.read(10)
                    guard fillsVectorSubbands else { continue }
                    let level = scales[ch][n].0 * Self.vectorFillLevel
                    for m in 0..<length { samples[ch][n][m] = level * Self.vectorNoise[address * 32 + m] }
                }
                vectorSubbands += subbands[ch] - vqStart[ch]
                for n in 0..<subbands[ch] where prediction[ch][n] { predictedSubbands += 1 }
                codedSubbands += subbands[ch]
            }
            var lfe: [Double] = []
            if lfeMode > 0 {
                let count = 2 * lfeMode * subsubframes
                let raw = (0..<count).map { _ in reader.readSigned(8) }
                let index = reader.read(8)
                guard index < DTSTables.scale7.count else { throw DecodeError() }
                let scale = Double(DTSTables.scale7[index]) * 0.035
                lfe = raw.map { Double($0) * scale }
            }
            for subsubframe in 0..<subsubframes {
                for ch in 0..<channels {
                    for n in 0..<vqStart[ch] {
                        let bits = abits[ch][n]
                        guard bits > 0 else { continue }
                        var values = [Int](repeating: 0, count: 8)
                        let sel = bits <= 10 ? select[ch][bits - 1] : 0
                        let books = bits <= 10 ? DTSBooks.samples[bits - 1] : []
                        if sel < books.count {
                            for m in 0..<8 {
                                guard let value = books[sel].decode(&reader) else { throw DecodeError() }
                                values[m] = value
                            }
                        } else if bits <= 7 {
                            // Block code: four samples per code, least significant digit first (C.3.2).
                            let levels = [3, 5, 7, 9, 13, 17, 25][bits - 1]
                            let width = [7, 10, 12, 13, 15, 17, 19][bits - 1]
                            let offset = (levels - 1) / 2
                            for block in 0..<2 {
                                var code = reader.read(width)
                                for m in 0..<4 {
                                    values[block * 4 + m] = code % levels - offset
                                    code /= levels
                                }
                                guard code == 0 else { throw DecodeError() }
                            }
                        } else {
                            for m in 0..<8 { values[m] = reader.readSigned(bits - 3) }
                        }
                        let step = Double(stepTable[bits]) / 4_194_304       // × 2^-22
                        let tmode = transient[ch][n] == 0 ? subsubframes : transient[ch][n]
                        let scale = subsubframe < tmode ? scales[ch][n].0 : scales[ch][n].1
                        let factor = step * scale * (bits <= 10 ? adjust[ch][bits - 1] : 1)
                        for m in 0..<8 { samples[ch][n][subsubframe * 8 + m] = factor * Double(values[m]) }
                    }
                }
                if subsubframe == subsubframes - 1 || syncEverySubsubframe {
                    guard reader.read(16) == 0xFFFF else { throw DecodeError() }
                }
            }

            // Inverse ADPCM (C.3.3). Without the coefficient codebook, the predictor is estimated
            // from the subband's own recent output (see `predictor`).
            for ch in 0..<channels {
                for n in 0..<32 {
                    var history = subbandHistory[ch][n]
                    let isCoded = n < vqStart[ch] && abits[ch][n] > 0
                    if prediction[ch][n] && isCoded {
                        let coefficients = Self.predictor(from: history)
                        var recent = Array(history.suffix(4))
                        for m in 0..<length {
                            var value = samples[ch][n][m]
                            for k in 0..<4 { value += coefficients[k] * recent[3 - k] }
                            samples[ch][n][m] = value
                            recent.removeFirst()
                            recent.append(value)
                        }
                    }
                    history.removeFirst(length)
                    history.append(contentsOf: samples[ch][n])
                    subbandHistory[ch][n] = history
                }
            }

            // Joint intensity (C.3.4) and sum/difference (C.3.5).
            var active = subbands
            for ch in 0..<channels where joint[ch] > 0 {
                let source = joint[ch] - 1
                for n in subbands[ch]..<subbands[source] {
                    for m in 0..<length { samples[ch][n][m] = jointScales[ch][n] * samples[source][n][m] }
                }
                active[ch] = max(active[ch], subbands[source])
            }
            func unmix(_ a: Speaker, _ b: Speaker) {
                guard let x = arrangement.firstIndex(of: a), let y = arrangement.firstIndex(of: b), x < channels, y < channels else { return }
                for n in 0..<32 {
                    for m in 0..<length {
                        let sum = samples[x][n][m], difference = samples[y][n][m]
                        samples[x][n][m] = sum + difference
                        samples[y][n][m] = sum - difference
                    }
                }
                active[x] = max(active[x], active[y]); active[y] = active[x]
            }
            if sumDifference.front { unmix(.left, .right) }
            if sumDifference.surround { unmix(.leftSurround, .rightSurround) }

            // Filter bank reconstruction (C.3.6) into the interleaved output.
            let coefficients = perfectFilter ? DTSTables.perfectQMF : DTSTables.lossyQMF
            let pcmCount = length * 32
            guard written + pcmCount <= output.frameCount else { throw DecodeError() }
            output.samples.withUnsafeMutableBufferPointer { out in
                for ch in 0..<channels {
                    guard let slot = speakerIndex.firstIndex(of: arrangement[ch]) else { continue }
                    var input = [Double](repeating: 0, count: 32)
                    for m in 0..<length {
                        for n in 0..<32 { input[n] = n < active[ch] ? samples[ch][n][m] : 0 }
                        banks[ch].synthesize(input, coefficients: coefficients) { i, value in
                            out[(written + m * 32 + i) * outputChannels + slot] = Float(value * Self.subbandOutputScale)
                        }
                    }
                }
                // LFE interpolation (C.3.7).
                if lfeMode > 0, let slot = speakerIndex.firstIndex(of: .lfe) {
                    let factor = lfeMode == 1 ? 128 : 64
                    let filter = lfeMode == 1 ? DTSTables.lfe128 : DTSTables.lfe64
                    let taps = 512 / factor
                    var history = lfeHistory
                    for (index, value) in lfe.enumerated() {
                        history.insert(value, at: 0)
                        history.removeLast()
                        for k in 0..<factor {
                            var sum = 0.0
                            for j in 0..<taps { sum += history[j] * filter[k + j * factor] }
                            let position = written + index * factor + k
                            if position < output.frameCount { out[position * outputChannels + slot] = Float(sum * Self.lfeOutputScale) }
                        }
                    }
                    lfeHistory = history
                }
            }
            written += pcmCount
        }
    }

    static let historyLength = 64

    /// RMS of a VQ-coded subband relative to its scale factor. Coded subbands just below
    /// the VQ range measure 0.96 (p10–p90: 0.88–1.06) across two minutes of a film soundtrack.
    static let vectorFillLevel = 0.96

    /// 1,024 fixed noise vectors of 32 samples with unit RMS, one per VQ address.
    static let vectorNoise: [Double] = {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var table: [Double] = []
        table.reserveCapacity(1024 * 32)
        for _ in 0..<1024 {
            var vector: [Double] = (0..<32).map { _ in
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                return Double(Int64(bitPattern: state) >> 11) / Double(1 << 52)
            }
            let rms = (vector.reduce(0) { $0 + $1 * $1 } / 32).squareRoot()
            if rms > 0 { vector = vector.map { $0 / rms } }
            table += vector
        }
        return table
    }()

    static func rms<C: Collection>(_ values: C) -> Double where C.Element == Double {
        values.isEmpty ? 0 : (values.reduce(0) { $0 + $1 * $1 } / Double(values.count)).squareRoot()
    }

    /// A 4th-order linear predictor estimated from recent output (autocorrelation method,
    /// so the synthesis filter is always stable), with bandwidth expansion and a cap on the
    /// prediction gain so an unlucky estimate can't amplify the residual much.
    static func predictor(from history: [Double]) -> [Double] {
        let order = 4
        var r = [Double](repeating: 0, count: order + 1)
        let count = history.count
        for lag in 0...order {
            var sum = 0.0
            for i in lag..<count { sum += history[i] * history[i - lag] }
            r[lag] = sum
        }
        guard r[0] > 0 else { return [0, 0, 0, 0] }
        r[0] *= 1.0001
        for lag in 1...order { r[lag] *= exp(-0.5 * pow(0.02 * Double(lag), 2)) }
        // Levinson-Durbin recursion.
        var a = [Double](repeating: 0, count: order + 1)
        var error = r[0]
        for i in 1...order {
            var acc = r[i]
            for j in 1..<i { acc -= a[j] * r[i - j] }
            let k = acc / error
            guard abs(k) < 1 else { break }
            var next = a
            next[i] = k
            for j in 1..<i { next[j] = a[j] - k * a[i - j] }
            a = next
            error *= 1 - k * k
            if error / r[0] < 0.01 { break }   // Cap the prediction gain at 20 dB.
        }
        var gamma = 1.0
        return (1...order).map { j in gamma *= 0.98; return a[j] * gamma }
    }

    /// Output gains to ±1.0 float. Decoded values are on a 24-bit integer scale. The
    /// specification leaves the filter bank's output gain (`rScale` in C.3.6) open; its
    /// pseudocode has 1/32 amplitude gain, and 256 places a mastered soundtrack's peaks at
    /// full scale while keeping the unity-gain LFE path in balance with the main channels.
    static let lfeOutputScale = 1.0 / 8_388_608
    static let subbandOutputScale = 256.0 / 8_388_608
}

// MARK: - Synthesis filter bank

/// The 32-band interpolation filter bank of clause C.3.6, one per channel.
nonisolated struct SynthesisBank {
    private var history = [Double](repeating: 0, count: 512)
    private var accumulator = [Double](repeating: 0, count: 64)

    /// Cosine modulation coefficients (PreCalCosMod).
    private static let modulation: [Double] = {
        var table: [Double] = []
        for k in 0..<16 { for i in 0..<16 { table.append(cos(Double((2 * i + 1) * (2 * k + 1)) * .pi / 64)) } }
        for k in 0..<16 { for i in 0..<16 { table.append(cos(Double(i * (2 * k + 1)) * .pi / 32)) } }
        for k in 0..<16 { table.append(0.25 / (2 * cos(Double(2 * k + 1) * .pi / 128))) }
        for k in 0..<16 { table.append(-0.25 / (2 * sin(Double(2 * k + 1) * .pi / 128))) }
        return table
    }()

    /// Turns one sample from each of the 32 subbands into 32 PCM samples.
    mutating func synthesize(_ input: [Double], coefficients: [Double], emit: (Int, Double) -> Void) {
        let cosMod = Self.modulation
        var sum = [Double](repeating: 0, count: 16)
        var difference = [Double](repeating: 0, count: 16)
        var j = 0
        var a = [Double](repeating: 0, count: 16)
        for k in 0..<16 {
            var value = 0.0
            for i in 0..<16 { value += (input[2 * i] + input[2 * i + 1]) * cosMod[j]; j += 1 }
            a[k] = value
        }
        for k in 0..<16 {
            var value = 0.0
            for i in 0..<16 {
                value += (i > 0 ? input[2 * i] + input[2 * i - 1] : input[0]) * cosMod[j]
                j += 1
            }
            sum[k] = a[k] + value
            difference[k] = a[k] - value
        }
        history.withUnsafeMutableBufferPointer { x in
            accumulator.withUnsafeMutableBufferPointer { z in
                for k in 0..<16 { x[k] = cosMod[j] * sum[k]; j += 1 }
                for k in 0..<16 { x[31 - k] = cosMod[j] * difference[k]; j += 1 }
                coefficients.withUnsafeBufferPointer { c in
                    for i in 0..<32 {
                        let k = 31 - i
                        var low = 0.0, high = 0.0
                        for j in stride(from: 0, to: 512, by: 64) {
                            low += c[i + j] * (x[i + j] - x[j + k])
                            high += c[32 + i + j] * (-x[i + j] - x[j + k])
                        }
                        z[i] += low
                        z[32 + i] += high
                    }
                }
                for i in 0..<32 { emit(i, z[i]) }
                for i in stride(from: 511, through: 32, by: -1) { x[i] = x[i - 32] }
                for i in 0..<32 {
                    z[i] = z[i + 32]
                    z[i + 32] = 0
                }
            }
        }
    }
}
