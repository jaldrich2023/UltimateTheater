//
//  ContentRatings.swift
//  Ultimate Theater
//
//  Film and TV ratings from rating authorities around the world, mapped onto the four
//  profile limits. Titles carry each country's certification (from TMDB), and the
//  household's ratings country decides which one is shown and enforced.
//

import Foundation

enum ContentRating {
    /// Ratings by country (ISO 3166-1), most permissive first within each level.
    /// Ratings not listed are read by their age number (see `level(of:country:)`).
    static let systems: [String: [RatingLimit: [String]]] = [
        "US": [.littleKids: ["G", "TV-Y", "TV-G"], .olderKids: ["PG", "TV-Y7", "TV-Y7-FV", "TV-PG"],
               .teens: ["PG-13", "TV-14"], .everything: ["R", "NC-17", "TV-MA"]],
        "GB": [.littleKids: ["U", "UC"], .olderKids: ["PG"], .teens: ["12", "12A"], .everything: ["15", "18", "R18"]],
        "IE": [.littleKids: ["G"], .olderKids: ["PG"], .teens: ["12A", "12", "15A"], .everything: ["15", "16", "18"]],
        "CA": [.littleKids: ["G", "C", "E"], .olderKids: ["PG", "C8"], .teens: ["14A", "14+"],
               .everything: ["18A", "18+", "R", "A"]],
        "AU": [.littleKids: ["G", "P", "C", "E"], .olderKids: ["PG"], .teens: ["M"], .everything: ["MA15+", "MA 15+", "AV15+", "R18+", "R 18+", "X18+"]],
        "NZ": [.littleKids: ["G"], .olderKids: ["PG"], .teens: ["M", "R13", "RP13"], .everything: ["R15", "R16", "RP16", "R18", "RP18", "R"]],
        "DE": [.littleKids: ["0"], .olderKids: ["6"], .teens: ["12"], .everything: ["16", "18"]],
        "AT": [.littleKids: ["0"], .olderKids: ["6", "8", "10"], .teens: ["12", "14"], .everything: ["16", "18"]],
        "CH": [.littleKids: ["0"], .olderKids: ["6", "8", "10"], .teens: ["12", "14"], .everything: ["16", "18"]],
        "FR": [.littleKids: ["U", "TP"], .olderKids: ["10"], .teens: ["12"], .everything: ["16", "18"]],
        "ES": [.littleKids: ["A", "APTA", "TP", "ERI"], .olderKids: ["7"], .teens: ["12", "13"], .everything: ["16", "18", "X"]],
        "IT": [.littleKids: ["T"], .olderKids: ["6+"], .teens: ["14+", "VM14"], .everything: ["18+", "VM18"]],
        "PT": [.littleKids: ["M/3", "M/4"], .olderKids: ["M/6"], .teens: ["M/12", "M/14"], .everything: ["M/16", "M/18", "P"]],
        "NL": [.littleKids: ["AL"], .olderKids: ["6", "9"], .teens: ["12", "14"], .everything: ["16", "18"]],
        "BE": [.littleKids: ["AL", "KT", "KT/EA"], .olderKids: ["6", "9"], .teens: ["12", "14"], .everything: ["16", "18", "KNT/ENA"]],
        "SE": [.littleKids: ["BTL"], .olderKids: ["7", "11"], .teens: ["15"], .everything: ["18"]],
        "NO": [.littleKids: ["A"], .olderKids: ["6", "9"], .teens: ["12", "15"], .everything: ["18"]],
        "DK": [.littleKids: ["A"], .olderKids: ["7", "11"], .teens: ["15"], .everything: ["F", "18"]],
        "FI": [.littleKids: ["S", "K-3"], .olderKids: ["K-7"], .teens: ["K-12"], .everything: ["K-16", "K-18"]],
        "PL": [.littleKids: ["AL", "0"], .olderKids: ["7"], .teens: ["12", "15"], .everything: ["16", "18", "21"]],
        "RU": [.littleKids: ["0+"], .olderKids: ["6+"], .teens: ["12+"], .everything: ["16+", "18+"]],
        "TR": [.littleKids: ["GENEL IZLEYICI", "GENEL İZLEYICI", "G"], .olderKids: ["7+", "7A"], .teens: ["13+", "13A"], .everything: ["15+", "16+", "18+"]],
        "JP": [.littleKids: ["G"], .olderKids: ["PG12"], .teens: ["R15+"], .everything: ["R18+"]],
        "KR": [.littleKids: ["ALL", "전체관람가"], .olderKids: ["12", "12세관람가"], .teens: ["15", "15세관람가"],
               .everything: ["18", "19", "청소년관람불가", "제한상영가"]],
        "HK": [.littleKids: ["I"], .olderKids: ["IIA"], .teens: ["IIB"], .everything: ["III"]],
        "TW": [.littleKids: ["0+", "G"], .olderKids: ["6+", "P"], .teens: ["12+", "PG12"], .everything: ["15+", "PG15", "18+", "R"]],
        "SG": [.littleKids: ["G"], .olderKids: ["PG"], .teens: ["PG13"], .everything: ["NC16", "M18", "R21"]],
        "MY": [.littleKids: ["U"], .olderKids: ["P13"], .teens: ["13"], .everything: ["16", "18", "18SG", "18SX", "18PA", "18PL"]],
        "PH": [.littleKids: ["G"], .olderKids: ["PG"], .teens: ["R-13"], .everything: ["R-16", "R-18", "X"]],
        "IN": [.littleKids: ["U"], .olderKids: ["UA", "U/A", "UA 7+", "UA7+"], .teens: ["UA 13+", "UA13+", "UA 16+", "UA16+"], .everything: ["A", "S"]],
        "TH": [.littleKids: ["P", "G"], .olderKids: ["13"], .teens: ["15"], .everything: ["18", "20"]],
        "ID": [.littleKids: ["SU"], .olderKids: ["13+"], .teens: ["17+"], .everything: ["21+"]],
        "BR": [.littleKids: ["L", "AL"], .olderKids: ["10"], .teens: ["12", "14"], .everything: ["16", "18"]],
        "MX": [.littleKids: ["AA", "A"], .olderKids: ["B"], .teens: ["B-15", "B15"], .everything: ["C", "D"]],
        "AR": [.littleKids: ["ATP"], .olderKids: ["+13"], .teens: ["+16"], .everything: ["+18", "C"]],
        "CL": [.littleKids: ["TE", "TE+7"], .olderKids: ["7"], .teens: ["14"], .everything: ["18"]],
        "CO": [.littleKids: ["T"], .olderKids: ["7"], .teens: ["12", "15"], .everything: ["18", "X"]],
        "ZA": [.littleKids: ["A", "PG"], .olderKids: ["7-9PG", "10-12PG", "10"], .teens: ["13", "14"], .everything: ["16", "18", "X18"]],
        "IL": [.littleKids: ["ALL", "G"], .olderKids: ["PG"], .teens: ["12", "14"], .everything: ["16", "18"]],
        "AE": [.littleKids: ["G"], .olderKids: ["PG"], .teens: ["PG13", "PG15"], .everything: ["15+", "18+", "21+"]],
        "SA": [.littleKids: ["G"], .olderKids: ["PG"], .teens: ["PG12", "PG15", "R12", "R15"], .everything: ["R18"]],
        "EG": [.littleKids: ["G"], .olderKids: ["PG"], .teens: ["+12"], .everything: ["+16", "+18"]],
        "GR": [.littleKids: ["K"], .olderKids: ["K-8", "K-12"], .teens: ["K-13", "K-15"], .everything: ["K-17", "K-18"]],
        "HU": [.littleKids: ["KN"], .olderKids: ["6"], .teens: ["12"], .everything: ["16", "18", "X"]],
        "CZ": [.littleKids: ["U"], .olderKids: ["7"], .teens: ["12"], .everything: ["15", "18"]],
        "RO": [.littleKids: ["AG"], .olderKids: ["AP-12"], .teens: ["N-15"], .everything: ["IM-18", "IM-18-XXX"]],
        "LT": [.littleKids: ["V"], .olderKids: ["N-7"], .teens: ["N-13"], .everything: ["N-16", "N-18"]],
        "CN": [.littleKids: ["G"], .olderKids: ["PG"], .teens: ["PG-13"], .everything: ["R"]],
    ]

