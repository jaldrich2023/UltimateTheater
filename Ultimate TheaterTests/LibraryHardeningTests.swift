//
//  LibraryHardeningTests.swift
//  Ultimate TheaterTests
//
//  PIN lockout and fail-closed PIN checks, provider ID validation, the redirect policy,
//  artwork download rules, and the versioned database schemas.
//

import Testing
import Foundation
import SwiftData
@testable import Ultimate_Theater

// MARK: - Secret stores for testing

/// A Keychain that can't be read (locked, access denied).
private struct FailingStore: SecretStore {
    func read(account: String, service: String) throws -> String? { throw KeychainError.unexpectedStatus(errSecInteractionNotAllowed) }
    func write(_ value: String?, account: String, service: String) throws { throw KeychainError.unexpectedStatus(errSecInteractionNotAllowed) }
}

/// A Keychain holding one fixed value (or nothing).
private struct FixedStore: SecretStore {
    var value: String?
    func read(account: String, service: String) throws -> String? { value }
    func write(_ value: String?, account: String, service: String) throws {}
}

struct PINLockoutTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func freeAttemptsThenDoublingWaits() {
        var lockout = PINLockout()
        for _ in 0..<(PINLockout.freeAttempts - 1) {
            lockout.recordFailure(at: start)
            #expect(!lockout.isLocked(at: start))
        }
        lockout.recordFailure(at: start)
        #expect(lockout.remaining(at: start) == 30)
        #expect(lockout.isLocked(at: start.addingTimeInterval(29)))
        #expect(!lockout.isLocked(at: start.addingTimeInterval(30)))

        let later = start.addingTimeInterval(31)
        lockout.recordFailure(at: later)
        #expect(lockout.remaining(at: later) == 60)
        lockout.recordFailure(at: later)
        #expect(lockout.remaining(at: later) == 120)
    }

    @Test func waitsAreCappedAtFifteenMinutes() {
        #expect(PINLockout.delay(afterFailures: 4) == 0)
        #expect(PINLockout.delay(afterFailures: 5) == 30)
        #expect(PINLockout.delay(afterFailures: 9) == 480)
        #expect(PINLockout.delay(afterFailures: 10) == 900)
        #expect(PINLockout.delay(afterFailures: 1_000) == 900)
    }

    @Test func clockSetBackwardsDoesNotLockForever() {
        var lockout = PINLockout()
        for _ in 0..<PINLockout.freeAttempts { lockout.recordFailure(at: start) }
        let wayBack = start.addingTimeInterval(-365 * 86_400)
        #expect(lockout.remaining(at: wayBack) == PINLockout.maximumDelay)
    }

    @Test func successResets() {
        var lockout = PINLockout()
        for _ in 0..<7 { lockout.recordFailure(at: start) }
        lockout.recordSuccess()
        #expect(lockout == PINLockout())
        #expect(!lockout.isLocked(at: start))
    }

    @Test func lockoutSurvivesRelaunch() throws {
        let suite = "PINLockoutTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PINLockoutStore(defaults: defaults, key: "lockout")
        var lockout = store.load()
        for _ in 0..<PINLockout.freeAttempts { lockout.recordFailure(at: start) }
        store.save(lockout)
        // A new store over the same defaults, as after relaunching.
        let reloaded = PINLockoutStore(defaults: defaults, key: "lockout").load()
        #expect(reloaded == lockout)
        #expect(reloaded.isLocked(at: start.addingTimeInterval(10)))
    }
}

/// A throwaway defaults suite for the PIN's configured marker, removed afterwards.
private func withMarkers(_ body: (UserDefaults) throws -> Void) rethrows {
    let suite = "AdministratorPINTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults)
}

/// An in-memory Keychain that remembers writes.
private final class MemoryStore: SecretStore, @unchecked Sendable {
    var value: String?
    init(_ value: String? = nil) { self.value = value }
    func read(account: String, service: String) throws -> String? { value }
    func write(_ value: String?, account: String, service: String) throws { self.value = value }
}

