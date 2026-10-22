//
//  TitleDetailView.swift
//  Ultimate Theater
//

import SwiftUI
import SwiftData

struct TitleDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var modelContext
    @Query private var allProgress: [WatchProgress]
    @Query private var allMyList: [MyListEntry]
    @Query private var allRatings: [UserRating]

    let titleID: String
    @State private var selectedSeason = 1
    @State private var isConfirmingRemoval = false
    @State private var trackChoice = TrackChoice()
    @State private var isShowingTrailer = false
    /// Play request waiting on the "use these settings every time?" answer.
    @State private var pendingPlay: PendingPlay?
    /// The damaged file being repaired, if the repair sheet is open.
    @State private var repairing: PlaybackItem?

    private struct PendingPlay: Identifiable {
        let item: PlaybackItem
        let position: Double
        var id: String { item.id }
    }

    /// Read live from the library so refreshes and edits show immediately.
    private var title: Title? { model.library.titles.first { $0.id == titleID } }

    private var profileID: String { model.profile?.id ?? "" }

    private func progress(for title: Title) -> [WatchProgress] {
        allProgress.filter { $0.profileID == profileID && $0.titleID == title.id }
    }

    private var userScore: Double? {
        allRatings.first { $0.profileID == profileID && $0.titleID == titleID }?.score
    }

    private var isInMyList: Bool {
        allMyList.contains { $0.profileID == profileID && $0.titleID == titleID }
    }

    var body: some View {
        if let title {
            content(for: title)
        } else {
            ContentUnavailableView("Title Removed", systemImage: "film",
                                   description: Text("This title is no longer in your library."))
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

                let similar = WatchHistory.similar(to: title, in: model.titles)
                if !similar.isEmpty {
                    Shelf(title: "More Like This", items: similar) { item in
                        PosterCard(title: item)
                    }
                }

                details(title)
            }
            .padding(.bottom, 60)
        }
        .ignoresSafeArea(edges: .top)
        .background { AppBackground() }
        .navigationTitle(title.name)
        .toolbar {
            ToolbarItem {
                libraryMenu(title)
            }
        }
        .sheet(item: $repairing) { item in
            RepairView(title: item.title, playbackID: item.id)
        }
        .confirmationDialog("Remove “\(title.name)” from your library?", isPresented: $isConfirmingRemoval) {
            Button("Remove from Library", role: .destructive) {
                model.close(title.id)
                model.library.remove(title.id)
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
              let list = await model.library.withFileAccess(item.id, { await MediaInspector.trackList(for: $0) }) else {
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
        ZStack(alignment: .bottomLeading) {
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

            VStack(alignment: .leading, spacing: 16) {
                Text(title.name)
                    .font(.system(size: 60, weight: .black))
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
                           action: ("Fix Match…", { model.matchingTitle = title }))
                }
                if !resume.item.isPlayable {
                    let issue = resume.item.episode?.playbackIssue ?? title.playbackIssue
                    notice(issue?.message ?? "This file can't be played.", systemImage: "exclamationmark.triangle.fill",
                           action: issue?.isDamage == true && model.canManageLibrary ? ("Repair…", { repairing = resume.item }) : nil)
                }

                actions(title, resume: resume, resumeEntry: resumeEntry)
                    .padding(.top, 4)

                TrackPickers(choice: $trackChoice)

                credits(title)

                if let collection = title.collection {
                    Button { model.open(collection) } label: {
                        Label("Part of \(collection.name)", systemImage: "square.stack.3d.up.fill")
                            .font(.callout.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                    .help("See every movie in this collection")
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, pageMargin)
            .padding(.bottom, 24)
        }
        .containerRelativeFrame(.vertical) { height, _ in max(height * 0.8, 520) }
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
                Button(action.0, action: action.1)
                    .buttonStyle(.glass)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }

    private func actions(_ title: Title, resume: (item: PlaybackItem, position: Double, label: String),
                         resumeEntry: WatchProgress?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                requestPlay(resume.item, from: resume.position)
            } label: {
                VStack(spacing: 6) {
                    Label(resume.label, systemImage: "play.fill")
                    if resume.position > 0, let resumeEntry {
                        WatchProgressBar(fraction: resumeEntry.fraction)
                            .frame(width: 110)
                    }
                }
            }
            .buttonStyle(PlayButtonStyle())
            .keyboardShortcut(.return, modifiers: [])
            .disabled(!resume.item.isPlayable)

            if resume.position > 0 {
                Button {
                    requestPlay(resume.item, from: 0)
                } label: {
                    Label("Start Over", systemImage: "gobackward")
                        .font(.headline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glass)
            }

            Button {
                withAnimation(.snappy) {
                    WatchHistory.toggleMyList(title, profileID: profileID, entries: allMyList, in: modelContext)
                }
            } label: {
                Label(isInMyList ? "In My List" : "My List", systemImage: isInMyList ? "checkmark" : "plus")
                    .font(.headline)
                    .contentTransition(.symbolEffect(.replace))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glass)
            .keyboardShortcut("l", modifiers: .command)
            .help("Add or remove from My List (⌘L)")

            if let trailer = title.trailer {
                Button {
                    isShowingTrailer = true
                } label: {
                    Label("Trailer", systemImage: "play.rectangle")
                        .font(.headline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glass)
                .keyboardShortcut("t", modifiers: .command)
                .help("Watch the trailer (⌘T)")
                .sheet(isPresented: $isShowingTrailer) {
                    TrailerView(title: title, trailer: trailer)
                }
            }

            if let resumeEntry, resume.position > 0 {
                Text(resumeEntry.remainingDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
        }
    }

    private func libraryMenu(_ title: Title) -> some View {
        Menu {
            Button("Refresh Info", systemImage: "arrow.clockwise") {
                Task { await model.library.refreshMetadata(for: [title.id], force: true) }
            }
            .disabled(model.library.isBusy)
            Button("Fix Match…", systemImage: "wand.and.stars") { model.matchingTitle = title }
            Button("Edit Info…", systemImage: "pencil") { model.editingTitle = title }
            Divider()
            Button("Show in Finder", systemImage: "folder") {
                model.library.revealInFinder(title.allEpisodes.first?.id ?? title.id)
            }
            Button("Check File for Damage…", systemImage: "bandage") {
                repairing = PlaybackItem(title: title, episode: title.allEpisodes.first)
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
                ForEach(season?.episodes ?? []) { episode in
                    EpisodeRow(title: title, episode: episode,
                               progress: progress.first { $0.playbackID == episode.id },
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
    let title: Title
    let episode: Episode
    let progress: WatchProgress?
    let onPlay: (PlaybackItem, Double) -> Void
    @State private var isHovered = false

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
                    Image(systemName: episode.isPlayable ? "play.fill" : "exclamationmark.triangle.fill")
                        .font(.title2)
                        .frame(width: 48, height: 48)
                        .glassEffect(.regular, in: .circle)
                        .opacity(isHovered ? 1 : 0)
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
                            Text("\(episode.runtimeMinutes)m")
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
        .onHover { hovering in withAnimation(.snappy) { isHovered = hovering } }
        .accessibilityLabel("Episode \(episode.number), \(episode.name)")
    }
}
