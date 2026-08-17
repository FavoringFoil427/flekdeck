//
//  LCMinimizeToIconAnimator.swift
//  LiveContainerSwiftUI
//
//  The way iOS closes an app, for the built-in pages: the page shrinks into its
//  own springboard icon with its corners rounding off to the icon's, the grid
//  behind it settles forward out of a slight zoom, and the icon it lands on
//  takes a bounce at the moment it arrives.
//
//  Everything here runs off ONE critically damped spring — page, corners and
//  grid share its mass, stiffness and damping — and the icon's bounce is fired
//  by watching where the page actually is, not by a timer that predicts it. That
//  is what keeps the parts in step on a slow device, a dropped frame or a 120Hz
//  display alike.
//
//  The handoff — the page's last frame and the icon's first — is placed where
//  the two are the same size on screen, so neither jumps as one becomes the
//  other. See `handoffProgress(finalScale:)`.
//
//  Used wherever Settings or the Installer returns to the home screen — the
//  multitask home button, the installer's own close button, and the full-screen
//  cover the pre-multitask path presents them in.
//

import UIKit

enum LCMinimizeToIconAnimator {

    // MARK: - The spring

    /// The flight is a spring rather than a bezier, because that is the shape iOS
    /// gives this transition: it leaves briskly, covers most of the distance
    /// early, and eases into the icon along a decelerating tail no cubic curve
    /// reproduces convincingly.
    ///
    /// `response` is the spring's natural period — what an undamped spring of the
    /// same stiffness would take to reach its target. Every other number below is
    /// derived from it, so the whole scene stays in step by construction rather
    /// than by three constants that have to be kept in agreement by hand.
    private static let springResponse: TimeInterval = 0.30

    /// Angular frequency, ω = 2π / response.
    private static var springOmega: CGFloat { 2 * .pi / CGFloat(springResponse) }

    /// Critically damped (ζ = 1): stiffness = ω², damping = 2ω. Critical is the
    /// point of the whole choice — a page going into an icon must not overshoot
    /// it and come back, which any springier damping ratio would do.
    private static var springStiffness: CGFloat { springOmega * springOmega }
    private static var springDamping: CGFloat { 2 * springOmega }

    private static var springTiming: UISpringTimingParameters {
        UISpringTimingParameters(mass: 1,
                                 stiffness: springStiffness,
                                 damping: springDamping,
                                 initialVelocity: .zero)
    }

    /// How long that spring takes to settle completely, as Core Animation works
    /// it out from the same parameters. Longer than the arrival below, because
    /// the last few percent of a critically damped spring are sub-pixel — which
    /// is exactly why nothing visible is timed to it.
    private static var springSettlingDuration: TimeInterval {
        springAnimation(keyPath: "transform").settlingDuration
    }

