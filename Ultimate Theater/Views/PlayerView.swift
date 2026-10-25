//
//  PlayerView.swift
//  Ultimate Theater
//

import SwiftUI
import SwiftData
import AVFoundation

/// Immersive full-window player built on the Theater engine, with our own transport,
/// subtitles, Skip Intro / Skip Credits, Up Next, and the episode picker.
struct PlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var modelContext

    let startPosition: Double
    let startSelection: PlaybackSelection?

    @State private var current: PlaybackItem
    @State private var engine: TheaterEngine?
    @State private var isChromeVisible = true
    @State private var lastActivity = Date.now
    @State private var isUpNextDismissed = false
    /// Rolls into the next episode when one ends (Settings › Playback).
    @AppStorage(PlaybackSettings.autoplayKey) private var autoplayNext = true
    /// Episodes rolled into without the viewer touching anything; after a few, ask first.
    @State private var autoplayStreak = 0
    /// "Are you still watching?" after several episodes played on their own.
    @State private var isAskingStillWatching = false
    @State private var fileError: String?
    /// Playback ID whose file security scope is currently open.
    @State private var openFileID: String?
    /// Brief confirmation after saving a favourite scene.
    @State private var savedSceneAt: Double?
    /// The file was moved or deleted (its drive is connected): offer to remove the title.
    @State private var isFileMissing = false
    @State private var isConfirmingRemoval = false
    /// The pointer is over the title card, which then shows the synopsis.
    @State private var isTitleCardExpanded = false
    /// The pointer is over the synopsis panel itself, which keeps it open.
    @State private var isSynopsisHovered = false
    /// The info pane's width, so the synopsis above it lines up exactly with it.
    @State private var titleCardWidth: CGFloat = 0
    private var showsSynopsis: Bool {
        (isTitleCardExpanded || isSynopsisHovered) && !synopsis.isEmpty && !isShowingEpisodes
    }
    /// The Episodes button's panel, rising from the bar like the synopsis.
    @State private var isShowingEpisodes = false
    /// Season shown in the Episodes panel (starts on the playing episode's season).
    @State private var episodePanelSeason: Int?
    /// The episode row under the pointer in the Episodes panel.
    @State private var hoveredEpisodeID: String?
    /// The player's height, so the Episodes panel can grow as tall as the room above the bar allows.
    @State private var playerHeight: CGFloat = 0
    /// AirPlay video to an Apple TV, for files that support it.
    @State private var airPlay = AirPlayHandoff()
    /// A cast to a Google Cast, DLNA, or Roku device; kept after it stops until the viewer
    /// returns to the Mac, so the outcome stays on screen.
    @State private var cast: CastSession?
    /// The current file's container and codecs, for the Cast menu's compatibility checks.
    @State private var castProfile: CastMediaProfile?
    /// The current file, while its security scope is open.
    @State private var openURL: URL?
    /// The engine was muted because it loaded the next episode while casting.
    @State private var isEngineMutedForCast = false
    /// Why casting stopped (e.g. the next episode's format), shown briefly.
    @State private var castNotice: String?
    /// The window the player is in; notifications about other windows are ignored.
    @State private var hostWindow = WindowReference()
    /// The intro and credits of the current item, worked out once per item (and again when
    /// its chapters load or the library finishes detecting them), not on every redraw.
    @State private var skipSegments = SkipSegments()
    /// "Find Subtitles…" sheet; while it's up, the player's bare-key shortcuts are off.
    @State private var subtitleSearch: SubtitleSearchTarget?
    /// A narrow window: the transport bar tightens up to fit.
    @State private var isCompact = false
    /// The transport bar's height, which grows while the title card shows the synopsis.
    @State private var controlBarHeight: CGFloat = 0

    init(item: PlaybackItem, startPosition: Double, startSelection: PlaybackSelection?) {
        self.startPosition = startPosition
        self.startSelection = startSelection
        _current = State(initialValue: item)
    }

    /// The playback position right now. Not for `body`: reading it there would redraw the
    /// whole player ten times a second (the time-dependent overlays read it themselves).
    private var currentPosition: Double { airPlay.isExternal ? airPlay.currentTime : engine?.currentTime ?? 0 }
    private var isMini: Bool { model.isPlayerMinimized }
    private var duration: Double { engine?.duration ?? 0 }
    private var failure: String? { fileError ?? engine?.failure }

    /// The episode's synopsis, or the title's for movies (and episodes without one).
    private var synopsis: String {
        current.episode.map(\.synopsis).flatMap { $0.isEmpty ? nil : $0 } ?? current.title.synopsis
    }

    private var nextEpisode: Episode? {
        guard let episode = current.episode else { return nil }
        return current.title.episode(after: episode)
    }

    private var previousEpisode: Episode? {
        guard let episode = current.episode else { return nil }
        return current.title.episode(before: episode)
    }

    /// Previous/next episode buttons for the transport; nil for movies.
    private var episodeSkips: TheaterControls.EpisodeSkips? {
        guard current.episode != nil else { return nil }
        return .init(previous: previousEpisode.map { episode in { switchTo(PlaybackItem(title: current.title, episode: episode)) } },
                     next: nextEpisode.map { episode in { switchTo(PlaybackItem(title: current.title, episode: episode)) } },
                     previousName: previousEpisode.map { "\($0.code) · \($0.name)" },
                     nextName: nextEpisode.map { "\($0.code) · \($0.name)" })
    }

    /// What decides the skip segments; they're recomputed only when this changes.
    private struct SkipInputs: Equatable {
        var itemID: String
        var chapters: [PlaybackChapter]
        var duration: Double
        var detected: SkipSegments?
    }

    private var skipInputs: SkipInputs {
        SkipInputs(itemID: current.id, chapters: engine?.chapters ?? [], duration: duration,
                   detected: current.episode != nil ? model.library.skipSegments[current.id] : nil)
    }

    /// The intro and credits: for episodes, what the library detected (chapter names or matching
    /// audio across episodes), else the file's chapter names; movies use chapter intros only.
    private func computeSkipSegments() -> SkipSegments {
        let fromChapters = SkipChapters.segments(from: (engine?.chapters ?? []).map { ($0.title, $0.start, $0.end) },
                                                 duration: duration > 0 ? duration : nil)
        guard current.episode != nil else {
            return SkipSegments(introStart: fromChapters.introStart, introEnd: fromChapters.introEnd)
        }
        return model.library.skipSegments[current.id] ?? fromChapters
    }

    /// When Skip Intro, Skip Credits, and Up Next are offered, for the current item.
    private var skipOffer: SkipOffer {
        SkipOffer(segments: skipSegments, isEpisode: current.episode != nil, duration: duration,
                  isActive: engine?.hasStarted == true && failure == nil)
    }

    /// The Playback menu's view of this player.
    private var commandContext: PlayerCommandContext {
        PlayerCommandContext(
            isMinimized: isMini,
            // Not while "Are you still watching?" is up: Space mustn't quietly resume.
            acceptsTransportKeys: !isMini && subtitleSearch == nil && model.pinRequest == nil && engine != nil
                && !isAskingStillWatching,
            // Whatever shows the picture: the Apple TV during AirPlay, else the engine.
            isPlaying: model.activeTransport?.isPlaying == true,
            isMuted: airPlay.isExternal ? airPlay.volume == 0 : engine?.isMuted == true,
            hasPreviousEpisode: previousEpisode != nil,
            hasNextEpisode: nextEpisode != nil,
            togglePlayback: { withActivity { model.activeTransport?.togglePlayback() } },
            skip: { seconds in withActivity { model.activeTransport?.skip(by: seconds) } },
            skipSegment: {
                withActivity {
                    let offer = skipOffer
                    let position = currentPosition
                    if offer.showsCredits(at: position) { skipCredits() } else if offer.showsIntro(at: position) { skipIntro() }
                }
            },
            previousEpisode: { withActivity { if let previousEpisode { switchTo(PlaybackItem(title: current.title, episode: previousEpisode)) } } },
            nextEpisode: { withActivity { playNext() } },
            toggleMute: {
                withActivity {
                    if airPlay.isExternal { airPlay.volume = airPlay.volume == 0 ? 1 : 0 } else { engine?.isMuted.toggle() }
                }
            },
            toggleFullScreen: { withActivity { toggleFullScreen() } },
            minimize: { model.minimizePlayer() },
            expand: { model.expandPlayer() },
            stop: { close() })
    }

    private func withActivity(_ action: () -> Void) {
        action()
        revealChrome()
    }

    private func toggleFullScreen() {
        (hostWindow.window ?? NSApp.keyWindow)?.toggleFullScreen(nil)
    }

    /// Escape leaves full screen first; otherwise it shrinks the player to picture-in-picture.
    private func closeEpisodesPanel() {
        withAnimation(.smooth(duration: 0.3)) { isShowingEpisodes = false }
    }

    private func handleEscape() {
        // Escape closes the Episodes panel first.
        if isShowingEpisodes { return closeEpisodesPanel() }
        if let window = hostWindow.window, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        } else {
            model.minimizePlayer()
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            surface
                // Full bleed in the window; inside the picture-in-picture box it must stay
                // exactly the box's size, or the picture is enlarged and cropped.
                .ignoresSafeArea(edges: isMini ? [] : .all)
                // Double-click the picture to enter or leave full screen.
                .contentShape(.rect)
                .onTapGesture(count: 2) {
                    if isMini { model.expandPlayer() } else { toggleFullScreen() }
                }

            // Subtitles are too small to read in picture-in-picture, so they're hidden there.
            if let engine, !isMini {
                ImageSubtitleOverlay(bitmaps: engine.subtitleBitmaps, videoSize: engine.videoSize)
                    .ignoresSafeArea()
                SubtitleOverlay(text: engine.subtitleText, isRaised: isChromeVisible)
            }

            if let failure {
                failureMessage(failure)
            } else if engine?.hasStarted != true || engine?.isBuffering == true {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            if let cast, !isMini {
                CastExternalScreen(session: cast, item: current, onWatchOnMac: { watchOnMac() }, onStop: { stopCasting() })
            } else if airPlay.isAirPlayActive, !isMini {
                AirPlayExternalScreen(handoff: airPlay, item: current)
            }

            if isMini {
                MiniPlayerControls(transport: airPlay.isExternal ? airPlay : engine, onExpand: model.expandPlayer, onClose: close)
            } else {
                topBar
                    .frame(maxHeight: .infinity, alignment: .top)
                    .opacity(isChromeVisible ? 1 : 0)

                if let savedSceneAt {
                    Label("Saved scene at \(TheaterControlsTime.format(savedSceneAt))", systemImage: "heart.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 96)
                }

                if let castNotice {
                    Label(castNotice, systemImage: "tv.badge.wifi")
                        .font(.callout)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 520)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: .rect(cornerRadius: 16))
                        .transition(.opacity)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 96)
                }

                // While the Episodes panel is open, a click anywhere outside it (and outside the
                // bar) just closes it, without pausing or toggling full screen.
                if isShowingEpisodes {
                    Color.clear
                        .contentShape(.rect)
                        .ignoresSafeArea()
                        .onTapGesture { closeEpisodesPanel() }
                        .accessibilityHidden(true)
                }

                // Without the bar (casting, AirPlay, or a file that won't play), picture-in-
                // picture still sits in the lower-right corner.
                if engine == nil || failure != nil || isPictureElsewhere {
                    Button(action: model.minimizePlayer) {
                        Image(systemName: "pip.enter")
                            .font(.title3.weight(.semibold))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.theaterGlassCircle)
                    .help("Picture in Picture: keep watching while you browse (Esc)")
                    .accessibilityLabel("Picture in picture")
                    .padding(28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .opacity(isChromeVisible ? 1 : 0)
                }

                if let engine, failure == nil, !isPictureElsewhere {
                    // The synopsis panel stacked directly on top of the bar. The stack is pinned
                    // to the bottom of the screen, so as the panel grows, its bottom edge stays put
                    // just above the info pane and its top edge rises toward the top of the screen.
                    VStack(alignment: .leading, spacing: 0) {
                    // Both panels rise from the same spot; only one is open at a time.
                    ZStack(alignment: .bottom) {
                        if !synopsis.isEmpty {
                            synopsisPanel
                        }
                        if current.title.kind == .series {
                            episodesPanel
                        }
                    }
                    // One continuous glass bar: the title's info on the left, the transport on the right.
                    HStack(alignment: .center, spacing: 0) {
                        titleCard
                            .frame(maxHeight: .infinity)
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { titleCardWidth = $0 }
                        Rectangle()
                            .fill(.white.opacity(0.14))
                            .frame(width: 1)
                            .padding(.vertical, 14)
                        TheaterControls(engine: engine, episodes: episodeSkips, isCompact: isCompact,
                                        subtitleSearch: $subtitleSearch, onToggleFullScreen: toggleFullScreen,
                                        onPictureInPicture: model.minimizePlayer,
                                        castButton: CastButton(profile: castProfile, activeDeviceID: cast?.device.id,
                                                               onCast: { startCasting(to: $0) }))
                            .frame(maxHeight: .infinity)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    // Square top edge (the synopsis panel rises from it); rounded bottom corners.
                    .glassEffect(.regular, in: UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 22,
                                                                      bottomTrailingRadius: 22, topTrailingRadius: 0))
                    // The skip and Up Next overlays sit just above the bar itself.
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlBarHeight = $0 }
                    }
                    .padding(.horizontal, isCompact ? 20 : 40)
                    .padding(.bottom, 28)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .opacity(isChromeVisible ? 1 : 0)
                    .allowsHitTesting(isChromeVisible)
                }

                if isAskingStillWatching, let nextEpisode {
                    StillWatchingPrompt(title: current.title, episode: nextEpisode,
                                        onContinue: {
                                            autoplayStreak = 0
                                            isAskingStillWatching = false
                                            playNext()
                                        },
                                        onStop: { finish() })
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else if let engine, engine.hasStarted, !engine.isPlaying, failure == nil, !isPictureElsewhere,
                          // The synopsis and Episodes panels rise over the same spot, so the paused
                          // details step aside while either is open.
                          !showsSynopsis, !isShowingEpisodes {
                    pausedInfo
                        .transition(.opacity)
                }

                if let engine {
                    // Skip Intro / Skip Credits / Up Next: the only parts of the player that follow
                    // the playback position, so only they redraw as it advances.
                    PlayerTimedOverlay(engine: engine, airPlay: airPlay, offer: skipOffer,
                                       title: current.title, nextEpisode: nextEpisode,
                                       isUpNextDismissed: $isUpNextDismissed,
                                       isAskingStillWatching: isAskingStillWatching,
                                       isAutoplay: autoplayNext && autoplayStreak < PlaybackSettings.stillWatchingAfter,
                                       onPlayNext: playNext, onSkipIntro: skipIntro, onSkipCredits: skipCredits)
                        .padding(.trailing, isCompact ? 20 : 40)
                        // Clear the transport controls (bar, its bottom margin, and a gap).
                        .padding(.bottom, controlBarHeight > 0 ? controlBarHeight + 28 + 16 : 150)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        // While the picture is on an Apple TV (or a cast device that can't seek),
                        // those controls aren't offered here.
                        .opacity(offersTimedOverlays ? 1 : 0)
                        .disabled(!offersTimedOverlays)
                }

                // Escape leaves full screen, or shrinks the player to picture-in-picture. While
                // "Are you still watching?" is up, Escape is its Back to Browsing.
                if !isAskingStillWatching {
                    Button("Picture in Picture", action: handleEscape)
                        .keyboardShortcut(.cancelAction)
                        .hidden()
                }

                if let engine, !isPictureElsewhere {
                    TheaterKeyCommands(engine: engine, onActivity: revealChrome)
                }
            }
        }
        .preferredColorScheme(.dark)
        .environment(airPlay)
        .background {
            HostingWindowReader { hostWindow.window = $0 }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width < 1200 } action: { isCompact = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { playerHeight = $0 }
        // No screen saver, lock screen, or sleep while something is playing.
        .onChange(of: sleepMode, initial: true) { _, mode in PlaybackSleepGuard.shared.update(mode) }
        .onChange(of: skipInputs, initial: true) { skipSegments = computeSkipSegments() }
        // The Playback menu (Space, arrows, S, M, F…) acts on this player.
        .focusedSceneValue(\.playerCommands, commandContext)
        .onContinuousHover { phase in
            if case .active = phase { revealChrome() }
        }
        // Minimised during playback: the Dock shows the live picture.
        .task {
            for await note in NotificationCenter.default.notifications(named: NSWindow.didMiniaturizeNotification) {
                guard let window = note.object as? NSWindow, window === hostWindow.window, let engine else { continue }
                DockPreview.shared.start(in: window, engine: engine)
                // Playing on this Mac: keep watching in a floating window on the desktop.
                if engine.hasStarted, engine.isPlaying, failure == nil, !isPictureElsewhere {
                    DesktopPictureInPicture.shared.show(engine: engine, mainWindow: window)
                }
            }
        }
        .task {
            for await note in NotificationCenter.default.notifications(named: NSWindow.didDeminiaturizeNotification) {
                guard let window = note.object as? NSWindow, window === hostWindow.window else { continue }
                DockPreview.shared.stop(in: window)
                DesktopPictureInPicture.shared.hide()
            }
        }
        .task(id: current.id) {
            let isFirstItem = current.id == model.nowPlaying?.id
            await load(current, from: isFirstItem ? startPosition : 0, selection: isFirstItem ? startSelection : nil)
            await monitorPlayback()
        }
        .onAppear { CastDiscovery.shared.begin() }
        .onChange(of: cast?.phase) { _, phase in castPhaseChanged(phase) }
        .onDisappear {
            DesktopPictureInPicture.shared.hide()
            PlaybackSleepGuard.shared.update(.none)
            saveProgress()
            CastDiscovery.shared.end()
            if let cast {
                airPlay.castSession = nil
                self.cast = nil
                Task { await cast.end() }
            }
            airPlay.reset()
            engine?.shutdown()
            closeFile()
            NSCursor.setHiddenUntilMouseMoves(false)
            if let window = hostWindow.window { DockPreview.shared.stop(in: window) }
        }
    }

    /// Playing on this Mac keeps the display awake; playing on an Apple TV only keeps the
    /// Mac awake so the stream continues.
    private var sleepMode: PlaybackSleepGuard.Mode {
        if airPlay.isExternal { return airPlay.isPlaying ? .system : .none }
        return engine?.isPlaying == true ? .systemAndDisplay : .none
    }

    /// The picture is on an Apple TV or a cast device (or a cast just stopped and its
    /// outcome is showing): the Mac's own controls step aside.
    private var isPictureElsewhere: Bool { airPlay.isExternal || cast != nil }

    /// Skip Intro / Skip Credits / Up Next: on the Mac, or on a cast device that can seek.
    private var offersTimedOverlays: Bool {
        if airPlay.isAirPlayActive { return false }
        guard let cast else { return true }
        return cast.isActive && cast.capabilities.canSeek
    }

    @ViewBuilder
    private var surface: some View {
        if let engine {
            TheaterSurface(displayLayer: engine.displayLayer)
        }
    }

    private func failureMessage(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("Can't Play “\(current.headline)”")
                .font(.title2.weight(.bold))
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            HStack(spacing: 12) {
                Button("Close", action: close)
                    .buttonStyle(.theaterPlain)
                if isFileMissing, model.canManageLibrary {
                    Button("Remove from Library…", role: .destructive) { isConfirmingRemoval = true }
                        .buttonStyle(.glassProminent)
                }
            }
            .confirmationDialog("Remove “\(current.headline)” from your library?", isPresented: $isConfirmingRemoval) {
                Button(current.episode == nil ? "Remove from Library" : "Remove This Episode", role: .destructive) {
                    let id = current.id
                    close()
                    model.library.removePlayable(id)
                }
            } message: {
                Text("Its file can't be found. You can add it again later if it turns up.")
            }
        }
        .foregroundStyle(.white)
        .padding(32)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    // MARK: Chrome

    /// The title card, styled like the app's title pages.
    private var titleCard: some View {
        HStack(spacing: 14) {
            ArtworkView(title: current.title, style: .poster)
                .frame(width: 48, height: 72)
                .clipShape(.rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Text(current.headline)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                if let subheadline = current.subheadline {
                    Text(subheadline)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                MetadataLine(title: current.title, showsBadges: true)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                HStack(spacing: 8) {
                    Button(action: saveScene) {
                        Label("Save Scene", systemImage: "heart")
                            .font(.callout.weight(.semibold))
                    }
                    // Plain: the title card already sits on the bar's glass.
                    .buttonStyle(.theaterPlain)
                    .controlSize(.small)
                    .keyboardShortcut("b", modifiers: [])
                    .help("Save this moment to Favourite Scenes (B)")
                    if current.title.kind == .series {
                        episodeMenu
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: isCompact ? 300 : 420, maxHeight: .infinity, alignment: .leading)
        .foregroundStyle(.white)
        .contentShape(.rect)
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.3)) { isTitleCardExpanded = hovering }
        }
    }

    /// The info pane's width (falls back to its maximum before it's been measured).
    private var infoPaneWidth: CGFloat { titleCardWidth > 0 ? titleCardWidth : (isCompact ? 300 : 420) }

    /// Series name, then season/episode and the episode's title (or, for a movie, its year).
    private var synopsisHeader: (title: String, detail: String?) {
        if let episode = current.episode {
            let numbers = "Season \(episode.season) · Episode \(episode.number)"
            return (current.title.name, episode.name.isEmpty ? numbers : "\(numbers) · \(episode.name)")
        }
        return (current.title.name, current.title.yearText)
    }

    private var synopsisPanel: some View {
        let header = synopsisHeader
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(header.title)
                    .font(.headline)
                    .lineLimit(1)
                if let detail = header.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
            Divider()
                .overlay(.white.opacity(0.2))
            Text(synopsis)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(10)
        }
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        // Slightly narrower than the info pane, centred over it.
        .frame(width: max(infoPaneWidth - 32, 200), alignment: .leading)
        // The panel's height grows from 0 at its bottom edge (sitting right on the info pane's
        // top edge) up to its full height; the glass follows that height.
        .modifier(GrowUpward(progress: showsSynopsis ? 1 : 0))
        // Rounded top corners; straight bottom edge where it meets the info pane.
        .glassEffect(.regular, in: UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 0,
                                                          bottomTrailingRadius: 0, topTrailingRadius: 18))
        .opacity(showsSynopsis ? 1 : 0)
        .allowsHitTesting(showsSynopsis)
        .animation(.smooth(duration: 0.3), value: showsSynopsis)
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.3)) { isSynopsisHovered = hovering }
        }
        .frame(width: infoPaneWidth)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Synopsis")
    }

    /// While paused, the title's details over a darkened picture, like the app's title pages.
    private var pausedInfo: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paused")
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(Theme.accent)
            Text(current.headline)
                .font(.system(size: 44, weight: .bold))
                .lineLimit(2)
            if let subheadline = current.subheadline {
                Text(subheadline)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            MetadataLine(title: current.title, showsBadges: true)
                .font(.callout)
            if !synopsis.isEmpty {
                Text(synopsis)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(3)
                    .frame(maxWidth: 560, alignment: .leading)
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, 60)
        .padding(.bottom, 190)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .background {
            LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0.2), .clear],
                           startPoint: .bottomLeading, endPoint: .topTrailing)
                .ignoresSafeArea()
        }
        .allowsHitTesting(false)
    }

    private var isWindowFullScreen: Bool { hostWindow.window?.styleMask.contains(.fullScreen) ?? false }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 16) {
            // The window's close, minimise, and zoom buttons (the system ones are hidden with
            // the toolbar while the player fills the window). Full screen has its own.
            if !isWindowFullScreen {
                WindowTrafficLights(window: hostWindow.window)
            }

            Spacer()

            if let warning = engine?.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .frame(maxWidth: 420, alignment: .trailing)
            }

        }
        .foregroundStyle(.white)
        .padding(.leading, 20)
        .padding(.trailing, 28)
        // Lined up with where macOS puts the window buttons.
        .padding(.top, 18)
        .padding(.bottom, 48)
        .background {
            LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    /// Episodes grouped in a submenu per season; the current season and episode are marked.
    private var episodeMenu: some View {
        Button {
            withAnimation(.smooth(duration: 0.3)) {
                if !isShowingEpisodes { episodePanelSeason = current.episode?.season ?? current.title.seasons.first?.number }
                isShowingEpisodes.toggle()
            }
        } label: {
            Label("Episodes", systemImage: isShowingEpisodes ? "chevron.down" : "rectangle.stack.fill")
                .font(.callout.weight(.semibold))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.theaterPlain)
        .controlSize(.small)
        .fixedSize()
        .help(isShowingEpisodes ? "Hide episodes" : "Show episodes")
        .accessibilityLabel(isShowingEpisodes ? "Hide episodes" : "Show episodes")
    }

    private var episodesPanel: some View {
        let seasons = current.title.seasons
        let selected = seasons.first { $0.number == episodePanelSeason } ?? seasons.first
        let episodes = selected?.episodes ?? []
        let rowHeight: CGFloat = 34
        // Tall enough for the whole season, limited only by the space above the bar (leaving
        // room for the panel's header, the season buttons, and a margin under the top bar).
        let header: CGFloat = seasons.count > 1 ? 120 : 84
        let room = playerHeight > 0 ? playerHeight - controlBarHeight - 28 - header - 96 : 320
        // Sized for the season with the most episodes, so the panel keeps one height while you
        // switch seasons — but never taller than the room in the player window.
        let tallestSeason = seasons.map(\.episodes.count).max() ?? episodes.count
        let panelListHeight = CGFloat(max(tallestSeason, 1)) * rowHeight
        let listHeight = max(min(panelListHeight, room), rowHeight * 3)
        let scrolls = CGFloat(episodes.count) * rowHeight > listHeight
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(current.title.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(selected?.name ?? "Episodes")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
            }
            if seasons.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(seasons) { season in
                            let isSelected = season.number == selected?.number
                            Button(season.number == 0 ? "Specials" : "S\(season.number)") {
                                withAnimation(.smooth(duration: 0.2)) { episodePanelSeason = season.number }
                            }
                            .buttonStyle(TheaterGlassButtonStyle(tint: isSelected ? Theme.accent : nil, usesGlass: false))
                            .controlSize(.small)
                            .accessibilityLabel(season.name)
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            Divider()
                .overlay(.white.opacity(0.2))
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(episodes) { episode in
                            episodeRow(episode, height: rowHeight)
                                .id(episode.id)
                        }
                    }
                    // A lane for the scroll bar, so it never sits on top of the rows.
                    .padding(.trailing, scrolls ? 16 : 0)
                }
                .scrollIndicators(scrolls ? .visible : .never)
                .frame(height: listHeight)
                .onAppear {
                    if let playing = current.episode?.id { proxy.scrollTo(playing, anchor: .center) }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(width: max(infoPaneWidth - 32, 200), alignment: .leading)
        .modifier(GrowUpward(progress: isShowingEpisodes ? 1 : 0))
        .glassEffect(.regular, in: UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 0,
                                                          bottomTrailingRadius: 0, topTrailingRadius: 18))
        .opacity(isShowingEpisodes ? 1 : 0)
        .allowsHitTesting(isShowingEpisodes)
        .animation(.smooth(duration: 0.3), value: isShowingEpisodes)
        .frame(width: infoPaneWidth)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Episodes")
    }

    /// The row under the pointer is highlighted more strongly than the one that's playing.
    private func rowFill(isPlaying: Bool, isHovered: Bool) -> Color {
        if isHovered { return .white.opacity(0.18) }
        return isPlaying ? .white.opacity(0.1) : .clear
    }

    private func episodeRow(_ episode: Episode, height: CGFloat) -> some View {
        let isPlaying = episode.id == current.episode?.id
        return Button {
            withAnimation(.smooth(duration: 0.3)) { isShowingEpisodes = false }
            if !isPlaying { switchTo(PlaybackItem(title: current.title, episode: episode)) }
        } label: {
            HStack(spacing: 8) {
                Text("\(episode.number)")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 24, alignment: .trailing)
                Text(episode.name.isEmpty ? "Episode \(episode.number)" : episode.name)
                    .font(.callout.weight(isPlaying ? .bold : .regular))
                    .lineLimit(1)
                // The playing episode's speaker sits right after its title.
                if isPlaying {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                        .accessibilityLabel("Now playing")
                }
                Spacer(minLength: 4)
                // Always shown, so every row lines up.
                Text(episode.runtimeMinutes > 0
                     ? Duration.seconds(episode.runtimeMinutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
                     : "—")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                    .accessibilityLabel(episode.runtimeMinutes > 0
                                        ? Duration.seconds(episode.runtimeMinutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide))
                                        : "Length unknown")
                if !isPlaying, model.isWatched(episode, of: current.title) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.white.opacity(0.6))
                        .accessibilityLabel("Watched")
                }
            }
            .padding(.horizontal, 6)
            .frame(height: height)
            .background(rowFill(isPlaying: isPlaying, isHovered: hoveredEpisodeID == episode.id && episode.isPlayable),
                        in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { hoveredEpisodeID = episode.id } else if hoveredEpisodeID == episode.id { hoveredEpisodeID = nil }
        }
        .animation(.easeOut(duration: 0.12), value: hoveredEpisodeID)
        .disabled(!episode.isPlayable)
        .opacity(episode.isPlayable ? 1 : 0.4)
    }

    private func revealChrome() {
        lastActivity = .now
        // Any pointer or key activity shows someone's still there.
        autoplayStreak = 0
        if !isChromeVisible {
            withAnimation(.easeOut(duration: 0.2)) { isChromeVisible = true }
        }
    }

    // MARK: Playback

    private func load(_ item: PlaybackItem, from start: Double, selection explicit: PlaybackSelection?) async {
        airPlay.reset()
        engine?.shutdown()
        engine = nil
        fileError = nil
        isUpNextDismissed = false
        isAskingStillWatching = false
        castProfile = nil
        openURL = nil
        // A cast that's still going (or just finished an episode) carries on with this item.
        let castsThisItem = cast.map { $0.isActive || $0.phase == .finished } ?? false
        if castsThisItem {
            cast?.prepareForNext()
        } else if let cast {
            airPlay.castSession = nil
            self.cast = nil
            Task { await cast.end() }
        }
        closeFile()
        guard let url = await model.library.beginPlayback(item.id) else {
            let path = model.library.filePath(for: item.id) ?? "The video file"
            isFileMissing = model.library.isFileMissing(item.id)
            fileError = isFileMissing
                ? "\(path) couldn't be found. It may have been moved, renamed, or deleted."
                : "\(path) couldn't be found. If it's on an external drive, connect it and try again. Otherwise, add the file again."
            return
        }
        openFileID = item.id
        openURL = url
        // Find this episode's intro and credits (and the next one's) if that hasn't been done yet.
        if item.episode != nil { model.library.analyzeSkipSegments(startingWith: item.id) }

        // An explicit choice from the detail page wins; otherwise use what this profile saved.
        let selection = explicit ?? model.profile.flatMap { profile in
            model.playbackPreferences.selection(profileID: profile.id, titleID: item.title.id)
        }
        let newEngine = TheaterEngine()
        engine = newEngine
        model.playerEngine = newEngine
        model.playerControls = controlHooks(for: newEngine)
        airPlay.prepare(url: url, engine: newEngine)
        // While casting, the engine loads silently (for chapters, skip times, and Watch on
        // This Mac) and is paused once ready.
        if castsThisItem {
            newEngine.isMuted = true
            isEngineMutedForCast = true
        }
        Task { await inspectForCasting(item, url: url, recast: castsThisItem) }
        newEngine.subtitleSearchTarget = SubtitleSearchTarget(item: item, library: model.library)
        let playbackID = item.id
        let externalSubtitles = await Task.detached { ExternalSubtitleLibrary.subtitles(for: playbackID, videoURL: url) }.value
        await newEngine.load(url, start: start, selection: selection, externalSubtitles: externalSubtitles)
        if cast != nil, engine === newEngine { newEngine.pause() }
    }

    /// Polls playback state twice a second: autosaves progress, auto-hides chrome,
    /// and rolls into the next episode when one finishes.
    private func monitorPlayback() async {
        var ticks = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let engine, failure == nil else { return }

            ticks += 1
            if ticks.isMultiple(of: 10) { saveProgress() }

            // The controls stay up while the viewer reads the synopsis.
            if !isMini, isChromeVisible, !showsSynopsis, !isShowingEpisodes, engine.isPlaying, Date.now.timeIntervalSince(lastActivity) > 3 {
                withAnimation(.easeIn(duration: 0.4)) { isChromeVisible = false }
                NSCursor.setHiddenUntilMouseMoves(true)
            }

            let castFinished = cast?.phase == .finished
            let reachedEnd = castFinished || (duration > 0 && currentPosition >= duration - 0.6)
            if reachedEnd {
                saveProgress()
                if nextEpisode != nil, !isUpNextDismissed, autoplayNext {
                    if autoplayStreak >= PlaybackSettings.stillWatchingAfter {
                        engine.pause()
                        withAnimation(.smooth) { isAskingStillWatching = true }
                    } else {
                        autoplayStreak += 1
                        playNext()
                    }
                    return
                }
                // Nothing to roll into: go back to the title's page.
                finish()
                return
            }
        }
    }

    /// The same episode, skip, and close paths as the on-screen buttons, for the iPhone remote
    /// and the system media controls.
    private func controlHooks(for engine: TheaterEngine) -> PlayerControlHooks {
        PlayerControlHooks(engine: engine, airPlay: airPlay, state: {
            let onMac = offersTimedOverlays
            let offer = skipOffer
            let position = currentPosition
            return PlayerHookState(item: current, hasPreviousEpisode: previousEpisode != nil, hasNextEpisode: nextEpisode != nil,
                                   canSkipIntro: onMac && offer.showsIntro(at: position),
                                   canSkipCredits: onMac && offer.showsCredits(at: position))
        }, perform: { action in
            // A command from the remote or a media key shows someone's still watching.
            autoplayStreak = 0
            switch action {
            case .previousEpisode: if let previousEpisode { switchTo(PlaybackItem(title: current.title, episode: previousEpisode)) }
            case .nextEpisode: playNext()
            case .skipIntro: if skipOffer.showsIntro(at: currentPosition) { skipIntro() }
            case .skipCredits: if skipOffer.showsCredits(at: currentPosition) { skipCredits() }
            case .close: close()
            }
        })
    }

    private func playNext() {
        guard let nextEpisode else { return }
        switchTo(PlaybackItem(title: current.title, episode: nextEpisode))
    }

    private func skipIntro() {
        guard let end = skipSegments.introEnd else { return }
        // On the Mac or the cast device, whichever has the picture.
        if let transport = model.activeTransport { transport.seek(to: end) } else { engine?.seek(to: end) }
    }

    /// Rolls into the next episode, or ends playback as reaching the end would. Moving to the
    /// end first records this episode as finished.
    private func skipCredits() {
        engine?.seek(to: duration)
        // A cast device moves to the end too, so the saved progress records the episode as finished.
        if let cast, cast.isActive { cast.seek(to: duration) }
        if nextEpisode != nil { playNext() } else { finish() }
    }

    private func switchTo(_ item: PlaybackItem) {
        saveProgress()
        current = item // Restarts the `.task(id:)`, which loads the new item.
    }

    // MARK: Casting

    /// Reads the file's container and codecs for the Cast menu and, when a cast carries on
    /// into this item, sends it to the device (or explains why it can't).
    private func inspectForCasting(_ item: PlaybackItem, url: URL, recast: Bool) async {
        let profile = await Task.detached(priority: .userInitiated) { CastMediaProfile.inspect(url) }.value
        guard current.id == item.id, openURL == url else { return }
        castProfile = profile
        guard recast, let session = cast else { return }
        if case .unsupported(let reason) = CastCompatibility.check(profile, for: session.device) {
            showCastNotice(reason)
            await returnFromCast(resume: true)
            return
        }
        await session.replace(with: castItem(url: url, profile: profile))
    }

    private func castItem(url: URL, profile: CastMediaProfile) -> CastMediaItem {
        CastMediaItem(fileURL: url, title: current.headline, subtitle: current.subheadline, isEpisode: current.episode != nil,
                      posterURL: current.title.posterURL, duration: duration, profile: profile)
    }

    /// Sends the picture to a device, from where the Mac (or the previous device) is.
    private func startCasting(to device: CastDevice) {
        guard let engine, let url = openURL, let profile = castProfile else { return }
        guard CastCompatibility.check(profile, for: device).isPlayable else { return }
        let previous = cast
        Task {
            var position = engine.currentTime
            var wasPlaying = engine.isPlaying || !engine.hasStarted
            if let previous {
                wasPlaying = previous.isPlaying
                position = await previous.end()
            }
            if airPlay.isAirPlayActive {
                airPlay.returnToMac()
                position = engine.currentTime
            }
            engine.pause()
            let session: CastSession
            do { session = try CastSession(device: device) } catch {
                showCastNotice("\(device.name) can't be used for casting.")
                if wasPlaying { engine.play() }
                return
            }
            cast = session
            airPlay.castSession = session
            revealChrome()
            await session.start(castItem(url: url, profile: profile), at: position)
            if !wasPlaying, session.phase == .playing { session.pause() }
        }
    }

    /// "Watch on This Mac": picks up where the device was.
    private func watchOnMac() {
        Task { await returnFromCast(resume: true) }
    }

    /// "Stop Casting": stops the device and leaves the Mac paused at its position.
    private func stopCasting() {
        Task { await returnFromCast(resume: false) }
    }

    private func returnFromCast(resume: Bool) async {
        guard let session = cast else { return }
        let wasActive = session.isActive
        let position = await session.end()
        guard cast === session else { return }
        airPlay.castSession = nil
        cast = nil
        guard let engine else { return }
        if isEngineMutedForCast {
            engine.isMuted = false
            isEngineMutedForCast = false
        }
        if duration <= 0 || position < duration - 1 { engine.seek(to: position) }
        if resume, wasActive || session.phase != .finished { engine.play() }
        revealChrome()
    }

    /// When the device stops on its own, the Mac takes up its position (paused), so progress
    /// and Watch on This Mac start from there.
    private func castPhaseChanged(_ phase: CastSession.Phase?) {
        guard let phase, let cast else { return }
        switch phase {
        case .ended, .failed:
            if let engine, cast.currentTime > 0 { engine.seek(to: cast.currentTime) }
            saveProgress()
        default:
            break
        }
    }

    private func showCastNotice(_ text: String) {
        withAnimation(.smooth) { castNotice = text }
        Task {
            try? await Task.sleep(for: .seconds(8))
            withAnimation(.smooth) { if castNotice == text { castNotice = nil } }
        }
    }

    private func closeFile() {
        if let openFileID {
            model.library.endPlayback(openFileID)
            self.openFileID = nil
        }
    }

    private func saveProgress() {
        guard let profile = model.profile, duration > 0 else { return }
        WatchHistory.saveProgress(current, profileID: profile.id, position: currentPosition, duration: duration, in: modelContext)
    }

    private func close() {
        saveProgress()
        engine?.shutdown()
        closeFile()
        model.stopPlayback()
    }

    /// Saves the current moment as a favourite scene for this profile.
    private func saveScene() {
        guard let profile = model.profile, duration > 0 else { return }
        let time = currentPosition
        modelContext.insert(SceneBookmark(profileID: profile.id, titleID: current.title.id, playbackID: current.id, time: time))
        try? modelContext.save()
        withAnimation(.snappy) { savedSceneAt = time }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.smooth) { if savedSceneAt == time { savedSceneAt = nil } }
        }
    }

    /// Played to the end: closes onto the title's listing.
    private func finish() {
        saveProgress()
        engine?.shutdown()
        closeFile()
        model.finishPlayback(of: current.title)
    }
}

