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
    
    @objc init(appName: String, appUUID: String, appInfo: LCAppInfo? = nil, view: UIView?) {
        self.appName = appName
        self.appUUID = appUUID
        self.appInfo = appInfo
        self.view = view
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

    @objc public var windowHostingView = VirtualWindowsHostView()
    internal var hostingController: UIHostingController<AnyView>?
    private var navAssistButton: UIView?
    private var navAssistChevron: UIImageView?
    private var isNavAssistStashed: Bool = false
    private var navAssistStashedOnRight: Bool = true

    // Backward compatibility — always false since collapsed dock concept was removed
    @objc public var isCollapsed: Bool { return false }
    
    /// ObjC-accessible flag for whether the switcher bar is currently shown
    @objc public var barVisible: Bool { return isSwitcherBarVisible }

    public struct Constants {
        // MARK: - Switcher Bar Layout
        static let barHeight: CGFloat = 52.0
        static let barIconSize: CGFloat = 36.0
        static let barButtonSize: CGFloat = 36.0
        static let barSpacing: CGFloat = 10.0
        static let barHPadding: CGFloat = 12.0
        static let barVPadding: CGFloat = 8.0
        static let barCornerRadius: CGFloat = 26.0
        static let barBottomMargin: CGFloat = 16.0
        
        // MARK: - Navigation Assist
        static let navAssistSize: CGFloat = 50.0
        static let navAssistMargin: CGFloat = 8.0
        
        // MARK: - Animation
        static let standardAnimationDuration: TimeInterval = 0.3
        static let longAnimationDuration: TimeInterval = 0.4
        static let shortAnimationDuration1: TimeInterval = 0.15
        static let shortAnimationDuration2: TimeInterval = 0.1
        
        static let standardSpringDamping: CGFloat = 0.8
        static let showHideSpringDamping: CGFloat = 0.7
        static let standardSpringVelocity: CGFloat = 0.3
        static let showHideSpringVelocity: CGFloat = 0.5
        
        static let initialScale: CGFloat = 0.8
        static let bringToFrontScale: CGFloat = 1.02
    }

    public var keyWindow: UIWindow? {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first
    }

    public var safeAreaInsets: UIEdgeInsets {
        keyWindow?.safeAreaInsets ?? .zero
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
        keyWindow!.rootViewController!.view.addSubview(self.windowHostingView)
        setupDockView()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func deviceOrientationDidChange() {
        DispatchQueue.main.async {
            if self.isVisible {
                self.updateDockFrame()
                // Reposition nav assist if visible
                if let button = self.navAssistButton {
                    self.snapNavAssistToEdge(button, animated: false)
                }
            }
        }
    }
    
    private func setupDockView() {
        DispatchQueue.main.async {
            let barView = AnyView(SwitcherBarContentView()
                .environmentObject(self)
                .preferredColorScheme(.dark)
                .environment(\.colorScheme, .dark))
            
            self.hostingController = UIHostingController(rootView: barView)
            self.hostingController?.view.backgroundColor = .black
            self.hostingController?.view.clipsToBounds = false
            self.hostingController?.view.insetsLayoutMarginsFromSafeArea = false
            self.hostingController?.overrideUserInterfaceStyle = .dark
            self.hostingController?.view.overrideUserInterfaceStyle = .dark
        }
    }

    // MARK: - Frame Management
    private func updateDockFrame(animated: Bool = true) {
        guard let hostingController = hostingController, isSwitcherBarVisible else { return }

        let screenBounds = UIScreen.main.bounds
        let y = screenBounds.height - Constants.barHeight - safeAreaInsets.bottom
        let newFrame = CGRect(x: 0, y: y, width: screenBounds.width, height: screenBounds.height - y)
        
        if animated {
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: Constants.standardSpringDamping,
                initialSpringVelocity: Constants.standardSpringVelocity,
                options: .curveEaseOut
            ) {
                hostingController.view.frame = newFrame
            }
        } else {
            hostingController.view.frame = newFrame
        }
    }
    
    @objc public func addRunningApp(_ appName: String, appUUID: String, view: UIView?) {
        let appInfo = AppInfoProvider.shared.findAppInfo(appName: appName, dataUUID: appUUID)
        addRunningAppWithInfo(appInfo, appUUID: appUUID, view: view)
    }
    
    @objc public func removeRunningApp(_ appUUID: String) {
        guard isDockEnabled() else { return }
        
        DispatchQueue.main.async {
            self.apps.removeAll { $0.appUUID == appUUID }
            
            if self.frontmostAppUUID == appUUID {
                self.updateFrontmostApp()
            }
            
            if self.apps.isEmpty {
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
            self.isSwitcherBarVisible = true
            
            if hostingController.view.superview == nil {
                keyWindow.addSubview(hostingController.view)
            }
            
            self.updateDockFrame(animated: false)
            
            hostingController.view.alpha = 0
            hostingController.view.transform = CGAffineTransform(translationX: 0, y: 50)
            
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: Constants.showHideSpringDamping,
                initialSpringVelocity: Constants.showHideSpringVelocity,
                options: .curveEaseOut
            ) {
                hostingController.view.alpha = 1
                hostingController.view.transform = .identity
            }
        }
    }
    
    @objc public func hideDock() {
        guard isVisible, let hostingController = hostingController else { return }
        
        DispatchQueue.main.async {
            self.isVisible = false
            
            // Also remove nav assist if visible
            self.navAssistButton?.removeFromSuperview()
            self.navAssistButton = nil
            
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: Constants.showHideSpringDamping,
                initialSpringVelocity: Constants.showHideSpringVelocity,
                options: .curveEaseOut
            ) {
                hostingController.view.alpha = 0
                hostingController.view.transform = CGAffineTransform(translationX: 0, y: 50)
            } completion: { _ in
                hostingController.view.transform = .identity
            }
        }
    }
    
    // MARK: - Switcher Bar Actions
    
    /// Home button: minimize all visible windows, or restore last app if all minimized
    @objc public func goHome() {
        DispatchQueue.main.async {
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
    
    /// Hide the switcher bar with slide-down animation and show navigation assist
    @objc public func hideSwitcherBar() {
        guard let hostingController = hostingController, let keyWindow = self.keyWindow else { return }
        
        DispatchQueue.main.async {
            self.isSwitcherBarVisible = false
            NotificationCenter.default.post(name: .multitaskBarVisibilityChanged, object: nil)
            
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: Constants.standardSpringDamping,
                initialSpringVelocity: Constants.standardSpringVelocity,
                options: .curveEaseOut,
                animations: {
                    hostingController.view.alpha = 0
                    hostingController.view.transform = CGAffineTransform(translationX: 0, y: 80)
                }
            ) { _ in
                hostingController.view.isHidden = true
                hostingController.view.transform = .identity
                self.showNavAssist(in: keyWindow)
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
            self.updateDockFrame(animated: false)
            NotificationCenter.default.post(name: .multitaskBarVisibilityChanged, object: nil)
            
            hostingController.view.isHidden = false
            hostingController.view.alpha = 0
            hostingController.view.transform = CGAffineTransform(translationX: 0, y: 50)
            
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0.15,
                usingSpringWithDamping: Constants.showHideSpringDamping,
                initialSpringVelocity: Constants.showHideSpringVelocity,
                options: .curveEaseOut
            ) {
                hostingController.view.alpha = 1
                hostingController.view.transform = .identity
            }
        }
    }
    
    // MARK: - Navigation Assist Button
    
    private func showNavAssist(in window: UIWindow) {
        let size = Constants.navAssistSize
        let screenBounds = window.bounds
        let x = screenBounds.width - safeAreaInsets.right - size - Constants.navAssistMargin
        let y = screenBounds.height * 0.5
        
        isNavAssistStashed = false
        navAssistChevron = nil
        
        let button = createNavAssistButton()
        button.center = CGPoint(x: x + size / 2, y: y)
        button.alpha = 0
        button.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
        
        window.addSubview(button)
        self.navAssistButton = button
        
        UIView.animate(
            withDuration: Constants.standardAnimationDuration,
            delay: 0.15,
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
        let iconImage = UIImage(systemName: "square.stack", withConfiguration: iconConfig)
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
            unstashNavAssist()
        } else {
            showSwitcherBar()
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
        
        let onRight = button.center.x >= screenBounds.width / 2
        
        // Check if close enough to screen edge to stash
        let distanceToEdge: CGFloat
        if onRight {
            distanceToEdge = screenBounds.width - button.center.x
        } else {
            distanceToEdge = button.center.x
        }
        
        let shouldStash = distanceToEdge < stashThreshold
        
        let minY = safeArea.top + margin + halfSize
        let maxY = screenBounds.height - safeArea.bottom - margin - halfSize
        let targetY = max(minY, min(maxY, button.center.y))
        
        if shouldStash {
            navAssistStashedOnRight = onRight
            stashNavAssist(button, onRight: onRight, targetY: targetY, animated: animated)
        } else {
            let targetX: CGFloat
            if onRight {
                targetX = screenBounds.width - safeArea.right - margin - halfSize
            } else {
                targetX = safeArea.left + margin + halfSize
            }
            
            isNavAssistStashed = false
            navAssistChevron?.removeFromSuperview()
            navAssistChevron = nil
            button.viewWithTag(100)?.isHidden = false
            
            let newCenter = CGPoint(x: targetX, y: targetY)
            if animated {
                UIView.animate(
                    withDuration: Constants.standardAnimationDuration,
                    delay: 0,
                    usingSpringWithDamping: Constants.standardSpringDamping,
                    initialSpringVelocity: Constants.standardSpringVelocity,
                    options: .curveEaseOut
                ) {
                    button.center = newCenter
                    button.alpha = 1.0
                }
            } else {
                button.center = newCenter
                button.alpha = 1.0
            }
        }
    }
    
    private func stashNavAssist(_ button: UIView, onRight: Bool, targetY: CGFloat, animated: Bool) {
        let screenBounds = keyWindow!.bounds
        let size = Constants.navAssistSize
        // Show half the button so the chevron arrow is always visible
        let visibleAmount: CGFloat = size * 0.50
        let targetX: CGFloat
        if onRight {
            targetX = screenBounds.width - visibleAmount + size / 2
        } else {
            targetX = visibleAmount - size / 2
        }
        
        isNavAssistStashed = true
        
        // Add chevron indicator if not already present
        if navAssistChevron == nil {
            let chevronName = onRight ? "chevron.left" : "chevron.right"
            let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
            let chevronImage = UIImage(systemName: chevronName, withConfiguration: config)
            let chevronView = UIImageView(image: chevronImage)
            chevronView.tintColor = .white
            chevronView.contentMode = .center
            // Offset chevron toward the visible side
            let chevronFrame = button.bounds
            chevronView.frame = chevronFrame
            chevronView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            
            // Hide the main icon, show chevron
            button.viewWithTag(100)?.isHidden = true
            button.addSubview(chevronView)
            navAssistChevron = chevronView
        }
        
        let newCenter = CGPoint(x: targetX, y: targetY)
        if animated {
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: Constants.standardSpringDamping,
                initialSpringVelocity: Constants.standardSpringVelocity,
                options: .curveEaseOut
            ) {
                button.center = newCenter
                button.alpha = 0.85
            }
        } else {
            button.center = newCenter
            button.alpha = 0.85
        }
    }
    
    private func unstashNavAssist() {
        guard let button = navAssistButton else { return }
        let screenBounds = keyWindow!.bounds
        let safeArea = safeAreaInsets
        let margin = Constants.navAssistMargin
        let halfSize = Constants.navAssistSize / 2
        
        isNavAssistStashed = false
        
        // Remove chevron, restore square.stack icon
        navAssistChevron?.removeFromSuperview()
        navAssistChevron = nil
        button.viewWithTag(100)?.isHidden = false
        
        let targetX: CGFloat
        if navAssistStashedOnRight {
            targetX = screenBounds.width - safeArea.right - margin - halfSize
        } else {
            targetX = safeArea.left + margin + halfSize
        }
        
        UIView.animate(
            withDuration: Constants.standardAnimationDuration,
            delay: 0,
            usingSpringWithDamping: Constants.standardSpringDamping,
            initialSpringVelocity: Constants.standardSpringVelocity,
            options: .curveEaseOut
        ) {
            button.center.x = targetX
            button.alpha = 1.0
        }
    }
    
    // Find and bring corresponding multitask view to front
    func bringMultitaskViewToFront(uuid: String, from center: CGPoint? = nil) -> Bool {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            return false
        }

        for window in windowScene.windows {
            if let targetView = findMultitaskView(in: window, withUUID: uuid) {
                passURLSchemeToView(targetView)
                animateViewAppearance(targetView, from: center, in: window)
                let wasHomeState = self.isHomeState
                self.isHomeState = false
                self.frontmostAppUUID = uuid
                if wasHomeState {
                    self.showDock()
                } else {
                    self.updateDockFrame()
                }
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
            }
        }
    }
    
    @objc public func minimizeAllWindows(except: DecoratedAppSceneViewController? = nil) {
        DispatchQueue.main.async {
            self.apps.forEach { app in
                if let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController,
                   vc != except {
                    app.view?.layer.removeAllAnimations()
                    vc.minimizeWindow()
                }
            }
        }
    }
    
    // MARK: - Multitask Mode Check
    private func isDockEnabled() -> Bool {
        let multitaskMode = MultitaskMode(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCMultitaskMode")) ?? .virtualWindow
        return multitaskMode == .virtualWindow
    }
}

