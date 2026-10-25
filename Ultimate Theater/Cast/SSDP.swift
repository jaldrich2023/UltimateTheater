//
//  SSDP.swift
//  Ultimate Theater
//
//  Simple Service Discovery Protocol (UPnP Device Architecture 1.1, section 1.3): an
//  M-SEARCH request sent to the multicast group 239.255.255.250:1900, answered by unicast
//  HTTP-over-UDP responses carrying LOCATION (the device description URL), ST, and USN.
//
//  This uses a plain BSD UDP socket rather than NWConnectionGroup. Sending to a multicast
//  address and receiving the unicast replies on the same ephemeral socket doesn't join the
//  group, so it needs no multicast entitlement (com.apple.developer.networking.multicast is
//  an iOS/iPadOS entitlement); on macOS it needs only the sandbox's network client/server
//  entitlements and the user's Local Network permission.
//

import Foundation
import Darwin

nonisolated struct SSDPResponse: Hashable, Sendable {
    var location: URL
    var searchTarget: String
    var uniqueServiceName: String
    var server: String?
    /// The IPv4 address the response came from.
    var sender: String

    /// Parses one search response. The LOCATION must be an http URL on the sender's own
    /// address, so a device can't point the app at some other machine.
    static func parse(_ text: String, sender: String) -> SSDPResponse? {
        guard text.utf8.count <= 8 * 1024 else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        if lines.count == 1 { lines = text.components(separatedBy: "\n") }
        guard let status = lines.first?.uppercased(), status.hasPrefix("HTTP/1.1 200") || status.hasPrefix("HTTP/1.0 200") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        guard let locationText = headers["LOCATION"], let location = URL(string: locationText),
              let host = LANAddress.localHost(of: location), host == sender,
              let target = headers["ST"], !target.isEmpty else { return nil }
        return SSDPResponse(location: location, searchTarget: target, uniqueServiceName: headers["USN"] ?? locationText,
                            server: headers["SERVER"], sender: sender)
    }

    /// The device's UUID from its USN ("uuid:…::urn:…"), when it has one.
    var deviceUUID: String? {
        guard let range = uniqueServiceName.range(of: "uuid:", options: .caseInsensitive) else { return nil }
        let rest = uniqueServiceName[range.upperBound...]
        let uuid = rest.split(separator: ":", maxSplits: 1).first.map(String.init) ?? String(rest)
        return uuid.isEmpty ? nil : uuid.lowercased()
    }
}

nonisolated enum SSDP {
    static let mediaRenderer = "urn:schemas-upnp-org:device:MediaRenderer:1"
    static let roku = "roku:ecp"

    static func searchRequest(target: String, maxWait: Int = 2) -> String {
        "M-SEARCH * HTTP/1.1\r\n"
            + "HOST: 239.255.255.250:1900\r\n"
            + "MAN: \"ssdp:discover\"\r\n"
            + "MX: \(maxWait)\r\n"
            + "ST: \(target)\r\n"
            + "USER-AGENT: \(CastHTTPIdentity.userAgent)\r\n"
            + "\r\n"
    }

    /// Sends an M-SEARCH for each target and gathers responses until `timeout`. Blocking: call
    /// it off the main actor.
    static func search(targets: [String], timeout: Double = 3) -> [SSDPResponse] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var ttl: UInt8 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var loop: UInt8 = 0
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, socklen_t(MemoryLayout<UInt8>.size))
        // Send from the primary LAN interface when there's one (otherwise the default route).
        if let local = LANAddress.primaryIPv4(), var interface = inAddr(local) {
            setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &interface, socklen_t(MemoryLayout<in_addr>.size))
        }

        var bindAddress = sockaddr_in()
        bindAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bindAddress.sin_family = sa_family_t(AF_INET)
        bindAddress.sin_port = 0
        bindAddress.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &bindAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return [] }

        var group = sockaddr_in()
        group.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        group.sin_family = sa_family_t(AF_INET)
        group.sin_port = in_port_t(1900).bigEndian
        group.sin_addr = inAddr("239.255.255.250") ?? in_addr()

        // UDP is lossy: each request goes out twice.
        for _ in 0..<2 {
            for target in targets {
                let message = Array(searchRequest(target: target).utf8)
                _ = withUnsafePointer(to: &group) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, message, message.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            usleep(100_000)
        }

        var found: [SSDPResponse] = []
        var seen = Set<String>()
        let deadline = Date.now.addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 8192)
        while found.count < 256 {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining, 1) * 1000))
            if ready < 0 { break }
            if ready == 0 { continue }
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLength) }
            }
            guard count > 0 else { continue }
            let senderBytes = withUnsafeBytes(of: from.sin_addr) { [UInt8]($0) }
            guard LANAddress.isLocal(ipv4: senderBytes) else { continue }
            let sender = senderBytes.map(String.init).joined(separator: ".")
            let text = String(decoding: buffer[0..<count], as: UTF8.self)
            guard let response = SSDPResponse.parse(text, sender: sender) else { continue }
            let key = response.uniqueServiceName + "|" + response.location.absoluteString
            if seen.insert(key).inserted { found.append(response) }
        }
        return found
    }

    private static func inAddr(_ dotted: String) -> in_addr? {
        var address = in_addr()
        return inet_pton(AF_INET, dotted, &address) == 1 ? address : nil
    }
}
