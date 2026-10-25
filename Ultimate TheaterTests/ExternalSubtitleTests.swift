//
//  ExternalSubtitleTests.swift
//  Ultimate TheaterTests
//
//  External subtitles: SubRip / WebVTT parsing (odd timestamps, BOM, CRLF, legacy
//  encodings), the OpenSubtitles file hash, sidecar file names, and API query encoding.
//

import Testing
import Foundation
@testable import Ultimate_Theater

struct ExternalSubtitleTests {
    // MARK: SubRip

    @Test func parsesBasicSubRip() throws {
        let srt = """
        1
        00:00:01,000 --> 00:00:02,500
        Hello <i>there</i>.

        2
        00:00:03,000 --> 00:00:04,000
        Two
        lines
        """
        let cues = try SubtitleFileParser.parse(Data(srt.utf8))
        #expect(cues.count == 2)
        #expect(cues[0].start == 1)
        #expect(cues[0].end == 2.5)
        #expect(cues[0].text == "Hello there.")
        #expect(cues[1].text == "Two\nlines")
    }

    @Test func handlesBOMAndCRLF() throws {
        let srt = "1\r\n00:00:05,250 --> 00:00:06,000\r\nCRLF line\r\n\r\n2\r\n00:00:07,000 --> 00:00:08,000\r\nNext\r\n"
        let cues = try SubtitleFileParser.parse(Data([0xEF, 0xBB, 0xBF]) + Data(srt.utf8))
        #expect(cues.count == 2)
        #expect(cues[0].start == 5.25)
        #expect(cues[0].text == "CRLF line")
    }

    @Test func toleratesOddTimestamps() {
        #expect(SubtitleFileParser.timestamp("0:00:01,5") == 1.5)
        #expect(SubtitleFileParser.timestamp("00:01:02.345") == 62.345)
        #expect(SubtitleFileParser.timestamp("01:02.5") == 62.5)
        #expect(SubtitleFileParser.timestamp("01:00:00:250") == 3600.25)
        #expect(SubtitleFileParser.timestamp("1:02:03") == 3723)
        #expect(SubtitleFileParser.timestamp("abc") == nil)
        #expect(SubtitleFileParser.timestamp("00:-1:00,000") == nil)
    }

    @Test func recoversFromMissingBlankLinesAndIndexes() {
        let srt = """
        00:00:01,000 --> 00:00:02,000
        No index here
        2
        00:00:03,000 --> 00:00:04,000
        Index without a blank line


        00:00:05,000 --> 00:00:04,000
        Ends before it starts
        """
        let cues = SubtitleFileParser.parse(text: srt)
        #expect(cues.map(\.text) == ["No index here", "Index without a blank line"])
    }

    @Test func stripsMarkupAndEntities() {
        let cue = SubtitleFileParser.parse(text: "00:00:01,000 --> 00:00:02,000\n{\\an8}<font color=\"red\">Tom &amp; Jerry</font>")
        #expect(cue.first?.text == "Tom & Jerry")
    }

    @Test func decodesWindows1252() throws {
        // "Café" in Windows-1252 isn't valid UTF-8.
        var data = Data("00:00:01,000 --> 00:00:02,000\nCaf".utf8)
        data.append(0xE9)
        let cues = try SubtitleFileParser.parse(data)
        #expect(cues.first?.text == "Café")
    }

    @Test func rejectsNonSubtitles() {
        #expect(throws: SubtitleFileError.self) { try SubtitleFileParser.parse(Data("<html>not a subtitle</html>".utf8)) }
    }

    // MARK: WebVTT

    @Test func parsesWebVTT() throws {
        let vtt = """
        WEBVTT - Example

        STYLE
        ::cue { color: yellow }

        NOTE This is a comment

        intro
        00:01.000 --> 00:02.000 align:start position:10%
        <v Narrator>Once upon a time</v>

        01:00:00.000 --> 01:00:01.500
        <c.yellow>Later</c> &lt;b&gt;
        """
        let cues = try SubtitleFileParser.parse(Data(vtt.utf8))
        #expect(cues.count == 2)
        #expect(cues[0].start == 1)
        #expect(cues[0].text == "Once upon a time")
        #expect(cues[1].start == 3600)
        #expect(cues[1].end == 3601.5)
        #expect(cues[1].text == "Later <b>")
    }

