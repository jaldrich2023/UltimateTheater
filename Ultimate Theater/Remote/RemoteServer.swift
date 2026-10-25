//
//  RemoteServer.swift
//  Ultimate Theater
//
//  A small HTTP server on Network.framework for the iPhone remote. It accepts local-network
//  peers only, reads one size-limited request per connection, hands it to the app, and keeps
//  Server-Sent Events streams open for live updates. Advertised over Bonjour as
//  _ultimatetheater._tcp under a generic name. Each peer gets a limited share of connections
//  and streams, and a stream that stops reading is dropped instead of buffering without end.
//

import Foundation
import Network
import os

nonisolated struct RemotePeer: Sendable {
    let address: String
}

nonisolated final class RemoteServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest, RemotePeer) async -> HTTPResponse

    enum State: Sendable, Equatable {
        case stopped
        case starting
        case ready(port: UInt16)
        case failed(String)
    }

    static let preferredPort: UInt16 = 52_525
    static let serviceType = "_ultimatetheater._tcp"

    private let queue = DispatchQueue(label: "UltimateTheater.RemoteServer")
    private let handler: Handler
    private let onStateChange: @Sendable (State) -> Void

    // Confined to `queue`.
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var heartbeat: DispatchSourceTimer?
    private var serviceName = ""
    private let streamCount = OSAllocatedUnfairLock(initialState: 0)
    /// Peers (by share key) that have made a request with a cookie the app accepted, oldest
    /// first; they may use the connections held back for paired phones.
    private var knownPaired: [String] = []

    /// Whether any phone is listening for live updates (readable from any thread).
    var hasStreams: Bool { streamCount.withLock { $0 > 0 } }

    init(handler: @escaping Handler, onStateChange: @escaping @Sendable (State) -> Void) {
        self.handler = handler
        self.onStateChange = onStateChange
    }

    // MARK: Lifecycle

    func start(serviceName: String) {
        queue.async { [self] in
            self.serviceName = serviceName
            startListener(port: Self.preferredPort)
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            heartbeat?.cancel()
            heartbeat = nil
            for client in clients.values { client.connection.cancel() }
            clients = [:]
            streamCount.withLock { $0 = 0 }
            onStateChange(.stopped)
        }
    }

    /// Ends every live-update stream, e.g. after a device is revoked (phones reconnect and
    /// are checked again).
    func closeStreams() {
        queue.async { [self] in
            for client in clients.values where client.isStream { client.connection.cancel() }
        }
    }

    /// Sends a JSON state update to every open stream.
    func broadcast(_ json: Data) {
        let event = SSE.event(json)
        queue.async { [self] in
            for client in clients.values where client.isStream { sendOnStream(event, to: client) }
        }
    }

    /// Queues bytes on an open stream, tracking what the phone hasn't read yet. A phone that
    /// falls too far behind (asleep, or deliberately not reading) is disconnected; it
    /// reconnects when it wakes.
    private func sendOnStream(_ data: Data, to client: Client) {
        guard !RemoteConnectionLimits.shouldDrop(bytesInFlight: client.bytesInFlight, adding: data.count) else {
            client.connection.cancel()
            return
        }
        client.bytesInFlight += data.count
        let count = data.count
        // Completions run on `queue`, the connection's queue.
        client.connection.send(content: data, completion: .contentProcessed { [weak client] _ in
            guard let client else { return }
            client.bytesInFlight = max(client.bytesInFlight - count, 0)
        })
    }

    private func startListener(port: UInt16) {
        onStateChange(.starting)
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.includePeerToPeer = false
        parameters.prohibitedInterfaceTypes = [.cellular]
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port) ?? .any)
            listener.service = NWListener.Service(name: serviceName, type: Self.serviceType)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener else { return }
                self.listenerChanged(listener, state: state, requestedPort: port)
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            if port != 0 { return startListener(port: 0) }
            onStateChange(.failed(error.localizedDescription))
        }
    }

    private func listenerChanged(_ listener: NWListener, state: NWListener.State, requestedPort: UInt16) {
        guard listener === self.listener else { return }
        switch state {
        case .ready:
            startHeartbeat()
            onStateChange(.ready(port: listener.port?.rawValue ?? requestedPort))
        case .failed(let error):
            listener.cancel()
            self.listener = nil
            // The preferred port is taken: let the system pick one.
            if requestedPort != 0, case .posix(let code) = error, code == .EADDRINUSE {
                startListener(port: 0)
            } else {
                onStateChange(.failed(error.localizedDescription))
            }
        case .waiting(let error):
            onStateChange(.failed(error.localizedDescription))
        default:
            break
        }
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            for client in self.clients.values where client.isStream { self.sendOnStream(SSE.heartbeat, to: client) }
        }
        timer.resume()
        heartbeat = timer
    }

    // MARK: Connections

    private final class Client: @unchecked Sendable {
        let connection: NWConnection
        let peer: RemotePeer
        /// The peer for per-device limits (see `RemoteConnectionLimits.shareKey`).
        let peerKey: String
        var buffer = Data()
        var isStream = false
        var hasRequest = false
        var hasHeaders = false
        var bytesInFlight = 0
        var timeout: DispatchWorkItem?

        init(connection: NWConnection, peer: RemotePeer, peerKey: String) {
            self.connection = connection
            self.peer = peer
            self.peerKey = peerKey
        }
    }

    private func accept(_ connection: NWConnection) {
        guard LANAddressFilter.isAllowed(connection.endpoint), case .hostPort(let host, _) = connection.endpoint else {
            connection.cancel()
            return
        }
        let peer = RemotePeer(address: "\(host)")
        let linkLocalInUse = Set(clients.values.map(\.peerKey).filter(PairingThrottle.isLinkLocalKey))
        let key = RemoteConnectionLimits.shareKey(PairingThrottle.peerKey(peer.address), linkLocalKeysInUse: linkLocalInUse)
        let client = Client(connection: connection, peer: peer, peerKey: key)
        let fromPeer = clients.values.filter { $0.peerKey == key }.count
        guard RemoteConnectionLimits.canAccept(total: clients.count, fromPeer: fromPeer,
                                               isKnownPaired: knownPaired.contains(key)) else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        clients[id] = client
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.remove(id)
            default: break
            }
        }
        // A short wait for the headers, so idle connections can't hold the slots.
        scheduleTimeout(for: client, after: RemoteConnectionLimits.headerTimeout)
        connection.start(queue: queue)
        receive(on: client)
    }

    private func scheduleTimeout(for client: Client, after seconds: TimeInterval) {
        client.timeout?.cancel()
        let timeout = DispatchWorkItem { [weak connection = client.connection] in connection?.cancel() }
        client.timeout = timeout
        queue.asyncAfter(deadline: .now() + seconds, execute: timeout)
    }

    /// Remembers a peer whose cookie the app accepted.
    private func notePaired(_ key: String) {
        knownPaired.removeAll { $0 == key }
        knownPaired.append(key)
        if knownPaired.count > RemoteConnectionLimits.maxKnownPairedPeers { knownPaired.removeFirst() }
    }

    private func remove(_ id: ObjectIdentifier) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.timeout?.cancel()
        if client.isStream { streamCount.withLock { $0 = max($0 - 1, 0) } }
    }

    private func receive(on client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if client.hasRequest {
                // Event streams: the phone only ever closes them.
                if isComplete || error != nil { client.connection.cancel() } else { self.receive(on: client) }
                return
            }
            if let data { client.buffer.append(data) }
            if !client.hasHeaders, HTTPParser.hasCompleteHeaders(client.buffer) {
                // Headers are in: the rest of the request gets the remaining time.
                client.hasHeaders = true
                self.scheduleTimeout(for: client, after: RemoteConnectionLimits.requestTimeout - RemoteConnectionLimits.headerTimeout)
            }
            switch HTTPParser.parse(client.buffer) {
            case .incomplete:
                if isComplete || error != nil {
                    client.connection.cancel()
                } else {
                    self.receive(on: client)
                }
            case .failure(let failure):
                client.hasRequest = true
                self.send(.error(failure.status, "Bad request"), to: client)
            case .complete(let request, _):
                client.hasRequest = true
                client.timeout?.cancel()
                client.buffer = Data()
                let handler = self.handler
                let peer = client.peer
                Task {
                    let response = await handler(request, peer)
                    self.queue.async {
                        if response.isFromPairedDevice { self.notePaired(client.peerKey) }
                        self.send(response, to: client)
                    }
                }
            }
        }
    }

    private func send(_ response: HTTPResponse, to client: Client) {
        let connection = client.connection
        if response.isEventStream {
            // Only paired devices get event streams (the app checks before answering), and
            // each peer may hold only a couple of the slots.
            let fromPeer = clients.values.filter { $0.isStream && $0.peerKey == client.peerKey }.count
            let total = streamCount.withLock { $0 }
            guard RemoteConnectionLimits.canOpenStream(total: total, fromPeer: fromPeer) else {
                var busy = HTTPResponse.error(503, "Too many open remotes")
                busy.headers.append(("Retry-After", "5"))
                return send(busy, to: client)
            }
            client.isStream = true
            streamCount.withLock { $0 += 1 }
            sendOnStream(response.serialized(), to: client)
            receive(on: client) // Watch for the phone closing the stream.
        } else {
            connection.send(content: response.serialized(), isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
