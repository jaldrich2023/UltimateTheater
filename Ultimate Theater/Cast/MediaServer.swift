//
//  MediaServer.swift
//  Ultimate Theater
//
//  The HTTP server casting devices fetch the video from. It serves exactly one file (the one
//  being cast) and its poster, each at a path holding a fresh 256-bit random token, to peers
//  on the local network only. Tokens are revoked when casting stops, which also ends any
//  transfer in progress. Range requests are supported (TVs seek by requesting byte ranges),
//  as are the DLNA streaming headers some TVs insist on.
//
//  The file is read in chunks on the server's own queue, never on the main actor; the next
//  chunk is read only once the previous one has been handed to the network, so a slow TV
//  can't make the Mac buffer the file in memory.
//

import Foundation
import os
import Network

// MARK: - Range

nonisolated enum HTTPByteRange {
    enum Resolution: Equatable {
        /// No (usable) Range header: send the whole file with 200.
        case full
        /// Inclusive byte offsets, sent with 206.
        case partial(start: Int64, end: Int64)
        /// 416, with "Content-Range: bytes */size".
        case unsatisfiable
    }

    /// Resolves a Range header against a file size (RFC 9110 §14). Malformed headers,
    /// other units, and multiple ranges are ignored (the server may always send the whole
    /// representation instead), which is what every casting device copes with.
    static func resolve(_ header: String?, size: Int64) -> Resolution {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return .full }
        guard header.lowercased().hasPrefix("bytes=") else { return .full }
        let spec = header.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(","), size > 0 else { return .full }
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .full }
        let first = parts[0].trimmingCharacters(in: .whitespaces)
        let last = parts[1].trimmingCharacters(in: .whitespaces)
        func number(_ text: String) -> Int64? {
            guard !text.isEmpty, text.count <= 18, text.allSatisfy(\.isASCIIDigit) else { return nil }
            return Int64(text)
        }
        if first.isEmpty {
            // bytes=-N: the last N bytes.
            guard let suffix = number(last) else { return .full }
            guard suffix > 0 else { return .unsatisfiable }
            return .partial(start: max(size - suffix, 0), end: size - 1)
        }
        guard let start = number(first) else { return .full }
        if last.isEmpty {
            return start < size ? .partial(start: start, end: size - 1) : .unsatisfiable
        }
        guard let end = number(last), end >= start else { return .full }
        guard start < size else { return .unsatisfiable }
        return .partial(start: start, end: min(end, size - 1))
    }
}

nonisolated private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

// MARK: - Requests

nonisolated struct CastHTTPRequest: Equatable, Sendable {
    var method: String
    /// The path without its query, still percent-encoded.
    var path: String
    /// Header names lowercased.
    var headers: [String: String]

    var keepAlive: Bool {
        let connection = headers["connection"]?.lowercased() ?? ""
        return !connection.contains("close")
    }

    enum ParseResult: Equatable {
        case incomplete
        case invalid
        case request(CastHTTPRequest, consumed: Int)
    }

    static let maximumHeaderSize = 16 * 1024

    static func parse(_ data: Data) -> ParseResult {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maximumHeaderSize ? .invalid : .incomplete
        }
        let headerLength = end.lowerBound - data.startIndex
        guard headerLength <= maximumHeaderSize else { return .invalid }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1."), requestLine[1].hasPrefix("/") else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty, !name.contains(" ") else { return .invalid }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // Devices only ever GET or HEAD; a request body isn't something we accept.
        if let length = headers["content-length"], length != "0" { return .invalid }
        if headers["transfer-encoding"] != nil { return .invalid }
        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        return .request(CastHTTPRequest(method: String(requestLine[0]), path: path, headers: headers),
                        consumed: end.upperBound - data.startIndex)
    }
}

/// Which published resource a path names.
nonisolated enum CastMediaRoute: Equatable {
    case media
    case artwork
    case notFound

    /// "/media/<token>/<file name>" and "/art/<token>.jpg"; the token must match exactly.
    static func match(path: String, mediaToken: String?, artworkToken: String?) -> CastMediaRoute {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        // parts[0] is the empty string before the leading slash.
        guard parts.count >= 3, parts[0].isEmpty else { return .notFound }
        if parts[1] == "media", parts.count == 4, !parts[3].isEmpty, let mediaToken,
           CastToken.matches(parts[2], mediaToken) {
            return .media
        }
        if parts[1] == "art", parts.count == 3, parts[2].hasSuffix(".jpg"), let artworkToken,
           CastToken.matches(parts[2].dropLast(4), artworkToken) {
            return .artwork
        }
        return .notFound
    }
}

