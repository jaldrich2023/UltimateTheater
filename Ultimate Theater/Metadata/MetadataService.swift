//
//  MetadataService.swift
//  Ultimate Theater
//
//  Queries every enabled source in parallel, picks the best match from each,
//  lines them up on a shared IMDb ID, and merges them field by field with TMDB
//  taking priority.
//

import Foundation
import Security

// MARK: - Matching

nonisolated enum MetadataMatcher {
    /// Confidence (0…1+) that a candidate is the title described by the query.
    static func score(_ candidate: MetadataCandidate, for query: MetadataQuery) -> Double {
        guard candidate.kind == query.kind else { return 0 }
        let wanted = FilenameParser.normalizedKey(query.title)
        let found = FilenameParser.normalizedKey(candidate.title)
        guard !wanted.isEmpty, !found.isEmpty else { return 0 }

        var score: Double
        if wanted == found {
            // Exact wording (including "The") edges out article-only differences.
            score = query.title.lowercased() == candidate.title.lowercased() ? 1.05 : 1
        } else if found.hasPrefix(wanted) || wanted.hasPrefix(found) {
            score = 0.8
        } else {
            score = 0.85 * tokenSimilarity(query.title, candidate.title)
        }

        if let wantedYear = query.year, let foundYear = candidate.year {
            switch abs(wantedYear - foundYear) {
            case 0: score += 0.2
            case 1: score += 0.1
            default: score -= 0.35
            }
        }
        return score
    }

    static let threshold = 0.6

    static func best(_ candidates: [MetadataCandidate], for query: MetadataQuery) -> MetadataCandidate? {
        candidates
            .map { ($0, score($0, for: query)) }
            .filter { $0.1 >= threshold }
            .max { $0.1 < $1.1 }?.0
    }

    private static func tokenSimilarity(_ a: String, _ b: String) -> Double {
        func tokens(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0 != "the" && $0 != "a" })
        }
        let lhs = tokens(a), rhs = tokens(b)
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(lhs.union(rhs).count)
    }
}

// MARK: - Merging

nonisolated enum MetadataMerger {
    /// Field-level source priority. TMDB leads everywhere except content ratings,
    /// where OMDb's MPAA data is more complete.
    private static let general: [MetadataProviderID] = [.tmdb, .tvmaze, .omdb, .wikipedia]
    private static let synopsis: [MetadataProviderID] = [.tmdb, .tvmaze, .wikipedia, .omdb]
    private static let maturity: [MetadataProviderID] = [.omdb, .tmdb]
    private static let runtime: [MetadataProviderID] = [.tmdb, .omdb, .tvmaze]
    private static let director: [MetadataProviderID] = [.tmdb, .omdb, .wikipedia]
    private static let episodes: [MetadataProviderID] = [.tmdb, .tvmaze]

    static func merge(_ records: [MetadataRecord]) -> MergedMetadata? {
        guard !records.isEmpty else { return nil }
        let byProvider = Dictionary(records.map { ($0.provider, $0) }, uniquingKeysWith: { first, _ in first })

        func pick<T>(_ order: [MetadataProviderID], _ value: (MetadataRecord) -> T?) -> T? {
            for provider in order {
                if let record = byProvider[provider], let found = value(record) { return found }
            }
            return nil
        }
        func pickList(_ order: [MetadataProviderID], _ value: (MetadataRecord) -> [String]) -> [String] {
            pick(order) { record in
                let list = value(record)
                return list.isEmpty ? nil : list
            } ?? []
        }

        var merged = MetadataRecord(provider: pick(general) { $0.provider } ?? records[0].provider)
        merged.title = pick(general) { $0.title }
        merged.year = pick(general) { $0.year }
        merged.synopsis = pick(synopsis) { $0.synopsis }
        merged.tagline = pick([.tmdb]) { $0.tagline }
        merged.maturity = pick(maturity) { $0.maturity }
        merged.certifications = byProvider[.tmdb]?.certifications ?? [:]
        if merged.certifications["US"] == nil, let us = byProvider[.omdb]?.maturity { merged.certifications["US"] = us }
        merged.runtimeMinutes = pick(runtime) { $0.runtimeMinutes }
        merged.genres = pickList(general) { $0.genres }
        merged.cast = pickList(general) { $0.cast }
        merged.director = pick(director) { $0.director }
        merged.writers = pickList([.tmdb, .omdb]) { $0.writers }
        merged.studios = pickList([.tmdb, .tvmaze, .omdb]) { $0.studios }
        merged.trailer = pick([.tmdb]) { $0.trailer }
        merged.collection = pick([.tmdb]) { $0.collection }
        merged.posterURL = pick(general) { $0.posterURL }
        merged.backdropURL = pick(general) { $0.backdropURL }
        merged.tmdbID = pick(general) { $0.tmdbID }
        merged.imdbID = pick(general) { $0.imdbID }
        merged.tvmazeID = pick(general) { $0.tvmazeID }
        merged.wikipediaKey = pick(general) { $0.wikipediaKey }
        merged.episodes = pick(episodes) { $0.episodes.isEmpty ? nil : $0.episodes } ?? []

        // Keep one score per rating source, in a stable display order.
        var ratings: [RatingSource: ExternalRating] = [:]
        for rating in records.flatMap(\.ratings) where ratings[rating.source] == nil {
            ratings[rating.source] = rating
        }
        merged.ratings = RatingSource.allCases.compactMap { ratings[$0] }

        let sources = MetadataProviderID.allCases.filter { byProvider[$0] != nil }
        return MergedMetadata(record: merged, sources: sources)
    }
}

