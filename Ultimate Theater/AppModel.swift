//
//  AppModel.swift
//  Ultimate Theater
//

import SwiftUI
import SwiftData

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case home
    case movies
    case shows
    case collections
    case recentlyAdded
    case myList
    case library
    case search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .movies: "Movies"
        case .shows: "TV Shows"
        case .collections: "Collections"
        case .recentlyAdded: "Recently Added"
        case .myList: "My List"
        case .library: "Manage Library"
        case .search: "Search"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house.fill"
        case .movies: "film.fill"
        case .shows: "tv.fill"
        case .collections: "square.stack.3d.up.fill"
        case .recentlyAdded: "clock.fill"
        case .myList: "plus.rectangle.on.rectangle"
        case .library: "externaldrive.fill"
        case .search: "magnifyingglass"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .home: "1"
        case .movies: "2"
        case .shows: "3"
        case .collections: "4"
        case .recentlyAdded: "5"
        case .myList: "6"
        case .library: "7"
        case .search: "f"
        }
    }
}

/// A page pushed onto the browsing stack.
enum AppRoute: Hashable {
    case title(Title)
    case collection(CollectionInfo)
}

/// A movie collection and the library's movies in it, oldest first.
struct MovieCollection: Identifiable, Hashable {
    let info: CollectionInfo
    let movies: [Title]

    var id: Int { info.id }

    /// One slot per film in the collection: the library's copy, or a placeholder.
    enum Entry: Identifiable, Hashable {
        case owned(Title)
        case missing(CollectionPart)

        var id: String {
            switch self {
            case .owned(let title): title.id
            case .missing(let part): "missing-\(part.id)"
            }
        }
    }

    /// Every film in release order. Falls back to just the owned movies when TMDB
    /// didn't provide the full list.
    var entries: [Entry] {
        guard let parts = info.parts, !parts.isEmpty else { return movies.map(Entry.owned) }
        var remaining = movies
        var entries: [Entry] = parts.map { part in
            let index = remaining.firstIndex { $0.tmdbID == part.id }
                ?? remaining.firstIndex { FilenameParser.normalizedKey($0.name) == FilenameParser.normalizedKey(part.title)
                    && ($0.year == nil || part.year == nil || $0.year == part.year) }
            guard let index else { return .missing(part) }
            return .owned(remaining.remove(at: index))
        }
        entries += remaining.map(Entry.owned) // Owned films TMDB didn't list.
        return entries
    }

    /// Total films in the collection, owned or not.
    var totalCount: Int { max(info.parts?.count ?? 0, movies.count) }

    /// "3 movies" or "3 of 4 movies".
    var countDescription: String {
        let owned = movies.count
        if totalCount > owned { return "\(owned) of \(totalCount) movies" }
        return owned == 1 ? "1 movie" : "\(owned) movies"
    }

    /// "The Matrix" from "The Matrix Collection", for sorting and the A–Z index.
    var displayName: String {
        info.name.replacing(/\s+Collection$/, with: "")
    }

    var years: String? {
        let years = movies.compactMap(\.year)
        guard let first = years.min(), let last = years.max() else { return nil }
        return first == last ? String(first) : "\(first)–\(last)"
    }

    var latestAddition: Date { movies.map(\.dateAdded).max() ?? .distantPast }

    var sortName: String { Title.sortName(for: displayName) }

    var indexCharacter: Character {
        Title.indexCharacter(forSortName: sortName)
    }
}

/// App-wide UI state: active profile, navigation, search, and playback.
@Observable
final class AppModel {
    private static let lastProfileKey = "lastProfileID"

    let library: MediaLibrary
    /// Saved audio/subtitle choices per profile.
    let playbackPreferences = PlaybackPreferences()

    /// The active viewer. `nil` shows the "Who's watching?" picker.
    var profile: Profile?

    var section: SidebarSection = .home {
        didSet { if oldValue != section { path = [] } }
    }

    var path: [AppRoute] = []
    var searchText = ""
    var isSearchPresented = false
    /// Genre hub currently shown on the Search page, if any.
    var selectedGenre: Genre?
    /// Shows the Add Media file picker.
    var isImporterPresented = false
    /// Title shown in the Fix Match sheet.
    var matchingTitle: Title?
    /// Title shown in the Edit Info sheet.
    var editingTitle: Title?

