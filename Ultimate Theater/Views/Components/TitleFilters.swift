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
                    .buttonStyle(.theaterGlass)
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
            button.buttonStyle(.theaterGlass)
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
    /// Largest letter size; grows with the viewer's text size when the strip has room.
    @ScaledMetric(relativeTo: .caption2) private var maxLetterSize: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let rowHeight = proxy.size.height / CGFloat(Self.characters.count)
            VStack(spacing: 0) {
                ForEach(Self.characters, id: \.self) { character in
                    Button {
                        onSelect(character)
                    } label: {
                        Text(String(character))
                            .font(.system(size: min(max(rowHeight * 0.62, 8), maxLetterSize), weight: .bold, design: .rounded))
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
///
/// The filtered, sorted results (and the letters they cover) are cached in state and only
/// rebuilt when the titles, filters, sort, or ratings change. Scrolling lives in a child view,
/// so the scroll position updating on every row doesn't re-run any of that work here.
struct FilterableTitleGrid: View {
    @Environment(AppModel.self) private var model
    /// Only this profile's ratings.
    @Query private var profileRatings: [UserRating]

    private let heading: Text
    let titles: [Title]
    /// Label for an add button in the header (e.g. "Add Movies"), when adding fits this page.
    var addLabel: String?

    @State private var filter: TitleFilter
    @State private var sort: BrowseSort
    @State private var ascending: Bool
    @State private var cache: GridResults?

    /// Localizable heading (string literals land in the String Catalog).
    init(heading: LocalizedStringResource, titles: [Title], profileID: String?, addLabel: String? = nil,
         filter: TitleFilter = TitleFilter(), sort: BrowseSort = .alphabetical) {
        self.init(heading: Text(heading), titles: titles, profileID: profileID, addLabel: addLabel, filter: filter, sort: sort)
    }

    init(heading: Text, titles: [Title], profileID: String?, addLabel: String? = nil,
         filter: TitleFilter = TitleFilter(), sort: BrowseSort = .alphabetical) {
        self.heading = heading
        self.titles = titles
        self.addLabel = addLabel
        let id = profileID ?? ""
        _profileRatings = Query(filter: #Predicate<UserRating> { $0.profileID == id })
        _filter = State(initialValue: filter)
        _sort = State(initialValue: sort)
        _ascending = State(initialValue: sort.defaultAscending)
    }

    /// This profile's own ratings, by title.
    private var ratings: [String: Double] {
        Dictionary(profileRatings.map { ($0.titleID, $0.score) }, uniquingKeysWith: { first, _ in first })
    }

    /// Sort order and direction in one glass dropdown: a submenu per order holding its two
    /// directions (the current choice is checked).
    private var sortMenu: some View {
        Menu {
            ForEach(BrowseSort.allCases) { option in
                Menu {
                    ForEach([true, false], id: \.self) { isAscending in
                        Button {
                            withAnimation(.smooth) {
                                sort = option
                                ascending = isAscending
                            }
                        } label: {
                            let label = isAscending ? option.directionLabels.ascending : option.directionLabels.descending
                            if sort == option && ascending == isAscending {
                                Label(label, systemImage: "checkmark")
                            } else {
                                Label(label, systemImage: isAscending ? "arrow.up" : "arrow.down")
                            }
                        }
                    }
                } label: {
                    if sort == option {
                        Label(option.rawValue, systemImage: "checkmark")
                    } else {
                        Text(option.rawValue)
                    }
                }
            }
        } label: {
            Label("\(sort.rawValue) · \(ascending ? sort.directionLabels.ascending : sort.directionLabels.descending)",
                  systemImage: ascending ? "arrow.up" : "arrow.down")
        }
        .menuStyle(.button)
        .buttonStyle(.theaterGlass)
        .fixedSize()
        .help("Sort titles")
    }

    var body: some View {
        let ratings = ratings
        let inputs = GridInputs(titles: titles, catalogVersion: model.catalogVersion, filter: filter, sort: sort, ascending: ascending, ratings: ratings)
        // Only the first frame (before onChange fills the cache) works the results out inline.
        let current = cache.flatMap { $0.inputs == inputs ? $0 : nil } ?? GridResults(inputs, version: cache?.version ?? 0)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .lastTextBaseline) {
                    PageHeader(title: heading, subtitle: filter.isActive
                               ? Text("\(current.titles.count) of ^[\(titles.count) title](inflect: true)")
                               : Text("^[\(titles.count) title](inflect: true)"))
                    if addLabel != nil, model.canManageLibrary {
                        // Re-fetches info for this library only, not every title everywhere.
                        Button {
                            model.refreshInfo(for: titles.map(\.id))
                        } label: {
                            Label("Refresh Info", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.theaterGlass)
                        .disabled(model.library.isBusy || titles.isEmpty)
                        .help(Text("Fetch the latest info for every title in \(heading)"))
                    }
                    // Adding media lives in the sidebar; the header's main control is the sort.
                    sortMenu
                        .padding(.trailing, pageMargin)
                }
                TitleFilterBar(titles: titles, ratings: ratings, filter: $filter)
                    .padding(.horizontal, pageMargin)
            }
            .padding(.top, 28)
            .padding(.bottom, 12)

            TitleGridScroller(results: current, isAlphabetical: sort == .alphabetical,
                              clearFilters: { withAnimation { filter = TitleFilter() } },
                              switchToAlphabetical: { sort = .alphabetical; ascending = true })
        }
        .background { AppBackground() }
        .onChange(of: inputs, initial: true) { _, inputs in
            let version = cache?.version ?? 0
            var rebuilt = GridResults(inputs, version: version)
            // Bump the animation token only when the shown order actually changes.
            if rebuilt.titles.map(\.id) != cache?.titles.map(\.id) { rebuilt.version = version + 1 }
            cache = rebuilt
        }
    }
}

/// Everything a grid's results depend on; the cached results are rebuilt only when this changes.
private struct GridInputs: Equatable {
    let titles: [Title]
    /// `AppModel.catalogVersion` when `titles` was taken: any edit to a title's info
    /// rebuilds the catalog, so equal versions plus equal IDs mean equal titles.
    let catalogVersion: Int
    let filter: TitleFilter
    let sort: BrowseSort
    let ascending: Bool
    let ratings: [String: Double]

    /// Compares the catalog version and title IDs rather than every field of every title.
    static func == (lhs: GridInputs, rhs: GridInputs) -> Bool {
        lhs.catalogVersion == rhs.catalogVersion && lhs.filter == rhs.filter && lhs.sort == rhs.sort
            && lhs.ascending == rhs.ascending && lhs.ratings == rhs.ratings
            && lhs.titles.count == rhs.titles.count && lhs.titles.elementsEqual(rhs.titles) { $0.id == $1.id }
    }
}

/// Filtered, sorted titles plus what the jump index needs, worked out once per change.
private struct GridResults {
    let inputs: GridInputs
    let titles: [Title]
    let available: Set<Character>
    /// Index letter for each result, for lighting the jump bar while scrolling.
    let letters: [Title.ID: Character]
    /// Changes whenever the result order changes; drives the grid's re-sort animation.
    var version: Int

    var ratings: [String: Double] { inputs.ratings }

    init(_ inputs: GridInputs, version: Int) {
        self.inputs = inputs
        titles = inputs.sort.apply(inputs.filter.apply(inputs.titles, ratings: inputs.ratings),
                                   ratings: inputs.ratings, ascending: inputs.ascending)
        var letters: [Title.ID: Character] = [:]
        letters.reserveCapacity(titles.count)
        for title in titles { letters[title.id] = title.indexCharacter }
        self.letters = letters
        available = Set(letters.values)
        self.version = version
    }
}

/// The scrolling poster grid and its jump bar. Owns the scroll position, so scrolling only
/// re-renders this view (a dictionary lookup for the lit letter), not the filters above.
private struct TitleGridScroller: View {
    let results: GridResults
    let isAlphabetical: Bool
    let clearFilters: () -> Void
    let switchToAlphabetical: () -> Void

    /// First visible title, kept in sync with scrolling.
    @State private var topTitleID: Title.ID?

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 210), spacing: 22, alignment: .top)]

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                if results.titles.isEmpty {
                    ContentUnavailableView {
                        Label("No Matches", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("No titles match every filter. Try removing some selections.")
                    } actions: {
                        Button("Clear Filters", action: clearFilters)
                            .buttonStyle(.theaterGlass)
                    }
                    // Centered in the visible pane, not pinned to the top.
                    .containerRelativeFrame([.horizontal, .vertical])
                } else {
                    LazyVGrid(columns: columns, spacing: 30) {
                        ForEach(results.titles) { title in
                            GridPosterCard(title: title, myRating: results.ratings[title.id])
                                .id(title.id)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.leading, pageMargin)
                    .padding(.trailing, 16)
                    .padding(.vertical, 16)
                    .animation(.smooth, value: results.version)
                }
            }
            .scrollPosition(id: $topTitleID, anchor: .top)
            // Fill the width so the jump bar stays at the right edge even with few items.
            .frame(maxWidth: .infinity, alignment: .leading)

            // Outside the scroll view, so its scroll bar sits just left of the index.
            if !results.titles.isEmpty {
                AlphabetIndex(available: results.available, current: currentLetter) { character in
                    jump(to: character)
                }
                .frame(maxHeight: 640)
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
            }
        }
    }

    /// Letter of the first visible title. Only meaningful (and shown) in A–Z order.
    private var currentLetter: Character? {
        guard isAlphabetical else { return nil }
        return topTitleID.flatMap { results.letters[$0] } ?? results.titles.first?.indexCharacter
    }

    /// Switches to A–Z order and scrolls to the first title at or after `character`.
    private func jump(to character: Character) {
        let order = AlphabetIndex.characters
        let needsResort = !isAlphabetical
        if needsResort { switchToAlphabetical() }
        // Same titles, in the order the grid is about to show.
        let sorted = needsResort ? BrowseSort.alphabetical.apply(results.titles) : results.titles
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
