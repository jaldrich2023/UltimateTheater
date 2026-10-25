//
//  MediaLibrary.swift
//  Ultimate Theater
//
//  The user's own movies and shows: importing files and folders, keeping
//  sandbox access to them across launches, fetching metadata, and producing the
//  `Title` values the UI renders.
//

import SwiftUI
import SwiftData
import AppKit

/// Progress for a long-running library operation, shown in the status banner.
struct LibraryActivity: Equatable {
    var message: String
    var completed: Int = 0
    var total: Int = 0

    var fraction: Double? { total > 0 ? Double(completed) / Double(total) : nil }
}

/// A one-off message for the status banner.
struct LibraryNotice: Equatable, Identifiable {
    let id = UUID()
    var message: String
    var isError = false
}

/// User edits from the Edit Info sheet.
struct MetadataEdits {
    var name: String
    var year: Int?
    var tagline: String
    var synopsis: String
    var maturity: String
    var genres: [Genre]
    var posterURL: String
    var backdropURL: String
    var isLocked: Bool
}

@Observable
final class MediaLibrary {
    /// The master library's database. A ModelContext doesn't keep its container alive,
    /// so the library holds it for as long as it uses `context`.
    let container: ModelContainer
    let context: ModelContext
    let metadata: MetadataService

    private(set) var titles: [Title] = []
    private(set) var folders: [LibraryFolder] = []
    private(set) var activity: LibraryActivity? {
        didSet {
            // Folder changes that arrived while busy were held back; work through them now.
            if activity == nil, oldValue != nil, !pendingChanges.isEmpty {
                Task { [weak self] in await self?.applyFolderChanges() }
            }
        }
    }
    var notice: LibraryNotice?

    var isBusy: Bool { activity != nil }

    /// Library folders are always watched: deleted videos leave the library, and new ones
    /// wait in `pending` until the administrator approves them.
    private(set) var pending: [PendingMedia] = []

    private var watcher: FolderWatcher?
    /// Network volumes don't report file changes reliably, so their folders are polled.
    private var networkPoll: Task<Void, Never>?
    /// Re-checks folders when a drive or share is mounted.
    private var mountWatch: Task<Void, Never>?
    private var pendingChanges: [FolderWatcher.Change] = []
    /// Folder changes are being worked out; later ones wait for the same pass.
    private var isApplyingChanges = false

    /// Playback ID → where its file lives.
    private var files: [String: FileReference] = [:]
    /// Security scopes opened for playback, by playback ID: one entry per `beginPlayback`,
    /// each closed by its own `endPlayback`, so a second user of the same file (or a quick
    /// look such as Reveal in Finder) never closes another's access.
    private var playbackScopes: [String: [URL]] = [:]
    /// Opens the saved folder scopes after launch (resolving bookmarks can be slow on a
    /// network volume, so it isn't done on the main actor). File access waits for it.
    private var scopeOpening: Task<Void, Never>?
    /// Folder (and chosen file) scopes kept open for the session so files inside stay
    /// reachable, by path: each is opened once and closed when its folder is removed.
    private var sessionScopes: [String: URL] = [:]
    /// Intro and credits times by episode ID, updated as background analysis finishes.
    private(set) var skipSegments: [String: SkipSegments] = [:]
    /// Episode IDs waiting for intro and credits analysis, and the task working through them.
    private var skipQueue: [String] = []
    private var skipWorker: Task<Void, Never>?

    nonisolated private struct FileReference: Sendable {
        let path: String
        let bookmark: Data?
        let ownerID: String
        let isEpisode: Bool
    }

    init(container: ModelContainer, metadata: MetadataService) {
        self.container = container
        self.context = container.mainContext
        self.metadata = metadata
        reload()
        scopeOpening = Task { [weak self] in
            await self?.openFolderScopes()
            self?.restartWatching()
        }
    }

    isolated deinit {
        networkPoll?.cancel()
        mountWatch?.cancel()
        skipWorker?.cancel()
        scopeOpening?.cancel()
        for url in sessionScopes.values { url.stopAccessingSecurityScopedResource() }
        for url in playbackScopes.values.joined() { url.stopAccessingSecurityScopedResource() }
    }

    // MARK: Reading

    func reload() {
        let items = (try? context.fetch(FetchDescriptor<MediaItem>(sortBy: [SortDescriptor(\.dateAdded, order: .reverse)]))) ?? []
        folders = (try? context.fetch(FetchDescriptor<LibraryFolder>(sortBy: [SortDescriptor(\.path)]))) ?? []
        pending = (try? context.fetch(FetchDescriptor<PendingMedia>(predicate: #Predicate { !$0.isIgnored },
                                                                     sortBy: [SortDescriptor(\.dateFound)]))) ?? []

        var references: [String: FileReference] = [:]
        var segments: [String: SkipSegments] = [:]
        for item in items {
            if let path = item.filePath {
                references[item.id] = FileReference(path: path, bookmark: item.fileBookmark, ownerID: item.id, isEpisode: false)
            }
            for episode in item.episodes {
                references[episode.id] = FileReference(path: episode.filePath, bookmark: episode.fileBookmark,
                                                       ownerID: episode.id, isEpisode: true)
                let found = SkipSegments(introStart: episode.introStart, introEnd: episode.introEnd, creditsStart: episode.creditsStart)
                if !found.isEmpty { segments[episode.id] = found }
            }
        }
        files = references
        skipSegments = segments
        titles = items.map { Self.makeTitle(from: $0) }
        prefetchArtwork()
    }

