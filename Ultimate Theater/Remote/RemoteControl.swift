//
//  RemoteControl.swift
//  Ultimate Theater
//
//  The iPhone remote's app side: pairing, paired devices, routing requests, and turning the
//  phone's commands into the same player actions as the on-screen controls. Everything here
//  runs on the main actor; the server only moves bytes.
//
//  Security model
//  • Off by default; only the administrator profile can turn it on (with the admin PIN, if set).
//  • Local network only: the listener accepts local peers, and each peer address is checked
//    against private IPv4 / link-local ranges.
//  • Every request's Host must be one of this Mac's own addresses or names with the server's
//    port (no DNS rebinding), checked before anything else.
//  • Pairing uses a random six-digit code that expires after ten minutes and works once.
//    Wrong guesses are limited per device with growing delays, and a code is retired after
//    too many wrong guesses overall (see PairingThrottle). A successful pairing gets a random
//    256-bit token in an HttpOnly, SameSite=Strict cookie that lasts 30 days and is renewed
//    while in use; only its SHA-256 is saved, and every request but the pairing page itself
//    must present it (compared in constant time).
//  • Commands need a JSON body and a custom header (so other web pages can't send them), and
//    any Origin header must match the Host. Responses never include file paths.
//  • The connection is plain HTTP: someone able to watch the Wi-Fi could read the cookie.
//    A self-signed TLS certificate wouldn't be trusted by the phone's browser, so it isn't
//    used; the limited lifetime and revocation in Settings bound the risk.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers
import SystemConfiguration
import os

/// The Host check's inputs, readable from the server's queue, so a request addressed to
/// another name (DNS rebinding, probes) is turned away without waiting on the main actor.
nonisolated final class RemoteHostGate: Sendable {
    private struct State: Sendable {
        var hosts: Set<String> = []
        var port: UInt16?
        var updated = Date.distantPast
    }

    /// The main actor re-reads the Mac's addresses after a miss at most this often.
    static let refreshInterval: TimeInterval = 3

    private let state = OSAllocatedUnfairLock(initialState: State())

    func update(hosts: Set<String>, at date: Date) {
        state.withLock { $0.hosts = hosts; $0.updated = date }
    }

    func update(port: UInt16?) {
        state.withLock { $0.port = port }
    }

    /// `false` when the request is certainly for another host: it doesn't match, and the
    /// addresses are too fresh for the main actor to re-read them. Otherwise the main
    /// actor makes the final check.
    func mightAllow(_ request: HTTPRequest, now: Date = .now) -> Bool {
        let current = state.withLock { $0 }
        guard let port = current.port else { return false }
        if RemoteHostPolicy.isAllowed(hostHeader: request.header("host"), allowedHosts: current.hosts, port: port) { return true }
        return now.timeIntervalSince(current.updated) > Self.refreshInterval
    }
}

struct PairedRemote: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    let tokenHash: String
    let pairedAt: Date
    var lastSeen: Date
}

@Observable
final class RemoteControl {
    static let shared = RemoteControl()

    enum Status: Equatable {
        case off
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    static let cookieName = RemoteCookie.name
    static let codeLifetime: TimeInterval = 10 * 60
    private static let enabledKey = "remote.enabled"
    private static let devicesKey = "remote.devices"
    private static let maxDevices = 10

