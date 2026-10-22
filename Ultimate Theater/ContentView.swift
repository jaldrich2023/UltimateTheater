//
//  ContentView.swift
//  Ultimate Theater
//
//  Created by John Aldrich on 10/21/26.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Root: profile picker → main browsing shell, with the player layered on top.
struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if model.profile == nil {
                ProfilePickerView()
                    .transition(.opacity.combined(with: .scale(scale: 1.04)))
            } else {
                MainView()
                    .transition(.opacity)
            }

            if let item = model.nowPlaying {
                PlayerView(item: item, startPosition: model.startPosition, startSelection: model.startSelection)
                    .id(item.id)
                    .transition(.opacity)
                    .zIndex(10)
            }

            PINOverlay()
                .zIndex(20)
        }
        .animation(.smooth(duration: 0.25), value: model.pinRequest?.id)
        .frame(minWidth: AppWindow.minimumSize.width, minHeight: AppWindow.minimumSize.height)
        .background { AppBackground() }
        .preferredColorScheme(.dark)
    }
}

enum AppWindow {
    /// The launch size is also the smallest the window can be resized to.
    static let minimumSize = CGSize(width: 1440, height: 900)
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var isDropTargeted = false
    /// The sidebar is always shown in a window; in full screen it appears on hover at the left edge.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isFullScreen = false
    @State private var hideSidebarTask: Task<Void, Never>?

    /// Video types for the Add Media panel, including formats added but flagged as unsupported.
    private static let importTypes: [UTType] = [.folder, .movie, .audiovisualContent]
        + FilenameParser.videoExtensions.compactMap { UTType(filenameExtension: $0) }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
                .toolbar(removing: .sidebarToggle)
                .onHover { isInside in
                    guard isFullScreen else { return }
                    if isInside { showSidebar() } else { scheduleSidebarHide() }
                }
        } detail: {
            NavigationStack(path: $model.path) {
                root
                    .navigationDestination(for: AppRoute.self) { route in
                        switch route {
                        case .title(let title):
                            TitleDetailView(titleID: title.id)
                                .id(title.id)
                        case .collection(let collection):
                            CollectionDetailView(collectionID: collection.id)
                                .id(collection.id)
                        }
                    }
            }
            .overlay(alignment: .bottom) {
                LibraryActivityBanner()
            }
            .overlay {
                if isDropTargeted { dropHighlight }
            }
            .overlay(alignment: .leading) {
                if isFullScreen, columnVisibility == .detailOnly {
                    // Hover target along the left edge that reveals the sidebar in full screen.
                    Color.clear
                        .frame(width: 8)
                        .frame(maxHeight: .infinity)
                        .contentShape(.rect)
                        .onHover { if $0 { showSidebar() } }
                        .accessibilityHidden(true)
                }
            }
        }
        .onChange(of: columnVisibility) { _, visibility in
            // Outside full screen the sidebar can't be collapsed.
            if !isFullScreen, visibility != .all { columnVisibility = .all }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: NSWindow.didEnterFullScreenNotification) {
                isFullScreen = true
                withAnimation(.smooth) { columnVisibility = .detailOnly }
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: NSWindow.willExitFullScreenNotification) {
                isFullScreen = false
                hideSidebarTask?.cancel()
                withAnimation(.smooth) { columnVisibility = .all }
            }
        }
        .searchable(text: $model.searchText, isPresented: $model.isSearchPresented,
                    placement: .toolbar, prompt: "Movies, shows, people, genres")
        .onChange(of: model.searchText) { _, query in
            // Typing anywhere jumps straight to results.
            guard !query.isEmpty else { return }
            model.selectedGenre = nil
            if model.section != .search { model.section = .search }
            model.path = []
        }
        .toolbar {
            if model.canManageLibrary {
                ToolbarItem(placement: .primaryAction) {
                    Button { model.addMedia() } label: {
                        Label("Add Movies & Shows", systemImage: "plus")
                    }
                    .help("Add movies and shows (⌘O)")
                    .disabled(model.library.isBusy)
                }
            }
        }
        .toolbar(removing: .title)
        .toolbar(model.nowPlaying == nil ? .automatic : .hidden, for: .windowToolbar)
        .fileImporter(isPresented: $model.isImporterPresented, allowedContentTypes: Self.importTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await model.library.importMedia(from: urls) }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let fileURLs = urls.filter(\.isFileURL)
            guard model.canManageLibrary, !fileURLs.isEmpty else { return false }
            Task { await model.library.importMedia(from: fileURLs) }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .sheet(item: $model.matchingTitle) { title in
            FixMatchView(title: title)
        }
        .sheet(item: $model.editingTitle) { title in
            EditInfoView(title: title)
        }
    }

    private func showSidebar() {
        hideSidebarTask?.cancel()
        guard columnVisibility != .all else { return }
        withAnimation(.smooth(duration: 0.3)) { columnVisibility = .all }
    }

    /// Hides the full-screen sidebar shortly after the pointer leaves it.
    private func scheduleSidebarHide() {
        hideSidebarTask?.cancel()
        hideSidebarTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, isFullScreen else { return }
            withAnimation(.smooth(duration: 0.3)) { columnVisibility = .detailOnly }
        }
    }

    @ViewBuilder
    private var root: some View {
        switch model.section {
        case .home: HomeView()
        case .movies: BrowseView(kind: .movie)
        case .shows: BrowseView(kind: .series)
        case .collections: CollectionsView()
        case .recentlyAdded: RecentlyAddedView()
        case .myList: MyListView()
        case .library: LibraryManagerView()
        case .search: SearchView()
        }
    }

    private var dropHighlight: some View {
        ZStack {
            Theme.background.opacity(0.7)
            VStack(spacing: 14) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(Theme.accent)
                Text("Drop to Add to Your Library")
                    .font(.title.weight(.bold))
                Text("Movies, episodes, or whole folders")
                    .foregroundStyle(.secondary)
            }
            .padding(40)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                .padding(20)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

// MARK: - Sidebar

/// Custom sidebar styled to match the cinematic content area.
private struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Namespace private var selectionNamespace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandMark(size: 14)
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 26)

            ScrollView {
                // One container so the selection glass slides and morphs between rows.
                GlassEffectContainer(spacing: 8) {
                    VStack(alignment: .leading, spacing: 24) {
                        group(nil, [.home, .search])
                        group("Browse", [.movies, .shows, .collections, .recentlyAdded])
                        group("Library", model.canManageLibrary ? [.myList, .library] : [.myList])
                    }
                }
            }
            .scrollIndicators(.never)

            Spacer(minLength: 12)

            if model.canManageLibrary {
                Button { model.addMedia() } label: {
                    Label("Add Movies & Shows", systemImage: "plus")
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glass)
                .disabled(model.library.isBusy)
                .padding(.bottom, 10)
            }

            ProfileSwitcher()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
        // A floating Liquid Glass panel over the app's ambient backdrop.
        .background {
            RadialGradient(colors: [Theme.accent.opacity(0.14), .clear], center: .topLeading,
                           startRadius: 0, endRadius: 420)
                .clipShape(.rect(cornerRadius: 22))
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(8)
        .background { AppBackground() }
    }

    private func group(_ heading: String?, _ sections: [SidebarSection]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let heading {
                Text(heading.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }
            ForEach(sections) { section in
                SidebarRow(section: section, badge: badge(for: section), namespace: selectionNamespace)
            }
        }
    }

    private func badge(for section: SidebarSection) -> SidebarRow.Badge? {
        switch section {
        case .movies: return model.movies.isEmpty ? nil : .count(model.movies.count)
        case .shows: return model.shows.isEmpty ? nil : .count(model.shows.count)
        case .collections:
            let count = model.collections.count
            return count == 0 ? nil : .count(count)
        case .library:
            let attention = model.library.titles.filter { $0.needsMatch || !$0.isPlayable }.count
            return attention > 0 ? .attention(attention) : nil
        default: return nil
        }
    }
}

