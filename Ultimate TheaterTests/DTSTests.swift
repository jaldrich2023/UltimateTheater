//
//  DTSTests.swift
//  Ultimate TheaterTests
//
//  The DTS core decoder: codebooks, framing in every word packing, and frames built
//  bit by bit from the specification's syntax tables.
//

import Testing
import Foundation
@testable import Ultimate_Theater

struct DTSTests {
    /// A stereo frame: one subframe of one subsubframe (256 samples), two subbands, with
    /// subband 0 carried as plain 8-bit samples (ABITS 11) and subband 1 silent.
    static func stereoFrame(samples: [Int], dsync: Int = 0xFFFF) -> Data {
        var bits = BitWriter()
        // Bit stream header (Table 5-1).
        bits.write(0x7FFE_8001, bits: 32)
        bits.write(1, bits: 1); bits.write(31, bits: 5)          // FTYPE normal, SHORT
        bits.write(0, bits: 1)                                   // CPF
        bits.write(7, bits: 7)                                   // NBLKS: 8 blocks of 32 samples
        let sizeOffset = 46
        bits.write(0, bits: 14)                                  // FSIZE, patched below
        bits.write(2, bits: 6)                                   // AMODE: L + R
        bits.write(13, bits: 4)                                  // SFREQ: 48 kHz
        bits.write(15, bits: 5)                                  // RATE: 768 kbit/s
        bits.write(0, bits: 1 + 1 + 1 + 1 + 1 + 3 + 1 + 1)       // FixedBit … ASPF
        bits.write(0, bits: 2)                                   // LFF: no LFE
        bits.write(0, bits: 1)                                   // HFLAG
        bits.write(1, bits: 1)                                   // FILTS: perfect reconstruction
        bits.write(7, bits: 4); bits.write(0, bits: 2 + 3 + 1 + 1 + 4)
        // Primary audio coding header (Table 5-21).
        bits.write(0, bits: 4)                                   // SUBFS: 1 subframe
        bits.write(1, bits: 3)                                   // PCHS: 2 channels
        for _ in 0..<2 { bits.write(0, bits: 5) }                // SUBS: 2 subbands
        for _ in 0..<2 { bits.write(1, bits: 5) }                // VQSUB: none (starts at 2)
        for _ in 0..<2 { bits.write(0, bits: 3) }                // JOINX
        for _ in 0..<2 { bits.write(0, bits: 2) }                // THUFF
        for _ in 0..<2 { bits.write(6, bits: 3) }                // SHUFF: 7-bit linear
        for _ in 0..<2 { bits.write(6, bits: 3) }                // BHUFF: 5-bit linear
        for _ in 0..<2 { bits.write(1, bits: 1) }                // SEL, ABITS 1: block code (no ADJ)
        for _ in 1..<5 { for _ in 0..<2 { bits.write(3, bits: 2) } }
        for _ in 5..<10 { for _ in 0..<2 { bits.write(7, bits: 3) } }
        // Side information (Table 5-28).
        bits.write(0, bits: 2); bits.write(0, bits: 3)           // SSC, PSC
        for _ in 0..<4 { bits.write(0, bits: 1) }                // PMODE
        for _ in 0..<2 { bits.write(11, bits: 5); bits.write(0, bits: 5) } // ABITS
        for _ in 0..<2 { bits.write(80, bits: 7) }               // SCALES for subband 0
        // Audio data (Table 5-29): 8 plain 8-bit samples per channel, then DSYNC.
        for _ in 0..<2 { for value in samples { bits.write(value & 0xFF, bits: 8) } }
        bits.write(dsync, bits: 16)
        var bytes = bits.bytes
        while bytes.count < 96 { bytes.append(0) }
        let size = bytes.count - 1
        var patched = BitWriter()
        var reader = DTSBitReader(Data(bytes))
        while reader.bitsLeft > 0 {
            if reader.position == sizeOffset { patched.write(size, bits: 14); reader.skip(14) } else { patched.writeBit(reader.readBit()) }
        }
        return Data(patched.bytes)
    }