// MARK: - Server

nonisolated final class CastMediaServer: @unchecked Sendable {
    struct PublishedFile: Sendable {
        let url: URL
        let contentType: String
        let size: Int64
        let token: String
        let path: String
    }

    enum ServerError: Error, LocalizedError {
        case couldNotListen(String)
        case fileUnreadable

        var errorDescription: String? {
            switch self {
            case .couldNotListen(let reason): "Ultimate Theater couldn't start sharing the video on your network (\(reason))."
            case .fileUnreadable: "The video file couldn't be read."
            }
        }
    }

    static let chunkSize = 256 * 1024
    static let maximumConnections = 24
    static let requestTimeout: Double = 30

    // Everything below is touched only on `queue`.
    private let queue = DispatchQueue(label: "cast.media-server", qos: .userInitiated)
    private var listener: NWListener?
    private var port: UInt16?
    private var file: PublishedFile?
    private var artwork: (token: String, data: Data)?
    private var connections: [ObjectIdentifier: ClientConnection] = [:]

    /// Only touched on the server's queue.
    private final class ClientConnection: @unchecked Sendable {
        let connection: NWConnection
        var buffer = Data()
        var timeout: DispatchWorkItem?
        var isStreaming = false
        init(connection: NWConnection) { self.connection = connection }
    }

    /// Starts listening (once) and returns the port.
    func start() async throws -> UInt16 {
        if let port = queue.sync(execute: { self.port }) { return port }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let listener: NWListener
        do { listener = try NWListener(using: parameters, on: .any) } catch {
            throw ServerError.couldNotListen(error.localizedDescription)
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            queue.async { [self] in
                // Only the first ready/failed/cancelled state finishes the wait.
                let once = OSAllocatedUnfairLock(initialState: false)
                let first: @Sendable () -> Bool = {
                    once.withLock { done in
                        defer { done = true }
                        return !done
                    }
                }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard first() else { return }
                        let port = listener.port?.rawValue ?? 0
                        self.port = port
                        continuation.resume(returning: port)
                    case .failed(let error):
                        self.listener = nil
                        self.port = nil
                        if first() {
                            continuation.resume(throwing: ServerError.couldNotListen(error.localizedDescription))
                        }
                        listener.cancel()
                    case .cancelled:
                        if first() {
                            continuation.resume(throwing: ServerError.couldNotListen("cancelled"))
                        }
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                self.listener = listener
                listener.start(queue: queue)
            }
        }
    }

    /// Publishes a file under a new token (revoking any earlier one). Returns the URL path.
    func publish(file url: URL, contentType: String) throws -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value, size > 0,
              FileManager.default.isReadableFile(atPath: url.path) else { throw ServerError.fileUnreadable }
        let token = CastToken.make()
        let name = Self.safeFileName(url.lastPathComponent)
        let path = "/media/\(token)/\(name)"
        let published = PublishedFile(url: url, contentType: contentType, size: size, token: token, path: path)
        queue.sync {
            self.file = published
            dropStreams()
        }
        return path
    }

    /// Publishes JPEG artwork under its own token. Returns the URL path.
    func publishArtwork(_ data: Data) -> String {
        let token = CastToken.make()
        queue.sync { artwork = (token, data) }
        return "/art/\(token).jpg"
    }

    var publishedFile: PublishedFile? { queue.sync { file } }

    /// Revokes every token and closes every connection; the listener keeps running.
    func revoke() {
        queue.sync {
            file = nil
            artwork = nil
            for client in connections.values { client.timeout?.cancel(); client.connection.cancel() }
            connections = [:]
        }
    }

    func stop() {
        revoke()
        queue.sync {
            listener?.cancel()
            listener = nil
            port = nil
        }
    }

    /// The file name part of the URL: ASCII letters, digits, dots, dashes, and underscores,
    /// keeping the extension (some TVs look at it).
    static func safeFileName(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var cleaned = String(name.map { allowed.contains($0) ? $0 : "_" })
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 80 {
            let ext = (name as NSString).pathExtension
            cleaned = String(cleaned.prefix(70)) + (ext.isEmpty ? "" : "." + String(ext.prefix(8)).filter { allowed.contains($0) })
        }
        return cleaned.isEmpty ? "video" : cleaned
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        guard LANAddress.isLocal(connection.endpoint), connections.count < Self.maximumConnections else {
            connection.cancel()
            return
        }
        let client = ClientConnection(connection: connection)
        let id = ObjectIdentifier(connection)
        connections[id] = client
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.remove(id)
            default: break
            }
        }
        connection.start(queue: queue)
        armTimeout(client)
        receive(client)
    }

    private func remove(_ id: ObjectIdentifier) {
        connections.removeValue(forKey: id)?.timeout?.cancel()
    }

    /// Ends transfers of a revoked or replaced file.
    private func dropStreams() {
        for (id, client) in connections where client.isStreaming {
            client.connection.cancel()
            connections.removeValue(forKey: id)
        }
    }

    private func armTimeout(_ client: ClientConnection) {
        client.timeout?.cancel()
        let item = DispatchWorkItem { [weak client] in client?.connection.cancel() }
        client.timeout = item
        queue.asyncAfter(deadline: .now() + Self.requestTimeout, execute: item)
    }

    private func receive(_ client: ClientConnection) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self, weak client] data, _, isComplete, error in
            guard let self, let client else { return }
            if let data { client.buffer.append(data) }
            process(client, isClosed: isComplete || error != nil)
        }
    }

    /// Answers the request at the front of the buffer, or reads more of it.
    private func process(_ client: ClientConnection, isClosed: Bool = false) {
        switch CastHTTPRequest.parse(client.buffer) {
        case .incomplete:
            if isClosed { client.connection.cancel() } else { receive(client) }
        case .invalid:
            client.buffer = Data()
            send(client, head: Self.head(status: 400, headers: ["Content-Length": "0", "Connection": "close"]), keepAlive: false)
        case .request(let request, let consumed):
            client.buffer = Data(client.buffer.dropFirst(consumed))
            client.timeout?.cancel()
            respond(to: request, on: client)
        }
    }

    private func respond(to request: CastHTTPRequest, on client: ClientConnection) {
        let keepAlive = request.keepAlive
        guard request.method == "GET" || request.method == "HEAD" else {
            send(client, head: Self.head(status: 405, headers: ["Allow": "GET, HEAD", "Content-Length": "0", "Connection": "close"]), keepAlive: false)
            return
        }
        let isHead = request.method == "HEAD"
        switch CastMediaRoute.match(path: request.path, mediaToken: file?.token, artworkToken: artwork?.token) {
        case .media:
            guard let file else { return notFound(client, keepAlive: keepAlive) }
            serve(file, request: request, isHead: isHead, keepAlive: keepAlive, on: client)
        case .artwork:
            guard let artwork else { return notFound(client, keepAlive: keepAlive) }
            let head = Self.head(status: 200, headers: ["Content-Type": "image/jpeg", "Content-Length": "\(artwork.data.count)",
                                                        "Cache-Control": "no-store", "Connection": keepAlive ? "keep-alive" : "close"])
            var response = Data(head.utf8)
            if !isHead { response.append(artwork.data) }
            send(client, head: nil, body: response, keepAlive: keepAlive)
        case .notFound:
            notFound(client, keepAlive: keepAlive)
        }
    }

    private func notFound(_ client: ClientConnection, keepAlive: Bool) {
        send(client, head: Self.head(status: 404, headers: ["Content-Length": "0", "Connection": keepAlive ? "keep-alive" : "close"]),
             keepAlive: keepAlive)
    }

    private func serve(_ file: PublishedFile, request: CastHTTPRequest, isHead: Bool, keepAlive: Bool, on client: ClientConnection) {
        let range = HTTPByteRange.resolve(request.headers["range"], size: file.size)
        var headers = Self.mediaHeaders(contentType: file.contentType, keepAlive: keepAlive)
        let start: Int64
        let length: Int64
        let status: Int
        switch range {
        case .full:
            status = 200
            start = 0
            length = file.size
        case .partial(let first, let last):
            status = 206
            start = first
            length = last - first + 1
            headers["Content-Range"] = "bytes \(first)-\(last)/\(file.size)"
        case .unsatisfiable:
            headers["Content-Range"] = "bytes */\(file.size)"
            headers["Content-Length"] = "0"
            send(client, head: Self.head(status: 416, headers: headers), keepAlive: keepAlive)
            return
        }
        headers["Content-Length"] = "\(length)"
        let head = Data(Self.head(status: status, headers: headers).utf8)
        guard !isHead else {
            send(client, head: nil, body: head, keepAlive: keepAlive)
            return
        }
        guard let handle = try? FileHandle(forReadingFrom: file.url) else {
            send(client, head: Self.head(status: 404, headers: ["Content-Length": "0", "Connection": "close"]), keepAlive: false)
            return
        }
        do { try handle.seek(toOffset: UInt64(start)) } catch {
            try? handle.close()
            client.connection.cancel()
            return
        }
        client.isStreaming = true
        client.connection.send(content: head, completion: .contentProcessed { [weak self, weak client] error in
            guard let self, let client else { try? handle.close(); return }
            guard error == nil else { try? handle.close(); client.connection.cancel(); return }
            stream(handle, remaining: length, token: file.token, keepAlive: keepAlive, on: client)
        })
    }

    /// Sends the next chunk once the previous one is on its way.
    private func stream(_ handle: FileHandle, remaining: Int64, token: String, keepAlive: Bool, on client: ClientConnection) {
        guard file?.token == token, connections[ObjectIdentifier(client.connection)] != nil else {
            try? handle.close()
            client.connection.cancel()
            return
        }
        guard remaining > 0 else {
            try? handle.close()
            client.isStreaming = false
            finish(client, keepAlive: keepAlive)
            return
        }
        let count = Int(min(remaining, Int64(Self.chunkSize)))
        guard let chunk = try? handle.read(upToCount: count), !chunk.isEmpty else {
            // The file shrank or vanished: the promised length can't be met.
            try? handle.close()
            client.connection.cancel()
            return
        }
        client.connection.send(content: chunk, completion: .contentProcessed { [weak self, weak client] error in
            guard let self, let client else { try? handle.close(); return }
            guard error == nil else { try? handle.close(); client.connection.cancel(); return }
            stream(handle, remaining: remaining - Int64(chunk.count), token: token, keepAlive: keepAlive, on: client)
        })
    }

    private func send(_ client: ClientConnection, head: String?, body: Data? = nil, keepAlive: Bool) {
        var data = head.map { Data($0.utf8) } ?? Data()
        if let body { data.append(body) }
        client.connection.send(content: data, completion: .contentProcessed { [weak self, weak client] error in
            guard let self, let client else { return }
            if error != nil { client.connection.cancel(); return }
            finish(client, keepAlive: keepAlive)
        })
    }

    /// After a response: wait for the next request on a kept-alive connection, else close.
    private func finish(_ client: ClientConnection, keepAlive: Bool) {
        guard keepAlive else {
            client.connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak client] _ in
                client?.connection.cancel()
            })
            return
        }
        armTimeout(client)
        process(client) // A pipelined request may already be buffered.
    }

    // MARK: Headers

    static func mediaHeaders(contentType: String, keepAlive: Bool) -> [String: String] {
        [
            "Content-Type": contentType,
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-store",
            "transferMode.dlna.org": "Streaming",
            "contentFeatures.dlna.org": CastCompatibility.dlnaFeatures,
            "Connection": keepAlive ? "keep-alive" : "close",
        ]
    }

    static func head(status: Int, headers: [String: String]) -> String {
        let reason = switch status {
        case 200: "OK"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 416: "Range Not Satisfiable"
        default: "Error"
        }
        var text = "HTTP/1.1 \(status) \(reason)\r\nServer: \(CastHTTPIdentity.userAgent)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { text += "\(name): \(value)\r\n" }
        return text + "\r\n"
    }
}
