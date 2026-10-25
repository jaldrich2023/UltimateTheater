//
//  GoogleCast.swift
//  Ultimate Theater
//
//  Google Cast (CASTV2) sender, written from the protocol's public description:
//  • TLS to the device on port 8009. Cast devices present self-signed certificates, so this
//    one connection accepts the device's certificate (nothing else's trust changes); the
//    device was found on the local network by Bonjour and is spoken to only about playback.
//  • Each message is a length-prefixed protobuf `CastMessage` (CastProtobuf.swift) whose
//    payload is JSON, addressed from "sender-0" to "receiver-0" (the device) or to the
//    transport ID of a running app.
//  • Namespaces: tp.connection (CONNECT/CLOSE), tp.heartbeat (PING/PONG every 5 s),
//    receiver (LAUNCH, GET_STATUS, STOP, SET_VOLUME), and media (LOAD, PLAY, PAUSE, SEEK,
//    STOP, GET_STATUS; MEDIA_STATUS replies and broadcasts).
//  • Playback uses the Default Media Receiver (app ID CC1AD845), which plays a URL directly.
//

import Foundation
import os
import Network
import Security

nonisolated enum GoogleCastNamespace {
    static let connection = "urn:x-cast:com.google.cast.tp.connection"
    static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
    static let receiver = "urn:x-cast:com.google.cast.receiver"
    static let media = "urn:x-cast:com.google.cast.media"
}

enum GoogleCastError: Error, LocalizedError {
    case connectionFailed(String)
    case timedOut
    case closed
    case launchFailed
    case refused(String)
    case loadFailed(String?)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let reason): "Couldn't connect to the Cast device (\(reason))."
        case .timedOut: "The Cast device didn't respond in time."
        case .closed: "The connection to the Cast device was lost."
        case .launchFailed: "The Cast device couldn't start its media player."
        case .refused(let reason): "The Cast device refused the request (\(reason))."
        case .loadFailed(let reason): "The Cast device couldn't load the video\(reason.map { " (\($0))" } ?? "")."
        }
    }
}

/// The TLS connection and framing. Messages arrive in order on `messages`.
nonisolated final class GoogleCastChannel: @unchecked Sendable {
    let messages: AsyncStream<CastMessage>
    private let continuation: AsyncStream<CastMessage>.Continuation
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "cast.google-cast")
    private var reader = CastFrameReader()

    init(endpoint: NWEndpoint) {
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        // Cast devices use self-signed certificates: accept the device's for this connection.
        sec_protocol_options_set_verify_block(security, { _, _, complete in complete(true) }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 10
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
        // The media URL is advertised on IPv4, so reach the device over IPv4 too.
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        connection = NWConnection(to: endpoint, using: parameters)
        (messages, continuation) = AsyncStream.makeStream(of: CastMessage.self, bufferingPolicy: .bufferingNewest(256))
    }

    /// Opens the connection; throws if it isn't ready within `timeout`.
    func open(timeout: Double = 12) async throws {
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                // Callbacks and the timeout race to finish the wait; only the first one counts.
                let once = OSAllocatedUnfairLock(initialState: false)
                let resume: @Sendable (Result<Void, Error>) -> Bool = { result in
                    let first = once.withLock { done in
                        defer { done = true }
                        return !done
                    }
                    if first { waiter.resume(with: result) }
                    return first
                }
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        _ = resume(.success(()))
                        self?.receive()
                    case .failed(let error):
                        _ = resume(.failure(GoogleCastError.connectionFailed(error.localizedDescription)))
                        self?.close()
                    case .waiting:
                        // Waiting on a route or on the Local Network permission prompt; the
                        // timeout decides.
                        break
                    case .cancelled:
                        _ = resume(.failure(GoogleCastError.closed))
                        self?.continuation.finish()
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    if resume(.failure(GoogleCastError.timedOut)) { self?.close() }
                }
            }
        }
    }

    /// The device's IPv4 address, once connected.
    var remoteIPv4: String? {
        guard case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint, case .ipv4(let address) = host else { return nil }
        return [UInt8](address.rawValue).map(String.init).joined(separator: ".")
    }

    func send(_ message: CastMessage) {
        connection.send(content: message.framed(), completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })
    }

    func close() {
        connection.cancel()
        continuation.finish()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    for message in try reader.append(data) { continuation.yield(message) }
                } catch {
                    close()
                    return
                }
            }
            if isComplete || error != nil { close() } else { receive() }
        }
    }
}