struct AdministratorPINFailClosedTests {
    @Test func unreadableKeychainCountsAsSetAndNeverVerifies() {
        withMarkers { markers in
            let store = FailingStore()
            #expect(AdministratorPIN.isSet(in: store, markers: markers))
            #expect(!AdministratorPIN.verify("1234", in: store, markers: markers))
            guard case .unreadable = AdministratorPIN.stored(in: store, markers: markers) else {
                Issue.record("A read failure should be reported as unreadable")
                return
            }
        }
    }

    @Test func noPINAllowsAccess() {
        withMarkers { markers in
            let store = FixedStore(value: nil)
            #expect(!AdministratorPIN.isSet(in: store, markers: markers))
            #expect(AdministratorPIN.verify("0000", in: store, markers: markers))
        }
    }

    @Test func storedPINVerifiesOnlyTheRightEntry() {
        withMarkers { markers in
            let store = FixedStore(value: PINHash.make("2468"))
            #expect(AdministratorPIN.isSet(in: store, markers: markers))
            #expect(AdministratorPIN.verify("2468", in: store, markers: markers))
            #expect(!AdministratorPIN.verify("1357", in: store, markers: markers))
        }
    }

    @Test func failedSaveIsReported() {
        withMarkers { markers in
            #expect(!AdministratorPIN.set("1234", in: FailingStore(), markers: markers))
            #expect(throws: (any Error).self) { try AdministratorPIN.save("1234", in: FailingStore(), markers: markers) }
            // A write that doesn't stick (read-back mismatch) is a failure too.
            #expect(!AdministratorPIN.set("1234", in: FixedStore(value: nil), markers: markers))
            #expect(!markers.bool(forKey: AdministratorPIN.configuredMarkerKey))
            #expect(AdministratorPIN.set("1234", in: MemoryStore(), markers: markers))
            #expect(markers.bool(forKey: AdministratorPIN.configuredMarkerKey))
        }
    }

    @Test func deletedKeychainItemFailsClosedWhenMarkerIsSet() throws {
        try withMarkers { markers in
            let store = MemoryStore()
            try AdministratorPIN.save("1234", in: store, markers: markers)
            store.value = nil // The Keychain item deleted behind the app's back.
            guard case .unreadable = AdministratorPIN.stored(in: store, markers: markers) else {
                Issue.record("A missing item with the marker set should be unreadable")
                return
            }
            #expect(!AdministratorPIN.verify("1234", in: store, markers: markers))
            #expect(!AdministratorPIN.verify("0000", in: store, markers: markers))
        }
    }

    @Test func existingItemMigratesTheMarker() {
        withMarkers { markers in
            let store = MemoryStore(PINHash.make("1111"))
            #expect(!markers.bool(forKey: AdministratorPIN.configuredMarkerKey))
            #expect(AdministratorPIN.isSet(in: store, markers: markers))
            #expect(markers.bool(forKey: AdministratorPIN.configuredMarkerKey))
        }
    }

    @Test func removingThePINClearsTheMarker() throws {
        try withMarkers { markers in
            let store = MemoryStore()
            try AdministratorPIN.save("1234", in: store, markers: markers)
            try AdministratorPIN.save(nil, in: store, markers: markers)
            #expect(AdministratorPIN.stored(in: store, markers: markers) == .none)
            try AdministratorPIN.save("1234", in: store, markers: markers)
            #expect(AdministratorPIN.clearAfterOwnerAuthentication(in: store, markers: markers))
            #expect(AdministratorPIN.stored(in: store, markers: markers) == .none)
            #expect(!AdministratorPIN.clearAfterOwnerAuthentication(in: FailingStore(), markers: markers))
        }
    }
}

