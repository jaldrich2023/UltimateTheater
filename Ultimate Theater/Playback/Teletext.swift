//
//  Teletext.swift
//  Ultimate Theater
//
//  Teletext subtitles (ETSI EN 300 706) as carried in DVB transport streams (EN 300 472):
//  data units of 44 bytes, Hamming-protected addresses, and odd-parity text rows. The
//  subtitle page's rows become text cues.
//

import Foundation

nonisolated final class TeletextDecoder {
    /// The subtitle page to follow: magazine (1–8) and page number (BCD, e.g. 0x88 for 888).
    let magazine: Int
    let page: Int

    private var rows: [Int: String] = [:]
    private var pageStart: Double?
    private var collecting = false

    init(magazine: Int, page: Int) {
        self.magazine = magazine
        self.page = page
    }

    /// The page described by a teletext descriptor entry, as two bytes (magazine, page).
    static func page(fromSetup data: Data?) -> (magazine: Int, page: Int) {
        guard let data, data.count >= 2 else { return (8, 0x88) }
        return (Int(data[data.startIndex]), Int(data[data.startIndex + 1]))
    }

    /// Feeds one PES payload. Returns finished subtitles: each lasts until the page is
    /// next sent (subtitles replace one another).
    func decode(_ data: Data, pts: Double) -> [(start: Double, end: Double, text: String)] {
        let b = [UInt8](data)
        guard let first = b.first, (0x10...0x1F).contains(first) else { return [] }
        var cues: [(Double, Double, String)] = []
        var i = 1
        while i + 2 <= b.count {
            let unitID = b[i]
            let length = Int(b[i + 1])
            let start = i + 2
            guard start + length <= b.count else { break }
            if (unitID == 0x02 || unitID == 0x03), length == 44 {
                let unit = b[start..<(start + length)].map(Self.reversed)
                if let cue = packet(Array(unit), pts: pts) { cues.append(cue) }
            }
            i = start + length
        }
        return cues
    }

    private func packet(_ unit: [UInt8], pts: Double) -> (Double, Double, String)? {
        // unit[0]: field/line, unit[1]: framing code (0xE4), unit[2...3]: address, then 40 bytes.
        guard unit.count == 44, unit[1] == 0xE4,
              let low = Self.hamming(unit[2]), let high = Self.hamming(unit[3]) else { return nil }
        let packetMagazine = (low & 0x07) == 0 ? 8 : low & 0x07
        let row = (low >> 3) | (high << 1)
        guard packetMagazine == magazine else { return nil }
        let body = Array(unit[4...])

        if row == 0 {
            guard let units = Self.hamming(body[0]), let tens = Self.hamming(body[1]) else { return nil }
            let number = tens << 4 | units
            var finished: (Double, Double, String)?
            // A new header for our page ends the previous one.
            if collecting, let start = pageStart {
                let text = assembledText()
                if !text.isEmpty { finished = (start, max(pts, start + 0.5), text) }
            }
            collecting = number == page
            if collecting {
                rows = [:]
                pageStart = pts
            }
            return finished
        }
        guard collecting, (1...23).contains(row) else { return nil }
        rows[row] = Self.text(body)
        return nil
    }

    private func assembledText() -> String {
        rows.sorted { $0.key < $1.key }
            .map { $0.value.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Text from 40 odd-parity characters; control codes (colors, boxing) become spaces.
    private static func text(_ bytes: [UInt8]) -> String {
        String(bytes.map { byte -> Character in
            let value = byte & 0x7F
            guard value >= 0x20 else { return " " }
            switch value {
            case 0x23: return "#"
            case 0x24: return "¤"
            case 0x40: return "@"
            case 0x5B: return "←"
            case 0x5C: return "½"
            case 0x5D: return "→"
            case 0x5E: return "↑"
            case 0x5F: return "#"
            case 0x60: return "–"
            case 0x7B: return "¼"
            case 0x7C: return "‖"
            case 0x7D: return "¾"
            case 0x7E: return "÷"
            case 0x7F: return " "
            default: return Character(UnicodeScalar(value))
            }
        })
    }

    /// Hamming 8/4: data bits are 1, 3, 5, and 7. Returns nil when uncorrectable.
    static func hamming(_ byte: UInt8) -> Int? {
        let bits = (0..<8).map { Int(byte >> $0) & 1 }
        let a = bits[0] ^ bits[1] ^ bits[5] ^ bits[7]
        let b = bits[1] ^ bits[2] ^ bits[3] ^ bits[7]
        let c = bits[1] ^ bits[3] ^ bits[4] ^ bits[5]
        let d = bits.reduce(0, ^)
        var data = [bits[1], bits[3], bits[5], bits[7]]
        // Each check has odd parity; the failing ones point at a single wrong bit.
        let syndrome = (a == 1 ? 0 : 1) | (b == 1 ? 0 : 2) | (c == 1 ? 0 : 4)
        if syndrome != 0 {
            guard d == 0 else { return nil } // Two errors.
            switch syndrome {
            case 7: data[0] ^= 1   // D1 is in checks A, B, and C
            case 6: data[1] ^= 1   // D2: B and C
            case 5: data[2] ^= 1   // D3: A and C
            case 3: data[3] ^= 1   // D4: A and B
            default: break         // A protection bit; the data is fine.
            }
        }
        return data[0] | data[1] << 1 | data[2] << 2 | data[3] << 3
    }

    /// Teletext is sent least-significant bit first.
    static func reversed(_ byte: UInt8) -> UInt8 {
        var value = byte
        var result: UInt8 = 0
        for _ in 0..<8 {
            result = result << 1 | value & 1
            value >>= 1
        }
        return result
    }
}
