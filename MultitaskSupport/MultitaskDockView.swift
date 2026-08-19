//
//  MultitaskDockView.swift
//  LiveContainer
//
//  Created by boa-z on 2025/6/28.
//

import Foundation
import SwiftUI
import UIKit
import Combine

extension NSNotification.Name {
    static let multitaskBarVisibilityChanged = NSNotification.Name("MultitaskBarVisibilityChanged")
    /// Posted when the rounded/flat bar design setting is toggled in Settings, so
    /// the visible bar can re-lay out live instead of waiting for the next layout.
    static let multitaskBarDesignChanged = NSNotification.Name("MultitaskBarDesignChanged")
    /// Posted by a guest window once its app is drawing its own content, which is
    /// the cue to drop the launch screen the window opened with. Object is the
    /// window's view. Name is duplicated as a literal in
    /// `DecoratedAppSceneViewController`.
    static let lcWindowContentDidArrive = NSNotification.Name("LCWindowContentDidArrive")
}

// MARK: - App Info Provider
class AppInfoProvider {
    
    static let shared = AppInfoProvider()
    
    private var infoCacheByUUID = [String: LCAppInfo]()
    private var infoCacheByName = [String: LCAppInfo]()
    private let cacheQueue = DispatchQueue(label: "com.livecontainer.appinfoprovider.cachequeue", attributes: .concurrent)
    
    private init() {}
    
    public func findAppInfo(appName: String, dataUUID: String) -> LCAppInfo? {
        if let appInfo = findAppInfoFromSharedModel(appName: appName, dataUUID: dataUUID) {
            return appInfo
        }
        if let appInfo = findAppInfo(byUUID: dataUUID) {
            return appInfo
        }
        return findAppInfo(byName: appName)
    }
    
    public func findAppInfo(byUUID dataUUID: String) -> LCAppInfo? {
        if let cachedInfo = cacheQueue.sync(execute: { infoCacheByUUID[dataUUID] }) {
            return cachedInfo
        }
        
        guard let appGroupPath = LCSharedUtils.appGroupPath()?.path else { return nil }
        
        let searchPaths = [
            "\(appGroupPath)/LiveContainer/Data/Application/\(dataUUID)/LCAppInfo.plist",
            "\(appGroupPath)/Containers/\(dataUUID)/LCAppInfo.plist",
            "\(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "")/Data/Application/\(dataUUID)/LCAppInfo.plist"
        ]
        
        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path),
               let appInfoDict = NSDictionary(contentsOfFile: path),
               let bundlePath = appInfoDict["bundlePath"] as? String,
               let appInfo = LCAppInfo(bundlePath: bundlePath) {
                
                cacheQueue.async(flags: .barrier) { self.infoCacheByUUID[dataUUID] = appInfo }
                return appInfo
            }
        }
        return nil
    }

    public func findAppInfo(byName appName: String) -> LCAppInfo? {
        if let cachedInfo = cacheQueue.sync(execute: { infoCacheByName[appName] }) {
            return cachedInfo
        }

        var searchPaths: [String] = []
        if let appGroupPath = LCSharedUtils.appGroupPath()?.path {
            searchPaths.append("\(appGroupPath)/LiveContainer/Applications")
        }
        if let docPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path {
            searchPaths.append("\(docPath)/Applications")
        }

        for appsPath in searchPaths {
            guard let appDirs = try? FileManager.default.contentsOfDirectory(atPath: appsPath) else { continue }
            
            for appDir in appDirs where appDir.hasSuffix(".app") {
                if let appInfo = LCAppInfo(bundlePath: "\(appsPath)/\(appDir)"), appInfo.displayName() == appName {
                    cacheQueue.async(flags: .barrier) { self.infoCacheByName[appName] = appInfo }
                    return appInfo
                }
            }
        }
        return nil
    }

    private func findAppInfoFromSharedModel(appName: String, dataUUID: String) -> LCAppInfo? {
        let allApps = DataManager.shared.model.apps + DataManager.shared.model.hiddenApps
        
        for appModel in allApps {
            if appModel.appInfo.containers.contains(where: { $0.folderName == dataUUID }) {
                return appModel.appInfo
            }
        }
        
        for appModel in allApps {
            if appModel.appInfo.displayName() == appName {
                return appModel.appInfo
            }
        }
        return nil
    }
    
    public func clearCache() {
        cacheQueue.async(flags: .barrier) {
            self.infoCacheByUUID.removeAll()
            self.infoCacheByName.removeAll()
        }
    }
}

// MARK: - App Model for Dock
@objc class DockAppModel: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    @objc let appName: String
    @objc let appUUID: String
    let appInfo: LCAppInfo?
    let view: UIView?
    
    /// Non-nil for built-in pages (e.g. "settings", "installer"); nil for guest apps
    let internalPageKind: String?
    
    var isInternalPage: Bool { internalPageKind != nil }
    
    /// The home-screen item this window belongs to, so minimizing it can find the
    /// icon to shrink into: a built-in page by its kind, a guest app by its
    /// bundle. Both are asked of `FlekHomeItem`, so neither can drift from the id
    /// the springboard files that icon under. Nil for a guest registered without
    /// app info, which has no icon that can be named.
    var springboardItemID: String? {
        if let kind = internalPageKind.flatMap(FlekDefaultAppKind.init(rawValue:)) {
            return FlekHomeItem.defaultApp(kind).id
        }
        guard let appInfo else { return nil }
        return FlekHomeItem.installedID(for: appInfo)
    }

    /// Asset catalog icon name for built-in pages
    var internalPageIconAssetName: String? {
        switch internalPageKind {
        case "settings": return "FlekIconSettings"
        case "installer": return "FlekIconInstaller"
        case "flekstore": return "FlekIconFlekStore"
        default: return nil
        }
    }
    
    @objc init(appName: String, appUUID: String, appInfo: LCAppInfo? = nil, view: UIView?) {
        self.appName = appName
        self.appUUID = appUUID
        self.appInfo = appInfo
        self.view = view
        self.internalPageKind = nil
        super.init()
    }
    
    init(appName: String, appUUID: String, view: UIView?, internalPageKind: String) {
        self.appName = appName
        self.appUUID = appUUID
        self.appInfo = nil
        self.view = view
        self.internalPageKind = internalPageKind
        super.init()
    }
}

// MARK: - MultitaskDockView Manager
@available(iOS 16.0, *)
@objc public class MultitaskDockManager: NSObject, ObservableObject {
    @objc public static let shared = MultitaskDockManager()
    
    @Published var apps: [DockAppModel] = []
    @Published var isVisible: Bool = false
    @Published var isSwitcherBarVisible: Bool = true
    @Published var frontmostAppUUID: String?
    @Published var isHomeState: Bool = false
    /// Where each running app's icon sits in the home dock, in window
    /// coordinates, keyed by its home-screen item id. Written by the icons
    /// themselves as they lay out, and read by the minimize animation when a
    /// window's own springboard icon is on a page the user is not looking at.
    /// Deliberately not `@Published`: it is written from a layout pass, and
    /// publishing it would invalidate the view that just reported it.
    var homeDockIconFrames: [String: CGRect] = [:]
    /// Where the home dock itself sits, in window coordinates — what a window
    /// aims at when it belongs in the dock but has no icon of its own there, the
    /// dock showing only the four most recent apps.
    var homeDockPillFrame: CGRect = .zero
    /// Set while a minimizing window is on its way to the dock, which makes the
    /// dock appear in place rather than springing in. A target still travelling
    /// into position is one the window cannot land on cleanly.
    var homeDockShouldSkipEntrance = false
    /// Identifies the trip to the dock that asked for the entrance to be skipped,
    /// so the reset belonging to an earlier one cannot clear a later one's — going
    /// home twice inside the reset's own delay would otherwise leave the second
    /// dock springing in under an arriving window.
    private var homeDockEntranceSkipToken = 0
    /// The launch screen each window opened with, until its guest has content of
    /// its own to show behind it.
    private var launchPlaceholders: [ObjectIdentifier: UIView] = [:]
    /// Windows whose guest has reported drawing content of its own. Kept apart
    /// from the placeholders so the report and the placeholder can arrive in
    /// either order without one being lost.
    private var windowsWithContent: Set<ObjectIdentifier> = []
    @Published var isAppSwitcherOpen: Bool = false
    /// The interface orientation the switcher overrode, restored when it closes.
    private var orientationBeforeSwitcher: UIInterfaceOrientation?
    @Published var isClosingAll: Bool = false
    /// Snapshot of the springboard (wallpaper + icons) captured when the switcher
    /// opens, shown blurred behind the cards — the app-switcher equivalent of
    /// Spotlight's blurred home background.
    @Published var springboardSnapshot: UIImage?
    /// Published mirror of `isBarLandscape` so the SwiftUI bar content can react
    /// to rotation (its own local geometry is always a horizontal strip and
    /// can't reveal orientation).
    @Published var isLandscapeBar: Bool = false

    /// The screen the switcher overlay sizes its cards against.
    ///
    /// Published rather than read from `UIScreen` where it is needed. A plain read
    /// is not something SwiftUI can depend on, so nothing re-ran the overlay's body
    /// when the device turned: the cards kept the width and height the previous
    /// orientation gave them, which on iPad left a landscape-shaped card sitting in
    /// a portrait window, clipped and off-centre. iPhone turns the window portrait
    /// before the switcher opens and holds it, so this never changes there.
    @Published private(set) var switcherScreenSize: CGSize = UIScreen.main.bounds.size

