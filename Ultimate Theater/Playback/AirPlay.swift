//
//  AirPlay.swift
//  Ultimate Theater
//
//  AirPlay for the Theater engine.
//
//  What's possible on macOS (see AVRoutePickerView.h and "Supporting AirPlay in your app"):
//  • AVRoutePickerView routes media from an AVPlayer. Routing an AVSampleBufferAudioRenderer
//    from the picker is documented for iOS and tvOS only, and AVSampleBufferDisplayLayer has
//    no AirPlay video path at all, so the engine's picture can't be sent to an Apple TV.
//  • The engine's sound can go to any Core Audio output, AirPlay included, through
//    AVSampleBufferAudioRenderer.audioOutputDeviceUniqueID (macOS only).
//  • For files AVFoundation plays natively and that are AirPlay Video compatible
//    (AVAsset isCompatibleWithAirPlayVideo), the file is handed to an AVPlayer with
//    allowsExternalPlayback; the route picker sends that player to the Apple TV.
//    (usesExternalPlaybackWhileExternalScreenIsActive is unavailable on macOS.)
//

import SwiftUI
import AVFoundation
import AVKit
import CoreAudio

// MARK: - Transport

/// The controls shared by the Theater engine and an Apple TV handoff, so the remote, the
/// media keys, and Now Playing drive whichever is showing the picture.
protocol PlaybackTransport: AnyObject {
    var currentTime: Double { get }
    var duration: Double { get }
    var isPlaying: Bool { get }
    func play()
    func pause()
    func togglePlayback()
    func seek(to seconds: Double)
    func skip(by seconds: Double)
}

extension TheaterEngine: PlaybackTransport {}

// MARK: - Apple TV handoff

/// Hands a natively playable file to an AVPlayer that can AirPlay video, and keeps its
/// position in step with the engine both ways.
@Observable
final class AirPlayHandoff: PlaybackTransport {
    enum Support: Equatable {
        case checking
        /// AirPlay video works for this file.
        case video
        /// Only sound can go to AirPlay; the reason is shown in the player.
        case audioOnly(String)
    }

    private(set) var support: Support = .checking
    /// The picture is on an AirPlay device and the engine is paused.
    private(set) var isAirPlayActive = false
    private var airPlayTime: Double = 0
    private var airPlayDuration: Double = 0
    private var airPlayIsPlaying = false
    /// Offered to the route picker; replaced after returning to the Mac so the next pick
    /// starts from a local route.
    private(set) var player: AVPlayer?
    /// A cast to a Google Cast, DLNA, or Roku device, attached by the player. While it's
    /// active the handoff routes the transport there, so everything that drives an Apple TV
    /// (the remote, media keys, the Dock menu, Now Playing) drives the cast device too.
    var castSession: CastSession?

    @ObservationIgnored private weak var engine: TheaterEngine?
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var monitor: Task<Void, Never>?

    private var activeCast: CastSession? {
        guard let castSession, castSession.isActive else { return nil }
        return castSession
    }

    /// The picture is on another device (an Apple TV or a cast device) and the engine is paused.
    var isExternal: Bool { activeCast != nil || isAirPlayActive }
    var currentTime: Double { activeCast?.currentTime ?? airPlayTime }
    var duration: Double { activeCast?.duration ?? airPlayDuration }
    var isPlaying: Bool { activeCast?.isPlaying ?? airPlayIsPlaying }