// MARK: - Service

final class MetadataService {
    let settings: MetadataSettings

    init(settings: MetadataSettings) {
        if !AppEnvironment.isRunningTests { HTTPClient.purgeLegacyKeyedCacheIfNeeded() }
        self.settings = settings
    }

    /// Enabled, configured providers for a kind, in priority order.
    func providers(for kind: TitleKind) -> [any MetadataProvider] {
        MetadataProviderID.allCases.compactMap { id -> (any MetadataProvider)? in
            guard settings.isActive(id), id.supports(kind) else { return nil }
            switch id {
            case .tmdb: return TMDBProvider(apiKey: settings.apiKey(for: .tmdb) ?? "")
            case .omdb: return OMDbProvider(apiKey: settings.apiKey(for: .omdb) ?? "")
            case .tvmaze: return TVmazeProvider()
            case .wikipedia: return WikipediaProvider()
            }
        }
    }

    /// Searches every source at once, for Fix Match. Errors are reported per source.
    func searchAll(_ query: MetadataQuery) async -> (candidates: [MetadataCandidate], errors: [MetadataProviderID: String]) {
        let providers = providers(for: query.kind)
        var candidates: [MetadataProviderID: [MetadataCandidate]] = [:]
        var errors: [MetadataProviderID: String] = [:]

        await withTaskGroup(of: (MetadataProviderID, Result<[MetadataCandidate], Error>).self) { group in
            for provider in providers {
                group.addTask {
                    do { return (provider.id, .success(try await provider.search(query))) }
                    catch { return (provider.id, .failure(error)) }
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(let found): candidates[id] = found
                case .failure(let error): errors[id] = error.localizedDescription
                }
            }
        }

        // Best matches first; ties broken by source priority.
        let ordered = MetadataProviderID.allCases.flatMap { candidates[$0] ?? [] }
        let ranked = ordered.enumerated().sorted { lhs, rhs in
            let l = MetadataMatcher.score(lhs.element, for: query), r = MetadataMatcher.score(rhs.element, for: query)
            return abs(l - r) > 0.001 ? l > r : lhs.offset < rhs.offset
        }
        return (ranked.map(\.element), errors)
    }

    /// Automatic identification: best match from each source, aligned and merged.
    func identify(_ query: MetadataQuery) async -> MergedMetadata? {
        let providers = providers(for: query.kind)
        var records = await withTaskGroup(of: MetadataRecord?.self) { group -> [MetadataRecord] in
            for provider in providers {
                group.addTask {
                    guard let results = try? await provider.search(query),
                          let match = MetadataMatcher.best(results, for: query) else { return nil }
                    return try? await provider.details(for: match, query: query)
                }
            }
            var found: [MetadataRecord] = []
            for await record in group {
                if let record { found.append(record) }
            }
            return found
        }
        records = await align(records, providers: providers, query: query)
        return MetadataMerger.merge(records)
    }