    @Test func everyCodebookDecodesItsOwnCodes() throws {
        let books: [[Int32]] = [DTSTables.huffmanA3, DTSTables.huffmanD4, DTSTables.huffmanE12, DTSTables.huffmanC13,
                                DTSTables.huffmanG17, DTSTables.huffmanD25, DTSTables.huffmanF33, DTSTables.huffmanD65,
                                DTSTables.huffmanSE129, DTSTables.huffmanD129]
        for triples in books {
            let book = DTSHuffmanBook(triples)
            var kraft = 0.0
            for index in stride(from: 0, to: triples.count, by: 3) {
                var bits = BitWriter()
                bits.write(Int(triples[index + 2]), bits: Int(triples[index + 1]))
                var reader = DTSBitReader(Data(bits.bytes))
                #expect(book.decode(&reader) == Int(triples[index]))
                #expect(reader.position == Int(triples[index + 1]))
                kraft += pow(2, -Double(triples[index + 1]))
            }
            #expect(abs(kraft - 1) < 1e-9) // Complete prefix codes.
        }
    }

    @Test func decodesASyntheticStereoFrame() throws {
        let frame = Self.stereoFrame(samples: [40, -40, 90, -90, 120, -120, 60, -60])
        let decoder = DTSCoreDecoder()
        let output = try #require(decoder.decode(frame))
        #expect(output.frameCount == 256)
        #expect(output.sampleRate == 48000)
        #expect(output.channels == [.left, .right])
        #expect(decoder.damagedFrames == 0)
        let left = stride(from: 0, to: output.samples.count, by: 2).map { output.samples[$0] }
        let right = stride(from: 1, to: output.samples.count, by: 2).map { output.samples[$0] }
        #expect(left == right)
        #expect((left.map(abs).max() ?? 0) > 0.001)
        #expect(output.samples.allSatisfy { $0.isFinite && abs($0) < 1 })
    }

    @Test func damagedFrameBecomesSilenceOfTheSameLength() throws {
        let frame = Self.stereoFrame(samples: [40, -40, 90, -90, 120, -120, 60, -60], dsync: 0x1234)
        let decoder = DTSCoreDecoder()
        let output = try #require(decoder.decode(frame))
        #expect(output.frameCount == 256)
        #expect(decoder.damagedFrames == 1)
        #expect(output.samples.allSatisfy { $0 == 0 })
    }

    @Test(arguments: [DTSFramer.Packing.big16, .little16, .big14, .little14])
    func framerReadsEveryWordPacking(_ packing: DTSFramer.Packing) throws {
        let frame = Self.stereoFrame(samples: [1, 2, 3, 4, 5, 6, 7, 8])
        let wire = Self.pack(frame, as: packing)
        var stream = Data([0x00, 0x11, 0x22])  // Leading junk before the first sync.
        stream.append(wire); stream.append(wire)
        var framer = DTSFramer()
        var frames: [Data] = []
        // Arrive in small pieces, as a byte stream from AVI or MPEG would.
        for start in stride(from: 0, to: stream.count, by: 37) {
            frames += framer.push(stream.subdata(in: start..<min(stream.count, start + 37)))
        }
        #expect(frames.count == 2)
        for found in frames { #expect(found.prefix(frame.count) == frame) }
    }

    static func pack(_ frame: Data, as packing: DTSFramer.Packing) -> Data {
        var words: [UInt16] = []
        switch packing {
        case .big16, .little16:
            for index in stride(from: 0, to: frame.count, by: 2) {
                words.append(UInt16(frame[index]) << 8 | UInt16(index + 1 < frame.count ? frame[index + 1] : 0))
            }
        case .big14, .little14:
            var reader = DTSBitReader(frame)
            while reader.bitsLeft > 0 {
                let value = UInt16(reader.read(14))
                // Sign-extend bit 13 into the two spare bits, as 14-bit streams do.
                words.append(value & 0x2000 != 0 ? value | 0xC000 : value)
            }
        }
        let littleEndian = packing == .little16 || packing == .little14
        return Data(words.flatMap { littleEndian ? [UInt8($0 & 0xFF), UInt8($0 >> 8)] : [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
    }

    @Test func dtsTracksAreDecodable() {
        #expect(MatroskaDemuxer.codec(for: "A_DTS", kind: .audio) == .dts)
        #expect(AVIDemuxer.audioCodec(0x2001, bits: 16) == .dts)
        #expect(MediaCodec.dts.isSupported)
    }
}
