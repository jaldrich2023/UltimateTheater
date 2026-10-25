//
//  LibraryStore.swift
//  Ultimate Theater
//
//  Where the app's data lives, as two SQLite databases in Application Support:
//
//   • Library.sqlite: the master library (titles, episodes, watched folders).
//   • Users.sqlite: the household (profiles, watch progress, My List, ratings).
//
//  Keeping them apart means the library can be rebuilt or shared without touching
//  anyone's history, and the other way around.
//

import Foundation
import SwiftData
import CoreData
import SQLite3

/// The master library's models, version 1: exactly the models Library.sqlite holds today,
/// so existing databases open unchanged. Later model changes add a version and a stage.
enum LibrarySchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [MediaItem.self, MediaEpisode.self, LibraryFolder.self, PendingMedia.self]
    }
}

/// The household's models, version 1: exactly what Users.sqlite holds today.
enum UsersSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [StoredProfile.self, WatchProgress.self, MyListEntry.self, UserRating.self, SceneBookmark.self]
    }
}

/// Library.sqlite's versions, oldest first. No stages yet: there's only one version.
enum LibraryMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [LibrarySchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

/// Users.sqlite's versions, oldest first.
enum UsersMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [UsersSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

enum LibraryStore {
    static let librarySchema = Schema(versionedSchema: LibrarySchemaV1.self)
    static let usersSchema = Schema(versionedSchema: UsersSchemaV1.self)
    /// The models of a library database from before the split: the library's own plus the
    /// household's, which were carried to Users.sqlite. (Every library model is included, so
    /// reading the old file never drops one of its tables.)
    static let schema = Schema([
        MediaItem.self, MediaEpisode.self, LibraryFolder.self, PendingMedia.self,
        StoredProfile.self, WatchProgress.self, MyListEntry.self, UserRating.self,
    ])

    /// Which database couldn't be opened, so recovery can move aside only that one.
    enum StoreOpenError: LocalizedError {
        case libraryFailed(any Error)
        case usersFailed(any Error)

        var libraryFailed: Bool { if case .libraryFailed = self { true } else { false } }
        var usersFailed: Bool { if case .usersFailed = self { true } else { false } }

        var underlying: any Error {
            switch self {
            case .libraryFailed(let error), .usersFailed(let error): error
            }
        }

        var errorDescription: String? { underlying.localizedDescription }
    }

    /// A database holds data this build doesn't know (written by a newer version of the
    /// app). It's left untouched rather than opened, since opening it would remove that data.
    struct UnknownDataError: LocalizedError, Equatable {
        let entities: [String]

        var errorDescription: String? {
            "It holds data from a newer version of Ultimate Theater (\(entities.joined(separator: ", "))). "
                + "Open it with that version, or move it aside to start fresh."
        }
    }

    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Ultimate Theater", directoryHint: .isDirectory)
    }

    /// The master library database.
    static var databaseURL: URL {
        directory.appending(path: "Library.sqlite")
    }

    /// The user database.
    static var usersDatabaseURL: URL {
        directory.appending(path: "Users.sqlite")
    }

    /// SQLite keeps recent changes in companion journal files beside each database.
    private static let companionSuffixes = ["", "-wal", "-shm"]

    /// Opens both databases: each container holds only its own models, so each file
    /// contains only its own tables.
    /// Throws a `StoreOpenError` saying which database failed.
    static func makeContainers() throws -> (library: ModelContainer, users: ModelContainer) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw StoreOpenError.libraryFailed(error)
        }
        moveEarlierStore()
        let carried: UserData?
        do { carried = try carryOverUserData() } catch { throw StoreOpenError.libraryFailed(error) }
        let users: ModelContainer
        do {
            users = try open(usersSchema, plan: UsersMigrationPlan.self,
                             configuration: ModelConfiguration("Users", schema: usersSchema, url: usersDatabaseURL))
            if let carried {
                carried.insert(into: users.mainContext)
                try users.mainContext.save()
            }
        } catch {
            throw StoreOpenError.usersFailed(error)
        }
        // The household's old tables in the library database are dropped only now, once
        // Users.sqlite holds their rows.
        let library: ModelContainer
        do {
            library = try open(librarySchema, plan: LibraryMigrationPlan.self,
                               configuration: ModelConfiguration("Library", schema: librarySchema, url: databaseURL),
                               alsoAllowing: Set(schema.entities.map(\.name)))
        } catch {
            throw StoreOpenError.libraryFailed(error)
        }
        return (library, users)
    }

    /// Opens a database with its migration plan. A database written by a build from before
    /// versioning (whose models may differ slightly from version 1) isn't a version the plan
    /// knows, so it's opened the way it always was, with automatic lightweight migration;
    /// from then on it matches version 1.
    ///
    /// Either way can remove tables the schema doesn't have, so a database holding any model
    /// besides the schema's (and `alsoAllowing`'s, such as tables already carried elsewhere)
    /// is refused with `UnknownDataError` before anything opens it.
    static func open(_ schema: Schema, plan: any SchemaMigrationPlan.Type,
                     configuration: ModelConfiguration, alsoAllowing allowed: Set<String> = []) throws -> ModelContainer {
        if !configuration.isStoredInMemoryOnly {
            let unknown = unknownEntities(at: configuration.url, schema: schema, alsoAllowing: allowed)
            if !unknown.isEmpty { throw UnknownDataError(entities: unknown) }
        }
        do {
            return try ModelContainer(for: schema, migrationPlan: plan, configurations: [configuration])
        } catch {
            return try ModelContainer(for: schema, configurations: [configuration])
        }
    }

    /// Models stored in the database at `url` that neither `schema` nor `allowed` has, read
    /// from the store's metadata without opening it. Empty when there's no database yet.
    static func unknownEntities(at url: URL, schema: Schema, alsoAllowing allowed: Set<String> = []) -> [String] {
        guard FileManager.default.fileExists(atPath: url.path),
              let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(
                type: .sqlite, at: url, options: nil),
              let hashes = metadata[NSStoreModelVersionHashesKey] as? [String: Any] else { return [] }
        let known = Set(schema.entities.map(\.name)).union(allowed)
        return hashes.keys.filter { !known.contains($0) }.sorted()
    }

    /// Renames databases that can't be opened (with their journal files) to
    /// "Library.sqlite.damaged-<date>" and so on, beside the originals, so the app can start
    /// fresh while the old files stay available for recovery. Nothing is deleted.
    /// Returns the renamed main database files.
    @discardableResult
    static func moveAsideDamagedStores(library: Bool = true, users: Bool = true) throws -> [URL] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: .now)
        let manager = FileManager.default
        var moved: [URL] = []
        for store in [library ? databaseURL : nil, users ? usersDatabaseURL : nil].compactMap({ $0 }) {
            guard manager.fileExists(atPath: store.path) else { continue }
            var base = store.path + ".damaged-" + stamp
            var attempt = 1
            while companionSuffixes.contains(where: { manager.fileExists(atPath: base + $0) }) {
                attempt += 1
                base = store.path + ".damaged-" + stamp + "-\(attempt)"
            }
            // The main file first: if that fails nothing has moved and the store is intact.
            for suffix in companionSuffixes {
                let source = store.path + suffix
                guard manager.fileExists(atPath: source) else { continue }
                try manager.moveItem(atPath: source, toPath: base + suffix)
            }
            moved.append(URL(fileURLWithPath: base))
        }
        return moved
    }

    /// Earlier versions kept the same SQLite data as "UltimateTheater.store" directly in
    /// Application Support. Moves it (with its journal files) to the new location once.
    private static func moveEarlierStore() {
        let manager = FileManager.default
        let earlier = URL.applicationSupportDirectory.appending(path: "UltimateTheater.store")
        guard manager.fileExists(atPath: earlier.path), !manager.fileExists(atPath: databaseURL.path) else { return }
        for suffix in companionSuffixes {
            let source = URL(fileURLWithPath: earlier.path + suffix)
            guard manager.fileExists(atPath: source.path) else { continue }
            try? manager.moveItem(at: source, to: URL(fileURLWithPath: databaseURL.path + suffix))
        }
    }

    /// User data copied out of a library database from before the split.
    private struct UserData {
        var profiles: [(id: String, name: String, symbol: String, palette: Int, limit: Int, unrated: Bool, pin: String?, image: Data?, created: Date)] = []
        var progress: [(profile: String, title: String, playback: String, position: Double, duration: Double, watched: Date)] = []
        var lists: [(profile: String, title: String, added: Date)] = []
        var ratings: [(profile: String, title: String, score: Double, rated: Date)] = []

        var isEmpty: Bool { profiles.isEmpty && progress.isEmpty && lists.isEmpty && ratings.isEmpty }

        /// Adds what Users.sqlite doesn't have yet. (A launch interrupted after copying, before
        /// the library dropped its old tables, copies again; nothing is added twice.)
        func insert(into context: ModelContext) {
            let profileIDs = Set(((try? context.fetch(FetchDescriptor<StoredProfile>())) ?? []).map(\.id))
            let progressKeys = Set(((try? context.fetch(FetchDescriptor<WatchProgress>())) ?? []).map { "\($0.profileID)\n\($0.playbackID)" })
            let listKeys = Set(((try? context.fetch(FetchDescriptor<MyListEntry>())) ?? []).map { "\($0.profileID)\n\($0.titleID)" })
            let ratingKeys = Set(((try? context.fetch(FetchDescriptor<UserRating>())) ?? []).map { "\($0.profileID)\n\($0.titleID)" })
            for p in profiles where !profileIDs.contains(p.id) {
                let stored = StoredProfile(id: p.id, name: p.name, symbol: p.symbol, paletteIndex: p.palette,
                                           ratingLimit: RatingLimit(rawValue: p.limit) ?? .everything, allowsUnrated: p.unrated)
                stored.pinHash = p.pin
                stored.imageData = p.image
                stored.dateCreated = p.created
                context.insert(stored)
            }
            for p in progress where !progressKeys.contains("\(p.profile)\n\(p.playback)") {
                let entry = WatchProgress(profileID: p.profile, titleID: p.title, playbackID: p.playback,
                                          position: p.position, duration: p.duration)
                entry.lastWatched = p.watched
                context.insert(entry)
            }
            for l in lists where !listKeys.contains("\(l.profile)\n\(l.title)") {
                let entry = MyListEntry(profileID: l.profile, titleID: l.title)
                entry.addedAt = l.added
                context.insert(entry)
            }
            for r in ratings where !ratingKeys.contains("\(r.profile)\n\(r.title)") {
                let entry = UserRating(profileID: r.profile, titleID: r.title, score: r.score)
                entry.ratedAt = r.rated
                context.insert(entry)
            }
        }
    }

    /// Before the split, user data lived in Library.sqlite. While its tables are still there,
    /// reads them so they can be written to Users.sqlite (opening the library with only its
    /// own models then removes them).
    private static func carryOverUserData() throws -> UserData? {
        guard FileManager.default.fileExists(atPath: databaseURL.path),
              hasTable("ZSTOREDPROFILE", in: databaseURL) || hasTable("ZWATCHPROGRESS", in: databaseURL) else { return nil }
        var data = UserData()
        let unknown = unknownEntities(at: databaseURL, schema: schema)
        if !unknown.isEmpty { throw UnknownDataError(entities: unknown) }
        let old = try ModelContainer(for: schema, configurations: [ModelConfiguration("Legacy", schema: schema, url: databaseURL)])
        let context = ModelContext(old)
        for p in (try? context.fetch(FetchDescriptor<StoredProfile>())) ?? [] {
            data.profiles.append((p.id, p.name, p.symbol, p.paletteIndex, p.ratingLimitRaw, p.allowsUnrated, p.pinHash, p.imageData, p.dateCreated))
        }
        for p in (try? context.fetch(FetchDescriptor<WatchProgress>())) ?? [] {
            data.progress.append((p.profileID, p.titleID, p.playbackID, p.position, p.duration, p.lastWatched))
        }
        for l in (try? context.fetch(FetchDescriptor<MyListEntry>())) ?? [] {
            data.lists.append((l.profileID, l.titleID, l.addedAt))
        }
        for r in (try? context.fetch(FetchDescriptor<UserRating>())) ?? [] {
            data.ratings.append((r.profileID, r.titleID, r.score, r.ratedAt))
        }
        return data.isEmpty ? nil : data
    }

    private static func hasTable(_ name: String, in url: URL) -> Bool {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return false }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// Size of a database and its journal files, in bytes.
    static func size(of url: URL) -> Int64 {
        companionSuffixes.reduce(0) { total, suffix in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path + suffix)
            return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    /// Removes cached artwork, web responses, and other caches.
    static func clearCaches() {
        URLCache.shared.removeAllCachedResponses()
        HTTPClient.session.configuration.urlCache?.removeAllCachedResponses()
        let manager = FileManager.default
        for url in (try? manager.contentsOfDirectory(at: URL.cachesDirectory, includingPropertiesForKeys: nil)) ?? [] {
            try? manager.removeItem(at: url)
        }
    }
}
