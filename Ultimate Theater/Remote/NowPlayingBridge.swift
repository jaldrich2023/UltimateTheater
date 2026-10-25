//
//  NowPlayingBridge.swift
//  Ultimate Theater
//
//  Publishes what's playing to MPNowPlayingInfoCenter (Control Center's Now Playing, the
//  menu bar, AirPods, Apple Watch) and answers MPRemoteCommandCenter commands (media keys,
//  headphone controls) through the same player paths as the on-screen buttons.
//

import Foundation
import MediaPlayer
import AppKit

final class NowPlayingBridge {
    private weak var model: AppModel?
    private var task: Task<Void, Never>?
    private var isRegistered = false

    // What was last published, to avoid needless updates.
    private var publishedItemID: String?
    private var publishedRate: Double = -1
    private var publishedDuration: Double = -1
    private var publishedPosition: Double = 0
    private var publishedAt = Date.distantPast
    private var artwork: MPMediaItemArtwork?
    private var artworkItemID: String?

    func start(model: AppModel) {
        self.model = model
        registerCommands()
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    // Stop once the bridge is gone; don't hold it across the sleep.
                    guard let self else { return }
                    self.update()
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    // MARK: Now Playing

    private func update() {
        let center = MPNowPlayingInfoCenter.default()
        guard let model, let item = model.nowPlaying else {
            if publishedItemID != nil {
                center.nowPlayingInfo = nil
                center.playbackState = .stopped
                publishedItemID = nil
                artworkItemID = nil
                artwork = nil
            }
            return
        }
        let transport = model.activeTransport
        let rate: Double = transport?.isPlaying == true ? 1 : 0
        let position = transport?.currentTime ?? 0
        let duration = transport?.duration ?? 0
        let hooks = model.activePlayerHooks?.state()
        let commands = MPRemoteCommandCenter.shared()
        commands.previousTrackCommand.isEnabled = hooks?.hasPreviousEpisode ?? false
        commands.nextTrackCommand.isEnabled = hooks?.hasNextEpisode ?? false

        // Elapsed time is extrapolated from the rate, so only jumps need publishing.
        let expected = publishedPosition + (publishedRate > 0 ? Date.now.timeIntervalSince(publishedAt) : 0)
        let changed = item.id != publishedItemID || rate != publishedRate || abs(duration - publishedDuration) > 0.5
            || abs(position - expected) > 1.5
        guard changed, position.isFinite, duration.isFinite else { return }

        if item.id != artworkItemID { loadArtwork(for: item) }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.episode?.name ?? item.headline,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if let episode = item.episode {
            info[MPMediaItemPropertyArtist] = item.headline
            info[MPMediaItemPropertyAlbumTitle] = "\(item.headline) · \(episode.code)"
        } else if let year = item.title.yearText {
            info[MPMediaItemPropertyArtist] = year
        }
        if let artwork, artworkItemID == item.id { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        center.playbackState = rate > 0 ? .playing : .paused

        publishedItemID = item.id
        publishedRate = rate
        publishedDuration = duration
        publishedPosition = position
        publishedAt = .now
    }

    private func loadArtwork(for item: PlaybackItem) {
        artworkItemID = item.id
        artwork = nil
        guard let url = item.title.posterURL else { return }
        let id = item.id
        Task { [weak self] in
            guard let image = await ArtworkCache.shared.image(for: url, size: .poster), let self, self.artworkItemID == id else { return }
            self.artwork = Self.artwork(from: image)
            self.publishedItemID = nil // Republish with the artwork.
            self.update()
        }
    }

    /// Built outside the main actor: the request handler may be called on any thread.
    nonisolated private static func artwork(from image: CGImage) -> MPMediaItemArtwork {
        let size = CGSize(width: image.width, height: image.height)
        let picture = NSImage(cgImage: image, size: size)
        return MPMediaItemArtwork(boundsSize: size) { _ in picture }
    }

    // MARK: Remote commands

    private func registerCommands() {
        guard !isRegistered else { return }
        isRegistered = true
        let center = MPRemoteCommandCenter.shared()
        Self.handle(center.playCommand) { [weak self] in self?.transport?.play() != nil }
        Self.handle(center.pauseCommand) { [weak self] in self?.transport?.pause() != nil }
        Self.handle(center.togglePlayPauseCommand) { [weak self] in self?.transport?.togglePlayback() != nil }
        Self.handle(center.stopCommand) { [weak self] in
            guard let model = self?.model, model.nowPlaying != nil else { return false }
            model.closePlayerSavingProgress()
            return true
        }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        Self.handle(center.skipForwardCommand) { [weak self] in self?.transport?.skip(by: 10) != nil }
        Self.handle(center.skipBackwardCommand) { [weak self] in self?.transport?.skip(by: -10) != nil }
        Self.handle(center.nextTrackCommand) { [weak self] in self?.model?.activePlayerHooks?.perform(.nextEpisode) != nil }
        Self.handle(center.previousTrackCommand) { [weak self] in self?.model?.activePlayerHooks?.perform(.previousEpisode) != nil }
        Self.handlePosition(center.changePlaybackPositionCommand) { [weak self] time in
            self?.transport?.seek(to: time) != nil
        }
    }

    private var transport: (any PlaybackTransport)? { model?.activeTransport }

    /// Runs a command on the main actor. Returns whether anything could act on it, so media
    /// keys fall through to other apps when nothing is playing here.
    nonisolated private static func run(_ action: @escaping @MainActor @Sendable () -> Bool) -> MPRemoteCommandHandlerStatus {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { action() } ? .success : .noActionableNowPlayingItem
        }
        Task { @MainActor in _ = action() }
        return .success
    }

    nonisolated private static func handle(_ command: MPRemoteCommand, _ action: @escaping @MainActor @Sendable () -> Bool) {
        command.isEnabled = true
        command.addTarget { _ in run(action) }
    }

    nonisolated private static func handlePosition(_ command: MPChangePlaybackPositionCommand,
                                                   _ action: @escaping @MainActor @Sendable (Double) -> Bool) {
        command.isEnabled = true
        command.addTarget { event in
            guard let time = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime, time.isFinite else { return .commandFailed }
            return run { action(time) }
        }
    }
}
