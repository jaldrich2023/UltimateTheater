//
//  ProfilePickerView.swift
//  Ultimate Theater
//

import SwiftUI
import UniformTypeIdentifiers

/// "Who's watching?": choose, create, edit, and remove profiles. A new installation
/// starts here with no profiles and a welcome message.
struct ProfilePickerView: View {
    @Environment(AppModel.self) private var model
    @State private var hasAppeared = false
    /// The profile being created (`nil` id) or edited.
    @State private var editing: ProfileDraft?
    @State private var isManaging = false

    /// Tiles per row before wrapping onto another row.
    private let columns = 5

    var body: some View {
        ZStack {
            ProfileBackdrop()
            if model.profiles.isEmpty {
                SetupWizardView()
            } else {
                picker
            }
            if let draft = editing {
                ProfileEditor(draft: draft) { editing = nil }
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .zIndex(1)
            }
        }
        .foregroundStyle(.white)
        .animation(.smooth(duration: 0.35), value: editing?.id)
        .animation(.smooth(duration: 0.35), value: editing == nil)
        .onAppear { hasAppeared = true }
        .onChange(of: model.profiles.isEmpty) { _, isEmpty in
            if isEmpty { isManaging = false }
        }
    }

    // MARK: Who's watching

    private var picker: some View {
        VStack(spacing: 56) {
            VStack(spacing: 14) {
                BrandMark(size: 22)
                Text(isManaging ? "Manage Profiles" : "Who's watching?")
                    .font(.system(size: 52, weight: .bold))
                    .contentTransition(.opacity)
            }
            VStack(spacing: 36) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 40) {
                        ForEach(row) { tile($0) }
                    }
                }
            }
            HStack(spacing: 14) {
                Button {
                    if isManaging {
                        withAnimation(.smooth) { isManaging = false }
                    } else {
                        model.requireAdministrator("Enter the administrator PIN to manage profiles.") {
                            withAnimation(.smooth) { isManaging = true }
                        }
                    }
                } label: {
                    Label(isManaging ? "Done" : "Manage Profiles", systemImage: isManaging ? "checkmark" : "pencil")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .keyboardShortcut(isManaging ? .cancelAction : KeyboardShortcut("m", modifiers: .command))
            }
            Text(isManaging ? "Choose a profile to edit or remove it" : "Press 1–\(min(model.profiles.count, 9)) to choose a profile")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private enum Tile: Identifiable {
        case profile(Profile, index: Int)
        case add

        var id: String {
            switch self {
            case .profile(let profile, _): profile.id
            case .add: "add"
            }
        }
    }

    private var rows: [[Tile]] {
        var tiles = model.profiles.enumerated().map { Tile.profile($1, index: $0) }
        if model.canAddProfile, !isManaging { tiles.append(.add) }
        return stride(from: 0, to: tiles.count, by: columns).map { Array(tiles[$0..<min(tiles.count, $0 + columns)]) }
    }

    @ViewBuilder
    private func tile(_ tile: Tile) -> some View {
        switch tile {
        case .profile(let profile, let index):
            ProfileTile(profile: profile, isLastUsed: profile.id == model.lastProfileID, isManaging: isManaging) {
                if isManaging { editing = ProfileDraft(profile) } else { model.requestOpen(profile) }
            }
            .numberShortcut(index)
            .contextMenu {
                Button("Edit Profile…", systemImage: "pencil") {
                    model.requireAdministrator("Enter the administrator PIN to edit \(profile.name).") { editing = ProfileDraft(profile) }
                }
            }
            .appearing(hasAppeared, delay: Double(index) * 0.07)
        case .add:
            AddProfileTile(title: "Add Profile") {
                model.requireAdministrator("Enter the administrator PIN to add a profile.") { editing = ProfileDraft() }
            }
                .keyboardShortcut("n", modifiers: .command)
                .appearing(hasAppeared, delay: Double(model.profiles.count) * 0.07)
        }
    }
}

