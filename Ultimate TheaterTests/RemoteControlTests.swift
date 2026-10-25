//
//  RemoteControlTests.swift
//  Ultimate TheaterTests
//
//  The iPhone remote's pure parts: HTTP parsing (including malformed and oversized input),
//  responses, the local-network filter, tokens, command decoding, and the security policy
//  decisions (Host allowlist, pairing throttle, cookie lifetime, connection limits).
//

import Testing
import Foundation
import Network
@testable import Ultimate_Theater

struct HTTPParserTests {
    private func parse(_ text: String) -> HTTPParseResult {
        HTTPParser.parse(Data(text.utf8))
    }

    private func request(_ text: String) -> HTTPRequest? {
        if case .complete(let request, _) = parse(text) { return request }
        return nil
    }

    @Test func parsesGetWithQueryAndCookies() throws {
        let request = try #require(request("GET /api/browse?q=star+wars&x=%2F HTTP/1.1\r\nHost: 192.168.1.5:52525\r\nCookie: a=1; ut_remote=abc\r\n\r\n"))
        #expect(request.method == "GET")
        #expect(request.path == "/api/browse")
        #expect(request.query["q"] == "star wars")
        #expect(request.query["x"] == "/")
        #expect(request.header("HOST") == "192.168.1.5:52525")
        #expect(request.cookies["ut_remote"] == "abc")
        #expect(request.body.isEmpty)
    }

    @Test func parsesPostBody() throws {
        let body = #"{"action":"play"}"#
        let text = "POST /api/command HTTP/1.1\r\nHost: mac\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        guard case .complete(let request, let consumed) = parse(text) else { Issue.record("Not parsed"); return }
        #expect(String(decoding: request.body, as: UTF8.self) == body)
        #expect(consumed == text.utf8.count)
    }

    @Test func waitsForMoreBytes() {
        #expect(parse("GET / HTTP/1.1\r\nHost: mac\r\n") == .incomplete)
        #expect(parse("POST /pair HTTP/1.1\r\nHost: mac\r\nContent-Length: 10\r\n\r\n12345") == .incomplete)
        #expect(parse("") == .incomplete)
    }

    @Test func rejectsMalformedRequestLines() {
        #expect(parse("GET\r\n\r\n") == .failure(.malformed))
        #expect(parse("GET /  HTTP/1.1\r\nHost: mac\r\n\r\n") == .failure(.malformed))
        #expect(parse("GET relative HTTP/1.1\r\nHost: mac\r\n\r\n") == .failure(.malformed))
        #expect(parse("GET / HTTP/2\r\nHost: mac\r\n\r\n") == .failure(.malformed))
        #expect(parse("get / HTTP/1.1\r\nHost: mac\r\n\r\n") == .failure(.malformed))
        #expect(parse("GET / HTTP/1.1\r\n\r\n") == .failure(.malformed)) // HTTP/1.1 needs Host.
        #expect(parse("GET /%ZZ HTTP/1.1\r\nHost: mac\r\n\r\n") == .failure(.malformed))
        #expect(parse("GET /%00 HTTP/1.1\r\nHost: mac\r\n\r\n") == .failure(.malformed))
    }

    @Test func rejectsBadHeaders() {
        #expect(parse("GET / HTTP/1.1\r\nHost: mac\r\nNoColon\r\n\r\n") == .failure(.malformed))
        #expect(parse("GET / HTTP/1.1\r\nHost: mac\r\n folded: value\r\n\r\n") == .failure(.malformed))
        #expect(parse("GET / HTTP/1.1\r\nHost: mac\r\nBad Name: x\r\n\r\n") == .failure(.malformed))
        #expect(parse("GET / HTTP/1.1\r\nHost: mac\r\nX: caf\u{E9}\r\n\r\n") == .failure(.malformed))
        #expect(parse("POST / HTTP/1.1\r\nHost: mac\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx") == .failure(.malformed))
        #expect(parse("POST / HTTP/1.1\r\nHost: mac\r\nContent-Length: -1\r\n\r\n") == .failure(.malformed))
        #expect(parse("POST / HTTP/1.1\r\nHost: mac\r\nContent-Length: 1e3\r\n\r\n") == .failure(.malformed))
    }

