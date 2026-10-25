//
//  SleepPrevention.swift
//  Ultimate Theater
//
//  Keeps the Mac awake while something is playing: no display sleep (so no screen saver
//  and no lock screen) and no idle system sleep. Released as soon as playback pauses,
//  stops, or the player closes.
//

import Foundation

@MainActor
final class PlaybackSleepGuard {
    static let shared = PlaybackSleepGuard()

    enum Mode: Equatable {
        /// Nothing playing: the Mac may sleep normally.
        case none
        /// Playing somewhere else (an Apple TV): stay awake so playback continues, but
        /// let the display sleep.
        case system
        /// Playing on this Mac: keep the display on too, so the screen saver and lock
        /// screen don't cover the picture.
        case systemAndDisplay
    }

    private(set) var mode: Mode = .none
    private var activity: NSObjectProtocol?

    private init() {}

    func update(_ newMode: Mode) {
        guard newMode != mode else { return }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        mode = newMode

        let options: ProcessInfo.ActivityOptions
        switch newMode {
        case .none: return
        case .system: options = [.userInitiated, .idleSystemSleepDisabled]
        case .systemAndDisplay: options = [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled]
        }
        activity = ProcessInfo.processInfo.beginActivity(options: options, reason: "Playing a movie or show")
    }
}