private struct SidebarRow: View {
    enum Badge {
        case count(Int)
        case attention(Int)
    }

    @Environment(AppModel.self) private var model
    let section: SidebarSection
    let badge: Badge?
    let namespace: Namespace.ID
    @State private var isHovered = false

    private var isSelected: Bool { model.section == section }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.6))
                    .frame(width: 22)
                Text(section.title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.78))
                Spacer(minLength: 4)
                badgeView
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background {
                if isSelected {
                    // Accent-tinted glass that slides to the selected row.
                    Color.clear
                        .glassEffect(.regular.tint(Theme.accent.opacity(0.75)).interactive(), in: .rect(cornerRadius: 10))
                        .glassEffectID("selection", in: namespace)
                        .shadow(color: Theme.accent.opacity(0.3), radius: 10, y: 3)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.white.opacity(0.06))
                }
            }
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("\(section.title) (⌘\(String(section.shortcut.character).uppercased()))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var badgeView: some View {
        switch badge {
        case .count(let count):
            Text("\(count)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isSelected ? .white.opacity(0.85) : .white.opacity(0.4))
        case .attention(let count):
            Text("\(count)")
                .font(.caption2.weight(.heavy))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.orange, in: .capsule)
                .foregroundStyle(.black)
                .help("\(count) titles need attention")
        case nil:
            EmptyView()
        }
    }

    private func select() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            model.section = section
        }
        if section == .search {
            model.isSearchPresented = true
        } else {
            model.searchText = ""
            model.selectedGenre = nil
        }
    }
}

private struct ProfileSwitcher: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let profile = model.profile {
            VStack(alignment: .leading, spacing: 8) {
                Text("SIGNED IN AS")
                    .font(.caption2.weight(.bold))
                    .tracking(1)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
                HStack(spacing: 8) {
                    Menu {
                        Section("Switch Profile") {
                            ForEach(model.profiles.filter { $0.id != profile.id }) { other in
                                Button(other.name, systemImage: other.symbol) { model.requestSwitch(to: other) }
                            }
                        }
                        Divider()
                        Button("Manage Profiles…", systemImage: "person.2") { model.signOut() }
                    } label: {
                        HStack(spacing: 10) {
                            ProfileAvatar(profile: profile, size: 30)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(profile.name)
                                    .font(.callout.weight(.semibold))
                                    .lineLimit(1)
                                Text(profile.ratingLimit == .everything ? "Switch profile" : profile.ratingLimit.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .contentShape(.rect)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
                    .accessibilityLabel("Signed in as \(profile.name). Switch profile")

                    Button {
                        model.signOut()
                    } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glass)
                    .help("Log Out")
                    .accessibilityLabel("Log out of \(profile.name)")
                }
            }
        }
    }
}
