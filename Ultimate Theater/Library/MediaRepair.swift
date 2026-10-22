//
//  MediaRepair.swift
//  Ultimate Theater
//
//  Finds and fixes the most common kinds of damage in every container the Theater
//  engine reads, writing a repaired copy:
//
//   • MP4/MOV: missing index (see MovieRepair.swift); cut-off file with an intact index.
//   • AVI: missing or broken index (idx1); cut-off file with wrong sizes.
//   • MKV/WebM: cut-off segment or cluster; missing seek index (Cues) or duration.
//   • MPEG-TS/M2TS: lost sync, damaged or partial packets.
//   • MPEG-PS (MPG/VOB): cut-off pack or missing end code.
//   • FLV: cut-off tags, wrong duration in the metadata.
//   • Ogg: pages with bad checksums, cut-off pages, missing end-of-stream flags.
//

import Foundation

/// Damage found in a file and how it will be fixed.
nonisolated struct RepairPlan: Sendable {
    enum Kind: Sendable {
        case mp4MissingIndex
        case mp4Truncated
        case avi
        case matroska
        case transportStream(packetSize: Int, syncOffset: Int)
        case programStream
        case flv
        case ogg
    }

    let kind: Kind
    let format: String
    /// Plain-language descriptions of each problem.
    let findings: [String]
    /// Extension for the repaired copy.
    let fileExtension: String
}

nonisolated enum MediaRepairError: LocalizedError {
    case unsupported(String)
    case nothingToKeep

    var errorDescription: String? {
        switch self {
        case .unsupported(let detail): "This damage can't be repaired automatically: \(detail)."
        case .nothingToKeep: "No playable media could be found in this file."
        }
    }
}

nonisolated enum MediaRepair {
    /// Checks a file. Returns nil when no damage was found.
    static func diagnose(_ url: URL) throws -> RepairPlan? {
        let source = try FileByteSource(url: url)
        let head = try source.read(at: 0, count: 8192)
        let ext = url.pathExtension.lowercased()
        if head.count >= 8, ["ftyp", "moov", "mdat", "free", "wide", "skip", "pnot"].contains(String(decoding: head[4..<8], as: UTF8.self)) {
            return try MP4Fixer.diagnose(source, ext: ext.isEmpty ? "mp4" : ext)
        }
        if head.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return try MatroskaFixer.diagnose(source, ext: ext.isEmpty ? "mkv" : ext) }
        if head.count >= 12, head.prefix(4) == Data("RIFF".utf8), head[8..<12] == Data("AVI ".utf8) { return try AVIFixer.diagnose(source) }
        if OggDemuxer.matches(head) { return try OggFixer.diagnose(source, ext: ext.isEmpty ? "ogg" : ext) }
        if FLVDemuxer.matches(head) { return try FLVFixer.diagnose(source) }
        if ProgramStreamReader.matches(head) { return try ProgramStreamFixer.diagnose(source, ext: ext.isEmpty ? "mpg" : ext) }
        if let layout = TransportStreamFixer.layout(of: [UInt8](head)) {
            return try TransportStreamFixer.diagnose(source, layout: layout, ext: ext.isEmpty ? "ts" : ext)
        }
        return nil
    }

    /// Writes a repaired copy and returns what was done.
    static func repair(_ plan: RepairPlan, source url: URL, to output: URL, progress: (Double) -> Void) throws -> [String] {
        let source = try FileByteSource(url: url)
        let writer = try RepairWriter(url: output)
        defer { writer.close() }
        switch plan.kind {
        case .mp4MissingIndex: throw MediaRepairError.unsupported("a missing MP4 index needs a matching reference movie")
        case .mp4Truncated: return try MP4Fixer.repair(source, url: url, writer: writer, progress: progress)
        case .avi: return try AVIFixer.repair(source, writer: writer, progress: progress)
        case .matroska: return try MatroskaFixer.repair(source, writer: writer, progress: progress)
        case .transportStream(let size, let sync): return try TransportStreamFixer.repair(source, size: size, sync: sync, writer: writer, progress: progress)
        case .programStream: return try ProgramStreamFixer.repair(source, writer: writer, progress: progress)
        case .flv: return try FLVFixer.repair(source, writer: writer, progress: progress)
        case .ogg: return try OggFixer.repair(source, writer: writer, progress: progress)
        }
    }

    static func describe(bytes: UInt64) -> String {
        Int64(bytes).formatted(.byteCount(style: .file))
    }
}

// MARK: - Output

/// Buffered output with random-access patches.
nonisolated final class RepairWriter {
    private let handle: FileHandle
    private var buffer = Data()
    private(set) var position: UInt64 = 0

    init(url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteNoPermission) }
        handle = try FileHandle(forWritingTo: url)
    }

    func write(_ data: Data) throws {
        buffer.append(data)
        position += UInt64(data.count)
        if buffer.count >= 8 << 20 { try flush() }
    }

    func write(_ bytes: [UInt8]) throws { try write(Data(bytes)) }

    /// Copies a byte range of the source in chunks.
    func copy(from source: FileByteSource, range: Range<UInt64>, progress: (UInt64) -> Void = { _ in }) throws {
        var at = range.lowerBound
        while at < range.upperBound {
            let count = Int(min(UInt64(4 << 20), range.upperBound - at))
            let chunk = try source.read(at: at, count: count)
            guard !chunk.isEmpty else { break }
            try write(chunk)
            at += UInt64(chunk.count)
            progress(at)
        }
    }

    /// Overwrites bytes already written.
    func patch(_ data: Data, at offset: UInt64) throws {
        try flush()
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: data)
        try handle.seekToEnd()
    }

    func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    func close() {
        try? flush()
        try? handle.close()
    }
}

private nonisolated func be32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
private nonisolated func be64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
private nonisolated func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

// MARK: - MP4 / MOV

