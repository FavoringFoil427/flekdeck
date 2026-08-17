//
//  LCMinimizeToIconAnimator.swift
//  LiveContainerSwiftUI
//
//  The way iOS closes an app, for the built-in pages: the page shrinks into its
//  own springboard icon with its corners rounding off to the icon's, the grid
//  behind it settles forward out of a slight zoom, and the icon it lands on
//  takes a bounce at the moment it arrives.
//
//  Everything here runs off ONE number — `flightDuration`, how long a window
//  takes to cross in either direction. The critically damped spring that carries
//  it is derived from that, per flight, so that each direction's own finish
//  lands exactly on it: a closing window is done when it matches its icon, an
//  opening one when it has all but reached full size. Opening and closing are
//  therefore the same speed by construction, on every screen, rather than by two
//  numbers kept in agreement by hand. Page, corners and grid all move on the
//  flight's spring.
//
//  The icon's bounce is fired by watching where the window actually is, not by a
//  timer that predicts it — which is what keeps the parts in step on a slow
//  device, a dropped frame or a 120Hz display alike.
//
//  The handoff — the page's last frame and the icon's first — is placed where
//  the two are the same size on screen, so neither jumps as one becomes the
//  other. See `handoffProgress(finalScale:iconPeak:)`.
//
//  Used wherever Settings or the Installer returns to the home screen — the
//  multitask home button, the installer's own close button, and the full-screen
//  cover the pre-multitask path presents them in.
//

import UIKit

enum LCMinimizeToIconAnimator {

    // MARK: - The spring

    /// How long a window takes to cross, in either direction and on any screen.
    ///
    /// One number for the whole feature. Opening and closing are the same move
    /// reversed and should take the same time, but "done" means something
    /// different at each end: a closing window is finished when it matches the
    /// icon and disappears, while an opening one is finished when it has all but
    /// reached full size. Timing both to the same spring made the opening feel
    /// the slower of the two, because it goes on visibly growing after the point
    /// at which a closing window would already have gone.
    ///
    /// So the spring is derived from this, rather than the other way round: each
    /// direction gets the spring that puts *its own* finish exactly here.
    private static let flightDuration: TimeInterval = 0.21

    /// How much of the growth counts as open. The last half-percent of a
    /// critically damped spring is sub-pixel, and waiting for it is what made an
    /// opening window feel as though it were settling in rather than arriving.
    private static let openCompleteProgress: CGFloat = 0.995

    /// A critically damped spring, described by its angular frequency.
    ///
    /// Critical damping (ζ = 1) is the point of the choice: stiffness = ω²,
    /// damping = 2ω, and a window going into an icon cannot overshoot it and swing
    /// back, which any springier ratio would do.
    private struct Spring {
        let omega: CGFloat

        var timing: UISpringTimingParameters {
            UISpringTimingParameters(mass: 1,
                                     stiffness: omega * omega,
                                     damping: 2 * omega,
                                     initialVelocity: .zero)
        }

        func animation(keyPath: String) -> CASpringAnimation {
            let animation = CASpringAnimation(keyPath: keyPath)
            animation.mass = 1
            animation.stiffness = omega * omega
            animation.damping = 2 * omega
            animation.initialVelocity = 0
            return animation
        }

        /// How long it takes to settle completely, as Core Animation works it out
        /// from the same parameters. Always longer than the flight, because the
        /// tail is sub-pixel — which is exactly why nothing visible is timed to it.
        var settlingDuration: TimeInterval {
            animation(keyPath: "transform").settlingDuration
        }
    }

    /// The spring that covers `progress` of its distance in exactly
    /// `flightDuration` — the one piece of arithmetic that makes the two
    /// directions the same speed while letting each define its own finish.
    private static func spring(reaching progress: CGFloat) -> Spring {
        Spring(omega: CGFloat(omegaT(forProgress: progress) / flightDuration))
    }

