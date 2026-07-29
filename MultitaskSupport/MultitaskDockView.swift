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
    private var navAssistButton: UIView?
    private var navAssistChevron: UIImageView?
    private var isNavAssistStashed: Bool = false

    /// Which edge the floating button stashes against. Portrait uses the
    /// horizontal edges (left/right); landscape uses the vertical edges
    /// (top/bottom) so the button tucks away along the long edges instead.
    private enum NavAssistEdge { case left, right, top, bottom }
    private var navAssistStashedEdge: NavAssistEdge = .right

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
        Constants.barHeightWithLedge
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
        let amount: CGFloat = reserved ? Constants.barHeight : 0
        if isBarLandscape {
            controller.additionalSafeAreaInsets.right = amount
            controller.additionalSafeAreaInsets.bottom = 0
        } else {
            controller.additionalSafeAreaInsets.bottom = amount
            controller.additionalSafeAreaInsets.right = 0
        }
    }

    public struct Constants {
        // MARK: - Switcher Bar Layout
        static let barHeight: CGFloat = 25.0
        /// Taller bar strip used when the rounded ledge (concave corners) is on.
        static let barHeightWithLedge: CGFloat = 80.0
        static let barIconSize: CGFloat = 40.0
        static let barButtonSize: CGFloat = 40.0
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
    }

    /// The window the bar and its overlays attach to. `connectedScenes` is an
    /// *unordered* Set and multi-scene support is enabled, so after an in-place app
    /// update iOS can restore a stale/background scene from the previous launch.
    /// Picking `connectedScenes.first`/`windows.first` could then return nil (→ the
    /// bar container is never added, so the bar never shows) or a not-yet-ready
    /// window whose `safeAreaInsets` are still zero (→ the bar is sized without the
    /// home-indicator inset — the "weird sizing"). A clean install has only one
    /// fresh scene, which is why the bug never appears there. Resolve deterministically
    /// by preferring the foreground-active scene's key window, then falling back.
    public var keyWindow: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .sorted { Self.sceneActivationRank($0) < Self.sceneActivationRank($1) }
        for scene in scenes {
            if let key = scene.windows.first(where: { $0.isKeyWindow }) { return key }
        }
        for scene in scenes {
            if let visible = scene.windows.first(where: { !$0.isHidden }) ?? scene.windows.first {
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
    }

    /// The visible solid strip of the bar (below the concave corners). Floored to
    /// the button height so the buttons are always covered: portrait gets button
    /// room from its ~34pt home-indicator inset, but landscape has none — and with a
    /// large device corner radius (~55pt) the natural region (effectiveBarHeight -
    /// cornerRadius + inset) fell short of the 44pt buttons. Portrait's larger
    /// natural value still wins, so it's unaffected.
    public var barFlatRegion: CGFloat {
        let buttonRoom = Constants.barButtonSize * 1.1 + 14   // buttons + margin
        let base = max(effectiveBarHeight - barCornerRadiusActive, 0) + safeAreaInsets.bottom
        return max(base, buttonRoom)
    }

    // MARK: - Bar Edge / Orientation

    /// Whether the switcher bar should sit on a vertical (short) edge, i.e. the
    /// device is in landscape. The bar always lives on a *short* edge: the
    /// bottom in portrait, the right edge in landscape.
    private var isBarLandscape: Bool {
        if let orientation = keyWindow?.windowScene?.interfaceOrientation {
            return orientation.isLandscape
        }
        return UIScreen.main.bounds.width > UIScreen.main.bounds.height
    }

    /// The resting transform of the bar's hosting view. Identity in portrait;
    /// rotated -90° in landscape so the (otherwise identical) horizontal pill
    /// runs vertically along the right edge. Applying this transform to a view
    /// whose local bounds are a horizontal strip yields the vertical bar.
    private var barBaseTransform: CGAffineTransform {
        isBarLandscape ? CGAffineTransform(rotationAngle: -.pi / 2) : .identity
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
        
        // Menu label: icon + app name text + chevron
        let menuIconSize: CGFloat = 24
        let chevronWidth: CGFloat = 12
        let menuInternalSpacing: CGFloat = 5
        let menuHPadding: CGFloat = 8
        let appName = frontmostAppName()
        let textWidth = (appName as NSString).size(withAttributes: [
            .font: UIFont.systemFont(ofSize: 14, weight: .medium)
        ]).width
        let menuWidth = menuHPadding + menuIconSize + menuInternalSpacing + textWidth + menuInternalSpacing + chevronWidth + menuHPadding
        
        return Constants.barHPadding + sideButtonsWidth + menuWidth + Constants.barHPadding
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
    }

    @objc private func deviceOrientationDidChange() {
        DispatchQueue.main.async {
            if self.isVisible {
                // Snap (not animate) so the bar lands on its new short edge as the
                // system's own rotation animation completes, avoiding a compounded
                // spin from animating our -90° transform at the same time.
                self.updateDockFrame(animated: false)
                // Reposition nav assist if visible
                if let button = self.navAssistButton {
                    self.snapNavAssistToEdge(button, animated: false)
                }
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

        let screenBounds = UIScreen.main.bounds
        var insets = safeAreaInsets
        // On a fast, state-restored launch (after an in-place update) the window's
        // safe area can still be zero when the bar first lays out, which would size
        // the bar without the home-indicator inset. Force a layout pass and re-read
        // so a late-arriving bottom inset is applied instead of baked in as zero.
        if !isBarLandscape, insets.bottom == 0, let win = keyWindow {
            win.layoutIfNeeded()
            insets = win.safeAreaInsets
        }

        // Cross-thickness of the bar. Deliberately the same slim value in both
        // orientations so the landscape bar matches the portrait one instead of
        // ballooning to include the large horizontal safe-area inset (e.g. the
        // notch), which previously made it a wide full-height sidebar.
        // Strip = visible flat region + the concave corner radius carved above it.
        let thickness = barFlatRegion + barCornerRadiusActive


        let boundsSize: CGSize
        let center: CGPoint
        if isBarLandscape {
            // Vertical strip on the right edge. Local strip length spans the
            // screen height; thickness extends inward from the right edge.
            boundsSize = CGSize(width: screenBounds.height, height: thickness)
            center = CGPoint(x: screenBounds.width - thickness / 2, y: screenBounds.height / 2)
        } else {
            // Horizontal strip on the bottom edge (unchanged portrait layout).
            boundsSize = CGSize(width: screenBounds.width, height: thickness)
            center = CGPoint(x: screenBounds.width / 2, y: screenBounds.height - thickness / 2)
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
                options: .curveEaseOut
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
                        UIView.animate(withDuration: Constants.shortAnimationDuration1, delay: 0, options: .curveEaseIn) {
                            overlay.view.alpha = 0
                        } completion: { _ in
                            overlay.view.removeFromSuperview()
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
                return
            }

            self.isSwitcherBarVisible = true
            self.refreshOrientationLock()

            // Reserve space for the bar on its current edge for internal pages
            for (_, controller) in self.internalPageControllers {
                self.applyBarInset(to: controller, reserved: true)
            }

            // Add the pass-through container (which holds the bar) to the window.
            if let container = self.barContainer {
                container.frame = keyWindow.bounds
                if container.superview !== keyWindow {
                    keyWindow.addSubview(container)
                } else {
                    keyWindow.bringSubviewToFront(container)
                }
            } else if hostingController.view.superview == nil {
                keyWindow.addSubview(hostingController.view)
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
                // Minimize ALL visible windows and hide the dock bar
                self.minimizeAllWindows()
                self.updateFrontmostApp()
                self.isHomeState = true
                self.hideDock()
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

        let size = Constants.navAssistSize
        let screenBounds = window.bounds
        let x = screenBounds.width - safeAreaInsets.right - size - Constants.navAssistMargin
        let y = screenBounds.height * 0.5

        isNavAssistStashed = false
        navAssistChevron = nil

        let button = createNavAssistButton()
        button.center = CGPoint(x: x + size / 2, y: y)

        window.addSubview(button)
        self.navAssistButton = button
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
            options: .curveEaseOut
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
        let iconImage = UIImage(systemName: "iphone.app.switcher", withConfiguration: iconConfig)
        let iconView = UIImageView(image: iconImage)
        iconView.tintColor = .white
        iconView.contentMode = .center
        iconView.frame = button.bounds
        iconView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        iconView.tag = 100 // Tag for reliable lookup
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
            
        case .ended, .cancelled:
            snapNavAssistToEdge(button, animated: true)
            
        default:
            break
        }
    }
    
    private func snapNavAssistToEdge(_ button: UIView, animated: Bool) {
        let screenBounds = keyWindow!.bounds
        let safeArea = safeAreaInsets
        let margin = Constants.navAssistMargin
        let halfSize = Constants.navAssistSize / 2
        let stashThreshold: CGFloat = halfSize + margin // How close to edge before stashing

        // Portrait keeps the button on the vertical (left/right) edges; in
        // landscape it may dock/stash against any of the four edges.
        let allowedEdges: [NavAssistEdge] = isBarLandscape
            ? [.left, .right, .top, .bottom]
            : [.left, .right]

        // Distance from the button center to a given screen edge.
        func distance(to edge: NavAssistEdge) -> CGFloat {
            switch edge {
            case .left:   return button.center.x
            case .right:  return screenBounds.width - button.center.x
            case .top:    return button.center.y
            case .bottom: return screenBounds.height - button.center.y
            }
        }

        // Snap to whichever allowed edge is nearest.
        let edge = allowedEdges.min(by: { distance(to: $0) < distance(to: $1) })!

        let minX = safeArea.left + margin + halfSize
        let maxX = screenBounds.width - safeArea.right - margin - halfSize
        let minY = safeArea.top + margin + halfSize
        let maxY = screenBounds.height - safeArea.bottom - margin - halfSize
        let clampedX = max(minX, min(maxX, button.center.x))
        let clampedY = max(minY, min(maxY, button.center.y))

        // Resting position when docked to an edge ignores that edge's safe-area
        // inset so the button can sit right against the physical edge (the notch
        // inset on the sides, and the home-indicator inset at the bottom,
        // otherwise push it far inward in landscape). Portrait only uses the
        // left/right edges, whose insets are zero, so it is unaffected.
        let edgeMinX = margin + halfSize
        let edgeMaxX = screenBounds.width - margin - halfSize
        let edgeMinY = margin + halfSize
        let edgeMaxY = screenBounds.height - margin - halfSize

        if distance(to: edge) < stashThreshold {
            navAssistStashedEdge = edge
            // The stash slides the button off `edge`; `along` is the free-axis
            // coordinate (Y for left/right edges, X for top/bottom edges).
            let along: CGFloat
            switch edge {
            case .left, .right:  along = clampedY
            case .top, .bottom:  along = clampedX
            }
            stashNavAssist(button, edge: edge, along: along, animated: animated)
        } else {
            let target: CGPoint
            switch edge {
            case .left:   target = CGPoint(x: edgeMinX, y: clampedY)
            case .right:  target = CGPoint(x: edgeMaxX, y: clampedY)
            case .top:    target = CGPoint(x: clampedX, y: edgeMinY)
            case .bottom: target = CGPoint(x: clampedX, y: edgeMaxY)
            }
            restoreNavAssistIcon(button)
            moveNavAssist(button, to: target, alpha: 1.0, animated: animated)
        }
    }

    /// Clears the stashed chevron and restores the normal iphone.app.switcher icon.
    private func restoreNavAssistIcon(_ button: UIView) {
        isNavAssistStashed = false
        navAssistChevron?.removeFromSuperview()
        navAssistChevron = nil
        button.viewWithTag(100)?.isHidden = false
    }

    /// Animates (or snaps) the floating button to a center point.
    private func moveNavAssist(_ button: UIView, to center: CGPoint, alpha: CGFloat, animated: Bool) {
        if animated {
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: Constants.standardSpringDamping,
                initialSpringVelocity: Constants.standardSpringVelocity,
                options: .curveEaseOut
            ) {
                button.center = center
                button.alpha = alpha
            }
        } else {
            button.center = center
            button.alpha = alpha
        }
    }
    
    private func stashNavAssist(_ button: UIView, edge: NavAssistEdge, along: CGFloat, animated: Bool) {
        let screenBounds = keyWindow!.bounds
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
        moveNavAssist(button, to: newCenter, alpha: 0.55, animated: animated)
    }
    
    private func unstashNavAssist() {
        guard let button = navAssistButton else { return }
        let screenBounds = keyWindow!.bounds
        let safeArea = safeAreaInsets
        let margin = Constants.navAssistMargin
        let halfSize = Constants.navAssistSize / 2
        
        // Remove chevron, restore iphone.app.switcher icon
        restoreNavAssistIcon(button)

        // Slide back in from whichever edge it was stashed against.
        var newCenter = button.center
        switch navAssistStashedEdge {
        case .right: newCenter.x = screenBounds.width - safeArea.right - margin - halfSize
        case .left:  newCenter.x = safeArea.left + margin + halfSize
        case .bottom: newCenter.y = screenBounds.height - safeArea.bottom - margin - halfSize
        case .top:    newCenter.y = safeArea.top + margin + halfSize
        }

        moveNavAssist(button, to: newCenter, alpha: 1.0, animated: true)
    }
    
    // Find and bring corresponding multitask view to front
    func bringMultitaskViewToFront(uuid: String, from center: CGPoint? = nil) -> Bool {
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
                animateViewAppearance(targetView, from: center, in: window)
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

    private func animateViewAppearance(_ view: UIView, from center: CGPoint?, in window: UIWindow) {
        let isHidden = view.isHidden || view.alpha < 0.1
        let decoratedVC = view._viewDelegate() as? DecoratedAppSceneViewController
        let isMaximized = decoratedVC?.isMaximized ?? false
        
        // when a fullscreen multitask app is brought to front, optionally hide other windows
        if UserDefaults.lcShared().bool(forKey: "LCMaxOneAppOnStage") && isMaximized {
            MultitaskDockManager.shared.minimizeAllWindows(except: decoratedVC)
        }
        
        if isHidden {
            view.layer.removeAllAnimations()
            view.isHidden = true
            view.transform = .identity
            let origFrame = view.frame
            let pipManager = PiPManager.shared!
            if let decoratedVC = view._viewDelegate(), pipManager.isPiP(withDecoratedVC: decoratedVC) {
                pipManager.stopPiP()
            } else {
                view.transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
                view.isHidden = false
                let smaller = min(view.frame.size.width, view.frame.size.height)
                view.frame.size = CGSize(width: smaller, height: smaller)
                if let center { view.center = center }
            }
            
            self.bringViewToFront(view, in: window)
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: 1.0,
                initialSpringVelocity: 0,
                options: .curveEaseInOut,
                animations: {
                    view.alpha = 1.0
                    view.transform = .identity
                    view.frame = origFrame
                }
            )
        } else {
            bringViewToFront(view, in: window)
            
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
        
        DispatchQueue.main.async {
            self.apps.append(appModel)
            self.frontmostAppUUID = appUUID
            self.isHomeState = false
            
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
        
        let appModel = DockAppModel(appName: name, appUUID: uuid, view: hostVC.view, internalPageKind: kind)
        
        DispatchQueue.main.async {
            self.apps.append(appModel)
            self.frontmostAppUUID = uuid
            self.isHomeState = false
            
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
    
    @objc public func minimizeAllWindows(except: DecoratedAppSceneViewController? = nil) {
        DispatchQueue.main.async {
            // Capture snapshots of visible windows before minimizing them
            for app in self.apps {
                self.captureSnapshot(for: app.appUUID)
            }
            self.apps.forEach { app in
                if app.isInternalPage {
                    app.view?.isHidden = true
                } else if let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController,
                   vc != except {
                    app.view?.layer.removeAllAnimations()
                    vc.minimizeWindow()
                }
            }
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
        
        // Capture the content region only, dropping the safe-area periphery on every
        // edge. The guest is handed those insets as `peripheryInsets` and fills them
        // with its own background, which on screen reads as the status-bar and
        // home-indicator strips — but a card has neither, so they arrive as dead
        // margin around the app. Internal pages need the same treatment for a second
        // reason: they pin their bottom controls above the switcher bar, and that
        // reserved strip is part of the safe area too.
        //
        // Trimming every edge rather than just the bottom keeps this correct in
        // landscape, where the periphery sits on the sides — and those sides become
        // the top and bottom of the card once the capture is turned upright.
        let captureRect = appView.bounds.inset(by: appView.safeAreaInsets)
        let viewSize = captureRect.size
        guard viewSize.width > 0 && viewSize.height > 0 else { return }

        // Cards are always portrait, so a landscape capture is turned a quarter turn to
        // fill one rather than sitting as a band between black margins. Which way to
        // turn depends on the edge the user rotated towards, so the content ends up
        // the same way up as when they were looking at it.
        var quarterTurn: CGFloat = 0
        if viewSize.width > viewSize.height {
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
        appSnapshotRotations[appUUID] = quarterTurn

        func uprightForPortraitCard(_ image: UIImage) -> UIImage {
            // Re-tagging the CGImage costs nothing and never resamples.
            guard quarterTurn != 0, let cgImage = image.cgImage else { return image }
            return UIImage(cgImage: cgImage, scale: image.scale,
                           orientation: quarterTurn < 0 ? .left : .right)
        }

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
                appSnapshotImages[appUUID] = uprightForPortraitCard(image)
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
        keyWindow.addSubview(hc.view)
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
            options: .curveEaseOut
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
        minimizeAllWindows()
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
            app.view?.removeFromSuperview()
            internalPageControllers[uuid] = nil
            removeRunningApp(uuid)
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
                overlay.view.removeFromSuperview()
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

    
    var body: some View {
        activeBarContent
        // Make the bar buttons 10% larger (scales the glass pills + glyphs uniformly).
        .scaleEffect(1.1)
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
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                dockManager.hideSwitcherBar()
            }) {
                Image(systemName: "chevron.down")
                    .foregroundColor(.white)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: MultitaskDockManager.Constants.barButtonSize,
                           height: MultitaskDockManager.Constants.barButtonSize)
            }
            .stableBarGlass(capsule: false)
            
            // Middle: App switcher button
            Button(action: {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                if dockManager.isAppSwitcherOpen {
                    dockManager.dismissAppSwitcher()
                } else {
                    dockManager.showAppSwitcher()
                }
            }) {
                FrontmostAppIconLabel()
                    .stableBarGlass(capsule: true)
            }
            
            // Right: Home button
            Button(action: {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                dockManager.goHome()
            }) {
                Image(systemName: "app")
                    .foregroundColor(.white)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: MultitaskDockManager.Constants.barButtonSize,
                           height: MultitaskDockManager.Constants.barButtonSize)
            }
            .stableBarGlass(capsule: false)
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
        HStack(spacing: 5) {
            if let icon = appIcon {
                Image(uiImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: "app.fill")
                    .foregroundColor(.white)
                    .font(.system(size: 18))
                    .frame(width: 24, height: 24)
            }
            
            Text(frontmostApp?.appName ?? "App")
                .foregroundColor(.white)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
            
            Image(systemName: "chevron.up")
                .foregroundColor(.white.opacity(0.6))
                .font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 16)
        .frame(height: MultitaskDockManager.Constants.barButtonSize)
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
    
    private let cardSpacing: CGFloat = 16

    // Fixed corner radius (matches the Figma design spec).
    private let cardCornerRadius: CGFloat = 34

    // Card dimensions — proportional to screen like iOS app switcher
    /// Raised from 0.62 to hold the card's original height. Card height now follows
    /// the trimmed snapshot's aspect rather than the screen's, which is shorter, so
    /// at the old fraction the card lost ~11% of its height.
    private var cardWidth: CGFloat {
        UIScreen.main.bounds.width * 0.70
    }
    /// Shaped like the snapshot it holds, not like the whole screen. Snapshots are
    /// captured with the safe-area periphery trimmed off, so they are shorter than
    /// the screen — sizing the card from the full screen aspect left the image
    /// slightly too tall for it, and filling the card then cropped the sides.
    private var cardHeight: CGFloat {
        let screen = UIScreen.main.bounds
        let insets = dockManager.cachedSafeAreaInsets
        let contentHeight = max(screen.height - insets.top - insets.bottom, 1)
        return cardWidth * (contentHeight / screen.width)
    }

    // How far the cards slide left and the buttons slide down when the user taps
    // the background to return to the springboard.
    private var exitCardOffset: CGFloat { UIScreen.main.bounds.width + cardWidth }
    private var exitButtonOffset: CGFloat { UIScreen.main.bounds.height * 0.4 }
    
    var body: some View {
        ZStack(alignment: .bottom) {
            // Blurred springboard background: the captured home (wallpaper +
            // icons) behind a dark material, the same treatment Spotlight uses.
            // Falls back to a flat dark blur if no snapshot was captured.
            ZStack {
                if let snapshot = dockManager.springboardSnapshot {
                    Image(uiImage: snapshot)
                        .resizable()
                        .scaledToFill()
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
                }
                .offset(x: exiting ? -exitCardOffset : 0)
                
                // Flexible gap so the cards sit up top and the bottom actions
                // fall to the bottom edge.
                Spacer(minLength: 20)

                // Close all button (floating capsule, centered above the bar).
                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    showCloseAllConfirm = true
                }) {
                    HStack(spacing: 7) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Close all")
                            .font(.system(size: 18, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .modifier(GlassCapsuleBackground())
                }
                .padding(.bottom, 20)
                .offset(y: exiting ? exitButtonOffset : 0)
                .alert("Close All Apps?", isPresented: $showCloseAllConfirm) {
                    Button("Cancel", role: .cancel) { }
                    Button("Close All", role: .destructive) {
                        dockManager.closeAllApps()
                    }
                } message: {
                    Text("This closes every open app.")
                }

                // Reserve the bar's footprint so Close all sits above the bottom
                // bar (which is a separate bottom-anchored layer below).
                Spacer()
                    .frame(height: 50)
            }

            // Control preference toggle, styled as the switcher bar it hides: a
            // full-width black bar anchored flush to the very bottom edge with
            // exactly the real bar's thickness (bar height + bottom safe area).
            // As its own bottom-aligned ZStack layer it can't be shifted by the
            // VStack's flow, so its height matches the real bar precisely.
            Button(action: {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.easeInOut(duration: 0.25)) {
                    dockManager.setPrefersFloatingButton(!dockManager.prefersFloatingButton)
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: dockManager.prefersFloatingButton ? "platter.filled.bottom.iphone" : "chevron.down")
                        .font(.system(size: 18, weight: .semibold))
                        .contentTransition(.opacity)
                    Text(dockManager.prefersFloatingButton ? "Use Switcher Bar" : "Hide Switcher Bar")
                        .font(.system(size: 18, weight: .medium))
                        .contentTransition(.opacity)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                // Center the label in the flat solid body (from the flat-top line
                // down to the bottom edge), instead of pinning it to the bottom.
                // Pad the top by the corner-ledge height so centering happens below
                // the concave corners, while keeping the overall height (bar height
                // + bottom safe area) so the bar shape/background is unchanged.
                .frame(maxWidth: .infinity,
                       minHeight: dockManager.effectiveBarHeight - dockManager.barCornerRadiusActive + dockManager.cachedSafeAreaInsets.bottom,
                       alignment: .center)
                .padding(.top, dockManager.barCornerRadiusActive)
                // Limit the tap area to the bar's actual visible shape. The frame is
                // as tall as the real bar (incl. the concave overhang), but that
                // overhang is transparent and overlaps the "Close all" button above
                // it — a rectangular hit area there stole Close all's taps and
                // flipped this toggle instead. Matching the hit shape to the fill
                // frees the overhang so Close all receives its taps.
                .contentShape(BarTopBar(radius: dockManager.barCornerRadiusActive,
                                        curve: dockManager.barCornerRadiusActive * dockManager.barLedgeAmountActive))
            }
            .buttonStyle(.plain)
            // Same concave rounded top corners and height as the switcher bar it
            // hides — including the rounding amount from the Settings slider, so
            // this chin always matches the real bar. Solid black while the bar is
            // the active control; once the user taps Hide (floating-button mode),
            // the black fades out to reveal a translucent ultra-thin-material bar
            // underneath. Layering the black over the material and animating its
            // opacity lets the two states cross-fade smoothly when the toggle flips.
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
                    .ignoresSafeArea()
            }
            .offset(y: exiting ? exitButtonOffset : 0)
        }
        .ignoresSafeArea()
        // Tap anywhere that isn't a card or a button returns to the springboard.
        // Cards and buttons consume their own taps, so only the empty area here
        // (top, bottom, sides, gaps between cards) triggers this.
        .contentShape(Rectangle())
        .onTapGesture {
            exitToSpringboard()
        }
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
                cardHStack
                    .scrollTargetLayout()
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
                cardHStack
            }
        }
    }
    
    private var cardHStack: some View {
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
        .padding(.horizontal, (UIScreen.main.bounds.width - cardWidth) / 2)
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
    private static var windowInterfaceStyle: UIUserInterfaceStyle {
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
                    completion([])
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
            }
            // Customize button, laid over the whole row rather than placed in it.
            // UIKit anchors a button's menu to that button's bounds, so a 32pt button
            // on the trailing edge put the menu against the card's right edge; a
            // row-wide source centres it on the card. Only its trailing icon area
            // takes touches, so the name beside it stays untappable. Guest apps only:
            // internal Settings / Installer pages have no guest process, so nothing
            // in the menu would apply to them.
            .overlay {
                if !app.isInternalPage {
                    CustomizeMenuButton(app: app)
                }
            }
            // Inset the row 20pt on each side so the name (left) and the customize
            // button (right) sit just inside the card's edges.
            .frame(width: cardWidth - 40)
            .padding(.horizontal, 20)
            
            // Card with snapshot
            ZStack {
                if let snapshotImage = dockManager.appSnapshotImages[app.appUUID] {
                    // Frozen bitmap, filling the card. A landscape capture was already
                    // turned upright, so both orientations arrive at roughly the card's
                    // own aspect and fill crops only a sliver — where fitting would
                    // leave black bars wherever the capture was trimmed.
                    Image(uiImage: snapshotImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: cardWidth, height: cardHeight)
                        .clipped()
                } else if let snapshotView = dockManager.appSnapshotViews[app.appUUID] {
                    SnapshotViewRepresentable(
                        snapshotView: snapshotView,
                        naturalSize: dockManager.appSnapshotSizes[app.appUUID] ?? .zero,
                        rotation: dockManager.appSnapshotRotations[app.appUUID] ?? 0)
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
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            dockManager.dismissAppSwitcher()
            let _ = dockManager.bringMultitaskViewToFront(uuid: app.appUUID)
        }
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
    private let iconSize: CGFloat = FlekTheme.searchPillSize * 0.94
    
    var body: some View {
        ForEach(Array(dockManager.apps.suffix(4))) { app in
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
        }
    }
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
    private let pillHeight: CGFloat = FlekTheme.searchPillSize * 1.3

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
        } else {
            switcherButton
                .frame(width: pillHeight, height: pillHeight)
                .modifier(DockPillBackground(isCircle: true))
        }
    }

    private var switcherButton: some View {
        Button {
            MultitaskDockManager.shared.showAppSwitcher()
        } label: {
            Image(systemName: "iphone.app.switcher")
                .font(.system(size: FlekTheme.searchPillSize * 0.55, weight: .regular))
                .foregroundStyle(Color.primary.opacity(0.6))
                .frame(width: FlekTheme.searchPillSize * 1.3, height: FlekTheme.searchPillSize * 1.3)
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

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if isCircle {
                content.glassEffect(in: .circle)
            } else {
                content.glassEffect(in: .capsule)
            }
        } else {
            if isCircle {
                content.background(
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(Circle().fill(Color.primary.opacity(0.15)))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                )
            } else {
                content.background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(Capsule().fill(Color.primary.opacity(0.15)))
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                )
            }
        }
    }
}

// MARK: - Glass Capsule Background (native Liquid Glass on iOS 26+, fallback on older)
struct GlassCapsuleBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(in: .capsule)
        } else {
            content.background(Capsule().fill(Color.white.opacity(0.15)))
        }
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
