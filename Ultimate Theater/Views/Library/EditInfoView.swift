//
//  EditInfoView.swift
//  Ultimate Theater
//

import SwiftUI

/// Manually edit a title's details. Locking keeps refreshes from overwriting them.
struct EditInfoView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let title: Title
    @State private var edits: MetadataEdits
    @State private var yearText: String

    init(title: Title) {
        self.title = title
        let item = (title.posterURL?.absoluteString ?? "", title.backdropURL?.absoluteString ?? "")
        _edits = State(initialValue: MetadataEdits(
            name: title.name,
            year: title.year,
            tagline: title.tagline,
            synopsis: title.synopsis,
            maturity: title.maturity,
            genres: title.genres,
            posterURL: item.0,
            backdropURL: item.1,
            isLocked: true
        ))
        _yearText = State(initialValue: title.yearText ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Title", text: $edits.name)
                    TextField("Year", text: $yearText)
                    TextField("Rating", text: $edits.maturity, prompt: Text("PG-13, TV-MA, …"))
                    TextField("Tagline", text: $edits.tagline)
                    LabeledContent("Synopsis") {
                        TextEditor(text: $edits.synopsis)
                            .font(.body)
                            .frame(minHeight: 90)
                    }
                }
                Section("Genres") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading) {
                        ForEach(Genre.allCases) { genre in
                            Toggle(genre.displayName, isOn: Binding(
                                get: { edits.genres.contains(genre) },
                                set: { isOn in
                                    if isOn { edits.genres.append(genre) } else { edits.genres.removeAll { $0 == genre } }
                                }
                            ))
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                Section("Artwork") {
                    TextField("Poster URL", text: $edits.posterURL)
                    TextField("Backdrop URL", text: $edits.backdropURL)
                }
                Section {
                    Toggle("Lock info", isOn: $edits.isLocked)
                } footer: {
                    Text("Locked titles keep your edits when info is refreshed. Ratings still update.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    edits.year = Int(yearText.trimmingCharacters(in: .whitespaces))
                    model.library.applyEdits(edits, to: title.id)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(edits.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 560, height: 560)
    }
}

/// Bottom-of-window status for imports and metadata fetches.
struct LibraryActivityBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let activity = model.library.activity {
                HStack(spacing: 12) {
                    if let fraction = activity.fraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(activity.message)
                        .lineLimit(1)
                    if activity.total > 0 {
                        Text("\(activity.completed) of \(activity.total)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let notice = model.library.notice {
                HStack(spacing: 10) {
                    Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(notice.isError ? .orange : .green)
                    Text(notice.message)
                        .lineLimit(2)
                    Button {
                        withAnimation { model.library.notice = nil }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Dismiss")
                }
                .task(id: notice.id) {
                    try? await Task.sleep(for: .seconds(notice.isError ? 10 : 6))
                    withAnimation { if model.library.notice?.id == notice.id { model.library.notice = nil } }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .font(.callout)
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
        .opacity(model.library.activity == nil && model.library.notice == nil ? 0 : 1)
        .animation(.smooth, value: model.library.activity)
        .animation(.smooth, value: model.library.notice)
        .padding(.bottom, 24)
    }
}
