//
//  CollectionsView.swift
//  Ultimate Theater
//
//  Movie collections (franchises), laid out like the Movies page: header, sort,
//  facet filters, poster grid, and the A–Z jump index.
//

import SwiftUI
import SwiftData

enum CollectionSort: String, CaseIterable, Identifiable {
    case alphabetical = "A–Z"
    case recentlyAdded = "Recently Added"
    case releaseDate = "Release Date"
    case size = "Most Movies"

    var id: String { rawValue }

    func apply(_ collections: [MovieCollection]) -> [MovieCollection] {
        switch self {
        case .alphabetical:
            collections.sorted { $0.sortName.localizedStandardCompare($1.sortName) == .orderedAscending }
        case .recentlyAdded:
            collections.sorted { $0.latestAddition > $1.latestAddition }
        case .releaseDate:
            collections.sorted { ($0.movies.first?.year ?? 0) > ($1.movies.first?.year ?? 0) }
        case .size:
            collections.sorted { $0.movies.count == $1.movies.count ? $0.sortName < $1.sortName : $0.movies.count > $1.movies.count }
        }
    }
}

struct CollectionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Query private var allRatings: [UserRating]

    @State private var filter = TitleFilter()
    @State private var sort: CollectionSort = .alphabetical
    @State private var topID: MovieCollection.ID?

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 230), spacing: 26, alignment: .top)]

    private var ratings: [String: Double] {
        let profileID = model.profile?.id
        return Dictionary(allRatings.filter { $0.profileID == profileID }.map { ($0.titleID, $0.score) },
                          uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        let collections = model.collections
        if collections.isEmpty {
            emptyState
        } else {
            content(collections)
        }
    }

    private func content(_ collections: [MovieCollection]) -> some View {
        let ratings = ratings
        let members = collections.flatMap(\.movies)
        // A collection is shown when any of its movies matches the filters.
        let results = sort.apply(collections.filter { collection in
            !filter.isActive || collection.movies.contains { filter.matches($0, ratings: ratings) }
        })
        let current: Character? = sort == .alphabetical
            ? (results.first { $0.id == topID } ?? results.first)?.indexCharacter
            : nil

        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .lastTextBaseline) {
                    PageHeader(title: "Collections",
                               subtitle: "\(results.count) collections · \(results.reduce(0) { $0 + $1.movies.count }) movies")
                    Picker("Sort", selection: $sort) {
                        ForEach(CollectionSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .padding(.trailing, pageMargin)
                }
                TitleFilterBar(titles: members, ratings: ratings, filter: $filter)
                    .padding(.horizontal, pageMargin)
            }
            .padding(.top, 28)
            .padding(.bottom, 12)

            HStack(spacing: 0) {
                ScrollView {
                    if results.isEmpty {
                        ContentUnavailableView {
                            Label("No Matches", systemImage: "line.3.horizontal.decrease.circle")
                        } description: {
                            Text("No collection has a movie matching every filter.")
                        } actions: {
                            Button("Clear Filters") { withAnimation { filter = TitleFilter() } }
                                .buttonStyle(.glass)
                        }
                        .padding(.top, 60)
                    } else {
                        LazyVGrid(columns: columns, spacing: 34) {
                            ForEach(results) { collection in
                                CollectionCard(collection: collection)
                                    .id(collection.id)
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.leading, pageMargin)
                        .padding(.trailing, 16)
                        .padding(.vertical, 16)
                        .animation(.smooth, value: results.map(\.id))
                    }
                }
                .scrollPosition(id: $topID, anchor: .top)
                // Fill the width so the jump bar stays at the right edge even with few items.
                .frame(maxWidth: .infinity, alignment: .leading)

                if !results.isEmpty {
                    AlphabetIndex(available: Set(results.map(\.indexCharacter)), current: current) { character in
                        jump(to: character, in: collections)
                    }
                    .frame(maxHeight: 640)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
                }
            }
        }
        .background { AppBackground() }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Collections Yet", systemImage: "square.stack.3d.up")
        } description: {
            Text("Movies that belong to a series, like The Matrix or Toy Story, are grouped here automatically. Collections come from TMDB, so add a TMDB key in Settings, then refresh your library's info.")
        } actions: {
            HStack {
                Button("Metadata Sources…") { openSettings() }
                    .buttonStyle(.glass)
                Button("Refresh All Info") { Task { await model.library.refreshMetadata(force: true) } }
                    .buttonStyle(.glassProminent)
                    .disabled(model.library.titles.isEmpty || model.library.isBusy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { AppBackground() }
    }

    private func jump(to character: Character, in collections: [MovieCollection]) {
        let needsResort = sort != .alphabetical
        if needsResort { sort = .alphabetical }
        let sorted = CollectionSort.alphabetical.apply(collections)
        let order = AlphabetIndex.characters
        guard let start = order.firstIndex(of: character) else { return }
        let target = order[start...].lazy.compactMap { letter in sorted.first { $0.indexCharacter == letter } }.first ?? sorted.last
        guard let target else { return }
        Task {
            if needsResort { try? await Task.sleep(for: .milliseconds(50)) }
            withAnimation(.smooth) { topID = target.id }
        }
    }
}

/// A blank slot for a film in the collection that isn't in the library.
private struct MissingMovieCard: View {
    let part: CollectionPart

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .fill(.white.opacity(0.03))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.cardRadius)
                        .strokeBorder(.white.opacity(0.18), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                }
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "film")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.25))
                        Text("Not in Library")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
                .aspectRatio(2 / 3, contentMode: .fit)
            VStack(alignment: .leading, spacing: 2) {
                Text(part.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(part.year.map(String.init) ?? "Upcoming")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(part.title), not in your library")
    }
}

