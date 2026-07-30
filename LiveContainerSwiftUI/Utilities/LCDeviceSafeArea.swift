//
//  LCDeviceSafeArea.swift
//  LiveContainerSwiftUI
//
//  The device's own safe-area insets, as opposed to whatever a particular view
//  hierarchy has been told.
//
//  Layouts that deliberately sink into the home-indicator inset need to know
//  whether that inset exists at all: a phone with a physical home button reports
//  zero, and the same negative offset that looks right on a notched device pushes
//  content off the bottom of the screen there.
//
//  A `GeometryReader` is the obvious way to ask and the wrong one — placed under
//  `ignoresSafeArea` it reports zero on every device, and placed inside a view that
//  already respects the safe area it reports zero as well. Reading the window is
//  unambiguous, and it also excludes any `additionalSafeAreaInsets` the multitask
//  host adds to reserve room for the switcher bar, which is a different question.
//

import UIKit

enum LCDeviceSafeArea {

    /// The window's bottom safe-area inset: the home indicator's height, or zero on
    /// a device with a physical home button.
    ///
    /// Resolving this walks the connected scenes, so call it from `onAppear` or a
    /// change notification and hold the result — never from a SwiftUI body, which
    /// re-evaluates far too often for that.
    static func bottomInset() -> CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow }
            ?? scenes.flatMap(\.windows).first
        return window?.safeAreaInsets.bottom ?? 0
    }
}
