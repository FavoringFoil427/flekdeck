import UIKit
import SwiftUI
import Intents

@objc class AppDelegate: UIResponder, UIApplicationDelegate {
    
    /// Set to `.portrait` when the springboard is visible so that only the
    /// home screen is locked to portrait while the rest of the app can rotate.
    static var orientationLock: UIInterfaceOrientationMask = .allButUpsideDown

    /// Puts the interface into `orientationLock`, turning the window when the
    /// orientation it is currently in has just stopped being allowed.
    ///
    /// Narrowing the mask is not enough on its own. UIKit re-resolves orientation
    /// off a device event, and leaving a landscape app for the springboard is not
    /// one — the phone lies exactly where it was. Without an explicit request the
    /// window keeps that landscape and the springboard, which has only a portrait
    /// layout, is drawn sideways into it.
    ///
    /// Returns whether a turn was actually asked for, so a caller that must not draw
    /// until the window has turned knows whether it has anything to wait for.
    @discardableResult
    static func applyOrientationLock() -> Bool {
        guard #available(iOS 16.0, *) else { return false }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                ?? scenes.first else { return false }

        // Every window in the scene, not just the key one. This app keeps overlay
        // windows above its own — the multitask host, the rotation readout — and
        // whichever of them happens to be key may have no root controller at all,
        // in which case asking only the key window asks nobody.
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }

        let current = mask(for: scene.interfaceOrientation)
        guard !current.isEmpty, !orientationLock.contains(current) else { return false }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientationLock))
        return true
    }

    /// The single-orientation mask an interface orientation belongs to, so it can
    /// be tested against `orientationLock`. Empty for `.unknown`, which no mask
    /// contains and which nothing should be turned away from.
    private static func mask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        switch orientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return []
        }
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? ) -> Bool {
        application.shortcutItems = nil
        UserDefaults.standard.removeObject(forKey: "LCNeedToAcquireJIT")
        
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            // Fix launching app if user opens JIT waiting dialog and kills the app. Won't trigger normally.
            if DataManager.shared.model.isJITModalOpen && !UserDefaults.standard.bool(forKey: "LCKeepSelectedWhenQuit"){
                UserDefaults.standard.removeObject(forKey: "selected")
                UserDefaults.standard.removeObject(forKey: "selectedContainer")
            }
        }
        
        // allow new scene pop up as a new fullscreen window
        method_exchangeImplementations(
            class_getInstanceMethod(UIApplication.self, #selector(UIApplication.requestSceneSessionActivation(_ :userActivity:options:errorHandler:)))!,
            class_getInstanceMethod(UIApplication.self, #selector(UIApplication.hook_requestSceneSessionActivation(_:userActivity:options:errorHandler:)))!)

        // remove symbol caches if user upgraded iOS
        if let lastIOSBuildVersion = LCUtils.appGroupUserDefault.string(forKey: "LCLastIOSBuildVersion"),
           let currentVersion = UIDevice.current.buildVersion,
           lastIOSBuildVersion == currentVersion {
            
        } else {
            LCUtils.appGroupUserDefault.removeObject(forKey: "symbolOffsetCache")
            LCUtils.appGroupUserDefault.setValue(UIDevice.current.buildVersion, forKey: "LCLastIOSBuildVersion")
        }
        
        // Auto-import embedded fs_cert.p12 if no certificate is stored yet
        if LCSharedUtils.certificatePassword() == nil {
            Self.importEmbeddedCertificateIfNeeded()
        }
        
        return true
    }
    
    /// Silently imports fs_cert.p12 from the app bundle on first launch.
    private static func importEmbeddedCertificateIfNeeded() {
        guard let url = Bundle.main.url(forResource: "fs_cert", withExtension: "p12"),
              let certData = try? Data(contentsOf: url) else { return }
        
        let password: String = {
            if let value = Bundle.main.infoDictionary?["fsPassword"] as? String, !value.isEmpty {
                return value
            }
            return "12345"
        }()
        
        guard LCUtils.getCertTeamId(withKeyData: certData, password: password) != nil else { return }
        
        LCUtils.appGroupUserDefault.set(certData, forKey: "LCCertificateData")
        LCUtils.appGroupUserDefault.set(password, forKey: "LCCertificatePassword")
        LCUtils.appGroupUserDefault.set(Date(), forKey: "LCCertificateUpdateDate")
    }
    
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return Self.orientationLock
    }
    
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
    
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        switch intent {
        case is ViewAppIntent: return ViewAppIntentHandler()
        default:
            return nil
        }
    }
    
}

class SceneDelegate: NSObject, UIWindowSceneDelegate, ObservableObject { // Make SceneDelegate conform ObservableObject
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        self.window = (scene as? UIWindowScene)?.keyWindow
    }
    
}


@objc extension UIApplication {
    
    func hook_requestSceneSessionActivation(
        _ sceneSession: UISceneSession?,
        userActivity: NSUserActivity?,
        options: UIScene.ActivationRequestOptions?,
        errorHandler: ((any Error) -> Void)? = nil
    ) {
        var newOptions = options
        if newOptions == nil {
            newOptions = UIScene.ActivationRequestOptions()
        }
        newOptions!._setRequestFullscreen(UIScreen.main.bounds == self.keyWindow!.bounds)
        self.hook_requestSceneSessionActivation(sceneSession, userActivity: userActivity, options: newOptions, errorHandler: errorHandler)
    }
    
}

/// Manages a passthrough overlay window that shows the iOS beta warning badge
/// above all app content, including sheets and full-screen covers.
class BetaOverlayManager {
    static let shared = BetaOverlayManager()
    private var overlayWindow: UIWindow?

    func show(on scene: UIWindowScene) {
        guard overlayWindow == nil else { return }

        let window = PassthroughWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        window.isHidden = false

        let hosting = UIHostingController(rootView: BetaBadgeView())
        hosting.view.backgroundColor = .clear
        window.rootViewController = hosting
        overlayWindow = window
    }

    func hide() {
        overlayWindow?.isHidden = true
        overlayWindow = nil
    }
}

/// A UIWindow subclass that passes through all touches so the badge
/// doesn't block interaction with the app underneath.
private class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Return nil so all touches pass through to the window below.
        return nil
    }
}

/// Watermark-style overlay shown in the bottom-right corner, like "Activate Windows".
private struct BetaBadgeView: View {
    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("iOS Beta Detected")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Beta versions of iOS may cause certificate revocation.\nApps and features may not work correctly.\nPlease roll back to the stable release version.")
                        .font(.system(size: 11))
                        .multilineTextAlignment(.trailing)
                }
                .foregroundStyle(.white.opacity(0.55))
                .shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 1)
                .padding(.trailing, 16)
                .padding(.bottom, 90)
            }
        }
        .ignoresSafeArea()
    }
}

public class ViewAppIntentHandler: NSObject, ViewAppIntentHandling
{
    public func provideAppOptionsCollection(for intent: ViewAppIntent, with completion: @escaping (INObjectCollection<App>?, Error?) -> Void)
    {
        completion(INObjectCollection(items:[]), nil)
    }
}
