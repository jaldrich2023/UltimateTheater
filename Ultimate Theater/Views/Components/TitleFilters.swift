//
//  TitleFilters.swift
//  Ultimate Theater
//
//  Multi-select facet filters (genre, year, studio, writer, director, actors)
//  and the 0–9 A–Z jump index used by browse grids.
//

import SwiftUI
import SwiftData

enum TitleFacet: String, CaseIterable, Identifiable {
    case genre
    case year
    case rated
    case studio
    case writer
    case director
    case actor
    case myRating

    var id: String { rawValue }

    var title: String {
        switch self {
        case .genre: "Genre"
        case .year: "Year"
        case .studio: "Studio"
        case .writer: "Writer"
        case .director: "Director"
        case .actor: "Actors"
        case .rated: "Rated"
        case .myRating: "My Rating"
        }
    }

    var systemImage: String {
        switch self {
        case .genre: "theatermasks"
        case .year: "calendar"
        case .studio: "building.2"
        case .writer: "pencil.and.scribble"
        case .director: "megaphone"
        case .actor: "person.2"
        case .rated: "checkmark.shield"
        case .myRating: "star"
        }
    }

    /// Content ratings in a familiar order; anything else follows alphabetically.
    private static let ratingOrder = ["G", "PG", "PG-13", "R", "NC-17", "TV-Y", "TV-Y7", "TV-G", "TV-PG", "TV-14", "TV-MA", "NR"]
    private static let myRatingBuckets = ["9–10", "7–8.5", "5–6.5", "Below 5", "Not Rated"]

    static func myRatingBucket(_ score: Double?) -> String {
        guard let score else { return "Not Rated" }
        switch score {
        case 9...: return "9–10"
        case 7..<9: return "7–8.5"
        case 5..<7: return "5–6.5"
        default: return "Below 5"
        }
    }

    /// Values for `title`. `ratings` maps title IDs to the viewer's own scores.
    func values(of title: Title, ratings: [String: Double] = [:]) -> [String] {
        switch self {
        case .rated: title.displayRating.isEmpty ? [] : [title.displayRating]
        case .myRating: [Self.myRatingBucket(ratings[title.id])]
        case .genre: title.genres.map(\.displayName)
        case .year: title.yearText.map { [$0] } ?? []
        case .studio: title.studios
        case .writer: title.writers
        case .director: title.directors
        case .actor: title.cast
        }
    }

    /// Every value present in `titles`, with how many titles have it.
    func options(in titles: [Title], ratings: [String: Double] = [:]) -> [FacetOption] {
        var counts: [String: Int] = [:]
        for title in titles {
            for value in Set(values(of: title, ratings: ratings)) { counts[value, default: 0] += 1 }
        }
        let options = counts.map { FacetOption(value: $0.key, count: $0.value) }
        switch self {
        case .rated:
            return options.sorted { lhs, rhs in
                let l = Self.ratingOrder.firstIndex(of: lhs.value) ?? Int.max
                let r = Self.ratingOrder.firstIndex(of: rhs.value) ?? Int.max
                return l == r ? lhs.value < rhs.value : l < r
            }
        case .myRating:
            return options.sorted { (Self.myRatingBuckets.firstIndex(of: $0.value) ?? 9) < (Self.myRatingBuckets.firstIndex(of: $1.value) ?? 9) }
        case .year:
            return options.sorted { $0.value > $1.value }
        case .genre:
            return options.sorted { $0.value < $1.value }
        default:
            // Most frequent first, so the people and studios you have most of are easy to find.
            return options.sorted { $0.count == $1.count ? $0.value < $1.value : $0.count > $1.count }
        }
    }
}

struct FacetOption: Identifiable, Hashable {
    let value: String
    let count: Int
    var id: String { value }
}

/// Selected values per facet. Values within a facet are OR'd; facets are AND'd.
struct TitleFilter: Equatable {
    var selections: [TitleFacet: Set<String>] = [:]

    var isActive: Bool { selections.values.contains { !$0.isEmpty } }

    subscript(facet: TitleFacet) -> Set<String> {
        get { selections[facet] ?? [] }
        set { selections[facet] = newValue }
    }

    func matches(_ title: Title, ratings: [String: Double] = [:]) -> Bool {
        selections.allSatisfy { facet, selected in
            selected.isEmpty || !selected.isDisjoint(with: facet.values(of: title, ratings: ratings))
        }
    }

    func apply(_ titles: [Title], ratings: [String: Double] = [:]) -> [Title] {
        isActive ? titles.filter { matches($0, ratings: ratings) } : titles
    }
}

// MARK: - Filter bar

