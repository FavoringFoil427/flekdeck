//
//  FlekLauncherTheme.swift
//  LiveContainerSwiftUI
//
//  Design tokens and reusable glass building blocks for the FlekLauncher
//  springboard home screen. Values are taken from the FlekSign Figma design
//  (file paCG8NHeIWaCsxJ8ThkcEw).
//

import SwiftUI

/// SF Symbol names resolved against what the running system actually ships.
///
/// A too-new symbol name is not an error: `Image(systemName:)` just draws nothing
/// and `UIImage(systemName:)` returns nil, so the failure mode is a silently blank
/// icon rather than a crash. Names are plain strings, so picking one by
/// availability is free at the type level — unlike view types, which have to be
/// erased (see `flekGlassCard`).
enum FlekSymbol {
    /// `iphone.app.switcher` is iOS 18+.
    static var appSwitcher: String {
        if #available(iOS 18.0, *) { return "iphone.app.switcher" }
        return "rectangle.stack"
    }

    /// iOS 18 introduced `document.fill` alongside the older `doc.fill`.
    static var document: String {
        if #available(iOS 18.0, *) { return "document.fill" }
        return "doc.fill"
    }

    /// `photo.badge.plus` is iOS 17+.
    static var addPhoto: String {
        if #available(iOS 17.0, *) { return "photo.badge.plus" }
        return "photo.on.rectangle"
    }

    /// `iphone.gen3` is iOS 16.1+.
    static var device: String {
        if #available(iOS 16.1, *) { return "iphone.gen3" }
        return "iphone"
    }

    /// `app.grid` is iOS 26+.
    static var appGrid: String {
        if #available(iOS 26.0, *) { return "app.grid" }
        return "square.grid.2x2"
    }

    /// `arrow.down.circle.badge.xmark` is iOS 26+.
    static var cancelDownload: String {
        if #available(iOS 26.0, *) { return "arrow.down.circle.badge.xmark" }
        return "xmark.circle"
    }
}

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

/// The pre-iOS 26 frosted surface shared by the bottom-bar controls.
///
/// The springboard search button and the multitask dock pill sit side by side in
/// the same bar, so they have to be the same material. They previously carried
/// their own copies — white 0.45 for the search button, `Color.primary` 0.15 for
/// the pill — which read as two different materials on anything below iOS 26,
/// where both get real Liquid Glass and the difference disappears.
///
/// The pill's tint is the one kept: `Color.primary` tracks the color scheme, so
/// the surface stays subtle in both themes instead of always washing toward
/// white. Keeping it in one place stops the two drifting apart again.
struct FlekFrostedSurface<S: InsettableShape>: View {
    let shape: S
    var tint: Color = .primary
    var fill: Double = 0.15
    var stroke: Double = 0.15

    var body: some View {
        shape
            .fill(.ultraThinMaterial)
            .overlay(shape.fill(tint.opacity(fill)))
            .overlay(shape.strokeBorder(tint.opacity(stroke), lineWidth: 0.5))
    }
}

extension View {
    /// Applies the standard frosted card surface.
    /// Uses Liquid Glass on iOS 26+ when the user preference is enabled,
    /// otherwise falls back to the thin-material style.
    // Erased to AnyView: an opaque return type would bake the iOS 26-only type
    // `glassEffect` produces into this function's static type, and the runtime
    // resolves that type before the availability check runs — which traps on
    // iOS 17.x, where the type is absent from the system SwiftUI.
    func flekGlassCard(cornerRadius: CGFloat = FlekTheme.cardCorner, tint: Double = 0.22) -> AnyView {
        let useGlass = LCUtils.appGroupUserDefault.object(forKey: FlekLauncherKeys.cardStyleGlass) as? Bool ?? true
        if #available(iOS 26, *), useGlass {
            return AnyView(self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
        }
        return AnyView(self.background(FlekGlassBackground(cornerRadius: cornerRadius, tint: tint)))
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
                FlekFrostedSurface(shape: Circle())
                Image(systemName: systemImage)
                    .font(.system(size: size * iconScale, weight: .regular))
                    .foregroundStyle(Color.primary.opacity(0.6))
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
    }
}
