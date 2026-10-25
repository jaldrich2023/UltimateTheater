//
//  FolderWatcherTests.swift
//  Ultimate TheaterTests
//

import Testing
import Foundation
@testable import Ultimate_Theater

@MainActor
struct FolderWatcherTests {
    @Test func reportsNewAndRemovedFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "watch-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var changes: [FolderWatcher.Change] = []
        let watcher = try #require(FolderWatcher(paths: [folder.path], latency: 0.1) { changes += $0 })

        // Instead of guessing how long the event stream takes to start, write a probe file
        // until the watcher reports it: from then on it is known to be live.
        let probe = folder.appending(path: "probe.txt")
        let live = try await waitUntil(timeout: .seconds(5), pollingEvery: .milliseconds(100)) {
            try Data(UUID().uuidString.utf8).write(to: probe)
            return changes.contains { $0.path.hasSuffix("probe.txt") }
        }
        try #require(live, "the folder watcher never started reporting")
        changes = []

        let movie = folder.appending(path: "New Movie (2026).mp4")
        try Data("video".utf8).write(to: movie)
        try await waitUntil(timeout: .seconds(5)) { changes.contains { $0.path.hasSuffix("New Movie (2026).mp4") } }
        #expect(changes.contains { $0.path.hasSuffix("New Movie (2026).mp4") && !$0.wasRemoved })

        changes = []
        try FileManager.default.removeItem(at: movie)
        try await waitUntil(timeout: .seconds(5)) {
            changes.contains { $0.path.hasSuffix("New Movie (2026).mp4") && $0.wasRemoved }
        }
        #expect(changes.contains { $0.path.hasSuffix("New Movie (2026).mp4") && $0.wasRemoved })
        _ = watcher
    }
}
