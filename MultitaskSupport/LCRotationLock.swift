//
//  LCRotationLock.swift
//  LiveContainer
//
//  One place that decides whether a guest's geometry may be re-derived, and a
//  small on-screen panel showing that decision and letting it be forced.
//

import UIKit

/// Whether guest geometry is currently allowed to change.
///
/// The multitask geometry paths all ask this before re-deriving a guest's frame
/// or orientation. It answers yes for two separate reasons that behave
/// identically once made:
///
///  - **Flat.** The phone is face-up, face-down, or not yet reporting. In that
///    state the device is not saying which way the screen is being read, so
///    anything derived from it is a guess. Deriving is suspended and whatever the
///    guest had is reasserted.
///  - **Manual.** Held on deliberately from the panel below.
///
/// Deliberately one predicate rather than two: a manual lock that took a
/// different path through the geometry code would be a second thing to get right,
/// and the point of it is to reproduce the automatic behaviour exactly.
@objc public final class LCRotationLock: NSObject {

    /// True while the phone is lying flat and cannot say how it is being read.
    @objc public static var isFlat: Bool {
        !UIDevice.current.orientation.isValidInterfaceOrientation
    }

    /// Forced on from the panel. Survives the phone being picked up.
    @objc public static var isManual: Bool = false {
        didSet {
            guard oldValue != isManual else { return }
            // Releasing a lock has to actively provoke a re-derivation. The paths
            // that would normally repair the geometry are driven by a bounds
            // change, and nothing about unlocking changes any bounds — so without
            // this the guest keeps the frozen shape until something else happens
            // to lay out.
            if !isManual { requestRelayout() }
        }
    }

    /// The single question every geometry guard asks.
    @objc public static var isLocked: Bool { isFlat || isManual }

    /// Why it is locked, for the panel.
    @objc public static var reason: String {
        if isManual && isFlat { return "MANUAL + FLAT" }
        if isManual { return "MANUAL" }
        if isFlat { return "FACE UP" }
        return "FREE"
    }

    /// How the phone is being held, in words rather than enum names.
    @objc public static var positionDescription: String {
        switch UIDevice.current.orientation {
        case .portrait:           return "VERTICAL"
        case .portraitUpsideDown: return "VERTICAL (upside down)"
        case .landscapeLeft:      return "HORIZONTAL (left)"
        case .landscapeRight:     return "HORIZONTAL (right)"
        case .faceUp:             return "FACE UP"
        case .faceDown:           return "FACE DOWN"
        default:                  return "UNKNOWN"
        }
    }

    private static func requestRelayout() {
        guard #available(iOS 16.0, *) else { return }
        DispatchQueue.main.async {
            let host = MultitaskDockManager.shared.windowHostingView
            host.setNeedsLayout()
            host.layoutIfNeeded()
            NotificationCenter.default.post(name: .multitaskBarVisibilityChanged, object: nil)
        }
    }
}

// MARK: - On-screen panel

/// A compact always-on-top readout of how the phone is being held, whether
/// rotation is locked, and a button to hold it locked by hand.
@objc public final class LCRotationLockOverlay: NSObject {

    @objc public static let shared = LCRotationLockOverlay()

    private var window: UIWindow?
    private var label: UILabel?
    private var button: UIButton?
    private var timer: Timer?

    @objc public func start() {
        guard window == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else {
            // No foreground scene yet. Retry rather than fail silently — a panel
            // that is simply absent looks the same as one reporting nothing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.start() }
            return
        }

        let win = LockPassthroughWindow(windowScene: scene)
        // Above the multitask overlay window, so a maximized guest cannot bury it.
        win.windowLevel = .alert + 100
        win.backgroundColor = .clear
        win.isHidden = false

        let panel = UIView()
        panel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        panel.layer.cornerRadius = 8
        panel.layer.borderWidth = 1
        panel.layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor

        let text = UILabel()
        text.numberOfLines = 0
        text.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        text.textColor = .white

        let toggle = UIButton(type: .system)
        toggle.titleLabel?.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        toggle.addTarget(self, action: #selector(toggleLock), for: .touchUpInside)
        toggle.layer.cornerRadius = 5
        toggle.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)

        let host = UIViewController()
        host.view.backgroundColor = .clear
        host.view.addSubview(panel)
        panel.addSubview(text)
        panel.addSubview(toggle)

        for v in [panel, text, toggle] { v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.leadingAnchor, constant: 6),
            panel.topAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.topAnchor, constant: 6),

            text.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            text.topAnchor.constraint(equalTo: panel.topAnchor, constant: 6),

            toggle.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            toggle.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 6),
            toggle.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -6),
        ])
        win.rootViewController = host

        window = win
        label = text
        button = toggle

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    @objc public func stop() {
        timer?.invalidate()
        timer = nil
        window?.isHidden = true
        window = nil
        label = nil
        button = nil
    }

    @objc private func toggleLock() {
        LCRotationLock.isManual.toggle()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        refresh()
    }

    private func refresh() {
        let locked = LCRotationLock.isLocked
        label?.text = """
        POSITION  \(LCRotationLock.positionDescription)
        ROTATION  \(locked ? "LOCKED" : "FREE")
        REASON    \(LCRotationLock.reason)
        """
        button?.setTitle(LCRotationLock.isManual ? "UNLOCK" : "LOCK", for: .normal)
        button?.backgroundColor = LCRotationLock.isManual
            ? UIColor.systemRed.withAlphaComponent(0.85)
            : UIColor.systemBlue.withAlphaComponent(0.85)
        button?.setTitleColor(.white, for: .normal)
        // Border tracks the effective state, so a lock held by the phone lying
        // flat reads the same at a glance as one held by hand.
        (button?.superview)?.layer.borderColor = locked
            ? UIColor.systemRed.withAlphaComponent(0.8).cgColor
            : UIColor.white.withAlphaComponent(0.25).cgColor
    }
}

/// Transparent to touches everywhere except the panel, so the app underneath
/// stays fully usable.
private final class LockPassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        return hit === rootViewController?.view ? nil : hit
    }
}