    /// Points the overlay at the window's current shape: the box it is laid out in,
    /// and the size its cards measure themselves against.
    ///
    /// Both, because either alone leaves the layout wrong. The published size fixes
    /// the card metrics; the frame fixes the space they are arranged in. The hosting
    /// view is parented straight to the window and never becomes a child view
    /// controller, so nothing tells it the window turned — autoresizing is supposed
    /// to carry it, and when it does not the column is laid out against the old
    /// height and runs off the bottom of the new one.
    ///
    /// Deliberately NOT sampled while the turn is in progress.
    ///
    /// Taken as the turn begins and animated over it, so the overlay travels with the
    /// rotation rather than waiting for it and then jumping.
    ///
    /// Measuring this early was once ruinous: it caught the scroll view mid-turn at a
    /// viewport 1698pt wide inside an 820pt window. That was the backdrop, which
    /// filled rather than fitted and dragged the whole stack out with it; now that it
    /// is pinned to this very size, an early measurement has nothing left to distort.
    /// The later samples remain as insurance for a window that is slow to settle —
    /// they cost nothing when the size already matches.
    ///
    /// - Parameter animated: false when opening, where there is no turn to follow and
    ///   the overlay is about to be built from the result.
    func refreshSwitcherScreenSize(animated: Bool = true) {
        let apply = { [weak self] in
            guard let self else { return }
            let overlay = self.switcherOverlayController?.view
            guard let window = overlay?.window ?? self.keyWindow else { return }
            let bounds = window.bounds
            guard bounds.width > 0, bounds.height > 0 else { return }

            if let overlay, overlay.frame != bounds { overlay.frame = bounds }
            guard self.switcherScreenSize != bounds.size else { return }

            // Roughly the system's own rotation, so the cards resize and re-centre
            // across the same beat the window turns on instead of after it.
            if animated {
                withAnimation(.easeInOut(duration: Self.rotationDuration)) {
                    self.switcherScreenSize = bounds.size
                }
            } else {
                self.switcherScreenSize = bounds.size
            }
        }
        apply()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: apply)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: apply)
    }

    /// How long the system takes to turn the interface.
    static let rotationDuration: TimeInterval = 0.35

    /// Whether the bar's and the switcher's controls tap back when pressed.
    /// Off is a deliberate choice — the buttons sit under the thumb during any
    /// app switch, and their feedback is the most repeated in the app — so it
    /// lives in Settings ▸ Personalization rather than following the system's
    /// global haptics setting alone.
    static let buttonHapticsKey = "LCMultitaskButtonHaptics"

    /// The controls' one and only feedback: the softest impact iOS offers, so a
    /// row of buttons pressed dozens of times a session stays unobtrusive.
    /// Silent when the user has switched it off.
    static func buttonHaptic() {
        let defaults = LCUtils.appGroupUserDefault
        let enabled = defaults.object(forKey: buttonHapticsKey) as? Bool ?? true
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    /// Persisted user preference for which multitask control to show when an app
    /// is opened: the switcher bar (false) or the floating button (true). The
    /// switcher overlay toggles this; it takes effect the next time an app opens.
    static let preferFloatingButtonKey = "LCMultitaskPreferFloatingButton"
    @Published var prefersFloatingButton: Bool =
        LCUtils.appGroupUserDefault.bool(forKey: MultitaskDockManager.preferFloatingButtonKey)

    /// Update and persist the control preference. Does not change what's on
    /// screen right now — it is applied when an app is next opened.
    func setPrefersFloatingButton(_ value: Bool) {
        prefersFloatingButton = value
        LCUtils.appGroupUserDefault.set(value, forKey: MultitaskDockManager.preferFloatingButtonKey)
    }

    var appSnapshotViews: [String: UIView] = [:]
    /// Each snapshot's size at capture time. A card is always portrait, but an app
    /// captured in landscape is a landscape image — without its original shape the
    /// card can only stretch it to fit.
    var appSnapshotSizes: [String: CGSize] = [:]
    /// The quarter-turn each capture needs to sit upright in a portrait card, in
    /// radians. Shared by both card paths so a guest app and an internal page
    /// captured side by side are turned the same way.
    var appSnapshotRotations: [String: CGFloat] = [:]
    /// Genuinely frozen captures, preferred over `appSnapshotViews` when available.
    ///
    /// `resizableSnapshotView` does not freeze a view that hosts a guest process's
    /// remote layer — it returns a replicant that keeps mirroring the live layer. So
    /// once the switcher rotates the interface to portrait the guest re-lays out and
    /// the card's content silently changes underneath whatever size we laid it out
    /// against. An image captured while the app is still on screen cannot drift.
    var appSnapshotImages: [String: UIImage] = [:]
    var internalPageControllers: [String: UIHostingController<AnyView>] = [:]

    @objc public var windowHostingView = VirtualWindowsHostView()
    /// Watches the window's safe area so the bar re-lays out when it changes.
    private let safeAreaSentinel = SafeAreaSentinelView()
    internal var hostingController: UIHostingController<AnyView>?
    private var switcherOverlayController: UIHostingController<AnyView>?
    /// Full-window host for the switcher bar that limits touches to the bar's
    /// visible shape so its transparent corners/overhang pass taps to the content.
    private var barContainer: BarPassthroughContainer?
    /// The window the bar, the floating button and the switcher overlay live in.
    ///
    /// They used to be plain subviews of the app's own window — which is exactly
    /// where UIKit puts a modal presentation. A sheet, a full-screen cover, an
    /// alert or a document picker is inserted above whatever the window already
    /// held, so the installer's sources sheet, a settings sheet or an error alert
    /// raised over a guest window all buried the bar and left no way out of the
    /// app but the sheet's own dismiss. A presentation cannot escape the window of
    /// the controller presenting it, so one window higher is enough to be out of
    /// reach of all of them at once.
    private var overlayWindow: MultitaskOverlayWindow?
    private var navAssistButton: UIView?
    private var navAssistChevron: UIImageView?
    private var isNavAssistStashed: Bool = false

    /// One of the four sides. Which frame it is named in depends on where it is
    /// used: the layout's own coordinates, or the viewer's — what the user sees
    /// once the phone has been turned. `viewerRotationSteps` converts between them,
    /// and both the switcher bar and the floating button go through it.
    private enum ScreenEdge { case left, right, top, bottom }

    /// Where the floating button lives, held in the VIEWER's frame: which side of
    /// what the user is looking at it is parked on, and how far along that side it
    /// sits as a fraction of the side's usable travel (down the viewer's left and
    /// right sides from the top; across the viewer's top and bottom from the left).
    ///
    /// The viewer's frame, because that is the one the user is describing when they
    /// say the button was "on the right". Which layout edge that turns out to be
    /// depends on whether the interface turns with the phone:
    ///
    ///  - Interface rotates with the device — the layout's right edge already *is*
    ///    the viewer's right, and the button stays on it.
    ///  - Interface stays put while the phone turns (a portrait-locked host with a
    ///    guest app rotating inside it) — the viewer's right is now the layout's top
    ///    or bottom, depending on which way the phone was turned, and the button has
    ///    to move to that edge to stay where the user left it.
    ///
    /// `viewerRotationSteps` is the difference between those two worlds, and is 0
    /// in the first. `currentScreenPlacement()` resolves the stored position into
    /// the layout edge and offset to draw at; `rememberScreenPlacement(edge:fraction:)`
    /// converts a drag's layout-space landing spot back.
    private var navAssistViewEdge: ScreenEdge = .right
    private var navAssistAlongFraction: CGFloat = 0.5

    /// Last device orientation worth acting on, as quarter-turns. `UIDevice` reports
    /// face-up and face-down as orientations of their own; a phone laid flat on a
    /// table must not read as "portrait" and swing the button across the screen.
    /// Nil until the device has reported a real one.
    private var lastKnownDeviceSteps: Int?
    /// True while a finger is actually moving the button, so the geometry callbacks
    /// that re-place it on a resize don't pull it out from under that finger.
    ///
    /// Asked of the gesture rather than latched by it: a latch set on `.began` is
    /// never cleared if the button is torn down mid-drag (the switcher bar coming
    /// back, the dock hiding), and a stuck latch would silently stop every later
    /// re-placement. A recogniser that has gone away answers false by construction.
    private var isNavAssistDragging: Bool {
        navAssistButton?.gestureRecognizers?.contains {
            $0 is UIPanGestureRecognizer && ($0.state == .began || $0.state == .changed)
        } ?? false
    }

    // Backward compatibility — always false since collapsed dock concept was removed
    @objc public var isCollapsed: Bool { return false }
    
    /// ObjC-accessible flag for whether the switcher bar is currently shown
    @objc public var barVisible: Bool { return isSwitcherBarVisible }

    /// Live read of the LCMultitaskBarLedgeAmount setting: how rounded the bar's
    /// concave top corners are, as a fraction 0 (flat, the original short bar) …
    /// 1 (full device-radius rounded corners). Migrates from the old on/off
    /// boolean `LCMultitaskBarLedge` (on → 1, off → 0) until the slider is used.
    /// With neither key set, defaults to `Self.barLedgeAmountDefault`.
    /// Read live here but only applied via `captureBarDesign()` as the bar
    /// (re)lays out, so changing it in Settings never resizes the bar under the
    /// user's finger.
    private var barLedgeAmountSetting: CGFloat {
        let d = LCUtils.appGroupUserDefault
        if let stored = d.object(forKey: "LCMultitaskBarLedgeAmount") as? NSNumber {
            return max(0, min(1, CGFloat(stored.doubleValue) / 100.0))
        }
        if let legacyOn = d.object(forKey: "LCMultitaskBarLedge") as? Bool {
            return legacyOn ? 1 : 0
        }
        return Self.barLedgeAmountDefault
    }

    /// Default bar rounding when the user has never touched the slider — must
    /// match the `LCMultitaskBarLedgeAmount` @AppStorage default in settings.
    private static let barLedgeAmountDefault: CGFloat = 0.6

    /// The design actually in effect on the visible bar. Captured from the setting
    /// only when the bar (re)appears via `captureBarDesign()` — never mid-session —
    /// so toggling the setting while the settings page (whose own toggle sits over
    /// this same bar) is open never changes anything under the user's finger. The
    /// new design applies the next time the bar is laid out (app switch, rotation,
    /// or re-show).
    @Published private(set) var barLedgeActive: Bool = true

    /// How rounded the bar's concave corners actually are on the visible bar,
    /// 0 (flat) … 1 (full `barCornerRadiusActive`). Captured from the slider
    /// setting; published so moving the slider re-renders the bar live.
    @Published private(set) var barLedgeAmountActive: CGFloat = 1

    /// The concave corner radius actually in effect on the visible bar, captured
    /// from the user's slider setting (falling back to the device screen radius).
    /// Published so changing the slider re-renders the bar live.
    @Published private(set) var barCornerRadiusActive: CGFloat = 39

    /// Re-reads the design settings (rounded/flat + corner radius) into the
    /// published state; called as the bar is laid out and when the settings change.
    func captureBarDesign() {
        let amount = barLedgeAmountSetting
        if barLedgeAmountActive != amount { barLedgeAmountActive = amount }
        // Any rounding at all uses the concave-cornered hit path; only a fully
        // flat bar (0) uses the plain flat-top hit path.
        let active = amount > 0
        if barLedgeActive != active { barLedgeActive = active }
        let r = barCornerRadiusSetting
        if barCornerRadiusActive != r { barCornerRadiusActive = r }
    }

    /// Bar strip height. Both designs use the same tall strip so the buttons and
    /// the reserved content sit in exactly the same place: the rounded design
    /// carves concave corners from the top, while the flat design just draws its
    /// fill in the lower flat-solid region (square top). Only the corners differ.
    var effectiveBarHeight: CGFloat {
        // The bar's visible strip is measured *inward* from the screen's corner
        // radius (`effectiveBarHeight - cornerRadius + bottom inset`), so a shallower
        // corner yields a thicker bar from the same constant. iPad's corners are about
        // a third of an iPhone's, which made both the bar and the switcher's chin
        // noticeably taller there; a smaller constant brings the visible strip back in
        // line with iPhone's.
        UIDevice.current.userInterfaceIdiom == .pad
            ? Constants.barHeightWithLedgePad
            : Constants.barHeightWithLedge
    }

    /// The device's physical screen corner radius (private UIScreen value) so the
    /// bar's concave corners match the phone's rounded screen corners. Falls back
    /// to a sensible default on devices that report none.
    var deviceScreenCornerRadius: CGFloat {
        let r = (UIScreen.main.value(forKey: "_displayCornerRadius") as? CGFloat) ?? 0
        return r > 0 ? r : 39
    }

    /// Resolved concave corner radius from the user setting: the stored slider
    /// value when set, otherwise the device screen radius (the default "match the
    /// phone's corners"). Read via `captureBarDesign()` into `barCornerRadiusActive`.
    private var barCornerRadiusSetting: CGFloat {
        // The corner-radius slider is hidden for now, so always match the device
        // screen radius and IGNORE any previously-stored value. A value written
        // while the slider was enabled persists across reinstalls (but is absent on
        // a clean install), so reading it here made the bar's corners the wrong size
        // only after an update/relaunch — the "too tall after reinstall" bug.
        // Re-enable the stored read below when the slider is brought back.
        return deviceScreenCornerRadius
        // let v = LCUtils.appGroupUserDefault.double(forKey: "LCMultitaskBarCornerRadius")
        // return v > 0 ? CGFloat(v) : deviceScreenCornerRadius
    }

    /// The strip the bar occupies, as insets on whichever edge it currently sits
    /// on — zero when no bar is up. Guest windows inset their maximized frame by
    /// this so their content sits flush against the bar wherever it is, rather than
    /// assuming a bottom-or-right edge derived from the interface orientation, which
    /// is not the same question once the layout and the device part ways.
    @objc public var barReservedInsets: UIEdgeInsets {
        guard isSwitcherBarVisible else { return .zero }
        let thickness = barReservedThickness
        switch barLayoutEdge {
        case .bottom: return UIEdgeInsets(top: 0, left: 0, bottom: thickness, right: 0)
        case .top:    return UIEdgeInsets(top: thickness, left: 0, bottom: 0, right: 0)
        case .left:   return UIEdgeInsets(top: 0, left: thickness, bottom: 0, right: 0)
        case .right:  return UIEdgeInsets(top: 0, left: 0, bottom: 0, right: thickness)
        }
    }

    /// The exact on-screen thickness of the switcher bar strip on its short edge
    /// (matches `updateDockFrame`). App windows reserve this so their content
    /// sits flush against the bar with no background gap showing through.
    @objc public var barReservedThickness: CGFloat {
        // Reserve down to the bar's visible flat top so the app sits flush against
        // it. The tall rounded design's concave corners rise `deviceScreenCornerRadius`
        // above that flat top and overlay the app's bottom corners (the nesting
        // look), so they must not be reserved. Deriving the flat top from the real
        // corner radius keeps the app flush on every device — the old fixed base
        // height only lined up on phones whose corner radius matched the assumed
        // value and left a thin gap on the rest.
        // Both designs and both orientations share the same flat-top line, so reserve
        // down to it (the concave corners / square top sit above it and overlay
        // nothing that needs reserving). Landscape uses the identical value now that
        // its bar is the same shaped strip as portrait.
        return barFlatRegion
    }

    /// Reserves (or clears) space for the switcher bar on an internal page,
    /// on the axis where the bar actually lives — the bottom edge in portrait,
    /// the right edge in landscape. Reserving the bottom in landscape (where the
    /// bar is on the right) left a stale inset that pushed bottom content up and
    /// broke the hide-to-bottom-edge behaviour.
    func applyBarInset(to controller: UIHostingController<AnyView>, reserved: Bool) {
        // Reserve the bar's *actual* solid region, minus whatever the device already
        // insets on that edge — the page's safe area covers that part already.
        //
        // This used to reserve a flat `Constants.barHeight` (25pt) against a bar whose
        // solid region is more than twice that. On a notched phone the home-indicator
        // inset happened to make up the difference, so it looked right; a device with
        // a home button has no such inset, and the bar covered the page's bottom
        // controls.
        let insets = safeAreaInsets
        // Cleared on every edge first: the bar moves between them, and a reservation
        // left behind on the edge it came from would push content off the other side.
        var reserve = UIEdgeInsets.zero
        if reserved {
            switch barLayoutEdge {
            case .bottom: reserve.bottom = max(barFlatRegion - insets.bottom, 0)
            case .top:    reserve.top    = max(barFlatRegion - insets.top, 0)
            case .right:  reserve.right  = max(barFlatRegion - insets.right, 0)
            case .left:   reserve.left   = max(barFlatRegion - insets.left, 0)
            }
        }
        controller.additionalSafeAreaInsets = reserve
    }

    public struct Constants {
        // MARK: - Switcher Bar Layout
        static let barHeight: CGFloat = 25.0
        /// Taller bar strip used when the rounded ledge (concave corners) is on.
        static let barHeightWithLedge: CGFloat = 80.0
        /// iPad equivalent of `barHeightWithLedge`. Lower because iPad's shallow screen
        /// corners would otherwise turn the same constant into a much thicker strip.
        static let barHeightWithLedgePad: CGFloat = 58.0
        static let barIconSize: CGFloat = 40.0
        static let barButtonSize: CGFloat = 40.0
        /// The switcher's Close all capsule, and the width the bar's app menu
        /// starts from — so the two read as the same control in both states.
        static let barMenuBaseWidth: CGFloat = 112.0
        /// As wide as the app menu may grow to fit a long name before the name
        /// itself has to give way. Past this the row starts to crowd the side
        /// buttons on a narrow phone, and the capsule stops looking like the one
        /// Close all occupies.
        static let barMenuMaxWidth: CGFloat = 140.0
        /// The app menu's internal layout, shared by the label and the width
        /// measurement that sizes its capsule — they have to agree or the name is
        /// measured against the wrong room.
        static let barMenuHPadding: CGFloat = 10.0
        static let barMenuSpacing: CGFloat = 4.0
        static let barMenuIconSize: CGFloat = 24.0
        static let barMenuChevronWidth: CGFloat = 12.0
        /// Clearance kept either side of the row so it never runs to the bezel.
        static let barRowMargin: CGFloat = 16.0
        /// The row is drawn at `barButtonSize` and scaled up by this on screen.
        static let barContentScale: CGFloat = 1.1
        static let barSpacing: CGFloat = 10.0
        static let barHPadding: CGFloat = 12.0
        static let barVPadding: CGFloat = 4.0
        static let barCornerRadius: CGFloat = 26.0
        static let barBottomMargin: CGFloat = 16.0
        
        // MARK: - Navigation Assist
        static let navAssistSize: CGFloat = 65.0
        static let navAssistMargin: CGFloat = 8.0
        
        // MARK: - Animation
        static let standardAnimationDuration: TimeInterval = 0.3
        static let longAnimationDuration: TimeInterval = 0.4
        static let barSlideDuration: TimeInterval = 0.2  // bar slide up/down (snappy)
        static let shortAnimationDuration1: TimeInterval = 0.15
        static let shortAnimationDuration2: TimeInterval = 0.1
        
        static let standardSpringDamping: CGFloat = 0.8
        static let showHideSpringDamping: CGFloat = 0.7
        static let standardSpringVelocity: CGFloat = 0.3
        static let showHideSpringVelocity: CGFloat = 0.5
        
        static let initialScale: CGFloat = 0.8
        static let bringToFrontScale: CGFloat = 1.02
        /// How far a home dock icon swells as it takes a minimizing window. Kept
        /// equal to the springboard icon's own bounce, so a window lands the same
        /// way wherever it ends up.
        static let homeDockIconBounceScale: CGFloat = 1.16
    }

    /// The app's own window — the one the springboard, the guest windows and the
    /// built-in pages live in.
    ///
    /// `connectedScenes` is an
    /// *unordered* Set and multi-scene support is enabled, so after an in-place app
    /// update iOS can restore a stale/background scene from the previous launch.
    /// Picking `connectedScenes.first`/`windows.first` could then return nil (→ the
    /// bar container is never added, so the bar never shows) or a not-yet-ready
    /// window whose `safeAreaInsets` are still zero (→ the bar is sized without the
    /// home-indicator inset — the "weird sizing"). A clean install has only one
    /// fresh scene, which is why the bug never appears there. Resolve deterministically
    /// by preferring the foreground-active scene's key window, then falling back.
    ///
    /// Our own overlay window is never a candidate: it is never made key, but the
    /// fallbacks below would happily settle on it, and everything that resolves the
    /// key window here wants the app's content — its safe area, its root view
    /// controller, its orientation.
    public var keyWindow: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .sorted { Self.sceneActivationRank($0) < Self.sceneActivationRank($1) }
        for scene in scenes {
            if let key = scene.windows.first(where: { $0.isKeyWindow && !($0 is MultitaskOverlayWindow) }) {
                return key
            }
        }
        for scene in scenes {
            let candidates = scene.windows.filter { !($0 is MultitaskOverlayWindow) }
            if let visible = candidates.first(where: { !$0.isHidden }) ?? candidates.first {
                return visible
            }
        }
        return nil
    }

    /// Ranks scenes so the foreground-active one wins over restored/background
    /// scenes left over from a previous launch (lower is preferred).
    private static func sceneActivationRank(_ scene: UIWindowScene) -> Int {
        switch scene.activationState {
        case .foregroundActive:   return 0
        case .foregroundInactive: return 1
        case .background:         return 2
        default:                  return 3
        }
    }

    public var safeAreaInsets: UIEdgeInsets {
        keyWindow?.safeAreaInsets ?? .zero
    }

    /// A cached copy for SwiftUI bodies to read.
    ///
    /// `safeAreaInsets` resolves `keyWindow`, which enumerates every connected scene,
    /// allocates, sorts them and then scans their windows. That is fine once per
    /// layout but ruinous inside a view body, where it runs per card per frame — it
    /// showed up as the switcher carousel stuttering and dropping touches. Refreshed
    /// wherever the real insets can change.
    @Published private(set) var cachedSafeAreaInsets: UIEdgeInsets = .zero

    func refreshCachedSafeAreaInsets() {
        let current = safeAreaInsets
        if cachedSafeAreaInsets != current { cachedSafeAreaInsets = current }
        refreshCachedWindowShortEdge()
    }

    /// The window's shorter side — the one the bar's row has to fit across. The
    /// window, not the screen: on iPad the app can be handed a fraction of the
    /// display in Split View or Slide Over, and `UIScreen` would still report the
    /// whole panel.
    @Published private(set) var cachedWindowShortEdge: CGFloat =
        min(UIScreen.main.bounds.width, UIScreen.main.bounds.height)

    func refreshCachedWindowShortEdge() {
        guard let bounds = keyWindow?.bounds, bounds.width > 0, bounds.height > 0 else { return }
        let edge = min(bounds.width, bounds.height)
        if cachedWindowShortEdge != edge { cachedWindowShortEdge = edge }
    }

    /// Room the row's middle capsule may occupy, after the two side buttons, the
    /// gaps and the side padding have taken theirs.
    ///
    /// The window, not the screen: Display Zoom drops an iPhone to 320pt and an
    /// iPad Slide Over window is narrower still, and nothing else stops the row
    /// running past the bezel there. Everything in the row is scaled up by
    /// `barContentScale` on screen, so the budget is divided back down by it.
    private var barMenuBudget: CGFloat {
        let sides = Constants.barButtonSize * 2
            + Constants.barSpacing * 2
            + Constants.barHPadding * 2
        return (cachedWindowShortEdge - Constants.barRowMargin * 2)
            / Constants.barContentScale - sides
    }

    /// The switcher's Close all capsule: one fixed size, whatever is on screen.
    public var barCloseAllWidth: CGFloat {
        min(Constants.barMenuBaseWidth, barMenuBudget)
    }

    /// The bar's app menu capsule, sized to the app it is naming.
    ///
    /// It starts at Close all's width and grows with a longer name, up to
    /// `barMenuMaxWidth`. A name too long even for that doesn't widen it further —
    /// the label shrinks inside the capsule instead (see `FrontmostAppIconLabel`),
    /// which keeps the capsule recognisably the same control as the one the
    /// switcher puts in its place.
    public var barMenuWidth: CGFloat {
        let name = frontmostAppName()
        let textWidth = (name as NSString).size(withAttributes: [
            .font: UIFont.systemFont(ofSize: 14, weight: .medium)
        ]).width
        // Padding + icon + gap + name + gap + chevron + padding, matching the
        // label's own layout.
        let content = Constants.barMenuHPadding * 2
            + Constants.barMenuIconSize
            + Constants.barMenuSpacing * 2
            + ceil(textWidth)
            + Constants.barMenuChevronWidth
        let ideal = min(max(content, Constants.barMenuBaseWidth), Constants.barMenuMaxWidth)
        return min(ideal, barMenuBudget)
    }

    /// The visible solid strip of the bar (below the concave corners). Floored to
    /// the button height so the buttons are always covered: portrait gets button
    /// room from its ~34pt home-indicator inset, but landscape has none — and with a
    /// large device corner radius (~55pt) the natural region (effectiveBarHeight -
    /// cornerRadius + inset) fell short of the 44pt buttons. Portrait's larger
    /// natural value still wins, so it's unaffected.
    public var barFlatRegion: CGFloat {
        let buttonRoom = Constants.barButtonSize * Constants.barContentScale + 14   // buttons + margin
        let base = max(effectiveBarHeight - barCornerRadiusActive, 0) + safeAreaInsets.bottom
        return max(base, buttonRoom)
    }

    // MARK: - Bar Edge / Orientation

    /// The space the bar is laid out in: the pass-through container that holds it,
    /// which tracks the overlay host it was added to.
    ///
    /// Not `UIScreen.main.bounds`. That describes the display, and the two part
    /// company whenever the overlay host is not turned the same way as the device —
    /// at which point a bar positioned by screen numbers lands wherever those
    /// numbers happen to fall in the host's own coordinates, which is nowhere in
    /// particular. Falls back outward through the hierarchy, and only reaches the
    /// screen when the bar has no home yet.
    private var barLayoutBounds: CGRect {
        let candidates = [
            barContainer?.bounds,
            barContainer?.superview?.bounds,
            hostingController?.view.superview?.bounds,
            keyWindow?.bounds,
        ]
        for case let bounds? in candidates where bounds.width > 0 && bounds.height > 0 {
            return bounds
        }
        return UIScreen.main.bounds
    }

    /// The bar's space as the user sees it — the layout's own rectangle, turned if
    /// the layout is not the way up the viewer is.
    private var barViewerSize: CGSize {
        let bounds = barLayoutBounds
        return viewerRotationSteps % 2 == 0
            ? bounds.size
            : CGSize(width: bounds.height, height: bounds.width)
    }

    /// The side of the *user's view* the bar belongs on: its bottom when the view is
    /// upright, its right when the view is on its side. This is the rule stated in
    /// the terms the user sees it in, and everything else is derived from it.
    private var barViewerEdge: ScreenEdge {
        // iPad keeps the bar along the bottom in both orientations. Moving it to the
        // edge is an iPhone accommodation — there a bottom bar in landscape would eat
        // most of the little height available — but iPad has the width for it, and
        // rotating the strip stood the app names on their side.
        if UIDevice.current.userInterfaceIdiom == .pad { return .bottom }
        let size = barViewerSize
        return size.width > size.height ? .right : .bottom
    }

    /// The layout edge that currently *is* `barViewerEdge`.
    ///
    /// The two are the same edge whenever the layout turns with the phone. When it
    /// does not — a host that stays put while the device turns — the side the user
    /// sees as the right of the screen is the layout's top or bottom, depending on
    /// which way the phone was turned, and the bar has to be drawn along that edge
    /// to appear where the rule says it should be.
    private var barLayoutEdge: ScreenEdge {
        rotateEdge(barViewerEdge, by: -viewerRotationSteps)
    }

    /// Whether the bar is laid out as a vertical strip, i.e. it sits on a left or
    /// right *layout* edge. Drives the -90° turn of the strip, the edge the internal
    /// pages reserve, and the bar content's own edge margins.
    private var isBarLandscape: Bool {
        let edge = barLayoutEdge
        return edge == .left || edge == .right
    }

    /// The resting transform of the bar's hosting view: the turn that lays the
    /// strip along its layout edge with its concave top facing into the screen.
    ///
    /// The strip is always built the same way — long axis horizontal, ledge along
    /// its own top — so identity puts it on the bottom edge and each quarter-turn
    /// walks it round to the next one. Facing the interior is what makes the bar
    /// read the same to the user on every edge: the content leans into the screen,
    /// exactly as the landscape bar has always done.
    private var barBaseTransform: CGAffineTransform {
        switch barLayoutEdge {
        case .bottom: return .identity
        case .right:  return CGAffineTransform(rotationAngle: -.pi / 2)
        case .left:   return CGAffineTransform(rotationAngle: .pi / 2)
        case .top:    return CGAffineTransform(rotationAngle: .pi)
        }
    }

    /// The transform used while the bar is hidden/off-screen. The slide offset
    /// is applied in the bar's *local* space (before rotation), so a local
    /// downward slide becomes an off-bottom slide in portrait and an off-right
    /// slide in landscape — the bar always exits through its own short edge.
    private func barHiddenTransform(offset: CGFloat = 50) -> CGAffineTransform {
        CGAffineTransform(translationX: 0, y: offset).concatenating(barBaseTransform)
    }

    // MARK: - Bar Width Calculation
    private func barWidth() -> CGFloat {
        // Side buttons: hide + home
        let sideButtonsWidth = Constants.barButtonSize * 2 + Constants.barSpacing * 2
        
        // Menu label: a fixed capsule now, whatever the app is called — the name
        // truncates inside it rather than stretching it.
        return Constants.barHPadding + sideButtonsWidth + barMenuWidth + Constants.barHPadding
    }
    
    private func frontmostAppName() -> String {
        if let uuid = frontmostAppUUID, let app = apps.first(where: { $0.appUUID == uuid }) {
            return app.appName
        }
        return apps.last?.appName ?? "App"
    }
    
    override init() {
        super.init()
        // Every launch starts with the switcher bar as the control. The
        // floating-button choice is session-only and deliberately NOT restored on
        // relaunch, so the user always returns to the bar after quitting (and, since
        // the bar mode lays the bar out, its sizing is always captured correctly —
        // floating-button mode skips that layout).
        prefersFloatingButton = false
        LCUtils.appGroupUserDefault.set(false, forKey: MultitaskDockManager.preferFloatingButtonKey)
        keyWindow!.rootViewController!.view.addSubview(self.windowHostingView)
        // Ask UIKit to keep `UIDevice.current.orientation` live. Without this the
        // device orientation reads as unknown and its notification may never fire —
        // and when the interface itself is not rotating, the phone being turned is
        // the *only* signal that the floating button has to move.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        if let win = keyWindow { attachSafeAreaSentinel(to: win) }
        refreshCachedSafeAreaInsets()
        setupDockView()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
        // Safety net: whenever LiveContainer returns to the foreground, make sure a
        // foregrounded app/page always exposes a way to minimize or exit it.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        // Re-lay out the bar live when the rounded/flat design toggle changes.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(barDesignSettingChanged),
            name: .multitaskBarDesignChanged,
            object: nil
        )
        // A guest window announcing it has something to show. Sent rather than
        // called, the way the bar's own state travels between these two files:
        // the window is Objective-C and the dock is Swift, and a notification
        // needs neither side's generated header to reach the other.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowContentDidArrive(_:)),
            name: .lcWindowContentDidArrive,
            object: nil
        )
    }

    /// Live-apply the rounded/flat bar design when its Settings toggle changes.
    /// Safe to do live because the toggle is a Settings list row, not a control
    /// sitting on the bar. `updateDockFrame` re-reads the setting via
    /// `captureBarDesign()` and animates the strip to the new size/shape. If the
    /// bar isn't on screen, the next layout picks the design up on its own.
    @objc private func barDesignSettingChanged() {
        DispatchQueue.main.async {
            // Both designs share the same strip size, so re-reading the design
            // (rounded/flat + corner radius) into the published state is all that's
            // needed to re-render the bar live — no re-layout. `captureBarDesign`
            // only publishes when a value actually changed.
            self.captureBarDesign()
        }
    }

    @objc private func appDidBecomeActive() {
        ensureControlAccessible()
        DispatchQueue.main.async {
            // Keep the safe-area sentinel on the current key window (it can change
            // across scene transitions), and re-lay out the bar if it's already
            // visible: on a cold relaunch the bar can first appear before the safe
            // area is ready, and `ensureControlAccessible` won't re-lay out a bar
            // that's already shown — so it would otherwise stay mis-sized.
            if let win = self.keyWindow { self.attachSafeAreaSentinel(to: win) }
            self.refreshCachedSafeAreaInsets()
            if self.isVisible && self.isSwitcherBarVisible {
                self.updateDockFrame(animated: false)
            }
        }
    }

    /// The view the bar, the floating button and the switcher overlay are parented
    /// to: the root of the overlay window, created on first use.
    ///
    /// Created lazily rather than at init so the app's own window is long since
    /// key by the time this one appears — a window made visible while nothing else
    /// is key can be handed the key window role, and this one must never have it.
    ///
    /// Follows the app if it ever moves to another scene (an in-place update can
    /// restore one), carrying whatever is on screen across rather than stranding
    /// it on a window the user is no longer looking at.
    private func overlayHostView() -> UIView? {
        guard let scene = keyWindow?.windowScene else {
            return overlayWindow?.rootViewController?.view
        }
        if let existing = overlayWindow, existing.windowScene === scene {
            existing.isHidden = false
            return existing.rootViewController?.view
        }

        let window = MultitaskOverlayWindow(windowScene: scene)
        // One level above the app's own window: past every presentation made
        // inside it, and still below the status bar and the system's own alert
        // windows, which have no business being covered by ours.
        window.windowLevel = .normal + 1
        window.backgroundColor = .clear
        let root = MultitaskOverlayRootViewController()
        // The button is positioned in this host's coordinate space, so the host is
        // what has to be re-measured when it changes size — a rotation, or anything
        // else that resizes the window. Runs both from the rotation coordinator (so
        // the move rides the system animation) and from the host's own layout (the
        // authoritative moment, whatever order the rotation callbacks arrive in).
        root.onHostGeometryChange = { [weak self] bounds in
            guard let self else { return }
            // The bar is measured against this same host, so it re-lays out here too
            // rather than waiting on a device notification that may fire before the
            // host has resized — or, when the host is not the thing turning, never
            // describe this host at all.
            if self.isVisible && self.isSwitcherBarVisible {
                self.updateDockFrame(animated: false)
            }
            guard let button = self.navAssistButton, !self.isNavAssistDragging else { return }
            self.placeNavAssist(button, in: bounds, stashed: self.isNavAssistStashed, animated: false)
        }
        window.rootViewController = root
        window.isHidden = false

        // Both windows share the scene's coordinate space, so the frames the
        // moved views already have still mean the same thing here.
        if let old = overlayWindow?.rootViewController?.view,
           let new = window.rootViewController?.view {
            for subview in old.subviews {
                new.addSubview(subview)
            }
        }
        overlayWindow?.isHidden = true
        overlayWindow = window
        return window.rootViewController?.view
    }

    /// Attach the safe-area sentinel to `window` (moving it if the key window
    /// changed) so a later safe-area update re-lays out the bar and internal-page
    /// reservations with the correct inset.
    private func attachSafeAreaSentinel(to window: UIWindow) {
        if safeAreaSentinel.onChange == nil {
            safeAreaSentinel.backgroundColor = .clear
            safeAreaSentinel.isUserInteractionEnabled = false
            safeAreaSentinel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            safeAreaSentinel.onChange = { [weak self] in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.refreshCachedSafeAreaInsets()
                    if self.isVisible && self.isSwitcherBarVisible {
                        self.updateDockFrame(animated: false)
                    }
                    let reserved = self.isVisible && self.isSwitcherBarVisible
                    for (_, controller) in self.internalPageControllers {
                        self.applyBarInset(to: controller, reserved: reserved)
                    }
                }
            }
        }
        if safeAreaSentinel.superview !== window {
            safeAreaSentinel.removeFromSuperview()
            safeAreaSentinel.frame = window.bounds
            window.addSubview(safeAreaSentinel)
            window.sendSubviewToBack(safeAreaSentinel)
        }
    }

    
    deinit {
        NotificationCenter.default.removeObserver(self)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    @objc private func deviceOrientationDidChange() {
        DispatchQueue.main.async {
            // Re-size the switcher's cards for the orientation they are now in.
            self.refreshSwitcherScreenSize()
            if self.isVisible {
                // Snap (not animate) so the bar lands on its new short edge as the
                // system's own rotation animation completes, avoiding a compounded
                // spin from animating our -90° transform at the same time.
                self.updateDockFrame(animated: false)
            }
            // Put the floating button back on the edge it was already on, measured
            // in its host's bounds. Not gated on `isVisible` (that tracks the bar)
            // and deliberately outside it: the button is its own control, and this
            // is a cheap idempotent re-place. The host's layout callback repeats it
            // once the rotation settles, which is what makes a device notification
            // arriving before the window has resized harmless.
            if let button = self.navAssistButton, !self.isNavAssistDragging {
                // Animated: when the interface is not rotating there is no system
                // animation for the move to hide inside, and a jump reads as a
                // glitch. When it is, this pass finds the button already at its
                // target and the animation costs nothing.
                self.placeNavAssist(button, stashed: self.isNavAssistStashed, animated: true)
            }
            // Move the internal-page bar reservation to the correct edge for the
            // new orientation (bottom in portrait, right in landscape).
            let reserved = self.isVisible && self.isSwitcherBarVisible
            for (_, controller) in self.internalPageControllers {
                self.applyBarInset(to: controller, reserved: reserved)
            }
        }
    }
    
    private func setupDockView() {
        DispatchQueue.main.async {
            // Capture the design once at startup so `barCornerRadiusActive` reflects
            // the device radius from the start (used by the bar reserve and the
            // switcher toggle) even before the bar is first laid out.
            self.captureBarDesign()
            let barView = AnyView(SwitcherBarContentView()
                .environmentObject(self)
                .preferredColorScheme(.dark)
                .environment(\.colorScheme, .dark))
            
            self.hostingController = UIHostingController(rootView: barView)
            self.hostingController?.view.backgroundColor = .clear
            self.hostingController?.view.clipsToBounds = false
            self.hostingController?.view.insetsLayoutMarginsFromSafeArea = false
            self.hostingController?.overrideUserInterfaceStyle = .dark
            self.hostingController?.view.overrideUserInterfaceStyle = .dark

            // Wrap the bar in a full-window pass-through container so taps that land
            // in the bar's transparent concave corners / overhang reach the content
            // underneath (guest apps and internal-page controls like Import IPA /
            // search) instead of being swallowed by the rectangular hosting view.
            // The container hit-tests against the bar's actual shape.
            let container = BarPassthroughContainer()
            container.backgroundColor = .clear
            container.clipsToBounds = false
            container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            if let barView = self.hostingController?.view {
                container.barView = barView
                container.addSubview(barView)
            }
            container.hitPathProvider = { [weak self] bounds in
                // Landscape / plain bar fills its whole bounds (nil == full rect).
                // Both designs (portrait and landscape) leave the region above the
                // flat-top line transparent, so hit-test against the actual fill shape
                // and pass taps above it through to the content beneath. The point is
                // converted into the bar's un-rotated local space below, so the same
                // local shape works in landscape after the -90° transform.
                guard let self = self else { return nil }
                let r = self.barCornerRadiusActive
                let cg = self.barLedgeActive
                    ? BarTopBar(radius: r, curve: r * self.barLedgeAmountActive)
                        .path(in: bounds).cgPath
                    : BarFlatTop(inset: r).path(in: bounds).cgPath
                return UIBezierPath(cgPath: cg)
            }
            self.barContainer = container
        }
    }

    // MARK: - Frame Management

    /// Positions the switcher bar on the current short edge — bottom in
    /// portrait, right edge in landscape — keeping identical portrait sizing.
    ///
    /// The hosting view's *local* bounds are always a horizontal strip
    /// (`length × thickness`, thickness = barHeight + outer safe-area inset).
    /// In landscape the view is rotated -90° via `barBaseTransform`, turning the
    /// horizontal pill into a vertical one hugging the right edge. Because the
    /// view carries a transform, we drive it with bounds + center + transform
    /// rather than `frame` (setting `frame` under a non-identity transform is
    /// undefined).
    private func updateDockFrame(animated: Bool = true) {
        guard let hostingController = hostingController, isSwitcherBarVisible else { return }

        // Pick up the current design as the bar (re)lays out — never mid-toggle.
        captureBarDesign()

        // Keep the published orientation flag in sync so the bar content picks
        // the right edge margin (-2 portrait, -10 landscape).
        if isLandscapeBar != isBarLandscape {
            isLandscapeBar = isBarLandscape
        }

        let screenBounds = barLayoutBounds
        var insets = safeAreaInsets
        // On a fast, state-restored launch (after an in-place update) the window's
        // safe area can still be zero when the bar first lays out, which would size
        // the bar without the home-indicator inset. Force a layout pass and re-read
        // so a late-arriving bottom inset is applied instead of baked in as zero.
        if barLayoutEdge == .bottom, insets.bottom == 0, let win = keyWindow {
            win.layoutIfNeeded()
            insets = win.safeAreaInsets
        }

        // Cross-thickness of the bar. Deliberately the same slim value in both
        // orientations so the landscape bar matches the portrait one instead of
        // ballooning to include the large horizontal safe-area inset (e.g. the
        // notch), which previously made it a wide full-height sidebar.
        // Strip = visible flat region + the concave corner radius carved above it.
        let thickness = barFlatRegion + barCornerRadiusActive


        // The strip spans its edge and its thickness reaches inward from it. Local
        // bounds are always a horizontal strip; `barBaseTransform` turns it onto the
        // edge, so the length here is the length of that edge.
        let edge = barLayoutEdge
        let boundsSize: CGSize
        let center: CGPoint
        switch edge {
        case .bottom:
            boundsSize = CGSize(width: screenBounds.width, height: thickness)
            center = CGPoint(x: screenBounds.midX, y: screenBounds.height - thickness / 2)
        case .top:
            boundsSize = CGSize(width: screenBounds.width, height: thickness)
            center = CGPoint(x: screenBounds.midX, y: thickness / 2)
        case .right:
            boundsSize = CGSize(width: screenBounds.height, height: thickness)
            center = CGPoint(x: screenBounds.width - thickness / 2, y: screenBounds.midY)
        case .left:
            boundsSize = CGSize(width: screenBounds.height, height: thickness)
            center = CGPoint(x: thickness / 2, y: screenBounds.midY)
        }

        let apply = {
            hostingController.view.bounds = CGRect(origin: .zero, size: boundsSize)
            hostingController.view.transform = self.barBaseTransform
            hostingController.view.center = center
        }

        if animated {
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: Constants.standardSpringDamping,
                initialSpringVelocity: Constants.standardSpringVelocity,
                // The bar carries the buttons that leave an app, and a view being
                // animated by UIKit takes no touches unless it is asked to. Without
                // this it is dead to the touch for the length of every re-layout.
                options: [.curveEaseOut, .allowUserInteraction]
            ) {
                apply()
            }
        } else {
            apply()
        }
    }
    
    @objc public func addRunningApp(_ appName: String, appUUID: String, view: UIView?) {
        let appInfo = AppInfoProvider.shared.findAppInfo(appName: appName, dataUUID: appUUID)
        addRunningAppWithInfo(appInfo, appUUID: appUUID, view: view)
    }
    
    @objc public func removeRunningApp(_ appUUID: String) {
        guard isDockEnabled() else { return }
        
        DispatchQueue.main.async {
            // Before the app leaves the list, while its controller can still be
            // found: anything it presented goes with it.
            self.dismissPresentation(forAppUUID: appUUID)
            // Read while the app is still in the list: a window closed before its
            // app ever drew would otherwise leave its launch screen behind here.
            if let view = self.apps.first(where: { $0.appUUID == appUUID })?.view {
                self.launchPlaceholders.removeValue(forKey: ObjectIdentifier(view))
                self.windowsWithContent.remove(ObjectIdentifier(view))
            }
            // Animate the list mutation so the remaining switcher cards slide in
            // to fill the gap smoothly instead of snapping into place.
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                self.apps.removeAll { $0.appUUID == appUUID }
            }
            self.appSnapshotViews.removeValue(forKey: appUUID)
            self.appSnapshotSizes.removeValue(forKey: appUUID)
            self.appSnapshotImages.removeValue(forKey: appUUID)
            self.appSnapshotRotations.removeValue(forKey: appUUID)
            if let hostVC = self.internalPageControllers.removeValue(forKey: appUUID) {
                hostVC.willMove(toParent: nil)
                hostVC.view.removeFromSuperview()
                hostVC.removeFromParent()
            }
            
            if self.frontmostAppUUID == appUUID {
                self.updateFrontmostApp()
            }
            
            if self.apps.isEmpty {
                if self.isAppSwitcherOpen {
                    // Dismiss overlay without restoring bar (since we're hiding dock next)
                    self.isAppSwitcherOpen = false
                    if let overlay = self.switcherOverlayController {
                        // Eased out over the standard duration: this uncovers the live
                        // springboard, whose icons carry glass the backdrop's snapshot
                        // does not, and a short ease-in dropped that difference in on
                        // the last frame.
                        UIView.animate(withDuration: Constants.standardAnimationDuration,
                                       delay: 0, options: .curveEaseOut) {
                            overlay.view.alpha = 0
                        } completion: { _ in
                            overlay.view.removeFromSuperview()
                            overlay.view.alpha = 1
                        }
                    }
                }
                // No apps left: we are effectively on the springboard now. Record the
                // home state so control-visibility logic stays consistent.
                self.isHomeState = true
                self.hideDock()
            } else if self.isVisible {
                self.updateDockFrame()
            }
        }
    }
    
    // MARK: - Show/Hide Dock (lifecycle — called when apps are added/removed)
    @objc public func showDock() {
        guard isDockEnabled() else { return }
        guard !isVisible, let hostingController = hostingController else { return }
        guard let keyWindow = self.keyWindow else { return }
        
        DispatchQueue.main.async {
            self.isVisible = true
            // Capture the design (corner radius + rounded/flat) now, even in
            // floating-button mode where the bar isn't laid out. Otherwise
            // `captureBarDesign()` — which only runs inside `updateDockFrame` — never
            // fires, leaving `barCornerRadiusActive` at its default and the switcher
            // toggle / bar reserve sized with the wrong radius.
            self.captureBarDesign()

            // Honor the saved control preference: show the floating button
            // instead of the bar when the user has chosen it.
            if self.prefersFloatingButton {
                self.isSwitcherBarVisible = false
                // No bar on screen → don't reserve its strip on internal pages.
                for (_, controller) in self.internalPageControllers {
                    self.applyBarInset(to: controller, reserved: false)
                }
                hostingController.view.isHidden = true
                hostingController.view.alpha = 0
                if !self.isHomeState && self.hasForegroundAppWindow() {
                    self.showNavAssist(in: keyWindow)
                }
                self.refreshOrientationLock()
                NotificationCenter.default.post(name: .multitaskBarVisibilityChanged, object: nil)
                return
            }

            self.isSwitcherBarVisible = true
            self.refreshOrientationLock()

            // Reserve space for the bar on its current edge for internal pages
            for (_, controller) in self.internalPageControllers {
                self.applyBarInset(to: controller, reserved: true)
            }

            // Add the pass-through container (which holds the bar) to the overlay
            // window, out of reach of anything presented in the app's own.
            let host: UIView = self.overlayHostView() ?? keyWindow
            if let container = self.barContainer {
                container.frame = host.bounds
                if container.superview !== host {
                    host.addSubview(container)
                } else {
                    host.bringSubviewToFront(container)
                }
            } else if hostingController.view.superview == nil {
                host.addSubview(hostingController.view)
            }

            self.updateDockFrame(animated: false)

            hostingController.view.isHidden = false
            hostingController.view.alpha = 0
            let slideOffset = max(hostingController.view.bounds.height, 120)
            hostingController.view.transform = self.barHiddenTransform(offset: slideOffset)

            // Smooth ease-in-out slide up from just below the edge (no spring kick).
            UIView.animate(
                withDuration: Constants.barSlideDuration,
                delay: 0,
                options: [.curveEaseInOut, .beginFromCurrentState],
                animations: {
                    hostingController.view.alpha = 1
                    hostingController.view.transform = self.barBaseTransform
                }
            )

            // Tell the windows the bar is here, now that it has been laid out and
            // the strip it occupies is known. Hiding and showing the bar announced
            // itself; its first appearance did not — so a window opened before the
            // bar existed kept the full-height frame it was given and left its
            // guest drawing underneath the bar, until some later change happened to
            // put the frame right. Toggling the bar was that later change.
            NotificationCenter.default.post(name: .multitaskBarVisibilityChanged, object: nil)
        }
    }

    @objc public func hideDock() {
        guard isVisible, let hostingController = hostingController else { return }
        
        DispatchQueue.main.async {
            self.isVisible = false

            // Remove the bar reservation from internal pages
            for (_, controller) in self.internalPageControllers {
                self.applyBarInset(to: controller, reserved: false)
            }

            // Also remove nav assist if visible
            self.navAssistButton?.removeFromSuperview()
            self.navAssistButton = nil

            // No control on screen anymore → back to portrait (springboard).
            self.refreshOrientationLock()
            
            let slideOffset = max(hostingController.view.bounds.height, 120)
            // Smooth ease-in-out slide down just off the edge (no spring kick).
            UIView.animate(
                withDuration: Constants.barSlideDuration,
                delay: 0,
                options: [.curveEaseInOut, .beginFromCurrentState],
                animations: {
                    hostingController.view.alpha = 0
                    hostingController.view.transform = self.barHiddenTransform(offset: slideOffset)
                }
            ) { _ in
                hostingController.view.transform = self.barBaseTransform
            }
        }
    }
    
    // MARK: - Switcher Bar Actions
    
    /// Home button: minimize all visible windows, or restore last app if all minimized
    @objc public func goHome() {
        DispatchQueue.main.async {
            // Dismiss app switcher if open
            if self.isAppSwitcherOpen { self.dismissAppSwitcher() }
            
            // Check if any windows are visible
            let hasVisibleWindow = self.windowHostingView.subviews.contains { view in
                !view.isHidden && view.alpha > 0.1
            }
            
            if hasVisibleWindow {
                // Whether anything is headed for the dock has to be settled before
                // the home state flips, since that is what puts the dock on screen:
                // decided any later and its entrance has already begun.
                let flying = self.frontmostVisibleWindow()
                self.homeDockShouldSkipEntrance = self.apps.contains { app in
                    guard let view = app.view, view === flying,
                          let itemID = app.springboardItemID else { return false }
                    return LCMinimizeToIconAnimator.willUseHomeDock(forItemID: itemID)
                }

                // Minimize ALL visible windows and hide the dock bar. This is the
                // way home, so a built-in page shrinks into its own icon on the
                // way rather than simply going out.
                self.minimizeAllWindows(style: .intoIcons)
                self.updateFrontmostApp()
                self.isHomeState = true
                self.hideDock()

                // Every other way the dock appears keeps its entrance.
                if self.homeDockShouldSkipEntrance {
                    self.homeDockEntranceSkipToken &+= 1
                    let token = self.homeDockEntranceSkipToken
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        if self.homeDockEntranceSkipToken == token {
                            self.homeDockShouldSkipEntrance = false
                        }
                    }
                }
            } else {
                // All minimized — bring back last used app
                self.isHomeState = false
                self.showDock()
                if let uuid = self.frontmostAppUUID {
                    let _ = self.bringMultitaskViewToFront(uuid: uuid)
                } else if let lastApp = self.apps.last {
                    let _ = self.bringMultitaskViewToFront(uuid: lastApp.appUUID)
                }
            }
        }
    }
    
    /// Find the current frontmost visible app from the view hierarchy
    private func updateFrontmostApp() {
        for view in self.windowHostingView.subviews.reversed() {
            if !view.isHidden && view.alpha > 0.1 {
                if let app = apps.first(where: { $0.view === view }) {
                    frontmostAppUUID = app.appUUID
                    updateDockFrame()
                    return
                }
            }
        }
        frontmostAppUUID = nil
        updateDockFrame()
    }

    /// True when an app or built-in page (Settings / Installer / FlekStore) is
    /// actually on screen in the window host.
    private func hasForegroundAppWindow() -> Bool {
        return self.windowHostingView.subviews.contains { view in
            !view.isHidden && view.alpha > 0.1
        }
    }

    // MARK: - Orientation

    /// Whether a multitask control — the bottom switcher bar OR the floating
    /// nav-assist button — is currently on screen. This is the single flag used
    /// to decide if the device may rotate: when a control is present an app is
    /// on stage and should be rotatable; the bare springboard (no control)
    /// stays portrait-locked.
    ///
    /// Uses the logical visibility flags (not view alpha) so the value is
    /// correct immediately, before show/hide animations settle.
    var isAnyControlVisible: Bool {
        let barShown = isVisible
            && isSwitcherBarVisible
            && (hostingController?.view.isHidden == false)
        let navShown = navAssistButton != nil
        return barShown || navShown
    }

    /// Drives `AppDelegate.orientationLock` from control visibility:
    /// rotatable (`.allButUpsideDown`) while the switcher bar or floating button
    /// is shown, portrait-locked otherwise. No-op outside virtual-window
    /// multitask mode, where the SwiftUI `OrientationLockModifier` owns
    /// orientation instead.
    @objc public func refreshOrientationLock() {
        guard isDockEnabled() else { return }
        DispatchQueue.main.async {
            // The app switcher overlay is portrait-only. Otherwise: rotatable
            // while a control is on screen, portrait-locked on the springboard.
            let lockPortrait = self.isAppSwitcherOpen || !self.isAnyControlVisible
            AppDelegate.orientationLock = lockPortrait ? .portrait : .allButUpsideDown

            let keyWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
            keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()

            // If the switcher opened while the device is held in landscape,
            // actively rotate the interface to portrait so it's always upright.
            if self.isAppSwitcherOpen,
               let scene = keyWindow?.windowScene,
               scene.interfaceOrientation.isLandscape {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
        }
    }

    /// Invariant guard: whenever an app/page is in the foreground (i.e. we are not on
    /// the springboard), at least one control — the bottom switcher bar OR the floating
    /// nav-assist button — must be reachable so the user can always minimize or exit.
    /// If a state desync ever leaves both hidden, this restores the switcher bar.
    @objc public func ensureControlAccessible() {
        ensureControlAccessible(retriesLeft: 8)
    }

    /// Guarantees a multitask control (switcher bar or floating button) is on screen
    /// whenever an app is foregrounded. This self-heals two launch/relaunch races
    /// that could otherwise leave neither control visible:
    ///  1. The app's view is in the hierarchy a beat before it becomes visible, so
    ///     `hasForegroundAppWindow()` can momentarily be false; if we still expect an
    ///     app (the list is non-empty) we retry shortly instead of giving up.
    ///  2. When neither control is up we show the one the user *prefers* (the old
    ///     code always brought back the bar, ignoring floating-button mode, and
    ///     `applyPreferredControl` only switches between controls — it does nothing
    ///     when neither is present).
    private func ensureControlAccessible(retriesLeft: Int) {
        DispatchQueue.main.async {
            guard self.isDockEnabled() else { return }
            // Reconcile rotation with current control visibility every time we
            // re-check (e.g. on foreground), self-healing against any stale lock.
            self.refreshOrientationLock()
            // Springboard has its own UI (the app list); no floating control is needed.
            guard !self.isHomeState else { return }
            // The app-switcher overlay already provides controls while it is open.
            guard !self.isAppSwitcherOpen else { return }

            // A control is only needed when an app window is actually on screen.
            // During launch/relaunch the app view can lag its own appearance, so if
            // we expect an app but its window isn't ready yet, retry shortly rather
            // than leaving the user with no bar and no button.
            guard self.hasForegroundAppWindow() else {
                if !self.apps.isEmpty && retriesLeft > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self.ensureControlAccessible(retriesLeft: retriesLeft - 1)
                    }
                }
                return
            }

            let barShown = self.isVisible
                && self.isSwitcherBarVisible
                && (self.hostingController?.view.isHidden == false)
                && ((self.hostingController?.view.alpha ?? 0) > 0.1)
            let navShown = self.navAssistButton?.window != nil

            guard !barShown && !navShown else { return }

            // Neither control is reachable — show the one the user prefers.
            if self.prefersFloatingButton {
                guard let keyWindow = self.keyWindow else { return }
                self.isVisible = true
                self.isSwitcherBarVisible = false
                self.hostingController?.view.isHidden = true
                self.hostingController?.view.alpha = 0
                self.showNavAssist(in: keyWindow)
            } else if self.isVisible {
                self.showSwitcherBar()
            } else {
                self.showDock()
            }
        }
    }
    
    /// Hide the switcher bar with slide-down animation and show navigation assist
    @objc public func hideSwitcherBar() {
        guard let hostingController = hostingController, let keyWindow = self.keyWindow else { return }
        
        DispatchQueue.main.async {
            guard self.isSwitcherBarVisible else { return }
            self.isSwitcherBarVisible = false
            NotificationCenter.default.post(name: .multitaskBarVisibilityChanged, object: nil)
            
            // Bring the floating button in immediately, concurrent with the bar
            // sliding out, instead of waiting for the slide to finish. The button
            // sits mid-right and the bar at the bottom, so they never overlap.
            let showsFloatingButton = !self.isHomeState && self.hasForegroundAppWindow()
            if showsFloatingButton {
                self.showNavAssist(in: keyWindow)
            }

            // Remove the bar reservation from internal pages so they stretch full
            for (_, controller) in self.internalPageControllers {
                UIView.animate(withDuration: Constants.longAnimationDuration) {
                    self.applyBarInset(to: controller, reserved: false)
                }
            }

            // Smooth ease-in-out slide fully off the bottom edge (no spring kick),
            // keeping the bar opaque for most of the travel so it reads as a clean
            // slide-down rather than a quick fade.
            UIView.animate(
                withDuration: Constants.barSlideDuration,
                delay: 0,
                options: [.curveEaseInOut, .beginFromCurrentState],
                animations: {
                    hostingController.view.transform = self.barHiddenTransform(offset: 160)
                    hostingController.view.alpha = 0
                }
            ) { _ in
                hostingController.view.isHidden = true
                hostingController.view.transform = self.barBaseTransform
                // showNavAssist already refreshes the orientation lock when it
                // runs, so only do it here for the no-button (home) case.
                if !showsFloatingButton {
                    self.refreshOrientationLock()
                }
                // Safety net: guarantee a control is on screen. If an app is
                // foreground but its window read as not-ready when we tried to show
                // the floating button above, this re-checks (and retries) so hiding
                // the bar can never leave the user with neither control.
                self.ensureControlAccessible()
            }
        }
    }

    /// Show the switcher bar with slide-up animation and hide navigation assist
    @objc public func showSwitcherBar() {
        guard let hostingController = hostingController else { return }
        
        DispatchQueue.main.async {
            // Hide nav assist and reset stash state
            self.isNavAssistStashed = false
            self.navAssistChevron = nil
            UIView.animate(withDuration: 0.2, animations: {
                self.navAssistButton?.alpha = 0
                self.navAssistButton?.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
            }) { _ in
                self.navAssistButton?.removeFromSuperview()
                self.navAssistButton = nil
            }
            
            self.isSwitcherBarVisible = true
            self.refreshOrientationLock()
            self.updateDockFrame(animated: false)
            NotificationCenter.default.post(name: .multitaskBarVisibilityChanged, object: nil)
            
            // Restore the bar reservation on internal pages
            for (_, controller) in self.internalPageControllers {
                UIView.animate(withDuration: Constants.standardAnimationDuration) {
                    self.applyBarInset(to: controller, reserved: true)
                }
            }
            
            hostingController.view.isHidden = false
            hostingController.view.alpha = 0
            let slideOffset = max(hostingController.view.bounds.height, 120)
            hostingController.view.transform = self.barHiddenTransform(offset: slideOffset)

            // Smooth ease-in-out slide up (no spring kick), after nav assist hides.
            UIView.animate(
                withDuration: Constants.barSlideDuration,
                delay: 0.15,
                options: [.curveEaseInOut, .beginFromCurrentState],
                animations: {
                    hostingController.view.alpha = 1
                    hostingController.view.transform = self.barBaseTransform
                }
            )
        }
    }
    
    // MARK: - Navigation Assist Button
    
    private func showNavAssist(in window: UIWindow, animated: Bool = true) {
        // Remove any existing nav assist button to prevent duplicates
        navAssistButton?.removeFromSuperview()
        navAssistButton = nil

        isNavAssistStashed = false
        navAssistChevron = nil

        let button = createNavAssistButton()

        // The overlay window, alongside the bar and for the same reason: when this
        // button is the control on screen it is the only way out of the app, so a
        // sheet presented over it must not be able to take it away.
        let host = self.overlayHostView() ?? window
        host.addSubview(button)
        self.navAssistButton = button
        // A fresh button starts halfway down the right of the user's view, whichever
        // layout edge that currently is.
        self.navAssistViewEdge = .right
        self.navAssistAlongFraction = 0.5
        // Placed only now that it has a host: its position is measured in that
        // host's space, and the host is not necessarily `window`.
        self.placeNavAssist(button, stashed: false, animated: false)
        // Floating button now on stage → allow rotation.
        self.refreshOrientationLock()

        guard animated else {
            // Instant placement (e.g. when revealing behind the switcher overlay
            // as it fades) so the button is already in its final state.
            button.alpha = 1
            button.transform = .identity
            return
        }

        button.alpha = 0
        button.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
        UIView.animate(
            withDuration: Constants.standardAnimationDuration,
            delay: 0.03,
            usingSpringWithDamping: Constants.showHideSpringDamping,
            initialSpringVelocity: 0,
            // Tappable as it arrives, rather than only once it has settled.
            options: [.curveEaseOut, .allowUserInteraction]
        ) {
            button.alpha = 1
            button.transform = .identity
        }
    }
    
    private func createNavAssistButton() -> UIView {
        let size = Constants.navAssistSize
        let button = UIView(frame: CGRect(x: 0, y: 0, width: size, height: size))
        
        let blurEffect = UIBlurEffect(style: .systemMaterialDark)
        let blurView = UIVisualEffectView(effect: blurEffect)
        blurView.frame = button.bounds
        blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        blurView.isUserInteractionEnabled = false
        blurView.layer.cornerRadius = size / 2
        blurView.clipsToBounds = true
        button.addSubview(blurView)
        
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        let iconImage = UIImage(systemName: FlekSymbol.appSwitcher, withConfiguration: iconConfig)
        let iconView = UIImageView(image: iconImage)
        iconView.tintColor = .white
        iconView.contentMode = .center
        iconView.frame = button.bounds
        iconView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        iconView.tag = 100 // Tag for reliable lookup
        // Upright from the start: the button can be created while the phone is
        // already held sideways.
        iconView.transform = navAssistIconTransform
        button.addSubview(iconView)
        
        button.layer.cornerRadius = size / 2
        button.layer.borderWidth = 0.5
        button.layer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.3
        button.layer.shadowRadius = 4
        button.layer.shadowOffset = CGSize(width: 0, height: 2)
        
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(navAssistTapped))
        button.addGestureRecognizer(tapGesture)
        
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(navAssistDragged(_:)))
        button.addGestureRecognizer(panGesture)
        
        return button
    }
    
    @objc private func navAssistTapped() {
        let impactFeedback = UIImpactFeedbackGenerator(style: .light)
        impactFeedback.impactOccurred()
        
        if isNavAssistStashed {
            // Docked at an edge: first tap brings the button back out.
            unstashNavAssist()
        } else {
            // Open the multitask switcher directly instead of showing the bar.
            showAppSwitcher()
        }
    }
    
    @objc private func navAssistDragged(_ gesture: UIPanGestureRecognizer) {
        guard let button = navAssistButton else { return }
        let translation = gesture.translation(in: button.superview)
        
        switch gesture.state {
        case .changed:
            button.center = CGPoint(
                x: button.center.x + translation.x,
                y: button.center.y + translation.y
            )
            gesture.setTranslation(.zero, in: button.superview)
            
        case .ended, .cancelled, .failed:
            snapNavAssistToEdge(button, animated: true)
            
        default:
            break
        }
    }
    
    private func snapNavAssistToEdge(_ button: UIView, animated: Bool) {
        guard let screenBounds = navAssistHostBounds(for: button) else { return }
        let margin = Constants.navAssistMargin
        let halfSize = Constants.navAssistSize / 2
        let stashThreshold: CGFloat = halfSize + margin // How close to edge before stashing

        // Every edge is dockable in either orientation. The edge is remembered and
        // carried through rotation, so restricting the set per orientation would
        // mean a button parked on one could not stay there once the device turned.
        let allowedEdges: [ScreenEdge] = [.left, .right, .top, .bottom]

        // Distance from the button center to a given screen edge.
        func distance(to edge: ScreenEdge) -> CGFloat {
            switch edge {
            case .left:   return button.center.x
            case .right:  return screenBounds.width - button.center.x
            case .top:    return button.center.y
            case .bottom: return screenBounds.height - button.center.y
            }
        }

        // Snap to whichever allowed edge is nearest, and remember where along it the
        // drag left the button so a rotation can reproduce the same spot.
        let edge = allowedEdges.min(by: { distance(to: $0) < distance(to: $1) })!
        let range = navAssistAlongRange(for: edge, in: screenBounds, insets: navAssistHostInsets(for: button))
        let along: CGFloat
        switch edge {
        case .left, .right:  along = button.center.y
        case .top, .bottom:  along = button.center.x
        }

        rememberScreenPlacement(edge: edge, fraction: navAssistFraction(of: along, in: range))
        placeNavAssist(button, in: screenBounds, stashed: distance(to: edge) < stashThreshold, animated: animated)
    }

    // MARK: - Viewer Frame

    /// The four sides in clockwise order, the order a quarter-turn steps through.
    private static let edgesClockwise: [ScreenEdge] = [.top, .right, .bottom, .left]

    /// Quarter-turns the interface has been turned against the phone's own frame.
    /// `.landscapeLeft` is the phone held turned clockwise (home button on the
    /// left — the enum names are inverted against `UIDeviceOrientation`, see
    /// UIOrientation.h), which puts the phone's top side at the picture's right:
    /// one step.
    private var interfaceRotationSteps: Int {
        let scene = navAssistButton?.window?.windowScene ?? keyWindow?.windowScene
        switch scene?.interfaceOrientation {
        case .landscapeLeft:      return 1
        case .portraitUpsideDown: return 2
        case .landscapeRight:     return 3
        default:                  return 0
        }
    }

    /// Quarter-turns the phone itself is being held at, from the same zero.
    /// `UIDeviceOrientation.landscapeRight` is home button on the left, i.e. the
    /// phone turned clockwise — the mirror of the interface naming above.
    ///
    /// Falls back to the interface's own turn when the device won't say (flat on a
    /// table, or orientation notifications not running), which makes the two cancel
    /// out and leaves the button on the layout edge it is already on.
    private func deviceRotationSteps() -> Int {
        switch UIDevice.current.orientation {
        case .portrait:           lastKnownDeviceSteps = 0
        case .landscapeRight:     lastKnownDeviceSteps = 1
        case .portraitUpsideDown: lastKnownDeviceSteps = 2
        case .landscapeLeft:      lastKnownDeviceSteps = 3
        default: break
        }
        return lastKnownDeviceSteps ?? interfaceRotationSteps
    }

    /// Quarter-turns from the layout's frame to the viewer's — how far what the user
    /// sees has turned relative to the coordinates the button is positioned in.
    ///
    /// Zero whenever the interface rotates with the phone, because then they are the
    /// same frame. Non-zero exactly when the interface has stayed where it was while
    /// the phone turned, which is the case that has to move the button to a
    /// different layout edge to leave it on the same side of the user's view.
    private var viewerRotationSteps: Int {
        ((deviceRotationSteps() - interfaceRotationSteps) % 4 + 4) % 4
    }

    /// The turn that keeps the button's symbol upright to the user: the inverse of
    /// however far the layout is turned away from the viewer's frame. Identity
    /// whenever the interface rotates with the phone — there the layout is already
    /// the right way up — and a quarter-turn back when it is not, where a glyph
    /// drawn upright in layout coordinates would otherwise read as lying on its
    /// side. Quarter-turns only, so the square symbol never clips.
    private var navAssistIconTransform: CGAffineTransform {
        let steps = viewerRotationSteps
        guard steps != 0 else { return .identity }
        return CGAffineTransform(rotationAngle: -CGFloat(steps) * .pi / 2)
    }

    private func rotateEdge(_ edge: ScreenEdge, by steps: Int) -> ScreenEdge {
        let edges = Self.edgesClockwise
        guard let index = edges.firstIndex(of: edge) else { return edge }
        return edges[(index + steps % 4 + 4) % 4]
    }

    /// Whether the along-edge direction reverses when the layout is turned `steps`
    /// quarter-turns into the viewer's frame. A quarter-turn keeps one pair of sides
    /// running the same way and reverses the other; a half-turn reverses both.
    /// Named for the edge as it is in the layout, so the same answer serves both
    /// directions of the conversion.
    private func fractionFlips(layoutEdge: ScreenEdge, steps: Int) -> Bool {
        switch ((steps % 4) + 4) % 4 {
        case 1:  return layoutEdge == .left || layoutEdge == .right
        case 2:  return true
        case 3:  return layoutEdge == .top || layoutEdge == .bottom
        default: return false
        }
    }

    /// The stored viewer-frame position resolved into the layout edge that is
    /// currently on that side of the user's view, and the offset to draw it at.
    private func currentScreenPlacement() -> (edge: ScreenEdge, fraction: CGFloat) {
        let steps = viewerRotationSteps
        let edge = rotateEdge(navAssistViewEdge, by: -steps)
        let flips = fractionFlips(layoutEdge: edge, steps: steps)
        return (edge, flips ? 1 - navAssistAlongFraction : navAssistAlongFraction)
    }

    /// Records where a drag left the button — a layout edge and offset — as the side
    /// of the user's view it landed on, so a later turn of the phone can put it back
    /// on that same side rather than that same layout edge.
    private func rememberScreenPlacement(edge: ScreenEdge, fraction: CGFloat) {
        let steps = viewerRotationSteps
        navAssistViewEdge = rotateEdge(edge, by: steps)
        navAssistAlongFraction = fractionFlips(layoutEdge: edge, steps: steps)
            ? 1 - fraction
            : fraction
    }

    /// The space the button's center is expressed in: its own superview — the
    /// overlay window's root view — not `keyWindow`. The two are different windows,
    /// and measuring a position for one against the other is what puts the button
    /// somewhere the user cannot see it. `keyWindow` is only the fallback for a
    /// button that has not been added to a host yet.
    private func navAssistHostBounds(for button: UIView) -> CGRect? {
        guard let bounds = button.superview?.bounds ?? keyWindow?.bounds,
              bounds.width > 0, bounds.height > 0 else { return nil }
        return bounds
    }

    /// Safe-area insets of that same host, for the same reason.
    private func navAssistHostInsets(for button: UIView) -> UIEdgeInsets {
        button.superview?.safeAreaInsets ?? safeAreaInsets
    }

    /// The span the button's center may travel along `edge` — the free axis (Y for
    /// the side edges, X for the top and bottom), inset by the safe area and the
    /// margin at both ends.
    private func navAssistAlongRange(for edge: ScreenEdge, in screenBounds: CGRect, insets safeArea: UIEdgeInsets) -> ClosedRange<CGFloat> {
        let margin = Constants.navAssistMargin
        let halfSize = Constants.navAssistSize / 2
        let lower: CGFloat
        let upper: CGFloat
        switch edge {
        case .left, .right:
            lower = safeArea.top + margin + halfSize
            upper = screenBounds.height - safeArea.bottom - margin - halfSize
        case .top, .bottom:
            lower = safeArea.left + margin + halfSize
            upper = screenBounds.width - safeArea.right - margin - halfSize
        }
        return lower...max(lower, upper)
    }

    /// Where `along` sits within `range`, as 0...1. A degenerate range (a window too
    /// small for the button to travel at all) reads as the middle.
    private func navAssistFraction(of along: CGFloat, in range: ClosedRange<CGFloat>) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0.5 }
        return min(max((along - range.lowerBound) / span, 0), 1)
    }

    /// Puts the button back on the side of the phone it is parked on, at the offset
    /// along that side it is parked at, docked or stashed. Everything is derived
    /// from the stored device-frame position and the bounds passed in — never from
    /// the button's current center — which is what makes this safe to re-run after a
    /// rotation has left that center describing the old geometry.
    private func placeNavAssist(_ button: UIView, in bounds: CGRect? = nil, stashed: Bool, animated: Bool) {
        guard let screenBounds = bounds ?? navAssistHostBounds(for: button),
              screenBounds.width > 0, screenBounds.height > 0 else { return }
        let margin = Constants.navAssistMargin
        let halfSize = Constants.navAssistSize / 2
        // The physical side the button is parked on, read as the screen edge it
        // shows up as in the orientation the interface is in right now.
        let placement = currentScreenPlacement()
        let range = navAssistAlongRange(for: placement.edge, in: screenBounds, insets: navAssistHostInsets(for: button))
        let along = range.lowerBound + (range.upperBound - range.lowerBound) * placement.fraction

        if stashed {
            stashNavAssist(button, in: screenBounds, edge: placement.edge, along: along, animated: animated)
            return
        }

        // Resting position when docked to an edge ignores that edge's safe-area
        // inset so the button can sit right against the physical edge (the notch
        // inset on the sides, and the home-indicator inset at the bottom, would
        // otherwise push it far inward in landscape).
        let edgeMinX = margin + halfSize
        let edgeMaxX = screenBounds.width - margin - halfSize
        let edgeMinY = margin + halfSize
        let edgeMaxY = screenBounds.height - margin - halfSize

        let target: CGPoint
        switch placement.edge {
        case .left:   target = CGPoint(x: edgeMinX, y: along)
        case .right:  target = CGPoint(x: edgeMaxX, y: along)
        case .top:    target = CGPoint(x: along, y: edgeMinY)
        case .bottom: target = CGPoint(x: along, y: edgeMaxY)
        }
        restoreNavAssistIcon(button)
        moveNavAssist(button, to: clampNavAssistCenter(target, in: screenBounds), alpha: 1.0, animated: animated)
    }

    /// Keeps a center inside the host, which keeps at least half the button on
    /// screen on each axis — the same half a stash deliberately leaves showing.
    /// A backstop: if the remembered fraction is ever applied against geometry it
    /// wasn't measured in, the button comes out at the wrong spot rather than at no
    /// spot at all.
    private func clampNavAssistCenter(_ center: CGPoint, in screenBounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(center.x, 0), screenBounds.width),
                y: min(max(center.y, 0), screenBounds.height))
    }

    /// Clears the stashed chevron and restores the normal iphone.app.switcher icon.
    private func restoreNavAssistIcon(_ button: UIView) {
        isNavAssistStashed = false
        navAssistChevron?.removeFromSuperview()
        navAssistChevron = nil
        button.viewWithTag(100)?.isHidden = false
    }

    /// Animates (or snaps) the floating button to a center point.
    ///
    /// Also the one place the symbol's counter-turn is applied, because every
    /// placement — docked, stashed, dragged, re-placed on a turn of the phone —
    /// comes through here, so the glyph can never be left lying on its side.
    /// The chevron is deliberately left alone: it points into the screen, and
    /// which way that is survives the turn on its own.
    private func moveNavAssist(_ button: UIView, to center: CGPoint, alpha: CGFloat, animated: Bool) {
        let icon = button.viewWithTag(100)
        let iconTransform = navAssistIconTransform
        if animated {
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: Constants.standardSpringDamping,
                initialSpringVelocity: Constants.standardSpringVelocity,
                // Still a button while it is settling against the edge it was
                // thrown at, not a picture of one.
                options: [.curveEaseOut, .allowUserInteraction]
            ) {
                button.center = center
                button.alpha = alpha
                icon?.transform = iconTransform
            }
        } else {
            button.center = center
            button.alpha = alpha
            icon?.transform = iconTransform
        }
    }
    
    private func stashNavAssist(_ button: UIView, in screenBounds: CGRect, edge: ScreenEdge, along: CGFloat, animated: Bool) {
        let size = Constants.navAssistSize
        // Show half the button off the edge; the chevron is positioned in the
        // visible half (below) so it stays fully on-screen.
        let visibleAmount: CGFloat = size * 0.50

        // Center for the half-off-screen stashed position, and the chevron that
        // points back toward the screen interior. `along` is the free-axis
        // coordinate (Y for left/right edges, X for top/bottom edges).
        let newCenter: CGPoint
        let chevronName: String
        switch edge {
        case .right:
            newCenter = CGPoint(x: screenBounds.width - visibleAmount + size / 2, y: along)
            chevronName = "chevron.left"
        case .left:
            newCenter = CGPoint(x: visibleAmount - size / 2, y: along)
            chevronName = "chevron.right"
        case .bottom:
            newCenter = CGPoint(x: along, y: screenBounds.height - visibleAmount + size / 2)
            chevronName = "chevron.up"
        case .top:
            newCenter = CGPoint(x: along, y: visibleAmount - size / 2)
            chevronName = "chevron.down"
        }

        isNavAssistStashed = true

        // Add or update chevron indicator, positioned in the visible half of the
        // button (the half facing the screen interior) so the edge can't clip it.
        let config = UIImage.SymbolConfiguration(pointSize: 16.8, weight: .bold)  // 20% larger than the base 14
        let chevronImage = UIImage(systemName: chevronName, withConfiguration: config)

        // Center the chevron on the centroid of the visible half-disk — the true
        // middle of the not-hidden part of the round button — rather than the
        // rectangular midpoint of the half, which reads as off toward the interior.
        let mid = size / 2
        let centroidOffset = 2 * size / (3 * CGFloat.pi)  // half-disk centroid from the flat (edge) side
        let chevronCenter: CGPoint
        switch edge {
        case .right:  chevronCenter = CGPoint(x: mid - centroidOffset, y: mid)
        case .left:   chevronCenter = CGPoint(x: mid + centroidOffset, y: mid)
        case .bottom: chevronCenter = CGPoint(x: mid, y: mid - centroidOffset)
        case .top:    chevronCenter = CGPoint(x: mid, y: mid + centroidOffset)
        }

        let chevronView: UIImageView
        if let existing = navAssistChevron {
            existing.image = chevronImage
            chevronView = existing
        } else {
            let v = UIImageView(image: chevronImage)
            v.tintColor = .white
            v.contentMode = .center
            button.viewWithTag(100)?.isHidden = true
            button.addSubview(v)
            navAssistChevron = v
            chevronView = v
        }
        chevronView.sizeToFit()
        chevronView.center = chevronCenter

        // See-through while stashed (down from the default), but the frosted
        // background stays so the chevron keeps contrast against app content.
        moveNavAssist(button, to: clampNavAssistCenter(newCenter, in: screenBounds), alpha: 0.55, animated: animated)
    }
    
    private func unstashNavAssist() {
        guard let button = navAssistButton else { return }
        // Slides back in from whichever edge it was stashed against, to the same
        // resting place a drag to that edge would have left it in.
        placeNavAssist(button, stashed: false, animated: true)
    }
    
    // Find and bring corresponding multitask view to front
    /// `fromRect` is the thing on screen the window should come out of, in window
    /// coordinates — a switcher card, which is already showing the app at a known
    /// size and place. `from` is the weaker form for a caller that knows only
    /// where a finger landed.
    func bringMultitaskViewToFront(uuid: String, from center: CGPoint? = nil,
                                   fromRect: CGRect? = nil) -> Bool {
        // Use the same foreground-active resolution as `keyWindow` rather than the
        // unordered `connectedScenes.first`, so a restored/background scene from a
        // previous launch can't be searched instead of the live one.
        guard let windowScene = keyWindow?.windowScene else {
            return false
        }
        
        // Capture snapshot of the current frontmost app before switching away from it
        if let currentFrontmost = self.frontmostAppUUID, currentFrontmost != uuid {
            captureSnapshot(for: currentFrontmost)
        }

        for window in windowScene.windows {
            if let targetView = findMultitaskView(in: window, withUUID: uuid) {
                passURLSchemeToView(targetView)
                // The window being left behind takes its modals with it. Windows here
                // are always maximized, so a sheet belonging to one of them would
                // otherwise be left sitting over the window arriving in its place —
                // the switcher's path to another app never minimizes the old one.
                for other in self.apps where other.appUUID != uuid {
                    self.dismissPresentation(forAppUUID: other.appUUID)
                }
                let source = fromRect ?? center.map(LCMinimizeToIconAnimator.sourceRect(around:))
                // A card is already showing this app, so the window grows out of it
                // opaque. Everywhere else it comes out of an icon, which it has to
                // fade in over.
                animateViewAppearance(targetView, from: source, fadesIn: fromRect == nil,
                                      in: window)
                let wasHomeState = self.isHomeState
                self.isHomeState = false
                self.frontmostAppUUID = uuid
                // Move app to end so it's most recent (for home screen icon ordering)
                if let idx = self.apps.firstIndex(where: { $0.appUUID == uuid }) {
                    let app = self.apps.remove(at: idx)
                    self.apps.append(app)
                }
                if wasHomeState {
                    self.showDock()
                } else {
                    self.updateDockFrame()
                }
                self.ensureControlAccessible()
                return true
            }
        }
        
        return false
    }

    private func passURLSchemeToView(_ view: UIView) {
        if let launchUrl = UserDefaults.standard.string(forKey: "launchAppUrlScheme") {
            UserDefaults.standard.removeObject(forKey: "launchAppUrlScheme")
            if let decoratedVC = view._viewDelegate() as? DecoratedAppSceneViewController {
                decoratedVC.appSceneVC.openURLScheme(launchUrl)
            }
        }
    }

    private func animateViewAppearance(_ view: UIView, from source: CGRect?,
                                       fadesIn: Bool = true, in window: UIWindow) {
        let isHidden = view.isHidden || view.alpha < 0.1
        let decoratedVC = view._viewDelegate() as? DecoratedAppSceneViewController
        let isMaximized = decoratedVC?.isMaximized ?? false
        
        // when a fullscreen multitask app is brought to front, optionally hide other windows
        if UserDefaults.lcShared().bool(forKey: "LCMaxOneAppOnStage") && isMaximized {
            // They are making way rather than going home, so the one on top fades
            // and the rest simply go. Every window fading at once read as the stack
            // being scattered by an app being opened.
            MultitaskDockManager.shared.minimizeAllWindows(except: decoratedVC, style: .fade)
        }
        
        if isHidden {
            view.layer.removeAllAnimations()
            view.isHidden = true
            view.transform = .identity
            // Asked through hasShared first: un-minimizing a window must not be
            // what constructs the PiP manager. If it does not exist there is no
            // PiP to stop, so the scale-in below is already the right branch.
            if PiPManager.hasShared, let pipManager = PiPManager.shared,
               let decoratedVC = view._viewDelegate(), pipManager.isPiP(withDecoratedVC: decoratedVC) {
                pipManager.stopPiP()
                view.isHidden = false
                view.alpha = 1
                self.bringViewToFront(view, in: window)
            } else {
                // Out of the icon it went into: the way home, run backwards. A
                // window pressed in the switcher comes out of its card instead,
                // that being what the user just touched.
                self.bringViewToFront(view, in: window)
                LCMinimizeToIconAnimator.expand(
                    view,
                    fromItemID: self.apps.first { $0.view === view }?.springboardItemID,
                    sourceInWindow: source,
                    fadesIn: fadesIn
                )
            }
        } else {
            bringViewToFront(view, in: window)

            // The pulse that acknowledges a tap on an already-visible window is
            // motion for its own sake — the window is where it was either way —
            // so under Reduce Motion it is simply brought forward.
            guard !UIAccessibility.isReduceMotionEnabled else { return }

            UIView.animate(withDuration: Constants.shortAnimationDuration1, animations: {
                let scale = Constants.bringToFrontScale
                view.transform = CGAffineTransform(scaleX: scale, y: scale)
            }) { _ in
                UIView.animate(withDuration: Constants.shortAnimationDuration2) {
                    view.transform = .identity
                }
            }
        }
    }

    private func bringViewToFront(_ view: UIView, in window: UIWindow) {
        if let superview = view.superview {
            superview.bringSubviewToFront(view)
        }
        if let windowSuperview = window.superview {
            windowSuperview.bringSubviewToFront(window)
        }
    }
    
    // Recursively find multitask view
    private func findMultitaskView(in view: UIView, withUUID uuid: String) -> UIView? {
        apps.first { $0.appUUID == uuid }?.view
    }
    
    // Get view's dataUUID property through reflection
    private func getDataUUID(from view: UIView) -> String? {
        let mirror = Mirror(reflecting: view)
        
        if let child = (mirror.children.first { $0.label == "dataUUID" })?.value as? String {
            return child
        }
        
        if view.responds(to: NSSelectorFromString("dataUUID")) {
            return view.value(forKey: "dataUUID") as? String
        }
        
        return nil
    }
    
    @objc public func addRunningAppWithInfo(_ appInfo: LCAppInfo?, appUUID: String, view: UIView?) {
        guard isDockEnabled() else { return }
        
        if apps.contains(where: { $0.appUUID == appUUID }) {
            return
        }
        
        let appName = appInfo?.displayName() ?? "Unknown App"
        let appModel = DockAppModel(appName: appName, appUUID: appUUID, appInfo: appInfo, view: view)

        // Hidden the instant it is registered, not when the animation gets around
        // to it. The window is added to the hierarchy at full size by its own
        // construction, and the opening runs a turn of the run loop later — long
        // enough for one frame of a full-screen window to be drawn before it
        // collapses onto its icon to grow back out of it.
        view?.alpha = 0
        if let view {
            self.attachLaunchPlaceholder(to: view, appInfo: appInfo)
        }

        DispatchQueue.main.async {
            self.apps.append(appModel)
            self.frontmostAppUUID = appUUID
            self.isHomeState = false

            // Opens at once, carrying the app's launch screen. The guest has drawn
            // nothing yet, but its bundle has been readable all along, so there is
            // something to open *with* — and nothing has to wait. The placeholder
            // is dropped once the guest has content behind it.
            if let view {
                LCMinimizeToIconAnimator.expand(view, fromItemID: appModel.springboardItemID)
            }

            // The bar comes up with the window, never ahead of it: it is the
            // control for a foreground window, and on a screen that still shows
            // the springboard it is both a lie and — since `goHome` decides by
            // what is visible — a button that would open the app rather than
            // leave it.
            if !self.isVisible {
                self.showDock()
            } else {
                self.updateDockFrame()
                // Dock already up: reconcile the control with the saved
                // preference so opening another app applies a changed choice.
                self.applyPreferredControl()
            }
            self.ensureControlAccessible()
        }
    }
    
    /// Open a built-in page (Settings, Installer, FlekStore) as a multitask window
    public func openInternalPage<Content: View>(kind: String, uuid: String, name: String, @ViewBuilder content: () -> Content) {
        guard isDockEnabled() else { return }
        
        // If already open, just bring to front
        if apps.contains(where: { $0.appUUID == uuid }) {
            let _ = bringMultitaskViewToFront(uuid: uuid)
            return
        }
        
        let hostVC = UIHostingController(rootView: AnyView(content()))
        hostVC.view.frame = windowHostingView.bounds
        hostVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if isSwitcherBarVisible {
            applyBarInset(to: hostVC, reserved: true)
        }

        // Add as child view controller so the hosting controller inherits
        // proper safe area insets (status bar, etc.) for correct nav bar layout
        if let rootVC = keyWindow?.rootViewController {
            rootVC.addChild(hostVC)
            windowHostingView.addSubview(hostVC.view)
            hostVC.didMove(toParent: rootVC)
        } else {
            windowHostingView.addSubview(hostVC.view)
        }
        
        internalPageControllers[uuid] = hostVC
        // Hidden from the moment it is in the hierarchy, so the frame before the
        // opening animation starts is not a full-screen page appearing whole.
        hostVC.view.alpha = 0

        let appModel = DockAppModel(appName: name, appUUID: uuid, view: hostVC.view, internalPageKind: kind)
        
        DispatchQueue.main.async {
            self.apps.append(appModel)
            self.frontmostAppUUID = uuid
            self.isHomeState = false

            // Out of its own icon, the same as a guest app — this page used to
            // simply be there, one frame absent and the next full screen.
            LCMinimizeToIconAnimator.expand(hostVC.view, fromItemID: appModel.springboardItemID)

            if !self.isVisible {
                self.showDock()
            } else {
                self.updateDockFrame()
                // Dock already up: reconcile the control with the saved
                // preference so opening another app applies a changed choice.
                self.applyPreferredControl()
            }
            self.ensureControlAccessible()
        }
    }
    
    // MARK: - A Window's Modals

    /// The controller a window's modals are presented from: the hosting controller
    /// for a built-in page, the decorated controller for a guest window.
    private func presentingController(forAppUUID uuid: String) -> UIViewController? {
        if let page = internalPageControllers[uuid] { return page }
        return apps.first { $0.appUUID == uuid }?.view?._viewDelegate() as? DecoratedAppSceneViewController
    }

    /// Closes whatever a window has presented — a sheet, a cover, an alert — as the
    /// window leaves the screen.
    ///
    /// UIKit puts a presentation in the *window*, beside the page that raised it
    /// rather than inside it, so hiding the page leaves its sheet behind. Nothing
    /// could reach that state while the bar sat underneath every presentation —
    /// there was no way to press home or switch windows with a sheet open — but now
    /// that the bar is above them, going home would strand the sheet over the
    /// springboard.
    ///
    /// Closed rather than hidden along with the page. A sheet is not simply a view
    /// laid over the window: UIKit re-hosts the presenting content inside the
    /// presentation to build the card stack, so putting the container away takes
    /// parts of the app with it and leaves the presentation half-live — reachable
    /// by neither the page nor the springboard. Dismissing is the only way to get
    /// the window back into a state UIKit agrees with.
    ///
    /// `then` runs once the window is out of that card stack and back in the
    /// window on its own, which is what any animation of the window has to wait
    /// for. Starting the minimize alongside the dismissal instead flew a page that
    /// was still hosted inside the presentation: the page shrank into its icon
    /// while the sheet stayed put on top of the springboard, and only caught up
    /// when UIKit finished unwinding the presentation a beat later. It runs
    /// straight away — same turn, no dispatch — when there is nothing presented,
    /// so the common path keeps the timing it always had.
    private func dismissPresentation(forAppUUID uuid: String, then: (() -> Void)? = nil) {
        guard let controller = presentingController(forAppUUID: uuid),
              controller.presentedViewController != nil else {
            then?()
            return
        }
        controller.dismiss(animated: false) { then?() }
    }

    /// A newly launched window has something to show, and now makes its entrance
    /// out of the icon it was launched from.
    ///
    /// Until this runs the window is invisible and the springboard is what the
    /// user is looking at, which is the point: a window opened the instant its
    /// icon is pressed spends its first stretch as a black rectangle, because the
    /// guest process renders on its own schedule. Growing that out of an icon
    /// replaces the home screen with nothing. The home screen keeps the screen
    /// until the app can take it.
    @objc private func windowContentDidArrive(_ note: Notification) {
        guard let view = note.object as? UIView else { return }
        DispatchQueue.main.async {
            // Remembered even when there is nothing to drop yet. The guest reports
            // once and only once, so a report that arrives before the window has
            // been given its launch screen must not be the report that is lost —
            // that is a stand-in left covering a running app for good.
            self.windowsWithContent.insert(ObjectIdentifier(view))

            // Whatever the window opened with has served its purpose: the guest is
            // drawing its own first frame behind it now, which for most apps is the
            // very launch screen this was standing in for — so the two crossing
            // over is not something there is anything to see.
            guard let placeholder = self.launchPlaceholders.removeValue(forKey: ObjectIdentifier(view)) else { return }
            self.fadeOutLaunchPlaceholder(placeholder)
        }
    }

    private func fadeOutLaunchPlaceholder(_ placeholder: UIView) {
        UIView.animate(withDuration: Constants.standardAnimationDuration, delay: 0,
                       options: [.curveEaseInOut, .beginFromCurrentState]) {
            placeholder.alpha = 0
        } completion: { _ in
            placeholder.removeFromSuperview()
        }
    }

    /// Puts the app's launch screen into a window that has not opened yet, so it
    /// has something of its own to open with. Kept here rather than on the window
    /// so that dropping it later does not depend on the guest still being around
    /// to be asked.
    private func attachLaunchPlaceholder(to view: UIView, appInfo: LCAppInfo?) {
        // The guest got there first: it is already drawing, so there is nothing
        // for a launch screen to stand in for.
        guard !windowsWithContent.contains(ObjectIdentifier(view)) else { return }
        guard let placeholder = LCLaunchPlaceholder.view(for: appInfo) else { return }
        // Pinned rather than framed: the window is handed this while it is still
        // being assembled, and is given its real size only once the guest's scene
        // reports in — by which time the placeholder has to have followed it.
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.topAnchor.constraint(equalTo: view.topAnchor),
            placeholder.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            placeholder.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        launchPlaceholders[ObjectIdentifier(view)] = placeholder
    }

    /// How windows leave when several are put away at once. Whichever it is, at
    /// most one of them moves: several windows animating together reads as the
    /// stack being scattered rather than an app being put away.
    enum WindowExit {
        /// Going home. The window on top shrinks into its own icon.
        case intoIcons
        /// Making way for a window being brought forward. The one on top fades;
        /// there is no icon it is going to.
        case fade
        /// Underneath somebody else's choreography — the switcher's own way home,
        /// where the overlay is clearing to reveal the springboard. Any movement
        /// of ours would be seen through it, so there is none.
        case immediate
    }

    @objc public func minimizeAllWindows(except: DecoratedAppSceneViewController? = nil) {
        minimizeAllWindows(except: except, style: .fade)
    }

    /// `intoIcons` is the home button's path: a built-in page shrinks into its
    /// own springboard icon on the way out. Every other caller — switching apps,
    /// the switcher's own way back — has its own choreography over the top of
    /// this, so there the page just goes.
    func minimizeAllWindows(except: DecoratedAppSceneViewController? = nil, style: WindowExit) {
        DispatchQueue.main.async {
            // Capture snapshots of visible windows before minimizing them
            for app in self.apps {
                self.captureSnapshot(for: app.appUUID)
            }
            // Only the window on top flies home. Hopping between apps in the
            // switcher leaves the ones behind visible but covered — nothing hides
            // them, they are simply underneath — and flying those as well sends
            // several windows shrinking out from under the top one at once, a home
            // button that scatters the whole stack instead of putting away the app
            // in front of you. The rest go without a move of their own, so what the
            // flying window uncovers is the springboard.
            let flying = style == .immediate ? nil : self.frontmostVisibleWindow()
            // What the flying window actually covers. A maximized window covers the
            // whole stack, which is the usual case; a windowed guest covers little
            // or nothing, and those windows are genuinely on screen beside it, so
            // they keep an exit of their own rather than blinking out.
            let covered = flying?.frame ?? .null
            self.apps.forEach { app in
                if app.isInternalPage {
                    guard let pageView = app.view else { return }
                    // The page's sheet goes first and the flight waits for it, so the
                    // page leaves from the window rather than from inside the
                    // presentation it was hosted in.
                    self.dismissPresentation(forAppUUID: app.appUUID) {
                        if style == .intoIcons, pageView === flying,
                           let itemID = app.springboardItemID {
                            LCMinimizeToIconAnimator.minimize(pageView, toItemID: itemID)
                        } else {
                            pageView.isHidden = true
                        }
                    }
                } else if let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController,
                   vc != except {
                    self.dismissPresentation(forAppUUID: app.appUUID) {
                        app.view?.layer.removeAllAnimations()
                        // A guest window goes into its own icon too. It has to fly the
                        // live view — a guest renders into a layer hosted by the render
                        // server, which this process cannot snapshot — and then be left
                        // in the resting state the window class expects, which is what
                        // `finishMinimizeWindow` is for.
                        if style == .intoIcons, let guestView = app.view,
                           guestView === flying, let itemID = app.springboardItemID {
                            LCMinimizeToIconAnimator.minimize(guestView, toItemID: itemID) {
                                vc.finishMinimizeWindow()
                            }
                        } else if style == .immediate {
                            vc.finishMinimizeWindow()
                        } else if let guestView = app.view, guestView !== flying,
                                  covered.contains(guestView.frame) {
                            // Out of sight behind the window that is leaving, so it
                            // needs no exit of its own — and must not draw one, or it
                            // is seen moving as that window uncovers it.
                            vc.finishMinimizeWindow()
                        } else {
                            vc.minimizeWindow()
                        }
                    }
                }
            }
        }
    }

    /// The window the user is actually looking at: the topmost of the host's
    /// stack that is neither hidden nor transparent. Read from the view order
    /// rather than from `frontmostAppUUID`, which records what was last brought
    /// forward and not what is on top of the screen now.
    private func frontmostVisibleWindow() -> UIView? {
        let windows = Set(apps.compactMap { $0.view }.map(ObjectIdentifier.init))
        return windowHostingView.subviews.last {
            windows.contains(ObjectIdentifier($0)) && !$0.isHidden && $0.alpha > 0.1
        }
    }
    
    // MARK: - App Switcher Overlay
    
    /// Capture the springboard (wallpaper + icons) as a still image, excluding
    /// the live guest-app windows, so the switcher can show it blurred behind the
    /// cards (matching Spotlight's blurred home). Renders the layer tree with the
    /// app-window host hidden; `isHidden` is honoured by layer rendering without a
    /// screen update, so hiding + restoring in place causes no flicker.
    func captureSpringboardSnapshot() {
        guard let rootView = keyWindow?.rootViewController?.view,
              rootView.bounds.width > 0, rootView.bounds.height > 0 else { return }
        let wasHidden = windowHostingView.isHidden
        windowHostingView.isHidden = true

        // UIVisualEffectView blurs (the list rows' .ultraThinMaterial glass, the
        // bottom variable blur, glass controls) are extremely slow to rasterize
        // via `layer.render(in:)` and dominated the capture time (list ~240ms).
        // The snapshot is only ever shown heavily blurred behind the switcher
        // cards, so hide them for the render and restore immediately (same run
        // loop, no screen update = no flicker).
        var hiddenEffectViews: [UIView] = []
        func hideEffectViews(in view: UIView) {
            for sub in view.subviews {
                if sub is UIVisualEffectView, !sub.isHidden {
                    sub.isHidden = true
                    hiddenEffectViews.append(sub)
                }
                hideEffectViews(in: sub)
            }
        }
        hideEffectViews(in: rootView)

        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        // Blurred behind the cards anyway — render at 1x, not full retina.
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(bounds: rootView.bounds, format: format)
        let image = renderer.image { ctx in
            rootView.layer.render(in: ctx.cgContext)
        }

        for v in hiddenEffectViews { v.isHidden = false }
        windowHostingView.isHidden = wasHidden
        springboardSnapshot = image
    }

    func captureSnapshots() {
        // Only attempt fresh snapshots for currently visible apps.
        // Keep existing cached snapshots for hidden/minimized apps,
        // since drawHierarchy cannot capture CARemoteLayer content
        // from child processes when views are not actively rendered.
        for app in apps {
            guard let appView = app.view else { continue }
            if !appView.isHidden && appView.alpha > 0.1 {
                captureSnapshot(for: app.appUUID)
            }
        }
    }
    
    /// Capture a snapshot of a single app's view while it's currently visible on screen.
    /// Must be called while the view is still rendering (before any minimize/hide animation).
    /// Snapshots the app view directly (not the window) so each app captures its own
    /// layer tree, avoiding cross-contamination when multiple apps overlap on screen.
    func captureSnapshot(for appUUID: String) {
        guard let app = apps.first(where: { $0.appUUID == appUUID }),
              let appView = app.view,
              !appView.isHidden, appView.alpha > 0.1 else { return }
        
        // The quarter turn a landscape capture needs to stand upright in a PORTRAIT
        // card, so it fills one rather than sitting as a band between black margins.
        // Which way to turn depends on the edge the user rotated towards, so the
        // content ends up the same way up as when they were looking at it.
        //
        // Recorded, not applied. Whether the card is portrait is not knowable here:
        // on iPad the card takes the shape of the screen, so it is landscape whenever
        // the device is, and the device can turn while the switcher is open. The card
        // applies this itself, against the shape it actually has.
        //
        // Decided from the view's own shape rather than from the trimmed capture,
        // because the trim below depends on this turn and so cannot be what fixes it.
        // The two never disagree: a trim takes a strip off an edge, which is nowhere
        // near enough to stand a landscape view on its end.
        var quarterTurn: CGFloat = 0
        if appView.bounds.width > appView.bounds.height {
            let interfaceOrientation = appView.window?.windowScene?.interfaceOrientation
                ?? keyWindow?.windowScene?.interfaceOrientation
            switch interfaceOrientation {
            case .landscapeLeft:
                quarterTurn = -.pi / 2
            case .landscapeRight:
                quarterTurn = .pi / 2
            default:
                // The interface is portrait but the capture is not: a landscape-only
                // guest rendering sideways inside an upright host. The interface can't
                // say which way it is being read, so use the device. Note the axes are
                // mirrored — device landscapeLeft is interface landscapeRight.
                quarterTurn = UIDevice.current.orientation == .landscapeLeft ? .pi / 2 : -.pi / 2
            }
        }

        // Capture the content region, dropping the safe-area periphery on every edge
        // except the one that ends up along the TOP of the card. The guest is handed
        // those insets as `peripheryInsets` and fills them with its own background,
        // which on screen reads as the status-bar and home-indicator strips. The home
        // indicator and the side strips are dead margin once the app is in a card, but
        // the status bar is part of how the app actually looked, and the system's own
        // switcher keeps it — so this one does too. Internal pages are trimmed for a
        // second reason: they pin their bottom controls above the switcher bar, and
        // that reserved strip is part of the safe area as well.
        //
        // Which edge survives depends on the turn the card will apply. A portrait
        // capture is drawn as it was taken, so it is the capture's own top. A landscape
        // capture is stood upright, and the turn carries one of its sides up there —
        // clockwise brings the left edge to the top, counter-clockwise the right one.
        //
        // The capture's own top is kept in every case as well, not just the unturned
        // one. It costs nothing where the turn is what matters (a phone held in
        // landscape has no top inset to keep), and it covers the one case the turn
        // cannot: an iPad, whose card takes the screen's shape, so a landscape capture
        // is drawn flat in a landscape card with its top edge still on top.
        var trim = appView.safeAreaInsets
        trim.top = 0
        if quarterTurn > 0 {
            trim.left = 0
        } else if quarterTurn < 0 {
            trim.right = 0
        }
        let captureRect = appView.bounds.inset(by: trim)
        let viewSize = captureRect.size
        guard viewSize.width > 0 && viewSize.height > 0 else { return }

        appSnapshotRotations[appUUID] = quarterTurn

        // A frozen bitmap of the app exactly as it looks right now. `drawHierarchy`
        // renders through the render server, so unlike `layer.render(in:)` it can
        // capture the guest's hosted layer — but only while the view is actually on
        // screen, which is the moment this runs. `afterScreenUpdates: true` is what
        // makes the hosted content resolve; with `false` the guest's layer has not
        // been committed into the context and comes back blank.
        // Internal pages only. A guest app renders into a remote layer composited by
        // the render server, and the host process cannot read those pixels back:
        // `drawHierarchy` reports success — it did draw the local hierarchy — but the
        // guest's content simply is not in it, so the bitmap comes out black. Internal
        // pages are ordinary in-process views and capture correctly.
        if app.isInternalPage {
            let renderer = UIGraphicsImageRenderer(size: viewSize)
            var drawn = false
            let image = renderer.image { _ in
                drawn = appView.drawHierarchy(
                    in: CGRect(origin: CGPoint(x: -captureRect.origin.x, y: -captureRect.origin.y),
                               size: appView.bounds.size),
                    afterScreenUpdates: true)
            }
            if drawn {
                // Stored as captured; the card turns it when it draws it.
                appSnapshotImages[appUUID] = image
                appSnapshotSizes[appUUID] = viewSize
            } else {
                appSnapshotImages.removeValue(forKey: appUUID)
            }
        } else {
            appSnapshotImages.removeValue(forKey: appUUID)
        }

        // Replicant fallback, for when the bitmap capture comes back empty.
        // Using the view (not the window) ensures we get this specific app's
        // layer tree including CARemoteLayer content, rather than whatever
        // happens to be visually on top at the same screen position.
        if let viewSnapshot = appView.resizableSnapshotView(
            from: captureRect,
            afterScreenUpdates: false,
            withCapInsets: .zero
        ) {
            viewSnapshot.frame = CGRect(origin: .zero, size: viewSize)
            appSnapshotViews[appUUID] = viewSnapshot
            appSnapshotSizes[appUUID] = viewSize
            return
        }
        
        // Fallback: snapshot the content view directly
        if let decoratedVC = appView._viewDelegate() as? DecoratedAppSceneViewController,
           let contentView = decoratedVC.appSceneVC.contentView,
           let viewSnapshot = contentView.snapshotView(afterScreenUpdates: false) {
            appSnapshotViews[appUUID] = viewSnapshot
            appSnapshotSizes[appUUID] = viewSnapshot.bounds.size
        }
    }
    
    /// The turn a card should apply to a capture, given the shape the card has now.
    /// Zero for a landscape card: the turn only ever existed to stand a landscape
    /// capture up in a portrait one, and applying it to a card that is already
    /// landscape lays the app on its side in a frame that matched it.
    func cardSnapshotRotation(for appUUID: String, portraitCard: Bool) -> CGFloat {
        guard portraitCard else { return 0 }
        return appSnapshotRotations[appUUID] ?? 0
    }

    /// Opens the switcher, first making sure the window is actually portrait.
    ///
    /// The overlay is portrait-only, but requesting the rotation and building the
    /// overlay in the same pass laid it out against the *outgoing* landscape window —
    /// the rotation only lands a runloop or two later. The first rendered frame was
    /// therefore sized from landscape geometry, and if the system declined the
    /// request altogether the overlay simply stayed there, portrait layout inside a
    /// landscape window. Waiting for the window to actually turn removes both cases.
    func showAppSwitcher() {
        guard let keyWindow = self.keyWindow else { return }

        // Snapshot the running apps before any rotation, so a card shows the app as
        // it actually looked. Capturing afterwards would catch it mid-turn or already
        // re-laid out for a portrait window it is about to leave again.
        captureSnapshots()

        // Lock now and synchronously — `refreshOrientationLock` defers to the next
        // runloop, which is already too late for the presentation below.
        orientationBeforeSwitcher = keyWindow.windowScene?.interfaceOrientation
        AppDelegate.orientationLock = .portrait
        keyWindow.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()

        if let scene = keyWindow.windowScene, scene.interfaceOrientation.isLandscape {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            whenWindowIsPortrait(keyWindow) { [weak self] in
                self?.presentAppSwitcher(in: keyWindow)
            }
            return
        }
        presentAppSwitcher(in: keyWindow)
    }

    /// Calls `body` once the window has finished rotating to portrait, or after a
    /// short grace period if it never does — the switcher must open either way, and
    /// a device with rotation locked at the system level never turns at all.
    private func whenWindowIsPortrait(_ window: UIWindow, attempt: Int = 0, _ body: @escaping () -> Void) {
        let isPortrait = window.bounds.height >= window.bounds.width
        guard !isPortrait, attempt < 12 else {
            body()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
            self?.whenWindowIsPortrait(window, attempt: attempt + 1, body)
        }
    }

    private func presentAppSwitcher(in keyWindow: UIWindow) {
        // Ensure the design is captured before the overlay's bottom toggle renders,
        // so it uses the real corner radius (not the uncaptured default) — otherwise,
        // if the switcher is opened in floating-button mode, the toggle draws an
        // over-tall solid chin.
        captureBarDesign()

        // The springboard snapshot is the overlay's blurred backdrop, so it is taken
        // here — after any rotation — to match the portrait overlay it sits behind.
        captureSpringboardSnapshot()
        refreshCachedSafeAreaInsets()
        // Sync the preference to whatever control is actually active right now,
        // so the overlay's toggle reflects the current state — the user may have
        // switched between the bar and the floating button in-app since it was
        // last changed here.
        setPrefersFloatingButton(!isSwitcherBarVisible)
        isAppSwitcherOpen = true
        // The portrait lock was applied in `showAppSwitcher` before we waited for the
        // window to turn; this keeps the rest of the orientation state consistent.
        refreshOrientationLock()

        // Always recreate the overlay so it picks up the latest apps & snapshots
        switcherOverlayController?.view.removeFromSuperview()

        // Resolve the window's safe area before the overlay reads it, so the bottom
        // toggle bar's height (effectiveBarHeight + safeAreaInsets.bottom) is stable
        // instead of occasionally rendering with a not-yet-ready zero inset — the
        // "randomly taller/shorter" toggle. Pairs with the same guard in updateDockFrame.
        keyWindow.layoutIfNeeded()
        // Size the cards for the orientation the overlay is about to open in.
        refreshSwitcherScreenSize(animated: false)

        let overlayView = AnyView(
            AppSwitcherOverlay()
                .environmentObject(self)
                .preferredColorScheme(.dark)
                .environment(\.colorScheme, .dark)
        )
        let hc = UIHostingController(rootView: overlayView)
        // Opaque black on the hosting view (which fills the whole window) so the
        // very bottom / home-indicator region is always covered — even when the
        // SwiftUI content is inset by a guest app's bottom safe area, which
        // otherwise left the springboard showing through as a gap under the bar.
        hc.view.backgroundColor = .black
        hc.view.frame = keyWindow.bounds
        hc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hc.overrideUserInterfaceStyle = .dark
        switcherOverlayController = hc
        
        hc.view.alpha = 0
        // Into the overlay window, above the bar it replaces — and, like the bar,
        // above anything the app has presented in its own window.
        (overlayHostView() ?? keyWindow).addSubview(hc.view)
        // Force a full layout + render pass while the overlay is still invisible,
        // so its blurred background, cards and bottom bar are all drawn before the
        // fade starts. Without this the first visible frames show the bare black
        // backdrop and everything "pops in" a frame later — the blink/reload.
        hc.view.setNeedsLayout()
        hc.view.layoutIfNeeded()

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        
        // Keep the existing bottom bar at full opacity underneath during the
        // entrance. Its black rounded region is identical to the overlay's own
        // bottom bar, so leaving it solid means the bar never cross-fades — only
        // the "buttons" on it appear to change, instead of the whole bar blinking
        // as the overlay dissolves in over transparent content.
        UIView.animate(
            withDuration: Constants.standardAnimationDuration,
            delay: 0,
            usingSpringWithDamping: 0.85,
            initialSpringVelocity: 0,
            // A view being animated by UIKit does not receive touches unless it is
            // asked to. Without this the overlay ignores everything for the length
            // of its own entrance: the switcher is fully drawn and plainly there,
            // and the first tap or swipe onto a card does nothing.
            options: [.curveEaseOut, .allowUserInteraction]
        ) {
            hc.view.alpha = 1
        } completion: { _ in
            // Overlay is fully opaque on top now, so hiding the bar underneath
            // has no visible effect — it just keeps the bar's state consistent
            // for the exit path.
            self.hostingController?.view.alpha = 0
        }
    }
    
    /// Return to the springboard from the app switcher: minimize every window so
    /// the real home is behind the overlay, then remove the overlay after its exit
    /// animation. Kept separate from `dismissAppSwitcher` so the host is removed
    /// without the fade/scale (the SwiftUI content animates itself out).
    func goToSpringboardFromSwitcher() {
        guard isAppSwitcherOpen else { return }
        isAppSwitcherOpen = false
        // The overlay above is already clearing to reveal the springboard, and a
        // window moving underneath it is seen through it. They go without a move.
        minimizeAllWindows(style: .immediate)
        updateFrontmostApp()
        isHomeState = true
        hideDock()
        refreshOrientationLock()
        guard let overlay = switcherOverlayController else { return }
        // Clear the overlay's opaque backdrop so the LIVE springboard behind it (its
        // glass already rendering) shows through as the switcher content animates out —
        // cards slide left, buttons drop, and the blurred-home background fades away.
        // Revealing the live springboard (not the glass-less snapshot) is what keeps the
        // icon glass consistent, matching Close all / the Home button.
        overlay.view.backgroundColor = .clear
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
            overlay.view.removeFromSuperview()
            overlay.view.transform = .identity
            self.springboardSnapshot = nil
            self.ensureControlAccessible()
        }
    }

    /// Puts the interface back where it was before the switcher forced portrait.
    ///
    /// Releasing the lock is not enough on its own: `.allButUpsideDown` still includes
    /// portrait, so UIKit has no reason to leave it, and no fresh device-orientation
    /// event arrives if the phone never physically moved. Without an explicit request
    /// the app returns upright even though it is being held sideways.
    private func restoreOrientationAfterSwitcher() {
        guard let scene = keyWindow?.windowScene else { return }

        // Follow the device where it can say — that way turning the phone while the
        // switcher was open wins over what we recorded — and fall back to the recorded
        // orientation when it cannot (face up, flat on a table, unknown).
        let target: UIInterfaceOrientation
        switch UIDevice.current.orientation {
        case .landscapeLeft: target = .landscapeRight   // device and interface axes are mirrored
        case .landscapeRight: target = .landscapeLeft
        case .portrait: target = .portrait
        default: target = orientationBeforeSwitcher ?? scene.interfaceOrientation
        }
        orientationBeforeSwitcher = nil
        guard target != scene.interfaceOrientation else { return }

        let mask: UIInterfaceOrientationMask
        switch target {
        case .landscapeLeft: mask = .landscapeLeft
        case .landscapeRight: mask = .landscapeRight
        default: mask = .portrait
        }
        // The lock still says portrait-only at this point; widen it first or the
        // request is refused against the supported set.
        AppDelegate.orientationLock = .allButUpsideDown
        keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }

    func dismissAppSwitcher() {
        isAppSwitcherOpen = false
        restoreOrientationAfterSwitcher()

        // Put the chosen control into its final state INSTANTLY (no transition)
        // so it's already in place behind the overlay before it fades — the app
        // is revealed already showing the correct control, with no bar flash.
        applyPreferredControlInstant()

        // Restore normal rotation now that the portrait-only overlay is closing.
        refreshOrientationLock()

        guard let overlay = switcherOverlayController else { return }

        UIView.animate(
            withDuration: Constants.shortAnimationDuration1,
            delay: 0,
            options: .curveEaseIn
        ) {
            overlay.view.alpha = 0
            overlay.view.transform = CGAffineTransform(scaleX: 1.05, y: 1.05)
        } completion: { _ in
            overlay.view.removeFromSuperview()
            overlay.view.transform = .identity
            self.springboardSnapshot = nil
            self.ensureControlAccessible()
        }
    }

    /// Puts the multitask control into its final state for the saved preference
    /// with NO animation, so when the switcher overlay is removed the correct
    /// control (bar or floating button) is already in place — no transition and
    /// no chance for `ensureControlAccessible` to briefly restore the wrong one.
    private func applyPreferredControlInstant() {
        guard isDockEnabled(), !isHomeState, hasForegroundAppWindow(),
              let keyWindow = self.keyWindow else { return }
        if prefersFloatingButton {
            // Floating button mode: keep the bar hidden, show the button now.
            isSwitcherBarVisible = false
            for (_, controller) in internalPageControllers {
                applyBarInset(to: controller, reserved: false)
            }
            hostingController?.view.isHidden = true
            hostingController?.view.alpha = 0
            showNavAssist(in: keyWindow, animated: false)
        } else {
            // Switcher bar mode: remove the floating button, show the bar now.
            navAssistButton?.removeFromSuperview()
            navAssistButton = nil
            isNavAssistStashed = false
            navAssistChevron = nil
            isSwitcherBarVisible = true
            for (_, controller) in internalPageControllers {
                applyBarInset(to: controller, reserved: true)
            }
            updateDockFrame(animated: false)
            hostingController?.view.isHidden = false
            hostingController?.view.alpha = 1
            hostingController?.view.transform = barBaseTransform
        }
        NotificationCenter.default.post(name: .multitaskBarVisibilityChanged, object: nil)
        refreshOrientationLock()
    }

    /// Reconciles the on-screen control with the saved preference. Called when
    /// an app is opened so a preference changed in the switcher takes effect:
    /// shows the floating button or the switcher bar as chosen.
    func applyPreferredControl() {
        guard isDockEnabled(), isVisible else { return }
        if prefersFloatingButton {
            if isSwitcherBarVisible { hideSwitcherBar() }
        } else {
            if !isSwitcherBarVisible { showSwitcherBar() }
        }
    }

    func closeApp(uuid: String) {
        guard let app = apps.first(where: { $0.appUUID == uuid }) else { return }

        if app.isInternalPage {
            let teardown = { [weak self] in
                app.view?.removeFromSuperview()
                self?.internalPageControllers[uuid] = nil
                self?.removeRunningApp(uuid)
            }
            // Its modals go first, with the page still reachable — the teardown
            // drops the controller they would have to be found through — and the
            // flight waits for them, so the snapshot below is of the page itself
            // rather than of a page still hosted inside its own sheet.
            dismissPresentation(forAppUUID: uuid) {
                // A built-in page's own close button is the way home from it, so it
                // makes the same trip into its icon the home button gives the rest.
                // The page itself goes now — a snapshot flies in its place — so the
                // bar and the home state update on time rather than after the flight.
                if let pageView = app.view, !pageView.isHidden, let itemID = app.springboardItemID {
                    LCMinimizeToIconAnimator.minimizeByReplacing(pageView, toItemID: itemID, teardown: teardown)
                } else {
                    teardown()
                }
            }
        } else if let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController {
            vc.closeWindow()
        }
    }

    /// Kicks off a guest app's (asynchronous) process termination WITHOUT
    /// mutating the `apps` list. The switcher removes the card separately on a
    /// fixed, short schedule via `removeRunningApp`, so the reflow of the
    /// remaining cards never has to wait for the app process to actually exit.
    /// Internal pages tear down instantly and are handled entirely by
    /// `removeRunningApp`, so nothing extra is needed for them here.
    func beginAppTeardown(uuid: String) {
        guard let app = apps.first(where: { $0.appUUID == uuid }) else { return }
        if !app.isInternalPage,
           let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController {
            vc.closeWindow()
        }
    }

    func closeAllApps() {
        isClosingAll = true
        
        let totalDelay = 0.3 + Double(apps.count) * 0.05
        
        DispatchQueue.main.asyncAfter(deadline: .now() + totalDelay) { [weak self] in
            guard let self = self else { return }
            let appsToClose = self.apps
            for app in appsToClose {
                self.dismissPresentation(forAppUUID: app.appUUID)
                if app.isInternalPage {
                    app.view?.removeFromSuperview()
                    self.internalPageControllers[app.appUUID] = nil
                } else if let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController {
                    vc.closeWindow()
                }
            }
            self.apps.removeAll { $0.isInternalPage }
            self.isClosingAll = false
            self.isAppSwitcherOpen = false
            if let overlay = self.switcherOverlayController {
                // Faded rather than whipped away. Behind it is the live springboard,
                // and the backdrop it is covering has no glass on its icons — pulling
                // it in one frame made every card's glass snap into existence at once.
                UIView.animate(withDuration: Constants.standardAnimationDuration,
                               delay: 0, options: .curveEaseOut) {
                    overlay.view.alpha = 0
                } completion: { _ in
                    overlay.view.removeFromSuperview()
                    overlay.view.alpha = 1
                }
            }
            // All apps closed: we are back on the springboard.
            self.isHomeState = true
            self.hideDock()
        }
    }
    
    // MARK: - Multitask Mode Check
    private func isDockEnabled() -> Bool {
        let multitaskMode = MultitaskMode(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCMultitaskMode")) ?? .virtualWindow
        return multitaskMode == .virtualWindow
    }
}

