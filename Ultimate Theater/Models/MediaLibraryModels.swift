//
//  MediaLibraryModels.swift
//  Ultimate Theater
//
//  Persistent records for the user's own movies and shows.
//

import Foundation
import SwiftData

nonisolated enum RatingSource: String, Codable, Hashable, Sendable, CaseIterable {
    case imdb
    case rottenTomatoes
    case metacritic
    case tmdb
    case tvmaze

    var displayName: String {
        switch self {
        case .imdb: "IMDb"
        case .rottenTomatoes: "Rotten Tomatoes"
        case .metacritic: "Metacritic"
        case .tmdb: "TMDB"
        case .tvmaze: "TVmaze"
        }
    }
}

/// A score from one source, normalized to 0–100 for sorting, plus its native display string.
nonisolated struct ExternalRating: Codable, Hashable, Sendable {
    var source: RatingSource
    var score: Double
    var display: String
}

/// A trailer hosted on YouTube or Vimeo (from TMDB).
nonisolated struct TrailerInfo: Codable, Hashable, Sendable {
    var site: String
    var key: String
    var name: String

    /// Privacy-enhanced embeddable player URL.
    var embedURL: URL? {
        switch site.lowercased() {
        case "youtube": url("www.youtube-nocookie.com", path: "/embed/\(key)",
                            query: ["autoplay": "1", "rel": "0", "modestbranding": "1", "playsinline": "1"])
        case "vimeo": url("player.vimeo.com", path: "/video/\(key)", query: ["autoplay": "1"])
        default: nil
        }
    }

    var watchURL: URL? {
        switch site.lowercased() {
        case "youtube": url("www.youtube.com", path: "/watch", query: ["v": key])
        case "vimeo": url("vimeo.com", path: "/\(key)")
        default: nil
        }
    }

    /// An HTTPS URL on the video site, only for a well-formed key (keys come from TMDB and
    /// are stored, so they're checked every time they're used).
    private func url(_ host: String, path: String, query: KeyValuePairs<String, String> = [:]) -> URL? {
        guard MetadataIDs.isTrailerKey(key) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return components.url
    }
}

/// A movie franchise grouping, e.g. "The Matrix Collection" (from TMDB).
nonisolated struct CollectionInfo: Codable, Hashable, Sendable, Identifiable {
    var id: Int
    var name: String
    var posterURL: URL?
    var backdropURL: URL?
    /// Every film in the collection, including ones not in the library.
    var parts: [CollectionPart]? = nil
}

nonisolated struct CollectionPart: Codable, Hashable, Sendable, Identifiable {
    var id: Int // TMDB movie ID
    var title: String
    var year: Int?
}

nonisolated enum MetadataStatus: String, Codable, Sendable {
    /// Imported, info not fetched yet.
    case pending
    /// Matched to at least one provider.
    case matched
    /// Searched every enabled provider without a confident match.
    case unmatched
}

@Model
final class MediaItem {
    @Attribute(.unique) var id: String
    var kindRaw: String
    var name: String
    var year: Int?
    var synopsis: String
    var tagline: String
    var maturity: String
    /// Certifications by country, from the metadata sources.
    var certifications: [String: String] = [:]
    var runtimeMinutes: Int
    var genreNames: [String]
    var cast: [String]
    var director: String
    var writers: [String] = []
    var studios: [String] = []
    var trailer: TrailerInfo?
    var collection: CollectionInfo?
    var posterURLString: String?
    var backdropURLString: String?
    var ratings: [ExternalRating]
    var tmdbID: Int?
    var imdbID: String?
    var tvmazeID: Int?
    var wikipediaKey: String?
    var metadataSources: [String]
    var statusRaw: String
    /// When set, refreshes never overwrite the user's edits.
    var isMetadataLocked: Bool
    var dateAdded: Date
    var lastRefreshed: Date?

    // Movie file (series keep files on their episodes).
    var filePath: String?
    var fileBookmark: Data?
    var isPlayable: Bool
    /// Why the file can't play, when it can't.
    var playbackIssue: String?
    var playbackIssueIsDamage = false
    /// `QualityBadge` raw values detected from the video track.
    var qualityBadges: [String] = []

    @Relationship(deleteRule: .cascade, inverse: \MediaEpisode.show)
    var episodes: [MediaEpisode] = []

    init(kind: TitleKind, name: String, year: Int?) {
        self.id = "lib-\(UUID().uuidString)"
        self.kindRaw = kind.rawValue
        self.name = name
        self.year = year
        self.synopsis = ""
        self.tagline = ""
        self.maturity = ""
        self.runtimeMinutes = 0
        self.genreNames = []
        self.cast = []
        self.director = ""
        self.ratings = []
        self.metadataSources = []
        self.statusRaw = MetadataStatus.pending.rawValue
        self.isMetadataLocked = false
        self.dateAdded = .now
        self.isPlayable = true
    }

    var kind: TitleKind { TitleKind(rawValue: kindRaw) ?? .movie }

    var status: MetadataStatus {
        get { MetadataStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var sortedEpisodes: [MediaEpisode] {
        episodes.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
    }
}

@Model
final class MediaEpisode {
    @Attribute(.unique) var id: String
    var season: Int
    var number: Int
    var name: String
    var synopsis: String
    var runtimeMinutes: Int
    var stillURLString: String?
    var filePath: String
    var fileBookmark: Data?
    var isPlayable: Bool
    var playbackIssue: String?
    var playbackIssueIsDamage = false
    var qualityBadges: [String] = []
    /// Skip Intro / Skip Credits times in seconds, found by `SkipSegmentDetector`.
    var introStart: Double?
    var introEnd: Double?
    var creditsStart: Double?
    /// The detector version that last analysed this episode (0: never).
    var skipAnalysisVersion: Int = 0
    var show: MediaItem?

    init(season: Int, number: Int, name: String, filePath: String, fileBookmark: Data?, isPlayable: Bool) {
        self.id = "lib-ep-\(UUID().uuidString)"
        self.season = season
        self.number = number
        self.name = name
        self.synopsis = ""
        self.runtimeMinutes = 0
        self.filePath = filePath
        self.fileBookmark = fileBookmark
        self.isPlayable = isPlayable
    }
}

/// A folder the user added, kept so it can be rescanned for new files.
@Model
final class LibraryFolder {
    @Attribute(.unique) var path: String
    var bookmark: Data?
    var dateAdded: Date
    var lastScanned: Date?

    init(path: String, bookmark: Data?) {
        self.path = path
        self.bookmark = bookmark
        self.dateAdded = .now
    }

    var displayName: String { URL(fileURLWithPath: path).lastPathComponent }
}

/// A video the folder watcher found, waiting for the administrator to approve it.
@Model
final class PendingMedia {
    @Attribute(.unique) var path: String
    var dateFound: Date
    /// The administrator chose not to add it; it isn't offered again.
    var isIgnored = false

    init(path: String) {
        self.path = path
        self.dateFound = .now
    }

    var fileName: String { URL(fileURLWithPath: path).lastPathComponent }
}
