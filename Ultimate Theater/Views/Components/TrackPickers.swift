//
//  TrackPickers.swift
//  Ultimate Theater
//
//  Audio and subtitle choices shown on a title's page before playback.
//

import SwiftUI

/// The tracks a title offers and what the viewer has chosen.
struct TrackChoice: Equatable {
    var list: MediaTrackList?
    var audioID: String?
    /// `nil` means subtitles off.
    var subtitleID: String?
    /// What would be used without any change: the saved preference, else the file default.
    private var baseline: (audio: String?, subtitle: String?) = (nil, nil)

    static func == (lhs: TrackChoice, rhs: TrackChoice) -> Bool {
        lhs.list == rhs.list && lhs.audioID == rhs.audioID && lhs.subtitleID == rhs.subtitleID
            && lhs.baseline.audio == rhs.baseline.audio && lhs.baseline.subtitle == rhs.baseline.subtitle
    }

    init() {}

    init(list: MediaTrackList, saved: PlaybackSelection?) {
        self.list = list
        let resolved = (saved ?? .automatic).resolve(in: list)
        audioID = resolved.audio?.id
        subtitleID = resolved.subtitle?.id
        baseline = (audioID, subtitleID)
    }

    var hasChoices: Bool {
        guard let list else { return false }
        return list.audio.count > 1 || !list.subtitles.isEmpty
    }

    /// The viewer changed something from what would play anyway.
    var isCustomized: Bool {
        list != nil && (audioID != baseline.audio || subtitleID != baseline.subtitle)
    }

    var audio: TrackOption? { list?.audio.first { $0.id == audioID } }
    var subtitle: TrackOption? { list?.subtitles.first { $0.id == subtitleID } }

    /// A language-based selection that carries across episodes and titles.
    var selection: PlaybackSelection? {
        guard list != nil else { return nil }
        return PlaybackSelection(audio: audio.map { TrackPreference($0) },
                                 subtitles: subtitle.map { .track(TrackPreference($0)) } ?? .off)
    }

    mutating func markSaved() {
        baseline = (audioID, subtitleID)
    }
}

struct TrackPickers: View {
    @Binding var choice: TrackChoice

    var body: some View {
        if let list = choice.list, choice.hasChoices {
            HStack(spacing: 10) {
                if !list.audio.isEmpty {
                    Menu {
                        Picker("Audio", selection: $choice.audioID) {
                            ForEach(list.audio) { option in
                                Text(Self.label(option))
                                    .tag(Optional(option.id))
                                    .disabled(!option.isSupported)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label(choice.audio.map { Self.label($0) } ?? "Audio", systemImage: "waveform")
                            .lineLimit(1)
                    }
                    .help("Audio track")
                }

                Menu {
                    Picker("Subtitles", selection: $choice.subtitleID) {
                        Text("Off").tag(String?.none)
                        ForEach(list.subtitles) { option in
                            Text(Self.label(option))
                                .tag(Optional(option.id))
                                .disabled(!option.isSupported)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(choice.subtitle.map { "Subtitles: \($0.title)" } ?? "Subtitles: Off",
                          systemImage: choice.subtitle == nil ? "captions.bubble" : "captions.bubble.fill")
                        .lineLimit(1)
                }
                .disabled(list.subtitles.isEmpty)
                .help(list.subtitles.isEmpty ? "This title has no subtitles" : "Subtitles")

                Text(summary(list))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .font(.callout.weight(.medium))
            .fixedSize()
        }
    }

    private func summary(_ list: MediaTrackList) -> String {
        let audio = list.audio.count == 1 ? "1 audio track" : "\(list.audio.count) audio tracks"
        let subtitles = list.subtitles.count == 1 ? "1 subtitle" : "\(list.subtitles.count) subtitles"
        return "\(audio) · \(subtitles)"
    }

    static func label(_ option: TrackOption) -> String {
        [option.title, option.detail].compactMap { $0 }.joined(separator: " · ")
    }
}
