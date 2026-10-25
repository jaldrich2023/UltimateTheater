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
    case statistics
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
        case .statistics: "Watch Stats"
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
        case .statistics: "chart.bar.xaxis"
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
        case .statistics: "8"
        case .library: "7"
        case .search: "f"
        }
    }
}

/// A page pushed onto the browsing stack.
enum AppRoute: Hashable {
    case title(Title)
    case collection(CollectionInfo)
    case smartCollection(SmartCollection)
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
        let phrase = totalCount > owned
            ? AttributedString(localized: "\(owned) of ^[\(totalCount) movie](inflect: true)")
            : AttributedString(localized: "^[\(owned) movie](inflect: true)")
        return String(phrase.characters)
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

/// How the app was launched.
enum AppEnvironment {
    /// Unit tests run inside the app (TEST_HOST), or UI tests launched it (`-uitest` or
    /// `UITEST=1`): no real databases, preferences, network, Keychain, or remote.
    nonisolated static let isRunningTests: Bool = {
        let process = ProcessInfo.processInfo
        return process.environment["XCTestConfigurationFilePath"] != nil
            || process.arguments.contains("-uitest")
            || process.environment["UITEST"] == "1"
    }()

    /// Preferences used while testing, kept apart from the real ones.
    nonisolated static let testDefaultsSuite = "com.ultimatetheater.tests"

    /// The preferences an `AppModel` uses unless told otherwise.
    static var defaultUserDefaults: UserDefaults {
        isRunningTests ? (UserDefaults(suiteName: testDefaultsSuite) ?? .standard) : .standard
    }
}

/// App-wide UI state: active profile, navigation, search, and playback.
@Observable
final class AppModel {
    private static let lastProfileKey = "lastProfileID"

    let library: MediaLibrary
    /// Saved audio/subtitle choices per profile.
    let playbackPreferences = PlaybackPreferences()

    /// Preferences this model reads and writes: `.standard` in the app, a separate suite
    /// while tests run inside it.
    @ObservationIgnored let defaults: UserDefaults
    /// The persistent domain `resetEverything()` clears.
    @ObservationIgnored private let defaultsDomain: String?

    /// The active viewer. `nil` shows the "Who's watching?" picker.
    var profile: Profile? {
        didSet {
            if oldValue?.id != profile?.id {
                reloadWatchProgress()
                reloadMyList()
            }
            if oldValue != profile { rebuildCatalog() }
        }
    }

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
    /// Changes with every play request, so asking for the same title again (Start Over, or
    /// playing what's already in picture-in-picture) reloads the player at the new position.
    private(set) var playRequest = 0
    /// Where the picture-in-picture player docks in the sidebar, in window coordinates.
    var pictureInPictureSlot: CGRect = .zero
    /// The player shrunk to a floating picture-in-picture card while browsing.
    private(set) var isPlayerMinimized = false
    /// The playing engine, for controls outside the player (the Dock menu).
    @ObservationIgnored weak var playerEngine: TheaterEngine?
    /// Episode skips, Skip Intro/Credits, and close, for the iPhone remote and media keys.
    @ObservationIgnored var playerControls: PlayerControlHooks?
    private(set) var startPosition: Double = 0
    /// Audio/subtitle choice made on the detail page for this play, if any.
    private(set) var startSelection: PlaybackSelection?

    init(library: MediaLibrary, defaults: UserDefaults = AppEnvironment.defaultUserDefaults) {
        self.library = library
        self.defaults = defaults
        defaultsDomain = defaults === UserDefaults.standard ? Bundle.main.bundleIdentifier : AppEnvironment.testDefaultsSuite
        ratingsCountry = defaults.string(forKey: RatingsRegion.key).flatMap { ContentRating.systems[$0] != nil ? $0 : nil }
            ?? RatingsRegion.current
        rebuildCatalog()
        observeLibraryTitles()
    }

    var lastProfileID: String? {
        defaults.string(forKey: Self.lastProfileKey)
    }

    /// The player fills the window (not docked in picture-in-picture), so browsing shortcuts
    /// such as Return on a focused title are off.
    var isPlayerFullWindow: Bool { nowPlaying != nil && !isPlayerMinimized }