/// What the Playback menu needs from the player in the focused window.
struct PlayerCommandContext {
    var isMinimized: Bool
    /// Space, the arrows, S, M, and F go to the player: it fills the window and no sheet
    /// (with a text field) is up.
    var acceptsTransportKeys: Bool
    var isPlaying: Bool
    var isMuted: Bool
    var hasPreviousEpisode: Bool
    var hasNextEpisode: Bool
    var togglePlayback: () -> Void
    var skip: (Double) -> Void
    /// Skip Intro or Skip Credits, whichever is on offer.
    var skipSegment: () -> Void
    var previousEpisode: () -> Void
    var nextEpisode: () -> Void
    var toggleMute: () -> Void
    var toggleFullScreen: () -> Void
    var minimize: () -> Void
    var expand: () -> Void
    var stop: () -> Void
}

extension FocusedValues {
    @Entry var playerCommands: PlayerCommandContext?
}

/// When Skip Intro, Skip Credits, and Up Next are offered for an item.
struct SkipOffer {
    /// How long Skip Intro / Skip Credits stay on screen after an episode's intro or credits begin.
    static let offerSeconds: Double = 15

    var segments: SkipSegments
    var isEpisode: Bool
    var duration: Double
    /// Playback has started and hasn't failed.
    var isActive: Bool

