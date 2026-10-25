//
//  SettingsView.swift
//  Ultimate Theater
//

import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    /// Reopens on the pane last used.
    @AppStorage("settingsPane") private var pane: SettingsPane = .metadata

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding(get: { pane }, set: { if let new = $0 { pane = new } })) { item in
                SettingsSidebarRow(pane: item)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 240)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                if pane.isAdministratorOnly, !model.canManageLibrary {
                    AdministratorOnlyView()
                } else {
                    switch pane {
                    case .metadata: MetadataSettingsView()
                    case .library: LibrarySettingsView()
                    case .playback: PlaybackSettingsView()
                    case .parentalControls: ParentalControlsView()
                    case .remote: RemoteSettingsView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle(pane.title)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(width: 820, height: 600)
        .tint(Theme.accent)
        .background { AppBackground() }
        .background(WindowCentering())
        // Administrator PIN prompts asked for from Settings show over this window.
        .overlay {
            if model.pinHost == .settings {
                PINOverlay()
            }
        }
        .animation(.smooth(duration: 0.25), value: model.pinRequest?.id)
        .onDisappear { model.cancelPINRequest(in: .settings) }
    }
}

/// Shown in place of a management pane to anyone but the household administrator.
private struct AdministratorOnlyView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Administrator Only", systemImage: "crown.fill")
        } description: {
            Text("Only the household administrator can change these settings.")
        } actions: {
            if let administrator = model.administratorProfile, model.profile?.id != administrator.id {
                Button("Switch to Administrator…") {
                    model.requestOpen(administrator, in: .settings)
                }
                .buttonStyle(.theaterGlass)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The sections of Settings, listed in its sidebar.
enum SettingsPane: String, CaseIterable, Identifiable {
    case metadata, library, playback, parentalControls, remote

    var id: String { rawValue }

    /// Panes that manage the household (sources, library, PINs, remote), not just preferences.
    var isAdministratorOnly: Bool { self != .playback }

    var title: String {
        switch self {
        case .metadata: "Metadata"
        case .library: "Library"
        case .playback: "Playback"
        case .parentalControls: "Parental Controls"
        case .remote: "Remote"
        }
    }

    var systemImage: String {
        switch self {
        case .metadata: "sparkle.magnifyingglass"
        case .library: "externaldrive.fill"
        case .playback: "play.rectangle.fill"
        case .parentalControls: "lock.shield.fill"
        case .remote: "iphone.radiowaves.left.and.right"
        }
    }

    /// The tile color behind the icon, System Settings style.
    var color: Color {
        switch self {
        case .metadata: Color(hex: 0x3B82F6)
        case .library: Color(hex: 0x8A4DFF)
        case .playback: Theme.accent
        case .parentalControls: Color(hex: 0x22A06B)
        case .remote: Color(hex: 0xF59E0B)
        }
    }
}

private struct SettingsSidebarRow: View {
    let pane: SettingsPane

    var body: some View {
        Label {
            Text(pane.title)
        } icon: {
            Image(systemName: pane.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(pane.color.gradient, in: .rect(cornerRadius: 6))
        }
        .padding(.vertical, 2)
    }
}

/// The app's look for a Settings tab: the ambient backdrop shows through the grouped
/// form, whose sections read as translucent panels.
private struct SettingsFormStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
    }
}

/// Keeps the Settings window centered on screen every time it opens, rather than wherever
/// it was last left: it's centered when first shown, and again as it closes so the next
/// opening (which may reuse the same window) starts in the middle too.
private struct WindowCentering: NSViewRepresentable {
    func makeNSView(context: Context) -> CenteringView { CenteringView() }
    func updateNSView(_ nsView: CenteringView, context: Context) {}

    final class CenteringView: NSView {
        private var closeObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            closeObserver = nil
            guard let window else { return }
            // Don't let AppKit restore a saved position over ours.
            window.setFrameAutosaveName("")
            window.isRestorable = false
            // After SwiftUI has sized the window for its content.
            Task { @MainActor [weak window] in if let window { Self.center(window) } }
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak window] _ in
                MainActor.assumeIsolated {
                    if let window { Self.center(window) }
                }
            }
        }

        /// Exactly centered in the visible part of the screen (AppKit's `center()` sits a little high).
        private static func center(_ window: NSWindow) {
            guard let screen = window.screen ?? NSScreen.main else { return }
            let area = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: (area.midX - size.width / 2).rounded(),
                                          y: (area.midY - size.height / 2).rounded()))
        }

        isolated deinit {
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        }
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
            OpenSubtitlesSettingsSection()
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
        .modifier(SettingsFormStyle())
    }
}

