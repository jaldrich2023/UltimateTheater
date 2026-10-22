//
//  Ultimate_TheaterTests.swift
//  Ultimate TheaterTests
//
//  Created by John Aldrich on 10/21/26.
//

import Testing
import SQLite3
import Foundation
import SwiftUI
@testable import Ultimate_Theater

// MARK: - Fixtures

@MainActor
private func makeTitle(_ id: String, kind: TitleKind = .movie, genres: [Genre] = [.drama], maturity: String = "PG-13",
                       ratings: [ExternalRating] = [], episodes: Int = 0, seasons: Int = 1) -> Title {
    let seasonList = (1...max(seasons, 1)).map { season in
        Season(number: season, episodes: (0..<episodes).map { index in
            Episode(id: "\(id)-s\(season)e\(index + 1)", titleID: id, season: season, number: index + 1,
                    name: "Episode \(index + 1)", synopsis: "", runtimeMinutes: 45, stillURL: nil,
                    isPlayable: true, fileFormat: "MP4")
        })
    }
    return Title(id: id, name: id.capitalized, kind: kind, tagline: "", synopsis: "", year: 2020, maturity: maturity,
                 runtimeMinutes: 100, genres: genres, cast: ["Ada Lovelace"], director: "Grace Hopper", writers: ["Mary Shelley"],
                 studios: ["A24"], badges: [],
                 artwork: Artwork(colors: [.red, .blue, .black], symbol: "film"), posterURL: nil, backdropURL: nil,
                 ratings: ratings, metadataSources: [], needsMatch: false, isPlayable: true, fileFormat: "MP4",
                 dateAdded: .now, seasons: kind == .series ? seasonList : [])
}

// MARK: - Filename parsing

struct FilenameParserTests {
    @Test(arguments: [
        ("The.Matrix.1999.1080p.BluRay.x264-GROUP", "The Matrix", 1999),
        ("Blade Runner 2049 (2017)", "Blade Runner 2049", 2017),
        ("2001 A Space Odyssey 1968 2160p UHD", "2001 A Space Odyssey", 1968),
        ("[YTS] Heat (1995) [1080p]", "Heat", 1995),
        ("inception_2010_720p", "Inception", 2010),
        ("Arrival", "Arrival", nil),
    ] as [(String, String, Int?)])
    func movies(filename: String, title: String, year: Int?) {
        let parsed = FilenameParser.parse(filename: filename)
        #expect(parsed.title == title)
        #expect(parsed.year == year)
        #expect(!parsed.isEpisode)
    }

    @Test func seasonEpisodeTag() {
        let parsed = FilenameParser.parse(filename: "Severance - S01E02 - Half Loop")
        #expect(parsed.title == "Severance")
        #expect(parsed.season == 1)
        #expect(parsed.episode == 2)
        #expect(parsed.episodeTitle == "Half Loop")
    }

    @Test(arguments: [
        ("Star Trek Enterprise Season 4 Episode 22 - These Are the Voyages", "Star Trek Enterprise", 4, 22, "These Are the Voyages"),
        ("Doctor Who Series 2, Ep. 3 - School Reunion", "Doctor Who", 2, 3, "School Reunion"),
        ("The.Wire.Season.1.Episode.05.The.Pager.720p", "The Wire", 1, 5, "The Pager"),
        ("Fargo S2 E9 Castle", "Fargo", 2, 9, "Castle"),
    ] as [(String, String, Int, Int, String)])
    func spelledOutSeasonAndEpisode(filename: String, show: String, season: Int, episode: Int, title: String) {
        let parsed = FilenameParser.parse(filename: filename)
        #expect(parsed.title == show)
        #expect(parsed.season == season)
        #expect(parsed.episode == episode)
        #expect(parsed.episodeTitle == title)
    }

    @Test func episodeWordInsideSeasonFolder() {
        let parsed = FilenameParser.parse(filename: "Star Trek Enterprise Episode 22 - These Are the Voyages",
                                          folders: ["Season 4", "Star Trek Enterprise"])
        #expect(parsed.title == "Star Trek Enterprise")
        #expect(parsed.season == 4)
        #expect(parsed.episode == 22)
        #expect(parsed.episodeTitle == "These Are the Voyages")
    }