nonisolated enum MP4Fixer {
    struct TopBox {
        let type: String
        let offset: UInt64
        let headerLength: UInt64
        let declaredSize: UInt64
    }

    static func topBoxes(_ source: FileByteSource) throws -> [TopBox] {
        var boxes: [TopBox] = []
        var offset: UInt64 = 0
        while offset + 8 <= source.size {
            let header = try source.read(at: offset, count: 16)
            var size = UInt64(header.prefix(4).bigEndianUInt)
            var headerLength: UInt64 = 8
            if size == 1, header.count >= 16 { size = UInt64(header[8..<16].bigEndianUInt); headerLength = 16 }
            if size == 0 { size = source.size - offset }
            guard size >= headerLength else { break }
            boxes.append(TopBox(type: String(decoding: header[4..<8], as: UTF8.self), offset: offset, headerLength: headerLength, declaredSize: size))
            offset += size
        }
        return boxes
    }

    static func diagnose(_ source: FileByteSource, ext: String) throws -> RepairPlan? {
        let boxes = try topBoxes(source)
        guard let moov = boxes.first(where: { $0.type == "moov" }) else {
            guard boxes.contains(where: { $0.type == "mdat" }) else { return nil }
            return RepairPlan(kind: .mp4MissingIndex, format: "MP4", findings: [
                "The index that describes the video and audio is missing, usually because a copy or encode was interrupted.",
            ], fileExtension: ext)
        }
        guard moov.offset + moov.declaredSize <= source.size else { return nil } // A cut-off index can't be trusted.
        let tracks = try trackTables(source, moov: moov)
        let missing = tracks.reduce(0) { $0 + ($1.samples.count - $1.keptCount(fileSize: source.size)) }
        let cut = boxes.last.map { $0.offset + $0.declaredSize > source.size } ?? false
        guard missing > 0 || cut else { return nil }
        var findings = ["The file was cut off before the end (\(MediaRepair.describe(bytes: source.size)) of \(MediaRepair.describe(bytes: (boxes.last.map { $0.offset + $0.declaredSize }) ?? source.size)) present)."]
        if missing > 0 { findings.append("\(missing.formatted()) video and audio samples listed in the index are missing, so playback stops or fails near the end.") }
        return RepairPlan(kind: .mp4Truncated, format: "MP4", findings: findings, fileExtension: ext)
    }

    struct Sample {
        let offset: UInt64
        let size: UInt32
        let descriptionIndex: UInt32
    }

    struct TrackTables {
        var samples: [Sample] = []
        var durations: [(count: UInt32, delta: UInt32)] = []
        var compositionOffsets: [(count: UInt32, offset: UInt32)]?
        var cttsVersion: UInt8 = 0
        var syncSamples: Set<UInt32>?

        func keptCount(fileSize: UInt64) -> Int {
            samples.firstIndex { $0.offset + UInt64($0.size) > fileSize } ?? samples.count
        }
    }

    private static func boxBody(_ data: Data, _ path: [String]) -> Data? {
        var current = data
        for type in path {
            guard let child = MP4Boxes.child(type, of: current) else { return nil }
            current = child
        }
        return current
    }

    private static func u32(_ d: Data, _ at: Int) -> UInt32 { UInt32(d[(d.startIndex + at)..<(d.startIndex + at + 4)].bigEndianUInt) }
    private static func u64(_ d: Data, _ at: Int) -> UInt64 { UInt64(d[(d.startIndex + at)..<(d.startIndex + at + 8)].bigEndianUInt) }

    static func trackTables(_ source: FileByteSource, moov: TopBox) throws -> [TrackTables] {
        let data = try source.read(at: moov.offset + moov.headerLength, count: Int(moov.declaredSize - moov.headerLength))
        return MP4Boxes.children(of: data).filter { $0.type == "trak" }.compactMap { trak in
            boxBody(trak.body, ["mdia", "minf", "stbl"]).flatMap(tables(fromSampleTable:))
        }
    }

    static func tables(fromSampleTable stbl: Data) -> TrackTables? {
        guard let stsz = MP4Boxes.child("stsz", of: stbl), let stsc = MP4Boxes.child("stsc", of: stbl),
              let stts = MP4Boxes.child("stts", of: stbl) else { return nil }
        var chunkOffsets: [UInt64] = []
        if let co = MP4Boxes.child("stco", of: stbl) {
            chunkOffsets = (0..<Int(u32(co, 4))).map { UInt64(u32(co, 8 + $0 * 4)) }
        } else if let co = MP4Boxes.child("co64", of: stbl) {
            chunkOffsets = (0..<Int(u32(co, 4))).map { u64(co, 8 + $0 * 8) }
        } else { return nil }
        let uniform = u32(stsz, 4)
        let count = Int(u32(stsz, 8))
        let sizes: [UInt32] = uniform != 0 ? Array(repeating: uniform, count: count) : (0..<count).map { u32(stsz, 12 + $0 * 4) }
        let entries = (0..<Int(u32(stsc, 4))).map { (first: Int(u32(stsc, 8 + $0 * 12)), perChunk: Int(u32(stsc, 12 + $0 * 12)), description: u32(stsc, 16 + $0 * 12)) }

        var tables = TrackTables()
        var sampleIndex = 0
        for (chunk, chunkOffset) in chunkOffsets.enumerated() where sampleIndex < count {
            let chunkNumber = chunk + 1
            guard let entry = entries.last(where: { $0.first <= chunkNumber }) else { continue }
            var offset = chunkOffset
            for _ in 0..<entry.perChunk where sampleIndex < count {
                tables.samples.append(Sample(offset: offset, size: sizes[sampleIndex], descriptionIndex: entry.description))
                offset += UInt64(sizes[sampleIndex])
                sampleIndex += 1
            }
        }
        tables.durations = (0..<Int(u32(stts, 4))).map { (u32(stts, 8 + $0 * 8), u32(stts, 12 + $0 * 8)) }
        if let ctts = MP4Boxes.child("ctts", of: stbl) {
            tables.cttsVersion = ctts.first ?? 0
            tables.compositionOffsets = (0..<Int(u32(ctts, 4))).map { (u32(ctts, 8 + $0 * 8), u32(ctts, 12 + $0 * 8)) }
        }
        if let stss = MP4Boxes.child("stss", of: stbl) {
            tables.syncSamples = Set((0..<Int(u32(stss, 4))).map { u32(stss, 8 + $0 * 4) })
        }
        return tables
    }

    /// Run-length entries truncated to the first `count` samples.
    private static func truncate<T>(_ runs: [(count: UInt32, value: T)], to count: Int) -> [(count: UInt32, value: T)] {
        var left = UInt32(count)
        var result: [(count: UInt32, value: T)] = []
        for run in runs where left > 0 {
            let take = min(run.count, left)
            result.append((take, run.value))
            left -= take
        }
        return result
    }

    static func repair(_ source: FileByteSource, url: URL, writer: RepairWriter, progress: (Double) -> Void) throws -> [String] {
        let boxes = try topBoxes(source)
        guard let moov = boxes.first(where: { $0.type == "moov" }) else { throw MediaRepairError.unsupported("the index is missing") }
        let moovData = try source.read(at: moov.offset + moov.headerLength, count: Int(moov.declaredSize - moov.headerLength))

        // Rebuild every track's sample tables with only the samples that are present.
        var movieTimescale: UInt32 = 1000
        if let mvhd = MP4Boxes.child("mvhd", of: moovData) { movieTimescale = (mvhd.first ?? 0) == 1 ? u32(mvhd, 20) : u32(mvhd, 12) }
        var longest: UInt64 = 0
        var dropped = 0
        var newMoov = Data()
        for child in MP4Boxes.children(of: moovData) {
            guard child.type == "trak" else {
                if child.type != "mvhd" { newMoov.append(child.whole) }
                continue
            }
            let (trak, movieDuration, removed) = rebuildTrack(child.body, fileSize: source.size, movieTimescale: movieTimescale)
            newMoov.append(MovieIndexWriter.box("trak", trak))
            longest = max(longest, movieDuration)
            dropped += removed
        }
        if var mvhd = MP4Boxes.child("mvhd", of: moovData) {
            if (mvhd.first ?? 0) == 1 { mvhd.replaceSubrange((mvhd.startIndex + 24)..<(mvhd.startIndex + 32), with: be64(longest)) }
            else { mvhd.replaceSubrange((mvhd.startIndex + 16)..<(mvhd.startIndex + 20), with: be32(UInt32(min(longest, UInt64(UInt32.max))))) }
            newMoov = MovieIndexWriter.box("mvhd", mvhd) + newMoov
        }

        // Copy the file, retire the old index, end the media data where the file ends,
        // and add the new index.
        try writer.copy(from: source, range: 0..<source.size) { progress(Double($0) / Double(source.size)) }
        try writer.patch(Data("free".utf8), at: moov.offset + 4)
        if let mdat = boxes.last(where: { $0.type == "mdat" }), mdat.offset + mdat.declaredSize > source.size {
            let size = source.size - mdat.offset
            if mdat.headerLength == 16 { try writer.patch(be64(size), at: mdat.offset + 8) }
            else if size <= UInt64(UInt32.max) { try writer.patch(be32(UInt32(size)), at: mdat.offset) }
        }
        try writer.write(MovieIndexWriter.box("moov", newMoov))
        let seconds = Double(longest) / Double(max(movieTimescale, 1))
        return ["Rebuilt the index for the \(Int(seconds / 60)) min \(Int(seconds) % 60) sec that are present (\(dropped.formatted()) missing samples removed)."]
    }

    /// Returns the rebuilt track, its duration in the movie timescale, and how many samples were removed.
    private static func rebuildTrack(_ trak: Data, fileSize: UInt64, movieTimescale: UInt32) -> (Data, UInt64, Int) {
        guard let mdia = MP4Boxes.child("mdia", of: trak), let mdhd = MP4Boxes.child("mdhd", of: mdia),
              let minf = MP4Boxes.child("minf", of: mdia), let stbl = MP4Boxes.child("stbl", of: minf),
              let tables = tables(fromSampleTable: stbl) else { return (trak, 0, 0) }
        let kept = tables.keptCount(fileSize: fileSize)
        let timescale = (mdhd.first ?? 0) == 1 ? u32(mdhd, 20) : u32(mdhd, 12)
        let durations = truncate(tables.durations.map { ($0.count, $0.delta) }, to: kept)
        let mediaDuration = durations.reduce(UInt64(0)) { $0 + UInt64($1.count) * UInt64($1.value) }
        let movieDuration = UInt64((Double(mediaDuration) / Double(max(timescale, 1)) * Double(movieTimescale)).rounded())

        // New sample table: one sample per chunk keeps chunk bookkeeping simple.
        let samples = tables.samples.prefix(kept)
        var parts = Data()
        if let stsd = MP4Boxes.box("stsd", in: stbl) { parts.append(stsd) }
        var stts = be32(UInt32(durations.count))
        for run in durations { stts.append(be32(run.count) + be32(run.value)) }
        parts.append(MovieIndexWriter.fullBox("stts", stts))
        if let offsets = tables.compositionOffsets {
            let runs = truncate(offsets.map { ($0.count, $0.offset) }, to: kept)
            var ctts = be32(UInt32(runs.count))
            for run in runs { ctts.append(be32(run.count) + be32(run.value)) }
            parts.append(MovieIndexWriter.fullBox("ctts", version: tables.cttsVersion, ctts))
        }
        if let sync = tables.syncSamples {
            let keptSync = sync.filter { $0 <= UInt32(kept) }.sorted()
            var stss = be32(UInt32(keptSync.count))
            for number in keptSync { stss.append(be32(number)) }
            parts.append(MovieIndexWriter.fullBox("stss", stss))
        }
        var stsc = Data()
        var stscCount: UInt32 = 0
        var lastDescription: UInt32 = 0
        for (index, sample) in samples.enumerated() where sample.descriptionIndex != lastDescription {
            stsc.append(be32(UInt32(index + 1)) + be32(1) + be32(sample.descriptionIndex))
            stscCount += 1
            lastDescription = sample.descriptionIndex
        }
        parts.append(MovieIndexWriter.fullBox("stsc", be32(stscCount) + stsc))
        var stsz = be32(0) + be32(UInt32(kept))
        for sample in samples { stsz.append(be32(sample.size)) }
        parts.append(MovieIndexWriter.fullBox("stsz", stsz))
        var co64 = be32(UInt32(kept))
        for sample in samples { co64.append(be64(sample.offset)) }
        parts.append(MovieIndexWriter.fullBox("co64", co64))
        // Other sample-table boxes that don't depend on the sample count are kept.
        for child in MP4Boxes.children(of: stbl) where !["stsd", "stts", "ctts", "stss", "stsc", "stsz", "stz2", "stco", "co64", "sdtp", "sbgp"].contains(child.type) {
            parts.append(child.whole)
        }
        let newStbl = MovieIndexWriter.box("stbl", parts)

        // Patch durations on the way back up the tree.
        var newMdhd = mdhd
        if (mdhd.first ?? 0) == 1 { newMdhd.replaceSubrange((newMdhd.startIndex + 24)..<(newMdhd.startIndex + 32), with: be64(mediaDuration)) }
        else { newMdhd.replaceSubrange((newMdhd.startIndex + 16)..<(newMdhd.startIndex + 20), with: be32(UInt32(min(mediaDuration, UInt64(UInt32.max))))) }
        let newMinf = MP4Boxes.children(of: minf).reduce(into: Data()) { $0.append($1.type == "stbl" ? newStbl : Data($1.whole)) }
        let newMdia = MP4Boxes.children(of: mdia).reduce(into: Data()) { result, child in
            switch child.type {
            case "mdhd": result.append(MovieIndexWriter.box("mdhd", newMdhd))
            case "minf": result.append(MovieIndexWriter.box("minf", newMinf))
            default: result.append(child.whole)
            }
        }
        let newTrak = MP4Boxes.children(of: trak).reduce(into: Data()) { result, child in
            switch child.type {
            case "tkhd":
                var tkhd = Data(child.body)
                if (tkhd.first ?? 0) == 1 { tkhd.replaceSubrange((tkhd.startIndex + 28)..<(tkhd.startIndex + 36), with: be64(movieDuration)) }
                else { tkhd.replaceSubrange((tkhd.startIndex + 20)..<(tkhd.startIndex + 24), with: be32(UInt32(min(movieDuration, UInt64(UInt32.max))))) }
                result.append(MovieIndexWriter.box("tkhd", tkhd))
            case "edts":
                result.append(MovieIndexWriter.box("edts", clampEditList(Data(child.body), to: movieDuration)))
            case "mdia":
                result.append(MovieIndexWriter.box("mdia", newMdia))
            default:
                result.append(child.whole)
            }
        }
        return (newTrak, movieDuration, tables.samples.count - kept)
    }

    /// Shortens edit list segments that run past the track's new end.
    private static func clampEditList(_ edts: Data, to duration: UInt64) -> Data {
        MP4Boxes.children(of: edts).reduce(into: Data()) { result, child in
            guard child.type == "elst" else { result.append(child.whole); return }
            var elst = Data(child.body)
            let version = elst.first ?? 0
            let count = Int(u32(elst, 4))
            let entrySize = version == 1 ? 20 : 12
            var remaining = duration
            for index in 0..<count {
                let at = 8 + index * entrySize
                guard at + entrySize <= elst.count else { break }
                let segment = version == 1 ? u64(elst, at) : UInt64(u32(elst, at))
                let clamped = min(segment, remaining)
                remaining -= clamped
                if version == 1 { elst.replaceSubrange((elst.startIndex + at)..<(elst.startIndex + at + 8), with: be64(clamped)) }
                else { elst.replaceSubrange((elst.startIndex + at)..<(elst.startIndex + at + 4), with: be32(UInt32(clamped))) }
            }
            result.append(MovieIndexWriter.box("elst", elst))
        }
    }
}