private struct ProviderSection: View {
    let provider: MetadataProviderID
    let settings: MetadataSettings
    let service: MetadataService

    @State private var key = ""
    @State private var isTesting = false
    @State private var testResult: (success: Bool, message: String)?
    /// A saved key is locked behind the administrator PIN; unlocking lasts while Settings is open.
    @State private var isUnlocked = false
    @State private var pinRequest: PINRequest?

    private var isLocked: Bool {
        settings.hasKey(provider) && AdministratorPIN.isSet && !isUnlocked
    }

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
                if isLocked {
                    HStack {
                        Label("Key saved  ••••\(String(key.suffix(4)))", systemImage: "lock.fill")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Change Key…") {
                            pinRequest = PINRequest(title: "Administrator PIN", message: "Enter the administrator PIN to change the \(provider.displayName) key.",
                                                    profile: nil, kind: .verify(AdministratorPIN.verify)) { _ in
                                isUnlocked = true
                            }
                        }
                    }
                } else {
                    SecureField("API Key", text: $key, prompt: Text(provider == .tmdb ? "API key or read access token" : "API key"))
                        .onChange(of: key) { _, newValue in
                            settings.setAPIKey(newValue, for: provider)
                            testResult = nil
                        }
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
        .sheet(item: $pinRequest) { request in
            PINPadView(request: request) { pinRequest = nil }
        }
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
    @Environment(\.openWindow) private var openWindow
    @State private var isConfirmingReset = false
    /// The watched folder waiting on "Stop watching?".
    @State private var removingFolder: LibraryFolder?
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
                        Button("Remove…") { removingFolder = folder }
                            .accessibilityLabel("Stop watching \(folder.displayName)")
                    }
                }
                Text("These folders are watched, including folders on network drives. Deleted videos leave the library; new ones wait for approval in Library. Titles on a disconnected drive are kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Add Folder…") {
                        // The file panel belongs to the main window.
                        openWindow(id: AppWindow.mainID)
                        model.addMedia()
                    }
                    .disabled(library.isBusy)
                    Button("Rescan All") { model.rescanLibraryFolders(in: .settings) }
                        .disabled(library.folders.isEmpty || library.isBusy)
                }
            }
            Section {
                LabeledContent("Titles", value: "\(library.titles.count)")
                Button("Refresh All Info") { model.refreshInfo(in: .settings) }
                    .disabled(library.titles.isEmpty || library.isBusy)
            } header: {
                Text("Metadata")
            } footer: {
                Text("Re-fetches info for every title. Locked titles keep your edits.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("Every file plays with the built-in Theater engine. Containers: MP4, M4V, MOV, 3GP, MKV, WebM, AVI, MPEG-TS and Blu-ray/AVCHD M2TS, MPEG program streams (MPG, VOB), Ogg, FLV, and DV. Video: H.264, HEVC (including HDR10, HLG, and Dolby Vision), AV1, VP9, VP8, Theora, MPEG-1, MPEG-2, MPEG-4 Part 2 (Xvid/DivX), H.263, Apple ProRes, DV, and Motion JPEG. Audio: AAC (including LATM broadcast audio), Apple Lossless, FLAC, Opus, Vorbis, Dolby Digital, Dolby Digital Plus, Dolby TrueHD (lossless, including Atmos beds), DTS (core, including DTS-HD tracks), MP3, MP2, PCM and LPCM, ADPCM, µ-law, A-law, and AMR. Subtitles: SRT, ASS/SSA, MP4 text, Blu-ray PGS, DVD subtitles, DVB subtitles, and Teletext. Files using other formats are added and flagged.")
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
        .modifier(SettingsFormStyle())
        .sheet(item: $pinRequest) { request in
            PINPadView(request: request) { pinRequest = nil }
                .padding(20)
        }
        .confirmationDialog("Stop watching “\(removingFolder?.displayName ?? "")”?",
                            isPresented: Binding(get: { removingFolder != nil }, set: { if !$0 { removingFolder = nil } }),
                            titleVisibility: .visible, presenting: removingFolder) { folder in
            Button("Stop Watching Folder", role: .destructive) {
                model.manageLibrary("Enter the administrator PIN to stop watching “\(folder.displayName)”.", in: .settings) {
                    library.removeFolder(folder)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("New videos in this folder won't be added any more. Titles already in your library stay, and no files are deleted.")
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
    /// Shown when the Keychain refused a PIN change.
    @State private var pinSaveError: String?

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
                                if AdministratorPIN.set(nil) {
                                    hasPIN = false
                                    pinSaveError = nil
                                } else {
                                    pinSaveError = "The administrator PIN couldn't be removed from the Keychain, so it's still on."
                                }
                            }
                        }
                    }
                }
                if let pinSaveError {
                    Label(pinSaveError, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
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
        .modifier(SettingsFormStyle())
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
            if AdministratorPIN.set(pin) {
                hasPIN = true
                pinSaveError = nil
            } else {
                pinSaveError = "The new PIN couldn't be saved to the Keychain. The previous setting is unchanged."
            }
        }
    }
}