// MARK: - Switcher Bar Content View
/// The flat design's fill: a plain rectangle covering only the bar's flat solid
/// part — everything at or below the flat-top line (`inset` = the device corner
/// radius, the same line the rounded design's flat top sits on). Same geometry as
/// the rounded bar, just a square top edge instead of concave corners, and the
/// region above the line stays transparent exactly as it does in the rounded one.
struct BarFlatTop: Shape {
    var inset: CGFloat
    func path(in rect: CGRect) -> Path {
        let top = min(max(inset, 0), rect.height)
        return Path(CGRect(x: rect.minX, y: rect.minY + top,
                           width: rect.width, height: rect.height - top))
    }
}

/// The portrait bar's top edge, unifying the flat and rounded designs into one
/// shape so they can animate into each other (SwiftUI can't tween between two
/// different `Shape` types). `radius` fixes the flat-top line (`inset` below the
/// strip top); `curve` is how far the concave corners rise above that line at the
/// edges — 0 gives a plain square top (flat), `radius` gives the full concave
/// corners (rounded). Interpolating `curve` (the animatable value) morphs between
/// the two while the flat-top line — and therefore the content beneath — stays put.
struct BarTopBar: Shape {
    var radius: CGFloat
    var curve: CGFloat
    var animatableData: CGFloat {
        get { curve }
        set { curve = newValue }
    }
    func path(in rect: CGRect) -> Path {
        let r = min(max(radius, 0), min(rect.width / 2, rect.height))
        let flatTopY = rect.minY + r
        let c = min(max(curve, 0), r)
        var p = Path()
        if c <= 0.5 {
            // Flat: plain rectangle from the flat-top line down.
            p.addRect(CGRect(x: rect.minX, y: flatTopY,
                             width: rect.width, height: rect.maxY - flatTopY))
            return p
        }
        // Concave corners rising `c` above the flat top at each edge.
        p.move(to: CGPoint(x: rect.minX, y: flatTopY - c))
        p.addQuadCurve(to: CGPoint(x: rect.minX + c, y: flatTopY),
                       control: CGPoint(x: rect.minX, y: flatTopY))
        p.addLine(to: CGPoint(x: rect.maxX - c, y: flatTopY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: flatTopY - c),
                       control: CGPoint(x: rect.maxX, y: flatTopY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// Full-window container that hosts the switcher bar and restricts touches to the
/// bar's actual visible shape. The bar's hosting view is a full rectangular strip,
/// but its concave top corners and the transparent overhang above the bar sit over
/// live content (guest apps and internal pages) — without this, those regions
/// swallow taps meant for controls beneath them (e.g. the installer's Import IPA
/// and search buttons). Points outside the provided shape return nil so the touch
/// falls through to whatever is behind the container.
/// Invisible, non-interactive full-window view whose `safeAreaInsetsDidChange`
/// lets the dock re-lay out the bar when the window's safe area updates. On a cold
/// relaunch (and some scene transitions) the safe area is populated a beat *after*
/// the bar first appears, and nothing else re-lays the bar out for a pure safe-area
/// change — so without this the bar keeps the stale (often zero-bottom) size it was
/// first laid out with, which is the "wrong size after relaunch" symptom.
final class SafeAreaSentinelView: UIView {
    var onChange: (() -> Void)?
    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        onChange?()
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

/// The window the multitask bar and its companions live in, one level above the
/// app's own so that nothing presented inside the app can come up over them.
///
/// Transparent to any touch that misses their content: the bar hit-tests against
/// its own shape and the rest of the screen still belongs to whatever is beneath.
/// A window that answers `nil` is skipped, and the event goes on down the stack.
final class MultitaskOverlayWindow: UIWindow {
    /// Never the key window. UIKit hands that role to whichever window a touch
    /// lands in, so tapping the bar handed it here — and a great deal of the app
    /// asks the scene for its key window when what it means is "the window the app
    /// is in": its root view controller, its safe area, the view to present from.
    /// Refusing the role keeps all of that pointing at the app's own window; the
    /// bar and the switcher need no keyboard, which is all the role really buys.
    override var canBecomeKey: Bool { false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit === self || hit === rootViewController?.view { return nil }
        return hit
    }
}

/// Root of the overlay window. It exists only because a window is expected to
/// have one — it draws nothing, and holds no content beyond the views the dock
/// manager parents to it.
final class MultitaskOverlayRootViewController: UIViewController {
    /// Called with this host's bounds whenever they change — from the rotation
    /// coordinator with the size being rotated into, and again from the host's own
    /// layout once the new size is real. The dock manager re-places the floating
    /// button from it. Two callers because neither is sufficient alone: a
    /// device-orientation notification can arrive before the window has resized
    /// (and fires for face-up/down, where it never does), while the layout pass
    /// always runs but only after the fact.
    var onHostGeometryChange: ((CGRect) -> Void)?

    override func loadView() {
        let root = OverlayPassthroughView()
        root.backgroundColor = .clear
        root.onSizeChange = { [weak self] bounds in
            self?.onHostGeometryChange?(bounds)
        }
        view = root
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        // Inside the coordinator so the move rides the system's rotation animation
        // rather than jumping before or after it.
        coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.onHostGeometryChange?(CGRect(origin: .zero, size: size))
        })
    }
}

/// Reports no hit of its own, so a touch landing on bare overlay falls through to
/// the app underneath instead of stopping at a full-screen transparent view.
final class OverlayPassthroughView: UIView {
    /// Reports a real change of size, once per change — the moment anything
    /// positioned in this view's space has to be measured again.
    var onSizeChange: ((CGRect) -> Void)?
    private var lastReportedSize: CGSize?

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastReportedSize else { return }
        lastReportedSize = bounds.size
        onSizeChange?(bounds)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

final class BarPassthroughContainer: UIView {
    weak var barView: UIView?
    /// Returns the bar's opaque hit path in `barView`'s local coordinates, or nil
    /// to treat the whole bar bounds as opaque (the plain rectangular bar).
    var hitPathProvider: ((CGRect) -> UIBezierPath?)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let bar = barView, bar.superview === self,
              !bar.isHidden, bar.alpha > 0.01 else {
            // No bar actively shown → never intercept; let content behind respond.
            return nil
        }
        let pInBar = bar.convert(point, from: self)
        guard bar.bounds.contains(pInBar) else { return nil }
        if let provider = hitPathProvider, let path = provider(bar.bounds),
           !path.contains(pInBar) {
            // Transparent notch / overhang → pass through to the content beneath.
            return nil
        }
        return super.hitTest(point, with: event)
    }
}

@available(iOS 16.0, *)
struct SwitcherBarContentView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    /// Bumped on each home press to drive the glyph's bounce.
    @State private var homeBounce = 0

    
    var body: some View {
        activeBarContent
        // Make the bar buttons 10% larger (scales the glass pills + glyphs uniformly).
        .scaleEffect(MultitaskDockManager.Constants.barContentScale)
        .padding(.horizontal, MultitaskDockManager.Constants.barHPadding)
        // Center the buttons in the flat solid body — a block spanning the flat-top
        // line down to the screen edge (visible flat strip + safe area). Same formula
        // in both orientations: the bar view is a horizontal strip that landscape just
        // rotates -90°, so the identical height/shape applies either way.
        .frame(height: dockManager.barFlatRegion, alignment: .center)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea()
        // Bar background: one shape (portrait AND landscape) that morphs between a flat
        // square top and rounded concave corners via barLedgeAmountActive — the app
        // content above then looks like it has rounded corners nesting into the bar.
        // In landscape the whole bar view is rotated -90°, so the concave "top" edge
        // lands on the screen-inward side and the shape rotates correctly with no
        // landscape special case. The host view's backgroundColor is cleared in
        // setupDockView so the concave corners reveal the app behind them.
        .background {
            BarTopBar(radius: dockManager.barCornerRadiusActive,
                      curve: dockManager.barCornerRadiusActive * dockManager.barLedgeAmountActive)
                .fill(Color.black)
                .animation(.easeInOut(duration: 0.32), value: dockManager.barLedgeAmountActive)
                .ignoresSafeArea()
        }
    }
    
    // MARK: - Active State (app running in foreground)
    private var activeBarContent: some View {
        HStack(spacing: MultitaskDockManager.Constants.barSpacing) {
            // Left: Hide button
            Button(action: {
                MultitaskDockManager.buttonHaptic()
                dockManager.hideSwitcherBar()
            }) {
                Image(systemName: "chevron.down")
                    .foregroundColor(.white)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: MultitaskDockManager.Constants.barButtonSize,
                           height: MultitaskDockManager.Constants.barButtonSize)
                    .stableBarGlass(capsule: false)
            }
            .buttonStyle(BarControlButtonStyle())
            
            // Middle: App switcher button
            Button(action: {
                MultitaskDockManager.buttonHaptic()
                if dockManager.isAppSwitcherOpen {
                    dockManager.dismissAppSwitcher()
                } else {
                    dockManager.showAppSwitcher()
                }
            }) {
                FrontmostAppIconLabel()
                    .stableBarGlass(capsule: true)
            }
            .buttonStyle(BarControlButtonStyle())
            
            // Right: Home button
            Button(action: {
                MultitaskDockManager.buttonHaptic()
                homeBounce += 1
                dockManager.goHome()
            }) {
                Image(systemName: "app")
                    .foregroundColor(.white)
                    .font(.system(size: 16, weight: .medium))
                    .modifier(SymbolBounce(value: homeBounce))
                    .frame(width: MultitaskDockManager.Constants.barButtonSize,
                           height: MultitaskDockManager.Constants.barButtonSize)
                    .stableBarGlass(capsule: false)
            }
            .buttonStyle(BarControlButtonStyle())
        }
    }
    
    
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false
    
    static func cachedIcon(for app: DockAppModel) -> UIImage? {
        let cacheKey = "\(app.appName)_\(app.appUUID)"
        if let cached = IconCacheManager.shared.getIcon(for: cacheKey) {
            return cached
        }
        // Internal pages use asset catalog icons
        if let assetName = app.internalPageIconAssetName, let icon = UIImage(named: assetName) {
            IconCacheManager.shared.setIcon(icon, for: cacheKey)
            return icon
        }
        // Try loading synchronously and cache it
        if let appInfo = app.appInfo {
            let darkMode = LCUtils.appGroupUserDefault.bool(forKey: "darkModeIcon")
            let icon = appInfo.iconIsDarkIcon(darkMode)
            if let icon { IconCacheManager.shared.setIcon(icon, for: cacheKey) }
            return icon
        }
        return nil
    }
}

// MARK: - Frontmost App Icon Label
@available(iOS 16.0, *)
struct FrontmostAppIconLabel: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    @State private var appIcon: UIImage?
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) var darkModeIcon = false
    
    private var frontmostApp: DockAppModel? {
        if let uuid = dockManager.frontmostAppUUID {
            return dockManager.apps.first { $0.appUUID == uuid }
        }
        return dockManager.apps.last
    }
    
    var body: some View {
        HStack(spacing: MultitaskDockManager.Constants.barMenuSpacing) {
            if let icon = appIcon {
                Image(uiImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .frame(width: MultitaskDockManager.Constants.barMenuIconSize,
                           height: MultitaskDockManager.Constants.barMenuIconSize)
            } else {
                Image(systemName: "app.fill")
                    .foregroundColor(.white)
                    .font(.system(size: 18))
                    .frame(width: MultitaskDockManager.Constants.barMenuIconSize,
                           height: MultitaskDockManager.Constants.barMenuIconSize)
            }
            
            // The capsule grows to fit this up to `barMenuMaxWidth`. Past that it
            // stops, and the name is what gives way: it shrinks first, and only
            // truncates once there is nothing left to shrink.
            Text(frontmostApp?.appName ?? "App")
                .foregroundColor(.white)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .truncationMode(.tail)
            
            Image(systemName: "chevron.up")
                .foregroundColor(.white.opacity(0.6))
                .font(.system(size: 10, weight: .semibold))
                .frame(width: MultitaskDockManager.Constants.barMenuChevronWidth)
        }
        .padding(.horizontal, MultitaskDockManager.Constants.barMenuHPadding)
        // Sized by the manager, not by this layout: the switcher's Close all has
        // to agree with it, and a capsule that sized itself to its contents would
        // stretch to fill the row's slack instead of stopping at its cap.
        .frame(width: dockManager.barMenuWidth,
               height: MultitaskDockManager.Constants.barButtonSize)
        // The width belongs to whichever app is frontmost, so it changes on every
        // switch. Glide between the two rather than snapping, the way iOS resizes
        // its own pill controls.
        .animation(.spring(response: 0.3, dampingFraction: 0.9),
                   value: dockManager.barMenuWidth)
        .onAppear { loadIcon() }
        .onChange(of: dockManager.frontmostAppUUID) { _ in loadIcon() }
        .onChange(of: dockManager.apps.count) { _ in loadIcon() }
    }
    
    private func loadIcon() {
        guard let app = frontmostApp else {
            appIcon = nil
            return
        }
        
        let cacheKey = "\(app.appName)_\(app.appUUID)"
        if let cached = IconCacheManager.shared.getIcon(for: cacheKey) {
            self.appIcon = cached
            return
        }
        
        // Internal pages use asset catalog icons
        if let assetName = app.internalPageIconAssetName, let icon = UIImage(named: assetName) {
            self.appIcon = icon
            IconCacheManager.shared.setIcon(icon, for: cacheKey)
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            var icon: UIImage?
            if let appInfo = app.appInfo {
                icon = appInfo.iconIsDarkIcon(darkModeIcon)
            } else if let found = AppInfoProvider.shared.findAppInfo(appName: app.appName, dataUUID: app.appUUID) {
                icon = found.iconIsDarkIcon(darkModeIcon)
            }
            DispatchQueue.main.async {
                if let icon = icon {
                    self.appIcon = icon
                    IconCacheManager.shared.setIcon(icon, for: cacheKey)
                }
            }
        }
    }
}

