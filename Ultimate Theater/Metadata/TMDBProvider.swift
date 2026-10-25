//
//  TMDBProvider.swift
//  Ultimate Theater
//
//  The Movie Database (https://developer.themoviedb.org). Primary source for
//  movies and TV. Accepts a v3 API key or a v4 read access token.
//

import Foundation

nonisolated struct TMDBProvider: MetadataProvider {
    let id = MetadataProviderID.tmdb
    let apiKey: String

    private static let base = URL(string: "https://api.themoviedb.org/3")!
    private static let imageBase = "https://image.tmdb.org/t/p/"

    // MARK: MetadataProvider

    func search(_ query: MetadataQuery) async throws -> [MetadataCandidate] {
        var items = [URLQueryItem(name: "query", value: query.title), URLQueryItem(name: "include_adult", value: "false")]
        if let year = query.year {
            items.append(URLQueryItem(name: query.kind == .movie ? "year" : "first_air_date_year", value: String(year)))
        }
        let path = query.kind == .movie ? "search/movie" : "search/tv"
        let response: SearchResponse = try await get(path, items)
        return response.results.prefix(12).map { result in
            MetadataCandidate(
                provider: id,
                externalID: String(result.id),
                title: result.title ?? result.name ?? "",
                year: MetadataText.year(in: result.releaseDate ?? result.firstAirDate),
                kind: query.kind,
                overview: MetadataText.value(result.overview),
                posterURL: Self.image(result.posterPath, size: "w342")
            )
        }
    }

    func details(for candidate: MetadataCandidate, query: MetadataQuery) async throws -> MetadataRecord {
        guard let tmdbID = MetadataIDs.numeric(candidate.externalID) else { throw MetadataError.badResponse }
        return candidate.kind == .movie
            ? try await movie(id: tmdbID)
            : try await show(id: tmdbID, seasons: query.seasons)
    }

    func lookup(imdbID: String, query: MetadataQuery) async throws -> MetadataRecord? {
        guard MetadataIDs.isIMDb(imdbID) else { return nil }
        let response: FindResponse = try await get("find/\(imdbID)", [URLQueryItem(name: "external_source", value: "imdb_id")])
        switch query.kind {
        case .movie:
            guard let match = response.movieResults.first else { return nil }
            return try await movie(id: match.id)
        case .series:
            guard let match = response.tvResults.first else { return nil }
            return try await show(id: match.id, seasons: query.seasons)
        }
    }

    // MARK: Details

    private func movie(id tmdbID: Int) async throws -> MetadataRecord {
        let details: MovieDetails = try await get("movie/\(tmdbID)", [
            URLQueryItem(name: "append_to_response", value: "credits,release_dates,videos"),
        ])
        var record = MetadataRecord(provider: id)
        record.tmdbID = tmdbID
        record.imdbID = MetadataText.value(details.imdbId)
        record.title = details.title
        record.year = MetadataText.year(in: details.releaseDate)
        record.synopsis = MetadataText.value(details.overview)
        record.tagline = MetadataText.value(details.tagline)
        record.runtimeMinutes = details.runtime.flatMap { $0 > 0 ? $0 : nil }
        record.genres = details.genres.map(\.name)
        record.cast = details.credits?.cast.prefix(8).map(\.name) ?? []
        record.director = details.credits?.crew.filter { $0.job == "Director" }.map(\.name).joined(separator: ", ")
        record.writers = Self.writers(in: details.credits)
        record.studios = details.productionCompanies?.prefix(4).map(\.name) ?? []
        record.posterURL = Self.image(details.posterPath, size: "w780")
        record.backdropURL = Self.image(details.backdropPath, size: "w1280")
        for country in details.releaseDates?.results ?? [] {
            if let rating = country.releaseDates.compactMap({ MetadataText.value($0.certification) }).first {
                record.certifications[country.iso31661] = rating
            }
        }
        record.maturity = record.certifications["US"]
        record.ratings = Self.rating(average: details.voteAverage, count: details.voteCount)
        record.trailer = Self.bestTrailer(details.videos)
        if let reference = details.belongsToCollection {
            // The full list of films lets the app show the ones that aren't in the library.
            let parts: [CollectionPart]? = (try? await get("collection/\(reference.id)", []) as CollectionDetails)?.parts
                .map { CollectionPart(id: $0.id, title: $0.title, year: MetadataText.year(in: $0.releaseDate)) }
                .sorted { ($0.year ?? Int.max) < ($1.year ?? Int.max) }
            record.collection = CollectionInfo(id: reference.id, name: reference.name,
                                               posterURL: Self.image(reference.posterPath, size: "w780"),
                                               backdropURL: Self.image(reference.backdropPath, size: "w1280"),
                                               parts: parts)
        }
        return record
    }

    private func show(id tmdbID: Int, seasons: [Int]) async throws -> MetadataRecord {
        let details: TVDetails = try await get("tv/\(tmdbID)", [
            URLQueryItem(name: "append_to_response", value: "credits,content_ratings,external_ids,videos"),
        ])
        var record = MetadataRecord(provider: id)
        record.tmdbID = tmdbID
        record.imdbID = MetadataText.value(details.externalIds?.imdbId)
        record.title = details.name
        record.year = MetadataText.year(in: details.firstAirDate)
        record.synopsis = MetadataText.value(details.overview)
        record.tagline = MetadataText.value(details.tagline)
        record.runtimeMinutes = details.episodeRunTime?.first
        record.genres = details.genres.map(\.name)
        record.cast = details.credits?.cast.prefix(8).map(\.name) ?? []
        record.director = details.createdBy.flatMap { $0.isEmpty ? nil : "Created by " + $0.map(\.name).joined(separator: ", ") }
        record.writers = Self.unique((details.createdBy?.map(\.name) ?? []) + Self.writers(in: details.credits))
        record.studios = Self.unique((details.networks?.map(\.name) ?? []) + (details.productionCompanies?.prefix(3).map(\.name) ?? []))
        record.posterURL = Self.image(details.posterPath, size: "w780")
        record.backdropURL = Self.image(details.backdropPath, size: "w1280")
        for country in details.contentRatings?.results ?? [] {
            if let rating = MetadataText.value(country.rating) { record.certifications[country.iso31661] = rating }
        }
        record.maturity = record.certifications["US"]
        record.ratings = Self.rating(average: details.voteAverage, count: details.voteCount)
        record.trailer = Self.bestTrailer(details.videos)

        // Episode guides, one request per season on disk.
        for season in Set(seasons).sorted() {
            guard let guide: SeasonDetails = try? await get("tv/\(tmdbID)/season/\(season)", []) else { continue }
            record.episodes += guide.episodes.map { episode in
                EpisodeMetadata(
                    season: episode.seasonNumber ?? season,
                    number: episode.episodeNumber,
                    name: MetadataText.value(episode.name),
                    synopsis: MetadataText.value(episode.overview),
                    runtimeMinutes: episode.runtime,
                    stillURL: Self.image(episode.stillPath, size: "w500")
                )
            }
        }
        return record
    }

    // MARK: Helpers

    private func get<T: Decodable>(_ path: String, _ items: [URLQueryItem]) async throws -> T {
        guard !apiKey.isEmpty else { throw MetadataError.missingAPIKey(id) }
        var components = URLComponents(url: Self.base.appending(path: path), resolvingAgainstBaseURL: false)
        var queryItems = items
        var headers: [String: String] = [:]
        // v4 read access tokens are long JWTs; v3 keys are 32 hex characters.
        if apiKey.count > 40 {
            headers["Authorization"] = "Bearer \(apiKey)"
        } else {
            queryItems.append(URLQueryItem(name: "api_key", value: apiKey))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { throw MetadataError.badResponse }
        return try await HTTPClient.get(T.self, from: url, headers: headers, keyStrategy: .convertFromSnakeCase,
                                        containsSecret: true, provider: id)
    }

    private static func image(_ path: String?, size: String) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: imageBase + size + path)
    }

    /// Official trailer first, then teasers; English and higher resolution preferred.
    static func bestTrailer(_ videos: Videos?) -> TrailerInfo? {
        let playable = (videos?.results ?? []).filter { ["YouTube", "Vimeo"].contains($0.site) && ["Trailer", "Teaser"].contains($0.type) }
        let best = playable.max { lhs, rhs in
            func rank(_ video: Video) -> (Int, Int, Int, Int) {
                (video.type == "Trailer" ? 1 : 0, video.official == true ? 1 : 0,
                 video.iso6391 == "en" ? 1 : 0, video.size ?? 0)
            }
            return rank(lhs) < rank(rhs)
        }
        return best.map { TrailerInfo(site: $0.site, key: $0.key, name: $0.name) }
    }

    private static func writers(in credits: Credits?) -> [String] {
        unique(credits?.crew.filter { $0.department == "Writing" }.map(\.name) ?? []).prefix(6).map(\.self)
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    private static func rating(average: Double?, count: Int?) -> [ExternalRating] {
        guard let average, average > 0, (count ?? 0) > 0 else { return [] }
        return [ExternalRating(source: .tmdb, score: average * 10, display: "\(Int((average * 10).rounded()))%")]
    }

    // MARK: DTOs

    private struct SearchResponse: Decodable {
        let results: [SearchResult]
    }

    private struct SearchResult: Decodable {
        let id: Int
        let title: String?
        let name: String?
        let releaseDate: String?
        let firstAirDate: String?
        let overview: String?
        let posterPath: String?
    }

    private struct FindResponse: Decodable {
        let movieResults: [IDOnly]
        let tvResults: [IDOnly]
    }

    private struct IDOnly: Decodable {
        let id: Int
    }

    private struct Named: Decodable {
        let name: String
    }

    private struct Credits: Decodable {
        let cast: [Named]
        let crew: [CrewMember]
    }

    private struct CrewMember: Decodable {
        let name: String
        let job: String?
        let department: String?
    }

    private struct MovieDetails: Decodable {
        let title: String
        let tagline: String?
        let overview: String?
        let releaseDate: String?
        let runtime: Int?
        let genres: [Named]
        let posterPath: String?
        let backdropPath: String?
        let voteAverage: Double?
        let voteCount: Int?
        let imdbId: String?
        let productionCompanies: [Named]?
        let belongsToCollection: CollectionReference?
        let credits: Credits?
        let releaseDates: ReleaseDates?
        let videos: Videos?
    }

    private struct CollectionReference: Decodable {
        let id: Int
        let name: String
        let posterPath: String?
        let backdropPath: String?
    }

    private struct CollectionDetails: Decodable {
        let parts: [CollectionMovie]
    }

    private struct CollectionMovie: Decodable {
        let id: Int
        let title: String
        let releaseDate: String?
    }

    struct Videos: Decodable {
        let results: [Video]
    }

    struct Video: Decodable {
        let key: String
        let site: String
        let type: String
        let name: String
        let official: Bool?
        let iso6391: String?
        let size: Int?
    }

    private struct ReleaseDates: Decodable {
        let results: [CountryReleases]
    }

    private struct CountryReleases: Decodable {
        let iso31661: String
        let releaseDates: [Certification]
    }

    private struct Certification: Decodable {
        let certification: String?
    }

    private struct TVDetails: Decodable {
        let name: String
        let tagline: String?
        let overview: String?
        let firstAirDate: String?
        let episodeRunTime: [Int]?
        let genres: [Named]
        let posterPath: String?
        let backdropPath: String?
        let voteAverage: Double?
        let voteCount: Int?
        let createdBy: [Named]?
        let networks: [Named]?
        let productionCompanies: [Named]?
        let credits: Credits?
        let videos: Videos?
        let contentRatings: ContentRatings?
        let externalIds: ExternalIDs?
    }

    private struct ContentRatings: Decodable {
        let results: [CountryRating]
    }

    private struct CountryRating: Decodable {
        let iso31661: String
        let rating: String?
    }

    private struct ExternalIDs: Decodable {
        let imdbId: String?
    }

    private struct SeasonDetails: Decodable {
        let episodes: [SeasonEpisode]
    }

    private struct SeasonEpisode: Decodable {
        let episodeNumber: Int
        let seasonNumber: Int?
        let name: String?
        let overview: String?
        let runtime: Int?
        let stillPath: String?
    }
}
