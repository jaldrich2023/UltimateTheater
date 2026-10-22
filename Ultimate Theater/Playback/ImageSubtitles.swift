//
//  ImageSubtitles.swift
//  Ultimate Theater
//
//  Bitmap subtitle decoders: Blu-ray PGS (HDMV presentation graphics) and DVD
//  subpictures (VobSub). Each produces images placed on the video plane.
//

import Foundation
import CoreGraphics

/// A subtitle image and where it sits, as fractions of the video picture.
nonisolated struct SubtitleBitmap: Hashable, @unchecked Sendable {
    let image: CGImage
    let frame: CGRect

    static func == (a: SubtitleBitmap, b: SubtitleBitmap) -> Bool {
        a.image === b.image && a.frame == b.frame
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(image))
        hasher.combine(frame.origin.x)
        hasher.combine(frame.origin.y)
    }
}

nonisolated enum ImageSubtitleEvent {
    /// Images to show from `start`; `end` is nil when a later event clears them.
    case show(start: Double, end: Double?, bitmaps: [SubtitleBitmap])
    case clear(at: Double)
}

nonisolated enum SubtitleImaging {
    /// An RGBA image from palette indices.
    static func image(width: Int, height: Int, indices: [UInt8], palette: [UInt32]) -> CGImage? {
        guard width > 0, height > 0, indices.count >= width * height else { return nil }
        var pixels = [UInt32](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let index = Int(indices[i])
            pixels[i] = index < palette.count ? palette[index] : 0
        }
        let data = pixels.withUnsafeBytes { Data($0) } as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Premultiplied RGBA packed for a big-endian 32-bit pixel.
    static func pixel(red: Double, green: Double, blue: Double, alpha: Double) -> UInt32 {
        func channel(_ value: Double) -> UInt32 { UInt32(max(0, min(255, (value * alpha).rounded()))) }
        let a = UInt32(max(0, min(255, (alpha * 255).rounded())))
        return (channel(red) << 24 | channel(green) << 16 | channel(blue) << 8 | a).bigEndian
    }
}

// MARK: - PGS

/// Decodes HDMV presentation graphics. Segments (PCS, WDS, PDS, ODS, END) may arrive one
/// per packet (transport streams) or several per packet (Matroska); a display set is
/// complete at its END segment.
nonisolated final class PGSDecoder {
    private struct Placement {
        let objectID: Int
        let x: Int
        let y: Int
        let crop: CGRect?
    }

    private struct Object {
        var width = 0
        var height = 0
        var data = Data()
    }

    private var planeWidth = 1920
    private var planeHeight = 1080
    private var palettes: [Int: [UInt32]] = [:]
    private var objects: [Int: Object] = [:]
    private var placements: [Placement] = []
    private var paletteID = 0
    private var compositionTime: Double?

    func decode(_ data: Data, pts: Double) -> [ImageSubtitleEvent] {
        var events: [ImageSubtitleEvent] = []
        let b = [UInt8](data)
        var i = 0
        while i + 3 <= b.count {
            // Elementary .sup streams prefix each segment with "PG" and two timestamps.
            if b[i] == 0x50, b[i + 1] == 0x47, i + 13 <= b.count { i += 10 }
            let type = b[i]
            let length = Int(b[i + 1]) << 8 | Int(b[i + 2])
            let start = i + 3
            guard start + length <= b.count else { break }
            let segment = Array(b[start..<(start + length)])
            switch type {
            case 0x16: readComposition(segment, pts: pts)
            case 0x14: readPalette(segment)
            case 0x15: readObject(segment)
            case 0x80:
                if let event = finishDisplaySet() { events.append(event) }
            default: break // Window definitions: placement comes from the composition.
            }
            i = start + length
        }
        return events
    }

    private func readComposition(_ s: [UInt8], pts: Double) {
        guard s.count >= 11 else { return }
        planeWidth = Int(s[0]) << 8 | Int(s[1])
        planeHeight = Int(s[2]) << 8 | Int(s[3])
        let state = s[7]
        if state & 0x80 != 0 { objects = [:] } // Epoch start: earlier objects are discarded.
        paletteID = Int(s[9])
        let count = Int(s[10])
        var at = 11
        placements = []
        for _ in 0..<count {
            guard at + 8 <= s.count else { break }
            let id = Int(s[at]) << 8 | Int(s[at + 1])
            let cropped = s[at + 3] & 0x80 != 0
            let x = Int(s[at + 4]) << 8 | Int(s[at + 5])
            let y = Int(s[at + 6]) << 8 | Int(s[at + 7])
            var crop: CGRect?
            at += 8
            if cropped, at + 8 <= s.count {
                crop = CGRect(x: Int(s[at]) << 8 | Int(s[at + 1]), y: Int(s[at + 2]) << 8 | Int(s[at + 3]),
                              width: Int(s[at + 4]) << 8 | Int(s[at + 5]), height: Int(s[at + 6]) << 8 | Int(s[at + 7]))
                at += 8
            }
            placements.append(Placement(objectID: id, x: x, y: y, crop: crop))
        }
        compositionTime = pts
    }

    private func readPalette(_ s: [UInt8]) {
        guard s.count >= 2 else { return }
        let id = Int(s[0])
        var palette = palettes[id] ?? [UInt32](repeating: 0, count: 256)
        let isHD = planeHeight >= 720
        var at = 2
        while at + 5 <= s.count {
            let y = (Double(s[at + 1]) - 16) * 255 / 219
            let cr = (Double(s[at + 2]) - 128) * 255 / 224
            let cb = (Double(s[at + 3]) - 128) * 255 / 224
            let alpha = Double(s[at + 4]) / 255
            let (r, g, b) = isHD
                ? (y + 1.5748 * cr, y - 0.1873 * cb - 0.4681 * cr, y + 1.8556 * cb)   // BT.709
                : (y + 1.402 * cr, y - 0.3441 * cb - 0.7141 * cr, y + 1.772 * cb)     // BT.601
            palette[Int(s[at])] = SubtitleImaging.pixel(red: r, green: g, blue: b, alpha: alpha)
            at += 5
        }
        palettes[id] = palette
    }

    private func readObject(_ s: [UInt8]) {
        guard s.count >= 4 else { return }
        let id = Int(s[0]) << 8 | Int(s[1])
        let sequence = s[3]
        var object = objects[id] ?? Object()
        if sequence & 0x80 != 0 { // First fragment: data length, then the size.
            guard s.count >= 11 else { return }
            object = Object(width: Int(s[7]) << 8 | Int(s[8]), height: Int(s[9]) << 8 | Int(s[10]), data: Data(s[11...]))
        } else {
            object.data.append(contentsOf: s[4...])
        }
        objects[id] = object
    }

    private func finishDisplaySet() -> ImageSubtitleEvent? {
        guard let time = compositionTime else { return nil }
        compositionTime = nil
        guard !placements.isEmpty else { return .clear(at: time) }
        let palette = palettes[paletteID] ?? []
        var bitmaps: [SubtitleBitmap] = []
        for placement in placements {
            guard let object = objects[placement.objectID], object.width > 0, object.height > 0,
                  let indices = Self.runLengthDecode(object.data, width: object.width, height: object.height),
                  var image = SubtitleImaging.image(width: object.width, height: object.height, indices: indices, palette: palette)
            else { continue }
            var origin = CGPoint(x: placement.x, y: placement.y)
            if let crop = placement.crop, let cropped = image.cropping(to: crop) {
                image = cropped
                origin = CGPoint(x: placement.x, y: placement.y)
            }
            bitmaps.append(SubtitleBitmap(image: image, frame: CGRect(
                x: origin.x / Double(planeWidth), y: origin.y / Double(planeHeight),
                width: Double(image.width) / Double(planeWidth), height: Double(image.height) / Double(planeHeight))))
        }
        return bitmaps.isEmpty ? .clear(at: time) : .show(start: time, end: nil, bitmaps: bitmaps)
    }

    /// PGS run-length coding: a nonzero byte is one pixel; 00 introduces a run or ends a line.
    static func runLengthDecode(_ data: Data, width: Int, height: Int) -> [UInt8]? {
        let b = [UInt8](data)
        var out = [UInt8](repeating: 0, count: width * height)
        var x = 0
        var y = 0
        var i = 0
        func put(_ color: UInt8, _ count: Int) {
            guard y < height else { return }
            let n = min(count, width - x)
            if n > 0 { for k in 0..<n { out[y * width + x + k] = color } }
            x += max(0, n)
        }
        while i < b.count, y < height {
            let first = b[i]; i += 1
            if first != 0 { put(first, 1); continue }
            guard i < b.count else { break }
            let flags = b[i]; i += 1
            if flags == 0 { x = 0; y += 1; continue } // End of line.
            var count = Int(flags & 0x3F)
            if flags & 0x40 != 0 { guard i < b.count else { break }; count = count << 8 | Int(b[i]); i += 1 }
            var color: UInt8 = 0
            if flags & 0x80 != 0 { guard i < b.count else { break }; color = b[i]; i += 1 }
            put(color, count)
        }
        return out
    }
}

// MARK: - VobSub

/// Decodes DVD subpicture units. The palette and picture size come from the `.idx` text
/// that Matroska stores as codec private data; DVD files without one use a neutral palette.
nonisolated struct VobSubDecoder {
    private var palette: [(r: Double, g: Double, b: Double)]
    private var planeWidth: Double
    private var planeHeight: Double

    init(codecPrivate: Data?, defaultSize: (width: Int, height: Int)) {
        planeWidth = Double(defaultSize.width)
        planeHeight = Double(defaultSize.height)
        // Neutral fallback: background, white text, black and gray edges.
        palette = (0..<16).map { index in
            let level: Double = [0, 255, 0, 128][index % 4]
            return (level, level, level)
        }
        guard let text = codecPrivate.map({ String(decoding: $0, as: UTF8.self) }) else { return }
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "size":
                let size = parts[1].split(separator: "x").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if size.count == 2, size[0] > 0, size[1] > 0 { planeWidth = size[0]; planeHeight = size[1] }
            case "palette":
                let colors = parts[1].split(separator: ",").compactMap { UInt32($0.trimmingCharacters(in: .whitespaces), radix: 16) }
                if colors.count == 16 {
                    palette = colors.map { (Double($0 >> 16 & 0xFF), Double($0 >> 8 & 0xFF), Double($0 & 0xFF)) }
                }
            default:
                break
            }
        }
    }

    /// One complete subpicture unit (SPU).
    func decode(_ data: Data, pts: Double) -> ImageSubtitleEvent? {
        let b = [UInt8](data)
        guard b.count >= 4 else { return nil }
        let size = Int(b[0]) << 8 | Int(b[1])
        let controlStart = Int(b[2]) << 8 | Int(b[3])
        guard size <= b.count, controlStart + 4 <= size else { return nil }
        var colors: [Int] = [0, 1, 2, 3]
        var alphas: [Double] = [0, 1, 1, 1]
        var area: (x1: Int, x2: Int, y1: Int, y2: Int)?
        var fields: (top: Int, bottom: Int)?
        var start: Double?
        var stop: Double?
        var sequence = controlStart
        var visited = Set<Int>()
        // Control sequences: a delay, the next sequence's offset, then commands.
        while sequence + 4 <= size, visited.insert(sequence).inserted {
            let delay = Double(Int(b[sequence]) << 8 | Int(b[sequence + 1])) * 1024 / 90000
            let next = Int(b[sequence + 2]) << 8 | Int(b[sequence + 3])
            var i = sequence + 4
            commands: while i < size {
                let command = b[i]; i += 1
                switch command {
                case 0x00, 0x01: start = start ?? delay
                case 0x02: stop = delay
                case 0x03:
                    guard i + 2 <= size else { break commands }
                    colors = [Int(b[i + 1] & 0x0F), Int(b[i + 1] >> 4), Int(b[i] & 0x0F), Int(b[i] >> 4)]
                    i += 2
                case 0x04:
                    guard i + 2 <= size else { break commands }
                    alphas = [b[i + 1] & 0x0F, b[i + 1] >> 4, b[i] & 0x0F, b[i] >> 4].map { Double($0) / 15 }
                    i += 2
                case 0x05:
                    guard i + 6 <= size else { break commands }
                    area = (Int(b[i]) << 4 | Int(b[i + 1]) >> 4, Int(b[i + 1] & 0x0F) << 8 | Int(b[i + 2]),
                            Int(b[i + 3]) << 4 | Int(b[i + 4]) >> 4, Int(b[i + 4] & 0x0F) << 8 | Int(b[i + 5]))
                    i += 6
                case 0x06:
                    guard i + 4 <= size else { break commands }
                    fields = (Int(b[i]) << 8 | Int(b[i + 1]), Int(b[i + 2]) << 8 | Int(b[i + 3]))
                    i += 4
                case 0x07:
                    guard i + 2 <= size else { break commands }
                    i += Int(b[i]) << 8 | Int(b[i + 1])
                default:
                    break commands // 0xFF ends the sequence.
                }
            }
            if next == sequence { break }
            sequence = next
        }
        guard let area, let fields, area.x2 >= area.x1, area.y2 >= area.y1 else {
            return stop.map { .clear(at: pts + $0) }
        }
        let width = area.x2 - area.x1 + 1
        let height = area.y2 - area.y1 + 1
        // Interlaced: even lines from the top field, odd lines from the bottom field.
        var indices = [UInt8](repeating: 0, count: width * height)
        for (parity, offset) in [(0, fields.top), (1, fields.bottom)] {
            var nibble = offset * 2
            func next() -> Int {
                guard nibble / 2 < controlStart else { return 0 }
                defer { nibble += 1 }
                return Int(nibble % 2 == 0 ? b[nibble / 2] >> 4 : b[nibble / 2] & 0x0F)
            }
            var row = parity
            while row < height {
                var x = 0
                while x < width {
                    var code = next()
                    if code < 0x4 { code = code << 4 | next()
                        if code < 0x10 { code = code << 4 | next()
                            if code < 0x40 { code = code << 4 | next() } } }
                    let count = code >> 2 == 0 ? width - x : min(code >> 2, width - x)
                    for k in 0..<count { indices[row * width + x + k] = UInt8(code & 3) }
                    x += count
                    if nibble / 2 >= controlStart { break }
                }
                if nibble % 2 != 0 { nibble += 1 } // Lines start on a byte boundary.
                row += 2
            }
        }
        let pixels: [UInt32] = (0..<4).map { slot in
            let color = palette[colors[slot] & 0x0F]
            return SubtitleImaging.pixel(red: color.r, green: color.g, blue: color.b, alpha: alphas[slot])
        }
        guard let image = SubtitleImaging.image(width: width, height: height, indices: indices, palette: pixels) else { return nil }
        let bitmap = SubtitleBitmap(image: image, frame: CGRect(
            x: Double(area.x1) / planeWidth, y: Double(area.y1) / planeHeight,
            width: Double(width) / planeWidth, height: Double(height) / planeHeight))
        return .show(start: pts + (start ?? 0), end: stop.map { pts + $0 }, bitmaps: [bitmap])
    }
}

