//
//  HomeView.swift
//  Ultimate Theater
//

import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.titles.isEmpty {
            WelcomeView(isLibraryEmpty: model.library.titles.isEmpty)
        } else {
            // My List's order comes from a query scoped to this profile; rebuilt when the profile changes.
            HomeShelves(profileID: model.profile?.id ?? "")
                .id(model.profile?.id)
        }
    }
}

/// What Home's rows are derived from. Each part is a cheap version number (or the My List
/// order), so comparing keys never walks the library.
private struct HomeRowsKey: Equatable {
    let catalogVersion: Int
    let historyVersion: Int
    let myList: [String]
}

/// Home's derived rows, worked out once per change of `HomeRowsKey` rather than every render.
private struct HomeRows {
    let key: HomeRowsKey
    let continueItems: [ContinueItem]
    let recentlyWatched: [Title]
    let myList: [Title]
    let topRated: [RankedTitle]
    let genres: [Genre]
    let genreRows: [GenreRow]
    /// Titles like the one most recently in progress.
    let becauseYouWatched: [Title]

    /// Titles shown in the Recently Watched row (See All opens the whole collection).
    static let recentlyWatchedLimit = 20

    @MainActor
    init(_ key: HomeRowsKey, model: AppModel) {
        self.key = key
        let titles = model.titles
        let byID = model.titleByID
        // Each title's latest entry decides; a finished latest entry drops the title from the row.
        var latest: [(titleID: String, entry: WatchProgress)] = []
        latest.reserveCapacity(model.watchProgressByTitle.count)
        for (titleID, entries) in model.watchProgressByTitle {
            if let entry = entries.max(by: { $0.lastWatched < $1.lastWatched }) { latest.append((titleID, entry)) }
        }
        continueItems = latest.sorted { $0.entry.lastWatched > $1.entry.lastWatched }
            .compactMap { item in
                guard !item.entry.isFinished, let title = byID[item.titleID] else { return nil }
                return ContinueItem(title: title, entry: item.entry)
            }
        // Same order as the Recently Watched collection: finished titles included, newest first.
        recentlyWatched = Array(SmartCollection.recentlyWatched.titles(in: model).prefix(Self.recentlyWatchedLimit))
        myList = key.myList.compactMap { byID[$0] }
        topRated = titles.filter { $0.criticScore != nil }
            .sorted { ($0.criticScore ?? 0) > ($1.criticScore ?? 0) }
            .prefix(10)
            .enumerated()
            .map { RankedTitle(rank: $0.offset + 1, title: $0.element) }
        // One pass over the library for every genre row and tile.
        var byGenre: [Genre: [Title]] = [:]
        for title in titles {
            for genre in Set(title.genres) { byGenre[genre, default: []].append(title) }
        }
        genres = Genre.allCases.filter { byGenre[$0] != nil }
        // Genres with enough titles to make a row, largest first.
        genreRows = genres.compactMap { genre in byGenre[genre].map { GenreRow(genre: genre, titles: $0) } }
            .filter { $0.titles.count >= 3 }
            .sorted { $0.titles.count > $1.titles.count }
        becauseYouWatched = continueItems.first.map { WatchHistory.similar(to: $0.title, in: titles) } ?? []
    }
}

/// Home's rows, from the model's cached catalog and watch history. They're rebuilt only when
/// the catalog, the watch history, or My List changes, not on every render (or every
/// progress autosave a live entry makes).
private struct HomeShelves: View {
    @Environment(AppModel.self) private var model
    /// This profile's My List, newest first.
    @Query private var myListEntries: [MyListEntry]
    @State private var cache: HomeRows?

    init(profileID: String) {
        _myListEntries = Query(filter: #Predicate<MyListEntry> { $0.profileID == profileID },
                               sort: \.addedAt, order: .reverse)
    }

