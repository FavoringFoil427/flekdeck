//
//  VariableBlurView.swift
//  LiveContainerSwiftUI
//
//  A real progressive (variable-radius) blur — the blur radius itself ramps
//  from strong to none along a gradient, unlike a SwiftUI material whose alpha
//  merely fades. Uses the private CAFilter "variableBlur" primitive that iOS
//  itself uses behind the Home Screen dock / Spotlight. The material tint is
//  stripped so the result is *just* blur, no frosting.
//

import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

struct VariableBlurView: UIViewRepresentable {
    /// Maximum blur radius at the strong end of the gradient.
    var maxBlurRadius: CGFloat = 18
    /// .top => blurred at top, clear at bottom (default). .bottom => reverse.
    var direction: VariableBlurUIView.Direction = .top

    func makeUIView(context: Context) -> VariableBlurUIView {
        VariableBlurUIView(maxBlurRadius: maxBlurRadius, direction: direction)
    }

    func updateUIView(_ uiView: VariableBlurUIView, context: Context) {}
}

final class VariableBlurUIView: UIVisualEffectView {

    enum Direction {
        case top     // strong at top, clear at bottom
        case bottom  // strong at bottom, clear at top
    }

    init(maxBlurRadius: CGFloat, direction: Direction) {
        super.init(effect: UIBlurEffect(style: .regular))

        guard let variableBlur = Self.makeVariableBlurFilter() else { return }

        let gradientImage = Self.makeGradientImage(direction: direction)
        variableBlur.setValue(maxBlurRadius, forKey: "inputRadius")
        variableBlur.setValue(gradientImage, forKey: "inputMaskImage")
        variableBlur.setValue(true, forKey: "inputNormalizeEdges")

        subviews.first?.layer.filters = [variableBlur]

        // Drop the visual-effect tint/vibrancy layers so it reads as pure blur.
        for subview in subviews.dropFirst() {
            subview.alpha = 0
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Match the screen scale so the blur backdrop stays crisp.
        guard let window, let backdropLayer = subviews.first?.layer else { return }
        backdropLayer.setValue(window.screen.scale, forKey: "scale")
    }

    // Keep the filter from being reset when the trait collection changes.
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {}

    private static func makeVariableBlurFilter() -> NSObject? {
        guard let filterClass = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
        let selector = NSSelectorFromString("filterWithType:")
        guard filterClass.responds(to: selector) else { return nil }
        let unmanaged = filterClass.perform(selector, with: "variableBlur")
        return unmanaged?.takeUnretainedValue() as? NSObject
    }

    private static func makeGradientImage(width: CGFloat = 100,
                                          height: CGFloat = 100,
                                          direction: Direction) -> CGImage? {
        let filter = CIFilter.smoothLinearGradient()
        filter.color0 = CIColor.black   // black => full blur
        filter.color1 = CIColor.clear   // clear => no blur
        // CoreImage origin is bottom-left.
        // Reach fully-clear (0 blur) a little above the bottom edge; CoreImage
        // keeps the endpoint color past the point, so the very bottom edge is
        // guaranteed to have zero blur (no hard seam).
        switch direction {
        case .top:
            filter.point0 = CGPoint(x: 0, y: height)          // top => blurred
            filter.point1 = CGPoint(x: 0, y: height * 0.12)   // ~bottom => clear
        case .bottom:
            filter.point0 = CGPoint(x: 0, y: 0)               // bottom => blurred
            filter.point1 = CGPoint(x: 0, y: height * 0.88)   // ~top => clear
        }
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: CGRect(x: 0, y: 0, width: width, height: height))
    }
}