    // MARK: OpenSubtitles hash

    @Test func hashOfZeroFileIsItsSize() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "hash-zero-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(count: 131_072).write(to: url)
        #expect(try OpenSubtitlesHash.compute(url: url) == "0000000000020000")
    }

    @Test func hashMatchesReferenceSum() throws {
        let size = 300_007
        let bytes = (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
        let url = FileManager.default.temporaryDirectory.appending(path: "hash-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(bytes).write(to: url)

        // Reference: size plus little-endian 64-bit words of the first and last 64 KiB.
        var expected = UInt64(size)
        for start in [0, size - 65_536] {
            for word in stride(from: start, to: start + 65_536, by: 8) {
                var value: UInt64 = 0
                for byte in 0..<8 { value |= UInt64(bytes[word + byte]) << (8 * UInt64(byte)) }
                expected &+= value
            }
        }
        let hex = String(expected, radix: 16)
        #expect(try OpenSubtitlesHash.compute(url: url) == String(repeating: "0", count: 16 - hex.count) + hex)
    }

    @Test func hashNeedsAtLeast64KiB() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "hash-small-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(count: 1_000).write(to: url)
        #expect(try OpenSubtitlesHash.compute(url: url) == nil)
    }

    // MARK: Sidecars

    @Test func sidecarLanguages() {
        let base = "Movie (2010)"
        #expect(SidecarSubtitles.info(forSidecar: "Movie (2010).srt", videoBaseName: base) == .init())
        #expect(SidecarSubtitles.info(forSidecar: "Movie (2010).en.srt", videoBaseName: base)?.languageCode == "en")
        let forced = SidecarSubtitles.info(forSidecar: "Movie (2010).eng.forced.srt", videoBaseName: base)
        #expect(forced?.languageCode == "en")
        #expect(forced?.isForced == true)
        #expect(SidecarSubtitles.info(forSidecar: "movie (2010).FRE.srt", videoBaseName: base)?.languageCode == "fr")
        #expect(SidecarSubtitles.info(forSidecar: "Movie (2010).Spanish.vtt", videoBaseName: base)?.languageCode == "es")
        #expect(SidecarSubtitles.info(forSidecar: "Movie (2010).pt-br.srt", videoBaseName: base)?.languageCode == "pt-BR")
        let sdh = SidecarSubtitles.info(forSidecar: "Movie (2010).en.hi.srt", videoBaseName: base)
        #expect(sdh?.languageCode == "en")
        #expect(sdh?.isSDH == true)
        #expect(SidecarSubtitles.info(forSidecar: "Movie (2010).hi.srt", videoBaseName: base)?.languageCode == "hi")
    }

    @Test func sidecarMustBelongToTheVideo() {
        #expect(SidecarSubtitles.info(forSidecar: "Other Movie.en.srt", videoBaseName: "Movie") == nil)
        #expect(SidecarSubtitles.info(forSidecar: "Movie 2.en.srt", videoBaseName: "Movie") == nil)
        #expect(SidecarSubtitles.info(forSidecar: "Movie.en.sub", videoBaseName: "Movie") == nil)
    }

    // MARK: OpenSubtitles requests

    @Test func queryIsSortedLowercasedAndPlusEncoded() {
        let query = OpenSubtitlesClient.encodedQuery([("query", "The Matrix"), ("languages", "en"), ("imdb_id", "133093")])
        #expect(query == "imdb_id=133093&languages=en&query=the+matrix")
        #expect(SubtitleSearchQuery.numericIMDbID("tt0133093") == 133093)
        #expect(SubtitleSearchQuery.numericIMDbID("nonsense") == nil)
    }

    @Test func episodeSearchUsesParentIDs() {
        let query = SubtitleSearchQuery(title: "Show", year: 2020, isEpisode: true, season: 2, episode: 5,
                                        imdbID: 123, tmdbID: 456, movieHash: "0123456789abcdef", languages: ["fr", "en"])
        let items = Dictionary(uniqueKeysWithValues: OpenSubtitlesClient.parameters(for: query, useIDs: true))
        #expect(items["parent_imdb_id"] == "123")
        #expect(items["season_number"] == "2")
        #expect(items["episode_number"] == "5")
        #expect(items["languages"] == "en,fr")
        #expect(items["moviehash"] == "0123456789abcdef")
        #expect(items["query"] == nil)
    }
}