    /// Whether a bare Return may start the focused page's Play button: not while the player
    /// fills the window, a PIN pad or a library sheet is open, or the search field is in use
    /// (Return there submits the search).
    var acceptsPlayReturnKey: Bool {
        !isPlayerFullWindow && pinRequest == nil && !isSearchPresented && matchingTitle == nil && editingTitle == nil
    }

    // MARK: Catalog

    /// The library filtered by the active profile's rating limit. Stored (not computed per
    /// render), and rebuilt when the library, profile, or ratings country changes.
    private(set) var titles: [Title] = []
    private(set) var movies: [Title] = []
    private(set) var shows: [Title] = []
    /// Movies grouped by their TMDB collection.
    private(set) var collections: [MovieCollection] = []
    /// Billboard picks: newest titles with real backdrop art, then anything recent.
    private(set) var featured: [Title] = []
    /// Every title the active profile may see, by ID.
    private(set) var titleByID: [String: Title] = [:]

    /// The country whose rating authority decides what restricted profiles see.
    var ratingsCountry: String = "US" {
        didSet {
            defaults.set(ratingsCountry, forKey: RatingsRegion.key)
            if oldValue != ratingsCountry { rebuildCatalog() }
        }
    }

    /// Bumped whenever the catalog is rebuilt, so views can compare one number instead of
    /// whole title arrays.
    private(set) var catalogVersion = 0

    private func rebuildCatalog() {
        defer { catalogVersion &+= 1 }
        let all = library.titles
        let visible: [Title]
        if let profile, profile.ratingLimit < .everything {
            let country = ratingsCountry
            visible = all.filter { profile.allows($0, country: country) }
        } else {
            visible = all
        }
        let movies = visible.filter { $0.kind == .movie }
        titles = visible
        self.movies = movies
        shows = visible.filter { $0.kind == .series }
        collections = Dictionary(grouping: movies.filter { $0.collection != nil }) { $0.collection!.id }
            .compactMap { _, movies in
                // Prefer the copy of the collection info that lists every film.
                (movies.compactMap(\.collection).first { $0.parts != nil } ?? movies.first?.collection).map { info in
                    MovieCollection(info: info, movies: movies.sorted { ($0.year ?? 0) < ($1.year ?? 0) })
                }
            }
        let withArt = visible.filter { $0.backdropURL != nil }
        featured = Array((withArt.isEmpty ? visible : withArt).prefix(5))
        titleByID = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Rebuilds the catalog whenever the library's titles change.
    private func observeLibraryTitles() {
        withObservationTracking {
            _ = library.titles
        } onChange: { [weak self] in
            // Called before the change lands; rebuild once it has.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.rebuildCatalog()
                self.observeLibraryTitles()
            }
        }
    }

    /// Adding, approving, removing, and editing library titles belongs to the household
    /// administrator's profile alone.
    var canManageLibrary: Bool { profile?.isAdministrator == true }

    /// The household administrator's profile, if there is one.
    var administratorProfile: Profile? { storedProfiles.first(where: \.isAdministrator) }

    /// Runs a library-management action: only on the administrator's profile, and only after
    /// the administrator PIN (when one is set) is entered for this action.
    func manageLibrary(_ reason: String, in host: PINHost = .main, then action: @escaping () -> Void) {
        guard canManageLibrary else { return }
        requireAdministrator(reason, in: host, then: action)
    }

    /// Shows the Add Media file picker (after the administrator PIN).
    func addMedia(in host: PINHost = .main) {
        manageLibrary("Enter the administrator PIN to add movies and shows.", in: host) { [weak self] in
            self?.isImporterPresented = true
        }
    }

    /// Adds dropped files or folders (after the administrator PIN).
    func importDropped(_ urls: [URL]) {
        manageLibrary("Enter the administrator PIN to add movies and shows.") { [weak self] in
            guard let self else { return }
            Task { await self.library.importMedia(from: urls) }
        }
    }

    func rescanLibraryFolders(in host: PINHost = .main) {
        manageLibrary("Enter the administrator PIN to rescan the library folders.", in: host) { [weak self] in
            guard let self else { return }
            Task { await self.library.rescanFolders() }
        }
    }

