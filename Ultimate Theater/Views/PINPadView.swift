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
    @FocusState private var isFocused: Bool

    private static let keypadRows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]]

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
                Text(errorMessage ?? request.message)
                    .font(.callout)
                    .foregroundStyle(errorMessage == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
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
                        if !digits.isEmpty { digits.removeLast() }
                    } label: {
                        Image(systemName: "delete.left")
                            .font(.title3)
                            .frame(width: 64, height: 64)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete")
                }
            }
        }
        .padding(36)
        .frame(width: 360)
        .glassEffect(.regular, in: .rect(cornerRadius: 30))
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear { isFocused = true }
        .onKeyPress(characters: .decimalDigits) { press in
            press.characters.forEach { type(String($0)) }
            return .handled
        }
        .onKeyPress(.delete) {
            if !digits.isEmpty { digits.removeLast() }
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
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
    }

    private func type(_ digit: String) {
        guard digits.count < PINHash.length else { return }
        digits += digit
        errorMessage = nil
        guard digits.count == PINHash.length else { return }
        let entered = digits
        switch request.kind {
        case .verify(let check):
            if check(entered) {
                finish()
                request.completion(entered)
            } else {
                reject("That PIN isn't right. Try again.")
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

    private func reject(_ message: String) {
        errorMessage = message
        shakes += 1
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            digits = ""
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