    /// Uses the title the user picked in Fix Match, then enriches it from the other sources.
    func metadata(for candidate: MetadataCandidate, query: MetadataQuery) async throws -> MergedMetadata? {
        let providers = providers(for: query.kind)
        guard let chosenProvider = providers.first(where: { $0.id == candidate.provider }) else { return nil }
        let chosen = try await chosenProvider.details(for: candidate, query: query)

        var refined = query
        refined.title = chosen.title ?? candidate.title
        refined.year = chosen.year ?? candidate.year

        var records = [chosen]
        if let imdbID = chosen.imdbID {
            records += await lookupAll(imdbID: imdbID, providers: providers.filter { $0.id != candidate.provider }, query: refined)
        } else if let tmdb = providers.first(where: { $0.id == .tmdb }), candidate.provider != .tmdb,
                  let results = try? await tmdb.search(refined),
                  let match = MetadataMatcher.best(results, for: refined),
                  let record = try? await tmdb.details(for: match, query: refined) {
            // No IMDb ID (e.g. Wikipedia): find the TMDB entry by title, then everything else from it.
            records.append(record)
            if let imdbID = record.imdbID {
                records += await lookupAll(imdbID: imdbID, providers: providers.filter { $0.id != candidate.provider && $0.id != .tmdb }, query: refined)
            }
        }
        // The user's pick wins over any automatically found duplicate from the same source.
        return MetadataMerger.merge(records)
    }

    /// Refreshes an already-identified title directly by its IMDb ID.
    func refresh(imdbID: String, query: MetadataQuery) async -> MergedMetadata? {
        let providers = providers(for: query.kind).filter { $0.id != .wikipedia }
        return MetadataMerger.merge(await lookupAll(imdbID: imdbID, providers: providers, query: query))
    }

    /// Verifies the connection and key for one source.
    func test(_ id: MetadataProviderID) async -> String? {
        let provider: any MetadataProvider = switch id {
        case .tmdb: TMDBProvider(apiKey: settings.apiKey(for: .tmdb) ?? "")
        case .omdb: OMDbProvider(apiKey: settings.apiKey(for: .omdb) ?? "")
        case .tvmaze: TVmazeProvider()
        case .wikipedia: WikipediaProvider()
        }
        let query = MetadataQuery(title: id == .tvmaze ? "Breaking Bad" : "Inception", year: nil,
                                  kind: id == .tvmaze ? .series : .movie)
        do {
            let results = try await provider.search(query)
            return results.isEmpty ? "Connected, but the test search returned no results." : nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Alignment

    /// Once any source reports an IMDb ID, re-fetch sources that matched something else
    /// (or nothing) by that ID, so every field describes the same title.
    private func align(_ records: [MetadataRecord], providers: [any MetadataProvider], query: MetadataQuery) async -> [MetadataRecord] {
        let anchor = MetadataProviderID.allCases.lazy.compactMap { id in records.first { $0.provider == id && $0.imdbID != nil } }.first
        guard let anchor, let imdbID = anchor.imdbID else {
            return records
        }
        let consistent = records.filter { $0.imdbID == nil ? isPlausible($0, against: anchor) : $0.imdbID == imdbID }
        let missing = providers.filter { provider in
            provider.id != .wikipedia && !consistent.contains { $0.provider == provider.id }
        }
        return consistent + (await lookupAll(imdbID: imdbID, providers: missing, query: query))
    }

    private func lookupAll(imdbID: String, providers: [any MetadataProvider], query: MetadataQuery) async -> [MetadataRecord] {
        await withTaskGroup(of: MetadataRecord?.self) { group -> [MetadataRecord] in
            for provider in providers {
                group.addTask { try? await provider.lookup(imdbID: imdbID, query: query) }
            }
            var found: [MetadataRecord] = []
            for await record in group {
                if let record { found.append(record) }
            }
            return found
        }
    }

    /// Records without an IMDb ID (Wikipedia) must agree on title and year.
    private func isPlausible(_ record: MetadataRecord, against anchor: MetadataRecord) -> Bool {
        guard let title = record.title, let anchorTitle = anchor.title else { return false }
        let sameTitle = FilenameParser.normalizedKey(title) == FilenameParser.normalizedKey(anchorTitle)
        let sameYear = record.year == nil || anchor.year == nil || abs((record.year ?? 0) - (anchor.year ?? 0)) <= 1
        return sameTitle && sameYear
    }
}

// MARK: - Settings

/// Which sources are enabled and their API keys (stored in the Keychain).
@Observable
final class MetadataSettings {
    private static let enabledKey = "metadata.enabledProviders"
    private static let autoFetchKey = "metadata.autoFetch"

    var enabledProviders: Set<MetadataProviderID> {
        didSet { defaults.set(enabledProviders.map(\.rawValue), forKey: Self.enabledKey) }
    }

    var autoFetch: Bool {
        didSet { defaults.set(autoFetch, forKey: Self.autoFetchKey) }
    }

    private var keys: [MetadataProviderID: String] = [:]
    /// Where the choices are saved, and where the API keys are kept. Tests pass their own.
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secrets: any SecretStore

    init(defaults: UserDefaults = .standard, secrets: any SecretStore = SystemKeychain()) {
        self.defaults = defaults
        self.secrets = secrets
        if let stored = defaults.stringArray(forKey: Self.enabledKey) {
            enabledProviders = Set(stored.compactMap(MetadataProviderID.init(rawValue:)))
        } else {
            enabledProviders = Set(MetadataProviderID.allCases)
        }
        autoFetch = defaults.object(forKey: Self.autoFetchKey) as? Bool ?? true
        for id in MetadataProviderID.allCases where id.requiresAPIKey {
            keys[id] = try? secrets.read(account: id.rawValue, service: Keychain.apiKeyService)
        }
    }

    func apiKey(for id: MetadataProviderID) -> String? {
        keys[id]
    }

    /// Saves (or with an empty value, removes) a source's key. Returns whether the Keychain
    /// took it; when it didn't, the key in use stays the previous one, so the app never uses
    /// a key that won't be there next launch.
    @discardableResult
    func setAPIKey(_ value: String, for id: MetadataProviderID) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = trimmed.isEmpty ? nil : trimmed
        do {
            try secrets.write(new, account: id.rawValue, service: Keychain.apiKeyService)
        } catch {
            return false
        }
        keys[id] = new
        return true
    }

    /// Back to a fresh installation: every source on, automatic fetching on, no API keys.
    func reset() {
        for id in MetadataProviderID.allCases where id.requiresAPIKey { setAPIKey("", for: id) }
        enabledProviders = Set(MetadataProviderID.allCases)
        autoFetch = true
    }

    func isEnabled(_ id: MetadataProviderID) -> Bool {
        enabledProviders.contains(id)
    }

    func setEnabled(_ enabled: Bool, for id: MetadataProviderID) {
        if enabled { enabledProviders.insert(id) } else { enabledProviders.remove(id) }
    }

    func hasKey(_ id: MetadataProviderID) -> Bool {
        !(keys[id] ?? "").isEmpty
    }

    /// Enabled and, if it needs one, has a key.
    func isActive(_ id: MetadataProviderID) -> Bool {
        isEnabled(id) && (!id.requiresAPIKey || hasKey(id))
    }

    var activeProviders: [MetadataProviderID] {
        MetadataProviderID.allCases.filter(isActive)
    }
}

/// Where secrets (API keys, the administrator PIN's hash) are kept. Reading tells "nothing
/// saved" (`nil`) apart from "couldn't read" (a thrown error), so callers can fail closed.
nonisolated protocol SecretStore: Sendable {
    func read(account: String, service: String) throws -> String?
    /// Saves `value`, or removes the secret when it's `nil`. A failed save leaves any existing
    /// secret as it was.
    func write(_ value: String?, account: String, service: String) throws
}

nonisolated enum KeychainError: LocalizedError, Equatable {
    case unexpectedStatus(OSStatus)
    case unreadableData

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "The Keychain couldn't be used (\(detail))."
        case .unreadableData: return "A Keychain item couldn't be read."
        }
    }
}