/// The deep gradient behind the profile screens.
private struct ProfileBackdrop: View {
    var body: some View {
        ZStack {
            Theme.background
            RadialGradient(colors: [Theme.accent.opacity(0.25), .clear], center: .top, startRadius: 0, endRadius: 700)
            RadialGradient(colors: [Color(hex: 0x4F7CFF).opacity(0.18), .clear], center: .bottomTrailing,
                           startRadius: 0, endRadius: 800)
        }
        .ignoresSafeArea()
    }
}

private extension View {
    /// Number keys 1–9 choose the first nine profiles.
    @ViewBuilder
    func numberShortcut(_ index: Int) -> some View {
        if index < 9 {
            keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [])
        } else {
            self
        }
    }

    /// The picker's staggered entrance.
    func appearing(_ hasAppeared: Bool, delay: Double) -> some View {
        opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 20)
            .animation(.smooth(duration: 0.6).delay(delay), value: hasAppeared)
    }
}

// MARK: - Tiles

private struct ProfileTile: View {
    let profile: Profile
    let isLastUsed: Bool
    let isManaging: Bool
    let action: () -> Void
    @State private var isHovered = false

    private var caption: String {
        if isManaging { return "Edit" }
        return profile.ratingLimit == .everything ? " " : profile.ratingLimit.title
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 16) {
                ProfileAvatar(profile: profile, size: 150)
                    .overlay {
                        if isManaging {
                            RoundedRectangle(cornerRadius: 150 * 0.24)
                                .fill(.black.opacity(0.45))
                                .overlay {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 44, weight: .semibold))
                                }
                                .transition(.opacity)
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 150 * 0.24)
                            .strokeBorder(.white, lineWidth: isHovered ? 4 : 0)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if profile.hasPIN, !isManaging {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 14, weight: .bold))
                                .padding(8)
                                .glassEffect(.regular, in: .circle)
                                .offset(x: 6, y: 6)
                                .accessibilityLabel("Locked with a PIN")
                        }
                    }
                    .scaleEffect(isHovered ? 1.06 : 1)
                    .shadow(color: profile.colors[0].opacity(isHovered ? 0.6 : 0.2), radius: isHovered ? 30 : 12, y: 8)
                VStack(spacing: 4) {
                    Text(profile.name)
                        .font(.title3.weight(isHovered ? .bold : .medium))
                        .foregroundStyle(isHovered ? .white : .white.opacity(0.75))
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(profile.lastUsedDescription)
                        .font(.caption2)
                        .foregroundStyle(isLastUsed ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                }
                .frame(width: 170)
                .lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isHovered = hovering } }
        .animation(.smooth, value: isManaging)
        .accessibilityLabel(isManaging ? "Edit \(profile.name)" : "\(profile.name) profile")
    }
}

/// A dashed tile that starts a new profile.
private struct AddProfileTile: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 150 * 0.24)
                    .strokeBorder(.white.opacity(isHovered ? 0.9 : 0.35), style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                    .background(.white.opacity(isHovered ? 0.1 : 0.04), in: .rect(cornerRadius: 150 * 0.24))
                    .frame(width: 150, height: 150)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 54, weight: .semibold))
                            .foregroundStyle(.white.opacity(isHovered ? 1 : 0.7))
                    }
                    .scaleEffect(isHovered ? 1.06 : 1)
                VStack(spacing: 4) {
                    Text(title)
                        .font(.title3.weight(isHovered ? .bold : .medium))
                        .foregroundStyle(isHovered ? .white : .white.opacity(0.75))
                    Text(" ")
                        .font(.caption)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isHovered = hovering } }
        .help("Create a new profile (⌘N)")
    }
}

// MARK: - Editor

/// Editable copy of a profile.
struct ProfileDraft: Identifiable {
    let id: String?
    var name: String
    var symbol: String
    var paletteIndex: Int
    var ratingLimit: RatingLimit
    var allowsUnrated: Bool
    var imageData: Data?
    /// Whether the saved profile already has a PIN.
    let hadPIN: Bool
    var pinChange: PINChange = .unchanged

