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

@MainActor
struct LibraryStoreLifetimeTests {
    @Test func libraryKeepsItsContainerAlive() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        weak var released: ModelContainer?
        let library: MediaLibrary = try {
            let container = try ModelContainer(for: LibraryStore.librarySchema,
                                               configurations: [ModelConfiguration("Library", schema: LibraryStore.librarySchema, url: url)])
            released = container
            return MediaLibrary(container: container, metadata: MetadataService(settings: MetadataSettings()))
        }()
        #expect(released != nil)
        library.context.insert(LibraryFolder(path: "/Volumes/Movies/Movies", bookmark: nil))
        try library.context.save()
        #expect(try library.context.fetch(FetchDescriptor<LibraryFolder>()).count == 1)
    }
}
