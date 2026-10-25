//
//  SmartCollections.swift
//  Ultimate Theater
//
//  Collections the app builds on its own from the library and this profile's watch
//  history: Unwatched, In Progress, Recently Watched, Highly Rated, and one per decade.
//

import SwiftUI
import SwiftData

enum SmartCollection: Hashable, Identifiable {
    case unwatched
    case inProgress
    case recentlyWatched
    case highlyRated
    case decade(Int)

    var id: String {
        switch self {
        case .unwatched: "unwatched"
        case .inProgress: "in-progress"
        case .recentlyWatched: "recently-watched"
        case .highlyRated: "highly-rated"
        case .decade(let start): "decade-\(start)"
        }
    }

    /// Localizable, so a String Catalog can translate it.
    var name: LocalizedStringResource {
        switch self {
        case .unwatched: "Unwatched"
        case .inProgress: "In Progress"
        case .recentlyWatched: "Recently Watched"
        case .highlyRated: "Highly Rated"
        case .decade(let start): "The \(String(start))s"
        }
    }

    var symbol: String {
        switch self {
        case .unwatched: "eye.slash"
        case .inProgress: "play.circle"
        case .recentlyWatched: "clock.arrow.circlepath"
        case .highlyRated: "star.fill"
        case .decade: "calendar"
        }
    }

    var subtitle: LocalizedStringResource {
        switch self {
        case .unwatched: "Movies and shows you haven't started"
        case .inProgress: "Started but not finished"
        case .recentlyWatched: "What you've watched lately, newest first"
        case .highlyRated: "Critics' favorites in your library"
        case .decade(let start): "Released \(String(start))–\(String(start + 9))"
        }
    }

    /// Two-color wash for the tile, so the row reads at a glance.
    var colors: [Color] {
        switch self {
        case .unwatched: [Color(hex: 0x3B5BFF), Color(hex: 0x1B1F4A)]
        case .inProgress: [Theme.accent, Color(hex: 0x4A1020)]
        case .recentlyWatched: [Color(hex: 0x1FB89A), Color(hex: 0x0E3A33)]
        case .highlyRated: [Theme.gold, Color(hex: 0x4A3508)]
        case .decade: [Color(hex: 0x8A4DFF), Color(hex: 0x24134A)]
        }
    }

    /// Whether the grid keeps this collection's own order (most recent first) rather than sorting.
    var isOrdered: Bool { self == .recentlyWatched }

    /// The collection's titles for the active profile, from the titles that profile may see.
    @MainActor
    func titles(in model: AppModel) -> [Title] {
        let history = model.watchProgressByTitle
        switch self {
        case .unwatched:
            return model.titles.filter { history[$0.id]?.isEmpty ?? true }
        case .inProgress:
            return model.titles.filter { title in
                guard let entries = history[title.id], !entries.isEmpty else { return false }
                return !WatchHistory.isWatched(title, in: entries)
                    && entries.contains { $0.position > 10 || $0.isFinished }
            }
        case .recentlyWatched:
            let byID = Dictionary(model.titles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return history
                .compactMap { id, entries in entries.map(\.lastWatched).max().map { (id, $0) } }
                .sorted { $0.1 > $1.1 }
                .prefix(60)
                .compactMap { byID[$0.0] }
        case .highlyRated:
            return model.titles.filter { ($0.criticScore ?? 0) >= 80 }
        case .decade(let start):
            return model.titles.filter { ($0.year ?? 0) >= start && ($0.year ?? 0) < start + 10 }
        }
    }

    /// The collections worth showing right now: none that are empty, and only decades with a few titles.
    @MainActor
    static func available(in model: AppModel) -> [SmartCollection] {
        let fixed: [SmartCollection] = [.inProgress, .recentlyWatched, .unwatched, .highlyRated]
        let decades = Dictionary(grouping: model.titles.compactMap(\.year).filter { $0 > 1800 }) { $0 / 10 * 10 }
            .filter { $0.value.count >= 3 }
            .keys.sorted(by: >)
            .map(SmartCollection.decade)
        return (fixed + decades).filter { !$0.titles(in: model).isEmpty }
    }
}

/// A horizontal row of smart collection tiles, for the top of the Collections page.
struct SmartCollectionsRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let collections = SmartCollection.available(in: model)
        if !collections.isEmpty {
            Shelf(title: "Made for You", subtitle: "Collections built from your library and watch history",
                  items: collections) { collection in
                SmartCollectionTile(collection: collection)
            }
        }
    }
}

struct SmartCollectionTile: View {
    @Environment(AppModel.self) private var model
    let collection: SmartCollection

    var body: some View {
        let titles = collection.titles(in: model)
        Button { model.open(collection) } label: {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: collection.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                // A fan of the first few posters along the right edge.
                HStack(spacing: -46) {
                    ForEach(Array(titles.prefix(3).enumerated()), id: \.element.id) { index, title in
                        ArtworkView(title: title, style: .poster)
                            .frame(width: 70, height: 105)
                            .clipShape(.rect(cornerRadius: 8))
                            .rotationEffect(.degrees(Double(index - 1) * 8))
                            .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 22)
                .offset(y: 18)

                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: collection.symbol)
                        .font(.title3.weight(.semibold))
                    Text(collection.name)
                        .font(.title3.weight(.bold))
                        .lineLimit(1)
                    Text("^[\(titles.count) title](inflect: true)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 4)
                .padding(16)
            }
            .frame(width: 280, height: 150)
            .clipShape(.rect(cornerRadius: Theme.cardRadius))
            .hoverLift()
        }
        .buttonStyle(.plain)
        .help(Text(collection.subtitle))
        .accessibilityLabel(Text("\(Text(collection.name)), ^[\(titles.count) title](inflect: true)"))
    }
}

/// One smart collection's titles: the usual filterable grid, or for Recently Watched a grid
/// kept in the order things were watched.
struct SmartCollectionView: View {
    @Environment(AppModel.self) private var model
    let collection: SmartCollection

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 210), spacing: 22, alignment: .top)]

    var body: some View {
        let titles = collection.titles(in: model)
        if collection.isOrdered {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    PageHeader(title: collection.name, subtitle: collection.subtitle)
                    if titles.isEmpty {
                        ContentUnavailableView {
                            Label { Text(collection.name) } icon: { Image(systemName: collection.symbol) }
                        } description: {
                            Text("Nothing here yet.")
                        }
                            .containerRelativeFrame([.horizontal, .vertical])
                    } else {
                        LazyVGrid(columns: columns, spacing: 30) {
                            ForEach(titles) { GridPosterCard(title: $0) }
                        }
                        .padding(.horizontal, pageMargin)
                    }
                }
                .padding(.vertical, 28)
            }
            .background { AppBackground() }
        } else {
            FilterableTitleGrid(heading: collection.name, titles: titles, profileID: model.profile?.id,
                                sort: collection == .unwatched ? .recentlyAdded : .alphabetical)
                .id(GridIdentity(section: collection.id, profileID: model.profile?.id))
        }
    }
}
