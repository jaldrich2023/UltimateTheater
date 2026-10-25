//
//  Ultimate_TheaterApp.swift
//  Ultimate Theater
//
//  Created by John Aldrich on 10/21/26.
//

import SwiftUI
import SwiftData

@main
struct Ultimate_TheaterApp: App {
    /// Profiles, progress, My List, and ratings (Users.sqlite). The master library has its own.
    private let container: ModelContainer
    @State private var model: AppModel
    /// Why the databases couldn't be opened; the main window then offers recovery instead.
    private let storeFailure: StoreFailure?
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let isTesting = AppEnvironment.isRunningTests
        var failure: StoreFailure?
        let containers: (library: ModelContainer, users: ModelContainer)
        if isTesting {
            // Tests run inside the app: never touch the real library.
            containers = Self.inMemoryContainers()
        } else {
            do {
                containers = try LibraryStore.makeContainers()
            } catch {
                failure = StoreFailure(error)
                containers = Self.inMemoryContainers()
            }
        }
        storeFailure = failure
        container = containers.users
        let library = MediaLibrary(container: containers.library,
                                   metadata: MetadataService(settings: MetadataSettings()))
        let model = AppModel(library: library)
        model.modelContext = container.mainContext
        AppDelegate.model = model
        // Media keys and Now Playing, plus the iPhone remote if the administrator turned it on.
        if !isTesting, failure == nil {
            RemoteControl.shared.attach(model)
        }
        _model = State(initialValue: model)
    }

    /// Empty, memory-only databases, for tests and for the recovery window.
    private static func inMemoryContainers() -> (library: ModelContainer, users: ModelContainer) {
        do {
            let library = try ModelContainer(for: LibraryStore.librarySchema, configurations: [
                ModelConfiguration("Library", schema: LibraryStore.librarySchema, isStoredInMemoryOnly: true),
            ])
            let users = try ModelContainer(for: LibraryStore.usersSchema, configurations: [
                ModelConfiguration("Users", schema: LibraryStore.usersSchema, isStoredInMemoryOnly: true),
            ])
            return (library, users)
        } catch {
            // Memory-only stores have no file to be damaged; failing here is a programming error.
            fatalError("Could not create in-memory databases: \(error)")
        }
    }

    var body: some Scene {
        // A single main window: every window would share one model (and one player).
        Window("Ultimate Theater", id: AppWindow.mainID) {
            if let storeFailure {
                StoreRecoveryView(failure: storeFailure)
            } else {
                ContentView()
                    .environment(model)
                    .defaultAppStorage(model.defaults)
                    .task {
                        guard !AppEnvironment.isRunningTests else { return }
                        await model.library.reprobeIfNeeded()
                        await model.library.fetchMissingCertifications()
                    }
            }
        }
        .modelContainer(container)
        // ⌘0 brings the main window back after it's been closed (Window ▸ Ultimate Theater).
        .keyboardShortcut("0", modifiers: .command)
        .windowResizability(.contentMinSize)
        // Always open centered rather than wherever the window was last left, at the preferred
        // size or as much of it as the screen allows.
        .restorationBehavior(.disabled)
        .defaultWindowPlacement { _, context in
            let size = AppWindow.launchSize(in: context.defaultDisplay.visibleRect)
            return WindowPlacement(.center, size: size)
        }
        .commands {
            AboutCommand()

            MainWindowCommands(model: model, isAvailable: storeFailure == nil)

            PlaybackCommands()
        }

        Window("About Ultimate Theater", id: AboutCommand.windowID) {
            AboutView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultPosition(.center)

        Settings {
            Group {
                if storeFailure == nil {
                    SettingsView()
                } else {
                    // Nothing to manage (and no reset) until the library can be opened.
                    UnavailableSettingsView()
                }
            }
            .environment(model)
            .defaultAppStorage(model.defaults)
            .preferredColorScheme(.dark)
        }
        .modelContainer(container)
        .defaultPosition(.center)
        // Resizable, so its zoom button works like the main window's.
        .windowResizability(.contentMinSize)
    }
}

