//
//  SetupWizardView.swift
//  Ultimate Theater
//
//  The first-launch guide: create the first profile, protect the household with an
//  administrator PIN, add movie and TV folders, connect movie-info sources, and choose
//  the ratings country.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SetupWizardView: View {
    private enum Step: Int, CaseIterable {
        case welcome, profile, pin, library, sources, ratings, done

        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .profile: "Profile"
            case .pin: "Protection"
            case .library: "Library"
            case .sources: "Sources"
            case .ratings: "Ratings"
            case .done: "Ready"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @State private var step: Step = .welcome
    @State private var draft = ProfileDraft()
    @State private var hasAdministratorPIN = AdministratorPIN.isSet
    @State private var addedFolders: [URL] = []
    @State private var tmdbKey = ""
    @State private var omdbKey = ""
    @State private var sourceChecks: [MetadataProviderID: SourceCheck] = [:]
    @FocusState private var isNameFocused: Bool

    private var accent: Color { draft.preview.colors[0] }
    private var settings: MetadataSettings { model.library.metadata.settings }

    var body: some View {
        VStack(spacing: 28) {
            progress
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, minHeight: 360, alignment: .top)
                    .padding(.horizontal, 48)
                    .padding(.top, 40)
                navigation
                    .padding(.horizontal, 48)
                    .padding(.vertical, 28)
            }
            .frame(width: 820)
            .glassEffect(.regular, in: .rect(cornerRadius: 32))
            .shadow(color: .black.opacity(0.45), radius: 40, y: 20)
            .animation(.smooth(duration: 0.35), value: step)
        }
        .padding(40)
        .onAppear {
            tmdbKey = settings.apiKey(for: .tmdb) ?? ""
            omdbKey = settings.apiKey(for: .omdb) ?? ""
        }
    }

    // MARK: Chrome

    private var progress: some View {
        HStack(spacing: 10) {
            ForEach(Step.allCases, id: \.self) { item in
                VStack(spacing: 6) {
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.white.opacity(0.15)))
                        .frame(width: 84, height: 4)
                    Text(item.title)
                        .font(.caption.weight(item == step ? .bold : .regular))
                        .foregroundStyle(item == step ? .primary : .secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count): \(step.title)")
    }

    private var navigation: some View {
        HStack {
            if step != .welcome, step != .done {
                Button("Back") { move(-1) }
                    .buttonStyle(.glass)
            }
            Spacer()
            switch step {
            case .welcome:
                Button("Get Started") { move(1) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            case .profile:
                Button("Continue") { move(1) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            case .pin, .library, .sources:
                if isStepSkippable {
                    Button("Skip") { move(1) }
                        .buttonStyle(.glass)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Continue") { move(1) }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                }
            case .ratings:
                Button("Continue") { move(1) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            case .done:
                Button("Start Watching", action: finish)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }

    private var isStepSkippable: Bool {
        switch step {
        case .pin: !hasAdministratorPIN
        case .library: addedFolders.isEmpty && model.library.folders.isEmpty
        default: false
        }
    }

    private func move(_ delta: Int) {
        if step == .sources { saveKeys() }
        step = Step(rawValue: step.rawValue + delta) ?? step
        if step == .profile { isNameFocused = true }
    }

    // MARK: Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .profile: profile
        case .pin: pin
        case .library: library
        case .sources: sources
        case .ratings: ratings
        case .done: done
        }
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            BrandMark(size: 26)
            Text("Welcome to your theater")
                .font(.system(size: 44, weight: .bold))
            Text("Let's set things up. In a few steps you'll create your profile, add your movies and shows, and choose how titles are rated for your household.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 600)
            HStack(spacing: 28) {
                feature("person.crop.circle.fill", "Profiles", "Lists, progress, and limits for everyone")
                feature("film.stack.fill", "Your library", "Movies and shows from your own drives")
                feature("sparkles.tv.fill", "Rich details", "Artwork, cast, ratings, and trailers")
            }
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundStyle(Theme.accent)
                .frame(width: 60, height: 60)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
            Text(title).font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 190)
    }

    private var profile: some View {
        HStack(alignment: .top, spacing: 40) {
            VStack(spacing: 14) {
                ProfileAvatar(profile: draft.preview, size: 150)
                    .shadow(color: accent.opacity(0.6), radius: 30, y: 10)
                Button(draft.imageData == nil ? "Choose Picture…" : "Change Picture…", systemImage: "photo", action: choosePicture)
                    .buttonStyle(.glass)
            }
            VStack(alignment: .leading, spacing: 20) {
                header("Create your profile", "This is the household's main profile. It can watch everything and manage the library.")
                TextField("", text: $draft.name, prompt: Text("Your name").foregroundStyle(.white.opacity(0.35)))
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.white.opacity(0.08), in: .rect(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(isNameFocused ? accent : .white.opacity(0.12), lineWidth: isNameFocused ? 2 : 1))
                    .focused($isNameFocused)
                    .onSubmit { if !draft.name.isEmpty { move(1) } }
                HStack(spacing: 12) {
                    ForEach(Profile.palettes.indices, id: \.self) { index in
                        Button { draft.paletteIndex = index } label: {
                            Circle()
                                .fill(LinearGradient(colors: Profile.palettes[index], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 30, height: 30)
                                .overlay(Circle().strokeBorder(.white, lineWidth: draft.paletteIndex == index ? 3 : 0))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Color \(index + 1)")
                    }
                }
                HStack(spacing: 8) {
                    ForEach(Profile.symbols.prefix(10), id: \.self) { symbol in
                        Button { draft.symbol = symbol } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 40, height: 40)
                                .background(draft.symbol == symbol ? AnyShapeStyle(accent.opacity(0.5)) : AnyShapeStyle(.white.opacity(0.07)),
                                            in: .rect(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(symbol)
                    }
                }
            }
        }
    }

    private var pin: some View {
        VStack(alignment: .leading, spacing: 22) {
            header("Protect your household", "An administrator PIN keeps children's profiles from switching to grown-up ones, and is needed to add, change, or remove profiles. You can set it up later in Settings.")
            HStack(spacing: 18) {
                Image(systemName: hasAdministratorPIN ? "lock.shield.fill" : "lock.shield")
                    .font(.system(size: 44))
                    .foregroundStyle(hasAdministratorPIN ? .green : Theme.accent)
                    .frame(width: 80, height: 80)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
                VStack(alignment: .leading, spacing: 8) {
                    Text(hasAdministratorPIN ? "Administrator PIN is set" : "No administrator PIN yet")
                        .font(.title3.weight(.semibold))
                    Button(hasAdministratorPIN ? "Change PIN…" : "Set Administrator PIN…") {
                        model.requestNewPIN(title: "Administrator PIN", message: "Choose a four-digit PIN for the household.") { pin in
                            AdministratorPIN.set(pin)
                            hasAdministratorPIN = true
                        }
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 20) {
            header("Add your movies and shows", "Choose the folders where your videos live. Ultimate Theater finds every movie and episode inside, fetches its details, and keeps watching the folders for anything new.")
            HStack(spacing: 14) {
                Button("Add Movies Folder…", systemImage: "film") { chooseFolders() }
                    .buttonStyle(.glass)
                Button("Add TV Shows Folder…", systemImage: "tv") { chooseFolders() }
                    .buttonStyle(.glass)
            }
            .controlSize(.large)
            if !addedFolders.isEmpty || !model.library.folders.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(Set(addedFolders.map(\.path) + model.library.folders.map(\.path))).sorted(), id: \.self) { path in
                        Label(path, systemImage: "folder.fill")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.06), in: .rect(cornerRadius: 12))
            }
            if let activity = model.library.activity {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(activity.message).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Toggle("Automatically add new videos from these folders", isOn: Bindable(model.library).watchesFolders)
                .toggleStyle(.switch)
                .tint(Theme.accent)
        }
    }

    // MARK: Sources

    /// The result of checking a source's connection (and key).
    private enum SourceCheck: Equatable {
        case checking
        case connected
        case failed(String)
    }

    /// Main source first, then the ones that fill in around it.
    private static let sourceOrder: [MetadataProviderID] = [.tmdb, .tvmaze, .omdb, .wikipedia]

    private var sources: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Where movie and TV info comes from",
                   "Ultimate Theater looks up posters, cast, synopses, episode guides, and ratings online. Choose the sources to use. TMDB and OMDb each need a free API key, which takes about a minute to get; the others work right away.")
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Self.sourceOrder) { sourceCard($0) }
                }
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: 380)
            Toggle("Look up info automatically when titles are added", isOn: Binding(
                get: { settings.autoFetch }, set: { settings.autoFetch = $0 }))
                .toggleStyle(.switch)
                .tint(Theme.accent)
            HStack(spacing: 10) {
                Image("TMDBLogo").resizable().scaledToFit().frame(height: 12)
                Text(DataAttribution.tmdbNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sourceCard(_ id: MetadataProviderID) -> some View {
        let enabled = settings.enabledProviders.contains(id)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: Self.symbol(for: id))
                    .font(.title3)
                    .foregroundStyle(enabled ? Theme.accent : .secondary)
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(id.displayName).font(.headline)
                        ForEach(Self.coverage(of: id), id: \.self) { tag in
                            Text(tag)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(.white.opacity(0.1), in: .capsule)
                        }
                        if id == .tmdb {
                            Text("Recommended")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    Text(id.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle(id.displayName, isOn: Binding(
                    get: { settings.enabledProviders.contains(id) },
                    set: { isOn in
                        if isOn { settings.enabledProviders.insert(id) } else { settings.enabledProviders.remove(id) }
                    }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(Theme.accent)
            }
            if enabled {
                if id.requiresAPIKey {
                    keyRow(for: id)
                } else {
                    HStack(spacing: 10) {
                        Label("No key needed", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        checkStatus(for: id)
                        Button("Test Connection") { check(id) }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .disabled(sourceChecks[id] == .checking)
                    }
                    .padding(.leading, 54)
                }
            } else if id == .tmdb {
                Text("Without TMDB, details and artwork come only from the other sources and may be incomplete.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 54)
            }
        }
        .padding(14)
        .background(.white.opacity(enabled ? 0.06 : 0.03), in: .rect(cornerRadius: 16))
        .animation(.smooth(duration: 0.25), value: enabled)
    }

    private func keyRow(for id: MetadataProviderID) -> some View {
        let key = id == .tmdb ? $tmdbKey : $omdbKey
        return VStack(alignment: .leading, spacing: 8) {
            if key.wrappedValue.isEmpty {
                HStack(spacing: 6) {
                    Text(Self.keyInstructions(for: id))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let url = id.keySignupURL {
                        Link("Get a free key", destination: url).font(.caption.weight(.semibold))
                    }
                }
            }
            HStack(spacing: 10) {
                SecureField("", text: key, prompt: Text("Paste your \(id.displayName) API key").foregroundStyle(.white.opacity(0.35)))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.08), in: .rect(cornerRadius: 10))
                    .onChange(of: key.wrappedValue) { sourceChecks[id] = nil }
                checkStatus(for: id)
                Button("Check Key") { check(id) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(key.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty || sourceChecks[id] == .checking)
            }
            if case .failed(let message) = sourceChecks[id] {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 54)
    }

    @ViewBuilder
    private func checkStatus(for id: MetadataProviderID) -> some View {
        switch sourceChecks[id] {
        case .checking:
            ProgressView().controlSize(.small)
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        case .failed:
            Label("Didn't work", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        case nil:
            EmptyView()
        }
    }

    /// Saves the key (if any) and runs a test search against the source.
    private func check(_ id: MetadataProviderID) {
        if id == .tmdb { settings.setAPIKey(tmdbKey, for: .tmdb) }
        if id == .omdb { settings.setAPIKey(omdbKey, for: .omdb) }
        sourceChecks[id] = .checking
        Task {
            let error = await model.library.metadata.test(id)
            sourceChecks[id] = error.map(SourceCheck.failed) ?? .connected
        }
    }

    private static func symbol(for id: MetadataProviderID) -> String {
        switch id {
        case .tmdb: "film.stack"
        case .tvmaze: "tv"
        case .omdb: "star.leadinghalf.filled"
        case .wikipedia: "book.closed"
        }
    }

    private static func coverage(of id: MetadataProviderID) -> [String] {
        switch id {
        case .tmdb: ["Movies", "TV", "Artwork"]
        case .tvmaze: ["TV", "Episodes"]
        case .omdb: ["Ratings"]
        case .wikipedia: ["Synopses"]
        }
    }

    private static func keyInstructions(for id: MetadataProviderID) -> String {
        switch id {
        case .tmdb: "Create a free TMDB account, open Settings → API, and copy the “API Key”."
        case .omdb: "Request a free key with your email address; OMDb sends it within a minute."
        default: ""
        }
    }

    private var ratings: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 20) {
            header("How titles are rated", "Choose the country whose rating system your household uses. It decides which rating is shown and what profiles with content limits can watch.")
            Picker("Ratings country", selection: $model.ratingsCountry) {
                ForEach(ContentRating.countries, id: \.code) { country in
                    Text(country.name).tag(country.code)
                }
            }
            .frame(maxWidth: 360)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(RatingLimit.allCases) { limit in
                    HStack(alignment: .firstTextBaseline) {
                        Text(limit.title).font(.callout.weight(.semibold)).frame(width: 110, alignment: .leading)
                        Text(limit.addedRatings(in: model.ratingsCountry).joined(separator: "  ·  "))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
            .background(.white.opacity(0.06), in: .rect(cornerRadius: 12))
            Text("You can add profiles for children with a content limit right after setup.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var done: some View {
        VStack(spacing: 20) {
            ProfileAvatar(profile: draft.preview, size: 120)
                .shadow(color: accent.opacity(0.6), radius: 30, y: 10)
            Text("You're all set, \(draft.name)")
                .font(.system(size: 38, weight: .bold))
            Text(model.library.isBusy
                 ? "Your library is still being scanned. Titles appear as they're found."
                 : "Your theater is ready. Add more profiles any time from the profile screen.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func header(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 30, weight: .bold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url, let data = ProfilePicture.avatarData(from: url) else { return }
        draft.imageData = data
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        addedFolders += panel.urls
        let urls = panel.urls
        Task { await model.library.importMedia(from: urls) }
    }

    private func saveKeys() {
        settings.setAPIKey(tmdbKey, for: .tmdb)
        settings.setAPIKey(omdbKey, for: .omdb)
    }

    private func finish() {
        saveKeys()
        draft.ratingLimit = .everything
        if let profile = model.saveProfile(draft) {
            model.select(profile)
        }
    }
}