    /// ωt at which a critically damped spring has covered `progress` of its
    /// distance: the solution of (1 + ωt)·e^(−ωt) = 1 − progress. It has no
    /// elementary inverse, so it is bisected — two dozen iterations of
    /// arithmetic, once per flight.
    private static func omegaT(forProgress progress: CGFloat) -> Double {
        let target = Double(min(max(progress, 0), 0.999))
        var low = 0.0
        var high = 20.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if 1 - (1 + mid) * exp(-mid) < target { low = mid } else { high = mid }
        }
        return low
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
    private static func handoffProgress(finalScale: CGFloat, iconPeak: CGFloat) -> CGFloat {
        guard finalScale < 1 else { return 1 }
        let progress = (1 - finalScale * iconPeak) / (1 - finalScale)
        return min(max(progress, 0.8), 0.995)
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

    /// How long to give a destination to appear before giving up on one, and how
    /// often to look. Spaced by a frame rather than by a turn of the run loop:
    /// the home dock is rendered by SwiftUI in response to the home state it
    /// belongs to, and several run-loop hops can pass inside a single frame,
    /// before it has been laid out at all. Costs nothing in the common case,
    /// where the icon is already on screen and the first look finds it.
    private static let targetAttempts = 3
    private static let targetRetryInterval: TimeInterval = 1.0 / 60

    private static let cornerAnimationKey = "lcMinimizeCorner"

    /// How long the page takes to go when Reduce Motion is on. Exactly the flight
    /// it stands in for, so turning the setting on changes how getting home
    /// *looks*, not how long it takes.
    private static var dissolveDuration: TimeInterval { flightDuration }

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

    /// Whether the grid is already on the move. Every flight asks it to go, and
    /// without this the second and third would each snap it back to its starting
    /// point while the first was still running.
    /// How many windows are in the air. The host view blacks out everything
    /// behind a visible window so a guest that does not fill the screen is
    /// letterboxed rather than fringed with white — but a window in flight is
    /// visible and small, and that backdrop would cover the springboard the
    /// flight is crossing, arriving in one frame because opacity reaches its
    /// final value as soon as the animation is committed. So it is held back for
    /// the length of the flight. Counted, not flagged: pressing home with several
    /// windows open puts several in the air at once, and the backdrop comes back
    /// only when the last of them has landed.
    private static var flightsInProgress = 0

    private static func beginFlight() {
        flightsInProgress += 1
        if flightsInProgress == 1 { setBackdropSuspended(true) }
    }

    private static func endFlight() {
        flightsInProgress = max(0, flightsInProgress - 1)
        if flightsInProgress == 0 { setBackdropSuspended(false) }
    }

    private static func setBackdropSuspended(_ suspended: Bool) {
        guard #available(iOS 16.0, *) else { return }
        MultitaskDockManager.shared.windowHostingView.backdropSuspended = suspended
    }

    private static var isGridSettling = false
    /// Identifies the move the grid is currently making, so the backstop that
    /// releases it cannot release a later one that has since claimed it.
    private static var gridMove = 0

    /// The operation each window is currently in the middle of, so a completion
    /// belonging to a superseded one cannot undo the newer. Opening and closing
    /// are the same view travelling in opposite directions and either can begin
    /// while the other is still finishing — minimizing a window that is still
    /// growing, or reopening one that is still on its way out.
    private static var operations: [ObjectIdentifier: Int] = [:]
    private static var lastOperation = 0

    private static func beginOperation(on view: UIView) -> Int {
        lastOperation &+= 1
        operations[ObjectIdentifier(view)] = lastOperation
        return lastOperation
    }

    private static func isCurrentOperation(_ token: Int, on view: UIView) -> Bool {
        operations[ObjectIdentifier(view)] == token
    }

    private static func endOperation(_ token: Int, on view: UIView) {
        if operations[ObjectIdentifier(view)] == token {
            operations.removeValue(forKey: ObjectIdentifier(view))
        }
    }

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

        let token = beginOperation(on: view)
        let finish = {
            // Something may have brought the window back while it was still on its
            // way out. A newer operation on the same view owns it now, and hiding
            // it here would take away a window the user has just asked for — as
            // would finishing after a restore that bypasses this file altogether,
            // which is what the alpha says. (`minimizeWindow`'s `if (!finished)
            // return` guarded the same case; a property animator finishes on
            // schedule regardless, so the state has to be the test.)
            guard isCurrentOperation(token, on: view), view.alpha < 0.5 else { return }
            endOperation(token, on: view)

            view.isHidden = true
            view.transform = .identity
            view.alpha = 1
            completion?()
        }

        if prefersDissolve {
            dissolve(view, completion: finish)
        } else {
            flyWhenTargetIsReady(view, in: container, toItemID: itemID,
                                 attemptsLeft: targetAttempts, completion: finish)
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
            flyWhenTargetIsReady(snapshot, in: window, toItemID: itemID,
                                 attemptsLeft: targetAttempts) {
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

    // MARK: - Opening

    /// The flight in reverse: a window grows out of the icon it belongs to, on the
    /// same spring, its corners unrolling from the icon's radius to the screen's.
    /// The window is left visible, untransformed and opaque.
    ///
    /// `sourceInWindow` overrides the icon lookup for a caller that knows where the
    /// window is coming from and it is not an icon — the switcher, where the card
    /// the user just pressed is the thing that should become the window.
    static func expand(
        _ view: UIView,
        fromItemID itemID: String?,
        sourceInWindow: CGRect? = nil,
        completion: (() -> Void)? = nil
    ) {
        guard let container = view.superview,
              view.bounds.width > 1, view.bounds.height > 1 else {
            view.isHidden = false
            view.alpha = 1
            completion?()
            return
        }

        view.layer.removeAllAnimations()
        view.transform = .identity
        view.isHidden = false

        let token = beginOperation(on: view)
        let finish = {
            // A window minimized while it was still opening belongs to that
            // newer operation; putting it back to full size here would undo it.
            guard isCurrentOperation(token, on: view) else { return }
            endOperation(token, on: view)

            view.transform = .identity
            view.alpha = 1
            completion?()
        }

        if prefersDissolve {
            view.alpha = 0
            let fade = UIViewPropertyAnimator(duration: dissolveDuration, curve: .easeInOut) {
                view.alpha = 1
            }
            fade.addCompletion { _ in finish() }
            fade.startAnimation()
            return
        }

        let full = view.frame
        let source = onScreenFrame(sourceInWindow, in: container)
            ?? itemID.flatMap { destination(forItemID: $0, in: container)?.frame }
            ?? screenCentreDestination(in: container).frame
        let scaleX = max(0.01, source.width / max(full.width, 1))
        let scaleY = max(0.01, source.height / max(full.height, 1))
        // The spring that has the window all but full size at `flightDuration` —
        // the opening's own definition of arriving, landed on the same clock the
        // closing one uses for its handoff, so the two read as one speed.
        let spring = spring(reaching: openCompleteProgress)
        let settling = spring.settlingDuration

        let originalRadius = view.layer.cornerRadius
        let originalMasksToBounds = view.layer.masksToBounds
        let originalCornerCurve = view.layer.cornerCurve
        view.layer.masksToBounds = true
        view.layer.cornerCurve = .continuous

        // Collapsed onto the icon to begin with, and released from there.
        view.transform = CGAffineTransform(
            translationX: source.midX - full.midX,
            y: source.midY - full.midY
        ).scaledBy(x: scaleX, y: scaleY)
        view.alpha = 0

        let screenRadius = displayCornerRadius()
        let startRadius = min(source.width * iconCornerRadiusRatio,
                              min(source.width, source.height) / 2) / scaleX
        let corner = spring.animation(keyPath: "cornerRadius")
        corner.fromValue = startRadius
        corner.toValue = screenRadius
        corner.duration = settling
        view.layer.cornerRadius = screenRadius
        view.layer.add(corner, forKey: cornerAnimationKey)

        zoomGridAway(on: spring, settling: settling, under: view, in: container)

        let flight = UIViewPropertyAnimator(duration: settling, timingParameters: spring.timing)
        flight.addAnimations { view.transform = .identity }
        flight.addCompletion { _ in
            view.layer.removeAnimation(forKey: cornerAnimationKey)
            view.layer.cornerRadius = originalRadius
            view.layer.masksToBounds = originalMasksToBounds
            view.layer.cornerCurve = originalCornerCurve
            endFlight()
            finish()
        }

        // The mirror of the closing cross-fade: the window is transparent while it
        // is still icon-sized, so the icon shows through where it is going to be,
        // and opaque by the time it has grown clear of it.
        let fade = UIViewPropertyAnimator(
            duration: max(0.05, flightDuration * (1 - fadeStartFraction)),
            curve: .easeOut
        ) {
            view.alpha = 1
        }

        beginFlight()
        flight.startAnimation()
        fade.startAnimation()
    }

    /// An icon-sized source around a point, for a caller that knows where a window
    /// is coming from but not how big the thing it came from was.
    static func sourceRect(around pointInWindow: CGPoint) -> CGRect {
        CGRect(x: pointInWindow.x - fallbackTargetSize / 2,
               y: pointInWindow.y - fallbackTargetSize / 2,
               width: fallbackTargetSize,
               height: fallbackTargetSize)
    }

    // MARK: - The flight

    /// Waits, briefly, for somewhere to fly to. Both possible destinations arrive
    /// a turn of the run loop late in their own way: the springboard is still
    /// behind a cover that has only just been dismissed, and the home dock is only
    /// laid out as the home state it belongs to takes effect. A few turns is the
    /// difference between landing on an icon and shrinking into the middle of the
    /// screen for want of waiting.
    private static func flyWhenTargetIsReady(
        _ view: UIView,
        in container: UIView,
        toItemID itemID: String,
        attemptsLeft: Int,
        completion: @escaping () -> Void
    ) {
        guard let destination = destination(forItemID: itemID, in: container) else {
            if attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + targetRetryInterval) {
                    flyWhenTargetIsReady(view, in: container, toItemID: itemID,
                                         attemptsLeft: attemptsLeft - 1, completion: completion)
                }
            } else {
                fly(view, in: container, to: screenCentreDestination(in: container),
                    itemID: itemID, completion: completion)
            }
            return
        }
        fly(view, in: container, to: destination, itemID: itemID, completion: completion)
    }

    private static func fly(
        _ view: UIView,
        in container: UIView,
        to destination: Destination,
        itemID: String,
        completion: @escaping () -> Void
    ) {
        let start = view.frame
        let target = destination.frame
        let scaleX = max(0.01, target.width / max(start.width, 1))
        let scaleY = max(0.01, target.height / max(start.height, 1))

        // The spring that puts the handoff at `flightDuration`, whatever that
        // handoff works out to be on this screen — which is what holds the speed
        // steady from an iPhone SE to an iPad in landscape, where the same window
        // has half again as far to travel.
        let handoff = handoffProgress(finalScale: scaleX, iconPeak: destination.iconPeak)
        let spring = spring(reaching: handoff)
        let settling = spring.settlingDuration

        let originalRadius = view.layer.cornerRadius
        let originalMasksToBounds = view.layer.masksToBounds
        let originalCornerCurve = view.layer.cornerCurve
        view.layer.masksToBounds = true
        view.layer.cornerCurve = .continuous

        // The corners round off on the same spring as the shape they belong to —
        // on any other curve they run ahead of or behind the shrink. The radius
        // renders through the transform, so the value that lands at the icon's is
        // the icon's divided by the scale the page shrinks by.
        let corner = spring.animation(keyPath: "cornerRadius")
        // Clamped to half the target's shorter side: the dock as a whole is a wide
        // pill, and an icon's proportion of its width would round the corners past
        // its own height.
        let landedRadius = min(target.width * iconCornerRadiusRatio,
                               min(target.width, target.height) / 2)
        let endRadius = landedRadius / scaleX
        corner.fromValue = originalRadius > 0 ? originalRadius : displayCornerRadius()
        corner.toValue = endRadius
        corner.duration = settling
        view.layer.cornerRadius = endRadius
        view.layer.add(corner, forKey: cornerAnimationKey)

        settleGrid(on: spring, settling: settling)

        let flight = UIViewPropertyAnimator(duration: settling, timingParameters: spring.timing)
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
            endFlight()
            completion()
        }

        // The cross-fade is its own animator so it can finish on the handoff
        // instead of trailing the spring's long asymptotic tail: the page is gone
        // the instant it matches the icon, not fading for a further quarter of a
        // second over the top of it.
        let fadeStart = flightDuration * fadeStartFraction
        let fade = UIViewPropertyAnimator(duration: flightDuration - fadeStart, curve: .easeIn) {
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
            timeout: settling + 0.2,
            // Runs on arrival and on giving up alike, so a flight that was
            // interrupted does not leave its watcher in the table.
            onFinish: { arrived in
                arrivalWatchers[itemID] = nil
                if arrived { answer(destination, itemID: itemID) }
            }
        )

        beginFlight()
        flight.startAnimation()
        fade.startAnimation(afterDelay: fadeStart)
    }

