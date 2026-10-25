//
//  OpenSubtitlesProvider.swift
//  Ultimate Theater
//
//  Subtitle search and download from OpenSubtitles.com (REST API v1,
//  https://api.opensubtitles.com/api/v1). The household supplies its own API key and,
//  optionally, an OpenSubtitles login for a larger download quota. Only the key, that
//  login, and search terms (title, year, season/episode, IDs, file hash, languages) are sent.
//

import Foundation

// MARK: - Settings

nonisolated struct OpenSubtitlesCredentials: Sendable, Hashable {
    var apiKey: String
    var username: String?
    var password: String?

    var hasLogin: Bool { !(username ?? "").isEmpty && !(password ?? "").isEmpty }
}

/// The OpenSubtitles API key and optional login, kept in the Keychain like the metadata keys.
@Observable
final class OpenSubtitlesSettings {
    static let shared = OpenSubtitlesSettings()

    private enum Account {
        static let apiKey = "opensubtitles"
        static let username = "opensubtitles.username"
        static let password = "opensubtitles.password"
    }

    private(set) var apiKey: String?
    private(set) var username: String?
    private(set) var password: String?

    private init() {
        apiKey = Keychain.string(for: Account.apiKey)
        username = Keychain.string(for: Account.username)
        password = Keychain.string(for: Account.password)
    }

    var hasKey: Bool { !(apiKey ?? "").isEmpty }
    /// Anything saved, which the administrator PIN then protects.
    var hasSavedValues: Bool { hasKey || !(username ?? "").isEmpty || !(password ?? "").isEmpty }

    var credentials: OpenSubtitlesCredentials? {
        guard let apiKey, !apiKey.isEmpty else { return nil }
        return OpenSubtitlesCredentials(apiKey: apiKey, username: username, password: password)
    }

    func setAPIKey(_ value: String) {
        apiKey = Self.store(value, account: Account.apiKey, trimming: true)
    }

    func setUsername(_ value: String) {
        username = Self.store(value, account: Account.username, trimming: true)
    }

    func setPassword(_ value: String) {
        password = Self.store(value, account: Account.password, trimming: false)
    }

    /// Erases the key and login (app reset).
    func reset() {
        setAPIKey("")
        setUsername("")
        setPassword("")
        Task { await OpenSubtitlesClient.shared.signOut() }
    }

    private static func store(_ value: String, account: String, trimming: Bool) -> String? {
        let stored = trimming ? value.trimmingCharacters(in: .whitespacesAndNewlines) : value
        Keychain.set(stored.isEmpty ? nil : stored, for: account)
        return stored.isEmpty ? nil : stored
    }
}

// MARK: - Search types

/// What to look for. IDs are preferred over a text query when known.
nonisolated struct SubtitleSearchQuery: Sendable, Hashable {
    var title: String
    var year: Int?
    var isEpisode = false
    var season: Int?
    var episode: Int?
    /// Numeric IMDb ID of the movie, or of the show for episodes.
    var imdbID: Int?
    /// TMDB ID of the movie, or of the show for episodes.
    var tmdbID: Int?
    var movieHash: String?
    /// OpenSubtitles language codes ("en", "pt-br").
    var languages: [String] = []

    /// "tt0133093" → 133093.
    static func numericIMDbID(_ text: String?) -> Int? {
        guard let text else { return nil }
        let digits = text.lowercased().replacingOccurrences(of: "tt", with: "")
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let value = Int(digits), value > 0 else { return nil }
        return value
    }
}

nonisolated struct SubtitleSearchResult: Identifiable, Hashable, Sendable {
    let id: String
    let fileID: Int
    let release: String
    let languageCode: String
    let downloadCount: Int
    let isHearingImpaired: Bool
    let isForeignPartsOnly: Bool
    let isMachineTranslated: Bool
    let isFromTrusted: Bool
    /// Found by the file's hash, so it's timed for exactly this file.
    let matchesFile: Bool
    let featureTitle: String?
    let uploadDate: Date?
}