// MARK: - Icon Cache Manager
class IconCacheManager {
    static let shared = IconCacheManager()
    private var cache: [String: UIImage] = [:]
    private let cacheQueue = DispatchQueue(label: "icon.cache.queue", attributes: .concurrent)
    
    private init() {}
    
    func getIcon(for key: String) -> UIImage? {
        return cacheQueue.sync {
            return cache[key]
        }
    }
    
    func setIcon(_ icon: UIImage, for key: String) {
        cacheQueue.async(flags: .barrier) {
            self.cache[key] = icon
        }
    }
    
    func clearCache() {
        cacheQueue.async(flags: .barrier) {
            self.cache.removeAll()
        }
    }
}
// MARK: - App Icon View
@available(iOS 16.0, *)
struct AppIconView: View {
    let app: DockAppModel
    var iconSize: CGFloat = MultitaskDockManager.Constants.barIconSize
    @State private var isPressed = false
    @State private var appIcon: UIImage?
    @State private var isLoading = true
    @EnvironmentObject var dockManager: MultitaskDockManager
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) var darkModeIcon = false
    
    var body: some View {
        Group {
            if isLoading && appIcon == nil {
                LoadingIconView()
            } else if let icon = appIcon {
                IconImageView(icon: icon)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
            }
        }
        .frame(width: iconSize, height: iconSize)
        .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 2)
        .scaleEffect(isPressed ? 1.15 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isPressed)
        .onAppear {
            loadAppIcon()
        }
        .onPressGesture(
            onPress: {
                isPressed = true
            },
            onRelease: { location in
                isPressed = false
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                let _ = dockManager.bringMultitaskViewToFront(uuid: app.appUUID, from: location)
            }
        )
        .contentShape(Rectangle())
    }
    
    private func loadAppIcon() {
        let cacheKey = "\(app.appName)_\(app.appUUID)"
        
        if let cachedIcon = IconCacheManager.shared.getIcon(for: cacheKey) {
            self.appIcon = cachedIcon
            self.isLoading = false
            return
        }
        
        // Internal pages use asset catalog icons
        if let assetName = app.internalPageIconAssetName, let icon = UIImage(named: assetName) {
            self.appIcon = icon
            self.isLoading = false
            IconCacheManager.shared.setIcon(icon, for: cacheKey)
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            var finalIcon: UIImage?
            
            if let appInfo = self.app.appInfo {
                finalIcon = appInfo.iconIsDarkIcon(darkModeIcon)
            } else {
                if let foundAppInfo = AppInfoProvider.shared.findAppInfo(appName: self.app.appName, dataUUID: self.app.appUUID) {
                    finalIcon = foundAppInfo.iconIsDarkIcon(darkModeIcon)
                }
            }
            
            DispatchQueue.main.async {
                self.isLoading = false
                if let icon = finalIcon {
                    self.appIcon = icon
                    IconCacheManager.shared.setIcon(icon, for: cacheKey)
                }
            }
        }
    }
}

