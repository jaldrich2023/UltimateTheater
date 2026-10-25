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
    private static let headers = [
        "User-Agent": "UltimateTheater/1.0 (macOS; personal media library)",
        "Accept": "application/json",
    ]

    /// Keyless sources (TVmaze, Wikipedia): responses may be cached on disk.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.requestCachePolicy = .useProtocolCachePolicy
        let cache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 64 << 20)
        purgeOnce(cache)
        configuration.urlCache = cache
        configuration.httpAdditionalHeaders = headers
        return URLSession(configuration: configuration, delegate: RedirectGuard.shared, delegateQueue: nil)
    }()

    /// Sources whose requests carry an API key (TMDB, OMDb): nothing is cached, in memory or on
    /// disk, so keys never end up in cache files.
    static let keyedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpAdditionalHeaders = headers
        return URLSession(configuration: configuration, delegate: RedirectGuard.shared, delegateQueue: nil)
    }()

    private static let purgedKey = "metadata.keyedCachePurged"

    /// Earlier versions cached keyed requests (with their API keys in the URLs) on disk.
    /// Until that's been cleared, a cache is emptied before it's used.
    private static func purgeOnce(_ cache: URLCache) {
        guard !UserDefaults.standard.bool(forKey: purgedKey) else { return }
        cache.removeAllCachedResponses()
    }

    /// Clears the cache earlier versions wrote keyed responses to (and the shared one), once.
    /// Called at launch, so it doesn't wait for the first keyless request.
    static func purgeLegacyKeyedCacheIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: purgedKey) else { return }
        session.configuration.urlCache?.removeAllCachedResponses()
        URLCache.shared.removeAllCachedResponses()
        UserDefaults.standard.set(true, forKey: purgedKey)
    }

    /// `containsSecret`: the URL or headers carry an API key, so the response isn't cached.
    static func get<T: Decodable>(_ type: T.Type, from url: URL, headers: [String: String] = [:],
                                  keyStrategy: JSONDecoder.KeyDecodingStrategy = .useDefaultKeys,
                                  containsSecret: Bool = false,
                                  provider: MetadataProviderID) async throws -> T {
        guard url.scheme?.lowercased() == "https" else { throw MetadataError.badResponse }
        var request = URLRequest(url: url)
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await (containsSecret ? keyedSession : session).data(for: request)
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

/// Redirects for metadata and subtitle requests: only to HTTPS, and credentials (API keys in
/// headers, tokens, cookies) only ever go to the host the request was made to.
nonisolated final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = RedirectGuard()

    /// Headers that identify the user or carry a key.
    static let credentialHeaders = ["Authorization", "Api-Key", "Cookie", "Proxy-Authorization", "X-Api-Key"]

    /// The request to follow for a redirect, or `nil` to refuse it. Same-host HTTPS redirects
    /// are followed unchanged; other HTTPS hosts get the request without its credentials.
    static func decision(for redirect: URLRequest, originalURL: URL?) -> URLRequest? {
        guard let target = redirect.url, target.scheme?.lowercased() == "https", let host = target.host()?.lowercased() else {
            return nil
        }
        guard host != originalURL?.host()?.lowercased() else { return redirect }
        var stripped = redirect
        for header in credentialHeaders {
            stripped.setValue(nil, forHTTPHeaderField: header)
        }
        return stripped
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(Self.decision(for: request, originalURL: task.originalRequest?.url))
    }
}

/// Checks provider IDs before they're put into URLs.
nonisolated enum MetadataIDs {
    /// "tt0133093".
    static func isIMDb(_ id: String) -> Bool {
        id.wholeMatch(of: /tt\d{1,10}/) != nil
    }

    /// A positive TMDB or TVmaze ID from its text form ("603"); nothing else.
    static func numeric(_ id: String) -> Int? {
        guard id.wholeMatch(of: /\d{1,10}/) != nil, let value = Int(id), value > 0 else { return nil }
        return value
    }

    /// YouTube and Vimeo video keys.
    static func isTrailerKey(_ key: String) -> Bool {
        key.wholeMatch(of: /[A-Za-z0-9_-]{1,32}/) != nil
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
