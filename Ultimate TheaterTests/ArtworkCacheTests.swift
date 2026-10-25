//
//  ArtworkCacheTests.swift
//  Ultimate TheaterTests
//

import Testing
import Foundation
import AppKit
@testable import Ultimate_Theater

struct ArtworkCacheTests {
    /// A cache in its own temporary folder, so tests never touch the app's real artwork cache.
    private func withCache(_ body: (ArtworkCache) async throws -> Void) async rethrows {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ArtworkCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try await body(ArtworkCache(directory: folder))
    }

    @Test func loadedArtIsAvailableSynchronouslyAtDisplaySize() async throws {
        // A 1000×1500 test poster on disk.
        let image = NSImage(size: NSSize(width: 1000, height: 1500), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let url = Fixtures.temporaryURL("png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        try await withCache { cache in
            #expect(cache.cachedImage(for: url, size: .poster) == nil)
            let loaded = try #require(await cache.image(for: url, size: .poster))
            #expect(max(loaded.width, loaded.height) == ArtworkCache.Size.poster.rawValue)
            // Now it's in memory: a view created next draws it on its first frame.
            #expect(cache.cachedImage(for: url, size: .poster) != nil)
            #expect(cache.isOnDisk(url))
        }
    }

    @Test func plainHTTPArtworkIsUpgraded() throws {
        let http = try #require(URL(string: "http://static.tvmaze.com/uploads/images/original_untouched/1/1.jpg"))
        #expect(ArtworkCache.upgraded(http).absoluteString == "https://static.tvmaze.com/uploads/images/original_untouched/1/1.jpg")
        let port80 = try #require(URL(string: "http://example.com:80/a.jpg"))
        #expect(ArtworkCache.upgraded(port80).absoluteString == "https://example.com/a.jpg")
    }

    @Test func metadataArtworkIsLimitedToTheWeb() {
        #expect(ArtworkCache.webArtworkURL(string: "https://image.tmdb.org/t/p/w780/a.jpg") != nil)
        #expect(ArtworkCache.webArtworkURL(string: "http://image.tmdb.org/t/p/w780/a.jpg")?.scheme == "https")
        // A source can't point the app at a file on the Mac.
        #expect(ArtworkCache.webArtworkURL(string: "file:///Users/me/Pictures/private.png") == nil)
        #expect(ArtworkCache.webArtworkURL(string: "/etc/passwd") == nil)
        #expect(ArtworkCache.webArtworkURL(string: "data:image/png;base64,AAAA") == nil)
    }

    @Test func downloadsIdentifyTheApp() {
        #expect(ArtworkCache.userAgent.hasPrefix("UltimateTheater/"))
    }
}