    @Test func movieWithEpisodeInItsTitleStaysAMovie() {
        let parsed = FilenameParser.parse(filename: "Star Wars Episode 4 - A New Hope (1977)")
        #expect(!parsed.isEpisode)
        #expect(parsed.year == 1977)
    }

    @Test func sceneStyleEpisode() {
        let parsed = FilenameParser.parse(filename: "the.office.us.s02e05.720p.web-dl")
        #expect(parsed.title == "The Office Us")
        #expect(parsed.season == 2)
        #expect(parsed.episode == 5)
        #expect(parsed.episodeTitle == nil)
    }

    @Test func crossStyleEpisode() {
        let parsed = FilenameParser.parse(filename: "Firefly 1x07 Jaynestown")
        #expect(parsed.title == "Firefly")
        #expect(parsed.season == 1)
        #expect(parsed.episode == 7)
    }

    @Test func seasonFolderLayout() {
        let parsed = FilenameParser.parse(filename: "07 - One Minute", folders: ["Season 3", "Breaking Bad", "TV"])
        #expect(parsed.title == "Breaking Bad")
        #expect(parsed.season == 3)
        #expect(parsed.episode == 7)
        #expect(parsed.episodeTitle == "One Minute")
    }

    @Test func episodeWithoutShowNameUsesFolder() {
        let parsed = FilenameParser.parse(filename: "S02E01", folders: ["Season 2", "Andor (2022)"])
        #expect(parsed.title == "Andor")
        #expect(parsed.year == 2022)
        #expect(parsed.season == 2)
    }

    @Test func genericFilenameUsesFolder() {
        let parsed = FilenameParser.parse(filename: "movie", folders: ["Inception (2010)"])
        #expect(parsed.title == "Inception")
        #expect(parsed.year == 2010)
    }

    @Test func yearBorrowedFromMatchingFolder() {
        let parsed = FilenameParser.parse(filename: "Heat", folders: ["Heat (1995)"])
        #expect(parsed.year == 1995)
    }

    @Test func videoFileDetection() {
        #expect(FilenameParser.isVideoFile(URL(fileURLWithPath: "/m/Heat.mkv")))
        #expect(FilenameParser.isVideoFile(URL(fileURLWithPath: "/m/Heat.M4V")))
        #expect(!FilenameParser.isVideoFile(URL(fileURLWithPath: "/m/Heat.srt")))
        #expect(!FilenameParser.isVideoFile(URL(fileURLWithPath: "/m/heat-sample.mkv")))
    }

    @Test func normalizedKeysIgnoreArticlesAndPunctuation() {
        #expect(FilenameParser.normalizedKey("The Office") == FilenameParser.normalizedKey("office"))
        #expect(FilenameParser.normalizedKey("Spider-Man: No Way Home") == "spidermannowayhome")
    }
}

// MARK: - Matching & merging

struct MetadataMatchingTests {
    private func candidate(_ title: String, _ year: Int?, kind: TitleKind = .movie,
                           provider: MetadataProviderID = .tmdb) -> MetadataCandidate {
        MetadataCandidate(provider: provider, externalID: title, title: title, year: year, kind: kind,
                          overview: nil, posterURL: nil)
    }

    @Test func exactTitleAndYearWins() {
        let query = MetadataQuery(title: "Dune", year: 2021, kind: .movie)
        let best = MetadataMatcher.best([candidate("Dune", 1984), candidate("Dune", 2021), candidate("Dune: Part Two", 2024)], for: query)
        #expect(best?.year == 2021)
    }

    @Test func wrongKindNeverMatches() {
        let query = MetadataQuery(title: "Fargo", year: nil, kind: .series)
        #expect(MetadataMatcher.score(candidate("Fargo", 1996, kind: .movie), for: query) == 0)
    }

    @Test func unrelatedTitlesFallBelowThreshold() {
        let query = MetadataQuery(title: "Arrival", year: 2016, kind: .movie)
        #expect(MetadataMatcher.best([candidate("The Arrival of a Train", 1896)], for: query) == nil)
    }

