//
//  TabView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Foundation
import SwiftUI
import ObjectiveC

struct LCTabView: View {
    @Binding var appDataFolderNames: [String]
    @Binding var tweakFolderNames: [String]
    
    @State var errorShow = false
    @State var crashReportShow = false
    @State var errorInfo = ""
    @State private var isiOSBeta = false
    @AppStorage("LCBetaBannerOverride", store: LCUtils.appGroupUserDefault) private var betaBannerOverride: Int = 0
    
    @State var previousSelectedTab : LCTabIdentifier = .apps
    @State private var isBlocked = false
    @State private var hasCheckedBlockedStatus = false
    @State private var didFailBlockedStatusCheck = false
    @State private var pendingURL: URL?
    @State private var accessVerificationFailureMessage = "Please check your internet connection and try again."
    @State private var blockedReason = "Unavailable"
    @State private var blockedMessage = "Your access has been limited by the service."
    @AppStorage("FSEncryptedUDID") private var encryptedUDID: String = ""
    
    @EnvironmentObject var sharedModel : SharedModel
    @EnvironmentObject var sceneDelegate: SceneDelegate
    @State var shouldToggleMainWindowOpen = false
    @Environment(\.scenePhase) var scenePhase

    
    @StateObject var searchContextAppList = SearchContext()
    @StateObject var searchContextSource = SearchContext()
    