// MARK: - Press Gesture Helper
extension View {
    func onPressGesture(onPress: @escaping () -> Void, onRelease: @escaping (_ location: CGPoint) -> Void) -> some View {
        self.simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if value.translation == CGSize.zero {
                        onPress()
                    }
                }
                .onEnded { value in
                    onRelease(value.startLocation)
                }
        )
    }
}

// MARK: - App Switcher Overlay
@available(iOS 16.0, *)
struct AppSwitcherOverlay: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    @State private var isPresented = false
    @State private var exiting = false
    @State private var showCloseAllConfirm = false
    /// Bumped on press to bounce each glyph; see `SymbolBounce`.
    @State private var closeBounce = 0
    @State private var homeBounce = 0
    
    private let cardSpacing: CGFloat = 16

    // Fixed corner radius (matches the Figma design spec).
    private let cardCornerRadius: CGFloat = 34

    // Card dimensions — proportional to screen like iOS app switcher
    /// Raised from 0.62 to hold the card's original height. Card height now follows
    /// the trimmed snapshot's aspect rather than the screen's, which is shorter, so
    /// at the old fraction the card lost ~11% of its height.
    private var cardWidth: CGFloat {
        dockManager.switcherScreenSize.width * 0.70
    }
    /// Height of the header row above each card's image — the app icon's own size,
    /// which is the tallest thing in it. Named because the card's height is capped
    /// against the room the column has left once this and the chin have taken theirs.
    private let cardHeaderHeight: CGFloat = 32

    /// Shaped like the snapshot it holds, not like the whole screen. A snapshot keeps
    /// the app's status-bar strip but is trimmed of the rest of the periphery, so it
    /// is shorter than the screen by the bottom inset alone — sizing the card from the
    /// full screen aspect left the image slightly too tall for it, and filling the
    /// card then cropped the sides.
    ///
    /// Capped at the height the column actually has spare. Keeping the status-bar
    /// strip makes a card taller than it used to be, and on a short screen carrying a
    /// deep bar the header above and the chin below can want more room than is left.
    /// The cap only binds there; everywhere else the card is still exactly its
    /// snapshot's shape.
    private var cardHeight: CGFloat {
        let screen = dockManager.switcherScreenSize
        let insets = dockManager.cachedSafeAreaInsets
        let contentHeight = max(screen.height - insets.bottom, 1)
        let natural = cardWidth * (contentHeight / screen.width)
        // Everything the column spends outside the image: the top spacer, the header
        // row and the gap under it, the minimum gap above the chin, and the chin.
        let chrome = (insets.top + 12) + (cardHeaderHeight + 8) + 20 + (dockManager.barFlatRegion + 20)
        return min(natural, max(screen.height - chrome, 1))
    }

    // How far the cards slide left and the buttons slide down when the user taps
    // the background to return to the springboard.
    private var exitCardOffset: CGFloat { dockManager.switcherScreenSize.width + cardWidth }
    private var exitButtonOffset: CGFloat { dockManager.switcherScreenSize.height * 0.4 }
    
    var body: some View {
        ZStack(alignment: .bottom) {
            // Blurred springboard background: the captured home (wallpaper +
            // icons) behind a dark material, the same treatment Spotlight uses.
            // Falls back to a flat dark blur if no snapshot was captured.
            ZStack {
                if let snapshot = dockManager.springboardSnapshot {
                    // Pinned to the window's size, and clipped to it.
                    //
                    // `scaledToFill` sizes a view to COVER what it was offered, so it
                    // reports back something larger in one axis — and this is a sibling
                    // in the ZStack, so the ZStack grew to match and everything else
                    // was centred against that instead of against the screen. A
                    // springboard captured in landscape and drawn in portrait came out
                    // 1698pt wide inside an 820pt window, which dragged the card row
                    // 400pt off the left edge. The frame stops it having any say in the
                    // layout; the clip keeps the overspill from drawing outside.
                    Image(uiImage: snapshot)
                        .resizable()
                        .scaledToFill()
                        .frame(width: dockManager.switcherScreenSize.width,
                               height: dockManager.switcherScreenSize.height)
                        .clipped()
                        .ignoresSafeArea()
                }
                // Blur + scrim fade out on exit so the sharp home is revealed
                // (the snapshot, then the real springboard once the overlay goes).
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)
                        .ignoresSafeArea()
                    // Slight scrim so the cards keep contrast over the blurred home.
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                }
            }
            // Fade the entire blurred-home background out on exit. The snapshot is
            // captured with layer rendering, which can't capture the icons' glass, so
            // resting on it made the glass look like it "appears". Fading it away reveals
            // the LIVE springboard behind the (cleared) overlay, glass already intact.
            .opacity(exiting ? 0 : 1)
            // Eased out, not in, and on its own curve rather than the one carrying the
            // cards away. The cards want to accelerate off the screen; the backdrop is
            // uncovering the real springboard underneath, and easing in held it at full
            // opacity for most of the animation before dropping it — so the icons' glass
            // arrived all at once at the very end, which is the pop this fade exists to
            // prevent. Easing out spends the opacity early and lets the last of it go
            // gently, so the glass comes up rather than snapping in.
            .animation(.easeOut(duration: 0.3), value: exiting)
            // Returning to the springboard lives HERE, on the backdrop, not on the
            // ZStack as a whole. The backdrop is the bottom-most, full-bleed layer;
            // every card, button and control sits above it. So whether a tap
            // dismisses is decided by ordinary front-to-back hit testing — a tap
            // reaches this gesture only when nothing on top of it caught it first.
            // For these layers — plain SwiftUI views that each fully consume any
            // touch inside their own bounds — front-to-back hit testing settles
            // that the same way on every iOS version and screen size, with none of
            // the ancestor/descendant arbitration that shifted between releases.
            //
            // Attached to the ancestor ZStack instead (as it was), the gesture
            // competed with each control's own gesture through SwiftUI's
            // ancestor/descendant arbitration, which resolves differently across
            // releases: that is why tapping the mute or Customize button dismissed
            // the switcher on 17.4 but not elsewhere. Nothing above needs to "win"
            // a race any more; it simply has to be hit first, which it always is.
            .contentShape(Rectangle())
            .onTapGesture {
                exitToSpringboard()
            }

            VStack(spacing: 0) {
                // Pin the content near the top with a small margin below the
                // safe area (the overlay ignores the safe area, so add it back
                // here) instead of pushing everything toward the bottom.
                Spacer()
                    .frame(minHeight: dockManager.cachedSafeAreaInsets.top + 12)

                // Horizontal scrolling app cards
                ScrollViewReader { proxy in
                    cardScrollView
                    .onAppear {
                        // Always land on the most-recently-used app (the rightmost
                        // card), matching iOS. `frontmostAppUUID` is transient — it's
                        // cleared to nil whenever we visit the springboard — so when
                        // it's unavailable, fall back to the last app in recency order
                        // (the `apps` array keeps the most-recent app at the end).
                        // Without this fallback the scroll was skipped and the view
                        // rested at its leading edge, showing the leftmost (oldest) card.
                        let target = dockManager.frontmostAppUUID ?? dockManager.apps.last?.appUUID
                        if let target {
                            // Defer to the next runloop so the scroll target layout is
                            // resolved before we scroll: calling scrollTo before layout
                            // settles under `.viewAligned` can snap back to the first
                            // card, which is the intermittent "jumps to left card" bug.
                            DispatchQueue.main.async {
                                proxy.scrollTo(target, anchor: .center)
                            }
                        }
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                            isPresented = true
                        }
                    }
                    // Re-centred as the device turns, rather than rebuilt. Both the card
                    // width and the padding either side of the row change with the
                    // orientation, so the scroll is left holding an offset that belongs
                    // to the old geometry. Discarding the row's identity to clear that
                    // also discards any chance of animating it — a view with a new
                    // identity has nothing to animate from, which is what made a
                    // rotation look like a redraw. Keeping the identity and moving the
                    // scroll lets the whole thing travel with the turn.
                    //
                    // Left to the next runloop so the row has been laid out at its new
                    // width before it is centred; scrolling against the old one lands
                    // between cards.
                    .onChange(of: dockManager.switcherScreenSize) { _ in
                        guard let target = dockManager.frontmostAppUUID
                                ?? dockManager.apps.last?.appUUID else { return }
                        DispatchQueue.main.async {
                            withAnimation(.easeInOut(duration: MultitaskDockManager.rotationDuration)) {
                                proxy.scrollTo(target, anchor: .center)
                            }
                        }
                    }
                }
                .offset(x: exiting ? -exitCardOffset : 0)
                
                // Flexible gap so the cards sit up top and the bottom actions
                // fall to the bottom edge.
                Spacer(minLength: 20)

                // Reserve the chin's footprint — the controls live inside it, as a
                // separate bottom-anchored layer below — so the cards stop above it.
                Spacer()
                    .frame(height: dockManager.barFlatRegion + 20)
            }
            // Dead while the switcher animates out. Without this a second tap
            // during the ~0.3s exit could land on a card that is still sliding
            // and visible, bringing that app forward while we are already on the
            // way to the springboard.
            .allowsHitTesting(!exiting)

            // The chin: the switcher bar itself, anchored flush to the very bottom
            // edge with exactly the real bar's thickness (bar height + bottom safe
            // area), holding the overlay's three controls the way the real bar holds
            // its own. Left toggles the bar (the action this chin used to carry as a
            // full-width "Hide Switcher Bar" label), middle closes everything, right
            // goes home. As its own bottom-aligned ZStack layer it can't be shifted
            // by the VStack's flow, so its height matches the real bar precisely.
            HStack(spacing: MultitaskDockManager.Constants.barSpacing) {
                Button(action: {
                    MultitaskDockManager.buttonHaptic()
                    // A spring, not a curve: the symbol replace below takes its
                    // timing from this transaction, and iOS's own symbol swaps
                    // settle with a little spring rather than easing flatly.
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        dockManager.setPrefersFloatingButton(!dockManager.prefersFloatingButton)
                    }
                }) {
                    Image(systemName: dockManager.prefersFloatingButton ? "chevron.up" : "chevron.down")
                        .foregroundColor(.white)
                        .font(.system(size: 14, weight: .semibold))
                        .modifier(SymbolReplaceTransition())
                        .frame(width: MultitaskDockManager.Constants.barButtonSize,
                               height: MultitaskDockManager.Constants.barButtonSize)
                        .stableBarGlass(capsule: false)
                        // The whole circle takes the tap, not just the glyph.
                        // Without it the ring around a chevron is see-through to
                        // hit testing, and a near-miss reaches the backdrop
                        // behind — which returns to the springboard.
                        .contentShape(Circle())
                }
                .buttonStyle(BarControlButtonStyle())
                .accessibilityLabel(dockManager.prefersFloatingButton ? "Use Switcher Bar" : "Hide Switcher Bar")
                .modifier(ChinControlEntrance(shown: isPresented, index: 0, from: -1))

                Button(action: {
                    MultitaskDockManager.buttonHaptic()
                    closeBounce += 1
                    showCloseAllConfirm = true
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .modifier(SymbolBounce(value: closeBounce))
                        Text("Close all")
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundColor(.white)
                    // The same fixed width the bar's app menu uses, so the capsule
                    // this one replaces is exactly the size it was.
                    .frame(width: dockManager.barCloseAllWidth,
                           height: MultitaskDockManager.Constants.barButtonSize)
                    .stableBarGlass(capsule: true)
                    .contentShape(Capsule())
                }
                .buttonStyle(BarControlButtonStyle())
                .modifier(ChinControlEntrance(shown: isPresented, index: 1, from: 0))
                .alert("Close All Apps?", isPresented: $showCloseAllConfirm) {
                    Button("Cancel", role: .cancel) { }
                    Button("Close All", role: .destructive) {
                        dockManager.closeAllApps()
                    }
                } message: {
                    Text("This closes every open app.")
                }

                Button(action: {
                    homeBounce += 1
                    exitToSpringboard()
                }) {
                    Image(systemName: "app")
                        .foregroundColor(.white)
                        .font(.system(size: 16, weight: .medium))
                        .modifier(SymbolBounce(value: homeBounce))
                        .frame(width: MultitaskDockManager.Constants.barButtonSize,
                               height: MultitaskDockManager.Constants.barButtonSize)
                        .stableBarGlass(capsule: false)
                        .contentShape(Circle())
                }
                .buttonStyle(BarControlButtonStyle())
                .accessibilityLabel("Home")
                .modifier(ChinControlEntrance(shown: isPresented, index: 2, from: 1))
            }
            // Sized and spaced exactly as the real bar sizes and spaces its own
            // row — same button metric, same 10pt gaps, same 1.1 scale-up, same
            // side padding — so the controls don't change size as the switcher
            // opens over the bar or dismisses back into it.
            .scaleEffect(MultitaskDockManager.Constants.barContentScale)
            .padding(.horizontal, MultitaskDockManager.Constants.barHPadding)
            // Centred in the flat solid body — the block from the flat-top line down
            // to the screen edge — exactly as the real bar centres its own controls.
            // `barFlatRegion` floors at that same button height, so the row always
            // has room: on a device with no bottom inset and a shallow corner radius
            // the natural region is far too short to hold it.
            .frame(maxWidth: .infinity)
            .frame(height: dockManager.barFlatRegion, alignment: .center)
            .padding(.top, dockManager.barCornerRadiusActive)
            // Same concave rounded top corners and height as the real switcher bar —
            // including the rounding amount from the Settings slider, so this chin
            // always matches it. Solid black while the bar is the active control;
            // once the user taps the arrow (floating-button mode), the black fades
            // out to reveal a translucent ultra-thin-material bar underneath.
            // Layering the black over the material and animating its opacity lets
            // the two states cross-fade smoothly when the toggle flips.
            .background {
                BarTopBar(radius: dockManager.barCornerRadiusActive,
                          curve: dockManager.barCornerRadiusActive * dockManager.barLedgeAmountActive)
                    .fill(.thinMaterial)
                    .environment(\.colorScheme, .dark)
                    .overlay {
                        BarTopBar(radius: dockManager.barCornerRadiusActive,
                                  curve: dockManager.barCornerRadiusActive * dockManager.barLedgeAmountActive)
                            .fill(Color.black)
                            .opacity(dockManager.prefersFloatingButton ? 0 : 1)
                    }
                    .animation(.easeInOut(duration: 0.32), value: dockManager.barLedgeAmountActive)
                    .animation(.easeInOut(duration: 0.25), value: dockManager.prefersFloatingButton)
                    .ignoresSafeArea()
            }
            .offset(y: exiting ? exitButtonOffset : 0)
            // Inert during the exit animation, like the cards above. This chin is a
            // separate ZStack sibling, so the cards' own allowsHitTesting guard
            // doesn't reach it — without this, a second tap landing on the arrow
            // while the switcher slides away would flip the persisted preference.
            .allowsHitTesting(!exiting)
        }
        .ignoresSafeArea()
        // Note: background-tap-to-dismiss is deliberately NOT here on the ZStack.
        // It lives on the backdrop layer above, so it is governed by hit testing
        // rather than by competing with descendant controls' gestures. See there.
    }

    /// Tapping the background returns to the springboard: cards slide off to the
    /// left, buttons drop past the bottom edge, and the blur fades to reveal the
    /// home. The manager minimizes the app windows behind the overlay and removes
    /// it once the animation completes.
    private func exitToSpringboard() {
        guard !exiting else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.easeIn(duration: 0.3)) { exiting = true }
        dockManager.goToSpringboardFromSwitcher()
    }

    // MARK: - Card Scroll View (with iOS 17+ snapping)
    @ViewBuilder
    private var cardScrollView: some View {
        if #available(iOS 17.0, *) {
            ScrollView(.horizontal, showsIndicators: false) {
                cardRow
                    // scrollTargetLayout sits directly on the HStack so it still
                    // finds the cards as snap targets; the dismiss catcher layers
                    // behind that, not between it and the stack.
                    .scrollTargetLayout()
                    .background(dismissTapCatcher)
            }
            // `.never` lets a flick carry across multiple cards with momentum and
            // then settle aligned (like the iOS App Switcher). The default
            // (`.automatic`, which acts like `.always` on a compact iPhone width)
            // limits each swipe to a single card, so a gentle or quick horizontal
            // swipe that didn't fully cross to the next card snapped back to the
            // current one — which read as the swipe "not registering".
            .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
            .scrollClipDisabled()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                cardRow
                    .background(dismissTapCatcher)
            }
        }
    }

    /// Behind the cards and spanning the whole padded row — the side gutters and
    /// the gaps between cards. A horizontal ScrollView claims its full width for
    /// hit testing, so those regions never fall through to the backdrop's dismiss
    /// gesture below the ScrollView; this catches them from inside the scroll
    /// content instead. It sits BEHIND the cards, so a tap on a card still reaches
    /// the card (front-most wins) and only a tap on genuinely empty row space
    /// lands here — local, deterministic, no ancestor gesture in sight.
    private var dismissTapCatcher: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { exitToSpringboard() }
    }

    private var cardRow: some View {
        HStack(alignment: .top, spacing: cardSpacing) {
            ForEach(Array(dockManager.apps.enumerated()), id: \.element.appUUID) { pair in
                AppSwitcherCard(
                    app: pair.element,
                    cardWidth: cardWidth,
                    cardHeight: cardHeight,
                    cornerRadius: cardCornerRadius,
                    cardIndex: pair.offset
                )
                .id(pair.element.appUUID)
                // Graceful exit if the card is removed while still partly on-screen.
                .transition(.move(edge: .top).combined(with: .opacity))
                .scaleEffect(isPresented ? 1.0 : 0.85)
                .opacity(isPresented ? 1.0 : 0)
                .animation(
                    .spring(response: 0.4, dampingFraction: 0.82)
                    .delay(Double(pair.offset) * 0.03),
                    value: isPresented
                )
            }
        }
        .padding(.horizontal, (dockManager.switcherScreenSize.width - cardWidth) / 2)
    }
}