    // MARK: - The home screen's half of it

    /// Brings the grid forward as the page recedes, on the same spring, so the
    /// two halves of the move land together.
    private static func settleGrid(on spring: Spring, settling: TimeInterval) {
        guard let grid = LCSpringboardViewController.current?.viewIfLoaded,
              grid.window != nil, claimGrid() else { return }

        grid.transform = CGAffineTransform(scaleX: gridZoom, y: gridZoom)
        grid.alpha = gridStartAlpha

        let settle = UIViewPropertyAnimator(duration: settling, timingParameters: spring.timing)
        settle.addAnimations {
            grid.transform = .identity
            grid.alpha = 1
        }
        settle.addCompletion { _ in isGridSettling = false }
        settle.startAnimation()
        scheduleGridRelease(settling: settling)
    }

    /// Claims the grid for a move, and returns whether it was free to take.
    private static func claimGrid() -> Bool {
        guard !isGridSettling else { return false }
        isGridSettling = true
        gridMove &+= 1
        return true
    }

    /// A backstop for the grid flag. If the animation that should clear it is
    /// interrupted and never reports, the flag stays on and quietly disables the
    /// counter-move for the rest of the session — the kind of fault nobody
    /// notices except that the animation has felt flat for a week. Tied to the
    /// move that scheduled it, so a stale backstop cannot free a grid that a
    /// later move has since claimed.
    private static func scheduleGridRelease(settling: TimeInterval) {
        let move = gridMove
        DispatchQueue.main.asyncAfter(deadline: .now() + settling + 0.5) {
            if gridMove == move { isGridSettling = false }
        }
    }