    @Test func rejectsUnsupportedFeatures() {
        #expect(parse("DELETE / HTTP/1.1\r\nHost: mac\r\n\r\n") == .failure(.unsupportedMethod))
        #expect(parse("POST / HTTP/1.1\r\nHost: mac\r\nTransfer-Encoding: chunked\r\n\r\n") == .failure(.unsupportedEncoding))
    }

    @Test func enforcesSizeLimits() {
        let hugeHeader = "GET / HTTP/1.1\r\nHost: mac\r\nX-Pad: " + String(repeating: "a", count: HTTPParser.maxHeaderBytes) + "\r\n\r\n"
        #expect(parse(hugeHeader) == .failure(.headersTooLarge))
        // No blank line yet, but already over the limit: don't keep buffering.
        #expect(parse("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: HTTPParser.maxHeaderBytes + 10)) == .failure(.headersTooLarge))
        #expect(parse("POST / HTTP/1.1\r\nHost: mac\r\nContent-Length: \(HTTPParser.maxBodyBytes + 1)\r\n\r\n") == .failure(.bodyTooLarge))
        let manyHeaders = "GET / HTTP/1.1\r\nHost: mac\r\n" + (0...HTTPParser.maxHeaderCount).map { "X-\($0): 1\r\n" }.joined() + "\r\n"
        #expect(parse(manyHeaders) == .failure(.headersTooLarge))
    }

    @Test func errorStatuses() {
        #expect(HTTPError.malformed.status == 400)
        #expect(HTTPError.bodyTooLarge.status == 413)
        #expect(HTTPError.headersTooLarge.status == 431)
    }
}

struct HTTPResponseTests {
    @Test func serializesWithSecurityHeaders() {
        let text = String(decoding: HTTPResponse.html("<p>hi</p>").serialized(), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Length: 9\r\n"))
        #expect(text.contains("Connection: close\r\n"))
        #expect(text.contains("X-Frame-Options: DENY\r\n"))
        #expect(text.contains("Cache-Control: no-store\r\n"))
        #expect(text.hasSuffix("\r\n\r\n<p>hi</p>"))
    }

    @Test func headerValuesCantSplitResponses() {
        let text = String(decoding: HTTPResponse.redirect(to: "/\r\nSet-Cookie: evil=1").serialized(), as: UTF8.self)
        #expect(!text.contains("\r\nSet-Cookie: evil"))
    }

    @Test func eventStreamStaysOpen() {
        let text = String(decoding: HTTPResponse.eventStream(initial: Data("{}".utf8)).serialized(), as: UTF8.self)
        #expect(text.contains("text/event-stream"))
        #expect(!text.contains("Content-Length"))
        #expect(text.hasSuffix("data: {}\n\n"))
    }
}

struct LANAddressFilterTests {
    @Test(arguments: ["10.0.0.4", "172.16.0.1", "172.31.255.254", "192.168.1.20", "169.254.3.3", "127.0.0.1",
                      "fe80::1", "fe80::1c2b:3cff:fe4d:5e6f", "::1", "::ffff:192.168.0.9"])
    func allowsLocalAddresses(_ address: String) {
        #expect(LANAddressFilter.isAllowed(address: address))
    }

    @Test(arguments: ["8.8.8.8", "172.32.0.1", "172.15.0.1", "100.64.0.1", "192.169.0.1", "1.1.1.1",
                      "2001:4860:4860::8888", "fd00::1", "::ffff:8.8.8.8", "localhost", "example.com", ""])
    func rejectsOtherAddresses(_ address: String) {
        #expect(!LANAddressFilter.isAllowed(address: address))
    }

    @Test func rejectsNamedEndpoints() {
        #expect(!LANAddressFilter.isAllowed(.hostPort(host: "example.com", port: 80)))
        #expect(LANAddressFilter.isAllowed(.hostPort(host: "192.168.1.2", port: 80)))
    }
}

struct RemoteTokenTests {
    @Test func tokensAreRandomAndWellFormed() {
        let a = RemoteToken.generate(), b = RemoteToken.generate()
        #expect(a != b)
        #expect(RemoteToken.isWellFormed(a))
        #expect(a.count == 64)
    }

