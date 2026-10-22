//
//  PlayerView.swift
//  Ultimate Theater
//

import SwiftUI
import SwiftData
import AVFoundation

/// Immersive full-window player built on the Theater engine, with our own transport,
/// subtitles, chapters, Skip Intro, Up Next, and the episode picker.
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
    @State private var fileError: String?
    /// Pointer is in the bottom band of the player, where chapters appear.
    @State private var isPointerNearBottom = false
    @State private var viewHeight: CGFloat = 0
    @State private var thumbnails: ThumbnailGenerator?
    /// Playback ID whose file security scope is currently open.
    @State private var openFileID: String?

    init(item: PlaybackItem, startPosition: Double, startSelection: PlaybackSelection?) {
        self.startPosition = startPosition
        self.startSelection = startSelection
        _current = State(initialValue: item)
    }

    private var position: Double { engine?.currentTime ?? 0 }
    private var duration: Double { engine?.duration ?? 0 }
    private var remaining: Double { max(duration - position, 0) }
    private var failure: String? { fileError ?? engine?.failure }

    private var nextEpisode: Episode? {
        guard let episode = current.episode else { return nil }
        return current.title.episode(after: episode)
    }

    /// From the file's chapter markers ("Intro", "Opening", …), when present.
    private var introRange: Range<Double>? {
        guard let chapter = engine?.chapters.first(where: { chapter in
            ["intro", "opening", "title sequence", "main title"].contains { chapter.title.lowercased().contains($0) }
        }), let end = chapter.end ?? nextChapterStart(after: chapter), end > chapter.start else { return nil }
        return chapter.start..<end
    }

    private var creditsStart: Double? {
        engine?.chapters.first { chapter in
            ["credits", "end titles", "ending"].contains { chapter.title.lowercased().contains($0) }
        }?.start
    }

    private func nextChapterStart(after chapter: PlaybackChapter) -> Double? {
        engine?.chapters.first { $0.start > chapter.start }?.start
    }

    /// Chapters long enough to be worth listing (some files mark every scene).
    private var chapters: [PlaybackChapter] {
        (engine?.chapters ?? []).sorted { $0.start < $1.start }
    }

    private var showsChapters: Bool {
        isPointerNearBottom && chapters.count > 1 && duration > 0 && failure == nil
    }

    private var showsSkipIntro: Bool {
        guard let introRange else { return false }
        return introRange.contains(position) && introRange.upperBound - position > 1
    }

    /// Shows at a "Credits" chapter if the file has one, otherwise in the last 20 seconds.
    private var showsUpNext: Bool {
        guard nextEpisode != nil, duration > 0, !isUpNextDismissed else { return false }
        if let creditsStart { return position >= creditsStart }
        return remaining <= min(20, duration * 0.2)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            surface
                .ignoresSafeArea()

            if let engine {
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

            topBar
                .frame(maxHeight: .infinity, alignment: .top)
                .opacity(isChromeVisible ? 1 : 0)

            if let engine, failure == nil {
                TheaterControls(engine: engine)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .opacity(isChromeVisible ? 1 : 0)
                    .allowsHitTesting(isChromeVisible)
            }

            if let engine, engine.hasStarted, !engine.isPlaying, failure == nil, !showsChapters {
                pausedInfo
                    .transition(.opacity)
            }

            if showsChapters {
                ChapterBar(chapters: chapters, duration: duration, position: position, thumbnails: thumbnails) { chapter in
                    engine?.seek(to: chapter.start)
                    revealChrome()
                }
                .padding(.horizontal, 60)
                .padding(.bottom, 150)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            VStack(alignment: .trailing, spacing: 16) {
                if showsUpNext, let nextEpisode {
                    UpNextCard(title: current.title, episode: nextEpisode, secondsRemaining: Int(remaining.rounded(.up)),
                               onPlay: { playNext() },
                               onDismiss: { withAnimation(.snappy) { isUpNextDismissed = true } })
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if showsSkipIntro {
                    Button {
                        if let introRange { engine?.seek(to: introRange.upperBound) }
                    } label: {
                        Label("Skip Intro", systemImage: "forward.end.fill")
                            .font(.headline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.glass)
                    .keyboardShortcut("s", modifiers: [])
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .padding(.trailing, 40)
            // Clear the transport controls (and the chapter strip when it's showing).
            .padding(.bottom, 150 + (showsChapters ? 230 : 0))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .animation(.smooth, value: showsSkipIntro)
            .animation(.smooth, value: showsUpNext)
            .animation(.smooth, value: showsChapters)

            // Escape closes the player.
            Button("Close Player", action: close)
                .keyboardShortcut(.cancelAction)
                .hidden()

            if let engine {
                TheaterKeyCommands(engine: engine, onActivity: revealChrome)
            }
        }
        .preferredColorScheme(.dark)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewHeight = $0 }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                revealChrome()
                let nearBottom = location.y > viewHeight - 300
                if nearBottom != isPointerNearBottom {
                    withAnimation(.smooth(duration: 0.25)) { isPointerNearBottom = nearBottom }
                }
            case .ended:
                withAnimation(.smooth(duration: 0.25)) { isPointerNearBottom = false }
            }
        }
        .task(id: current.id) {
            let isFirstItem = current.id == model.nowPlaying?.id
            await load(current, from: isFirstItem ? startPosition : 0, selection: isFirstItem ? startSelection : nil)
            await monitorPlayback()
        }
        .onDisappear {
            saveProgress()
            engine?.shutdown()
            closeFile()
            NSCursor.setHiddenUntilMouseMoves(false)
        }
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
            Button("Close", action: close)
                .buttonStyle(.glass)
        }
        .foregroundStyle(.white)
        .padding(32)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    // MARK: Chrome

    /// While paused, the title's details over a darkened picture, like the app's title pages.
    private var pausedInfo: some View {
        let synopsis = current.episode.map(\.synopsis).flatMap { $0.isEmpty ? nil : $0 } ?? current.title.synopsis
        return VStack(alignment: .leading, spacing: 10) {
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

    private var topBar: some View {
        HStack(alignment: .center, spacing: 16) {
            Button(action: close) {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("Back (Esc)")
            .accessibilityLabel("Close player")

            // The title card, styled like the app's title pages.
            HStack(spacing: 14) {
                ArtworkView(title: current.title, style: .poster)
                    .frame(width: 40, height: 60)
                    .clipShape(.rect(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 3) {
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
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 18)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))

            Spacer()

            if let warning = engine?.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .frame(maxWidth: 420, alignment: .trailing)
            }

            if current.title.kind == .series {
                episodeMenu
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 48)
        .background {
            LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    private var episodeMenu: some View {
        Menu {
            ForEach(current.title.seasons) { season in
                Section(season.name) {
                    ForEach(season.episodes) { episode in
                        Button {
                            switchTo(PlaybackItem(title: current.title, episode: episode))
                        } label: {
                            if episode.id == current.episode?.id {
                                Label("\(episode.number). \(episode.name)", systemImage: "speaker.wave.2.fill")
                            } else {
                                Text("\(episode.number). \(episode.name)")
                            }
                        }
                    }
                }
            }
        } label: {
            Label("Episodes", systemImage: "rectangle.stack.fill")
                .font(.headline)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
    }

    private func revealChrome() {
        lastActivity = .now
        if !isChromeVisible {
            withAnimation(.easeOut(duration: 0.2)) { isChromeVisible = true }
        }
    }

    // MARK: Playback

    private func load(_ item: PlaybackItem, from start: Double, selection explicit: PlaybackSelection?) async {
        engine?.shutdown()
        engine = nil
        fileError = nil
        isUpNextDismissed = false
        closeFile()
        guard let url = model.library.beginPlayback(item.id) else {
            let path = model.library.filePath(for: item.id) ?? "The video file"
            fileError = "\(path) couldn't be found. If it's on an external drive, connect it and try again. Otherwise, add the file again."
            return
        }
        openFileID = item.id
        thumbnails = ThumbnailGenerator(url: url)

        // An explicit choice from the detail page wins; otherwise use what this profile saved.
        let selection = explicit ?? model.profile.flatMap { profile in
            model.playbackPreferences.selection(profileID: profile.id, titleID: item.title.id)
        }
        let newEngine = TheaterEngine()
        engine = newEngine
        await newEngine.load(url, start: start, selection: selection)
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

            if isChromeVisible, engine.isPlaying, Date.now.timeIntervalSince(lastActivity) > 3 {
                withAnimation(.easeIn(duration: 0.4)) {
                    isChromeVisible = false
                    isPointerNearBottom = false
                }
                NSCursor.setHiddenUntilMouseMoves(true)
            }

            let reachedEnd = duration > 0 && position >= duration - 0.6
            if reachedEnd {
                saveProgress()
                if nextEpisode != nil, !isUpNextDismissed {
                    playNext()
                    return
                }
                revealChrome()
            }
        }
    }

    private func playNext() {
        guard let nextEpisode else { return }
        switchTo(PlaybackItem(title: current.title, episode: nextEpisode))
    }

    private func switchTo(_ item: PlaybackItem) {
        saveProgress()
        current = item // Restarts the `.task(id:)`, which loads the new item.
    }

    private func closeFile() {
        if let openFileID {
            model.library.endPlayback(openFileID)
            self.openFileID = nil
        }
    }

    private func saveProgress() {
        guard let profile = model.profile, duration > 0 else { return }
        WatchHistory.saveProgress(current, profileID: profile.id, position: position, duration: duration, in: modelContext)
    }

    private func close() {
        saveProgress()
        engine?.shutdown()
        closeFile()
        model.stopPlayback()
    }
}

/// Chapter and scene markers: a timeline with a marker at each chapter, plus named tiles.
private struct ChapterBar: View {
    let chapters: [PlaybackChapter]
    let duration: Double
    let position: Double
    let thumbnails: ThumbnailGenerator?
    let onSelect: (PlaybackChapter) -> Void

    @State private var hovered: PlaybackChapter?
    /// Time under the pointer on the timeline, for the frame preview.
    @State private var hoveredTime: Double?
    @State private var timelineWidth: CGFloat = 1

    private var current: PlaybackChapter? {
        chapters.last { $0.start <= position + 0.5 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Chapters", systemImage: "list.bullet.rectangle")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let chapter = hovered ?? current {
                    Text(chapter.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
            }

            timeline
                .overlay(alignment: .bottomLeading) {
                    if let hoveredTime {
                        FramePreview(time: hoveredTime, thumbnails: thumbnails)
                            .offset(x: min(max(timelineWidth * hoveredTime / duration - 90, 0), timelineWidth - 180), y: -28)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .zIndex(1)

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(Array(chapters.enumerated()), id: \.element) { index, chapter in
                            tile(chapter, number: index + 1)
                                .id(chapter)
                        }
                    }
                }
                .scrollIndicators(.never)
                .onAppear {
                    if let current { proxy.scrollTo(current, anchor: .center) }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: 1000)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    /// The whole runtime, with a tick at each chapter start and the playhead.
    private var timeline: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18)).frame(height: 4)
                Capsule().fill(Theme.accent).frame(width: width * min(position / duration, 1), height: 4)
                ForEach(chapters, id: \.self) { chapter in
                    let x = width * min(chapter.start / duration, 1)
                    Rectangle()
                        .fill(chapter == hovered || chapter == current ? .white : .white.opacity(0.6))
                        .frame(width: 2, height: chapter == hovered ? 16 : 10)
                        .offset(x: x - 1)
                }
            }
            .frame(height: 16)
            .contentShape(.rect)
            .onContinuousHover { phase in
                if case .active(let location) = phase {
                    let time = min(max(Double(location.x / max(width, 1)) * duration, 0), duration)
                    hovered = chapters.last { $0.start <= time }
                    hoveredTime = time
                } else {
                    hovered = nil
                    hoveredTime = nil
                }
            }
            .onAppear { timelineWidth = width }
            .onChange(of: width) { _, newWidth in timelineWidth = newWidth }
            .onTapGesture { location in
                let time = Double(location.x / max(width, 1)) * duration
                if let chapter = chapters.last(where: { $0.start <= time }) { onSelect(chapter) }
            }
        }
        .frame(height: 16)
        .accessibilityHidden(true)
    }

    private func tile(_ chapter: PlaybackChapter, number: Int) -> some View {
        let isCurrent = chapter == current
        return Button { onSelect(chapter) } label: {
            VStack(alignment: .leading, spacing: 4) {
                ChapterThumbnail(time: Self.representativeTime(of: chapter), thumbnails: thumbnails)
                    .frame(width: 150, height: 84)
                    .clipShape(.rect(cornerRadius: 8))
                HStack(spacing: 6) {
                    Text("\(number)")
                        .font(.caption.weight(.heavy))
                        .monospacedDigit()
                        .foregroundStyle(isCurrent ? Theme.accent : .secondary)
                    if isCurrent {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.accent)
                    }
                }
                Text(chapter.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(Self.format(chapter.start))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(width: 150, height: 162, alignment: .topLeading)
            .padding(10)
            .background(.white.opacity(isCurrent ? 0.16 : (chapter == hovered ? 0.1 : 0.05)), in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isCurrent ? Theme.accent.opacity(0.8) : .clear, lineWidth: 1.5)
            }
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? chapter : (hovered == chapter ? nil : hovered) }
        .help("Jump to \(chapter.title)")
        .accessibilityLabel("Chapter \(number), \(chapter.title), at \(Self.format(chapter.start))")
    }

    /// A few seconds in, past any fade from black at the chapter boundary.
    static func representativeTime(of chapter: PlaybackChapter) -> Double {
        let length = (chapter.end ?? chapter.start + 60) - chapter.start
        return chapter.start + min(10, max(length / 4, 0))
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}

/// A still frame from the video, loaded on demand.
private struct ChapterThumbnail: View {
    let time: Double
    let thumbnails: ThumbnailGenerator?
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.white.opacity(0.06)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: "film")
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
        .clipped()
        .task(id: Int(time / 5)) {
            guard let thumbnails else { return }
            let frame = await thumbnails.image(at: time)
            withAnimation(.easeOut(duration: 0.2)) { image = frame }
        }
    }
}

/// Floating frame preview above the chapter timeline.
private struct FramePreview: View {
    let time: Double
    let thumbnails: ThumbnailGenerator?

    var body: some View {
        VStack(spacing: 6) {
            ChapterThumbnail(time: time, thumbnails: thumbnails)
                .frame(width: 180, height: 101)
                .clipShape(.rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.5), lineWidth: 1))
            Text(ChapterBar.format(time))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.black.opacity(0.6), in: .capsule)
        }
        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
    }
}

