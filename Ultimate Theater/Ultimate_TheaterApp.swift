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

    init() {
        let containers: (library: ModelContainer, users: ModelContainer)
        do {
            containers = try LibraryStore.makeContainers()
        } catch {
            fatalError("Could not open the library databases: \(error)")
        }
        container = containers.users
        let library = MediaLibrary(container: containers.library,
                                   metadata: MetadataService(settings: MetadataSettings()))
        let model = AppModel(library: library)
        model.modelContext = container.mainContext
        _model = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .task {
                    await model.library.reprobeIfNeeded()
                    await model.library.fetchMissingCertifications()
                }
        }
        .modelContainer(container)
        .defaultSize(AppWindow.minimumSize)
        .windowResizability(.contentMinSize)
        // Always open centered rather than wherever the window was last left.
        .restorationBehavior(.disabled)
        .defaultPosition(.center)
        .commands {
            AboutCommand()

            CommandGroup(after: .newItem) {
                Button("Add Movies & Shows…") { model.addMedia() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(!model.canManageLibrary || model.library.isBusy)
                Button("Rescan Library Folders") { Task { await model.library.rescanFolders() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.library.folders.isEmpty || model.library.isBusy)
                Button("Refresh All Info") { Task { await model.library.refreshMetadata(force: true) } }
                    .disabled(model.library.titles.isEmpty || model.library.isBusy)
            }

            // Replaces the system Show/Hide Sidebar command: the sidebar is always visible
            // (in full screen it appears when the pointer reaches the left edge).
            CommandGroup(replacing: .sidebar) {
                Divider()
                ForEach(SidebarSection.allCases.filter { $0 != .search }) { section in
                    Button(section.title) {
                        model.searchText = ""
                        model.section = section
                    }
                    .keyboardShortcut(section.shortcut, modifiers: .command)
                    .disabled(model.profile == nil || (section == .library && !model.canManageLibrary))
                }
                Divider()
            }

            CommandGroup(after: .textEditing) {
                Button("Search") {
                    model.section = .search
                    model.isSearchPresented = true
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(model.profile == nil)
            }

            CommandMenu("Profile") {
                ForEach(model.profiles) { profile in
                    Button(profile.name) { model.select(profile) }
                }
                Divider()
                Button("Switch Profile…") { model.signOut() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }

        Window("About Ultimate Theater", id: AboutCommand.windowID) {
            AboutView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultPosition(.center)

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
        .modelContainer(container)
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