    @Test func rejectsMalformedTokens() {
        #expect(!RemoteToken.isWellFormed(""))
        #expect(!RemoteToken.isWellFormed(String(repeating: "g", count: 64)))
        #expect(!RemoteToken.isWellFormed(String(repeating: "A", count: 64))) // Lowercase only.
        #expect(!RemoteToken.isWellFormed(String(repeating: "a", count: 63)))
    }

    @Test func pairingCodesAreSixDigits() {
        for _ in 0..<50 {
            let code = RemoteToken.pairingCode()
            #expect(RemoteToken.isWellFormedCode(code))
        }
        #expect(!RemoteToken.isWellFormedCode("12345"))
        #expect(!RemoteToken.isWellFormedCode("12345a"))
        #expect(!RemoteToken.isWellFormedCode("１２３４５６")) // Full-width digits.
    }

    @Test func hashesAreStableAndDistinct() {
        let token = RemoteToken.generate()
        #expect(RemoteToken.hash(token) == RemoteToken.hash(token))
        #expect(RemoteToken.hash(token) != RemoteToken.hash(RemoteToken.generate()))
        #expect(RemoteToken.hash(token) != token)
    }

    @Test func constantTimeComparison() {
        #expect(RemoteToken.constantTimeEquals("123456", "123456"))
        #expect(!RemoteToken.constantTimeEquals("123456", "123457"))
        #expect(!RemoteToken.constantTimeEquals("123456", "1234567"))
        #expect(!RemoteToken.constantTimeEquals("", "1"))
        #expect(RemoteToken.constantTimeEquals("", ""))
    }
}

struct RemoteCommandTests {
    private func decode(_ json: String) -> RemoteCommand? {
        RemoteCommand.decode(Data(json.utf8))
    }

    @Test func decodesCommands() {
        #expect(decode(#"{"action":"togglePlayback"}"#) == .togglePlayback)
        #expect(decode(#"{"action":"skip","value":-10}"#) == .skip(-10))
        #expect(decode(#"{"action":"seek","value":123.5}"#) == .seek(123.5))
        #expect(decode(#"{"action":"volume","value":0.4}"#) == .volume(0.4))
        #expect(decode(#"{"action":"audio","value":"2"}"#) == .audio("2"))
        #expect(decode(#"{"action":"subtitle","value":null}"#) == .subtitle(nil))
        #expect(decode(#"{"action":"subtitle"}"#) == .subtitle(nil))
        #expect(decode(#"{"action":"subtitle","value":"ext-1"}"#) == .subtitle("ext-1"))
        #expect(decode(#"{"action":"playTitle","value":"lib-3F2A"}"#) == .playTitle("lib-3F2A"))
        #expect(decode(#"{"action":"nextEpisode"}"#) == .nextEpisode)
        #expect(decode(#"{"action":"skipCredits"}"#) == .skipCredits)
        #expect(decode(#"{"action":"stop"}"#) == .stop)
    }

    @Test func rejectsBadCommands() {
        #expect(decode("") == nil)
        #expect(decode("not json") == nil)
        #expect(decode("[]") == nil)
        #expect(decode(#"{"value":1}"#) == nil)
        #expect(decode(#"{"action":"format-disk"}"#) == nil)
        #expect(decode(#"{"action":"skip"}"#) == nil)
        #expect(decode(#"{"action":"skip","value":"10"}"#) == nil)
        #expect(decode(#"{"action":"skip","value":true}"#) == nil)
        #expect(decode(#"{"action":"skip","value":100000}"#) == nil)
        #expect(decode(#"{"action":"seek","value":-5}"#) == nil)
        #expect(decode(#"{"action":"volume","value":1.5}"#) == nil)
        #expect(decode(#"{"action":"audio","value":3}"#) == nil)
        #expect(decode(#"{"action":"playTitle","value":"../../etc/passwd"}"#) == nil)
        #expect(decode(#"{"action":"playTitle","value":"<script>"}"#) == nil)
        #expect(decode(#"{"action":"playTitle","value":""}"#) == nil)
    }

    @Test func rejectsOversizedBodies() {
        let padding = String(repeating: "x", count: RemoteCommand.maxBodyBytes)
        #expect(decode(#"{"action":"play","pad":"\#(padding)"}"#) == nil)
        #expect(RemoteCommand.identifier(String(repeating: "a", count: 129)) == nil)
        #expect(RemoteCommand.identifier(String(repeating: "a", count: 128)) != nil)
    }