// MARK: - Customize Dropdown (menu-style, but with a slider)

/// Hosts a UIKit button so the Customize menu can be a genuine `UIMenu`: it needs
/// `UICustomViewMenuElement` to carry a live slider, which SwiftUI's `Menu` can't do.
/// `showsMenuAsPrimaryAction` keeps the interaction a single tap, and the menu is
/// rebuilt on each presentation so PID, PiP state and scale are always current.
/// Spans the card row so the menu is anchored to — and therefore centred on — the
/// card, while only the trailing icon area accepts touches. Without the width the
/// menu hangs off the card's right edge; without the narrowed hit area the app name
/// beside the icon would open the menu too.
final class WideAnchorMenuButton: UIButton {
    var touchableWidth: CGFloat = 44

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.contains(point) && point.x >= bounds.width - touchableWidth
    }
}

/// The bar that appears while the speaker button is held, and fills as the
/// finger moves. Deliberately not a UISlider: nothing ever touches it directly,
/// it only reports what the gesture on the button is doing. No glyph on it
/// either — the button that raised it is already showing one.
@available(iOS 16.0, *)
final class VolumeSlideOverlay: UIView {
    static let trackWidth: CGFloat = 168
    private static let height: CGFloat = 36
    private static let inset: CGFloat = 14
    /// The track thickens once the drag is under way, the way Control Center's
    /// sliders swell under a finger.
    private static let restingTrackHeight: CGFloat = 8
    private static let activeTrackHeight: CGFloat = 11