    private(set) var isEnabled = UserDefaults.standard.bool(forKey: RemoteControl.enabledKey)
    private(set) var status: Status = .off
    private(set) var pairingCode: String?
    private(set) var pairingExpiry: Date?
    /// Pairing stopped after too many wrong codes; a new code must be made on the Mac.
    private(set) var isPairingLocked = false
    private(set) var devices: [PairedRemote] = []
    /// The Mac's address on the local network, for the pairing link.
    private(set) var address: String?

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var server: RemoteServer?
    @ObservationIgnored private var throttle = PairingThrottle()
    /// This Mac's addresses and `.local` name, for the Host check.
    @ObservationIgnored private var allowedHosts: Set<String> = []
    @ObservationIgnored private var allowedHostsUpdated = Date.distantPast
    /// A copy of `allowedHosts` and the port for the server's queue.
    @ObservationIgnored private let hostGate = RemoteHostGate()
    /// When each device's cookie was last re-sent.
    @ObservationIgnored private var cookieRenewed: [UUID: Date] = [:]
    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private var lastBroadcast: Data?
    @ObservationIgnored private var posterCache: [String: Data] = [:]
    @ObservationIgnored private var lastSeenSaved = Date.distantPast
    @ObservationIgnored private var serverGeneration = 0
    @ObservationIgnored let nowPlaying = NowPlayingBridge()

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.devicesKey),
           let saved = try? JSONDecoder().decode([PairedRemote].self, from: data) {
            devices = saved.filter { !RemoteCookie.isExpired(lastSeen: $0.lastSeen, now: .now) }
        }
    }

    /// Called once at launch.
    func attach(_ model: AppModel) {
        self.model = model
        nowPlaying.start(model: model)
        if isEnabled { startServer() }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled { startServer() } else { stopServer() }
    }

    // MARK: Pairing

    var port: UInt16? {
        if case .running(let port) = status { return port }
        return nil
    }

    /// "http://192.168.1.20:52525"
    var baseURL: String? {
        guard let address, let port else { return nil }
        return "http://\(address):\(port)"
    }

    /// The link in the QR code: opening it pairs the phone.
    var pairingURL: String? {
        guard let baseURL, let pairingCode, let pairingExpiry, pairingExpiry > .now else { return nil }
        return "\(baseURL)/pair?code=\(pairingCode)"
    }

    /// Makes sure a pairing code is available (a fresh one if the last expired).
    func ensurePairingCode() {
        guard isEnabled, !isPairingLocked else { return }
        if pairingCode == nil || (pairingExpiry ?? .distantPast) <= .now { newPairingCode() }
    }

    /// While Settings › Remote is open the code stays usable: one close to expiring gets a
    /// fresh lifetime (the same code, so the QR code on screen keeps working), and an
    /// expired one is replaced. A code retired after too many wrong guesses stays retired.
    func keepPairingCodeAlive() {
        guard isEnabled, !isPairingLocked else { return }
        guard let expiry = pairingExpiry, pairingCode != nil, expiry > .now else { return newPairingCode() }
        if expiry.timeIntervalSinceNow < 60 { pairingExpiry = .now.addingTimeInterval(Self.codeLifetime) }
    }

    func newPairingCode() {
        pairingCode = RemoteToken.pairingCode()
        pairingExpiry = .now.addingTimeInterval(Self.codeLifetime)
        throttle.newCode()
        isPairingLocked = false
    }

    func revoke(_ device: PairedRemote) {
        devices.removeAll { $0.id == device.id }
        saveDevices()
        server?.closeStreams()
    }

    func revokeAll() {
        devices = []
        saveDevices()
        server?.closeStreams()
    }

    private func saveDevices() {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: Self.devicesKey)
        }
    }

    // MARK: Server

    private func startServer() {
        guard server == nil else { return }
        serverGeneration += 1
        let generation = serverGeneration
        address = NetworkInfo.lanIPv4()
        refreshAllowedHosts()
        let gate = hostGate
        let server = RemoteServer(handler: { [weak self] request, peer in
            // Checked here, on the server's queue, before anything waits on the main actor.
            guard gate.mightAllow(request) else { return .error(421, "Unknown host.") }
            guard let self else { return .error(503, "Unavailable") }
            return await self.handle(request, peer: peer)
        }, onStateChange: { [generation] state in
            Task { @MainActor in RemoteControl.shared.serverChanged(state, generation: generation) }
        })
        self.server = server
        server.start(serviceName: NetworkInfo.serviceName)
        newPairingCode()
        updates = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, let server = self.server else { return }
                ticks += 1
                if ticks.isMultiple(of: 20) { // Wi-Fi changes.
                    self.address = NetworkInfo.lanIPv4()
                    self.refreshAllowedHosts()
                }
                guard server.hasStreams else {
                    self.lastBroadcast = nil
                    continue
                }
                let state = self.stateJSON()
                if state != self.lastBroadcast {
                    self.lastBroadcast = state
                    server.broadcast(state)
                }
            }
        }
    }

    private func stopServer() {
        updates?.cancel()
        updates = nil
        server?.stop()
        server = nil
        status = .off
        hostGate.update(port: nil)
        pairingCode = nil
        pairingExpiry = nil
        posterCache = [:]
        cookieRenewed = [:]
    }

    private func refreshAllowedHosts() {
        allowedHosts = NetworkInfo.hostNames()
        allowedHostsUpdated = .now
        hostGate.update(hosts: allowedHosts, at: allowedHostsUpdated)
    }

    /// The DNS-rebinding check. A miss re-reads the Mac's addresses once (at most every few
    /// seconds) in case the network just changed.
    private func isAllowedHost(_ request: HTTPRequest) -> Bool {
        guard let port else { return false }
        let header = request.header("host")
        if RemoteHostPolicy.isAllowed(hostHeader: header, allowedHosts: allowedHosts, port: port) { return true }
        guard Date.now.timeIntervalSince(allowedHostsUpdated) > RemoteHostGate.refreshInterval else { return false }
        refreshAllowedHosts()
        return RemoteHostPolicy.isAllowed(hostHeader: header, allowedHosts: allowedHosts, port: port)
    }

    private func serverChanged(_ state: RemoteServer.State, generation: Int) {
        guard server != nil, generation == serverGeneration else { return } // Ignore a stopped server's last words.
        switch state {
        case .stopped: status = .off
        case .starting: status = .starting
        case .ready(let port):
            status = .running(port: port)
            hostGate.update(port: port)
        case .failed(let message): status = .failed(message)
        }
    }

    // MARK: Requests

    func handle(_ request: HTTPRequest, peer: RemotePeer) async -> HTTPResponse {
        // Before anything else (pairing included): the request must be addressed to this Mac.
        guard isAllowedHost(request) else { return .error(421, "Unknown host.") }
        guard isEnabled else { return .error(503, "The remote is turned off on the Mac.") }
        // Browsers send Origin on cross-site requests; ours must come from this server's own page.
        if let origin = request.header("origin"), origin != "http://\(request.header("host") ?? "")" {
            return .error(403, "Requests from other sites aren't allowed.")
        }
        let authenticated = authenticatedDevice(for: request)

        switch (request.method, request.path) {
        case ("GET", "/"):
            guard let authenticated else { return .html(RemotePage.pairing) }
            markSeen(authenticated.device)
            return renewingCookie(.html(RemotePage.remote), for: authenticated)
        case ("GET", "/pair"):
            return pair(code: request.query["code"], request: request, peer: peer, viaLink: true)
        case ("POST", "/pair"):
            guard isScripted(request) else { return .error(403, "Not allowed.") }
            let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]
            return pair(code: object?["code"] as? String, request: request, peer: peer, viaLink: false)
        case ("GET", "/favicon.ico"):
            return HTTPResponse(status: 204)
        default:
            break
        }

        guard let authenticated else {
            return .error(401, "This device isn't paired. Enter the code from Ultimate Theater's Settings on the Mac.")
        }
        markSeen(authenticated.device)
        return renewingCookie(await route(request), for: authenticated)
    }

    /// Sliding expiry: an active phone's cookie is re-sent with a fresh 30 days now and then.
    private func renewingCookie(_ response: HTTPResponse, for authenticated: (device: PairedRemote, token: String)) -> HTTPResponse {
        let id = authenticated.device.id
        var response = response
        response.isFromPairedDevice = true
        guard RemoteCookie.shouldRenew(lastRenewed: cookieRenewed[id], now: .now) else { return response }
        cookieRenewed[id] = .now
        response.headers.append(("Set-Cookie", RemoteCookie.header(token: authenticated.token)))
        return response
    }

    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/api/state"):
            return .json(stateJSON())
        case ("GET", "/api/events"):
            return .eventStream(initial: stateJSON())
        case ("GET", "/api/browse"):
            return .json(browseJSON(query: request.query["q"]))
        case ("POST", "/api/command"):
            guard isScripted(request) else { return .error(403, "Not allowed.") }
            guard let command = RemoteCommand.decode(request.body) else { return .error(400, "Unknown command.") }
            if let problem = execute(command) { return .error(409, problem) }
            return .json(stateJSON())
        case ("GET", let path) where path.hasPrefix("/api/poster/"):
            return await poster(for: String(path.dropFirst("/api/poster/".count)))
        default:
            return .error(404, "Not found.")
        }
    }

    /// Our page's fetches carry a JSON body type and a custom header, which a plain form or
    /// image on another site can't add.
    private func isScripted(_ request: HTTPRequest) -> Bool {
        request.header("x-remote") == "1" && (request.header("content-type") ?? "").lowercased().hasPrefix("application/json")
    }

    /// The paired device presenting this request's cookie, and its (well-formed) token.
    private func authenticatedDevice(for request: HTTPRequest) -> (device: PairedRemote, token: String)? {
        guard let token = request.cookies[Self.cookieName], RemoteToken.isWellFormed(token) else { return nil }
        let hash = RemoteToken.hash(token)
        var match: PairedRemote?
        for device in devices where RemoteToken.constantTimeEquals(device.tokenHash, hash) {
            match = device // No early exit.
        }
        guard let match else { return nil }
        // Unused for longer than the cookie lasts: the pairing has lapsed, whatever the browser kept.
        if RemoteCookie.isExpired(lastSeen: match.lastSeen, now: .now) {
            devices.removeAll { $0.id == match.id }
            saveDevices()
            return nil
        }
        return (match, token)
    }

    private func markSeen(_ device: PairedRemote) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        // Keep Settings and the saved list from churning on every request.
        guard Date.now.timeIntervalSince(devices[index].lastSeen) > 30 else { return }
        devices[index].lastSeen = .now
        if Date.now.timeIntervalSince(lastSeenSaved) > 60 {
            lastSeenSaved = .now
            saveDevices()
        }
    }

    private func pair(code: String?, request: HTTPRequest, peer: RemotePeer, viaLink: Bool) -> HTTPResponse {
        let failure: (Int, String) -> HTTPResponse = { status, message in
            viaLink ? .redirect(to: "/?pair=failed") : .error(status, message)
        }
        guard let expected = pairingCode, let expiry = pairingExpiry, expiry > .now else {
            return failure(403, "There's no current pairing code. Open Settings › Remote on the Mac for a new one.")
        }
        // Visits without a (well-formed) code aren't guesses, so they don't count.
        guard PairingThrottle.countsAsGuess(code), let code else { return failure(400, "Enter the six-digit code.") }
        let now = Date.now
        switch throttle.decision(for: peer.address, now: now) {
        case .allowed:
            break
        case .wait(let seconds):
            return failure(429, "Too many tries. Wait \(Int(seconds.rounded(.up))) seconds and try again.")
        case .peerExhausted:
            return failure(429, "Too many wrong codes from this device. Make a new code in Settings › Remote on the Mac.")
        }
        guard RemoteToken.constantTimeEquals(code, expected) else {
            if throttle.recordFailure(for: peer.address, now: now) {
                // Too many guesses in all: this code is retired, so codes can't be found by
                // brute force. Someone at the Mac makes a new one.
                pairingCode = nil
                pairingExpiry = nil
                isPairingLocked = true
                return failure(403, "Too many wrong codes. Make a new code in Settings › Remote on the Mac.")
            }
            return failure(403, "That code isn't right.")
        }
        throttle.recordSuccess(for: peer.address)

        let token = RemoteToken.generate()
        let device = PairedRemote(id: UUID(), name: RemoteDeviceName.from(userAgent: request.header("user-agent")),
                                  tokenHash: RemoteToken.hash(token), pairedAt: .now, lastSeen: .now)
        devices.append(device)
        if devices.count > Self.maxDevices {
            devices = Array(devices.sorted { $0.lastSeen > $1.lastSeen }.prefix(Self.maxDevices))
        }
        saveDevices()
        newPairingCode() // Each code pairs one device.

        cookieRenewed[device.id] = .now
        let cookie = RemoteCookie.header(token: token)
        if viaLink { return .redirect(to: "/", setCookie: cookie) }
        var response = HTTPResponse.json(Data(#"{"ok":true}"#.utf8))
        response.headers.append(("Set-Cookie", cookie))
        return response
    }

    // MARK: Commands

    /// Runs a command; returns a message when it can't.
    private func execute(_ command: RemoteCommand) -> String? {
        guard let model else { return "Ultimate Theater isn't ready." }
        switch command {
        case .playTitle(let id):
            guard model.profile != nil else { return "Choose a profile on the Mac first." }
            guard let title = model.titles.first(where: { $0.id == id }), title.isPlayable else { return "That title can't be played." }
            model.playResuming(title)
            return nil
        case .stop:
            guard model.nowPlaying != nil else { return nil }
            model.closePlayerSavingProgress()
            return nil
        default:
            break
        }

        guard let transport = model.activeTransport else { return "Nothing is playing." }
        let hooks = model.activePlayerHooks
        let engine = model.playerEngine
        switch command {
        case .togglePlayback: transport.togglePlayback()
        case .play: transport.play()
        case .pause: transport.pause()
        case .skip(let seconds): transport.skip(by: seconds)
        case .seek(let seconds): transport.seek(to: seconds)
        case .volume(let level):
            engine?.volume = Float(level)
            if level > 0 { engine?.isMuted = false }
            hooks?.airPlay?.volume = Float(level)
        case .toggleMute:
            engine?.isMuted.toggle()
        case .audio(let id):
            guard let engine, engine.trackList.audio.contains(where: { $0.id == id && $0.isSupported }) else { return "That audio track isn't available." }
            engine.selectAudio(id)
        case .subtitle(let id):
            guard let engine else { return "Nothing is playing." }
            if let id, !engine.trackList.subtitles.contains(where: { $0.id == id && $0.isSupported }) { return "Those subtitles aren't available." }
            engine.selectSubtitle(id)
        case .previousEpisode, .nextEpisode, .skipIntro, .skipCredits:
            guard let hooks else { return "Not available right now." }
            let state = hooks.state()
            switch command {
            case .previousEpisode where state.hasPreviousEpisode: hooks.perform(.previousEpisode)
            case .nextEpisode where state.hasNextEpisode: hooks.perform(.nextEpisode)
            case .skipIntro where state.canSkipIntro: hooks.perform(.skipIntro)
            case .skipCredits where state.canSkipCredits: hooks.perform(.skipCredits)
            default: return "Not available right now."
            }
        case .playTitle, .stop:
            break
        }
        return nil
    }

    // MARK: JSON

    private static func finite(_ value: Double) -> Double { value.isFinite ? value : 0 }

    func stateJSON() -> Data {
        var state: [String: Any] = ["playing": false, "profile": model?.profile?.name ?? NSNull()]
        if let model, let item = model.nowPlaying {
            let transport = model.activeTransport
            let engine = model.playerEngine
            let hooks = model.activePlayerHooks?.state()
            state["playing"] = true
            state["item"] = [
                "title": item.headline,
                "subtitle": item.subheadline ?? NSNull(),
                "poster": item.title.posterURL == nil ? NSNull() : "/api/poster/\(item.title.id)",
            ] as [String: Any]
            state["isEpisode"] = item.episode != nil
            state["isPlaying"] = transport?.isPlaying ?? false
            state["buffering"] = engine.map { !$0.hasStarted || $0.isBuffering } ?? true
            state["position"] = (Self.finite(transport?.currentTime ?? 0) * 2).rounded() / 2
            state["duration"] = Self.finite(transport?.duration ?? 0).rounded()
            state["volume"] = Double(engine?.volume ?? 1)
            state["muted"] = engine?.isMuted ?? false
            state["external"] = transport is AirPlayHandoff
            state["canPrevious"] = hooks?.hasPreviousEpisode ?? false
            state["canNext"] = hooks?.hasNextEpisode ?? false
            state["canSkipIntro"] = hooks?.canSkipIntro ?? false
            state["canSkipCredits"] = hooks?.canSkipCredits ?? false
            if let engine {
                state["audio"] = engine.trackList.audio.map { Self.trackJSON($0) }
                state["audioID"] = engine.selectedAudioID ?? NSNull()
                state["subtitles"] = engine.trackList.subtitles.map { Self.trackJSON($0) }
                state["subtitleID"] = engine.selectedSubtitleID ?? NSNull()
            }
        }
        return (try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    private static func trackJSON(_ option: TrackOption) -> [String: Any] {
        ["id": option.id, "label": [option.title, option.detail].compactMap { $0 }.joined(separator: " · "), "supported": option.isSupported]
    }

    private func browseJSON(query: String?) -> Data {
        var result: [String: Any] = ["profile": NSNull(), "continue": [Any](), "results": [Any]()]
        if let model, let profile = model.profile {
            result["profile"] = profile.name
            let titles = model.titles
            let progress = model.watchProgressByTitle.values.flatMap { $0 }
            result["continue"] = WatchHistory.continueWatching(progress, titles: titles).prefix(20).map { title, entry in
                let episode = title.allEpisodes.first { $0.id == entry.playbackID }
                return Self.titleJSON(title, detail: episode.map { "\($0.code) · \($0.name)" } ?? entry.remainingDescription,
                                      progress: entry.fraction)
            }
            let trimmed = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed.count <= 100 {
                result["results"] = model.search(titles, for: trimmed).prefix(40).map {
                    Self.titleJSON($0, detail: [$0.yearText, $0.kind.displayName].compactMap { $0 }.joined(separator: " · "), progress: nil)
                }
            }
        }
        return (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    private static func titleJSON(_ title: Title, detail: String, progress: Double?) -> [String: Any] {
        [
            "id": title.id,
            "title": title.name,
            "detail": detail,
            "playable": title.isPlayable,
            "poster": title.posterURL == nil ? NSNull() : "/api/poster/\(title.id)",
            "progress": progress.map { finite($0) } ?? NSNull(),
        ]
    }

    // MARK: Posters

    /// The title's poster, re-encoded small. Only titles the current profile may see: with no
    /// profile chosen, nothing (`model.titles` would be the whole library).
    private func poster(for id: String) async -> HTTPResponse {
        guard RemoteCommand.identifier(id) != nil, let model, model.profile != nil,
              let url = model.titles.first(where: { $0.id == id })?.posterURL else { return .error(404, "Not found.") }
        if let cached = posterCache[id] { return .image(cached) }
        guard let image = await ArtworkCache.shared.image(for: url, size: .poster) else { return .error(404, "Not found.") }
        let data = await Task.detached(priority: .utility) { Self.jpeg(image) }.value
        guard let data else { return .error(404, "Not found.") }
        if posterCache.count > 150 { posterCache = [:] }
        posterCache[id] = data
        return .image(data)
    }

    nonisolated private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

// MARK: - Network details

nonisolated enum NetworkInfo {
    /// The Bonjour name. Deliberately generic, so the network isn't told whose Mac this is;
    /// Bonjour adds a number if another Mac already uses it.
    static let serviceName = "Ultimate Theater"

    /// The Mac's Bonjour host name ("johns-macbook-pro.local"), lowercased.
    static var localHostName: String? {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty else { return nil }
        return name.lowercased() + ".local"
    }

    /// Every name a phone may use for this Mac in `Host`: its local-network addresses (IPv4,
    /// and IPv6 without the zone) and its `.local` name. Loopback is added by the policy.
    static func hostNames() -> Set<String> {
        var names = Set<String>()
        if let localHostName { names.insert(localHostName) }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return names }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let socket = entry.ifa_addr,
                  socket.pointee.sa_family == UInt8(AF_INET) || socket.pointee.sa_family == UInt8(AF_INET6),
                  Int32(entry.ifa_flags) & IFF_UP != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(socket, socklen_t(socket.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            var address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).lowercased()
            if let percent = address.firstIndex(of: "%") { address = String(address[..<percent]) }
            if LANAddressFilter.isAllowed(address: address) { names.insert(address) }
        }
        return names
    }

    /// The first private IPv4 address on an active Ethernet/Wi-Fi interface.
    static func lanIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var candidates: [(interface: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let socket = entry.ifa_addr, socket.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(socket, socklen_t(socket.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard LANAddressFilter.isAllowed(address: address), !address.hasPrefix("127."), !address.hasPrefix("169.254.") else { continue }
            candidates.append((String(cString: entry.ifa_name), address))
        }
        return (candidates.first { $0.interface.hasPrefix("en") } ?? candidates.first)?.address
    }
}
