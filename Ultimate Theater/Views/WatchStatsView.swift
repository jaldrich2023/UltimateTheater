//
//  WatchStatsView.swift
//  Ultimate Theater
//
//  Each profile's own watch statistics: time watched, what's been finished, weekly
//  activity, favorite genres, and most-watched shows. The administrator can look at
//  any profile; everyone else sees only their own.
//

import SwiftUI
import SwiftData
import Charts

struct WatchStatsView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedProfileID: String?

    private var profileID: String? { selectedProfileID ?? model.profile?.id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                // Its query is scoped to the profile being looked at.
                WatchStatsSections(profileID: profileID ?? "", profileName: profileName,
                                   canContinue: profileID != nil && profileID == model.profile?.id)
                    .id(profileID)
            }
            .padding(.vertical, 28)
        }
        .background { AppBackground() }
    }

    private var profileName: String {
        model.profiles.first { $0.id == profileID }?.name ?? String(localized: "this profile")
    }

    private var header: some View {
        HStack(alignment: .lastTextBaseline) {
            PageHeader(title: Text("Watch Stats"), subtitle: Text("What \(profileName) has been watching"))
            // The administrator can look at each profile in the household.
            if model.profile?.isAdministrator == true, model.profiles.count > 1 {
                Picker("Profile", selection: Binding(get: { profileID ?? "" }, set: { selectedProfileID = $0 })) {
                    ForEach(model.profiles) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .padding(.trailing, pageMargin)
            }
        }
    }
}

/// The figures for one profile. Stats are worked out only when the history or library
/// changes, not on every render.
private struct WatchStatsSections: View {
    @Environment(AppModel.self) private var model
    @Query private var entries: [WatchProgress]
    let profileName: String
    /// Continue buttons only when looking at your own stats: playing from another profile's
    /// page would record the watching against yours.
    let canContinue: Bool

    @State private var stats: WatchStats?