nonisolated enum OpenSubtitlesError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidAPIKey(String?)
    case loginFailed
    case loginRequired
    case rateLimited(retryAfter: Int?)
    case quotaExceeded(String?)
    case rejected(String)
    case offline
    case serverUnavailable
    case http(status: Int, message: String?)
    case badResponse
    case notASubtitle

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add an OpenSubtitles API key in Settings → Metadata to search for subtitles."
        case .invalidAPIKey(let message):
            "OpenSubtitles rejected the API key\(message.map { " (\($0))" } ?? ""). Check it in Settings → Metadata."
        case .loginFailed:
            "OpenSubtitles didn't accept the username or password. Check them in Settings → Metadata."
        case .loginRequired:
            "OpenSubtitles needs you to sign in to download more subtitles today. Add your OpenSubtitles username and password in Settings → Metadata."
        case .rateLimited(let seconds):
            "OpenSubtitles is receiving too many requests. Try again in \(seconds.map { "\(max($0, 1)) seconds" } ?? "a moment")."
        case .quotaExceeded(let message):
            message ?? "You've reached today's OpenSubtitles download limit."
        case .rejected(let message):
            "OpenSubtitles refused the request: \(message)"
        case .offline:
            "You're not connected to the internet."
        case .serverUnavailable:
            "OpenSubtitles isn't responding right now. Try again later."
        case .http(let status, let message):
            "OpenSubtitles responded with an error (\(status))\(message.map { ": \($0)" } ?? ".")"
        case .badResponse:
            "OpenSubtitles sent an unexpected response."
        case .notASubtitle:
            "The downloaded file isn't a subtitle this app can read."
        }
    }
}

// MARK: - Client

