//
//  MP4Demuxer.swift
//  Ultimate Theater
//
//  Reads ISO base media files (MP4, M4V, MOV, 3GP): sample tables, edit lists,
//  fragments, chapters, and timed text. Spec: ISO/IEC 14496-12, plus QuickTime
//  sound and chapter conventions.
//

import Foundation

nonisolated final class MP4Demuxer: MediaDemuxer {
    private(set) var tracks: [ContainerTrack] = []
    private(set) var duration: Double?
    private(set) var chapters: [ContainerChapter] = []
    var enabledTrackIDs: Set<Int> = []

    private let source: FileByteSource
    private var tables: [Int: SampleTable] = [:]
    /// Track IDs in the order their tables were read (stable tie-breaking).
    private var tableOrder: [Int] = []
    /// A track read out of file order because it fell behind (a file storing one track apart
    /// from another); it's read until it catches up.
    private var catchingUpID: Int?

    /// How far (seconds of decode time) a track may fall behind before it's read out of file order.
    static let maxTrackLag: Double = 1.5
    /// Most sample records one track may hold; more come from damaged tables (and would
    /// exhaust memory). Ten hours at 60 frames a second is about 2.2 million.
    static let maxSamplesPerTrack = 20_000_000

    struct Sample {
        var offset: UInt64
        var size: Int
        var dts: Int64
        var ctsOffset: Int32
        var duration: UInt32
        var isSync: Bool
    }

    private struct SampleTable {
        var track: ContainerTrack
        let timescale: Double
        /// Media time that presentation time zero maps to (from the edit list).
        let mediaStart: Int64
        var samples: [Sample]
        var cursor = 0
        /// QuickTime allows negative composition offsets, which would put a frame's decode
        /// time after its presentation time. Decode times shift earlier by the most negative
        /// offset (what the 'cslg' box records), so decoding always precedes display.
        var decodeShift: Int64 = 0

        init(track: ContainerTrack, timescale: Double, mediaStart: Int64, samples: [Sample]) {
            self.track = track
            self.timescale = timescale
            self.mediaStart = mediaStart
            self.samples = samples
            refreshDecodeShift()
        }

        mutating func refreshDecodeShift() {
            decodeShift = max(0, -Int64(samples.lazy.map(\.ctsOffset).min() ?? 0))
        }

        func pts(_ sample: Sample) -> Double {
            Double(sample.dts &+ Int64(sample.ctsOffset) &- mediaStart) / timescale
        }

        func dts(_ sample: Sample) -> Double {
            Double(sample.dts &- decodeShift &- mediaStart) / timescale
        }
    }

    init(source: FileByteSource) throws {
        self.source = source
        try parse()
        enabledTrackIDs = Set(tracks.map(\.id))
    }

    // MARK: Packets

    func nextPacket() throws -> MediaPacket? {
        var id = 0
        var table: SampleTable
        var sample: Sample
        repeat {
            guard let nextID = nextTrackID(), let found = tables[nextID] else { return nil }
            id = nextID
            table = found
            sample = table.samples[table.cursor]
            table.cursor += 1
            tables[id] = table
        } while sample.size > FileByteSource.maxPayloadSize // A damaged size entry; skip the sample.

        let data = try source.read(at: sample.offset, count: sample.size)
        guard data.count == sample.size else { throw ContainerError.truncated }
        return MediaPacket(trackID: id, pts: table.pts(sample),
                           dts: table.track.kind == .video ? table.dts(sample) : nil,
                           duration: Double(sample.duration) / table.timescale,
                           isKeyframe: sample.isSync, data: data)
    }

    /// The track whose next sample is read. Normally that's file order, the sequential read
    /// an interleaved file is written for. A track whose next decode time falls more than
    /// `maxTrackLag` behind the file-order choice (one track stored before another) is read
    /// until it catches up, so the two arrive together in bursts rather than the whole first
    /// track having to be buffered before the second starts.
    private func nextTrackID() -> Int? {
        /// The next sample's decode time; a damaged timescale gives none (file order only).
        func nextTime(_ id: Int) -> Double? {
            guard let table = tables[id], table.cursor < table.samples.count else { return nil }
            let time = table.dts(table.samples[table.cursor])
            return time.isFinite ? time : nil
        }
        var inFileOrder: (id: Int, offset: UInt64)?
        var lagging: (id: Int, time: Double)?
        var active: [Int] = []
        for id in tableOrder where enabledTrackIDs.contains(id) {
            guard let table = tables[id], table.cursor < table.samples.count else { continue }
            active.append(id)
            let offset = table.samples[table.cursor].offset
            if inFileOrder.map({ offset < $0.offset }) ?? true { inFileOrder = (id, offset) }
            if let time = nextTime(id), lagging.map({ time < $0.time }) ?? true { lagging = (id, time) }
        }
        guard let fileOrderID = inFileOrder?.id else { return nil }

        // Keep catching up until the lagging track reaches the others.
        if let id = catchingUpID {
            let others = active.filter { $0 != id }.compactMap(nextTime).min()
            if active.contains(id), let time = nextTime(id), let others, time < others { return id }
            catchingUpID = nil
        }
        if let lagging, lagging.id != fileOrderID, let leader = nextTime(fileOrderID),
           leader - lagging.time > Self.maxTrackLag {
            catchingUpID = lagging.id
            return lagging.id
        }
        return fileOrderID
    }

    @discardableResult
    func seek(to seconds: Double) throws -> Double {
        catchingUpID = nil
        var landing = max(seconds, 0)
        // Video lands on the sync sample at or before the target; everything else follows it.
        if let videoID = tableOrder.first(where: { tables[$0]?.track.kind == .video && enabledTrackIDs.contains($0) }),
           var video = tables[videoID] {
            let index = video.samples.indices.last { video.samples[$0].isSync && video.pts(video.samples[$0]) <= landing + 0.001 }
                ?? video.samples.firstIndex(where: \.isSync) ?? 0
            video.cursor = index
            if index < video.samples.count { landing = video.pts(video.samples[index]) }
            tables[videoID] = video
        }
        for id in tableOrder where tables[id]?.track.kind != .video {
            guard var table = tables[id] else { continue }
            table.cursor = table.samples.firstIndex { table.dts($0) + Double($0.duration) / table.timescale > landing }
                ?? table.samples.count
            tables[id] = table
        }
        return landing
    }

    // MARK: Parsing

    private func parse() throws {
        var moov: ArraySlice<UInt8>?
        var fragments: [(offset: UInt64, data: ArraySlice<UInt8>)] = []
        var position: UInt64 = 0
        while position + 8 <= source.size {
            let header = try source.read(at: position, count: 16)
            guard header.count >= 8 else { break }
            var size = UInt64(Self.be32(header, 0))
            let type = String(decoding: header.subdata(in: 4..<8), as: UTF8.self)
            var headerLength: UInt64 = 8
            if size == 1, header.count >= 16 {
                size = header.subdata(in: 8..<16).bigEndianUInt
                headerLength = 16
            } else if size == 0 {
                size = source.size - position
            }
            guard size >= headerLength else { throw ContainerError.corrupt("invalid box size") }
            // A box claiming more than the file holds was cut short; read what exists, then stop.
            let available = source.size - position
            let bodyLength = Int(min(size, available) - min(headerLength, available))
            switch type {
            case "moov":
                // The index must be parsed whole; large files (long, many tracks) can exceed
                // the usual read limit.
                moov = ArraySlice(try source.read(at: position + headerLength, count: bodyLength,
                                                  limit: FileByteSource.maxIndexSize))
            case "moof":
                fragments.append((position, ArraySlice(try source.read(at: position + headerLength, count: bodyLength))))
            default:
                break // mdat, free, … are read on demand.
            }
            guard size < available else { break }
            position += size
        }
        guard let moov else { throw ContainerError.incomplete }
        try parseMovie(moov, fragments: fragments)
        guard !tables.isEmpty else { throw ContainerError.corrupt("no playable tracks") }
    }

    private func parseMovie(_ moov: ArraySlice<UInt8>, fragments: [(offset: UInt64, data: ArraySlice<UInt8>)]) throws {
        let children = Box.children(of: moov)
        var movieTimescale: Double = 1000
        if let mvhd = children.first(where: { $0.type == "mvhd" }) {
            let version = mvhd.data.first ?? 0
            movieTimescale = Double(Box.u32(mvhd.data, version == 1 ? 20 : 12))
            let length = version == 1 ? Double(Box.u64(mvhd.data, 24)) : Double(Box.u32(mvhd.data, 16))
            if movieTimescale > 0 { duration = length / movieTimescale }
        }

        var trexDefaults: [Int: (duration: UInt32, size: UInt32, flags: UInt32)] = [:]
        for trex in children.first(where: { $0.type == "mvex" }).map({ Box.children(of: $0.data) })?.filter({ $0.type == "trex" }) ?? [] {
            trexDefaults[Int(Box.u32(trex.data, 4))] = (Box.u32(trex.data, 12), Box.u32(trex.data, 16), Box.u32(trex.data, 20))
        }

        var chapterTrackIDs = Set<Int>()
        for trak in children where trak.type == "trak" {
            guard let parsed = parseTrack(trak.data, movieTimescale: movieTimescale) else { continue }
            chapterTrackIDs.formUnion(parsed.chapterTracks)
            tables[parsed.table.track.id] = parsed.table
            tableOrder.append(parsed.table.track.id)
        }

        for fragment in fragments {
            appendFragment(fragment.data, moofOffset: fragment.offset, defaults: trexDefaults)
        }

        // QuickTime chapter tracks become chapters rather than subtitles.
        for id in chapterTrackIDs {
            guard let table = tables[id] else { continue }
            // A damaged table can't make this read the whole file: titles are short.
            chapters = try table.samples.prefix(10_000).map { sample in
                let data = try source.read(at: sample.offset, count: min(sample.size, 1 << 16))
                return ContainerChapter(title: Self.timedText(data) ?? "Chapter", start: table.pts(sample),
                                        end: table.pts(sample) + Double(sample.duration) / table.timescale)
            }
            tables[id] = nil
            tableOrder.removeAll { $0 == id }
        }
        if chapters.isEmpty, let udta = children.first(where: { $0.type == "udta" }),
           let chpl = Box.children(of: udta.data).first(where: { $0.type == "chpl" }) {
            chapters = Self.neroChapters(chpl.data)
        }
        chapters.sort { $0.start < $1.start }

        tracks = tableOrder.compactMap { tables[$0]?.track }
        if duration == nil || duration == 0 {
            duration = tables.values.compactMap { table in table.samples.last.map { table.pts($0) } }.max()
        }
    }

    private func parseTrack(_ trak: ArraySlice<UInt8>, movieTimescale: Double) -> (table: SampleTable, chapterTracks: [Int])? {
        let children = Box.children(of: trak)
        guard let tkhd = children.first(where: { $0.type == "tkhd" }),
              let mdia = children.first(where: { $0.type == "mdia" }).map({ Box.children(of: $0.data) }),
              let mdhd = mdia.first(where: { $0.type == "mdhd" }),
              let hdlr = mdia.first(where: { $0.type == "hdlr" }),
              let stbl = mdia.first(where: { $0.type == "minf" }).flatMap({ Box.child("stbl", in: $0.data) }) else { return nil }

        let tkhdVersion = tkhd.data.first ?? 0
        let trackID = Int(Box.u32(tkhd.data, tkhdVersion == 1 ? 20 : 12))
        let isEnabled = (Box.u32(tkhd.data, 0) & 0x1) != 0
        let mdhdVersion = mdhd.data.first ?? 0
        let timescale = Double(Box.u32(mdhd.data, mdhdVersion == 1 ? 20 : 12))
        guard timescale > 0 else { return nil }
        let language = Self.language(packed: Box.u16(mdhd.data, mdhdVersion == 1 ? 32 : 20))
            ?? mdia.first(where: { $0.type == "elng" }).map { String(decoding: $0.data.dropFirst(4).prefix { $0 != 0 }, as: UTF8.self) }

        let handler = String(decoding: hdlr.data.dropFirst(8).prefix(4), as: UTF8.self)
        let kind: ContainerTrackKind
        switch handler {
        case "vide": kind = .video
        case "soun": kind = .audio
        case "sbtl", "text", "subt": kind = .subtitle
        default: return nil
        }

        let stblChildren = Box.children(of: stbl)
        guard let stsd = stblChildren.first(where: { $0.type == "stsd" }),
              let entry = Box.children(of: stsd.data.dropFirst(8)).first,
              var track = Self.describe(entry, id: trackID, kind: kind) else { return nil }
        track.language = language
        track.isDefault = isEnabled
        if let name = children.first(where: { $0.type == "udta" }).flatMap({ Box.child("name", in: $0.data) }) {
            let text = String(decoding: name.prefix { $0 != 0 }, as: UTF8.self)
            if !text.isEmpty { track.name = text }
        }

        // Uncompressed-style audio lists one "sample" per frame; read it a chunk at a time.
        let channels = max(track.channels ?? 2, 1)
        var chunkBytes: ((Int) -> Int)?
        switch track.codec {
        case .pcm(let bits, _, _): chunkBytes = { Self.product($0, max(bits / 8 * channels, 1)) }
        case .muLaw, .aLaw: chunkBytes = { Self.product($0, channels) }
        case .appleIMA4: chunkBytes = { Self.product(($0 + 63) / 64 * 34, channels) }
        default: chunkBytes = nil
        }
        let samples = Self.buildSamples(stblChildren, chunkBytes: chunkBytes, chunkGranule: track.codec == .appleIMA4 ? 64 : 1,
                                        fileSize: source.size)
        if kind == .video, let first = samples.first, track.frameDuration == nil {
            track.frameDuration = Double(first.duration) / timescale
        }

        // Edit list: empty edits delay the track; the first media edit says where it starts.
        var mediaStart: Int64 = 0
        if let elst = children.first(where: { $0.type == "edts" }).flatMap({ Box.child("elst", in: $0.data) }) {
            let version = elst.first ?? 0
            let entrySize = version == 1 ? 20 : 12
            let count = min(Int(Box.u32(elst, 4)), max(elst.count - 8, 0) / entrySize)
            var emptyDelay: Int64 = 0
            var offset = 8
            for _ in 0..<count {
                let segment = version == 1 ? Int64(clamping: Box.u64(elst, offset)) : Int64(Box.u32(elst, offset))
                let mediaTime = version == 1 ? Int64(bitPattern: Box.u64(elst, offset + 8)) : Int64(Int32(bitPattern: Box.u32(elst, offset + 4)))
                offset += entrySize
                if mediaTime == -1 {
                    // A movie timescale of zero can't place the delay; ignore the empty edit.
                    guard movieTimescale > 0 else { continue }
                    emptyDelay = emptyDelay &+ Self.clampedInt64(Double(segment) / movieTimescale * timescale)
                } else {
                    mediaStart = mediaTime &- emptyDelay
                    break
                }
            }
        }

        var chapterTracks: [Int] = []
        if let tref = children.first(where: { $0.type == "tref" }), let chap = Box.child("chap", in: tref.data) {
            chapterTracks = stride(from: 0, to: chap.count - 3, by: 4).map { Int(Box.u32(chap, $0)) }
        }
        return (SampleTable(track: track, timescale: timescale, mediaStart: mediaStart, samples: samples), chapterTracks)
    }

    /// Walks a run-length table (stts / ctts) one sample at a time without expanding it.
    private struct RunIterator {
        let runs: [(count: Int, value: UInt32)]
        private var run = 0
        private var used = 0

        init(_ runs: [(count: Int, value: UInt32)]) {
            self.runs = runs
        }

        mutating func next() -> UInt32 {
            while run < runs.count, used >= runs[run].count { run += 1; used = 0 }
            guard run < runs.count else { return runs.last?.value ?? 0 }
            used += 1
            return runs[run].value
        }

        /// Sum of the next `count` values (fast across long runs).
        mutating func advance(by count: Int) -> UInt64 {
            var remaining = count
            var total: UInt64 = 0
            while remaining > 0 {
                while run < runs.count, used >= runs[run].count { run += 1; used = 0 }
                guard run < runs.count else { return total &+ UInt64(remaining) &* UInt64(runs.last?.value ?? 1) }
                let take = min(remaining, runs[run].count - used)
                total = total &+ UInt64(take) &* UInt64(runs[run].value)
                used += take
                remaining -= take
            }
            return total
        }
    }

    /// Builds one record per sample from stts/ctts/stss/stsc/stsz/stco. Uncompressed-style audio
    /// is grouped into one packet per chunk (`chunkBytes` converts frames to bytes), since
    /// QuickTime lists every audio frame as a "sample". A chunk larger than a packet may be is
    /// split into packets of whole `chunkGranule`-frame groups.
    private static func buildSamples(_ stbl: [Box], chunkBytes: ((Int) -> Int)?, chunkGranule: Int = 1, fileSize: UInt64) -> [Sample] {
        func table(_ type: String) -> ArraySlice<UInt8>? { stbl.first { $0.type == type }?.data }
        /// Entry count from a table header, limited to the entries the box actually holds.
        func entryCount(_ data: ArraySlice<UInt8>, at offset: Int = 4, header: Int = 8, entrySize: Int) -> Int {
            min(Int(Box.u32(data, offset)), max(data.count - header, 0) / entrySize)
        }
        func runs(_ data: ArraySlice<UInt8>?) -> [(count: Int, value: UInt32)] {
            guard let data else { return [] }
            return (0..<entryCount(data, entrySize: 8)).map { (Int(Box.u32(data, 8 + $0 * 8)), Box.u32(data, 12 + $0 * 8)) }
        }

        // Sample sizes, read on demand from the table.
        var fixedSize = 0
        var sampleCount = 0
        var sizeAt: (Int) -> Int = { _ in 0 }
        if let stsz = table("stsz") {
            fixedSize = Int(Box.u32(stsz, 4))
            // A fixed size can't describe more samples than the file holds bytes for. (Size 1 is
            // QuickTime's implied-size convention, where compressed frames can be smaller.)
            sampleCount = fixedSize > 1 ? min(Int(Box.u32(stsz, 8)), Int(clamping: fileSize / UInt64(fixedSize)))
                : fixedSize != 0 ? Int(Box.u32(stsz, 8)) : entryCount(stsz, at: 8, header: 12, entrySize: 4)
            sizeAt = { fixedSize != 0 ? fixedSize : Int(Box.u32(stsz, 12 + $0 * 4)) }
        } else if let stz2 = table("stz2") {
            let fieldSize = Int(Box.u8(stz2, 7))
            let tableBytes = max(stz2.count - 12, 0)
            sampleCount = min(Int(Box.u32(stz2, 8)), fieldSize == 4 ? tableBytes * 2 : fieldSize == 8 ? tableBytes : tableBytes / 2)
            sizeAt = { i in
                switch fieldSize {
                case 4: Int(Box.u8(stz2, 12 + i / 2) >> (i % 2 == 0 ? 4 : 0) & 0x0F)
                case 8: Int(Box.u8(stz2, 12 + i))
                default: Int(Box.u16(stz2, 12 + i * 2))
                }
            }
        }
        var chunkOffsets: [UInt64] = []
        if let stco = table("stco") {
            chunkOffsets = (0..<entryCount(stco, entrySize: 4)).map { UInt64(Box.u32(stco, 8 + $0 * 4)) }
        } else if let co64 = table("co64") {
            chunkOffsets = (0..<entryCount(co64, entrySize: 8)).map { Box.u64(co64, 8 + $0 * 8) }
        }
        var stsc: [(firstChunk: Int, samplesPerChunk: Int)] = []
        if let data = table("stsc") {
            stsc = (0..<entryCount(data, entrySize: 12)).map { (Int(Box.u32(data, 8 + $0 * 12)), Int(Box.u32(data, 12 + $0 * 12))) }
        }
        var deltas = RunIterator(runs(table("stts")))
        var compositionOffsets = RunIterator(runs(table("ctts")))
        let hasCompositionOffsets = table("ctts") != nil
        let syncSamples: Set<Int>? = table("stss").map { stss in Set((0..<entryCount(stss, entrySize: 4)).map { Int(Box.u32(stss, 8 + $0 * 4)) - 1 }) }

        var samples: [Sample] = []
        samples.reserveCapacity(chunkBytes == nil ? min(sampleCount, 1 << 20) : chunkOffsets.count)
        var sampleIndex = 0
        var dts: Int64 = 0
        var stscIndex = 0
        for (chunkIndex, chunkOffset) in chunkOffsets.enumerated() {
            let chunkNumber = chunkIndex + 1
            while stscIndex + 1 < stsc.count, stsc[stscIndex + 1].firstChunk <= chunkNumber { stscIndex += 1 }
            let perChunk = stsc.isEmpty ? 0 : stsc[stscIndex].samplesPerChunk
            let count = min(perChunk, sampleCount - sampleIndex)
            guard count > 0 else { break }

            if let chunkBytes {
                // Fixed size 1 is QuickTime's "size per frame is implied" convention.
                func bytes(_ first: Int, _ frames: Int) -> Int {
                    fixedSize <= 1 ? chunkBytes(frames)
                        : fixedSize != 0 ? product(fixedSize, frames)
                        : (0..<frames).reduce(0) { $0 &+ sizeAt(first + $1) }
                }
                let total = bytes(sampleIndex, count)
                // A chunk too big for one packet (long uncompressed audio) becomes several.
                var piece = count
                if total > FileByteSource.maxPayloadSize {
                    let granule = max(chunkGranule, 1)
                    let granuleBytes = max(bytes(sampleIndex, min(granule, count)), 1)
                    piece = max(FileByteSource.maxPayloadSize / granuleBytes, 1) * granule
                }
                var offset = chunkOffset
                var done = 0
                // Pieces past the end of the file come from a damaged table.
                while done < count, samples.count < maxSamplesPerTrack, done == 0 || offset < fileSize {
                    let frames = min(piece, count - done)
                    let size = piece == count ? total : bytes(sampleIndex + done, frames)
                    let span = deltas.advance(by: frames)
                    samples.append(Sample(offset: offset, size: size, dts: dts, ctsOffset: 0, duration: UInt32(clamping: span), isSync: true))
                    dts = dts &+ Int64(clamping: span)
                    offset = offset &+ UInt64(clamping: size)
                    done += frames
                }
                if done < count { dts = dts &+ Int64(clamping: deltas.advance(by: count - done)) }
                sampleIndex += count
                continue
            }
            var offset = chunkOffset
            for _ in 0..<count {
                guard samples.count < maxSamplesPerTrack else { break }
                // Samples past the end of the file come from a damaged table.
                guard offset <= fileSize else { break }
                let size = sizeAt(sampleIndex)
                let delta = deltas.next()
                let cts = hasCompositionOffsets ? Int32(bitPattern: compositionOffsets.next()) : 0
                samples.append(Sample(offset: offset, size: size, dts: dts, ctsOffset: cts, duration: delta,
                                      isSync: syncSamples?.contains(sampleIndex) ?? true))
                offset = offset &+ UInt64(clamping: size)
                dts = dts &+ Int64(delta)
                sampleIndex += 1
            }
        }
        return samples
    }

    /// Adds the samples of one movie fragment (moof).
    private func appendFragment(_ moof: ArraySlice<UInt8>, moofOffset: UInt64,
                                defaults: [Int: (duration: UInt32, size: UInt32, flags: UInt32)]) {
        for traf in Box.children(of: moof) where traf.type == "traf" {
            let children = Box.children(of: traf.data)
            guard let tfhd = children.first(where: { $0.type == "tfhd" }) else { continue }
            let flags = Box.u32(tfhd.data, 0) & 0xFFFFFF
            let trackID = Int(Box.u32(tfhd.data, 4))
            guard var table = tables[trackID] else { continue }
            let fallback = defaults[trackID] ?? (0, 0, 0)
            var cursor = 8
            var baseOffset = moofOffset
            if flags & 0x01 != 0 { baseOffset = Box.u64(tfhd.data, cursor); cursor += 8 }
            if flags & 0x02 != 0 { cursor += 4 }
            var defaultDuration = fallback.duration
            var defaultSize = fallback.size
            var defaultFlags = fallback.flags
            if flags & 0x08 != 0 { defaultDuration = Box.u32(tfhd.data, cursor); cursor += 4 }
            if flags & 0x10 != 0 { defaultSize = Box.u32(tfhd.data, cursor); cursor += 4 }
            if flags & 0x20 != 0 { defaultFlags = Box.u32(tfhd.data, cursor) }

            var dts = table.samples.last.map { $0.dts &+ Int64($0.duration) } ?? 0
            if let tfdt = children.first(where: { $0.type == "tfdt" }) {
                dts = (tfdt.data.first ?? 0) == 1 ? Int64(clamping: Box.u64(tfdt.data, 4)) : Int64(Box.u32(tfdt.data, 4))
            }
            var dataEnd = baseOffset
            for trun in children where trun.type == "trun" {
                let runFlags = Box.u32(trun.data, 0) & 0xFFFFFF
                var at = 8
                var offset = dataEnd
                if runFlags & 0x01 != 0 {
                    // Skip runs whose data would start before the file or past its end.
                    let relative = Int64(Int32(bitPattern: Box.u32(trun.data, at)))
                    guard baseOffset <= source.size else { continue }
                    let start = Int64(baseOffset) + relative
                    guard start >= 0, UInt64(start) <= source.size else { continue }
                    offset = UInt64(start)
                    at += 4
                }
                var firstFlags: UInt32?
                if runFlags & 0x04 != 0 { firstFlags = Box.u32(trun.data, at); at += 4 }
                // Limit the count to the entries the box holds (or a sane total for default-only runs).
                let entrySize = [0x100, 0x200, 0x400, 0x800].filter { runFlags & $0 != 0 }.count * 4
                let held = entrySize > 0 ? max(trun.data.count - at, 0) / entrySize : 1 << 20
                var count = min(Int(Box.u32(trun.data, 4)), held)
                if runFlags & 0x200 == 0 {
                    // Every sample has the default size: zero-size samples carry nothing (a
                    // damaged header), and the run can't hold more samples than the bytes left.
                    guard defaultSize > 0, offset <= source.size else { continue }
                    count = min(count, Int(clamping: (source.size - offset) / UInt64(defaultSize)))
                }
                count = min(count, max(Self.maxSamplesPerTrack - table.samples.count, 0))
                for index in 0..<count {
                    guard offset <= source.size else { break }
                    let duration = runFlags & 0x100 != 0 ? Box.u32(trun.data, at) : defaultDuration
                    if runFlags & 0x100 != 0 { at += 4 }
                    let size = runFlags & 0x200 != 0 ? Box.u32(trun.data, at) : defaultSize
                    if runFlags & 0x200 != 0 { at += 4 }
                    var sampleFlags = runFlags & 0x400 != 0 ? Box.u32(trun.data, at) : defaultFlags
                    if runFlags & 0x400 != 0 { at += 4 }
                    if index == 0, let firstFlags { sampleFlags = firstFlags }
                    let cts = runFlags & 0x800 != 0 ? Int32(bitPattern: Box.u32(trun.data, at)) : 0
                    if runFlags & 0x800 != 0 { at += 4 }
                    table.samples.append(Sample(offset: offset, size: Int(size), dts: dts, ctsOffset: cts,
                                                duration: duration, isSync: sampleFlags & 0x10000 == 0))
                    offset = offset &+ UInt64(size)
                    dts = dts &+ Int64(duration)
                }
                dataEnd = offset
            }
            table.refreshDecodeShift()
            tables[trackID] = table
        }
    }

    // MARK: Sample descriptions

    /// Builds a track from its first sample entry (video, sound, or text).
    static func describe(_ entry: Box, id: Int, kind: ContainerTrackKind) -> ContainerTrack? {
        let type = entry.type
        let data = entry.data
        switch kind {
        case .video:
            guard data.count >= 78 else { return nil }
            var atoms: [String: Data] = [:]
            for child in Box.children(of: data.dropFirst(78)) {
                atoms[child.type] = Data(child.data)
            }
            var track = ContainerTrack(id: id, kind: .video, codec: .unsupported(type), codecID: type)
            track.width = Int(Box.u16(data, 24))
            track.height = Int(Box.u16(data, 26))
            switch type {
            case "avc1", "avc3", "dva1", "dvav":
                track.codec = .h264
                track.codecPrivate = atoms["avcC"]
            case "hvc1", "hev1", "dvh1", "dvhe":
                track.codec = .hevc
                track.codecPrivate = atoms["hvcC"]
            case "av01":
                track.codec = .av1
                track.codecPrivate = atoms["av1C"]
            case "mp4v":
                let esds = atoms["esds"].flatMap(ESDS.parse)
                // The object type distinguishes MPEG-4 Part 2 from MPEG-1/2 video in 'mp4v'.
                switch esds?.objectType {
                case 0x60, 0x61, 0x62, 0x63, 0x64, 0x65: track.codec = .mpeg2Video
                case 0x6A: track.codec = .mpeg1Video
                default: track.codec = .mpeg4Part2
                }
                track.codecPrivate = esds?.decoderSpecificInfo
            case "vp08":
                track.codec = .vp8
            case "vp09":
                track.codec = .vp9
                track.codecPrivate = atoms["vpcC"]
            case "s263", "h263":
                track.codec = .h263
            case "mp2v", "hdv1", "hdv2", "hdv3", "hdv5", "hdv6", "hdv7", "hdv8", "hdv9", "hdva", "xdv1", "xdv2", "xdv3",
                 "xdv4", "xdv5", "xdv6", "xdv7", "xdv8", "xdv9", "xdva", "xdvb", "xdvc", "xdvd", "xdve", "xdvf",
                 "xd5a", "xd5b", "xd5c", "xd5d", "xd5e", "xd5f", "xd59", "xdhd", "xdh2":
                track.codec = .mpeg2Video
            case "mp1v":
                track.codec = .mpeg1Video
            case "jpeg", "mjpa", "mjpb":
                track.codec = .mjpeg
            case "apch", "apcn", "apcs", "apco", "ap4h", "ap4x", "aprh", "aprn":
                track.codec = .prores(fourCC(type))
            case "dvc ", "dvcp", "dv5n", "dv5p", "dvpp":
                track.codec = .dv(fourCC(type))
            default: break
            }
            // Color and Dolby Vision configuration travel to the decoder unchanged.
            for key in ["colr", "pasp", "dvcC", "dvvC", "mdcv", "clli"] {
                if let atom = atoms[key] { track.extraAtoms[key] = atom }
            }
            if ["dvh1", "dvhe", "dva1", "dvav"].contains(type) || atoms["dvcC"] != nil || atoms["dvvC"] != nil {
                track.hdr = .dolbyVision
            } else if let colr = atoms["colr"], colr.count >= 10, String(decoding: colr.prefix(4), as: UTF8.self) == "nclx" {
                track.hdr = HDRFormat(transferCharacteristics: Int(Box.u16(ArraySlice(colr), 6)))
            }
            return track

        case .audio:
            guard data.count >= 28 else { return nil }
            let version = Int(Box.u16(data, 8))
            var channels = Int(Box.u16(data, 16))
            var bits = Int(Box.u16(data, 18))
            var sampleRate = Double(Box.u32(data, 24) >> 16)
            var childStart = 28
            var lpcmFlags: UInt32 = 0
            if version == 1 {
                childStart = 44
            } else if version == 2, data.count >= 64 {
                sampleRate = Double(bitPattern: Box.u64(data, 32))
                channels = Int(Box.u32(data, 40))
                bits = Int(Box.u32(data, 48))
                lpcmFlags = Box.u32(data, 52)
                childStart = 64
            }
            let children = Box.children(of: data.dropFirst(childStart))
            // QuickTime nests codec boxes inside 'wave'.
            let nested = children.first { $0.type == "wave" }.map { Box.children(of: $0.data) } ?? []
            func atom(_ name: String) -> Data? {
                (children.first { $0.type == name } ?? nested.first { $0.type == name }).map { Data($0.data) }
            }
            let isLittleEndian = nested.first { $0.type == "enda" }.map { Box.u16($0.data, 0) != 0 } ?? false

            var track = ContainerTrack(id: id, kind: .audio, codec: .unsupported(type), codecID: type)
            track.channels = channels
            track.sampleRate = sampleRate
            track.bitDepth = bits
            switch type {
            case "mp4a":
                guard let esds = atom("esds").flatMap(ESDS.parse) else { break }
                switch esds.objectType {
                case 0x40, 0x66, 0x67, 0x68:
                    track.codec = .aac
                    track.codecPrivate = esds.decoderSpecificInfo
                case 0x69, 0x6B: track.codec = .mp3
                case 0xA5: track.codec = .ac3
                case 0xA6: track.codec = .eac3
                default: track.codec = .unsupported(String(format: "MPEG-4 audio 0x%02X", esds.objectType))
                }
            case ".mp3", "ms\u{0}U": track.codec = .mp3
            case "ac-3", "sac3": track.codec = .ac3
            case "ec-3": track.codec = .eac3
            case "dtsc", "dtsh", "dtsl": track.codec = .dts
            case "mlpa": track.codec = .trueHD
            case "dtse": track.codec = .unsupported("DTS Express")
            case "alac":
                track.codec = .alac
                // The 'alac' box holds version/flags, then the 24-byte ALACSpecificConfig.
                track.codecPrivate = atom("alac").map { $0.count > 24 ? $0.suffix(24) : $0 }
            case "sowt": track.codec = .pcm(bits: 16, isFloat: false, isBigEndian: false)
            case "twos": track.codec = .pcm(bits: 16, isFloat: false, isBigEndian: true)
            case "in24": track.codec = .pcm(bits: 24, isFloat: false, isBigEndian: !isLittleEndian)
            case "in32": track.codec = .pcm(bits: 32, isFloat: false, isBigEndian: !isLittleEndian)
            case "fl32": track.codec = .pcm(bits: 32, isFloat: true, isBigEndian: !isLittleEndian)
            case "fl64": track.codec = .pcm(bits: 64, isFloat: true, isBigEndian: !isLittleEndian)
            case "raw ": track.codec = .unsupported("8-bit unsigned PCM")
            case "lpcm":
                track.codec = .pcm(bits: bits, isFloat: lpcmFlags & 0x1 != 0, isBigEndian: lpcmFlags & 0x2 != 0)
            case "Opus":
                track.codec = .opus
                track.codecPrivate = atom("dOps")
            case "fLaC":
                track.codec = .flac
                track.codecPrivate = atom("dfLa")
            case "samr":
                track.codec = .amrNB
            case "sawb":
                track.codec = .amrWB
            case "ulaw":
                track.codec = .muLaw
            case "alaw":
                track.codec = .aLaw
            case "ima4":
                track.codec = .appleIMA4
            default: break
            }
            return track

        case .subtitle:
            let codec: MediaCodec = ["tx3g", "text"].contains(type) ? .tx3g : .unsupported(type == "wvtt" ? "WebVTT" : type)
            return ContainerTrack(id: id, kind: .subtitle, codec: codec, codecID: type)
        }
    }

    // MARK: Helpers

    /// 3GPP / QuickTime text sample: big-endian 16-bit length, then the text.
    static func timedText(_ data: Data) -> String? {
        guard data.count >= 2 else { return nil }
        let length = Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])
        guard length > 0, data.count >= 2 + length else { return nil }
        return String(decoding: data.subdata(in: (data.startIndex + 2)..<(data.startIndex + 2 + length)), as: UTF8.self)
    }

    /// Nero chapters ('chpl'): start times in 100 ns units with Pascal-string titles.
    static func neroChapters(_ data: ArraySlice<UInt8>) -> [ContainerChapter] {
        let version = data.first ?? 0
        var at = version == 1 ? 9 : 5
        let count = Int(Box.u8(data, at - 1))
        var starts: [(Double, String)] = []
        for _ in 0..<count {
            guard at + 9 <= data.count else { break }
            let start = Double(Box.u64(data, at)) / 10_000_000
            let length = Int(Box.u8(data, at + 8))
            let begin = data.startIndex + at + 9
            guard begin + length <= data.endIndex else { break }
            starts.append((start, String(decoding: data[begin..<(begin + length)], as: UTF8.self)))
            at += 9 + length
        }
        return starts.enumerated().map { index, item in
            ContainerChapter(title: item.1, start: item.0, end: index + 1 < starts.count ? starts[index + 1].0 : nil)
        }
    }

    /// ISO 639-2/T code packed as three 5-bit letters.
    static func language(packed: UInt16) -> String? {
        guard packed != 0, packed != 0x7FFF else { return nil }
        let letters = [(packed >> 10) & 0x1F, (packed >> 5) & 0x1F, packed & 0x1F].map { Character(UnicodeScalar(UInt8($0) + 0x60)) }
        let code = String(letters)
        return code == "und" ? nil : code
    }

    /// Product that saturates instead of trapping on damaged size fields.
    static func product(_ a: Int, _ b: Int) -> Int {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        return overflow ? Int.max : value
    }

    /// Converts to Int64, saturating non-finite and out-of-range values.
    static func clampedInt64(_ value: Double) -> Int64 {
        guard value.isFinite else { return 0 }
        if value >= 9.2e18 { return .max }
        if value <= -9.2e18 { return .min }
        return Int64(value)
    }

    static func fourCC(_ text: String) -> UInt32 {
        text.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func be32(_ data: Data, _ offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return (0..<4).reduce(0) { $0 << 8 | UInt32(data[start + $1]) }
    }
}