    var body: some View {
        let key = HomeRowsKey(catalogVersion: model.catalogVersion, historyVersion: model.watchHistoryVersion,
                              myList: myListEntries.map(\.titleID))
        // Only a frame before onChange fills the cache works the rows out inline.
        let rows = cache.flatMap { $0.key == key ? $0 : nil } ?? HomeRows(key, model: model)
        let titles = model.titles

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 40) {
                HeroCarousel(titles: model.featured)
                    .padding(.bottom, -24)

                if !rows.continueItems.isEmpty {
                    Shelf(title: "Continue Watching", subtitle: "Pick up right where you left off", items: rows.continueItems) { item in
                        ContinueWatchingCard(title: item.title, entry: item.entry)
                    }
                    .captionBelowArtwork(44)
                }

                if !rows.recentlyWatched.isEmpty {
                    Shelf(title: "Recently Watched", items: rows.recentlyWatched,
                          seeAll: { model.open(SmartCollection.recentlyWatched) }) { title in
                        PosterCard(title: title)
                    }
                }

                posterShelf("Recently Added", Array(titles.prefix(12)), landscape: true,
                            seeAll: { model.section = .recentlyAdded })

                if rows.topRated.count >= 3 {
                    Shelf(title: "Top Rated in Your Library", items: rows.topRated, spacing: 8) { ranked in
                        Top10Card(rank: ranked.rank, title: ranked.title)
                    }
                }

                if !rows.myList.isEmpty {
                    Shelf(title: "My List", items: rows.myList, seeAll: { model.section = .myList }) { title in
                        PosterCard(title: title)
                    }
                }

                if let recent = rows.continueItems.first?.title {
                    posterShelf("Because You Watched \(recent.name)", rows.becauseYouWatched)
                }

                posterShelf("Movies", model.movies, seeAll: { model.section = .movies })
                posterShelf("TV Shows", model.shows, seeAll: { model.section = .shows })

                if rows.genres.count > 1 {
                    Shelf(title: "Browse by Genre", items: rows.genres) { genre in
                        GenreTile(genre: genre) { model.showGenre(genre) }
                    }
                }

                ForEach(rows.genreRows) { row in
                    posterShelf(row.genre.shelfTitle, row.titles, seeAll: { model.showGenre(row.genre) })
                }
            }
            .padding(.bottom, 60)
        }
        .ignoresSafeArea(edges: .top)
        .background { AppBackground() }
        .onChange(of: key, initial: true) { _, key in
            cache = HomeRows(key, model: model)
        }
    }

    @ViewBuilder
    private func posterShelf(_ title: LocalizedStringResource, _ titles: [Title],
                             landscape: Bool = false, seeAll: (() -> Void)? = nil) -> some View {
        if !titles.isEmpty {
            Shelf(title: title, items: titles, seeAll: seeAll) { item in
                if landscape {
                    LandscapeCard(title: item, caption: item.subtitleLine.isEmpty ? item.kind.displayName : item.subtitleLine)
                } else {
                    PosterCard(title: item)
                }
            }
            .captionBelowArtwork(landscape ? 24 : 0)
        }
    }
}

private struct GenreRow: Identifiable {
    let genre: Genre
    let titles: [Title]
    var id: Genre { genre }
}

private extension Genre {
    /// Localizable, so a String Catalog can translate the row names.
    var shelfTitle: LocalizedStringResource {
        switch self {
        case .action: "Action & Adventure"
        case .sciFi: "Mind-Bending Sci-Fi"
        case .drama: "Dramas"
        case .comedy: "Comedies"
        case .thriller: "Edge-of-Your-Seat Thrillers"
        case .mystery: "Mysteries"
        case .fantasy: "Fantasy Worlds"
        case .animation: "Animation"
        case .family: "For the Whole Family"
        case .documentary: "Real Stories"
        case .romance: "Romance"
        case .horror: "Horror"
        }
    }
}

/// First-run screen: how to add media and set up metadata sources.
private struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let isLibraryEmpty: Bool

    var body: some View {
        ZStack {
            Theme.background
            RadialGradient(colors: [Theme.accent.opacity(0.22), .clear], center: .top, startRadius: 0, endRadius: 650)

            VStack(spacing: 28) {
                Image(systemName: isLibraryEmpty ? "popcorn.fill" : "star.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(LinearGradient(colors: [Theme.accent, Color(hex: 0xFF8A3D)],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                VStack(spacing: 10) {
                    Text(isLibraryEmpty ? "Build Your Home Theater" : "Nothing Here for Kids Yet")
                        .font(.system(size: 40, weight: .bold))
                    Text(isLibraryEmpty
                         ? "Add your movies and TV shows. Ultimate Theater identifies each one and brings in posters, cast, ratings, and episode guides from TMDB, OMDb, TVmaze, and Wikipedia."
                         : "Kids profiles show titles rated G, PG, TV-Y, TV-Y7, TV-G, or TV-PG. Ratings appear once titles are identified.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 620)
                }

                if isLibraryEmpty {
                    HStack(spacing: 12) {
                        Button { model.addMedia() } label: {
                            Label("Add Movies & Shows…", systemImage: "plus")
                        }
                        .buttonStyle(PlayButtonStyle())
                        .keyboardShortcut(.defaultAction)

                        Button { openSettings() } label: {
                            Label("Metadata Sources…", systemImage: "gearshape")
                                .font(.headline)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.theaterGlass)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        tip("folder.fill", "Choose a folder to add everything inside it. Ultimate Theater can rescan it for new videos later.")
                        tip("arrow.down.doc.fill", "Or drag files and folders anywhere into this window.")
                        tip("textformat", "Name movies like “Heat (1995).mp4” and episodes like “Severance S01E02.mp4” for the best matches.")
                        tip("key.fill", "TVmaze and Wikipedia work right away. Add free TMDB and OMDb keys in Settings for the richest info.")
                    }
                    .padding(20)
                    .frame(maxWidth: 620, alignment: .leading)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
                }
            }
            .padding(40)
        }
        .ignoresSafeArea(edges: .top)
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Theme.accent)
        }
        .font(.callout)
    }
}

private struct ContinueItem: Identifiable {
    let title: Title
    let entry: WatchProgress
    var id: String { title.id }
}

private struct RankedTitle: Identifiable {
    let rank: Int
    let title: Title
    var id: String { title.id }
}