    /// Re-fetches info for these titles, or for everything when `ids` is nil.
    func refreshInfo(for ids: [String]? = nil, in host: PINHost = .main) {
        if let ids, ids.isEmpty { return }
        let reason = ids?.count == 1 ? "Enter the administrator PIN to refresh this title's info."
            : "Enter the administrator PIN to refresh info."
        manageLibrary(reason, in: host) { [weak self] in
            guard let self else { return }
            Task { await self.library.refreshMetadata(for: ids, force: true) }
        }
    }

    func fixMatch(_ title: Title) {
        manageLibrary("Enter the administrator PIN to fix the match for “\(title.name)”.") { [weak self] in
            self?.matchingTitle = title
        }
    }

    func editInfo(_ title: Title) {
        manageLibrary("Enter the administrator PIN to edit “\(title.name)”.") { [weak self] in
            self?.editingTitle = title
        }
    }

    /// Whether another profile already holds the administrator role.
    func hasOtherAdministrator(than id: String?) -> Bool {
        storedProfiles.contains { $0.isAdministrator && $0.id != id }
    }

    // MARK: PINs

    /// The PIN prompt currently shown over the app.
    var pinRequest: PINRequest?
    /// The window showing `pinRequest`.
    private(set) var pinHost: PINHost = .main

    /// Where a PIN prompt appears.
    enum PINHost {
        /// Over the main window.
        case main
        /// Over the Settings window.
        case settings
    }

    private static let lockedLimitKey = "profiles.lockedRatingLimit"

    /// Once a restricted profile is opened, the household stays at that limit until the
    /// administrator PIN is entered, so logging out (or relaunching) doesn't lift it.
    private var lockedLimit: RatingLimit? {
        get {
            defaults.object(forKey: Self.lockedLimitKey) == nil ? nil
                : RatingLimit(rawValue: defaults.integer(forKey: Self.lockedLimitKey))
        }
        set {
            if let newValue { defaults.set(newValue.rawValue, forKey: Self.lockedLimitKey) }
            else { defaults.removeObject(forKey: Self.lockedLimitKey) }
        }
    }

    /// Opens a profile, asking for the administrator PIN when it's less restricted than the
    /// current (or last restricted) profile, and for its own PIN when it has one.
    func requestOpen(_ target: Profile, in host: PINHost = .main) {
        var steps: [PINRequest] = []
        let ceiling = profile?.ratingLimit ?? lockedLimit
        if let ceiling, target.ratingLimit > ceiling, AdministratorPIN.isSet {
            steps.append(PINRequest(title: "Administrator PIN", message: "\(target.name) can watch more mature titles. Enter the administrator PIN to continue.",
                                    profile: target, kind: .verify(AdministratorPIN.verify), completion: { _ in }))
        }
        if target.isAdministrator, AdministratorPIN.isSet, profile?.id != target.id, steps.isEmpty {
            steps.append(PINRequest(title: "Administrator PIN", message: "Enter the administrator PIN to open \(target.name).",
                                    profile: target, kind: .verify(AdministratorPIN.verify), completion: { _ in }))
        }
        if target.hasPIN {
            let id = target.id
            steps.append(PINRequest(title: "Enter \(target.name)'s PIN", message: "This profile is locked.", profile: target,
                                    kind: .verify { [weak self] in self?.verifyPIN($0, profileID: id) ?? false },
                                    lockoutTargets: [.profile(id)], completion: { _ in }))
        }
        runPINSteps(steps, in: host) { [weak self] in self?.select(target) }
    }

    func requestSwitch(to target: Profile) {
        requestOpen(target)
    }

    /// Runs an action that only the household administrator may perform.
    func requireAdministrator(_ reason: String, in host: PINHost = .main, then action: @escaping () -> Void) {
        guard AdministratorPIN.isSet else { return action() }
        runPINSteps([PINRequest(title: "Administrator PIN", message: reason, profile: nil,
                                kind: .verify(AdministratorPIN.verify), completion: { _ in })], in: host, then: action)
    }

    /// Asks for a new PIN (entered twice) and hands it to `completion`.
    func requestNewPIN(title: String, message: String, profile: Profile? = nil, completion: @escaping (String) -> Void) {
        pinHost = .main
        pinRequest = PINRequest(title: title, message: message, profile: profile, kind: .create, completion: completion)
    }