struct TitleFilterBar: View {
    let titles: [Title]
    var ratings: [String: Double] = [:]
    @Binding var filter: TitleFilter

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(TitleFacet.allCases) { facet in
                    FacetFilterButton(facet: facet, options: facet.options(in: titles, ratings: ratings), selection: $filter[facet])
                }
                if filter.isActive {
                    Button {
                        withAnimation(.snappy) { filter = TitleFilter() }
                    } label: {
                        Label("Clear", systemImage: "xmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                    .help("Clear all filters")
                    .transition(.opacity)
                }
            }
        }
    }
}

/// A dropdown button that opens a searchable multi-select checklist.
private struct FacetFilterButton: View {
    let facet: TitleFacet
    let options: [FacetOption]
    @Binding var selection: Set<String>

    @State private var isPresented = false

    private var label: String {
        switch selection.count {
        case 0: facet.title
        case 1: "\(facet.title): \(selection.first ?? "")"
        default: "\(facet.title) (\(selection.count))"
        }
    }

    var body: some View {
        let button = Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: facet.systemImage)
                Text(label)
                    .lineLimit(1)
                    .frame(maxWidth: 150)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .opacity(0.7)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .disabled(options.isEmpty)
        .help(options.isEmpty
              ? "No \(facet.title.lowercased()) info yet. It appears once titles are identified."
              : "Filter by \(facet.title.lowercased())")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            FacetChecklist(facet: facet, options: options, selection: $selection)
        }

        if selection.isEmpty {
            button.buttonStyle(.glass)
        } else {
            button.buttonStyle(.glassProminent).tint(Theme.accent)
        }
    }
}

private struct FacetChecklist: View {
    let facet: TitleFacet
    let options: [FacetOption]
    @Binding var selection: Set<String>
    @State private var query = ""