// MARK: - DVB subtitles

/// Decodes DVB bitmap subtitles (ETSI EN 300 743): page and region compositions, color
/// tables, and run-length coded objects, shown as images on the display.
nonisolated final class DVBSubtitleDecoder {
    private struct Region {
        var width = 0
        var height = 0
        var depth = 4
        var clutID = 0
        var pixels: [UInt8] = []
        var objects: [(id: Int, x: Int, y: Int)] = []
    }

    private var displayWidth = 720
    private var displayHeight = 576
    private var pageTimeout = 0.0
    private var pageRegions: [(id: Int, x: Int, y: Int)] = []
    private var regions: [Int: Region] = [:]
    private var cluts: [Int: [UInt32]] = [:]
    private var pageStart: Double?

    func decode(_ data: Data, pts: Double) -> [ImageSubtitleEvent] {
        let b = [UInt8](data)
        // PES data: data_identifier 0x20, subtitle_stream_id 0x00, then segments.
        var i = b.count >= 2 && b[0] == 0x20 ? 2 : 0
        var events: [ImageSubtitleEvent] = []
        while i + 6 <= b.count, b[i] == 0x0F {
            let type = b[i + 1]
            let length = Int(b[i + 4]) << 8 | Int(b[i + 5])
            let start = i + 6
            guard start + length <= b.count else { break }
            let segment = Array(b[start..<(start + length)])
            switch type {
            case 0x10: pageComposition(segment, pts: pts)
            case 0x11: regionComposition(segment)
            case 0x12: colorTable(segment)
            case 0x13: objectData(segment)
            case 0x14 where segment.count >= 5:
                displayWidth = (Int(segment[1]) << 8 | Int(segment[2])) + 1
                displayHeight = (Int(segment[3]) << 8 | Int(segment[4])) + 1
            case 0x80: events += finish(pts: pts)
            default: break
            }
            i = start + length
        }
        return events
    }

    private func pageComposition(_ s: [UInt8], pts: Double) {
        guard s.count >= 2 else { return }
        pageTimeout = Double(s[0])
        let state = (s[1] >> 2) & 0x03
        if state != 0 { regions = [:] } // Acquisition point or mode change: a fresh page.
        pageRegions = stride(from: 2, to: s.count - 5, by: 6).map { at in
            (Int(s[at]), Int(s[at + 2]) << 8 | Int(s[at + 3]), Int(s[at + 4]) << 8 | Int(s[at + 5]))
        }
        pageStart = pts
    }

    private func regionComposition(_ s: [UInt8]) {
        guard s.count >= 10 else { return }
        let id = Int(s[0])
        let fill = s[1] & 0x08 != 0
        let width = Int(s[2]) << 8 | Int(s[3])
        let height = Int(s[4]) << 8 | Int(s[5])
        let depthCode = Int(s[6] >> 2 & 0x07) // 1 = 2-bit, 2 = 4-bit, 3 = 8-bit
        let depth = depthCode == 3 ? 8 : (depthCode == 2 ? 4 : 2)
        var region = regions[id] ?? Region()
        if region.width != width || region.height != height || region.pixels.isEmpty {
            region.pixels = [UInt8](repeating: 0, count: width * height)
        }
        region.width = width
        region.height = height
        region.depth = depth
        region.clutID = Int(s[7])
        if fill {
            let code: UInt8 = region.depth == 8 ? s[8] : (region.depth == 4 ? s[9] >> 4 : (s[9] >> 2) & 0x03)
            region.pixels = [UInt8](repeating: code, count: width * height)
        }
        var objects: [(Int, Int, Int)] = []
        var at = 10
        while at + 6 <= s.count {
            let objectID = Int(s[at]) << 8 | Int(s[at + 1])
            let type = s[at + 2] >> 6
            let x = Int(s[at + 2] & 0x0F) << 8 | Int(s[at + 3])
            let y = Int(s[at + 4] & 0x0F) << 8 | Int(s[at + 5])
            objects.append((objectID, x, y))
            at += type == 1 || type == 2 ? 8 : 6
        }
        region.objects = objects
        regions[id] = region
    }

    private func colorTable(_ s: [UInt8]) {
        guard s.count >= 2 else { return }
        let id = Int(s[0])
        var table = cluts[id] ?? Self.defaultTable
        var at = 2
        while at + 2 <= s.count {
            let entry = Int(s[at])
            let full = s[at + 1] & 0x01 != 0
            let y, cr, cb, t: Double
            if full {
                guard at + 6 <= s.count else { break }
                (y, cr, cb, t) = (Double(s[at + 2]), Double(s[at + 3]), Double(s[at + 4]), Double(s[at + 5]))
                at += 6
            } else {
                guard at + 4 <= s.count else { break }
                let packed = Int(s[at + 2]) << 8 | Int(s[at + 3])
                (y, cr, cb, t) = (Double(packed >> 10 & 0x3F) * 4, Double(packed >> 6 & 0x0F) * 16, Double(packed >> 2 & 0x0F) * 16, Double(packed & 0x03) * 64)
                at += 4
            }
            guard entry < table.count else { continue }
            // Y = 0 means fully transparent; T is transparency (0 = opaque).
            let alpha = y == 0 ? 0 : (255 - t) / 255
            let r = y + 1.402 * (cr - 128), g = y - 0.344 * (cb - 128) - 0.714 * (cr - 128), bl = y + 1.772 * (cb - 128)
            table[entry] = SubtitleImaging.pixel(red: r, green: g, blue: bl, alpha: alpha)
        }
        cluts[id] = table
    }

    /// Default colors: entry 0 transparent, then white, black, and grays.
    private static let defaultTable: [UInt32] = (0..<256).map { index -> UInt32 in
        switch index {
        case 0: return 0
        case 1: return SubtitleImaging.pixel(red: 255, green: 255, blue: 255, alpha: 1)
        case 2: return SubtitleImaging.pixel(red: 0, green: 0, blue: 0, alpha: 1)
        default:
            let level = Double(index % 16) * 17
            return SubtitleImaging.pixel(red: level, green: level, blue: level, alpha: 1)
        }
    }

    private func objectData(_ s: [UInt8]) {
        guard s.count >= 7 else { return }
        let id = Int(s[0]) << 8 | Int(s[1])
        guard (s[2] >> 2) & 0x03 == 0 else { return } // Only pixel-coded objects (not character strings).
        let topLength = Int(s[3]) << 8 | Int(s[4])
        let bottomLength = Int(s[5]) << 8 | Int(s[6])
        guard 7 + topLength + bottomLength <= s.count else { return }
        let top = Array(s[7..<(7 + topLength)])
        let bottom = bottomLength > 0 ? Array(s[(7 + topLength)..<(7 + topLength + bottomLength)]) : top
        for (regionID, var region) in regions {
            for placement in region.objects where placement.id == id {
                draw(top, into: &region, x: placement.x, y: placement.y)
                draw(bottom, into: &region, x: placement.x, y: placement.y + 1)
            }
            regions[regionID] = region
        }
    }

    /// Decodes one field's pixel data (every other line) into a region.
    private func draw(_ data: [UInt8], into region: inout Region, x: Int, y startY: Int) {
        var r = BitCursor(data)
        var px = x
        var py = startY
        var map2to4: [UInt8] = [0, 7, 8, 15]
        var map2to8: [UInt8] = [0, 0x77, 0x88, 0xFF]
        var map4to8: [UInt8] = (0..<16).map { UInt8($0 * 17) }
        func put(_ code: UInt8, _ count: Int, bits: Int) {
            let value: UInt8
            switch (bits, region.depth) {
            case (2, 4): value = map2to4[Int(code)]
            case (2, 8): value = map2to8[Int(code)]
            case (4, 8): value = map4to8[Int(code)]
            default: value = code
            }
            guard py >= 0, py < region.height else { px += count; return }
            for _ in 0..<count where px < region.width {
                region.pixels[py * region.width + px] = value
                px += 1
            }
        }
        while let type = r.read(8) {
            switch type {
            case 0x10: // 2-bit/pixel code string
                while true {
                    guard let code = r.read(2) else { break }
                    if code != 0 { put(UInt8(code), 1, bits: 2); continue }
                    if r.read(1) == 1 { let run = (r.read(3) ?? 0) + 3; put(UInt8(r.read(2) ?? 0), run, bits: 2); continue }
                    if r.read(1) == 1 { put(0, 1, bits: 2); continue }
                    let s3 = r.read(2) ?? 0
                    if s3 == 0 { break }
                    if s3 == 1 { put(0, 2, bits: 2) }
                    else if s3 == 2 { let run = (r.read(4) ?? 0) + 12; put(UInt8(r.read(2) ?? 0), run, bits: 2) }
                    else { let run = (r.read(8) ?? 0) + 29; put(UInt8(r.read(2) ?? 0), run, bits: 2) }
                }
                r.skip((8 - r.position % 8) % 8)
            case 0x11: // 4-bit/pixel code string
                while true {
                    guard let code = r.read(4) else { break }
                    if code != 0 { put(UInt8(code), 1, bits: 4); continue }
                    if r.read(1) == 0 {
                        let run = r.read(3) ?? 0
                        if run == 0 { break }
                        put(0, run + 2, bits: 4)
                    } else if r.read(1) == 0 {
                        let run = (r.read(2) ?? 0) + 4
                        put(UInt8(r.read(4) ?? 0), run, bits: 4)
                    } else {
                        switch r.read(2) ?? 0 {
                        case 0: put(0, 1, bits: 4)
                        case 1: put(0, 2, bits: 4)
                        case 2: let run = (r.read(4) ?? 0) + 9; put(UInt8(r.read(4) ?? 0), run, bits: 4)
                        default: let run = (r.read(8) ?? 0) + 25; put(UInt8(r.read(4) ?? 0), run, bits: 4)
                        }
                    }
                }
                r.skip((8 - r.position % 8) % 8)
            case 0x12: // 8-bit/pixel code string
                while true {
                    guard let code = r.read(8) else { break }
                    if code != 0 { put(UInt8(code), 1, bits: 8); continue }
                    if r.read(1) == 0 {
                        let run = r.read(7) ?? 0
                        if run == 0 { break }
                        put(0, run, bits: 8)
                    } else {
                        let run = r.read(7) ?? 0
                        put(UInt8(r.read(8) ?? 0), run, bits: 8)
                    }
                }
            case 0x20: map2to4 = (0..<4).map { _ in UInt8(r.read(4) ?? 0) }
            case 0x21: map2to8 = (0..<4).map { _ in UInt8(r.read(8) ?? 0) }
            case 0x22: map4to8 = (0..<16).map { _ in UInt8(r.read(8) ?? 0) }
            case 0xF0: // End of line: fields interleave, so the next line is two down.
                px = x
                py += 2
            default:
                return
            }
        }
    }

    private func finish(pts: Double) -> [ImageSubtitleEvent] {
        let start = pageStart ?? pts
        var bitmaps: [SubtitleBitmap] = []
        for placement in pageRegions {
            guard let region = regions[placement.id], region.width > 0, region.height > 0,
                  region.pixels.contains(where: { $0 != 0 }) else { continue }
            let table = cluts[region.clutID] ?? Self.defaultTable
            guard let image = SubtitleImaging.image(width: region.width, height: region.height, indices: region.pixels, palette: table) else { continue }
            bitmaps.append(SubtitleBitmap(image: image, frame: CGRect(
                x: Double(placement.x) / Double(displayWidth), y: Double(placement.y) / Double(displayHeight),
                width: Double(region.width) / Double(displayWidth), height: Double(region.height) / Double(displayHeight))))
        }
        guard !bitmaps.isEmpty else { return [.clear(at: start)] }
        return [.show(start: start, end: pageTimeout > 0 ? start + pageTimeout : nil, bitmaps: bitmaps)]
    }
}
