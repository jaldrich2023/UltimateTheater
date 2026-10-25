//
//  TitleDetailView.swift
//  Ultimate Theater
//

import SwiftUI
import SwiftData

struct TitleDetailView: View {
    @Environment(AppModel.self) private var model
    let titleID: String

    var body: some View {
        // Its queries are scoped to this title and profile, so they're rebuilt when the profile changes.
        TitleDetailPage(titleID: titleID, profileID: model.profile?.id ?? "")
            .id(model.profile?.id)
    }
}

private struct TitleDetailPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var modelContext
    /// This profile's rating of this title (at most one).
    @Query private var ratings: [UserRating]
    /// This profile's saved scenes in this title, in time order.
    @Query private var scenes: [SceneBookmark]
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 60

    let titleID: String
    let profileID: String

    init(titleID: String, profileID: String) {
        self.titleID = titleID
        self.profileID = profileID
        _ratings = Query(filter: #Predicate<UserRating> { $0.profileID == profileID && $0.titleID == titleID })
        _scenes = Query(filter: #Predicate<SceneBookmark> { $0.profileID == profileID && $0.titleID == titleID },
                        sort: \.time)
    }
    @State private var selectedSeason = 1
    @State private var isConfirmingRemoval = false
    @State private var isConfirmingDelete = false
    @State private var trackChoice = TrackChoice()
    /// "Find Subtitles…" sheet for this movie or episode.
    @State private var findingSubtitles: SubtitleSearchTarget?
    @State private var isShowingTrailer = false
    /// Play request waiting on the "use these settings every time?" answer.
    @State private var pendingPlay: PendingPlay?
    /// The damaged file being repaired, if the repair sheet is open.
    @State private var repairing: PlaybackItem?
    /// The scroll view's visible height; the header is at least most of it.
    @State private var viewportHeight: CGFloat = 0

    private struct PendingPlay: Identifiable {
        let item: PlaybackItem
        let position: Double
        var id: String { item.id }
    }

    /// Read live from the profile's catalog (rebuilt on refreshes and edits), so a title the
    /// profile's rating limit hides never shows. The administrator also sees titles not yet
    /// in the catalog straight from the library.
    private var title: Title? {
        model.titleByID[titleID]
            ?? (model.canManageLibrary ? model.library.titles.first { $0.id == titleID } : nil)
    }

    /// This profile's history for the title, from the model's cached watch history.
    private func progress(for title: Title) -> [WatchProgress] {
        model.watchProgressByTitle[title.id] ?? []
    }

    private var userScore: Double? { ratings.first?.score }

    var body: some View {
        if let title {
            content(for: title)
        } else {
            ContentUnavailableView("Title Removed", systemImage: "film",
                                   description: Text("This title is no longer in your library."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(for title: Title) -> some View {
        let progress = progress(for: title)
        let resume = WatchHistory.resumePoint(for: title, in: progress)
        let resumeEntry = progress.first { $0.playbackID == resume.item.id }

        return ScrollView {
            VStack(alignment: .leading, spacing: 44) {
                header(title, resume: resume, resumeEntry: resumeEntry)

                if title.kind == .series {
                    episodes(title, progress: progress)
                }

                details(title)

                favouriteScenes(title)

                let similar = WatchHistory.similar(to: title, in: model.titles)
                if !similar.isEmpty {
                    Shelf(title: "More Like This", items: similar) { item in
                        PosterCard(title: item)
                    }
                }
            }
            .padding(.bottom, 60)
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, height in
            viewportHeight = height
        }
        .ignoresSafeArea(edges: .top)
        .background { AppBackground() }
        .navigationTitle(title.name)
        .toolbar {
            if model.canManageLibrary {
                ToolbarItem {
                    libraryMenu(title)
                }
            }
        }
        .sheet(item: $repairing) { item in
            RepairView(title: item.title, playbackID: item.id)
        }
        .sheet(item: $findingSubtitles) { target in
            SubtitleSearchView(target: target) { subtitle in
                Task {
                    await loadTracks(for: target.item, title: title)
                    if trackChoice.list?.subtitles.contains(where: { $0.id == subtitle.id }) == true {
                        trackChoice.subtitleID = subtitle.id
                    }
                }
            }
        }
        .confirmationDialog("Delete “\(title.name)”?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Remove from Library", role: .destructive) {
                model.manageLibrary("Enter the administrator PIN to remove “\(title.name)”.") {
                    model.close(title.id)
                    model.library.remove(title.id)
                }
            }
            Button(title.kind == .movie ? "Move File to Trash" : "Move All Episode Files to Trash", role: .destructive) {
                model.manageLibrary("Enter the administrator PIN to move “\(title.name)” to the Trash.") {
                    model.close(title.id)
                    model.library.moveToTrash(title.id)
                }
            }
        } message: {
            Text("Removing keeps the video files on disk. Moving them to the Trash deletes them from your library and your Mac.")
        }
        .confirmationDialog("Remove “\(title.name)” from your library?", isPresented: $isConfirmingRemoval) {
            Button("Remove from Library", role: .destructive) {
                model.manageLibrary("Enter the administrator PIN to remove “\(title.name)”.") {
                    model.close(title.id)
                    model.library.remove(title.id)
                }
            }
        } message: {
            Text("The video files stay on your Mac. You can add them again at any time.")
        }
        .confirmationDialog("Use these audio and subtitle settings every time?",
                            isPresented: Binding(get: { pendingPlay != nil }, set: { if !$0 { pendingPlay = nil } }),
                            presenting: pendingPlay) { request in
            Button("Always Use These Settings") { remember(.all, title: title, then: request) }
            Button(title.kind == .movie ? "Use for This Movie Only" : "Use for This Show Only") {
                remember(.title, title: title, then: request)
            }
            Button("Just This Time") { start(request) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(settingsSummary)
        }
        .onAppear {
            // Open on the season the viewer is currently in.
            if let season = resume.item.episode?.season ?? title.seasons.first?.number {
                selectedSeason = season
            }
        }
        .task(id: resume.item.id) {
            await loadTracks(for: resume.item, title: title)
        }
    }

    // MARK: Audio & subtitles

    private enum RememberScope { case all, title }

    private var settingsSummary: String {
        let audio = trackChoice.audio.map { TrackPickers.label($0) } ?? "Default audio"
        let subtitles = trackChoice.subtitle.map { "\($0.title) subtitles" } ?? "no subtitles"
        return "\(audio), \(subtitles)."
    }

    private func loadTracks(for item: PlaybackItem, title: Title) async {
        guard item.isPlayable,
              let list = await model.library.withFileAccess(item.id, { await MediaInspector.trackList(for: $0, playbackID: item.id) }) else {
            trackChoice = TrackChoice()
            return
        }
        let saved = model.profile.flatMap { model.playbackPreferences.selection(profileID: $0.id, titleID: title.id) }
        trackChoice = TrackChoice(list: list, saved: saved)
    }

    /// Plays now, or first asks whether to keep changed audio/subtitle settings.
    private func requestPlay(_ item: PlaybackItem, from position: Double) {
        if trackChoice.isCustomized {
            pendingPlay = PendingPlay(item: item, position: position)
        } else {
            start(PendingPlay(item: item, position: position))
        }
    }

    private func start(_ request: PendingPlay) {
        model.play(request.item, from: request.position, selection: trackChoice.selection)
    }

    private func remember(_ scope: RememberScope, title: Title, then request: PendingPlay) {
        if let profile = model.profile, let selection = trackChoice.selection {
            switch scope {
            case .all: model.playbackPreferences.saveDefault(selection, profileID: profile.id)
            case .title: model.playbackPreferences.save(selection, profileID: profile.id, titleID: title.id)
            }
            trackChoice.markSaved()
        }
        start(request)
    }

    // MARK: Header

    private func header(_ title: Title, resume: (item: PlaybackItem, position: Double, label: String),
                        resumeEntry: WatchProgress?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title.name)
                .font(.system(size: titleSize, weight: .black))
                .fontWidth(.condensed)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
            MetadataLine(title: title)
            RatingsRow(ratings: title.ratings, userScore: userScore) { score in
                model.setRating(score, for: title)
            }
            if !title.tagline.isEmpty {
                Text(title.tagline)
                    .font(.title3.italic())
                    .foregroundStyle(.white.opacity(0.7))
            }
            if !title.synopsis.isEmpty {
                Text(title.synopsis)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(6)
                    .frame(maxWidth: 620, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if title.needsMatch {
                notice("This title wasn't recognized automatically.", systemImage: "questionmark.circle.fill",
                       action: model.canManageLibrary ? ("Fix Match…", { model.fixMatch(title) }) : nil)
            }
            if !resume.item.isPlayable {
                let issue = resume.item.episode?.playbackIssue ?? title.playbackIssue
                notice(issue?.message ?? "This file can't be played.", systemImage: "exclamationmark.triangle.fill",
                       action: issue?.isDamage == true && model.canManageLibrary ? ("Repair…", {
                           let item = resume.item
                           model.manageLibrary("Enter the administrator PIN to repair this file.") { repairing = item }
                       }) : nil)
            }

            actions(title, resume: resume, resumeEntry: resumeEntry)
                .padding(.top, 4)

            TrackPickers(choice: $trackChoice, onFindSubtitles: resume.item.isPlayable ? {
                findingSubtitles = SubtitleSearchTarget(item: resume.item, library: model.library)
            } : nil)

            credits(title)

            if let collection = title.collection {
                Button { model.open(collection) } label: {
                    Label("Part of \(collection.name)", systemImage: "square.stack.3d.up.fill")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.theaterGlass)
                .help("See every movie in this collection")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, pageMargin)
        .padding(.top, 60)
        .padding(.bottom, 24)
        // At least most of the window tall, but as tall as the text and buttons need: the
        // content decides the height and the backdrop fills in behind it, so nothing is cut
        // off in a short window.
        .frame(maxWidth: .infinity, minHeight: max(viewportHeight * 0.8, 520), alignment: .bottomLeading)
        .background {
            ZStack {
                ArtworkView(title: title, style: .backdrop)
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.9), location: 0),
                    .init(color: .black.opacity(0.4), location: 0.5),
                    .init(color: .clear, location: 0.85),
                ], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, .clear, Theme.background], startPoint: .top, endPoint: .bottom)
            }
            .backgroundExtensionEffect()
            // Full width from the first frame: no layout animation slides it into place.
            .transaction { $0.animation = nil }
            .overlay(alignment: .bottom) { ArtEdgeDivider() }
        }
        .clipped()
    }

    @ViewBuilder
    private func credits(_ title: Title) -> some View {
        if !title.cast.isEmpty || !title.director.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if !title.cast.isEmpty {
                    Text("\(Text("Starring").foregroundStyle(.secondary)) \(title.cast.prefix(5).joined(separator: ", "))")
                }
                if !title.director.isEmpty {
                    if title.kind == .movie {
                        Text("\(Text("Director").foregroundStyle(.secondary)) \(title.director)")
                    } else {
                        Text(title.director)
                    }
                }
            }
            .font(.subheadline)
            .lineLimit(1)
            .frame(maxWidth: 620, alignment: .leading)
        }
    }

    private func notice(_ text: String, systemImage: String, action: (String, () -> Void)?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.orange)
            Text(text)
                .font(.callout)
            if let action {
                // The capsule is already glass; the button keeps its legible base without stacking more.
                Button(action.0, action: action.1)
                    .buttonStyle(.theaterPlain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }

    private func actions(_ title: Title, resume: (item: PlaybackItem, position: Double, label: String),
                         resumeEntry: WatchProgress?) -> some View {
        // Full labels when the row fits; otherwise the secondary buttons shrink to icons
        // (still labelled for VoiceOver and tooltips) so nothing runs off a narrow window.
        ViewThatFits(in: .horizontal) {
            actionRow(title, resume: resume, resumeEntry: resumeEntry, isCompact: false)
            actionRow(title, resume: resume, resumeEntry: resumeEntry, isCompact: true)
        }
        .sheet(isPresented: $isShowingTrailer) {
            if let trailer = title.trailer {
                TrailerView(title: title, trailer: trailer)
            }
        }
    }

    private func actionRow(_ title: Title, resume: (item: PlaybackItem, position: Double, label: String),
                           resumeEntry: WatchProgress?, isCompact: Bool) -> some View {
        let isInMyList = model.isInMyList(title)
        let isWatched = WatchHistory.isWatched(title, in: progress(for: title))
        // One container so the row's glass buttons render and blend together.
        return GlassEffectContainer(spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Button {
                    requestPlay(resume.item, from: resume.position)
                } label: {
                    VStack(spacing: 6) {
                        // Resuming shows how much is left right on the button.
                        if let resumeEntry, resume.position > 0 {
                            Label("\(resume.label) · \(resumeEntry.remainingDescription)", systemImage: "play.fill")
                        } else {
                            Label(resume.label, systemImage: "play.fill")
                        }
                        if resume.position > 0, let resumeEntry {
                            WatchProgressBar(fraction: resumeEntry.fraction)
                                .frame(width: 110)
                        }
                    }
                }
                .buttonStyle(PlayButtonStyle())
                // Return belongs to the player, a PIN pad, or the search field while they're in use.
                .keyboardShortcut(model.acceptsPlayReturnKey ? KeyboardShortcut(.return, modifiers: []) : nil)
                .disabled(!resume.item.isPlayable)
                .fixedSize()

                if resume.position > 0 {
                    Button {
                        requestPlay(resume.item, from: 0)
                    } label: {
                        secondaryLabel("Start Over", systemImage: "gobackward", isCompact: isCompact)
                    }
                    .buttonStyle(.theaterGlass)
                    .help("Start Over")
                }

                Button {
                    model.toggleMyList(title)
                } label: {
                    secondaryLabel(isInMyList ? "In My List" : "My List", systemImage: isInMyList ? "checkmark" : "plus",
                                   isCompact: isCompact)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.theaterGlass)
                .keyboardShortcut("l", modifiers: .command)
                .help("Add or remove from My List (⌘L)")

                Button {
                    model.setWatched(!isWatched, title)
                } label: {
                    secondaryLabel(isWatched ? "Watched" : "Mark Watched",
                                   systemImage: isWatched ? "checkmark.circle.fill" : "checkmark.circle", isCompact: isCompact)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.theaterGlass)
                .help(isWatched ? "Mark as unwatched" : "Mark as watched")

                if title.trailer != nil {
                    Button {
                        isShowingTrailer = true
                    } label: {
                        secondaryLabel("Trailer", systemImage: "play.rectangle", isCompact: isCompact)
                    }
                    .buttonStyle(.theaterGlass)
                    // ⌘T is the system's Show Fonts / new tab shortcut.
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .help("Watch the trailer (⇧⌘T)")
                }

                if model.canManageLibrary {
                    Button {
                        // The PIN is asked once a choice is made in the dialog.
                        isConfirmingDelete = true
                    } label: {
                        secondaryLabel("Delete", systemImage: "trash", isCompact: isCompact)
                    }
                    .buttonStyle(.theaterGlass)
                    .help("Remove this title from your library, or move its files to the Trash")
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// A secondary action's label: text and icon, or just the icon in a narrow window (the
    /// text stays as its accessibility label).
    @ViewBuilder
    private func secondaryLabel(_ text: String, systemImage: String, isCompact: Bool) -> some View {
        Group {
            if isCompact {
                Image(systemName: systemImage)
                    .accessibilityLabel(text)
            } else {
                Label(text, systemImage: systemImage)
            }
        }
        .font(.headline)
            .padding(.horizontal, isCompact ? 4 : 10)
            .padding(.vertical, 6)
    }

    private func libraryMenu(_ title: Title) -> some View {
        Menu {
            Button("Refresh Info", systemImage: "arrow.clockwise") { model.refreshInfo(for: [title.id]) }
                .disabled(model.library.isBusy)
            Button("Fix Match…", systemImage: "wand.and.stars") { model.fixMatch(title) }
            Button("Edit Info…", systemImage: "pencil") { model.editInfo(title) }
            Divider()
            Button("Show in Finder", systemImage: "folder") {
                model.library.revealInFinder(title.allEpisodes.first?.id ?? title.id)
            }
            Button("Check File for Damage…", systemImage: "bandage") {
                let item = PlaybackItem(title: title, episode: title.allEpisodes.first)
                model.manageLibrary("Enter the administrator PIN to check and repair this file.") { repairing = item }
            }
            Divider()
            Button("Remove from Library…", systemImage: "trash", role: .destructive) {
                isConfirmingRemoval = true
            }
        } label: {
            Label("Library Actions", systemImage: "ellipsis.circle")
        }
        .help("Refresh, fix, or edit this title's info")
    }

    // MARK: Episodes

    private func episodes(_ title: Title, progress: [WatchProgress]) -> some View {
        let season = title.seasons.first { $0.number == selectedSeason } ?? title.seasons.first
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Episodes")
                    .font(.title2.weight(.bold))
                Spacer()
                if title.seasons.count > 1 {
                    Picker("Season", selection: $selectedSeason) {
                        ForEach(title.seasons) { season in
                            Text(season.name).tag(season.number)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .padding(.horizontal, pageMargin)

            LazyVStack(spacing: 4) {
                let episodes = season?.episodes ?? []
                let finished = Set(progress.filter(\.isFinished).map(\.playbackID))
                ForEach(episodes) { episode in
                    EpisodeRow(title: title, episode: episode,
                               progress: progress.first { $0.playbackID == episode.id },
                               season: episodes,
                               isSeasonWatched: !episodes.isEmpty && episodes.allSatisfy { finished.contains($0.id) },
                               onPlay: requestPlay)
                }
            }
            .padding(.horizontal, pageMargin - 12)
        }
    }

    // MARK: Details

    private func details(_ title: Title) -> some View {
        let videoFile = title.kind == .movie ? title.id : title.allEpisodes.first?.id
        let location = videoFile.flatMap(model.library.filePath(for:))

        return VStack(alignment: .leading, spacing: 16) {
            Text("About")
                .font(.title2.weight(.bold))
            Grid(alignment: .topLeading, horizontalSpacing: 48, verticalSpacing: 14) {
                GridRow {
                    detail("Genres", title.genres.map(\.displayName).joined(separator: ", "))
                    detail("Rated", title.displayRating)
                    detail(title.kind == .movie ? "Released" : "Premiered", title.yearText ?? "")
                }
                GridRow {
                    detail("Cast", title.cast.joined(separator: "\n"))
                    detail(title.kind == .movie ? "Director" : "Creator",
                           title.director.replacingOccurrences(of: "Created by ", with: ""))
                    detail("Ratings", title.ratings.map { "\($0.source.displayName): \($0.display)" }.joined(separator: "\n"))
                }
                if let list = trackChoice.list, !list.isEmpty {
                    GridRow {
                        detail("Audio", list.audio.map { TrackPickers.label($0) }.joined(separator: "\n"))
                        detail("Subtitles", list.subtitles.map { TrackPickers.label($0) }.joined(separator: "\n"))
                    }
                }
                GridRow {
                    detail("File", [title.fileFormat, title.badges.map(\.rawValue).joined(separator: ", ")]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    detail(title.kind == .movie ? "Location" : "Folder",
                           (title.kind == .movie ? location : location.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }) ?? "")
                    detail("Info From", title.metadataSources.joined(separator: ", "))
                }
            }
            if title.metadataSources.contains(MetadataProviderID.tmdb.displayName) {
                HStack(spacing: 8) {
                    Image("TMDBLogo").resizable().scaledToFit().frame(height: 9)
                        .accessibilityLabel("TMDB")
                    Text(DataAttribution.tmdbNotice)
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, pageMargin)
    }

    /// Moments this profile saved while watching, each playable from that point.
    @ViewBuilder
    private func favouriteScenes(_ title: Title) -> some View {
        if !scenes.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Favourite Scenes")
                    .font(.title2.weight(.bold))
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(scenes) { scene in
                            let episode = title.allEpisodes.first { $0.id == scene.playbackID }
                            let item = PlaybackItem(title: title, episode: episode)
                            HStack(spacing: 12) {
                                Button {
                                    requestPlay(item, from: scene.time)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "heart.fill")
                                            .foregroundStyle(Theme.accent)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(scene.timeText)
                                                .font(.headline.monospacedDigit())
                                            Text(episode.map { "\($0.code) · \($0.name)" } ?? "Play from here")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .disabled(!item.isPlayable)
                                .help("Play from \(scene.timeText)")
                                Button {
                                    withAnimation(.snappy) {
                                        modelContext.delete(scene)
                                        try? modelContext.save()
                                    }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption.weight(.bold))
                                }
                                // The scene's row is already glass, so no glass of its own.
                                .buttonStyle(.theaterPlainCircle)
                                .controlSize(.small)
                                .help("Remove this scene")
                                .accessibilityLabel("Remove scene at \(scene.timeText)")
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .glassEffect(.regular, in: .rect(cornerRadius: 14))
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.never)
            }
            .padding(.horizontal, pageMargin)
        }
    }

    @ViewBuilder
    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value.isEmpty ? "—" : value)
                .font(.callout)
                .foregroundStyle(value.isEmpty ? .tertiary : .primary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: 280, alignment: .leading)
    }
}

struct EpisodeRow: View {
    @Environment(AppModel.self) private var model
    let title: Title
    let episode: Episode
    let progress: WatchProgress?
    /// Every episode in this episode's season, for "Mark Season Watched".
    var season: [Episode] = []
    var isSeasonWatched = false
    let onPlay: (PlaybackItem, Double) -> Void
    @State private var isHovered = false

    private var isWatched: Bool { progress?.isFinished == true }

    var body: some View {
        Button {
            let position = (progress?.isFinished ?? true) ? 0 : (progress?.position ?? 0)
            onPlay(PlaybackItem(title: title, episode: episode), position)
        } label: {
            HStack(alignment: .top, spacing: 20) {
                ZStack {
                    if let still = episode.stillURL {
                        Color.black
                        RemoteImage(url: still)
                    } else {
                        ArtworkView(title: title, style: .backdrop)
                    }
                    Text("\(episode.number)")
                        .font(.system(size: 40, weight: .black))
                        .fontWidth(.compressed)
                        .foregroundStyle(.white.opacity(isHovered ? 0 : 0.9))
                        .shadow(color: .black.opacity(0.5), radius: 6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    // Only built while hovered, so a long season doesn't keep idle glass around.
                    if isHovered {
                        Image(systemName: episode.isPlayable ? "play.fill" : "exclamationmark.triangle.fill")
                            .font(.title2)
                            .frame(width: 48, height: 48)
                            .glassEffect(.regular, in: .circle)
                            .transition(.opacity)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: 224, height: 126)
                .overlay(alignment: .bottom) {
                    if let progress {
                        WatchProgressBar(fraction: progress.fraction)
                            .padding(10)
                    }
                }
                .clipShape(.rect(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(episode.number). \(episode.name)")
                            .font(.headline)
                        Spacer()
                        if progress?.isFinished == true {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .accessibilityLabel("Watched")
                        }
                        if episode.runtimeMinutes > 0 {
                            Text(Duration.seconds(episode.runtimeMinutes * 60)
                                .formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !episode.isPlayable {
                        Text(episode.playbackIssue?.message ?? "This episode can't be played.")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    } else if !episode.synopsis.isEmpty {
                        Text(episode.synopsis)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                .padding(.top, 8)
            }
            .padding(12)
            .background {
                // Hovered episodes lift into glass.
                if isHovered { Color.clear.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14)) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!episode.isPlayable)
        .overlay(alignment: .bottomTrailing) {
            // Outside the row's play button so clicking it never starts playback.
            if isHovered {
                Button { model.setWatched(!isWatched, episodes: [episode], of: title) } label: {
                    Image(systemName: isWatched ? "eye.slash" : "checkmark")
                        .font(.callout.weight(.semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.theaterGlassCircle)
                .help(isWatched ? "Mark as Unwatched" : "Mark as Watched")
                .accessibilityLabel(isWatched ? "Mark episode \(episode.number) as unwatched" : "Mark episode \(episode.number) as watched")
                .padding(20)
                .transition(.opacity)
            }
        }
        .onHover { hovering in withAnimation(.snappy) { isHovered = hovering } }
        .contextMenu {
            Button(isWatched ? "Mark Episode as Unwatched" : "Mark Episode as Watched",
                   systemImage: isWatched ? "eye.slash" : "checkmark.circle") {
                model.setWatched(!isWatched, episodes: [episode], of: title)
            }
            if season.count > 1 {
                Button(isSeasonWatched ? "Mark Season \(episode.season) as Unwatched" : "Mark Season \(episode.season) as Watched",
                       systemImage: isSeasonWatched ? "eye.slash" : "checkmark.circle.fill") {
                    model.setWatched(!isSeasonWatched, episodes: season, of: title)
                }
            }
            Divider()
            Button(model.isWatched(title) ? "Mark Series as Unwatched" : "Mark Series as Watched",
                   systemImage: "tv") {
                model.setWatched(!model.isWatched(title), title)
            }
        }
        .accessibilityLabel("Episode \(episode.number), \(episode.name)\(isWatched ? ", watched" : "")")
    }
}
