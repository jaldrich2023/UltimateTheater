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
    @Environment(\.openWindow) private var openWindow

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
                let isMini = model.isPlayerMinimized
                // One player view in both sizes, so playback carries on when it shrinks to
                // picture-in-picture in the corner.
                PlayerView(item: item, startPosition: model.startPosition, startSelection: model.startSelection)
                    .id("\(item.id)#\(model.playRequest)")
                    .modifier(PlayerPlacement(isMini: isMini, slot: model.pictureInPictureSlot))
                    .transition(.opacity)
                    .zIndex(10)
            }

            // Prompts asked for from Settings show over that window instead.
            if model.pinHost == .main {
                PINOverlay()
                    .zIndex(20)
            }
        }
        .animation(.smooth(duration: 0.25), value: model.pinRequest?.id)
        .frame(minWidth: AppWindow.minimumSize.width, minHeight: AppWindow.minimumSize.height)
        .background { AppBackground() }
        .preferredColorScheme(.dark)
        // Closing the window stops playback (saving progress), so reopening it doesn't
        // restart the last title from where it was first opened.
        .onDisappear {
            model.closePlayerSavingProgress()
            model.cancelPINRequest(in: .main)
        }
        .onAppear {
            // Clicking the Dock icon with the window closed opens it again.
            AppDelegate.openMainWindow = { [openWindow] in openWindow(id: AppWindow.mainID) }
        }
    }
}

enum AppWindow {
    /// The main window's scene identifier.
    static let mainID = "main"
    /// The size the window opens at when the screen has room.
    static let preferredSize = CGSize(width: 1480, height: 1140)
    /// The smallest layout everything is designed to fit (13-inch MacBook Air and up).
    static let smallestLayout = CGSize(width: 1024, height: 680)
    /// Space kept between a launch-size window and the screen edges.
    static let screenMargin: CGFloat = 20

    /// The smallest the window can be resized to: the smallest layout, or the main screen's
    /// visible area if that's smaller still, so the window always fits on screen.
    static let minimumSize: CGSize = {
        guard let visible = NSScreen.main?.visibleFrame.size else { return smallestLayout }
        return CGSize(width: min(smallestLayout.width, visible.width), height: min(smallestLayout.height, visible.height))
    }()

    /// The preferred size, shrunk to fit the screen's visible area (less a margin) but never
    /// below the minimum or beyond the screen.
    static func launchSize(in visible: CGRect) -> CGSize {
        guard visible.width > 0, visible.height > 0 else { return minimumSize }
        func fit(_ preferred: CGFloat, _ available: CGFloat, _ minimum: CGFloat) -> CGFloat {
            min(max(min(preferred, available - screenMargin * 2), minimum), available)
        }
        return CGSize(width: fit(preferredSize.width, visible.width, minimumSize.width),
                      height: fit(preferredSize.height, visible.height, minimumSize.height))
    }
}

/// Keeps a window's close, minimise, and zoom buttons visible and working.
enum WindowControls {
    static func show(in window: NSWindow) {
        // Full screen has its own controls (shown at the top edge on hover).
        guard !window.styleMask.contains(.fullScreen) else { return }
        window.styleMask.formUnion([.closable, .miniaturizable, .resizable])
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind) else { continue }
            button.isHidden = false
            button.isEnabled = true
            // The titlebar container itself can be hidden along with the toolbar.
            var container = button.superview
            while let view = container, view !== window.contentView?.superview {
                view.isHidden = false
                container = view.superview
            }
        }
    }

    /// After SwiftUI has finished updating the toolbar for the new state.
    static func showSoon(in window: NSWindow?) {
        guard let window else { return }
        Task { @MainActor [weak window] in
            for delay in [0, 150, 500] {
                try? await Task.sleep(for: .milliseconds(delay))
                if let window { show(in: window) }
            }
        }
    }
}

/// A weak reference to the window hosting a view, filled in by `HostingWindowReader`.
final class WindowReference {
    weak var window: NSWindow?
}

/// Reports the window a view is in, so window notifications can be matched to it.
struct HostingWindowReader: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = self.window
            // After the current update, so it can safely change view state.
            Task { @MainActor [weak self] in self?.onChange?(window) }
        }
    }
}

