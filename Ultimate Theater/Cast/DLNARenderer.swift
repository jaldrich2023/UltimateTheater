//
//  DLNARenderer.swift
//  Ultimate Theater
//
//  UPnP AV MediaRenderer control (UPnP Device Architecture 1.1, AVTransport:1,
//  RenderingControl:1, ConnectionManager:1), as used by DLNA TVs and players:
//  1. The device description (the SSDP LOCATION) lists the renderer's services and their
//     control URLs.
//  2. Each action is a SOAP 1.1 POST to the service's control URL with a SOAPACTION header.
//  3. Playback: SetAVTransportURI (the media URL plus DIDL-Lite metadata naming the title,
//     artwork, and protocolInfo), then Play; Pause, Stop, and Seek (REL_TIME) control it, and
//     GetPositionInfo / GetTransportInfo are polled for progress.
//  Every reply is size-capped, time-limited, and parsed without DTDs or external entities.
//

import Foundation

// MARK: - Device description

nonisolated struct UPnPService: Hashable, Sendable {
    var serviceType: String
    var controlURL: URL
}

nonisolated struct UPnPRendererDescription: Hashable, Sendable {
    var friendlyName: String?
    var manufacturer: String?
    var modelName: String?
    var udn: String?
    var avTransport: UPnPService?
    var renderingControl: UPnPService?
    var connectionManager: UPnPService?

    /// Parses a device description. Control URLs are resolved against URLBase (or the
    /// description's own URL) and must stay on the device's own host.
    static func parse(_ data: Data, location: URL) -> UPnPRendererDescription? {
        guard data.count <= FlatXMLReader.maximumSize, !XMLSafety.hasDoctype(data),
              let deviceHost = LANAddress.localHost(of: location) else { return nil }
        let collector = DescriptionCollector()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = collector
        guard parser.parse(), !collector.devices.isEmpty else { return nil }

        let base = collector.urlBase.flatMap { URL(string: $0) } ?? location
        func resolve(_ text: String) -> URL? {
            guard !text.isEmpty, let url = URL(string: text, relativeTo: base)?.absoluteURL,
                  LANAddress.localHost(of: url) == deviceHost else { return nil }
            return url
        }
        // The renderer itself, or the root device when none says it's a MediaRenderer.
        let renderer = collector.devices.first { $0.deviceType.contains("MediaRenderer") } ?? collector.devices[0]
        var description = UPnPRendererDescription(friendlyName: renderer.friendlyName, manufacturer: renderer.manufacturer,
                                                  modelName: renderer.modelName, udn: renderer.udn)
        // Prefer the renderer's own services, then any device's.
        let services = renderer.services + collector.devices.flatMap(\.services)
        for service in services {
            guard let url = resolve(service.controlURL) else { continue }
            let found = UPnPService(serviceType: service.serviceType, controlURL: url)
            if service.serviceType.hasPrefix("urn:schemas-upnp-org:service:AVTransport:"), description.avTransport == nil {
                description.avTransport = found
            } else if service.serviceType.hasPrefix("urn:schemas-upnp-org:service:RenderingControl:"), description.renderingControl == nil {
                description.renderingControl = found
            } else if service.serviceType.hasPrefix("urn:schemas-upnp-org:service:ConnectionManager:"), description.connectionManager == nil {
                description.connectionManager = found
            }
        }
        return description
    }

    private final class DescriptionCollector: NSObject, XMLParserDelegate {
        struct Device {
            var deviceType = ""
            var friendlyName: String?
            var manufacturer: String?
            var modelName: String?
            var udn: String?
            var services: [(serviceType: String, controlURL: String)] = []
        }

        var urlBase: String?
        private(set) var devices: [Device] = []
        private var stack: [Device] = []
        private var service: (type: String, control: String)?
        private var text = ""
        private var depth = 0

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            depth += 1
            guard depth < 48, devices.count + stack.count < 32 else { parser.abortParsing(); return }
            text = ""
            switch XMLSafety.localName(elementName) {
            case "device": stack.append(Device())
            case "service": service = ("", "")
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if text.count < 4096 { text += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            depth -= 1
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = ""
            switch XMLSafety.localName(elementName) {
            case "URLBase": urlBase = value
            case "serviceType": service?.type = value
            case "controlURL": service?.control = value
            case "service":
                if let service, !stack.isEmpty, stack[stack.count - 1].services.count < 16 {
                    stack[stack.count - 1].services.append((service.type, service.control))
                }
                service = nil
            case "device":
                if let device = stack.popLast() { devices.append(device) }
            default:
                guard service == nil, !stack.isEmpty else { break }
                let index = stack.count - 1
                switch XMLSafety.localName(elementName) {
                case "deviceType": stack[index].deviceType = value
                case "friendlyName": stack[index].friendlyName = value
                case "manufacturer": stack[index].manufacturer = value
                case "modelName": stack[index].modelName = value
                case "UDN": stack[index].udn = value
                default: break
                }
            }
        }
    }
}

// MARK: - SOAP

nonisolated enum UPnPSOAP {
    static func envelope(action: String, serviceType: String, arguments: [(String, String)]) -> String {
        let body = arguments.map { "<\($0.0)>\(XMLSafety.escape($0.1))</\($0.0)>" }.joined()
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
            + "<s:Body><u:\(action) xmlns:u=\"\(XMLSafety.escape(serviceType))\">\(body)</u:\(action)></s:Body></s:Envelope>"
    }

    static func soapAction(action: String, serviceType: String) -> String {
        "\"\(serviceType)#\(action)\""
    }
}

nonisolated enum DLNAError: Error, LocalizedError, Equatable {
    case fault(code: String?, description: String?)
    case noService

    var errorDescription: String? {
        switch self {
        case .fault(let code, let description):
            "The TV refused the request\(description.map { " (\($0))" } ?? code.map { " (error \($0))" } ?? "")."
        case .noService: "This device can't be controlled for playback."
        }
    }
}

/// One SOAP action against a UPnP service.
nonisolated enum DLNAControl {
    static func invoke(_ service: UPnPService, _ action: String, _ arguments: [(String, String)] = [("InstanceID", "0")],
                       timeout: Double = 6) async throws -> [String: String] {
        let body = Data(UPnPSOAP.envelope(action: action, serviceType: service.serviceType, arguments: arguments).utf8)
        let reply = try await LANHTTP.send(method: "POST", url: service.controlURL, headers: [
            "Content-Type": "text/xml; charset=\"utf-8\"",
            "SOAPACTION": UPnPSOAP.soapAction(action: action, serviceType: service.serviceType),
        ], body: body, timeout: timeout, maxBody: 128 * 1024)
        let values = FlatXMLReader.read(reply.body)?.values ?? [:]
        guard reply.status == 200 else {
            throw DLNAError.fault(code: values["errorCode"], description: values["errorDescription"])
        }
        return values
    }

    /// The renderer's accepted protocols (Sink), split into entries.
    static func protocolInfo(_ manager: UPnPService) async throws -> [String] {
        let values = try await invoke(manager, "GetProtocolInfo", [], timeout: 4)
        return (values["Sink"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.prefix(400).map { $0 }
    }
}

// MARK: - DIDL-Lite and time

nonisolated enum DIDLLite {
    /// The metadata sent with SetAVTransportURI: an item with its title, artwork, and one
    /// resource with the protocolInfo the renderer should expect.
    static func metadata(title: String, mediaURL: URL, mimeType: String, size: Int64?, duration: Double?,
                         artworkURL: URL?, isEpisode: Bool) -> String {
        let protocolInfo = "http-get:*:\(mimeType):\(CastCompatibility.dlnaFeatures)"
        var resAttributes = " protocolInfo=\"\(XMLSafety.escape(protocolInfo))\""
        if let size, size > 0 { resAttributes += " size=\"\(size)\"" }
        if let duration, duration > 0 { resAttributes += " duration=\"\(UPnPTime.format(duration)).000\"" }
        var item = "<dc:title>\(XMLSafety.escape(title))</dc:title>"
        item += "<upnp:class>\(isEpisode ? "object.item.videoItem" : "object.item.videoItem.movie")</upnp:class>"
        if let artworkURL { item += "<upnp:albumArtURI>\(XMLSafety.escape(artworkURL.absoluteString))</upnp:albumArtURI>" }
        item += "<res\(resAttributes)>\(XMLSafety.escape(mediaURL.absoluteString))</res>"
        return "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" "
            + "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" xmlns:dlna=\"urn:schemas-dlna-org:metadata-1-0/\">"
            + "<item id=\"0\" parentID=\"-1\" restricted=\"1\">\(item)</item></DIDL-Lite>"
    }
}

nonisolated enum UPnPTime {
    /// "H:MM:SS" (hours unpadded, as AVTransport expects).
    static func format(_ seconds: Double) -> String {
        let total = seconds.isFinite ? Int(min(max(seconds, 0), 359_999)) : 0
        return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    /// Parses "H+:MM:SS[.F+]" (and "MM:SS"); nil for "NOT_IMPLEMENTED" and the like.
    static func parse(_ text: String?) -> Double? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty, text.count <= 24 else { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var total: Double = 0
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            let value: Double?
            if isLast {
                // Seconds may carry a fraction, either decimal (".500") or F0/F1 ("1/2").
                let secondsText = part.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
                guard !secondsText.isEmpty, secondsText.allSatisfy(\.isNumber), let whole = Double(secondsText) else { return nil }
                let fraction = part.split(separator: ".", maxSplits: 1).dropFirst().first.flatMap { Double("0." + $0) } ?? 0
                value = whole + (fraction.isFinite ? fraction : 0)
            } else {
                guard !part.isEmpty, part.allSatisfy(\.isNumber), let whole = Double(part) else { return nil }
                value = whole
            }
            guard let value else { return nil }
            total = total * 60 + value
        }
        return total
    }
}

// MARK: - Client

/// Drives one DLNA renderer.
final class DLNARendererClient: CastRendererClient {
    let device: CastDevice
    private let transport: UPnPService
    private let rendering: UPnPService?
    private var polls = 0
    private var lastVolume: Float?

    init(device: CastDevice) throws {
        guard let renderer = device.renderer, let transport = renderer.avTransport else { throw DLNAError.noService }
        self.device = device
        self.transport = transport
        self.rendering = renderer.renderingControl
    }

    var capabilities: CastCapabilities {
        CastCapabilities(canSeek: true, volume: rendering == nil ? .none : .absolute)
    }

    var mediaHost: String? { device.host.flatMap { LANAddress.localIPv4(toward: $0) } }

    func connect() async throws {
        // Nothing to open: each action is its own HTTP request. Check the TV answers.
        _ = try await DLNAControl.invoke(transport, "GetTransportInfo", timeout: 5)
    }

    func load(_ request: CastLoadRequest) async throws {
        let mime = CastCompatibility.dlnaMIMEType(request.profile, sink: device.sinkProtocols) ?? request.contentType
        let metadata = DIDLLite.metadata(title: request.displayTitle, mediaURL: request.mediaURL, mimeType: mime,
                                         size: request.fileSize, duration: request.duration, artworkURL: request.artworkURL,
                                         isEpisode: request.isEpisode)
        // Many TVs only take a new URI once stopped.
        _ = try? await DLNAControl.invoke(transport, "Stop", timeout: 4)
        _ = try await DLNAControl.invoke(transport, "SetAVTransportURI", [
            ("InstanceID", "0"), ("CurrentURI", request.mediaURL.absoluteString), ("CurrentURIMetaData", metadata),
        ], timeout: 10)
        _ = try await DLNAControl.invoke(transport, "Play", [("InstanceID", "0"), ("Speed", "1")], timeout: 10)
        guard request.startTime > 3 else { return }
        // Seeking is refused until playback has actually started.
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(500))
            let info = try? await DLNAControl.invoke(transport, "GetTransportInfo", timeout: 3)
            if info?["CurrentTransportState"] == "PLAYING" { break }
        }
        try? await seek(to: request.startTime)
    }

    func play() async throws {
        _ = try await DLNAControl.invoke(transport, "Play", [("InstanceID", "0"), ("Speed", "1")])
    }

    func pause() async throws {
        _ = try await DLNAControl.invoke(transport, "Pause")
    }

    func seek(to seconds: Double) async throws {
        _ = try await DLNAControl.invoke(transport, "Seek", [("InstanceID", "0"), ("Unit", "REL_TIME"), ("Target", UPnPTime.format(seconds))])
    }

    func setVolume(_ level: Float) async throws {
        guard let rendering else { return }
        let value = Int((min(max(level, 0), 1) * 100).rounded())
        _ = try await DLNAControl.invoke(rendering, "SetVolume", [("InstanceID", "0"), ("Channel", "Master"), ("DesiredVolume", "\(value)")])
        lastVolume = Float(value) / 100
    }

    func stop() async {
        _ = try? await DLNAControl.invoke(transport, "Stop", timeout: 4)
    }

    func status() async throws -> CastPlaybackStatus {
        polls += 1
        let info = try await DLNAControl.invoke(transport, "GetTransportInfo", timeout: 4)
        let position = try? await DLNAControl.invoke(transport, "GetPositionInfo", timeout: 4)
        if let rendering, polls % 5 == 1,
           let reply = try? await DLNAControl.invoke(rendering, "GetVolume", [("InstanceID", "0"), ("Channel", "Master")], timeout: 3),
           let current = reply["CurrentVolume"].flatMap(Int.init) {
            lastVolume = Float(min(max(current, 0), 100)) / 100
        }
        return Self.status(transport: info, position: position, volume: lastVolume)
    }

    nonisolated static func status(transport info: [String: String], position: [String: String]?, volume: Float?) -> CastPlaybackStatus {
        let state: CastPlaybackStatus.State
        if info["CurrentTransportStatus"] == "ERROR_OCCURRED" {
            state = .failed("The TV couldn't play the video.")
        } else {
            switch info["CurrentTransportState"] ?? "" {
            case "PLAYING": state = .playing
            case "PAUSED_PLAYBACK", "PAUSED_RECORDING": state = .paused
            case "TRANSITIONING": state = .buffering
            case "STOPPED", "NO_MEDIA_PRESENT": state = .stopped
            default: state = .buffering
            }
        }
        let duration = UPnPTime.parse(position?["TrackDuration"]).flatMap { $0 > 0 ? $0 : nil }
        return CastPlaybackStatus(state: state, position: UPnPTime.parse(position?["RelTime"]), duration: duration, volume: volume)
    }

    func disconnect() {}
}