struct PerTargetLockoutTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func profileMissesDoNotLockTheAdministrator() {
        withMarkers { defaults in
            let profile = PINAttemptGuard(targets: [.profile("kid")], defaults: defaults)
            for _ in 0..<PINLockout.freeAttempts { profile.recordFailure(at: start) }
            #expect(profile.isLocked(at: start))
            #expect(!PINAttemptGuard(targets: [.administrator], defaults: defaults).isLocked(at: start))
            #expect(!PINAttemptGuard(targets: [.profile("other")], defaults: defaults).isLocked(at: start))
            // Persisted: a fresh guard sees the same lock.
            #expect(PINAttemptGuard(targets: [.profile("kid")], defaults: defaults).isLocked(at: start))
        }
    }

    @Test func sharedPromptLocksOnEitherAndNeverClearsTheAdministrator() {
        withMarkers { defaults in
            let admin = PINAttemptGuard(targets: [.administrator], defaults: defaults)
            for _ in 0..<PINLockout.freeAttempts { admin.recordFailure(at: start) }
            let shared = PINAttemptGuard(targets: [.administrator, .profile("kid")], defaults: defaults)
            #expect(shared.isLocked(at: start))
            shared.recordSuccess()
            #expect(admin.isLocked(at: start))
        }
    }

    @Test func unreadableAdministratorMissesAreNotCounted() {
        withMarkers { defaults in
            let admin = PINAttemptGuard(targets: [.administrator], defaults: defaults)
            for _ in 0..<(PINLockout.freeAttempts * 2) { admin.recordFailure(at: start, administratorUnreadable: true) }
            #expect(admin.failures == 0)
        }
    }

    @Test func legacySharedRecordBecomesTheAdministrators() throws {
        try withMarkers { defaults in
            var lockout = PINLockout()
            for _ in 0..<PINLockout.freeAttempts { lockout.recordFailure(at: start) }
            defaults.set(try JSONEncoder().encode(lockout), forKey: PINLockoutStore.defaultKey)
            #expect(PINLockoutStore.forTarget(.administrator, defaults: defaults).load() == lockout)
            #expect(PINLockoutStore.forTarget(.profile("kid"), defaults: defaults).load() == PINLockout())
            #expect(defaults.data(forKey: PINLockoutStore.defaultKey) == nil)
        }
    }
}

struct MetadataIDValidationTests {
    @Test func imdbIDs() {
        #expect(MetadataIDs.isIMDb("tt0133093"))
        #expect(MetadataIDs.isIMDb("tt1"))
        #expect(!MetadataIDs.isIMDb("tt"))
        #expect(!MetadataIDs.isIMDb("0133093"))
        #expect(!MetadataIDs.isIMDb("tt0133093/../../account"))
        #expect(!MetadataIDs.isIMDb("tt0133093?api_key=x"))
        #expect(!MetadataIDs.isIMDb("tt12345678901"))
    }

    @Test func numericIDs() {
        #expect(MetadataIDs.numeric("603") == 603)
        #expect(MetadataIDs.numeric("0") == nil)
        #expect(MetadataIDs.numeric("-3") == nil)
        #expect(MetadataIDs.numeric("+5") == nil)
        #expect(MetadataIDs.numeric("12/videos") == nil)
        #expect(MetadataIDs.numeric("") == nil)
    }

    @Test func trailerKeys() {
        #expect(MetadataIDs.isTrailerKey("dQw4w9WgXcQ"))
        #expect(MetadataIDs.isTrailerKey("a_b-C"))
        #expect(!MetadataIDs.isTrailerKey(""))
        #expect(!MetadataIDs.isTrailerKey("abc?autoplay=0"))
        #expect(!MetadataIDs.isTrailerKey("abc/../x"))
        #expect(!MetadataIDs.isTrailerKey(String(repeating: "a", count: 33)))
    }

    @Test func trailerURLsOnlyForValidKeys() {
        let good = TrailerInfo(site: "YouTube", key: "dQw4w9WgXcQ", name: "Trailer")
        #expect(good.watchURL?.absoluteString == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(good.embedURL?.absoluteString.hasPrefix("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?autoplay=1") == true)
        let vimeo = TrailerInfo(site: "Vimeo", key: "76979871", name: "Trailer")
        #expect(vimeo.watchURL?.absoluteString == "https://vimeo.com/76979871")

        let bad = TrailerInfo(site: "YouTube", key: "x\"><script>", name: "Trailer")
        #expect(bad.watchURL == nil)
        #expect(bad.embedURL == nil)
    }
}