    /// Dismisses a prompt left over a window that closed.
    func cancelPINRequest(in host: PINHost) {
        if pinHost == host { pinRequest = nil }
    }

    private func runPINSteps(_ steps: [PINRequest], in host: PINHost = .main, then done: @escaping () -> Void) {
        guard let first = steps.first else { return done() }
        let rest = Array(steps.dropFirst())
        pinHost = host
        pinRequest = PINRequest(title: first.title, message: first.message, profile: first.profile, kind: first.kind,
                                lockoutTargets: first.lockoutTargets) { [weak self] _ in
            self?.runPINSteps(rest, in: host, then: done)
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
        var targets: Set<PINLockoutTarget> = []
        if hasAdministrator { targets.insert(.administrator) }
        if target.hasPIN { targets.insert(.profile(id)) }
        runPINSteps([PINRequest(title: "Remove \(target.name)", message: message, profile: target,
                                kind: .verify(verify), lockoutTargets: targets, completion: { _ in })]) { [weak self] in
            self?.deleteProfile(target)
            done()
        }
    }

    func select(_ profile: Profile) {
        defaults.set(profile.id, forKey: Self.lastProfileKey)
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
        // Saves where playback (perhaps in picture-in-picture) got to before the profile goes.
        if nowPlaying != nil { closePlayerSavingProgress() }
        withAnimation(.smooth(duration: 0.45)) {
            nowPlaying = nil
            profile = nil
        }
    }

    func open(_ title: Title) {
        path.append(.title(title))
    }

    /// When a title plays to the end, the player closes onto that title's page.
    func finishPlayback(of title: Title) {
        stopPlayback()
        if case .title(let shown) = path.last, shown.id == title.id { return }
        open(title)
    }

    func open(_ collection: CollectionInfo) {
        path.append(.collection(collection))
    }

    func open(_ collection: SmartCollection) {
        path.append(.smartCollection(collection))
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

    func play(_ item: PlaybackItem, from position: Double = 0, selection: PlaybackSelection? = nil) {
        startPosition = position
        startSelection = selection
        playRequest += 1
        withAnimation(.easeInOut(duration: 0.35)) {
            nowPlaying = item
            isPlayerMinimized = false
        }
    }

    func stopPlayback() {
        withAnimation(.easeInOut(duration: 0.35)) {
            nowPlaying = nil
            isPlayerMinimized = false
        }
    }

    /// Shrinks the player to picture-in-picture; playback continues while browsing.
    func minimizePlayer() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { isPlayerMinimized = true }
    }

    func expandPlayer() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { isPlayerMinimized = false }
    }

    // MARK: Watch history & My List

    /// Set at launch so lightweight views (cards, context menus) can act on watch
    /// history without each owning a `@Query`.
    var modelContext: ModelContext? {
        didSet {
            loadProfiles()
            observeWatchHistory()
        }
    }

    /// The active profile's watch history grouped by title, so every card and menu can show
    /// watched state without its own query. Entries are live models, so position updates show
    /// up without touching this dictionary; it only changes when entries are added or removed.
    private(set) var watchProgressByTitle: [String: [WatchProgress]] = [:] {
        didSet { watchHistoryVersion &+= 1 }
    }
    /// Bumped whenever watch history is reloaded or refreshed, so views can cache rows
    /// derived from it.
    private(set) var watchHistoryVersion = 0
    /// Titles on the active profile's My List.
    private(set) var myListIDs: Set<String> = []
    @ObservationIgnored private var watchHistoryObserver: Task<Void, Never>?
    @ObservationIgnored private var historyRefresh: Task<Void, Never>?
    @ObservationIgnored private var pendingRefresh: (progress: Bool, myList: Bool) = (false, false)
    /// Every loaded progress entry, for spotting additions and removals.
    @ObservationIgnored private var loadedProgressIDs: Set<PersistentIdentifier> = []

