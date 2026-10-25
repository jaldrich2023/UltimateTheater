//
//  HeroCarousel.swift
//  Ultimate Theater
//

import SwiftUI

/// Full-bleed, auto-advancing billboard at the top of Home. Pauses while the pointer is over it
/// or a full-window player covers it, and stays put when Reduce Motion is on.
struct HeroCarousel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let titles: [Title]

    @State private var index = 0
    @State private var isHovered = false
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 64

    /// Whether the slides advance on their own right now.
    private var autoAdvances: Bool {
        titles.count > 1 && !isHovered && !reduceMotion && !model.isPlayerFullWindow
    }

    private var title: Title? { titles[safe: index] }

    var body: some View {
        if let title {
            ZStack(alignment: .bottomLeading) {
                backdrop(for: title)
                info(for: title)
                    .padding(.horizontal, pageMargin)
                    .padding(.bottom, 56)
                    .id(title.id)
                    .transition(reduceMotion ? .opacity
                                : .asymmetric(insertion: .opacity.combined(with: .offset(y: 12)), removal: .opacity))
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
            .task(id: TimerKey(index: index, isRunning: autoAdvances)) {
                // Restart the timer whenever the slide changes or advancing resumes.
                guard autoAdvances else { return }
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, autoAdvances else { return }
                advance(by: 1)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Featured: \(title.name)")
            .onChange(of: titles.count) { _, count in
                // Fewer featured titles (a removal, or a stricter profile): stay on a real slide.
                if index >= count { index = max(count - 1, 0) }
            }
        }
    }

    private func backdrop(for title: Title) -> some View {
        ZStack {
            // Shown at full width straight away, without drifting or panning.
            ArtworkView(title: title, style: .backdrop)
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
        .overlay(alignment: .bottom) { ArtEdgeDivider() }
    }

    private func info(for title: Title) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title.name)
                .font(.system(size: titleSize, weight: .black))
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
            let isInMyList = model.isInMyList(title)
            // One container so the adjacent glass buttons render and blend together.
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button { model.playResuming(title) } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(PlayButtonStyle())
                    // Return belongs to the player, a PIN pad, or the search field while they're in use.
                    .keyboardShortcut(model.acceptsPlayReturnKey ? KeyboardShortcut(.return, modifiers: []) : nil)

                    Button { model.open(title) } label: {
                        Label("More Info", systemImage: "info.circle")
                            .font(.headline)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.theaterGlass)

                    Button {
                        model.toggleMyList(title)
                    } label: {
                        Image(systemName: isInMyList ? "checkmark" : "plus")
                            .font(.headline)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.theaterGlassCircle)
                    .help(isInMyList ? "Remove from My List" : "Add to My List")
                    .accessibilityLabel(isInMyList ? "Remove from My List" : "Add to My List")

                    let isWatched = model.isWatched(title)
                    Button { model.setWatched(!isWatched, title) } label: {
                        Image(systemName: isWatched ? "checkmark.circle.fill" : "checkmark.circle")
                            .font(.headline)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(TheaterGlassButtonStyle(isCircular: true, tint: isWatched ? Theme.accent : nil))
                    .help(isWatched ? "Watched · Click to mark as unwatched" : "Mark as watched")
                    .accessibilityLabel(isWatched ? "Mark as unwatched" : "Mark as watched")
                }
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
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.6)) { index = i }
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

    private struct TimerKey: Equatable {
        let index: Int
        let isRunning: Bool
    }

    private func advance(by delta: Int) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.8)) {
            index = (index + delta + titles.count) % titles.count
        }
    }
}
