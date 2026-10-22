//
//  HeroCarousel.swift
//  Ultimate Theater
//

import SwiftUI

/// Full-bleed, auto-advancing billboard at the top of Home. Pauses while the pointer is over it.
struct HeroCarousel: View {
    @Environment(AppModel.self) private var model
    let titles: [Title]

    @State private var index = 0
    @State private var isHovered = false
    @State private var isInMyList = false

    private var title: Title? { titles[safe: index] }

    var body: some View {
        if let title {
            ZStack(alignment: .bottomLeading) {
                backdrop(for: title)
                info(for: title)
                    .padding(.horizontal, pageMargin)
                    .padding(.bottom, 56)
                    .id(title.id)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 12)), removal: .opacity))
                if titles.count > 1 {
                    pageIndicator
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, pageMargin)
                        .padding(.bottom, 60)
                }
            }
            .containerRelativeFrame(.vertical) { height, _ in max(height * 0.74, 480) }
            .clipped()
            .onHover { isHovered = $0 }
            .task(id: "\(index)-\(isHovered)") {
                // Restart the timer whenever the slide changes or the pointer leaves.
                guard !isHovered, titles.count > 1 else { return }
                try? await Task.sleep(for: .seconds(9))
                guard !Task.isCancelled else { return }
                advance(by: 1)
            }
            .onChange(of: title.id, initial: true) { isInMyList = model.isInMyList(title) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Featured: \(title.name)")
        }
    }

    private func backdrop(for title: Title) -> some View {
        ZStack {
            ArtworkView(title: title, style: .backdrop)
                // Slow Ken Burns drift keeps the billboard alive.
                .phaseAnimator([1.0, 1.07]) { content, scale in
                    content.scaleEffect(scale, anchor: .trailing)
                } animation: { _ in .easeInOut(duration: 14) }
                .id(title.id)
                .transition(.opacity)
            LinearGradient(stops: [
                .init(color: .black.opacity(0.85), location: 0),
                .init(color: .black.opacity(0.45), location: 0.45),
                .init(color: .clear, location: 0.8),
            ], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, .clear, Theme.background], startPoint: .top, endPoint: .bottom)
        }
        .backgroundExtensionEffect()
    }

    private func info(for title: Title) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title.name)
                .font(.system(size: 64, weight: .black))
                .fontWidth(.condensed)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .shadow(color: .black.opacity(0.4), radius: 12)
            MetadataLine(title: title)
            if !title.synopsis.isEmpty {
                Text(title.synopsis)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(3)
                    .frame(maxWidth: 560, alignment: .leading)
            }
            HStack(spacing: 12) {
                Button { model.playResuming(title) } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(PlayButtonStyle())
                .keyboardShortcut(.return, modifiers: [])

                Button { model.open(title) } label: {
                    Label("More Info", systemImage: "info.circle")
                        .font(.headline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glass)

                Button {
                    model.toggleMyList(title)
                    isInMyList.toggle()
                } label: {
                    Image(systemName: isInMyList ? "checkmark" : "plus")
                        .font(.headline)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help(isInMyList ? "Remove from My List" : "Add to My List")
                .accessibilityLabel(isInMyList ? "Remove from My List" : "Add to My List")
            }
            .padding(.top, 4)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: 640, alignment: .leading)
    }

    private var pageIndicator: some View {
        HStack(spacing: 8) {
            ForEach(titles.indices, id: \.self) { i in
                Button {
                    withAnimation(.smooth(duration: 0.6)) { index = i }
                } label: {
                    Capsule()
                        .fill(i == index ? .white : .white.opacity(0.35))
                        .frame(width: i == index ? 26 : 8, height: 8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show \(titles[i].name)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }

    private func advance(by delta: Int) {
        withAnimation(.smooth(duration: 0.8)) {
            index = (index + delta + titles.count) % titles.count
        }
    }
}
