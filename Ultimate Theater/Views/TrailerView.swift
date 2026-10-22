//
//  TrailerView.swift
//  Ultimate Theater
//

import SwiftUI
import WebKit

/// Plays a title's trailer in the official embedded player.
struct TrailerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let title: Title
    let trailer: TrailerInfo

    @State private var page = WebPage()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.name)
                        .font(.headline)
                    Text(trailer.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let watchURL = trailer.watchURL {
                    Button {
                        openURL(watchURL)
                    } label: {
                        Label("Open in \(trailer.site)", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.glass)
                }
                Button("Done") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            WebView(page)
                .webViewElementFullscreenBehavior(.enabled)
                .webViewBackForwardNavigationGestures(.disabled)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(.black)
        }
        .frame(width: 1000)
        .background { AppBackground() }
        .preferredColorScheme(.dark)
        .task {
            guard let embed = trailer.embedURL else { return }
            // The embedded player expects to be hosted by a web page with an origin.
            let html = """
            <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
            <style>html,body{margin:0;height:100%;background:#000}iframe{border:0;width:100%;height:100%}</style>
            </head><body><iframe src="\(embed.absoluteString)" allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen></iframe></body></html>
            """
            _ = page.load(html: html, baseURL: URL(string: "https://ultimate-theater.app")!)
        }
    }
}