/// Settings shared by every profile for how episodes play.
enum PlaybackSettings {
    static let autoplayKey = "autoplayNextEpisode"
    /// The Up Next countdown, in seconds, before the next episode starts on its own (at the
    /// end of the file).
    static let countdownSeconds = 15
    /// Without detected credits, Up Next appears this many seconds before the end.
    static let upNextLeadSeconds = 20
    /// Episodes in a row with no input before asking "Are you still watching?".
    static let stillWatchingAfter = 3
}

private struct PlaybackSettingsView: View {
    @AppStorage(PlaybackSettings.autoplayKey) private var autoplayNext = true
    @AppStorage(CastSettings.discoveryKey) private var findsCastingDevices = true

    var body: some View {
        Form {
            Section {
                Toggle("Play the next episode automatically", isOn: $autoplayNext)
            } header: {
                Text("TV Shows")
            } footer: {
                Text(autoplayNext
                     ? "Up Next appears once an episode's credits are over (or in its last \(PlaybackSettings.upNextLeadSeconds) seconds when no credits are found). The next episode starts when the episode ends, after a \(PlaybackSettings.countdownSeconds)-second countdown. After \(PlaybackSettings.stillWatchingAfter) episodes in a row with no activity, Ultimate Theater asks whether you're still watching."
                     : "Up Next still appears at the end of each episode, but the next one only starts when you choose Play Now.")
            }
            Section {
                Toggle("Find casting devices on this network", isOn: $findsCastingDevices)
                    .onChange(of: findsCastingDevices) { CastDiscovery.shared.applySetting() }
            } header: {
                Text("Casting")
            } footer: {
                Text("After you first open the Cast menu, Ultimate Theater looks for Chromecast, Google TV, DLNA smart TVs, and Roku devices on your local network while a video is open. Nothing leaves your network: when you cast, the device streams the video directly from this Mac through a private, single-use link that stops working when casting ends.")
            }
        }
        .modifier(SettingsFormStyle())
    }
}
