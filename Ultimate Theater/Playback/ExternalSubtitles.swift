//
//  ExternalSubtitles.swift
//  Ultimate Theater
//
//  Subtitles that live outside the video file: sidecar files sitting next to it
//  (Movie.srt, Movie.en.srt, Movie.eng.forced.srt) and subtitles downloaded from
//  OpenSubtitles, kept in Application Support. Includes our own SubRip / WebVTT
//  parser and the OpenSubtitles file hash.
//
//  Everything read here is untrusted: sizes are capped, text is decoded defensively,
//  and nothing is ever interpreted beyond plain cue text.
//

import Foundation

// MARK: - External subtitle

/// One subtitle file offered beside a video's own tracks.
nonisolated struct ExternalSubtitle: Hashable, Sendable, Identifiable {
    enum Source: String, Codable, Sendable {
        case sidecar
        case downloaded
    }

    /// Track ID used by the engine and pickers; never collides with numeric container track IDs.
    let id: String
    let url: URL
    /// ISO 639-1 / BCP 47 code ("en", "pt-BR"), if known.
    let languageCode: String?
    /// Shown after the language, e.g. the release name of a download.
    let name: String?
    var isForced = false
    var isSDH = false
    let source: Source
}

extension ExternalSubtitle {
    var trackOption: TrackOption {
        let format = url.pathExtension.lowercased() == "vtt" ? "WebVTT" : "SubRip"
        return TrackOption(id: id, kind: .subtitle, languageCode: languageCode, name: name,
                           format: source == .downloaded ? "\(format) · Downloaded" : "\(format) · Subtitle file",
                           isForced: isForced, isSDH: isSDH)
    }
}

// MARK: - SubRip / WebVTT

nonisolated enum SubtitleFileError: LocalizedError {
    case tooLarge
    case unreadable
    case noCues

    var errorDescription: String? {
        switch self {
        case .tooLarge: "The subtitle file is too large."
        case .unreadable: "The subtitle file's text couldn't be read."
        case .noCues: "The file doesn't contain any SubRip or WebVTT subtitles."
        }
    }
}

