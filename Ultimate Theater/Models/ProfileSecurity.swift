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
nonisolated enum AdministratorPIN {
    private static let service = "UltimateTheater.PINs"
    private static let account = "administrator"

    static var isSet: Bool { Keychain.string(for: account, service: service) != nil }

    static func set(_ pin: String?) {
        Keychain.set(pin.map(PINHash.make), for: account, service: service)
    }

    static func verify(_ pin: String) -> Bool {
        guard let stored = Keychain.string(for: account, service: service) else { return true }
        return PINHash.verify(pin, against: stored)
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
    /// Called with the entered (verified or newly chosen) PIN.
    let completion: (String) -> Void
}
