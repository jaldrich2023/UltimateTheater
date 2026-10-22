//
//  ArtworkView.swift
//  Ultimate Theater
//

import SwiftUI

enum ArtworkStyle {
    /// 2:3 key art.
    case poster
    /// 16:9 tile with the title in the lower-leading corner.
    case landscape
    /// Full-bleed hero/detail background with no text.
    case backdrop
}

/// Real artwork from the metadata sources when available, falling back to generated
/// art (genre palette + glyph) while loading or when a title has no images.
struct ArtworkView: View {
    let title: Title
    var style: ArtworkStyle = .poster

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                GeneratedArtwork(title: title, style: style, size: size,
                                 showsTitle: style != .backdrop && !hasImage)
                if let backdrop = style == .poster ? nil : title.backdropURL {
                    RemoteImage(url: backdrop, size: style == .backdrop ? .backdrop : .wide)
                    if style == .landscape { landscapeTitle(in: size) }
                } else if let poster = title.posterURL {
                    if style == .poster {
                        RemoteImage(url: poster, size: .poster)
                    } else {
                        posterAsBackdrop(poster, in: size)
                        if style == .landscape { landscapeTitle(in: size) }
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .clipped()
        .accessibilityElement()
        .accessibilityLabel(title.name)
    }

    private var hasImage: Bool {
        title.posterURL != nil || (style != .poster && title.backdropURL != nil)
    }

    /// Wide slots with only a poster: a blurred fill with the poster set to the trailing side.
    private func posterAsBackdrop(_ url: URL, in size: CGSize) -> some View {
        ZStack(alignment: .trailing) {
            RemoteImage(url: url, size: .poster)
                .blur(radius: 40)
                .opacity(0.7)
            RemoteImage(url: url, contentMode: .fit, size: .wide)
                .frame(width: size.height * 0.92 * 2 / 3, height: size.height * 0.92)
                .clipShape(.rect(cornerRadius: max(size.height * 0.02, 4)))
                .shadow(color: .black.opacity(0.5), radius: 20)
                .padding(.trailing, size.width * (style == .backdrop ? 0.08 : 0.05))
        }
    }

    private func landscapeTitle(in size: CGSize) -> some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            Text(title.name)
                .font(.system(size: max(size.height * 0.11, 11), weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .shadow(color: .black.opacity(0.6), radius: 6)
                .padding(size.height * 0.08)
        }
    }
}

/// A remote image that fills its frame. Cached art draws on the first frame; art that has
/// to be downloaded fades in over the generated artwork underneath.
struct RemoteImage: View {
    let url: URL
    var contentMode: ContentMode
    var size: ArtworkCache.Size
    @State private var image: CGImage?

    init(url: URL, contentMode: ContentMode = .fill, size: ArtworkCache.Size = .wide) {
        self.url = url
        self.contentMode = contentMode
        self.size = size
        _image = State(initialValue: ArtworkCache.shared.cachedImage(for: url, size: size))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .accessibilityHidden(true)
        .task(id: url) {
            if let cached = ArtworkCache.shared.cachedImage(for: url, size: size) {
                image = cached
                return
            }
            let isLocal = ArtworkCache.shared.isOnDisk(url)
            let loaded = await ArtworkCache.shared.image(for: url, size: size)
            if isLocal { image = loaded } else { withAnimation(.easeOut(duration: 0.25)) { image = loaded } }
        }
    }
}

/// Generated key art from the title's genre palette and glyph.
private struct GeneratedArtwork: View {
    let title: Title
    let style: ArtworkStyle
    let size: CGSize
    let showsTitle: Bool

    var body: some View {
        ZStack {
            background
            motif
            vignette
            if showsTitle {
                titleTreatment
            }
        }
    }

    private var palette: (Color, Color, Color) {
        let colors = title.artwork.colors
        return (colors[safe: 0] ?? .gray, colors[safe: 1] ?? .black, colors[safe: 2] ?? .black)
    }

    /// Stable 0...1 value derived from the title ID, used to vary composition per title.
    private var seed: Float {
        let sum = title.id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Float(sum % 100) / 100
    }

    private var background: some View {
        let (a, b, c) = palette
        return MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.3 + seed * 0.4, 0.35 + (1 - seed) * 0.3], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ],
            colors: [
                c, b, c,
                a, b.mix(with: a, by: 0.4), c,
                b, c, c,
            ]
        )
    }

    private var motif: some View {
        let (a, _, _) = palette
        let dimension = style == .poster ? size.height * 0.62 : size.height * 0.95
        let offset: CGSize = switch style {
        case .poster: CGSize(width: size.width * 0.22, height: -size.height * 0.08)
        case .landscape: CGSize(width: size.width * 0.26, height: -size.height * 0.04)
        case .backdrop: CGSize(width: size.width * 0.24, height: -size.height * 0.02)
        }
        return ZStack {
            Circle()
                .fill(a.opacity(0.55))
                .frame(width: dimension * 0.9, height: dimension * 0.9)
                .blur(radius: dimension * 0.22)
            Image(systemName: title.artwork.symbol)
                .resizable()
                .scaledToFit()
                .frame(width: dimension, height: dimension)
                .foregroundStyle(
                    LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .rotationEffect(.degrees(-10 + Double(seed) * 20))
                .blendMode(.plusLighter)
        }
        .offset(offset)
    }

    private var vignette: some View {
        ZStack {
            RadialGradient(colors: [.clear, .black.opacity(0.55)], center: .center, startRadius: 0, endRadius: 600)
            if style != .backdrop {
                LinearGradient(colors: [.clear, .clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
            }
        }
    }

    private var titleTreatment: some View {
        let isPoster = style == .poster
        return VStack(alignment: isPoster ? .center : .leading, spacing: size.height * 0.02) {
            Spacer(minLength: 0)
            Text(title.name.uppercased())
                .font(.system(size: isPoster ? size.width * 0.15 : size.height * 0.15, weight: .black))
                .fontWidth(.compressed)
                .tracking(isPoster ? 1 : 0.5)
                .multilineTextAlignment(isPoster ? .center : .leading)
                .lineLimit(3)
                .minimumScaleFactor(0.5)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
            if isPoster, let year = title.yearText {
                Text(year)
                    .font(.system(size: max(size.width * 0.06, 8), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding(isPoster ? size.width * 0.08 : size.height * 0.09)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isPoster ? .center : .leading)
    }
}

nonisolated extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
