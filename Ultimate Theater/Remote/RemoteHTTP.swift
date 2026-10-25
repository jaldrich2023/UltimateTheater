//
//  RemoteHTTP.swift
//  Ultimate Theater
//
//  The pure, testable pieces of the iPhone remote: a strict, size-limited HTTP/1.1 request
//  parser, response serialization, the local-network address filter, token helpers with
//  constant-time comparison, decoding of the remote's JSON commands, and the policy decisions
//  (Host allowlist, pairing throttle, cookie lifetime, connection and stream limits).
//

import Foundation
import Network
import CryptoKit

// MARK: - Requests

nonisolated struct HTTPRequest: Sendable, Equatable {
    var method: String
    /// The percent-decoded path, without the query.
    var path: String
    var query: [String: String]
    /// Header values by lowercased name.
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    var cookies: [String: String] { HTTPParser.cookies(from: header("cookie")) }
}

nonisolated enum HTTPError: Error, Equatable, Sendable {
    case malformed
    case headersTooLarge
    case bodyTooLarge
    case unsupportedMethod
    case unsupportedEncoding

    var status: Int {
        switch self {
        case .malformed: 400
        case .headersTooLarge: 431
        case .bodyTooLarge: 413
        case .unsupportedMethod: 405
        case .unsupportedEncoding: 501
        }
    }
}

nonisolated enum HTTPParseResult: Equatable, Sendable {
    /// More bytes are needed.
    case incomplete
    /// A whole request, and how many bytes of the buffer it used.
    case complete(HTTPRequest, consumed: Int)
    case failure(HTTPError)
}

/// A deliberately small HTTP/1.1 parser: GET and POST only, `Content-Length` bodies only
/// (no chunked encoding), and hard limits on header and body size.
nonisolated enum HTTPParser {
    static let maxHeaderBytes = 8 * 1024
    static let maxBodyBytes = 16 * 1024
    static let maxHeaderCount = 48
    static let allowedMethods: Set<String> = ["GET", "POST"]

    static func parse(_ buffer: Data) -> HTTPParseResult {
        let bytes = [UInt8](buffer)
        guard let headerEnd = endOfHeaders(in: bytes) else {
            return bytes.count > maxHeaderBytes ? .failure(.headersTooLarge) : .incomplete
        }
        guard headerEnd <= maxHeaderBytes else { return .failure(.headersTooLarge) }
        // Header bytes must be printable ASCII (plus CR, LF, and tab).
        guard bytes[..<headerEnd].allSatisfy({ $0 == 9 || $0 == 10 || $0 == 13 || (32...126).contains($0) }),
              let head = String(bytes: bytes[..<headerEnd], encoding: .ascii) else { return .failure(.malformed) }

        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .failure(.malformed) }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return .failure(.malformed) }
        let method = String(parts[0]), target = String(parts[1]), version = String(parts[2])
        guard !method.isEmpty, method.allSatisfy({ $0.isASCII && $0.isUppercase }) else { return .failure(.malformed) }
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else { return .failure(.malformed) }
        guard allowedMethods.contains(method) else { return .failure(.unsupportedMethod) }
        guard target.hasPrefix("/"), target.count <= 2048 else { return .failure(.malformed) }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty else { continue }
            // Obsolete line folding is a classic smuggling vector; refuse it.
            guard let first = line.first, first != " ", first != "\t",
                  let colon = line.firstIndex(of: ":") else { return .failure(.malformed) }
            let name = line[..<colon].lowercased()
            guard !name.isEmpty, name.allSatisfy(isTokenCharacter) else { return .failure(.malformed) }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "content-length", headers[name] != nil { return .failure(.malformed) }
            if let existing = headers[name] {
                headers[name] = name == "cookie" ? existing + "; " + value : existing + ", " + value
            } else {
                headers[name] = value
            }
            guard headers.count <= maxHeaderCount else { return .failure(.headersTooLarge) }
        }
        if version == "HTTP/1.1", headers["host"] == nil { return .failure(.malformed) }
        if headers["transfer-encoding"] != nil { return .failure(.unsupportedEncoding) }

        var length = 0
        if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.count <= 6, raw.allSatisfy(\.isASCIIDigitCharacter), let value = Int(raw) else {
                return .failure(.malformed)
            }
            length = value
        }
        guard length <= maxBodyBytes else { return .failure(.bodyTooLarge) }
        let bodyStart = headerEnd + 4
        guard bytes.count >= bodyStart + length else { return .incomplete }

        let (rawPath, rawQuery) = splitTarget(target)
        guard let path = rawPath.removingPercentEncoding, !path.contains("\0") else { return .failure(.malformed) }
        let request = HTTPRequest(method: method, path: path, query: parseQuery(rawQuery), headers: headers,
                                  body: Data(bytes[bodyStart..<(bodyStart + length)]))
        return .complete(request, consumed: bodyStart + length)
    }

    /// Whether the blank line ending the headers has arrived (a body may still be coming).
    static func hasCompleteHeaders(_ data: Data) -> Bool {
        endOfHeaders(in: [UInt8](data.prefix(maxHeaderBytes + 4))) != nil
    }

    /// Index of the blank line's first CR (the end of the headers), if it has arrived.
    private static func endOfHeaders(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        let limit = min(bytes.count - 4, maxHeaderBytes + 1)
        guard limit >= 0 else { return nil }
        for index in 0...limit where bytes[index] == 13 && bytes[index + 1] == 10 && bytes[index + 2] == 13 && bytes[index + 3] == 10 {
            return index
        }
        return nil
    }

    private static func isTokenCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || "!#$%&'*+-.^_`|~".contains(character))
    }

    private static func splitTarget(_ target: String) -> (path: String, query: String) {
        let withoutFragment = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        let pieces = withoutFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        return (String(pieces[0]), pieces.count > 1 ? String(pieces[1]) : "")
    }

    /// `a=1&b=two+words` → ["a": "1", "b": "two words"]. Later duplicates are ignored.
    static func parseQuery(_ query: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = decodeComponent(String(pieces[0])), !key.isEmpty, result[key] == nil else { continue }
            result[key] = pieces.count > 1 ? decodeComponent(String(pieces[1])) ?? "" : ""
        }
        return result
    }

    private static func decodeComponent(_ text: String) -> String? {
        text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }

    static func cookies(from header: String?) -> [String: String] {
        guard let header else { return [:] }
        var result: [String: String] = [:]
        for part in header.split(separator: ";") {
            let pieces = part.split(separator: "=", maxSplits: 1)
            guard pieces.count == 2 else { continue }
            let name = pieces[0].trimmingCharacters(in: .whitespaces)
            if result[name] == nil { result[name] = pieces[1].trimmingCharacters(in: .whitespaces) }
        }
        return result
    }
}