    /// The grid's half of an opening: it draws back and dims as the window grows
    /// out of it, the same move `settleGrid` plays coming home, run the other way.
    ///
    /// Only when the window will cover the grid, because the grid has to be put
    /// back at the end — it is left zoomed otherwise, and a later minimize would
    /// start from the wrong place. Under a window that covers the screen that
    /// reset is unseen; under a smaller one it would be a visible snap, so a
    /// window that does not cover the grid leaves it alone.
    private static func zoomGridAway(on spring: Spring, settling: TimeInterval, under view: UIView, in container: UIView) {
        guard view.frame.union(container.bounds) == view.frame,
              let grid = LCSpringboardViewController.current?.viewIfLoaded,
              grid.window != nil, claimGrid() else { return }

        grid.transform = .identity
        grid.alpha = 1

        let zoom = UIViewPropertyAnimator(duration: settling, timingParameters: spring.timing)
        zoom.addAnimations {
            grid.transform = CGAffineTransform(scaleX: gridZoom, y: gridZoom)
            grid.alpha = gridStartAlpha
        }
        zoom.addCompletion { _ in
            // Behind the open window now, so putting it back is unseen — and it
            // has to be back before the window is ever minimized again.
            grid.transform = .identity
            grid.alpha = 1
            isGridSettling = false
        }
        zoom.startAnimation()
        scheduleGridRelease(settling: settling)
    }

