//
//  CastNetwork.swift
//  Ultimate Theater
//
//  Small pieces shared by the casting protocols: which addresses count as the local network,
//  the Mac's own address on it, and a minimal HTTP/1.1 client for talking to TVs and
//  streamers (UPnP descriptions and SOAP, Roku ECP). The client is built on Network.framework
//  so every response is size-capped and time-limited, and plain HTTP to LAN devices doesn't
//  depend on App Transport Security exceptions.
//

import Foundation
import Network
import Darwin

// MARK: - Local network addresses

nonisolated enum LANAddress {
    /// Private IPv4 (RFC 1918) and link-local addresses: where casting devices live.
    static func isLocal(ipv4 bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        switch (bytes[0], bytes[1]) {
        case (10, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        case (169, 254): return true
        default: return false
        }
    }

    /// IPv6 link-local (fe80::/10), unique local (fc00::/7), and IPv4-mapped local addresses.
    static func isLocal(ipv6 bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return true }
        if bytes[0] & 0xFE == 0xFC { return true }
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return isLocal(ipv4: Array(bytes[12..<16]))
        }
        return false
    }

    /// Whether a dotted IPv4 or IPv6 literal is on the local network.
    static func isLocal(literal: String) -> Bool {
        if let v4 = IPv4Address(literal) { return isLocal(ipv4: [UInt8](v4.rawValue)) }
        let trimmed = literal.split(separator: "%").first.map(String.init) ?? literal
        if let v6 = IPv6Address(trimmed) { return isLocal(ipv6: [UInt8](v6.rawValue)) }
        return false
    }

    /// Whether a connecting peer is on the local network.
    static func isLocal(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return isLocal(ipv4: [UInt8](address.rawValue))
        case .ipv6(let address): return isLocal(ipv6: [UInt8](address.rawValue))
        default: return false
        }
    }

    /// The host of a URL when it's a local IPv4/IPv6 literal (device URLs must be).
    static func localHost(of url: URL) -> String? {
        guard url.scheme?.lowercased() == "http", let host = url.host(percentEncoded: false) else { return nil }
        let bare = host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host
        return isLocal(literal: bare) ? bare : nil
    }

    /// The Mac's IPv4 address on the route toward `peer` (a connected UDP socket asks the
    /// kernel which source address it would use; nothing is sent).
    static func localIPv4(toward peer: String) -> String? {
        guard let target = IPv4Address(peer) else { return primaryIPv4() }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return primaryIPv4() }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(9).bigEndian
        target.rawValue.withUnsafeBytes { raw in
            withUnsafeMutableBytes(of: &address.sin_addr) { $0.copyMemory(from: raw) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return primaryIPv4() }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return primaryIPv4() }
        let bytes = withUnsafeBytes(of: local.sin_addr) { [UInt8]($0) }
        guard isLocal(ipv4: bytes) else { return primaryIPv4() }
        return bytes.map(String.init).joined(separator: ".")
    }

    /// The first local IPv4 address on an active Ethernet or Wi-Fi interface.
    static func primaryIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var candidates: [(name: String, address: String)] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let raw = entry.pointee.ifa_addr, raw.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let bytes = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                withUnsafeBytes(of: pointer.pointee.sin_addr) { [UInt8]($0) }
            }
            guard isLocal(ipv4: bytes), bytes[0] != 169 else { continue }
            candidates.append((String(cString: entry.pointee.ifa_name), bytes.map(String.init).joined(separator: ".")))
        }
        return (candidates.first { $0.name.hasPrefix("en") } ?? candidates.first)?.address
    }
}

// MARK: - Tokens

nonisolated enum CastToken {
    /// 256 random bits as 64 lowercase hex characters.
    static func make() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // SecRandomCopyBytes doesn't fail in practice; fall back to the system generator.
            var generator = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: 0...255, using: &generator) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Compares without stopping at the first difference.
    static func matches(_ candidate: Substring, _ token: String) -> Bool {
        let a = Array(candidate.utf8)
        let b = Array(token.utf8)
        guard a.count == b.count, !b.isEmpty else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}

// MARK: - HTTP client

nonisolated struct LANHTTPResponse: Sendable {
    var status: Int
    /// Header names lowercased.
    var headers: [String: String]
    var body: Data

    var bodyText: String { String(decoding: body, as: UTF8.self) }
}