    @Test func deviceNames() {
        #expect(RemoteDeviceName.from(userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X)") == "iPhone")
        #expect(RemoteDeviceName.from(userAgent: "Mozilla/5.0 (iPad; CPU OS 27_0 like Mac OS X)") == "iPad")
        #expect(RemoteDeviceName.from(userAgent: nil) == "Web Browser")
    }
}

struct RemoteHostPolicyTests {
    private let mac: Set<String> = ["192.168.1.20", "fe80::1c2b:3cff:fe4d:5e6f", "johns-mac.local"]

    private func allowed(_ host: String?, port: UInt16 = 52_525) -> Bool {
        RemoteHostPolicy.isAllowed(hostHeader: host, allowedHosts: mac, port: port)
    }

    @Test func allowsTheMacsOwnNames() {
        #expect(allowed("192.168.1.20:52525"))
        #expect(allowed("Johns-Mac.local:52525"))
        #expect(allowed("johns-mac.local.:52525"))
        #expect(allowed("[fe80::1c2b:3cff:fe4d:5e6f%en0]:52525"))
        #expect(allowed("localhost:52525"))
        #expect(allowed("127.0.0.1:52525"))
        #expect(allowed("[::1]:52525"))
        #expect(allowed("192.168.1.20", port: 80)) // Port 80 may be left out.
    }

    @Test func rejectsOtherHosts() {
        #expect(!allowed(nil))
        #expect(!allowed(""))
        #expect(!allowed("evil.example:52525"))        // DNS rebinding.
        #expect(!allowed("192.168.1.21:52525"))        // Another machine.
        #expect(!allowed("192.168.1.20:80"))           // Wrong port.
        #expect(!allowed("192.168.1.20"))              // Missing port.
        #expect(!allowed("192.168.1.20:52525:1"))
        #expect(!allowed("192.168.1.20:abc"))
        #expect(!allowed("192.168.1.20:"))
        #expect(!allowed("fe80::1c2b:3cff:fe4d:5e6f")) // Bare IPv6 isn't a valid Host.
        #expect(!allowed("[::1]x:52525"))
        #expect(!allowed("192.168.1.20.evil.example:52525"))
    }

    @Test func splitsHostAndPort() {
        #expect(RemoteHostPolicy.split("Mac.Local:8080")?.host == "mac.local")
        #expect(RemoteHostPolicy.split("Mac.Local:8080")?.port == 8080)
        #expect(RemoteHostPolicy.split("[::1]")?.host == "::1")
        #expect(RemoteHostPolicy.split("[::1]")?.port == nil)
        #expect(RemoteHostPolicy.split("mac:70000") == nil)
    }
}

struct PairingThrottleTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test func onlyRealCodesCount() {
        #expect(!PairingThrottle.countsAsGuess(nil))
        #expect(!PairingThrottle.countsAsGuess(""))
        #expect(!PairingThrottle.countsAsGuess("12345"))
        #expect(!PairingThrottle.countsAsGuess("abcdef"))
        #expect(PairingThrottle.countsAsGuess("123456"))
    }

    @Test func delaysGrowExponentially() {
        #expect(PairingThrottle.delay(afterFailures: 0) == 0)
        #expect(PairingThrottle.delay(afterFailures: 1) == 0)
        #expect(PairingThrottle.delay(afterFailures: 2) == 1)
        #expect(PairingThrottle.delay(afterFailures: 3) == 2)
        #expect(PairingThrottle.delay(afterFailures: 5) == 8)
        #expect(PairingThrottle.delay(afterFailures: 100) == PairingThrottle.maxDelay)
    }

    @Test func backsOffPerPeer() {
        var throttle = PairingThrottle()
        #expect(throttle.decision(for: "192.168.1.50", now: start) == .allowed)
        throttle.recordFailure(for: "192.168.1.50", now: start)
        #expect(throttle.decision(for: "192.168.1.50", now: start) == .allowed) // First miss: no delay.
        throttle.recordFailure(for: "192.168.1.50", now: start)
        #expect(throttle.decision(for: "192.168.1.50", now: start) == .wait(1))
        #expect(throttle.decision(for: "192.168.1.50", now: start.addingTimeInterval(1)) == .allowed)
        // Another device isn't slowed down.
        #expect(throttle.decision(for: "192.168.1.60", now: start) == .allowed)
    }

