//
//  SettingsView.swift
//  Ultimate Theater
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Metadata", systemImage: "sparkle.magnifyingglass") {
                MetadataSettingsView()
            }
            Tab("Library", systemImage: "externaldrive") {
                LibrarySettingsView()
            }
            Tab("Parental Controls", systemImage: "lock.shield") {
                ParentalControlsView()
            }
        }
        .frame(width: 620, height: 640)
    }
}

private struct MetadataSettingsView: View {
    @Environment(AppModel.self) private var model

    private var settings: MetadataSettings { model.library.metadata.settings }

    var body: some View {
        Form {
            Section {
                Text("Ultimate Theater combines several sources. TMDB is preferred for every field it covers; the others fill in ratings, episode guides, and anything TMDB is missing.")
                    .foregroundStyle(.secondary)
            }
            ForEach(MetadataProviderID.allCases) { provider in
                ProviderSection(provider: provider, settings: settings, service: model.library.metadata)
            }
            Section {
                Toggle("Fetch info automatically when adding media", isOn: Binding(
                    get: { settings.autoFetch }, set: { settings.autoFetch = $0 }
                ))
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Image("TMDBLogo").resizable().scaledToFit().frame(height: 10)
                        .accessibilityLabel("TMDB")
                    Text(DataAttribution.tmdbNotice)
                    Text("TVmaze and Wikipedia content is licensed under CC BY-SA 4.0. OMDb's terms permit personal, non-commercial use.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProviderSection: View {
    let provider: MetadataProviderID
    let settings: MetadataSettings
    let service: MetadataService

    @State private var key = ""
    @State private var isTesting = false
    @State private var testResult: (success: Bool, message: String)?

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { settings.isEnabled(provider) }, set: { settings.setEnabled($0, for: provider) })) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(provider.displayName)
                            .font(.headline)
                        if provider == .tmdb {
                            Text("PRIMARY")
                                .font(.caption2.weight(.heavy))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Theme.accent, in: .capsule)
                                .foregroundStyle(.white)
                        }
                    }
                    Text(provider.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if provider.requiresAPIKey {
                SecureField("API Key", text: $key, prompt: Text(provider == .tmdb ? "API key or read access token" : "API key"))
                    .onChange(of: key) { _, newValue in
                        settings.setAPIKey(newValue, for: provider)
                        testResult = nil
                    }
            }

            HStack {
                if let url = provider.keySignupURL {
                    Link(settings.hasKey(provider) ? "Manage Key" : "Get a Free Key", destination: url)
                }
                Spacer()
                if let testResult {
                    Label(testResult.message, systemImage: testResult.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(testResult.success ? .green : .orange)
                        .font(.callout)
                        .lineLimit(2)
                }
                Button {
                    runTest()
                } label: {
                    if isTesting { ProgressView().controlSize(.small) } else { Text("Test Connection") }
                }
                .disabled(isTesting || (provider.requiresAPIKey && !settings.hasKey(provider)))
            }

            if settings.isEnabled(provider), provider.requiresAPIKey, !settings.hasKey(provider) {
                Label("Add a key to use \(provider.displayName).", systemImage: "key")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .onAppear { key = settings.apiKey(for: provider) ?? "" }
    }

    private func runTest() {
        isTesting = true
        Task {
            let error = await service.test(provider)
            testResult = error.map { (false, $0) } ?? (true, "Connected")
            isTesting = false
        }
    }
}

private struct LibrarySettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var isConfirmingReset = false
    @State private var pinRequest: PINRequest?

    private var library: MediaLibrary { model.library }

    private func databaseRow(_ name: String, url: URL) -> some View {
        LabeledContent(name) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(url.lastPathComponent)
                Text(LibraryStore.size(of: url).formatted(.byteCount(style: .file)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .help(url.path(percentEncoded: false))
    }

    var body: some View {
        Form {
            Section("Watched Folders") {
                if library.folders.isEmpty {
                    Text("Folders you add are listed here and can be rescanned for new videos.")
                        .foregroundStyle(.secondary)
                }
                ForEach(library.folders) { folder in
                    HStack {
                        Label(folder.displayName, systemImage: "folder.fill")
                        Spacer()
                        Text(folder.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 260, alignment: .trailing)
                        Button("Remove") { library.removeFolder(folder) }
                    }
                }
                Toggle("Automatically add new videos from these folders", isOn: Bindable(library).watchesFolders)
                    .help("New files are added and deleted files are removed as soon as they change. Titles on a disconnected drive are kept.")
                HStack {
                    Button("Add Folder…") { model.addMedia() }
                    Button("Rescan All") { Task { await library.rescanFolders() } }
                        .disabled(library.folders.isEmpty || library.isBusy)
                }
            }
            Section {
                LabeledContent("Titles", value: "\(library.titles.count)")
                Button("Refresh All Info") { Task { await library.refreshMetadata(force: true) } }
                    .disabled(library.titles.isEmpty || library.isBusy)
            } header: {
                Text("Metadata")
            } footer: {
                Text("Re-fetches info for every title. Locked titles keep your edits.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("Every file plays with the built-in Theater engine. Containers: MP4, M4V, MOV, 3GP, MKV, WebM, AVI, MPEG-TS and Blu-ray/AVCHD M2TS, MPEG program streams (MPG, VOB), Ogg, FLV, and DV. Video: H.264, HEVC (including HDR10, HLG, and Dolby Vision), AV1, VP9, VP8, Theora, MPEG-1, MPEG-2, MPEG-4 Part 2 (Xvid/DivX), H.263, Apple ProRes, DV, and Motion JPEG. Audio: AAC (including LATM broadcast audio), Apple Lossless, FLAC, Opus, Vorbis, Dolby Digital, Dolby Digital Plus, the Dolby Digital core of TrueHD, DTS (core, including DTS-HD tracks), MP3, MP2, PCM and LPCM, ADPCM, µ-law, A-law, and AMR. Subtitles: SRT, ASS/SSA, MP4 text, Blu-ray PGS, DVD subtitles, DVB subtitles, and Teletext. Files using other formats are added and flagged.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Formats")
            }
            Section {
                databaseRow("Master library", url: LibraryStore.databaseURL)
                databaseRow("Users", url: LibraryStore.usersDatabaseURL)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([LibraryStore.databaseURL, LibraryStore.usersDatabaseURL])
                }
            } header: {
                Text("Databases")
            } footer: {
                Text("Both are SQLite databases. The master library holds titles, episodes, and watched folders; the user database holds profiles, watch progress, My Lists, and ratings.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Reset Ultimate Theater…", role: .destructive) {
                    if AdministratorPIN.isSet {
                        pinRequest = PINRequest(title: "Administrator PIN", message: "Enter the administrator PIN to reset the app.",
                                                profile: nil, kind: .verify(AdministratorPIN.verify)) { _ in
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(350)) // Let the PIN sheet close first.
                                isConfirmingReset = true
                            }
                        }
                    } else {
                        isConfirmingReset = true
                    }
                }
            } header: {
                Text("Reset")
            } footer: {
                Text("Erases the library, every profile, watch history, settings, saved API keys, and caches, and returns the app to its first-launch state. Your movie files aren't touched.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $pinRequest) { request in
            PINPadView(request: request) { pinRequest = nil }
                .padding(20)
        }
        .confirmationDialog("Reset Ultimate Theater?", isPresented: $isConfirmingReset, titleVisibility: .visible) {
            Button("Erase Everything and Reset", role: .destructive) { model.resetEverything() }
        } message: {
            Text("All profiles, the library, watch history, My Lists, ratings, settings, and API keys are erased. This can't be undone. Your movie files stay where they are.")
        }
    }
}

/// The administrator PIN and how profiles are protected.
private struct ParentalControlsView: View {
    @Environment(AppModel.self) private var model
    @State private var hasPIN = AdministratorPIN.isSet
    @State private var pinRequest: PINRequest?

    var body: some View {
        Form {
            Section {
                LabeledContent("Administrator PIN") {
                    Text(hasPIN ? "On" : "Off")
                        .foregroundStyle(hasPIN ? .green : .secondary)
                }
                HStack {
                    Button(hasPIN ? "Change PIN…" : "Set PIN…") {
                        verifyThen { choosePIN() }
                    }
                    if hasPIN {
                        Button("Turn Off…", role: .destructive) {
                            verifyThen {
                                AdministratorPIN.set(nil)
                                hasPIN = false
                            }
                        }
                    }
                }
            } header: {
                Text("Administrator")
            } footer: {
                Text("When set, the administrator PIN is needed to add, edit, or remove profiles, to reset the app, and to leave a profile with a content limit for one with a higher limit. A profile with a limit stays in effect even after logging out, until the PIN is entered.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Ratings country", selection: Bindable(model).ratingsCountry) {
                    ForEach(ContentRating.countries, id: \.code) { country in
                        Text(country.name).tag(country.code)
                    }
                }
                LabeledContent("Limits") {
                    VStack(alignment: .trailing, spacing: 2) {
                        ForEach(RatingLimit.allCases.filter { $0 < .everything }) { limit in
                            Text("\(limit.title): \(limit.allowedRatings(in: model.ratingsCountry).joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Content Ratings")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(RatingNotices.summary)
                    Text(RatingNotices.mpa)
                    Text(RatingNotices.tv)
                }
                .foregroundStyle(.secondary)
            }
            Section("Profiles") {
                if model.profiles.isEmpty {
                    Text("No profiles yet.").foregroundStyle(.secondary)
                }
                ForEach(model.profiles) { profile in
                    HStack(spacing: 10) {
                        ProfileAvatar(profile: profile, size: 26)
                        Text(profile.name)
                        Spacer()
                        Text(profile.ratingLimit.title).foregroundStyle(.secondary)
                        Image(systemName: profile.hasPIN ? "lock.fill" : "lock.open")
                            .foregroundStyle(profile.hasPIN ? .primary : .tertiary)
                            .help(profile.hasPIN ? "Opening this profile needs its PIN" : "No PIN")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $pinRequest) { request in
            PINPadView(request: request) { pinRequest = nil }
                .padding(20)
        }
    }

    private func verifyThen(_ action: @escaping () -> Void) {
        guard AdministratorPIN.isSet else { return action() }
        pinRequest = PINRequest(title: "Administrator PIN", message: "Enter the current administrator PIN.", profile: nil,
                                kind: .verify(AdministratorPIN.verify)) { _ in
            // Let the first sheet close before showing the next.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                action()
            }
        }
    }

    private func choosePIN() {
        pinRequest = PINRequest(title: "New Administrator PIN", message: "Choose a four-digit PIN.", profile: nil, kind: .create) { pin in
            AdministratorPIN.set(pin)
            hasPIN = true
        }
    }
}