/// Our own parser for SubRip (.srt) and WebVTT (.vtt) text subtitles.
nonisolated enum SubtitleFileParser {
    /// Real subtitle files are a few hundred KB; anything far larger isn't one.
    static let maximumFileSize = 8 << 20
    static let maximumCues = 20_000
    static let maximumCueLength = 1_000

    static func parse(contentsOf url: URL) throws -> [SubtitleCue] {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maximumFileSize else { throw SubtitleFileError.tooLarge }
        return try parse(Data(contentsOf: url, options: .mappedIfSafe))
    }

    static func parse(_ data: Data) throws -> [SubtitleCue] {
        guard data.count <= maximumFileSize else { throw SubtitleFileError.tooLarge }
        guard let text = decodeText(data) else { throw SubtitleFileError.unreadable }
        let cues = parse(text: text)
        guard !cues.isEmpty else { throw SubtitleFileError.noCues }
        return cues
    }

    /// Decodes subtitle bytes: a byte-order mark wins, then UTF-8, then Windows-1252, then Latin-1.
    static func decodeText(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(4))
        var text: String?
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            text = String(decoding: data.dropFirst(3), as: UTF8.self)
        } else if bytes.starts(with: [0xFF, 0xFE]) {
            text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            text = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        } else {
            text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .windowsCP1252)
                ?? String(data: data, encoding: .isoLatin1)
        }
        guard var text else { return nil }
        // NULs and other control characters have no place in cue text.
        text.unicodeScalars.removeAll { $0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t" }
        return text
    }

    /// Parses SubRip or WebVTT text. Tolerant of missing indexes, extra blank lines, CRLF,
    /// a missing hour field, dot or comma before milliseconds, and cue settings after the times.
    static func parse(text: String) -> [SubtitleCue] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        var cues: [SubtitleCue] = []
        var current: (start: Double, end: Double, lines: [Substring])?

        func finish() {
            guard let cue = current else { return }
            current = nil
            let body = cleaned(cue.lines.joined(separator: "\n"))
            guard !body.isEmpty, cues.count < maximumCues else { return }
            cues.append(SubtitleCue(start: cue.start, end: cue.end, text: String(body.prefix(maximumCueLength))))
        }

        for line in lines {
            if let times = timing(line) {
                if var open = current {
                    // No blank line before this cue: a bare number just above it is its index.
                    if let last = open.lines.last, last.allSatisfy(\.isNumber) { open.lines.removeLast() }
                    current = open
                    finish()
                }
                current = times.end > times.start ? (times.start, times.end, []) : nil
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                finish()
            } else if current != nil {
                current?.lines.append(line)
            }
            // Anything else (indexes, the WEBVTT header, NOTE / STYLE / REGION blocks) is skipped.
        }
        finish()
        return cues.sorted { $0.start < $1.start }
    }

    /// "00:01:02,345 --> 00:01:04,000" (SubRip) or "01:02.345 --> 01:04.000 align:start" (WebVTT).
    static func timing(_ line: Substring) -> (start: Double, end: Double)? {
        guard let arrow = line.range(of: "-->") else { return nil }
        let left = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
        let right = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
        let endToken = right.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard let start = timestamp(left), let end = timestamp(endToken) else { return nil }
        return (start, end)
    }

    /// Seconds from "[h]h:mm:ss[,.]fff", "mm:ss.fff", or the odd "hh:mm:ss:fff".
    static func timestamp(_ text: String) -> Double? {
        var fields = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (2...4).contains(fields.count) else { return nil }
        var fraction = 0.0
        if fields.count == 4 {
            // hh:mm:ss:fff — milliseconds after a colon.
            let digits = fields.removeLast()
            guard !digits.isEmpty, digits.count <= 3, digits.allSatisfy(\.isASCIIDigit), let value = Double(digits) else { return nil }
            fraction = value / pow(10, Double(digits.count))
        }
        let last = fields.removeLast()
        let secondParts = last.split(omittingEmptySubsequences: false) { $0 == "," || $0 == "." }
        guard (1...2).contains(secondParts.count), let seconds = Int(secondParts[0]),
              secondParts[0].allSatisfy(\.isASCIIDigit), !secondParts[0].isEmpty else { return nil }
        if secondParts.count == 2 {
            let digits = secondParts[1].prefix(3)
            guard !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit), let value = Double(digits) else { return nil }
            fraction = value / pow(10, Double(digits.count))
        }
        var total = Double(seconds) + fraction
        var multiplier = 60.0
        for field in fields.reversed() {
            guard !field.isEmpty, field.count <= 3, field.allSatisfy(\.isASCIIDigit), let value = Double(field) else { return nil }
            total += value * multiplier
            multiplier *= 60
        }
        return total.isFinite && total >= 0 ? total : nil
    }

    /// Plain cue text: markup tags, ASS override blocks, and common entities removed.
    static func cleaned(_ raw: String) -> String {
        var text = raw.replacing(/\{\\[^}]*\}/, with: "")
        text = SubtitleText.plain(text, isASS: false)
        for (entity, value) in ["&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&lrm;": "", "&rlm;": "", "&quot;": "\"", "&#39;": "'", "&amp;": "&"] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Character {
    nonisolated var isASCIIDigit: Bool { isASCII && isNumber }
}

// MARK: - OpenSubtitles hash