// MARK: - AVI

nonisolated enum AVIFixer {
    private struct Chunk {
        let id: String
        let offset: UInt64   // Of the chunk header, in the source.
        let size: UInt32
    }

    private struct Layout {
        var riffSize: UInt64 = 0
        var before: [Range<UInt64>] = []   // Chunks before 'movi' (hdrl, INFO, JUNK…), in order.
        var hdrl: Range<UInt64>?
        var moviHeader: UInt64?
        var chunks: [Chunk] = []
        var hasIndex = false
        var indexValid = false
        var isOpenDML = false
        var truncated = false
    }

    private static func layout(_ source: FileByteSource) throws -> Layout {
        var layout = Layout()
        let head = [UInt8](try source.read(at: 0, count: 12))
        layout.riffSize = UInt64(UInt32(head[4]) | UInt32(head[5]) << 8 | UInt32(head[6]) << 16 | UInt32(head[7]) << 24)
        layout.truncated = layout.riffSize + 8 > source.size
        var at: UInt64 = 12
        while at + 8 <= min(source.size, layout.riffSize + 8) {
            let h = [UInt8](try source.read(at: at, count: 12))
            guard h.count >= 8 else { break }
            let id = String(decoding: h[0..<4], as: UTF8.self)
            let size = UInt64(UInt32(h[4]) | UInt32(h[5]) << 8 | UInt32(h[6]) << 16 | UInt32(h[7]) << 24)
            let end = at + 8 + size + (size & 1)
            let listType = h.count >= 12 ? String(decoding: h[8..<12], as: UTF8.self) : ""
            if id == "LIST", listType == "movi" {
                layout.moviHeader = at
                walkMovi(source, from: at + 12, to: min(end, source.size), into: &layout.chunks)
                if end > source.size { layout.truncated = true; break }
            } else if id == "idx1" {
                layout.hasIndex = true
                layout.indexValid = end <= source.size && size >= 16
            } else if end <= source.size {
                if id == "LIST", listType == "hdrl" {
                    layout.hdrl = at..<end
                    let hdrl = try source.read(at: at, count: Int(end - at))
                    if hdrl.range(of: Data("indx".utf8)) != nil { layout.isOpenDML = true }
                }
                if layout.moviHeader == nil { layout.before.append(at..<end) }
            } else {
                layout.truncated = true
                break
            }
            at = end
        }
        if source.size > layout.riffSize + 8 + 12, try source.read(at: layout.riffSize + 8 + 8, count: 4) == Data("AVIX".utf8) {
            layout.isOpenDML = true
        }
        return layout
    }

    private static func walkMovi(_ source: FileByteSource, from start: UInt64, to end: UInt64, into chunks: inout [Chunk]) {
        var at = start
        while at + 8 <= end {
            guard let h = try? [UInt8](source.read(at: at, count: 12)), h.count >= 8 else { break }
            let id = String(decoding: h[0..<4], as: UTF8.self)
            let size = UInt32(h[4]) | UInt32(h[5]) << 8 | UInt32(h[6]) << 16 | UInt32(h[7]) << 24
            let next = at + 8 + UInt64(size) + UInt64(size & 1)
            if id == "LIST" {
                walkMovi(source, from: at + 12, to: min(next, end), into: &chunks)
            } else if next <= source.size || at + 8 + UInt64(size) <= source.size {
                let valid = id.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x41 && $0 <= 0x5A) }
                guard valid else { break } // Garbage: the rest is damaged.
                if id != "JUNK" { chunks.append(Chunk(id: id, offset: at, size: size)) }
            } else {
                break // Cut off.
            }
            at = next
        }
    }

    static func diagnose(_ source: FileByteSource) throws -> RepairPlan? {
        let layout = try layout(source)
        var findings: [String] = []
        if layout.truncated { findings.append("The file was cut off before the end, so its recorded sizes are wrong.") }
        if !layout.hasIndex { findings.append("The index is missing, so seeking is slow or impossible.") }
        else if !layout.indexValid { findings.append("The index is damaged.") }
        // Large (OpenDML) AVIs span several parts with their own indexes; rebuilding them
        // isn't supported, and they rarely lack an index.
        guard !findings.isEmpty, !layout.isOpenDML else { return nil }
        return RepairPlan(kind: .avi, format: "AVI", findings: findings, fileExtension: "avi")
    }

    static func repair(_ source: FileByteSource, writer: RepairWriter, progress: (Double) -> Void) throws -> [String] {
        let layout = try layout(source)
        guard layout.moviHeader != nil, let hdrl = layout.hdrl else { throw MediaRepairError.unsupported("the header is damaged") }
        guard !layout.chunks.isEmpty else { throw MediaRepairError.nothingToKeep }

        // Stream types and codecs from the header, to flag keyframes.
        let header = try source.read(at: hdrl.lowerBound, count: Int(hdrl.count))
        let streamHandlers = streamCodecs(in: header)

        try writer.write(Data("RIFF".utf8) + le32(0) + Data("AVI ".utf8))
        var counts: [Int: Int] = [:]
        for chunk in layout.chunks {
            if let stream = Int(chunk.id.prefix(2)), chunk.id.hasSuffix("dc") || chunk.id.hasSuffix("db") { counts[stream, default: 0] += 1 }
        }
        for range in layout.before {
            var data = try source.read(at: range.lowerBound, count: Int(range.count))
            if range == hdrl { data = patchHeader(data, videoFrames: counts) }
            try writer.write(data)
        }
        let moviStart = writer.position
        try writer.write(Data("LIST".utf8) + le32(0) + Data("movi".utf8))
        var index = Data()
        let total = Double(layout.chunks.count)
        for (number, chunk) in layout.chunks.enumerated() {
            let offsetInMovi = UInt32(writer.position - (moviStart + 8))
            let available = min(UInt64(chunk.size), source.size - (chunk.offset + 8))
            let data = try source.read(at: chunk.offset + 8, count: Int(available))
            try writer.write(Data(chunk.id.utf8) + le32(UInt32(data.count)) + data + (data.count % 2 == 1 ? Data([0]) : Data()))
            let stream = Int(chunk.id.prefix(2)) ?? 0
            let isVideo = chunk.id.hasSuffix("dc") || chunk.id.hasSuffix("db")
            let key = !isVideo || isKeyframe(data, codec: streamHandlers[stream] ?? "")
            index.append(Data(chunk.id.utf8) + le32(key ? 0x10 : 0) + le32(offsetInMovi) + le32(UInt32(data.count)))
            if number % 500 == 0 { progress(Double(number) / total) }
        }
        try writer.patch(le32(UInt32(writer.position - moviStart - 8)), at: moviStart + 4)
        try writer.write(Data("idx1".utf8) + le32(UInt32(index.count)) + index)
        try writer.patch(le32(UInt32(writer.position - 8)), at: 4)
        progress(1)
        var done = ["Rebuilt the index with \(layout.chunks.count.formatted()) entries."]
        if layout.truncated { done.append("Ended the file cleanly after the last complete frame and corrected its sizes.") }
        return done
    }

    /// Video stream codecs (FourCC) by stream number.
    private static func streamCodecs(in hdrl: Data) -> [Int: String] {
        var result: [Int: String] = [:]
        var stream = 0
        let b = [UInt8](hdrl)
        var i = 0
        while i + 8 <= b.count {
            let id = String(decoding: b[i..<(i + 4)], as: UTF8.self)
            if id == "strh", i + 16 <= b.count {
                let type = String(decoding: b[(i + 8)..<(i + 12)], as: UTF8.self)
                if type == "vids" { result[stream] = String(decoding: b[(i + 12)..<(i + 16)], as: UTF8.self).uppercased() }
                stream += 1
            }
            i += 1
        }
        return result
    }

    private static func isKeyframe(_ data: Data, codec: String) -> Bool {
        if ["H264", "X264", "AVC1", "DAVC"].contains(codec) {
            return AnnexB.nalUnits(in: data.prefix(4096)).contains { ($0.first ?? 0) & 0x1F == 5 }
        }
        if ["XVID", "DIVX", "DX50", "FMP4", "MP4V", "DIV3", "MP43"].contains(codec) {
            return MPEG4Part2.vopType(in: data) == .intra
        }
        return true // MJPEG, uncompressed, and unknown codecs: every frame stands alone.
    }

    /// Sets the frame count and has-index flag in the main header.
    private static func patchHeader(_ hdrl: Data, videoFrames: [Int: Int]) -> Data {
        var data = hdrl
        guard let avih = data.range(of: Data("avih".utf8)) else { return data }
        let fields = avih.upperBound + 4
        if fields + 20 <= data.endIndex {
            let flagsAt = fields + 12
            var flags = UInt32(data[flagsAt]) | UInt32(data[flagsAt + 1]) << 8 | UInt32(data[flagsAt + 2]) << 16 | UInt32(data[flagsAt + 3]) << 24
            flags |= 0x10 // AVIF_HASINDEX
            data.replaceSubrange(flagsAt..<(flagsAt + 4), with: le32(flags))
            if let frames = videoFrames.sorted(by: { $0.key < $1.key }).first?.value {
                data.replaceSubrange((fields + 16)..<(fields + 20), with: le32(UInt32(frames)))
            }
        }
        return data
    }
}

