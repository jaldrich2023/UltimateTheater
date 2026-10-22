//
//  Profile.swift
//  Ultimate Theater
//

import SwiftUI
import SwiftData
import AppKit

/// The most mature content a profile may see, using US film and TV ratings.
enum RatingLimit: Int, CaseIterable, Identifiable, Codable {
    case littleKids
    case olderKids
    case teens
    case everything

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .littleKids: "Little Kids"
        case .olderKids: "Older Kids"
        case .teens: "Teens"
        case .everything: "All Ratings"
        }
    }

    var summary: String {
        switch self {
        case .littleKids: "Titles for all ages."
        case .olderKids: "Adds parental-guidance titles."
        case .teens: "Adds titles for ages 13 and up."
        case .everything: "No restrictions."
        }
    }

    /// Ratings this level adds to the ones below it, in a country's rating system.
    func addedRatings(in country: String = RatingsRegion.current) -> [String] {
        ContentRating.ratings(for: self, country: country)
    }

    /// Every rating allowed at this level in a country's rating system.
    func allowedRatings(in country: String = RatingsRegion.current) -> [String] {
        RatingLimit.allCases.filter { $0 <= self }.flatMap { $0.addedRatings(in: country) }
    }
}

extension RatingLimit: Comparable {
    static func < (a: RatingLimit, b: RatingLimit) -> Bool { a.rawValue < b.rawValue }
}

/// A household viewer. Each profile keeps its own My List, watch progress, and ratings.
struct Profile: Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String
    let colors: [Color]
    var paletteIndex = 0
    var ratingLimit: RatingLimit = .everything
    /// Whether a restricted profile may see titles with no known rating.
    var allowsUnrated = true
    /// Opening this profile asks for its PIN.
    var hasPIN = false
    /// A picture chosen for the profile, shown instead of the symbol.
    var image: NSImage?
    var imageData: Data?
    /// When the profile was last opened; nil if it never has been.
    var lastUsed: Date?

    /// Most profiles the picker offers.

    /// "Used today", "Used yesterday", "Used Oct 3", or "Not used yet".
    var lastUsedDescription: String {
        guard let lastUsed else { return "Not used yet" }
        let calendar = Calendar.current
        if calendar.isDateInToday(lastUsed) { return "Used today" }
        if calendar.isDateInYesterday(lastUsed) { return "Used yesterday" }
        let sameYear = calendar.isDate(lastUsed, equalTo: .now, toGranularity: .year)
        return "Used " + lastUsed.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
    }
    static let maximumCount = 10

    /// Profiles below the teen level get the family-friendly treatment.
    var isKids: Bool { ratingLimit < .teens }

    /// Whether this profile may see a title, judged by the household country's rating.
    func allows(_ title: Title, country: String = RatingsRegion.current) -> Bool {
        guard ratingLimit < .everything else { return true }
        guard let level = ContentRating.level(for: title, country: country) else { return allowsUnrated }
        return level <= ratingLimit
    }

    /// Avatar colors offered when creating a profile.
    static let palettes: [[Color]] = [
        [Color(hex: 0xFF6A3D), Color(hex: 0xC81D4E)],
        [Color(hex: 0x4F7CFF), Color(hex: 0x6B2FD9)],
        [Color(hex: 0x2BB6A3), Color(hex: 0x0E5E6F)],
        [Color(hex: 0xFFD23F), Color(hex: 0xFF7A00)],
        [Color(hex: 0xFF5FA2), Color(hex: 0x9B2C8F)],
        [Color(hex: 0x6EE07A), Color(hex: 0x1F8A4C)],
        [Color(hex: 0x8E9AAF), Color(hex: 0x3C4657)],
        [Color(hex: 0x3DD6FF), Color(hex: 0x1E5BD8)],
    ]

    /// Avatar symbols offered when creating a profile.
    static let symbols = [
        "person.fill", "face.smiling.inverse", "star.fill", "heart.fill", "popcorn.fill", "film.fill",
        "gamecontroller.fill", "music.note", "pawprint.fill", "leaf.fill", "bolt.fill", "moon.stars.fill",
        "crown.fill", "sparkles", "flame.fill", "airplane",
    ]

    init(id: String, name: String, symbol: String, paletteIndex: Int, ratingLimit: RatingLimit, allowsUnrated: Bool) {
        let index = min(max(paletteIndex, 0), Self.palettes.count - 1)
        self.id = id
        self.name = name
        self.symbol = symbol
        self.colors = Self.palettes[index]
        self.paletteIndex = index
        self.ratingLimit = ratingLimit
        self.allowsUnrated = allowsUnrated
    }

    init(_ stored: StoredProfile) {
        self.init(id: stored.id, name: stored.name, symbol: stored.symbol, paletteIndex: stored.paletteIndex,
                  ratingLimit: RatingLimit(rawValue: stored.ratingLimitRaw) ?? .everything,
                  allowsUnrated: stored.allowsUnrated)
        hasPIN = stored.pinHash != nil
        imageData = stored.imageData
        image = stored.imageData.flatMap(NSImage.init(data:))
        lastUsed = stored.lastUsed
    }

    /// Profiles that earlier versions created automatically. When one of them already has
    /// watch history, it's kept as a regular profile so nothing is lost.
    static let legacy: [(id: String, name: String, symbol: String, palette: Int, limit: RatingLimit)] = [
        ("primary", "Primary", "person.fill", 0, .everything),
        ("movie-night", "Movie Night", "popcorn.fill", 1, .everything),
        ("guest", "Guest", "person.fill", 2, .everything),
        ("kids", "Kids", "star.fill", 3, .olderKids),
    ]
}

/// A viewer profile, saved in the library database.
@Model
final class StoredProfile {
    @Attribute(.unique) var id: String
    var name: String
    var symbol: String
    var paletteIndex: Int
    var ratingLimitRaw: Int = RatingLimit.everything.rawValue
    var allowsUnrated = true
    /// Salted hash of the profile's PIN, when it has one.
    var pinHash: String?
    /// The profile picture (square JPEG), when one was chosen.
    @Attribute(.externalStorage) var imageData: Data?
    var dateCreated: Date
    /// When the profile was last opened.
    var lastUsed: Date?

    init(id: String = "profile-\(UUID().uuidString)", name: String, symbol: String, paletteIndex: Int,
         ratingLimit: RatingLimit, allowsUnrated: Bool) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.paletteIndex = paletteIndex
        self.ratingLimitRaw = ratingLimit.rawValue
        self.allowsUnrated = allowsUnrated
        self.dateCreated = .now
    }
}

/// Prepares chosen pictures for use as avatars.
enum ProfilePicture {
    /// Crops an image to a centered square and scales it to 512 pixels, as JPEG.
    static func avatarData(from image: NSImage) -> Data? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = min(source.width, source.height)
        let crop = CGRect(x: (source.width - side) / 2, y: (source.height - side) / 2, width: side, height: side)
        guard let square = source.cropping(to: crop) else { return nil }
        let size = 512
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    static func avatarData(from url: URL) -> Data? {
        NSImage(contentsOf: url).flatMap { avatarData(from: $0) }
    }
}

/// Shared visual constants.
enum Theme {
    /// Signature accent used for progress, highlights, and the brand mark.
    static let accent = Color(hex: 0xFF3D5A)
    static let gold = Color(hex: 0xFFC247)
    static let background = Color(hex: 0x0A0A0F)
    static let cardRadius: CGFloat = 12
}
