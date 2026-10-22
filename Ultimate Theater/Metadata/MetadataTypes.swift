//
//  MetadataTypes.swift
//  Ultimate Theater
//
//  Provider-neutral metadata types plus the `MetadataProvider` protocol every
//  source (TMDB, OMDb, TVmaze, Wikipedia) implements.
//

import Foundation

nonisolated enum MetadataProviderID: String, CaseIterable, Identifiable, Codable, Sendable {
    case tmdb
    case omdb
    case tvmaze
    case wikipedia

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tmdb: "TMDB"
        case .omdb: "OMDb"
        case .tvmaze: "TVmaze"
        case .wikipedia: "Wikipedia"
        }
    }

    var summary: String {
        switch self {
        case .tmdb: "Primary source for movies and TV: posters, backdrops, cast, genres, ratings, and episode details."
        case .omdb: "IMDb, Rotten Tomatoes, and Metacritic scores, plus US content ratings."
        case .tvmaze: "TV shows and full episode guides. No key required."
        case .wikipedia: "Synopses and posters for movies and TV. No key required."
        }
    }

    var requiresAPIKey: Bool { self == .tmdb || self == .omdb }

    var keySignupURL: URL? {
        switch self {
        case .tmdb: URL(string: "https://www.themoviedb.org/settings/api")
        case .omdb: URL(string: "https://www.omdbapi.com/apikey.aspx")
        default: nil
        }
    }

    func supports(_ kind: TitleKind) -> Bool {
        self == .tvmaze ? kind == .series : true
    }
}

nonisolated struct MetadataQuery: Hashable, Sendable {
    var title: String
    var year: Int?
    var kind: TitleKind
    /// Seasons present on disk, so episode guides only fetch what's needed.
    var seasons: [Int] = []
}

/// One search hit, shown in Fix Match and used for auto-matching.
nonisolated struct MetadataCandidate: Identifiable, Hashable, Sendable {
    let provider: MetadataProviderID
    let externalID: String
    let title: String
    let year: Int?
    let kind: TitleKind
    let overview: String?
    let posterURL: URL?

    var id: String { "\(provider.rawValue):\(externalID)" }
}

nonisolated struct EpisodeMetadata: Hashable, Sendable {
    var season: Int
    var number: Int
    var name: String?
    var synopsis: String?
    var runtimeMinutes: Int?
    var stillURL: URL?
}

/// Everything one provider knows about a title. Every field is optional; records
/// from several providers are merged by `MetadataMerger`.
nonisolated struct MetadataRecord: Sendable {
    var provider: MetadataProviderID
    var title: String?
    var year: Int?
    var synopsis: String?
    var tagline: String?
    var maturity: String?
    /// Certifications by country (ISO 3166-1), e.g. ["US": "PG-13", "GB": "12A"].
    var certifications: [String: String] = [:]
    var runtimeMinutes: Int?
    var genres: [String] = []
    var cast: [String] = []
    var director: String?
    var writers: [String] = []
    var studios: [String] = []
    var trailer: TrailerInfo?
    var collection: CollectionInfo?
    var posterURL: URL?
    var backdropURL: URL?
    var ratings: [ExternalRating] = []
    var tmdbID: Int?
    var imdbID: String?
    var tvmazeID: Int?
    var wikipediaKey: String?
    var episodes: [EpisodeMetadata] = []

    init(provider: MetadataProviderID) {
        self.provider = provider
    }
}

/// The merged result applied to a library item.
nonisolated struct MergedMetadata: Sendable {
    var record: MetadataRecord
    var sources: [MetadataProviderID]
}

nonisolated protocol MetadataProvider: Sendable {
    var id: MetadataProviderID { get }
    func search(_ query: MetadataQuery) async throws -> [MetadataCandidate]
    func details(for candidate: MetadataCandidate, query: MetadataQuery) async throws -> MetadataRecord
    /// Direct lookup by IMDb ID, used to line up every source on the same title.
    func lookup(imdbID: String, query: MetadataQuery) async throws -> MetadataRecord?
}

nonisolated extension MetadataProvider {
    func lookup(imdbID: String, query: MetadataQuery) async throws -> MetadataRecord? { nil }
}

nonisolated enum MetadataError: LocalizedError, Equatable {
    case missingAPIKey(MetadataProviderID)
    case invalidAPIKey(MetadataProviderID)
    case http(status: Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider): "\(provider.displayName) needs an API key. Add one in Settings."
        case .invalidAPIKey(let provider): "\(provider.displayName) rejected the API key. Check it in Settings."
        case .http(let status): "The server responded with an error (\(status))."
        case .badResponse: "The server sent an unexpected response."
        }
    }
}

// MARK: - HTTP

nonisolated enum HTTPClient {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 64 << 20)
        configuration.httpAdditionalHeaders = [
            "User-Agent": "UltimateTheater/1.0 (macOS; personal media library)",
            "Accept": "application/json",
        ]
        return URLSession(configuration: configuration)
    }()

    static func get<T: Decodable>(_ type: T.Type, from url: URL, headers: [String: String] = [:],
                                  keyStrategy: JSONDecoder.KeyDecodingStrategy = .useDefaultKeys,
                                  provider: MetadataProviderID) async throws -> T {
        var request = URLRequest(url: url)
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MetadataError.badResponse }
        switch http.statusCode {
        case 200..<300: break
        case 401: throw MetadataError.invalidAPIKey(provider)
        default: throw MetadataError.http(status: http.statusCode)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = keyStrategy
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw MetadataError.badResponse
        }
    }
}

// MARK: - Parsing helpers

nonisolated enum MetadataText {
    /// First 4-digit year in strings like "2010-07-15", "2022–", or "2010 film by …".
    static func year(in text: String?) -> Int? {
        guard let text, let match = text.firstMatch(of: /(?:19|20)\d{2}/) else { return nil }
        return Int(text[match.range])
    }

    /// Strips HTML tags and entities from provider summaries (TVmaze sends `<p>…</p>`).
    static func plainText(_ html: String?) -> String? {
        guard let html else { return nil }
        var text = html.replacing(/<[^>]+>/, with: "")
        for (entity, value) in ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Treats OMDb-style "N/A" and empty strings as missing.
    static func value(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty, text != "N/A" else { return nil }
        return text
    }

    static func list(_ text: String?) -> [String] {
        value(text)?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
    }

    static func minutes(_ text: String?) -> Int? {
        guard let text = value(text), let match = text.firstMatch(of: /\d+/) else { return nil }
        return Int(text[match.range])
    }
}