    /// Checks the file and, when it can AirPlay video, prepares a paused player for it.
    func prepare(url: URL, engine: TheaterEngine) {
        reset()
        self.url = url
        self.engine = engine
        engine.audioOutputDeviceID = AudioOutputList.shared.selected?.uid
        // Holds the handoff only while updating it, so the loop ends once the handoff is gone.
        monitor = Task { [weak self] in
            let verdict = await Self.support(for: url)
            do {
                guard let self, !Task.isCancelled else { return }
                self.support = verdict
                guard verdict == .video else { return }
                self.makePlayer()
            }
            while !Task.isCancelled {
                do {
                    guard let self else { return }
                    self.checkRoute()
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    /// Tears down the player (the title closed or another one is loading).
    func reset() {
        monitor?.cancel()
        monitor = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        isAirPlayActive = false
        airPlayIsPlaying = false
        support = .checking
    }

    /// Brings the picture back to the Mac at the Apple TV's position.
    func returnToMac() {
        guard isAirPlayActive, let player else { return }
        let wasPlaying = airPlayIsPlaying
        player.pause()
        let time = player.currentTime().seconds
        if time.isFinite { airPlayTime = time }
        endExternal(resume: wasPlaying)
        player.replaceCurrentItem(with: nil)
        makePlayer() // A fresh player starts on the local route.
    }

    private func makePlayer() {
        guard let url else { return }
        let player = AVPlayer(url: url)
        player.allowsExternalPlayback = true
        player.actionAtItemEnd = .pause
        player.preventsDisplaySleepDuringVideoPlayback = false
        self.player = player
    }

    /// Notices when the route picker sends the player to (or away from) an AirPlay device.
    private func checkRoute() {
        guard let player else { return }
        let external = player.isExternalPlaybackActive
        if external, !isAirPlayActive { beginExternal(player) }
        else if !external, isAirPlayActive {
            player.pause()
            endExternal(resume: airPlayIsPlaying)
        }
        if isAirPlayActive {
            let time = player.currentTime().seconds
            if time.isFinite { airPlayTime = time }
            airPlayIsPlaying = player.timeControlStatus != .paused
            if let length = player.currentItem?.duration.seconds, length.isFinite, length > 0 { airPlayDuration = length }
        }
    }

    private func beginExternal(_ player: AVPlayer) {
        let start = engine?.currentTime ?? 0
        engine?.pause()
        airPlayDuration = engine?.duration ?? airPlayDuration
        airPlayTime = start
        isAirPlayActive = true
        airPlayIsPlaying = true
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    private func endExternal(resume: Bool) {
        isAirPlayActive = false
        airPlayIsPlaying = false
        guard let engine else { return }
        engine.seek(to: airPlayTime)
        if resume { engine.play() }
    }

    // MARK: Transport

    func play() {
        if let activeCast { return activeCast.play() }
        guard isAirPlayActive else { return }
        player?.play()
        airPlayIsPlaying = true
    }

    func pause() {
        if let activeCast { return activeCast.pause() }
        guard isAirPlayActive else { return }
        player?.pause()
        airPlayIsPlaying = false
    }

    func togglePlayback() { isPlaying ? pause() : play() }

    func seek(to seconds: Double) {
        if let activeCast { return activeCast.seek(to: seconds) }
        guard isAirPlayActive, let player else { return }
        let target = TheaterEngine.seekTarget(seconds, duration: airPlayDuration)
        airPlayTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(by seconds: Double) { seek(to: currentTime + seconds) }

    var volume: Float {
        get { activeCast?.volume ?? player?.volume ?? 1 }
        set {
            if let activeCast { activeCast.volume = newValue } else { player?.volume = newValue }
        }
    }

    // MARK: Compatibility

    nonisolated private static let videoCodecs = Set(["avc1", "avc3", "hvc1", "hev1", "dvh1", "dvhe"].map(fourCC))
    nonisolated private static let audioCodecs = Set(["aac ", "ac-3", "ec-3"].map(fourCC))

    nonisolated static func fourCC(_ text: String) -> FourCharCode {
        text.utf8.prefix(4).reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    /// AirPlay video needs an MP4/M4V/MOV that AVFoundation can play, with H.264 or HEVC video
    /// and AAC, Dolby Digital, or Dolby Digital Plus sound.
    nonisolated static func support(for url: URL) async -> Support {
        let container = url.pathExtension.lowercased()
        let audioNote = "Sound can still play on AirPlay speakers or an Apple TV (choose it under Sound Output)."
        guard ["mp4", "m4v", "mov"].contains(container) else {
            let kind = container.isEmpty ? "This file" : "This \(container.uppercased()) file"
            return .audioOnly("AirPlay video needs an MP4, M4V, or MOV file. \(kind) plays in the Theater engine, which can't send its picture over AirPlay. \(audioNote)")
        }
        let asset = AVURLAsset(url: url)
        guard let (playable, compatible) = try? await asset.load(.isPlayable, .isCompatibleWithAirPlayVideo), playable, compatible,
              let videoTracks = try? await asset.loadTracks(withMediaType: .video), let video = videoTracks.first,
              let videoFormats = try? await video.load(.formatDescriptions),
              videoFormats.allSatisfy({ videoCodecs.contains($0.mediaSubType.rawValue) }) else {
            return .audioOnly("AirPlay video needs H.264 or HEVC video that macOS can play directly. \(audioNote)")
        }
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        for track in audioTracks {
            let formats = (try? await track.load(.formatDescriptions)) ?? []
            if !formats.allSatisfy({ audioCodecs.contains($0.mediaSubType.rawValue) }) {
                return .audioOnly("AirPlay video needs AAC, Dolby Digital, or Dolby Digital Plus sound. \(audioNote)")
            }
        }
        return .video
    }
}

// MARK: - Sound output (Core Audio)

/// A place the engine's sound can play: a Core Audio output device, or one receiver of the
/// system's AirPlay device.
nonisolated struct AudioOutput: Identifiable, Hashable, Sendable {
    let uid: String
    let name: String
    /// For AirPlay receivers: the AirPlay device's data source to select.
    var dataSource: UInt32?
    var isAirPlay = false

    var id: String { dataSource.map { "\(uid)#\($0)" } ?? uid }
}

nonisolated enum CoreAudioOutputs {
    static func all() -> [AudioOutput] {
        var outputs: [AudioOutput] = []
        for device in deviceIDs() where hasOutput(device) {
            guard let uid = string(device, kAudioDevicePropertyDeviceUID),
                  let name = string(device, kAudioObjectPropertyName) else { continue }
            let transport: UInt32 = value(device, kAudioDevicePropertyTransportType) ?? 0
            if transport == kAudioDeviceTransportTypeAirPlay {
                let sources = dataSources(device)
                if sources.isEmpty {
                    outputs.append(AudioOutput(uid: uid, name: name, isAirPlay: true))
                } else {
                    outputs += sources.map { AudioOutput(uid: uid, name: $0.name, dataSource: $0.id, isAirPlay: true) }
                }
            } else {
                outputs.append(AudioOutput(uid: uid, name: name))
            }
        }
        return outputs
    }

    /// Points the AirPlay device at the chosen receiver.
    static func activate(_ output: AudioOutput) {
        guard var source = output.dataSource, let device = deviceIDs().first(where: { string($0, kAudioDevicePropertyDeviceUID) == output.uid }) else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource, mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &source)
    }

    private static func deviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasOutput(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.load(as: T.self)
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var text: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &text) == noErr, let text else { return nil }
        return text.takeRetainedValue() as String
    }

    private static func dataSources(_ device: AudioObjectID) -> [(id: UInt32, name: String)] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSources, mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [UInt32](repeating: 0, count: Int(size) / MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var source = id
            var name: Unmanaged<CFString>?
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSourceNameForIDCFString,
                                                         mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            let status = withUnsafeMutablePointer(to: &source) { sourcePointer in
                withUnsafeMutablePointer(to: &name) { namePointer in
                    var translation = AudioValueTranslation(mInputData: sourcePointer, mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                                                            mOutputData: namePointer, mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size))
                    var translationSize = UInt32(MemoryLayout<AudioValueTranslation>.size)
                    return AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &translationSize, &translation)
                }
            }
            guard status == noErr, let name else { return nil }
            return (id, name.takeRetainedValue() as String)
        }
    }
}

/// The sound outputs offered in the player, and the one chosen (kept for the session).
@Observable
final class AudioOutputList {
    static let shared = AudioOutputList()

    private(set) var outputs: [AudioOutput] = []
    /// Nil follows the Mac's sound output setting.
    private(set) var selected: AudioOutput?

    func refresh() async {
        let found = await Task.detached(priority: .utility) { CoreAudioOutputs.all() }.value
        if found != outputs { outputs = found }
        if let selected, !found.contains(selected) { self.selected = nil }
    }

    func select(_ output: AudioOutput?, for engine: TheaterEngine?) {
        selected = output
        if let output, output.dataSource != nil {
            // Pointing the AirPlay device at a receiver can take a moment; keep it off the main thread.
            Task.detached(priority: .userInitiated) { CoreAudioOutputs.activate(output) }
        }
        engine?.audioOutputDeviceID = output?.uid
    }
}

// MARK: - Player controls

/// The system AirPlay route button, bound to the handoff player.
struct AirPlayRouteButton: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        let accent = NSColor(Theme.accent)
        view.setRoutePickerButtonColor(.white, for: .normal)
        view.setRoutePickerButtonColor(NSColor.white.withAlphaComponent(0.7), for: .normalHighlighted)
        view.setRoutePickerButtonColor(accent, for: .active)
        view.setRoutePickerButtonColor(accent.withAlphaComponent(0.7), for: .activeHighlighted)
        view.player = player
        view.setAccessibilityLabel("AirPlay")
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// AirPlay in the transport bar: the route button for Apple TV video (when the file allows
/// it) and a Sound Output menu that sends the engine's audio to any output, AirPlay included.
struct AirPlayControls: View {
    @Environment(AirPlayHandoff.self) private var handoff: AirPlayHandoff?
    @Environment(AppModel.self) private var model
    private let outputs = AudioOutputList.shared

    var body: some View {
        HStack(spacing: 14) {
            if let player = handoff?.player {
                AirPlayRouteButton(player: player)
                    .frame(width: 24, height: 22)
                    .help("Play on Apple TV (AirPlay)")
            }
            Menu {
                Section("Sound Output") {
                    outputButton(nil, title: "Mac Sound Setting")
                    ForEach(outputs.outputs) { output in
                        outputButton(output, title: output.isAirPlay ? "AirPlay: \(output.name)" : output.name)
                    }
                }
                if case .audioOnly(let reason) = handoff?.support {
                    Section("Apple TV") {
                        Text(reason)
                    }
                } else if handoff?.support == .video {
                    Section("Apple TV") {
                        Text("Use the AirPlay button to watch this on an Apple TV.")
                    }
                }
            } label: {
                Image(systemName: outputs.selected?.isAirPlay == true ? "airplay.audio" : "hifispeaker")
            }
            .menuIndicator(.hidden)
            .help("Sound output")
        }
        .task {
            while !Task.isCancelled {
                await outputs.refresh()
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    private func outputButton(_ output: AudioOutput?, title: String) -> some View {
        Button {
            outputs.select(output, for: model.playerEngine)
        } label: {
            if outputs.selected?.id == output?.id {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

/// Shown in the player while the picture is on an Apple TV.
struct AirPlayExternalScreen: View {
    let handoff: AirPlayHandoff
    let item: PlaybackItem
    @State private var scrubPosition: Double?

    private var shownTime: Double { scrubPosition ?? handoff.currentTime }

    var body: some View {
        ZStack {
            ArtworkView(title: item.title, style: .backdrop)
                .blur(radius: 30)
                .overlay(Color.black.opacity(0.65))
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "appletv.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Theme.accent)
                Text("Playing on Apple TV")
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

                HStack(spacing: 12) {
                    Text(TheaterControlsTime.format(shownTime)).monospacedDigit()
                    Slider(value: Binding(get: { shownTime }, set: { scrubPosition = $0 }),
                           in: 0...max(handoff.duration, 1)) { editing in
                        if !editing, let target = scrubPosition {
                            handoff.seek(to: target)
                            scrubPosition = nil
                        }
                    }
                    .tint(Theme.accent)
                    .accessibilityLabel("Playback position")
                    Text("-" + TheaterControlsTime.format(max(handoff.duration - shownTime, 0)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .frame(maxWidth: 560)

                HStack(spacing: 22) {
                    Button { handoff.skip(by: -10) } label: {
                        Image(systemName: "gobackward.10").font(.title3).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.theaterGlassCircle)
                    .accessibilityLabel("Back 10 seconds")
                    Button { handoff.togglePlayback() } label: {
                        Image(systemName: handoff.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 56, height: 56)
                            .background(.white, in: .circle)
                            .contentTransition(.symbolEffect(.replace))
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.space, modifiers: [])
                    .accessibilityLabel(handoff.isPlaying ? "Pause" : "Play")
                    Button { handoff.skip(by: 10) } label: {
                        Image(systemName: "goforward.10").font(.title3).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.theaterGlassCircle)
                    .accessibilityLabel("Forward 10 seconds")
                }

                HStack(spacing: 14) {
                    Button { handoff.returnToMac() } label: {
                        Label("Watch on This Mac", systemImage: "macbook")
                            .font(.headline)
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.theaterGlass)
                    if let player = handoff.player {
                        AirPlayRouteButton(player: player)
                            .frame(width: 28, height: 26)
                            .help("Choose another AirPlay device")
                    }
                }
                .padding(.top, 6)
            }
            .foregroundStyle(.white)
            .padding(40)
            .frame(maxWidth: 720)
        }
        .transition(.opacity)
    }
}
