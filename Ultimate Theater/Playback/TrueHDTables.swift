//
//  TrueHDTables.swift
//  Ultimate Theater
//
//  Constant tables for the Dolby TrueHD / MLP decoder (TrueHDDecoder.swift).
//
//  The entropy codebooks and the noise table are not in Dolby's public high-level
//  bitstream description. They were transcribed from FFmpeg's libavcodec (mlp.c:
//  ff_mlp_huffman_tables; mlpdec.c: noise_table), which is licensed under the GNU
//  Lesser General Public License, version 2.1 or later. See THIRD_PARTY_NOTICES.md.
//  Sample-rate codes and channel assignments follow Dolby's document (tables 3, 7, 10, 11).
//

import Foundation

nonisolated enum TrueHDTables {
    /// The three residual codebooks as (code, length) pairs; codebook n decodes symbol
    /// index i, which the decoder recentres. All three share the codes beginning 00 and
    /// 01 and differ in the codes beginning 1. The longest code is 9 bits.
    static let huffmanCodes: [[(code: UInt16, length: UInt8)]] = [
        [   // Codebook 1: symbols -7 ... +10
            (0x01, 9), (0x01, 8), (0x01, 7), (0x01, 6), (0x01, 5), (0x01, 4), (0x01, 3),
            (0x04, 3), (0x05, 3), (0x06, 3), (0x07, 3),
            (0x03, 3), (0x05, 4), (0x09, 5), (0x11, 6), (0x21, 7), (0x41, 8), (0x81, 9),
        ],
        [   // Codebook 2: symbols -7 ... +8
            (0x01, 9), (0x01, 8), (0x01, 7), (0x01, 6), (0x01, 5), (0x01, 4), (0x01, 3),
            (0x02, 2), (0x03, 2),
            (0x03, 3), (0x05, 4), (0x09, 5), (0x11, 6), (0x21, 7), (0x41, 8), (0x81, 9),
        ],
        [   // Codebook 3: symbols -7 ... +7
            (0x01, 9), (0x01, 8), (0x01, 7), (0x01, 6), (0x01, 5), (0x01, 4), (0x01, 3),
            (0x01, 1),
            (0x03, 3), (0x05, 4), (0x09, 5), (0x11, 6), (0x21, 7), (0x41, 8), (0x81, 9),
        ],
    ]

    /// Width of the codebook lookup tables, in bits (the longest code).
    static let huffmanLookupBits = 9

    /// 512-entry lookup tables, one per codebook, indexed by the next 9 bits of the
    /// stream. Each entry is `symbol << 4 | length`; 0 marks an invalid code.
    static let huffmanLookup: [[UInt16]] = huffmanCodes.map { codes in
        var table = [UInt16](repeating: 0, count: 1 << huffmanLookupBits)
        for (symbol, entry) in codes.enumerated() {
            let shift = huffmanLookupBits - Int(entry.length)
            let first = Int(entry.code) << shift
            for index in first..<(first + (1 << shift)) {
                table[index] = UInt16(symbol) << 4 | UInt16(entry.length)
            }
        }
        return table
    }

    /// Pseudo-random values added to rematrixed samples in substreams whose restart
    /// sync word is 0x31EB (the TrueHD six- and eight-channel substreams).
    static let noise: [Int8] = [
         30,  51,  22,  54,   3,   7,  -4,  38,  14,  55,  46,  81,  22,  58,  -3,   2,
         52,  31,  -7,  51,  15,  44,  74,  30,  85, -17,  10,  33,  18,  80,  28,  62,
         10,  32,  23,  69,  72,  26,  35,  17,  73,  60,   8,  56,   2,   6,  -2,  -5,
         51,   4,  11,  50,  66,  76,  21,  44,  33,  47,   1,  26,  64,  48,  57,  40,
         38,  16, -10, -28,  92,  22, -18,  29, -10,   5, -13,  49,  19,  24,  70,  34,
         61,  48,  30,  14,  -6,  25,  58,  33,  42,  60,  67,  17,  54,  17,  22,  30,
         67,  44,  -9,  50, -11,  43,  40,  32,  59,  82,  13,  49, -14,  55,  60,  36,
         48,  49,  31,  47,  15,  12,   4,  65,   1,  23,  29,  39,  45,  -2,  84,  69,
          0,  72,  37,  57,  27,  41, -15, -16,  35,  31,  14,  61,  24,   0,  27,  24,
         16,  41,  55,  34,  53,   9,  56,  12,  25,  29,  53,   5,  20, -20,  -8,  20,
         13,  28,  -3,  78,  38,  16,  11,  62,  46,  29,  21,  24,  46,  65,  43, -23,
         89,  18,  74,  21,  38, -12,  19,  12, -19,   8,  15,  33,   4,  57,   9,  -8,
         36,  35,  26,  28,   7,  83,  63,  79,  75,  11,   3,  87,  37,  47,  34,  40,
         39,  19,  20,  42,  27,  34,  39,  77,  13,  42,  59,  64,  45,  -1,  32,  37,
         45,  -5,  53,  -6,   7,  36,  50,  23,   6,  32,   9, -21,  18,  71,  27,  52,
        -25,  31,  35,  42,  -1,  68,  63,  52,  26,  43,  66,  37,  41,  25,  40,  70,
    ]

    /// Speakers flagged by each bit of the 6- and 8-channel presentation channel
    /// assignments (Dolby tables 7 and 10), in bitstream order. Bit 4 means top side
    /// speakers instead of top front when bit 11 of the major sync `flags` is set (table 11).
    static let assignmentSpeakers: [[TrueHDDecoder.Speaker]] = [
        [.left, .right],                                // L/R
        [.center],                                      // C
        [.lfe],                                         // LFE
        [.leftSurround, .rightSurround],                // Ls/Rs
        [.topFrontLeft, .topFrontRight],                // Tfl/Tfr (or Tsl/Tsr)
        [.leftCenter, .rightCenter],                    // Lsc/Rsc
        [.leftRearSurround, .rightRearSurround],        // Lb/Rb
        [.centerSurround],                              // Cb
        [.topCenter],                                   // Tc
        [.leftSurroundDirect, .rightSurroundDirect],    // Lsd/Rsd
        [.leftWide, .rightWide],                        // Lw/Rw
        [.topFrontCenter],                              // Tfc
        [.lfe2],                                        // LFE2
    ]

    /// MLP (DVD-Audio) channel arrangements, in bitstream channel order: channel group 1
    /// followed by group 2. "S" (a single surround) is the rear centre speaker.
    static let mlpArrangements: [[TrueHDDecoder.Speaker]] = [
        [.center],
        [.left, .right],
        [.left, .right, .centerSurround],
        [.left, .right, .leftSurround, .rightSurround],
        [.left, .right, .lfe],
        [.left, .right, .lfe, .centerSurround],
        [.left, .right, .lfe, .leftSurround, .rightSurround],
        [.left, .right, .center],
        [.left, .right, .center, .centerSurround],
        [.left, .right, .center, .leftSurround, .rightSurround],
        [.left, .right, .center, .lfe],
        [.left, .right, .center, .lfe, .centerSurround],
        [.left, .right, .center, .lfe, .leftSurround, .rightSurround],
        [.left, .right, .center, .centerSurround],
        [.left, .right, .center, .leftSurround, .rightSurround],
        [.left, .right, .center, .lfe],
        [.left, .right, .center, .lfe, .centerSurround],
        [.left, .right, .center, .lfe, .leftSurround, .rightSurround],
        [.left, .right, .leftSurround, .rightSurround, .lfe],
        [.left, .right, .leftSurround, .rightSurround, .center],
        [.left, .right, .leftSurround, .rightSurround, .center, .lfe],
    ]

    /// MLP word lengths by quantization code (16, 20 or 24 bits; 0 = invalid).
    static let mlpWordLengths: [Int] = [16, 20, 24, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
}