    /// When a skip button is offered: from the segment's start until it ends, or for episodes,
    /// for at most `offerSeconds`. Nil when too little is left to be worth skipping.
    private func window(from start: Double, to end: Double) -> Range<Double>? {
        let limit = isEpisode ? start + Self.offerSeconds : end
        let upper = min(limit, end - 1)
        return upper > start ? start..<upper : nil
    }

    func showsIntro(at position: Double) -> Bool {
        guard isActive, let start = segments.introStart, let end = segments.introEnd,
              let window = window(from: start, to: end) else { return false }
        return window.contains(position)
    }

    /// Episodes only, for the first moments of the end credits.
    func showsCredits(at position: Double) -> Bool {
        guard isEpisode, isActive, duration > 0, let start = segments.creditsStart,
              let window = window(from: start, to: duration) else { return false }
        return window.contains(position)
    }

    /// Shows once Skip Credits has had its moment (or, with no credits found, in the last
    /// `PlaybackSettings.upNextLeadSeconds`), and always during the final countdown.
    func showsUpNext(at position: Double) -> Bool {
        guard duration > 0 else { return false }
        let remaining = max(duration - position, 0)
        if remaining <= Double(PlaybackSettings.countdownSeconds) { return true }
        if let creditsStart = segments.creditsStart { return position >= creditsStart && !showsCredits(at: position) }
        return remaining <= min(Double(PlaybackSettings.upNextLeadSeconds), duration * 0.2)
    }
}