// MARK: - Matroska / WebM

nonisolated enum MatroskaFixer {
    private static let segmentID: UInt32 = 0x18538067
    private static let seekHeadID: UInt32 = 0x114D9B74
    private static let infoID: UInt32 = 0x1549A966
    private static let tracksID: UInt32 = 0x1654AE6B
    private static let clusterID: UInt32 = 0x1F43B675
    private static let cuesID: UInt32 = 0x1C53BB6B
    private static let voidID: UInt32 = 0xEC
    private static let durationID: UInt32 = 0x4489
    private static let timecodeScaleID: UInt32 = 0x2AD7B1
    private static let unknownSize: UInt64 = (1 << 56) - 1

    private struct Element {
        let id: UInt32
        let offset: UInt64      // Of the header.
        let headerLength: Int
        let size: UInt64?       // nil = unknown size
    }

    private struct Scan {
        var ebmlHeader: Range<UInt64> = 0..<0
        var segmentDataStart: UInt64 = 0
        var segmentSizeKnown = true
        var segmentEnd: UInt64 = 0
        var topLevel: [Element] = []
        var truncated = false
    }

    private static func readElement(_ source: FileByteSource, at offset: UInt64) throws -> Element? {
        let bytes = try source.read(at: offset, count: 12)
        var reader = ByteReader(bytes)
        guard let id = try? EBML.readID(&reader), let (size, sizeLength) = try? EBML.readSize(&reader) else { return nil }
        let idLength = reader.position - sizeLength
        let isUnknown = size == (UInt64(1) << (7 * sizeLength)) - 1
        return Element(id: id, offset: offset, headerLength: idLength + sizeLength, size: isUnknown ? nil : size)
    }

    private static func scan(_ source: FileByteSource) throws -> Scan {
        var scan = Scan()
        guard let ebml = try readElement(source, at: 0), let ebmlSize = ebml.size else { throw ContainerError.corrupt("no EBML header") }
        scan.ebmlHeader = 0..<(UInt64(ebml.headerLength) + ebmlSize)
        guard let segment = try readElement(source, at: scan.ebmlHeader.upperBound), segment.id == segmentID else {
            throw ContainerError.corrupt("no segment")
        }
        scan.segmentDataStart = segment.offset + UInt64(segment.headerLength)
        scan.segmentSizeKnown = segment.size != nil
        let declaredEnd = segment.size.map { scan.segmentDataStart + $0 } ?? source.size
        scan.segmentEnd = min(declaredEnd, source.size)
        if declaredEnd > source.size { scan.truncated = true }
        var at = scan.segmentDataStart
        while at < scan.segmentEnd, let element = try readElement(source, at: at) {
            scan.topLevel.append(element)
            if let size = element.size {
                let end = at + UInt64(element.headerLength) + size
                if end > source.size { scan.truncated = true; break }
                at = end
            } else {
                // Unknown size (live recordings): find the next top-level element.
                guard let next = try nextTopLevel(source, after: at + UInt64(element.headerLength), limit: scan.segmentEnd) else {
                    break
                }
                at = next
            }
        }
        return scan
    }

    /// The next cluster or other top-level element, scanning children of an unknown-size cluster.
    private static func nextTopLevel(_ source: FileByteSource, after start: UInt64, limit: UInt64) throws -> UInt64? {
        var at = start
        let topIDs: Set<UInt32> = [clusterID, cuesID, infoID, tracksID, seekHeadID, 0x1043A770, 0x1254C367, 0x1941A469]
        while at < limit, let element = try readElement(source, at: at) {
            if topIDs.contains(element.id) { return at }
            guard let size = element.size else { return nil }
            at += UInt64(element.headerLength) + size
        }
        return nil
    }

    static func diagnose(_ source: FileByteSource, ext: String) throws -> RepairPlan? {
        let scan = try scan(source)
        var findings: [String] = []
        if scan.truncated { findings.append("The file was cut off before the end; the last part of the video is incomplete.") }
        if !scan.topLevel.contains(where: { $0.id == cuesID }) { findings.append("The seek index (Cues) is missing, so jumping around the video is slow.") }
        if !scan.segmentSizeKnown || scan.topLevel.contains(where: { $0.id == clusterID && $0.size == nil }) {
            findings.append("Parts of the file have no recorded size (common in recordings that were stopped abruptly).")
        }
        if let info = scan.topLevel.first(where: { $0.id == infoID }), let size = info.size {
            let data = try source.read(at: info.offset + UInt64(info.headerLength), count: Int(size))
            if !EBML.children(ArraySlice(data)).contains(where: { $0.id == durationID }) { findings.append("The duration is missing.") }
        }
        guard !findings.isEmpty else { return nil }
        return RepairPlan(kind: .matroska, format: ext == "webm" ? "WebM" : "Matroska", findings: findings, fileExtension: ext)
    }

    // EBML writing.
    private static func id(_ value: UInt32) -> Data {
        let bytes = withUnsafeBytes(of: value.bigEndian) { Array($0) }
        return Data(bytes.drop { $0 == 0 })
    }
    private static func size(_ value: UInt64, length: Int = 8) -> Data {
        var bytes = [UInt8](repeating: 0, count: length)
        var v = value
        for index in stride(from: length - 1, through: 0, by: -1) { bytes[index] = UInt8(v & 0xFF); v >>= 8 }
        bytes[0] |= UInt8(0x80 >> (length - 1))
        return Data(bytes)
    }
    private static func element(_ elementID: UInt32, _ payload: Data) -> Data { id(elementID) + size(UInt64(payload.count)) + payload }
    private static func uint(_ elementID: UInt32, _ value: UInt64) -> Data { element(elementID, be64(value)) }

    static func repair(_ source: FileByteSource, writer: RepairWriter, progress: (Double) -> Void) throws -> [String] {
        let scan = try scan(source)
        // Header-level elements to keep, and the clusters.
        var info: Data?
        var timecodeScale: UInt64 = 1_000_000
        var keep: [(id: UInt32, data: Data)] = []
        var videoTrack: UInt64?
        for element in scan.topLevel where element.id != clusterID {
            guard let size = element.size, ![seekHeadID, cuesID, voidID].contains(element.id) else { continue }
            let data = try source.read(at: element.offset, count: element.headerLength + Int(size))
            let body = data.dropFirst(element.headerLength)
            if element.id == infoID {
                info = Data(body)
                if let scale = EBML.children(ArraySlice(body)).first(where: { $0.id == timecodeScaleID }) { timecodeScale = EBML.uint(scale.data) }
            } else {
                if element.id == tracksID { videoTrack = Self.videoTrackNumber(Data(body)) }
                keep.append((element.id, Data(data)))
            }
        }
        guard let info else { throw MediaRepairError.unsupported("the segment information is missing") }

        // Copy clusters (fixing unknown or cut-off sizes) to a temporary list of complete clusters.
        let clusters = scan.topLevel.filter { $0.id == clusterID }
        guard !clusters.isEmpty else { throw MediaRepairError.nothingToKeep }

        // Layout: EBML header, Segment (known size), SeekHead, Info, kept elements, Clusters, Cues.
        try writer.copy(from: source, range: scan.ebmlHeader)
        let segmentHeaderAt = writer.position
        try writer.write(id(segmentID) + size(0))
        let segmentStart = writer.position
        // Each Seek entry is 42 bytes as written here (8-byte sizes); the rest is a Void.
        let seekEntries = 1 + keep.count + 1 // Info, the kept elements, Cues
        let seekHeadSize = 12 + 42 * seekEntries + 16
        let seekHeadAt = writer.position
        try writer.write(Data(count: seekHeadSize)) // Filled in at the end.
        var positions: [(UInt32, UInt64)] = []
        // Info with a placeholder duration (the last element), patched once the clusters are read.
        positions.append((infoID, writer.position - segmentStart))
        var infoChildren = EBML.children(ArraySlice(info)).filter { $0.id != durationID }.reduce(into: Data()) { result, child in
            result.append(id(child.id) + size(UInt64(child.data.count)) + Data(child.data))
        }
        infoChildren.append(element(durationID, be64(0)))
        try writer.write(element(infoID, infoChildren))
        let durationValueAt = writer.position - 8
        for (elementID, data) in keep {
            positions.append((elementID, writer.position - segmentStart))
            try writer.write(data)
        }

        var cues: [(time: UInt64, position: UInt64)] = []
        var lastTime: UInt64 = 0
        let total = Double(clusters.count)
        for (number, cluster) in clusters.enumerated() {
            let start = cluster.offset + UInt64(cluster.headerLength)
            let end: UInt64 = {
                if let size = cluster.size { return min(start + size, scan.segmentEnd) }
                return (number + 1 < clusters.count) ? clusters[number + 1].offset : scan.segmentEnd
            }()
            let body = try source.read(at: start, count: Int(end - start))
            var children = Data()
            var clusterTime: UInt64 = 0
            var hasKeyframe = false
            var reader = ByteReader(body)
            while !reader.isAtEnd {
                let elementStart = reader.position
                guard let childID = try? EBML.readID(&reader), let (childSize, _) = try? EBML.readSize(&reader),
                      reader.remaining >= Int(childSize) else { break } // Cut off: keep what's complete.
                let payload = try reader.take(Int(childSize))
                children.append(Data(body[(body.startIndex + elementStart)..<(body.startIndex + reader.position)]))
                if childID == 0xE7 { clusterTime = EBML.uint(payload) }
                if childID == 0xA3 || childID == 0xA0 {
                    let block = childID == 0xA3 ? payload : (EBML.children(payload).first { $0.id == 0xA1 }?.data ?? [])
                    if let (track, time, key) = blockInfo(block, isSimple: childID == 0xA3) {
                        let absolute = UInt64(max(0, Int64(clusterTime) + Int64(time)))
                        lastTime = max(lastTime, absolute)
                        if track == videoTrack, key, !hasKeyframe {
                            hasKeyframe = true
                            cues.append((absolute, writer.position - segmentStart))
                        }
                    }
                }
            }
            guard !children.isEmpty else { continue }
            if videoTrack == nil, !hasKeyframe { cues.append((clusterTime, writer.position - segmentStart)) }
            try writer.write(element(clusterID, children))
            if number % 50 == 0 { progress(Double(number) / total) }
        }

        // Cues.
        positions.append((cuesID, writer.position - segmentStart))
        var cuePoints = Data()
        for cue in cues {
            let positionsElement = element(0xB7, uint(0xF7, videoTrack ?? 1) + uint(0xF1, cue.position))
            cuePoints.append(element(0xBB, uint(0xB3, cue.time) + positionsElement))
        }
        try writer.write(element(cuesID, cuePoints))
        let segmentEnd = writer.position

        try writer.patch(be64(Double(lastTime + 1).bitPattern), at: durationValueAt)

        // SeekHead, padded likewise.
        var seeks = Data()
        for (elementID, position) in positions {
            seeks.append(element(0x4DBB, element(0x53AB, id(elementID)) + uint(0x53AC, position)))
        }
        let seekHead = element(seekHeadID, seeks)
        try writer.patch(seekHead + voidPadding(seekHeadSize - seekHead.count), at: seekHeadAt)
        try writer.patch(id(segmentID) + size(segmentEnd - segmentStart), at: segmentHeaderAt)
        progress(1)

        let seconds = Double(lastTime) * Double(timecodeScale) / 1_000_000_000
        var done = ["Rebuilt the seek index with \(cues.count.formatted()) entries and recorded the duration (\(Int(seconds / 60)) min \(Int(seconds) % 60) sec)."]
        if scan.truncated { done.append("Ended the file cleanly after the last complete frame.") }
        return done
    }

    /// A Void element filling exactly `count` bytes (at least 2).
    private static func voidPadding(_ count: Int) -> Data {
        guard count >= 2 else { return Data(count: max(0, count)) }
        if count < 9 { return Data([0xEC, 0x80 | UInt8(count - 2)]) + Data(count: count - 2) }
        return id(voidID) + size(UInt64(count - 9)) + Data(count: count - 9)
    }

    private static func videoTrackNumber(_ tracks: Data) -> UInt64? {
        for entry in EBML.children(ArraySlice(tracks)) where entry.id == 0xAE {
            let fields = EBML.children(entry.data)
            if let type = fields.first(where: { $0.id == 0x83 }), EBML.uint(type.data) == 1,
               let number = fields.first(where: { $0.id == 0xD7 }) {
                return EBML.uint(number.data)
            }
        }
        return nil
    }

    private static func blockInfo(_ block: ArraySlice<UInt8>, isSimple: Bool) -> (UInt64, Int16, Bool)? {
        var reader = ByteReader(Array(block))
        guard let (track, _) = try? EBML.readSize(&reader), let time = try? reader.u16be(), let flags = try? reader.u8() else { return nil }
        return (track, Int16(bitPattern: time), isSimple ? flags & 0x80 != 0 : true)
    }
}

