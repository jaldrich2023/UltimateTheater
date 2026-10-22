//
//  WikipediaProvider.swift
//  Ultimate Theater
//
//  English Wikipedia (REST API). Keyless fallback for movies and TV: synopsis,
//  year, director, and the lead image (usually the poster). Text is CC BY-SA.
//

import Foundation

nonisolated struct WikipediaProvider: MetadataProvider {
    let id = MetadataProviderID.wikipedia

    func search(_ query: MetadataQuery) async throws -> [MetadataCandidate] {
        let hint = query.kind == .movie ? "film" : "television series"
        let text = [query.title, query.year.map(String.init), hint].compactMap { $0 }.joined(separator: " ")
        var components = URLComponents(string: "https://en.wikipedia.org/w/rest.php/v1/search/page")
        components?.queryItems = [URLQueryItem(name: "q", value: text), URLQueryItem(name: "limit", value: "10")]
        guard let url = components?.url else { throw MetadataError.badResponse }

        let response = try await HTTPClient.get(SearchResponse.self, from: url, provider: id)
        return response.pages.compactMap { page in
            guard let description = page.description, Self.describes(query.kind, description) else { return nil }
            return MetadataCandidate(
                provider: id,
                externalID: page.key,
                title: Self.cleanTitle(page.title),
                year: MetadataText.year(in: description),
                kind: query.kind,
                overview: description,
                posterURL: nil
            )
        }
    }

    func details(for candidate: MetadataCandidate, query: MetadataQuery) async throws -> MetadataRecord {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        guard let key = candidate.externalID.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(key)") else {
            throw MetadataError.badResponse
        }
        let summary = try await HTTPClient.get(Summary.self, from: url, keyStrategy: .convertFromSnakeCase, provider: id)

        var record = MetadataRecord(provider: id)
        record.wikipediaKey = candidate.externalID
        record.title = Self.cleanTitle(summary.title)
        record.year = MetadataText.year(in: summary.description) ?? candidate.year
        record.synopsis = MetadataText.value(summary.extract)
        if let description = summary.description, candidate.kind == .movie,
           let match = description.firstMatch(of: /film by (.+)$/) {
            let director = String(match.1)
            record.director = director.prefix(1).uppercased() + director.dropFirst()
        }
        record.posterURL = summary.originalimage.flatMap { URL(string: Self.absolute($0.source)) }
        return record
    }

    // MARK: Helpers

    /// Keeps "2010 film by Christopher Nolan" / "American television series (2022–present)";
    /// drops characters, soundtracks, franchises, and lists.
    static func describes(_ kind: TitleKind, _ description: String) -> Bool {
        let lowered = description.lowercased()
        let excluded = ["soundtrack", "album", "character", "franchise", "list of", "episode", "novel", "video game", "song"]
        guard !excluded.contains(where: lowered.contains) else { return false }
        switch kind {
        case .movie: return lowered.contains("film") && !lowered.contains("series")
        case .series: return lowered.contains("television series") || lowered.contains("tv series")
            || lowered.contains("miniseries") || lowered.contains("animated series") || lowered.contains("sitcom")
        }
    }

    /// "Severance (TV series)" → "Severance", "Heat (1995 film)" → "Heat".
    static func cleanTitle(_ title: String) -> String {
        title.replacing(/\s*\((?:[^)]*(?:film|series|miniseries|TV)[^)]*)\)$/, with: "")
    }

    private static func absolute(_ url: String) -> String {
        url.hasPrefix("//") ? "https:" + url : url
    }

    // MARK: DTOs

    private struct SearchResponse: Decodable {
        let pages: [Page]
    }

    private struct Page: Decodable {
        let key: String
        let title: String
        let description: String?
    }

    private struct Summary: Decodable {
        let title: String
        let description: String?
        let extract: String?
        let originalimage: ImageInfo?
    }

    private struct ImageInfo: Decodable {
        let source: String
    }
}