private extension Character {
    nonisolated var isASCIIDigitCharacter: Bool { isASCII && isNumber }
}

// MARK: - Responses

nonisolated struct HTTPResponse: Sendable {
    var status: Int
    var headers: [(name: String, value: String)] = []
    var body = Data()
    /// Server-Sent Events: the connection stays open and receives broadcasts.
    var isEventStream = false
    /// Answered for a paired device (its cookie checked out). Not sent; lets the server
    /// keep connections free for paired phones.
    var isFromPairedDevice = false

    static func json(_ data: Data, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json; charset=utf-8")], body: data)
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
        return json(body, status: status)
    }

    static func html(_ text: String) -> HTTPResponse {
        HTTPResponse(status: 200, headers: [("Content-Type", "text/html; charset=utf-8")], body: Data(text.utf8))
    }

    static func redirect(to location: String, setCookie: String? = nil) -> HTTPResponse {
        var response = HTTPResponse(status: 303, headers: [("Location", location)])
        if let setCookie { response.headers.append(("Set-Cookie", setCookie)) }
        return response
    }

    static func image(_ data: Data) -> HTTPResponse {
        HTTPResponse(status: 200, headers: [("Content-Type", "image/jpeg"), ("Cache-Control", "private, max-age=3600")], body: data)
    }

    static func eventStream(initial: Data) -> HTTPResponse {
        HTTPResponse(status: 200, headers: [("Content-Type", "text/event-stream; charset=utf-8")],
                     body: SSE.event(initial), isEventStream: true)
    }

    static let reasons: [Int: String] = [
        200: "OK", 204: "No Content", 303: "See Other", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
        404: "Not Found", 405: "Method Not Allowed", 408: "Request Timeout", 409: "Conflict", 413: "Payload Too Large",
        421: "Misdirected Request", 429: "Too Many Requests", 431: "Request Header Fields Too Large", 500: "Internal Server Error",
        501: "Not Implemented", 503: "Service Unavailable",
    ]

    /// Headers every response carries: nothing is cached, framed, sniffed, or referred.
    static let securityHeaders: [(String, String)] = [
        ("X-Content-Type-Options", "nosniff"),
        ("X-Frame-Options", "DENY"),
        ("Referrer-Policy", "no-referrer"),
        ("Cross-Origin-Resource-Policy", "same-origin"),
        ("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self'; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"),
    ]

    /// The status line and headers (and body, unless this is an event stream's opening).
    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Status")\r\n"
        var names = Set<String>()
        for (name, value) in headers {
            names.insert(name.lowercased())
            head += "\(name): \(Self.sanitized(value))\r\n"
        }
        if !names.contains("cache-control") { head += "Cache-Control: no-store\r\n" }
        for (name, value) in Self.securityHeaders { head += "\(name): \(value)\r\n" }
        if isEventStream {
            head += "Connection: keep-alive\r\n\r\n"
        } else {
            head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        }
        return Data(head.utf8) + body
    }

    /// Header values never carry line breaks (no response splitting).
    private static func sanitized(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
    }
}

