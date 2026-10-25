//
//  CastDevice.swift
//  Ultimate Theater
//
//  The casting devices on the network and how they're found:
//  • Google Cast (Chromecast, Google TV, Nest displays, TVs with Cast built in) advertise
//    `_googlecast._tcp` over Bonjour; the TXT record carries the name (fn) and model (md).
//  • DLNA / UPnP AV renderers (most Samsung, LG, Sony, Panasonic, and Philips TVs, Xbox,
//    many receivers, and Fire TV or Roku apps that act as renderers) answer SSDP searches
//    for urn:schemas-upnp-org:device:MediaRenderer:1.
//  • Roku players and TVs answer SSDP searches for roku:ecp.
//  Apple TV is reached through AirPlay, which the player handles separately.
//

import Foundation
import Network

nonisolated enum CastDeviceKind: String, Sendable, CaseIterable, Hashable {
    case googleCast
    case dlna
    case roku

    var groupName: String {
        switch self {
        case .googleCast: "Google Cast"
        case .dlna: "Smart TVs & Media Players (DLNA)"
        case .roku: "Roku"
        }
    }

    var symbol: String {
        switch self {
        case .googleCast: "tv.badge.wifi"
        case .dlna: "tv"
        case .roku: "tv.and.mediabox"
        }
    }
}

