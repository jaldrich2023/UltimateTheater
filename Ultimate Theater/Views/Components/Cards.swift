//
//  Cards.swift
//  Ultimate Theater
//

import SwiftUI
import SwiftData

// MARK: - Hover

/// Lifts a card toward the viewer on pointer hover, with a soft shadow and highlight rim.
struct HoverLift: ViewModifier {
    var scale: CGFloat = 1.05
    var cornerRadius: CGFloat = Theme.cardRadius
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.white.opacity(isHovered ? 0.55 : 0.08), lineWidth: isHovered ? 2 : 1)
            }
            .scaleEffect(isHovered ? scale : 1)
            .shadow(color: .black.opacity(isHovered ? 0.6 : 0.25), radius: isHovered ? 18 : 6, y: isHovered ? 12 : 3)
            .zIndex(isHovered ? 1 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

extension View {
    func hoverLift(scale: CGFloat = 1.05, cornerRadius: CGFloat = Theme.cardRadius) -> some View {
        modifier(HoverLift(scale: scale, cornerRadius: cornerRadius))
    }

    /// Standard right-click actions for any title.
    func titleContextMenu(_ title: Title, model: AppModel) -> some View {
        contextMenu {
            Button("Play", systemImage: "play.fill") { model.playResuming(title) }
            Button("View Details", systemImage: "info.circle") { model.open(title) }
            Divider()
            if model.isInMyList(title) {
                Button("Remove from My List", systemImage: "checkmark") { model.toggleMyList(title) }
            } else {
                Button("Add to My List", systemImage: "plus") { model.toggleMyList(title) }
            }
            Divider()
            Button("Fix Match…", systemImage: "wand.and.stars") { model.matchingTitle = title }
            Button("Edit Info…", systemImage: "pencil") { model.editingTitle = title }
            Button("Show in Finder", systemImage: "folder") {
                model.library.revealInFinder(title.allEpisodes.first?.id ?? title.id)
            }
        }
    }
}

// MARK: - Cards

struct PosterCard: View {
    @Environment(AppModel.self) private var model
    let title: Title
    var width: CGFloat = 176

    var body: some View {
        Button { model.open(title) } label: {
            ArtworkView(title: title, style: .poster)
                .frame(width: width, height: width * 1.5)
                .clipShape(.rect(cornerRadius: Theme.cardRadius))
                .hoverLift()
        }
        .buttonStyle(.plain)
        .titleContextMenu(title, model: model)
        .help([title.name, title.subtitleLine].filter { !$0.isEmpty }.joined(separator: " · "))
    }
}

/// Poster that fills its grid cell, used in browse grids.
struct GridPosterCard: View {
    @Environment(AppModel.self) private var model
    let title: Title

    var body: some View {
        Button { model.open(title) } label: {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkView(title: title, style: .poster)
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .overlay(alignment: .topLeading) { LibraryStatusBadge(title: title).padding(8) }
                    .clipShape(.rect(cornerRadius: Theme.cardRadius))
                    .hoverLift(scale: 1.04)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(title.subtitleLine.isEmpty ? title.kind.displayName : title.subtitleLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .titleContextMenu(title, model: model)
    }
}

struct LandscapeCard: View {
    @Environment(AppModel.self) private var model
    let title: Title
    var width: CGFloat = 300
    var caption: String?

    var body: some View {
        Button { model.open(title) } label: {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkView(title: title, style: .landscape)
                    .frame(width: width, height: width * 9 / 16)
                    .clipShape(.rect(cornerRadius: Theme.cardRadius))
                    .hoverLift()
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: width, alignment: .leading)
                }
            }
        }
        .buttonStyle(.plain)
        .titleContextMenu(title, model: model)
    }
}

/// Netflix-style ranked tile with an oversized numeral behind the poster.
struct Top10Card: View {
    @Environment(AppModel.self) private var model
    let rank: Int
    let title: Title

    var body: some View {
        Button { model.open(title) } label: {
            HStack(alignment: .bottom, spacing: -28) {
                Text("\(rank)")
                    .font(.system(size: 190, weight: .black))
                    .fontWidth(.compressed)
                    .foregroundStyle(
                        LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.15)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .shadow(color: .black.opacity(0.6), radius: 6)
                    .frame(height: 210, alignment: .bottom)
                    .offset(y: 26)
                ArtworkView(title: title, style: .poster)
                    .frame(width: 140, height: 210)
                    .clipShape(.rect(cornerRadius: Theme.cardRadius))
                    .hoverLift()
            }
        }
        .buttonStyle(.plain)
        .titleContextMenu(title, model: model)
        .accessibilityLabel("Number \(rank), \(title.name)")
    }
}