struct RedirectPolicyTests {
    private func request(_ url: String, authorized: Bool = true) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        if authorized {
            request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
            request.setValue("key", forHTTPHeaderField: "Api-Key")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    @Test func sameHostHTTPSKeepsHeaders() throws {
        let original = URL(string: "https://api.tvmaze.com/lookup/shows?imdb=tt0944947")
        let followed = try #require(RedirectGuard.decision(for: request("https://api.tvmaze.com/shows/82"), originalURL: original))
        #expect(followed.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test func otherHostLosesCredentials() throws {
        let original = URL(string: "https://api.opensubtitles.com/api/v1/download")
        let followed = try #require(RedirectGuard.decision(for: request("https://dl.example.com/file.srt"), originalURL: original))
        #expect(followed.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(followed.value(forHTTPHeaderField: "Api-Key") == nil)
        #expect(followed.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test func insecureRedirectsAreRefused() {
        let original = URL(string: "https://api.themoviedb.org/3/movie/603")
        #expect(RedirectGuard.decision(for: request("http://api.themoviedb.org/3/movie/603"), originalURL: original) == nil)
        #expect(RedirectGuard.decision(for: request("file:///etc/passwd"), originalURL: original) == nil)
    }
}

struct ArtworkRulesTests {
    @Test func onlyHTTPSAndLocalFiles() throws {
        #expect(ArtworkCache.isAllowed(try #require(URL(string: "https://image.tmdb.org/t/p/w780/a.jpg"))))
        #expect(ArtworkCache.isAllowed(URL(fileURLWithPath: "/tmp/poster.png")))
        #expect(!ArtworkCache.isAllowed(try #require(URL(string: "http://image.tmdb.org/t/p/w780/a.jpg"))))
        #expect(!ArtworkCache.isAllowed(try #require(URL(string: "ftp://example.com/a.jpg"))))
        #expect(!ArtworkCache.isAllowed(try #require(URL(string: "data:image/png;base64,AAAA"))))
    }

    @Test func imageTypesWithinTheSizeCap() {
        #expect(ArtworkCache.accepts(mimeType: "image/jpeg", expectedLength: 300_000))
        #expect(ArtworkCache.accepts(mimeType: "IMAGE/PNG", expectedLength: -1)) // Length unknown: capped while reading.
        #expect(ArtworkCache.accepts(mimeType: "application/octet-stream", expectedLength: 1_000))
        #expect(!ArtworkCache.accepts(mimeType: "text/html", expectedLength: 1_000))
        #expect(!ArtworkCache.accepts(mimeType: nil, expectedLength: 1_000))
        #expect(!ArtworkCache.accepts(mimeType: "image/jpeg", expectedLength: Int64(ArtworkCache.maximumDownloadSize) + 1))
    }

    @Test func pruningRemovesLeastRecentlyUsedFirst() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "artwork-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = folder.appending(path: "old"), recent = folder.appending(path: "recent")
        try Data(count: 600).write(to: old)
        try Data(count: 600).write(to: recent)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: old.path)

        ArtworkCache.prune(folder, to: 1_000)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
    }
}

@MainActor
struct VersionedSchemaTests {
    @Test func bothSchemasOpenInMemoryWithTheirPlans() throws {
        let library = try ModelContainer(for: LibraryStore.librarySchema, migrationPlan: LibraryMigrationPlan.self,
                                         configurations: [ModelConfiguration("Library", schema: LibraryStore.librarySchema,
                                                                             isStoredInMemoryOnly: true)])
        library.mainContext.insert(LibraryFolder(path: "/Volumes/Movies", bookmark: nil))
        try library.mainContext.save()
        #expect(try library.mainContext.fetchCount(FetchDescriptor<LibraryFolder>()) == 1)

        let users = try ModelContainer(for: LibraryStore.usersSchema, migrationPlan: UsersMigrationPlan.self,
                                       configurations: [ModelConfiguration("Users", schema: LibraryStore.usersSchema,
                                                                           isStoredInMemoryOnly: true)])
        users.mainContext.insert(MyListEntry(profileID: "p", titleID: "t"))
        try users.mainContext.save()
        #expect(try users.mainContext.fetchCount(FetchDescriptor<MyListEntry>()) == 1)
    }

