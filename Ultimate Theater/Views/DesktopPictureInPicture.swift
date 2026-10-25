//
//  DesktopPictureInPicture.swift
//  Ultimate Theater
//
//  While the main window is minimised during playback, the picture keeps playing in a small
//  floating window on the desktop. Its expand button (or a double-click) brings the app back:
//  the main window is restored and focused, and the floating window goes away.
//
//  A video layer can only be on screen in one place, so the floating window borrows the
//  engine's display layer and hands it back to the player when it closes.
//

import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class DesktopPictureInPicture {
    static let shared = DesktopPictureInPicture()

    private var panel: NSPanel?
    private weak var mainWindow: NSWindow?
    private weak var engine: TheaterEngine?
    /// Where the display layer lived in the player, so it can be put back.
    private weak var originalSuperlayer: CALayer?
    private weak var originalHost: NSView?
    private weak var model: AppModel?

    private init() {}

    var isShowing: Bool { panel != nil }

    /// Whether `layer` is on loan to the floating window (so the player mustn't take it back).
    func isBorrowing(_ layer: CALayer) -> Bool {
        panel != nil && engine?.displayLayer === layer
    }

    /// Shows the floating player for `engine`, whose main window has just been minimised.
    func show(engine: TheaterEngine, mainWindow: NSWindow, model: AppModel) {
        guard panel == nil else { return }
        self.engine = engine
        self.mainWindow = mainWindow
        self.model = model

        let layer = engine.displayLayer
        originalSuperlayer = layer.superlayer
        originalHost = layer.superlayer?.delegate as? NSView

        let size = Self.initialSize(for: engine.videoSize)
        let screen = mainWindow.screen ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let frame = NSRect(x: area.maxX - size.width - 24, y: area.minY + 24, width: size.width, height: size.height)

        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .resizable, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.title = "Ultimate Theater Picture in Picture"
        if let video = engine.videoSize, video.width > 0, video.height > 0 { panel.contentAspectRatio = video }
        panel.minSize = NSSize(width: 240, height: 135)
        panel.maxSize = NSSize(width: 1280, height: 720)

        self.panel = panel
        install(engine, model: model, in: panel)
        panel.orderFrontRegardless()
    }

    /// The player moved on to another episode (from this window's controls, or on its own):
    /// show the new engine's picture here, and give it back to the player when this closes.
    func follow(_ newEngine: TheaterEngine) {
        guard let panel, let model, newEngine !== engine else { return }
        engine = newEngine
        // The player hosts each engine's layer in the same view, so that's where it goes back.
        if let host = originalHost { originalSuperlayer = host.layer }
        if let video = newEngine.videoSize, video.width > 0, video.height > 0 { panel.contentAspectRatio = video }
        install(newEngine, model: model, in: panel)
    }

    private func install(_ engine: TheaterEngine, model: AppModel, in panel: NSPanel) {
        let root = DesktopPiPView(engine: engine, model: model, layer: engine.displayLayer,
                                  onExpand: { [weak self] in self?.returnToApp() },
                                  onClose: { [weak self] in self?.closeAndPause() },
                                  onStop: { [weak self, weak model] in
                                      self?.hide()
                                      model?.closePlayerSavingProgress()
                                  })
        let host = NSHostingView(rootView: root)
        host.wantsLayer = true
        host.layer?.cornerRadius = 14
        host.layer?.masksToBounds = true
        panel.contentView = host
    }

    /// Closes the floating player (the main window came back by itself, or playback ended).
    func hide() {
        guard let panel else { return }
        self.panel = nil
        panel.orderOut(nil)
        panel.contentView = nil
        // Give the picture back to the player.
        if let engine, let originalSuperlayer {
            let layer = engine.displayLayer
            if layer.superlayer !== originalSuperlayer {
                layer.removeFromSuperlayer()
                originalSuperlayer.addSublayer(layer)
            }
            if let originalHost {
                layer.frame = originalHost.bounds
                originalHost.needsLayout = true
            }
        }
        originalSuperlayer = nil
        originalHost = nil
    }

    /// The expand button: restore the main window and bring the app to the front.
    func returnToApp() {
        let window = mainWindow
        hide()
        NSApp.activate()
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// The close button: pause and close the floating player; the main window stays in the Dock.
    private func closeAndPause() {
        engine?.pause()
        hide()
    }

    /// About 400 points wide, shaped like the video.
    private static func initialSize(for video: CGSize?) -> NSSize {
        let width: CGFloat = 400
        guard let video, video.width > 0, video.height > 0 else { return NSSize(width: width, height: width * 9 / 16) }
        return NSSize(width: width, height: (width * video.height / video.width).rounded())
    }
}

/// The floating player's content: the picture, plus play/pause, return-to-app, and close
/// controls that appear on hover.
private struct DesktopPiPView: View {
    let engine: TheaterEngine
    let model: AppModel
    let layer: AVSampleBufferDisplayLayer
    let onExpand: () -> Void
    let onClose: () -> Void
    let onStop: () -> Void

    @State private var isHovered = false

    var body: some View {
        ZStack {
            Color.black
            BorrowedLayerView(layer: layer)
            // Double-click the picture to go back to the app.
            Color.clear
                .contentShape(.rect)
                .onTapGesture(count: 2, perform: onExpand)

            VStack {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.caption.weight(.bold)).frame(width: 18, height: 18)
                    }
                    .buttonStyle(.theaterGlassCircle)
                    .help("Close and pause")
                    .accessibilityLabel("Close picture in picture and pause")
                    Spacer()
                    Button(action: onExpand) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption.weight(.bold)).frame(width: 18, height: 18)
                    }
                    .buttonStyle(.theaterGlassCircle)
                    .help("Return to Ultimate Theater")
                    .accessibilityLabel("Return to Ultimate Theater")
                }
                Spacer()
                HStack(spacing: 14) {
                    let state = isHovered ? model.activePlayerHooks?.state() : nil
                    if state?.item.episode != nil {
                        Button { model.activePlayerHooks?.perform(.previousEpisode) } label: {
                            Image(systemName: "backward.end.fill").font(.callout).frame(width: 22, height: 22)
                        }
                        .buttonStyle(.theaterGlassCircle)
                        .disabled(state?.hasPreviousEpisode != true)
                        .help("Previous Episode")
                        .accessibilityLabel("Previous episode")
                    }
                    Button { engine.togglePlayback() } label: {
                        Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3).frame(width: 30, height: 30)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.theaterGlassCircle)
                    .accessibilityLabel(engine.isPlaying ? "Pause" : "Play")
                    if state?.item.episode != nil {
                        Button { model.activePlayerHooks?.perform(.nextEpisode) } label: {
                            Image(systemName: "forward.end.fill").font(.callout).frame(width: 22, height: 22)
                        }
                        .buttonStyle(.theaterGlassCircle)
                        .disabled(state?.hasNextEpisode != true)
                        .help("Next Episode")
                        .accessibilityLabel("Next episode")
                    }
                }
                Spacer()
            }
            .padding(10)
            .opacity(isHovered ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: isHovered)
        }
        .onHover { isHovered = $0 }
        // Right-click: the player's controls, the same ones the Playback menu offers.
        .contextMenu { controlsMenu }
        .preferredColorScheme(.dark)
    }

    /// Built when the menu opens, so it reflects what the player can do right then.
    @ViewBuilder
    private var controlsMenu: some View {
        let hooks = model.activePlayerHooks
        let state = hooks?.state()

        Button(engine.isPlaying ? "Pause" : "Play", systemImage: engine.isPlaying ? "pause.fill" : "play.fill") {
            engine.togglePlayback()
        }
        Button("Back 10 Seconds", systemImage: "gobackward.10") { engine.skip(by: -10) }
        Button("Forward 10 Seconds", systemImage: "goforward.10") { engine.skip(by: 10) }

        if state?.canSkipIntro == true || state?.canSkipCredits == true {
            Divider()
            if state?.canSkipIntro == true {
                Button("Skip Intro", systemImage: "forward.end.fill") { hooks?.perform(.skipIntro) }
            }
            if state?.canSkipCredits == true {
                Button("Skip Credits", systemImage: "forward.end.fill") { hooks?.perform(.skipCredits) }
            }
        }

        if state?.item.episode != nil {
            Divider()
            Button("Previous Episode", systemImage: "backward.end.fill") { hooks?.perform(.previousEpisode) }
                .disabled(state?.hasPreviousEpisode != true)
            Button("Next Episode", systemImage: "forward.end.fill") { hooks?.perform(.nextEpisode) }
                .disabled(state?.hasNextEpisode != true)
        }

        Divider()
        Button(engine.isMuted ? "Unmute" : "Mute", systemImage: engine.isMuted ? "speaker.wave.2.fill" : "speaker.slash.fill") {
            engine.isMuted.toggle()
        }
        Menu("Volume") {
            ForEach([25, 50, 75, 100], id: \.self) { percent in
                Button {
                    engine.volume = Float(percent) / 100
                    engine.isMuted = false
                } label: {
                    if !engine.isMuted, Int((engine.volume * 100).rounded()) == percent {
                        Label("\(percent)%", systemImage: "checkmark")
                    } else {
                        Text("\(percent)%")
                    }
                }
            }
        }

        Divider()
        Button("Return to Ultimate Theater", systemImage: "arrow.up.left.and.arrow.down.right", action: onExpand)
        Button("Close Picture in Picture", systemImage: "pip.exit", action: onClose)
        Button("Stop Playback", systemImage: "stop.fill", role: .destructive, action: onStop)
    }
}

/// Hosts the engine's display layer while it's on loan to the floating window.
private struct BorrowedLayerView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.adopt(layer)
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {}

    final class HostView: NSView {
        private weak var hosted: CALayer?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
        }

        required init?(coder: NSCoder) { nil }

        func adopt(_ sublayer: CALayer) {
            sublayer.removeFromSuperlayer()
            layer?.addSublayer(sublayer)
            hosted = sublayer
            needsLayout = true
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Only while it's still ours; the player may have taken it back.
            if let hosted, hosted.superlayer === layer { hosted.frame = bounds }
            CATransaction.commit()
        }
    }
}