/// Server-Sent Events framing.
nonisolated enum SSE {
    static func event(_ json: Data) -> Data {
        // JSON from JSONSerialization never contains raw newlines, so one `data:` line suffices.
        Data("data: ".utf8) + json + Data("\n\n".utf8)
    }

    static let heartbeat = Data(": keep-alive\n\n".utf8)
}

// MARK: - Local network filter

/// Only peers on the local network may talk to the remote server: private IPv4 ranges,
/// IPv4 link-local, loopback, and IPv6 link-local (or IPv4-mapped private addresses).
nonisolated enum LANAddressFilter {
    static func isAllowed(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        return isAllowed(host)
    }

    static func isAllowed(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address): isAllowedIPv4([UInt8](address.rawValue))
        case .ipv6(let address): isAllowedIPv6([UInt8](address.rawValue))
        default: false // Names are never accepted as peers.
        }
    }

    /// For tests and diagnostics: "192.168.1.20", "fe80::1%en0".
    static func isAllowed(address text: String) -> Bool {
        if let v4 = IPv4Address(text) { return isAllowedIPv4([UInt8](v4.rawValue)) }
        if let v6 = IPv6Address(text) { return isAllowedIPv6([UInt8](v6.rawValue)) }
        return false
    }

    static func isAllowedIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        switch (bytes[0], bytes[1]) {
        case (10, _): return true                          // 10.0.0.0/8
        case (172, 16...31): return true                   // 172.16.0.0/12
        case (192, 168): return true                       // 192.168.0.0/16
        case (169, 254): return true                       // Link-local
        case (127, _): return true                         // Loopback (this Mac)
        default: return false
        }
    }

    static func isAllowedIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return true }              // fe80::/10 link-local
        if bytes[0..<15].allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true }  // ::1
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return isAllowedIPv4(Array(bytes[12..<16]))                           // ::ffff:a.b.c.d
        }
        return false
    }
}

// MARK: - Tokens

nonisolated enum RemoteToken {
    /// 32 random bytes as 64 lowercase hex characters. `SystemRandomNumberGenerator` is
    /// cryptographically secure on Apple platforms.
    static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    /// A random six-digit pairing code.
    static func pairingCode() -> String {
        var generator = SystemRandomNumberGenerator()
        return String(format: "%06d", Int.random(in: 0..<1_000_000, using: &generator))
    }

    static func isWellFormed(_ token: String) -> Bool {
        token.utf8.count == 64 && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func isWellFormedCode(_ code: String) -> Bool {
        code.utf8.count == 6 && code.utf8.allSatisfy { (48...57).contains($0) }
    }

    /// Only hashes are stored, so the saved device list never holds a usable token.
    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Compares without exiting early, so timing reveals nothing about where values differ.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        var difference = UInt8(truncatingIfNeeded: a.count ^ b.count)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            difference |= x ^ y
        }
        return difference == 0
    }
}

// MARK: - Commands

