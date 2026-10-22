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
        try await Task.sleep(for: .milliseconds(300))

        let movie = folder.appending(path: "New Movie (2026).mp4")
        try Data("video".utf8).write(to: movie)
        for _ in 0..<50 where !changes.contains(where: { $0.path.hasSuffix("New Movie (2026).mp4") }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(changes.contains { $0.path.hasSuffix("New Movie (2026).mp4") && !$0.wasRemoved })

        changes = []
        try FileManager.default.removeItem(at: movie)
        for _ in 0..<50 where !changes.contains(where: \.wasRemoved) {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(changes.contains { $0.path.hasSuffix("New Movie (2026).mp4") && $0.wasRemoved })
        _ = watcher
    }
}