/// Skip Intro, Skip Credits, and the Up Next card: the overlays that follow the playback
/// position. They live in their own view so only they redraw as time advances.
private struct PlayerTimedOverlay: View {
    let engine: TheaterEngine
    let airPlay: AirPlayHandoff
    let offer: SkipOffer
    let title: Title
    let nextEpisode: Episode?
    @Binding var isUpNextDismissed: Bool
    let isAskingStillWatching: Bool
    let isAutoplay: Bool
    let onPlayNext: () -> Void
    let onSkipIntro: () -> Void
    let onSkipCredits: () -> Void

    private enum Offer: Equatable {
        case none, skipIntro, skipCredits, upNext
    }

    private var position: Double { airPlay.isExternal ? airPlay.currentTime : engine.currentTime }

    private var shown: Offer {
        let position = position
        if nextEpisode != nil, !isUpNextDismissed, !isAskingStillWatching, offer.showsUpNext(at: position) { return .upNext }
        if offer.showsCredits(at: position) { return .skipCredits }
        if offer.showsIntro(at: position) { return .skipIntro }
        return .none
    }

    var body: some View {
        let shown = shown
        VStack(alignment: .trailing, spacing: 16) {
            switch shown {
            case .upNext:
                if let nextEpisode {
                    UpNextCard(title: title, episode: nextEpisode,
                               secondsRemaining: TheaterControlsTime.clampedSeconds((offer.duration - position).rounded(.up)),
                               isAutoplay: isAutoplay,
                               onPlay: onPlayNext,
                               onDismiss: { withAnimation(.snappy) { isUpNextDismissed = true } })
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            case .skipCredits:
                skipButton("Skip Credits", hint: nextEpisode == nil ? "Ends playback" : "Plays the next episode",
                           action: onSkipCredits)
            case .skipIntro:
                skipButton("Skip Intro", hint: "Jumps to the end of the opening titles", action: onSkipIntro)
            case .none:
                EmptyView()
            }
        }
        .animation(.smooth, value: shown)
    }

    /// Skip Intro / Skip Credits: shown above the transport even while the controls are hidden.
    /// S (Playback menu) does the same.
    private func skipButton(_ title: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "forward.end.fill")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .buttonStyle(.theaterGlass)
        .help("\(title) (S)")
        .accessibilityLabel(title)
        .accessibilityHint(hint)
        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.9)),
                                removal: .opacity))
    }
}