/// The OpenSubtitles "moviehash": the file size plus the 64-bit little-endian sums of the
/// first and last 64 KiB, wrapping on overflow, as 16 lowercase hex digits.
nonisolated enum OpenSubtitlesHash {
    static let chunkSize = 65_536

    static func compute(url: URL) throws -> String? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size >= UInt64(chunkSize) else { return nil }
        try handle.seek(toOffset: 0)
        let head = try handle.read(upToCount: chunkSize) ?? Data()
        try handle.seek(toOffset: size - UInt64(chunkSize))
        let tail = try handle.read(upToCount: chunkSize) ?? Data()
        guard head.count == chunkSize, tail.count == chunkSize else { return nil }
        return hash(size: size, head: head, tail: tail)
    }

    static func hash(size: UInt64, head: Data, tail: Data) -> String {
        var sum = size
        for chunk in [head, tail] {
            chunk.withUnsafeBytes { buffer in
                var offset = 0
                while offset + 8 <= buffer.count {
                    sum &+= UInt64(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
                    offset += 8
                }
            }
        }
        let hex = String(sum, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }
}

// MARK: - Sidecar files

nonisolated enum SidecarSubtitles {
    static let extensions: Set<String> = ["srt", "vtt"]

    struct Info: Equatable {
        var languageCode: String?
        var isForced = false
        var isSDH = false
    }

    /// ISO 639-2/B codes the system doesn't map to ISO 639-1.
    private static let bibliographic: [String: String] = [
        "alb": "sq", "arm": "hy", "baq": "eu", "bur": "my", "chi": "zh", "cze": "cs", "dut": "nl", "fre": "fr",
        "geo": "ka", "ger": "de", "gre": "el", "ice": "is", "mac": "mk", "mao": "mi", "may": "ms", "per": "fa",
        "rum": "ro", "slo": "sk", "tib": "bo", "wel": "cy", "scc": "sr", "scr": "hr", "pob": "pt-BR",
    ]

    /// English language names ("english", "spanish") to codes.
    private static let languageNames: [String: String] = {
        var names: [String: String] = [:]
        let english = Locale(identifier: "en")
        for code in Locale.LanguageCode.isoLanguageCodes {
            guard code.identifier.count == 2, let name = english.localizedString(forLanguageCode: code.identifier) else { continue }
            names[name.lowercased()] = code.identifier
        }
        return names
    }()

    /// Language and flags from a sidecar's name, or nil if it doesn't belong to the video.
    /// "Movie.srt" → unknown language; "Movie.en.srt", "Movie.eng.forced.srt", "Movie.English.sdh.srt".
    static func info(forSidecar fileName: String, videoBaseName: String) -> Info? {
        let url = URL(fileURLWithPath: fileName)
        guard extensions.contains(url.pathExtension.lowercased()) else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        let base = videoBaseName.lowercased()
        let lowered = stem.lowercased()
        guard lowered == base || lowered.hasPrefix(base + ".") else { return nil }
        let tokens = lowered.dropFirst(base.count).split(separator: ".").map(String.init)

        var info = Info()
        var hasHI = false
        for token in tokens {
            switch token {
            case "forced", "foreign": info.isForced = true
            case "sdh", "cc": info.isSDH = true
            case "hi": hasHI = true
            case "default", "full": break
            default:
                if info.languageCode == nil { info.languageCode = languageCode(token) }
            }
        }
        // "hi" is Hindi on its own, and "hearing impaired" beside another language.
        if hasHI {
            if info.languageCode == nil { info.languageCode = "hi" } else { info.isSDH = true }
        }
        return info
    }

    /// "en", "eng", "fre", "pt-br", "english" → a BCP 47 code, or nil.
    static func languageCode(_ token: String) -> String? {
        let token = token.lowercased()
        if let code = bibliographic[token] { return code }
        if let code = languageNames[token] { return code }
        let parts = token.split(separator: "-", maxSplits: 1).map(String.init)
        guard let first = parts.first, (2...3).contains(first.count), first.allSatisfy(\.isLetter),
              let alpha2 = Locale.LanguageCode(first).identifier(.alpha2) else { return nil }
        if parts.count == 2 {
            guard (2...4).contains(parts[1].count) else { return nil }
            return "\(alpha2)-\(parts[1].uppercased())"
        }
        return alpha2
    }

    /// Sidecars in the video's folder. Empty when the folder can't be listed (sandbox, offline drive).
    static func find(nextTo videoURL: URL) -> [ExternalSubtitle] {
        let folder = videoURL.deletingLastPathComponent()
        let base = videoURL.deletingPathExtension().lastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.sorted().compactMap { name in
            guard let info = info(forSidecar: name, videoBaseName: base) else { return nil }
            return ExternalSubtitle(id: "ext:file:\(name)", url: folder.appending(path: name), languageCode: info.languageCode,
                                    name: nil, isForced: info.isForced, isSDH: info.isSDH, source: .sidecar)
        }
    }
}

// MARK: - Downloaded subtitles

/// Downloaded subtitles in Application Support: Subtitles/<playback id>/<lang>.srt, with an
/// index of what each file is.
nonisolated enum ExternalSubtitleLibrary {
    struct Record: Codable, Hashable {
        var fileName: String
        var languageCode: String?
        var release: String?
        var isSDH: Bool
        var isForced: Bool
        var openSubtitlesFileID: Int?
        var downloadedAt: Date
    }

    private static let indexName = "subtitles.json"

    static var directory: URL {
        URL.applicationSupportDirectory
            .appending(path: "Ultimate Theater", directoryHint: .isDirectory)
            .appending(path: "Subtitles", directoryHint: .isDirectory)
    }

    static func folder(for playbackID: String) -> URL {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        var name = String(playbackID.map { allowed.contains($0) ? $0 : "_" }.prefix(120))
        if name.isEmpty || name != playbackID {
            // Keep differently-spelled IDs apart after sanitizing.
            name += "-" + String(stableHash(playbackID), radix: 16)
        }
        return directory.appending(path: name, directoryHint: .isDirectory)
    }

    /// FNV-1a, stable across launches (unlike `hashValue`).
    private static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }

    static func records(for playbackID: String) -> [Record] {
        let url = folder(for: playbackID).appending(path: indexName)
        guard let data = try? Data(contentsOf: url), data.count < 1 << 20 else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    private static func write(_ records: [Record], for playbackID: String) throws {
        let data = try JSONEncoder().encode(records)
        try data.write(to: folder(for: playbackID).appending(path: indexName), options: .atomic)
    }

    static func downloaded(for playbackID: String) -> [ExternalSubtitle] {
        let folder = folder(for: playbackID)
        return records(for: playbackID).compactMap { record in
            let url = folder.appending(path: record.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return ExternalSubtitle(id: "ext:dl:\(record.fileName)", url: url, languageCode: record.languageCode,
                                    name: record.release.map(shortName) ?? "Downloaded",
                                    isForced: record.isForced, isSDH: record.isSDH, source: .downloaded)
        }
    }

    /// Sidecars next to the video, then downloads. Call with the video's file access open.
    static func subtitles(for playbackID: String, videoURL: URL?) -> [ExternalSubtitle] {
        (videoURL.map(SidecarSubtitles.find(nextTo:)) ?? []) + downloaded(for: playbackID)
    }

    /// Saves validated subtitle text as UTF-8 and records it. A file already downloaded is replaced.
    static func save(text: String, format: String, playbackID: String, languageCode: String?, release: String?,
                     isSDH: Bool, isForced: Bool, openSubtitlesFileID: Int?) throws -> ExternalSubtitle {
        let folder = folder(for: playbackID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var records = records(for: playbackID)
        let ext = format == "vtt" ? "vtt" : "srt"
        let fileName: String
        if let fileID = openSubtitlesFileID, let existing = records.firstIndex(where: { $0.openSubtitlesFileID == fileID }) {
            fileName = records.remove(at: existing).fileName
        } else {
            let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
            let language = String((languageCode ?? "und").filter { allowed.contains($0) }.prefix(12))
            var candidate = "\(language.isEmpty ? "und" : language).\(ext)"
            var number = 2
            let taken = Set(records.map(\.fileName))
            while taken.contains(candidate) || FileManager.default.fileExists(atPath: folder.appending(path: candidate).path) {
                candidate = "\(language)-\(number).\(ext)"
                number += 1
            }
            fileName = candidate
        }
        try Data(text.utf8).write(to: folder.appending(path: fileName), options: .atomic)
        let record = Record(fileName: fileName, languageCode: languageCode, release: release.map { String($0.prefix(200)) },
                            isSDH: isSDH, isForced: isForced, openSubtitlesFileID: openSubtitlesFileID, downloadedAt: .now)
        records.append(record)
        try write(records, for: playbackID)
        return downloaded(for: playbackID).first { $0.id == "ext:dl:\(fileName)" }
            ?? ExternalSubtitle(id: "ext:dl:\(fileName)", url: folder.appending(path: fileName), languageCode: languageCode,
                                name: "Downloaded", isForced: isForced, isSDH: isSDH, source: .downloaded)
    }

    /// Forgets the downloads for removed movies or episodes.
    static func remove(playbackIDs: [String]) {
        for id in playbackIDs {
            try? FileManager.default.removeItem(at: folder(for: id))
        }
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Release names get long; keep enough to tell downloads apart.
    private static func shortName(_ release: String) -> String {
        let trimmed = release.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Downloaded" }
        return trimmed.count > 40 ? String(trimmed.prefix(39)) + "…" : trimmed
    }
}

// MARK: - Title page

extension MediaInspector {
    /// A file's own tracks plus its sidecar and downloaded subtitles. Call with file access open.
    static func trackList(for url: URL, playbackID: String) async -> MediaTrackList {
        var list = await trackList(for: url)
        let external = await Task.detached { ExternalSubtitleLibrary.subtitles(for: playbackID, videoURL: url) }.value
        list.subtitles += external.map(\.trackOption)
        return list
    }
}