    private var visible: [FacetOption] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return options }
        return options.filter { $0.value.localizedStandardContains(trimmed) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if options.count > 8 {
                TextField("Search \(facet.title.lowercased())", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(12)
                Divider()
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(visible) { option in
                        Toggle(isOn: binding(for: option.value)) {
                            HStack {
                                Text(option.value)
                                    .lineLimit(1)
                                Spacer(minLength: 12)
                                Text("\(option.count)")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                    if visible.isEmpty {
                        Text("No matches")
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 340)

            Divider()
            HStack {
                Text(selection.isEmpty ? "Any \(facet.title.lowercased())" : "\(selection.count) selected")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { selection = [] }
                    .disabled(selection.isEmpty)
            }
            .font(.callout)
            .padding(12)
        }
        .frame(width: 300)
    }

    private func binding(for value: String) -> Binding<Bool> {
        Binding(
            get: { selection.contains(value) },
            set: { isOn in
                if isOn { selection.insert(value) } else { selection.remove(value) }
            }
        )
    }
}

// MARK: - Alphabet index

/// Vertical 0–9 A–Z strip. Letters without titles are dimmed; clicking one jumps to the next available.
struct AlphabetIndex: View {
    static let characters: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    let available: Set<Character>
    /// Letter of the first visible title, lit while scrolling.
    var current: Character?
    let onSelect: (Character) -> Void

    @State private var hovered: Character?

    var body: some View {
        GeometryReader { proxy in
            let rowHeight = proxy.size.height / CGFloat(Self.characters.count)
            VStack(spacing: 0) {
                ForEach(Self.characters, id: \.self) { character in
                    Button {
                        onSelect(character)
                    } label: {
                        Text(String(character))
                            .font(.system(size: min(max(rowHeight * 0.62, 8), 12), weight: .bold, design: .rounded))
                            .foregroundStyle(color(for: character))
                            .frame(width: 24, height: rowHeight)
                            .scaleEffect(current == character ? 1.25 : 1)
                            .background {
                                if current == character || hovered == character {
                                    Circle()
                                        .fill(current == character ? Theme.accent : .white.opacity(0.2))
                                        .frame(width: min(rowHeight, 20), height: min(rowHeight, 20))
                                        .shadow(color: current == character ? Theme.accent.opacity(0.7) : .clear, radius: 6)
                                }
                            }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 ? character : (hovered == character ? nil : hovered) }
                    .accessibilityLabel("Jump to \(String(character))")
                    .accessibilityAddTraits(current == character ? .isSelected : [])
                }
            }
        }
        .animation(.snappy(duration: 0.18), value: current)
        .frame(width: 24)
        .padding(.vertical, 10)
        .padding(.horizontal, 3)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Alphabet index")
    }

    private func color(for character: Character) -> Color {
        if current == character || hovered == character { return .white }
        return available.contains(character) ? .white.opacity(0.9) : .white.opacity(0.25)
    }
}

// MARK: - Filterable grid

/// Poster grid with a header, sort menu, facet filters, and the A–Z jump index.
struct FilterableTitleGrid: View {
    @Environment(AppModel.self) private var model
    @Query private var allRatings: [UserRating]

    let heading: String
    let titles: [Title]
    /// Label for an add button in the header (e.g. "Add Movies"), when adding fits this page.
    var addLabel: String?

    @State private var filter: TitleFilter
    @State private var sort: BrowseSort
    /// First visible title, kept in sync with scrolling.
    @State private var topTitleID: Title.ID?

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 210), spacing: 22, alignment: .top)]

    init(heading: String, titles: [Title], addLabel: String? = nil, filter: TitleFilter = TitleFilter(), sort: BrowseSort = .alphabetical) {
        self.heading = heading
        self.titles = titles
        self.addLabel = addLabel
        _filter = State(initialValue: filter)
        _sort = State(initialValue: sort)
    }

    /// This profile's own ratings, by title.
    private var ratings: [String: Double] {
        let profileID = model.profile?.id
        return Dictionary(allRatings.filter { $0.profileID == profileID }.map { ($0.titleID, $0.score) },
                          uniquingKeysWith: { first, _ in first })
    }

    private var results: [Title] {
        sort.apply(filter.apply(titles, ratings: ratings), ratings: ratings)
    }

    var body: some View {
        let results = results
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .lastTextBaseline) {
                    PageHeader(title: heading, subtitle: filter.isActive
                               ? "\(results.count) of \(titles.count) titles"
                               : "\(titles.count) titles")
                    Picker("Sort", selection: $sort) {
                        ForEach(BrowseSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .padding(.trailing, addLabel != nil && model.canManageLibrary ? 0 : pageMargin)
                    .help("Sort titles")
                    if addLabel != nil, model.canManageLibrary {
                        // Re-fetches info for this library only, not every title everywhere.
                        Button {
                            let ids = titles.map(\.id)
                            Task { await model.library.refreshMetadata(for: ids, force: true) }
                        } label: {
                            Label("Refresh Info", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.glass)
                        .disabled(model.library.isBusy || titles.isEmpty)
                        .help("Fetch the latest info for every title in \(heading)")
                    }
                    if let addLabel, model.canManageLibrary {
                        Button { model.addMedia() } label: {
                            Label(addLabel, systemImage: "plus")
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(model.library.isBusy)
                        .padding(.trailing, pageMargin)
                        .help("\(addLabel) to your library")
                    }
                }
                TitleFilterBar(titles: titles, ratings: ratings, filter: $filter)
                    .padding(.horizontal, pageMargin)
            }
            .padding(.top, 28)
            .padding(.bottom, 12)

            HStack(spacing: 0) {
                ScrollView {
                    if results.isEmpty {
                        ContentUnavailableView {
                            Label("No Matches", systemImage: "line.3.horizontal.decrease.circle")
                        } description: {
                            Text("No titles match every filter. Try removing some selections.")
                        } actions: {
                            Button("Clear Filters") { withAnimation { filter = TitleFilter() } }
                                .buttonStyle(.glass)
                        }
                        .padding(.top, 60)
                    } else {
                        LazyVGrid(columns: columns, spacing: 30) {
                            ForEach(results) { title in
                                GridPosterCard(title: title)
                                    .id(title.id)
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.leading, pageMargin)
                        .padding(.trailing, 16)
                        .padding(.vertical, 16)
                        .animation(.smooth, value: results.map(\.id))
                    }
                }
                .scrollPosition(id: $topTitleID, anchor: .top)
                // Fill the width so the jump bar stays at the right edge even with few items.
                .frame(maxWidth: .infinity, alignment: .leading)

                // Outside the scroll view, so its scroll bar sits just left of the index.
                if !results.isEmpty {
                    AlphabetIndex(available: Set(results.map(\.indexCharacter)), current: currentLetter) { character in
                        jump(to: character)
                    }
                    .frame(maxHeight: 640)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
                }
            }
        }
        .background { AppBackground() }
    }

    /// Letter of the first visible title. Only meaningful (and shown) in A–Z order.
    private var currentLetter: Character? {
        guard sort == .alphabetical else { return nil }
        let visible = results
        let top = visible.first { $0.id == topTitleID } ?? visible.first
        return top?.indexCharacter
    }

    /// Switches to A–Z order and scrolls to the first title at or after `character`.
    private func jump(to character: Character) {
        let order = AlphabetIndex.characters
        let needsResort = sort != .alphabetical
        if needsResort { sort = .alphabetical }
        let sorted = BrowseSort.alphabetical.apply(filter.apply(titles, ratings: ratings))
        guard let start = order.firstIndex(of: character) else { return }
        let target = order[start...].lazy.compactMap { letter in sorted.first { $0.indexCharacter == letter } }.first
            ?? sorted.last
        guard let target else { return }
        Task {
            // Let the grid re-sort before scrolling.
            if needsResort { try? await Task.sleep(for: .milliseconds(50)) }
            withAnimation(.smooth) { topTitleID = target.id }
        }
    }
}