/// Talks to the OpenSubtitles REST API, respecting its rate limits (5 requests per second,
/// one login per second) and reusing the login token for the session.
actor OpenSubtitlesClient {
    static let shared = OpenSubtitlesClient()

    /// The API requires "AppName vVersion".
    static let userAgent = "Ultimate Theater v1.0"
    private static let defaultHost = "api.opensubtitles.com"
    private static let allowedHosts: Set<String> = ["api.opensubtitles.com", "vip-api.opensubtitles.com"]
    private static let maximumDownloadSize = SubtitleFileParser.maximumFileSize

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = ["User-Agent": OpenSubtitlesClient.userAgent]
        // Redirects stay on HTTPS, and the API key and login token never follow one to another host.
        return URLSession(configuration: configuration, delegate: RedirectGuard.shared, delegateQueue: nil)
    }()

    private struct Login {
        let username: String
        let token: String
        let host: String
    }

    private var login: Login?
    /// Credentials that failed to log in; the API asks clients not to retry them.
    private var rejectedLogin: OpenSubtitlesCredentials?
    private var lastRequest: ContinuousClock.Instant?
    private var lastLogin: ContinuousClock.Instant?

    func signOut() {
        login = nil
        rejectedLogin = nil
    }

    // MARK: Public

    /// Searches, preferring the file hash and IDs; falls back to the title if IDs find nothing.
    func search(_ query: SubtitleSearchQuery, credentials: OpenSubtitlesCredentials) async throws -> [SubtitleSearchResult] {
        var results = try await searchRequest(Self.parameters(for: query, useIDs: true), credentials: credentials)
        if results.isEmpty, query.imdbID != nil || query.tmdbID != nil {
            results = try await searchRequest(Self.parameters(for: query, useIDs: false), credentials: credentials)
        }
        var seen = Set<Int>()
        return results.filter { seen.insert($0.fileID).inserted }.sorted { lhs, rhs in
            if lhs.matchesFile != rhs.matchesFile { return lhs.matchesFile }
            if lhs.isMachineTranslated != rhs.isMachineTranslated { return !lhs.isMachineTranslated }
            return lhs.downloadCount > rhs.downloadCount
        }
    }

    /// Requests a download link, then fetches and validates the subtitle text.
    func download(_ result: SubtitleSearchResult, credentials: OpenSubtitlesCredentials) async throws -> (text: String, remaining: Int?) {
        if credentials.hasLogin, login?.username != credentials.username {
            try await signIn(credentials)
        }
        let body = try JSONSerialization.data(withJSONObject: ["file_id": result.fileID])
        let response: DownloadResponse
        do {
            response = try await send(path: "/download", method: "POST", body: body, credentials: credentials, as: DownloadResponse.self)
        } catch OpenSubtitlesError.invalidAPIKey(let message) where login != nil {
            // An expired login token: sign in again once.
            login = nil
            guard credentials.hasLogin else { throw OpenSubtitlesError.invalidAPIKey(message) }
            try await signIn(credentials)
            response = try await send(path: "/download", method: "POST", body: body, credentials: credentials, as: DownloadResponse.self)
        }
        guard let link = response.link.flatMap(URL.init(string:)), link.scheme?.lowercased() == "https" else {
            throw OpenSubtitlesError.badResponse
        }
        let data = try await fetchFile(link)
        guard let text = SubtitleFileParser.decodeText(data), !SubtitleFileParser.parse(text: text).isEmpty else {
            throw OpenSubtitlesError.notASubtitle
        }
        return (text, response.remaining)
    }

    /// Checks the key (and login, if given). Returns a short status for Settings.
    func check(_ credentials: OpenSubtitlesCredentials) async throws -> String {
        if credentials.hasLogin {
            login = nil
            rejectedLogin = nil
            let user = try await signIn(credentials)
            if let allowed = user?.allowedDownloads {
                return "Signed in · \(allowed) downloads a day"
            }
            return "Signed in"
        }
        _ = try await send(path: "/infos/formats", credentials: credentials, as: IgnoredResponse.self)
        return "Connected"
    }

    // MARK: Requests

    /// Query parameters as the API prefers them: no defaults, lowercase values, IDs without "tt"
    /// or leading zeros. (Sorting happens when the URL is built.)
    static func parameters(for query: SubtitleSearchQuery, useIDs: Bool) -> [(String, String)] {
        var items: [(String, String)] = []
        let languages = Set(query.languages.map { $0.lowercased() }).sorted()
        if !languages.isEmpty { items.append(("languages", languages.joined(separator: ","))) }
        if let hash = query.movieHash, hash.count == 16, hash.allSatisfy(\.isHexDigit) {
            items.append(("moviehash", hash.lowercased()))
        }
        let hasID = useIDs && (query.imdbID != nil || query.tmdbID != nil)
        if query.isEpisode {
            if hasID {
                if let imdb = query.imdbID { items.append(("parent_imdb_id", String(imdb))) }
                else if let tmdb = query.tmdbID { items.append(("parent_tmdb_id", String(tmdb))) }
            } else {
                items.append(("query", query.title))
                items.append(("type", "episode"))
            }
            if let season = query.season { items.append(("season_number", String(season))) }
            if let episode = query.episode { items.append(("episode_number", String(episode))) }
        } else if hasID {
            if let imdb = query.imdbID { items.append(("imdb_id", String(imdb))) }
            else if let tmdb = query.tmdbID { items.append(("tmdb_id", String(tmdb))) }
        } else {
            items.append(("query", query.title))
            items.append(("type", "movie"))
            if let year = query.year { items.append(("year", String(year))) }
        }
        return items
    }

    /// Sorted, lowercased, with "+" for spaces, so the API needn't redirect.
    static func encodedQuery(_ items: [(String, String)]) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~,")
        return items.sorted { $0.0 < $1.0 }.map { name, value in
            let encoded = value.lowercased().addingPercentEncoding(withAllowedCharacters: allowed.union(.init(charactersIn: " "))) ?? ""
            return "\(name)=\(encoded.replacingOccurrences(of: " ", with: "+"))"
        }.joined(separator: "&")
    }

    private func searchRequest(_ items: [(String, String)], credentials: OpenSubtitlesCredentials) async throws -> [SubtitleSearchResult] {
        let response = try await send(path: "/subtitles", query: items, credentials: credentials, as: SearchResponse.self)
        return (response.data ?? []).compactMap(Self.result(from:))
    }

    private static func result(from item: SearchResponse.Item) -> SubtitleSearchResult? {
        guard let attributes = item.attributes, let files = attributes.files, files.count == 1,
              let fileID = files[0].fileID else { return nil } // Multi-CD sets aren't supported.
        let release = attributes.release.flatMap { $0.isEmpty ? nil : $0 } ?? files[0].fileName ?? "Subtitle"
        return SubtitleSearchResult(
            id: item.id ?? String(fileID),
            fileID: fileID,
            release: String(release.prefix(200)),
            languageCode: attributes.language ?? "und",
            downloadCount: attributes.downloadCount ?? 0,
            isHearingImpaired: attributes.hearingImpaired ?? false,
            isForeignPartsOnly: attributes.foreignPartsOnly ?? false,
            isMachineTranslated: (attributes.machineTranslated ?? false) || (attributes.aiTranslated ?? false),
            isFromTrusted: attributes.fromTrusted ?? false,
            matchesFile: attributes.moviehashMatch ?? false,
            featureTitle: attributes.featureDetails?.movieName ?? attributes.featureDetails?.title,
            uploadDate: attributes.uploadDate.flatMap { try? Date($0, strategy: .iso8601) }
        )
    }

    @discardableResult
    private func signIn(_ credentials: OpenSubtitlesCredentials) async throws -> LoginResponse.User? {
        guard let username = credentials.username, let password = credentials.password, credentials.hasLogin else { return nil }
        if rejectedLogin == credentials { throw OpenSubtitlesError.loginFailed }
        // Login is limited to one request per second.
        if let lastLogin, ContinuousClock.now - lastLogin < .seconds(1) {
            try await Task.sleep(until: lastLogin + .seconds(1))
        }
        lastLogin = .now
        let body = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])
        let response: LoginResponse
        do {
            response = try await send(path: "/login", method: "POST", body: body, credentials: credentials,
                                      authorized: false, as: LoginResponse.self)
        } catch OpenSubtitlesError.invalidAPIKey, OpenSubtitlesError.http(status: 400, message: _) {
            rejectedLogin = credentials
            throw OpenSubtitlesError.loginFailed
        }
        guard let token = response.token, !token.isEmpty else { throw OpenSubtitlesError.badResponse }
        let host = response.baseURL.map { $0.lowercased() }.flatMap { Self.allowedHosts.contains($0) ? $0 : nil } ?? Self.defaultHost
        login = Login(username: username, token: token, host: host)
        return response.user
    }

    private func send<T: Decodable>(path: String, method: String = "GET", query: [(String, String)] = [], body: Data? = nil,
                                    credentials: OpenSubtitlesCredentials, authorized: Bool = true,
                                    as type: T.Type, retrying: Bool = true) async throws -> T {
        guard !credentials.apiKey.isEmpty else { throw OpenSubtitlesError.missingAPIKey }
        var components = URLComponents()
        components.scheme = "https"
        components.host = login?.host ?? Self.defaultHost
        components.path = "/api/v1" + path
        if !query.isEmpty { components.percentEncodedQuery = Self.encodedQuery(query) }
        guard let url = components.url else { throw OpenSubtitlesError.badResponse }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(credentials.apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authorized, let token = login?.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        try await throttle()
        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else { throw OpenSubtitlesError.badResponse }
        let message = Self.message(in: data)
        switch http.statusCode {
        case 200..<300:
            break
        case 401:
            throw OpenSubtitlesError.invalidAPIKey(message)
        case 403:
            if message?.localizedCaseInsensitiveContains("api") == true || message?.localizedCaseInsensitiveContains("key") == true {
                throw OpenSubtitlesError.invalidAPIKey(message)
            }
            throw OpenSubtitlesError.rejected(message ?? "Access denied.")
        case 406, 407:
            if path == "/download" {
                throw login == nil && !credentials.hasLogin ? OpenSubtitlesError.loginRequired : OpenSubtitlesError.quotaExceeded(message)
            }
            throw OpenSubtitlesError.http(status: http.statusCode, message: message)
        case 429:
            let wait = Self.retryAfter(http)
            if retrying, let wait, wait <= 2 {
                try await Task.sleep(for: .seconds(max(wait, 1)))
                return try await send(path: path, method: method, query: query, body: body, credentials: credentials,
                                      authorized: authorized, as: type, retrying: false)
            }
            throw OpenSubtitlesError.rateLimited(retryAfter: wait)
        case 500..<600:
            throw OpenSubtitlesError.serverUnavailable
        default:
            throw OpenSubtitlesError.http(status: http.statusCode, message: message)
        }
        guard data.count <= 4 << 20 else { throw OpenSubtitlesError.badResponse }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw OpenSubtitlesError.badResponse
        }
    }

    /// Fetches the temporary download link (no API key or token sent), capped in size.
    private func fetchFile(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw Self.mapped(error)
        }
        guard let http = response as? HTTPURLResponse else { throw OpenSubtitlesError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw http.statusCode >= 500 ? OpenSubtitlesError.serverUnavailable : OpenSubtitlesError.http(status: http.statusCode, message: nil)
        }
        if http.expectedContentLength > Int64(Self.maximumDownloadSize) { throw SubtitleFileError.tooLarge }
        var data = Data()
        data.reserveCapacity(Int(max(http.expectedContentLength, 0)))
        for try await byte in bytes {
            data.append(byte)
            if data.count > Self.maximumDownloadSize { throw SubtitleFileError.tooLarge }
        }
        return data
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw Self.mapped(error)
        }
    }

    private static func mapped(_ error: Error) -> Error {
        guard let error = error as? URLError else { return error }
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return OpenSubtitlesError.offline
        case .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: return OpenSubtitlesError.serverUnavailable
        default: return error
        }
    }

    /// Keeps under the free tier's 5 requests per second.
    private func throttle() async throws {
        if let lastRequest {
            let next = lastRequest + .milliseconds(250)
            if ContinuousClock.now < next { try await Task.sleep(until: next) }
        }
        lastRequest = .now
    }

    private static func retryAfter(_ response: HTTPURLResponse) -> Int? {
        for field in ["Retry-After", "ratelimit-reset", "x-ratelimit-reset"] {
            if let value = response.value(forHTTPHeaderField: field).flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
                return value
            }
        }
        return nil
    }

    /// The API's own error text, shortened and stripped of anything odd.
    private static func message(in data: Data) -> String? {
        guard data.count < 64 << 10,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let text = (object["message"] as? String)
            ?? (object["errors"] as? [String])?.joined(separator: " ")
            ?? (object["error"] as? String)
        guard let text else { return nil }
        let clean = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : String(clean.prefix(200))
    }

    // MARK: DTOs

    private struct IgnoredResponse: Decodable {}

    private struct LoginResponse: Decodable {
        struct User: Decodable {
            let allowedDownloads: Int?
            enum CodingKeys: String, CodingKey { case allowedDownloads = "allowed_downloads" }
        }

        let user: User?
        let token: String?
        let baseURL: String?

        enum CodingKeys: String, CodingKey {
            case user, token
            case baseURL = "base_url"
        }
    }

    private struct DownloadResponse: Decodable {
        let link: String?
        let remaining: Int?
    }

    private struct SearchResponse: Decodable {
        struct Item: Decodable {
            let id: String?
            let attributes: Attributes?
        }

        struct Attributes: Decodable {
            let language: String?
            let downloadCount: Int?
            let hearingImpaired: Bool?
            let foreignPartsOnly: Bool?
            let machineTranslated: Bool?
            let aiTranslated: Bool?
            let fromTrusted: Bool?
            let moviehashMatch: Bool?
            let release: String?
            let uploadDate: String?
            let featureDetails: FeatureDetails?
            let files: [File]?

            enum CodingKeys: String, CodingKey {
                case language, release, files
                case downloadCount = "download_count"
                case hearingImpaired = "hearing_impaired"
                case foreignPartsOnly = "foreign_parts_only"
                case machineTranslated = "machine_translated"
                case aiTranslated = "ai_translated"
                case fromTrusted = "from_trusted"
                case moviehashMatch = "moviehash_match"
                case uploadDate = "upload_date"
                case featureDetails = "feature_details"
            }
        }

        struct FeatureDetails: Decodable {
            let title: String?
            let movieName: String?
            enum CodingKeys: String, CodingKey {
                case title
                case movieName = "movie_name"
            }
        }

        struct File: Decodable {
            let fileID: Int?
            let fileName: String?
            enum CodingKeys: String, CodingKey {
                case fileID = "file_id"
                case fileName = "file_name"
            }
        }

        let data: [Item]?
    }
}

