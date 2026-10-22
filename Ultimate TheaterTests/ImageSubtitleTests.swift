//
//  ImageSubtitleTests.swift
//  Ultimate TheaterTests
//
//  PGS and DVD subpicture decoding from hand-built display sets with known pixels.
//

import Testing
import Foundation
import CoreGraphics
@testable import Ultimate_Theater

struct ImageSubtitleTests {
    /// RGBA bytes of one pixel.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        guard let data = image.dataProvider?.data as Data? else { return [] }
        let at = y * image.bytesPerRow + x * 4
        return Array(data[at..<(at + 4)])
    }

    private func segment(_ type: UInt8, _ body: [UInt8]) -> [UInt8] {
        [type, UInt8(body.count >> 8), UInt8(body.count & 0xFF)] + body
    }

    @Test func pgsDisplaySetsShowAndClear() throws {
        let composition = segment(0x16, [0x07, 0x80, 0x04, 0x38, 0x10, 0, 1, 0x80, 0, 0, 1,
                                         0, 0, 0, 0, 0, 100, 0x03, 0x84])           // object 0 at (100, 900)
        let palette = segment(0x14, [0, 0, 1, 235, 128, 128, 255, 2, 16, 128, 128, 255]) // 1 = white, 2 = black
        // 4×2 object: two white pixels and a run of two black ones, then a transparent row.
        let rle: [UInt8] = [1, 1, 0, 0x82, 2, 0, 0, 0, 0x04, 0, 0]
        let object = segment(0x15, [0, 0, 0, 0xC0, 0, 0, UInt8(rle.count + 4), 0, 4, 0, 2] + rle)
        let decoder = PGSDecoder()
        let events = decoder.decode(Data(composition + palette + object + segment(0x80, [])), pts: 12.5)
        guard case .show(let start, let end, let bitmaps)? = events.first else {
            Issue.record("Expected a display set")
            return
        }
        #expect(start == 12.5 && end == nil && bitmaps.count == 1)
        let bitmap = try #require(bitmaps.first)
        #expect(bitmap.image.width == 4 && bitmap.image.height == 2)
        #expect(abs(bitmap.frame.minX - 100.0 / 1920) < 1e-9 && abs(bitmap.frame.minY - 900.0 / 1080) < 1e-9)
        #expect(pixel(bitmap.image, 0, 0) == [255, 255, 255, 255])
        #expect(pixel(bitmap.image, 2, 0) == [0, 0, 0, 255])
        #expect(pixel(bitmap.image, 1, 1)[3] == 0)

        // A composition with no objects clears the screen.
        let clearing = segment(0x16, [0x07, 0x80, 0x04, 0x38, 0x10, 0, 2, 0x00, 0, 0, 0])
        let cleared = decoder.decode(Data(clearing + segment(0x80, [])), pts: 15)
        guard case .clear(let time)? = cleared.first else {
            Issue.record("Expected a clear")
            return
        }
        #expect(time == 15)
    }

    @Test func dvdSubpictureDecodesInterlacedFields() throws {
        let controls: [UInt8] = [
            0, 0, 0, 30,                       // delay 0, next sequence at 30
            0x01,                              // start display
            0x03, 0x32, 0x10,                  // colors: background 0, pattern 1, emphasis 2 and 3
            0x04, 0xFF, 0xF0,                  // contrast: transparent background
            0x05, 0x00, 0xA0, 0x0D, 0x01, 0x40, 0x15, // x 10…13, y 20…21
            0x06, 0, 4, 0, 5,                  // top field at 4, bottom at 5
            0xFF,
            0, 90, 0, 30, 0x02, 0xFF,          // after 90 ticks (1.024 s): stop display
        ]
        let unit: [UInt8] = [0, 36, 0, 6, 0x11, 0x12] + controls
        let idx = "size: 720x480\npalette: 000000, ffffff, ff0000, 00ff00, 0000ff, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0\n"
        let decoder = VobSubDecoder(codecPrivate: Data(idx.utf8), defaultSize: (720, 576))
        guard case .show(let start, let end, let bitmaps)? = decoder.decode(Data(unit), pts: 30) else {
            Issue.record("Expected a subpicture")
            return
        }
        #expect(start == 30 && abs((end ?? 0) - 31.024) < 1e-9)
        let bitmap = try #require(bitmaps.first)
        #expect(bitmap.image.width == 4 && bitmap.image.height == 2)
        #expect(abs(bitmap.frame.minX - 10.0 / 720) < 1e-9 && abs(bitmap.frame.minY - 20.0 / 480) < 1e-9)
        #expect(pixel(bitmap.image, 3, 0) == [255, 255, 255, 255]) // Top field: pattern (white)
        #expect(pixel(bitmap.image, 0, 1) == [255, 0, 0, 255])     // Bottom field: emphasis 1 (red)
    }
}