    @Test func onePeerCantRetireTheCode() {
        var throttle = PairingThrottle()
        var now = start
        var retired = false
        for _ in 0..<(PairingThrottle.perPeerLimit * 4) {
            guard throttle.decision(for: "192.168.1.50", now: now) == .allowed else {
                now = now.addingTimeInterval(PairingThrottle.maxDelay)
                continue
            }
            retired = retired || throttle.recordFailure(for: "192.168.1.50", now: now)
        }
        #expect(!retired)
        #expect(throttle.codeFailures == PairingThrottle.perPeerLimit)
        #expect(throttle.decision(for: "192.168.1.50", now: now.addingTimeInterval(PairingThrottle.maxDelay)) == .peerExhausted)
        // The real phone can still pair.
        #expect(throttle.decision(for: "192.168.1.60", now: now) == .allowed)
    }

    @Test func newCodeResetsGuessesButNotDelays() {
        var throttle = PairingThrottle()
        for _ in 0..<PairingThrottle.perPeerLimit { throttle.recordFailure(for: "10.0.0.9", now: start) }
        #expect(throttle.decision(for: "10.0.0.9", now: start) == .peerExhausted)
        throttle.newCode()
        #expect(throttle.codeFailures == 0)
        #expect(throttle.decision(for: "10.0.0.9", now: start) == .wait(PairingThrottle.delay(afterFailures: PairingThrottle.perPeerLimit)))
        #expect(throttle.decision(for: "10.0.0.9", now: start.addingTimeInterval(PairingThrottle.maxDelay)) == .allowed)
    }

    @Test func manyPeersRetireTheCode() {
        var throttle = PairingThrottle()
        var retired = false
        for index in 0..<PairingThrottle.globalLimit {
            retired = throttle.recordFailure(for: "192.168.1.\(100 + index / PairingThrottle.perPeerLimit)", now: start)
        }
        #expect(retired)
    }

    @Test func successAndQuietTimeForget() {
        var throttle = PairingThrottle()
        for _ in 0..<3 { throttle.recordFailure(for: "10.0.0.9", now: start) }
        throttle.recordSuccess(for: "10.0.0.9")
        #expect(throttle.decision(for: "10.0.0.9", now: start) == .allowed)
        for _ in 0..<PairingThrottle.perPeerLimit { throttle.recordFailure(for: "10.0.0.8", now: start) }
        #expect(throttle.decision(for: "10.0.0.8", now: start.addingTimeInterval(PairingThrottle.forgetAfter + 1)) == .allowed)
    }

    @Test func globalIPv6PeersGroupByPrefix() {
        #expect(PairingThrottle.peerKey("2001:db8:1:2::1") == PairingThrottle.peerKey("2001:db8:1:2:abcd::9"))
        #expect(PairingThrottle.peerKey("2001:db8:1:2::1") != PairingThrottle.peerKey("2001:db8:1:3::1"))
        #expect(PairingThrottle.peerKey("fd12:3456:789a:1::1") == PairingThrottle.peerKey("fd12:3456:789a:1::2")) // ULA
        #expect(PairingThrottle.peerKey("::ffff:192.168.1.5") == "192.168.1.5")
        #expect(PairingThrottle.peerKey("192.168.1.5") == "192.168.1.5")
        #expect(PairingThrottle.peerKey("192.168.1.5") != PairingThrottle.peerKey("192.168.1.6"))
        var throttle = PairingThrottle()
        for index in 0..<PairingThrottle.perPeerLimit { throttle.recordFailure(for: "2001:db8:1:2::\(index + 1)", now: start) }
        #expect(throttle.decision(for: "2001:db8:1:2::99", now: start) == .peerExhausted)
    }