    let pub = NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)
    
    var body: some View {
        Group {
            if !hasCheckedBlockedStatus {
                ZStack {
                    Color.black.ignoresSafeArea()
                    ProgressView()
                        .tint(.white)
                }
            } else if didFailBlockedStatusCheck {
                AccessVerificationFailedView(message: accessVerificationFailureMessage) {
                    Task {
                        await refreshBlockedStatus()
                    }
                }
            } else if isBlocked {
                AccessBlockedView(reason: blockedReason, message: blockedMessage)
            } else {
                // FlekLauncher: the springboard home screen replaces the old tab bar.
                // Settings and the Installer are now opened as full-screen pages from
                // the home screen instead of being separate tabs.
                LCAppListView(appDataFolderNames: $appDataFolderNames, tweakFolderNames: $tweakFolderNames, searchContext: searchContextAppList)
            }
        }
        .modifier(HomeIndicatorHiddenModifier())
        .alert("lc.common.error".loc, isPresented: $errorShow) {
            Button("lc.common.ok".loc) {}
            Button("lc.common.copy".loc) { copyError() }
        } message: {
            Text(errorInfo)
        }
        .sheet(isPresented: $crashReportShow) {
            NavigationView {
                ScrollView {
                    Text(errorInfo)
                        .font(.system(size: 12).monospaced())
                        .fixedSize(horizontal: false, vertical: false)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("lc.common.copy".loc, action: {
                            copyError()
                        })
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("lc.common.ok".loc, action: {
                            crashReportShow = false
                        })
                    }
                }
                .navigationTitle("lc.common.error".loc)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            setupInitialRepositoriesIfNeeded()
            Task { await MultiRepoSearchModel.prefetchAllRepos() }
            await refreshBlockedStatus()

            guard !isBlocked, !didFailBlockedStatusCheck else {
                return
            }

            sharedModel.selectedTab = .apps
            closeDuplicatedWindow()
            checkLastLaunchError()
            checkTeamId()
            checkBundleId()
            checkGetTaskAllow()
            checkPrivateContainerBookmark()
            checkiOSBeta()
            processPendingURLIfNeeded()
        }
        .onReceive(pub) { out in
            if let scene1 = sceneDelegate.window?.windowScene, let scene2 = out.object as? UIWindowScene, scene1 == scene2 {
                if shouldToggleMainWindowOpen {
                    DataManager.shared.model.mainWindowOpened = false
                }
            }
        }
        .onChange(of: sharedModel.selectedTab) { newValue in
            if newValue != LCTabIdentifier.search {
                previousSelectedTab = newValue
            }
        }
        .onChange(of: betaBannerOverride) { _ in
            updateBetaOverlay()
        }
        .onOpenURL { url in
            dispatchURL(url: url)
        }
    }
    
    func dispatchURL(url: URL) {
        if isBlocked || didFailBlockedStatusCheck || !hasCheckedBlockedStatus {
            pendingURL = url
            return
        }
        repeat {
            if url.isFileURL {
                sharedModel.selectedTab = .apps
                break
            }
            if url.scheme?.lowercased() == "sidestore" {
                sharedModel.selectedTab = .apps
                break
            }
            
            guard let host = url.host?.lowercased() else {
                return
            }
            
            switch host {
            case "livecontainer-launch", "install", "open-web-page", "open-url":
                sharedModel.selectedTab = .apps
            case "certificate":
                sharedModel.selectedTab = .settings
            case "source":
                sharedModel.selectedTab = .sources
            default:
                return
            }
            
        } while(false)
        
        sharedModel.deepLink = url
    }

    func processPendingURLIfNeeded() {
        guard let url = pendingURL else {
            return
        }
        pendingURL = nil
        dispatchURL(url: url)
    }
    
    // MARK: - Existing helper functions
    func closeDuplicatedWindow() {
        if let session = sceneDelegate.window?.windowScene?.session, DataManager.shared.model.mainWindowOpened {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil) { e in
                print(e)
            }
        } else {
            shouldToggleMainWindowOpen = true
        }
        DataManager.shared.model.mainWindowOpened = true
    }
    
    func checkLastLaunchError() {
        var errorStr = UserDefaults.standard.string(forKey: "error")
        if errorStr == nil && UserDefaults.standard.bool(forKey: "SigningInProgress") {
            errorStr = "lc.signer.crashDuringSignErr".loc
            UserDefaults.standard.removeObject(forKey: "SigningInProgress")
        }
        guard let errorStr else { return }
        UserDefaults.standard.removeObject(forKey: "error")
        errorInfo = errorStr
        crashReportShow = true
    }
    
    func copyError() { UIPasteboard.general.string = errorInfo }
    
    
    func checkTeamId() {
        if let certificateTeamId = UserDefaults.standard.string(forKey: "LCCertificateTeamId") {
            if DataManager.shared.model.multiLCStatus != 2 {
                return
            }
            
            guard let primaryLCTeamId = Bundle.main.infoDictionary?["PrimaryLiveContainerTeamId"] as? String else {
                print("Unable to find PrimaryLiveContainerTeamId")
                return
            }
            if certificateTeamId != primaryLCTeamId {
                errorInfo = "lc.settings.multiLC.teamIdMismatch".loc
                errorShow = true
                return
            }
            return
        }
        
        guard let currentTeamId = LCSharedUtils.teamIdentifier() else {
            print("Failed to determine team id.")
            return
        }
        
        if DataManager.shared.model.multiLCStatus == 2 {
            guard let primaryLCTeamId = Bundle.main.infoDictionary?["PrimaryLiveContainerTeamId"] as? String else {
                print("Unable to find PrimaryLiveContainerTeamId")
                return
            }
            if currentTeamId != primaryLCTeamId {
                errorInfo = "lc.settings.multiLC.teamIdMismatch".loc
                errorShow = true
                return
            }
        }
        UserDefaults.standard.set(currentTeamId, forKey: "LCCertificateTeamId")
    }
    
    func checkBundleId() {
        if UserDefaults.standard.bool(forKey: "LCBundleIdChecked") {
            return
        }
        
        let task = SecTaskCreateFromSelf(nil)
        guard let value = SecTaskCopyValueForEntitlement(task, "application-identifier" as CFString, nil), let appIdentifier = value.takeRetainedValue() as? String else {
            errorInfo = "Unable to determine application-identifier"
            errorShow = true
            return
        }
        
        guard let bundleId = Bundle.main.bundleIdentifier else {
            return
        }
        
        var correctBundleId = ""
        if appIdentifier.count > 11 {
            let startIndex = appIdentifier.index(appIdentifier.startIndex, offsetBy: 11)
            correctBundleId = String(appIdentifier[startIndex...])
        }
        
        if(bundleId != correctBundleId) {
            errorInfo = "lc.settings.bundleIdMismatch %@ %@".localizeWithFormat(bundleId, correctBundleId)
            //errorShow = true
        }
        UserDefaults.standard.set(true, forKey: "LCBundleIdChecked")
    }
    
    func checkGetTaskAllow() {
        let task = SecTaskCreateFromSelf(nil)
        guard let value = SecTaskCopyValueForEntitlement(task, "get-task-allow" as CFString, nil), (value.takeRetainedValue() as? NSNumber)?.boolValue ?? false else {
            errorInfo = "lc.settings.notDevCert".loc
            errorShow = true
            return
        }
    }
    
    private func setupInitialRepositoriesIfNeeded() {
        let didSetupKey = "DidSetupDefaultRepositories"
        
        guard !UserDefaults.standard.bool(forKey: didSetupKey) else {
            return
        }
        
        let defaultApps: [AppRepository] = [
            AppRepository(
                name: "FlekSt0re Lib",
                iconUrl: "https://flekstore.com/pro_app/icons/apple-touch-icon.png",
                sourceURL: "Default app catalog",
                isSelected: true
            ),
            AppRepository(
                name: "Nabzclan - App Store",
                iconUrl: "https://cdn.nabzclan.vip/popupv3/imgs/logo-tras.png",
                sourceURL: "https://appstore.nabzclan.vip/repos/altstore.php",
                isSelected: false
            ),
            AppRepository(
                name: "AppTesters IPA Repo",
                iconUrl: "https://apptesters.org/apptesters-512x512.png",
                sourceURL: "https://repository.apptesters.org/",
                isSelected: false
            ),
            AppRepository(
                name: "Quantum Source",
                iconUrl: "https://quarksources.github.io/assets/ElementQ-Circled.png",
                sourceURL: "https://quarksources.github.io/dist/quantumsource.min.json",
                isSelected: false
            )
        ]
        
        if let data = try? JSONEncoder().encode(defaultApps) {
            UserDefaults.standard.set(data, forKey: "savedRepositories")
        }
        UserDefaults.standard.set(true, forKey: didSetupKey)
        
    }
    private func refreshBlockedStatus() async {
        #if targetEnvironment(simulator)
        await MainActor.run {
            isBlocked = false
            didFailBlockedStatusCheck = false
            hasCheckedBlockedStatus = true
        }
        return
        #endif

        guard let resolvedEncryptedUDID = resolveEncryptedUDID() else {
            await MainActor.run {
                accessVerificationFailureMessage = "User UDID is empty. Please contact FlekSt0re tech support."
                didFailBlockedStatusCheck = true
                hasCheckedBlockedStatus = true
            }
            return
        }

        guard let url = URL(string: "https://nestapi.flekstore.com/device-service/get-status/\(resolvedEncryptedUDID)") else {
            await MainActor.run {
                accessVerificationFailureMessage = "Please check your internet connection and try again."
                didFailBlockedStatusCheck = true
                hasCheckedBlockedStatus = true
            }
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(DeviceStatusResponse.self, from: data)

            await MainActor.run {
                isBlocked = response.isBanned
                blockedReason = formatBanReason(response.banReason)
                blockedMessage = formatBanMessage(response.message)
                accessVerificationFailureMessage = "Please check your internet connection and try again."
                didFailBlockedStatusCheck = false
                hasCheckedBlockedStatus = true
            }
        } catch {
            await MainActor.run {
                accessVerificationFailureMessage = "Please check your internet connection and try again."
                didFailBlockedStatusCheck = true
                hasCheckedBlockedStatus = true
            }
        }
    }

    private func resolveEncryptedUDID() -> String? {
        let stored = encryptedUDID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty {
            return stored
        }

        if let bundleValue = Bundle.main.infoDictionary?["encryptedUdid"] as? String {
            let trimmed = bundleValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                encryptedUDID = trimmed
                return trimmed
            }
        }

        return nil
    }

    private func formatBanReason(_ rawReason: String?) -> String {
        let trimmed = rawReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "Unavailable" }

        return trimmed.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func formatBanMessage(_ rawMessage: String?) -> String {
        let trimmed = rawMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "Your access has been limited by the service." }

        return trimmed
    }

    func checkiOSBeta() {
        // Beta iOS builds have a build version ending with a lowercase letter (e.g. 22A5307f)
        if let buildVersion = UIDevice.current.buildVersion,
           let lastChar = buildVersion.last,
           lastChar.isLowercase {
            isiOSBeta = true
        }
        updateBetaOverlay()
    }

    private func updateBetaOverlay() {
        let shouldShow: Bool
        switch betaBannerOverride {
        case 1: shouldShow = true
        case 2: shouldShow = false
        default: shouldShow = isiOSBeta
        }

        if let scene = sceneDelegate.window?.windowScene {
            if shouldShow {
                BetaOverlayManager.shared.show(on: scene)
            } else {
                BetaOverlayManager.shared.hide()
            }
        }
    }

    func checkPrivateContainerBookmark() {
        if sharedModel.multiLCStatus == 2 {
            return
        }
        if LCUtils.appGroupUserDefault.object(forKey: "LCLaunchExtensionPrivateDocBookmark") != nil {
            return
        }
        
        guard let bookmark = LCUtils.bookmark(for: LCPath.docPath) else {
            errorInfo = "Failed to create bookmark for Documents folder?"
            errorShow = true
            return
        }
        LCUtils.appGroupUserDefault.set(bookmark, forKey: "LCLaunchExtensionPrivateDocBookmark")
    }
}
private struct AccessVerificationFailedView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.yellow)

                Text("Unable to verify access")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.body)
                    .foregroundStyle(Color.white.opacity(0.85))
                    .multilineTextAlignment(.center)

                Button(action: onRetry) {
                    Text("Retry")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .padding(.top, 8)
            }
            .padding(24)
            .frame(maxWidth: 420)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(0.10))
            )
            .padding(.horizontal, 24)
        }
    }
}

