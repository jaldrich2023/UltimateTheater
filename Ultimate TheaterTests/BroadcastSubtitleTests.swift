//
//  BroadcastSubtitleTests.swift
//  Ultimate TheaterTests
//
//  DVB bitmap subtitles and Teletext subtitles encoded by hand following their specs
//  (ETSI EN 300 743 and EN 300 706) and decoded again.
//

import Testing
import Foundation
import CoreGraphics
@testable import Ultimate_Theater

struct BroadcastSubtitleTests {
    private func segment(_ type: UInt8, _ body: [UInt8]) -> [UInt8] {
        [0x0F, type, 0x00, 0x01, UInt8(body.count >> 8), UInt8(body.count & 0xFF)] + body
    }

    @Test func dvbPageBecomesAPositionedImage() throws {
        let page = segment(0x10, [5, 0x08, 0, 0, 0, 100, 0x01, 0x90])                 // region 0 at (100, 400), 5 s
        let region = segment(0x11, [0, 0x08, 0, 8, 0, 2, 0x48, 0, 0, 0,             // 8×2, 4-bit, CLUT 0
                                    0, 0, 0x00, 0x00, 0x00, 0x00])                   // object 0 at (0, 0)
        let clut = segment(0x12, [0, 0, 1, 0x41, 235, 128, 128, 0])                  // entry 1: white, opaque
        let pixels: [UInt8] = [0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11]          // won't all fit: 16 codes of 1
        let line: [UInt8] = [0x11] + Array(pixels.prefix(4)) + [0x00, 0xF0]          // 8 pixels of color 1, end, end of line
        let object = segment(0x13, [0, 0, 0x00, 0, UInt8(line.count), 0, 0] + line)   // bottom field repeats the top
        let payload = Data([0x20, 0x00] + page + region + clut + object + segment(0x80, []) + [0xFF])

        let events = DVBSubtitleDecoder().decode(payload, pts: 42)
        guard case .show(let start, let end, let bitmaps)? = events.first else {
            Issue.record("Expected a subtitle")
            return
        }
        #expect(start == 42 && end == 47)
        let bitmap = try #require(bitmaps.first)
        #expect(bitmap.image.width == 8 && bitmap.image.height == 2)
        #expect(abs(bitmap.frame.minX - 100.0 / 720) < 1e-9 && abs(bitmap.frame.minY - 400.0 / 576) < 1e-9)
        let data = try #require(bitmap.image.dataProvider?.data as Data?)
        #expect(Array(data[0..<4]) == [235, 235, 235, 255])
        #expect(Array(data[(bitmap.image.bytesPerRow)..<(bitmap.image.bytesPerRow + 4)]) == [235, 235, 235, 255])

        // A page with no regions clears the screen.
        let clear = Data([0x20, 0x00] + segment(0x10, [5, 0x00]) + segment(0x80, []))
        guard case .clear(let time)? = DVBSubtitleDecoder().decode(clear, pts: 50).first else {
            Issue.record("Expected a clear")
            return
        }
        #expect(time == 50)
    }

    // Teletext encoding helpers.
    private func hamming(_ value: Int) -> UInt8 {
        let d = (0..<4).map { (value >> $0) & 1 }
        let p1 = 1 ^ d[0] ^ d[2] ^ d[3]
        let p2 = 1 ^ d[0] ^ d[1] ^ d[3]
        let p3 = 1 ^ d[0] ^ d[1] ^ d[2]
        var byte = p1 | d[0] << 1 | p2 << 2 | d[1] << 3 | p3 << 4 | d[2] << 5 | d[3] << 7
        let ones = (0..<8).reduce(0) { $0 + (byte >> $1) & 1 }
        if ones % 2 == 0 { byte |= 1 << 6 }
        return UInt8(byte)
    }

    private func parity(_ character: Character) -> UInt8 {
        let value = UInt8(character.asciiValue ?? 0x20)
        return value.nonzeroBitCount % 2 == 0 ? value | 0x80 : value
    }

    private func unit(row: Int, body: [UInt8]) -> [UInt8] {
        let address = [hamming(0 | (row & 1) << 3), hamming(row >> 1)] // Magazine 8 is sent as 0.
        let bytes = [0x02, 0xE4] + address + body + [UInt8](repeating: parity(" "), count: max(0, 40 - body.count))
        return [0x02, 44] + bytes.prefix(44).map(TeletextDecoder.reversed)
    }

    private func header(page: Int) -> [UInt8] {
        unit(row: 0, body: [hamming(page & 0x0F), hamming(page >> 4)] + [UInt8](repeating: hamming(0), count: 6))
    }

    private func text(row: Int, _ string: String) -> [UInt8] {
        unit(row: row, body: Array(repeating: parity(" "), count: 4) + string.map(parity))
    }

    @Test func teletextPageBecomesTextCues() {
        #expect((0..<16).allSatisfy { TeletextDecoder.hamming(hamming($0)) == $0 })
        // One bit error is corrected.
        #expect(TeletextDecoder.hamming(hamming(9) ^ 0x02) == 9)

        let decoder = TeletextDecoder(magazine: 8, page: 0x88)
        let first = Data([0x10] + header(page: 0x88) + text(row: 21, "Where are you going?") + text(row: 22, "Home."))
        #expect(decoder.decode(first, pts: 10).isEmpty) // The page isn't finished until it's sent again.
        let next = Data([0x10] + header(page: 0x88) + text(row: 22, "Good night."))
        let cues = decoder.decode(next, pts: 13.5)
        #expect(cues.count == 1)
        #expect(cues.first?.start == 10 && cues.first?.end == 13.5)
        #expect(cues.first?.text == "Where are you going?\nHome.")
    }
}
