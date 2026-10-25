//
//  BrowseViews.swift
//  Ultimate Theater
//

import SwiftUI
import SwiftData

private let posterGrid = [GridItem(.adaptive(minimum: 160, maximum: 210), spacing: 22, alignment: .top)]

enum BrowseSort: String, CaseIterable, Identifiable {
    case recentlyAdded = "Recently Added"
    case alphabetical = "A–Z"
    case newest = "Release Date"
    case rating = "Top Rated"
    case myRating = "My Rating"

    var id: String { rawValue }

    /// The direction each order starts in: A–Z ascending, everything else newest/highest first.
    var defaultAscending: Bool { self == .alphabetical }

    /// Labels for the two directions, in this order's terms.
    var directionLabels: (ascending: String, descending: String) {
        switch self {
        case .alphabetical: ("A to Z", "Z to A")
        case .newest: ("Oldest First", "Newest First")
        case .recentlyAdded: ("Oldest Added First", "Newest Added First")
        case .rating, .myRating: ("Lowest First", "Highest First")
        }
    }

    /// `ratings` (title ID → the viewer's score) is used by the My Rating order. With no
    /// direction given, each order uses its default.
    func apply(_ titles: [Title], ratings: [String: Double] = [:], ascending: Bool? = nil) -> [Title] {
        let sorted: [Title] = switch self {
        case .myRating: titles.sorted { (ratings[$0.id] ?? -1) > (ratings[$1.id] ?? -1) }
        case .recentlyAdded: titles.sorted { $0.dateAdded > $1.dateAdded }
        case .alphabetical: titles.sorted { $0.sortName.localizedStandardCompare($1.sortName) == .orderedAscending }
        case .newest: titles.sorted { a, b in
            (a.year ?? 0) != (b.year ?? 0) ? (a.year ?? 0) > (b.year ?? 0)
                : a.sortName.localizedStandardCompare(b.sortName) == .orderedAscending
        }
        case .rating: titles.sorted { ($0.criticScore ?? -1) > ($1.criticScore ?? -1) }
        }
        guard let ascending, ascending != defaultAscending else { return sorted }
        return sorted.reversed()
    }
}

// MARK: - Movies / TV Shows

struct BrowseView: View {
    @Environment(AppModel.self) private var model
    let kind: TitleKind

    private var source: [Title] { kind == .movie ? model.movies : model.shows }

    var body: some View {
        if source.isEmpty {
            ContentUnavailableView {
                Label(kind == .movie ? "No Movies Yet" : "No TV Shows Yet", systemImage: kind == .movie ? "film" : "tv")
            } description: {
                Text(kind == .movie
                     ? "Add movie files or a folder of movies to see them here."
                     : "Add episode files named like “Show S01E01.mp4” or organized in Season folders.")
            } actions: {
                if model.canManageLibrary {
                    Button(kind == .movie ? "Add Movies…" : "Add TV Shows…") { model.addMedia() }
                        .buttonStyle(.glassProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { AppBackground() }
        } else {
            FilterableTitleGrid(heading: kind == .movie ? "Movies" : "TV Shows", titles: source,
                                profileID: model.profile?.id,
                                addLabel: kind == .movie ? "Add Movies" : "Add TV Shows")
                // Fresh filters per section, and a ratings query per profile.
                .id(GridIdentity(section: kind.rawValue, profileID: model.profile?.id))
        }
    }
}

/// Identity for a filterable grid: a fresh one (filters, ratings query) per section and profile.
struct GridIdentity: Hashable {
    let section: String
    let profileID: String?
}

// MARK: - Recently Added

struct RecentlyAddedView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case added = "Recently Added"
        case released = "Newest Releases"
        case rated = "Top Rated"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @State private var tab: Tab = .added

    private var titles: [Title] {
        switch tab {
        case .added: BrowseSort.recentlyAdded.apply(model.titles)
        case .released: BrowseSort.newest.apply(model.titles.filter { $0.year != nil })
        case .rated: BrowseSort.rating.apply(model.titles.filter { $0.criticScore != nil })
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "Recently Added", subtitle: "The newest additions to your library")
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.horizontal, pageMargin)

                if titles.isEmpty {
                    ContentUnavailableView("Nothing to Show", systemImage: "clock",
                                           description: Text(tab == .rated
                                                ? "Ratings appear after titles are identified by OMDb, TMDB, or TVmaze."
                                                : "Add movies and shows to fill this page."))
                        // Centered in the space below the header.
                        .frame(maxWidth: .infinity)
                        .containerRelativeFrame(.vertical) { height, _ in height * 0.75 }
                } else {
                    LazyVStack(spacing: 28) {
                        ForEach(Array(titles.enumerated()), id: \.element.id) { offset, title in
                            TitleRow(title: title, rank: tab == .rated ? offset + 1 : nil, tab: tab)
                        }
                    }
                    .padding(.horizontal, pageMargin)
                }
            }
            .padding(.vertical, 28)
        }
        .background { AppBackground() }
    }
}

private struct TitleRow: View {
    @Environment(AppModel.self) private var model
    let title: Title
    let rank: Int?
    let tab: RecentlyAddedView.Tab