    @Test func mergePrefersTMDBButTakesRatingsFromEverySource() throws {
        var tmdb = MetadataRecord(provider: .tmdb)
        tmdb.title = "Inception"
        tmdb.synopsis = "TMDB synopsis"
        tmdb.maturity = "PG-13"
        tmdb.ratings = [ExternalRating(source: .tmdb, score: 84, display: "84%")]

        var omdb = MetadataRecord(provider: .omdb)
        omdb.title = "Inception (OMDb)"
        omdb.synopsis = "OMDb plot"
        omdb.maturity = "PG-13 (OMDb)"
        omdb.runtimeMinutes = 148
        omdb.ratings = [ExternalRating(source: .imdb, score: 88, display: "8.8"),
                        ExternalRating(source: .rottenTomatoes, score: 87, display: "87%")]

        var wikipedia = MetadataRecord(provider: .wikipedia)
        wikipedia.director = "Christopher Nolan"

        let merged = try #require(MetadataMerger.merge([wikipedia, omdb, tmdb]))
        #expect(merged.record.title == "Inception")
        #expect(merged.record.synopsis == "TMDB synopsis")
        #expect(merged.record.maturity == "PG-13 (OMDb)") // OMDb leads for content ratings.
        #expect(merged.record.runtimeMinutes == 148)      // Filled from OMDb when TMDB lacks it.
        #expect(merged.record.director == "Christopher Nolan")
        #expect(merged.record.ratings.map(\.source) == [.imdb, .rottenTomatoes, .tmdb])
        #expect(merged.sources == [.tmdb, .omdb, .wikipedia])
    }

    @Test func omdbRatingStringsAreNormalized() throws {
        let imdb = try #require(OMDbProvider.rating(from: .init(source: "Internet Movie Database", value: "8.8/10")))
        #expect(imdb.score == 88 && imdb.display == "8.8")
        let rt = try #require(OMDbProvider.rating(from: .init(source: "Rotten Tomatoes", value: "87%")))
        #expect(rt.score == 87 && rt.display == "87%")
        let mc = try #require(OMDbProvider.rating(from: .init(source: "Metacritic", value: "74/100")))
        #expect(mc.source == .metacritic && mc.score == 74)
        #expect(OMDbProvider.normalizedRating("Not Rated") == "NR")
        #expect(OMDbProvider.normalizedRating("N/A") == nil)
    }

    @Test func wikipediaDescriptionsAreClassified() {
        #expect(WikipediaProvider.describes(.movie, "2010 film by Christopher Nolan"))
        #expect(!WikipediaProvider.describes(.movie, "2010 soundtrack album by Hans Zimmer"))
        #expect(WikipediaProvider.describes(.series, "American television series (2022–present)"))
        #expect(!WikipediaProvider.describes(.series, "Fictional character in The Matrix"))
        #expect(WikipediaProvider.cleanTitle("Severance (TV series)") == "Severance")
        #expect(WikipediaProvider.cleanTitle("Heat (1995 film)") == "Heat")
    }

    @Test func textHelpers() {
        #expect(MetadataText.year(in: "2022–") == 2022)
        #expect(MetadataText.plainText("<p>A <b>bold</b> &amp; brave show.</p>") == "A bold & brave show.")
        #expect(MetadataText.minutes("148 min") == 148)
        #expect(MetadataText.list("Drama, Sci-Fi") == ["Drama", "Sci-Fi"])
    }
}

// MARK: - Genres

@MainActor
struct GenreMappingTests {
    @Test func providerGenresMapToAppGenres() {
        #expect(Genre.from(providerName: "Science Fiction") == [.sciFi])
        #expect(Genre.from(providerName: "Sci-Fi & Fantasy") == [.sciFi, .fantasy])
        #expect(Genre.from(providerName: "Action & Adventure") == [.action])
        #expect(Genre.from(providerName: "Crime") == [.thriller])
        #expect(Genre.from(providerNames: ["Drama", "Science-Fiction", "Mystery", "Drama"]) == [.drama, .sciFi, .mystery])
    }
}

// MARK: - Watch history

@MainActor
struct WatchHistoryTests {
    private let profileID = "primary"

