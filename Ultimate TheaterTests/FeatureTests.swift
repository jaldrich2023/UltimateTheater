//
//  FeatureTests.swift
//  Ultimate TheaterTests
//
//  Watched tags and progress, sort directions, the administrator role, the approval queue,
//  favourite scenes, episode navigation, and the new decoders' handling of bad input.
//

import Testing
import Foundation
import SwiftData
import SwiftUI
@testable import Ultimate_Theater

@MainActor
private func title(_ id: String, kind: TitleKind = .movie, year: Int = 2020, episodes: Int = 0, seasons: Int = 1,
                   added: Date = .now) -> Title {
    let seasonList = (1...max(seasons, 1)).map { season in
        Season(number: season, episodes: (0..<episodes).map { index in
            Episode(id: "\(id)-s\(season)e\(index + 1)", titleID: id, season: season, number: index + 1,
                    name: "Episode \(index + 1)", synopsis: "", runtimeMinutes: 45, stillURL: nil,
                    isPlayable: true, fileFormat: "MP4")
        })
    }
    return Title(id: id, name: id.capitalized, kind: kind, tagline: "", synopsis: "", year: year, maturity: "PG-13",
                 runtimeMinutes: 100, genres: [.drama], cast: [], director: "", writers: [], studios: [], badges: [],
                 artwork: Artwork(colors: [.red, .blue, .black], symbol: "film"), posterURL: nil, backdropURL: nil,
                 ratings: [], metadataSources: [], needsMatch: false, isPlayable: true, fileFormat: "MP4",
                 dateAdded: added, seasons: kind == .series ? seasonList : [])
}

@MainActor
private func usersContext() throws -> ModelContext {
    let configuration = ModelConfiguration("Users", schema: LibraryStore.usersSchema, isStoredInMemoryOnly: true)
    return ModelContext(try ModelContainer(for: LibraryStore.usersSchema, configurations: [configuration]))
}

@MainActor
private func library() throws -> MediaLibrary {
    let configuration = ModelConfiguration("Library", schema: LibraryStore.librarySchema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: LibraryStore.librarySchema, configurations: [configuration])
    return MediaLibrary(container: container, metadata: MetadataService(settings: testMetadataSettings()))
}

@MainActor
struct WatchedTagTests {
    @Test func markingAMovieWatchedAndUnwatched() throws {
        let context = try usersContext()
        let movie = title("heat")
        WatchHistory.setWatched(true, movie, profileID: "p", in: context)
        // Unwatching uses a batch delete, which only sees saved rows (as in the app, where
        // autosave runs between the two actions).
        try context.save()
        var progress = try context.fetch(FetchDescriptor<WatchProgress>())
        #expect(WatchHistory.isWatched(movie, in: progress))
        #expect(WatchHistory.partialProgress(movie, in: progress) == nil)

        WatchHistory.setWatched(false, movie, profileID: "p", in: context)
        progress = try context.fetch(FetchDescriptor<WatchProgress>())
        #expect(progress.isEmpty)
        #expect(!WatchHistory.isWatched(movie, in: progress))
    }

    @Test func aShowIsWatchedOnlyWhenEveryEpisodeIs() throws {
        let context = try usersContext()
        let show = title("lost", kind: .series, episodes: 3, seasons: 2)
        let episode = try #require(show.allEpisodes.first)
        WatchHistory.saveProgress(PlaybackItem(title: show, episode: episode), profileID: "p", position: 2700, duration: 2700, in: context)
        #expect(!WatchHistory.isWatched(show, in: try context.fetch(FetchDescriptor<WatchProgress>())))

        WatchHistory.setWatched(true, show, profileID: "p", in: context)
        let progress = try context.fetch(FetchDescriptor<WatchProgress>())
        #expect(progress.count == 6)
        #expect(WatchHistory.isWatched(show, in: progress))
    }

    @Test func partlyWatchedMoviesShowProgress() throws {
        let context = try usersContext()
        let movie = title("arrival")
        WatchHistory.saveProgress(PlaybackItem(title: movie, episode: nil), profileID: "p", position: 3000, duration: 6000, in: context)
        let progress = try context.fetch(FetchDescriptor<WatchProgress>())
        #expect(WatchHistory.partialProgress(movie, in: progress) == 0.5)
        #expect(!WatchHistory.isWatched(movie, in: progress))
    }
}

@MainActor
struct SortDirectionTests {
    @Test func everyOrderReversesOnRequest() {
        let old = title("casablanca", year: 1942, added: .now.addingTimeInterval(-100))
        let mid = title("heat", year: 1995, added: .now.addingTimeInterval(-50))
        let new = title("arrival", year: 2016, added: .now)
        let titles = [mid, new, old]

        #expect(BrowseSort.newest.apply(titles).map(\.id) == ["arrival", "heat", "casablanca"])
        #expect(BrowseSort.newest.apply(titles, ascending: true).map(\.id) == ["casablanca", "heat", "arrival"])
        #expect(BrowseSort.alphabetical.apply(titles).map(\.id) == ["arrival", "casablanca", "heat"])
        #expect(BrowseSort.alphabetical.apply(titles, ascending: false).map(\.id) == ["heat", "casablanca", "arrival"])
        #expect(BrowseSort.recentlyAdded.apply(titles, ascending: true).map(\.id) == ["casablanca", "heat", "arrival"])
        #expect(BrowseSort.alphabetical.defaultAscending && !BrowseSort.newest.defaultAscending)
    }
}

