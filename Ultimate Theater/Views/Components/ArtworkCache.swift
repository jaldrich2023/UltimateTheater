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
import Synchronization

nonisolated final class ArtworkCache: Sendable {
    static let shared = ArtworkCache()

    /// Largest artwork download accepted.
    static let maximumDownloadSize = 20 << 20
    /// The on-disk cache is trimmed to this, least recently used first.
    static let diskLimit: Int64 = 1 << 30

    /// Common display sizes, in pixels (longest side). Requests round up to one of these.
    enum Size: Int, CaseIterable {
        case poster = 480
        case wide = 960
        case backdrop = 1920
    }

    private final class Entry: Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    /// NSCache is thread-safe, but its Objective-C interface isn't marked Sendable.
    nonisolated(unsafe) private let memory = NSCache<NSString, Entry>()
    private let directory: URL
    private let inFlight = Mutex<[String: Task<CGImage?, Never>]>([:])
    private let session: URLSession
    /// Files written since the disk cache was last trimmed.
    private let writesSincePrune = Mutex(0)
    /// The disk cache is trimmed again after this many new files (and at launch).
    static let writesBetweenPrunes = 200

    /// Identifies the app to artwork servers.
    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "UltimateTheater/\(version) (macOS; personal media library artwork)"
    }()

    private convenience init() {
        self.init(directory: URL.cachesDirectory.appending(path: "Artwork", directoryHint: .isDirectory))
    }

    /// A cache keeping its files in `directory` (tests use a temporary folder).
    init(directory: URL) {
        memory.totalCostLimit = 512 << 20 // Decoded bytes.
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.urlCache = nil // Files are cached here instead.
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        session = URLSession(configuration: configuration, delegate: RedirectGuard.shared, delegateQueue: nil)
        Task.detached(priority: .background) { Self.prune(directory, to: Self.diskLimit) }
    }

    /// Which artwork URLs are fetched: HTTPS from the network, or local files. (Local files
    /// only ever come from artwork the user chose: info from metadata sources is limited to
    /// web addresses before it's saved; see `webArtworkURL`.)
    static func isAllowed(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": url.host() != nil
        case "file": true
        default: false
        }
    }

    /// Plain HTTP artwork is fetched over HTTPS instead.
    static func upgraded(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http", var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.scheme = "https"
        if parts.port == 80 { parts.port = nil }
        return parts.url ?? url
    }

    /// An artwork address from a metadata source, as it may be saved: HTTPS (plain HTTP is
    /// upgraded), never a local file or another scheme.
    static func webArtworkURL(string: String) -> URL? { webArtworkURL(URL(string: string)) }

    static func webArtworkURL(_ url: URL?) -> URL? {
        guard let url else { return nil }
        let upgraded = upgraded(url)
        guard upgraded.scheme?.lowercased() == "https", upgraded.host() != nil else { return nil }
        return upgraded
    }

    /// Whether a download's response is acceptable artwork: an image type (or a generic binary
    /// type, which must then decode as an image) no larger than the cap.
    static func accepts(mimeType: String?, expectedLength: Int64) -> Bool {
        guard expectedLength <= Int64(maximumDownloadSize) else { return false }
        guard let mimeType = mimeType?.lowercased() else { return false }
        return mimeType.hasPrefix("image/") || mimeType == "application/octet-stream" || mimeType == "binary/octet-stream"
    }

    private func key(_ url: URL, _ size: Size) -> String { "\(size.rawValue)|\(url.absoluteString)" }

    private func file(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: digest)
    }

    /// A decoded image already in memory, for drawing on the first frame.
    func cachedImage(for url: URL, size: Size) -> CGImage? {
        memory.object(forKey: key(Self.upgraded(url), size) as NSString)?.image
    }

    /// The image from memory, disk, or the network (in that order).
    func image(for url: URL, size: Size) async -> CGImage? {
        let url = Self.upgraded(url)
        if let cached = cachedImage(for: url, size: size) { return cached }
        let key = key(url, size)
        guard Self.isAllowed(url) else { return nil }
        let task: Task<CGImage?, Never> = inFlight.withLock { inFlight in
            if let existing = inFlight[key] { return existing }
            let task = Task.detached(priority: .userInitiated) { [self] in await load(url, size: size) }
            inFlight[key] = task
            return task
        }
        let image = await task.value
        inFlight.withLock { _ = $0.removeValue(forKey: key) }
        return image
    }

    /// Whether the original file is on disk (so loading it won't need the network).
    func isOnDisk(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: file(for: Self.upgraded(url)).path)
    }

    private func load(_ url: URL, size: Size) async -> CGImage? {
        let path = file(for: url)
        let image: CGImage
        if let data = try? Data(contentsOf: path), let decoded = Self.decode(data, maxPixelSize: size.rawValue) {
            image = decoded
            // Marks it recently used, for trimming the disk cache.
            try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: path.path)
        } else {
            guard let downloaded = await download(url), let decoded = Self.decode(downloaded, maxPixelSize: size.rawValue) else {
                return nil
            }
            // Only files that really are images are kept.
            if (try? downloaded.write(to: path, options: .atomic)) != nil { noteWrite() }
            image = decoded
        }
        memory.setObject(Entry(image), forKey: key(url, size) as NSString, cost: image.bytesPerRow * image.height)
        return image
    }

    /// The file's bytes, if it's an acceptable image no larger than the cap.
    private func download(_ url: URL) async -> Data? {
        if url.isFileURL {
            let length = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard length > 0, length <= Self.maximumDownloadSize else { return nil }
            return try? Data(contentsOf: url)
        }
        guard let (bytes, response) = try? await session.bytes(from: url) else { return nil }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              Self.accepts(mimeType: http.mimeType, expectedLength: http.expectedContentLength) else {
            bytes.task.cancel()
            return nil
        }
        var data = Data()
        data.reserveCapacity(Int(min(max(http.expectedContentLength, 0), Int64(Self.maximumDownloadSize))))
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > Self.maximumDownloadSize {
                    bytes.task.cancel()
                    return nil
                }
            }
        } catch {
            return nil
        }
        return data.isEmpty ? nil : data
    }

    /// Counts a new file, trimming the disk cache in the background every so often.
    private func noteWrite() {
        let due = writesSincePrune.withLock { count -> Bool in
            count += 1
            guard count >= Self.writesBetweenPrunes else { return false }
            count = 0
            return true
        }
        guard due else { return }
        let directory = directory
        Task.detached(priority: .background) { Self.prune(directory, to: Self.diskLimit) }
    }

    /// Deletes the least recently used files until the cache fits within `limit` (trimming to
    /// 80% of it, so it isn't trimmed again straight away).
    static func prune(_ directory: URL, to limit: Int64) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
        else { return }
        var files = contents.compactMap { url -> (url: URL, size: Int64, used: Date)? in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var total = files.reduce(0) { $0 + $1.size }
        guard total > limit else { return }
        files.sort { $0.used < $1.used }
        let target = limit / 10 * 8
        for file in files where total > target {
            if (try? FileManager.default.removeItem(at: file.url)) != nil { total -= file.size }
        }
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
