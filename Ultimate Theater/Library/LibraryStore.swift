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
import SQLite3

enum LibraryStore {
    static let librarySchema = Schema([MediaItem.self, MediaEpisode.self, LibraryFolder.self])
    static let usersSchema = Schema([StoredProfile.self, WatchProgress.self, MyListEntry.self, UserRating.self])
    static let schema = Schema([
        MediaItem.self, MediaEpisode.self, LibraryFolder.self,
        StoredProfile.self, WatchProgress.self, MyListEntry.self, UserRating.self,
    ])

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
    static func makeContainers() throws -> (library: ModelContainer, users: ModelContainer) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        moveEarlierStore()
        let carried = try carryOverUserData()
        let users = try ModelContainer(for: usersSchema, configurations: [
            ModelConfiguration("Users", schema: usersSchema, url: usersDatabaseURL),
        ])
        if let carried {
            carried.insert(into: users.mainContext)
            try users.mainContext.save()
        }
        let library = try ModelContainer(for: librarySchema, configurations: [
            ModelConfiguration("Library", schema: librarySchema, url: databaseURL),
        ])
        return (library, users)
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

        func insert(into context: ModelContext) {
            for p in profiles {
                let stored = StoredProfile(id: p.id, name: p.name, symbol: p.symbol, paletteIndex: p.palette,
                                           ratingLimit: RatingLimit(rawValue: p.limit) ?? .everything, allowsUnrated: p.unrated)
                stored.pinHash = p.pin
                stored.imageData = p.image
                stored.dateCreated = p.created
                context.insert(stored)
            }
            for p in progress {
                let entry = WatchProgress(profileID: p.profile, titleID: p.title, playbackID: p.playback,
                                          position: p.position, duration: p.duration)
                entry.lastWatched = p.watched
                context.insert(entry)
            }
            for l in lists {
                let entry = MyListEntry(profileID: l.profile, titleID: l.title)
                entry.addedAt = l.added
                context.insert(entry)
            }
            for r in ratings {
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