    private static func springAnimation(keyPath: String) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = 1
        animation.stiffness = springStiffness
        animation.damping = springDamping
        animation.initialVelocity = 0
        return animation
    }

    // MARK: - The handoff

    /// The frame the page hands off to the icon — where the cross-fade finishes
    /// and the bounce fires.
    ///
    /// Not "when the spring settles": a critically damped spring is asymptotic,
    /// and its last few percent take as long again as the whole visible move. The
    /// handoff is instead the moment the two are *the same size on screen*, so
    /// nothing changes size as one becomes the other. The page renders at
    /// `pageWidth · (1 − p(1 − s))` after a fraction `p` of a flight ending at
    /// scale `s`, and the icon is `iconWidth · bounceScale` at the peak of its
    /// bounce — which is `pageWidth · s · bounceScale`. Equating the two and
    /// solving for `p`:
    ///
    ///     p = (1 − s · bounceScale) / (1 − s)
    ///
    /// That lands around 96% of the way on a phone and 99% on the wider iPad
    /// grid, which is the point of deriving it rather than picking one number:
    /// the same fixed percentage is a different number of points on every screen.
    private static func handoffProgress(finalScale: CGFloat) -> CGFloat {
        guard finalScale < 1 else { return 1 }
        let progress = (1 - finalScale * bounceScale) / (1 - finalScale)
        return min(max(progress, 0.8), 0.995)
    }

    /// When a critically damped spring has covered `progress` of its distance.
    /// Its position, 1 − (1 + ωt)·e^(−ωt), has no elementary inverse, so this
    /// bisects for ωt — two dozen iterations of arithmetic, once per flight.
    private static func time(forProgress progress: CGFloat) -> TimeInterval {
        let target = Double(min(max(progress, 0), 0.999))
        var low = 0.0
        var high = 20.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if 1 - (1 + mid) * exp(-mid) < target { low = mid } else { high = mid }
        }
        return TimeInterval(CGFloat(low) / springOmega)
    }

    /// When the cross-fade starts, as a fraction of the way to the handoff. The
    /// page holds its content through the move and gives way only at the end of
    /// it — iOS does not dissolve the app halfway there.
    private static let fadeStartFraction: TimeInterval = 0.58

    // MARK: - Shape

    /// The icon's answering bounce, fired on the frame the page lands.
    private static let bounceDuration: TimeInterval = 0.3
    private static let bounceScale: CGFloat = 1.16
    /// Where the grid starts the flight — zoomed in and dimmed a touch, settling
    /// back to rest on the same spring as the page. Without that counter-move the
    /// icons read as wallpaper behind a shrinking rectangle instead of a home
    /// screen coming forward to meet it. Both are deliberately slight: the grid
    /// is uncovered gradually, and anything stronger shows as a flash along the
    /// edges the page does not cover.
    private static let gridZoom: CGFloat = 1.04
    private static let gridStartAlpha: CGFloat = 0.82
    /// An icon's corner radius as a share of its width — the springboard's own
    /// proportion, taken from the frame it lands on so the page rounds off to the
    /// right shape on both the phone and the iPad grid.
    private static let iconCornerRadiusRatio: CGFloat = 0.2237
    /// The square a page shrinks into when there is no icon to aim at — the list
    /// layout, or a page with no home-screen icon of its own. It still recedes
    /// rather than blinking out.
    private static let fallbackTargetSize: CGFloat = 78

    private static let cornerAnimationKey = "lcMinimizeCorner"

    /// How long the page takes to go when Reduce Motion is on. Close to the
    /// handoff the flight would have reached, so turning the setting on changes
    /// how getting home *looks*, not how long it takes.
    private static let dissolveDuration: TimeInterval = 0.25

    /// Whether to go home without the flight. A full-screen surface scaling to a
    /// fifth of its size, over a grid scaling underneath it, is exactly the
    /// large-field motion the setting exists to suppress — and it is the most
    /// motion this app produces anywhere. Read per flight, so the setting takes
    /// effect on the next minimize rather than the next launch.
    private static var prefersDissolve: Bool {
        UIAccessibility.isReduceMotionEnabled
    }

    /// The flights in the air, keyed by the icon each is heading for, so every one
    /// of them can bounce its own icon on the frame it lands. Going home with
    /// several windows open starts several at once, and a single watcher would
    /// let only the last of them arrive. Starting another flight to the same icon
    /// cancels the one already going there — which is also what stops a page
    /// restored mid-flight from leaving an icon popping on its own.
    private static var arrivalWatchers: [String: LCFlightArrivalWatcher] = [:]

    /// Whether the grid is already coming forward. Every flight asks it to, and
    /// without this the second and third would each snap it back to its zoomed
    /// starting point while the first was still settling.
    private static var isGridSettling = false

    // MARK: - Entry points

    /// Flies `view` into the springboard icon for `itemID`, then hides it. The
    /// view is left hidden, untransformed and fully opaque, ready to be shown
    /// again by whatever brings the page back.
    static func minimize(_ view: UIView, toItemID itemID: String, completion: (() -> Void)? = nil) {
        guard let container = view.superview, !view.isHidden,
              view.bounds.width > 1, view.bounds.height > 1 else {
            view.isHidden = true
            completion?()
            return
        }

        view.layer.removeAllAnimations()
        view.transform = .identity
        view.alpha = 1

        let finish = {
            // Something may have brought the window back while it was still on
            // its way out — reopening it resets the transform and puts the alpha
            // back to 1. Hiding it now would take away a window the user has just
            // asked for, so a flight that no longer owns the view stands down.
            // (`minimizeWindow`'s `if (!finished) return` guarded the same case;
            // a property animator finishes on schedule regardless, so the state
            // has to be the test.)
            guard view.alpha < 0.5 else { return }

            view.isHidden = true
            view.transform = .identity
            view.alpha = 1
            completion?()
        }

        if prefersDissolve {
            dissolve(view, completion: finish)
        } else {
            fly(view, in: container, toItemID: itemID, completion: finish)
        }
    }

    /// The same flight for a page that is going away rather than being hidden:
    /// the page is replaced by a snapshot, `teardown` runs straight away so the
    /// rest of the UI updates on time, and the snapshot makes the trip in its
    /// place.
    static func minimizeByReplacing(_ view: UIView, toItemID itemID: String, teardown: @escaping () -> Void) {
        guard let window = view.window, view.bounds.width > 1, view.bounds.height > 1,
              let snapshot = view.snapshotView(afterScreenUpdates: false) else {
            teardown()
            return
        }

        snapshot.frame = view.convert(view.bounds, to: window)
        window.addSubview(snapshot)
        teardown()

        // Nothing to aim at under Reduce Motion, so nothing to wait for either:
        // the page can start going the moment it is replaced.
        if prefersDissolve {
            dissolve(snapshot) { snapshot.removeFromSuperview() }
            return
        }

        // The springboard is uncovered by the teardown, and needs a turn of the
        // run loop (sometimes two) to be back on screen before its icons can be
        // measured — hence the wait rather than a flight straight from here.
        DispatchQueue.main.async {
            flyWhenGridIsReady(snapshot, in: window, toItemID: itemID, attemptsLeft: 3) {
                snapshot.removeFromSuperview()
            }
        }
    }

    // MARK: - The flight, for those who would rather not have one

    /// Going home under Reduce Motion: the page gives way where it stands and the
    /// springboard is simply behind it. No shrink, no corner morph, no counter-
    /// zoom on the grid, and no bounce — there is no arrival to answer. The grid
    /// is also left on whatever page it was on, since nothing needs an icon to
    /// aim at any more.
    private static func dissolve(_ view: UIView, completion: @escaping () -> Void) {
        let fade = UIViewPropertyAnimator(duration: dissolveDuration, curve: .easeInOut) {
            view.alpha = 0
        }
        fade.addCompletion { _ in completion() }
        fade.startAnimation()
    }

    // MARK: - The flight

    private static func flyWhenGridIsReady(
        _ view: UIView,
        in container: UIView,
        toItemID itemID: String,
        attemptsLeft: Int,
        completion: @escaping () -> Void
    ) {
        if attemptsLeft > 0, iconFrame(forItemID: itemID, in: container) == nil {
            DispatchQueue.main.async {
                flyWhenGridIsReady(view, in: container, toItemID: itemID,
                                   attemptsLeft: attemptsLeft - 1, completion: completion)
            }
            return
        }
        fly(view, in: container, toItemID: itemID, completion: completion)
    }

    private static func fly(
        _ view: UIView,
        in container: UIView,
        toItemID itemID: String,
        completion: @escaping () -> Void
    ) {
        let start = view.frame
        let target = iconFrame(forItemID: itemID, in: container) ?? fallbackFrame(in: container)
        let scaleX = max(0.01, target.width / max(start.width, 1))
        let scaleY = max(0.01, target.height / max(start.height, 1))
        let settling = springSettlingDuration

        let originalRadius = view.layer.cornerRadius
        let originalMasksToBounds = view.layer.masksToBounds
        let originalCornerCurve = view.layer.cornerCurve
        view.layer.masksToBounds = true
        view.layer.cornerCurve = .continuous

        // The corners round off on the same spring as the shape they belong to —
        // on any other curve they run ahead of or behind the shrink. The radius
        // renders through the transform, so the value that lands at the icon's is
        // the icon's divided by the scale the page shrinks by.
        let corner = springAnimation(keyPath: "cornerRadius")
        let endRadius = target.width * iconCornerRadiusRatio / scaleX
        corner.fromValue = originalRadius > 0 ? originalRadius : displayCornerRadius()
        corner.toValue = endRadius
        corner.duration = settling
        view.layer.cornerRadius = endRadius
        view.layer.add(corner, forKey: cornerAnimationKey)

        settleGrid(settling: settling)

        let flight = UIViewPropertyAnimator(duration: settling, timingParameters: springTiming)
        flight.addAnimations {
            view.transform = CGAffineTransform(
                translationX: target.midX - start.midX,
                y: target.midY - start.midY
            ).scaledBy(x: scaleX, y: scaleY)
        }
        flight.addCompletion { _ in
            view.layer.removeAnimation(forKey: cornerAnimationKey)
            view.layer.cornerRadius = originalRadius
            view.layer.masksToBounds = originalMasksToBounds
            view.layer.cornerCurve = originalCornerCurve
            completion()
        }

        // The cross-fade is its own animator so it can finish on the handoff
        // instead of trailing the spring's long asymptotic tail: the page is gone
        // the instant it matches the icon, not fading for a further quarter of a
        // second over the top of it.
        let handoff = handoffProgress(finalScale: scaleX)
        let handoffTime = time(forProgress: handoff)
        let fadeStart = handoffTime * fadeStartFraction
        let fade = UIViewPropertyAnimator(duration: handoffTime - fadeStart, curve: .easeIn) {
            view.alpha = 0
        }

        // The icon is bounced by where the page actually is. A timer set to fire
        // near the end only predicts the landing — and predicts it differently on
        // every device — where this watches the flight's own presentation layer
        // and calls it on the frame the page reaches the icon.
        arrivalWatchers[itemID]?.cancel()
        arrivalWatchers[itemID] = LCFlightArrivalWatcher(
            view: view,
            finalScale: scaleX,
            arrivalProgress: handoff,
            timeout: settling + 0.2
        ) {
            arrivalWatchers[itemID] = nil
            bounceIcon(itemID)
        }

        flight.startAnimation()
        fade.startAnimation(afterDelay: fadeStart)
    }

    // MARK: - The home screen's half of it

    /// Brings the grid forward as the page recedes, on the same spring, so the
    /// two halves of the move land together.
    private static func settleGrid(settling: TimeInterval) {
        guard !isGridSettling,
              let grid = LCSpringboardViewController.current?.viewIfLoaded,
              grid.window != nil else { return }

        isGridSettling = true
        grid.transform = CGAffineTransform(scaleX: gridZoom, y: gridZoom)
        grid.alpha = gridStartAlpha

        let settle = UIViewPropertyAnimator(duration: settling, timingParameters: springTiming)
        settle.addAnimations {
            grid.transform = .identity
            grid.alpha = 1
        }
        settle.addCompletion { _ in isGridSettling = false }
        settle.startAnimation()
    }

    /// The icon takes the page. Looked up at the moment this fires, so a grid
    /// that reloaded during the flight still bounces the icon that is actually on
    /// screen.
    private static func bounceIcon(_ itemID: String) {
        guard let cell = LCSpringboardViewController.current?.iconCell(forItemID: itemID),
              cell.window != nil else { return }

        // Only the icon is scaled. A transform on the whole cell drags its glass
        // card with it, which the material does not survive cleanly.
        let icon = cell.iconImageView
        icon.transform = CGAffineTransform(scaleX: bounceScale, y: bounceScale)
        UIView.animate(withDuration: bounceDuration, delay: 0,
                       usingSpringWithDamping: 0.56, initialSpringVelocity: 0.8,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            icon.transform = .identity
        }
    }

    // MARK: - Where the page is headed

    /// The icon's frame in `container`'s coordinates, or nil when the item has no
    /// icon on screen to aim at.
    private static func iconFrame(forItemID itemID: String, in container: UIView) -> CGRect? {
        guard container.window != nil,
              let cell = LCSpringboardViewController.current?.iconCell(forItemID: itemID),
              cell.window != nil else { return nil }

        let icon = cell.iconImageView
        let frame = icon.convert(icon.bounds, to: container)
        guard frame.width > 1, frame.height > 1 else { return nil }
        return frame
    }

    private static func fallbackFrame(in container: UIView) -> CGRect {
        CGRect(x: container.bounds.midX - fallbackTargetSize / 2,
               y: container.bounds.midY - fallbackTargetSize / 2,
               width: fallbackTargetSize,
               height: fallbackTargetSize)
    }

    /// The screen's own corner radius, so a page with square corners of its own
    /// still starts the flight shaped like the screen it fills.
    private static func displayCornerRadius() -> CGFloat {
        (UIScreen.main.value(forKey: "_displayCornerRadius") as? CGFloat) ?? 0
    }
}