/// Drives one Google Cast device through the Default Media Receiver.
final class GoogleCastClient: CastRendererClient {
    static let defaultMediaReceiver = "CC1AD845"
    private static let senderID = "sender-0"
    private static let receiverID = "receiver-0"

    let device: CastDevice
    private var channel: GoogleCastChannel?
    private var listener: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var transportID: String?
    private var sessionID: String?
    private var mediaSessionID: Int?
    private var lastHeard = Date.now
    private var latest = CastPlaybackStatus(state: .idle)
    private var volume: Float?
    private var runningApps: [(appID: String, sessionID: String, transportID: String)] = []

    init(device: CastDevice) throws {
        guard device.serviceName != nil else { throw GoogleCastError.connectionFailed("no address") }
        self.device = device
    }

    var capabilities: CastCapabilities { CastCapabilities(canSeek: true, volume: .absolute) }

    var mediaHost: String? { channel?.remoteIPv4.flatMap { LANAddress.localIPv4(toward: $0) } ?? LANAddress.primaryIPv4() }

    func connect() async throws {
        guard let name = device.serviceName else { throw GoogleCastError.connectionFailed("no address") }
        let channel = GoogleCastChannel(endpoint: .service(name: name, type: "_googlecast._tcp", domain: device.serviceDomain ?? "local.", interface: nil))
        self.channel = channel
        try await channel.open()
        lastHeard = .now
        listener = Task { [weak self] in
            for await message in channel.messages {
                self?.handle(message)
            }
            self?.channelClosed()
        }
        sendJSON(GoogleCastNamespace.connection, to: Self.receiverID, ["type": "CONNECT", "origin": [String: Any](), "userAgent": "Ultimate Theater"])
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                if Date.now.timeIntervalSince(lastHeard) > 20 {
                    channel.close()
                    return
                }
                sendJSON(GoogleCastNamespace.heartbeat, to: Self.receiverID, ["type": "PING"])
            }
        }
        _ = try await request(GoogleCastNamespace.receiver, to: Self.receiverID, ["type": "GET_STATUS"], timeout: 8)
    }

    /// Starts the Default Media Receiver (or joins it when it's already running).
    private func launchReceiver() async throws {
        if let app = runningApps.first(where: { $0.appID == Self.defaultMediaReceiver }) {
            join(app.sessionID, app.transportID)
            return
        }
        _ = try? await request(GoogleCastNamespace.receiver, to: Self.receiverID,
                               ["type": "LAUNCH", "appId": Self.defaultMediaReceiver], timeout: 20)
        for _ in 0..<20 {
            if let app = runningApps.first(where: { $0.appID == Self.defaultMediaReceiver }) {
                join(app.sessionID, app.transportID)
                return
            }
            try await Task.sleep(for: .seconds(1))
            _ = try? await request(GoogleCastNamespace.receiver, to: Self.receiverID, ["type": "GET_STATUS"], timeout: 4)
        }
        throw GoogleCastError.launchFailed
    }

    private func join(_ session: String, _ transport: String) {
        if transportID != transport {
            sessionID = session
            transportID = transport
            mediaSessionID = nil
            sendJSON(GoogleCastNamespace.connection, to: transport, ["type": "CONNECT", "origin": [String: Any](), "userAgent": "Ultimate Theater"])
        }
    }

    func load(_ request: CastLoadRequest) async throws {
        try await launchReceiver()
        guard let transportID else { throw GoogleCastError.launchFailed }
        latest = CastPlaybackStatus(state: .buffering) // Not the previous item's end.
        let reply = try await self.request(GoogleCastNamespace.media, to: transportID,
                                           Self.loadPayload(request, sessionID: sessionID), timeout: 45)
        if let type = reply["type"] as? String, type != "MEDIA_STATUS" {
            throw GoogleCastError.loadFailed(reply["reason"] as? String ?? reply["detailedErrorCode"].map { "\($0)" } ?? type)
        }
    }

    /// The LOAD request: a buffered stream of the published file, starting at `startTime`.
    nonisolated static func loadPayload(_ request: CastLoadRequest, sessionID: String?) -> [String: Any] {
        var metadata: [String: Any] = ["metadataType": request.isEpisode ? 2 : 1]
        if request.isEpisode {
            metadata["seriesTitle"] = request.title
            metadata["title"] = request.subtitle ?? request.title
        } else {
            metadata["title"] = request.title
            if let subtitle = request.subtitle { metadata["subtitle"] = subtitle }
        }
        if let artwork = request.artworkURL { metadata["images"] = [["url": artwork.absoluteString]] }
        var media: [String: Any] = [
            "contentId": request.mediaURL.absoluteString,
            "contentUrl": request.mediaURL.absoluteString,
            "contentType": request.contentType,
            "streamType": "BUFFERED",
            "metadata": metadata,
        ]
        if request.duration > 0 { media["duration"] = request.duration }
        var payload: [String: Any] = ["type": "LOAD", "media": media, "autoplay": true, "currentTime": max(request.startTime, 0)]
        if let sessionID { payload["sessionId"] = sessionID }
        return payload
    }

    private func mediaCommand(_ type: String, _ extra: [String: Any] = [:]) async throws {
        guard let transportID, let mediaSessionID else { throw GoogleCastError.closed }
        var payload = extra
        payload["type"] = type
        payload["mediaSessionId"] = mediaSessionID
        let reply = try await request(GoogleCastNamespace.media, to: transportID, payload, timeout: 10)
        if let replyType = reply["type"] as? String, replyType.hasPrefix("INVALID") {
            throw GoogleCastError.refused(reply["reason"] as? String ?? replyType)
        }
    }

    func play() async throws { try await mediaCommand("PLAY") }

    func pause() async throws { try await mediaCommand("PAUSE") }

    func seek(to seconds: Double) async throws {
        try await mediaCommand("SEEK", ["currentTime": max(seconds, 0), "resumeState": "PLAYBACK_START"])
    }

    func setVolume(_ level: Float) async throws {
        let level = Double(min(max(level, 0), 1))
        _ = try await request(GoogleCastNamespace.receiver, to: Self.receiverID,
                              ["type": "SET_VOLUME", "volume": ["level": level]], timeout: 6)
        volume = Float(level)
    }

    func stop() async {
        if let sessionID {
            _ = try? await request(GoogleCastNamespace.receiver, to: Self.receiverID, ["type": "STOP", "sessionId": sessionID], timeout: 5)
        }
    }

    func status() async throws -> CastPlaybackStatus {
        // Once the channel is gone the last status (a failure or a stop) is the answer.
        guard channel != nil else { return latest }
        if let transportID {
            var payload: [String: Any] = ["type": "GET_STATUS"]
            if let mediaSessionID { payload["mediaSessionId"] = mediaSessionID }
            _ = try? await request(GoogleCastNamespace.media, to: transportID, payload, timeout: 5)
        }
        var status = latest
        status.volume = volume
        return status
    }

    func disconnect() {
        if let transportID { sendJSON(GoogleCastNamespace.connection, to: transportID, ["type": "CLOSE"]) }
        sendJSON(GoogleCastNamespace.connection, to: Self.receiverID, ["type": "CLOSE"])
        heartbeat?.cancel()
        listener?.cancel()
        channel?.close()
        channel = nil
        failPending(GoogleCastError.closed)
    }

    // MARK: Messages

    private func sendJSON(_ namespace: String, to destination: String, _ payload: [String: Any]) {
        guard let channel, let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        channel.send(CastMessage(sourceID: Self.senderID, destinationID: destination, namespace: namespace, payloadUTF8: text))
    }

    /// Sends a request and waits for the reply carrying its requestId.
    private func request(_ namespace: String, to destination: String, _ payload: [String: Any], timeout: Double) async throws -> [String: Any] {
        guard channel != nil else { throw GoogleCastError.closed }
        let id = nextRequestID
        nextRequestID += 1
        var payload = payload
        payload["requestId"] = id
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            sendJSON(namespace, to: destination, payload)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.pending.removeValue(forKey: id)?.resume(throwing: GoogleCastError.timedOut)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func handle(_ message: CastMessage) {
        lastHeard = .now
        guard let text = message.payloadUTF8, text.utf8.count <= CastFrameReader.maximumFrameSize else { return }
        let data = Data(text.utf8)
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let type = json["type"] as? String else { return }

        switch (message.namespace, type) {
        case (GoogleCastNamespace.heartbeat, "PING"):
            sendJSON(GoogleCastNamespace.heartbeat, to: message.sourceID, ["type": "PONG"])
        case (GoogleCastNamespace.receiver, "RECEIVER_STATUS"):
            updateReceiver(json["status"] as? [String: Any])
        case (GoogleCastNamespace.media, "MEDIA_STATUS"):
            updateMedia(json["status"] as? [[String: Any]] ?? [])
        case (GoogleCastNamespace.media, "LOAD_FAILED"), (GoogleCastNamespace.media, "LOAD_CANCELLED"):
            latest.state = .failed("The Cast device couldn't play the video.")
        case (GoogleCastNamespace.connection, "CLOSE"):
            if message.sourceID == transportID {
                transportID = nil
                mediaSessionID = nil
                latest.state = .stopped
            }
        default:
            break
        }
        if let id = (json["requestId"] as? NSNumber)?.intValue, id > 0, let waiter = pending.removeValue(forKey: id) {
            waiter.resume(returning: data)
        }
    }

    private func updateReceiver(_ status: [String: Any]?) {
        guard let status else { return }
        if let volume = status["volume"] as? [String: Any], let level = (volume["level"] as? NSNumber)?.floatValue {
            self.volume = (volume["muted"] as? Bool) == true ? 0 : level
        }
        let apps = (status["applications"] as? [[String: Any]] ?? []).compactMap { app -> (String, String, String)? in
            guard let appID = app["appId"] as? String, let session = app["sessionId"] as? String,
                  let transport = app["transportId"] as? String else { return nil }
            return (appID, session, transport)
        }
        runningApps = apps.map { (appID: $0.0, sessionID: $0.1, transportID: $0.2) }
        // Someone started another app on the TV, or stopped ours.
        if let sessionID, !runningApps.contains(where: { $0.sessionID == sessionID }) {
            self.sessionID = nil
            transportID = nil
            mediaSessionID = nil
            latest.state = .stopped
        }
    }

    private func updateMedia(_ statuses: [[String: Any]]) {
        guard let entry = statuses.first(where: { ($0["mediaSessionId"] as? NSNumber)?.intValue == mediaSessionID }) ?? statuses.first else {
            return
        }
        if let id = (entry["mediaSessionId"] as? NSNumber)?.intValue { mediaSessionID = id }
        latest = Self.status(from: entry, previous: latest)
    }

    nonisolated static func status(from entry: [String: Any], previous: CastPlaybackStatus) -> CastPlaybackStatus {
        var status = previous
        if let time = (entry["currentTime"] as? NSNumber)?.doubleValue, time.isFinite { status.position = time }
        if let media = entry["media"] as? [String: Any], let duration = (media["duration"] as? NSNumber)?.doubleValue,
           duration.isFinite, duration > 0 {
            status.duration = duration
        }
        switch entry["playerState"] as? String ?? "" {
        case "PLAYING": status.state = .playing
        case "PAUSED": status.state = .paused
        case "BUFFERING", "LOADING": status.state = .buffering
        case "IDLE":
            switch entry["idleReason"] as? String ?? "" {
            case "FINISHED": status.state = .finished
            case "ERROR": status.state = .failed("The Cast device couldn't play the video.")
            case "CANCELLED", "INTERRUPTED": status.state = .stopped
            default: status.state = .idle
            }
        default: break
        }
        return status
    }

    private func channelClosed() {
        guard channel != nil else { return }
        channel = nil
        heartbeat?.cancel()
        failPending(GoogleCastError.closed)
        if latest.state != .finished { latest.state = .failed("The connection to \(device.name) was lost.") }
    }

    private func failPending(_ error: Error) {
        let waiters = pending
        pending = [:]
        for waiter in waiters.values { waiter.resume(throwing: error) }
    }
}
