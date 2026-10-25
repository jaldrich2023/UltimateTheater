//
//  Roku.swift
//  Ultimate Theater
//
//  Roku's External Control Protocol (ECP): plain HTTP on port 8060.
//  • POST /input/15985?t=v&u=<url>&videoName=…&videoFormat=… opens the URL in Roku's
//    built-in media player ("Play on Roku", channel 15985).
//  • POST /keypress/<key> presses a remote button (Play toggles play/pause; Home leaves).
//  • GET /query/media-player reports the player's state and position (milliseconds).
//  • GET /query/device-info names the device.
//
//  Limitations of ECP, shown in the player:
//  • There's no seek and no start position: the video starts from the beginning and the
//    Roku remote is used to scan. Positions are still read back, so "Watch on This Mac"
//    resumes where the Roku was.
//  • Volume is only up/down/mute key presses, and only on Roku TVs (or when the Roku
//    controls the TV over HDMI-CEC).
//  • Newer Roku OS versions can turn off "Control by mobile apps" (Settings › System ›
//    Advanced system settings), which blocks ECP entirely, or limit it to some commands.
//

import Foundation

nonisolated enum RokuECP {
    /// Roku's built-in "Play on Roku" media player channel.
    static let mediaPlayerChannel = "15985"

    struct DeviceInfo: Sendable, Equatable {
        var name: String?
        var model: String?
    }

    struct PlayerState: Sendable, Equatable {
        var state: String
        var isError: Bool
        var position: Double?
        var duration: Double?
    }

    /// The characters left unescaped in ECP query values (RFC 3986 unreserved).
    private static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    static func base(host: String, port: UInt16) -> String {
        host.contains(":") ? "http://[\(host)]:\(port)" : "http://\(host):\(port)"
    }

    /// The ECP request that plays a URL in the Roku media player.
    static func playURL(host: String, port: UInt16 = 8060, media: URL, title: String, format: String, artwork: URL?) -> URL? {
        var query = "t=v&u=\(encode(media.absoluteString))&videoName=\(encode(title))&videoFormat=\(encode(format))"
        if let artwork { query += "&k=\(encode(artwork.absoluteString))" }
        return URL(string: "\(base(host: host, port: port))/input/\(mediaPlayerChannel)?\(query)")
    }

    static func keypressURL(host: String, port: UInt16 = 8060, key: String) -> URL? {
        guard key.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return URL(string: "\(base(host: host, port: port))/keypress/\(key)")
    }

    /// ECP's videoFormat values for the containers it plays.
    static func videoFormat(for container: CastContainer) -> String {
        switch container {
        case .matroska: "mkv"
        case .mov: "mov"
        default: "mp4"
        }
    }

    static func parsePlayer(_ data: Data) -> PlayerState? {
        guard let reader = FlatXMLReader.read(data), let player = reader.attributes["player"] else { return nil }
        func milliseconds(_ text: String?) -> Double? {
            guard let digits = text?.prefix(while: \.isNumber), !digits.isEmpty, digits.count < 12, let value = Double(digits) else { return nil }
            return value / 1000
        }
        return PlayerState(state: player["state"]?.lowercased() ?? "none", isError: player["error"]?.lowercased() == "true",
                           position: milliseconds(reader.values["position"]), duration: milliseconds(reader.values["duration"]))
    }

    static func parseDeviceInfo(_ data: Data) -> DeviceInfo? {
        guard let reader = FlatXMLReader.read(data) else { return nil }
        let values = reader.values
        let name = [values["user-device-name"], values["friendly-device-name"], values["default-device-name"]]
            .compactMap { $0 }.first { !$0.isEmpty }
        let model = [values["friendly-model-name"], values["model-name"]].compactMap { $0 }.first { !$0.isEmpty }
        return DeviceInfo(name: name, model: model)
    }

    static func deviceInfo(host: String, port: UInt16) async -> DeviceInfo? {
        guard let url = URL(string: "\(base(host: host, port: port))/query/device-info"),
              let reply = try? await LANHTTP.send(method: "GET", url: url, timeout: 4), reply.status == 200 else { return nil }
        return parseDeviceInfo(reply.body)
    }

    static func state(_ player: PlayerState) -> CastPlaybackStatus.State {
        if player.isError { return .failed("The Roku couldn't play the video.") }
        switch player.state {
        case "play": return .playing
        case "pause": return .paused
        case "buffer", "startup", "open": return .buffering
        default: return .stopped // "close", "stop", "none"
        }
    }
}

enum RokuError: Error, LocalizedError {
    case refused(Int)
    case unreachable

    var errorDescription: String? {
        switch self {
        case .refused(403): "The Roku refused the request. Turn on Settings › System › Advanced system settings › Control by mobile apps on the Roku."
        case .refused(let status): "The Roku refused the request (HTTP \(status))."
        case .unreachable: "The Roku couldn't be reached."
        }
    }
}

/// Drives one Roku through ECP.
final class RokuClient: CastRendererClient {
    let device: CastDevice
    private let host: String
    private let port: UInt16
    private var lastState: CastPlaybackStatus.State = .idle

    init(device: CastDevice) throws {
        guard let host = device.host else { throw RokuError.unreachable }
        self.device = device
        self.host = host
        self.port = device.port ?? 8060
    }

    var capabilities: CastCapabilities { CastCapabilities(canSeek: false, volume: .steps) }

    var mediaHost: String? { LANAddress.localIPv4(toward: host) }

    func connect() async throws {
        guard let url = URL(string: "\(RokuECP.base(host: host, port: port))/query/device-info") else { throw RokuError.unreachable }
        let reply = try await LANHTTP.send(method: "GET", url: url, timeout: 5)
        guard reply.status == 200 else { throw RokuError.refused(reply.status) }
    }

    func load(_ request: CastLoadRequest) async throws {
        guard let url = RokuECP.playURL(host: host, port: port, media: request.mediaURL, title: request.displayTitle,
                                        format: RokuECP.videoFormat(for: request.profile.container), artwork: request.artworkURL) else {
            throw RokuError.unreachable
        }
        try await post(url)
        lastState = .buffering
    }

    private func post(_ url: URL) async throws {
        let reply = try await LANHTTP.send(method: "POST", url: url, timeout: 6)
        guard (200..<300).contains(reply.status) else { throw RokuError.refused(reply.status) }
    }

    private func press(_ key: String) async throws {
        guard let url = RokuECP.keypressURL(host: host, port: port, key: key) else { return }
        try await post(url)
    }

    // Play is a toggle on the Roku remote, so it's only pressed when it changes something.
    func play() async throws {
        guard lastState == .paused else { return }
        try await press("Play")
        lastState = .playing
    }

    func pause() async throws {
        guard lastState == .playing || lastState == .buffering else { return }
        try await press("Play")
        lastState = .paused
    }

    func seek(to seconds: Double) async throws {}

    func setVolume(_ level: Float) async throws {}

    func stepVolume(up: Bool) async throws {
        try await press(up ? "VolumeUp" : "VolumeDown")
    }

    func stop() async {
        try? await press("Home")
    }

    func status() async throws -> CastPlaybackStatus {
        guard let url = URL(string: "\(RokuECP.base(host: host, port: port))/query/media-player") else { throw RokuError.unreachable }
        let reply = try await LANHTTP.send(method: "GET", url: url, timeout: 4)
        guard reply.status == 200, let player = RokuECP.parsePlayer(reply.body) else { throw RokuError.refused(reply.status) }
        let state = RokuECP.state(player)
        lastState = state
        return CastPlaybackStatus(state: state, position: player.position, duration: player.duration, volume: nil)
    }

    func disconnect() {}
}
