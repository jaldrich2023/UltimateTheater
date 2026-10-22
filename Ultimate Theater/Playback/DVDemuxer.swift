//
//  DVDemuxer.swift
//  Ultimate Theater
//
//  Raw DV files (.dv, .dif) from camcorders: each frame is a fixed-size run of 80-byte
//  DIF blocks. The video goes to the system DV decoder as whole frames; the audio is
//  spread across the frame's audio blocks in the standard shuffle order (IEC 61834-2)
//  and is gathered back into PCM here.
//

import Foundation

nonisolated final class DVDemuxer: MediaDemuxer {
    let tracks: [ContainerTrack]
    let duration: Double?
    let chapters: [ContainerChapter] = []
    var enabledTrackIDs: Set<Int>

    private static let videoID = 1
    private static let audioID = 2

    private let source: FileByteSource
    private let frameSize: Int
    private let frameDuration: Double
    private let frameCount: Int
    private let isPAL: Bool
    private var frameIndex = 0
    private var pending: [MediaPacket] = []

    static func matches(_ head: Data) -> Bool {
        // A DIF header block: section type 0 (header) with sequence 0, block 0.
        let b = [UInt8](head.prefix(80))
        return b.count >= 80 && b[0] & 0xE0 == 0x00 && b[0] & 0x1F == 0x1F && b[1] & 0xF0 == 0x00 && b[2] == 0x00
    }

    init(source: FileByteSource) throws {
        self.source = source
        let header = [UInt8](try source.read(at: 0, count: 80 * 6))
        guard header.count == 480 else { throw ContainerError.truncated }
        isPAL = header[3] & 0x80 != 0
        let sequences = isPAL ? 12 : 10
        // VAUX source pack (0x60) in the first VAUX block: STYPE 4 means 50 Mb/s (two channels of DIF data).
        let isDV50 = Self.videoSourceType(header) == 4
        frameSize = sequences * 150 * 80 * (isDV50 ? 2 : 1)
        frameDuration = isPAL ? 1.0 / 25 : 1001.0 / 30000
        frameCount = Int(source.size / UInt64(frameSize))
        guard frameCount > 0 else { throw ContainerError.truncated }
        duration = Double(frameCount) * frameDuration

        let fourCC: String = switch (isPAL, isDV50) {
        case (false, false): "dvc "
        case (true, false): "dvcp"
        case (false, true): "dv5n"
        case (true, true): "dv5p"
        }
        var video = ContainerTrack(id: Self.videoID, kind: .video, codec: .dv(fourCC.utf8.reduce(0) { $0 << 8 | UInt32($1) }), codecID: fourCC)
        video.width = 720
        video.height = isPAL ? 576 : 480
        video.frameDuration = frameDuration
        var tracks = [video]
        if let format = Self.audioFormat(try source.read(at: 0, count: frameSize)) {
            var audio = ContainerTrack(id: Self.audioID, kind: .audio, codec: .pcm(bits: 16, isFloat: false, isBigEndian: false), codecID: "DV audio")
            audio.sampleRate = format.sampleRate
            audio.channels = 2
            audio.bitDepth = 16
            tracks.append(audio)
        }
        self.tracks = tracks
        enabledTrackIDs = Set(tracks.map(\.id))
    }

    func nextPacket() throws -> MediaPacket? {
        if !pending.isEmpty { return pending.removeFirst() }
        guard frameIndex < frameCount else { return nil }
        let frame = try source.read(at: UInt64(frameIndex) * UInt64(frameSize), count: frameSize)
        let time = Double(frameIndex) * frameDuration
        frameIndex += 1
        guard frame.count == frameSize else { return nil }
        if enabledTrackIDs.contains(Self.audioID), let pcm = Self.audio(from: [UInt8](frame), isPAL: isPAL) {
            pending.append(MediaPacket(trackID: Self.audioID, pts: time, duration: frameDuration, isKeyframe: true, data: pcm))
        }
        if enabledTrackIDs.contains(Self.videoID) {
            return MediaPacket(trackID: Self.videoID, pts: time, duration: frameDuration, isKeyframe: true, data: frame)
        }
        return pending.isEmpty ? try nextPacket() : pending.removeFirst()
    }

    @discardableResult
    func seek(to seconds: Double) throws -> Double {
        pending = []
        frameIndex = max(0, min(frameCount - 1, Int(seconds / frameDuration)))
        return Double(frameIndex) * frameDuration
    }

    // MARK: Audio

    private static func videoSourceType(_ header: [UInt8]) -> Int? {
        // VAUX blocks follow the header and two subcode blocks; packs are 5 bytes from offset 3.
        for block in 3..<6 {
            var at = block * 80 + 3
            while at + 5 <= block * 80 + 80 {
                if header[at] == 0x60 { return Int(header[at + 3] & 0x1F) }
                at += 5
            }
        }
        return nil
    }

    /// Sampling rate and quantization from the AAUX source pack (0x50).
    private static func audioFormat(_ frame: Data) -> (sampleRate: Double, isTwelveBit: Bool, samples: Int)? {
        let b = [UInt8](frame)
        let isPAL = b[3] & 0x80 != 0
        for sequence in 0..<(isPAL ? 12 : 10) {
            for block in 0..<9 {
                let at = (sequence * 150 + 6 + block * 16) * 80
                guard at + 8 <= b.count, b[at + 3] == 0x50 else { continue }
                let rateCode = Int(b[at + 7] >> 3 & 0x07)
                let quantization = Int(b[at + 7] & 0x07)
                guard rateCode <= 2, quantization <= 1 else { return nil }
                let rate = [48000.0, 44100, 32000][rateCode]
                let minimum = isPAL ? [1896, 1742, 1264][rateCode] : [1580, 1452, 1053][rateCode]
                return (rate, quantization == 1, minimum + Int(b[at + 4] & 0x3F))
            }
        }
        return nil
    }

    /// Where sample `k` of audio block `block` in DIF sequence `sequence` belongs: the
    /// IEC 61834 shuffle spreads each channel's samples across its half of the sequences.
    static func shuffledIndex(sequence: Int, block: Int, sample: Int, isPAL: Bool) -> Int {
        let half = isPAL ? 6 : 5
        let modulus = isPAL ? 18 : 15
        let offsets = isPAL ? [0, 13, 8] : [0, 10, 5]
        let row = sequence % half
        let position = (3 * row + offsets[block / 3]) % modulus + modulus * (block % 3)
        return position + (isPAL ? 54 : 45) * sample
    }

    /// Two channels of 16-bit PCM (little-endian, interleaved) gathered from one frame.
    static func audio(from frame: [UInt8], isPAL: Bool) -> Data? {
        guard let format = audioFormat(Data(frame)) else { return nil }
        let sequences = isPAL ? 12 : 10
        let half = sequences / 2
        var left = [Int16](repeating: 0, count: format.samples)
        var right = [Int16](repeating: 0, count: format.samples)
        for sequence in 0..<sequences {
            for block in 0..<9 {
                let at = (sequence * 150 + 6 + block * 16) * 80
                guard at + 80 <= frame.count else { continue }
                if format.isTwelveBit {
                    // Two 12-bit samples (one per channel) in every three bytes; nonlinear.
                    guard sequence < half else { continue } // The second half holds channels 3 and 4.
                    for k in 0..<24 {
                        let d = at + 8 + k * 3
                        let index = shuffledIndex(sequence: sequence, block: block, sample: k, isPAL: isPAL)
                        guard index < format.samples else { continue }
                        left[index] = expand12(Int(frame[d]) << 4 | Int(frame[d + 2]) >> 4)
                        right[index] = expand12(Int(frame[d + 1]) << 4 | Int(frame[d + 2]) & 0x0F)
                    }
                } else {
                    for k in 0..<36 {
                        let d = at + 8 + k * 2
                        let index = shuffledIndex(sequence: sequence, block: block, sample: k, isPAL: isPAL)
                        guard index < format.samples else { continue }
                        var value = Int16(bitPattern: UInt16(frame[d]) << 8 | UInt16(frame[d + 1]))
                        if value == Int16.min { value = 0 } // 0x8000 marks a missing sample.
                        if sequence < half { left[index] = value } else { right[index] = value }
                    }
                }
            }
        }
        var pcm = Data(capacity: format.samples * 4)
        for index in 0..<format.samples {
            withUnsafeBytes(of: left[index].littleEndian) { pcm.append(contentsOf: $0) }
            withUnsafeBytes(of: right[index].littleEndian) { pcm.append(contentsOf: $0) }
        }
        return pcm
    }

    /// 12-bit nonlinear DV audio to 16-bit linear.
    private static func expand12(_ code: Int) -> Int16 {
        var sample = code & 0x800 != 0 ? code - 0x1000 : code // Sign-extend.
        let segment = (sample & 0xF00) >> 8
        if (2...7).contains(segment) {
            let shift = segment - 1
            sample = (sample - 256 * shift) << shift
        } else if (8...13).contains(segment) {
            let shift = 14 - segment
            sample = ((sample + 256 * shift + 1) << shift) - 1
        }
        return Int16(clamping: sample)
    }
}