/// The login Keychain (generic passwords). Items stay where earlier versions put them.
nonisolated struct SystemKeychain: SecretStore {
    func read(account: String, service: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
                throw KeychainError.unreadableData
            }
            return text
        case errSecItemNotFound: return nil
        default: throw KeychainError.unexpectedStatus(status)
        }
    }

    func write(_ value: String?, account: String, service: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard let value else {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unexpectedStatus(status) }
            return
        }
        let data = Data(value.utf8)
        // Update in place, so a failure never leaves the account without its old secret.
        let updated = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch updated {
        case errSecSuccess: return
        case errSecItemNotFound:
            var item = base
            item[kSecValueData as String] = data
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError.unexpectedStatus(added) }
        default: throw KeychainError.unexpectedStatus(updated)
        }
    }
}

/// Minimal generic-password Keychain wrapper for API keys and PINs.
nonisolated enum Keychain {
    static let apiKeyService = "UltimateTheater.MetadataAPIKeys"

    /// The saved value, or `nil` when there's none or it couldn't be read. Use
    /// `SystemKeychain().read` where a read failure must be told apart (PINs).
    static func string(for account: String, service: String = apiKeyService) -> String? {
        try? SystemKeychain().read(account: account, service: service)
    }

    /// Saves (or with `nil`, removes) a value. Returns whether it worked.
    @discardableResult
    static func set(_ value: String?, for account: String, service: String = apiKeyService) -> Bool {
        (try? SystemKeychain().write(value, account: account, service: service)) != nil
    }
}
