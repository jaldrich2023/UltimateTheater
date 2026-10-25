//
//  AboutView.swift
//  Ultimate Theater
//

import SwiftUI

/// The About Ultimate Theater window.
struct AboutView: View {
    @Environment(\.openURL) private var openURL
    @State private var page: Page = .about

    private enum Page: String, CaseIterable, Identifiable {
        case about = "About"
        case license = "License"
        case notices = "Third-Party Notices"
        var id: String { rawValue }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                Picker("Page", selection: $page) {
                    ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 40)
                .padding(.top, 20)

                switch page {
                case .about: aboutPage
                case .license:
                    LegalTextPage(text: LegalDocument.license.text, isMarkdown: false)
                case .notices:
                    LegalTextPage(text: LegalDocument.thirdPartyNotices.text, isMarkdown: true)
                }
            }
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(.dark)
    }

    private var aboutPage: some View {
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
                        mark: AnyView(Text("OpenSubtitles").font(.callout.weight(.bold))),
                        text: "Downloaded subtitles come from OpenSubtitles.com, contributed by its community, and are subject to the OpenSubtitles terms of service.",
                        links: [("opensubtitles.com", "https://www.opensubtitles.com"),
                                ("Terms", "https://www.opensubtitles.com/en/tos")]
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
            .padding(.vertical, 28)
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

/// LICENSE and THIRD_PARTY_NOTICES.md from the top of the project, copied into the app
/// bundle as resources, so the About window always shows the files themselves.
enum LegalDocument {
    case license
    case thirdPartyNotices

    private var resource: (name: String, extension: String?) {
        switch self {
        case .license: ("LICENSE", nil)
        case .thirdPartyNotices: ("THIRD_PARTY_NOTICES", "md")
        }
    }

    /// The document's text, or a short note if the bundle is missing it.
    var text: String {
        let (name, ext) = resource
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return String(localized: "This document couldn't be loaded from the app bundle.")
        }
        return text.trimmingCharacters(in: .newlines)
    }
}

/// The license or the third-party notices, scrollable, in the About window. Markdown text
/// gets light formatting: headings, quotes, and table rows as stacked lines.
private struct LegalTextPage: View {
    let text: String
    let isMarkdown: Bool

    @ScaledMetric(relativeTo: .caption) private var monospacedSize: CGFloat = 11

    /// One piece of the notices, in reading order.
    private enum Block {
        case paragraph(String)
        case heading(String, level: Int)
        /// A table row's cells; the first is shown as its title.
        case tableRow([String])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if isMarkdown {
                    // Static text, so offsets are stable ids; parsing is cheap and only runs when the page is shown.
                    ForEach(Array(Self.blocks(in: text).enumerated()), id: \.offset) { _, block in
                        view(for: block)
                    }
                } else {
                    Text(verbatim: text)
                        .font(.system(size: monospacedSize, design: .monospaced))
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
        .frame(height: 560)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text).font(.callout)
        case .heading(let text, let level):
            switch level {
            case 1: inline(text).font(.title3.weight(.bold))
            case 2: inline(text).font(.headline).padding(.top, 8)
            default: inline(text).font(.subheadline.weight(.bold)).padding(.top, 4)
            }
        case .tableRow(let cells):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                    inline(cell).font(index == 0 ? .callout.weight(.semibold) : .caption)
                        .foregroundStyle(index == 0 ? .primary : .secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Paragraphs (consecutive lines joined), headings, quotes, list items, and table rows.
    private static func blocks(in text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph = []
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("### ") {
                flush(); blocks.append(.heading(String(line.dropFirst(4)), level: 3))
            } else if line.hasPrefix("## ") {
                flush(); blocks.append(.heading(String(line.dropFirst(3)), level: 2))
            } else if line.hasPrefix("# ") {
                flush(); blocks.append(.heading(String(line.dropFirst(2)), level: 1))
            } else if line.hasPrefix("| ---") {
                continue
            } else if line.hasPrefix("|") {
                flush()
                blocks.append(.tableRow(line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }))
            } else if line.hasPrefix(">") {
                paragraph.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("- ") {
                flush(); paragraph.append("•  " + line.dropFirst(2))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    private func inline(_ markdown: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown))
    }
}
