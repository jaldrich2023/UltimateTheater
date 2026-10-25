//
//  CastSession.swift
//  Ultimate Theater
//
//  One cast: a device playing a file the Mac serves. The session implements the app's
//  `PlaybackTransport`, and the player attaches it to its `AirPlayHandoff`, which routes the
//  transport to whichever external device shows the picture; so the Playback menu, the Dock
//  menu, Now Playing, and the iPhone remote drive a Chromecast, TV, or Roku exactly as they
//  drive an Apple TV.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Renderer protocol

struct CastCapabilities: Equatable {
    enum Volume: Equatable {
        case none
        /// A level from 0 to 1.
        case absolute
        /// Up and down steps only.
        case steps
    }

    var canSeek: Bool
    var volume: Volume
}

nonisolated struct CastLoadRequest: Sendable {
    var mediaURL: URL
    var contentType: String
    var profile: CastMediaProfile
    var title: String
    var subtitle: String?
    var artworkURL: URL?
    var startTime: Double
    var duration: Double
    var fileSize: Int64?
    var isEpisode: Bool

    /// "Show · S1:E2 · Pilot" for players with a single title line.
    var displayTitle: String { subtitle.map { "\(title) · \($0)" } ?? title }
}

nonisolated struct CastPlaybackStatus: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case idle
        case buffering
        case playing
        case paused
        /// Played to the end.
        case finished
        /// Stopped on the device, or another app took over.
        case stopped
        case failed(String)
    }

    var state: State
    var position: Double?
    var duration: Double?
    var volume: Float?
}

/// One casting protocol's control of one device.
protocol CastRendererClient: AnyObject {
    var device: CastDevice { get }
    var capabilities: CastCapabilities { get }
    /// The Mac's IPv4 address the device should fetch media from.
    var mediaHost: String? { get }
    func connect() async throws
    func load(_ request: CastLoadRequest) async throws
    func play() async throws
    func pause() async throws
    func seek(to seconds: Double) async throws
    func setVolume(_ level: Float) async throws
    func stepVolume(up: Bool) async throws
    func stop() async
    func status() async throws -> CastPlaybackStatus
    func disconnect()
}

extension CastRendererClient {
    func stepVolume(up: Bool) async throws {}
}

// MARK: - Session

/// What the player hands to a cast.
struct CastMediaItem {
    var fileURL: URL
    var title: String
    var subtitle: String?
    var isEpisode: Bool
    var posterURL: URL?
    var duration: Double
    var profile: CastMediaProfile
}

@Observable
final class CastSession: PlaybackTransport {
    enum Phase: Equatable {
        case connecting
        case loading
        case playing
        /// Played to the end on the device.
        case finished
        /// Stopped on the device (with the reason shown), or ended from the Mac.
        case ended(String?)
        case failed(String)
    }

    let device: CastDevice
    private(set) var phase: Phase = .connecting
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var isBuffering = true
    /// The device's volume, 0…1, when it reports one.
    private(set) var deviceVolume: Float?
    let capabilities: CastCapabilities

    @ObservationIgnored private let client: any CastRendererClient
    @ObservationIgnored private let server = CastMediaServer()
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var loadedAt = Date.now
    @ObservationIgnored private var seekTarget: (time: Double, until: Date)?
    @ObservationIgnored private var hasPlayed = false
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var generation = 0

    /// Connecting, loading, or playing (paused counts): the picture is on the device.
    var isActive: Bool {
        switch phase {
        case .connecting, .loading, .playing: true
        default: false
        }
    }

    var volume: Float {
        get { deviceVolume ?? 1 }
        set { setVolume(newValue) }
    }

    init(device: CastDevice) throws {
        self.device = device
        switch device.kind {
        case .googleCast: client = try GoogleCastClient(device: device)
        case .dlna: client = try DLNARendererClient(device: device)
        case .roku: client = try RokuClient(device: device)
        }
        capabilities = client.capabilities
    }

    /// Connects and starts playing `item` at `position`.
    func start(_ item: CastMediaItem, at position: Double) async {
        phase = .connecting
        currentTime = position
        duration = item.duration
        do {
            try await client.connect()
            try await load(item, at: position)
        } catch {
            fail(error)
        }
    }

    /// The player moved on to another item (the next episode) that will be cast with
    /// `replace(with:)`: the finished one's position and end no longer count.
    func prepareForNext() {
        guard phase == .finished || phase == .playing || phase == .loading else { return }
        poller?.cancel()
        generation += 1
        phase = .loading
        currentTime = 0
        duration = 0
        isPlaying = false
        isBuffering = true
    }