    private let blurEffect = UIBlurEffect(style: .systemMaterialDark)
    private let blurView: UIVisualEffectView
    private let vibrancyView: UIVisualEffectView
    private let trackBackground = UIView()
    private let fill = UIView()

    private var trackHeight = VolumeSlideOverlay.restingTrackHeight
    private var volume: Float = 1

    init() {
        blurView = UIVisualEffectView(effect: blurEffect)
        vibrancyView = UIVisualEffectView(effect: UIVibrancyEffect(blurEffect: blurEffect, style: .fill))
        super.init(frame: CGRect(x: 0, y: 0, width: Self.trackWidth + Self.inset * 2, height: Self.height))

        // Material rather than a flat colour: a solid grey capsule is the one
        // thing that reads as not-iOS however well it is shaped. Same style the
        // switcher's own floating button uses.
        blurView.frame = bounds
        blurView.layer.cornerRadius = Self.height / 2
        blurView.layer.cornerCurve = .continuous
        blurView.clipsToBounds = true
        blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(blurView)

        trackBackground.backgroundColor = UIColor.white.withAlphaComponent(0.22)
        trackBackground.layer.cornerCurve = .continuous
        blurView.contentView.addSubview(trackBackground)

        // Vibrancy, so the fill sits inside the material and picks up what is
        // behind it, rather than looking painted on top of it.
        blurView.contentView.addSubview(vibrancyView)
        fill.backgroundColor = .white
        fill.layer.cornerCurve = .continuous
        vibrancyView.contentView.addSubview(fill)

        isAccessibilityElement = true
        accessibilityLabel = "lc.multitask.volume".loc
        applyLayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setVolume(_ volume: Float) {
        self.volume = min(max(volume, 0), 1)
        applyLayout()
        accessibilityValue = "\(Int((CGFloat(self.volume) * 100).rounded()))%"
    }

    /// Swells the track. Called inside the entrance animation, so it arrives at
    /// resting thickness and settles into the active one.
    func setDragging(_ dragging: Bool) {
        trackHeight = dragging ? Self.activeTrackHeight : Self.restingTrackHeight
        applyLayout()
    }

    private func applyLayout() {
        let trackRect = CGRect(x: Self.inset,
                               y: (Self.height - trackHeight) / 2,
                               width: Self.trackWidth,
                               height: trackHeight)
        trackBackground.frame = trackRect
        trackBackground.layer.cornerRadius = trackHeight / 2
        vibrancyView.frame = trackRect

        // Never a sliver: below its own thickness the fill stops being a bar and
        // starts looking like a rendering fault, so it bottoms out at a round
        // nub — and disappears entirely only at true silence.
        let width = volume <= 0 ? 0 : max(trackHeight, Self.trackWidth * CGFloat(volume))
        fill.frame = CGRect(x: 0, y: 0, width: width, height: trackHeight)
        fill.layer.cornerRadius = trackHeight / 2
    }
}

/// Turns a press on the speaker button into a volume drag, in one gesture: hold
/// to bring up the bar, keep moving to set the level, lift to leave it there.
///
/// A `UIMenu` carrying a slider would be less code, but it costs a second touch
/// — the menu takes the press, and the slider cannot be reached until the finger
/// has lifted and come back down. Owning the gesture is what makes hold-and-slide
/// a single motion.
@available(iOS 16.0, *)
final class VolumeSlideCoordinator: NSObject {
    let control: () -> LCGuestVolume?
    private weak var button: UIButton?
    private var overlay: VolumeSlideOverlay?
    private var startVolume: Float = 1
    private var startX: CGFloat = 0
    private var wasAtEnd = false
    private var shownIconStep = -1
    private weak var lockedScrollView: UIScrollView?

    init(control: @escaping () -> LCGuestVolume?) {
        self.control = control
    }

    /// Swaps the speaker glyph, crossfading when the drawing actually differs.
    /// A snapshot crossfade rather than iOS 17's symbol transitions: those are
    /// applied to the image view, which a button will overwrite from its own
    /// stored image on the next layout pass, and this has to look the same on
    /// every version the app supports.
    func applyIcon(volume: Float, to button: UIButton, animated: Bool) {
        let step = MuteToggleButton.iconStep(forVolume: volume)
        guard step != shownIconStep else { return }
        let firstShow = shownIconStep < 0
        shownIconStep = step
        let image = MuteToggleButton.icon(forStep: step)

        guard animated, !firstShow, !UIAccessibility.isReduceMotionEnabled else {
            button.setImage(image, for: .normal)
            return
        }
        // .allowUserInteraction matters: without it the drag under way stops
        // being tracked for the length of the fade.
        UIView.transition(with: button, duration: 0.18,
                          options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState]) {
            button.setImage(image, for: .normal)
        }
    }

    func attach(to button: UIButton) {
        guard self.button !== button else { return }
        self.button = button

        let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = 0.25
        button.addGestureRecognizer(press)

        // Quick tap toggles mute — and UIKit itself tells the two apart, rather
        // than a separate SwiftUI tap gesture racing the long press. require(toFail:)
        // holds the tap until the long press has failed, so a short press toggles
        // and a press held long enough to raise the volume bar never also toggles
        // on release. That was a real double-fire: a hesitant hold that never
        // moved used to both show the bar and flip the mute.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.require(toFail: press)
        button.addGestureRecognizer(tap)
    }

    @objc private func handleTap() {
        guard let button = self.button, let audio = control() else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        audio.toggleMute()
        applyIcon(volume: audio.volume, to: button, animated: true)
        button.accessibilityLabel = (audio.muted ? "lc.multitask.unmute" : "lc.multitask.mute").loc
    }

    @objc private func handlePress(_ gesture: UILongPressGestureRecognizer) {
        guard let button = self.button, let audio = control() else { return }
        switch gesture.state {
        case .began:
            // The finger is going to lift on this button, and that lift must not
            // also read as a tap and toggle the mute the drag just set.
            button.cancelTracking(with: nil)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            startVolume = audio.volume
            startX = gesture.location(in: button.window).x
            wasAtEnd = startVolume <= 0 || startVolume >= 1
            presentOverlay(from: button, volume: audio.volume)
            // Unlock first: if a previous gesture ended without its .ended ever
            // arriving, the switcher would be left unable to scroll, which is a
            // far worse failure than a stray drag.
            unlockScrollView()
            lockEnclosingScrollView(from: button)
        case .changed:
            guard let overlay = self.overlay else { return }
            // Relative to where the press started, not to where the finger is:
            // the finger comes down on the button rather than on the bar, so an
            // absolute mapping would jump the level on the first pixel of travel.
            let travel = gesture.location(in: button.window).x - startX
            let volume = min(max(startVolume + Float(travel / VolumeSlideOverlay.trackWidth), 0), 1)
            audio.volume = volume
            overlay.setVolume(volume)
            applyIcon(volume: volume, to: button, animated: true)

            // A tap on arriving at either end, once per arrival — every native
            // slider does this, and travelling into a dead stop in silence is
            // the part that feels wrong without it.
            let atEnd = volume <= 0 || volume >= 1
            if atEnd && !wasAtEnd {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.7)
            }
            wasAtEnd = atEnd
        case .ended, .cancelled, .failed:
            dismissOverlay()
            unlockScrollView()
        default:
            break
        }
    }

    private func presentOverlay(from button: UIButton, volume: Float) {
        guard let window = button.window else { return }
        // Reuse whatever is still fading out from the last press, so a quick
        // second press does not stack a new bar on top of the old one.
        let overlay = self.overlay ?? VolumeSlideOverlay()
        overlay.layer.removeAllAnimations()
        overlay.transform = .identity
        overlay.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        overlay.setDragging(false)
        overlay.setVolume(volume)

        let anchor = button.convert(button.bounds, to: window)
        // Centred on the screen, sitting just above the button. Screen-centred,
        // not card-centred: the card's centre had to be guessed by walking the
        // view tree or measured and threaded through, and either way it landed
        // off often enough to be worth dropping. The window's centre needs
        // nothing, is the same on every device and orientation, and — since the
        // bar is a floating HUD, not part of the card — reads as belonging to the
        // screen anyway. It still springs from the button (the growth anchor
        // below uses the button's real position), so it does not feel detached.
        var origin = CGPoint(x: window.bounds.midX - overlay.bounds.width / 2,
                             y: anchor.minY - overlay.bounds.height - 10)
        origin.x = min(max(origin.x, 12), window.bounds.width - overlay.bounds.width - 12)
        // Below the button instead, if there is no room above it.
        let above = origin.y >= window.safeAreaInsets.top + 8
        if !above {
            origin.y = anchor.maxY + 10
        }
        overlay.frame.origin = origin

        // Grows out of the button that raised it rather than out of its own
        // middle: anchored at the point nearest the button, on the edge facing it.
        let anchorX = min(max((anchor.midX - overlay.frame.minX) / overlay.bounds.width, 0), 1)
        setAnchorPoint(CGPoint(x: anchorX, y: above ? 1 : 0), for: overlay)

        if overlay.superview == nil {
            window.addSubview(overlay)
        }

        if UIAccessibility.isReduceMotionEnabled {
            overlay.alpha = 0
            overlay.setDragging(true)
            UIView.animate(withDuration: 0.12) { overlay.alpha = 1 }
        } else {
            overlay.alpha = 0
            overlay.transform = CGAffineTransform(scaleX: 0.86, y: 0.86)
            UIView.animate(withDuration: 0.38, delay: 0, usingSpringWithDamping: 0.72, initialSpringVelocity: 0.4,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                overlay.alpha = 1
                overlay.transform = .identity
                overlay.setDragging(true)
            }
        }
        self.overlay = overlay
    }

    private func dismissOverlay() {
        guard let overlay = self.overlay else { return }
        // Held briefly before it goes, the way the system's own volume HUD
        // lingers. Fading the instant the finger lifts reads as the bar being
        // snatched away rather than finished with.
        UIView.animate(withDuration: 0.25, delay: 0.5,
                       options: [.curveEaseIn, .beginFromCurrentState]) {
            overlay.alpha = 0
            overlay.setDragging(false)
        } completion: { finished in
            // Not finished means a new press interrupted it and is now using it.
            guard finished else { return }
            overlay.removeFromSuperview()
            if self.overlay === overlay {
                self.overlay = nil
            }
        }
    }

    /// Moves the layer's anchor point without moving the view on screen.
    private func setAnchorPoint(_ anchorPoint: CGPoint, for view: UIView) {
        let newPoint = CGPoint(x: view.bounds.width * anchorPoint.x, y: view.bounds.height * anchorPoint.y)
        let oldPoint = CGPoint(x: view.bounds.width * view.layer.anchorPoint.x, y: view.bounds.height * view.layer.anchorPoint.y)
        var position = view.layer.position
        position.x += newPoint.x - oldPoint.x
        position.y += newPoint.y - oldPoint.y
        view.layer.position = position
        view.layer.anchorPoint = anchorPoint
    }

    // The switcher scrolls horizontally, and so does this drag. Without this the
    // cards slide away under the finger while the level is being set.
    private func lockEnclosingScrollView(from view: UIView) {
        var candidate: UIView? = view
        while let current = candidate {
            if let scrollView = current as? UIScrollView, scrollView.isScrollEnabled {
                scrollView.isScrollEnabled = false
                lockedScrollView = scrollView
                return
            }
            candidate = current.superview
        }
    }

    private func unlockScrollView() {
        lockedScrollView?.isScrollEnabled = true
        lockedScrollView = nil
    }

    deinit {
        lockedScrollView?.isScrollEnabled = true
    }
}

/// Volume control for one guest, as a speaker button: tap to mute, or hold and
/// slide to set the level without lifting a finger.
///
/// Its own control rather than a menu item because silencing a window is
/// something you reach for while listening to another one, and a two-tap trip
/// through a menu is a poor fit for that.
@available(iOS 16.0, *)
struct MuteToggleButton: UIViewRepresentable {
    let control: () -> LCGuestVolume?

    /// Volume controls standing in for the internal pages, which have no guest
    /// process behind them. They post to container ids nothing is listening on,
    /// so the button, the bar and the glyph all behave while no audio anywhere
    /// changes — which is the only way to try this UI on a simulator, where a
    /// real guest cannot run at all.
    private static var placeholderControls: [String: LCGuestVolume] = [:]

    private static func placeholderControl(for appUUID: String) -> LCGuestVolume {
        if let existing = placeholderControls[appUUID] { return existing }
        let placeholder: LCGuestVolume = LCGuestVolume(dataUUID: "ui-placeholder-\(appUUID)")
        placeholderControls[appUUID] = placeholder
        return placeholder
    }

    static func control(for app: DockAppModel) -> LCGuestVolume? {
        if let audio = (app.view?._viewDelegate() as? DecoratedAppSceneViewController)?.appSceneVC.audio {
            return audio
        }
        // Only for the internal pages. A guest window whose controller is
        // momentarily missing must come back nil rather than quietly send the
        // user's changes to a placeholder.
        return app.isInternalPage ? placeholderControl(for: app.appUUID) : nil
    }

    init(app: DockAppModel) {
        control = { MuteToggleButton.control(for: app) }
    }

    /// For the Xcode preview, which has no running guest to reach through.
    init(control: @escaping () -> LCGuestVolume?) {
        self.control = control
    }

    /// How many waves the speaker is drawn with, silence included. Kept as a step
    /// rather than a level because that is all the glyph can show — and knowing
    /// when it has actually changed is what keeps the animation off the other
    /// ninety-nine drag events that change nothing on screen.
    static func iconStep(forVolume volume: Float) -> Int {
        switch volume {
        case ..<0.01: return 0
        case ..<0.34: return 1
        case ..<0.67: return 2
        default: return 3
        }
    }

    static func icon(forStep step: Int) -> UIImage? {
        let configuration = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        if step == 0 {
            return UIImage(systemName: "speaker.slash.fill", withConfiguration: configuration)
        }
        // One symbol at a variable value, not three different ones: the waves are
        // the same drawing at every step, so going up or down changes only how
        // many of them are lit — which is what makes a crossfade read as waves
        // appearing rather than as two unrelated icons swapping.
        return UIImage(systemName: "speaker.wave.3.fill",
                       variableValue: Double(step) / 3.0,
                       configuration: configuration)
    }

    static func icon(forVolume volume: Float) -> UIImage? {
        icon(forStep: iconStep(forVolume: volume))
    }

    func makeCoordinator() -> VolumeSlideCoordinator {
        VolumeSlideCoordinator(control: control)
    }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.tintColor = UIColor.white.withAlphaComponent(0.9)
        button.overrideUserInterfaceStyle = CustomizeMenuButton.windowInterfaceStyle
        button.isUserInteractionEnabled = true
        // Both gestures — quick-tap mute and press-and-slide volume — are the
        // coordinator's, added here. Handling the tap in UIKit is safe now that
        // background-dismiss is hit-test-ordered: the tap lands on this button and
        // no ancestor gesture competes for it.
        context.coordinator.attach(to: button)
        updateUIView(button, context: context)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.attach(to: button)
        let volume = context.coordinator.control()?.volume ?? 1.0
        context.coordinator.applyIcon(volume: volume, to: button, animated: true)
        button.accessibilityLabel = (volume <= 0 ? "lc.multitask.unmute" : "lc.multitask.mute").loc
    }
}