// MARK: - Arrival watcher

/// Watches a flight in progress and calls back on the frame its rendered scale
/// reaches the icon.
///
/// The point is that it measures rather than predicts. Reading the presentation
/// layer each frame means the callback lands on the same frame the page does,
/// whatever the spring, the refresh rate or the load on the device — and if the
/// page never arrives, because it was brought back or interrupted, the callback
/// simply never fires.
private final class LCFlightArrivalWatcher {

    private var link: CADisplayLink?
    private weak var view: UIView?
    private let finalScale: CGFloat
    private let arrivalProgress: CGFloat
    private let deadline: CFTimeInterval
    private var onArrive: (() -> Void)?

    init(view: UIView,
         finalScale: CGFloat,
         arrivalProgress: CGFloat,
         timeout: TimeInterval,
         onArrive: @escaping () -> Void) {
        self.view = view
        self.finalScale = finalScale
        self.arrivalProgress = arrivalProgress
        self.deadline = CACurrentMediaTime() + timeout
        self.onArrive = onArrive

        let link = CADisplayLink(target: self, selector: #selector(step))
        // Common modes: a flight started from a scrolling grid must still be
        // watched while that scroll is tracking.
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func cancel() {
        link?.invalidate()
        link = nil
        onArrive = nil
    }

    @objc private func step() {
        guard let presentation = view?.layer.presentation() else {
            if CACurrentMediaTime() >= deadline { cancel() }
            return
        }

        let total = 1 - finalScale
        // A page that is not really shrinking has nowhere to arrive.
        guard total > 0.01 else { cancel(); return }

        let travelled = 1 - presentation.affineTransform().a
        if travelled / total >= arrivalProgress {
            let arrived = onArrive
            cancel()
            arrived?()
        } else if CACurrentMediaTime() >= deadline {
            // Interrupted, or it never moved. Nothing landed on the icon, so
            // nothing should bounce.
            cancel()
        }
    }
}
