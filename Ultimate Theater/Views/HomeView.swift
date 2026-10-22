//
//  HomeView.swift
//  Ultimate Theater
//

import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \WatchProgress.lastWatched, order: .reverse) private var allProgress: [WatchProgress]
    @Query(sort: \MyListEntry.addedAt, order: .reverse) private var allMyList: [MyListEntry]

    private var profileID: String { model.profile?.id ?? "" }

    private var continueWatching: [ContinueItem] {
        WatchHistory.continueWatching(allProgress.filter { $0.profileID == profileID }, titles: model.titles)
            .map { ContinueItem(title: $0.title, entry: $0.entry) }
    }

    private var myList: [Title] {
        allMyList.filter { $0.profileID == profileID }
            .compactMap { entry in model.titles.first { $0.id == entry.titleID } }
    }

    /// Highest-rated titles, ranked by the best available critic score.
    private var topRated: [RankedTitle] {
        model.titles.filter { $0.criticScore != nil }
            .sorted { ($0.criticScore ?? 0) > ($1.criticScore ?? 0) }
            .prefix(10)
            .enumerated()
            .map { RankedTitle(rank: $0.offset + 1, title: $0.element) }
    }

    /// Genres with enough titles to make a row, largest first.
    private var genreRows: [(genre: Genre, titles: [Title])] {
        Genre.allCases
            .map { genre in (genre, model.titles.filter { $0.genres.contains(genre) }) }
            .filter { $0.1.count >= 3 }
            .sorted { $0.1.count > $1.1.count }
    }

    var body: some View {
        if model.titles.isEmpty {
            WelcomeView(isLibraryEmpty: model.library.titles.isEmpty)
        } else {
            shelves
        }
    }

    private var shelves: some View {
        let continueItems = continueWatching
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 40) {
                HeroCarousel(titles: model.featured)
                    .padding(.bottom, -24)

                if !continueItems.isEmpty {
                    Shelf(title: "Continue Watching", subtitle: "Pick up right where you left off", items: continueItems) { item in
                        ContinueWatchingCard(title: item.title, entry: item.entry)
                    }
                }

                posterShelf("Recently Added", Array(model.titles.prefix(12)), landscape: true,
                            seeAll: { model.section = .recentlyAdded })

                if topRated.count >= 3 {
                    Shelf(title: "Top Rated in Your Library", items: topRated, spacing: 8) { ranked in
                        Top10Card(rank: ranked.rank, title: ranked.title)
                    }
                }

                if !myList.isEmpty {
                    Shelf(title: "My List", items: myList, seeAll: { model.section = .myList }) { title in
                        PosterCard(title: title)
                    }
                }

                if let recent = continueItems.first?.title {
                    posterShelf("Because You Watched \(recent.name)", WatchHistory.similar(to: recent, in: model.titles))
                }

                posterShelf("Movies", model.movies, seeAll: { model.section = .movies })
                posterShelf("TV Shows", model.shows, seeAll: { model.section = .shows })

                let genres = Genre.allCases.filter { genre in model.titles.contains { $0.genres.contains(genre) } }
                if genres.count > 1 {
                    Shelf(title: "Browse by Genre", items: genres) { genre in
                        GenreTile(genre: genre) { model.showGenre(genre) }
                    }
                }

                ForEach(genreRows, id: \.genre) { row in
                    posterShelf(row.genre.shelfTitle, row.titles, seeAll: { model.showGenre(row.genre) })
                }
            }
            .padding(.bottom, 60)
        }
        .ignoresSafeArea(edges: .top)
        .background { AppBackground() }
    }

    @ViewBuilder
    private func posterShelf(_ title: String, subtitle: String? = nil, _ titles: [Title],
                             landscape: Bool = false, seeAll: (() -> Void)? = nil) -> some View {
        if !titles.isEmpty {
            Shelf(title: title, subtitle: subtitle, items: titles, seeAll: seeAll) { item in
                if landscape {
                    LandscapeCard(title: item, caption: item.subtitleLine.isEmpty ? item.kind.displayName : item.subtitleLine)
                } else {
                    PosterCard(title: item)
                }
            }
        }
    }
}

private extension Genre {
    var shelfTitle: String {
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
                        .buttonStyle(.glass)
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