/// Hides the home indicator and requires a double-swipe to trigger the
/// system edge gesture (home bar), preventing accidental exits.
private struct HomeIndicatorHiddenModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content
                .persistentSystemOverlays(.hidden)
                .defersSystemGestures(on: .bottom)
                // SwiftUI's `.defersSystemGestures(on:)` frequently fails to
                // propagate `preferredScreenEdgesDeferringSystemGestures` to the
                // window's view controllers, so the bottom-edge deferral silently
                // does nothing. Install it directly on the hosting controller at
                // runtime as well, so the swipe-up-to-home gesture is actually
                // deferred (first swipe reveals the indicator, second leaves).
                .background(BottomEdgeGestureDeferralInstaller())
        } else {
            content
        }
    }
}

/// Zero-size helper that, once attached to a window, forces iOS to defer the
/// bottom screen-edge system gesture (swipe-up-to-home) by installing
/// `preferredScreenEdgesDeferringSystemGestures` directly on SwiftUI's
/// UIHostingController base class. This is the reliable path when the SwiftUI
/// `.defersSystemGestures` modifier is ignored.
///
/// Caveat: this preference is advisory. iOS still overrides it whenever it
/// decides the user clearly intends to go home, so a firm, deliberate swipe may
/// still leave in a single gesture on some devices / iOS versions — Apple
/// intentionally protects the home gesture and this cannot be fully defeated.
private struct BottomEdgeGestureDeferralInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = InstallerView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}

    private final class InstallerView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let root = window?.rootViewController else { return }
            ScreenEdgeGestureDeferrer.install(fromRoot: root)
        }
    }
}

