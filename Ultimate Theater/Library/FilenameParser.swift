//
//  FilenameParser.swift
//  Ultimate Theater
//
//  Turns media filenames into a title, year, and (for TV) season/episode numbers.
//  Handles common conventions:
//    The.Matrix.1999.1080p.BluRay.x264.mkv      → "The Matrix" (1999)
//    Severance - S01E02 - Half Loop.mp4         → "Severance" S1E2 "Half Loop"
//    the.office.us.2x05.mp4                     → "The Office Us" S2E5
//    Star Trek Enterprise Season 4 Episode 22 - These Are the Voyages
//                                               → "Star Trek Enterprise" S4E22 "These Are the Voyages"
//    Breaking Bad/Season 3/07 - One Minute.m4v  → "Breaking Bad" S3E7
//

import Foundation

nonisolated struct ParsedMediaName: Equatable, Sendable {
    var title: String
    var year: Int?
    var season: Int?
    var episode: Int?
    var episodeTitle: String?

    var isEpisode: Bool { season != nil && episode != nil }
}

nonisolated enum FilenameParser {
    /// Everything the Theater engine reads, plus formats it can identify but not yet decode.
    static let videoExtensions: Set<String> = Demuxers.supportedExtensions.union(["wmv", "asf"])

    static func isVideoFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard videoExtensions.contains(ext) else { return false }
        // Skip scene "sample" clips that ship alongside full files.
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        return !(name == "sample" || name.hasSuffix("-sample") || name.hasSuffix(".sample"))
    }

    static func parse(url: URL) -> ParsedMediaName {
        let filename = url.deletingPathExtension().lastPathComponent
        // Nearest folder first, e.g. ["Season 1", "Severance", "TV"].
        let folders = url.deletingLastPathComponent().pathComponents.reversed().filter { $0 != "/" }
        return parse(filename: filename, folders: Array(folders.prefix(3)))
    }

    static func parse(filename: String, folders: [String] = []) -> ParsedMediaName {
        let name = removeBracketedGroups(filename)

        // 1. S01E02 / s1e2 / S01.E02
        if let match = name.firstMatch(of: /[Ss](\d{1,2})[ ._-]*[Ee](\d{1,3})/) {
            return episode(show: String(name[..<match.range.lowerBound]),
                           season: Int(match.1), number: Int(match.2),
                           remainder: String(name[match.range.upperBound...]), folders: folders)
        }

        // 2. Spelled out: "Season 4 Episode 22", "Series 2, Ep. 3", "S4 E22"
        if let match = name.firstMatch(of: Self.spelledOutEpisode) {
            return episode(show: String(name[..<match.range.lowerBound]),
                           season: Int(match.1), number: Int(match.2),
                           remainder: String(name[match.range.upperBound...]), folders: folders)
        }

        // 3. 1x02
        if let match = name.firstMatch(of: /(?:^|[^0-9])(\d{1,2})x(\d{2,3})(?![0-9])/) {
            return episode(show: String(name[..<match.range.lowerBound]),
                           season: Int(match.1), number: Int(match.2),
                           remainder: String(name[match.range.upperBound...]), folders: folders)
        }

        // 4. "Show/Season 3/07 - Title", or "Show/Season 3/Show Episode 7 - Title"
        if let seasonFolder = folders.first,
           let seasonMatch = seasonFolder.wholeMatch(of: /(?:[Ss]eason|[Ss]eries|[Ss])[ ._-]*(\d{1,2})/) {
            let show = folders.count > 1 ? folders[1] : ""
            if let episodeMatch = name.firstMatch(of: /^(?:[Ee]pisode|[Ee][Pp]?)?[ ._-]*(\d{1,3})(?![0-9])/) {
                return episode(show: show, season: Int(seasonMatch.1), number: Int(episodeMatch.1),
                               remainder: String(name[episodeMatch.range.upperBound...]), folders: Array(folders.dropFirst()))
            }
            if let episodeMatch = name.firstMatch(of: Self.spelledOutEpisodeOnly) {
                // The folder names the show; text before "Episode" usually repeats it.
                return episode(show: show, season: Int(seasonMatch.1), number: Int(episodeMatch.1),
                               remainder: String(name[episodeMatch.range.upperBound...]), folders: Array(folders.dropFirst()))
            }
        }

        // 5. Movie
        var movie = splitYear(clean(name))
        if isGeneric(movie.title), let folder = folders.first {
            // "Inception (2010)/movie.mkv" → use the folder.
            movie = splitYear(clean(removeBracketedGroups(folder)))
        } else if movie.year == nil, let folder = folders.first {
            // Borrow a year from a matching folder name: "Heat (1995)/Heat.mkv".
            let fromFolder = splitYear(clean(removeBracketedGroups(folder)))
            if normalizedKey(fromFolder.title) == normalizedKey(movie.title) {
                movie.year = fromFolder.year
            }
        }
        return ParsedMediaName(title: titleCase(movie.title), year: movie.year)
    }

    /// Lowercased alphanumerics without a leading "the", for grouping and comparing titles.
    static func normalizedKey(_ title: String) -> String {
        var key = title.lowercased().filter { $0.isLetter || $0.isNumber }
        if key.hasPrefix("the"), key.count > 3 { key.removeFirst(3) }
        return key
    }

    // MARK: Helpers

    private static func episode(show rawShow: String, season: Int?, number: Int?,
                                remainder: String, folders: [String]) -> ParsedMediaName {
        var show = splitYear(clean(rawShow))
        if isGeneric(show.title) {
            // "Season 1/S01E02.mkv" → the show is the next folder up.
            let candidates = folders.filter { $0.wholeMatch(of: /(?:[Ss]eason|[Ss]eries|[Ss])[ ._-]*\d{1,2}/) == nil }
            if let folder = candidates.first {
                show = splitYear(clean(removeBracketedGroups(folder)))
            }
        }
        let episodeTitle = clean(remainder)
        return ParsedMediaName(
            title: titleCase(show.title),
            year: show.year,
            season: season,
            episode: number,
            episodeTitle: episodeTitle.isEmpty ? nil : episodeTitle
        )
    }

    /// "Season 4 Episode 22", "Season 4, Episode 22", "Series 2 Ep. 3", "S4 E22" (as whole words).
    private static let spelledOutEpisode = /\b(?:season|series|s)[ ._-]*(\d{1,2})[ ._,-]*(?:episode|ep\.?|e)[ ._-]*(\d{1,3})(?![0-9])/.ignoresCase().wordBoundaryKind(.simple)

    /// "Episode 22" / "Ep. 22" / "E22" on its own (the season comes from the folder).
    private static let spelledOutEpisodeOnly = /\b(?:episode|ep\.?|e)[ ._-]*(\d{1,3})(?![0-9])/.ignoresCase().wordBoundaryKind(.simple)

    /// Release tags that mark the end of the human-readable title.
    private static let releaseTag = /(?:2160p|1080p|1080i|720p|576p|480p|4k|uhd|hdr10\+?|hdr|dovi|bluray|blu-ray|bdrip|brrip|bdremux|remux|webrip|web-dl|webdl|hdtv|dvdrip|hdrip|x264|x265|h\.?264|h\.?265|hevc|avc|xvid|aac|ac3|eac3|ddp?5\.1|dts|atmos|truehd|10bit|repack|unrated|imax)(?![a-z0-9])/.ignoresCase()

    static func clean(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "_", with: " ")
        // Dots separate words in scene names, but keep dotted abbreviations like "S.H.I.E.L.D".
        if text.filter({ $0 == "." }).count >= 2 || !text.contains(" ") {
            text = text.replacingOccurrences(of: ".", with: " ")
        }
        if let tag = text.firstMatch(of: releaseTag) {
            text = String(text[..<tag.range.lowerBound])
        }
        text = text.replacing(/\s+/, with: " ")
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:,").union(.whitespaces))
    }

    private static func removeBracketedGroups(_ text: String) -> String {
        // "[YTS]" / "{edition}" are release noise; keep parentheses, which often hold the year.
        text.replacing(/\[[^\]]*\]|\{[^}]*\}/, with: " ")
    }

    /// Splits "Blade Runner 2049 (2017)" into ("Blade Runner 2049", 2017). Uses the last
    /// plausible year that still leaves a title in front of it.
    static func splitYear(_ text: String) -> (title: String, year: Int?) {
        let currentYear = Calendar.current.component(.year, from: .now)
        let matches = text.matches(of: /(?:^|[\s(])((?:19|20)\d{2})(?:[\s)]|$)/)
        for match in matches.reversed() {
            guard let year = Int(match.1), year <= currentYear + 1 else { continue }
            let title = String(text[..<match.range.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: " -–(").union(.whitespaces))
            if !title.isEmpty {
                return (title, year)
            }
        }
        return (text.trimmingCharacters(in: CharacterSet(charactersIn: " ()")), nil)
    }

    private static func isGeneric(_ title: String) -> Bool {
        let lowered = title.lowercased()
        return lowered.isEmpty || ["movie", "video", "film", "main", "feature", "title", "untitled"].contains(lowered)
            || lowered.allSatisfy(\.isNumber)
    }

    /// Capitalizes all-lowercase scene names; leaves intentionally cased titles alone.
    private static func titleCase(_ text: String) -> String {
        guard text == text.lowercased() else { return text }
        return text.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