    func item(for titleID: String) -> MediaItem? {
        try? context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.id == titleID })).first
    }

    func filePath(for playbackID: String) -> String? {
        files[playbackID]?.path
    }

    // MARK: Importing

    /// Adds video files and folders (scanned recursively). Already-imported files are skipped.
    func importMedia(from urls: [URL]) async {
        await waitForFolderChanges()
        guard !isBusy else {
            notice = LibraryNotice(message: "Please wait for the current import to finish.")
            return
        }
        activity = LibraryActivity(message: "Scanning for videos…")

        // Keep access for this session; bookmarks restore it on later launches.
        for url in urls { openSessionScope(url) }
        // Folders are read off the main actor, so a large or slow (network) folder doesn't
        // stall the interface.
        let scan = await Self.scan(urls)
        for (folder, bookmark) in scan.folders { rememberFolder(folder, bookmark: bookmark) }
        let discovered = scan.videos

        // Titles already in the wrong library (a movie under TV Shows, or the reverse) move first.
        let reclassified = reclassifyMisplacedTitles()
        let movedNote = reclassified.files == 0 ? nil
            : "Moved \(reclassified.files) title\(reclassified.files == 1 ? "" : "s") to the right library."

        let known = Set(files.values.map(\.path))
        let newFiles = discovered.filter { !known.contains($0.path) }
        guard !newFiles.isEmpty else {
            activity = nil
            notice = LibraryNotice(message: movedNote ?? (discovered.isEmpty
                ? "No supported video files were found."
                : "Everything there is already in your library."))
            analyzeSkipSegments(forShows: reclassified.items)
            if !reclassified.items.isEmpty, metadata.settings.autoFetch {
                await refreshMetadata(for: reclassified.items.map(\.id), force: false)
            }
            return
        }

        activity = LibraryActivity(message: "Adding \(newFiles.count) videos…", total: newFiles.count)
        var series = Dictionary(
            ((try? context.fetch(FetchDescriptor<MediaItem>())) ?? []).filter { $0.kind == .series }
                .map { (FilenameParser.normalizedKey($0.name), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var touched: [MediaItem] = []

        for (index, file) in newFiles.enumerated() {
            let parsed = FilenameParser.parse(url: file)
            let bookmark = await Self.makeBookmark(for: file)
            let inspection = await Self.inspect(file)

            if parsed.isEpisode, let season = parsed.season, let number = parsed.episode {
                let key = FilenameParser.normalizedKey(parsed.title)
                // A show removed while files were being read (say, its folder was removed) is
                // made again rather than used.
                if let existing = series[key], Self.isGone(existing) { series[key] = nil }
                let show = series[key] ?? {
                    let created = MediaItem(kind: .series, name: parsed.title, year: parsed.year)
                    context.insert(created)
                    series[key] = created
                    return created
                }()
                let episode = MediaEpisode(season: season, number: number,
                                           name: parsed.episodeTitle ?? "",
                                           filePath: file.path, fileBookmark: bookmark,
                                           isPlayable: inspection.isPlayable)
                episode.qualityBadges = inspection.badges.map(\.rawValue)
                episode.playbackIssue = inspection.issue?.message
                episode.playbackIssueIsDamage = inspection.issue?.isDamage ?? false
                episode.show = show
                context.insert(episode)
                if !touched.contains(where: { $0.id == show.id }) { touched.append(show) }
            } else {
                let movie = MediaItem(kind: .movie, name: parsed.title, year: parsed.year)
                movie.filePath = file.path
                movie.fileBookmark = bookmark
                movie.isPlayable = inspection.isPlayable
                movie.qualityBadges = inspection.badges.map(\.rawValue)
                movie.playbackIssue = inspection.issue?.message
                movie.playbackIssueIsDamage = inspection.issue?.isDamage ?? false
                context.insert(movie)
                touched.append(movie)
            }
            activity?.completed = index + 1
        }

        save()
        reload()
        activity = nil
        // Find every new episode's intro and credits now, so Skip Intro is ready on first play.
        analyzeSkipSegments(forShows: touched + reclassified.items)

        let movies = touched.filter { $0.kind == .movie }.count
        let shows = touched.count - movies
        let parts = [movies > 0 ? "\(movies) movie\(movies == 1 ? "" : "s")" : nil,
                     shows > 0 ? "\(shows) show\(shows == 1 ? "" : "s")" : nil].compactMap { $0 }
        notice = LibraryNotice(message: ["Added \(parts.joined(separator: " and ")) to your library.", movedNote]
            .compactMap { $0 }.joined(separator: " "))

        if metadata.settings.autoFetch {
            let ids = touched.map(\.id) + reclassified.items.map(\.id).filter { id in !touched.contains { $0.id == id } }
            await refreshMetadata(for: ids, force: false)
        }
    }

    /// Moves titles filed under the wrong library, judged by the same filename rules used
    /// when importing: a "movie" whose file is really an episode joins its show in TV
    /// Shows, and an "episode" whose file is really a movie becomes a movie (its show is
    /// removed once empty). Titles with edited, locked info are left as they are.
    /// Returns the titles that gained files (to fetch their info) and how many files moved.
    @discardableResult
    func reclassifyMisplacedTitles() -> (items: [MediaItem], files: Int) {
        let items = (try? context.fetch(FetchDescriptor<MediaItem>())) ?? []
        var series = Dictionary(items.filter { $0.kind == .series }.map { (FilenameParser.normalizedKey($0.name), $0) },
                                uniquingKeysWith: { first, _ in first })
        var touched: [MediaItem] = []
        var moved = 0
        func remember(_ item: MediaItem) {
            if !touched.contains(where: { $0.id == item.id }) { touched.append(item) }
        }

        for movie in items where movie.kind == .movie && !movie.isMetadataLocked {
            guard let path = movie.filePath else { continue }
            let parsed = FilenameParser.parse(url: URL(fileURLWithPath: path))
            guard parsed.isEpisode, let season = parsed.season, let number = parsed.episode else { continue }
            let key = FilenameParser.normalizedKey(parsed.title)
            let show = series[key] ?? {
                let created = MediaItem(kind: .series, name: parsed.title, year: parsed.year)
                context.insert(created)
                series[key] = created
                return created
            }()
            let episode = MediaEpisode(season: season, number: number, name: parsed.episodeTitle ?? "",
                                       filePath: path, fileBookmark: movie.fileBookmark, isPlayable: movie.isPlayable)
            episode.qualityBadges = movie.qualityBadges
            episode.playbackIssue = movie.playbackIssue
            episode.playbackIssueIsDamage = movie.playbackIssueIsDamage
            episode.show = show
            context.insert(episode)
            context.delete(movie)
            remember(show)
            moved += 1
        }

        for show in items where show.kind == .series && !show.isMetadataLocked {
            let episodes = Array(show.episodes)
            var remaining = episodes.count
            for episode in episodes {
                let parsed = FilenameParser.parse(url: URL(fileURLWithPath: episode.filePath))
                guard !parsed.isEpisode else { continue }
                let movie = MediaItem(kind: .movie, name: parsed.title, year: parsed.year)
                movie.filePath = episode.filePath
                movie.fileBookmark = episode.fileBookmark
                movie.isPlayable = episode.isPlayable
                movie.qualityBadges = episode.qualityBadges
                movie.playbackIssue = episode.playbackIssue
                movie.playbackIssueIsDamage = episode.playbackIssueIsDamage
                context.insert(movie)
                context.delete(episode)
                remember(movie)
                remaining -= 1
                moved += 1
            }
            if remaining == 0, !episodes.isEmpty {
                touched.removeAll { $0.id == show.id }
                context.delete(show)
            }
        }

        if moved > 0 {
            save()
            reload()
        }
        return (touched, moved)
    }

    /// Re-scans every remembered folder for new files.
    func rescanFolders() async {
        await scopeOpening?.value
        let saved = folders.map { (path: $0.path, bookmark: $0.bookmark) }
        var urls: [URL] = []
        for folder in saved {
            guard let bookmark = folder.bookmark else {
                urls.append(URL(fileURLWithPath: folder.path))
                continue
            }
            if let resolved = await Self.resolve(bookmark, startAccess: false) { urls.append(resolved.url) }
        }
        guard !urls.isEmpty else {
            notice = LibraryNotice(message: "Add a folder first, then it can be rescanned for new videos.")
            return
        }
        await importMedia(from: urls)
        for folder in folders where !Self.isGone(folder) { folder.lastScanned = .now }
        save()
    }

    func removeFolder(_ folder: LibraryFolder) {
        sessionScopes.removeValue(forKey: folder.path)?.stopAccessingSecurityScopedResource()
        context.delete(folder)
        save()
        reload()
        restartWatching()
    }

    // MARK: Watching folders

    private func restartWatching() {
        watcher = nil
        networkPoll?.cancel()
        let paths = ((try? context.fetch(FetchDescriptor<LibraryFolder>())) ?? []).map(\.path)
        watcher = FolderWatcher(paths: paths) { [weak self] changes in
            guard let self else { return }
            pendingChanges += changes
            Task { [weak self] in await self?.applyFolderChanges() }
        }
        // NAS shares and other network volumes: check every few minutes instead. Finding which
        // folders are on one touches the volumes, so it's done off the main actor.
        networkPoll = Task { [weak self] in
            let networkPaths = await Self.networkPaths(among: paths)
            guard !networkPaths.isEmpty else { return }
            while !Task.isCancelled {
                do {
                    // Held only while polling, so a library that's gone ends the loop.
                    guard let self else { return }
                    await self.pollNetworkFolders(networkPaths)
                }
                try? await Task.sleep(for: .seconds(300))
            }
        }
        // A drive or share that reconnects is checked straight away.
        if mountWatch == nil {
            mountWatch = Task { [weak self] in
                let mounts = NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didMountNotification)
                for await _ in mounts.map({ _ in () }) {
                    guard let self, !Task.isCancelled else { return }
                    self.restartWatching()
                }
            }
        }
    }

    /// Whether a folder lives on a network volume (SMB/AFP/NFS share, NAS).
    nonisolated static func isOnNetworkVolume(_ path: String) -> Bool {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsLocalKey])
        return values?.volumeIsLocal == false
    }

    @concurrent
    nonisolated private static func networkPaths(among paths: [String]) async -> [String] {
        paths.filter(isOnNetworkVolume)
    }

    /// Compares a network folder's videos with the library and reports the differences as
    /// changes, the same as FSEvents would.
    private func pollNetworkFolders(_ paths: [String]) async {
        let known = Set(files.values.map(\.path))
        let changes = await Self.networkChanges(in: paths, known: known)
        guard !changes.isEmpty, !Task.isCancelled else { return }
        pendingChanges += changes
        await applyFolderChanges()
    }

    /// Reads the folders (slow on a network share) off the main actor.
    @concurrent
    nonisolated private static func networkChanges(in paths: [String], known: Set<String>) async -> [FolderWatcher.Change] {
        let manager = FileManager.default
        var changes: [FolderWatcher.Change] = []
        for path in paths where manager.fileExists(atPath: path) {
            if Task.isCancelled { return [] }
            let found = videoFiles(in: URL(fileURLWithPath: path)).map(\.path)
            changes += found.filter { !known.contains($0) }.map { FolderWatcher.Change(path: $0, wasRemoved: false) }
            let prefix = path.hasSuffix("/") ? path : path + "/"
            changes += known.filter { $0.hasPrefix(prefix) && !manager.fileExists(atPath: $0) }
                .map { FolderWatcher.Change(path: $0, wasRemoved: true) }
        }
        return changes
    }

    // MARK: Approval

    /// Adds approved videos to the library.
    func approvePending(_ items: [PendingMedia]) async {
        await waitForFolderChanges()
        // Approved videos leave the waiting list only when they can be imported now.
        guard !isBusy else {
            notice = LibraryNotice(message: "Please wait for the current import to finish.")
            return
        }
        let items = items.filter { !Self.isGone($0) }
        let urls = items.map { URL(fileURLWithPath: $0.path) }
        for item in items { context.delete(item) }
        save()
        reload()
        await importMedia(from: urls)
    }

    /// Declines videos; they won't be offered again.
    func ignorePending(_ items: [PendingMedia]) {
        for item in items { item.isIgnored = true }
        save()
        reload()
    }

    /// Queues newly detected videos for the administrator's approval.
    private func queueForApproval(_ videos: [URL]) {
        let existing = Set(((try? context.fetch(FetchDescriptor<PendingMedia>())) ?? []).map(\.path))
        let new = videos.filter { !existing.contains($0.path) }
        guard !new.isEmpty else { return }
        for video in new { context.insert(PendingMedia(path: video.path)) }
        save()
        reload()
        notice = LibraryNotice(message: "\(new.count) new video\(new.count == 1 ? " is" : "s are") waiting for approval in Library.")
    }

    /// Imports new or changed videos and drops titles whose files were deleted. A missing
    /// folder (an unplugged drive) is left alone so its titles come back when it returns.
    private func applyFolderChanges() async {
        guard !isBusy, !isApplyingChanges, !pendingChanges.isEmpty else { return }
        isApplyingChanges = true
        let changes = pendingChanges
        pendingChanges = []

        // What changed is worked out off the main actor (it checks every affected file);
        // only the database updates happen here.
        let found = await Self.folderChangeSet(changes, references: Array(files.values), folderPaths: folders.map(\.path))
        // An import or info fetch that began meanwhile owns the library: hand these changes
        // back, to be worked out again once it ends (the files may have changed since).
        guard !isBusy else {
            pendingChanges = changes + pendingChanges
            isApplyingChanges = false
            return
        }
        var removedAny = false
        for reference in found.removed {
            if reference.isEpisode {
                let ownerID = reference.ownerID
                if let episode = try? context.fetch(FetchDescriptor<MediaEpisode>(predicate: #Predicate { $0.id == ownerID })).first {
                    let show = episode.show
                    context.delete(episode)
                    if let show, show.episodes.allSatisfy({ $0.id == ownerID }) { context.delete(show) }
                }
            } else if let item = item(for: reference.ownerID) {
                context.delete(item)
            }
            removedAny = true
        }
        if removedAny {
            save()
            reload()
        }

        // Files imported meanwhile aren't offered again.
        let known = Set(files.values.map(\.path))
        let videos = found.videos.filter { !known.contains($0.path) }
        if !videos.isEmpty {
            // Detected, not chosen: the administrator approves them first.
            queueForApproval(videos)
        }
        isApplyingChanges = false
        if !pendingChanges.isEmpty { await applyFolderChanges() }
    }

    /// Waits for a folder-change pass in progress to finish, so an import or info fetch
    /// doesn't start while it's working out what changed.
    private func waitForFolderChanges() async {
        while isApplyingChanges, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Whether a model was deleted (or its library reset) since it was fetched.
    private static func isGone(_ model: some PersistentModel) -> Bool {
        model.isDeleted || model.modelContext == nil
    }

    /// The library files a batch of changes removed (whose folder is still there, so it's not
    /// just an unplugged drive), and the new videos it added.
    @concurrent
    nonisolated private static func folderChangeSet(_ changes: [FolderWatcher.Change], references: [FileReference],
                                                     folderPaths: [String]) async -> (removed: [FileReference], videos: [URL]) {
        let manager = FileManager.default
        let removedPaths = Set(changes.filter { $0.wasRemoved && !manager.fileExists(atPath: $0.path) }.map(\.path))
        let presentFolders = folderPaths.filter { manager.fileExists(atPath: $0) }
        let removed = references.filter { reference in
            guard removedPaths.contains(reference.path) || removedPaths.contains(where: { reference.path.hasPrefix($0 + "/") })
            else { return false }
            let rootStillThere = presentFolders.contains { reference.path.hasPrefix($0 + "/") }
            return rootStillThere && !manager.fileExists(atPath: reference.path)
        }

        let known = Set(references.map(\.path))
        let added = Set(changes.filter { !$0.wasRemoved }.map(\.path)).filter { path in
            !known.contains(path) && manager.fileExists(atPath: path)
                && (FilenameParser.isVideoFile(URL(fileURLWithPath: path)) || isDirectory(URL(fileURLWithPath: path)))
        }
        // New subfolders contribute their videos; they aren't separate watched folders.
        let videos = added.sorted().flatMap { path -> [URL] in
            let url = URL(fileURLWithPath: path)
            return isDirectory(url) ? videoFiles(in: url).filter { !known.contains($0.path) } : [url]
        }
        return (removed, videos)
    }

    // MARK: Metadata

    /// Titles matched before ratings were kept for every country get them once, in the background.
    func fetchMissingCertifications() async {
        guard metadata.settings.isActive(.tmdb) else { return }
        let items = (try? context.fetch(FetchDescriptor<MediaItem>())) ?? []
        let missing = items.filter { $0.tmdbID != nil && $0.certifications.isEmpty && !$0.isMetadataLocked }.map(\.id)
        guard !missing.isEmpty else { return }
        await refreshMetadata(for: missing, force: true)
    }

    /// Fetches info for the given titles (or all). Without `force`, only titles that
    /// have never been matched are refreshed.
    /// Titles with a file (or, for shows, any episode) inside a library folder.
    func titleIDs(in folder: LibraryFolder) -> [String] {
        let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        let items = (try? context.fetch(FetchDescriptor<MediaItem>())) ?? []
        return items.filter { item in
            (item.filePath?.hasPrefix(prefix) ?? false) || item.episodes.contains { $0.filePath.hasPrefix(prefix) }
        }.map(\.id)
    }

    func refreshMetadata(for titleIDs: [String]? = nil, force: Bool) async {
        let all = (try? context.fetch(FetchDescriptor<MediaItem>())) ?? []
        let items = all.filter { item in
            (titleIDs?.contains(item.id) ?? true) && (force || item.status == .pending)
        }
        guard !items.isEmpty else { return }
        guard !metadata.settings.activeProviders.isEmpty else {
            notice = LibraryNotice(message: "Turn on a metadata source in Settings to fetch movie info.", isError: true)
            return
        }
        await waitForFolderChanges()
        guard !isBusy else { return }

        activity = LibraryActivity(message: "Fetching info…", total: items.count)
        var unmatched = 0
        for (index, item) in items.enumerated() {
            // Titles removed while info was being fetched are skipped.
            guard !Self.isGone(item) else { continue }
            activity?.message = "Fetching info for \(item.name)…"
            let query = Self.query(for: item)
            var merged: MergedMetadata?
            if force, let imdbID = item.imdbID {
                merged = await metadata.refresh(imdbID: imdbID, query: query)
            }
            if merged == nil {
                merged = await metadata.identify(query)
            }
            // The title may have been removed during the lookup.
            guard !Self.isGone(item) else { continue }
            if let merged {
                apply(merged, to: item)
            } else {
                item.status = .unmatched
                unmatched += 1
            }
            item.lastRefreshed = .now
            activity?.completed = index + 1
            // Shown straight away; saved in batches, and the library is rebuilt once at the end.
            if let position = titles.firstIndex(where: { $0.id == item.id }) {
                titles[position] = Self.makeTitle(from: item)
            }
            if (index + 1) % 25 == 0 { save() }
        }
        save()
        reload()
        activity = nil
        if unmatched > 0 {
            notice = LibraryNotice(message: "\(unmatched) title\(unmatched == 1 ? "" : "s") couldn't be identified. Use Fix Match to choose the right one.")
        }
    }

    /// Applies a search result the user picked in Fix Match.
    func applyMatch(_ candidate: MetadataCandidate, to titleID: String) async throws {
        guard let item = item(for: titleID) else { return }
        guard let merged = try await metadata.metadata(for: candidate, query: Self.query(for: item)),
              !Self.isGone(item) else { return }
        item.isMetadataLocked = false // An explicit match replaces previous edits.
        apply(merged, to: item)
        item.lastRefreshed = .now
        save()
        reload()
    }

    func applyEdits(_ edits: MetadataEdits, to titleID: String) {
        guard let item = item(for: titleID) else { return }
        item.name = edits.name.trimmingCharacters(in: .whitespaces).isEmpty ? item.name : edits.name
        item.year = edits.year
        item.tagline = edits.tagline
        item.synopsis = edits.synopsis
        item.maturity = edits.maturity
        item.genreNames = edits.genres.map(\.displayName)
        item.posterURLString = edits.posterURL.isEmpty ? nil : edits.posterURL
        item.backdropURLString = edits.backdropURL.isEmpty ? nil : edits.backdropURL
        item.isMetadataLocked = edits.isLocked
        if item.status == .unmatched { item.status = .matched }
        save()
        reload()
    }

    func remove(_ titleID: String) {
        guard let item = item(for: titleID) else { return }
        ExternalSubtitleLibrary.remove(playbackIDs: [item.id] + item.episodes.map(\.id))
        context.delete(item)
        save()
        reload()
    }

    /// A file that's gone while the drive it lived on is still connected (so it was moved or
    /// deleted, rather than sitting on an unplugged drive).
    func isFileMissing(_ playbackID: String) -> Bool {
        guard let path = files[playbackID]?.path, !FileManager.default.fileExists(atPath: path) else { return false }
        let components = URL(fileURLWithPath: path).pathComponents
        if components.count > 2, components[1] == "Volumes" {
            return FileManager.default.fileExists(atPath: "/Volumes/" + components[2])
        }
        return true
    }

    /// Removes one movie or episode by its playback ID; a show goes once it has no episodes left.
    func removePlayable(_ playbackID: String) {
        if let reference = files[playbackID], reference.isEpisode {
            let ownerID = reference.ownerID
            if let episode = try? context.fetch(FetchDescriptor<MediaEpisode>(predicate: #Predicate { $0.id == ownerID })).first {
                ExternalSubtitleLibrary.remove(playbackIDs: [playbackID])
                let show = episode.show
                context.delete(episode)
                if let show, show.episodes.allSatisfy({ $0.id == ownerID }) { context.delete(show) }
                save()
                reload()
            }
        } else {
            remove(playbackID)
        }
    }

    // MARK: Playback & Finder

    /// Resolves a file for playback and opens its security scope. Pair each call with one
    /// `endPlayback`. The bookmark is resolved off the main actor (a sleeping network drive
    /// can take a while to answer).
    func beginPlayback(_ playbackID: String) async -> URL? {
        guard let opened = await openFile(playbackID) else { return nil }
        if opened.scoped { playbackScopes[playbackID, default: []].append(opened.url) }
        return opened.url
    }

    /// Opens a file briefly (e.g. to read its tracks) without touching playback's own access.
    func withFileAccess<T>(_ playbackID: String, _ body: (URL) async -> T) async -> T? {
        guard let opened = await openFile(playbackID) else { return nil }
        defer { if opened.scoped { opened.url.stopAccessingSecurityScopedResource() } }
        return await body(opened.url)
    }

    /// Closes the access opened by one `beginPlayback`. Other users of the file keep theirs.
    func endPlayback(_ playbackID: String) {
        guard var scopes = playbackScopes[playbackID], !scopes.isEmpty else { return }
        scopes.removeLast().stopAccessingSecurityScopedResource()
        playbackScopes[playbackID] = scopes.isEmpty ? nil : scopes
    }

    /// Resolves a file and opens a scope of its own (`scoped`: the caller must close it).
    /// `nil` when the file can't be read.
    private func openFile(_ playbackID: String) async -> (url: URL, scoped: Bool)? {
        await scopeOpening?.value
        guard let reference = files[playbackID] else { return nil }
        if let bookmark = reference.bookmark, let resolved = await Self.resolve(bookmark, startAccess: true) {
            if let fresh = resolved.freshBookmark { refreshBookmark(for: reference, with: fresh) }
            if resolved.isReadable { return (resolved.url, resolved.didStartAccess) }
            if resolved.didStartAccess { resolved.url.stopAccessingSecurityScopedResource() }
            return nil
        }
        // No bookmark (or it no longer resolves): reachable only through an open folder scope.
        let url = URL(fileURLWithPath: reference.path)
        return await Self.isReadable(url) ? (url, false) : nil
    }

    /// A resolved security-scoped bookmark.
    nonisolated private struct ResolvedBookmark: @unchecked Sendable { // URL and Data are values.
        let url: URL
        /// Whether a scope was opened for the caller to close.
        let didStartAccess: Bool
        /// A replacement for a stale bookmark, when one could be made.
        let freshBookmark: Data?
        let isReadable: Bool
    }

    /// Resolves a bookmark off the main actor, optionally opening its scope.
    @concurrent
    nonisolated private static func resolve(_ bookmark: Data, startAccess: Bool) async -> ResolvedBookmark? {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil,
                                 bookmarkDataIsStale: &isStale) else { return nil }
        let started = url.startAccessingSecurityScopedResource()
        let fresh = isStale ? Self.bookmark(for: url) : nil
        let readable = FileManager.default.isReadableFile(atPath: url.path)
        if started, !startAccess { url.stopAccessingSecurityScopedResource() }
        return ResolvedBookmark(url: url, didStartAccess: started && startAccess, freshBookmark: fresh, isReadable: readable)
    }

    @concurrent
    nonisolated private static func isReadable(_ url: URL) async -> Bool {
        FileManager.default.isReadableFile(atPath: url.path)
    }

    /// Moves a title's video files (every episode, for a show) to the Trash and removes the
    /// title. Returns how many files couldn't be moved.
    @discardableResult
    func moveToTrash(_ titleID: String) -> Int {
        guard let item = item(for: titleID) else { return 0 }
        let ids = item.kind == .movie ? [item.id] : item.episodes.map(\.id)
        var failures = 0
        for id in ids {
            // A scope of its own: an open player's access to the same file is left alone.
            guard let opened = openFileNow(id) else { failures += 1; continue }
            do { try FileManager.default.trashItem(at: opened.url, resultingItemURL: nil) } catch { failures += 1 }
            if opened.scoped { opened.url.stopAccessingSecurityScopedResource() }
        }
        remove(titleID)
        if failures > 0 {
            notice = LibraryNotice(message: "\(failures) file\(failures == 1 ? "" : "s") couldn't be moved to the Trash. The title was removed from your library.", isError: true)
        }
        return failures
    }

    func revealInFinder(_ playbackID: String) {
        Task {
            // Its own scope, so a player showing the same file keeps its access.
            guard let opened = await openFile(playbackID) else {
                notice = LibraryNotice(message: "The file couldn't be found. It may have been moved or its drive disconnected.", isError: true)
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([opened.url])
            if opened.scoped { opened.url.stopAccessingSecurityScopedResource() }
        }
    }

    /// `openFile` for the Trash, which runs straight after the administrator confirms.
    private func openFileNow(_ playbackID: String) -> (url: URL, scoped: Bool)? {
        guard let reference = files[playbackID] else { return nil }
        if let bookmark = reference.bookmark {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil,
                                  bookmarkDataIsStale: &isStale) {
                let scoped = url.startAccessingSecurityScopedResource()
                if FileManager.default.isReadableFile(atPath: url.path) { return (url, scoped) }
                if scoped { url.stopAccessingSecurityScopedResource() }
                return nil
            }
        }
        let url = URL(fileURLWithPath: reference.path)
        return FileManager.default.isReadableFile(atPath: url.path) ? (url, false) : nil
    }

    // MARK: Private

    private func apply(_ merged: MergedMetadata, to item: MediaItem) {
        let record = merged.record
        if !item.isMetadataLocked {
            item.name = record.title ?? item.name
            item.year = record.year ?? item.year
            item.synopsis = record.synopsis ?? item.synopsis
            item.tagline = record.tagline ?? item.tagline
            item.maturity = record.maturity ?? item.maturity
            if !record.certifications.isEmpty { item.certifications = record.certifications }
            item.runtimeMinutes = record.runtimeMinutes ?? item.runtimeMinutes
            if !record.genres.isEmpty { item.genreNames = record.genres }
            if !record.cast.isEmpty { item.cast = record.cast }
            item.director = record.director ?? item.director
            if !record.writers.isEmpty { item.writers = record.writers }
            if !record.studios.isEmpty { item.studios = record.studios }
            item.collection = record.collection ?? item.collection
            // Web addresses only: a local file as artwork comes only from the user's own edits.
            item.posterURLString = ArtworkCache.webArtworkURL(record.posterURL)?.absoluteString ?? item.posterURLString
            item.backdropURLString = ArtworkCache.webArtworkURL(record.backdropURL)?.absoluteString ?? item.backdropURLString
        }
        item.ratings = record.ratings
        item.trailer = record.trailer ?? item.trailer
        item.tmdbID = record.tmdbID
        item.imdbID = record.imdbID
        item.tvmazeID = record.tvmazeID
        item.wikipediaKey = record.wikipediaKey
        item.metadataSources = merged.sources.map(\.displayName)
        item.status = .matched

        for episode in item.episodes {
            guard let match = record.episodes.first(where: { $0.season == episode.season && $0.number == episode.number }) else {
                continue
            }
            if !item.isMetadataLocked || episode.name.isEmpty {
                episode.name = match.name ?? episode.name
                episode.synopsis = match.synopsis ?? episode.synopsis
            }
            episode.runtimeMinutes = match.runtimeMinutes ?? episode.runtimeMinutes
            episode.stillURLString = ArtworkCache.webArtworkURL(match.stillURL)?.absoluteString ?? episode.stillURLString
        }
    }

    private static func query(for item: MediaItem) -> MetadataQuery {
        MetadataQuery(title: item.name, year: item.year, kind: item.kind,
                      seasons: Array(Set(item.episodes.map(\.season))).sorted())
    }

    private func save() {
        do {
            try context.save()
        } catch {
            notice = LibraryNotice(message: "Couldn't save the library: \(error.localizedDescription)", isError: true)
        }
    }

    private func rememberFolder(_ url: URL, bookmark: Data?) {
        guard !folders.contains(where: { $0.path == url.path }) else { return }
        context.insert(LibraryFolder(path: url.path, bookmark: bookmark))
        save()
        restartWatching()
    }

    /// Re-opens saved folder scopes at launch so files without their own bookmark stay playable.
    /// The bookmarks are resolved off the main actor.
    private func openFolderScopes() async {
        let saved = ((try? context.fetch(FetchDescriptor<LibraryFolder>())) ?? []).compactMap { folder in
            folder.bookmark.map { (path: folder.path, bookmark: $0) }
        }
        var refreshed = false
        for folder in saved {
            if Task.isCancelled { return }
            guard let resolved = await Self.resolve(folder.bookmark, startAccess: true) else { continue }
            if resolved.didStartAccess {
                if sessionScopes[resolved.url.path] == nil {
                    sessionScopes[resolved.url.path] = resolved.url
                } else {
                    resolved.url.stopAccessingSecurityScopedResource() // Opened meanwhile by an import.
                }
            }
            // Fetched again: the folder may have been removed while its bookmark resolved.
            let path = folder.path
            if let fresh = resolved.freshBookmark,
               let current = try? context.fetch(FetchDescriptor<LibraryFolder>(predicate: #Predicate { $0.path == path })).first {
                current.bookmark = fresh
                refreshed = true
            }
        }
        if refreshed { save() }
    }

    /// Opens a folder's or file's security scope for the rest of the session, once per path.
    private func openSessionScope(_ url: URL) {
        guard sessionScopes[url.path] == nil, url.startAccessingSecurityScopedResource() else { return }
        sessionScopes[url.path] = url
    }

    private func refreshBookmark(for reference: FileReference, with fresh: Data) {
        let ownerID = reference.ownerID
        if reference.isEpisode {
            let episode = try? context.fetch(FetchDescriptor<MediaEpisode>(predicate: #Predicate { $0.id == ownerID })).first
            episode?.fileBookmark = fresh
        } else {
            item(for: ownerID)?.fileBookmark = fresh
        }
        save()
    }

    /// Warms the artwork cache: every poster first, then the newest titles' backdrops, then
    /// the rest of the wide art, so screens draw their images immediately.
    private func prefetchArtwork() {
        var requests = titles.compactMap { title in title.posterURL.map { ($0, ArtworkCache.Size.poster) } }
        requests += titles.prefix(12).compactMap { title in title.backdropURL.map { ($0, ArtworkCache.Size.backdrop) } }
        requests += titles.compactMap { title in title.backdropURL.map { ($0, ArtworkCache.Size.wide) } }
        ArtworkCache.shared.prefetch(requests)
    }

    // MARK: Repair

    /// Playback IDs of healthy MP4/MOV files that could lend a damaged file their setup.
    func repairCandidates(excluding playbackID: String) -> [String] {
        let damagedFolder = files[playbackID].map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path }
        let candidates = files.filter { id, reference in
            id != playbackID && ["mp4", "m4v", "mov"].contains(URL(fileURLWithPath: reference.path).pathExtension.lowercased())
        }
        // Files from the same folder (often the same source) first.
        return candidates.sorted { a, b in
            let aNear = URL(fileURLWithPath: a.value.path).deletingLastPathComponent().path == damagedFolder
            let bNear = URL(fileURLWithPath: b.value.path).deletingLastPathComponent().path == damagedFolder
            return aNear != bNear ? aNear : a.value.path < b.value.path
        }.map(\.key)
    }

    /// Points a title or episode at a different file (such as a repaired copy) and re-checks it.
    func replaceFile(_ playbackID: String, with url: URL) async {
        guard let reference = files[playbackID] else { return }
        let ownerID = reference.ownerID
        let bookmark = Self.bookmark(for: url)
        let inspection = await Self.inspect(url)
        if reference.isEpisode {
            if let episode = try? context.fetch(FetchDescriptor<MediaEpisode>(predicate: #Predicate { $0.id == ownerID })).first {
                episode.filePath = url.path
                episode.fileBookmark = bookmark
                episode.isPlayable = inspection.isPlayable
                episode.qualityBadges = inspection.badges.map(\.rawValue)
                episode.playbackIssue = inspection.issue?.message
                episode.playbackIssueIsDamage = inspection.issue?.isDamage ?? false
            }
        } else if let item = item(for: ownerID) {
            item.filePath = url.path
            item.fileBookmark = bookmark
            item.isPlayable = inspection.isPlayable
            item.qualityBadges = inspection.badges.map(\.rawValue)
            item.playbackIssue = inspection.issue?.message
            item.playbackIssueIsDamage = inspection.issue?.isDamage ?? false
        }
        save()
        reload()
    }

    nonisolated private static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                              includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    @concurrent
    nonisolated private static func makeBookmark(for url: URL) async -> Data? {
        bookmark(for: url)
    }

    /// Sorts chosen items into folders (with their bookmarks) and the videos found in them,
    /// scanning folders recursively, off the main actor.
    @concurrent
    nonisolated private static func scan(_ urls: [URL]) async -> (folders: [(URL, Data?)], videos: [URL]) {
        var folders: [(URL, Data?)] = []
        var videos: [URL] = []
        for url in urls {
            if isDirectory(url) {
                folders.append((url, bookmark(for: url)))
                videos += videoFiles(in: url)
            } else if FilenameParser.isVideoFile(url) {
                videos.append(url)
            }
        }
        return (folders, videos)
    }

    nonisolated private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    nonisolated private static func videoFiles(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var found: [URL] = []
        for case let url as URL in enumerator where FilenameParser.isVideoFile(url) {
            found.append(url)
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Whether the Theater engine can play the file (its container and video codec are
    /// supported) and why not, plus resolution and HDR badges read from the video track.
    static func inspect(_ url: URL) async -> (isPlayable: Bool, badges: [QualityBadge], issue: PlaybackIssue?) {
        let opened: Result<ContainerTrack?, Error> = await Task.detached {
            Result { try Demuxers.open(url).tracks.first { $0.kind == .video } }
        }.value
        let video: ContainerTrack
        switch opened {
        case .failure(let error):
            let isDamage: Bool = if case ContainerError.unrecognizedFormat = error { false } else { true }
            return (false, [], PlaybackIssue(message: error.localizedDescription, isDamage: isDamage))
        case .success(nil):
            return (false, [], PlaybackIssue(message: "This file has no video track.", isDamage: false))
        case .success(let track?):
            video = track
        }
        guard video.codec.isSupported else {
            return (false, [], PlaybackIssue(message: "This file uses \(video.codec.displayName) video, which Ultimate Theater can't decode yet.",
                                             isDamage: false))
        }
        let width = video.width ?? 0
        let height = video.height ?? 0
        var badges: [QualityBadge] = []
        if width >= 3200 || height >= 1800 {
            badges.append(.uhd)
        } else if width >= 1260 || height >= 700 {
            badges.append(.hd)
        }
        switch video.hdr {
        case .dolbyVision: badges.append(.dolbyVision)
        case .hdr10, .hlg: badges.append(.hdr)
        case nil: break
        }
        return (true, badges, nil)
    }

    /// Bumped whenever playback support changes, so the library is re-probed once.
    private static let probeVersion = 3
    private static let probeVersionKey = "library.probeVersion"

    /// Re-checks every file against the current engine after an engine upgrade. Files that
    /// can't be reached right now (e.g. a disconnected drive) keep their previous status.
    func reprobeIfNeeded() async {
        guard UserDefaults.standard.integer(forKey: Self.probeVersionKey) < Self.probeVersion else { return }
        let items = (try? context.fetch(FetchDescriptor<MediaItem>())) ?? []
        var unreachable = false
        for item in items {
            if Self.isGone(item) { continue }
            if item.filePath != nil {
                if let result = await withFileAccess(item.id, { await Self.inspect($0) }), !Self.isGone(item) {
                    item.isPlayable = result.isPlayable
                    item.qualityBadges = result.badges.map(\.rawValue)
                    item.playbackIssue = result.issue?.message
                    item.playbackIssueIsDamage = result.issue?.isDamage ?? false
                } else {
                    unreachable = true
                }
            }
            for episode in Self.isGone(item) ? [] : item.episodes {
                if let result = await withFileAccess(episode.id, { await Self.inspect($0) }), !Self.isGone(episode) {
                    episode.isPlayable = result.isPlayable
                    episode.qualityBadges = result.badges.map(\.rawValue)
                    episode.playbackIssue = result.issue?.message
                    episode.playbackIssueIsDamage = result.issue?.isDamage ?? false
                } else {
                    unreachable = true
                }
            }
        }
        save()
        reload()
        // Try again next launch if some files were offline.
        if !unreachable { UserDefaults.standard.set(Self.probeVersion, forKey: Self.probeVersionKey) }
    }

    // MARK: Skip Intro & Credits

    /// Finds the intro and credits of an episode that's starting to play, and of the episode
    /// after it, in the background. Results are saved and published in `skipSegments`.
    func analyzeSkipSegments(startingWith episodeID: String) {
        guard let episode = mediaEpisode(episodeID), let show = episode.show else { return }
        let season = show.sortedEpisodes.filter { $0.season == episode.season }
        guard let index = season.firstIndex(where: { $0.id == episodeID }) else { return }
        let wanted = season[index...].prefix(2)
            .filter { $0.isPlayable && $0.skipAnalysisVersion < SkipSegmentDetector.version }
            .map(\.id)
        skipQueue.removeAll { wanted.contains($0) }
        skipQueue.insert(contentsOf: wanted, at: 0)
        startSkipWorker()
    }

    private func startSkipWorker() {
        guard skipWorker == nil, !skipQueue.isEmpty else { return }
        skipWorker = Task(priority: .background) { [weak self] in
            // Let playback (or a fresh import) get going before reading files alongside it.
            try? await Task.sleep(for: .seconds(5))
            while let self, !Task.isCancelled, !self.skipQueue.isEmpty {
                await self.analyzeSkipSegments(of: self.skipQueue.removeFirst())
            }
            // A reset cancels this worker and may already have started another.
            if !Task.isCancelled { self?.skipWorker = nil }
        }
    }

    /// Queues every not-yet-analysed episode of newly added shows, season by season in episode
    /// order (so each neighbour's fingerprint is still cached when the next episode needs it).
    /// Runs behind anything that's playing, which goes to the front of the queue.
    func analyzeSkipSegments(forShows shows: [MediaItem]) {
        let wanted = shows.filter { $0.kind == .series }
            .flatMap(\.sortedEpisodes)
            .filter { $0.isPlayable && $0.skipAnalysisVersion < SkipSegmentDetector.version }
            .map(\.id)
            .filter { !skipQueue.contains($0) }
        guard !wanted.isEmpty else { return }
        skipQueue.append(contentsOf: wanted)
        startSkipWorker()
    }

    /// Stops analysis and forgets cached fingerprints (for a library reset).
    func cancelSkipAnalysis() {
        skipWorker?.cancel()
        skipWorker = nil
        skipQueue = []
        Task { await EpisodeAudioPrintCache.shared.removeAll() }
    }

    /// Chapter names first; otherwise the episode's audio is matched against the episodes
    /// before and after it. Files that can't be reached are left for another time.
    private func analyzeSkipSegments(of episodeID: String) async {
        guard let episode = mediaEpisode(episodeID), episode.skipAnalysisVersion < SkipSegmentDetector.version,
              let show = episode.show else { return }
        guard var result = await withFileAccess(episodeID, { url in
            await Task.detached(priority: .background) { SkipSegmentDetector.chapterSegments(in: url) }.value
        }) else { return }

        if !result.isComplete {
            // Neighbours in the same season; across seasons only when it has no others.
            let playable = show.sortedEpisodes.filter { $0.isPlayable || $0.id == episodeID }
            var siblings = playable.filter { $0.season == episode.season }
            if siblings.count < 2 { siblings = playable.filter { $0.season != 0 || $0.id == episodeID } }
            guard let index = siblings.firstIndex(where: { $0.id == episodeID }) else { return }
            let neighbourIDs = [index - 1, index + 1].filter { siblings.indices.contains($0) }.map { siblings[$0].id }

            guard let target = await audioPrint(episodeID) else { return }
            var neighbours: [EpisodeAudioPrint] = []
            for id in neighbourIDs {
                if Task.isCancelled { return }
                if let print = await audioPrint(id) { neighbours.append(print) }
            }
            // Try again later if the neighbours are offline (an only episode has none to compare).
            guard !neighbours.isEmpty || neighbourIDs.isEmpty else { return }
            let detected = await Task.detached(priority: .background) {
                SkipSegmentDetector.detect(target: target, neighbours: neighbours)
            }.value
            result = result.filling(from: detected)
        }

        // The episode may have been removed (or the library reset) meanwhile.
        guard !Task.isCancelled, let episode = mediaEpisode(episodeID) else { return }
        episode.introStart = result.introStart
        episode.introEnd = result.introEnd
        episode.creditsStart = result.creditsStart
        episode.skipAnalysisVersion = SkipSegmentDetector.version
        save()
        skipSegments[episodeID] = result.isEmpty ? nil : result
    }

    private func audioPrint(_ episodeID: String) async -> EpisodeAudioPrint? {
        await withFileAccess(episodeID) { url in await EpisodeAudioPrintCache.shared.print(for: url) } ?? nil
    }

    private func mediaEpisode(_ id: String) -> MediaEpisode? {
        try? context.fetch(FetchDescriptor<MediaEpisode>(predicate: #Predicate { $0.id == id })).first
    }

    // MARK: Title building

    private static func makeTitle(from item: MediaItem) -> Title {
        let genres = Genre.from(providerNames: item.genreNames)
        let episodes = item.sortedEpisodes.map { episode in
            Episode(
                id: episode.id,
                titleID: item.id,
                season: episode.season,
                number: episode.number,
                name: episode.name.isEmpty ? "Episode \(episode.number)" : episode.name,
                synopsis: episode.synopsis,
                runtimeMinutes: episode.runtimeMinutes,
                stillURL: episode.stillURLString.flatMap(URL.init(string:)),
                isPlayable: episode.isPlayable,
                fileFormat: URL(fileURLWithPath: episode.filePath).pathExtension.uppercased(),
                playbackIssue: PlaybackIssue(message: episode.playbackIssue, isDamage: episode.playbackIssueIsDamage)
            )
        }
        let seasons = Dictionary(grouping: episodes, by: \.season)
            .map { Season(number: $0.key, episodes: $0.value) }
            .sorted { ($0.number == 0 ? Int.max : $0.number) < ($1.number == 0 ? Int.max : $1.number) }

        let badgeNames = item.kind == .movie ? item.qualityBadges : (item.episodes.first?.qualityBadges ?? [])
        let fileFormat = item.kind == .movie
            ? URL(fileURLWithPath: item.filePath ?? "").pathExtension.uppercased()
            : episodes.first?.fileFormat ?? ""

        return Title(
            id: item.id,
            name: item.name,
            kind: item.kind,
            tagline: item.tagline,
            synopsis: item.synopsis,
            year: item.year,
            maturity: item.maturity,
            runtimeMinutes: item.runtimeMinutes,
            genres: genres,
            cast: item.cast,
            director: item.director,
            writers: item.writers,
            studios: item.studios,
            badges: badgeNames.compactMap(QualityBadge.init(rawValue:)),
            artwork: fallbackArtwork(name: item.name, kind: item.kind, genre: genres.first),
            posterURL: item.posterURLString.flatMap(URL.init(string:)),
            backdropURL: item.backdropURLString.flatMap(URL.init(string:)),
            ratings: item.ratings,
            metadataSources: item.metadataSources,
            needsMatch: item.status == .unmatched,
            isPlayable: item.kind == .movie ? item.isPlayable : episodes.contains(where: \.isPlayable),
            fileFormat: fileFormat,
            dateAdded: item.dateAdded,
            seasons: seasons,
            trailer: item.trailer,
            collection: item.kind == .movie ? item.collection : nil,
            tmdbID: item.tmdbID,
            certifications: item.certifications,
            playbackIssue: item.kind == .movie
                ? PlaybackIssue(message: item.playbackIssue, isDamage: item.playbackIssueIsDamage)
                : episodes.first { !$0.isPlayable }?.playbackIssue
        )
    }

    /// Deterministic generated art based on the genre (or name) for titles without images.
    private static func fallbackArtwork(name: String, kind: TitleKind, genre: Genre?) -> Artwork {
        let seed = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let base = genre ?? Genre.allCases[seed % Genre.allCases.count]
        return Artwork(
            colors: base.colors + [Color(hex: 0x05050A)],
            symbol: genre?.systemImage ?? (kind == .movie ? "film" : "tv")
        )
    }
}
