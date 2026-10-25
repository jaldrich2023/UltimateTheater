//
//  ProfileSecurity.swift
//  Ultimate Theater
//
//  PINs: an administrator PIN that guards moving from a restricted profile to a less
//  restricted one (and managing profiles), and optional per-profile PINs. PINs are
//  stored only as salted SHA-256 hashes.
//

import Foundation
import CryptoKit
import LocalAuthentication

nonisolated enum PINHash {
    static let length = 4

    static func make(_ pin: String) -> String {
        let salt = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        return salt + ":" + digest(salt + pin)
    }

    static func verify(_ pin: String, against stored: String) -> Bool {
        let parts = stored.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        return digest(parts[0] + pin) == parts[1]
    }

    static func isValid(_ pin: String) -> Bool {
        pin.count == length && pin.allSatisfy { ("0"..."9").contains($0) }
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The household's administrator PIN, kept in the Keychain.
///
/// Fails closed: if the Keychain can't be read (locked, denied, damaged), the PIN counts as
/// set and no entry verifies, rather than the PIN being treated as absent. A marker kept
/// outside the Keychain (in the app's defaults) records that a PIN was configured, so
/// deleting the Keychain item doesn't remove the PIN either: a missing item with the marker
/// set also counts as unreadable. The Mac's owner can clear it with
/// `resetWithDeviceOwnerAuthentication()`.
nonisolated enum AdministratorPIN {
    private static let service = "UltimateTheater.PINs"
    private static let account = "administrator"
    /// Defaults key of the "a PIN is configured" marker.
    static let configuredMarkerKey = "security.administratorPINConfigured"

    /// What the Keychain holds for the administrator PIN.
    enum Stored: Equatable {
        case none
        case hash(String)
        case unreadable(String)
    }

    static func stored() -> Stored { stored(in: SystemKeychain(), markers: .standard) }

    /// The stored PIN in `store`, with the configured marker kept in `markers`. (Both are
    /// required, so a test can't touch the real marker by accident.)
    static func stored(in store: some SecretStore, markers: UserDefaults) -> Stored {
        do {
            guard let hash = try store.read(account: account, service: service) else {
                return markers.bool(forKey: configuredMarkerKey)
                    ? .unreadable("The administrator PIN is missing from the Keychain.")
                    : .none
            }
            // Earlier versions kept no marker: record it the first time the PIN is read.
            if !markers.bool(forKey: configuredMarkerKey) { markers.set(true, forKey: configuredMarkerKey) }
            return .hash(hash)
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    static var isSet: Bool { isSet(in: SystemKeychain(), markers: .standard) }

    static func isSet(in store: some SecretStore, markers: UserDefaults) -> Bool {
        stored(in: store, markers: markers) != .none
    }

    /// Whether a PIN is configured but can't be checked (so every entry is refused).
    static var isUnreadable: Bool {
        if case .unreadable = stored() { return true }
        return false
    }

    /// Why the PIN can't currently be checked, or `nil` when the Keychain reads fine.
    static var readFailureMessage: String? {
        guard case .unreadable(let reason) = stored() else { return nil }
        return "The administrator PIN couldn't be read from the Keychain, so access stays locked. \(reason)"
    }

    enum SaveError: LocalizedError {
        case notStored

        var errorDescription: String? {
            switch self {
            case .notStored: "The administrator PIN couldn't be saved in the Keychain."
            }
        }
    }

    /// Saves a new PIN (or with `nil`, removes it). Throws when the Keychain didn't accept the
    /// change; a failed save keeps the previous PIN. Callers should tell the user when this fails.
    static func save(_ pin: String?) throws { try save(pin, in: SystemKeychain(), markers: .standard) }

    static func save(_ pin: String?, in store: some SecretStore, markers: UserDefaults) throws {
        let hash = pin.map(PINHash.make)
        try store.write(hash, account: account, service: service)
        // Read it back, so a write that silently didn't stick is reported.
        guard (try? store.read(account: account, service: service)) == hash else { throw SaveError.notStored }
        // The marker changes only once the Keychain holds the new state.
        if hash == nil { markers.removeObject(forKey: configuredMarkerKey) } else { markers.set(true, forKey: configuredMarkerKey) }
    }

    /// Bool form of `save`. Prefer `save`, which says why it failed.
    @discardableResult
    static func set(_ pin: String?) -> Bool { set(pin, in: SystemKeychain(), markers: .standard) }

    @discardableResult
    static func set(_ pin: String?, in store: some SecretStore, markers: UserDefaults) -> Bool {
        (try? save(pin, in: store, markers: markers)) != nil
    }

    static func verify(_ pin: String) -> Bool { verify(pin, in: SystemKeychain(), markers: .standard) }

    static func verify(_ pin: String, in store: some SecretStore, markers: UserDefaults) -> Bool {
        switch stored(in: store, markers: markers) {
        case .none: true
        case .hash(let hash): PINHash.verify(pin, against: hash)
        case .unreadable: false
        }
    }

    /// Recovery for a forgotten or unreadable PIN: after the Mac's owner authenticates
    /// (password, Touch ID, or Apple Watch), removes the administrator PIN. Returns whether
    /// the PIN is now cleared; `false` when authentication was refused or the Keychain item
    /// couldn't be removed (the PIN then stays in force).
    static func resetWithDeviceOwnerAuthentication(
        reason: String = "reset the Ultimate Theater administrator PIN") async -> Bool {
        let authenticated = await DeviceOwner.authenticate(reason: reason)
        guard authenticated else { return false }
        return clearAfterOwnerAuthentication(in: SystemKeychain(), markers: .standard)
    }

    /// The removal step of the reset (separate so it can be tested without authentication).
    static func clearAfterOwnerAuthentication(in store: some SecretStore, markers: UserDefaults) -> Bool {
        do {
            try store.write(nil, account: account, service: service)
            guard try store.read(account: account, service: service) == nil else { return false }
        } catch {
            return false
        }
        markers.removeObject(forKey: configuredMarkerKey)
        return true
    }
}

/// Asks the Mac's owner to authenticate (LocalAuthentication, device-owner policy).
nonisolated enum DeviceOwner {
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

/// Limits PIN guesses: a few free tries, then waits that double with each further miss
/// (30 seconds, 1 minute, 2 minutes… up to 15 minutes). Saved, so relaunching doesn't reset it.
nonisolated struct PINLockout: Codable, Equatable {
    static let freeAttempts = 5
    static let baseDelay: TimeInterval = 30
    static let maximumDelay: TimeInterval = 15 * 60

    var failures = 0
    var lockedUntil: Date?

    /// The wait after this many consecutive misses (0 while tries remain).
    static func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures >= freeAttempts else { return 0 }
        let doublings = min(failures - freeAttempts, 20)
        return min(baseDelay * pow(2, Double(doublings)), maximumDelay)
    }

    /// Seconds left before another PIN can be tried. Never more than the longest wait, so a
    /// clock set backwards can't lock the pad for good.
    func remaining(at now: Date) -> TimeInterval {
        guard let lockedUntil else { return 0 }
        return min(max(lockedUntil.timeIntervalSince(now), 0), Self.maximumDelay)
    }

    func isLocked(at now: Date) -> Bool { remaining(at: now) > 0 }

    mutating func recordFailure(at now: Date) {
        failures += 1
        let delay = Self.delay(afterFailures: failures)
        lockedUntil = delay > 0 ? now.addingTimeInterval(delay) : nil
    }

    mutating func recordSuccess() {
        self = PINLockout()
    }
}

/// Which PIN a prompt checks. Each has its own lockout, so misses on one profile's PIN don't
/// lock the administrator out (and the reverse).
nonisolated enum PINLockoutTarget: Hashable, Sendable {
    case administrator
    /// A profile's own PIN, by profile ID.
    case profile(String)

    var storageSuffix: String {
        switch self {
        case .administrator: "administrator"
        case .profile(let id): "profile." + id
        }
    }
}

/// Where the PIN pad keeps a lockout between launches.
nonisolated struct PINLockoutStore {
    /// The single shared record of earlier versions; per-target keys start with it.
    static let defaultKey = "security.pinLockout"

    var defaults: UserDefaults = .standard
    var key: String = defaultKey

    /// The record for one PIN target.
    static func forTarget(_ target: PINLockoutTarget, defaults: UserDefaults = .standard) -> PINLockoutStore {
        migrateSharedRecord(in: defaults)
        return PINLockoutStore(defaults: defaults, key: defaultKey + "." + target.storageSuffix)
    }

    /// Earlier versions kept one record for every prompt. It becomes the administrator's, so
    /// updating doesn't grant fresh administrator guesses.
    private static func migrateSharedRecord(in defaults: UserDefaults) {
        guard let shared = defaults.data(forKey: defaultKey) else { return }
        let administratorKey = defaultKey + "." + PINLockoutTarget.administrator.storageSuffix
        if defaults.data(forKey: administratorKey) == nil { defaults.set(shared, forKey: administratorKey) }
        defaults.removeObject(forKey: defaultKey)
    }

    func load() -> PINLockout {
        guard let data = defaults.data(forKey: key),
              let lockout = try? JSONDecoder().decode(PINLockout.self, from: data) else { return PINLockout() }
        return lockout
    }

    func save(_ lockout: PINLockout) {
        guard let data = try? JSONEncoder().encode(lockout) else { return }
        defaults.set(data, forKey: key)
    }
}

/// The lockouts that apply to one prompt. A prompt that accepts more than one PIN (say, a
/// profile's own or the administrator's) is locked while any of them is, and a miss counts
/// against each.
nonisolated struct PINAttemptGuard {
    let targets: Set<PINLockoutTarget>
    var defaults: UserDefaults = .standard

    private func store(_ target: PINLockoutTarget) -> PINLockoutStore { .forTarget(target, defaults: defaults) }

    /// The longest wait among the targets.
    func remaining(at now: Date) -> TimeInterval {
        targets.map { store($0).load().remaining(at: now) }.max() ?? 0
    }

    func isLocked(at now: Date) -> Bool { remaining(at: now) > 0 }

    /// When the current lock ends (for restarting a countdown).
    func lockedUntil(at now: Date) -> Date? {
        targets.map { store($0).load() }.filter { $0.isLocked(at: now) }.compactMap(\.lockedUntil).max()
    }

    /// The most misses on any target.
    var failures: Int { targets.map { store($0).load().failures }.max() ?? 0 }

    /// Records a miss. While the administrator PIN is unreadable no entry can match it, so
    /// misses don't count against the administrator then.
    func recordFailure(at now: Date, administratorUnreadable: Bool = false) {
        for target in targets where !(target == .administrator && administratorUnreadable) {
            let store = store(target)
            var lockout = store.load()
            lockout.recordFailure(at: now)
            store.save(lockout)
        }
    }

    /// Records a correct entry. A prompt that also accepts another PIN doesn't say which one
    /// matched, so it never clears the administrator's misses (otherwise knowing your own PIN
    /// would reset the administrator's guesses).
    func recordSuccess() {
        for target in targets where target != .administrator || targets.count == 1 {
            store(target).save(PINLockout())
        }
    }
}

/// What to do with a profile's PIN when saving it.
enum PINChange: Equatable {
    case unchanged
    case set(String)
    case remove
}

/// A PIN prompt shown over the app.
struct PINRequest: Identifiable {
    enum Kind {
        /// Check an entered PIN.
        case verify((String) -> Bool)
        /// Choose a new PIN (entered twice).
        case create
    }

    let id = UUID()
    let title: String
    let message: String
    var profile: Profile?
    let kind: Kind
    /// Whose lockout this prompt uses. Per-profile PIN prompts pass `[.profile(id)]`; a
    /// prompt that also accepts the administrator PIN passes both.
    var lockoutTargets: Set<PINLockoutTarget> = [.administrator]
    /// Called with the entered (verified or newly chosen) PIN.
    let completion: (String) -> Void
}