/// A stacked poster for a collection, with its movie count.
private struct CollectionCard: View {
    @Environment(AppModel.self) private var model
    let collection: MovieCollection

    var body: some View {
        Button { model.open(collection.info) } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    // Two offset posters behind suggest a stack.
                    ForEach(Array(collection.movies.prefix(3).enumerated().reversed()), id: \.offset) { index, movie in
                        if index > 0 {
                            ArtworkView(title: movie, style: .poster)
                                .clipShape(.rect(cornerRadius: Theme.cardRadius))
                                .opacity(0.55)
                                .scaleEffect(1 - CGFloat(index) * 0.06)
                                .offset(y: -CGFloat(index) * 10)
                        }
                    }
                    front
                        .clipShape(.rect(cornerRadius: Theme.cardRadius))
                        .overlay(alignment: .bottomTrailing) {
                            Text(collection.totalCount > collection.movies.count
                                 ? "\(collection.movies.count)/\(collection.totalCount)" : "\(collection.movies.count)")
                                .font(.headline.weight(.heavy))
                                .monospacedDigit()
                                .padding(.horizontal, 8)
                                .frame(minWidth: 30, minHeight: 30)
                                .glassEffect(.regular, in: .capsule)
                                .padding(10)
                                .accessibilityLabel(collection.countDescription)
                        }
                        .hoverLift(scale: 1.04)
                }
                .aspectRatio(2 / 3, contentMode: .fit)
                .padding(.top, 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(collection.info.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Text([collection.countDescription, collection.years].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .help(collection.info.name)
    }

    @ViewBuilder
    private var front: some View {
        if let poster = collection.info.posterURL {
            ZStack {
                if let first = collection.movies.first { ArtworkView(title: first, style: .poster) }
                RemoteImage(url: poster, size: .poster)
            }
        } else if let first = collection.movies.first {
            ArtworkView(title: first, style: .poster)
        }
    }
}

/// One collection: backdrop header, play-in-order, and its movies by release date.
struct CollectionDetailView: View {
    @Environment(AppModel.self) private var model
    @Query private var allProgress: [WatchProgress]

    let collectionID: Int

    private var collection: MovieCollection? {
        model.collections.first { $0.id == collectionID }
    }

    /// The first movie this profile hasn't finished.
    private func nextUp(in collection: MovieCollection) -> Title? {
        let profileID = model.profile?.id
        return collection.movies.first { movie in
            !allProgress.contains { $0.profileID == profileID && $0.titleID == movie.id && $0.isFinished }
        } ?? collection.movies.first
    }

    var body: some View {
        if let collection {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    header(collection)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 210), spacing: 22, alignment: .top)], spacing: 30) {
                        ForEach(collection.entries) { entry in
                            switch entry {
                            case .owned(let movie): GridPosterCard(title: movie)
                            case .missing(let part): MissingMovieCard(part: part)
                            }
                        }
                    }
                    .padding(.horizontal, pageMargin)
                }
                .padding(.bottom, 60)
            }
            .ignoresSafeArea(edges: .top)
            .background { AppBackground() }
            .navigationTitle(collection.info.name)
        } else {
            ContentUnavailableView("Collection Unavailable", systemImage: "square.stack.3d.up",
                                   description: Text("None of this collection's movies are in your library anymore."))
        }
    }

    private func header(_ collection: MovieCollection) -> some View {
        ZStack(alignment: .bottomLeading) {
            ZStack {
                if let first = collection.movies.first {
                    ArtworkView(title: first, style: .backdrop)
                }
                if let backdrop = collection.info.backdropURL {
                    RemoteImage(url: backdrop, size: .backdrop)
                }
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.9), location: 0),
                    .init(color: .black.opacity(0.4), location: 0.5),
                    .init(color: .clear, location: 0.85),
                ], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, .clear, Theme.background], startPoint: .top, endPoint: .bottom)
            }
            .backgroundExtensionEffect()

            VStack(alignment: .leading, spacing: 14) {
                Text("COLLECTION")
                    .font(.caption.weight(.heavy))
                    .tracking(1.5)
                    .foregroundStyle(Theme.accent)
                Text(collection.info.name)
                    .font(.system(size: 54, weight: .black))
                    .fontWidth(.condensed)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                Text(["\(collection.countDescription) in your library", collection.years].compactMap { $0 }.joined(separator: " · "))
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.8))
                if let next = nextUp(in: collection) {
                    Button { model.playResuming(next) } label: {
                        Label(next.id == collection.movies.first?.id ? "Play from the Beginning" : "Continue with \(next.name)",
                              systemImage: "play.fill")
                    }
                    .buttonStyle(PlayButtonStyle())
                    .disabled(!next.isPlayable)
                    .padding(.top, 4)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, pageMargin)
            .padding(.bottom, 24)
        }
        .containerRelativeFrame(.vertical) { height, _ in max(height * 0.55, 420) }
        .clipped()
    }
}