// MARK: - MPEG transport stream

nonisolated enum TransportStreamFixer {
    static func layout(of b: [UInt8]) -> (size: Int, sync: Int)? {
        for (size, sync) in [(188, 0), (192, 4), (204, 0)] {
            for start in 0..<min(size, max(0, b.count - size * 4)) {
                let first = start + sync
                guard first < b.count, b[first] == 0x47 else { continue }
                if (1..<4).allSatisfy({ first + $0 * size < b.count && b[first + $0 * size] == 0x47 }) { return (size, sync) }
            }
        }
        return nil
    }

    /// Counts lost-sync regions and the partial last packet.
    private static func survey(_ source: FileByteSource, size: Int, sync: Int) throws -> (bad: Int, garbage: UInt64, partial: Bool) {
        var at: UInt64 = 0
        var bad = 0
        var garbage: UInt64 = 0
        while at + UInt64(size) <= source.size {
            let chunkSize = min(UInt64(size * 4096), source.size - at)
            let chunk = [UInt8](try source.read(at: at, count: Int(chunkSize)))
            var i = 0
            while i + size <= chunk.count {
                if chunk[i + sync] == 0x47 { i += size; continue }
                bad += 1
                // Resync within the chunk.
                var j = i + 1
                while j + size <= chunk.count, !(chunk[j + sync] == 0x47 && (j + sync + size >= chunk.count || chunk[j + sync + size] == 0x47)) { j += 1 }
                garbage += UInt64(j - i)
                i = j
            }
            at += UInt64(i)
            if i == 0 { break }
        }
        return (bad, garbage, (source.size - at) % UInt64(size) != 0 || source.size % UInt64(size) != 0)
    }

    static func diagnose(_ source: FileByteSource, layout: (size: Int, sync: Int), ext: String) throws -> RepairPlan? {
        let result = try survey(source, size: layout.size, sync: layout.sync)
        var findings: [String] = []
        if result.bad > 0 { findings.append("\(result.bad.formatted()) damaged regions (\(MediaRepair.describe(bytes: result.garbage))) break the stream, causing glitches or stalls.") }
        if source.size % UInt64(layout.size) != 0 { findings.append("The file ends partway through a packet.") }
        guard !findings.isEmpty else { return nil }
        return RepairPlan(kind: .transportStream(packetSize: layout.size, syncOffset: layout.sync), format: layout.size == 192 ? "M2TS" : "MPEG-TS",
                          findings: findings, fileExtension: ext)
    }

    static func repair(_ source: FileByteSource, size: Int, sync: Int, writer: RepairWriter, progress: (Double) -> Void) throws -> [String] {
        var at: UInt64 = 0
        var kept = 0
        var dropped: UInt64 = 0
        while at + UInt64(size) <= source.size {
            let chunk = [UInt8](try source.read(at: at, count: Int(min(UInt64(size * 4096), source.size - at))))
            var out = Data()
            var i = 0
            while i + size <= chunk.count {
                if chunk[i + sync] == 0x47, i + size + sync >= chunk.count || chunk[i + size + sync] == 0x47 || i + size == chunk.count {
                    out.append(contentsOf: chunk[i..<(i + size)])
                    kept += 1
                    i += size
                } else {
                    i += 1
                    dropped += 1
                }
            }
            try writer.write(out)
            guard i > 0 else { break }
            at += UInt64(i)
            progress(Double(at) / Double(source.size))
        }
        dropped += source.size - at
        return ["Kept \(kept.formatted()) intact packets and removed \(MediaRepair.describe(bytes: dropped)) of damaged data."]
    }
}

