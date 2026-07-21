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
    static let homeScreenOrder = "FlekHomeScreenOrder" // ordered IDs of all home screen items (default apps + installed)
    static let homeScreenPageSizes = "FlekHomeScreenPageSizes" // per-page item counts for custom page layouts
    static let cardStyleGlass = "FlekCardStyleGlass" // true = liquid glass, false = thin material
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

/// One tile on the springboard: a built-in app, an installed guest app, the
/// app currently being installed, or an empty grid slot (placeholder).
enum FlekHomeItem: Identifiable, DragulaItem {
    case defaultApp(FlekDefaultAppKind)
    case installed(LCAppModel)
    case installing(InstallItem)
    /// Empty grid slot that preserves an item's position on the grid.
    case placeholder(String)

    var id: String {
        switch self {
        case .defaultApp(let kind): return "default.\(kind.rawValue)"
        case .installed(let app): return "app.\(app.appInfo.relativeBundlePath ?? app.appInfo.bundlePath() ?? "unknown")"
        case .installing(let item): return "installing.\(item.id)"
        case .placeholder(let uid): return "placeholder.\(uid)"
        }
    }

    /// Only real app items can be dragged.
    var isDraggable: Bool {
        switch self {
        case .placeholder: return false
        default: return true
        }
    }

    /// Whether this item is an empty grid slot.
    var isPlaceholder: Bool {
        if case .placeholder = self { return true }
        return false
    }

    /// Whether this item can be deleted in edit mode.
    var canDelete: Bool {
        if case .installed = self { return true }
        return false
    }

    func getItemProvider() -> NSItemProvider {
        NSItemProvider(object: id as NSString)
    }
}

/// Snapshot of the in-progress install, used to render the install card/row.
struct FlekInstallState: Equatable {
    var name: String?
    var iconURL: String?
    var fraction: Double        // 0...1, combined progress for download bar
    var indeterminate: Bool     // true during prepare / decompress / signing
    var isInstalling: Bool      // true during install (post-download) phases
    var installFraction: Double // 0...1, install-only progress for circular ring
}

/// Per-app launch mode chosen from the home screen context menu. "Single"
/// launches the app on its own (full screen); "Parallel" uses the existing
/// multitasking window engine. A `nil` value means the user never picked one
/// (uses the global default from settings, not badged).
enum FlekLaunchMode: String {
    case single
    case parallel
}

final class FlekLaunchModeStore {
    static let shared = FlekLaunchModeStore()
    private let store = LCUtils.appGroupUserDefault
    private let key = "FlekAppLaunchModes"

    /// In-memory cache of the launch-mode map. mode()/showsSingleBadge() are
    /// called for every home cell on every render pass, so reading UserDefaults
    /// each time was needless work during scroll. Seed lazily from disk and
    /// refresh only on write.
    private lazy var cache: [String: String] = (store.dictionary(forKey: key) as? [String: String]) ?? [:]

    private func persist() {
        store.set(cache, forKey: key)
    }

    /// Reload from disk (e.g. if another LiveContainer instance changed it).
    func refresh() {
        cache = (store.dictionary(forKey: key) as? [String: String]) ?? [:]
    }

    func mode(for app: LCAppModel) -> FlekLaunchMode? {
        guard let id = app.appInfo.relativeBundlePath, let raw = cache[id] else { return nil }
        return FlekLaunchMode(rawValue: raw)
    }

    func set(_ mode: FlekLaunchMode, for app: LCAppModel) {
        guard let id = app.appInfo.relativeBundlePath else { return }
        cache[id] = mode.rawValue
        persist()
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

    /// In-memory cache so isNew() doesn't read UserDefaults and rebuild a Set for
    /// every row on every render. Seeded lazily from disk; updated on write.
    private lazy var cache: Set<String> = Set(store.stringArray(forKey: FlekLauncherKeys.launchedApps) ?? [])

    private func persist() {
        store.set(Array(cache), forKey: FlekLauncherKeys.launchedApps)
    }

    /// Reload from disk (e.g. if another LiveContainer instance changed it).
    func refresh() {
        cache = Set(store.stringArray(forKey: FlekLauncherKeys.launchedApps) ?? [])
    }

    func isNew(_ app: LCAppModel) -> Bool {
        guard let key = app.appInfo.relativeBundlePath else { return false }
        return !cache.contains(key)
    }

    func markLaunched(_ app: LCAppModel) {
        guard let key = app.appInfo.relativeBundlePath else { return }
        if cache.insert(key).inserted {
            persist()
        }
    }
}