/// Something the phone asks the player to do.
nonisolated enum RemoteCommand: Equatable, Sendable {
    case togglePlayback
    case play
    case pause
    case skip(Double)
    case seek(Double)
    case volume(Double)
    case toggleMute
    case audio(String)
    case subtitle(String?)
    case previousEpisode
    case nextEpisode
    case skipIntro
    case skipCredits
    case stop
    case playTitle(String)

    static let maxBodyBytes = 1024

    /// Decodes `{"action": "...", "value": ...}`. Anything unexpected is rejected.
    static func decode(_ data: Data) -> RemoteCommand? {
        guard !data.isEmpty, data.count <= maxBodyBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = object["action"] as? String else { return nil }
        let value = object["value"]
        switch action {
        case "togglePlayback": return .togglePlayback
        case "play": return .play
        case "pause": return .pause
        case "toggleMute": return .toggleMute
        case "previousEpisode": return .previousEpisode
        case "nextEpisode": return .nextEpisode
        case "skipIntro": return .skipIntro
        case "skipCredits": return .skipCredits
        case "stop": return .stop
        case "skip":
            guard let seconds = number(value), abs(seconds) <= 600 else { return nil }
            return .skip(seconds)
        case "seek":
            guard let seconds = number(value), seconds >= 0, seconds <= 60 * 60 * 24 else { return nil }
            return .seek(seconds)
        case "volume":
            guard let level = number(value), (0...1).contains(level) else { return nil }
            return .volume(level)
        case "audio":
            guard let id = identifier(value) else { return nil }
            return .audio(id)
        case "subtitle":
            if value == nil || value is NSNull { return .subtitle(nil) }
            guard let id = identifier(value) else { return nil }
            return .subtitle(id)
        case "playTitle":
            guard let id = identifier(value) else { return nil }
            return .playTitle(id)
        default:
            return nil
        }
    }

    private static func number(_ value: Any?) -> Double? {
        // JSON booleans also bridge to NSNumber; refuse them.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    /// Track and title IDs: short, and only characters our own IDs use.
    static func identifier(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 128,
              text.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.:".unicodeScalars.contains($0)) })
        else { return nil }
        return text
    }
}

/// A short device label from the browser's User-Agent ("iPhone", "iPad", …).
nonisolated enum RemoteDeviceName {
    static func from(userAgent: String?) -> String {
        guard let userAgent else { return "Web Browser" }
        for (needle, name) in [("iPhone", "iPhone"), ("iPad", "iPad"), ("Android", "Android Phone"), ("Macintosh", "Mac Browser")]
        where userAgent.contains(needle) {
            return name
        }
        return "Web Browser"
    }
}

// MARK: - Host allowlist

/// Defends against DNS rebinding: a page on another site that points its own name at this
/// Mac still sends its own name in `Host`, so only the Mac's addresses and names (with the
/// server's port) are accepted.
nonisolated enum RemoteHostPolicy {
    /// Names that always mean this Mac.
    static let loopbackNames: Set<String> = ["localhost", "127.0.0.1", "::1"]

    /// Splits "192.168.1.5:52525", "[fe80::1]:80", or "mac.local" into a lowercased host
    /// (brackets and any IPv6 zone removed, trailing dot dropped) and its port.
    static func split(_ value: String) -> (host: String, port: UInt16?)? {
        let text = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty, text.utf8.count <= 255 else { return nil }
        var host: Substring, portText: Substring?
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            host = text[text.index(after: text.startIndex)..<close]
            let rest = text[text.index(after: close)...]
            if rest.isEmpty {
                portText = nil
            } else {
                guard rest.hasPrefix(":") else { return nil }
                portText = rest.dropFirst()
            }
        } else {
            let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
            guard pieces.count <= 2 else { return nil } // Bare IPv6 isn't valid in Host.
            host = pieces[0]
            portText = pieces.count == 2 ? pieces[1] : nil
        }
        if let percent = host.firstIndex(of: "%") { host = host[..<percent] }
        if host.hasSuffix(".") { host = host.dropLast() }
        guard !host.isEmpty else { return nil }
        var port: UInt16?
        if let portText {
            guard !portText.isEmpty, portText.count <= 5, portText.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = UInt16(portText) else { return nil }
            port = value
        }
        return (String(host), port)
    }

    /// Whether a request's `Host` header names this server. `allowedHosts` holds the Mac's
    /// current addresses and `.local` name, lowercased; loopback names are always allowed.
    /// The port must match too (it may be left out only when the server is on port 80).
    static func isAllowed(hostHeader: String?, allowedHosts: Set<String>, port: UInt16) -> Bool {
        guard let hostHeader, let parts = split(hostHeader) else { return false }
        guard (parts.port ?? 80) == port else { return false }
        return loopbackNames.contains(parts.host) || allowedHosts.contains(parts.host)
    }
}