nonisolated struct CastDevice: Identifiable, Hashable, Sendable {
    let id: String
    let kind: CastDeviceKind
    var name: String
    var model: String?
    var manufacturer: String?
    /// Google Cast: the Bonjour service to connect to.
    var serviceName: String?
    var serviceDomain: String?
    /// DLNA and Roku: the device's IP address and port.
    var host: String?
    var port: UInt16?
    /// DLNA: the renderer's services.
    var renderer: UPnPRendererDescription?
    /// DLNA: what the renderer says it accepts (ConnectionManager GetProtocolInfo Sink).
    var sinkProtocols: [String]?
    var lastSeen = Date.now

    /// "Living Room TV" plus the model when it adds something.
    var detail: String? {
        let parts = [manufacturer, model].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != name }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// Settings › Playback › Casting.
enum CastSettings {
    static let discoveryKey = "castDiscoveryEnabled"
    /// Set once the Cast menu has been opened (and Local Network access asked for), after which
    /// discovery starts as soon as a player opens, so devices are already listed on the first click.
    static let hasSearchedKey = "castDiscoveryHasSearched"

    static var isDiscoveryEnabled: Bool {
        UserDefaults.standard.object(forKey: discoveryKey) as? Bool ?? true
    }
}

/// Finds casting devices while a player is open (and discovery is on in Settings).
@Observable
final class CastDiscovery {
    static let shared = CastDiscovery()

    private(set) var devices: [CastDevice] = []
    private(set) var isSearching = false

    @ObservationIgnored private var users = 0
    /// Discovery starts the first time the Cast menu is opened (which is also when macOS asks
    /// for Local Network permission), then runs whenever a player is open.
    @ObservationIgnored private var isRequested = UserDefaults.standard.bool(forKey: CastSettings.hasSearchedKey)
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var searchLoop: Task<Void, Never>?
    @ObservationIgnored private var refreshRequested = false
    /// Searches in a row that found nothing, for the quick-retry backoff (2, 4, 8, 16, then 30 s).
    @ObservationIgnored private var emptyRounds = 0
    @ObservationIgnored private var googleCast: [String: CastDevice] = [:]
    @ObservationIgnored private var found: [String: CastDevice] = [:]
    /// Description URLs that failed recently, so a broken device isn't fetched every round.
    @ObservationIgnored private var failures: [String: Date] = [:]

    /// SSDP devices not heard from for this long are dropped.
    static let expiry: TimeInterval = 180
    static let searchInterval: TimeInterval = 30

    func begin() {
        users += 1
        if users == 1 { applySetting() }
    }

    func end() {
        users = max(users - 1, 0)
        if users == 0 { halt() }
    }

    /// Searches again now (the Cast menu's Refresh, or after the setting changes).
    func refresh() {
        isRequested = true
        UserDefaults.standard.set(true, forKey: CastSettings.hasSearchedKey)
        refreshRequested = true
        applySetting()
    }

    /// Starts or stops discovery to match Settings.
    func applySetting() {
        guard users > 0, isRequested, CastSettings.isDiscoveryEnabled else {
            halt()
            return
        }
        if browser == nil { startBrowser() }
        if searchLoop == nil { startSearchLoop() }
    }

    private func halt() {
        browser?.cancel()
        browser = nil
        searchLoop?.cancel()
        searchLoop = nil
        isSearching = false
        googleCast = [:]
        found = [:]
        publish()
    }

    private func publish() {
        let all = Array(googleCast.values) + Array(found.values)
        let sorted = all.sorted { ($0.kind.rawValue, $0.name.localizedLowercase) < ($1.kind.rawValue, $1.name.localizedLowercase) }
        if sorted != devices { devices = sorted }
    }

    // MARK: Google Cast (Bonjour)

    private struct BonjourCast: Sendable {
        var name: String
        var domain: String
        var friendlyName: String?
        var model: String?
        var id: String?
    }

    private func startBrowser() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let services: [BonjourCast] = results.compactMap { result in
                guard case .service(let name, _, let domain, _) = result.endpoint else { return nil }
                var service = BonjourCast(name: name, domain: domain)
                if case .bonjour(let txt) = result.metadata {
                    service.friendlyName = txt["fn"]
                    service.model = txt["md"]
                    service.id = txt["id"]
                }
                return service
            }
            Task { @MainActor in self?.updateGoogleCast(services) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { @MainActor in self?.browser = nil } }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    private func updateGoogleCast(_ services: [BonjourCast]) {
        guard browser != nil else { return }
        var next: [String: CastDevice] = [:]
        for service in services {
            let id = "cast:" + (service.id?.lowercased() ?? service.name)
            let name = Self.clean(service.friendlyName) ?? Self.clean(service.name) ?? "Google Cast device"
            next[id] = CastDevice(id: id, kind: .googleCast, name: name, model: Self.clean(service.model),
                                  serviceName: service.name, serviceDomain: service.domain)
        }
        googleCast = next
        publish()
    }

    // MARK: DLNA and Roku (SSDP)

    private func startSearchLoop() {
        searchLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                isSearching = true
                let responses = await Task.detached(priority: .utility) {
                    SSDP.search(targets: [SSDP.mediaRenderer, SSDP.roku], timeout: 3)
                }.value
                guard !Task.isCancelled else { return }
                await process(responses)
                expire()
                isSearching = false
                refreshRequested = false
                // A Bonjour browser that failed (for example while the Local Network prompt
                // was up) is started again.
                if browser == nil { startBrowser() }
                // Until something is found, search again soon: the first search often goes
                // out while macOS is still asking for Local Network access, and is lost.
                let interval: TimeInterval
                if devices.isEmpty {
                    interval = min(2 * pow(2, Double(emptyRounds)), Self.searchInterval)
                    emptyRounds += 1
                } else {
                    interval = Self.searchInterval
                    emptyRounds = 0
                }
                var waited: TimeInterval = 0
                while waited < interval, !refreshRequested, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    waited += 0.5
                }
            }
        }
    }

    private func process(_ responses: [SSDPResponse]) async {
        var toDescribe: [(key: String, response: SSDPResponse)] = []
        for response in responses {
            let isRoku = response.searchTarget.lowercased() == SSDP.roku
            let key = (isRoku ? "roku:" : "dlna:") + (response.deviceUUID ?? response.location.absoluteString)
            if var known = found[key], known.host == response.sender {
                known.lastSeen = .now
                found[key] = known
                continue
            }
            if let failed = failures[response.location.absoluteString], Date.now.timeIntervalSince(failed) < 300 { continue }
            if !toDescribe.contains(where: { $0.key == key }) { toDescribe.append((key, response)) }
        }
        let batch = Array(toDescribe.prefix(16))
        let described = await withTaskGroup(of: (String, String, CastDevice?).self) { group in
            for (key, response) in batch {
                group.addTask {
                    let isRoku = key.hasPrefix("roku:")
                    let device = isRoku ? await Self.describeRoku(key: key, response: response)
                                        : await Self.describeRenderer(key: key, response: response)
                    return (key, response.location.absoluteString, device)
                }
            }
            var results: [(String, String, CastDevice?)] = []
            for await result in group { results.append(result) }
            return results
        }
        for (key, location, device) in described {
            if let device { found[key] = device } else { failures[location] = .now }
        }
        publish()
    }

    private func expire() {
        let cutoff = Date.now.addingTimeInterval(-Self.expiry)
        found = found.filter { $0.value.lastSeen >= cutoff }
        if failures.count > 200 { failures = [:] }
        publish()
    }

    nonisolated private static func describeRenderer(key: String, response: SSDPResponse) async -> CastDevice? {
        guard let reply = try? await LANHTTP.send(method: "GET", url: response.location, timeout: 5),
              reply.status == 200,
              let description = UPnPRendererDescription.parse(reply.body, location: response.location),
              description.avTransport != nil else { return nil }
        var sink: [String]?
        if let manager = description.connectionManager {
            sink = try? await DLNAControl.protocolInfo(manager)
        }
        return CastDevice(id: key, kind: .dlna, name: clean(description.friendlyName) ?? "TV (\(response.sender))",
                          model: clean(description.modelName), manufacturer: clean(description.manufacturer),
                          host: response.sender, port: UInt16(clamping: response.location.port ?? 80),
                          renderer: description, sinkProtocols: sink)
    }

    nonisolated private static func describeRoku(key: String, response: SSDPResponse) async -> CastDevice? {
        let port = UInt16(clamping: response.location.port ?? 8060)
        let info = await RokuECP.deviceInfo(host: response.sender, port: port)
        return CastDevice(id: key, kind: .roku, name: clean(info?.name) ?? "Roku (\(response.sender))",
                          model: clean(info?.model), manufacturer: "Roku", host: response.sender, port: port)
    }

    /// Device-supplied names, trimmed and limited to something displayable.
    nonisolated static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let printable = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
        let trimmed = printable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(80))
    }
}
