//
//  LibraryReclassificationTests.swift
//  Ultimate TheaterTests
//
//  Titles filed under the wrong library move to the right one when folders are scanned.
//

import Testing
import Foundation
import SwiftData
@testable import Ultimate_Theater

@MainActor
struct LibraryReclassificationTests {
    private func makeLibrary() throws -> MediaLibrary {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let container = try ModelContainer(for: LibraryStore.librarySchema,
                                           configurations: [ModelConfiguration("Library", schema: LibraryStore.librarySchema, url: url)])
        return MediaLibrary(container: container, metadata: MetadataService(settings: MetadataSettings()))
    }

    @Test func episodeFiledAsAMovieMovesToItsShow() throws {
        let library = try makeLibrary()
        let existing = MediaItem(kind: .series, name: "Star Trek Enterprise", year: nil)
        library.context.insert(existing)
        let movie = MediaItem(kind: .movie, name: "Star Trek Enterprise Season 4 Episode 22 These Are the Voyages", year: nil)
        movie.filePath = "/TV/Star Trek Enterprise Season 4 Episode 22 - These Are the Voyages.mkv"
        movie.isPlayable = true
        library.context.insert(movie)
        try library.context.save()

        let result = library.reclassifyMisplacedTitles()
        #expect(result.files == 1)
        let items = try library.context.fetch(FetchDescriptor<MediaItem>())
        #expect(items.filter { $0.kind == .movie }.isEmpty)
        let show = try #require(items.first { $0.kind == .series })
        #expect(show.id == existing.id)
        #expect(show.episodes.count == 1)
        #expect(show.episodes.first?.season == 4 && show.episodes.first?.number == 22)
        #expect(show.episodes.first?.name == "These Are the Voyages")
    }

    @Test func movieFiledAsAnEpisodeBecomesAMovie() throws {
        let library = try makeLibrary()
        let show = MediaItem(kind: .series, name: "Heat", year: nil)
        library.context.insert(show)
        let episode = MediaEpisode(season: 1, number: 1, name: "", filePath: "/Movies/Heat (1995).mkv", fileBookmark: nil, isPlayable: true)
        episode.show = show
        library.context.insert(episode)
        try library.context.save()

        library.reclassifyMisplacedTitles()
        let items = try library.context.fetch(FetchDescriptor<MediaItem>())
        #expect(items.count == 1)
        #expect(items.first?.kind == .movie)
        #expect(items.first?.name == "Heat")
        #expect(items.first?.year == 1995)
        #expect(items.first?.filePath == "/Movies/Heat (1995).mkv")
    }

    @Test func correctlyFiledAndLockedTitlesStay() throws {
        let library = try makeLibrary()
        let movie = MediaItem(kind: .movie, name: "Heat", year: 1995)
        movie.filePath = "/Movies/Heat (1995).mkv"
        library.context.insert(movie)
        let locked = MediaItem(kind: .movie, name: "My Edited Title", year: nil)
        locked.filePath = "/Movies/Show S01E01.mkv"
        locked.isMetadataLocked = true
        library.context.insert(locked)
        try library.context.save()

        #expect(library.reclassifyMisplacedTitles().files == 0)
        #expect(try library.context.fetch(FetchDescriptor<MediaItem>()).count == 2)
    }
}