    init(profileID: String, profileName: String, canContinue: Bool) {
        _entries = Query(filter: #Predicate<WatchProgress> { $0.profileID == profileID })
        self.profileName = profileName
        self.canContinue = canContinue
    }

    /// Changes whenever anything the stats count changes: entries added or removed, or
    /// progress saved into an existing entry.
    private struct Inputs: Equatable {
        let titles: [Title]
        let count: Int
        let watchedSeconds: Double
        let latest: Date?
    }

    private var inputs: Inputs {
        var seconds = 0.0
        var latest: Date?
        for entry in entries {
            seconds += entry.position + entry.duration
            if latest.map({ entry.lastWatched > $0 }) ?? true { latest = entry.lastWatched }
        }
        return Inputs(titles: model.library.titles, count: entries.count, watchedSeconds: seconds, latest: latest)
    }

    var body: some View {
        let inputs = inputs
        // Only the first frame (before onChange fills the cache) works the stats out inline.
        let stats = stats ?? WatchStats(entries: entries, titles: inputs.titles)
        VStack(alignment: .leading, spacing: 28) {
            if stats.isEmpty {
                ContentUnavailableView("No Watch History Yet", systemImage: "chart.bar.xaxis",
                                       description: Text("Statistics appear here once \(profileName) starts watching."))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
            } else {
                totals(stats)
                HStack(alignment: .top, spacing: 20) {
                    weeklyChart(stats)
                    genreChart(stats)
                }
                .padding(.horizontal, pageMargin)
                HStack(alignment: .top, spacing: 20) {
                    ranking("Most-Watched Shows", systemImage: "tv",
                            rows: stats.topShows.map { RankRow(title: $0.title, detail: Text("^[\($0.episodes) episode](inflect: true)")) })
                    ranking("Recently Finished", systemImage: "checkmark.circle",
                            rows: stats.recentlyFinished.map {
                                RankRow(title: $0.title, detail: Text($0.date, format: .relative(presentation: .named)))
                            })
                }
                .padding(.horizontal, pageMargin)
                inProgress(stats)
            }
        }
        .onChange(of: inputs, initial: true) {
            self.stats = WatchStats(entries: entries, titles: model.library.titles)
        }
    }

    // MARK: In progress

    private struct ProgressRow: Identifiable {
        let id: String
        let title: Title
        var subtitle: String?
        let detail: Text
        let fraction: Double
        let resume: () -> Void
    }

    @ViewBuilder
    private func inProgress(_ stats: WatchStats) -> some View {
        let movies = stats.moviesInProgress.map { item in
            ProgressRow(id: item.id, title: item.title, detail: Self.remaining(item),
                        fraction: item.fraction) {
                model.play(PlaybackItem(title: item.title, episode: nil), from: item.position)
            }
        }
        let shows = stats.showsInProgress.map { show in
            ProgressRow(id: show.title.id, title: show.title,
                        detail: Text("^[\(show.watched) of \(show.total) episode](inflect: true) watched"),
                        fraction: show.total > 0 ? Double(show.watched) / Double(show.total) : 0) {
                model.playResuming(show.title)
            }
        }
        let episodes = stats.episodesInProgress.map { item in
            ProgressRow(id: item.id, title: item.title,
                        subtitle: item.episode.map { "\($0.code) · \($0.name)" },
                        detail: Self.remaining(item), fraction: item.fraction) {
                model.play(PlaybackItem(title: item.title, episode: item.episode), from: item.position)
            }
        }
        if !movies.isEmpty || !shows.isEmpty || !episodes.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("In Progress")
                    .font(.title2.weight(.bold))
                    .padding(.horizontal, pageMargin)
                    .accessibilityAddTraits(.isHeader)
                HStack(alignment: .top, spacing: 20) {
                    progressPanel("Movies", systemImage: "film.fill", rows: movies)
                    progressPanel("TV Shows", systemImage: "tv.fill", rows: shows)
                    progressPanel("Episodes", systemImage: "play.rectangle.on.rectangle.fill", rows: episodes)
                }
                .padding(.horizontal, pageMargin)
            }
        }
    }

    private static func remaining(_ item: WatchStats.InProgressItem) -> Text {
        let seconds = max(item.duration - item.position, 60)
        let left = Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .narrow,
                                                                fractionalPart: .hide(rounded: .down)))
        return Text("\(left) left")
    }

    private func progressPanel(_ title: LocalizedStringResource, systemImage: String, rows: [ProgressRow]) -> some View {
        StatPanel(title: title, systemImage: systemImage) {
            if rows.isEmpty {
                Text("Nothing in progress.").foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                HStack(spacing: 12) {
                    Button { model.open(row.title) } label: {
                        HStack(spacing: 12) {
                            ArtworkView(title: row.title, style: .poster)
                                .frame(width: 32, height: 48)
                                .clipShape(.rect(cornerRadius: 5))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.title.name)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                if let subtitle = row.subtitle {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                row.detail
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                WatchProgressBar(fraction: row.fraction)
                                    .frame(maxWidth: 160)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Open \(row.title.name)")
                    if canContinue {
                        Button(action: row.resume) {
                            Label("Continue", systemImage: "play.fill")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.theaterGlass)
                        .controlSize(.small)
                        .help("Continue watching \(row.title.name)")
                        .accessibilityLabel("Continue watching \(row.title.name)")
                    }
                }
            }
        }
    }

    private struct RankRow: Identifiable {
        let title: Title
        let detail: Text
        var id: String { title.id }
    }

    private func totals(_ stats: WatchStats) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 16)], spacing: 16) {
            StatTile(value: stats.watchedTimeText, label: "Time watched", symbol: "clock.fill")
            StatTile(value: "\(stats.moviesFinished)", label: "Movies finished", symbol: "film.fill")
            StatTile(value: "\(stats.episodesFinished)", label: "Episodes finished", symbol: "tv.fill")
            StatTile(value: "\(stats.showsCompleted)", label: "Shows completed", symbol: "checkmark.seal.fill")
            StatTile(value: "\(stats.inProgress)", label: "In progress", symbol: "play.circle.fill")
        }
        .padding(.horizontal, pageMargin)
    }

    private func weeklyChart(_ stats: WatchStats) -> some View {
        StatPanel(title: "Last 12 Weeks", systemImage: "chart.bar.fill") {
            Chart(stats.weeks) { week in
                BarMark(x: .value("Week", week.start, unit: .weekOfYear), y: .value("Hours", week.hours))
                    .foregroundStyle(Theme.accent.gradient)
                    .cornerRadius(4)
            }
            .chartYAxisLabel("Hours")
            .frame(height: 200)
            Text("Time is counted in the week each title was last watched.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func genreChart(_ stats: WatchStats) -> some View {
        StatPanel(title: "Favorite Genres", systemImage: "theatermasks.fill") {
            if stats.genres.isEmpty {
                Text("Genres appear once titles have been identified.")
                    .foregroundStyle(.secondary)
                    .frame(height: 200)
            } else {
                Chart(stats.genres, id: \.genre) { item in
                    BarMark(x: .value("Hours", item.hours), y: .value("Genre", item.genre.displayName))
                        .foregroundStyle(Theme.gold.gradient)
                        .cornerRadius(4)
                }
                .chartXAxisLabel("Hours")
                .frame(height: 220)
            }
        }
    }

    private func ranking(_ title: LocalizedStringResource, systemImage: String, rows: [RankRow]) -> some View {
        StatPanel(title: title, systemImage: systemImage) {
            if rows.isEmpty {
                Text("Nothing yet.").foregroundStyle(.secondary)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                Button { model.open(row.title) } label: {
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        ArtworkView(title: row.title, style: .poster)
                            .frame(width: 32, height: 48)
                            .clipShape(.rect(cornerRadius: 5))
                        Text(row.title.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Spacer()
                        row.detail
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct StatTile: View {
    let value: String
    let label: LocalizedStringResource
    let symbol: String
    @ScaledMetric(relativeTo: .title) private var valueSize: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Theme.accent)
            Text(value)
                .font(.system(size: valueSize, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

private struct StatPanel<Content: View>: View {
    let title: LocalizedStringResource
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label { Text(title) } icon: { Image(systemName: systemImage) }
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

/// Figures for one profile, worked out from its watch history.
struct WatchStats {
    struct Week: Identifiable {
        let start: Date
        let hours: Double
        var id: Date { start }
    }

    let totalSeconds: Double
    let moviesFinished: Int
    let episodesFinished: Int
    let showsCompleted: Int
    let inProgress: Int
    let weeks: [Week]
    let genres: [(genre: Genre, hours: Double)]
    let topShows: [(title: Title, episodes: Int)]
    let recentlyFinished: [(title: Title, date: Date)]

    /// A movie or episode that's been started but not finished.
    struct InProgressItem: Identifiable {
        let id: String
        let title: Title
        let episode: Episode?
        let position: Double
        let duration: Double
        var fraction: Double { duration > 0 ? min(max(position / duration, 0), 1) : 0 }
    }

    /// A show partway through: some episodes started or finished, but not all of them.
    struct ShowProgress {
        let title: Title
        let watched: Int
        let total: Int
    }

    let moviesInProgress: [InProgressItem]
    let episodesInProgress: [InProgressItem]
    let showsInProgress: [ShowProgress]

    var isEmpty: Bool { totalSeconds < 1 && moviesFinished == 0 && episodesFinished == 0 }

    /// "3d 4h", "5h 12m", or "40m", in the viewer's locale.
    var watchedTimeText: String {
        // Whole minutes, so the shown figure never rounds up past what was watched.
        let minutes = max((totalSeconds / 60).rounded(.down), 0)
        guard minutes > 0 else { return Duration.zero.formatted(.units(allowed: [.minutes], width: .narrow, zeroValueUnits: .show(length: 1))) }
        let duration = Duration.seconds(minutes * 60)
        let units: Set<Duration.UnitsFormatStyle.Unit> = totalSeconds >= 48 * 3600 ? [.days, .hours] : [.hours, .minutes]
        return duration.formatted(.units(allowed: units, width: .narrow, zeroValueUnits: .hide,
                                         fractionalPart: .hide(rounded: .down)))
    }

    init(entries: [WatchProgress], titles: [Title], now: Date = .now, calendar: Calendar = .current) {
        let byID = Dictionary(titles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        /// How much of an entry has actually been watched.
        func watched(_ entry: WatchProgress) -> Double {
            entry.isFinished ? entry.duration : min(entry.position, entry.duration)
        }

        totalSeconds = entries.reduce(0) { $0 + watched($1) }
        let finished = entries.filter(\.isFinished)
        moviesFinished = finished.filter { $0.playbackID == $0.titleID }.count
        episodesFinished = finished.count - moviesFinished

        let grouped = Dictionary(grouping: entries, by: \.titleID)
        showsCompleted = grouped.compactMap { id, items in byID[id].map { ($0, items) } }
            .filter { $0.0.kind == .series && WatchHistory.isWatched($0.0, in: $0.1) }.count
        inProgress = grouped.compactMap { id, items in byID[id].map { ($0, items) } }
            .filter { title, items in !WatchHistory.isWatched(title, in: items) && items.contains { $0.position > 10 || $0.isFinished } }
            .count

        // Twelve calendar weeks, oldest first, including empty ones.
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let starts = (0..<12).reversed().compactMap { calendar.date(byAdding: .weekOfYear, value: -$0, to: thisWeek) }
        var hoursByWeek: [Date: Double] = [:]
        for entry in entries {
            guard let start = calendar.dateInterval(of: .weekOfYear, for: entry.lastWatched)?.start else { continue }
            hoursByWeek[start, default: 0] += watched(entry) / 3600
        }
        weeks = starts.map { Week(start: $0, hours: hoursByWeek[$0] ?? 0) }

        var genreHours: [Genre: Double] = [:]
        for (id, items) in grouped {
            guard let title = byID[id] else { continue }
            let hours = items.reduce(0) { $0 + watched($1) } / 3600
            for genre in title.genres { genreHours[genre, default: 0] += hours }
        }
        genres = genreHours.filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(6).map { ($0.key, $0.value) }

        topShows = grouped.compactMap { id, items -> (Title, Int)? in
            guard let title = byID[id], title.kind == .series else { return nil }
            let count = items.filter(\.isFinished).count
            return count > 0 ? (title, count) : nil
        }
        .sorted { $0.1 > $1.1 }
        .prefix(5)
        .map { ($0.0, $0.1) }

        recentlyFinished = finished.sorted { $0.lastWatched > $1.lastWatched }
            .compactMap { entry in byID[entry.titleID].map { ($0, entry.lastWatched) } }
            .reduce(into: [(title: Title, date: Date)]()) { list, item in
                if !list.contains(where: { $0.title.id == item.0.id }) { list.append((item.0, item.1)) }
            }
            .prefix(5)
            .map { $0 }

        // Most recently watched first; at most ten of each.
        let started = entries.filter { !$0.isFinished && $0.position > 10 }.sorted { $0.lastWatched > $1.lastWatched }
        moviesInProgress = Array(started.compactMap { entry -> InProgressItem? in
            guard entry.playbackID == entry.titleID, let title = byID[entry.titleID], title.kind == .movie else { return nil }
            return InProgressItem(id: entry.playbackID, title: title, episode: nil,
                                  position: entry.position, duration: entry.duration)
        }.prefix(10))
        episodesInProgress = Array(started.compactMap { entry -> InProgressItem? in
            guard let title = byID[entry.titleID], title.kind == .series,
                  let episode = title.allEpisodes.first(where: { $0.id == entry.playbackID }) else { return nil }
            return InProgressItem(id: entry.playbackID, title: title, episode: episode,
                                  position: entry.position, duration: entry.duration)
        }.prefix(10))
        showsInProgress = Array(grouped.compactMap { id, items -> (ShowProgress, Date)? in
            guard let title = byID[id], title.kind == .series, !title.allEpisodes.isEmpty,
                  !WatchHistory.isWatched(title, in: items),
                  items.contains(where: { $0.position > 10 || $0.isFinished }) else { return nil }
            let finished = Set(items.filter(\.isFinished).map(\.playbackID))
            let watched = title.allEpisodes.filter { finished.contains($0.id) }.count
            let latest = items.map(\.lastWatched).max() ?? .distantPast
            return (ShowProgress(title: title, watched: watched, total: title.allEpisodes.count), latest)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(10)
        .map(\.0))
    }
}