    @Test func linkLocalPeersAreKeyedByFullAddress() {
        // Every device on the link shares fe80::/64, so the prefix can't tell them apart.
        #expect(PairingThrottle.peerKey("fe80::1%en0") == PairingThrottle.peerKey("fe80::1"))
        #expect(PairingThrottle.peerKey("fe80::1") != PairingThrottle.peerKey("fe80::2"))
        #expect(PairingThrottle.isLinkLocalKey(PairingThrottle.peerKey("fe80::1")))
        #expect(PairingThrottle.isLinkLocalKey(PairingThrottle.peerKey("febf::1"))) // Still fe80::/10.
        #expect(!PairingThrottle.isLinkLocalKey(PairingThrottle.peerKey("fec0::1")))
        var throttle = PairingThrottle()
        for _ in 0..<PairingThrottle.perPeerLimit { throttle.recordFailure(for: "fe80::bad", now: start) }
        #expect(throttle.decision(for: "fe80::bad", now: start) == .peerExhausted)
        // A noisy neighbour doesn't lock out the phone next to it.
        #expect(throttle.decision(for: "fe80::1234", now: start) == .allowed)
    }

    @Test func mintedLinkLocalAddressesShareOneRecordPastTheCap() {
        var throttle = PairingThrottle()
        for index in 0..<PairingThrottle.maxLinkLocalPeers { throttle.recordFailure(for: "fe80::\(index + 1)", now: start) }
        // New link-local addresses now all count against one shared record.
        for index in 0..<PairingThrottle.perPeerLimit { throttle.recordFailure(for: "fe80::a:\(index + 1)", now: start) }
        #expect(throttle.decision(for: "fe80::b:1", now: start) == .peerExhausted)
        // Peers already tracked, and IPv4 peers, keep their own.
        #expect(throttle.decision(for: "fe80::1", now: start) != .peerExhausted)
        #expect(throttle.decision(for: "192.168.1.40", now: start) == .allowed)
    }

    @Test func globalLimitIsGenerous() {
        // Enough that a few noisy devices can't retire the code before a real phone pairs.
        #expect(PairingThrottle.globalLimit >= 100)
        #expect(PairingThrottle.globalLimit > PairingThrottle.perPeerLimit * PairingThrottle.maxLinkLocalPeers)
    }
}

struct RemoteCookieTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test func cookieLastsThirtyDays() {
        let token = RemoteToken.generate()
        let header = RemoteCookie.header(token: token)
        #expect(header.hasPrefix("ut_remote=\(token);"))
        #expect(header.contains("Max-Age=2592000"))
        #expect(header.contains("HttpOnly"))
        #expect(header.contains("SameSite=Strict"))
        #expect(!header.contains("31536000"))
    }

    @Test func renewsWhileInUse() {
        #expect(RemoteCookie.shouldRenew(lastRenewed: nil, now: now))
        #expect(!RemoteCookie.shouldRenew(lastRenewed: now.addingTimeInterval(-60), now: now))
        #expect(RemoteCookie.shouldRenew(lastRenewed: now.addingTimeInterval(-RemoteCookie.renewInterval), now: now))
    }

    @Test func unusedPairingsLapse() {
        #expect(!RemoteCookie.isExpired(lastSeen: now.addingTimeInterval(-29 * 24 * 3600), now: now))
        #expect(RemoteCookie.isExpired(lastSeen: now.addingTimeInterval(-31 * 24 * 3600), now: now))
    }
}

struct RemoteConnectionLimitTests {
    @Test func capsConnectionsPerPeerAndOverall() {
        #expect(RemoteConnectionLimits.canAccept(total: 0, fromPeer: 0))
        #expect(RemoteConnectionLimits.canAccept(total: 10, fromPeer: RemoteConnectionLimits.maxConnectionsPerPeer - 1))
        #expect(!RemoteConnectionLimits.canAccept(total: 10, fromPeer: RemoteConnectionLimits.maxConnectionsPerPeer))
        #expect(!RemoteConnectionLimits.canAccept(total: RemoteConnectionLimits.maxConnections, fromPeer: 0))
        // The last few connections are held for phones that have shown a working cookie.
        let reservedStart = RemoteConnectionLimits.maxConnections - RemoteConnectionLimits.reservedForPaired
        #expect(!RemoteConnectionLimits.canAccept(total: reservedStart, fromPeer: 0))
        #expect(RemoteConnectionLimits.canAccept(total: reservedStart, fromPeer: 0, isKnownPaired: true))
        #expect(!RemoteConnectionLimits.canAccept(total: RemoteConnectionLimits.maxConnections, fromPeer: 0, isKnownPaired: true))
        #expect(RemoteConnectionLimits.headerTimeout <= 3)
    }