    private func progress(_ title: Title, _ playbackID: String, position: Double, duration: Double = 100,
                          ago: TimeInterval = 0) -> WatchProgress {
        let entry = WatchProgress(profileID: profileID, titleID: title.id, playbackID: playbackID,
                                  position: position, duration: duration)
        entry.lastWatched = Date.now.addingTimeInterval(-ago)
        return entry
    }

    @Test func movieWithoutProgressStartsAtBeginning() {
        let movie = makeTitle("heat")
        let resume = WatchHistory.resumePoint(for: movie, in: [])
        #expect(resume.position == 0)
        #expect(resume.label == "Play")
    }

    @Test func partiallyWatchedMovieResumes() {
        let movie = makeTitle("heat")
        let resume = WatchHistory.resumePoint(for: movie, in: [progress(movie, movie.id, position: 40)])
        #expect(resume.position == 40)
        #expect(resume.label == "Resume")
    }

    @Test func finishedEpisodeAdvancesToNext() throws {
        let show = makeTitle("severance", kind: .series, episodes: 3)
        let first = try #require(show.allEpisodes.first)
        let resume = WatchHistory.resumePoint(for: show, in: [progress(show, first.id, position: 99)])
        #expect(resume.item.episode == show.episode(after: first))
        #expect(resume.position == 0)
    }

    @Test func lastEpisodeOfSeasonRollsIntoNextSeason() throws {
        let show = makeTitle("severance", kind: .series, episodes: 2, seasons: 2)
        let lastOfSeasonOne = try #require(show.seasons.first?.episodes.last)
        let next = try #require(show.episode(after: lastOfSeasonOne))
        #expect(next.season == 2 && next.number == 1)
    }

    @Test func continueWatchingSkipsFinishedAndDeduplicatesTitles() {
        let show = makeTitle("andor", kind: .series, episodes: 3)
        let movie = makeTitle("heat")
        let finished = makeTitle("arrival")
        let episodes = show.allEpisodes
        let entries = [
            progress(show, episodes[1].id, position: 30, ago: 10),
            progress(show, episodes[0].id, position: 99, ago: 100),
            progress(movie, movie.id, position: 20, ago: 50),
            progress(finished, finished.id, position: 99, ago: 5),
        ]
        let rows = WatchHistory.continueWatching(entries, titles: [show, movie, finished])
        #expect(rows.map(\.title.id) == ["andor", "heat"])
        #expect(rows.first?.entry.playbackID == episodes[1].id)
    }

    @Test func similarTitlesShareGenresAndExcludeSelf() {
        let base = makeTitle("dune", genres: [.sciFi, .action])
        let library = [base, makeTitle("arrival", genres: [.sciFi]), makeTitle("heat", genres: [.thriller]),
                       makeTitle("alien", genres: [.sciFi, .horror])]
        let similar = WatchHistory.similar(to: base, in: library)
        #expect(similar.map(\.id).sorted() == ["alien", "arrival"])
    }

    @Test func criticScorePrefersRottenTomatoes() {
        let title = makeTitle("heat", ratings: [ExternalRating(source: .imdb, score: 83, display: "8.3"),
                                                 ExternalRating(source: .rottenTomatoes, score: 88, display: "88%")])
        #expect(title.criticScore == 88)
        #expect(makeTitle("unrated").criticScore == nil)
    }

    @Test func directorCreditsSplitIntoNames() {
        let title = Title(id: "m", name: "Matrix", kind: .movie, tagline: "", synopsis: "", year: nil, maturity: "",
                          runtimeMinutes: 0, genres: [], cast: [], director: "Lana Wachowski, Lilly Wachowski",
                          writers: [], studios: [], badges: [], artwork: Artwork(colors: [], symbol: "film"),
                          posterURL: nil, backdropURL: nil, ratings: [], metadataSources: [], needsMatch: false,
                          isPlayable: true, fileFormat: "", dateAdded: .now, seasons: [])
        #expect(title.directors == ["Lana Wachowski", "Lilly Wachowski"])
    }