    /// Countries offered as the household's ratings country, by display name.
    static var countries: [(code: String, name: String)] {
        systems.keys.map { ($0, Locale.current.localizedString(forRegionCode: $0) ?? $0) }.sorted { $0.name < $1.name }
    }

    private static func normalized(_ rating: String) -> String {
        rating.uppercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "(").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// The level a rating belongs to. `country` selects the rating system; without one,
    /// US film and TV ratings are assumed. Ratings with only an age (such as "12+", "K-16",
    /// or "M/14") are read by that age. Returns nil for unrated or unknown ratings.
    static func level(of rating: String, country: String? = nil) -> RatingLimit? {
        let value = normalized(rating)
        guard !value.isEmpty, !["NR", "UNRATED", "NOT RATED", "N/A", "TBC", "BANNED", "-"].contains(value) else { return nil }
        let system = systems[country ?? "US"] ?? systems["US"]!
        for (level, ratings) in system where ratings.contains(where: { normalized($0) == value }) {
            return level
        }
        if country == nil || country == "US" {
            // Common UK ratings also show up in US-sourced data.
            if let level = level(of: value, country: "GB"), value != "PG" { return level }
        }
        // Fallback: the age in the rating.
        let digits = value.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard let age = digits.max() else { return nil }
        switch age {
        case ..<6: return .littleKids
        case 6...11: return .olderKids
        case 12...14: return .teens
        default: return .everything
        }
    }

