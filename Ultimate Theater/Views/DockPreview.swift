//
//  DockPreview.swift
//  Ultimate Theater
//
//  While the player's window is minimised, its Dock tile shows the live picture with a
//  play/pause badge, and the app's Dock menu carries minimal playback controls.
//

import AppKit
import AVFoundation
import VideoToolbox

@MainActor
final class DockPreview {
    static let shared = DockPreview()
    private var updates: Task<Void, Never>?

    /// Starts drawing the current frame into the minimised window's Dock tile.
    func start(in window: NSWindow, engine: TheaterEngine) {
        updates?.cancel()
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        window.dockTile.contentView = imageView
        updates = Task { [weak window, weak engine] in
            while !Task.isCancelled, let window, let engine {
                if let pixels = engine.displayLayer.sampleBufferRenderer.displayedPixelBuffer() {
                    var frame: CGImage?
                    VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &frame)
                    if let frame { imageView.image = Self.tile(frame, isPlaying: engine.isPlaying) }
                    window.dockTile.display()
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stop(in window: NSWindow) {
        updates?.cancel()
        updates = nil
        window.dockTile.contentView = nil
        window.dockTile.display()
    }

    /// The frame, fitted to the tile, with a play/pause badge in the corner.
    private static func tile(_ frame: CGImage, isPlaying: Bool) -> NSImage {
        let side: CGFloat = 256
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { bounds in
            let aspect = CGFloat(frame.width) / CGFloat(max(frame.height, 1))
            let height = bounds.width / aspect
            let picture = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
            NSBezierPath(roundedRect: picture, xRadius: 12, yRadius: 12).addClip()
            NSGraphicsContext.current?.cgContext.draw(frame, in: picture)
            let badge = NSRect(x: bounds.maxX - 76, y: picture.minY + 12, width: 64, height: 64)
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(ovalIn: badge).fill()
            let symbol = NSImage(systemSymbolName: isPlaying ? "pause.fill" : "play.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 30, weight: .bold).applying(.init(paletteColors: [.white])))
            symbol?.draw(in: badge.insetBy(dx: 17, dy: 17))
            return true
        }
    }
}

/// Supplies the Dock menu (playback controls while something is playing) and keeps the app
/// running with its main window closed; clicking the Dock icon brings the window back.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak static var model: AppModel?
    /// Opens (or brings forward) the main window; registered by the main window's content.
    static var openMainWindow: (() -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows, let open = Self.openMainWindow else { return true }
        open()
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        // Whatever shows the picture: the engine, or the Apple TV during AirPlay.
        guard let model = Self.model, let item = model.nowPlaying, let transport = model.activeTransport else { return nil }
        let menu = NSMenu()
        let title = NSMenuItem(title: item.headline, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        menu.addItem(withTitle: transport.isPlaying ? "Pause" : "Play", action: #selector(togglePlayback), keyEquivalent: "")
        menu.addItem(withTitle: "Back 10 Seconds", action: #selector(skipBack), keyEquivalent: "")
        menu.addItem(withTitle: "Forward 10 Seconds", action: #selector(skipForward), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Stop", action: #selector(stop), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }

    @objc private func togglePlayback() { Self.model?.activeTransport?.togglePlayback() }
    @objc private func skipBack() { Self.model?.activeTransport?.skip(by: -10) }
    @objc private func skipForward() { Self.model?.activeTransport?.skip(by: 10) }
    /// Stops the way the player's close button does, saving progress.
    @objc private func stop() { Self.model?.closePlayerSavingProgress() }
}
