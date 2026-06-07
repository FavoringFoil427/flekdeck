//
//  FlekLauncherModel.swift
//  LiveContainerSwiftUI
//
//  Shared model + value types for the FlekLauncher springboard.
//

import SwiftUI

/// AppStorage keys used by the launcher. Stored in the app group so they are
/// shared across LiveContainer instances, matching the rest of the app.
enum FlekLauncherKeys {
    static let wallpaperName = "FlekWallpaperName"   // bundled wallpaper asset name
    static let wallpaperPhoto = "FlekWallpaperPhoto" // file name of a user-picked photo wallpaper
    static let homeLayout = "FlekHomeLayout"         // "grid" | "list"
    static let launchedApps = "FlekLaunchedApps"     // bundle paths that have been opened at least once
}

/// Home screen layout chosen on the Personalization page.
enum FlekHomeLayout: String {
    case grid
    case list
}

/// The three built-in "apps" pinned at the start of the home screen.
/// They open internal FlekLauncher pages instead of a guest app.
enum FlekDefaultAppKind: String, CaseIterable, Identifiable {
    case flekstore
    case settings
    case installer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flekstore: return "FlekSt0re"
        case .settings: return "lc.tabView.settings".loc
        case .installer: return "Installer"
        }
    }

    var iconAssetName: String {
        switch self {
        case .flekstore: return "FlekIconFlekStore"
        case .settings: return "FlekIconSettings"
        case .installer: return "FlekIconInstaller"
        }
    }
}

/// One tile on the springboard: either a built-in app or an installed guest app.
enum FlekHomeItem: Identifiable {
    case defaultApp(FlekDefaultAppKind)
    case installed(LCAppModel)

    var id: String {
        switch self {
        case .defaultApp(let kind): return "default.\(kind.rawValue)"
        case .installed(let app): return "app.\(app.appInfo.relativeBundlePath ?? app.appInfo.bundlePath() ?? UUID().uuidString)"
        }
    }
}

/// Per-app launch mode chosen from the home screen context menu. "Single"
/// launches the app on its own (full screen); "Parallel" uses the existing
/// multitasking window engine. A `nil` value means the user never picked one
/// (treated as single, and not badged).
enum FlekLaunchMode: String {
    case single
    case parallel
}

final class FlekLaunchModeStore {
    static let shared = FlekLaunchModeStore()
    private let store = LCUtils.appGroupUserDefault
    private let key = "FlekAppLaunchModes"

    private var map: [String: String] {
        get { store.dictionary(forKey: key) as? [String: String] ?? [:] }
        set { store.set(newValue, forKey: key) }
    }

    func mode(for app: LCAppModel) -> FlekLaunchMode? {
        guard let id = app.appInfo.relativeBundlePath, let raw = map[id] else { return nil }
        return FlekLaunchMode(rawValue: raw)
    }

    func set(_ mode: FlekLaunchMode, for app: LCAppModel) {
        guard let id = app.appInfo.relativeBundlePath else { return }
        var m = map
        m[id] = mode.rawValue
        map = m
    }

    /// Whether the single-mode badge should be shown (user explicitly chose single).
    func showsSingleBadge(for app: LCAppModel) -> Bool {
        mode(for: app) == .single
    }
}

/// Tracks which guest apps have been launched at least once, so freshly
/// installed apps can show the blue "new" dot until first launch.
final class FlekLaunchTracker {
    static let shared = FlekLaunchTracker()
    private let store = LCUtils.appGroupUserDefault

    private var launched: Set<String> {
        get { Set(store.stringArray(forKey: FlekLauncherKeys.launchedApps) ?? []) }
        set { store.set(Array(newValue), forKey: FlekLauncherKeys.launchedApps) }
    }

    func isNew(_ app: LCAppModel) -> Bool {
        guard let key = app.appInfo.relativeBundlePath else { return false }
        return !launched.contains(key)
    }

    func markLaunched(_ app: LCAppModel) {
        guard let key = app.appInfo.relativeBundlePath else { return }
        var set = launched
        if set.insert(key).inserted {
            launched = set
        }
    }
}
