//
//  BroadcastFormatTests.swift
//  Ultimate TheaterTests
//
//  Broadcast and disc framings built from known data and unwrapped again: AAC in
//  LOAS/LATM, Opus in MPEG-TS, DVD LPCM, DVD IFO palettes, and the Dolby Digital core
//  inside Blu-ray TrueHD.
//

import Testing
import Foundation
@testable import Ultimate_Theater

struct BroadcastFormatTests {
    @Test func latmCarriesConfigurationAndFrames() async throws {
        let media = try await Fixtures.encode()
        let config = [UInt8](media.audioSpecificConfig)
        let frames = Array(media.aac.prefix(6))
        var stream = Data()
        for (index, frame) in frames.enumerated() {
            var bits = BitWriter()
            bits.write(index == 0 ? 0 : 1, bits: 1) // useSameStreamMux: the first frame carries the config.
            if index == 0 {
                bits.write(0, bits: 1)   // audioMuxVersion
                bits.write(1, bits: 1)   // allStreamsSameTimeFraming
                bits.write(0, bits: 6)   // numSubFrames
                bits.write(0, bits: 4)   // numProgram
                bits.write(0, bits: 3)   // numLayer
                for byte in config { bits.write(Int(byte), bits: 8) } // AudioSpecificConfig (AAC-LC: 16 bits)
                bits.write(0, bits: 3)   // frameLengthType
                bits.write(0xFF, bits: 8) // latmBufferFullness
                bits.write(0, bits: 1)   // otherDataPresent
                bits.write(0, bits: 1)   // crcCheckPresent
            }
            var length = frame.count
            while length >= 255 { bits.write(255, bits: 8); length -= 255 }
            bits.write(length, bits: 8)
            for byte in frame { bits.write(Int(byte), bits: 8) }
            let element = bits.bytes
            stream.append(contentsOf: [0x56, 0xE0 | UInt8(element.count >> 8), UInt8(element.count & 0xFF)] + element)
        }
        var parser = LATMParser()
        // Fed in two pieces, as PES payloads would arrive.
        let half = stream.count / 2
        let parsed = parser.frames(in: stream.prefix(half)) + parser.frames(in: stream.dropFirst(half))
        #expect(parsed == frames)
        #expect(parser.audioSpecificConfig == media.audioSpecificConfig)
        #expect(parser.sampleRate == media.sampleRate && parser.channels == media.channels)
    }

    @Test func opusInTransportStreamsIsUnwrapped() {
        let packets = [Data([0xFC, 1, 2, 3]), Data(repeating: 0x42, count: 300), Data([0x78])]
        var payload = Data()
        for (index, packet) in packets.enumerated() {
            let trims = index == 0
            payload.append(contentsOf: [0x7F, 0xE0 | (trims ? 0x10 : 0)])
            var size = packet.count
            while size >= 255 { payload.append(255); size -= 255 }
            payload.append(UInt8(size))
            if trims { payload.append(contentsOf: [0, 0x38]) } // 56-sample start trim
            payload.append(packet)
        }
        #expect(OpusTS.packets(in: payload) == packets)
    }

    @Test func dvdLPCMGroupsBecomePlainPCM() {
        // One 24-bit stereo group: L0 R0 L1 R1 high words, then their low bytes.
        let group: [UInt8] = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0xA1, 0xA2, 0xA3, 0xA4]
        var remainder = Data()
        let out = DVDLPCM.convert(Data(group + [0x99]), bits: 24, channels: 2, remainder: &remainder)
        #expect(out == Data([0x11, 0x22, 0xA1, 0x33, 0x44, 0xA2, 0x55, 0x66, 0xA3, 0x77, 0x88, 0xA4]))
        #expect(remainder == Data([0x99]))
    }

    @Test func dvdIFOSuppliesPaletteAndLanguages() throws {
        var ifo = [UInt8](repeating: 0, count: 4096 + 2048)
        ifo.replaceSubrange(0..<12, with: Array("DVDVIDEO-VTS".utf8))
        ifo[0x200] = 0x10                        // PAL
        ifo[0x203] = 2                           // two audio streams
        ifo.replaceSubrange(0x206..<0x208, with: Array("en".utf8))
        ifo.replaceSubrange(0x20E..<0x210, with: Array("fr".utf8))
        ifo[0x255] = 1                           // one subtitle stream
        ifo.replaceSubrange(0x258..<0x25A, with: Array("de".utf8))
        ifo[0xCF] = 2                            // program chains at sector 2
        let pgcit = 2 * 2048
        ifo[pgcit + 1] = 1                       // one program chain
        ifo[pgcit + 15] = 16                     // at offset 16
        let palette = pgcit + 16 + 0xA4
        ifo.replaceSubrange((palette + 4)..<(palette + 8), with: [0, 235, 128, 128]) // entry 1: white
        let info = try #require(DVDTitleSetInfo(ifo: Data(ifo)))
        #expect(info.audioLanguages == ["en", "fr"])
        #expect(info.subtitleLanguages == ["de"])
        #expect(info.pictureSize.height == 576)
        #expect(info.palette[1] == 0xEBEBEB)
        let setup = String(decoding: try #require(info.subtitleSetup), as: UTF8.self)
        #expect(setup.hasPrefix("size: 720x576"))
    }

    @Test func trueHDCoreKeepsOnlyIntactDolbyDigitalFrames() {
        // An AC-3 frame (48 kHz, frmsizecod 8 → 128 words) whose CRC checks out.
        var frame = [UInt8](repeating: 0x5A, count: 256)
        frame[0] = 0x0B; frame[1] = 0x77; frame[4] = 0x08; frame[5] = 8 << 3
        let crc = AC3.crc16(frame[2..<254])
        frame[254] = UInt8(crc >> 8); frame[255] = UInt8(crc & 0xFF)
        #expect(AC3.isIntact(frame))
        // TrueHD data with a false sync word before and after the real frame.
        let junk: [UInt8] = [0xF8, 0x72, 0x6F, 0xBA, 0x0B, 0x77, 0x00, 0x00, 0x08, 0x40] + [UInt8](repeating: 0x13, count: 300)
        var framer = AudioFramer(codec: .ac3, verifiesFrames: true)
        let found = framer.push(Data(junk + frame + junk + frame))
        #expect(found == [Data(frame), Data(frame)])
    }
}
