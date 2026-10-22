//
//  OggDemuxer.swift
//  Ultimate Theater
//
//  Ogg (RFC 3533): pages of laced packets per logical stream. Reads Opus, Vorbis, and
//  FLAC audio and Theora video; Speex and Kate subtitles are listed but not decoded.
//  Packet times come from page granule positions minus the durations of later packets.
//

import Foundation

nonisolated final class OggDemuxer: MediaDemuxer {
    let tracks: [ContainerTrack]
    let duration: Double?
    let chapters: [ContainerChapter] = []
    var enabledTrackIDs: Set<Int>

    private struct Page {
        let offset: UInt64
        let length: Int
        let isContinued: Bool
        let granule: Int64
        let serial: Int
        /// Packet pieces in this page; `complete` is false for a piece continuing on the next page.
        let pieces: [(data: Data, complete: Bool)]
    }

    private struct StreamState {
        let codec: MediaCodec
        let rate: Double
        let preSkip: Int64
        var headersLeft: Int
        var partial: Data?
        var vorbis: VorbisParser?
        /// Theora granule positions pack the last keyframe's number above `shift` bits and
        /// the frames since it below. Streams before version 3.2.1 count from zero.
        var theora: (shift: Int, countsFromZero: Bool)?

        /// The granule position as a count of units (samples, or frames for Theora) that
        /// end with the page's last packet.
        func units(_ granule: Int64) -> Int64 {
            guard let theora else { return granule }
            let frames = (granule >> Int64(theora.shift)) + (granule & ((1 << Int64(theora.shift)) - 1))
            return frames + (theora.countsFromZero ? 1 : 0)
        }

        func seconds(_ granule: Int64) -> Double {
            Double(units(granule) - preSkip) / rate
        }
    }

    private let source: FileByteSource
    private var position: UInt64 = 0
    private var states: [Int: StreamState] = [:]
    private let initialStates: [Int: StreamState]
    private var ready: [MediaPacket] = []
    /// Header packets are skipped only when reading from the start of the file.
    private var skipsHeaders = true

    static func matches(_ head: Data) -> Bool {
        head.prefix(4) == Data("OggS".utf8)
    }

    init(source: FileByteSource) throws {
        self.source = source
        // Identify streams from their first packets, and collect each one's header packets.
        var headers: [Int: [Data]] = [:]
        var order: [Int] = []
        var partial: [Int: Data] = [:]
        var at: UInt64 = 0
        var pagesRead = 0
        func needed(_ first: Data) -> Int {
            let b = [UInt8](first.prefix(9))
            if b.starts(with: [0x01] + Array("vorbis".utf8)) || b.starts(with: [0x80] + Array("theora".utf8)) { return 3 }
            if first.starts(with: Data("OpusHead".utf8)) || first.starts(with: Data("Speex   ".utf8)) { return 2 }
            if b.count >= 9, b.starts(with: [0x7F] + Array("FLAC".utf8)) { return 1 + (Int(b[7]) << 8 | Int(b[8])) }
            return 1
        }
        reading: while pagesRead < 2000, let page = try Self.page(in: source, at: at) {
            pagesRead += 1
            at = page.offset + UInt64(page.length)
            if headers[page.serial] == nil {
                guard !page.isContinued else { continue }
                order.append(page.serial)
                headers[page.serial] = []
            }
            for piece in page.pieces {
                var data = partial.removeValue(forKey: page.serial) ?? Data()
                data.append(piece.data)
                guard piece.complete else { partial[page.serial] = data; continue }
                if let first = headers[page.serial]?.first, headers[page.serial]!.count >= needed(first) { continue }
                headers[page.serial]?.append(data)
            }
            let done = order.allSatisfy { serial in headers[serial].map { !$0.isEmpty && $0.count >= needed($0[0]) } ?? false }
            if done, pagesRead > order.count { break reading }
        }
        guard !order.isEmpty else { throw ContainerError.unrecognizedFormat }

        var tracks: [ContainerTrack] = []
        var states: [Int: StreamState] = [:]
        for serial in order {
            guard let list = headers[serial], let first = list.first else { continue }
            let b = [UInt8](first)
            var track: ContainerTrack
            var rate = 48000.0
            var preSkip: Int64 = 0
            var theora: (shift: Int, countsFromZero: Bool)?
            if first.starts(with: Data("OpusHead".utf8)), b.count >= 19 {
                track = ContainerTrack(id: serial, kind: .audio, codec: .opus, codecID: "A_OPUS")
                track.channels = Int(b[9])
                track.sampleRate = 48000
                track.codecPrivate = first
                preSkip = Int64(b[10]) | Int64(b[11]) << 8
            } else if b.starts(with: [0x01] + Array("vorbis".utf8)), b.count >= 30, list.count == 3 {
                track = ContainerTrack(id: serial, kind: .audio, codec: .vorbis, codecID: "A_VORBIS")
                track.channels = Int(b[11])
                rate = Double(UInt32(b[12]) | UInt32(b[13]) << 8 | UInt32(b[14]) << 16 | UInt32(b[15]) << 24)
                track.sampleRate = rate
                track.codecPrivate = VorbisParser.lace(list)
            } else if b.starts(with: [0x7F] + Array("FLAC".utf8)), b.count >= 51 {
                track = ContainerTrack(id: serial, kind: .audio, codec: .flac, codecID: "A_FLAC")
                track.codecPrivate = first.dropFirst(9) // "fLaC" + STREAMINFO
                if let info = track.codecPrivate.flatMap(FLAC.streamInfo) {
                    rate = info.sampleRate
                    track.sampleRate = rate
                    track.channels = info.channels
                }
            } else if b.starts(with: [0x80] + Array("theora".utf8)), list.count == 3, let decoder = TheoraDecoder(headers: list) {
                track = ContainerTrack(id: serial, kind: .video, codec: .theora, codecID: "V_THEORA")
                track.width = decoder.pictureWidth
                track.height = decoder.pictureHeight
                track.codecPrivate = VorbisParser.lace(list)
                rate = Double(decoder.frameRateNumerator) / Double(decoder.frameRateDenominator)
                track.frameDuration = 1 / rate
                let version = decoder.version
                theora = (decoder.keyframeGranuleShift, (version.major, version.minor, version.revision) < (3, 2, 1))
            } else if b.starts(with: [0x80] + Array("theora".utf8)), b.count >= 20 {
                track = ContainerTrack(id: serial, kind: .video, codec: .unsupported("Theora"), codecID: "V_THEORA")
                track.width = Int(b[14]) << 16 | Int(b[15]) << 8 | Int(b[16])
                track.height = Int(b[17]) << 16 | Int(b[18]) << 8 | Int(b[19])
            } else if first.starts(with: Data("Speex   ".utf8)) {
                track = ContainerTrack(id: serial, kind: .audio, codec: .unsupported("Speex"), codecID: "A_SPEEX")
            } else if b.starts(with: [0x80] + Array("kate".utf8)) {
                track = ContainerTrack(id: serial, kind: .subtitle, codec: .unsupported("Kate"), codecID: "S_KATE")
            } else {
                continue // Skeleton and other metadata streams.
            }
            tracks.append(track)
            states[serial] = StreamState(codec: track.codec, rate: rate, preSkip: preSkip, headersLeft: list.count,
                                         vorbis: track.codec == .vorbis ? VorbisParser(headers: list) : nil, theora: theora)
        }
        guard !tracks.isEmpty else { throw ContainerError.unrecognizedFormat }
        self.tracks = tracks
        initialStates = states
        self.states = states
        enabledTrackIDs = Set(tracks.map(\.id))

        // Duration: the last granule position of each stream.
        var latest: Double?
        var window: UInt64 = 64 << 10
        while latest == nil, window <= 8 << 20 {
            let start = source.size > window ? source.size - window : 0
            var offset = try Self.nextPageOffset(in: source, from: start)
            while let found = offset, let page = try Self.page(in: source, at: found) {
                if let state = states[page.serial], page.granule >= 0, state.codec.isSupported {
                    latest = max(latest ?? 0, state.seconds(page.granule))
                }
                offset = found + UInt64(page.length)
            }
            if start == 0 { break }
            window *= 4
        }
        duration = latest
    }

    // MARK: Reading

    func nextPacket() throws -> MediaPacket? {
        while ready.isEmpty {
            guard let page = try Self.page(in: source, at: position) else {
                guard let next = try Self.nextPageOffset(in: source, from: position + 1) else { return nil }
                position = next // Damaged data: skip to the next page.
                continue
            }
            position = page.offset + UInt64(page.length)
            read(page)
        }
        return ready.removeFirst()
    }

    private func read(_ page: Page) {
        guard var state = states[page.serial] else { return }
        var completed: [Data] = []
        for (index, piece) in page.pieces.enumerated() {
            if index == 0, page.isContinued, state.partial == nil { continue } // Began before a seek.
            var data = state.partial ?? Data()
            state.partial = nil
            data.append(piece.data)
            if piece.complete { completed.append(data) } else { state.partial = data }
        }
        if skipsHeaders, state.headersLeft > 0 {
            let skip = min(state.headersLeft, completed.count)
            completed.removeFirst(skip)
            state.headersLeft -= skip
        }
        // Durations of the packets that end on this page, counted back from its granule position.
        let durations = completed.map { packet -> Int64 in
            switch state.codec {
            case .opus: Int64(Opus.packetDuration(packet) ?? 0)
            case .flac: Int64(FLAC.blockSize(ofFrame: packet, streamInfo: nil) ?? 0)
            case .vorbis: Int64(state.vorbis?.duration(of: packet) ?? 0)
            case .theora: 1
            default: 0
            }
        }
        states[page.serial] = state
        guard enabledTrackIDs.contains(page.serial), state.codec.isSupported, page.granule >= 0 else { return }
        var end = state.units(page.granule)
        var packets: [MediaPacket] = []
        for (packet, length) in zip(completed, durations).reversed() {
            let start = end - length
            packets.append(MediaPacket(trackID: page.serial, pts: Double(start - state.preSkip) / state.rate,
                                       duration: Double(length) / state.rate,
                                       isKeyframe: state.codec == .theora ? TheoraDecoder.isKeyframe(packet) : true, data: packet))
            end = start
        }
        ready += packets.reversed()
    }

    // MARK: Seeking

    @discardableResult
    func seek(to target: Double) throws -> Double {
        ready = []
        states = initialStates
        guard target > 0.5, let reference = tracks.first(where: { $0.codec.isSupported })?.id,
              let state = initialStates[reference] else {
            position = 0
            skipsHeaders = true
            return 0
        }
        // Bisect for the last page whose granule time is before the target (less a little pre-roll).
        let goal = target - 0.2
        var low: UInt64 = 0
        var high = source.size
        while high - low > 64 << 10 {
            let middle = low + (high - low) / 2
            var offset = try Self.nextPageOffset(in: source, from: middle)
            var time: Double?
            var pages = 0
            while let found = offset, pages < 200, let page = try Self.page(in: source, at: found) {
                pages += 1
                if page.serial == reference, page.granule >= 0 { time = state.seconds(page.granule); break }
                offset = found + UInt64(page.length)
            }
            if let time, time < goal { low = middle } else { high = middle }
        }
        skipsHeaders = low == 0
        position = try Self.nextPageOffset(in: source, from: low) ?? 0
        // Step forward to the first packet of the reference stream at the goal.
        var others: [MediaPacket] = []
        while let packet = try nextPacket() {
            guard packet.trackID == reference else { others.append(packet); continue }
            guard packet.pts + (packet.duration ?? 0) > goal else { others = []; continue }
            ready.insert(contentsOf: others + [packet], at: 0)
            return max(0, packet.pts)
        }
        return target
    }

    // MARK: Pages

    private static func page(in source: FileByteSource, at offset: UInt64) throws -> Page? {
        let head = [UInt8](try source.read(at: offset, count: 27))
        guard head.count == 27, head[0...3].elementsEqual("OggS".utf8), head[4] == 0 else { return nil }
        let segments = Int(head[26])
        let lacing = [UInt8](try source.read(at: offset + 27, count: segments))
        guard lacing.count == segments else { return nil }
        let bodyLength = lacing.reduce(0) { $0 + Int($1) }
        let body = try source.read(at: offset + 27 + UInt64(segments), count: bodyLength)
        guard body.count == bodyLength else { return nil }
        var granule: Int64 = 0
        for i in 0..<8 { granule |= Int64(head[6 + i]) << (8 * i) }
        let serial = Int(UInt32(head[14]) | UInt32(head[15]) << 8 | UInt32(head[16]) << 16 | UInt32(head[17]) << 24)
        var pieces: [(Data, Bool)] = []
        var start = 0
        var size = 0
        for value in lacing {
            size += Int(value)
            if value < 255 {
                pieces.append((body.subdata(in: (body.startIndex + start)..<(body.startIndex + start + size)), true))
                start += size
                size = 0
            }
        }
        if size > 0 || lacing.last == 255 {
            pieces.append((body.subdata(in: (body.startIndex + start)..<(body.startIndex + start + size)), false))
        }
        return Page(offset: offset, length: 27 + segments + bodyLength, isContinued: head[5] & 1 != 0,
                    granule: granule, serial: serial, pieces: pieces)
    }

    private static func nextPageOffset(in source: FileByteSource, from offset: UInt64) throws -> UInt64? {
        var at = offset
        while at < source.size {
            let window = [UInt8](try source.read(at: at, count: 64 << 10))
            guard window.count >= 4 else { return nil }
            for i in 0..<(window.count - 3) where window[i] == 0x4F && window[i + 1] == 0x67 && window[i + 2] == 0x67 && window[i + 3] == 0x53 {
                return at + UInt64(i)
            }
            at += UInt64(window.count - 3)
        }
        return nil
    }
}