struct ContinueWatchingCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var modelContext
    let title: Title
    let entry: WatchProgress
    var width: CGFloat = 320
    @State private var isHovered = false

    private var episode: Episode? {
        title.allEpisodes.first { $0.id == entry.playbackID }
    }

    var body: some View {
        Button {
            model.play(PlaybackItem(title: title, episode: episode), from: entry.position)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    ArtworkView(title: title, style: .landscape)
                    Image(systemName: "play.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 54, height: 54)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .opacity(isHovered ? 1 : 0)
                        .scaleEffect(isHovered ? 1 : 0.8)
                }
                .frame(width: width, height: width * 9 / 16)
                .overlay(alignment: .bottom) {
                    WatchProgressBar(fraction: entry.fraction)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
                .clipShape(.rect(cornerRadius: Theme.cardRadius))
                .hoverLift()

                VStack(alignment: .leading, spacing: 2) {
                    Text(episode.map { "\($0.code) · \($0.name)" } ?? title.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(entry.remainingDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(width: width, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(.snappy) { isHovered = hovering } }
        .contextMenu {
            Button("Resume", systemImage: "play.fill") {
                model.play(PlaybackItem(title: title, episode: episode), from: entry.position)
            }
            Button("Start Over", systemImage: "gobackward") {
                model.play(PlaybackItem(title: title, episode: episode))
            }
            Button("View Details", systemImage: "info.circle") { model.open(title) }
            Divider()
            Button("Remove from Continue Watching", systemImage: "xmark.circle", role: .destructive) {
                if let profile = model.profile {
                    withAnimation { WatchHistory.removeFromContinueWatching(title, profileID: profile.id, in: modelContext) }
                }
            }
        }
        .accessibilityLabel("Resume \(title.name), \(entry.remainingDescription)")
    }
}

struct GenreTile: View {
    let genre: Genre
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: genre.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: genre.systemImage)
                    .font(.system(size: 64, weight: .bold))
                    .foregroundStyle(.white.opacity(0.22))
                    .rotationEffect(.degrees(-12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .offset(x: 8, y: -4)
                Text(genre.displayName)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(14)
            }
            .frame(width: 200, height: 112)
            .clipShape(.rect(cornerRadius: Theme.cardRadius))
            .hoverLift()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Small pieces

struct WatchProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(Theme.accent)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityValue("\(Int(fraction * 100)) percent watched")
    }
}

/// Bright, high-contrast primary action (Play / Resume).
struct PlayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.black)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.white, in: .capsule)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .contentShape(.capsule)
    }
}

/// Score · year · rating · length · genres, with quality badges. Skips anything unknown.
struct MetadataLine: View {
    let title: Title
    var showsBadges = true

    var body: some View {
        HStack(spacing: 10) {
            if let score = title.criticScore, score >= 85 {
                Label("\(score)%", systemImage: "star.fill")
                    .foregroundStyle(Theme.gold)
            }
            if let year = title.yearText {
                Text(year)
            }
            if !title.displayRating.isEmpty {
                MaturityBadge(rating: title.displayRating)
            }
            if let length = title.lengthDescription {
                Text(length)
            }
            if !title.genreLine.isEmpty {
                Text(title.genreLine)
            }
            if showsBadges {
                ForEach(title.badges, id: \.self) { badge in
                    QualityBadgeView(badge: badge)
                }
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.white.opacity(0.85))
        .lineLimit(1)
    }
}

/// Scores from every source that rated the title (IMDb, Rotten Tomatoes, Metacritic, TMDB,
/// TVmaze), plus the viewer's own rating on the same 10-point scale.
struct RatingsRow: View {
    let ratings: [ExternalRating]
    var userScore: Double?
    /// When set, shows the viewer's rating chip, which opens the rating picker.
    var onRate: ((Double?) -> Void)?

    @State private var isRating = false