// MARK: - MPEG program stream

nonisolated enum ProgramStreamFixer {
    /// The end of the last complete pack or PES, and whether the stream ends with an end code.
    private static func lastCompleteEnd(_ source: FileByteSource) throws -> (end: UInt64, hasEndCode: Bool) {
        var at: UInt64 = 0
        var lastGood: UInt64 = 0
        var hasEnd = false
        while at + 4 <= source.size {
            let h = [UInt8](try source.read(at: at, count: 16))
            guard h.count >= 4, h[0] == 0, h[1] == 0, h[2] == 1 else { break }
            let length: UInt64
            switch h[3] {
            case 0xBA:
                guard h.count >= 14 else { return (lastGood, hasEnd) }
                length = h[4] & 0xC0 == 0x40 ? 14 + UInt64(h[13] & 0x07) : 12
            case 0xB9:
                length = 4
                hasEnd = true
            default:
                guard h.count >= 6, h[3] >= 0xBB else { return (lastGood, hasEnd) }
                length = 6 + UInt64(Int(h[4]) << 8 | Int(h[5]))
            }
            guard at + length <= source.size else { break }
            at += length
            lastGood = at
        }
        return (lastGood, hasEnd)
    }

    static func diagnose(_ source: FileByteSource, ext: String) throws -> RepairPlan? {
        let (end, hasEndCode) = try lastCompleteEnd(source)
        var findings: [String] = []
        if end < source.size { findings.append("The file ends with \(MediaRepair.describe(bytes: source.size - end)) of incomplete or damaged data.") }
        if !hasEndCode, end == source.size { return nil }
        guard !findings.isEmpty else { return nil }
        return RepairPlan(kind: .programStream, format: "MPEG", findings: findings, fileExtension: ext)
    }

    static func repair(_ source: FileByteSource, writer: RepairWriter, progress: (Double) -> Void) throws -> [String] {
        let (end, hasEndCode) = try lastCompleteEnd(source)
        guard end > 0 else { throw MediaRepairError.nothingToKeep }
        try writer.copy(from: source, range: 0..<end) { progress(Double($0) / Double(end)) }
        if !hasEndCode { try writer.write([0, 0, 1, 0xB9]) }
        return ["Removed \(MediaRepair.describe(bytes: source.size - end)) of incomplete data and ended the stream properly."]
    }
}

