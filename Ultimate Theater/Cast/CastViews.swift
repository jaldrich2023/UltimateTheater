//
//  CastViews.swift
//  Ultimate Theater
//
//  The player's Cast button (every device on the network, AirPlay included, with whether
//  each can play this file) and the screen shown while a cast device has the picture.
//

import SwiftUI

/// The Cast button in the transport bar and its device list.
struct CastButton: View {
    /// The file's container and codecs; nil while they're being read.
    let profile: CastMediaProfile?
    /// The device being cast to, if any.
    let activeDeviceID: String?
    let onCast: (CastDevice) -> Void

    @State private var isShowingDevices = false

    var body: some View {
        Button { isShowingDevices.toggle() } label: {
            Image(systemName: "tv.badge.wifi")
                .foregroundStyle(activeDeviceID == nil ? Color.white : Theme.accent)
        }
        .help("Cast to a TV or streaming device")
        .accessibilityLabel("Cast")
        .popover(isPresented: $isShowingDevices, arrowEdge: .bottom) {
            CastDeviceList(profile: profile, activeDeviceID: activeDeviceID) { device in
                isShowingDevices = false
                onCast(device)
            }
        }
        .onChange(of: isShowingDevices) { _, showing in
            if showing { CastDiscovery.shared.refresh() }
        }
    }
}

private struct CastDeviceList: View {
    let profile: CastMediaProfile?
    let activeDeviceID: String?
    let onCast: (CastDevice) -> Void

    @Environment(AirPlayHandoff.self) private var handoff: AirPlayHandoff?
    @AppStorage(CastSettings.discoveryKey) private var isDiscoveryEnabled = true
    private let discovery = CastDiscovery.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Cast")
                    .font(.headline)
                Spacer()
                if discovery.isSearching {
                    ProgressView().controlSize(.small)
                }
                Button("Refresh", systemImage: "arrow.clockwise") { discovery.refresh() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(!isDiscoveryEnabled)
                    .help("Search the network again")
            }

            airPlaySection

