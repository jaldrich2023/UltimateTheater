//
//  LibraryManagerView.swift
//  Ultimate Theater
//

import SwiftUI

/// Table view of everything in the library, with folder management and bulk actions.
struct LibraryManagerView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case movies = "Movies"
        case shows = "TV Shows"
        case attention = "Needs Attention"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @State private var filter: Filter = .all
    @State private var selection = Set<Title.ID>()
    @State private var sortOrder = [KeyPathComparator(\LibraryRow.dateAdded, order: .reverse)]
    @State private var pendingRemoval: [Title] = []
    /// Found videos waiting on "Ignore?".
    @State private var pendingIgnore: [PendingMedia] = []
    /// The watched folder waiting on "Stop watching?".
    @State private var removingFolder: LibraryFolder?

    private var library: MediaLibrary { model.library }

    private var rows: [LibraryRow] {
        library.titles
            .filter { title in
                switch filter {
                case .all: true
                case .movies: title.kind == .movie
                case .shows: title.kind == .series
                case .attention: title.needsMatch || !title.isPlayable
                }
            }
            .map { LibraryRow($0) }
            .sorted(using: sortOrder)
    }

    private var summary: String {
        let movies = library.titles.filter { $0.kind == .movie }.count
        let shows = library.titles.filter { $0.kind == .series }
        let episodes = shows.reduce(0) { $0 + $1.allEpisodes.count }
        return String(AttributedString(localized:
            "^[\(movies) movie](inflect: true) · ^[\(shows.count) show](inflect: true) · ^[\(episodes) episode](inflect: true)").characters)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Manage Library", subtitle: summary)
                .padding(.top, 28)

            actionBar
                .padding(.horizontal, pageMargin)

            if !library.pending.isEmpty {
                approvals
                    .padding(.horizontal, pageMargin)
            }

            if !library.folders.isEmpty {
                folders
                    .padding(.horizontal, pageMargin)
            }

            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.horizontal, pageMargin)

            table
                .padding(.horizontal, pageMargin - 8)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { AppBackground() }
        .confirmationDialog(
            pendingRemoval.count == 1 ? "Remove “\(pendingRemoval[0].name)” from your library?" : "Remove \(pendingRemoval.count) titles from your library?",
            isPresented: Binding(get: { !pendingRemoval.isEmpty }, set: { if !$0 { pendingRemoval = [] } })
        ) {
            Button("Remove from Library", role: .destructive) {
                let titles = pendingRemoval
                pendingRemoval = []
                // One PIN for the whole selection.
                model.manageLibrary(titles.count == 1 ? "Enter the administrator PIN to remove “\(titles[0].name)”."
                                    : "Enter the administrator PIN to remove \(titles.count) titles.") {
                    for title in titles {
                        model.close(title.id)
                        library.remove(title.id)
                    }
                    selection.subtract(titles.map(\.id))
                }
            }
        } message: {
            Text("The video files stay on your Mac.")
        }
        .confirmationDialog(
            pendingIgnore.count == 1 ? "Ignore “\(pendingIgnore[0].fileName)”?" : "Ignore \(pendingIgnore.count) new videos?",
            isPresented: Binding(get: { !pendingIgnore.isEmpty }, set: { if !$0 { pendingIgnore = [] } }),
            titleVisibility: .visible
        ) {
            Button(pendingIgnore.count == 1 ? "Ignore Video" : "Ignore All", role: .destructive) {
                let items = pendingIgnore
                pendingIgnore = []
                model.manageLibrary("Enter the administrator PIN to ignore new videos.") {
                    library.ignorePending(items)
                }
            }
        } message: {
            Text("Ignored videos aren't added to your library. The files stay on your Mac.")
        }
        .confirmationDialog("Stop watching “\(removingFolder?.displayName ?? "")”?",
                            isPresented: Binding(get: { removingFolder != nil }, set: { if !$0 { removingFolder = nil } }),
                            titleVisibility: .visible, presenting: removingFolder) { folder in
            Button("Stop Watching Folder", role: .destructive) {
                model.manageLibrary("Enter the administrator PIN to stop watching “\(folder.displayName)”.") {
                    library.removeFolder(folder)
                }
            }
        } message: { _ in
            Text("New videos in this folder won't be added any more. Titles already in your library stay, and no files are deleted.")
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button { model.addMedia() } label: {
                Label("Add Movies & Shows…", systemImage: "plus")
            }
            .buttonStyle(.glassProminent)

            Button { model.rescanLibraryFolders() } label: {
                Label("Rescan Folders", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.theaterGlass)
            .disabled(library.folders.isEmpty)

            Menu {
                let movies = library.titles.filter { $0.kind == .movie }.map(\.id)
                let shows = library.titles.filter { $0.kind == .series }.map(\.id)
                Button("Movies (\(movies.count))") { refresh(movies) }
                    .disabled(movies.isEmpty)
                Button("TV Shows (\(shows.count))") { refresh(shows) }
                    .disabled(shows.isEmpty)
                if !library.folders.isEmpty {
                    Section("Folders") {
                        ForEach(library.folders) { folder in
                            Button(folder.displayName) { refresh(library.titleIDs(in: folder)) }
                        }
                    }
                }
                Divider()
                Button("Everything (\(library.titles.count))") { model.refreshInfo() }
            } label: {
                Label("Refresh Info", systemImage: "arrow.clockwise")
            }
            .menuStyle(.button)
            .buttonStyle(.theaterGlass)
            .fixedSize()
            .disabled(library.titles.isEmpty)

            let unmatched = library.titles.filter(\.needsMatch).map(\.id)
            if !unmatched.isEmpty {
                Button { model.refreshInfo(for: unmatched) } label: {
                    Label("Identify \(unmatched.count) Unmatched", systemImage: "wand.and.stars")
                }
                .buttonStyle(.theaterGlass)
            }
        }
        .disabled(library.isBusy)
    }

    /// New videos the folder watcher found; they join the library once approved.
    private var approvals: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Waiting for Approval", systemImage: "tray.and.arrow.down.fill")
                    .font(.headline)
                Text("\(library.pending.count)")
                    .font(.caption.weight(.heavy))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.accent, in: .capsule)
                Spacer()
                Button("Ignore All…") { pendingIgnore = library.pending }
                    .buttonStyle(.theaterGlass)
                Button("Add All") { approve(library.pending) }
                    .buttonStyle(.glassProminent)
            }
            .disabled(library.isBusy)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(library.pending) { item in
                        HStack(spacing: 10) {
                            Image(systemName: "film")
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.fileName)
                                    .font(.callout.weight(.semibold))
                                    .lineLimit(1)
                                Text(URL(fileURLWithPath: item.path).deletingLastPathComponent().path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Text("Found \(item.dateFound, format: .relative(presentation: .named))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Ignore…") { pendingIgnore = [item] }
                                .buttonStyle(.theaterGlass)
                                .controlSize(.small)
                            Button("Add") { approve([item]) }
                                .buttonStyle(.glassProminent)
                                .controlSize(.small)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .glassEffect(.regular, in: .rect(cornerRadius: 12))
                    }
                }
            }
            .frame(maxHeight: 220)
            .disabled(library.isBusy)
        }
    }

    /// Re-fetches info for just these titles.
    private func refresh(_ ids: [String]) {
        model.refreshInfo(for: ids)
    }

    /// Adds found videos to the library (one PIN for all of them).
    private func approve(_ items: [PendingMedia]) {
        guard !items.isEmpty else { return }
        model.manageLibrary(items.count == 1 ? "Enter the administrator PIN to add “\(items[0].fileName)”."
                            : "Enter the administrator PIN to add \(items.count) videos.") {
            Task { await library.approvePending(items) }
        }
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Watched Folders")
                .font(.headline)
            ForEach(library.folders) { folder in
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(folder.displayName)
                            .font(.callout.weight(.semibold))
                        Text(folder.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    if let scanned = folder.lastScanned {
                        Text("Scanned \(scanned, format: .relative(presentation: .named))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        refresh(library.titleIDs(in: folder))
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.theaterGlassCircle)
                    .disabled(library.isBusy)
                    .help("Refresh info for the titles in this folder")
                    .accessibilityLabel("Refresh info for \(folder.displayName)")
                    Button {
                        removingFolder = folder
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.theaterGlassCircle)
                    .help("Stop watching this folder (titles stay in your library)")
                    .accessibilityLabel("Stop watching \(folder.displayName)")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
            }
        }
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.name) { row in
                HStack(spacing: 10) {
                    ArtworkView(title: row.title, style: .poster)
                        .frame(width: 26, height: 39)
                        .clipShape(.rect(cornerRadius: 3))
                    Text(row.name)
                        .fontWeight(.medium)
                }
            }
            .width(min: 200, ideal: 280)
            TableColumn("Type", value: \.kind) { Text($0.kind) }
                .width(80)
            TableColumn("Year", value: \.yearSort) { Text($0.title.yearText ?? "—") }
                .width(60)
            TableColumn("Status", value: \.status) { row in
                Label(row.status, systemImage: row.statusSymbol)
                    .foregroundStyle(row.statusColor)
            }
            .width(min: 110, ideal: 140)
            TableColumn("Format", value: \.format) { Text($0.format) }
                .width(90)
            TableColumn("Info From", value: \.sources) { Text($0.sources).foregroundStyle(.secondary) }
            TableColumn("Added", value: \.dateAdded) { row in
                Text(row.dateAdded, format: .dateTime.month(.abbreviated).day().year())
                    .foregroundStyle(.secondary)
            }
            .width(100)
        }
        .contextMenu(forSelectionType: Title.ID.self) { ids in
            let titles = library.titles.filter { ids.contains($0.id) }
            if titles.count == 1, let title = titles.first {
                Button("Open", systemImage: "info.circle") { model.open(title) }
                Button("Fix Match…", systemImage: "wand.and.stars") { model.fixMatch(title) }
                Button("Edit Info…", systemImage: "pencil") { model.editInfo(title) }
                Button("Show in Finder", systemImage: "folder") {
                    library.revealInFinder(title.allEpisodes.first?.id ?? title.id)
                }
            }
            if !titles.isEmpty {
                Button("Refresh Info", systemImage: "arrow.clockwise") {
                    model.refreshInfo(for: titles.map(\.id))
                }
                .disabled(library.isBusy)
                Divider()
                Button("Remove from Library…", systemImage: "trash", role: .destructive) {
                    pendingRemoval = titles
                }
            }
        } primaryAction: { ids in
            if let id = ids.first, let title = library.titles.first(where: { $0.id == id }) {
                model.open(title)
            }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(filter == .attention ? "Everything Looks Good" : "No Titles",
                                       systemImage: filter == .attention ? "checkmark.seal" : "film.stack",
                                       description: Text(filter == .attention
                                                         ? "All titles are identified and playable."
                                                         : "Add movies and shows to see them here."))
            }
        }
        .onDeleteCommand {
            pendingRemoval = library.titles.filter { selection.contains($0.id) }
        }
    }
}