    /// Casts another file (the next episode) on the same device.
    func replace(with item: CastMediaItem) async {
        // Still connecting for the previous item: wait for that to settle first.
        for _ in 0..<120 where phase == .connecting {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard phase == .loading || phase == .playing || phase == .finished else { return }
        poller?.cancel()
        server.revoke()
        currentTime = 0
        duration = item.duration
        do { try await load(item, at: 0) } catch { fail(error) }
    }

    private func load(_ item: CastMediaItem, at position: Double) async throws {
        phase = .loading
        isBuffering = true
        isPlaying = false
        hasPlayed = false
        generation += 1
        let port = try await server.start()
        guard let host = client.mediaHost ?? LANAddress.primaryIPv4() else {
            throw CastMediaServer.ServerError.couldNotListen("this Mac isn't connected to a local network")
        }
        let base = "http://\(host):\(port)"
        let path = try server.publish(file: item.fileURL, contentType: item.profile.container.mimeType)
        var artworkURL: URL?
        if let poster = item.posterURL, let jpeg = await Self.artworkJPEG(poster) {
            artworkURL = URL(string: base + server.publishArtwork(jpeg))
        }
        guard let mediaURL = URL(string: base + path) else { throw CastMediaServer.ServerError.fileUnreadable }
        let request = CastLoadRequest(mediaURL: mediaURL, contentType: item.profile.container.mimeType, profile: item.profile,
                                      title: item.title, subtitle: item.subtitle, artworkURL: artworkURL,
                                      startTime: capabilities.canSeek ? position : 0, duration: item.duration,
                                      fileSize: server.publishedFile?.size, isEpisode: item.isEpisode)
        if !capabilities.canSeek { currentTime = 0 }
        try await client.load(request)
        loadedAt = .now
        phase = .playing
        isPlaying = true
        startPolling()
    }

    /// Stops the device and the server. Returns the last known position.
    @discardableResult
    func end() async -> Double {
        let position = currentTime
        poller?.cancel()
        poller = nil
        if isActive || phase == .finished { phase = .ended(nil) }
        isPlaying = false
        server.stop()
        await client.stop()
        client.disconnect()
        return position
    }

    // MARK: Polling

    private func startPolling() {
        poller?.cancel()
        let generation = generation
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                do {
                    let status = try await client.status()
                    guard !Task.isCancelled, self.generation == generation else { return }
                    failures = 0
                    apply(status)
                } catch {
                    failures += 1
                    if failures >= 8 {
                        phase = .failed("Lost contact with \(device.name).")
                        server.revoke()
                        return
                    }
                }
                if !isActive { return }
            }
        }
    }

    private func apply(_ status: CastPlaybackStatus) {
        if let reported = status.duration, reported > 0, duration <= 0 { duration = reported }
        if let level = status.volume { deviceVolume = level }
        if let position = status.position, position.isFinite {
            if let seek = seekTarget {
                if abs(position - seek.time) < 3 || Date.now > seek.until { seekTarget = nil; currentTime = position }
            } else {
                currentTime = position
            }
        }
        let inGrace = Date.now.timeIntervalSince(loadedAt) < 20
        switch status.state {
        case .playing:
            hasPlayed = true
            isPlaying = true
            isBuffering = false
        case .paused:
            hasPlayed = true
            isPlaying = false
            isBuffering = false
        case .buffering:
            isBuffering = true
        case .finished:
            finish()
        case .idle, .stopped:
            if inGrace && !hasPlayed {
                isBuffering = true
            } else if isNearEnd {
                finish()
            } else {
                isPlaying = false
                phase = .ended("Playback was stopped on \(device.name).")
                server.revoke()
            }
        case .failed(let message):
            phase = .failed(message)
            server.revoke()
        }
    }

    private var isNearEnd: Bool {
        duration > 0 && (currentTime >= duration - 20 || currentTime >= duration * 0.97)
    }

    private func finish() {
        isPlaying = false
        isBuffering = false
        if duration > 0 { currentTime = duration }
        phase = .finished
        server.revoke()
    }

    private func fail(_ error: Error) {
        poller?.cancel()
        isPlaying = false
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        phase = .failed(message)
        server.stop()
        client.disconnect()
    }

    // MARK: Transport

    private func command(_ action: @escaping (any CastRendererClient) async throws -> Void) {
        let client = client
        Task { [weak self] in
            do { try await action(client) } catch {
                // A refused command isn't fatal: the next status poll shows the real state.
                _ = self
            }
        }
    }

    func play() {
        guard phase == .playing else { return }
        isPlaying = true
        command { try await $0.play() }
    }

    func pause() {
        guard phase == .playing else { return }
        isPlaying = false
        command { try await $0.pause() }
    }

    func togglePlayback() { isPlaying ? pause() : play() }

    func seek(to seconds: Double) {
        guard phase == .playing, capabilities.canSeek else { return }
        let target = TheaterEngine.seekTarget(seconds, duration: duration)
        currentTime = target
        seekTarget = (target, Date.now.addingTimeInterval(5))
        command { try await $0.seek(to: target) }
    }

    func skip(by seconds: Double) { seek(to: currentTime + seconds) }

    func setVolume(_ level: Float) {
        guard capabilities.volume == .absolute, isActive else { return }
        let level = min(max(level, 0), 1)
        deviceVolume = level
        command { try await $0.setVolume(level) }
    }

    func stepVolume(up: Bool) {
        guard isActive else { return }
        if capabilities.volume == .absolute {
            setVolume((deviceVolume ?? 0.5) + (up ? 0.05 : -0.05))
        } else if capabilities.volume == .steps {
            command { try await $0.stepVolume(up: up) }
        }
    }

    // MARK: Artwork

    /// The title's poster as a JPEG for the device's "now playing" screen.
    private static func artworkJPEG(_ url: URL) async -> Data? {
        guard let image = await ArtworkCache.shared.image(for: url, size: .poster) else { return nil }
        return await Task.detached(priority: .utility) { () -> Data? in
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            return CGImageDestinationFinalize(destination) ? data as Data : nil
        }.value
    }
}
