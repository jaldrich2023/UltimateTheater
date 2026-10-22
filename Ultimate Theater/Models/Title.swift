//
//  Title.swift
//  Ultimate Theater
//
//  Immutable view model for a movie or show in the user's library. Built from
//  `MediaItem` records by `MediaLibrary`.
//

import SwiftUI

/// Whether a title is a single feature or an episodic series.
nonisolated enum TitleKind: String, Hashable, CaseIterable, Identifiable, Codable, Sendable {
    case movie
    case series

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .movie: "Movie"
        case .series: "TV Show"
        }
    }
}

/// Video characteristics read from the file at import time.
enum QualityBadge: String, Hashable {
    case uhd = "4K"
    case hd = "HD"
    case hdr = "HDR"
    case dolbyVision = "Dolby Vision"
}

/// Procedurally rendered fallback art, used until (or if) real artwork is found.
struct Artwork: Hashable {
    let colors: [Color]
    let symbol: String
}

struct Episode: Identifiable, Hashable {
    let id: String
    let titleID: String
    let season: Int
    let number: Int
    let name: String
    let synopsis: String
    let runtimeMinutes: Int
    let stillURL: URL?
    let isPlayable: Bool
    let fileFormat: String
    var playbackIssue: PlaybackIssue? = nil

    var code: String { "S\(season):E\(number)" }
}

struct Season: Identifiable, Hashable {
    let number: Int
    let episodes: [Episode]

    var id: Int { number }
    var name: String { number == 0 ? "Specials" : "Season \(number)" }
}

/// Why a file can't be played: damaged (such as an interrupted copy) or in a format the
/// engine doesn't decode.
struct PlaybackIssue: Hashable, Sendable {
    let message: String
    let isDamage: Bool

    var label: String { isDamage ? "Damaged File" : "Unsupported Format" }

    init(message: String, isDamage: Bool) {
        self.message = message
        self.isDamage = isDamage
    }

    init?(message: String?, isDamage: Bool) {
        guard let message else { return nil }
        self.init(message: message, isDamage: isDamage)
    }
}

struct Title: Identifiable, Hashable {
    let id: String
    let name: String
    let kind: TitleKind
    let tagline: String
    let synopsis: String
    let year: Int?
    let maturity: String
    let runtimeMinutes: Int
    let genres: [Genre]
    let cast: [String]
    let director: String
    let writers: [String]
    let studios: [String]
    let badges: [QualityBadge]
    let artwork: Artwork
    let posterURL: URL?
    let backdropURL: URL?
    let ratings: [ExternalRating]
    let metadataSources: [String]
    let needsMatch: Bool
    let isPlayable: Bool
    let fileFormat: String
    let dateAdded: Date
    let seasons: [Season]
    var trailer: TrailerInfo? = nil
    var collection: CollectionInfo? = nil
    var tmdbID: Int? = nil
    /// Certifications by country (ISO 3166-1).
    var certifications: [String: String] = [:]
    var playbackIssue: PlaybackIssue? = nil


    var allEpisodes: [Episode] { seasons.flatMap(\.episodes) }

    /// Individual names from the director/creator credit ("Lana Wachowski, Lilly Wachowski").
    var directors: [String] {
        director.replacingOccurrences(of: "Created by ", with: "")
            .split(separator: /,\s*|\s+&\s+|\s+and\s+/)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Name used for alphabetical order, ignoring a leading "The", "A", or "An".
    var sortName: String { Self.sortName(for: name) }

    static func sortName(for name: String) -> String {
        let lowered = name.lowercased()
        for article in ["the ", "a ", "an "] where lowered.hasPrefix(article) && name.count > article.count {
            return String(name.dropFirst(article.count))
        }
        return name
    }

    /// Bucket in the 0–9 A–Z index. Accented letters fold to their base letter; symbols sort with 0.
    var indexCharacter: Character { Self.indexCharacter(forSortName: sortName) }

    static func indexCharacter(forSortName name: String) -> Character {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).uppercased()
        guard let first = folded.first(where: { $0.isLetter || $0.isNumber }), first.isASCII else { return "0" }
        return first
    }

    /// Best available critic score, 0–100: Rotten Tomatoes, then Metacritic, then audience scores.
    var criticScore: Int? {
        let order: [RatingSource] = [.rottenTomatoes, .metacritic, .tmdb, .imdb, .tvmaze]
        for source in order {
            if let rating = ratings.first(where: { $0.source == source }) {
                return Int(rating.score.rounded())
            }
        }
        return nil
    }

    var yearText: String? { year.map(String.init) }

    /// A compact length string: "2h 14m" for movies, "3 Seasons" for shows.
    var lengthDescription: String? {
        switch kind {
        case .movie:
            guard runtimeMinutes > 0 else { return nil }
            let hours = runtimeMinutes / 60
            let minutes = runtimeMinutes % 60
            return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
        case .series:
            let count = seasons.filter { $0.number > 0 }.count
            if count == 0 { return "\(allEpisodes.count) Episodes" }
            return count == 1 ? "1 Season" : "\(count) Seasons"
        }
    }

    var genreLine: String {
        genres.prefix(2).map(\.displayName).joined(separator: " · ")
    }

    /// "2019 · Sci-Fi · Drama", skipping anything unknown.
    var subtitleLine: String {
        ([yearText] + genres.prefix(2).map(\.displayName)).compactMap { $0 }.joined(separator: " · ")
    }

    func episode(after episode: Episode) -> Episode? {
        let episodes = allEpisodes
        guard let index = episodes.firstIndex(of: episode), index + 1 < episodes.count else { return nil }
        return episodes[index + 1]
    }
}

/// A single thing the player can play: a movie, or one episode of a show.
struct PlaybackItem: Identifiable, Hashable {
    let title: Title
    let episode: Episode?

    var id: String { episode?.id ?? title.id }
    var headline: String { title.name }
    var isPlayable: Bool { episode?.isPlayable ?? title.isPlayable }

    var subheadline: String? {
        guard let episode else { return nil }
        return "\(episode.code) · \(episode.name)"
    }
}