/// Sortable projection of a title for the library table. The sort keys are plain stored
/// values (nonisolated), so the table's `KeyPathComparator`s are Sendable.
struct LibraryRow: Identifiable {
    let title: Title

    nonisolated let id: String
    nonisolated let name: String
    nonisolated let kind: String
    nonisolated let yearSort: Int
    nonisolated let format: String
    nonisolated let sources: String
    nonisolated let dateAdded: Date
    nonisolated let status: String

    init(_ title: Title) {
        self.title = title
        id = title.id
        name = title.name
        kind = title.kind.displayName
        yearSort = title.year ?? 0
        format = ([title.fileFormat] + title.badges.map(\.rawValue)).filter { !$0.isEmpty }.joined(separator: " · ")
        sources = title.metadataSources.joined(separator: ", ")
        dateAdded = title.dateAdded
        status = if !title.isPlayable { "Unsupported" }
            else if title.needsMatch { "Needs Match" }
            else { title.metadataSources.isEmpty ? "Not Fetched" : "Matched" }
    }

    var statusSymbol: String {
        switch status {
        case "Unsupported": "exclamationmark.triangle.fill"
        case "Needs Match": "questionmark.circle.fill"
        case "Not Fetched": "clock"
        default: "checkmark.circle.fill"
        }
    }

    var statusColor: Color {
        switch status {
        case "Unsupported": .orange
        case "Needs Match": Theme.accent
        case "Not Fetched": .secondary
        default: .green
        }
    }
}