#if DEBUG
/// Stand-in for a switcher card, so the button and its bar can be exercised in
/// the canvas without a device or a running guest. The control it drives posts
/// its notifications into the void — nothing is listening on "preview".
@available(iOS 16.0, *)
private struct VolumeSlidePreviewCard: View {
    private let audio = LCGuestVolume(dataUUID: "preview")
    private let cardWidth: CGFloat = 240

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 8) {
                Text("Hold the speaker, then slide")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.bottom, 100)

                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 32, height: 32)
                    Text("Guest App")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer(minLength: 8)
                    MuteToggleButton(control: { audio })
                        .frame(width: 32, height: 32)
                        .padding(.trailing, 44)
                }
                .frame(width: cardWidth - 40)
                .padding(.horizontal, 20)

                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: cardWidth, height: 300)
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Every level the bar can show, for judging the fill's shape at the extremes
/// without having to drag to them.
@available(iOS 16.0, *)
private func volumeSlideLevelsPreview() -> UIView {
    let container = UIView()
    container.backgroundColor = UIColor(white: 0.08, alpha: 1)
    var y: CGFloat = 24
    for level in [Float(0), 0.02, 0.25, 0.5, 0.85, 1] {
        let overlay = VolumeSlideOverlay()
        overlay.setVolume(level)
        overlay.setDragging(true)
        overlay.frame.origin = CGPoint(x: 24, y: y)
        container.addSubview(overlay)
        y += overlay.bounds.height + 12
    }
    return container
}

// iOS 17 on the previews themselves — the macro is not available before it,
// which also satisfies the 16+ availability of everything they show.
@available(iOS 17.0, *)
#Preview("Volume bar — card") {
    VolumeSlidePreviewCard()
}

@available(iOS 17.0, *)
#Preview("Volume bar — levels") {
    volumeSlideLevelsPreview()
}
#endif

@available(iOS 16.0, *)
struct CustomizeMenuButton: UIViewRepresentable {
    let app: DockAppModel

    func makeUIView(context: Context) -> UIButton {
        let button = WideAnchorMenuButton(type: .system)
        button.setImage(UIImage(systemName: "slider.horizontal.3",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)),
                        for: .normal)
        button.tintColor = UIColor.white.withAlphaComponent(0.9)
        button.contentHorizontalAlignment = .trailing
        button.showsMenuAsPrimaryAction = true
        // A menu renders in its presenting view's trait environment, and the switcher
        // overlay forces .dark over an opaque black backdrop. Glass is adaptive: with
        // near-black behind it and a dark appearance it has almost nothing to frost,
        // so it reads as clear where the springboard's menu reads as frosted. Opt this
        // button back into the window's real appearance so the two match.
        button.overrideUserInterfaceStyle = Self.windowInterfaceStyle
        updateMenu(on: button)
        return button
    }

    /// The appearance the app is actually running in, read from the window rather
    /// than the surrounding view tree, which the overlay has overridden.
    static var windowInterfaceStyle: UIUserInterfaceStyle {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        return scene?.keyWindow?.traitCollection.userInterfaceStyle ?? .unspecified
    }

    func updateUIView(_ button: UIButton, context: Context) {
        updateMenu(on: button)
    }

    private func updateMenu(on button: UIButton) {
        let app = self.app
        // Deferred so the menu reflects state at the moment it opens, not at layout.
        button.menu = UIMenu(title: "", children: [
            UIDeferredMenuElement.uncached { completion in
                guard let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController else {
                    // Internal pages have no guest process, so every item in this
                    // menu is about something that does not exist. The button is
                    // still shown, and says as much when opened, rather than
                    // presenting an empty menu that looks broken.
                    completion([UIAction(title: "lc.multitask.noGuest".loc,
                                         attributes: .disabled) { _ in }])
                    return
                }
                completion(vc.customizeMenu().children)
            }
        ])
    }
}

// MARK: - App Switcher Card (with swipe-up-to-close)
@available(iOS 16.0, *)
struct AppSwitcherCard: View {
    let app: DockAppModel
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let cornerRadius: CGFloat
    
    let cardIndex: Int
    
    @EnvironmentObject var dockManager: MultitaskDockManager
    @State private var dragOffset: CGFloat = 0
    @State private var isDismissing = false
    @State private var isVerticalDrag = false
    @State private var hasPassedThreshold = false
    @State private var closeAllOffset: CGFloat = 0
    /// Where this card sits, so the window it opens can come out of it. Measured
    /// from the layout rather than from what is drawn: a card is scaled as it
    /// arrives and offset while it is dragged, and the window should come out of
    /// where the card sits rather than where it happens to be mid-gesture.
    @State private var cardFrame: CGRect = .zero

    /// Read off the size the card was given rather than from the device, so the
    /// content can never disagree with the frame holding it. iPhone's card is
    /// always the taller way round; iPad's follows the screen and turns with it.
    private var isPortraitCard: Bool { cardHeight > cardWidth }

    /// Whether this card shows the header's mute + Customize controls.
    ///
    /// A real guest window always does. The internal Settings / Installer pages
    /// have no guest process behind them, so their controls are placeholders —
    /// there only to preview this UI in the simulator, where a real multitask
    /// guest can't run. On a device build they are compiled out, so users never
    /// see a mute button that moves a level nothing hears or a Customize menu with
    /// nothing to customise.
    private var showsHeaderControls: Bool {
        if !app.isInternalPage { return true }
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    private let dismissThreshold: CGFloat = -120

    var body: some View {
        VStack(spacing: 8) {
            // App icon + left-aligned name, with the Customize button inline on the
            // trailing edge. Row spans the card width with 10pt side margins: name
            // group sits 10pt from the left, the slider button 10pt from the right.
            HStack(spacing: 6) {
                if let icon = SwitcherBarContentView.cachedIcon(for: app) {
                    Image(uiImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                } else {
                    Image(systemName: "app.fill")
                        .foregroundColor(.white)
                        .font(.system(size: 24))
                        .frame(width: 32, height: 32)
                }

                Text(app.appName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Spacer(minLength: 8)

                // Space held for the two trailing buttons, both of which are laid
                // over this row rather than placed in it, so the name still
                // truncates before it reaches them. Only when the controls are
                // actually shown — otherwise the name gets the full width back.
                if showsHeaderControls {
                    Color.clear.frame(width: 76, height: 32)
                }
            }
            // Customize button, laid over the whole row rather than placed in it.
            // UIKit anchors a button's menu to that button's bounds, so a 32pt button
            // on the trailing edge put the menu against the card's right edge; a
            // row-wide source centres it on the card. Only its trailing icon area
            // takes touches, so the name beside it stays untappable. Guest apps only:
            // internal Settings / Installer pages have no guest process, so nothing
            // in the menu would apply to them.
            .overlay {
                // Just the button. It hit-tests as an ordinary view, so a tap that
                // lands on it opens its menu (showsMenuAsPrimaryAction) and never
                // reaches the backdrop's dismiss gesture below — no defensive
                // tap-swallowing needed now that dismissal is hit-test-ordered
                // rather than an ancestor gesture racing this one.
                if showsHeaderControls {
                    CustomizeMenuButton(app: app)
                }
            }
            // Above the Customize button, not beneath it. That button is a
            // row-wide view that narrows its own touch area with point(inside:),
            // and SwiftUI does not necessarily consult that when it decides which
            // view a touch belongs to — on iOS 17.4 it hands the whole row to the
            // menu, so a mute button sitting under it never sees a tap. Being the
            // topmost view at that point settles it at both layers.
            .overlay(alignment: .trailing) {
                // Padding, not an offset: an offset moves what is drawn while the
                // hosted button stays where it was laid out, which put this
                // button's touch target 44pt to the right of its own icon — over
                // the Customize button. Padding moves the view itself.
                //
                // The tap goes on before the padding so the touch target is the
                // 32pt button and not the 76pt block: the padding has no gesture
                // of its own, so taps in it fall through to the Customize button
                // underneath, which is where they belong.
                if showsHeaderControls {
                    MuteToggleButton(app: app)
                        .frame(width: 32, height: 32)
                        .padding(.trailing, 44)
                }
            }
            // Inset the row 20pt on each side so the name (left) and the customize
            // button (right) sit just inside the card's edges.
            .frame(width: cardWidth - 40)
            .padding(.horizontal, 20)
            
            // Card with snapshot
            ZStack {
                if let snapshotImage = dockManager.appSnapshotImages[app.appUUID] {
                    // Frozen bitmap, filling the card. Turned upright for a portrait
                    // card and left alone for a landscape one, so either way it arrives
                    // at roughly the card's own aspect and fill crops only a sliver —
                    // where fitting would leave black bars wherever it was trimmed.
                    //
                    // Turned with a rotationEffect rather than by re-tagging the image's
                    // orientation. Re-tagging swaps the image's intrinsic size, and the
                    // row is laid out from that before any frame constrains it — so a
                    // turned card widened the HStack and slid itself off the screen. A
                    // rotationEffect draws the turn without the layout ever knowing:
                    // the inner frame is the card's shape before the quarter turn, the
                    // outer one is what the row sees, and it is the card's size either
                    // way round.
                    let turn = dockManager.cardSnapshotRotation(for: app.appUUID,
                                                                portraitCard: isPortraitCard)
                    Image(uiImage: snapshotImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: turn == 0 ? cardWidth : cardHeight,
                               height: turn == 0 ? cardHeight : cardWidth)
                        .clipped()
                        .rotationEffect(.radians(Double(turn)))
                        .frame(width: cardWidth, height: cardHeight)
                        .clipped()
                } else if let snapshotView = dockManager.appSnapshotViews[app.appUUID] {
                    SnapshotViewRepresentable(
                        snapshotView: snapshotView,
                        naturalSize: dockManager.appSnapshotSizes[app.appUUID] ?? .zero,
                        rotation: dockManager.cardSnapshotRotation(for: app.appUUID,
                                                                   portraitCard: isPortraitCard))
                        .frame(width: cardWidth, height: cardHeight)
                        .clipped()
                } else {
                    // Placeholder with blurred app icon
                    Rectangle()
                        .fill(Color.gray.opacity(0.15))
                        .frame(width: cardWidth, height: cardHeight)
                        .overlay {
                            VStack(spacing: 12) {
                                if let icon = SwitcherBarContentView.cachedIcon(for: app) {
                                    Image(uiImage: icon)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 64, height: 64)
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                                Text(app.appName)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 10, y: 5)
            // Opening the app hangs off the card itself, not off the whole
            // column. It used to include the header row, which is where both
            // controls live: SwiftUI resolves its own gestures before it reaches
            // a hosted UIKit button, so on iOS 17.4 a tap meant for the speaker
            // opened the app instead. Only a press long enough to fail this
            // gesture — the volume drag — ever got through.
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { cardFrame = geometry.frame(in: .global) }
                        .onChange(of: geometry.frame(in: .global)) { cardFrame = $0 }
                }
            )
            .onTapGesture {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                dockManager.dismissAppSwitcher()
                // Out of the card rather than out of nowhere: it is already
                // showing the app, at the size and place the user just pressed.
                let _ = dockManager.bringMultitaskViewToFront(
                    uuid: app.appUUID,
                    fromRect: cardFrame == .zero ? nil : cardFrame
                )
            }
        }
        .offset(y: dragOffset + closeAllOffset)
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    let h = value.translation.height
                    let w = value.translation.width
                    
                    // Determine direction on first significant movement
                    if !isVerticalDrag && abs(h) > 20 && abs(h) > abs(w) * 1.5 {
                        isVerticalDrag = true
                    }
                    
                    // Only track upward vertical drags
                    if isVerticalDrag && h < 0 {
                        dragOffset = h
                        
                        // Haptic feedback when crossing the dismiss threshold
                        let pastThreshold = h < dismissThreshold
                        if pastThreshold && !hasPassedThreshold {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            hasPassedThreshold = true
                        } else if !pastThreshold && hasPassedThreshold {
                            UISelectionFeedbackGenerator().selectionChanged()
                            hasPassedThreshold = false
                        }
                    }
                }
                .onEnded { value in
                    let velocity = value.velocity.height
                    let translation = value.translation.height
                    
                    // Dismiss based on distance OR velocity (inertia):
                    // - Dragged past threshold, OR
                    // - Fast upward flick (velocity < -800), OR
                    // - Predicted end position flies well past threshold
                    let shouldDismiss = isVerticalDrag && (
                        translation < dismissThreshold ||
                        velocity < -800 ||
                        value.predictedEndTranslation.height < dismissThreshold * 2
                    )
                    
                    if shouldDismiss {
                        isDismissing = true
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        
                        // Spring with initial velocity for smooth momentum handoff from gesture
                        let screenH = UIScreen.main.bounds.height
                        let totalChange = -screenH - dragOffset // negative (going further up)
                        // Normalize gesture velocity to proportion of remaining distance per second
                        let springVelocity = totalChange != 0 ? velocity / totalChange : 0
                        
                        // Fling the card off-screen with momentum handoff from the gesture.
                        withAnimation(.interpolatingSpring(stiffness: 350, damping: 38, initialVelocity: springVelocity)) {
                            dragOffset = -screenH
                        }
                        // As soon as the card has cleared the screen, start the real
                        // (async) teardown AND remove the card from the switcher list in
                        // one animated step. The remaining cards slide in to fill the gap
                        // on this fixed, short schedule instead of waiting on asynchronous
                        // app termination — so the reflow is both smooth and immediate.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            dockManager.beginAppTeardown(uuid: app.appUUID)
                            dockManager.removeRunningApp(app.appUUID)
                        }
                    } else {
                        // Snap back
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            dragOffset = 0
                        }
                    }
                    isVerticalDrag = false
                    hasPassedThreshold = false
                }
        )
        .onChange(of: dockManager.isClosingAll) { closing in
            if closing {
                withAnimation(.easeIn(duration: 0.3).delay(Double(cardIndex) * 0.05)) {
                    closeAllOffset = -UIScreen.main.bounds.height
                }
            }
        }
    }
}

// MARK: - Multitask Home Icons (shown on home screen when dock is hidden)
@available(iOS 16.0, *)
struct MultitaskHomeIcons: View {
    @ObservedObject var dockManager = MultitaskDockManager.shared
    let darkModeIcon: Bool
    private var iconSize: CGFloat { FlekTheme.bottomBarAppIconSize }

    var body: some View {
        ForEach(Array(dockManager.apps.suffix(4))) { app in
            MultitaskHomeIcon(app: app, iconSize: iconSize)
        }
    }
}

/// One running app in the home dock. Beyond drawing itself it does two things for
/// the minimize animation: it publishes where it is, so a window whose own
/// springboard icon is on a page the user is not looking at has somewhere real to
/// go, and it takes the window when it arrives.
@available(iOS 16.0, *)
private struct MultitaskHomeIcon: View {
    let app: DockAppModel
    let iconSize: CGFloat

    @ObservedObject private var dockManager = MultitaskDockManager.shared
    @State private var scale: CGFloat = 1

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            let _ = dockManager.bringMultitaskViewToFront(uuid: app.appUUID)
        } label: {
            if let icon = SwitcherBarContentView.cachedIcon(for: app) {
                Image(uiImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .frame(width: iconSize, height: iconSize)
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: iconSize, height: iconSize)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.gray.opacity(0.3)))
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(scale)
        .background(
            GeometryReader { geometry in
                // Kept on disappear rather than withdrawn. The dock is only on
                // screen in the home state, so it is absent at the very moment a
                // window is leaving for it, and the last known position of a
                // fixed bottom pill is a better answer than none. A stale entry
                // is checked against the screen before it is used, and refreshed
                // the moment the icon lays out again.
                Color.clear
                    .onAppear { publishFrame(geometry.frame(in: .global)) }
                    .onChange(of: geometry.frame(in: .global)) { publishFrame($0) }
            }
        )
        .onReceive(NotificationCenter.default.publisher(for: .lcHomeDockIconDidTakeWindow)) { note in
            guard let itemID = note.object as? String, itemID == app.springboardItemID else { return }
            // Set the peak outright and spring back from it. The two have to be
            // separate updates or SwiftUI coalesces them and the pop never shows.
            scale = MultitaskDockManager.Constants.homeDockIconBounceScale
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.56)) { scale = 1 }
            }
        }
    }

    private func publishFrame(_ frame: CGRect) {
        guard let itemID = app.springboardItemID, frame.width > 1, frame.height > 1 else { return }
        MultitaskDockManager.shared.homeDockIconFrames[itemID] = frame
    }
}

extension Notification.Name {
    /// A minimizing window has landed on its icon in the home dock, which is that
    /// icon's cue to answer it. Object is the home-screen item id.
    static let lcHomeDockIconDidTakeWindow = Notification.Name("LCHomeDockIconDidTakeWindow")
}

// MARK: - Multitask Home Dock Pill
/// The pill/circle shown at the bottom of the springboard when in multitask home state.
/// Observes the dock manager so it reactively switches between a capsule (when running
/// apps are present) and a circle (when only the switcher button remains).
@available(iOS 16.0, *)
struct MultitaskHomeDockPill: View {
    @ObservedObject private var dockManager = MultitaskDockManager.shared
    let darkModeIcon: Bool

    private var hasApps: Bool { !dockManager.apps.isEmpty }
    private var pillHeight: CGFloat { FlekTheme.bottomBarControlSize }

    var body: some View {
        if hasApps {
            HStack(spacing: 8) {
                MultitaskHomeIcons(darkModeIcon: darkModeIcon)
                switcherButton
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .frame(height: pillHeight)
            .modifier(DockPillBackground(isCircle: false))
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { publishPillFrame(geometry.frame(in: .global)) }
                        .onChange(of: geometry.frame(in: .global)) { publishPillFrame($0) }
                }
            )
        } else {
            switcherButton
                .frame(width: pillHeight, height: pillHeight)
                .modifier(DockPillBackground(isCircle: true))
        }
    }

    /// Reported for windows that belong in the dock but have no icon of their own
    /// in it — the dock holds only the four most recent apps, so a fifth still has
    /// somewhere to go.
    private func publishPillFrame(_ frame: CGRect) {
        guard frame.width > 1, frame.height > 1 else { return }
        MultitaskDockManager.shared.homeDockPillFrame = frame
    }

    private var switcherButton: some View {
        Button {
            MultitaskDockManager.shared.showAppSwitcher()
        } label: {
            Image(systemName: FlekSymbol.appSwitcher)
                .font(.system(size: FlekTheme.bottomBarGlyphSize, weight: .regular))
                .foregroundStyle(Color.primary.opacity(0.6))
                .frame(width: FlekTheme.bottomBarControlSize, height: FlekTheme.bottomBarControlSize)
        }
        .buttonStyle(.plain)
    }
}

/// Applies either a capsule or circle glass/material background depending on iOS version.
@available(iOS 16.0, *)
private extension View {
    /// Stable Liquid Glass for the multitask bar controls — pins the glass tone
    /// (fixed dark, matching the white icons) so it never re-tints to the app
    /// content behind it, the same approach as the Spotlight search. Falls back
    /// to a flat translucent fill on older iOS or when Liquid Glass is disabled.
    @ViewBuilder
    func stableBarGlass(capsule: Bool) -> some View {
        if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
            background {
                StableLiquidGlass(isDark: true, tint: UIColor(white: 1.0, alpha: 0.03))
            }
        } else if capsule {
            background(Capsule().fill(Color.white.opacity(0.15)))
        } else {
            background(Circle().fill(Color.white.opacity(0.15)))
        }
    }
}

private struct DockPillBackground: ViewModifier {
    let isCircle: Bool

    // Returns AnyView instead of `some View`. With an opaque return type the
    // inferred Body embeds the iOS 26-only type that `glassEffect` produces, and
    // the runtime has to resolve that type to render the modifier at all — an
    // `#available` check guards execution, not the type. On iOS 17.x the type is
    // absent from the system SwiftUI, so the metadata lookup fails and the Swift
    // runtime traps. Erasing pins Body to AnyView, which exists on every version
    // we support; the glass call is then only reached inside the guarded branch.
    func body(content: Content) -> AnyView {
        if #available(iOS 26.0, *) {
            if isCircle {
                return AnyView(content.glassEffect(in: .circle))
            }
            return AnyView(content.glassEffect(in: .capsule))
        }
        // Shares FlekFrostedSurface with the springboard search button — the two
        // sit side by side in the bottom bar and previously used different tints.
        if isCircle {
            return AnyView(content.background(FlekFrostedSurface(shape: Circle())))
        }
        return AnyView(content.background(FlekFrostedSurface(shape: Capsule())))
    }
}

// MARK: - Chin Control Entrance
/// Brings one of the switcher's chin controls in as the overlay opens: it rises
/// the last few points into the row and fades up, with the side buttons leaning
/// out from the middle and each one starting a beat after the last.
///
/// The stagger is what makes the row read as arriving rather than as being drawn
/// — the same left-to-right cascade iOS gives a toolbar it is presenting.
/// `from` is which way the control leans in: -1 leading, 0 straight up, 1
/// trailing.
@available(iOS 16.0, *)
struct ChinControlEntrance: ViewModifier {
    let shown: Bool
    let index: Int
    let from: CGFloat

    func body(content: Content) -> some View {
        content
            .offset(x: shown ? 0 : from * 14, y: shown ? 0 : 18)
            .opacity(shown ? 1 : 0)
            // Bound to `shown` alone, so it plays on the way in and leaves the
            // exit — a single offset carrying the whole chin off the bottom —
            // to run undisturbed.
            .animation(.spring(response: 0.42, dampingFraction: 0.82)
                        .delay(Double(index) * 0.04),
                       value: shown)
    }
}

// MARK: - Bar Control Button Style
/// The press behaviour shared by every control in the bar and in the switcher's
/// chin: the glass and its glyph shrink together under the finger and spring
/// back on release, the way iOS's own glass controls answer a touch.
///
/// A `ButtonStyle` rather than a gesture, so the press state comes from the
/// button itself and survives a finger that slides off and back on. It scales
/// `configuration.label`, which is why each control puts its glass *inside* its
/// label — glass applied to the button outside the style would sit still while
/// the glyph shrank inside it.
@available(iOS 16.0, *)
struct BarControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7),
                       value: configuration.isPressed)
    }
}

// MARK: - Symbol Bounce
/// Bounces an SF Symbol each time `value` changes, as iOS bounces its own
/// symbols to acknowledge a button whose effect is elsewhere on screen.
///
/// Erased to AnyView — see `DockPillBackground.body` for why: symbol effects are
/// an iOS 17 type and must not reach an iOS 16 runtime through this Body.
@available(iOS 16.0, *)
struct SymbolBounce: ViewModifier {
    let value: Int
    func body(content: Content) -> AnyView {
        if #available(iOS 17.0, *) {
            return AnyView(content.symbolEffect(.bounce, value: value))
        }
        return AnyView(content)
    }
}

// MARK: - Symbol Replace Transition
/// Swaps one SF Symbol for another the way iOS swaps its own: the outgoing glyph
/// scales away downward as the incoming one rises into its place, rather than
/// cross-fading. Drives the switcher chevron as it flips between down (hide the
/// bar) and up (bring it back).
///
/// Erased to AnyView — see `DockPillBackground.body` for why. `.symbolEffect` is
/// an iOS 17 type, and an opaque return type would bake it into the view's Body
/// metadata, which iOS 16 cannot resolve even though the call itself is guarded.
@available(iOS 16.0, *)
struct SymbolReplaceTransition: ViewModifier {
    func body(content: Content) -> AnyView {
        if #available(iOS 17.0, *) {
            return AnyView(content.contentTransition(.symbolEffect(.replace.downUp)))
        }
        // No symbol effects before 17: fade one glyph into the other instead.
        return AnyView(content.contentTransition(.opacity))
    }
}

// MARK: - Snapshot View Representable
/// Displays a UIView snapshot (replicant) in SwiftUI, resizing it to fit the available space.
/// Uses frame-based resizing (not transforms) since the view from resizableSnapshotView is
/// designed to be resized. This avoids issues with replicant views whose internal bounds
/// may not reflect point dimensions on Retina displays.
@available(iOS 16.0, *)
struct SnapshotViewRepresentable: UIViewRepresentable {
    let snapshotView: UIView
    /// The snapshot's shape when it was taken.
    var naturalSize: CGSize = .zero
    /// Quarter-turn needed to sit upright in a portrait card.
    var rotation: CGFloat = 0

    func makeUIView(context: Context) -> SnapshotFitView {
        let container = SnapshotFitView()
        container.naturalSize = naturalSize
        container.rotation = rotation
        container.setSnapshot(snapshotView)
        return container
    }

    func updateUIView(_ container: SnapshotFitView, context: Context) {
        container.naturalSize = naturalSize
        container.rotation = rotation
        container.setSnapshot(snapshotView)
    }
}

/// Holds a snapshot aspect-fitted and centred on a black backing.
///
/// The fit runs in `layoutSubviews` rather than in the representable's `updateUIView`:
/// SwiftUI calls that on state changes, not when the view is resized, so a container
/// that was still zero-sized on the first pass would never get a second one and the
/// card stayed black.
@available(iOS 16.0, *)
final class SnapshotFitView: UIView {
    var naturalSize: CGSize = .zero {
        didSet { if naturalSize != oldValue { setNeedsLayout() } }
    }
    var rotation: CGFloat = 0 {
        didSet { if rotation != oldValue { setNeedsLayout() } }
    }

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSnapshot(_ snapshot: UIView) {
        guard snapshot.superview !== self else { return }
        subviews.forEach { $0.removeFromSuperview() }
        snapshot.autoresizingMask = []
        addSubview(snapshot)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let snapshot = subviews.first else { return }
        let source = naturalSize
        guard source.width > 0, source.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            snapshot.frame = bounds
            return
        }
        // Aspect-fill. This path carries a live replicant of a guest's remote layer,
        // which keeps re-rendering as the guest re-lays out, so its content can differ
        // from the size recorded at capture. Filling crops that mismatch away; fitting
        // would strand the content in black margins.
        //
        // A turned capture is measured against its post-turn footprint, so the card is
        // filled by what the viewer actually sees rather than by the untured shape.
        let footprint = rotation == 0 ? source : CGSize(width: source.height, height: source.width)
        let scale = max(bounds.width / footprint.width, bounds.height / footprint.height)
        snapshot.transform = .identity
        snapshot.bounds = CGRect(origin: .zero,
                                 size: CGSize(width: source.width * scale,
                                              height: source.height * scale))
        snapshot.transform = rotation == 0 ? .identity : CGAffineTransform(rotationAngle: rotation)
        snapshot.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

// MARK: - Loading Icon View
struct LoadingIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.3))
            
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.2)
        }
    }
}