    @Test func capsStreamsPerPeerAndOverall() {
        #expect(RemoteConnectionLimits.canOpenStream(total: 0, fromPeer: 0))
        #expect(!RemoteConnectionLimits.canOpenStream(total: 1, fromPeer: RemoteConnectionLimits.maxStreamsPerPeer))
        #expect(!RemoteConnectionLimits.canOpenStream(total: RemoteConnectionLimits.maxStreams, fromPeer: 0))
    }

    @Test func dropsStalledStreams() {
        let limit = RemoteConnectionLimits.maxBytesInFlight
        #expect(limit == 256 * 1024)
        #expect(!RemoteConnectionLimits.shouldDrop(bytesInFlight: 0, adding: 1_000))
        #expect(!RemoteConnectionLimits.shouldDrop(bytesInFlight: limit - 1_000, adding: 1_000))
        #expect(RemoteConnectionLimits.shouldDrop(bytesInFlight: limit - 999, adding: 1_000))
    }
}

struct AirPlaySupportTests {
    @Test func fourCharacterCodes() {
        #expect(AirPlayHandoff.fourCC("avc1") == 0x6176_6331)
        #expect(AirPlayHandoff.fourCC("ac-3") == 0x6163_2D33)
    }

    @Test func otherContainersAreAudioOnly() async {
        let verdict = await AirPlayHandoff.support(for: URL(fileURLWithPath: "/tmp/movie.mkv"))
        guard case .audioOnly(let reason) = verdict else { Issue.record("Expected audio only"); return }
        #expect(reason.contains("MP4"))
    }
}

struct RemoteConnectionShareTests {
    @Test func linkLocalPeersPastTheCapShareOneSlot() {
        let inUse = Set((1...RemoteConnectionLimits.maxLinkLocalPeers).map { PairingThrottle.peerKey("fe80::\($0)") })
        let known = PairingThrottle.peerKey("fe80::1")
        #expect(RemoteConnectionLimits.shareKey(known, linkLocalKeysInUse: inUse) == known)
        let newcomer = PairingThrottle.peerKey("fe80::99")
        #expect(RemoteConnectionLimits.shareKey(newcomer, linkLocalKeysInUse: inUse) == RemoteConnectionLimits.linkLocalOverflowKey)
        // Below the cap, and for other addresses, peers keep their own share.
        #expect(RemoteConnectionLimits.shareKey(newcomer, linkLocalKeysInUse: []) == newcomer)
        #expect(RemoteConnectionLimits.shareKey("192.168.1.5", linkLocalKeysInUse: inUse) == "192.168.1.5")
    }

    @Test func headersCompleteBeforeTheBody() {
        #expect(!HTTPParser.hasCompleteHeaders(Data("GET / HTTP/1.1\r\nHost: a".utf8)))
        #expect(HTTPParser.hasCompleteHeaders(Data("POST /pair HTTP/1.1\r\nHost: a\r\nContent-Length: 10\r\n\r\n{".utf8)))
    }
}

struct RemoteHostGateTests {
    private func request(host: String) -> HTTPRequest? {
        guard case .complete(let request, _) = HTTPParser.parse(Data("GET / HTTP/1.1\r\nHost: \(host)\r\n\r\n".utf8)) else { return nil }
        return request
    }

    @Test func wrongHostIsRefusedWithoutTheMainActor() throws {
        let gate = RemoteHostGate()
        let now = Date()
        gate.update(hosts: ["192.168.1.20"], at: now)
        gate.update(port: 52_525)
        #expect(gate.mightAllow(try #require(request(host: "192.168.1.20:52525")), now: now))
        #expect(!gate.mightAllow(try #require(request(host: "evil.example:52525")), now: now))
        // Once the addresses are old enough to re-read, the main actor gets the final say.
        #expect(gate.mightAllow(try #require(request(host: "evil.example:52525")),
                                now: now.addingTimeInterval(RemoteHostGate.refreshInterval + 1)))
    }

    @Test func nothingIsAllowedWhileTheServerIsDown() throws {
        let gate = RemoteHostGate()
        gate.update(hosts: ["192.168.1.20"], at: .now)
        #expect(!gate.mightAllow(try #require(request(host: "192.168.1.20:52525"))))
    }
}
