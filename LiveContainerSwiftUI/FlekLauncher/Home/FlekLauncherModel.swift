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

/// The control edit mode draws in an item's corner.
enum FlekEditBadge {
    /// No control — the item is not an app the user manages.
    case none
    /// The usual minus, which uninstalls.
    case remove
    /// Stands in for the minus on an app that cannot be removed from the home
    /// screen; tapping it says why and where to go instead.
    case explain
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
    ///
    /// Shared apps are excluded: their bundle lives in the app group, where every
    /// LiveContainer instance on the device uses the same copy, so removing it
    /// here would take it away from all of them. The app's own menu hides
    /// Uninstall for the same reason — without this, edit mode was the one place
    /// that still offered (and performed) the deletion.
    ///
    /// A shared app whose bundle has already vanished is the exception: there is
    /// no shared copy left to protect, only a stale row, and refusing to delete
    /// it would strand it on the home screen with no way out.
    var canDelete: Bool {
        if case .installed(let app) = self { return !app.uiIsShared || app.isBundleMissing }
        return false
    }

    /// What edit mode puts in the corner of this item.
    ///
    /// An installed app that cannot be deleted still gets a control, just one
    /// that explains itself instead of removing anything. Leaving the corner
    /// empty is what made a shared app a dead end: no minus, and no way to find
    /// out why or what to do instead.
    var editBadge: FlekEditBadge {
        guard case .installed = self else { return .none }
        return canDelete ? .remove : .explain
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
    var failed: Bool = false    // install/download failed — show failed icon
    var errorMessage: String? = nil // reason to show in the failed-install alert
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

    /// Drops the app's stored mode when it is uninstalled. The key is the folder
    /// name, so a later install of the same app would otherwise silently adopt
    /// the choice made for the copy that is being removed.
    func forget(_ app: LCAppModel) {
        guard let id = app.appInfo.relativeBundlePath, cache.removeValue(forKey: id) != nil else { return }
        persist()
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

    /// Forgets an uninstalled app, so a later install of the same one is new
    /// again rather than inheriting the launched state of the copy it replaced.
    func forget(_ app: LCAppModel) {
        guard let key = app.appInfo.relativeBundlePath, cache.remove(key) != nil else { return }
        persist()
    }
}
