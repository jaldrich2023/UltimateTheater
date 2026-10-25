//
//  PlaybackTypes.swift
//  Ultimate Theater
//
//  Engine-neutral playback types shared by the native (AVFoundation) driver and
//  the Theater engine: track options, chapters, subtitle cues, and the user's
//  saved audio/subtitle preferences.
//

import Foundation

/// An audio or subtitle choice presented to the viewer.
nonisolated struct TrackOption: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case audio
        case subtitle
    }

    /// Engine-specific identifier (track number or media-selection index).
    let id: String
    let kind: Kind
    /// BCP 47 / ISO 639 language code, if known.
    let languageCode: String?
    /// The track's own name, e.g. "Director's Commentary".
    let name: String?
    /// Format details, e.g. "Dolby Digital 5.1".
    let format: String?
    var isForced = false
    var isSDH = false
    var isDefault = false
    var isSupported = true

    var languageName: String {
        guard let languageCode, !["und", "mis", "zxx"].contains(languageCode) else { return "Unknown Language" }
        return Locale.current.localizedString(forLanguageCode: languageCode) ?? languageCode
    }

    /// "English · Dolby Digital 5.1" / "Spanish (Forced)".
    var title: String {
        var base = languageName
        if let name, !name.isEmpty, name.lowercased() != languageName.lowercased() {
            base += " — \(name)"
        }
        if isForced { base += " (Forced)" } else if isSDH { base += " (SDH)" }
        return base
    }

    var detail: String? {
        isSupported ? format : [format, "not supported"].compactMap { $0 }.joined(separator: " · ")
    }

    var primaryLanguage: String? {
        languageCode.map { Locale.Language(identifier: $0).languageCode?.identifier ?? $0 }
    }
}

nonisolated struct MediaTrackList: Equatable, Sendable {
    var audio: [TrackOption] = []
    var subtitles: [TrackOption] = []

    var isEmpty: Bool { audio.isEmpty && subtitles.isEmpty }
}

nonisolated struct PlaybackChapter: Hashable, Sendable {
    let title: String
    let start: Double
    let end: Double?
}

nonisolated struct SubtitleCue: Hashable, Sendable {
    let start: Double
    /// Open-ended (infinity) for image subtitles until a later display set clears them.
    var end: Double
    let text: String
    var bitmaps: [SubtitleBitmap] = []
}

// MARK: - Preferences

/// What to pick when playback starts. Language-based so it carries across titles.
nonisolated struct TrackPreference: Codable, Hashable, Sendable {
    var languageCode: String?
    var name: String?
    var isForced = false
    var isSDH = false

    init(_ option: TrackOption) {
        languageCode = option.primaryLanguage
        name = option.name
        isForced = option.isForced
        isSDH = option.isSDH
    }

    /// The best matching option: same language and flags, then same language.
    func bestMatch(in options: [TrackOption]) -> TrackOption? {
        let candidates = options.filter { $0.isSupported && $0.primaryLanguage == languageCode }
        return candidates.first { $0.isForced == isForced && $0.isSDH == isSDH && $0.name == name }
            ?? candidates.first { $0.isForced == isForced && $0.isSDH == isSDH }
            ?? candidates.first
    }
}

nonisolated struct PlaybackSelection: Codable, Hashable, Sendable {
    enum Subtitles: Codable, Hashable, Sendable {
        /// Let the file decide (forced subtitles in the audio language, if any).
        case automatic
        case off
        case track(TrackPreference)
    }

    var audio: TrackPreference?
    var subtitles: Subtitles = .automatic

    static let automatic = PlaybackSelection()

    /// Resolves this selection against a file's actual tracks.
    func resolve(in tracks: MediaTrackList) -> (audio: TrackOption?, subtitle: TrackOption?) {
        let supportedAudio = tracks.audio.filter(\.isSupported)
        let audio = self.audio?.bestMatch(in: supportedAudio)
            ?? supportedAudio.first(where: \.isDefault)
            ?? supportedAudio.first
        let subtitle: TrackOption?
        switch subtitles {
        case .off:
            subtitle = nil
        case .track(let preference):
            subtitle = preference.bestMatch(in: tracks.subtitles)
        case .automatic:
            // Forced subtitles (foreign-dialogue only) in the audio's language.
            subtitle = tracks.subtitles.first { $0.isSupported && $0.isForced && $0.primaryLanguage == audio?.primaryLanguage }
        }
        return (audio, subtitle)
    }
}

/// Saved selections per profile: an "every title" default plus per-title overrides.
@Observable
final class PlaybackPreferences {
    private static let storageKey = "playback.selections"

    private struct Stored: Codable {
        var defaults: [String: PlaybackSelection] = [:]          // profileID → selection
        var titles: [String: [String: PlaybackSelection]] = [:]  // profileID → titleID → selection
    }

    private var stored: Stored {
        didSet {
            if let data = try? JSONEncoder().encode(stored) {
                UserDefaults.standard.set(data, forKey: Self.storageKey)
            }
        }
    }

    init() {
        stored = UserDefaults.standard.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
    }

    func selection(profileID: String, titleID: String) -> PlaybackSelection? {
        stored.titles[profileID]?[titleID] ?? stored.defaults[profileID]
    }

    /// Forgets every saved choice.
    func removeAll() {
        stored = Stored()
    }

    /// Forgets every saved choice for a deleted profile.
    func removeAll(forProfile profileID: String) {
        stored.defaults[profileID] = nil
        stored.titles[profileID] = nil
    }

    func saveDefault(_ selection: PlaybackSelection, profileID: String) {
        stored.defaults[profileID] = selection
        stored.titles[profileID] = nil // A new default replaces per-title choices.
    }

    func save(_ selection: PlaybackSelection, profileID: String, titleID: String) {
        stored.titles[profileID, default: [:]][titleID] = selection
    }

    func clear(profileID: String) {
        stored.defaults[profileID] = nil
        stored.titles[profileID] = nil
    }
}

// MARK: - Subtitle text

nonisolated enum SubtitleText {
    /// Plain text from SubRip (with HTML-style tags) or SSA/ASS event lines.
    static func plain(_ raw: String, isASS: Bool) -> String {
        var text = raw
        if isASS {
            // Matroska ASS blocks: ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text
            let parts = text.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            if parts.count == 9 { text = String(parts[8]) }
            text = text.replacing(/\{[^}]*\}/, with: "")
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\h", with: " ")
        }
        text = text.replacing(/<[^>]+>/, with: "")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
