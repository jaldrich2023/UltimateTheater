//
//  SubtitleSearchView.swift
//  Ultimate Theater
//
//  "Find Subtitles…": searches OpenSubtitles for a movie or episode and saves the chosen
//  subtitle as an extra subtitle track for that file. Also the OpenSubtitles section
//  of Settings.
//

import SwiftUI

/// The movie or episode subtitles are being found for.
struct SubtitleSearchTarget: Identifiable, Hashable {
    let item: PlaybackItem
    let query: SubtitleSearchQuery

    var id: String { item.id }
    var playbackID: String { item.id }

    var displayName: String {
        guard let episode = item.episode else { return item.title.name }
        return "\(item.title.name) · \(episode.code) · \(episode.name)"
    }

    init(item: PlaybackItem, library: MediaLibrary) {
        self.item = item
        let stored = library.item(for: item.title.id)
        query = SubtitleSearchQuery(
            title: item.title.name,
            year: item.title.year,
            isEpisode: item.episode != nil,
            season: item.episode?.season,
            episode: item.episode?.number,
            imdbID: SubtitleSearchQuery.numericIMDbID(stored?.imdbID),
            tmdbID: item.title.tmdbID
        )
    }
}

struct SubtitleSearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    let target: SubtitleSearchTarget
    /// Called with the saved subtitle, which the caller then selects.
    var onDownloaded: (ExternalSubtitle) -> Void

    private enum Phase: Equatable {
        case idle
        case searching
        case results
        case failed(String)
    }

    @State private var language = "en"
    @State private var phase = Phase.idle
    @State private var results: [SubtitleSearchResult] = []
    @State private var movieHash: String?
    @State private var didHash = false
    @State private var downloadingID: String?
    @State private var downloadError: String?

    private var settings: OpenSubtitlesSettings { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "captions.bubble.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 52, height: 52)
                    .glassEffect(.regular, in: .rect(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Find Subtitles")
                        .font(.title2.bold())
                    Text(target.displayName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if settings.hasKey {
                HStack(spacing: 10) {
                    Picker("Language", selection: $language) {
                        ForEach(SubtitleLanguages.codes, id: \.self) { code in
                            Text(SubtitleLanguages.name(code)).tag(code)
                        }
                    }
                    .frame(maxWidth: 280)
                    .onChange(of: language) { search() }
                    Spacer()
                    Button("Search Again", systemImage: "arrow.clockwise") { search() }
                        .buttonStyle(.theaterGlass)
                        .disabled(phase == .searching || downloadingID != nil)
                }
                content
                    .frame(maxWidth: .infinity, minHeight: 260, maxHeight: 360, alignment: .top)
            } else {
                missingKey
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            }

            if let downloadError {
                Label(downloadError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("Subtitles from OpenSubtitles.com")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.theaterGlass)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(28)
        .frame(width: 620)
        .task {
            let preferred = preferredLanguage()
            if preferred != language {
                language = preferred // Searches through onChange.
            } else {
                search()
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle, .searching:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(didHash || movieHash != nil ? "Searching OpenSubtitles…" : "Reading the file…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Search", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        case .results where results.isEmpty:
            ContentUnavailableView {
                Label("No Subtitles Found", systemImage: "captions.bubble")
            } description: {
                Text("OpenSubtitles has no \(SubtitleLanguages.name(language)) subtitles for this \(target.query.isEpisode ? "episode" : "movie"). Try another language.")
            }
        case .results:
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(results) { result in
                        row(result)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.automatic)
        }
    }

    private func row(_ result: SubtitleSearchResult) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(result.release)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(result.release)
                HStack(spacing: 8) {
                    Text(SubtitleLanguages.name(result.languageCode))
                    Label("\(result.downloadCount.formatted()) downloads", systemImage: "arrow.down.circle")
                    if result.isHearingImpaired {
                        badge("SDH", systemImage: "ear", color: .blue)
                            .help("For the deaf and hard of hearing: includes sound descriptions")
                    }
                    if result.isForeignPartsOnly {
                        badge("Forced", systemImage: "globe", color: .purple)
                            .help("Only foreign-language dialogue")
                    }
                    if result.isMachineTranslated {
                        badge("Machine translated", systemImage: "cpu", color: .gray)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                if result.matchesFile {
                    badge("Matches this file", systemImage: "checkmark.seal.fill", color: .green)
                        .font(.caption)
                        .help("Found by this file's fingerprint, so its timing should line up exactly")
                }
            }
            Spacer(minLength: 8)
            if downloadingID == result.id {
                ProgressView().controlSize(.small)
                    .frame(width: 110)
            } else {
                Button("Download") { download(result) }
                    .buttonStyle(PlayButtonStyle())
                    .controlSize(.small)
                    .disabled(downloadingID != nil)
            }
        }
        .padding(12)
        .background(.white.opacity(result.matchesFile ? 0.09 : 0.05), in: .rect(cornerRadius: 14))
    }

    private func badge(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.25), in: .capsule)
            .foregroundStyle(.white)
    }

    private var missingKey: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("An OpenSubtitles API key is needed", systemImage: "key.fill")
                .font(.headline)
            Text("Subtitles come from OpenSubtitles.com. Create a free API consumer on opensubtitles.com, then add its key in Settings → Metadata.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Settings") { openSettings() }
                    .buttonStyle(.theaterGlass)
                Link("Get a Key", destination: URL(string: "https://www.opensubtitles.com/consumers")!)
                    .font(.callout.weight(.semibold))
            }
        }
    }

    // MARK: Actions

    /// The viewer's saved subtitle language, else the system language, else English.
    private func preferredLanguage() -> String {
        if let profile = model.profile,
           case .track(let preference)? = model.playbackPreferences.selection(profileID: profile.id, titleID: target.item.title.id)?.subtitles,
           let code = preference.languageCode.flatMap(SubtitleLanguages.code(forPreferred:)) {
            return code
        }
        for identifier in Locale.preferredLanguages {
            if let code = SubtitleLanguages.code(forPreferred: identifier) { return code }
        }
        return "en"
    }

    private func search() {
        guard let credentials = settings.credentials else { return }
        phase = .searching
        downloadError = nil
        let language = language
        Task {
            if !didHash {
                let playbackID = target.playbackID
                movieHash = await model.library.withFileAccess(playbackID) { url in
                    await Task.detached { try? OpenSubtitlesHash.compute(url: url) }.value
                } ?? nil
                didHash = true
            }
            var query = target.query
            query.movieHash = movieHash
            query.languages = [language]
            do {
                let found = try await OpenSubtitlesClient.shared.search(query, credentials: credentials)
                guard language == self.language else { return } // A newer search is under way.
                results = found
                phase = .results
            } catch {
                guard language == self.language else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func download(_ result: SubtitleSearchResult) {
        guard let credentials = settings.credentials else { return }
        downloadingID = result.id
        downloadError = nil
        let playbackID = target.playbackID
        Task {
            do {
                let (text, _) = try await OpenSubtitlesClient.shared.download(result, credentials: credentials)
                let subtitle = try await Task.detached {
                    try ExternalSubtitleLibrary.save(
                        text: text, format: text.hasPrefix("WEBVTT") ? "vtt" : "srt", playbackID: playbackID,
                        languageCode: SubtitleLanguages.bcp47(result.languageCode), release: result.release,
                        isSDH: result.isHearingImpaired, isForced: result.isForeignPartsOnly,
                        openSubtitlesFileID: result.fileID)
                }.value
                downloadingID = nil
                onDownloaded(subtitle)
                dismiss()
            } catch {
                downloadingID = nil
                downloadError = error.localizedDescription
            }
        }
    }
}

// MARK: - Settings

/// The OpenSubtitles key and optional login, locked behind the administrator PIN once saved.
struct OpenSubtitlesSettingsSection: View {
    @State private var apiKey = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isChecking = false
    @State private var checkResult: (success: Bool, message: String)?
    @State private var isUnlocked = false
    @State private var pinRequest: PINRequest?

    private var settings: OpenSubtitlesSettings { .shared }

    private var isLocked: Bool {
        settings.hasSavedValues && AdministratorPIN.isSet && !isUnlocked
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Text("OpenSubtitles")
                    .font(.headline)
                Text("Finds and downloads subtitles for movies and episodes that have none. A free key allows a few downloads a day; signing in with an OpenSubtitles account raises the limit.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if isLocked {
                HStack {
                    Label(settings.hasKey ? "Key saved  ••••\(String((settings.apiKey ?? "").suffix(4)))" : "Login saved",
                          systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                    if let username = settings.username {
                        Text("· \(username)").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Change…") {
                        pinRequest = PINRequest(title: "Administrator PIN", message: "Enter the administrator PIN to change the OpenSubtitles settings.",
                                                profile: nil, kind: .verify(AdministratorPIN.verify)) { _ in
                            isUnlocked = true
                        }
                    }
                }
            } else {
                SecureField("API Key", text: $apiKey, prompt: Text("API key"))
                    .onChange(of: apiKey) { _, value in
                        settings.setAPIKey(value)
                        checkResult = nil
                    }
                TextField("Username", text: $username, prompt: Text("Optional"))
                    .textContentType(.username)
                    .onChange(of: username) { _, value in
                        settings.setUsername(value)
                        checkResult = nil
                    }
                SecureField("Password", text: $password, prompt: Text("Optional"))
                    .textContentType(.password)
                    .onChange(of: password) { _, value in
                        settings.setPassword(value)
                        checkResult = nil
                    }
            }

            HStack {
                Link(settings.hasKey ? "Manage Key" : "Get a Free Key", destination: URL(string: "https://www.opensubtitles.com/consumers")!)
                Spacer()
                if let checkResult {
                    Label(checkResult.message, systemImage: checkResult.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(checkResult.success ? .green : .orange)
                        .font(.callout)
                        .lineLimit(2)
                }
                Button {
                    runCheck()
                } label: {
                    if isChecking { ProgressView().controlSize(.small) } else { Text("Check") }
                }
                .disabled(isChecking || !settings.hasKey)
            }
        } footer: {
            Text("Subtitles are provided by OpenSubtitles.com under its terms of service. Only your key, your OpenSubtitles login, and what's being searched for (title, year, episode, and a fingerprint of the file) are sent.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            apiKey = settings.apiKey ?? ""
            username = settings.username ?? ""
            password = settings.password ?? ""
        }
        .sheet(item: $pinRequest) { request in
            PINPadView(request: request) { pinRequest = nil }
        }
    }

    private func runCheck() {
        guard let credentials = settings.credentials else { return }
        isChecking = true
        Task {
            do {
                let message = try await OpenSubtitlesClient.shared.check(credentials)
                checkResult = (true, message)
            } catch {
                checkResult = (false, error.localizedDescription)
            }
            isChecking = false
        }
    }
}
