//
//  FlekInternalPage.swift
//  LiveContainerSwiftUI
//
//  Hosts a built-in FlekDeck page (Settings / Installer) as a full-screen
//  cover, on the paths where multitasking is not available. A single glass
//  "back to home" chevron at the bottom returns to the springboard, shrinking
//  the page into its own icon on the way — the same trip the multitask home
//  button gives these pages.
//

import SwiftUI
import UIKit

struct FlekInternalPage<Content: View>: View {
    /// Returns to the springboard. Supplied by `FlekMinimizingCover`, which runs
    /// the minimize animation before dismissing the cover.
    var minimize: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .overlay(alignment: .bottom) {
                FlekGlassCircleButton(systemImage: "chevron.down", size: FlekTheme.navControlSize, iconScale: 0.42) {
                    minimize()
                }
                .padding(.bottom, 6)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            }
    }
}

/// A full-screen cover that goes home the way iOS closes an app: the page
/// shrinks into its own springboard icon, and only then is the cover dismissed —
/// with its own slide-down suppressed, since the shrink has already taken the
/// page off the screen and a slide underneath it would be a second, contrary
/// exit.
///
/// The content is handed the `minimize` action to call from whatever control it
/// closes with, so the installer's own close button and the settings chevron
/// both go home the same way.
struct FlekMinimizingCover<Content: View>: View {
    @Binding var isPresented: Bool
    /// The home-screen item this page belongs to — the icon it flies into.
    let itemID: String
    @ViewBuilder var content: (@escaping () -> Void) -> Content

    /// The cover's own view, resolved once it is on screen. Nil until then, and
    /// on any path where the presented controller cannot be reached — the page
    /// still dismisses, just without the flight.
    @State private var hostView: UIView?

    var body: some View {
        content(minimize)
            .background(FlekPresentedHostProbe { hostView = $0 })
    }

    private func minimize() {
        guard let hostView else {
            isPresented = false
            return
        }
        LCMinimizeToIconAnimator.minimizeByReplacing(hostView, toItemID: itemID) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { isPresented = false }
        }
    }
}

/// Hands back the view of the controller presenting this content, so a cover can
/// be snapshotted before it is dismissed. Resolves once and then stays quiet:
/// re-reporting on every SwiftUI update would write state on every pass.
private struct FlekPresentedHostProbe: UIViewRepresentable {
    let onResolve: (UIView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var resolved = false
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard !context.coordinator.resolved else { return }
        // The responder chain only reaches the hosting controller once the view
        // is in a window, which is a turn of the run loop away from here.
        DispatchQueue.main.async {
            guard !context.coordinator.resolved,
                  let host = uiView.presentedHostView else { return }
            context.coordinator.resolved = true
            onResolve(host)
        }
    }
}

private extension UIView {
    /// The root view of the presentation this view sits in: the nearest view
    /// controller up the responder chain, then out through its parents to the
    /// controller that was actually presented.
    var presentedHostView: UIView? {
        var responder: UIResponder? = self
        while let next = responder?.next, !(next is UIViewController) {
            responder = next
        }
        guard var controller = responder?.next as? UIViewController else { return nil }
        while let parent = controller.parent {
            controller = parent
        }
        return controller.isViewLoaded ? controller.view : nil
    }
}
