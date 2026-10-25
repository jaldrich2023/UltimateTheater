//
//  Shelf.swift
//  Ultimate Theater
//

import SwiftUI

/// Page margin shared by every screen so rows, heroes, and headers align.
let pageMargin: CGFloat = 44

/// A titled, horizontally scrolling row with hover-revealed paging arrows
/// (so mouse users don't need a trackpad to browse).
struct Shelf<Item: Identifiable, Content: View>: View where Item.ID: Hashable {
    private let title: Text
    private let subtitle: Text?
    let items: [Item]
    var spacing: CGFloat = 16
    var seeAll: (() -> Void)?
    /// Height of the text under each tile's artwork, so the paging arrows centre on the
    /// artwork rather than on artwork plus caption.
    private var captionHeight: CGFloat = 0
    @ViewBuilder let content: (Item) -> Content

    /// Localizable heading (string literals land in the String Catalog).
    init(title: LocalizedStringResource, subtitle: LocalizedStringResource? = nil, items: [Item], spacing: CGFloat = 16,
         seeAll: (() -> Void)? = nil, @ViewBuilder content: @escaping (Item) -> Content) {
        self.init(title: Text(title), subtitle: subtitle.map { Text($0) }, items: items, spacing: spacing, seeAll: seeAll, content: content)
    }

    /// Heading shown as-is, e.g. a title's name from the library.
    @_disfavoredOverload
    init(title: String, subtitle: String? = nil, items: [Item], spacing: CGFloat = 16,
         seeAll: (() -> Void)? = nil, @ViewBuilder content: @escaping (Item) -> Content) {
        self.init(title: Text(verbatim: title), subtitle: subtitle.map { Text(verbatim: $0) }, items: items, spacing: spacing,
                  seeAll: seeAll, content: content)
    }

    init(title: Text, subtitle: Text? = nil, items: [Item], spacing: CGFloat = 16,
         seeAll: (() -> Void)? = nil, @ViewBuilder content: @escaping (Item) -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.items = items
        self.spacing = spacing
        self.seeAll = seeAll
        self.content = content
    }

    @State private var visibleID: Item.ID?
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: spacing) {
                    ForEach(items) { item in
                        content(item)
                    }
                }
                .scrollTargetLayout()
                // Room for hover lift and shadows so they aren't clipped.
                .padding(.vertical, 14)
            }
            .scrollIndicators(.never)
            .scrollPosition(id: $visibleID, anchor: .leading)
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, pageMargin, for: .scrollContent)
            .scrollClipDisabled()
            .padding(.vertical, -14)
            .overlay { pagingArrows }
        }
        .onHover { hovering in withAnimation(.easeOut(duration: 0.2)) { isHovered = hovering } }
    }

    /// For rows whose tiles carry a caption below the artwork.
    func captionBelowArtwork(_ height: CGFloat) -> Self {
        var copy = self
        copy.captionHeight = height
        return copy
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.title2.weight(.bold))
                if let subtitle {
                    subtitle
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let seeAll {
                Button("See All", action: seeAll)
                    .buttonStyle(.theaterGlass)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, pageMargin)
        .accessibilityAddTraits(.isHeader)
    }

    private var currentIndex: Int {
        guard let visibleID else { return 0 }
        return items.firstIndex { $0.id == visibleID } ?? 0
    }

    @ViewBuilder
    private var pagingArrows: some View {
        if items.count > 3 {
            // Each arrow sits in the page margin beside the first and last visible tile,
            // centred on the tiles' artwork.
            HStack {
                arrow("chevron.left", label: "Scroll back") { page(by: -4) }
                    .opacity(isHovered && currentIndex > 0 ? 1 : 0)
                Spacer()
                arrow("chevron.right", label: "Scroll forward") { page(by: 4) }
                    .opacity(isHovered && currentIndex < items.count - 4 ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .padding(.bottom, captionHeight)
            .padding(.horizontal, max((pageMargin - Self.arrowSize) / 2, 0))
        }
    }

    private func arrow(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.headline.weight(.bold))
                // The circle style adds 6 pt around this, making the arrow arrowSize across.
                .frame(width: Self.arrowSize - 12, height: Self.arrowSize - 12)
        }
        .buttonStyle(.theaterGlassCircle)
        .accessibilityLabel(label)
    }

    /// Fits inside the page margin, so the arrow never covers a tile.
    private static var arrowSize: CGFloat { 40 }

    private func page(by delta: Int) {
        let target = min(max(currentIndex + delta, 0), items.count - 1)
        withAnimation(.smooth) { visibleID = items[target].id }
    }
}

/// A section heading used above grids and lists.
struct PageHeader: View {
    private let title: Text
    private let subtitle: Text?

    /// Localizable heading (string literals land in the String Catalog).
    init(title: LocalizedStringResource, subtitle: LocalizedStringResource? = nil) {
        self.init(title: Text(title), subtitle: subtitle.map { Text($0) })
    }

    /// Heading shown as-is.
    @_disfavoredOverload
    init(title: String, subtitle: String? = nil) {
        self.init(title: Text(verbatim: title), subtitle: subtitle.map { Text(verbatim: $0) })
    }

    init(title: Text, subtitle: Text? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            title
                .font(.largeTitle.weight(.heavy))
            if let subtitle {
                subtitle
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, pageMargin)
        .accessibilityAddTraits(.isHeader)
    }
}
