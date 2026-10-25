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
            if model.isWatched(title) {
                Button("Mark as Unwatched", systemImage: "eye.slash") { model.setWatched(false, title) }
            } else {
                Button("Mark as Watched", systemImage: "checkmark.circle") { model.setWatched(true, title) }
            }
            if model.canManageLibrary {
                Divider()
                Button("Fix Match…", systemImage: "wand.and.stars") { model.fixMatch(title) }
                Button("Edit Info…", systemImage: "pencil") { model.editInfo(title) }
                Button("Show in Finder", systemImage: "folder") {
                    model.library.revealInFinder(title.allEpisodes.first?.id ?? title.id)
                }
            }
        }
    }
}

// MARK: - Cards

/// The watched check on a title's artwork. Watched titles always show it; on hover it becomes
/// a Mark Watched / Mark Unwatched button. Sits outside the card's own button so clicking it
/// never opens the title.
struct WatchedToggle: View {
    @Environment(AppModel.self) private var model
    let title: Title
    var episode: Episode?
    let isHovered: Bool

    var body: some View {
        let isWatched = episode.map { model.isWatched($0, of: title) } ?? model.isWatched(title)
        if isHovered || isWatched {
            Button {
                if let episode {
                    model.setWatched(!isWatched, episodes: [episode], of: title)
                } else {
                    model.setWatched(!isWatched, title)
                }
            } label: {
                Image(systemName: isWatched && isHovered ? "eye.slash" : "checkmark")
                    .font(.caption.weight(.bold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 18, height: 18)
            }
            // At rest (a watched badge on every watched poster in a grid) it's a plain accent disc;
            // interactive glass is only created while the pointer is over the card.
            .buttonStyle(TheaterGlassButtonStyle(isCircular: true, tint: isWatched ? Theme.accent : nil, usesGlass: isHovered))
            .help(isWatched ? "Watched · Click to mark as unwatched" : "Mark as watched")
            .accessibilityLabel(isWatched ? "Mark \(title.name) as unwatched" : "Mark \(title.name) as watched")
            .padding(8)
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }
}

struct PosterCard: View {
    @Environment(AppModel.self) private var model
    let title: Title
    var width: CGFloat = 176
    @State private var isHovered = false

    var body: some View {
        Button { model.open(title) } label: {
            ArtworkView(title: title, style: .poster)
                .frame(width: width, height: width * 1.5)
                .overlay(alignment: .bottom) { PosterProgress(title: title) }
                .clipShape(.rect(cornerRadius: Theme.cardRadius))
                .hoverLift()
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) { WatchedToggle(title: title, isHovered: isHovered) }
        .onHover { hovering in withAnimation(.snappy) { isHovered = hovering } }
        .titleContextMenu(title, model: model)
        .help([title.name, title.subtitleLine].filter { !$0.isEmpty }.joined(separator: " · "))
    }
}

/// Poster that fills its grid cell, used in browse grids: the content rating and the
/// viewer's own rating under the title, a progress bar for an unfinished movie, and a
/// badge once it's been watched.
struct GridPosterCard: View {
    @Environment(AppModel.self) private var model
    let title: Title
    var myRating: Double?
    @State private var isHovered = false

    var body: some View {
        Button { model.open(title) } label: {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkView(title: title, style: .poster)
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .overlay(alignment: .topLeading) { LibraryStatusBadge(title: title).padding(8) }
                    .overlay(alignment: .bottom) { PosterProgress(title: title) }
                    .clipShape(.rect(cornerRadius: Theme.cardRadius))
                    .hoverLift(scale: 1.04)
                    .overlay(alignment: .topTrailing) { WatchedToggle(title: title, isHovered: isHovered) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        let rating = title.displayRating
                        if !rating.isEmpty {
                            Text(rating)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary, lineWidth: 1))
                                .foregroundStyle(.secondary)
                        }
                        if let myRating {
                            Label(myRating.formatted(.number.precision(.fractionLength(0...1))), systemImage: "star.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.gold)
                                .labelStyle(.titleAndIcon)
                                .help("Your rating")
                        }
                        Text(title.yearText ?? title.kind.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(.snappy) { isHovered = hovering } }
        .titleContextMenu(title, model: model)
    }
}

/// A progress bar along the bottom of a movie's artwork while it's partly watched.
struct PosterProgress: View {
    @Environment(AppModel.self) private var model
    let title: Title

    var body: some View {
        if let progress = model.partialProgress(title) {
            WatchProgressBar(fraction: progress)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .accessibilityLabel("\(Int(progress * 100))% watched")
        }
    }
}

struct LandscapeCard: View {
    @Environment(AppModel.self) private var model
    let title: Title
    var width: CGFloat = 300
    var caption: String?
    @State private var isHovered = false

    var body: some View {
        Button { model.open(title) } label: {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkView(title: title, style: .landscape)
                    .frame(width: width, height: width * 9 / 16)
                    .overlay(alignment: .bottom) { PosterProgress(title: title) }
                    .clipShape(.rect(cornerRadius: Theme.cardRadius))
                    .hoverLift()
                    .overlay(alignment: .topTrailing) { WatchedToggle(title: title, isHovered: isHovered) }
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
        .onHover { hovering in withAnimation(.snappy) { isHovered = hovering } }
        .titleContextMenu(title, model: model)
    }
}

/// Netflix-style ranked tile with an oversized numeral behind the poster.
struct Top10Card: View {
    @Environment(AppModel.self) private var model
    let rank: Int
    let title: Title
    @State private var isHovered = false

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
                    .overlay(alignment: .bottom) { PosterProgress(title: title) }
                    .clipShape(.rect(cornerRadius: Theme.cardRadius))
                    .hoverLift()
                    .overlay(alignment: .topTrailing) { WatchedToggle(title: title, isHovered: isHovered) }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(.snappy) { isHovered = hovering } }
        .titleContextMenu(title, model: model)
        .accessibilityLabel("Number \(rank), \(title.name)")
    }
}

struct ContinueWatchingCard: View {
    @Environment(AppModel.self) private var model
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
                    // Only built while hovered, so a row of cards doesn't keep idle glass around.
                    if isHovered {
                        Image(systemName: "play.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 54, height: 54)
                            .glassEffect(.regular.interactive(), in: .circle)
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: width, height: width * 9 / 16)
                .overlay(alignment: .bottom) {
                    WatchProgressBar(fraction: entry.fraction)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
                .clipShape(.rect(cornerRadius: Theme.cardRadius))
                .hoverLift()
                .overlay(alignment: .topTrailing) { WatchedToggle(title: title, episode: episode, isHovered: isHovered) }

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
            if let episode {
                Button("Mark Episode as Watched", systemImage: "checkmark.circle") {
                    model.setWatched(true, episodes: [episode], of: title)
                }
            }
            Button(title.kind == .series ? "Mark Series as Watched" : "Mark as Watched", systemImage: "checkmark.circle.fill") {
                model.setWatched(true, title)
            }
            Button("Remove from Continue Watching", systemImage: "xmark.circle", role: .destructive) {
                model.removeFromContinueWatching(title)
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

/// Liquid Glass buttons whose labels stay legible on any art. The system glass style lets the
/// label take on the colors behind it and fades it when the window isn't key, which made button
/// text vanish over bright backdrops; this keeps a white label over a faint dark base inside the glass.
struct TheaterGlassButtonStyle: ButtonStyle {
    var isCircular = false
    /// Colors the base under the label instead of the default faint black, e.g. the accent for "on" states.
    var tint: Color?
    /// Off for buttons that sit on a surface that's already glass, so glass isn't stacked on glass.
    var usesGlass = true
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let shape = isCircular ? AnyShape(.circle) : AnyShape(.capsule)
        let small = controlSize == .small || controlSize == .mini
        configuration.label
            .foregroundStyle(configuration.role == .destructive ? AnyShapeStyle(Color(hex: 0xFF6B6B)) : AnyShapeStyle(.white))
            .padding(.horizontal, isCircular ? (small ? 3 : 6) : (small ? 8 : 12))
            .padding(.vertical, isCircular ? (small ? 3 : 6) : (small ? 3 : 6))
            .background((tint ?? .black).opacity(tint == nil ? (configuration.isPressed ? 0.5 : 0.35) : (configuration.isPressed ? 0.95 : 0.8)), in: shape)
            .glassEffect(usesGlass ? .regular.interactive() : .identity, in: shape)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == TheaterGlassButtonStyle {
    /// Capsule-shaped glass button with an always-legible label.
    static var theaterGlass: TheaterGlassButtonStyle { TheaterGlassButtonStyle() }
    /// Round glass button for icons, with an always-legible symbol.
    static var theaterGlassCircle: TheaterGlassButtonStyle { TheaterGlassButtonStyle(isCircular: true) }
    /// The same legible capsule without its own glass, for buttons inside a glass panel or capsule.
    static var theaterPlain: TheaterGlassButtonStyle { TheaterGlassButtonStyle(usesGlass: false) }
    /// Round variant of `theaterPlain`.
    static var theaterPlainCircle: TheaterGlassButtonStyle { TheaterGlassButtonStyle(isCircular: true, usesGlass: false) }
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