/// Netflix-style "Next Episode" countdown card.
private struct UpNextCard: View {
    let title: Title
    let episode: Episode
    let secondsRemaining: Int
    /// Counts down over the last seconds and rolls into the episode at the end; otherwise just offers it.
    var isAutoplay = true

    /// The final seconds before the next episode starts on its own.
    private var isCountingDown: Bool { isAutoplay && secondsRemaining <= PlaybackSettings.countdownSeconds }
    let onPlay: () -> Void
    let onDismiss: () -> Void

    /// Fills over the countdown before the next episode starts on its own.
    private var countdown: Double? {
        guard isCountingDown else { return nil }
        return 1 - Double(max(secondsRemaining, 0)) / Double(PlaybackSettings.countdownSeconds)
    }

    var body: some View {
        HStack(spacing: 16) {
            ArtworkView(title: title, style: .backdrop)
                .frame(width: 150, height: 84)
                .clipShape(.rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(isCountingDown ? "UP NEXT IN \(secondsRemaining)" : "UP NEXT")
                    .font(.caption.weight(.heavy))
                    .tracking(1)
                    .foregroundStyle(Theme.accent)
                    .contentTransition(.numericText(countsDown: true))
                Text("\(episode.code) · \(episode.name)")
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Button(action: onPlay) {
                        Label("Play Now", systemImage: "play.fill")
                    }
                    .buttonStyle(PlayButtonStyle())
                    .controlSize(.small)
                    .keyboardShortcut("n", modifiers: [])
                    Button("Dismiss", action: onDismiss)
                        .buttonStyle(.theaterPlain)
                }
            }
        }
        .padding(14)
        .frame(width: 440)
        .overlay(alignment: .bottom) {
            if let countdown {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: proxy.size.width * countdown)
                        .animation(.linear(duration: 1), value: countdown)
                }
                .frame(height: 3)
                .padding(.horizontal, 18)
                .padding(.bottom, 6)
                .accessibilityHidden(true)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .foregroundStyle(.white)
    }
}

