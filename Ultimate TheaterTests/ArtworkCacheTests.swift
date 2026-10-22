//
//  ArtworkCacheTests.swift
//  Ultimate TheaterTests
//

import Testing
import Foundation
import AppKit
@testable import Ultimate_Theater

struct ArtworkCacheTests {
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

        #expect(ArtworkCache.shared.cachedImage(for: url, size: .poster) == nil)
        let loaded = try #require(await ArtworkCache.shared.image(for: url, size: .poster))
        #expect(max(loaded.width, loaded.height) == ArtworkCache.Size.poster.rawValue)
        // Now it's in memory: a view created next draws it on its first frame.
        #expect(ArtworkCache.shared.cachedImage(for: url, size: .poster) != nil)
        #expect(ArtworkCache.shared.isOnDisk(url))
    }
}