/// Runtime swizzler that makes every SwiftUI `UIHostingController` report the
/// bottom edge as deferring system gestures.
private enum ScreenEdgeGestureDeferrer {
    /// Hosting classes already swizzled, so repeated installs are no-ops.
    private static var swizzledClasses = Set<ObjectIdentifier>()

    static func install(fromRoot root: UIViewController) {
        let base = hostingControllerBaseClass(of: root) ?? object_getClass(root)
        swizzle(hostingBase: base)
        refresh(from: root)
    }

    /// Walks up the class hierarchy of `vc` and returns the highest-level class
    /// whose name identifies it as a SwiftUI `UIHostingController` — the base
    /// that every specialised `UIHostingController<Content>` inherits from, so
    /// swizzling it covers the root screen and every full-screen cover alike.
    private static func hostingControllerBaseClass(of vc: UIViewController) -> AnyClass? {
        var result: AnyClass? = nil
        var cls: AnyClass? = object_getClass(vc)
        while let c = cls {
            if String(cString: class_getName(c)).contains("UIHostingController") {
                result = c
            }
            cls = class_getSuperclass(c)
        }
        return result
    }

    private static func swizzle(hostingBase cls: AnyClass?) {
        guard let cls else { return }
        let id = ObjectIdentifier(cls)
        guard !swizzledClasses.contains(id) else { return }
        swizzledClasses.insert(id)

        // preferredScreenEdgesDeferringSystemGestures → previous value ∪ .bottom
        let preferredSel = #selector(getter: UIViewController.preferredScreenEdgesDeferringSystemGestures)
        if let method = class_getInstanceMethod(cls, preferredSel) {
            let previousIMP = method_getImplementation(method)
            let typeEnc = method_getTypeEncoding(method)
            let block: @convention(block) (UIViewController) -> UIRectEdge = { obj in
                typealias Getter = @convention(c) (UIViewController, Selector) -> UIRectEdge
                let previous = unsafeBitCast(previousIMP, to: Getter.self)(obj, preferredSel)
                return previous.union(.bottom)
            }
            class_replaceMethod(cls, preferredSel, imp_implementationWithBlock(block), typeEnc)
        }

        // childForScreenEdgesDeferringSystemGestures → nil, so the system reads
        // each hosting controller's own (now-deferred) preference instead of
        // forwarding to a child SwiftUI never wired up. This is a distinct path
        // from the home-indicator-hidden forwarding, which is left untouched.
        let childSel = #selector(getter: UIViewController.childForScreenEdgesDeferringSystemGestures)
        if let method = class_getInstanceMethod(cls, childSel) {
            let typeEnc = method_getTypeEncoding(method)
            let block: @convention(block) (UIViewController) -> UIViewController? = { _ in nil }
            class_replaceMethod(cls, childSel, imp_implementationWithBlock(block), typeEnc)
        }
    }

    /// Asks the current controller stack to re-query the now-swizzled prefs.
    private static func refresh(from root: UIViewController) {
        var vc: UIViewController? = root
        while let current = vc {
            current.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
            vc = current.presentedViewController
        }
    }
}