    /// Shown in capitals via `.textCase`, so translations keep their own casing rules.
    private var eyebrow: Text {
        switch tab {
        case .added:
            let days = Calendar.current.dateComponents([.day], from: title.dateAdded, to: .now).day ?? 0
            return switch days {
            case 0: Text("Added today")
            case 1: Text("Added yesterday")
            default: Text("Added ^[\(days) day](inflect: true) ago")
            }
        case .released:
            return title.yearText.map { Text("Released \($0)") } ?? Text(verbatim: "")
        case .rated:
            return title.criticScore.map { Text(verbatim: "\($0)% · \(title.ratings.first?.source.displayName ?? "")") }
                ?? Text(verbatim: "")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            if let rank {
                Text("\(rank)")
                    .font(.system(size: 56, weight: .black))
                    .fontWidth(.compressed)
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(width: 48, alignment: .trailing)
            }
            Button { model.open(title) } label: {
                ArtworkView(title: title, style: .landscape)
                    .frame(width: 380, height: 214)
                    .clipShape(.rect(cornerRadius: Theme.cardRadius))
                    .hoverLift(scale: 1.03)
            }
            .buttonStyle(.plain)
            .titleContextMenu(title, model: model)

            VStack(alignment: .leading, spacing: 10) {
                eyebrow
                    .textCase(.uppercase)
                    .font(.caption.weight(.heavy))
                    .tracking(1.2)
                    .foregroundStyle(Theme.accent)
                Text(title.name)
                    .font(.title.weight(.bold))
                MetadataLine(title: title, showsBadges: false)
                if !title.synopsis.isEmpty {
                    Text(title.synopsis)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .frame(maxWidth: 560, alignment: .leading)
                }
                HStack(spacing: 10) {
                    Button { model.playResuming(title) } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(PlayButtonStyle())
                    .disabled(!title.isPlayable)
                    let isInMyList = model.isInMyList(title)
                    Button {
                        model.toggleMyList(title)
                    } label: {
                        Label(isInMyList ? "In My List" : "My List", systemImage: isInMyList ? "checkmark" : "plus")
                            .font(.headline)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.theaterGlass)
                }
                .padding(.top, 4)
            }
            .padding(.top, 6)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - My List

struct MyListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        MyListGrid(profileID: model.profile?.id ?? "")
            .id(model.profile?.id)
    }
}

/// The saved titles, newest first, from a query scoped to one profile.
private struct MyListGrid: View {
    @Environment(AppModel.self) private var model
    @Query private var entries: [MyListEntry]

    init(profileID: String) {
        _entries = Query(filter: #Predicate<MyListEntry> { $0.profileID == profileID },
                         sort: \.addedAt, order: .reverse)
    }

    var body: some View {
        let byID = model.titleByID
        let titles = entries.compactMap { byID[$0.titleID] }
        Group {
            if titles.isEmpty {
                ContentUnavailableView {
                    Label("Your List Is Empty", systemImage: "plus.rectangle.on.rectangle")
                } description: {
                    Text("Save movies and shows you want to watch next. Use the + button on any title, or right-click a poster.")
                } actions: {
                    Button("Browse Home") { model.section = .home }
                        .buttonStyle(.glassProminent)
                        .tint(Theme.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        PageHeader(title: "My List", subtitle: "\(titles.count) saved")
                        LazyVGrid(columns: posterGrid, spacing: 30) {
                            ForEach(titles) { title in
                                GridPosterCard(title: title)
                            }
                        }
                        .padding(.horizontal, pageMargin)
                    }
                    .padding(.vertical, 28)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { AppBackground() }
    }
}

// MARK: - Search

struct SearchView: View {
    @Environment(AppModel.self) private var model

    private let genreGrid = [GridItem(.adaptive(minimum: 200, maximum: 220), spacing: 18)]

    var body: some View {
        if model.searchText.isEmpty, let genre = model.selectedGenre {
            genreHub(genre)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if !model.searchText.isEmpty {
                        results
                    } else {
                        landing
                    }
                }
                .padding(.vertical, 28)
            }
            .background { AppBackground() }
        }
    }

    @ViewBuilder
    private var results: some View {
        let matches = model.search(model.titles, for: model.searchText)
        if matches.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.vertical) { height, _ in height * 0.75 }
        } else {
            PageHeader(title: Text("Results for “\(model.searchText)”"),
                       subtitle: Text("^[\(matches.count) title](inflect: true)"))
            LazyVGrid(columns: posterGrid, spacing: 30) {
                ForEach(matches) { GridPosterCard(title: $0) }
            }
            .padding(.horizontal, pageMargin)
        }
    }

    /// The whole library, pre-filtered to one genre; the filter bar can refine or change it.
    private func genreHub(_ genre: Genre) -> some View {
        var filter = TitleFilter()
        filter[.genre] = [genre.displayName]
        return FilterableTitleGrid(heading: "Browse", titles: model.titles, profileID: model.profile?.id,
                                   filter: filter, sort: .alphabetical)
            .id(GridIdentity(section: genre.rawValue, profileID: model.profile?.id))
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        withAnimation(.snappy) { model.selectedGenre = nil }
                    } label: {
                        Label("All Genres", systemImage: "chevron.left")
                    }
                    .help("Back to all genres")
                    .accessibilityLabel("All Genres")
                }
            }
    }

    @ViewBuilder
    private var landing: some View {
        PageHeader(title: "Search", subtitle: "Find movies, shows, actors, and directors. Press ⌘F anytime.")
        Text("Browse by Genre")
            .font(.title2.weight(.bold))
            .padding(.horizontal, pageMargin)
        LazyVGrid(columns: genreGrid, alignment: .leading, spacing: 18) {
            ForEach(Genre.allCases.filter { g in model.titles.contains { $0.genres.contains(g) } }) { genre in
                GenreTile(genre: genre) { withAnimation(.snappy) { model.selectedGenre = genre } }
            }
        }
        .padding(.horizontal, pageMargin)

        if !model.titles.isEmpty {
            Shelf(title: "Recently Added", items: Array(model.titles.prefix(12))) {
                PosterCard(title: $0)
            }
        }
    }
}