/// Shown instead of rolling into another episode after several played with nobody touching
/// anything, so a sleeping viewer doesn't lose their place in the series.
private struct StillWatchingPrompt: View {
    let title: Title
    let episode: Episode
    let onContinue: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text("Are you still watching \(title.name)?")
                .font(.system(size: 30, weight: .bold))
                .multilineTextAlignment(.center)
            Text("Next: \(episode.code) · \(episode.name)")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.75))
            HStack(spacing: 12) {
                Button(action: onContinue) {
                    Label("Continue Watching", systemImage: "play.fill")
                }
                .buttonStyle(PlayButtonStyle())
                .keyboardShortcut(.defaultAction)
                Button(action: onStop) {
                    Text("Back to Browsing")
                        .font(.headline)
                }
                .buttonStyle(.theaterPlain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 6)
        }
        .foregroundStyle(.white)
        .padding(36)
        .frame(maxWidth: 560)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.45))
    }
}

// MARK: - Theater surface and controls

/// Hosts the Theater engine's display layer.
private struct TheaterSurface: NSViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.hostedLayer = displayLayer
        return view
    }

    func updateNSView(_ view: LayerHostView, context: Context) {
        if view.hostedLayer !== displayLayer { view.hostedLayer = displayLayer }
    }

    final class LayerHostView: NSView {
        var hostedLayer: CALayer? {
            didSet {
                oldValue?.removeFromSuperlayer()
                if let hostedLayer { layer?.addSublayer(hostedLayer) }
                needsLayout = true
            }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Not while the desktop picture-in-picture window has borrowed the layer.
            if let hostedLayer, hostedLayer.superlayer === layer { hostedLayer.frame = bounds }
            CATransaction.commit()
        }
    }
}

