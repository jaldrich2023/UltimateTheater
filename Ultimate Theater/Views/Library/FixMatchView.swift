//
//  FixMatchView.swift
//  Ultimate Theater
//

import SwiftUI

/// Search every metadata source and choose the correct title.
struct FixMatchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let title: Title

    @State private var query: String
    @State private var year: String
    @State private var results: [MetadataCandidate] = []
    @State private var errors: [MetadataProviderID: String] = [:]
    @State private var selection: MetadataCandidate.ID?
    @State private var isSearching = false
    @State private var isApplying = false
    @State private var applyError: String?

    init(title: Title) {
        self.title = title
        _query = State(initialValue: title.name)
        _year = State(initialValue: title.yearText ?? "")
    }

    private var sources: [MetadataProviderID] {
        model.library.metadata.settings.activeProviders.filter { $0.supports(title.kind) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Fix Match")
                    .font(.title2.weight(.bold))
                Text("Search for the correct \(title.kind == .movie ? "movie" : "show"). Info, artwork, and ratings will be replaced.")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                TextField("Title", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                TextField("Year", text: $year)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .onSubmit(search)
                Button("Search", action: search)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
            }

            Group {
                if sources.isEmpty {
                    ContentUnavailableView("No Metadata Sources", systemImage: "key",
                                           description: Text("Turn on a source in Settings › Metadata."))
                } else if isSearching {
                    ProgressView("Searching \(sources.map(\.displayName).formatted(.list(type: .and)))…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(results, selection: $selection) { candidate in
                        CandidateRow(candidate: candidate)
                            .tag(candidate.id)
                    }
                    .listStyle(.inset)
                    .alternatingRowBackgrounds()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !errors.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(errors.sorted { $0.key.rawValue < $1.key.rawValue }, id: \.key) { provider, message in
                        Label("\(provider.displayName): \(message)", systemImage: "exclamationmark.triangle")
                    }
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }
            if let applyError {
                Label(applyError, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    apply()
                } label: {
                    if isApplying {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Use This Match")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil || isApplying)
            }
        }
        .padding(24)
        .frame(width: 680, height: 540)
        .task { await runSearch() }
    }

    private func search() {
        Task { await runSearch() }
    }

    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        let request = MetadataQuery(title: trimmed, year: Int(year), kind: title.kind,
                                    seasons: Array(Set(title.allEpisodes.map(\.season))).sorted())
        let response = await model.library.metadata.searchAll(request)
        results = response.candidates
        errors = response.errors
        selection = results.first?.id
        isSearching = false
    }

    private func apply() {
        guard let candidate = results.first(where: { $0.id == selection }) else { return }
        isApplying = true
        applyError = nil
        Task {
            do {
                try await model.library.applyMatch(candidate, to: title.id)
                dismiss()
            } catch {
                applyError = error.localizedDescription
            }
            isApplying = false
        }
    }
}

private struct CandidateRow: View {
    let candidate: MetadataCandidate

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                Image(systemName: candidate.kind == .movie ? "film" : "tv")
                    .foregroundStyle(.tertiary)
                if let poster = candidate.posterURL {
                    RemoteImage(url: poster, size: .poster)
                }
            }
            .frame(width: 46, height: 69)
            .clipShape(.rect(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(candidate.title)
                        .font(.headline)
                    if let year = candidate.year {
                        Text(String(year))
                            .foregroundStyle(.secondary)
                    }
                }
                if let overview = candidate.overview {
                    Text(overview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Text(candidate.provider.displayName)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: .capsule)
        }
        .padding(.vertical, 4)
    }
}