    private(set) var nowPlaying: PlaybackItem?
    private(set) var startPosition: Double = 0
    /// Audio/subtitle choice made on the detail page for this play, if any.
    private(set) var startSelection: PlaybackSelection?

    init(library: MediaLibrary) {
        self.library = library
    }

    var lastProfileID: String? {
        UserDefaults.standard.string(forKey: Self.lastProfileKey)
    }

    /// The library filtered by the active profile's rating limit.
    var titles: [Title] {
        guard let profile, profile.ratingLimit < .everything else { return library.titles }
        let country = ratingsCountry
        return library.titles.filter { profile.allows($0, country: country) }
    }

    /// The country whose rating authority decides what restricted profiles see.
    var ratingsCountry: String = RatingsRegion.current {
        didSet { UserDefaults.standard.set(ratingsCountry, forKey: RatingsRegion.key) }
    }

    /// Adding, removing, and editing library titles is limited to unrestricted profiles,
    /// since the library manager lists every title.
    var canManageLibrary: Bool { profile?.ratingLimit == .everything }

    var movies: [Title] { titles.filter { $0.kind == .movie } }

    /// Movies grouped by their TMDB collection.
    var collections: [MovieCollection] {
        Dictionary(grouping: movies.filter { $0.collection != nil }) { $0.collection!.id }
            .compactMap { _, movies in
                // Prefer the copy of the collection info that lists every film.
                (movies.compactMap(\.collection).first { $0.parts != nil } ?? movies.first?.collection).map { info in
                    MovieCollection(info: info, movies: movies.sorted { ($0.year ?? 0) < ($1.year ?? 0) })
                }
            }
    }
    var shows: [Title] { titles.filter { $0.kind == .series } }

    /// Billboard picks: newest titles with real backdrop art, then anything recent.
    var featured: [Title] {
        let withArt = titles.filter { $0.backdropURL != nil }
        return Array((withArt.isEmpty ? titles : withArt).prefix(5))
    }

    // MARK: PINs

    /// The PIN prompt currently shown over the app.
    var pinRequest: PINRequest?

    private static let lockedLimitKey = "profiles.lockedRatingLimit"

    /// Once a restricted profile is opened, the household stays at that limit until the
    /// administrator PIN is entered, so logging out (or relaunching) doesn't lift it.
    private var lockedLimit: RatingLimit? {
        get {
            UserDefaults.standard.object(forKey: Self.lockedLimitKey) == nil ? nil
                : RatingLimit(rawValue: UserDefaults.standard.integer(forKey: Self.lockedLimitKey))
        }
        set {
            if let newValue { UserDefaults.standard.set(newValue.rawValue, forKey: Self.lockedLimitKey) }
            else { UserDefaults.standard.removeObject(forKey: Self.lockedLimitKey) }
        }
    }

    /// Opens a profile, asking for the administrator PIN when it's less restricted than the
    /// current (or last restricted) profile, and for its own PIN when it has one.
    func requestOpen(_ target: Profile) {
        var steps: [PINRequest] = []
        let ceiling = profile?.ratingLimit ?? lockedLimit
        if let ceiling, target.ratingLimit > ceiling, AdministratorPIN.isSet {
            steps.append(PINRequest(title: "Administrator PIN", message: "\(target.name) can watch more mature titles. Enter the administrator PIN to continue.",
                                    profile: target, kind: .verify(AdministratorPIN.verify), completion: { _ in }))
        }
        if target.hasPIN {
            let id = target.id
            steps.append(PINRequest(title: "Enter \(target.name)'s PIN", message: "This profile is locked.", profile: target,
                                    kind: .verify { [weak self] in self?.verifyPIN($0, profileID: id) ?? false }, completion: { _ in }))
        }
        runPINSteps(steps) { [weak self] in self?.select(target) }
    }

    func requestSwitch(to target: Profile) {
        requestOpen(target)
    }