// MARK: - Languages

nonisolated enum SubtitleLanguages {
    /// Languages offered in the search sheet, as OpenSubtitles codes.
    static let codes = [
        "ar", "bg", "ca", "cs", "da", "de", "el", "en", "es", "et", "eu", "fa", "fi", "fr", "he", "hi", "hr", "hu",
        "id", "is", "it", "ja", "ko", "lt", "lv", "ms", "nl", "no", "pl", "pt-br", "pt-pt", "ro", "ru", "sk", "sl",
        "sr", "sv", "th", "tr", "uk", "vi", "zh-cn", "zh-tw",
    ]

    static func name(_ code: String) -> String {
        switch code.lowercased() {
        case "pt-br": return "Portuguese (Brazil)"
        case "pt-pt": return "Portuguese (Portugal)"
        case "zh-cn": return "Chinese (Simplified)"
        case "zh-tw": return "Chinese (Traditional)"
        default:
            return Locale.current.localizedString(forLanguageCode: code) ?? code
        }
    }

    /// The OpenSubtitles code closest to a BCP 47 language ("en-US" → "en", "pt-BR" → "pt-br").
    static func code(forPreferred identifier: String) -> String? {
        let language = Locale.Language(identifier: identifier)
        guard let base = language.languageCode?.identifier.lowercased() else { return nil }
        switch base {
        case "pt": return language.region?.identifier == "PT" ? "pt-pt" : "pt-br"
        case "zh":
            let traditional = language.script?.identifier == "Hant" || ["TW", "HK", "MO"].contains(language.region?.identifier ?? "")
            return traditional ? "zh-tw" : "zh-cn"
        case "nb", "nn": return "no"
        default: return codes.contains(base) ? base : nil
        }
    }

    /// The code to store with a download: OpenSubtitles "pt-br" → BCP 47 "pt-BR".
    static func bcp47(_ code: String) -> String {
        let parts = code.split(separator: "-", maxSplits: 1)
        guard parts.count == 2 else { return code.lowercased() }
        return "\(parts[0].lowercased())-\(parts[1].uppercased())"
    }
}