// MARK: - Pairing throttle

/// Limits pairing-code guesses without letting one noisy device lock everyone out.
/// • Only attempts that carry a well-formed code count.
/// • Each peer gets `perPeerLimit` wrong guesses per code, and an exponential delay between
///   guesses that carries over to new codes (so making a new code doesn't reset an attacker).
/// • All peers together get `globalLimit` wrong guesses per code; past that the code is
///   retired. One device alone can't reach it, so it can't stop a phone from pairing.
/// Global and unique-local IPv6 peers are grouped by /64, because a single host can pick any
/// number of addresses in its prefix. Link-local peers (fe80::/10) all share one prefix, so
/// they're told apart by full address instead; past `maxLinkLocalPeers` of them, new ones
/// share a single record, so minting addresses doesn't buy more guesses.
nonisolated struct PairingThrottle: Sendable {
    static let perPeerLimit = 5
    static let globalLimit = 100
    static let maxLinkLocalPeers = 16
    /// The record shared by link-local peers past the cap.
    static let linkLocalOverflowKey = "ll:overflow"
    static let maxDelay: TimeInterval = 300
    /// A peer that's been quiet this long starts over.
    static let forgetAfter: TimeInterval = 30 * 60
    static let maxTrackedPeers = 256

    enum Decision: Equatable, Sendable {
        case allowed
        /// Try again after this many seconds.
        case wait(TimeInterval)
        /// This peer has used up its guesses for the current code.
        case peerExhausted
    }

    private struct Record: Sendable {
        var codeFailures = 0
        var failures = 0
        var nextAttempt = Date.distantPast
        var lastFailure = Date.distantPast
    }

    private var records: [String: Record] = [:]
    private(set) var codeFailures = 0

    /// Whether a pairing attempt is a guess that counts: only a well-formed six-digit code.
    /// A visit to /pair without one (a stale link, a probe) can't lock anyone out.
    static func countsAsGuess(_ code: String?) -> Bool {
        guard let code else { return false }
        return RemoteToken.isWellFormedCode(code)
    }

    /// Delay before the next guess after `failures` wrong ones: none for the first, then
    /// 1, 2, 4, 8… seconds, up to `maxDelay`.
    static func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures >= 2 else { return 0 }
        return min(pow(2, Double(min(failures - 2, 30))), maxDelay)
    }

    /// Who's guessing: IPv4 addresses as they are, link-local IPv6 addresses in full ("ll:…",
    /// zone dropped), other IPv6 addresses by /64 prefix ("v6:…").
    static func peerKey(_ address: String) -> String {
        let bare = address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? address
        if let v4 = IPv4Address(bare) { return "\(v4)" }
        if let v6 = IPv6Address(bare) {
            let bytes = [UInt8](v6.rawValue)
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
                return bytes[12..<16].map(String.init).joined(separator: ".")
            }
            if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 {
                return "ll:" + bytes.map { String(format: "%02x", $0) }.joined()
            }
            return "v6:" + bytes[0..<8].map { String(format: "%02x", $0) }.joined()
        }
        return address
    }

    static func isLinkLocalKey(_ key: String) -> Bool { key.hasPrefix("ll:") }

    /// The record a peer's guesses go to: its own, or the shared one once the link-local
    /// cap is reached.
    private func recordKey(for peer: String, now: Date) -> String {
        let key = Self.peerKey(peer)
        guard Self.isLinkLocalKey(key), key != Self.linkLocalOverflowKey, live(records[key], now: now) == nil else { return key }
        let tracked = records.filter { key, record in
            Self.isLinkLocalKey(key) && key != Self.linkLocalOverflowKey && live(record, now: now) != nil
        }.count
        return tracked >= Self.maxLinkLocalPeers ? Self.linkLocalOverflowKey : key
    }

    func decision(for peer: String, now: Date) -> Decision {
        guard let record = live(records[recordKey(for: peer, now: now)], now: now) else { return .allowed }
        if record.codeFailures >= Self.perPeerLimit { return .peerExhausted }
        if record.nextAttempt > now { return .wait(record.nextAttempt.timeIntervalSince(now)) }
        return .allowed
    }

    /// Records a wrong guess. Returns true when the code has had too many wrong guesses in
    /// total and must be retired.
    @discardableResult
    mutating func recordFailure(for peer: String, now: Date) -> Bool {
        let key = recordKey(for: peer, now: now)
        var record = live(records[key], now: now) ?? Record()
        record.codeFailures += 1
        record.failures += 1
        record.lastFailure = now
        record.nextAttempt = now.addingTimeInterval(Self.delay(afterFailures: record.failures))
        records[key] = record
        if records.count > Self.maxTrackedPeers {
            records = records.filter { live($0.value, now: now) != nil }
            if records.count > Self.maxTrackedPeers,
               let oldest = records.min(by: { $0.value.lastFailure < $1.value.lastFailure })?.key {
                records[oldest] = nil
            }
        }
        codeFailures += 1
        return codeFailures >= Self.globalLimit
    }

    mutating func recordSuccess(for peer: String) {
        records[Self.peerKey(peer)] = nil
    }

    /// A new code: every peer gets fresh guesses for it, but delays still apply.
    mutating func newCode() {
        codeFailures = 0
        for key in records.keys { records[key]?.codeFailures = 0 }
    }

    private func live(_ record: Record?, now: Date) -> Record? {
        guard let record, now.timeIntervalSince(record.lastFailure) < Self.forgetAfter else { return nil }
        return record
    }
}