    /// Runs an action that only the household administrator may perform.
    func requireAdministrator(_ reason: String, then action: @escaping () -> Void) {
        guard AdministratorPIN.isSet else { return action() }
        runPINSteps([PINRequest(title: "Administrator PIN", message: reason, profile: nil,
                                kind: .verify(AdministratorPIN.verify), completion: { _ in })], then: action)
    }

    /// Asks for a new PIN (entered twice) and hands it to `completion`.
    func requestNewPIN(title: String, message: String, profile: Profile? = nil, completion: @escaping (String) -> Void) {
        pinRequest = PINRequest(title: title, message: message, profile: profile, kind: .create, completion: completion)
    }

    private func runPINSteps(_ steps: [PINRequest], then done: @escaping () -> Void) {
        guard let first = steps.first else { return done() }
        let rest = Array(steps.dropFirst())
        pinRequest = PINRequest(title: first.title, message: first.message, profile: first.profile, kind: first.kind) { [weak self] _ in
            self?.runPINSteps(rest, then: done)
        }
    }

    /// Stamps a profile's last-used date.
    private func recordUse(of profileID: String) {
        guard let stored = try? modelContext?.fetch(FetchDescriptor<StoredProfile>(predicate: #Predicate { $0.id == profileID })).first else { return }
        stored.lastUsed = .now
        try? modelContext?.save()
        if let index = storedProfiles.firstIndex(where: { $0.id == profileID }) {
            storedProfiles[index].lastUsed = stored.lastUsed
        }
    }

    private func verifyPIN(_ pin: String, profileID: String) -> Bool {
        guard let stored = try? modelContext?.fetch(FetchDescriptor<StoredProfile>(predicate: #Predicate { $0.id == profileID })).first,
              let hash = stored.pinHash else { return true }
        return PINHash.verify(pin, against: hash)
    }

    /// Removing a profile takes the administrator PIN or the profile's own PIN (either one).
    /// With neither set, it's removed straight away.
    func requestRemoval(of target: Profile, then done: @escaping () -> Void) {
        let hasAdministrator = AdministratorPIN.isSet
        guard hasAdministrator || target.hasPIN else {
            deleteProfile(target)
            return done()
        }
        let id = target.id
        let message = switch (hasAdministrator, target.hasPIN) {
        case (true, true): "Enter the administrator PIN or \(target.name)'s PIN to remove this profile."
        case (true, false): "Enter the administrator PIN to remove \(target.name)."
        default: "Enter \(target.name)'s PIN to remove this profile."
        }
        let verify: (String) -> Bool = { [weak self] pin in
            (hasAdministrator && AdministratorPIN.verify(pin))
                || (target.hasPIN && (self?.verifyPIN(pin, profileID: id) ?? false))
        }
        runPINSteps([PINRequest(title: "Remove \(target.name)", message: message, profile: target,
                                kind: .verify(verify), completion: { _ in })]) { [weak self] in
            self?.deleteProfile(target)
            done()
        }
    }

    func select(_ profile: Profile) {
        UserDefaults.standard.set(profile.id, forKey: Self.lastProfileKey)
        recordUse(of: profile.id)
        lockedLimit = profile.ratingLimit < .everything ? profile.ratingLimit : nil
        withAnimation(.smooth(duration: 0.45)) {
            self.profile = profile
            section = .home
            path = []
            searchText = ""
        }
    }

    func signOut() {
        withAnimation(.smooth(duration: 0.45)) {
            nowPlaying = nil
            profile = nil
        }
    }

    func open(_ title: Title) {
        path.append(.title(title))
    }

    func open(_ collection: CollectionInfo) {
        path.append(.collection(collection))
    }

    /// Returns to the root after a title is removed from the library.
    func close(_ titleID: String) {
        path.removeAll { route in
            if case .title(let title) = route { return title.id == titleID }
            return false
        }
    }

    func showGenre(_ genre: Genre) {
        searchText = ""
        section = .search
        selectedGenre = genre
    }

    func addMedia() {
        isImporterPresented = true
    }

    func play(_ item: PlaybackItem, from position: Double = 0, selection: PlaybackSelection? = nil) {
        startPosition = position
        startSelection = selection
        withAnimation(.easeInOut(duration: 0.35)) {
            nowPlaying = item
        }
    }

    func stopPlayback() {
        withAnimation(.easeInOut(duration: 0.35)) {
            nowPlaying = nil
        }
    }

    // MARK: Watch history & My List

    /// Set at launch so lightweight views (cards, context menus) can act on watch
    /// history without each owning a `@Query`.
    var modelContext: ModelContext? {
        didSet { loadProfiles() }
    }

    // MARK: Profiles

    private var storedProfiles: [Profile] = []

    /// Every profile, oldest first. A new installation starts with none.
    var profiles: [Profile] { storedProfiles }

    var canAddProfile: Bool { profiles.count < Profile.maximumCount }

    private func loadProfiles() {
        migrateLegacyProfiles()
        let descriptor = FetchDescriptor<StoredProfile>(sortBy: [SortDescriptor(\.dateCreated)])
        storedProfiles = ((try? modelContext?.fetch(descriptor)) ?? []).map { Profile($0) }
    }

    /// Earlier versions came with four fixed profiles. Any of them with watch history,
    /// My List entries, or ratings becomes a saved profile so that history isn't lost.
    private func migrateLegacyProfiles() {
        let key = "profiles.migratedLegacy"
        guard let modelContext, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let existing = Set(((try? modelContext.fetch(FetchDescriptor<StoredProfile>())) ?? []).map(\.id))
        var used = Set(((try? modelContext.fetch(FetchDescriptor<WatchProgress>())) ?? []).map(\.profileID))
        used.formUnion(((try? modelContext.fetch(FetchDescriptor<MyListEntry>())) ?? []).map(\.profileID))
        used.formUnion(((try? modelContext.fetch(FetchDescriptor<UserRating>())) ?? []).map(\.profileID))
        for (offset, legacy) in Profile.legacy.enumerated() where used.contains(legacy.id) && !existing.contains(legacy.id) {
            let stored = StoredProfile(id: legacy.id, name: legacy.name, symbol: legacy.symbol, paletteIndex: legacy.palette,
                                       ratingLimit: legacy.limit, allowsUnrated: legacy.limit == .everything)
            stored.dateCreated = Date(timeIntervalSince1970: Double(offset)) // Keep the old order.
            modelContext.insert(stored)
        }
        try? modelContext.save()
    }

    /// Creates a profile, or updates an existing one.
    @discardableResult
    func saveProfile(_ draft: ProfileDraft) -> Profile? {
        guard let modelContext else { return nil }
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let allowsUnrated = draft.ratingLimit == .everything || draft.allowsUnrated
        let stored: StoredProfile
        if let id = draft.id, let existing = try? modelContext.fetch(FetchDescriptor<StoredProfile>(predicate: #Predicate { $0.id == id })).first {
            existing.name = trimmed
            existing.symbol = draft.symbol
            existing.paletteIndex = draft.paletteIndex
            existing.ratingLimitRaw = draft.ratingLimit.rawValue
            existing.allowsUnrated = allowsUnrated
            stored = existing
        } else {
            guard canAddProfile else { return nil }
            stored = StoredProfile(name: trimmed, symbol: draft.symbol, paletteIndex: draft.paletteIndex,
                                   ratingLimit: draft.ratingLimit, allowsUnrated: allowsUnrated)
            modelContext.insert(stored)
        }
        stored.imageData = draft.imageData
        switch draft.pinChange {
        case .unchanged: break
        case .set(let pin): stored.pinHash = PINHash.make(pin)
        case .remove: stored.pinHash = nil
        }
        try? modelContext.save()
        loadProfiles()
        let saved = Profile(stored)
        if profile?.id == saved.id { profile = saved }
        return saved
    }

    /// Erases everything: the library database (titles, folders, profiles, history, lists,
    /// ratings), preferences, saved API keys, and caches. The app returns to its
    /// first-launch state. Media files on disk are never touched.
    func resetEverything() {
        nowPlaying = nil
        profile = nil
        section = .home
        path = []
        searchText = ""
        selectedGenre = nil
        if let modelContext {
            try? modelContext.delete(model: WatchProgress.self)
            try? modelContext.delete(model: MyListEntry.self)
            try? modelContext.delete(model: UserRating.self)
            try? modelContext.delete(model: StoredProfile.self)
            try? modelContext.save()
        }
        try? library.context.delete(model: MediaEpisode.self)
        try? library.context.delete(model: MediaItem.self)
        try? library.context.delete(model: LibraryFolder.self)
        try? library.context.save()
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        library.metadata.settings.reset()
        AdministratorPIN.set(nil)
        pinRequest = nil
        playbackPreferences.removeAll()
        LibraryStore.clearCaches()
        ArtworkCache.shared.removeAll()
        library.reload()
        storedProfiles = []
    }

    /// Removes a profile with its watch history, My List, and ratings.
    func deleteProfile(_ removed: Profile) {
        guard let modelContext else { return }
        let id = removed.id
        try? modelContext.delete(model: StoredProfile.self, where: #Predicate { $0.id == id })
        try? modelContext.delete(model: WatchProgress.self, where: #Predicate { $0.profileID == id })
        try? modelContext.delete(model: MyListEntry.self, where: #Predicate { $0.profileID == id })
        try? modelContext.delete(model: UserRating.self, where: #Predicate { $0.profileID == id })
        try? modelContext.save()
        playbackPreferences.removeAll(forProfile: id)
        if lastProfileID == id { UserDefaults.standard.removeObject(forKey: Self.lastProfileKey) }
        if profile?.id == id { signOut() }
        loadProfiles()
    }

    /// Starts a title from wherever this profile left off.
    func playResuming(_ title: Title) {
        guard let profile, let modelContext else { return }
        let profileID = profile.id
        let titleID = title.id
        let descriptor = FetchDescriptor<WatchProgress>(predicate: #Predicate {
            $0.profileID == profileID && $0.titleID == titleID
        })
        let progress = (try? modelContext.fetch(descriptor)) ?? []
        let resume = WatchHistory.resumePoint(for: title, in: progress)
        play(resume.item, from: resume.position)
    }

    func isInMyList(_ title: Title) -> Bool {
        guard let profile, let modelContext else { return false }
        let key = "\(profile.id)|\(title.id)"
        let count = (try? modelContext.fetchCount(FetchDescriptor<MyListEntry>(predicate: #Predicate { $0.key == key }))) ?? 0
        return count > 0
    }

    func toggleMyList(_ title: Title) {
        guard let profile, let modelContext else { return }
        let key = "\(profile.id)|\(title.id)"
        let entries = (try? modelContext.fetch(FetchDescriptor<MyListEntry>(predicate: #Predicate { $0.key == key }))) ?? []
        withAnimation(.snappy) {
            WatchHistory.toggleMyList(title, profileID: profile.id, entries: entries, in: modelContext)
        }
    }

    /// Sets (or with `nil`, clears) this profile's rating for a title.
    func setRating(_ score: Double?, for title: Title) {
        guard let profile, let modelContext else { return }
        let key = UserRating.key(profileID: profile.id, titleID: title.id)
        let existing = try? modelContext.fetch(FetchDescriptor<UserRating>(predicate: #Predicate { $0.key == key })).first
        withAnimation(.snappy) {
            switch (existing, score) {
            case (let rating?, let score?):
                rating.score = score
                rating.ratedAt = .now
            case (let rating?, nil):
                modelContext.delete(rating)
            case (nil, let score?):
                modelContext.insert(UserRating(profileID: profile.id, titleID: title.id, score: score))
            case (nil, nil):
                break
            }
        }
    }

    func search(_ titles: [Title], for query: String) -> [Title] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        return titles.filter { title in
            title.name.localizedStandardContains(trimmed)
                || title.cast.contains { $0.localizedStandardContains(trimmed) }
                || title.director.localizedStandardContains(trimmed)
                || title.genres.contains { $0.displayName.localizedStandardContains(trimmed) }
        }
        // Title matches first, then alphabetical.
        .sorted { lhs, rhs in
            let l = lhs.name.localizedStandardContains(trimmed), r = rhs.name.localizedStandardContains(trimmed)
            return l != r ? l : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

/// Read/write helpers for watch progress and My List, scoped to a profile.
enum WatchHistory {
    /// Where pressing "Play" on a title should start: a specific episode and offset.
    static func resumePoint(for title: Title, in progress: [WatchProgress]) -> (item: PlaybackItem, position: Double, label: String) {
        let entries = progress.filter { $0.titleID == title.id }.sorted { $0.lastWatched > $1.lastWatched }

        switch title.kind {
        case .movie:
            if let entry = entries.first, !entry.isFinished, entry.position > 10 {
                return (PlaybackItem(title: title, episode: nil), entry.position, "Resume")
            }
            return (PlaybackItem(title: title, episode: nil), 0, "Play")

        case .series:
            guard let first = title.allEpisodes.first else {
                return (PlaybackItem(title: title, episode: nil), 0, "Play")
            }
            guard let latest = entries.first,
                  let episode = title.allEpisodes.first(where: { $0.id == latest.playbackID }) else {
                return (PlaybackItem(title: title, episode: first), 0, "Play \(first.code)")
            }
            if latest.isFinished, let next = title.episode(after: episode) {
                return (PlaybackItem(title: title, episode: next), 0, "Play \(next.code)")
            }
            if latest.isFinished {
                return (PlaybackItem(title: title, episode: first), 0, "Watch Again")
            }
            return (PlaybackItem(title: title, episode: episode), latest.position, "Resume \(episode.code)")
        }
    }

    /// Most-recent unfinished item per title, for the Continue Watching row.
    static func continueWatching(_ progress: [WatchProgress], titles: [Title]) -> [(title: Title, entry: WatchProgress)] {
        var seen = Set<String>()
        var result: [(Title, WatchProgress)] = []
        for entry in progress.sorted(by: { $0.lastWatched > $1.lastWatched }) where !seen.contains(entry.titleID) {
            seen.insert(entry.titleID)
            guard !entry.isFinished, let title = titles.first(where: { $0.id == entry.titleID }) else { continue }
            result.append((title, entry))
        }
        return result
    }

    static func saveProgress(_ item: PlaybackItem, profileID: String, position: Double, duration: Double, in context: ModelContext) {
        guard duration.isFinite, duration > 0, position.isFinite else { return }
        let key = WatchProgress.key(profileID: profileID, playbackID: item.id)
        let descriptor = FetchDescriptor<WatchProgress>(predicate: #Predicate { $0.key == key })
        if let existing = try? context.fetch(descriptor).first {
            existing.position = position
            existing.duration = duration
            existing.lastWatched = .now
        } else {
            context.insert(WatchProgress(profileID: profileID, titleID: item.title.id, playbackID: item.id,
                                         position: position, duration: duration))
        }
    }

    static func removeFromContinueWatching(_ title: Title, profileID: String, in context: ModelContext) {
        let titleID = title.id
        try? context.delete(model: WatchProgress.self, where: #Predicate {
            $0.profileID == profileID && $0.titleID == titleID
        })
    }

    static func toggleMyList(_ title: Title, profileID: String, entries: [MyListEntry], in context: ModelContext) {
        if let existing = entries.first(where: { $0.profileID == profileID && $0.titleID == title.id }) {
            context.delete(existing)
        } else {
            context.insert(MyListEntry(profileID: profileID, titleID: title.id))
        }
    }

    /// Titles sharing the most genres with `title`, best matches first.
    static func similar(to title: Title, in titles: [Title], limit: Int = 12) -> [Title] {
        let genres = Set(title.genres)
        let scored: [(title: Title, overlap: Int)] = titles.compactMap { candidate in
            guard candidate.id != title.id else { return nil }
            let overlap = genres.intersection(candidate.genres).count
            return overlap > 0 ? (candidate, overlap) : nil
        }
        let ranked = scored.sorted { lhs, rhs in
            lhs.overlap == rhs.overlap
                ? (lhs.title.criticScore ?? 0) > (rhs.title.criticScore ?? 0)
                : lhs.overlap > rhs.overlap
        }
        return ranked.prefix(limit).map(\.title)
    }
}