// MARK: - FLV

nonisolated enum FLVFixer {
    private static func tags(_ source: FileByteSource) throws -> (headerEnd: UInt64, tags: [(offset: UInt64, length: UInt64, time: UInt32)], end: UInt64) {
        let header = [UInt8](try source.read(at: 0, count: 9))
        let headerEnd = UInt64(UInt32(header[5]) << 24 | UInt32(header[6]) << 16 | UInt32(header[7]) << 8 | UInt32(header[8])) + 4
        var at = headerEnd
        var list: [(UInt64, UInt64, UInt32)] = []
        while at + 15 <= source.size {
            let h = [UInt8](try source.read(at: at, count: 11))
            let size = UInt64(h[1]) << 16 | UInt64(h[2]) << 8 | UInt64(h[3])
            let length = 11 + size + 4
            guard [8, 9, 18].contains(h[0] & 0x1F), at + length <= source.size else { break }
            let trailer = [UInt8](try source.read(at: at + 11 + size, count: 4))
            guard UInt64(UInt32(trailer[0]) << 24 | UInt32(trailer[1]) << 16 | UInt32(trailer[2]) << 8 | UInt32(trailer[3])) == 11 + size else { break }
            list.append((at, length, UInt32(h[7]) << 24 | UInt32(h[4]) << 16 | UInt32(h[5]) << 8 | UInt32(h[6])))
            at += length
        }
        return (headerEnd, list, at)
    }

    static func diagnose(_ source: FileByteSource) throws -> RepairPlan? {
        let scan = try tags(source)
        guard scan.end < source.size else { return nil }
        return RepairPlan(kind: .flv, format: "FLV", findings: [
            "The file ends with \(MediaRepair.describe(bytes: source.size - scan.end)) of incomplete or damaged data.",
        ], fileExtension: "flv")
    }

    static func repair(_ source: FileByteSource, writer: RepairWriter, progress: (Double) -> Void) throws -> [String] {
        let scan = try tags(source)
        guard !scan.tags.isEmpty else { throw MediaRepairError.nothingToKeep }
        try writer.copy(from: source, range: 0..<scan.end) { progress(Double($0) / Double(scan.end)) }
        // Correct the duration in onMetaData, when it's there.
        let duration = Double(scan.tags.map(\.time).max() ?? 0) / 1000
        if let script = scan.tags.first(where: { $0.offset < scan.end }),
           let data = try? source.read(at: script.offset, count: Int(min(script.length, 4096))),
           data.first.map({ $0 & 0x1F == 18 }) == true,
           let key = data.range(of: Data([0x00, 0x08]) + Data("duration".utf8)), key.upperBound + 9 <= data.endIndex,
           data[key.upperBound] == 0x00 {
            let at = script.offset + UInt64(key.upperBound - data.startIndex) + 1
            try writer.patch(be64(duration.bitPattern), at: at)
        }
        return ["Removed \(MediaRepair.describe(bytes: source.size - scan.end)) of incomplete data and corrected the duration."]
    }
}