    /// Whatever the window landed on answers it: the springboard icon bounces
    /// here, while the home dock's icon is asked to do its own — it is a SwiftUI
    /// view with no UIView of ours to transform.
    private static func answer(_ destination: Destination, itemID: String) {
        switch destination {
        case .springboardIcon:
            bounceIcon(itemID)
        case .dockIcon:
            NotificationCenter.default.post(name: .lcHomeDockIconDidTakeWindow, object: itemID)
        case .dockPill, .screenCentre:
            // Nothing there belongs to this window, so nothing answers for it.
            break
        }
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

    /// Where a window is going, and what should answer it when it gets there.
    private enum Destination {
        /// The item's own icon on the springboard, in front of the user now.
        case springboardIcon(CGRect)
        /// Its icon in the home dock — where a window goes when its springboard
        /// icon is on a page the user is not looking at. Flying to an icon they
        /// cannot see means flying off the side of the display, and scrolling the
        /// home screen to it means moving them somewhere they never asked to go.
        case dockIcon(CGRect)
        /// The dock itself, for a window that belongs there but has no icon in it:
        /// the dock shows the four most recent apps, and a fifth still went to the
        /// same place.
        case dockPill(CGRect)
        /// Nothing on screen to aim at: the middle, so it recedes rather than
        /// blinking out.
        case screenCentre(CGRect)

        var frame: CGRect {
            switch self {
            case .springboardIcon(let frame), .dockIcon(let frame),
                 .dockPill(let frame), .screenCentre(let frame):
                return frame
            }
        }

        /// Whether an icon swells to take the window. Only an icon can; the dock
        /// as a whole and the screen's middle have nothing to do it, and the
        /// handoff is sized against this.
        var iconPeak: CGFloat {
            switch self {
            case .springboardIcon, .dockIcon: return bounceScale
            case .dockPill, .screenCentre: return 1
            }
        }
    }

    /// Whether a window carrying this item would have to fall back to the dock:
    /// its own icon is not on the springboard page in front of the user. Asked
    /// before the home state flips, so the dock can be told to appear in place
    /// rather than springing in under an arriving window.
    static func willUseHomeDock(forItemID itemID: String) -> Bool {
        LCSpringboardViewController.current?.iconCell(forItemID: itemID) == nil
    }

    /// The best destination available right now, or nil if neither icon can be
    /// found yet — which is a reason to wait a moment, since the home dock only
    /// appears as the window leaves.
    private static func destination(forItemID itemID: String, in container: UIView) -> Destination? {
        guard let window = container.window else { return nil }

        // Same window, not merely some window: on iPad a second scene has a
        // springboard of its own, and `current` is whichever loaded last.
        if let cell = LCSpringboardViewController.current?.iconCell(forItemID: itemID),
           cell.window === window {
            let icon = cell.iconImageView
            let frame = icon.convert(icon.bounds, to: container)
            // Fully on screen, not just overlapping it. A grid still laid out for
            // the orientation the interface has just left reports icons half off
            // the edge, and those are not somewhere to send a window.
            if frame.width > 1, frame.height > 1, container.bounds.contains(frame) {
                return .springboardIcon(frame)
            }
        }

        if #available(iOS 16.0, *) {
            let dock = MultitaskDockManager.shared
            // Reported in window coordinates by whatever drew itself there.
            if let frame = onScreenFrame(dock.homeDockIconFrames[itemID], in: container) {
                return .dockIcon(frame)
            }
            if let frame = onScreenFrame(dock.homeDockPillFrame, in: container) {
                return .dockPill(frame)
            }
        }

        return nil
    }

