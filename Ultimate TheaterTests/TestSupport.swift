//
//  TestSupport.swift
//  Ultimate TheaterTests
//
//  Shared helpers: condition polling with a deadline (instead of fixed sleeps), the
//  realtime tag, a check for an audio output device, a seeded random generator, and
//  metadata settings isolated from the real preferences and Keychain.
//

import Testing
import Foundation
import CoreAudio
@testable import Ultimate_Theater

extension Tag {
    /// Tests that play media against the wall clock; they need an audio output device and
    /// can be skipped on loaded or headless machines.
    @Tag static var realtime: Self
}

/// Which optional groups of tests this run includes. The shared test plan
/// (Ultimate Theater.xctestplan) has two configurations: "Default" leaves realtime and UI
/// tests out; "Realtime" sets `UT_RUN_REALTIME_TESTS=1` to include them. Test plans can't
/// skip tags or targets per configuration, hence the environment variable.
nonisolated enum TestRun {
    static let realtimeVariable = "UT_RUN_REALTIME_TESTS"

    static var includesRealtime: Bool {
        ProcessInfo.processInfo.environment[realtimeVariable] == "1"
    }
}

extension Trait where Self == ConditionTrait {
    /// Pair with `.tags(.realtime)`: runs only in the test plan's "Realtime" configuration
    /// (or with `UT_RUN_REALTIME_TESTS=1`) and only when there's an audio output device.
    static var realtimeOnly: Self {
        .enabled(if: TestRun.includesRealtime && AudioOutputDevice.isAvailable,
                 "Realtime tests run in the Realtime test plan configuration, with an audio output device")
    }
}

/// Polls `condition` until it holds or `timeout` passes. Returns whether it held.
@discardableResult
func waitUntil(timeout: Duration = .seconds(5), pollingEvery interval: Duration = .milliseconds(20),
               isolation: isolated (any Actor)? = #isolation, _ condition: () throws -> Bool) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while true {
        if try condition() { return true }
        if clock.now >= deadline { return false }
        try await Task.sleep(for: interval)
    }
}

/// Named so it doesn't shadow the app's `AudioOutput` (Playback/AirPlay.swift).
nonisolated enum AudioOutputDevice {
    /// Whether the system has a default audio output device (CI machines and VMs often don't).
    static var isAvailable: Bool {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown
    }
}

/// Deterministic random numbers (SplitMix64), so generated test input is the same on every run.
nonisolated struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A secret store with no API keys that never touches the real Keychain.
nonisolated struct EmptySecretStore: SecretStore {
    func read(account: String, service: String) throws -> String? { nil }
    func write(_ value: String?, account: String, service: String) throws {}
}

/// Metadata settings kept apart from the app's real preferences and Keychain: a scratch
/// defaults suite (cleared each time) and no API keys.
@MainActor
func testMetadataSettings() -> MetadataSettings {
    let suite = "UltimateTheaterTests.metadata"
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    defaults.removePersistentDomain(forName: suite)
    return MetadataSettings(defaults: defaults, secrets: EmptySecretStore())
}