@MainActor
struct AdministratorRoleTests {
    /// A model on its own preferences suite (emptied first), so `select(_:)` never touches real defaults.
    /// A fixed name keeps a single scratch domain instead of one per run (these synchronous @MainActor tests never overlap).
    private func model() throws -> AppModel {
        let suite = "UltimateTheaterTests.AdministratorRole"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let model = AppModel(library: try library(), defaults: defaults)
        model.modelContext = try usersContext()
        return model
    }

    private func draft(_ name: String, limit: RatingLimit = .everything, administrator: Bool = false) -> ProfileDraft {
        var draft = ProfileDraft()
        draft.name = name
        draft.ratingLimit = limit
        draft.isAdministrator = administrator
        return draft
    }

    @Test func theFirstProfileIsTheAdministrator() throws {
        let model = try model()
        let first = try #require(model.saveProfile(draft("Parent")))
        let second = try #require(model.saveProfile(draft("Kid", limit: .littleKids)))
        #expect(first.isAdministrator && !second.isAdministrator)

        model.select(second)
        #expect(!model.canManageLibrary)
        model.select(first)
        #expect(model.canManageLibrary)
    }

    @Test func thereIsAlwaysExactlyOneAdministrator() throws {
        let model = try model()
        let first = try #require(model.saveProfile(draft("Parent")))
        // Taking the role away from the only administrator is refused.
        var demoted = ProfileDraft(first)
        demoted.isAdministrator = false
        #expect(model.saveProfile(demoted)?.isAdministrator == true)

        // Giving it to someone else moves it, and lifts their content limit.
        let kid = try #require(model.saveProfile(draft("Teen", limit: .teens)))
        var promoted = ProfileDraft(kid)
        promoted.isAdministrator = true
        let saved = try #require(model.saveProfile(promoted))
        #expect(saved.isAdministrator && saved.ratingLimit == .everything)
        #expect(model.profiles.filter(\.isAdministrator).map(\.id) == [saved.id])
    }
}

@MainActor
struct ApprovalQueueTests {
    @Test func ignoredVideosLeaveTheQueue() throws {
        let library = try library()
        library.context.insert(PendingMedia(path: "/Volumes/Movies/New Film (2024).mkv"))
        library.context.insert(PendingMedia(path: "/Volumes/Movies/Other.mkv"))
        try library.context.save()
        library.reload()
        #expect(library.pending.count == 2)

        library.ignorePending([library.pending[0]])
        #expect(library.pending.count == 1)
        // Ignored entries stay on record so they aren't offered again.
        #expect(try library.context.fetch(FetchDescriptor<PendingMedia>()).count == 2)
    }
}

@MainActor
struct SceneAndEpisodeTests {
    @Test func favouriteSceneTimes() {
        #expect(SceneBookmark(profileID: "p", titleID: "t", playbackID: "t", time: 725).timeText == "12:05")
        #expect(SceneBookmark(profileID: "p", titleID: "t", playbackID: "t", time: 3735).timeText == "1:02:15")
    }

    @Test func previousAndNextEpisodesCrossSeasons() throws {
        let show = title("lost", kind: .series, episodes: 2, seasons: 2)
        let episodes = show.allEpisodes
        #expect(show.episode(before: episodes[0]) == nil)
        #expect(show.episode(before: episodes[2])?.id == episodes[1].id)
        #expect(show.episode(after: episodes[1])?.id == episodes[2].id)
        #expect(show.episode(after: episodes[3]) == nil)
    }
}

struct NewDecoderRobustnessTests {
    @Test func mpeg4DecoderSurvivesGarbage() {
        let decoder = MPEG4Decoder(configuration: nil)
        var generator = SeededGenerator(state: 0x4D50_4734) // Same garbage on every run.
        for size in [0, 1, 7, 64, 4096] {
            let junk = Data((0..<size).map { _ in UInt8.random(in: 0...255, using: &generator) })
            let pictures = (try? decoder.decode(junk)) ?? []
            #expect(pictures.isEmpty)
        }
        decoder.reset()
        #expect(decoder.flush().isEmpty)
    }

    @Test func trueHDFramerFindsNothingInGarbage() {
        var framer = TrueHDFramer()
        let junk = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        #expect(framer.push(junk).isEmpty)
        #expect(TrueHDDecoder().decode(junk) == nil)
    }

    @Test func dtsVectorTablesAreComplete() {
        #expect(DTSVectorTables.prediction.count == 4096 * 4)
        #expect(DTSVectorTables.highFrequency.count == 1024 * 32)
        #expect(DTSVectorTables.prediction.prefix(4) == [9928, -2618, -1093, -1263])
    }
}

struct LegalTextTests {
    /// LICENSE and THIRD_PARTY_NOTICES.md are bundled as resources, so the About window can show them.
    @Test func aboutWindowLoadsTheBundledDocuments() {
        let missing = String(localized: "This document couldn't be loaded from the app bundle.")
        #expect(LegalDocument.license.text != missing)
        #expect(LegalDocument.license.text.contains("Ultimate Theater"))
        #expect(LegalDocument.thirdPartyNotices.text != missing)
        #expect(!LegalDocument.thirdPartyNotices.text.isEmpty)
    }
}