    /// Reloads the whole watch history for the active profile.
    func reloadWatchProgress() {
        guard let profile, let modelContext else {
            watchProgressByTitle = [:]
            loadedProgressIDs = []
            return
        }
        let profileID = profile.id
        let entries = (try? modelContext.fetch(FetchDescriptor<WatchProgress>(predicate: #Predicate {
            $0.profileID == profileID
        }))) ?? []
        watchProgressByTitle = Dictionary(grouping: entries, by: \.titleID)
        loadedProgressIDs = Set(entries.map(\.persistentModelID))
    }

    /// Applies only the additions and removals since the last load, touching just the
    /// affected titles (and nothing at all when entries were only updated in place).
    private func refreshWatchProgress() {
        guard let profile, let modelContext else { return reloadWatchProgress() }
        let profileID = profile.id
        guard let current = try? modelContext.fetchIdentifiers(FetchDescriptor<WatchProgress>(predicate: #Predicate {
            $0.profileID == profileID
        })) else { return reloadWatchProgress() }
        let currentIDs = Set(current)
        let added = currentIDs.subtracting(loadedProgressIDs)
        let removed = loadedProgressIDs.subtracting(currentIDs)
        guard !added.isEmpty || !removed.isEmpty else { return }
        var updated = watchProgressByTitle
        if !removed.isEmpty {
            for (titleID, entries) in updated where entries.contains(where: { removed.contains($0.persistentModelID) }) {
                let kept = entries.filter { !removed.contains($0.persistentModelID) }
                updated[titleID] = kept.isEmpty ? nil : kept
            }
        }
        for id in added {
            guard let entry = modelContext.model(for: id) as? WatchProgress else { return reloadWatchProgress() }
            updated[entry.titleID, default: []].append(entry)
        }
        watchProgressByTitle = updated
        loadedProgressIDs = currentIDs
    }

    private func reloadMyList() {
        guard let profile, let modelContext else {
            myListIDs = []
            return
        }
        let profileID = profile.id
        let entries = (try? modelContext.fetch(FetchDescriptor<MyListEntry>(predicate: #Predicate {
            $0.profileID == profileID
        }))) ?? []
        let ids = Set(entries.map(\.titleID))
        if ids != myListIDs { myListIDs = ids }
    }

    private func observeWatchHistory() {
        watchHistoryObserver?.cancel()
        reloadWatchProgress()
        reloadMyList()
        guard modelContext != nil else { return }
        watchHistoryObserver = Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: ModelContext.didSave) {
                guard let self else { return }
                // Only the users store holds watch history.
                guard let context = note.object as? ModelContext, context === self.modelContext else { continue }
                let changed = Self.changedEntities(in: note)
                self.scheduleHistoryRefresh(progress: changed?.contains("WatchProgress") ?? true,
                                            myList: changed?.contains("MyListEntry") ?? true)
            }
        }
    }

    /// The model types a save touched, or nil when the notification doesn't say.
    private static func changedEntities(in note: Notification) -> Set<String>? {
        guard let info = note.userInfo else { return nil }
        let keys: [ModelContext.NotificationKey] = [.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
        var found = false
        var names = Set<String>()
        for key in keys {
            let value = info[key.rawValue]
            if let ids = value as? [PersistentIdentifier] {
                found = true
                names.formUnion(ids.map(\.entityName))
            } else if let ids = value as? Set<PersistentIdentifier> {
                found = true
                names.formUnion(ids.map(\.entityName))
            }
        }
        return found ? names : nil
    }

    /// Coalesces bursts of saves (progress autosaves, a season marked watched) into one refresh.
    private func scheduleHistoryRefresh(progress: Bool, myList: Bool) {
        guard progress || myList else { return }
        pendingRefresh.progress = pendingRefresh.progress || progress
        pendingRefresh.myList = pendingRefresh.myList || myList
        historyRefresh?.cancel()
        historyRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            let pending = self.pendingRefresh
            self.pendingRefresh = (false, false)
            if pending.progress {
                self.refreshWatchProgress()
                // Positions and last-watched dates change in place; rows ordered by them
                // (Continue Watching) need rebuilding too.
                self.watchHistoryVersion &+= 1
            }
            if pending.myList { self.reloadMyList() }
        }
    }

    // MARK: Profiles

    private var storedProfiles: [Profile] = []

    /// Every profile, oldest first. A new installation starts with none.
    var profiles: [Profile] { storedProfiles }

    var canAddProfile: Bool { profiles.count < Profile.maximumCount }

    private func loadProfiles() {
        migrateLegacyProfiles()
        let descriptor = FetchDescriptor<StoredProfile>(sortBy: [SortDescriptor(\.dateCreated)])
        let stored = (try? modelContext?.fetch(descriptor)) ?? []
        // Households from before the administrator role: the oldest unrestricted profile takes it.
        if !stored.isEmpty, !stored.contains(where: \.isAdministrator),
           let first = stored.first(where: { $0.ratingLimitRaw == RatingLimit.everything.rawValue }) ?? stored.first {
            first.isAdministrator = true
            first.ratingLimitRaw = RatingLimit.everything.rawValue
            try? modelContext?.save()
        }
        storedProfiles = stored.map { Profile($0) }
    }

    /// Earlier versions came with four fixed profiles. Any of them with watch history,
    /// My List entries, or ratings becomes a saved profile so that history isn't lost.
    private func migrateLegacyProfiles() {
        let key = "profiles.migratedLegacy"
        guard let modelContext, !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
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
            // The household always keeps one administrator.
            existing.isAdministrator = draft.isAdministrator || !hasOtherAdministrator(than: existing.id)
            stored = existing
        } else {
            guard canAddProfile else { return nil }
            stored = StoredProfile(name: trimmed, symbol: draft.symbol, paletteIndex: draft.paletteIndex,
                                   ratingLimit: draft.ratingLimit, allowsUnrated: allowsUnrated)
            // The first profile is the administrator.
            stored.isAdministrator = draft.isAdministrator || !hasOtherAdministrator(than: nil)
            modelContext.insert(stored)
        }
        stored.imageData = draft.imageData
        if stored.isAdministrator {
            // The administrator manages every title, so it can't be content-restricted.
            stored.ratingLimitRaw = RatingLimit.everything.rawValue
            stored.allowsUnrated = true
            for other in (try? modelContext.fetch(FetchDescriptor<StoredProfile>())) ?? [] where other.id != stored.id {
                other.isAdministrator = false
            }
        }
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
            try? modelContext.delete(model: SceneBookmark.self)
            try? modelContext.delete(model: StoredProfile.self)
            try? modelContext.save()
        }
        library.cancelSkipAnalysis()
        try? library.context.delete(model: MediaEpisode.self)
        try? library.context.delete(model: MediaItem.self)
        try? library.context.delete(model: LibraryFolder.self)
        try? library.context.delete(model: PendingMedia.self)
        try? library.context.save()
        if let defaultsDomain {
            defaults.removePersistentDomain(forName: defaultsDomain)
        }
        library.metadata.settings.reset()
        OpenSubtitlesSettings.shared.reset()
        ExternalSubtitleLibrary.removeAll()
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
        try? modelContext.delete(model: SceneBookmark.self, where: #Predicate { $0.profileID == id })
        try? modelContext.save()
        playbackPreferences.removeAll(forProfile: id)
        if lastProfileID == id { defaults.removeObject(forKey: Self.lastProfileKey) }
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

    func isWatched(_ title: Title) -> Bool {
        WatchHistory.isWatched(title, in: watchProgressByTitle[title.id] ?? [])
    }

    /// How far into an unfinished movie this profile is (0…1), for poster progress bars.
    func partialProgress(_ title: Title) -> Double? {
        WatchHistory.partialProgress(title, in: watchProgressByTitle[title.id] ?? [])
    }

    /// Whether this profile has finished one episode.
    func isWatched(_ episode: Episode, of show: Title) -> Bool {
        watchProgressByTitle[show.id]?.contains { $0.playbackID == episode.id && $0.isFinished } ?? false
    }

    /// Clears this profile's progress for a title, taking it off Continue Watching.
    func removeFromContinueWatching(_ title: Title) {
        guard let profile, let modelContext else { return }
        withAnimation(.snappy) {
            WatchHistory.removeFromContinueWatching(title, profileID: profile.id, in: modelContext)
            try? modelContext.save()
            refreshWatchProgress()
        }
    }

    /// Tags a title as watched or unwatched for this profile.
    func setWatched(_ watched: Bool, _ title: Title) {
        guard let profile, let modelContext else { return }
        withAnimation(.snappy) {
            WatchHistory.setWatched(watched, title, profileID: profile.id, in: modelContext)
            try? modelContext.save()
            refreshWatchProgress()
        }
    }

    /// Tags individual episodes (one, or a whole season) as watched or unwatched for this profile.
    func setWatched(_ watched: Bool, episodes: [Episode], of show: Title) {
        guard let profile, let modelContext else { return }
        withAnimation(.snappy) {
            WatchHistory.setWatched(watched, episodes: episodes, of: show, profileID: profile.id, in: modelContext)
            try? modelContext.save()
            refreshWatchProgress()
        }
    }

    func isInMyList(_ title: Title) -> Bool {
        myListIDs.contains(title.id)
    }

    func toggleMyList(_ title: Title) {
        guard let profile, let modelContext else { return }
        let key = "\(profile.id)|\(title.id)"
        let entries = (try? modelContext.fetch(FetchDescriptor<MyListEntry>(predicate: #Predicate { $0.key == key }))) ?? []
        withAnimation(.snappy) {
            WatchHistory.toggleMyList(title, profileID: profile.id, entries: entries, in: modelContext)
            if myListIDs.contains(title.id) { myListIDs.remove(title.id) } else { myListIDs.insert(title.id) }
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

    /// Whether a title counts as watched: a finished movie, or a show whose every episode is finished.
    static func isWatched(_ title: Title, in progress: [WatchProgress]) -> Bool {
        let finished = Set(progress.filter { $0.titleID == title.id && $0.isFinished }.map(\.playbackID))
        switch title.kind {
        case .movie: return finished.contains(title.id)
        case .series: return !title.allEpisodes.isEmpty && title.allEpisodes.allSatisfy { finished.contains($0.id) }
        }
    }

    /// How far into an unfinished movie the viewer is (0…1), for poster progress bars.
    static func partialProgress(_ title: Title, in progress: [WatchProgress]) -> Double? {
        guard title.kind == .movie,
              let entry = progress.first(where: { $0.titleID == title.id && $0.playbackID == title.id }),
              !entry.isFinished, entry.position > 10 else { return nil }
        return entry.fraction
    }

    /// Tags a title (every episode, for a show) as watched, or clears its history.
    static func setWatched(_ watched: Bool, _ title: Title, profileID: String, in context: ModelContext) {
        guard watched else {
            removeFromContinueWatching(title, profileID: profileID, in: context)
            return
        }
        let items: [(id: String, minutes: Int)] = title.kind == .movie
            ? [(title.id, title.runtimeMinutes)]
            : title.allEpisodes.map { ($0.id, $0.runtimeMinutes) }
        for item in items {
            let key = WatchProgress.key(profileID: profileID, playbackID: item.id)
            let existing = try? context.fetch(FetchDescriptor<WatchProgress>(predicate: #Predicate { $0.key == key })).first
            let duration = max(existing?.duration ?? 0, Double(item.minutes * 60), 1)
            if let existing {
                existing.duration = duration
                existing.position = duration
                existing.lastWatched = .now
            } else {
                context.insert(WatchProgress(profileID: profileID, titleID: title.id, playbackID: item.id,
                                             position: duration, duration: duration))
            }
        }
    }

    /// Tags specific episodes of a show as watched, or clears just their history.
    static func setWatched(_ watched: Bool, episodes: [Episode], of show: Title, profileID: String, in context: ModelContext) {
        for episode in episodes {
            let key = WatchProgress.key(profileID: profileID, playbackID: episode.id)
            let existing = try? context.fetch(FetchDescriptor<WatchProgress>(predicate: #Predicate { $0.key == key })).first
            guard watched else {
                if let existing { context.delete(existing) }
                continue
            }
            let duration = max(existing?.duration ?? 0, Double(episode.runtimeMinutes * 60), 1)
            if let existing {
                existing.duration = duration
                existing.position = duration
                existing.lastWatched = .now
            } else {
                context.insert(WatchProgress(profileID: profileID, titleID: show.id, playbackID: episode.id,
                                             position: duration, duration: duration))
            }
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
