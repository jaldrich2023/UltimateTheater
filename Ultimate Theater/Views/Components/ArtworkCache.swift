//
//  ArtworkCache.swift
//  Ultimate Theater
//
//  Makes artwork appear instantly: images are kept decoded in memory at the size they're
//  shown, downloaded files are kept on disk, and the library's posters are prefetched in
//  the background, so screens draw their art on the first frame instead of waiting on a
//  network load.
//

import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

nonisolated final class ArtworkCache: @unchecked Sendable {
    static let shared = ArtworkCache()

    /// Common display sizes, in pixels (longest side). Requests round up to one of these.
    enum Size: Int, CaseIterable {
        case poster = 480
        case wide = 960
        case backdrop = 1920
    }

    private final class Entry {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let memory = NSCache<NSString, Entry>()
    private let directory: URL
    private let lock = NSLock()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]
    private let session: URLSession

    private init() {
        memory.totalCostLimit = 512 << 20 // Decoded bytes.
        directory = URL.cachesDirectory.appending(path: "Artwork", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.urlCache = nil // Files are cached here instead.
        session = URLSession(configuration: configuration)
    }

    private func key(_ url: URL, _ size: Size) -> String { "\(size.rawValue)|\(url.absoluteString)" }

    private func file(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: digest)
    }

    /// A decoded image already in memory, for drawing on the first frame.
    func cachedImage(for url: URL, size: Size) -> CGImage? {
        memory.object(forKey: key(url, size) as NSString)?.image
    }

    /// The image from memory, disk, or the network (in that order).
    func image(for url: URL, size: Size) async -> CGImage? {
        if let cached = cachedImage(for: url, size: size) { return cached }
        let key = key(url, size)
        let task: Task<CGImage?, Never> = lock.withLock {
            if let existing = inFlight[key] { return existing }
            let task = Task.detached(priority: .userInitiated) { [self] in await load(url, size: size) }
            inFlight[key] = task
            return task
        }
        let image = await task.value
        lock.withLock { inFlight[key] = nil }
        return image
    }

    /// Whether the original file is on disk (so loading it won't need the network).
    func isOnDisk(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: file(for: url).path)
    }

    private func load(_ url: URL, size: Size) async -> CGImage? {
        let path = file(for: url)
        var data = try? Data(contentsOf: path)
        if data == nil {
            guard let (downloaded, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 < 400, !downloaded.isEmpty else { return nil }
            try? downloaded.write(to: path, options: .atomic)
            data = downloaded
        }
        guard let data, let image = Self.decode(data, maxPixelSize: size.rawValue) else { return nil }
        memory.setObject(Entry(image), forKey: key(url, size) as NSString, cost: image.bytesPerRow * image.height)
        return image
    }

    /// Decodes straight to the display size, fully decompressed so drawing it is free.
    private static func decode(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Loads artwork ahead of time, a few at a time, so it's ready before it's shown.
    func prefetch(_ requests: [(URL, Size)]) {
        Task.detached(priority: .utility) { [self] in
            await withTaskGroup(of: Void.self) { group in
                var pending = requests[...]
                for _ in 0..<4 {
                    guard let (url, size) = pending.popFirst() else { break }
                    group.addTask { _ = await self.image(for: url, size: size) }
                }
                while await group.next() != nil {
                    guard let (url, size) = pending.popFirst() else { continue }
                    group.addTask { _ = await self.image(for: url, size: size) }
                }
            }
        }
    }

    /// Forgets everything (used when the app is reset).
    func removeAll() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
