//
//  LibraryStoreLifetimeTests.swift
//  Ultimate TheaterTests
//
//  The master library must keep its database container alive: a ModelContext alone
//  doesn't, and inserting into a context whose container is gone traps in SwiftData
//  (this happened when adding a folder in the setup wizard).
//

import Testing
import Foundation
import SwiftData
@testable import Ultimate_Theater

/// No API keys, and nothing read from the real Keychain.
private struct NoSecrets: SecretStore {
    func read(account: String, service: String) throws -> String? { nil }
    func write(_ value: String?, account: String, service: String) throws {}
}

/// Metadata settings kept apart from the app's real preferences and Keychain.
@MainActor
private func isolatedMetadataSettings() -> MetadataSettings {
    MetadataSettings(defaults: UserDefaults(suiteName: "MetadataSettingsTests-\(UUID().uuidString)") ?? .standard,
                     secrets: NoSecrets())
}

@MainActor
struct LibraryStoreLifetimeTests {
    @Test func libraryKeepsItsContainerAlive() throws {
        // Its own folder, so the database's -wal and -shm files go with it.
        let folder = FileManager.default.temporaryDirectory.appending(path: "LibraryStoreLifetimeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Library.sqlite")
        weak var released: ModelContainer?
        let library: MediaLibrary = try {
            let container = try ModelContainer(for: LibraryStore.librarySchema,
                                               configurations: [ModelConfiguration("Library", schema: LibraryStore.librarySchema, url: url)])
            released = container
            return MediaLibrary(container: container, metadata: MetadataService(settings: isolatedMetadataSettings()))
        }()
        #expect(released != nil)
        library.context.insert(LibraryFolder(path: "/Volumes/Movies/Movies", bookmark: nil))
        try library.context.save()
        #expect(try library.context.fetch(FetchDescriptor<LibraryFolder>()).count == 1)
    }
}
