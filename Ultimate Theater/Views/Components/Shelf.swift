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
    let title: String
    var subtitle: String?
    let items: [Item]
    var spacing: CGFloat = 16
    var seeAll: (() -> Void)?
    @ViewBuilder let content: (Item) -> Content

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

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.weight(.bold))
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let seeAll {
                Button("See All", action: seeAll)
                    .buttonStyle(.glass)
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
            HStack {
                arrow("chevron.left", label: "Scroll back") { page(by: -4) }
                    .opacity(isHovered && currentIndex > 0 ? 1 : 0)
                Spacer()
                arrow("chevron.right", label: "Scroll forward") { page(by: 4) }
                    .opacity(isHovered && currentIndex < items.count - 4 ? 1 : 0)
            }
            .padding(.horizontal, 8)
        }
    }

    private func arrow(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.bold))
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }

    private func page(by delta: Int) {
        let target = min(max(currentIndex + delta, 0), items.count - 1)
        withAnimation(.smooth) { visibleID = items[target].id }
    }
}

/// A section heading used above grids and lists.
struct PageHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.largeTitle.weight(.heavy))
            if let subtitle {
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, pageMargin)
        .accessibilityAddTraits(.isHeader)
    }
}
