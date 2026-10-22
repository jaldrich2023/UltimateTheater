//
//  TVmazeProvider.swift
//  Ultimate Theater
//
//  TVmaze (https://www.tvmaze.com/api). Free, keyless TV metadata with full
//  episode guides. Data is licensed CC BY-SA.
//

import Foundation

nonisolated struct TVmazeProvider: MetadataProvider {
    let id = MetadataProviderID.tvmaze

    private static let base = "https://api.tvmaze.com"

    func search(_ query: MetadataQuery) async throws -> [MetadataCandidate] {
        guard query.kind == .series else { return [] }
        var components = URLComponents(string: "\(Self.base)/search/shows")
        components?.queryItems = [URLQueryItem(name: "q", value: query.title)]
        guard let url = components?.url else { throw MetadataError.badResponse }
        let results: [SearchResult] = try await HTTPClient.get([SearchResult].self, from: url, provider: id)
        return results.prefix(10).map { candidate(from: $0.show) }
    }

    func details(for candidate: MetadataCandidate, query: MetadataQuery) async throws -> MetadataRecord {
        guard let showID = Int(candidate.externalID) else { throw MetadataError.badResponse }
        return try await show(id: showID)
    }

    func lookup(imdbID: String, query: MetadataQuery) async throws -> MetadataRecord? {
        guard query.kind == .series, let url = URL(string: "\(Self.base)/lookup/shows?imdb=\(imdbID)") else { return nil }
        // TVmaze answers a lookup with a redirect to the show, or 404 when unknown.
        guard let show = try? await HTTPClient.get(Show.self, from: url, provider: id) else { return nil }
        return try await self.show(id: show.id)
    }

    // MARK: Details

    private func show(id showID: Int) async throws -> MetadataRecord {
        // Brackets in `embed[]` must be percent-encoded.
        guard let url = URL(string: "\(Self.base)/shows/\(showID)?embed%5B%5D=episodes&embed%5B%5D=cast") else {
            throw MetadataError.badResponse
        }
        let show = try await HTTPClient.get(Show.self, from: url, provider: id)

        var record = MetadataRecord(provider: id)
        record.tvmazeID = show.id
        record.imdbID = show.externals?.imdb
        record.title = show.name
        record.year = MetadataText.year(in: show.premiered)
        record.synopsis = MetadataText.plainText(show.summary)
        record.runtimeMinutes = show.averageRuntime ?? show.runtime
        record.genres = show.genres ?? []
        record.cast = show.embedded?.cast?.prefix(8).map(\.person.name) ?? []
        record.studios = [show.network?.name, show.webChannel?.name].compactMap { $0 }
        record.posterURL = show.image?.original.flatMap(URL.init(string:))
        if let average = show.rating?.average {
            record.ratings = [ExternalRating(source: .tvmaze, score: average * 10, display: String(format: "%.1f", average))]
        }
        record.episodes = (show.embedded?.episodes ?? []).compactMap { episode in
            guard let season = episode.season, let number = episode.number else { return nil }
            return EpisodeMetadata(
                season: season,
                number: number,
                name: episode.name,
                synopsis: MetadataText.plainText(episode.summary),
                runtimeMinutes: episode.runtime,
                stillURL: (episode.image?.original ?? episode.image?.medium).flatMap(URL.init(string:))
            )
        }
        record.backdropURL = try? await backdrop(for: showID)
        return record
    }

    private func backdrop(for showID: Int) async throws -> URL? {
        guard let url = URL(string: "\(Self.base)/shows/\(showID)/images") else { return nil }
        let images = try await HTTPClient.get([ShowImage].self, from: url, provider: id)
        let background = images.first { $0.type == "background" && $0.main == true } ?? images.first { $0.type == "background" }
        return background?.resolutions.original.flatMap { URL(string: $0.url) }
    }

    private func candidate(from show: Show) -> MetadataCandidate {
        MetadataCandidate(
            provider: id,
            externalID: String(show.id),
            title: show.name,
            year: MetadataText.year(in: show.premiered),
            kind: .series,
            overview: MetadataText.plainText(show.summary),
            posterURL: (show.image?.medium ?? show.image?.original).flatMap(URL.init(string:))
        )
    }

    // MARK: DTOs

    private struct SearchResult: Decodable {
        let show: Show
    }

    private struct Show: Decodable {
        let id: Int
        let name: String
        let premiered: String?
        let summary: String?
        let genres: [String]?
        let runtime: Int?
        let averageRuntime: Int?
        let rating: Rating?
        let image: ImageSet?
        let externals: Externals?
        let network: Channel?
        let webChannel: Channel?
        let embedded: Embedded?

        enum CodingKeys: String, CodingKey {
            case id, name, premiered, summary, genres, runtime, averageRuntime, rating, image, externals, network, webChannel
            case embedded = "_embedded"
        }
    }

    private struct Rating: Decodable {
        let average: Double?
    }

    private struct ImageSet: Decodable {
        let medium: String?
        let original: String?
    }

    private struct Channel: Decodable {
        let name: String
    }

    private struct Externals: Decodable {
        let imdb: String?
    }

    private struct Embedded: Decodable {
        let episodes: [ShowEpisode]?
        let cast: [CastCredit]?
    }

    private struct ShowEpisode: Decodable {
        let season: Int?
        let number: Int?
        let name: String?
        let summary: String?
        let runtime: Int?
        let image: ImageSet?
    }

    private struct CastCredit: Decodable {
        let person: Person
    }

    private struct Person: Decodable {
        let name: String
    }

    private struct ShowImage: Decodable {
        let type: String?
        let main: Bool?
        let resolutions: Resolutions
    }

    private struct Resolutions: Decodable {
        let original: ImageFile?
    }

    private struct ImageFile: Decodable {
        let url: String
    }
}