/// An ISO base media box within an in-memory buffer.
nonisolated struct Box {
    let type: String
    let data: ArraySlice<UInt8>

    static func children(of data: ArraySlice<UInt8>) -> [Box] {
        var boxes: [Box] = []
        var at = data.startIndex
        while at + 8 <= data.endIndex {
            let remaining = data.endIndex - at
            var size = Int(data[at..<(at + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            let type = String(decoding: data[(at + 4)..<(at + 8)], as: UTF8.self)
            var header = 8
            if size == 1, remaining >= 16 {
                // Compare 64-bit sizes against the bytes left before converting.
                let large = data[(at + 8)..<(at + 16)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                guard large <= UInt64(remaining) else { break }
                size = Int(large)
                header = 16
            } else if size == 0 {
                size = remaining
            }
            guard size >= header, size <= remaining else { break }
            boxes.append(Box(type: type, data: data[(at + header)..<(at + size)]))
            at += size
        }
        return boxes
    }

    static func child(_ type: String, in data: ArraySlice<UInt8>) -> ArraySlice<UInt8>? {
        children(of: data).first { $0.type == type }?.data
    }

    // Big-endian reads at an offset relative to the slice start; out of range reads as zero.
    static func u8(_ data: ArraySlice<UInt8>, _ offset: Int) -> UInt8 {
        let index = data.startIndex + offset
        return data.indices.contains(index) ? data[index] : 0
    }

    static func u16(_ data: ArraySlice<UInt8>, _ offset: Int) -> UInt16 {
        UInt16(u8(data, offset)) << 8 | UInt16(u8(data, offset + 1))
    }

    static func u32(_ data: ArraySlice<UInt8>, _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 << 8 | UInt32(u8(data, offset + $1)) }
    }

    static func u64(_ data: ArraySlice<UInt8>, _ offset: Int) -> UInt64 {
        (0..<8).reduce(0) { $0 << 8 | UInt64(u8(data, offset + $1)) }
    }
}