    /// The level that governs a title in the given country: that country's certification,
    /// else the strictest certification known from anywhere (the safer choice), else the
    /// title's primary rating.
    static func level(for title: Title, country: String) -> RatingLimit? {
        if let rating = title.certifications[country], let level = level(of: rating, country: country) { return level }
        let known = title.certifications.compactMap { level(of: $0.value, country: $0.key) }
        if let strictest = known.max() { return strictest }
        return level(of: title.maturity)
    }

    /// Ratings to show for a level, in the household's rating system.
    static func ratings(for limit: RatingLimit, country: String) -> [String] {
        (systems[country] ?? systems["US"]!)[limit] ?? []
    }
}

/// Notices shown wherever ratings are explained.
enum RatingNotices {
    static let summary = "Ratings come from each country's rating authority, as published by TMDB and OMDb, and are shown for your ratings country. Ultimate Theater isn't affiliated with or endorsed by any rating authority."
    static let mpa = "G, PG, PG-13, R, and NC-17 are certification marks of the Motion Picture Association (MPA). Film ratings are assigned by the Classification and Rating Administration (filmratings.com)."
    static let tv = "TV-Y, TV-Y7, TV-G, TV-PG, TV-14, and TV-MA are TV Parental Guidelines ratings, administered by the TV Parental Guidelines Monitoring Board (tvguidelines.org)."
}

/// The country whose rating authority the household follows.
enum RatingsRegion {
    static let key = "ratings.country"

    static var current: String {
        if let stored = UserDefaults.standard.string(forKey: key), ContentRating.systems[stored] != nil { return stored }
        let region = Locale.current.region?.identifier ?? "US"
        return ContentRating.systems[region] != nil ? region : "US"
    }
}

extension Title {
    /// The rating to show: the household country's, else the primary rating.
    var displayRating: String {
        certifications[RatingsRegion.current] ?? maturity
    }
}