// MARK: - Cookie

/// The paired device's cookie. It lasts 30 days and is renewed while the phone is used; the
/// Mac also refuses devices it hasn't seen for that long, whatever the browser keeps.
nonisolated enum RemoteCookie {
    static let name = "ut_remote"
    static let lifetime: TimeInterval = 30 * 24 * 60 * 60
    /// How often an active phone's cookie is re-sent with a fresh lifetime.
    static let renewInterval: TimeInterval = 60 * 60

    /// `token` must already be well-formed (hex), so it can't inject attributes.
    static func header(token: String) -> String {
        "\(name)=\(token); Path=/; Max-Age=\(Int(lifetime)); HttpOnly; SameSite=Strict"
    }

    static func shouldRenew(lastRenewed: Date?, now: Date) -> Bool {
        guard let lastRenewed else { return true }
        return now.timeIntervalSince(lastRenewed) >= renewInterval
    }

    static func isExpired(lastSeen: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastSeen) > lifetime
    }
}

// MARK: - Connection limits

nonisolated enum RemoteConnectionLimits {
    static let maxConnections = 32
    /// Connections only peers that have shown a working cookie may use, so strangers
    /// filling the server can't keep a paired phone out.
    static let reservedForPaired = 8
    /// Enough for Safari's parallel requests plus the live-update stream.
    static let maxConnectionsPerPeer = 8
    /// Distinct link-local peers with their own connection share; more share one.
    static let maxLinkLocalPeers = 8
    /// The share used by link-local peers past the cap.
    static let linkLocalOverflowKey = "ll:overflow"
    /// How long a new connection has to send its request headers.
    static let headerTimeout: TimeInterval = 3
    /// How long a whole request (headers and body) may take.
    static let requestTimeout: TimeInterval = 10
    /// How many peers are remembered as paired.
    static let maxKnownPairedPeers = 64
    static let maxStreams = 8
    static let maxStreamsPerPeer = 2
    /// A stream with this much unsent data is a stalled phone, and is dropped.
    static let maxBytesInFlight = 256 * 1024

    /// `isKnownPaired`: the peer has made a request with a cookie the app accepted.
    static func canAccept(total: Int, fromPeer: Int, isKnownPaired: Bool = false) -> Bool {
        let cap = isKnownPaired ? maxConnections : maxConnections - reservedForPaired
        return total < cap && fromPeer < maxConnectionsPerPeer
    }

    /// The connection-share key for a peer: link-local peers past the cap share one.
    static func shareKey(_ peerKey: String, linkLocalKeysInUse: Set<String>) -> String {
        guard PairingThrottle.isLinkLocalKey(peerKey), !linkLocalKeysInUse.contains(peerKey) else { return peerKey }
        let distinct = linkLocalKeysInUse.subtracting([linkLocalOverflowKey]).count
        return distinct >= maxLinkLocalPeers ? linkLocalOverflowKey : peerKey
    }

    static func canOpenStream(total: Int, fromPeer: Int) -> Bool {
        total < maxStreams && fromPeer < maxStreamsPerPeer
    }

    /// Whether queuing `adding` more bytes on a stream would pass the limit.
    static func shouldDrop(bytesInFlight: Int, adding: Int) -> Bool {
        bytesInFlight + adding > maxBytesInFlight
    }
}