    var body: some View {
        HStack(spacing: 8) {
            if let onRate {
                Button { isRating = true } label: {
                    HStack(spacing: 6) {
                        Text("YOU")
                            .font(.caption2.weight(.heavy))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Theme.accent, in: .rect(cornerRadius: 4))
                        if let userScore {
                            Label(UserRating.display(userScore), systemImage: "star.fill")
                                .font(.subheadline.weight(.bold))
                                .monospacedDigit()
                        } else {
                            Label("Rate", systemImage: "star")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
                .help(userScore == nil ? "Rate this title" : "Change your rating")
                .accessibilityLabel(userScore.map { "Your rating: \(UserRating.display($0)) out of 10" } ?? "Rate this title")
                .popover(isPresented: $isRating, arrowEdge: .bottom) {
                    RatingPicker(score: userScore) { score in
                        onRate(score)
                        isRating = false
                    }
                }
            }
            ForEach(ratings, id: \.source) { rating in
                HStack(spacing: 6) {
                    Text(rating.source.shortName)
                        .font(.caption2.weight(.heavy))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(rating.source.brandColor, in: .rect(cornerRadius: 4))
                        .foregroundStyle(rating.source == .imdb ? .black : .white)
                    Text(rating.display)
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(rating.source.displayName) \(rating.display)")
            }
        }
    }
}

/// Ten stars with half-star precision: 0.5–10.
struct RatingPicker: View {
    let score: Double?
    let onCommit: (Double?) -> Void
    @State private var hovered: Double?

    private var shown: Double { hovered ?? score ?? 0 }

    var body: some View {
        VStack(spacing: 14) {
            Text("Your Rating")
                .font(.headline)
            HStack(spacing: 2) {
                ForEach(1...10, id: \.self) { star in
                    let value = Double(star)
                    Image(systemName: shown >= value ? "star.fill" : (shown >= value - 0.5 ? "star.leadinghalf.filled" : "star"))
                        .font(.title2)
                        .foregroundStyle(shown > 0 ? Theme.gold : .secondary)
                        .overlay {
                            HStack(spacing: 0) {
                                half(value - 0.5)
                                half(value)
                            }
                        }
                }
            }
            .onHover { if !$0 { hovered = nil } }
            Text(shown > 0 ? "\(UserRating.display(shown)) / 10" : "Not rated")
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(shown > 0 ? .primary : .secondary)
            HStack {
                Button("Clear Rating") { onCommit(nil) }
                    .disabled(score == nil)
                Spacer()
                Button("Done") { onCommit(score) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 320)
        .accessibilityElement(children: .contain)
        .accessibilityAdjustableAction { direction in
            let current = score ?? 0
            onCommit(direction == .increment ? min(current + 0.5, 10) : max(current - 0.5, 0.5))
        }
    }

    private func half(_ value: Double) -> some View {
        Color.clear
            .contentShape(.rect)
            .onHover { if $0 { hovered = value } }
            .onTapGesture { onCommit(value) }
            .accessibilityLabel("\(UserRating.display(value)) stars")
    }
}

extension RatingSource {
    var shortName: String {
        switch self {
        case .imdb: "IMDb"
        case .rottenTomatoes: "RT"
        case .metacritic: "MC"
        case .tmdb: "TMDB"
        case .tvmaze: "TVmaze"
        }
    }

    var brandColor: Color {
        switch self {
        case .imdb: Color(hex: 0xF5C518)
        case .rottenTomatoes: Color(hex: 0xFA320A)
        case .metacritic: Color(hex: 0x1A6E2E)
        case .tmdb: Color(hex: 0x01B4E4)
        case .tvmaze: Color(hex: 0x3C948B)
        }
    }
}

/// Flags titles that need attention in grids: unidentified, damaged, or in a format the engine can't play.
struct LibraryStatusBadge: View {
    let title: Title

    var body: some View {
        if !title.isPlayable {
            badge(title.playbackIssue?.label ?? "Can't Play", systemImage: "exclamationmark.triangle.fill", color: .orange)
                .help(title.playbackIssue?.message ?? "This file can't be played.")
        } else if title.needsMatch {
            badge("Needs Match", systemImage: "questionmark.circle.fill", color: Theme.accent)
                .help("No metadata source recognized this title. Right-click and choose Fix Match.")
        }
    }

    private func badge(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.9), in: .capsule)
            .foregroundStyle(.white)
    }
}

struct MaturityBadge: View {
    let rating: String

    var body: some View {
        Text(rating)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.6), lineWidth: 1))
            .accessibilityLabel("Rated \(rating)")
    }
}

struct QualityBadgeView: View {
    let badge: QualityBadge

    var body: some View {
        Text(badge.rawValue)
            .font(.caption.weight(.heavy))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.white.opacity(0.16), in: .rect(cornerRadius: 4))
    }
}
