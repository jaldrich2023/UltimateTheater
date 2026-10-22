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
            .map(LibraryRow.init)
            .sorted(using: sortOrder)
    }

    private var summary: String {
        let movies = library.titles.filter { $0.kind == .movie }.count
        let shows = library.titles.filter { $0.kind == .series }
        let episodes = shows.reduce(0) { $0 + $1.allEpisodes.count }
        return "\(movies) movies · \(shows.count) shows · \(episodes) episodes"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Manage Library", subtitle: summary)
                .padding(.top, 28)

            actionBar
                .padding(.horizontal, pageMargin)

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
                for title in pendingRemoval { library.remove(title.id) }
                selection.subtract(pendingRemoval.map(\.id))
                pendingRemoval = []
            }
        } message: {
            Text("The video files stay on your Mac.")
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button { model.addMedia() } label: {
                Label("Add Movies & Shows…", systemImage: "plus")
            }
            .buttonStyle(.glassProminent)

            Button { Task { await library.rescanFolders() } } label: {
                Label("Rescan Folders", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.glass)
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
                Button("Everything (\(library.titles.count))") { Task { await library.refreshMetadata(force: true) } }
            } label: {
                Label("Refresh Info", systemImage: "arrow.clockwise")
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .fixedSize()
            .disabled(library.titles.isEmpty)

            let unmatched = library.titles.filter(\.needsMatch).map(\.id)
            if !unmatched.isEmpty {
                Button { Task { await library.refreshMetadata(for: unmatched, force: true) } } label: {
                    Label("Identify \(unmatched.count) Unmatched", systemImage: "wand.and.stars")
                }
                .buttonStyle(.glass)
            }
        }
        .disabled(library.isBusy)
    }

    /// Re-fetches info for just these titles.
    private func refresh(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        Task { await library.refreshMetadata(for: ids, force: true) }
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
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .disabled(library.isBusy)
                    .help("Refresh info for the titles in this folder")
                    .accessibilityLabel("Refresh info for \(folder.displayName)")
                    Button {
                        library.removeFolder(folder)
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
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
                Button("Fix Match…", systemImage: "wand.and.stars") { model.matchingTitle = title }
                Button("Edit Info…", systemImage: "pencil") { model.editingTitle = title }
                Button("Show in Finder", systemImage: "folder") {
                    library.revealInFinder(title.allEpisodes.first?.id ?? title.id)
                }
            }
            if !titles.isEmpty {
                Button("Refresh Info", systemImage: "arrow.clockwise") {
                    Task { await library.refreshMetadata(for: titles.map(\.id), force: true) }
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

/// Sortable projection of a title for the library table.
struct LibraryRow: Identifiable {
    let title: Title

    var id: String { title.id }
    var name: String { title.name }
    var kind: String { title.kind.displayName }
    var yearSort: Int { title.year ?? 0 }
    var format: String { ([title.fileFormat] + title.badges.map(\.rawValue)).filter { !$0.isEmpty }.joined(separator: " · ") }
    var sources: String { title.metadataSources.joined(separator: ", ") }
    var dateAdded: Date { title.dateAdded }

    var status: String {
        if !title.isPlayable { return "Unsupported" }
        if title.needsMatch { return "Needs Match" }
        return title.metadataSources.isEmpty ? "Not Fetched" : "Matched"
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