    var requiresPIN: Bool {
        switch pinChange {
        case .unchanged: hadPIN
        case .set: true
        case .remove: false
        }
    }

    init() {
        id = nil
        name = ""
        symbol = Profile.symbols[0]
        paletteIndex = Int.random(in: 0..<Profile.palettes.count)
        ratingLimit = .everything
        allowsUnrated = true
        hadPIN = false
    }

    init(_ profile: Profile) {
        id = profile.id
        name = profile.name
        symbol = profile.symbol
        paletteIndex = profile.paletteIndex
        ratingLimit = profile.ratingLimit
        allowsUnrated = profile.allowsUnrated
        imageData = profile.imageData
        hadPIN = profile.hasPIN
    }

    var preview: Profile {
        var profile = Profile(id: id ?? "draft", name: name, symbol: symbol, paletteIndex: paletteIndex,
                              ratingLimit: ratingLimit, allowsUnrated: allowsUnrated)
        profile.imageData = imageData
        profile.image = imageData.flatMap(NSImage.init(data:))
        profile.hasPIN = requiresPIN
        return profile
    }
}

/// Creates or edits a profile on a glass panel over the profile screen: a live avatar
/// preview, name, colors, icon, and the content ratings this profile may watch.
private struct ProfileEditor: View {
    @Environment(AppModel.self) private var model
    @State private var draft: ProfileDraft
    @State private var isConfirmingDelete = false
    @State private var isDropTargeted = false
    @State private var hasAdministratorPIN = AdministratorPIN.isSet
    @FocusState private var isNameFocused: Bool
    let close: () -> Void

    init(draft: ProfileDraft, close: @escaping () -> Void) {
        _draft = State(initialValue: draft)
        self.close = close
    }

    private var isNew: Bool { draft.id == nil }
    private var isValid: Bool { !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var accent: Color { draft.preview.colors[0] }

    var body: some View {
        ZStack {
            // Dim and soften the picker behind the panel.
            Rectangle()
                .fill(.black.opacity(0.55))
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
            RadialGradient(colors: [accent.opacity(0.35), .clear], center: .center, startRadius: 0, endRadius: 650)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .animation(.smooth, value: draft.paletteIndex)

            HStack(alignment: .top, spacing: 44) {
                identity
                VStack(alignment: .leading, spacing: 26) {
                    nameField
                    colorPicker
                    iconPicker
                    ratingPicker
                }
                .frame(width: 520)
            }
            .padding(.horizontal, 44)
            .padding(.top, 40)
            .padding(.bottom, 96)
            .overlay(alignment: .bottom) { actions }
            .glassEffect(.regular, in: .rect(cornerRadius: 32))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
        }
        .onAppear { isNameFocused = isNew }
        .onExitCommand(perform: close)
        .confirmationDialog("Remove \(draft.name)?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Remove Profile", role: .destructive) {
                if let id = draft.id, let profile = model.profiles.first(where: { $0.id == id }) {
                    model.requestRemoval(of: profile, then: close)
                } else {
                    close()
                }
            }
        } message: {
            Text("This profile's My List, watch progress, and ratings are removed too. This can't be undone.")
        }
    }

