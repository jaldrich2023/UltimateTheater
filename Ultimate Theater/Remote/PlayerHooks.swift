//
//  PlayerHooks.swift
//  Ultimate Theater
//
//  The few things only the player view knows (its episode neighbours, whether Skip Intro or
//  Skip Credits is on screen, how to close cleanly), exposed so the iPhone remote and the
//  system media controls use exactly the same paths as the on-screen buttons.
//

import Foundation

/// What the player can do right now.
struct PlayerHookState {
    var item: PlaybackItem
    var hasPreviousEpisode = false
    var hasNextEpisode = false
    var canSkipIntro = false
    var canSkipCredits = false
}

enum PlayerHookAction {
    case previousEpisode
    case nextEpisode
    case skipIntro
    case skipCredits
    /// Saves progress and closes the player.
    case close
}

/// Registered by the player for each title it loads.
struct PlayerControlHooks {
    /// The engine these hooks belong to; stale hooks (from a closed player) are ignored.
    weak var engine: TheaterEngine?
    /// The Apple TV handoff, when the picture can be (or is) on an Apple TV.
    weak var airPlay: AirPlayHandoff?
    let state: () -> PlayerHookState
    let perform: (PlayerHookAction) -> Void
}

extension AppModel {
    /// The player's hooks, if they belong to the engine that's playing.
    var activePlayerHooks: PlayerControlHooks? {
        guard nowPlaying != nil, let hooks = playerControls, let engine = hooks.engine, engine === playerEngine else { return nil }
        return hooks
    }

    /// Whatever is showing the picture: the Apple TV handoff while it's external, else the engine.
    var activeTransport: (any PlaybackTransport)? {
        guard nowPlaying != nil else { return nil }
        if let airPlay = activePlayerHooks?.airPlay, airPlay.isExternal { return airPlay }
        return playerEngine
    }

    /// Stops playback the way the player's close button does (saving progress).
    func closePlayerSavingProgress() {
        if let hooks = activePlayerHooks {
            hooks.perform(.close)
        } else {
            playerEngine?.shutdown()
            stopPlayback()
        }
    }
}
