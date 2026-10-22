//
//  AboutView.swift
//  Ultimate Theater
//

import SwiftUI

/// The About Ultimate Theater window.
struct AboutView: View {
    @Environment(\.openURL) private var openURL

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 22) {
                // Loaded from the asset catalog so it never shows a stale cached system icon.
                Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 128, height: 128)
                    .shadow(color: Theme.accent.opacity(0.45), radius: 30, y: 10)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    BrandMark(size: 22)
                    Text("Your movies. Your theater.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(version)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }

                Divider().overlay(.white.opacity(0.1))

                VStack(alignment: .leading, spacing: 14) {
                    Text("Movie and TV information")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)

                    AttributionRow(
                        mark: AnyView(Image("TMDBLogo").resizable().scaledToFit().frame(height: 12)
                            .accessibilityLabel("TMDB")),
                        text: DataAttribution.tmdbNotice,
                        links: [("themoviedb.org", "https://www.themoviedb.org")]
                    )
                    AttributionRow(
                        mark: AnyView(Text("TVmaze").font(.callout.weight(.bold))),
                        text: "TV show and episode information from TVmaze, licensed under CC BY-SA 4.0.",
                        links: [("tvmaze.com", "https://www.tvmaze.com"),
                                ("CC BY-SA 4.0", "https://creativecommons.org/licenses/by-sa/4.0/")]
                    )
                    AttributionRow(
                        mark: AnyView(Text("Wikipedia").font(.callout.weight(.bold))),
                        text: "Synopses and images from Wikipedia, by Wikipedia contributors. Text licensed under CC BY-SA 4.0; images carry their own licenses.",
                        links: [("wikipedia.org", "https://www.wikipedia.org"),
                                ("CC BY-SA 4.0", "https://creativecommons.org/licenses/by-sa/4.0/")]
                    )
                    AttributionRow(
                        mark: AnyView(Text("OMDb").font(.callout.weight(.bold))),
                        text: "Ratings from the OMDb API. IMDb, Rotten Tomatoes, and Metacritic are trademarks of their respective owners.",
                        links: [("omdbapi.com", "https://www.omdbapi.com")]
                    )
                    AttributionRow(
                        mark: AnyView(Image(systemName: "play.rectangle").font(.callout)),
                        text: "Trailers are played from YouTube and Vimeo and are subject to those services' terms.",
                        links: []
                    )
                    AttributionRow(
                        mark: AnyView(Label("Content ratings", systemImage: "checkmark.shield").font(.callout.weight(.semibold))),
                        text: "\(RatingNotices.summary) \(RatingNotices.mpa) \(RatingNotices.tv)",
                        links: [("filmratings.com", "https://www.filmratings.com"), ("tvguidelines.org", "http://www.tvguidelines.org")]
                    )
                }
                .padding(16)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))

                VStack(spacing: 4) {
                    Text("Playback by the Ultimate Theater engine and Apple media frameworks.")
                    Text("© 2026 John Aldrich. All rights reserved.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 36)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(.dark)
    }

    private var background: some View {
        ZStack {
            Theme.background
            RadialGradient(colors: [Theme.accent.opacity(0.3), .clear], center: .top, startRadius: 0, endRadius: 360)
            RadialGradient(colors: [Color(hex: 0x4F7CFF).opacity(0.14), .clear], center: .bottomTrailing,
                           startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
    }

}

/// One data source: its mark, the required credit, and links.
private struct AttributionRow: View {
    @Environment(\.openURL) private var openURL
    let mark: AnyView
    let text: String
    let links: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            mark
                .foregroundStyle(.white.opacity(0.9))
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !links.isEmpty {
                HStack(spacing: 12) {
                    ForEach(links, id: \.0) { title, link in
                        Button(title) { if let url = URL(string: link) { openURL(url) } }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Attribution text required by the data providers' terms, shared wherever it's shown.
enum DataAttribution {
    /// Required verbatim by the TMDB API Terms of Use.
    static let tmdbNotice = "This application uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB."
}
