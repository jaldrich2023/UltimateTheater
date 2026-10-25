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

    private init() {}

    var isShowing: Bool { panel != nil }

    /// Shows the floating player for `engine`, whose main window has just been minimised.
    func show(engine: TheaterEngine, mainWindow: NSWindow) {
        guard panel == nil else { return }
        self.engine = engine
        self.mainWindow = mainWindow

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

        let root = DesktopPiPView(engine: engine, layer: layer,
                                  onExpand: { [weak self] in self?.returnToApp() },
                                  onClose: { [weak self] in self?.closeAndPause() })
        let host = NSHostingView(rootView: root)
        host.wantsLayer = true
        host.layer?.cornerRadius = 14
        host.layer?.masksToBounds = true
        panel.contentView = host
        self.panel = panel
        panel.orderFrontRegardless()
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
    let layer: AVSampleBufferDisplayLayer
    let onExpand: () -> Void
    let onClose: () -> Void

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
                Button { engine.togglePlayback() } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3).frame(width: 30, height: 30)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.theaterGlassCircle)
                .accessibilityLabel(engine.isPlaying ? "Pause" : "Play")
                Spacer()
            }
            .padding(10)
            .opacity(isHovered ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: isHovered)
        }
        .onHover { isHovered = $0 }
        .preferredColorScheme(.dark)
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