/// Netflix-style "Next Episode" countdown card.
private struct UpNextCard: View {
    let title: Title
    let episode: Episode
    let secondsRemaining: Int
    let onPlay: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            ArtworkView(title: title, style: .backdrop)
                .frame(width: 150, height: 84)
                .clipShape(.rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text("UP NEXT IN \(secondsRemaining)")
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
                        .buttonStyle(.glass)
                }
            }
        }
        .padding(14)
        .frame(width: 440)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .foregroundStyle(.white)
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
            hostedLayer?.frame = bounds
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

/// Transport bar for the Theater engine.
private struct TheaterControls: View {
    @Bindable var engine: TheaterEngine
    @State private var scrubPosition: Double?

    private var shownTime: Double { scrubPosition ?? engine.currentTime }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Text(Self.format(shownTime))
                    .monospacedDigit()
                Slider(value: Binding(get: { shownTime }, set: { scrubPosition = $0 }),
                       in: 0...max(engine.duration, 1)) { editing in
                    if !editing, let target = scrubPosition {
                        engine.seek(to: target)
                        scrubPosition = nil
                    }
                }
                .tint(Theme.accent)
                .accessibilityLabel("Playback position")
                Text("-" + Self.format(max(engine.duration - shownTime, 0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            ZStack {
            // Play and skip sit in the center, in the app's button styles.
            HStack(spacing: 22) {
                Button { engine.skip(by: -10) } label: {
                    Image(systemName: "gobackward.10").frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Back 10 seconds (←)")
                Button { engine.togglePlayback() } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 56, height: 56)
                        .background(.white, in: .circle)
                        .contentTransition(.symbolEffect(.replace))
                        .contentShape(.circle)
                }
                .help("Play/Pause (Space)")
                Button { engine.skip(by: 10) } label: {
                    Image(systemName: "goforward.10").frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Forward 10 seconds (→)")
            }

            HStack(spacing: 18) {

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
                } label: {
                    Image(systemName: engine.selectedSubtitleID == nil ? "captions.bubble" : "captions.bubble.fill")
                }
                .menuIndicator(.hidden)
                .help("Subtitles")
                .disabled(engine.trackList.subtitles.isEmpty)

                Spacer()

                HStack(spacing: 8) {
                    Button { engine.isMuted.toggle() } label: {
                        Image(systemName: engine.isMuted || engine.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: 22)
                    }
                    .help("Mute (M)")
                    Slider(value: $engine.volume, in: 0...1)
                        .frame(width: 90)
                        .tint(.white)
                        .accessibilityLabel("Volume")
                }

                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help("Full Screen (F)")
            }
            }
            .font(.title3)
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(.horizontal, 40)
        .padding(.bottom, 28)
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}

/// Player keyboard shortcuts: Space, arrows, M (mute), and F (full screen).
private struct TheaterKeyCommands: View {
    let engine: TheaterEngine
    let onActivity: () -> Void

    var body: some View {
        ZStack {
            shortcut(.space) { engine.togglePlayback() }
            shortcut(.leftArrow) { engine.skip(by: -10) }
            shortcut(.rightArrow) { engine.skip(by: 10) }
            shortcut(.upArrow) { engine.volume = min(engine.volume + 0.1, 1) }
            shortcut(.downArrow) { engine.volume = max(engine.volume - 0.1, 0) }
            shortcut("m") { engine.isMuted.toggle() }
            shortcut("f") { NSApp.keyWindow?.toggleFullScreen(nil) }
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