    /// A frame reported in window coordinates, converted for `container` and
    /// confirmed to be somewhere the user can actually see.
    ///
    /// Required to be wholly on screen rather than merely overlapping it. These
    /// come from SwiftUI, whose global space is documented as the screen, and on
    /// an iPad in Split View or Stage Manager the window is not the screen — a
    /// frame measured in one and used in the other is offset by the window's own
    /// origin. Insisting it lands entirely within the container turns that into a
    /// fall through to the next destination rather than a window flying somewhere
    /// senseless.
    private static func onScreenFrame(_ inWindow: CGRect?, in container: UIView) -> CGRect? {
        guard let inWindow, inWindow.width > 1, inWindow.height > 1 else { return nil }
        let frame = container.convert(inWindow, from: nil)
        return container.bounds.contains(frame) ? frame : nil
    }

    private static func screenCentreDestination(in container: UIView) -> Destination {
        .screenCentre(CGRect(x: container.bounds.midX - fallbackTargetSize / 2,
                             y: container.bounds.midY - fallbackTargetSize / 2,
                             width: fallbackTargetSize,
                             height: fallbackTargetSize))
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
    /// Called exactly once either way — `true` when the window reached the icon,
    /// `false` when it gave up on it — so the caller can drop the watcher whatever
    /// the outcome rather than only on a landing.
    private var onFinish: ((Bool) -> Void)?

    init(view: UIView,
         finalScale: CGFloat,
         arrivalProgress: CGFloat,
         timeout: TimeInterval,
         onFinish: @escaping (Bool) -> Void) {
        self.view = view
        self.finalScale = finalScale
        self.arrivalProgress = arrivalProgress
        self.deadline = CACurrentMediaTime() + timeout
        self.onFinish = onFinish

        let link = CADisplayLink(target: self, selector: #selector(step))
        // Common modes: a flight started from a scrolling grid must still be
        // watched while that scroll is tracking.
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Stops watching without reporting — for a flight replaced by another one,
    /// where the replacement's own watcher is the one that matters now.
    func cancel() {
        stop()
        onFinish = nil
    }

    private func stop() {
        link?.invalidate()
        link = nil
    }

    private func finish(arrived: Bool) {
        let report = onFinish
        stop()
        onFinish = nil
        report?(arrived)
    }

    @objc private func step() {
        guard let presentation = view?.layer.presentation() else {
            // The view has gone, so nothing is going to arrive.
            if CACurrentMediaTime() >= deadline { finish(arrived: false) }
            return
        }

        let total = 1 - finalScale
        // A window that is not really shrinking has nowhere to arrive.
        guard total > 0.01 else { finish(arrived: false); return }

        let travelled = 1 - presentation.affineTransform().a
        if travelled / total >= arrivalProgress {
            finish(arrived: true)
        } else if CACurrentMediaTime() >= deadline {
            // Interrupted, or it never moved. Nothing landed on the icon, so
            // nothing should answer for it.
            finish(arrived: false)
        }
    }
}