nonisolated enum LANHTTPError: Error, LocalizedError, Equatable {
    case notLocal
    case timedOut
    case tooLarge
    case malformed
    case connection(String)
    case status(Int)

    var errorDescription: String? {
        switch self {
        case .notLocal: "The device isn't on the local network."
        case .timedOut: "The device didn't respond in time."
        case .tooLarge: "The device sent more data than expected."
        case .malformed: "The device sent a response that couldn't be read."
        case .connection(let reason): "Couldn't reach the device (\(reason))."
        case .status(let code): "The device returned an error (HTTP \(code))."
        }
    }
}

/// Parses an HTTP/1.1 response from the bytes received so far.
nonisolated enum LANHTTPResponseParser {
    enum Result: Equatable {
        case incomplete
        case complete(status: Int, headers: [String: String], body: Data)
        case invalid
    }

    static let maximumHeaderSize = 16 * 1024

    static func parse(_ data: Data, isClosed: Bool, maxBody: Int) -> Result {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maximumHeaderSize ? .invalid : .incomplete
        }
        guard headerEnd.lowerBound <= maximumHeaderSize else { return .invalid }
        let head = String(decoding: data[data.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ", maxSplits: 2)
        guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/1."), let status = Int(statusLine[1]), (100...599).contains(status) else {
            return .invalid
        }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        let body = data[headerEnd.upperBound...]
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            switch dechunk(Data(body), maxBody: maxBody) {
            case .some(.some(let decoded)): return .complete(status: status, headers: headers, body: decoded)
            case .some(.none): return isClosed ? .invalid : .incomplete
            case .none: return .invalid
            }
        }
        if let lengthText = headers["content-length"] {
            guard let length = Int(lengthText), length >= 0 else { return .invalid }
            guard length <= maxBody else { return .invalid }
            if body.count >= length { return .complete(status: status, headers: headers, body: Data(body.prefix(length))) }
            return isClosed ? .invalid : .incomplete
        }
        if status == 204 || status == 304 || (100..<200).contains(status) {
            return .complete(status: status, headers: headers, body: Data())
        }
        guard body.count <= maxBody else { return .invalid }
        return isClosed ? .complete(status: status, headers: headers, body: Data(body)) : .incomplete
    }

    /// Decodes a chunked body. Nil: malformed or too large; `.some(nil)`: more bytes needed.
    static func dechunk(_ data: Data, maxBody: Int) -> Data?? {
        var output = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex) else {
                return data.endIndex - index > 64 ? nil : .some(nil)
            }
            let sizeText = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard sizeText.count <= 8, let size = Int(sizeText, radix: 16), size >= 0 else { return nil }
            index = lineEnd.upperBound
            if size == 0 { return .some(output) } // Trailers, if any, are ignored.
            guard output.count + size <= maxBody else { return nil }
            guard data.endIndex - index >= size + 2 else { return .some(nil) }
            output.append(data[index..<(index + size)])
            index += size
            guard data[index..<(index + 2)] == crlf else { return nil }
            index += 2
        }
    }
}

