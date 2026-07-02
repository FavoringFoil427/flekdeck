//
//  FlekLauncherTheme.swift
//  LiveContainerSwiftUI
//
//  Design tokens and reusable glass building blocks for the FlekLauncher
//  springboard home screen. Values are taken from the FlekSign Figma design
//  (file paCG8NHeIWaCsxJ8ThkcEw).
//

import SwiftUI

enum FlekTheme {
    // Springboard grid
    static let gridColumns = 3
    static let gridSpacing: CGFloat = 8
    static let screenHPadding: CGFloat = 16
    static let gridTopPadding: CGFloat = 12

    // App card (frosted tile holding icon + label)
    static let cardCorner: CGFloat = 20
    static let cardHeight: CGFloat = 128
    static let cardTopPadding: CGFloat = 16
    static let cardBottomPadding: CGFloat = 8
    static let cardHPadding: CGFloat = 8
    static let cardInnerSpacing: CGFloat = 8

    // Icon (Figma: 74×74 squircle)
    static let iconSize: CGFloat = 74
    static let iconCorner: CGFloat = 17   // continuous squircle approximation (~0.2237 * size)

    // Label
    static let labelSize: CGFloat = 14

    // Bottom search pill
    static let searchPillSize: CGFloat = 50
}

/// Frosted "liquid glass" surface used by cards, pills and popups.
/// The design specifies a white 60% fill over the wallpaper; we approximate the
/// iOS-26 liquid-glass look with a thin material plus a strong white tint.
struct FlekGlassBackground: View {
    var cornerRadius: CGFloat = FlekTheme.cardCorner
    var tint: Double = 0.45

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(tint))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
            )
    }
}

extension View {
    /// Applies the standard frosted card surface.
    /// Uses Liquid Glass on iOS 26+ when the user preference is enabled,
    /// otherwise falls back to the thin-material style.
    @ViewBuilder
    func flekGlassCard(cornerRadius: CGFloat = FlekTheme.cardCorner, tint: Double = 0.22) -> some View {
        let useGlass = LCUtils.appGroupUserDefault.object(forKey: FlekLauncherKeys.cardStyleGlass) as? Bool ?? true
        if #available(iOS 26, *), useGlass {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(FlekGlassBackground(cornerRadius: cornerRadius, tint: tint))
        }
    }
}

/// A circular glass button used for the bottom search pill and the
/// "back to home" affordance shown over full-screen internal pages.
struct FlekGlassCircleButton: View {
    let systemImage: String
    var size: CGFloat = FlekTheme.searchPillSize
    var iconScale: CGFloat = 0.5
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(Circle().fill(Color.white.opacity(0.45)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
                Image(systemName: systemImage)
                    .font(.system(size: size * iconScale, weight: .regular))
                    .foregroundStyle(Color.primary.opacity(0.6))
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
    }
}