/// Replaces the standard About panel with the themed About window.
private struct AboutCommand: Commands {
    static let windowID = "about"
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Ultimate Theater") { openWindow(id: Self.windowID) }
        }
    }
}

/// Library, navigation, search, and profile commands. Each one that changes what the main
/// window shows opens that window first, so it works after the window was closed.
private struct MainWindowCommands: Commands {
    let model: AppModel
    /// False while the databases couldn't be opened (the window shows recovery instead).
    let isAvailable: Bool
    @Environment(\.openWindow) private var openWindow

    private func showMainWindow() {
        openWindow(id: AppWindow.mainID)
    }

    var body: some Commands {
        let hasProfile = isAvailable && model.profile != nil
        let canManage = isAvailable && model.canManageLibrary && !model.library.isBusy

        CommandGroup(after: .newItem) {
            Button("Add Movies & Shows…") {
                showMainWindow()
                model.addMedia()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(!canManage)
            Button("Rescan Library Folders") {
                showMainWindow()
                model.rescanLibraryFolders()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!canManage || model.library.folders.isEmpty)
            Button("Refresh All Info") {
                showMainWindow()
                model.refreshInfo()
            }
            .disabled(!canManage || model.library.titles.isEmpty)
        }

        // Replaces the system Show/Hide Sidebar command: the sidebar is always visible
        // (in full screen it appears when the pointer reaches the left edge).
        CommandGroup(replacing: .sidebar) {
            Divider()
            ForEach(SidebarSection.allCases.filter { $0 != .search }) { section in
                Button(section.title) {
                    showMainWindow()
                    model.searchText = ""
                    model.section = section
                }
                .keyboardShortcut(section.shortcut, modifiers: .command)
                .disabled(!hasProfile || (section == .library && !model.canManageLibrary))
            }
            Divider()
        }

        CommandGroup(after: .textEditing) {
            Button("Search") {
                showMainWindow()
                model.section = .search
                model.isSearchPresented = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(!hasProfile)
        }

        CommandMenu("Profile") {
            ForEach(model.profiles) { profile in
                Button(profile.name) {
                    showMainWindow()
                    // The same PIN checks as choosing the profile on screen.
                    model.requestOpen(profile)
                }
                .disabled(!isAvailable)
            }
            Divider()
            Button("Switch Profile…") {
                showMainWindow()
                model.signOut()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(!isAvailable)
        }
    }
}

/// The Playback menu. Its items act on the player in the focused main window and are only
/// enabled while one is showing (the bare-key shortcuts never reach text fields elsewhere).
private struct PlaybackCommands: Commands {
    @FocusedValue(\.playerCommands) private var player

    var body: some Commands {
        CommandMenu("Playback") {
            let transport = player?.acceptsTransportKeys == true ? player : nil
            Button(transport?.isPlaying == true ? "Pause" : "Play") { transport?.togglePlayback() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(transport == nil)
            Button("Back 10 Seconds") { transport?.skip(-10) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(transport == nil)
            Button("Forward 10 Seconds") { transport?.skip(10) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(transport == nil)
            Divider()
            Button("Skip Intro or Credits") { transport?.skipSegment() }
                .keyboardShortcut("s", modifiers: [])
                .disabled(transport == nil)
            Button("Previous Episode") { transport?.previousEpisode() }
                .keyboardShortcut(.leftArrow, modifiers: .shift)
                .disabled(transport?.hasPreviousEpisode != true)
            Button("Next Episode") { transport?.nextEpisode() }
                .keyboardShortcut(.rightArrow, modifiers: .shift)
                .disabled(transport?.hasNextEpisode != true)
            Divider()
            Button(transport?.isMuted == true ? "Unmute" : "Mute") { transport?.toggleMute() }
                .keyboardShortcut("m", modifiers: [])
                .disabled(transport == nil)
            Button("Toggle Full Screen") { transport?.toggleFullScreen() }
                .keyboardShortcut("f", modifiers: [])
                .disabled(transport == nil)
            Divider()
            if player?.isMinimized == true {
                Button("Return to Player") { player?.expand() }
                    .keyboardShortcut(.return, modifiers: .command)
            } else {
                Button("Picture in Picture") { player?.minimize() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(player == nil)
            }
            Button("Stop") { player?.stop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(player == nil)
        }
    }
}

/// Why the databases couldn't be opened, and which of them failed.
struct StoreFailure {
    let reason: String
    /// Whether the master library (titles, folders) failed to open.
    let library: Bool
    /// Whether the users database (profiles, history) failed to open.
    let users: Bool

    init(_ error: any Error) {
        reason = error.localizedDescription
        if let failed = error as? LibraryStore.StoreOpenError {
            // Only the database that failed is moved aside; the other keeps its data.
            library = failed.libraryFailed
            users = failed.usersFailed
        } else {
            // Without a more specific error, both are treated as damaged.
            library = true
            users = true
        }
    }

    /// "library database", "users database", or "library databases".
    var storeDescription: String {
        switch (library, users) {
        case (true, false): "library database"
        case (false, true): "users database (profiles and watch history)"
        default: "library databases"
        }
    }
}

/// Shown in place of the app when its databases can't be opened.
private struct StoreRecoveryView: View {
    let failure: StoreFailure
    @State private var errorMessage: String?
    @State private var isConfirming = false
    @State private var pinRequest: PINRequest?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(.orange)
            Text("Your Library Couldn't Be Opened")
                .font(.title.weight(.bold))
            Text("Ultimate Theater couldn't read its \(failure.storeDescription). It may be damaged, or was written by a newer version of the app.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text(failure.reason)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .lineLimit(4)
            Text("Moving the damaged database aside keeps the old file (renamed, next to the original) and starts that part fresh. Your movie and show files are never touched.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let errorMessage {
                Label(errorMessage, systemImage: "xmark.octagon")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack(spacing: 12) {
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.theaterGlass)
                // No Return shortcut: this is destructive and must be chosen deliberately.
                Button("Move Damaged Library Aside and Start Fresh…", role: .destructive) { isConfirming = true }
                    .buttonStyle(.glassProminent)
            }
            .controlSize(.large)
            .padding(.top, 6)
        }
        .frame(maxWidth: 560)
        .padding(40)
        .frame(minWidth: 640, minHeight: 440)
        .background { AppBackground() }
        .preferredColorScheme(.dark)
        .confirmationDialog("Move the damaged \(failure.storeDescription) aside?", isPresented: $isConfirming,
                            titleVisibility: .visible) {
            Button("Move Aside and Start Fresh", role: .destructive, action: confirmStartFresh)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(failure.users
                 ? "Ultimate Theater starts with no profiles or watch history. The old database is kept, renamed, next to the new one."
                 : "Ultimate Theater starts with an empty library; your profiles and watch history are kept. The old database is kept, renamed, next to the new one.")
        }
        .sheet(item: $pinRequest) { request in
            PINPadView(request: request) { pinRequest = nil }
                .padding(20)
        }
    }

    /// The administrator PIN (if one is set) guards moving the library aside.
    private func confirmStartFresh() {
        guard AdministratorPIN.isSet else { return startFresh() }
        pinRequest = PINRequest(title: "Administrator PIN", message: "Enter the administrator PIN to start with a fresh library.",
                                profile: nil, kind: .verify(AdministratorPIN.verify)) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350)) // Let the PIN sheet close first.
                startFresh()
            }
        }
    }

    /// Renames the damaged databases, then relaunches so the app opens new ones.
    private func startFresh() {
        do {
            try LibraryStore.moveAsideDamagedStores(library: failure.library, users: failure.users)
        } catch {
            errorMessage = "The library couldn't be moved aside: \(error.localizedDescription)"
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}

/// Settings while the databases couldn't be opened: nothing can be changed or reset.
private struct UnavailableSettingsView: View {
    var body: some View {
        ContentUnavailableView("Settings Unavailable", systemImage: "externaldrive.badge.exclamationmark",
                               description: Text("Ultimate Theater's library couldn't be opened. Use the main window to recover it, then reopen Settings."))
            .frame(width: 520, height: 320)
            .background { AppBackground() }
    }
}
