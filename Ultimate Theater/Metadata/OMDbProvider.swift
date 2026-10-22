//
//  OMDbProvider.swift
//  Ultimate Theater
//
//  The Open Movie Database (https://www.omdbapi.com). Adds IMDb, Rotten Tomatoes,
//  and Metacritic scores and US content ratings.
//

import Foundation

nonisolated struct OMDbProvider: MetadataProvider {
    let id = MetadataProviderID.omdb
    let apiKey: String

    func search(_ query: MetadataQuery) async throws -> [MetadataCandidate] {
        var items = [
            URLQueryItem(name: "s", value: query.title),
            URLQueryItem(name: "type", value: query.kind == .movie ? "movie" : "series"),
        ]
        if let year = query.year { items.append(URLQueryItem(name: "y", value: String(year))) }
        let response: SearchResponse = try await get(items)
        if let error = try validate(response.response, error: response.error), !error { return [] }
        return (response.search ?? []).prefix(10).map { result in
            MetadataCandidate(
                provider: id,
                externalID: result.imdbID,
                title: result.title,
                year: MetadataText.year(in: result.year),
                kind: query.kind,
                overview: nil,
                posterURL: MetadataText.value(result.poster).flatMap(URL.init(string:))
            )
        }
    }

    func details(for candidate: MetadataCandidate, query: MetadataQuery) async throws -> MetadataRecord {
        guard let record = try await lookup(imdbID: candidate.externalID, query: query) else {
            throw MetadataError.badResponse
        }
        return record
    }

    func lookup(imdbID: String, query: MetadataQuery) async throws -> MetadataRecord? {
        let details: Details = try await get([URLQueryItem(name: "i", value: imdbID), URLQueryItem(name: "plot", value: "full")])
        guard try validate(details.response, error: details.error) != false else { return nil }

        var record = MetadataRecord(provider: id)
        record.imdbID = details.imdbID
        record.title = MetadataText.value(details.title)
        record.year = MetadataText.year(in: details.year)
        record.synopsis = MetadataText.value(details.plot)
        record.maturity = Self.normalizedRating(details.rated)
        record.runtimeMinutes = MetadataText.minutes(details.runtime)
        record.genres = MetadataText.list(details.genre)
        record.cast = MetadataText.list(details.actors)
        record.director = MetadataText.value(details.director)
        // "Jonathan Nolan (screenplay), Christopher Nolan (story)" → names only.
        record.writers = MetadataText.list(details.writer).map { $0.replacing(/\s*\([^)]*\)/, with: "") }
        record.studios = MetadataText.list(details.production)
        record.posterURL = MetadataText.value(details.poster).flatMap(URL.init(string:))
        record.ratings = (details.ratings ?? []).compactMap(Self.rating(from:))
        return record
    }

    // MARK: Helpers

    private func get<T: Decodable>(_ items: [URLQueryItem]) async throws -> T {
        guard !apiKey.isEmpty else { throw MetadataError.missingAPIKey(id) }
        var components = URLComponents(string: "https://www.omdbapi.com/")
        components?.queryItems = items + [URLQueryItem(name: "apikey", value: apiKey)]
        guard let url = components?.url else { throw MetadataError.badResponse }
        return try await HTTPClient.get(T.self, from: url, provider: id)
    }

    /// OMDb reports errors in the body with HTTP 200. Returns `false` for "not found".
    private func validate(_ response: String?, error: String?) throws -> Bool? {
        guard response == "False" else { return nil }
        if error?.localizedCaseInsensitiveContains("api key") == true { throw MetadataError.invalidAPIKey(id) }
        return false
    }

    static func normalizedRating(_ rated: String?) -> String? {
        guard let rated = MetadataText.value(rated) else { return nil }
        return ["Not Rated", "Unrated", "Approved", "Passed"].contains(rated) ? "NR" : rated
    }

    /// "8.8/10" (IMDb), "87%" (Rotten Tomatoes), "74/100" (Metacritic).
    static func rating(from rating: SourceRating) -> ExternalRating? {
        let value = rating.value
        switch rating.source {
        case "Internet Movie Database":
            guard let score = Double(value.split(separator: "/").first ?? "") else { return nil }
            return ExternalRating(source: .imdb, score: score * 10, display: String(format: "%.1f", score))
        case "Rotten Tomatoes":
            guard let score = Double(value.replacingOccurrences(of: "%", with: "")) else { return nil }
            return ExternalRating(source: .rottenTomatoes, score: score, display: "\(Int(score))%")
        case "Metacritic":
            guard let score = Double(value.split(separator: "/").first ?? "") else { return nil }
            return ExternalRating(source: .metacritic, score: score, display: "\(Int(score))")
        default:
            return nil
        }
    }

    // MARK: DTOs

    private struct SearchResponse: Decodable {
        let search: [SearchResult]?
        let response: String?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case search = "Search", response = "Response", error = "Error"
        }
    }

    private struct SearchResult: Decodable {
        let title: String
        let year: String
        let imdbID: String
        let poster: String?

        enum CodingKeys: String, CodingKey {
            case title = "Title", year = "Year", imdbID, poster = "Poster"
        }
    }

    struct SourceRating: Decodable {
        let source: String
        let value: String

        enum CodingKeys: String, CodingKey {
            case source = "Source", value = "Value"
        }
    }

    private struct Details: Decodable {
        let title: String?
        let year: String?
        let rated: String?
        let runtime: String?
        let genre: String?
        let director: String?
        let writer: String?
        let production: String?
        let actors: String?
        let plot: String?
        let poster: String?
        let ratings: [SourceRating]?
        let imdbID: String?
        let response: String?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case title = "Title", year = "Year", rated = "Rated", runtime = "Runtime", genre = "Genre"
            case director = "Director", writer = "Writer", production = "Production"
            case actors = "Actors", plot = "Plot", poster = "Poster"
            case ratings = "Ratings", imdbID, response = "Response", error = "Error"
        }
    }
}