private struct SubtitleOverlay: View {
    let text: String?
    let isRaised: Bool

    var body: some View {
        if let text {
            Text(text)
                .font(.system(size: 30, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 3, x: 0, y: 1)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.black.opacity(0.45), in: .rect(cornerRadius: 10))
                .frame(maxWidth: 1000)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, isRaised ? 170 : 60)
                .animation(.smooth, value: isRaised)
                .allowsHitTesting(false)
                .accessibilityLabel("Subtitle: \(text)")
        }
    }
}

/// Bitmap subtitles (PGS, DVD), drawn where the disc places them on the picture.
private struct ImageSubtitleOverlay: View {
    let bitmaps: [SubtitleBitmap]
    let videoSize: CGSize?

    var body: some View {
        GeometryReader { proxy in
            let picture = Self.fittedRect(for: videoSize ?? proxy.size, in: proxy.size)
            ForEach(bitmaps, id: \.self) { bitmap in
                Image(decorative: bitmap.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: picture.width * bitmap.frame.width, height: picture.height * bitmap.frame.height)
                    .position(x: picture.minX + picture.width * bitmap.frame.midX,
                              y: picture.minY + picture.height * bitmap.frame.midY)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The picture's rectangle when aspect-fitted into the view, matching the video layer.
    static func fittedRect(for content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else { return CGRect(origin: .zero, size: container) }
        let scale = min(container.width / content.width, container.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

/// Transport bar for the Theater engine. Its buttons are plain (no glass of their own): the
/// bar they sit in is already glass.
private struct TheaterControls: View {
    /// Jumps to the neighbouring episodes of a show (a nil action is unavailable).
    struct EpisodeSkips {
        var previous: (() -> Void)?
        var next: (() -> Void)?
        var previousName: String?
        var nextName: String?
    }

    @Bindable var engine: TheaterEngine
    var episodes: EpisodeSkips?
    /// A narrow window: a shorter volume slider.
    var isCompact = false
    /// "Find Subtitles…" sheet.
    @Binding var subtitleSearch: SubtitleSearchTarget?
    let onToggleFullScreen: () -> Void
    /// Shrinks the player to picture-in-picture (the bar's last, lower-right control).
    let onPictureInPicture: () -> Void
    /// Google Cast, DLNA, and Roku devices (and the AirPlay picker).
    let castButton: CastButton

    var body: some View {
        VStack(spacing: 12) {
            // The only part of the bar that follows the playback position.
            TheaterTimeline(engine: engine)

            ZStack {
            // Play and skip sit in the center, in the app's button styles.
            HStack(spacing: isCompact ? 16 : 22) {
                if let episodes {
                    Button { episodes.previous?() } label: {
                        Image(systemName: "backward.end.fill").frame(width: 30, height: 30)
                    }
                    .buttonStyle(.theaterPlainCircle)
                    .disabled(episodes.previous == nil)
                    .help(episodes.previousName.map { "Previous episode: \($0) (⇧←)" } ?? "No previous episode")
                    .accessibilityLabel("Previous episode")
                    .accessibilityValue(episodes.previousName ?? "")
                }
                Button { engine.skip(by: -10) } label: {
                    Image(systemName: "gobackward.10").frame(width: 30, height: 30)
                }
                .buttonStyle(.theaterPlainCircle)
                .help("Back 10 seconds (←)")
                .accessibilityLabel("Back 10 seconds")
                Button { engine.togglePlayback() } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(width: 56, height: 56)
                        .background(.white, in: .circle)
                        .contentTransition(.symbolEffect(.replace))
                        .contentShape(.circle)
                }
                .help("Play/Pause (Space)")
                .accessibilityLabel(engine.isPlaying ? "Pause" : "Play")
                Button { engine.skip(by: 10) } label: {
                    Image(systemName: "goforward.10").frame(width: 30, height: 30)
                }
                .buttonStyle(.theaterPlainCircle)
                .help("Forward 10 seconds (→)")
                .accessibilityLabel("Forward 10 seconds")
                if let episodes {
                    Button { episodes.next?() } label: {
                        Image(systemName: "forward.end.fill").frame(width: 30, height: 30)
                    }
                    .buttonStyle(.theaterPlainCircle)
                    .disabled(episodes.next == nil)
                    .help(episodes.nextName.map { "Next episode: \($0) (⇧→)" } ?? "No next episode")
                    .accessibilityLabel("Next episode")
                    .accessibilityValue(episodes.nextName ?? "")
                }
            }

            HStack(spacing: isCompact ? 12 : 18) {

                if !engine.trackList.audio.isEmpty {
                    Menu {
                        Picker("Audio", selection: Binding(get: { engine.selectedAudioID ?? "" }, set: engine.selectAudio)) {
                            ForEach(engine.trackList.audio) { option in
                                Text([option.title, option.detail].compactMap { $0 }.joined(separator: " · "))
                                    .tag(option.id)
                                    .disabled(!option.isSupported)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Image(systemName: "waveform")
                    }
                    .menuIndicator(.hidden)
                    .help("Audio")
                    .accessibilityLabel("Audio track")
                }

                Menu {
                    Picker("Subtitles", selection: Binding(get: { engine.selectedSubtitleID ?? "off" },
                                                           set: { engine.selectSubtitle($0 == "off" ? nil : $0) })) {
                        Text("Off").tag("off")
                        ForEach(engine.trackList.subtitles) { option in
                            Text([option.title, option.detail].compactMap { $0 }.joined(separator: " · "))
                                .tag(option.id)
                                .disabled(!option.isSupported)
                        }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Button("Find Subtitles…", systemImage: "magnifyingglass") { subtitleSearch = engine.subtitleSearchTarget }
                        .disabled(engine.subtitleSearchTarget == nil)
                } label: {
                    Image(systemName: engine.selectedSubtitleID == nil ? "captions.bubble" : "captions.bubble.fill")
                }
                .menuIndicator(.hidden)
                .help("Subtitles")
                .accessibilityLabel("Subtitles")
                .sheet(item: $subtitleSearch) { target in
                    SubtitleSearchView(target: target) { subtitle in
                        Task { await engine.addExternalSubtitle(subtitle) }
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    Button { engine.isMuted.toggle() } label: {
                        Image(systemName: engine.isMuted || engine.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: 22)
                    }
                    .help("Mute (M)")
                    .accessibilityLabel(engine.isMuted ? "Unmute" : "Mute")
                    Slider(value: $engine.volume, in: 0...1)
                        .frame(width: isCompact ? 60 : 90)
                        .tint(.white)
                        .accessibilityLabel("Volume")
                }

                castButton

                AirPlayControls()

                Button(action: onToggleFullScreen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help("Full Screen (F)")
                .accessibilityLabel("Toggle full screen")

                Button(action: onPictureInPicture) {
                    Image(systemName: "pip.enter")
                }
                .help("Picture in Picture: keep watching while you browse (Esc)")
                .accessibilityLabel("Picture in picture")
            }
            }
            .font(.title3)
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, isCompact ? 16 : 22)
        .padding(.vertical, 16)
    }
}

/// The scrubber with elapsed and remaining time. Reads the playback position, so it redraws as
/// playback advances while the rest of the transport bar doesn't.
private struct TheaterTimeline: View {
    @Bindable var engine: TheaterEngine
    @State private var scrubPosition: Double?

    /// The duration as a usable slider bound: finite, positive, and within what's shown.
    private var safeDuration: Double {
        let duration = engine.duration
        guard duration.isFinite, duration > 0 else { return 1 }
        return min(max(duration, 1), TheaterControlsTime.maximumSeconds)
    }

    private var shownTime: Double {
        let time = scrubPosition ?? engine.currentTime
        return time.isFinite ? min(max(time, 0), safeDuration) : 0
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(TheaterControlsTime.format(shownTime))
                .monospacedDigit()
                .accessibilityLabel("Elapsed \(TheaterControlsTime.spoken(shownTime))")
            Slider(value: Binding(get: { shownTime }, set: { scrubPosition = $0 }),
                   in: 0...safeDuration) { editing in
                if !editing, let target = scrubPosition {
                    engine.seek(to: target)
                    scrubPosition = nil
                }
            }
            .tint(Theme.accent)
            .accessibilityLabel("Playback position")
            .accessibilityValue(TheaterControlsTime.spoken(shownTime))
            Text("-" + TheaterControlsTime.format(max(safeDuration - shownTime, 0)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityLabel("Remaining \(TheaterControlsTime.spoken(max(safeDuration - shownTime, 0)))")
        }
        .font(.callout)
    }
}

/// Player keys the Playback menu doesn't carry: the volume arrows. (Space, ← →, S, M, and F
/// are in the Playback menu.)
private struct TheaterKeyCommands: View {
    let engine: TheaterEngine
    let onActivity: () -> Void

    var body: some View {
        ZStack {
            shortcut(.upArrow) { engine.volume = min(engine.volume + 0.1, 1) }
            shortcut(.downArrow) { engine.volume = max(engine.volume - 0.1, 0) }
        }
        .hidden()
    }

    private func shortcut(_ key: KeyEquivalent, action: @escaping () -> Void) -> some View {
        Button("") {
            action()
            onActivity()
        }
        .keyboardShortcut(key, modifiers: [])
    }
}

/// Time formatting shared by player overlays.
enum TheaterControlsTime {
    /// "1:02:03", or "2:03" under an hour.
    /// The longest time shown (99:59:59); anything beyond (or not finite) is clamped, so a
    /// damaged duration can't overflow the conversion to whole seconds.
    static let maximumSeconds: Double = 99 * 3600 + 59 * 60 + 59

    /// Whole seconds in 0…`maximumSeconds`; non-finite values count as zero.
    static func clampedSeconds(_ seconds: Double) -> Int {
        guard seconds.isFinite else { return 0 }
        return Int(min(max(seconds, 0), maximumSeconds))
    }

    static func format(_ seconds: Double) -> String {
        let total = clampedSeconds(seconds)
        let duration = Duration.seconds(total)
        return duration.formatted(.time(pattern: total >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    /// "1 hour, 2 minutes, 3 seconds", for VoiceOver.
    static func spoken(_ seconds: Double) -> String {
        let total = clampedSeconds(seconds)
        return Duration.seconds(total).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
}

/// Controls for the picture-in-picture player: play/pause, expand, and close. They fade in on
/// hover but are always there, so VoiceOver and the keyboard can reach them.
private struct MiniPlayerControls: View {
    /// The engine, or the Apple TV / cast device while it has the picture.
    let transport: (any PlaybackTransport)?
    let onExpand: () -> Void
    let onClose: () -> Void
    @State private var isHovered = false

    var body: some View {
        ZStack {
            Color.black.opacity(isHovered ? 0.35 : 0)
                .allowsHitTesting(false)
            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 14) {
                    Button(action: onExpand) { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 28, height: 28) }
                        .help("Return to full player")
                        .accessibilityLabel("Return to full player")
                    Button { transport?.togglePlayback() } label: {
                        Image(systemName: transport?.isPlaying == true ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .frame(width: 36, height: 36)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .help("Play/Pause")
                    .accessibilityLabel(transport?.isPlaying == true ? "Pause" : "Play")
                    Button(action: onClose) { Image(systemName: "xmark").frame(width: 28, height: 28) }
                        .help("Stop and close")
                        .accessibilityLabel("Stop and close player")
                }
                .buttonStyle(.theaterGlassCircle)
                .foregroundStyle(.white)
            }
            .opacity(isHovered ? 1 : 0)
            if let transport, transport.duration > 0 {
                MiniPlayerProgress(transport: transport)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .opacity(isHovered ? 1 : 0)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(.rect)
        .onTapGesture(count: 2, perform: onExpand)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.18)) { isHovered = hovering } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Picture in picture player")
    }
}

/// The picture-in-picture progress bar; the only part of the mini player that follows the time.
private struct MiniPlayerProgress: View {
    let transport: any PlaybackTransport

    var body: some View {
        WatchProgressBar(fraction: transport.duration > 0 ? transport.currentTime / transport.duration : 0)
    }
}

/// Grows a view's height upward from its bottom edge: at 0 it's flat, at 1 it's the content's
/// natural height. Only the frame changes, so anything applied afterwards (the glass) grows too.
private struct GrowUpward: ViewModifier, Animatable {
    var progress: CGFloat
    @State private var naturalHeight: CGFloat = 0

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { naturalHeight = $0 }
            .frame(height: naturalHeight > 0 ? max(naturalHeight * progress, 0) : nil, alignment: .bottom)
            .clipped()
    }
}

/// Close, minimise, and zoom buttons drawn like the system's, for the player's top bar.
private struct WindowTrafficLights: View {
    let window: NSWindow?
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            light(Color(red: 1, green: 0.37, blue: 0.34), symbol: "xmark", label: "Close") {
                window?.performClose(nil)
            }
            light(Color(red: 1, green: 0.74, blue: 0.18), symbol: "minus", label: "Minimize") {
                window?.performMiniaturize(nil)
            }
            light(Color(red: 0.16, green: 0.79, blue: 0.25), symbol: "plus", label: "Zoom") {
                window?.performZoom(nil)
            }
        }
        .onHover { isHovered = $0 }
    }

    private func light(_ color: Color, symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(.black.opacity(0.6))
                        .opacity(isHovered ? 1 : 0)
                }
                .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
