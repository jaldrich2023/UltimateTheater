//
//  PINPadView.swift
//  Ultimate Theater
//

import SwiftUI

/// A four-digit PIN pad on a glass card. Checks a PIN, or asks for a new one twice.
struct PINPadView: View {
    let request: PINRequest
    let finish: () -> Void

    @State private var digits = ""
    @State private var firstEntry: String?
    @State private var errorMessage: String?
    @State private var shakes = 0
    /// Briefly true after a wrong PIN, so input can't be typed into the cleared dots.
    @State private var isPaused = false
    /// When the current lockout ends; drives the countdown.
    @State private var lockedUntil: Date?
    /// Seconds until another PIN can be tried (ticks down while locked).
    @State private var lockRemaining = 0
    @FocusState private var isFocused: Bool
    /// Whether this prompt checks only the administrator PIN, so the Mac's owner may clear it
    /// (a forgotten PIN, or one the Keychain can't read).
    @State private var canResetWithOwner = false
    @State private var isResetting = false

    private static let keypadRows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]]

    private var isLocked: Bool { lockRemaining > 0 }
    /// The lockouts for the PIN(s) this prompt checks.
    private var attempts: PINAttemptGuard { PINAttemptGuard(targets: request.lockoutTargets) }
    private var acceptsInput: Bool { !isLocked && !isPaused }

    private var lockMessage: String {
        let minutes = lockRemaining / 60, seconds = lockRemaining % 60
        let time = minutes > 0 ? String(format: "%d:%02d", minutes, seconds) : "\(seconds) second\(seconds == 1 ? "" : "s")"
        return "Too many wrong PINs. Try again in \(time)."
    }

    private var prompt: String {
        switch request.kind {
        case .verify: request.title
        case .create: firstEntry == nil ? request.title : "Enter the same PIN again"
        }
    }

    var body: some View {
        VStack(spacing: 22) {
            Group {
                if let profile = request.profile {
                    ProfileAvatar(profile: profile, size: 72)
                } else {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .frame(width: 72, height: 72)
                        .glassEffect(.regular, in: .rect(cornerRadius: 18))
                }
            }
            VStack(spacing: 6) {
                Text(prompt)
                    .font(.title2.bold())
                    .contentTransition(.opacity)
                Text(isLocked ? lockMessage : errorMessage ?? request.message)
                    .font(.callout)
                    .foregroundStyle(errorMessage == nil && !isLocked ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 18) {
                ForEach(0..<PINHash.length, id: \.self) { index in
                    Circle()
                        .fill(index < digits.count ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.15)))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1))
                }
            }
            .modifier(Shake(amount: CGFloat(shakes)))
            .animation(.default, value: shakes)
            .accessibilityElement()
            .accessibilityLabel("\(digits.count) of \(PINHash.length) digits entered")

            Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                ForEach(Self.keypadRows, id: \.self) { row in
                    GridRow { ForEach(row, id: \.self) { key($0) } }
                }
                GridRow {
                    Button("Cancel", action: finish)
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 64, height: 64)
                    key("0")
                    Button {
                        if acceptsInput, !digits.isEmpty { digits.removeLast() }
                    } label: {
                        Image(systemName: "delete.left")
                            .font(.title3)
                            .frame(width: 64, height: 64)
                    }
                    .buttonStyle(.plain)
                    .disabled(!acceptsInput)
                    .accessibilityLabel("Delete")
                }
            }
            if canResetWithOwner {
                // Needs the Mac's password (or Touch ID); also the way out when the PIN can't be
                // read, since nothing typed here would ever match it then.
                Button("Forgot PIN? Use Mac Password…", action: resetWithOwner)
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(Theme.accent)
                    .disabled(isResetting)
            }
        }
        .padding(36)
        .frame(width: 360)
        .glassEffect(.regular, in: .rect(cornerRadius: 30))
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear {
            isFocused = true
            updateLock()
            if case .verify = request.kind, request.lockoutTargets == [.administrator], AdministratorPIN.isSet {
                canResetWithOwner = true
                if let message = AdministratorPIN.readFailureMessage { errorMessage = message }
            }
        }
        // Counts down while locked; restarts whenever a new lock begins.
        .task(id: lockedUntil) {
            while !Task.isCancelled, attempts.isLocked(at: .now) {
                updateLock()
                try? await Task.sleep(for: .seconds(1))
            }
            updateLock()
        }
        .onKeyPress(characters: .decimalDigits) { press in
            press.characters.forEach { type(String($0)) }
            return .handled
        }
        .onKeyPress(.delete) {
            if acceptsInput, !digits.isEmpty { digits.removeLast() }
            return .handled
        }
        .onKeyPress(.escape) {
            finish()
            return .handled
        }
    }

    private func key(_ digit: String) -> some View {
        Button { type(digit) } label: {
            Text(digit)
                .font(.system(size: 26, weight: .medium, design: .rounded))
                .frame(width: 64, height: 64)
        }
        .buttonStyle(.theaterGlassCircle)
        .disabled(!acceptsInput)
    }

    private func updateLock() {
        let now = Date.now
        lockRemaining = Int(attempts.remaining(at: now).rounded(.up))
        lockedUntil = attempts.lockedUntil(at: now)
    }

    private func type(_ digit: String) {
        guard acceptsInput, digits.count < PINHash.length else { return }
        digits += digit
        errorMessage = nil
        guard digits.count == PINHash.length else { return }
        let entered = digits
        switch request.kind {
        case .verify(let check):
            // Re-read in case another prompt (or a relaunch) changed it meanwhile.
            updateLock()
            guard !isLocked else {
                digits = ""
                return
            }
            if check(entered) {
                attempts.recordSuccess()
                finish()
                request.completion(entered)
            } else {
                let unreadable = request.lockoutTargets.contains(.administrator) ? AdministratorPIN.readFailureMessage : nil
                attempts.recordFailure(at: .now, administratorUnreadable: unreadable != nil)
                updateLock()
                let attemptsLeft = PINLockout.freeAttempts - attempts.failures
                let message = unreadable
                    ?? (attemptsLeft > 0 && attemptsLeft <= 2
                        ? "That PIN isn't right. \(attemptsLeft) tr\(attemptsLeft == 1 ? "y" : "ies") left before a wait."
                        : "That PIN isn't right. Try again.")
                reject(message)
            }
        case .create:
            if let first = firstEntry {
                if first == entered {
                    finish()
                    request.completion(entered)
                } else {
                    firstEntry = nil
                    reject("The PINs didn't match. Start again.")
                }
            } else {
                firstEntry = entered
                digits = ""
            }
        }
    }

    /// Clears an unreadable administrator PIN after the Mac's owner authenticates, then
    /// continues as if the PIN had been entered.
    private func resetWithOwner() {
        isResetting = true
        Task {
            let cleared = await AdministratorPIN.resetWithDeviceOwnerAuthentication()
            isResetting = false
            guard cleared else {
                errorMessage = AdministratorPIN.isUnreadable
                    ? "The PIN wasn't reset. It stays locked until the Keychain can be read."
                    : "The PIN wasn't reset."
                return
            }
            canResetWithOwner = false
            finish()
            request.completion("")
        }
    }

    private func reject(_ message: String) {
        errorMessage = message
        shakes += 1
        // Keys are ignored until the dots clear, so a typed-ahead digit can't land in them.
        isPaused = true
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            digits = ""
            isPaused = false
        }
    }
}

/// Horizontal shake for a rejected PIN.
private struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(amount * .pi * 4), y: 0))
    }
}

/// Dims the app and shows the pending PIN request from the app model.
struct PINOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let request = model.pinRequest {
            ZStack {
                Rectangle()
                    .fill(.black.opacity(0.6))
                    .background(.ultraThinMaterial)
                    .ignoresSafeArea()
                PINPadView(request: request) {
                    if model.pinRequest?.id == request.id { model.pinRequest = nil }
                }
                .id(request.id)
            }
            .transition(.opacity)
        }
    }
}