    @Test func versionOneMatchesTheModelsDirectly() {
        // Version 1 must be exactly the models written by builds from before versioning.
        let unversioned = Schema([MediaItem.self, MediaEpisode.self, LibraryFolder.self, PendingMedia.self])
        #expect(Set(LibraryStore.librarySchema.entities.map(\.name)) == Set(unversioned.entities.map(\.name)))
        let unversionedUsers = Schema([StoredProfile.self, WatchProgress.self, MyListEntry.self, UserRating.self, SceneBookmark.self])
        #expect(Set(LibraryStore.usersSchema.entities.map(\.name)) == Set(unversionedUsers.entities.map(\.name)))
    }

    @Test func databaseFromBeforeVersioningKeepsItsData() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Library.sqlite")

        // Written the way earlier builds did: an unversioned schema of the same models.
        do {
            let unversioned = Schema([MediaItem.self, MediaEpisode.self, LibraryFolder.self, PendingMedia.self])
            let container = try ModelContainer(for: unversioned, configurations: [ModelConfiguration("Library", schema: unversioned, url: url)])
            container.mainContext.insert(LibraryFolder(path: "/Volumes/Movies", bookmark: nil))
            try container.mainContext.save()
        }

        let reopened = try LibraryStore.open(LibraryStore.librarySchema, plan: LibraryMigrationPlan.self,
                                             configuration: ModelConfiguration("Library", schema: LibraryStore.librarySchema, url: url))
        #expect(try reopened.mainContext.fetch(FetchDescriptor<LibraryFolder>()).map(\.path) == ["/Volumes/Movies"])
    }
}

// MARK: - Repair output safety

