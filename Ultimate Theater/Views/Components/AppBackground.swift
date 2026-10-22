//
//  AppBackground.swift
//  Ultimate Theater
//
//  The backdrop behind every page: the near-black theater color with soft, faint pools
//  of the accent and a cool blue, so the Liquid Glass panels and controls floating above
//  it have color and depth to refract instead of a flat field.
//

import SwiftUI

struct AppBackground: View {
    var body: some View {
        ZStack {
            Theme.background
            RadialGradient(colors: [Theme.accent.opacity(0.14), .clear], center: UnitPoint(x: 0.92, y: 0.0),
                           startRadius: 0, endRadius: 700)
            RadialGradient(colors: [Color(hex: 0x3B5BFF).opacity(0.10), .clear], center: UnitPoint(x: 0.05, y: 1.0),
                           startRadius: 0, endRadius: 800)
            RadialGradient(colors: [Color(hex: 0x8A4DFF).opacity(0.06), .clear], center: .center,
                           startRadius: 0, endRadius: 900)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