/// Scrolls its content only when it doesn't fit, and otherwise centers it in the space.
struct FittingScrollView<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                content
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var isDropTargeted = false
    /// The sidebar is always shown in a window; in full screen it appears on hover at the left edge.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isFullScreen = false
    @State private var hideSidebarTask: Task<Void, Never>?
    /// The window this view is in; full-screen notifications from other windows are ignored.
    @State private var hostWindow = WindowReference()

    /// The sidebar's width while picture-in-picture is docked in it.
    private static let pictureInPictureSidebarWidth: CGFloat = 320

    /// Video types for the Add Media panel, including formats added but flagged as unsupported.
    private static let importTypes: [UTType] = [.folder, .movie, .audiovisualContent]
        + FilenameParser.videoExtensions.compactMap { UTType(filenameExtension: $0) }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Sidebar()
                // Wider while picture-in-picture is docked in it: pinned to that width (minimum
                // and maximum alike), so the split view really resizes the column rather than
                // keeping its current width within a looser range.
                .navigationSplitViewColumnWidth(min: model.isPlayerMinimized ? Self.pictureInPictureSidebarWidth : 220,
                                                ideal: model.isPlayerMinimized ? Self.pictureInPictureSidebarWidth : 240,
                                                max: model.isPlayerMinimized ? Self.pictureInPictureSidebarWidth : 360)
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
                        case .smartCollection(let collection):
                            SmartCollectionView(collection: collection)
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
        .onChange(of: model.isPlayerMinimized) { _, isMini in
            // Picture-in-picture docks in the sidebar, so it stays out in full screen.
            guard isFullScreen else { return }
            hideSidebarTask?.cancel()
            withAnimation(.smooth) { columnVisibility = isMini ? .all : .detailOnly }
        }
        .onChange(of: columnVisibility) { _, visibility in
            // Outside full screen the sidebar can't be collapsed.
            if !isFullScreen, visibility != .all { columnVisibility = .all }
        }
        .background {
            HostingWindowReader { window in
                hostWindow.window = window
                if let window { WindowControls.show(in: window) }
                // Shown again while already in full screen (after switching profiles, say).
                if let window, window.styleMask.contains(.fullScreen), !isFullScreen {
                    isFullScreen = true
                    if !model.isPlayerMinimized { columnVisibility = .detailOnly }
                }
            }
        }
        .task {
            for await note in NotificationCenter.default.notifications(named: NSWindow.didEnterFullScreenNotification) {
                guard let window = note.object as? NSWindow, window === hostWindow.window else { continue }
                isFullScreen = true
                withAnimation(.smooth) { columnVisibility = model.isPlayerMinimized ? .all : .detailOnly }
            }
        }
        .task {
            for await note in NotificationCenter.default.notifications(named: NSWindow.willExitFullScreenNotification) {
                guard let window = note.object as? NSWindow, window === hostWindow.window else { continue }
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
        .toolbar(removing: .title)
        // In full screen the toolbar (and the grey bar it draws over the sidebar's corner) stays
        // out of the way until the pointer reaches the top edge; its background never shows.
        .windowToolbarFullScreenVisibility(.onHover)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar(model.nowPlaying == nil || model.isPlayerMinimized ? .automatic : .hidden, for: .windowToolbar)
        // Hiding the toolbar for the player also hides the close, minimise, and zoom buttons;
        // bring them back whenever the player opens or closes.
        .onChange(of: model.nowPlaying == nil || model.isPlayerMinimized) {
            WindowControls.showSoon(in: hostWindow.window)
        }
        .onChange(of: isFullScreen) { WindowControls.showSoon(in: hostWindow.window) }
        .fileImporter(isPresented: $model.isImporterPresented, allowedContentTypes: Self.importTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await model.library.importMedia(from: urls) }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let fileURLs = urls.filter(\.isFileURL)
            guard model.canManageLibrary, !fileURLs.isEmpty else { return false }
            model.importDropped(fileURLs)
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
            guard !Task.isCancelled, isFullScreen, !model.isPlayerMinimized else { return }
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
        case .statistics: WatchStatsView()
        case .library:
            // Only the administrator manages the library.
            if model.canManageLibrary { LibraryManagerView() } else { HomeView() }
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
                        group("Library", model.canManageLibrary ? [.myList, .statistics, .library] : [.myList, .statistics])
                    }
                }
            }
            .scrollIndicators(.never)

            Spacer(minLength: 12)

            if model.isPlayerMinimized, model.nowPlaying != nil {
                // The slot the picture-in-picture player docks into.
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        // Only real moves, so the player isn't re-laid out for nothing.
                        if model.pictureInPictureSlot != frame { model.pictureInPictureSlot = frame }
                    }
                    .padding(.bottom, 12)
                    // The navigation list scrolls before the player or the buttons below it shrink.
                    .layoutPriority(1)
                    .transition(.opacity)
            }

            if model.canManageLibrary {
                Button { model.addMedia() } label: {
                    Label("Add Movies & Shows", systemImage: "plus")
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.theaterGlass)
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

    private func group(_ heading: LocalizedStringKey?, _ sections: [SidebarSection]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let heading {
                Text(heading)
                    .textCase(.uppercase)
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
            let attention = model.library.titles.filter { $0.needsMatch || !$0.isPlayable }.count + model.library.pending.count
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
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.6))
                    .frame(width: 22)
                Text(section.title)
                    .font(.body.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.78))
                Spacer(minLength: 4)
                badgeView
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background {
                if isHovered && !isSelected {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.white.opacity(0.06))
                }
            }
            // Accent-tinted glass that slides to the selected row. It's applied to the row itself
            // (not a background layer) so the sidebar's glass container always draws the label on top.
            .glassEffect(isSelected ? .regular.tint(Theme.accent.opacity(0.75)).interactive() : .identity,
                         in: .rect(cornerRadius: 10))
            .glassEffectID(isSelected ? "selection" : nil, in: namespace)
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
                .help(Text("Needs attention: ^[\(count) title](inflect: true)"))
                .accessibilityLabel(Text("Needs attention: ^[\(count) title](inflect: true)"))
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
                Text("Signed in as")
                    .textCase(.uppercase)
                    .font(.caption2.weight(.bold))
                    .tracking(1)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
                // The switcher and Log Out sit side by side: one container renders their glass
                // together (spacing below the gap, so the two shapes stay separate).
                GlassEffectContainer(spacing: 4) {
                    HStack(spacing: 8) {
                        Menu {
                            Section("Switch Profile") {
                                ForEach(model.profiles.filter { $0.id != profile.id }) { other in
                                    Button { model.requestSwitch(to: other) } label: {
                                        Label {
                                            if other.isAdministrator {
                                                // Menus draw symbols in the text color; the crown marks the administrator.
                                                Text("\(other.name) \(Image(systemName: "crown.fill"))")
                                            } else {
                                                Text(other.name)
                                            }
                                        } icon: {
                                            Image(systemName: other.symbol)
                                        }
                                    }
                                    .accessibilityLabel(other.isAdministrator ? "\(other.name), Administrator" : other.name)
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
                        .accessibilityLabel(profile.isAdministrator
                                            ? "Signed in as \(profile.name), Administrator. Switch profile"
                                            : "Signed in as \(profile.name). Switch profile")

                        Button {
                            model.signOut()
                        } label: {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .font(.title3.weight(.semibold))
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.theaterGlass)
                        .help("Log Out")
                        .accessibilityLabel("Log out of \(profile.name)")
                    }
                }
            }
        }
    }
}

/// The player fills the whole window (title bar included) normally, and docks into the
/// sidebar's slot in picture-in-picture. One modifier chain with changing values (no
/// branches), so the player keeps its identity and keeps playing.
private struct PlayerPlacement: ViewModifier {
    let isMini: Bool
    let slot: CGRect

    func body(content: Content) -> some View {
        content
            .frame(width: isMini ? slot.width : nil, height: isMini ? slot.height : nil)
            .frame(maxWidth: isMini ? nil : .infinity, maxHeight: isMini ? nil : .infinity)
            .clipShape(.rect(cornerRadius: isMini ? 12 : 0))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.white.opacity(isMini ? 0.18 : 0), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(isMini ? 0.45 : 0), radius: 14, y: 6)
            // Moved into the slot by layout (not just drawn there with an offset), so the
            // player never sits under the toolbar's safe area and keeps the slot's exact size.
            .padding(.leading, isMini ? slot.minX : 0)
            .padding(.top, isMini ? slot.minY : 0)
            // Laid out over the whole window in both modes, so window (global) coordinates
            // from the sidebar's slot line up exactly.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
    }
}