    @Test func libraryAndUsersAreSeparateSQLiteDatabases() throws {
        // The app host opened both databases at launch.
        func tables(_ url: URL) throws -> Set<String> {
            let handle = try FileHandle(forReadingFrom: url)
            let header = try #require(try handle.read(upToCount: 16))
            try handle.close()
            #expect(String(decoding: header, as: UTF8.self) == "SQLite format 3\0")
            var database: OpaquePointer?
            guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_close(database) }
            var statement: OpaquePointer?
            sqlite3_prepare_v2(database, "SELECT name FROM sqlite_master WHERE type = 'table'", -1, &statement, nil)
            defer { sqlite3_finalize(statement) }
            var names: Set<String> = []
            while sqlite3_step(statement) == SQLITE_ROW { names.insert(String(cString: sqlite3_column_text(statement, 0))) }
            return names
        }
        let library = try tables(LibraryStore.databaseURL)
        let users = try tables(LibraryStore.usersDatabaseURL)
        #expect(library.contains("ZMEDIAITEM") && library.contains("ZLIBRARYFOLDER"))
        #expect(!library.contains("ZSTOREDPROFILE") && !library.contains("ZWATCHPROGRESS"))
        #expect(users.isSuperset(of: ["ZSTOREDPROFILE", "ZWATCHPROGRESS", "ZMYLISTENTRY", "ZUSERRATING"]))
        #expect(!users.contains("ZMEDIAITEM"))
    }

    @Test func pinsAreStoredAsSaltedHashes() {
        let first = PINHash.make("1234")
        let second = PINHash.make("1234")
        #expect(first != second && !first.contains("1234")) // Salted, never the PIN itself.
        #expect(PINHash.verify("1234", against: first) && PINHash.verify("1234", against: second))
        #expect(!PINHash.verify("1235", against: first) && !PINHash.verify("", against: first))
        #expect(PINHash.isValid("0420") && !PINHash.isValid("12a4") && !PINHash.isValid("123"))
    }

    @Test func profileRatingLimits() {
        func title(_ maturity: String, _ certifications: [String: String] = [:]) -> Title {
            var title = makeTitle("t", maturity: maturity)
            title.certifications = certifications
            return title
        }
        let older = Profile(id: "k", name: "Kids", symbol: "star.fill", paletteIndex: 0, ratingLimit: .olderKids, allowsUnrated: false)
        #expect(older.allows(title("PG"), country: "US") && older.allows(title("TV-Y7"), country: "US"))
        #expect(!older.allows(title("PG-13"), country: "US") && !older.allows(title("R"), country: "US"))
        #expect(!older.allows(title(""), country: "US") && !older.allows(title("NR"), country: "US"))
        var withUnrated = older
        withUnrated.allowsUnrated = true
        #expect(withUnrated.allows(title("Not Rated"), country: "US"))
        let adult = Profile(id: "a", name: "Adult", symbol: "person.fill", paletteIndex: 1, ratingLimit: .everything, allowsUnrated: false)
        #expect(adult.allows(title("NC-17"), country: "US") && adult.allows(title(""), country: "US"))

        // Each country's own certification decides; the strictest one is used when it's missing.
        let film = title("PG-13", ["US": "PG-13", "GB": "12A", "DE": "16"])
        let teen = Profile(id: "t", name: "Teen", symbol: "bolt.fill", paletteIndex: 2, ratingLimit: .teens, allowsUnrated: false)
        #expect(teen.allows(film, country: "US") && teen.allows(film, country: "GB"))
        #expect(!teen.allows(film, country: "DE"))       // FSK 16
        #expect(!teen.allows(film, country: "FR"))       // No French rating: strictest known (FSK 16).
    }

    @Test func ratingSystemsAroundTheWorld() {
        #expect(ContentRating.level(of: "pg-13") == .teens && ContentRating.level(of: "TV-PG") == .olderKids)
        #expect(ContentRating.level(of: "12A", country: "GB") == .teens && ContentRating.level(of: "15", country: "GB") == .everything)
        #expect(ContentRating.level(of: "R15+", country: "JP") == .teens && ContentRating.level(of: "PG12", country: "JP") == .olderKids)
        #expect(ContentRating.level(of: "A", country: "IN") == .everything && ContentRating.level(of: "A", country: "DK") == .littleKids)
        #expect(ContentRating.level(of: "MA15+", country: "AU") == .everything && ContentRating.level(of: "M", country: "AU") == .teens)
        #expect(ContentRating.level(of: "K-12", country: "XX") == .teens)   // Unknown system: read by age.
        #expect(ContentRating.level(of: "Unrated") == nil)
        #expect(RatingLimit.teens.allowedRatings(in: "US") == ["G", "TV-Y", "TV-G", "PG", "TV-Y7", "TV-Y7-FV", "TV-PG", "PG-13", "TV-14"])
    }
}

