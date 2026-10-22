//
//  LibraryModels.swift
//  Ultimate Theater
//

import Foundation
import SwiftData

/// Resume point for a movie or episode, scoped to a profile.
@Model
final class WatchProgress {
    @Attribute(.unique) var key: String
    var profileID: String
    var titleID: String
    var playbackID: String
    var position: Double
    var duration: Double
    var lastWatched: Date

    init(profileID: String, titleID: String, playbackID: String, position: Double, duration: Double) {
        self.key = WatchProgress.key(profileID: profileID, playbackID: playbackID)
        self.profileID = profileID
        self.titleID = titleID
        self.playbackID = playbackID
        self.position = position
        self.duration = duration
        self.lastWatched = .now
    }

    static func key(profileID: String, playbackID: String) -> String {
        "\(profileID)|\(playbackID)"
    }

    var fraction: Double {
        duration > 0 ? min(max(position / duration, 0), 1) : 0
    }

    /// Treat the last few percent (credits) as finished.
    var isFinished: Bool { fraction >= 0.95 }

    var remainingDescription: String {
        let minutes = max(Int((duration - position) / 60), 1)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m left" : "\(minutes)m left"
    }
}

/// A title saved to a profile's My List.
@Model
final class MyListEntry {
    @Attribute(.unique) var key: String
    var profileID: String
    var titleID: String
    var addedAt: Date

    init(profileID: String, titleID: String) {
        self.key = "\(profileID)|\(titleID)"
        self.profileID = profileID
        self.titleID = titleID
        self.addedAt = .now
    }
}

/// A profile's own rating of a title, on a 0–10 scale in half steps.
@Model
final class UserRating {
    @Attribute(.unique) var key: String
    var profileID: String
    var titleID: String
    var score: Double
    var ratedAt: Date

    init(profileID: String, titleID: String, score: Double) {
        self.key = UserRating.key(profileID: profileID, titleID: titleID)
        self.profileID = profileID
        self.titleID = titleID
        self.score = score
        self.ratedAt = .now
    }

    static func key(profileID: String, titleID: String) -> String {
        "\(profileID)|\(titleID)"
    }

    /// "8.5", "7".
    static func display(_ score: Double) -> String {
        score.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(score)) : String(format: "%.1f", score)
    }
}