struct RepairOutputSafetyTests {
    private func withFolder(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "RepairOutputTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }

    @Test func theOriginalIsNeverADestination() throws {
        try withFolder { folder in
            let source = folder.appending(path: "Movie.mp4")
            try Data("original".utf8).write(to: source)
            #expect(throws: RepairOutput.Problem.sameAsSource) { try RepairOutput.prepare(destination: source, protecting: [source]) }
            // The same file by another path: a symbolic link, a hard link, or a roundabout spelling.
            let symlink = folder.appending(path: "Link.mp4")
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
            #expect(throws: RepairOutput.Problem.sameAsSource) { try RepairOutput.prepare(destination: symlink, protecting: [source]) }
            let hardLink = folder.appending(path: "Hard.mp4")
            try FileManager.default.linkItem(at: source, to: hardLink)
            #expect(throws: RepairOutput.Problem.sameAsSource) { try RepairOutput.prepare(destination: hardLink, protecting: [source]) }
            let roundabout = URL(fileURLWithPath: folder.path + "/./sub/../Movie.mp4")
            #expect(throws: RepairOutput.Problem.sameAsSource) { try RepairOutput.prepare(destination: roundabout, protecting: [source]) }
            #expect(try Data(contentsOf: source) == Data("original".utf8))
            // A different name is fine.
            let different = try RepairOutput.prepare(destination: folder.appending(path: "Movie (Repaired).mp4"), protecting: [source])
            different.discard()
        }
    }

    @Test func anExistingDestinationSurvivesUntilTheCopyIsComplete() throws {
        try withFolder { folder in
            let source = folder.appending(path: "Damaged.mkv")
            let destination = folder.appending(path: "Keep.mkv")
            try Data("source".utf8).write(to: source)
            try Data("existing".utf8).write(to: destination)

            // Cancelled: only the temporary file goes.
            let cancelled = try RepairOutput.prepare(destination: destination, protecting: [source])
            #expect(cancelled.temporary != destination)
            try Data("partial".utf8).write(to: cancelled.temporary)
            #expect(try Data(contentsOf: destination) == Data("existing".utf8))
            cancelled.discard()
            #expect(!FileManager.default.fileExists(atPath: cancelled.temporary.path))
            #expect(try Data(contentsOf: destination) == Data("existing".utf8))

            // Finished: the copy takes the destination's place only now.
            let finished = try RepairOutput.prepare(destination: destination, protecting: [source])
            try Data("repaired".utf8).write(to: finished.temporary)
            let placed = try finished.commit()
            #expect(try Data(contentsOf: placed) == Data("repaired".utf8))
            #expect(try Data(contentsOf: source) == Data("source".utf8))
        }
    }

    @Test func repairWritersNeverOverwrite() throws {
        try withFolder { folder in
            let existing = folder.appending(path: "Existing.mp4")
            try Data("keep me".utf8).write(to: existing)
            #expect(throws: (any Error).self) { _ = try RepairOutput.createNewFile(at: existing) }
            #expect(throws: (any Error).self) { _ = try RepairWriter(url: existing) }
            #expect(try Data(contentsOf: existing) == Data("keep me".utf8))
        }
    }
}

// MARK: - Store metadata guard

/// A model no version of the library schema has, standing in for one from a newer build.
@Model final class FutureLibraryThing {
    var note: String = ""
    init(note: String) { self.note = note }
}

@MainActor
struct StoreMetadataGuardTests {
    @Test func databaseWithUnknownModelsIsLeftUntouched() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "StoreGuardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Library.sqlite")
        let newer = Schema([MediaItem.self, MediaEpisode.self, LibraryFolder.self, PendingMedia.self, FutureLibraryThing.self])
        do {
            let container = try ModelContainer(for: newer, configurations: [ModelConfiguration("Library", schema: newer, url: url)])
            container.mainContext.insert(FutureLibraryThing(note: "from a newer build"))
            container.mainContext.insert(LibraryFolder(path: "/Volumes/Movies", bookmark: nil))
            try container.mainContext.save()
        }

        #expect(LibraryStore.unknownEntities(at: url, schema: LibraryStore.librarySchema) == ["FutureLibraryThing"])
        #expect(LibraryStore.unknownEntities(at: url, schema: LibraryStore.librarySchema, alsoAllowing: ["FutureLibraryThing"]).isEmpty)
        #expect(throws: LibraryStore.UnknownDataError.self) {
            _ = try LibraryStore.open(LibraryStore.librarySchema, plan: LibraryMigrationPlan.self,
                                      configuration: ModelConfiguration("Library", schema: LibraryStore.librarySchema, url: url))
        }

        // Its data is all still there.
        let reopened = try ModelContainer(for: newer, configurations: [ModelConfiguration("Library", schema: newer, url: url)])
        #expect(try reopened.mainContext.fetch(FetchDescriptor<FutureLibraryThing>()).map(\.note) == ["from a newer build"])
        #expect(try reopened.mainContext.fetchCount(FetchDescriptor<LibraryFolder>()) == 1)
    }

    @Test func noDatabaseYetHasNothingUnknown() {
        let url = FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID().uuidString).sqlite")
        #expect(LibraryStore.unknownEntities(at: url, schema: LibraryStore.librarySchema).isEmpty)
    }

    @Test func storeOpenErrorSaysWhichDatabaseFailed() {
        struct Failure: Error {}
        #expect(LibraryStore.StoreOpenError.libraryFailed(Failure()).libraryFailed)
        #expect(!LibraryStore.StoreOpenError.libraryFailed(Failure()).usersFailed)
        #expect(LibraryStore.StoreOpenError.usersFailed(Failure()).usersFailed)
        #expect(!LibraryStore.StoreOpenError.usersFailed(Failure()).libraryFailed)
    }
}