            if !isDiscoveryEnabled {
                Text("Finding casting devices is turned off. Turn on “Find casting devices on this network” in Settings › Playback.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if discovery.devices.isEmpty {
                Text(discovery.isSearching ? "Looking for TVs and streaming devices…" : "No casting devices found on this network.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(CastDeviceKind.allCases, id: \.self) { kind in
                            let devices = discovery.devices.filter { $0.kind == kind }
                            if !devices.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(kind.groupName)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .textCase(.uppercase)
                                    ForEach(devices) { device in
                                        CastDeviceRow(device: device, support: support(for: device),
                                                      isActive: device.id == activeDeviceID) { onCast(device) }
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
            }

            Divider()
            Text("Casting sends the original file to the device, which must be able to play its format; nothing is converted. Fire TV, Samsung, LG, and other smart TVs appear under DLNA when they offer it (on Fire TV, through a DLNA player app). Your Mac must stay awake and on the same network while casting.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 360)
    }

    private func support(for device: CastDevice) -> CastSupport? {
        profile.map { CastCompatibility.check($0, for: device) }
    }

    @ViewBuilder
    private var airPlaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Apple TV")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            if let player = handoff?.player {
                HStack(spacing: 10) {
                    AirPlayRouteButton(player: player)
                        .frame(width: 26, height: 24)
                    Text("Choose an AirPlay device")
                        .font(.callout)
                }
                .help("Play on Apple TV (AirPlay)")
            } else if case .audioOnly(let reason) = handoff?.support {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Checking whether this file can play over AirPlay…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct CastDeviceRow: View {
    let device: CastDevice
    /// Nil while the file's format is being read.
    let support: CastSupport?
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: device.kind.symbol)
                    .font(.title3)
                    .frame(width: 26)
                    .foregroundStyle(isActive ? Theme.accent : .primary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(device.name)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        if isActive {
                            Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                        }
                    }
                    if let detail = device.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let note = support?.note {
                        Label(note, systemImage: support?.isPlayable == true ? "info.circle" : "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(support?.isPlayable == true ? Color.secondary : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if support == nil {
                        Text("Checking this file's format…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(isActive ? Theme.accent.opacity(0.12) : Color.clear, in: .rect(cornerRadius: 8))
        .disabled(support?.isPlayable != true || isActive)
        .accessibilityHint(support?.note ?? "")
    }
}

/// Shown in the player while a cast device has the picture (or just after it stopped).
struct CastExternalScreen: View {
    let session: CastSession
    let item: PlaybackItem
    let onWatchOnMac: () -> Void
    let onStop: () -> Void
    @State private var scrubPosition: Double?

    private var shownTime: Double { scrubPosition ?? session.currentTime }
    private var safeDuration: Double { max(session.duration.isFinite ? session.duration : 0, 1) }

    private var statusLine: String {
        switch session.phase {
        case .connecting: "Connecting to \(session.device.name)…"
        case .loading: "Starting on \(session.device.name)…"
        case .playing: session.isBuffering ? "Loading on \(session.device.name)…" : "Playing on \(session.device.name)"
        case .finished: "Finished on \(session.device.name)"
        case .ended: "Stopped on \(session.device.name)"
        case .failed: "Couldn't play on \(session.device.name)"
        }
    }

    private var message: String? {
        switch session.phase {
        case .ended(let reason): reason
        case .failed(let reason): reason
        default: nil
        }
    }

    private var isControllable: Bool { session.phase == .playing }

    var body: some View {
        ZStack {
            ArtworkView(title: item.title, style: .backdrop)
                .blur(radius: 30)
                .overlay(Color.black.opacity(0.65))
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: session.device.kind.symbol)
                    .font(.system(size: 56))
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.pulse, isActive: session.phase == .connecting || session.phase == .loading || session.isBuffering)
                Text(statusLine)
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.7))
                VStack(spacing: 4) {
                    Text(item.headline)
                        .font(.largeTitle.weight(.bold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    if let subheadline = item.subheadline {
                        Text(subheadline)
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }

                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }

                if isControllable {
                    timeline
                    transport
                    if !session.capabilities.canSeek {
                        Text("\(session.device.name) can't be told where to start or seek from here; use its remote to scan. Watch on This Mac picks up where it is.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 480)
                    }
                }

                HStack(spacing: 14) {
                    Button(action: onWatchOnMac) {
                        Label("Watch on This Mac", systemImage: "macbook")
                            .font(.headline)
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.theaterGlass)
                    Button(action: onStop) {
                        Label(session.isActive ? "Stop Casting" : "Close", systemImage: "xmark")
                            .font(.headline)
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.theaterGlass)
                }
                .padding(.top, 6)
            }
            .foregroundStyle(.white)
            .padding(40)
            .frame(maxWidth: 720)

            // ↑ ↓ change the device's volume.
            if isControllable, session.capabilities.volume != .none {
                ZStack {
                    Button("") { session.stepVolume(up: true) }.keyboardShortcut(.upArrow, modifiers: [])
                    Button("") { session.stepVolume(up: false) }.keyboardShortcut(.downArrow, modifiers: [])
                }
                .hidden()
            }
        }
        .transition(.opacity)
    }

    private var timeline: some View {
        HStack(spacing: 12) {
            Text(TheaterControlsTime.format(shownTime)).monospacedDigit()
            Slider(value: Binding(get: { min(shownTime, safeDuration) }, set: { scrubPosition = $0 }),
                   in: 0...safeDuration) { editing in
                if !editing, let target = scrubPosition {
                    session.seek(to: target)
                    scrubPosition = nil
                }
            }
            .tint(Theme.accent)
            .disabled(!session.capabilities.canSeek)
            .accessibilityLabel("Playback position")
            .accessibilityValue(TheaterControlsTime.spoken(shownTime))
            Text("-" + TheaterControlsTime.format(max(session.duration - shownTime, 0)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .frame(maxWidth: 560)
    }

    private var transport: some View {
        HStack(spacing: 22) {
            if session.capabilities.canSeek {
                Button { session.skip(by: -10) } label: {
                    Image(systemName: "gobackward.10").font(.title3).frame(width: 30, height: 30)
                }
                .buttonStyle(.theaterGlassCircle)
                .accessibilityLabel("Back 10 seconds")
            }
            Button { session.togglePlayback() } label: {
                Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 56, height: 56)
                    .background(.white, in: .circle)
                    .contentTransition(.symbolEffect(.replace))
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(session.isPlaying ? "Pause" : "Play")
            if session.capabilities.canSeek {
                Button { session.skip(by: 10) } label: {
                    Image(systemName: "goforward.10").font(.title3).frame(width: 30, height: 30)
                }
                .buttonStyle(.theaterGlassCircle)
                .accessibilityLabel("Forward 10 seconds")
            }
            volumeControl
        }
    }

    @ViewBuilder
    private var volumeControl: some View {
        switch session.capabilities.volume {
        case .absolute:
            HStack(spacing: 8) {
                Image(systemName: session.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 22)
                Slider(value: Binding(get: { Double(session.volume) }, set: { session.setVolume(Float($0)) }), in: 0...1)
                    .frame(width: 110)
                    .tint(.white)
                    .accessibilityLabel("Volume on \(session.device.name)")
            }
            .padding(.leading, 12)
        case .steps:
            HStack(spacing: 10) {
                Button { session.stepVolume(up: false) } label: {
                    Image(systemName: "speaker.minus.fill").frame(width: 26, height: 26)
                }
                .buttonStyle(.theaterGlassCircle)
                .accessibilityLabel("Volume down")
                Button { session.stepVolume(up: true) } label: {
                    Image(systemName: "speaker.plus.fill").frame(width: 26, height: 26)
                }
                .buttonStyle(.theaterGlassCircle)
                .accessibilityLabel("Volume up")
            }
            .padding(.leading, 12)
        case .none:
            EmptyView()
        }
    }
}
