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
    private(set) var activity: LibraryActivity?
    var notice: LibraryNotice?

    var isBusy: Bool { activity != nil }

    private static let watchFoldersKey = "library.watchFolders"

    /// Adds new videos from watched folders automatically (and removes deleted ones).
    var watchesFolders: Bool = UserDefaults.standard.object(forKey: MediaLibrary.watchFoldersKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(watchesFolders, forKey: Self.watchFoldersKey)
            restartWatching()
        }
    }

    private var watcher: FolderWatcher?
    private var pendingChanges: [FolderWatcher.Change] = []

    /// Playback ID → where its file lives.
    private var files: [String: FileReference] = [:]
    /// Security scopes opened for playback, closed when playback ends.
    private var playbackScopes: [String: URL] = [:]
    /// Folder scopes kept open for the session so files inside stay reachable.
    private var sessionScopes: [URL] = []

    private struct FileReference {
        let path: String
        let bookmark: Data?
        let ownerID: String
        let isEpisode: Bool
    }

    init(container: ModelContainer, metadata: MetadataService) {
        self.container = container
        self.context = container.mainContext
        self.metadata = metadata
        openFolderScopes()
        reload()
        restartWatching()
    }

    // MARK: Reading

    func reload() {
        let items = (try? context.fetch(FetchDescriptor<MediaItem>(sortBy: [SortDescriptor(\.dateAdded, order: .reverse)]))) ?? []
        folders = (try? context.fetch(FetchDescriptor<LibraryFolder>(sortBy: [SortDescriptor(\.path)]))) ?? []

        var references: [String: FileReference] = [:]
        for item in items {
            if let path = item.filePath {
                references[item.id] = FileReference(path: path, bookmark: item.fileBookmark, ownerID: item.id, isEpisode: false)
            }
            for episode in item.episodes {
                references[episode.id] = FileReference(path: episode.filePath, bookmark: episode.fileBookmark,
                                                       ownerID: episode.id, isEpisode: true)
            }
        }
        files = references
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
        guard !isBusy else {
            notice = LibraryNotice(message: "Please wait for the current import to finish.")
            return
        }
        activity = LibraryActivity(message: "Scanning for videos…")

        var discovered: [URL] = []
        for url in urls {
            // Keep access for this session; bookmarks restore it on later launches.
            if url.startAccessingSecurityScopedResource() {
                sessionScopes.append(url)
            }
            if Self.isDirectory(url) {
                rememberFolder(url)
                discovered += Self.videoFiles(in: url)
            } else if FilenameParser.isVideoFile(url) {
                discovered.append(url)
            }
        }

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
            let bookmark = Self.bookmark(for: file)
            let inspection = await Self.inspect(file)

            if parsed.isEpisode, let season = parsed.season, let number = parsed.episode {
                let key = FilenameParser.normalizedKey(parsed.title)
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
        let urls = folders.compactMap { folder -> URL? in
            guard let bookmark = folder.bookmark else { return URL(fileURLWithPath: folder.path) }
            var isStale = false
            return try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil,
                            bookmarkDataIsStale: &isStale)
        }
        guard !urls.isEmpty else {
            notice = LibraryNotice(message: "Add a folder first, then it can be rescanned for new videos.")
            return
        }
        await importMedia(from: urls)
        for folder in folders { folder.lastScanned = .now }
        save()
    }

    func removeFolder(_ folder: LibraryFolder) {
        context.delete(folder)
        save()
        reload()
        restartWatching()
    }

    // MARK: Watching folders

    private func restartWatching() {
        watcher = nil
        guard watchesFolders else { return }
        let paths = ((try? context.fetch(FetchDescriptor<LibraryFolder>())) ?? []).map(\.path)
        watcher = FolderWatcher(paths: paths) { [weak self] changes in
            self?.pendingChanges += changes
            Task { await self?.applyFolderChanges() }
        }
    }

    /// Imports new or changed videos and drops titles whose files were deleted. A missing
    /// folder (an unplugged drive) is left alone so its titles come back when it returns.
    private func applyFolderChanges() async {
        guard !isBusy, !pendingChanges.isEmpty else { return }
        let changes = pendingChanges
        pendingChanges = []
        let manager = FileManager.default

        let removed = Set(changes.filter { $0.wasRemoved && !manager.fileExists(atPath: $0.path) }.map(\.path))
        var removedAny = false
        for reference in files.values where removed.contains(reference.path) || removed.contains(where: { reference.path.hasPrefix($0 + "/") }) {
            let rootStillThere = folders.contains { reference.path.hasPrefix($0.path + "/") && manager.fileExists(atPath: $0.path) }
            guard rootStillThere, !manager.fileExists(atPath: reference.path) else { continue }
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

        let known = Set(files.values.map(\.path))
        let added = Set(changes.filter { !$0.wasRemoved }.map(\.path)).filter { path in
            !known.contains(path) && manager.fileExists(atPath: path)
                && (FilenameParser.isVideoFile(URL(fileURLWithPath: path)) || Self.isDirectory(URL(fileURLWithPath: path)))
        }
        // New subfolders contribute their videos; they aren't separate watched folders.
        let videos = added.sorted().flatMap { path -> [URL] in
            let url = URL(fileURLWithPath: path)
            return Self.isDirectory(url) ? Self.videoFiles(in: url).filter { !known.contains($0.path) } : [url]
        }
        if !videos.isEmpty {
            await importMedia(from: videos)
        }
        if !pendingChanges.isEmpty { await applyFolderChanges() }
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
        guard !isBusy else { return }

        activity = LibraryActivity(message: "Fetching info…", total: items.count)
        var unmatched = 0
        for (index, item) in items.enumerated() {
            activity?.message = "Fetching info for \(item.name)…"
            let query = Self.query(for: item)
            var merged: MergedMetadata?
            if force, let imdbID = item.imdbID {
                merged = await metadata.refresh(imdbID: imdbID, query: query)
            }
            if merged == nil {
                merged = await metadata.identify(query)
            }
            if let merged {
                apply(merged, to: item)
            } else {
                item.status = .unmatched
                unmatched += 1
            }
            item.lastRefreshed = .now
            activity?.completed = index + 1
            save()
            reload()
        }
        activity = nil
        if unmatched > 0 {
            notice = LibraryNotice(message: "\(unmatched) title\(unmatched == 1 ? "" : "s") couldn't be identified. Use Fix Match to choose the right one.")
        }
    }

    /// Applies a search result the user picked in Fix Match.
    func applyMatch(_ candidate: MetadataCandidate, to titleID: String) async throws {
        guard let item = item(for: titleID) else { return }
        guard let merged = try await metadata.metadata(for: candidate, query: Self.query(for: item)) else { return }
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
        context.delete(item)
        save()
        reload()
    }

    // MARK: Playback & Finder

    /// Resolves a file for playback and opens its security scope. Pair with `endPlayback`.
    func beginPlayback(_ playbackID: String) -> URL? {
        guard let reference = files[playbackID] else { return nil }
        if let bookmark = reference.bookmark {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil,
                                  bookmarkDataIsStale: &isStale) {
                if url.startAccessingSecurityScopedResource() {
                    playbackScopes[playbackID] = url
                }
                if isStale { refreshBookmark(for: reference, url: url) }
                return url
            }
        }
        // No bookmark: reachable only through an open folder scope.
        return FileManager.default.isReadableFile(atPath: reference.path) ? URL(fileURLWithPath: reference.path) : nil
    }

    /// Opens a file briefly (e.g. to read its tracks) without touching playback's own access.
    func withFileAccess<T>(_ playbackID: String, _ body: (URL) async -> T) async -> T? {
        guard let reference = files[playbackID] else { return nil }
        var url = URL(fileURLWithPath: reference.path)
        var scoped = false
        if let bookmark = reference.bookmark {
            var isStale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil,
                                       bookmarkDataIsStale: &isStale) {
                url = resolved
                scoped = url.startAccessingSecurityScopedResource()
            }
        }
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return await body(url)
    }

    func endPlayback(_ playbackID: String) {
        playbackScopes.removeValue(forKey: playbackID)?.stopAccessingSecurityScopedResource()
    }

    func revealInFinder(_ playbackID: String) {
        guard let url = beginPlayback(playbackID) else {
            notice = LibraryNotice(message: "The file couldn't be found. It may have been moved or its drive disconnected.", isError: true)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        endPlayback(playbackID)
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
            item.posterURLString = record.posterURL?.absoluteString ?? item.posterURLString
            item.backdropURLString = record.backdropURL?.absoluteString ?? item.backdropURLString
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
            episode.stillURLString = match.stillURL?.absoluteString ?? episode.stillURLString
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

    private func rememberFolder(_ url: URL) {
        guard !folders.contains(where: { $0.path == url.path }) else { return }
        context.insert(LibraryFolder(path: url.path, bookmark: Self.bookmark(for: url)))
        save()
        restartWatching()
    }

    /// Re-opens saved folder scopes at launch so files without their own bookmark stay playable.
    private func openFolderScopes() {
        let saved = (try? context.fetch(FetchDescriptor<LibraryFolder>())) ?? []
        for folder in saved {
            guard let bookmark = folder.bookmark else { continue }
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil,
                                     bookmarkDataIsStale: &isStale) else { continue }
            if url.startAccessingSecurityScopedResource() {
                sessionScopes.append(url)
            }
            if isStale { folder.bookmark = Self.bookmark(for: url) }
        }
    }

    private func refreshBookmark(for reference: FileReference, url: URL) {
        let ownerID = reference.ownerID
        let fresh = Self.bookmark(for: url)
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

    private static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                              includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private static func videoFiles(in folder: URL) -> [URL] {
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
            if item.filePath != nil {
                if let result = await withFileAccess(item.id, { await Self.inspect($0) }) {
                    item.isPlayable = result.isPlayable
                    item.qualityBadges = result.badges.map(\.rawValue)
                    item.playbackIssue = result.issue?.message
                    item.playbackIssueIsDamage = result.issue?.isDamage ?? false
                } else {
                    unreachable = true
                }
            }
            for episode in item.episodes {
                if let result = await withFileAccess(episode.id, { await Self.inspect($0) }) {
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
