//
//  RemoteSettingsView.swift
//  Ultimate Theater
//
//  Settings › Remote: turn the iPhone remote on (administrator only), pair a phone with a
//  QR code or six-digit code, and revoke paired devices.
//

import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

struct RemoteSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var pinRequest: PINRequest?
    @State private var isConfirmingRevokeAll = false
    private let remote = RemoteControl.shared

    var body: some View {
        Form {
            Section {
                Toggle("Allow iPhone Remote", isOn: Binding(get: { remote.isEnabled }, set: { enabled in
                    verifyThen { remote.setEnabled(enabled) }
                }))
                .disabled(!model.canManageLibrary)
                LabeledContent("Status") {
                    Text(statusText).foregroundStyle(statusColor)
                }
            } header: {
                Text("iPhone Remote")
            } footer: {
                Text(model.canManageLibrary
                     ? "Control playback from a phone on the same Wi-Fi: play and pause, skip, change audio and subtitles, or start something from Continue Watching. Only devices on your local network can connect, and each one must be paired first. The connection isn't encrypted, so use it only on a Wi-Fi network you trust; pairings lapse after 30 days unused, and you can revoke them here."
                     : "Only the administrator's profile can turn the iPhone remote on or off.")
                    .foregroundStyle(.secondary)
            }

            if remote.isEnabled, model.canManageLibrary {
                Section {
                    pairing
                } header: {
                    Text("Pair a Phone")
                } footer: {
                    Text("Scan the code with the iPhone's Camera, or open the address in Safari and type the six-digit code. A code works once and expires after 10 minutes.")
                        .foregroundStyle(.secondary)
                }

                Section("Paired Devices") {
                    if remote.devices.isEmpty {
                        Text("No devices paired yet.").foregroundStyle(.secondary)
                    }
                    ForEach(remote.devices) { device in
                        HStack(spacing: 10) {
                            Image(systemName: device.name.contains("iPad") ? "ipad" : "iphone")
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                Text("Paired \(device.pairedAt.formatted(date: .abbreviated, time: .omitted)) · last used \(device.lastSeen.formatted(.relative(presentation: .named)))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Revoke", role: .destructive) { remote.revoke(device) }
                        }
                    }
                    if remote.devices.count > 1 {
                        Button("Revoke All…", role: .destructive) { isConfirmingRevokeAll = true }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        // The code stays valid for as long as this pane is open.
        .task {
            while !Task.isCancelled {
                remote.keepPairingCodeAlive()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .confirmationDialog("Revoke every paired device?", isPresented: $isConfirmingRevokeAll) {
            Button("Revoke All", role: .destructive) { remote.revokeAll() }
        } message: {
            Text("Each phone will need to be paired again.")
        }
        .sheet(item: $pinRequest) { request in
            PINPadView(request: request) { pinRequest = nil }
                .padding(20)
        }
    }

    @ViewBuilder
    private var pairing: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let isExpired = (remote.pairingExpiry ?? .distantPast) <= context.date
            HStack(alignment: .center, spacing: 20) {
                Group {
                    if let link = remote.pairingURL, !isExpired, let qr = QRCode.image(for: link) {
                        Image(decorative: qr, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .padding(8)
                            .background(.white, in: .rect(cornerRadius: 10))
                    } else {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.white.opacity(0.06))
                            .overlay { Image(systemName: "qrcode").font(.largeTitle).foregroundStyle(.secondary) }
                    }
                }
                .frame(width: 150, height: 150)
                .accessibilityLabel("Pairing QR code")

                VStack(alignment: .leading, spacing: 8) {
                    Text("Code")
                        .font(.caption.weight(.bold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    Text(isExpired ? "––––––" : spaced(remote.pairingCode ?? ""))
                        .font(.system(size: 30, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                    if let expiry = remote.pairingExpiry, !isExpired {
                        Text("Expires in \(Self.countdown(expiry.timeIntervalSince(context.date)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else if remote.isPairingLocked {
                        Text("Pairing stopped after too many wrong codes.").font(.caption).foregroundStyle(.orange)
                    } else {
                        Text("This code has expired.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let base = remote.baseURL {
                        Text(base)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    } else if case .failed = remote.status {
                        Text("The remote couldn't start.").font(.callout).foregroundStyle(.orange)
                    } else {
                        Text("Waiting for the network…").font(.callout).foregroundStyle(.secondary)
                    }
                    Button("New Code") { remote.newPairingCode() }
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
    }

    private var statusText: String {
        switch remote.status {
        case .off: "Off"
        case .starting: "Starting…"
        case .running: "On · \(NetworkInfo.serviceName)"
        case .failed(let message): "Couldn't start: \(message)"
        }
    }

    private var statusColor: Color {
        switch remote.status {
        case .running: .green
        case .failed: .orange
        default: .secondary
        }
    }

    private func spaced(_ code: String) -> String {
        code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
    }

    private static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Changing whether the remote is on takes the administrator PIN, when one is set.
    private func verifyThen(_ action: @escaping () -> Void) {
        guard model.canManageLibrary else { return }
        guard AdministratorPIN.isSet else { return action() }
        pinRequest = PINRequest(title: "Administrator PIN", message: "Enter the administrator PIN to change the iPhone remote.",
                                profile: nil, kind: .verify(AdministratorPIN.verify)) { _ in action() }
    }
}

/// QR codes with Core Image.
enum QRCode {
    private static let context = CIContext()
    /// The last code drawn, so the once-a-second countdown doesn't redraw it.
    private static var cache: (text: String, image: CGImage)?

    static func image(for text: String) -> CGImage? {
        if let cache, cache.text == text { return cache.image }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let image = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        cache = (text, image)
        return image
    }
}