// MARK: - Filters & index

@MainActor
struct TitleFilterTests {
    @Test func valuesWithinAFacetAreOredAndFacetsAreAnded() {
        let drama = makeTitle("heat", genres: [.drama])
        let scifi = makeTitle("dune", genres: [.sciFi])
        let horror = makeTitle("alien", genres: [.horror])
        var filter = TitleFilter()
        filter[.genre] = ["Drama", "Sci-Fi"]
        #expect(filter.apply([drama, scifi, horror]).map(\.id) == ["heat", "dune"])

        filter[.year] = ["1999"]
        #expect(filter.apply([drama, scifi, horror]).isEmpty) // Fixtures are all 2020.
        filter[.year] = ["2020"]
        #expect(filter.apply([drama, scifi, horror]).count == 2)
    }

    @Test func peopleAndStudioFacetsUseTitleCredits() {
        let title = makeTitle("heat")
        #expect(TitleFacet.actor.values(of: title) == ["Ada Lovelace"])
        #expect(TitleFacet.writer.values(of: title) == ["Mary Shelley"])
        #expect(TitleFacet.studio.values(of: title) == ["A24"])
        #expect(TitleFacet.director.values(of: title) == ["Grace Hopper"])
    }

    @Test func optionsCountTitlesPerValue() {
        let options = TitleFacet.genre.options(in: [makeTitle("a", genres: [.drama]), makeTitle("b", genres: [.drama, .comedy])])
        #expect(options.first { $0.value == "Drama" }?.count == 2)
        #expect(options.first { $0.value == "Comedy" }?.count == 1)
    }

    @Test func sortNameAndIndexIgnoreLeadingArticles() {
        #expect(makeTitle("the matrix").sortName == "Matrix")
        #expect(makeTitle("the matrix").indexCharacter == "M")
        #expect(makeTitle("an education").indexCharacter == "E")
        #expect(makeTitle("2001").indexCharacter == "2")
        #expect(makeTitle("élite").indexCharacter == "E")
        #expect(makeTitle("the").sortName == "The")
    }
}

// MARK: - Audio & subtitle selection

@MainActor
struct PlaybackSelectionTests {
    private let tracks = MediaTrackList(
        audio: [
            TrackOption(id: "1", kind: .audio, languageCode: "eng", name: nil, format: "Dolby Digital 5.1", isDefault: true),
            TrackOption(id: "2", kind: .audio, languageCode: "spa", name: nil, format: "AAC Stereo"),
            TrackOption(id: "3", kind: .audio, languageCode: "fra", name: nil, format: "DTS", isSupported: false),
        ],
        subtitles: [
            TrackOption(id: "4", kind: .subtitle, languageCode: "eng", name: nil, format: nil, isForced: true),
            TrackOption(id: "5", kind: .subtitle, languageCode: "eng", name: "SDH", format: nil, isSDH: true),
            TrackOption(id: "6", kind: .subtitle, languageCode: "spa", name: nil, format: nil),
        ]
    )

    @Test func automaticPicksDefaultAudioAndMatchingForcedSubtitles() {
        let resolved = PlaybackSelection.automatic.resolve(in: tracks)
        #expect(resolved.audio?.id == "1")
        #expect(resolved.subtitle?.id == "4")
    }

    @Test func savedPreferenceMatchesByLanguageAndFlags() {
        let spanish = PlaybackSelection(audio: TrackPreference(tracks.audio[1]), subtitles: .track(TrackPreference(tracks.subtitles[1])))
        let resolved = spanish.resolve(in: tracks)
        #expect(resolved.audio?.id == "2")
        #expect(resolved.subtitle?.id == "5")
        #expect(PlaybackSelection(audio: nil, subtitles: .off).resolve(in: tracks).subtitle == nil)
    }

