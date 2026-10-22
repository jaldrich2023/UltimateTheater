//
//  Genre.swift
//  Ultimate Theater
//

import SwiftUI

enum Genre: String, Hashable, CaseIterable, Identifiable {
    case action
    case sciFi
    case drama
    case comedy
    case thriller
    case mystery
    case fantasy
    case animation
    case family
    case documentary
    case romance
    case horror

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .action: "Action"
        case .sciFi: "Sci-Fi"
        case .drama: "Drama"
        case .comedy: "Comedy"
        case .thriller: "Thriller"
        case .mystery: "Mystery"
        case .fantasy: "Fantasy"
        case .animation: "Animation"
        case .family: "Family"
        case .documentary: "Documentary"
        case .romance: "Romance"
        case .horror: "Horror"
        }
    }

    var systemImage: String {
        switch self {
        case .action: "bolt.fill"
        case .sciFi: "sparkles"
        case .drama: "theatermasks.fill"
        case .comedy: "face.smiling.inverse"
        case .thriller: "eye.fill"
        case .mystery: "magnifyingglass"
        case .fantasy: "wand.and.stars"
        case .animation: "paintpalette.fill"
        case .family: "figure.2.and.child.holdinghands"
        case .documentary: "globe.americas.fill"
        case .romance: "heart.fill"
        case .horror: "moon.haze.fill"
        }
    }

    /// Two-stop gradient used for genre hub tiles.
    var colors: [Color] {
        switch self {
        case .action: [Color(hex: 0xFF5E3A), Color(hex: 0x8A1C0A)]
        case .sciFi: [Color(hex: 0x3A7BFF), Color(hex: 0x10154A)]
        case .drama: [Color(hex: 0xB3427A), Color(hex: 0x3A0C2A)]
        case .comedy: [Color(hex: 0xFFC53A), Color(hex: 0xC2410C)]
        case .thriller: [Color(hex: 0x4B5563), Color(hex: 0x0B0F17)]
        case .mystery: [Color(hex: 0x6D5BD0), Color(hex: 0x1C1440)]
        case .fantasy: [Color(hex: 0x2DD4BF), Color(hex: 0x134E4A)]
        case .animation: [Color(hex: 0xF472B6), Color(hex: 0x7C3AED)]
        case .family: [Color(hex: 0x34D399), Color(hex: 0x065F46)]
        case .documentary: [Color(hex: 0x22A6F0), Color(hex: 0x0B3B5C)]
        case .romance: [Color(hex: 0xFB7185), Color(hex: 0x881337)]
        case .horror: [Color(hex: 0x7F1D1D), Color(hex: 0x050505)]
        }
    }
}

extension Genre {
    /// Maps a provider's genre name (TMDB, TVmaze, OMDb, …) onto the app's genres.
    /// Combined names like "Sci-Fi & Fantasy" map to several.
    static func from(providerName name: String) -> [Genre] {
        let key = name.lowercased()
        var result: [Genre] = []
        func add(_ genre: Genre, if words: String...) {
            if words.contains(where: key.contains), !result.contains(genre) { result.append(genre) }
        }
        add(.action, if: "action", "adventure", "war", "western", "martial")
        add(.sciFi, if: "sci-fi", "science fiction", "science-fiction", "sci fi")
        add(.fantasy, if: "fantasy", "supernatural")
        add(.drama, if: "drama", "history", "biography", "legal", "medical")
        add(.comedy, if: "comedy", "sitcom")
        add(.thriller, if: "thriller", "crime", "espionage", "suspense")
        add(.mystery, if: "mystery")
        add(.animation, if: "animation", "anime")
        add(.family, if: "family", "kids", "children")
        add(.documentary, if: "documentary", "nature", "reality", "news")
        add(.romance, if: "romance")
        add(.horror, if: "horror")
        return result
    }

    static func from(providerNames names: [String]) -> [Genre] {
        var result: [Genre] = []
        for genre in names.flatMap({ from(providerName: $0) }) where !result.contains(genre) {
            result.append(genre)
        }
        return result
    }
}

extension Color {
    /// Creates a color from a 24-bit RGB hex literal, e.g. `Color(hex: 0xFF8800)`.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