    /// The avatar preview and a summary of what this profile can watch.
    private var identity: some View {
        VStack(spacing: 22) {
            Text(isNew ? "New Profile" : "Edit Profile")
                .font(.system(size: 34, weight: .bold))
            ProfileAvatar(profile: draft.preview, size: 190)
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 190 * 0.24).strokeBorder(.white, style: StrokeStyle(lineWidth: 4, dash: [10, 6]))
                    }
                }
                .shadow(color: accent.opacity(0.65), radius: 36, y: 12)
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first, let data = ProfilePicture.avatarData(from: url) else { return false }
                    draft.imageData = data
                    return true
                } isTargeted: { isDropTargeted = $0 }
                .help("Drop a picture here to use it for this profile")
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: draft.symbol)
                .animation(.smooth, value: draft.paletteIndex)
            Text(draft.name.isEmpty ? "Name" : draft.name)
                .font(.title2.weight(.semibold))
                .foregroundStyle(draft.name.isEmpty ? .tertiary : .primary)
                .lineLimit(1)
                .frame(maxWidth: 220)
            Label(draft.ratingLimit == .everything ? "All ratings" : "Up to \(draft.ratingLimit.addedRatings(in: model.ratingsCountry).first ?? "")",
                  systemImage: draft.ratingLimit == .everything ? "checkmark.shield" : "lock.shield.fill")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)

            VStack(spacing: 8) {
                Button(draft.imageData == nil ? "Choose Picture…" : "Change Picture…", systemImage: "photo", action: choosePicture)
                if draft.imageData != nil {
                    Button("Use Icon Instead", systemImage: "person.crop.square") { draft.imageData = nil }
                }
            }
            .buttonStyle(.glass)

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(get: { draft.requiresPIN }, set: setRequiresPIN)) {
                    Label("Lock with PIN", systemImage: "lock.fill")
                }
                .toggleStyle(.switch)
                .tint(accent)
                if draft.requiresPIN {
                    Button("Change PIN…") { askForNewPIN() }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.06), in: .rect(cornerRadius: 12))
        }
        .frame(width: 240)
    }

    private func setRequiresPIN(_ isOn: Bool) {
        if isOn { askForNewPIN() } else { draft.pinChange = draft.hadPIN ? .remove : .unchanged }
    }

    private func askForNewPIN() {
        model.requestNewPIN(title: "Choose a PIN", message: "\(draft.name.isEmpty ? "This profile" : draft.name) will ask for it every time it's opened.",
                            profile: draft.preview) { pin in
            draft.pinChange = .set(pin)
        }
    }

    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Profile Picture"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = ProfilePicture.avatarData(from: url) else { return }
        draft.imageData = data
    }

    private var nameField: some View {
        section("Name") {
            TextField("", text: $draft.name, prompt: Text("Who's watching?").foregroundStyle(.white.opacity(0.35)))
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.white.opacity(0.08), in: .rect(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(isNameFocused ? accent : .white.opacity(0.12), lineWidth: isNameFocused ? 2 : 1)
                }
                .focused($isNameFocused)
                .onSubmit(save)
        }
    }

    private var colorPicker: some View {
        section("Color") {
            HStack(spacing: 12) {
                ForEach(Profile.palettes.indices, id: \.self) { index in
                    Button {
                        draft.paletteIndex = index
                    } label: {
                        Circle()
                            .fill(LinearGradient(colors: Profile.palettes[index], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 34, height: 34)
                            .overlay {
                                Circle().strokeBorder(.white, lineWidth: draft.paletteIndex == index ? 3 : 0)
                            }
                            .scaleEffect(draft.paletteIndex == index ? 1.12 : 1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Color \(index + 1)")
                    .accessibilityAddTraits(draft.paletteIndex == index ? .isSelected : [])
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: draft.paletteIndex)
        }
    }

    private var iconPicker: some View {
        section("Icon") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(stride(from: 0, to: Profile.symbols.count, by: 8)), id: \.self) { start in
                    HStack(spacing: 10) {
                        ForEach(Profile.symbols[start..<min(Profile.symbols.count, start + 8)], id: \.self) { symbol in
                    let isSelected = draft.symbol == symbol
                    Button {
                        draft.symbol = symbol
                    } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 52, height: 52)
                            .background {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(isSelected
                                          ? AnyShapeStyle(LinearGradient(colors: draft.preview.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                                          : AnyShapeStyle(.white.opacity(0.07)))
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(symbol.replacingOccurrences(of: ".", with: " "))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                    }
                }
            }
        }
    }

    private var ratingPicker: some View {
        section("Content Ratings") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ForEach(RatingLimit.allCases) { limit in
                        RatingLimitCard(limit: limit, country: model.ratingsCountry, isSelected: draft.ratingLimit == limit,
                                        isIncluded: limit <= draft.ratingLimit, accent: accent) {
                            withAnimation(.smooth) { draft.ratingLimit = limit }
                        }
                    }
                }
                Toggle(isOn: $draft.allowsUnrated) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show unrated titles")
                        Text("Titles with no known rating, such as home videos and some imports.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .tint(accent)
                .disabled(draft.ratingLimit == .everything)
                .opacity(draft.ratingLimit == .everything ? 0.5 : 1)
                if draft.ratingLimit < .everything, !hasAdministratorPIN {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
                        Text("Set an administrator PIN so this profile can't switch to a less restricted one.")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Set PIN…") {
                            model.requestNewPIN(title: "Administrator PIN", message: "Needed to manage profiles and to leave restricted profiles.") { pin in
                                AdministratorPIN.set(pin)
                                hasAdministratorPIN = true
                            }
                        }
                        .buttonStyle(.glass)
                    }
                    .padding(10)
                    .background(.orange.opacity(0.12), in: .rect(cornerRadius: 10))
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if !isNew {
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label("Remove Profile", systemImage: "trash")
                }
                .buttonStyle(.glass)
            }
            Spacer()
            Button("Cancel", action: close)
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
            Button(isNew ? "Create Profile" : "Save", action: save)
                .buttonStyle(.glassProminent)
                .tint(accent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
        }
        .controlSize(.large)
        .padding(.horizontal, 44)
        .padding(.bottom, 32)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func save() {
        guard isValid else { return }
        model.saveProfile(draft)
        close()
    }
}

/// One rung of the rating ladder, listing the ratings it adds.
private struct RatingLimitCard: View {
    let limit: RatingLimit
    let country: String
    let isSelected: Bool
    let isIncluded: Bool
    let accent: Color
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Text(limit.title)
                    .font(.callout.weight(.bold))
                Text(limit.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                FlowingRatings(ratings: Array(limit.addedRatings(in: country).prefix(4)))
                    .opacity(isIncluded ? 1 : 0.35)
            }
            .padding(12)
            .frame(width: 122, height: 132, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? AnyShapeStyle(accent.opacity(0.28)) : AnyShapeStyle(.white.opacity(isHovered ? 0.1 : 0.06)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isSelected ? accent : .white.opacity(0.1), lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(limit.title): \(limit.allowedRatings(in: country).joined(separator: ", "))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Rating badges wrapped onto as many lines as they need.
private struct FlowingRatings: View {
    let ratings: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(stride(from: 0, to: ratings.count, by: 2)), id: \.self) { start in
                HStack(spacing: 4) {
                    ForEach(ratings[start..<min(ratings.count, start + 2)], id: \.self) { rating in
                        Text(rating)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.6), lineWidth: 1))
                    }
                }
            }
        }
    }
}

// MARK: - Shared

struct ProfileAvatar: View {
    let profile: Profile
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24)
            .fill(LinearGradient(colors: profile.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay {
                if let image = profile.image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(.rect(cornerRadius: size * 0.24))
                } else {
                    Image(systemName: profile.symbol)
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .accessibilityHidden(true)
    }
}

/// Wordmark used on the profile picker and in the sidebar.
struct BrandMark: View {
    var size: CGFloat = 15

    var body: some View {
        HStack(spacing: size * 0.4) {
            Image(systemName: "play.rectangle.fill")
                .foregroundStyle(
                    LinearGradient(colors: [Theme.accent, Color(hex: 0xFF8A3D)], startPoint: .leading, endPoint: .trailing)
                )
            Text("\(Text("ULTIMATE").fontWeight(.black)) \(Text("THEATER").fontWeight(.light))")
                .tracking(size * 0.2)
                .lineLimit(1)
                .fixedSize()
        }
        .font(.system(size: size))
        .foregroundStyle(.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ultimate Theater")
    }
}