    @Test func unsupportedAudioIsNeverChosen() {
        let french = PlaybackSelection(audio: TrackPreference(tracks.audio[2]))
        #expect(french.resolve(in: tracks).audio?.id == "1")
    }

    @Test func changingTracksMarksTheChoiceCustomized() {
        var choice = TrackChoice(list: tracks, saved: nil)
        #expect(!choice.isCustomized)
        choice.subtitleID = "6"
        #expect(choice.isCustomized)
        #expect(choice.selection?.subtitles == .track(TrackPreference(tracks.subtitles[2])))
        choice.markSaved()
        #expect(!choice.isCustomized)
    }

    @Test func trackTitlesAreReadable() {
        #expect(tracks.audio[0].title == "English")
        #expect(TrackPickers.label(tracks.audio[0]) == "English · Dolby Digital 5.1")
        #expect(tracks.subtitles[0].title == "English (Forced)")
        #expect(tracks.audio[2].detail == "DTS · not supported")
    }
}

@MainActor
struct RatingFacetTests {
    @Test func myRatingBuckets() {
        #expect(TitleFacet.myRatingBucket(nil) == "Not Rated")
        #expect(TitleFacet.myRatingBucket(9.5) == "9–10")
        #expect(TitleFacet.myRatingBucket(8.5) == "7–8.5")
        #expect(TitleFacet.myRatingBucket(5) == "5–6.5")
        #expect(TitleFacet.myRatingBucket(2) == "Below 5")
    }

    @Test func ratedAndMyRatingFilters() {
        let pg = makeTitle("up", maturity: "PG")
        let r = makeTitle("heat", maturity: "R")
        let ratings = ["heat": 9.0]
        var filter = TitleFilter()
        filter[.rated] = ["PG-13", "R"]
        #expect(filter.apply([pg, r], ratings: ratings).map(\.id) == ["heat"])
        filter = TitleFilter()
        filter[.myRating] = ["Not Rated"]
        #expect(filter.apply([pg, r], ratings: ratings).map(\.id) == ["up"])
        #expect(TitleFacet.rated.options(in: [r, pg]).map(\.value) == ["PG", "R"])
        #expect(BrowseSort.myRating.apply([pg, r], ratings: ratings).first?.id == "heat")
        #expect(UserRating.display(8.5) == "8.5" && UserRating.display(7) == "7")
    }
}

@MainActor
struct CollectionTests {
    @Test func collectionsGroupMoviesInReleaseOrder() {
        let matrix = CollectionInfo(id: 2344, name: "The Matrix Collection")
        var first = makeTitle("matrix")
        first.collection = matrix
        var second = Title(id: "reloaded", name: "The Matrix Reloaded", kind: .movie, tagline: "", synopsis: "", year: 2003,
                           maturity: "R", runtimeMinutes: 0, genres: [], cast: [], director: "", writers: [], studios: [],
                           badges: [], artwork: Artwork(colors: [], symbol: "film"), posterURL: nil, backdropURL: nil,
                           ratings: [], metadataSources: [], needsMatch: false, isPlayable: true, fileFormat: "",
                           dateAdded: .now, seasons: [])
        second.collection = matrix
        let collection = MovieCollection(info: matrix, movies: [first, second].sorted { ($0.year ?? 0) < ($1.year ?? 0) })
        #expect(collection.movies.map(\.id) == ["reloaded", "matrix"]) // 2003, then the 2020 fixture
        #expect(collection.displayName == "The Matrix")
        #expect(collection.sortName == "Matrix")
        #expect(collection.indexCharacter == "M")
        #expect(collection.years == "2003–2020")
    }

    @Test func articlesAreStrippedOnce() {
        #expect(Title.sortName(for: "The A-Team") == "A-Team")
        #expect(Title.indexCharacter(forSortName: Title.sortName(for: "The A-Team")) == "A")
    }

    @Test func trailerURLs() {
        let trailer = TrailerInfo(site: "YouTube", key: "abc123", name: "Official Trailer")
        #expect(trailer.embedURL?.host() == "www.youtube-nocookie.com")
        #expect(trailer.watchURL?.absoluteString == "https://www.youtube.com/watch?v=abc123")
        #expect(TrailerInfo(site: "Unknown", key: "x", name: "").embedURL == nil)
    }
}