// MARK: - Switcher Bar Content View
@available(iOS 16.0, *)
struct SwitcherBarContentView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    
    var body: some View {
        activeBarContent
        .padding(.horizontal, MultitaskDockManager.Constants.barHPadding)
        .padding(.vertical, MultitaskDockManager.Constants.barVPadding)
        .frame(maxWidth: .infinity)
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
            .modifier { content in
                if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                    content.glassEffect(.regular, in: .circle)
                } else {
                    content.background(Circle().fill(Color.white.opacity(0.15)))
                }
            }
            
            // Middle: App switcher dropdown menu
            Menu {
                ForEach(dockManager.apps) { app in
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        let _ = dockManager.bringMultitaskViewToFront(uuid: app.appUUID)
                    }) {
                        Label {
                            Text(app.appName)
                        } icon: {
                            if let icon = Self.cachedIcon(for: app) {
                                Image(uiImage: icon)
                            } else {
                                Image(systemName: "app.fill")
                            }
                        }
                    }
                }
            } label: {
                FrontmostAppIconLabel()
                    .modifier { content in
                        if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                            content.glassEffect(.regular, in: .capsule)
                        } else {
                            content.background(Capsule().fill(Color.white.opacity(0.15)))
                        }
                    }
            }
            
            // Right: Home button
            Button(action: {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                dockManager.goHome()
            }) {
                Image(systemName: "square")
                    .foregroundColor(.white)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: MultitaskDockManager.Constants.barButtonSize,
                           height: MultitaskDockManager.Constants.barButtonSize)
            }
            .modifier { content in
                if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                    content.glassEffect(.regular, in: .circle)
                } else {
                    content.background(Circle().fill(Color.white.opacity(0.15)))
                }
            }
        }
    }
    
    
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false
    
    static func cachedIcon(for app: DockAppModel) -> UIImage? {
        let cacheKey = "\(app.appName)_\(app.appUUID)"
        if let cached = IconCacheManager.shared.getIcon(for: cacheKey) {
            return cached
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
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
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

// MARK: - Multitask Home Icons (shown on home screen when dock is hidden)
@available(iOS 16.0, *)
struct MultitaskHomeIcons: View {
    @ObservedObject var dockManager = MultitaskDockManager.shared
    let darkModeIcon: Bool
    private let iconSize: CGFloat = FlekTheme.searchPillSize
    
    var body: some View {
        ForEach(Array(dockManager.apps.prefix(4))) { app in
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                let _ = dockManager.bringMultitaskViewToFront(uuid: app.appUUID)
            } label: {
                if let icon = SwitcherBarContentView.cachedIcon(for: app) {
                    Image(uiImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .frame(width: iconSize, height: iconSize)
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                } else {
                    Image(systemName: "app.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: iconSize, height: iconSize)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.gray.opacity(0.3)))
                }
            }
            .buttonStyle(.plain)
        }
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