// MARK: - Ogg

nonisolated enum OggFixer {
    private static let crcTable: [UInt32] = (0..<256).map { index in
        var r = UInt32(index) << 24
        for _ in 0..<8 { r = r & 0x8000_0000 != 0 ? (r << 1) ^ 0x04C1_1DB7 : r << 1 }
        return r
    }

    static func crc(_ bytes: [UInt8]) -> UInt32 {
        bytes.reduce(UInt32(0)) { ($0 << 8) ^ crcTable[Int(($0 >> 24) ^ UInt32($1))] }
    }

    private struct Page {
        let offset: UInt64
        let length: Int
        let serial: UInt32
        let flags: UInt8
        let valid: Bool
    }

    private static func pages(_ source: FileByteSource) throws -> (pages: [Page], skipped: UInt64) {
        var at: UInt64 = 0
        var result: [Page] = []
        var skipped: UInt64 = 0
        while at + 27 <= source.size {
            let head = [UInt8](try source.read(at: at, count: 27))
            guard head[0...3].elementsEqual("OggS".utf8) else {
                // Resync to the next capture pattern.
                let window = [UInt8](try source.read(at: at + 1, count: 64 << 10))
                guard let found = (0..<max(0, window.count - 3)).first(where: { window[$0] == 0x4F && window[$0 + 1] == 0x67 && window[$0 + 2] == 0x67 && window[$0 + 3] == 0x53 }) else {
                    skipped += source.size - at
                    break
                }
                skipped += UInt64(found + 1)
                at += UInt64(found + 1)
                continue
            }
            let segments = Int(head[26])
            let lacing = [UInt8](try source.read(at: at + 27, count: segments))
            let length = 27 + segments + lacing.reduce(0) { $0 + Int($1) }
            guard lacing.count == segments, at + UInt64(length) <= source.size else { skipped += source.size - at; break }
            var bytes = [UInt8](try source.read(at: at, count: length))
            let stored = UInt32(bytes[22]) | UInt32(bytes[23]) << 8 | UInt32(bytes[24]) << 16 | UInt32(bytes[25]) << 24
            bytes[22] = 0; bytes[23] = 0; bytes[24] = 0; bytes[25] = 0
            let serial = UInt32(head[14]) | UInt32(head[15]) << 8 | UInt32(head[16]) << 16 | UInt32(head[17]) << 24
            result.append(Page(offset: at, length: length, serial: serial, flags: head[5], valid: crc(bytes) == stored))
            at += UInt64(length)
        }
        return (result, skipped)
    }

    static func diagnose(_ source: FileByteSource, ext: String) throws -> RepairPlan? {
        let (pages, skipped) = try pages(source)
        var findings: [String] = []
        let bad = pages.filter { !$0.valid }.count
        if bad > 0 { findings.append("\(bad) pages are damaged (their checksums don't match).") }
        if skipped > 0 { findings.append("\(MediaRepair.describe(bytes: skipped)) of the file is incomplete or unreadable.") }
        let serials = Set(pages.map(\.serial))
        let ended = Set(pages.filter { $0.flags & 4 != 0 }.map(\.serial))
        if !serials.isSubset(of: ended) { findings.append("The stream doesn't end properly.") }
        guard !findings.isEmpty else { return nil }
        return RepairPlan(kind: .ogg, format: "Ogg", findings: findings, fileExtension: ext)
    }

    static func repair(_ source: FileByteSource, writer: RepairWriter, progress: (Double) -> Void) throws -> [String] {
        let (pages, _) = try pages(source)
        let good = pages.filter(\.valid)
        guard !good.isEmpty else { throw MediaRepairError.nothingToKeep }
        // The last page of each stream gets the end-of-stream flag (and a new checksum).
        var lastOfStream: [UInt32: UInt64] = [:]
        for page in good { lastOfStream[page.serial] = page.offset }
        for (index, page) in good.enumerated() {
            var bytes = [UInt8](try source.read(at: page.offset, count: page.length))
            if lastOfStream[page.serial] == page.offset, bytes[5] & 4 == 0 {
                bytes[5] |= 4
                bytes[22] = 0; bytes[23] = 0; bytes[24] = 0; bytes[25] = 0
                let value = crc(bytes)
                bytes[22] = UInt8(value & 0xFF); bytes[23] = UInt8(value >> 8 & 0xFF)
                bytes[24] = UInt8(value >> 16 & 0xFF); bytes[25] = UInt8(value >> 24)
            }
            try writer.write(bytes)
            if index % 200 == 0 { progress(Double(index) / Double(good.count)) }
        }
        return ["Kept \(good.count.formatted()) intact pages, removed \(pages.count - good.count) damaged ones, and ended each stream properly."]
    }
}
