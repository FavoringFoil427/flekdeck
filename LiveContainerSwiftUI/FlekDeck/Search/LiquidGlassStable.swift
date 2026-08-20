//
//  LiquidGlassStable.swift
//  LiveContainerSwiftUI
//
//  Telegram-style *stable* Liquid Glass.
//
//  iOS 26's `UIGlassEffect` samples the content behind it and re-tints itself a
//  moment after appearing (the "settling shift" over a dark wallpaper). Telegram
//  prevents this without giving up the translucent/refractive glass look: it
//  swizzles the private backdrop view's luminance callback
//  (`backdropLayer:didChangeLuma:`) and clamps the reported luma to a fixed range
//  defined per-instance on an `EffectSettingsContainerView` ancestor. Dark glass
//  clamps to 0.0...0.15, light to 0.8...0.801, so the glass keeps blurring and
//  refracting but never changes tone based on the wallpaper.
//
//  Uses private API (a UIKit-internal class name + selector). That's fine here
//  the same way it is for Telegram; it degrades gracefully (falls back to the
//  default adaptive behaviour) if the class/selector can't be found on a future
//  iOS build.
//

import SwiftUI
import UIKit
import ObjectiveC

// MARK: - Luma-clamping container

/// Plain `UIView` whose `lumaMin`/`lumaMax` define the allowed backdrop-luminance
/// range for any `UIVisualEffectView` placed inside it. The swizzled backdrop
/// callback walks up to the nearest instance of this class and clamps.
final class EffectSettingsContainerView: UIView {
    var lumaMin: Double = 0.0
    var lumaMax: Double = 0.0

    /// nil => capsule/circle (cornerRadius = min(w, h) / 2).
    var cornerRadiusOverride: CGFloat?
    weak var effectView: UIVisualEffectView?

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let effectView else { return }
        effectView.frame = bounds
        let radius = cornerRadiusOverride ?? (min(bounds.width, bounds.height) / 2.0)
        effectView.layer.cornerRadius = radius
        effectView.layer.cornerCurve = .continuous
        effectView.clipsToBounds = true
    }
}

// MARK: - Runtime swizzle

enum LiquidGlassRuntime {
    private static var installed = false

    /// Installs the luma clamp once. Safe to call repeatedly / off any glass creation.
    static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        installLumaClamp()
    }

    /// The backdrop view is a private Swift class inside UIKit whose mangled name
    /// ends in "UISDFBackdropView". The module-hash prefix can vary between iOS
    /// builds, so we match by suffix rather than hardcoding the full name.
    private static func findBackdropClass() -> AnyClass? {
        var count: UInt32 = 0
        guard let list = objc_copyClassList(&count) else { return nil }
        defer { free(UnsafeMutableRawPointer(list)) }
        let classes = UnsafeBufferPointer(start: list, count: Int(count))
        for cls in classes {
            if String(cString: class_getName(cls)).hasSuffix("UISDFBackdropView") {
                return cls
            }
        }
        return nil
    }

    private typealias LumaFn = @convention(c) (AnyObject, Selector, CALayer?, Double) -> Void
    private static var originalLuma: LumaFn?

    private static func installLumaClamp() {
        guard let cls = findBackdropClass() else { return }
        let selector = NSSelectorFromString("backdropLayer:didChangeLuma:")
        guard let method = class_getInstanceMethod(cls, selector) else { return }

        // Expect signature: void (self, _cmd, CALayer*, double). Bail if the ABI
        // isn't what we expect, to avoid corrupting the stack.
        if let raw = method_getTypeEncoding(method) {
            guard String(cString: raw).contains("d") else { return }
        }

        originalLuma = unsafeBitCast(method_getImplementation(method), to: LumaFn.self)

        let block: @convention(block) (AnyObject, CALayer?, Double) -> Void = { receiver, layer, luma in
            var value = luma
            if let view = receiver as? UIView,
               let container = nearestEffectContainer(view) {
                value = min(max(luma, container.lumaMin), container.lumaMax)
            }
            originalLuma?(receiver, selector, layer, value)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func nearestEffectContainer(_ view: UIView, depth: Int = 0) -> EffectSettingsContainerView? {
        if depth > 12 { return nil }
        if let container = view as? EffectSettingsContainerView { return container }
        guard let superview = view.superview else { return nil }
        return nearestEffectContainer(superview, depth: depth + 1)
    }
}

// MARK: - SwiftUI wrapper

/// A stable Liquid Glass surface for use as a `.background`. Keeps the real
/// translucent glass but pins its tone so it never adapts to the wallpaper.
@available(iOS 26.0, *)
struct StableLiquidGlass: UIViewRepresentable {
    var isDark: Bool
    var tint: UIColor?
    /// nil => capsule/circle (min(w, h) / 2).
    var cornerRadius: CGFloat? = nil

    func makeUIView(context: Context) -> EffectSettingsContainerView {
        LiquidGlassRuntime.installIfNeeded()

        let container = EffectSettingsContainerView(frame: .zero)
        container.cornerRadiusOverride = cornerRadius

        let effectView = UIVisualEffectView(effect: makeEffect())
        effectView.overrideUserInterfaceStyle = isDark ? .dark : .light
        container.addSubview(effectView)
        container.effectView = effectView

        applyClamp(container)
        context.coordinator.tint = tint
        context.coordinator.isDark = isDark
        return container
    }

    func updateUIView(_ container: EffectSettingsContainerView, context: Context) {
        container.cornerRadiusOverride = cornerRadius
        container.effectView?.overrideUserInterfaceStyle = isDark ? .dark : .light

        // Setting a property on an in-use UIVisualEffect does nothing; the effect
        // must be reassigned. Only do it when something actually changed.
        if context.coordinator.tint != tint || context.coordinator.isDark != isDark {
            container.effectView?.effect = makeEffect()
            context.coordinator.tint = tint
            context.coordinator.isDark = isDark
        }
        applyClamp(container)
        container.setNeedsLayout()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var tint: UIColor?
        var isDark = false
    }

    private func makeEffect() -> UIGlassEffect {
        let effect = UIGlassEffect(style: .regular)
        effect.tintColor = tint
        return effect
    }

    /// Narrow window pins the appearance: dark glass stays dark, light stays light.
    private func applyClamp(_ container: EffectSettingsContainerView) {
        if isDark {
            container.lumaMin = 0.0
            container.lumaMax = 0.15
        } else {
            container.lumaMin = 0.35
            container.lumaMax = 0.351
        }
    }
}