/// One HTTP/1.1 exchange with a device on the local network.
nonisolated enum LANHTTP {
    static func send(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil,
                     timeout: Double = 8, maxBody: Int = 256 * 1024) async throws -> LANHTTPResponse {
        guard let host = LANAddress.localHost(of: url) else { throw LANHTTPError.notLocal }
        let port = url.port ?? 80
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else { throw LANHTTPError.notLocal }

        var target = url.path(percentEncoded: true)
        if target.isEmpty { target = "/" }
        if let query = url.query(percentEncoded: true) { target += "?" + query }
        let hostHeader = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        var head = "\(method) \(target) HTTP/1.1\r\nHost: \(hostHeader)\r\nConnection: close\r\nUser-Agent: \(CastHTTPIdentity.userAgent)\r\n"
        for (name, value) in headers {
            // Header values come from our own code, but never let one carry a line break.
            guard !name.contains(where: \.isNewline), !value.contains(where: \.isNewline) else { continue }
            head += "\(name): \(value)\r\n"
        }
        if body != nil || method == "POST" { head += "Content-Length: \(body?.count ?? 0)\r\n" }
        head += "\r\n"
        var request = Data(head.utf8)
        if let body { request.append(body) }

        let exchange = Exchange(connection: NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp),
                                request: request, maxBody: maxBody)
        return try await withTaskCancellationHandler {
            try await exchange.run(timeout: timeout)
        } onCancel: {
            exchange.cancel()
        }
    }

    private final class Exchange: @unchecked Sendable {
        private let connection: NWConnection
        private let request: Data
        private let maxBody: Int
        private let queue = DispatchQueue(label: "cast.http-client")
        private var buffer = Data()
        private var continuation: CheckedContinuation<LANHTTPResponse, Error>?
        private var isFinished = false

        init(connection: NWConnection, request: Data, maxBody: Int) {
            self.connection = connection
            self.request = request
            self.maxBody = maxBody
        }

        func run(timeout: Double) async throws -> LANHTTPResponse {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    self.continuation = continuation
                    connection.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            connection.send(content: request, completion: .contentProcessed { [weak self] error in
                                if let error { self?.finish(.failure(LANHTTPError.connection(error.localizedDescription))) }
                            })
                            receive()
                        case .failed(let error):
                            finish(.failure(LANHTTPError.connection(error.localizedDescription)))
                        case .waiting:
                            // Waiting on a route or on the Local Network permission prompt; the
                            // timeout decides.
                            break
                        case .cancelled:
                            finish(.failure(CancellationError()))
                        default:
                            break
                        }
                    }
                    connection.start(queue: queue)
                    queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(.failure(LANHTTPError.timedOut)) }
                }
            }
        }

        func cancel() {
            queue.async { [weak self] in self?.finish(.failure(CancellationError())) }
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self, !isFinished else { return }
                if let data { buffer.append(data) }
                guard buffer.count <= maxBody + LANHTTPResponseParser.maximumHeaderSize + 4096 else {
                    finish(.failure(LANHTTPError.tooLarge))
                    return
                }
                let closed = isComplete || error != nil
                switch LANHTTPResponseParser.parse(buffer, isClosed: closed, maxBody: maxBody) {
                case .complete(let status, let headers, let body):
                    finish(.success(LANHTTPResponse(status: status, headers: headers, body: body)))
                case .invalid:
                    finish(.failure(LANHTTPError.malformed))
                case .incomplete:
                    if closed { finish(.failure(LANHTTPError.malformed)) } else { receive() }
                }
            }
        }

        private func finish(_ result: Result<LANHTTPResponse, Error>) {
            guard !isFinished else { return }
            isFinished = true
            connection.stateUpdateHandler = nil
            connection.cancel()
            continuation?.resume(with: result)
            continuation = nil
        }
    }
}

nonisolated enum CastHTTPIdentity {
    static let userAgent = "macOS UPnP/1.1 UltimateTheater/1.0"
}

// MARK: - XML

/// Collects the text of every element by local name (namespace prefixes dropped). Device XML
/// is small and flat enough that this covers SOAP responses, Roku replies, and device info.
nonisolated final class FlatXMLReader: NSObject, XMLParserDelegate {
    static let maximumSize = 256 * 1024

    private(set) var values: [String: String] = [:]
    private(set) var attributes: [String: [String: String]] = [:]
    private var text = ""
    private var depth = 0

    /// Nil when the XML is too large, has a DTD, or doesn't parse.
    static func read(_ data: Data) -> FlatXMLReader? {
        guard data.count <= maximumSize, !XMLSafety.hasDoctype(data) else { return nil }
        let reader = FlatXMLReader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = reader
        return parser.parse() ? reader : nil
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        depth += 1
        guard depth < 64 else { parser.abortParsing(); return }
        text = ""
        let name = XMLSafety.localName(elementName)
        if attributes[name] == nil, !attributeDict.isEmpty { attributes[name] = attributeDict }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard text.count < 64 * 1024 else { return }
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        depth -= 1
        let name = XMLSafety.localName(elementName)
        if values[name] == nil { values[name] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        text = ""
    }
}

nonisolated enum XMLSafety {
    static func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    /// Device XML never needs a DTD; refusing them rules out entity-expansion tricks.
    static func hasDoctype(_ data: Data) -> Bool {
        data.range(of: Data("<!DOCTYPE".utf8)) != nil || data.range(of: Data("<!doctype".utf8)) != nil
            || data.range(of: Data("<!ENTITY".utf8)) != nil
    }

    /// Escapes text for XML content or attribute values.
    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default:
                // Control characters other than tab and line breaks aren't allowed in XML 1.0.
                if let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
                   scalar.value < 0x20, scalar != "\t", scalar != "\n", scalar != "\r" { continue }
                result.append(character)
            }
        }
        return result
    }
}
