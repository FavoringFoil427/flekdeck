//
//  ContentView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Combine
import SwiftUI
import UniformTypeIdentifiers
import UIKit

class SearchContext: ObservableObject {
    @Published var query: String = ""
    @Published var debouncedQuery: String = ""
    @Published var isTyping: Bool = false
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        $query
            .debounce(for: .seconds(0.2), scheduler: DispatchQueue.main)
            .sink { [weak self] value in
                self?.isTyping = true
                self?.debouncedQuery = value
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self?.isTyping = false
                }
            }
            .store(in: &cancellables)
    }
}

struct AppReplaceOption : Hashable {
    var isReplace: Bool
    var nameOfFolderToInstall: String
    var appToReplace: LCAppModel?
}

/// Identifiable wrapper so the game-launch warning can be presented via .sheet(item:).
struct FlekGameWarningTarget: Identifiable {
    let id = UUID()
    let app: LCAppModel
}

struct NavigationTarget: Identifiable {
    let id = UUID()
    let view: AnyView
}

struct LCAppListView : View, LCAppBannerDelegate, LCAppModelDelegate {
    @Binding var appDataFolderNames: [String]
    @Binding var tweakFolderNames: [String]
    
    @State var didAppear = false
    // ipa choosing stuff
    @State var choosingIPA = false
    @State var errorShow = false
    @State var errorInfo = ""
    
    // ipa installing stuff
    @State var installprogressVisible = false
    @State private var homeScrollToPage: Int?
    @State var installProgressPercentage : Float = 0.0
    @State var installObserver : NSKeyValueObservation?
    
    @State var installOptions: [AppReplaceOption]
    @StateObject var installReplaceAlert = AlertHelper<AppReplaceOption>()
    @StateObject var bundleIdInput = InputHelper()
    
    @State var webViewOpened = false
    @State var webViewURL : URL = URL(string: "about:blank")!
    @StateObject private var webViewUrlInput = InputHelper()
    
    @EnvironmentObject var downloadHelper: DownloadHelper
    @StateObject private var installUrlInput = InputHelper()
    
    @State private var jitLog = ""
    @StateObject private var jitAlert = YesNoHelper()
    
    @StateObject private var runWhenMultitaskAlert = YesNoHelper()
    
    @StateObject private var generatedIconStyleSelector = AlertHelper<GeneratedIconStyle>()
    
    @State var safariViewOpened = false
    @State var safariViewURL = URL(string: "https://google.com")!
    
    @State private var navigationTarget: NavigationTarget?
    
    @State private var helpPresent = false
    
    @State private var customSortViewPresent = false

    // FlekLauncher springboard state
    @State private var isEditing = false
    @State private var showSettingsCover = false
    @State private var showInstallerCover = false
    @State private var showSearch = false
    @State private var installerPreselectFlekstore = false
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) var darkModeIcon = false
    @AppStorage(FlekLauncherKeys.homeLayout, store: LCUtils.appGroupUserDefault) var homeLayout: String = FlekHomeLayout.grid.rawValue


    @State private var homeSaveIconExporterShow = false
    @State private var homeSaveIconFile : ImageDocument?
    @StateObject private var homeUninstallAlert = YesNoHelper()
    @StateObject private var homeUninstallFolderAlert = YesNoHelper()
    @State private var homeRefreshToggle = false
    @State private var gameWarningTarget: FlekGameWarningTarget?
    @State private var orderedHomeItems: [FlekHomeItem] = []

    @EnvironmentObject private var sharedModel : SharedModel
    @EnvironmentObject private var sharedAppSortManager : LCAppSortManager
    
    
    @EnvironmentObject private var flekstoreSharedModel: FlekstoreSharedModel
    @EnvironmentObject private var sceneDelegate: SceneDelegate
    
    @AppStorage("LCMultitaskMode", store: LCUtils.appGroupUserDefault) var multitaskMode: MultitaskMode = .virtualWindow
    
    @State private var isViewAppeared = false
    @State private var isMultitaskHomeState = false
    @Environment(\.colorScheme) private var colorScheme
    
    @ObservedObject var searchContext: SearchContext
    var sortedApps: [LCAppModel] {
        return sharedAppSortManager.sortedApps
    }
    
    var sortedHiddenApps: [LCAppModel] {
        return sharedAppSortManager.sortedHiddenApps
    }
    
    var filteredApps: [LCAppModel] {
        let apps = sortedApps
        if searchContext.debouncedQuery.isEmpty {
            return apps
        } else {
            return apps.filter { app in
                app.appInfo.displayName().localizedCaseInsensitiveContains(searchContext.debouncedQuery) ||
                app.appInfo.bundleIdentifier()!.localizedCaseInsensitiveContains(searchContext.debouncedQuery)
            }
        }
    }
    
    var filteredHiddenApps: [LCAppModel] {
        let apps = sortedHiddenApps
        if searchContext.debouncedQuery.isEmpty || !sharedModel.isHiddenAppUnlocked {
            return apps
        } else {
            return apps.filter { app in
                app.appInfo.displayName().localizedCaseInsensitiveContains(searchContext.debouncedQuery) ||
                app.appInfo.bundleIdentifier()!.localizedCaseInsensitiveContains(searchContext.debouncedQuery)
            }
        }
    }
    
    init(appDataFolderNames: Binding<[String]>, tweakFolderNames: Binding<[String]>, searchContext: SearchContext) {
        _installOptions = State(initialValue: [])
        _appDataFolderNames = appDataFolderNames
        _tweakFolderNames = tweakFolderNames
        self.searchContext = searchContext
    }
    
    var body: some View {
        ZStack {
            FlekWallpaperView()

            homeContentView
            .padding(.top, 8)
            .padding(.bottom, 84)
            .id(homeRefreshToggle)
            .blur(radius: showSearch ? 20 : 0)

            if !showSearch {
            VStack {
                Spacer()
                if isEditing {
                    Button {
                        isEditing = false
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Done")
                                .font(.system(size: 16, weight: .medium))
                        }
                        .foregroundStyle(Color.primary.opacity(0.75))
                        .padding(.horizontal, 18)
                        .frame(height: FlekTheme.searchPillSize)
                        .background(Capsule().fill(.ultraThinMaterial))
                        .overlay(Capsule().fill(Color.white.opacity(0.28)))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                } else {
                    HStack(spacing: 10) {
                        // Show running multitask app icons when in home state
                        if #available(iOS 16.0, *), isMultitaskHomeState {
                            if #available(iOS 26.0, *) {
                                GlassEffectContainer(spacing: 10) {
                                    HStack(spacing: 10) {
                                        // App icons + switcher in unified glass pill
                                        HStack(spacing: 8) {
                                            MultitaskHomeIcons(darkModeIcon: darkModeIcon)

                                            // App switcher button
                                            Button {
                                                MultitaskDockManager.shared.showAppSwitcher()
                                            } label: {
                                                Image(systemName: "square.stack")
                                                    .font(.system(size: FlekTheme.searchPillSize * 0.4, weight: .regular))
                                                    .foregroundStyle(Color.primary.opacity(0.6))
                                                    .frame(width: FlekTheme.searchPillSize * 0.8, height: FlekTheme.searchPillSize * 0.8)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .padding(.horizontal, 6)
                                        .frame(height: FlekTheme.searchPillSize)
                                        .glassEffect(in: .capsule)

                                        // Search button with native glass
                                        Button {
                                            showSearch = true
                                        } label: {
                                            Image(systemName: "magnifyingglass")
                                                .font(.system(size: FlekTheme.searchPillSize * 0.5, weight: .regular))
                                                .foregroundStyle(Color.primary.opacity(0.6))
                                                .frame(width: FlekTheme.searchPillSize, height: FlekTheme.searchPillSize)
                                        }
                                        .buttonStyle(.plain)
                                        .glassEffect(in: .circle)
                                    }
                                }
                                .transition(.scale.combined(with: .opacity))
                            } else {
                                HStack(spacing: 8) {
                                    MultitaskHomeIcons(darkModeIcon: darkModeIcon)

                                    // App switcher button
                                    Button {
                                        MultitaskDockManager.shared.showAppSwitcher()
                                    } label: {
                                        Image(systemName: "square.stack")
                                            .font(.system(size: FlekTheme.searchPillSize * 0.4, weight: .regular))
                                            .foregroundStyle(Color.primary.opacity(0.6))
                                            .frame(width: FlekTheme.searchPillSize * 0.8, height: FlekTheme.searchPillSize * 0.8)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 6)
                                .frame(height: FlekTheme.searchPillSize)
                                .background(
                                    Capsule()
                                        .fill(.ultraThinMaterial)
                                        .overlay(Capsule().fill(Color.white.opacity(0.45)))
                                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
                                )
                                .transition(.scale.combined(with: .opacity))
                            }
                        }

                        // Search button — native glass on iOS 26+, custom on older
                        if #available(iOS 26.0, *) {
                            if !isMultitaskHomeState {
                                // Standalone search with native glass (multitask case is in GlassEffectContainer above)
                                Button {
                                    showSearch = true
                                } label: {
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: FlekTheme.searchPillSize * 0.5, weight: .regular))
                                        .foregroundStyle(Color.primary.opacity(0.6))
                                        .frame(width: FlekTheme.searchPillSize, height: FlekTheme.searchPillSize)
                                }
                                .buttonStyle(.plain)
                                .glassEffect(in: .circle)
                            }
                        } else {
                            FlekGlassCircleButton(systemImage: "magnifyingglass",
                                                  size: FlekTheme.searchPillSize, iconScale: 0.5) {
                                showSearch = true
                            }
                        }
                    }
                    .animation(.easeInOut(duration: 0.25), value: isMultitaskHomeState)
                    .id(colorScheme)
                    .padding(.bottom, 10)
                }
            }
            }


            if showSearch {
                FlekSearchView(
                    isPresented: $showSearch,
                    apps: sortedApps,
                    darkModeIcon: darkModeIcon,
                    onSelect: { app in handleHomeTap(.installed(app)) },
                    onInstallStoreApp: { app in
                        sharedModel.installingName = app.app_name
                        sharedModel.installingIconURL = app.app_icon
                        sharedModel.urlToInstall = app.install_url
                    }
                )
                .transition(.opacity)
            }
        }
        .onAppear {
            if !didAppear { onAppear() }
            if flekstoreSharedModel.appInstallURL != "" {
                Task {
                    await installFromUrl(urlStr: flekstoreSharedModel.appInstallURL)
                    await MainActor.run { flekstoreSharedModel.appInstallURL = "" }
                }
            }
            rebuildOrderedHomeItems()
        }
        .onChange(of: sharedAppSortManager.sortedApps.count) { _ in
            // Skip rebuilds while an install is in progress so the
            // ForEach identity stays stable and context menus don't
            // get cross-contaminated between items.
            guard !installprogressVisible else { return }
            rebuildOrderedHomeItems()
        }
        .onChange(of: installprogressVisible) { _ in
            rebuildOrderedHomeItems()
        }
        .onReceive({
            if #available(iOS 16.0, *) {
                return MultitaskDockManager.shared.$isHomeState.eraseToAnyPublisher()
            } else {
                return Just(false).eraseToAnyPublisher()
            }
        }()) { newValue in
            isMultitaskHomeState = newValue
        }
        .fullScreenCover(isPresented: $showSettingsCover) {
            FlekInternalPage(isPresented: $showSettingsCover) {
                LCSettingsView(appDataFolderNames: $appDataFolderNames, tweakFolderNames: $tweakFolderNames)
            }
        }
        .fullScreenCover(isPresented: $showInstallerCover) {
            FlekInstallerView(preselectFlekstore: installerPreselectFlekstore) {
                showInstallerCover = false
            }
        }
        .sheet(item: $navigationTarget) { target in
            target.view
        }
        .sheet(item: $gameWarningTarget) { target in
            FlekGameWarningView(appName: target.app.appInfo.displayName() ?? "") { parallel, remember in
                if remember {
                    FlekLaunchModeStore.shared.set(parallel ? .parallel : .single, for: target.app)
                    homeRefreshToggle.toggle()
                }
                Task { await launchHomeApp(target.app, parallel: parallel) }
            }
        }
        .onChange(of: installprogressVisible) { visible in
            if !visible {
                sharedModel.installingName = nil
                sharedModel.installingIconURL = nil
                sharedModel.installingURL = nil
                sharedModel.installFraction = 0
                sharedModel.installIndeterminate = true
            }
        }
        .onReceive(downloadHelper.$downloadProgress) { p in
            sharedModel.installFraction = Double(p)
        }
        .onReceive(downloadHelper.$isDownloading) { downloading in
            sharedModel.installIndeterminate = !downloading
        }
        .onChange(of: sharedModel.cancelInstallRequested) { req in
            if req {
                cancelHomeInstall()
                sharedModel.cancelInstallRequested = false
            }
        }
        .fileExporter(
            isPresented: $homeSaveIconExporterShow,
            document: homeSaveIconFile,
            contentType: .image,
            defaultFilename: "Icon.png",
            onCompletion: { _ in })
        .alert("lc.appBanner.confirmUninstallTitle".loc, isPresented: $homeUninstallAlert.show) {
            Button(role: .destructive) { homeUninstallAlert.close(result: true) } label: {
                Text("lc.appBanner.uninstall".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) { homeUninstallAlert.close(result: false) }
        } message: {
            Text("lc.appBanner.confirmUninstallShortMsg".loc)
        }
        .alert("lc.appBanner.deleteDataTitle".loc, isPresented: $homeUninstallFolderAlert.show) {
            Button(role: .destructive) { homeUninstallFolderAlert.close(result: true) } label: {
                Text("lc.common.delete".loc)
            }
            Button("lc.common.no".loc, role: .cancel) { homeUninstallFolderAlert.close(result: false) }
        } message: {
            Text("lc.appBanner.deleteDataShortMsg".loc)
        }
        .task(id: sharedModel.urlToInstall) {
            if let installURL = sharedModel.urlToInstall {
                await installFromUrl(urlStr: installURL)
                sharedModel.urlToInstall = nil
            }
        }
        .alert("lc.common.error".loc, isPresented: $errorShow){
            Button("lc.common.ok".loc, action: {
            })
            Button("lc.common.copy".loc, action: {
                copyError()
            })
        } message: {
            Text(errorInfo)
        }
        .betterFileImporter(isPresented: $choosingIPA, types: [.ipa, .tipa], multiple: false, callback: { fileUrls in
            Task { await startInstallApp(fileUrls[0]) }
        }, onDismiss: {
            choosingIPA = false
        })
        .alert("lc.appList.installation".loc, isPresented: $installReplaceAlert.show) {
            ForEach(installOptions, id: \.self) { installOption in
                Button(role: installOption.isReplace ? .destructive : nil, action: {
                    installReplaceAlert.close(result: installOption)
                }, label: {
                    Text(installOption.isReplace ? installOption.nameOfFolderToInstall : "lc.appList.installAsNew".loc)
                })
                
            }
            Button(role: .cancel, action: {
                installReplaceAlert.close(result: nil)
            }, label: {
                Text("lc.appList.abortInstallation".loc)
            })
        } message: {
            Text("lc.appList.installReplaceTip".loc)
        }
        .alert("lc.webView.runApp".loc, isPresented: $runWhenMultitaskAlert.show) {
            Button(role: .destructive) {
                runWhenMultitaskAlert.close(result: true)
            } label: {
                Text("lc.common.continue".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                runWhenMultitaskAlert.close(result: false)
            }
        } message: {
            Text("lc.appBanner.confirmRunWhenMultitasking".loc)
        }
        .alert("lc.appList.generatedIconStyleSelector.title".loc, isPresented:$generatedIconStyleSelector.show) {
            Button {
                generatedIconStyleSelector.close(result: .Light)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.light".loc)
            }
            Button {
                generatedIconStyleSelector.close(result: .Dark)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.dark".loc)
            }
            Button {
                generatedIconStyleSelector.close(result: .Original)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.original".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                generatedIconStyleSelector.close(result: nil)
            }
        }
        .textFieldAlert(
            isPresented: $webViewUrlInput.show,
            title:  "lc.appList.enterUrlTip".loc,
            text: $webViewUrlInput.initVal,
            placeholder: "scheme://",
            action: { newText in
                webViewUrlInput.close(result: newText)
            },
            actionCancel: {_ in
                webViewUrlInput.close(result: nil)
            }
        )
        .textFieldAlert(
            isPresented: $installUrlInput.show,
            title:  "lc.appList.installUrlInputTip".loc,
            text: $installUrlInput.initVal,
            placeholder: "https://",
            action: { newText in
                installUrlInput.close(result: newText)
            },
            actionCancel: {_ in
                installUrlInput.close(result: nil)
            }
        )
        .textFieldAlert(
            isPresented: $bundleIdInput.show,
            title: "lc.appList.customBundleId".loc,
            text: $bundleIdInput.initVal,
            placeholder: "com.example.app",
            action: { newText in
                bundleIdInput.close(result: newText)
            },
            actionCancel: { _ in
                bundleIdInput.close(result: nil)
            }
        )
        // Download progress is shown on the home app icon (and Installer row),
        // not as a blocking popup.
        .sheet(isPresented: $jitAlert.show, onDismiss: {
            jitAlert.close(result: false)
        }) {
            JITEnablingModal
        }
        .onChange(of: jitAlert.show) { newValue in
            sharedModel.isJITModalOpen = newValue
        }
        .fullScreenCover(isPresented: $webViewOpened) {
            LCWebView(url: $webViewURL, isPresent: $webViewOpened, itmsServicesHandler: { urlStr in
                await installFromPlist(urlStr: urlStr)
            })
        }
        .fullScreenCover(isPresented: $safariViewOpened) {
            SafariView(url: $safariViewURL)
        }
        .sheet(isPresented: $helpPresent) {
            LCHelpView(isPresent: $helpPresent)
        }
        .sheet(isPresented: $customSortViewPresent) {
            LCCustomSortView()
        }
        .onAppear() {
            if !isViewAppeared {
                if let webpageUrlStr = UserDefaults.standard.string(forKey: "webPageToOpen") {
                    Task { await openWebView(urlString: webpageUrlStr) }
                    UserDefaults.standard.set(nil, forKey: "webPageToOpen")
                }
                
                guard sharedModel.selectedTab == .apps, let link = sharedModel.deepLink else { return }
                sharedModel.deepLink = nil
                handleURL(url: link)
                isViewAppeared = true
            }
        }
        .onChange(of: sharedModel.deepLink) { link in
            guard sharedModel.selectedTab == .apps, let link else { return }
            sharedModel.deepLink = nil
            handleURL(url: link)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.InstallAppNotification)) { obj in
            if let obj2 = obj.object as? [String: Any], let installUrl = obj2["url"] as? URL {
                Task { await installFromUrl(urlStr: installUrl.absoluteString) }
            }
        }
    }

    // MARK: - FlekLauncher springboard

    /// Extracted to a separate computed property to help the Swift type-checker
    /// with the complex view body expression.
    @ViewBuilder
    private var homeContentView: some View {
        Group {
            if homeLayout == FlekHomeLayout.list.rawValue {
                FlekHomeListView(
                    items: $orderedHomeItems,
                    darkModeIcon: darkModeIcon,
                    isEditing: $isEditing,
                    isNew: { FlekLaunchTracker.shared.isNew($0) },
                    onTap: { handleHomeTap($0) },
                    onDelete: { item in
                        if case .installed(let app) = item { Task { await requestUninstall(app) } }
                    },
                    onDropCompleted: { persistHomeOrder() },
                    installState: homeInstallState,
                    onCancelInstall: { cancelHomeInstall() },
                    contextMenu: { item in homeContextMenu(for: item) }
                )
            } else {
                LCSpringboardRepresentable(
                    items: $orderedHomeItems,
                    darkModeIcon: darkModeIcon,
                    isEditing: $isEditing,
                    installState: homeInstallState,
                    onTap: { handleHomeTap($0) },
                    onDelete: { item in
                        if case .installed(let app) = item { Task { await requestUninstall(app) } }
                    },
                    onReorder: { persistHomeOrder() },
                    contextMenuProvider: { homeUIMenu(for: $0) },
                    scrollToPage: $homeScrollToPage
                )
            }
        }
    }

    /// Rebuilds `orderedHomeItems` from persisted order + current app list.
    /// Uses the stored home screen order only when the sort type is `.custom`
    /// (i.e. the user has manually dragged cards). For other sort types, the
    /// default-app positions fall back to the front of the list.
    func rebuildOrderedHomeItems() {
        let storedOrder = LCUtils.appGroupUserDefault.stringArray(forKey: FlekLauncherKeys.homeScreenOrder) ?? []
        let useStoredOrder = !storedOrder.isEmpty && sharedAppSortManager.appSortType == .custom

        // Build a lookup of all available items by ID
        var available: [String: FlekHomeItem] = [:]
        for kind in [FlekDefaultAppKind.settings, .installer] {
            let item = FlekHomeItem.defaultApp(kind)
            available[item.id] = item
        }
        for app in sortedApps {
            let item = FlekHomeItem.installed(app)
            available[item.id] = item
        }

        var result: [FlekHomeItem] = []
        var lastNewIdx: Int?
        var didReplaceDeleted = false

        if useStoredOrder {
            // Respect the full user-defined order (default apps + installed apps).
            // "__empty__" markers are restored as placeholder items to preserve
            // the user's custom grid layout (free-placement of icons).
            for (slotIndex, id) in storedOrder.enumerated() {
                if id == "__empty__" {
                    result.append(.placeholder("slot.\(slotIndex)"))
                } else if let item = available.removeValue(forKey: id) {
                    result.append(item)
                } else {
                    // Deleted app – use distinct prefix so per-page
                    // compaction can remove only these gaps.
                    result.append(.placeholder("deleted.\(slotIndex)"))
                    didReplaceDeleted = true
                }
            }
            // Place new items at the first available placeholder slot
            // instead of appending at the end
            let remainingDefaults = available.values.compactMap { item -> FlekHomeItem? in
                if case .defaultApp = item { return item }
                return nil
            }
            let remainingInstalled = available.values.compactMap { item -> FlekHomeItem? in
                if case .installed = item { return item }
                return nil
            }
            for newItem in remainingDefaults + remainingInstalled {
                if let placeholderIdx = result.firstIndex(where: { $0.isPlaceholder }) {
                    result[placeholderIdx] = newItem
                    lastNewIdx = placeholderIdx
                } else {
                    lastNewIdx = result.count
                    result.append(newItem)
                }
            }
        } else {
            // Default layout: settings + installer at the front, then sorted apps
            result = [.defaultApp(.settings), .defaultApp(.installer)]
            result.append(contentsOf: sortedApps.map { .installed($0) })
        }

        // Compact deleted-app placeholders within each page so the
        // remaining apps on that page close the gap, without pulling
        // items from other pages.
        // Skip during edit mode – editPages is the source of truth there.
        if didReplaceDeleted && !isEditing {
            let isDeletedPlaceholder: (FlekHomeItem) -> Bool = { item in
                if case .placeholder(let id) = item { return id.hasPrefix("deleted.") }
                return false
            }

            var sizes = LCUtils.appGroupUserDefault.array(forKey: FlekLauncherKeys.homeScreenPageSizes) as? [Int] ?? []
            if !sizes.isEmpty {
                // Remove deleted placeholders page-by-page
                var offset = 0
                for pageIdx in 0..<sizes.count {
                    let pageStart = offset
                    let pageEnd = min(pageStart + sizes[pageIdx], result.count)
                    var i = pageStart
                    var removed = 0
                    while i < pageEnd - removed {
                        if isDeletedPlaceholder(result[i]) {
                            result.remove(at: i)
                            removed += 1
                        } else {
                            i += 1
                        }
                    }
                    sizes[pageIdx] -= removed
                    offset = pageStart + sizes[pageIdx]
                }
                // Safety: remove any deleted placeholders beyond stored pages
                result.removeAll(where: isDeletedPlaceholder)
                // Trim trailing pages that are now all-placeholder or empty
                while sizes.count > 1 {
                    let lastPageStart = sizes.dropLast().reduce(0, +)
                    let lastPageEnd = min(lastPageStart + (sizes.last ?? 0), result.count)
                    guard lastPageStart < result.count else {
                        sizes.removeLast()
                        continue
                    }
                    let lastPage = result[lastPageStart..<lastPageEnd]
                    if lastPage.isEmpty || !lastPage.contains(where: { !$0.isPlaceholder }) {
                        result.removeSubrange(lastPageStart..<lastPageEnd)
                        sizes.removeLast()
                    } else {
                        break
                    }
                }
                LCUtils.appGroupUserDefault.set(sizes, forKey: FlekLauncherKeys.homeScreenPageSizes)
            } else {
                // No page sizes stored — just remove deleted placeholders
                result.removeAll(where: isDeletedPlaceholder)
            }
        }

        // Place the installing indicator at the first placeholder slot
        var scrollIdx: Int?
        if installprogressVisible {
            if let placeholderIdx = result.firstIndex(where: { $0.isPlaceholder }) {
                result[placeholderIdx] = .installing
                scrollIdx = placeholderIdx
            } else {
                scrollIdx = result.count
                result.append(.installing)
            }
        }

        orderedHomeItems = result

        // Persist immediately when the grid changed (new items placed at
        // placeholder slots, or deleted apps replaced with placeholders) so
        // subsequent rebuilds produce a stable layout.
        if lastNewIdx != nil || didReplaceDeleted {
            persistHomeOrder()
        }

        // Auto-scroll to the page containing the installing/new app
        if let idx = scrollIdx ?? lastNewIdx {
            homeScrollToPage = pageForIndex(idx)
        }
    }

    /// Persists the current home screen order after a drag-and-drop reorder.
    /// Placeholders are saved as `"__empty__"` markers to preserve grid positions.
    func persistHomeOrder() {
        let ids = orderedHomeItems.compactMap { item -> String? in
            // Save the installing card's slot as __empty__ so the new app
            // takes the exact same position once install finishes
            if case .installing = item { return "__empty__" }
            if item.isPlaceholder { return "__empty__" }
            return item.id
        }
        LCUtils.appGroupUserDefault.set(ids, forKey: FlekLauncherKeys.homeScreenOrder)
        // Also update the app sort manager for installed app order
        let appIds = orderedHomeItems.compactMap { item -> String? in
            guard case .installed(let app) = item else { return nil }
            return sharedAppSortManager.getUniqueIdentifier(for: app)
        }
        if sharedAppSortManager.appSortType != .custom {
            sharedAppSortManager.appSortType = .custom
        }
        sharedAppSortManager.customSortOrder = appIds
    }

    /// Returns the page index for a given flat-array position using
    /// the persisted page sizes (or uniform chunking as fallback).
    ///
    /// When the index is beyond the stored page sizes the last page is
    /// filled up to `itemsPerPage` before a new page is assumed —
    /// matching `LCSpringboardViewController.paginateFromFlatItems()`.
    private func pageForIndex(_ index: Int) -> Int {
        // Estimate itemsPerPage from screen geometry
        // (mirrors LCSpringboardViewController.recalculateItemsPerPage)
        let screenBounds = UIScreen.main.bounds
        let cellSize = LCSpringboardPageCell.computeCellWidth(forWidth: screenBounds.width)
        let pageControlHeight: CGFloat = 30
        let topInset: CGFloat = 12
        let bottomInset: CGFloat = 12
        let lineSpacing: CGFloat = 8
        let pageHeight = screenBounds.height - pageControlHeight
        let availableHeight = pageHeight - topInset - bottomInset
        let rows = max(1, Int((availableHeight + lineSpacing) / (cellSize + lineSpacing)))
        let ipp = max(1, rows * LCSpringboardPageCell.columns)

        let sizes = LCUtils.appGroupUserDefault.array(forKey: FlekLauncherKeys.homeScreenPageSizes) as? [Int] ?? []
        if !sizes.isEmpty {
            var offset = 0
            for (page, size) in sizes.enumerated() {
                offset += size
                if index < offset { return page }
            }
            // Beyond stored sizes: the last page can still hold items
            // up to itemsPerPage (mirroring paginateFromFlatItems).
            let lastPageSize = sizes.last ?? 0
            let room = max(0, ipp - lastPageSize)
            let beyondStored = index - offset
            if beyondStored < room {
                return sizes.count - 1
            }
            let beyondLastPage = beyondStored - room
            return sizes.count + beyondLastPage / ipp
        }

        return index / ipp
    }

    /// Scrolls the springboard to the page containing the given item.
    private func scrollToItem(_ item: FlekHomeItem) {
        guard let idx = orderedHomeItems.firstIndex(where: { $0.id == item.id }) else { return }
        let page = pageForIndex(idx)
        homeScrollToPage = page
    }

    var homeInstallState: FlekInstallState {
        // Unified progress bar: download fills 0%→80%, install fills 80%→100%.
        // For local-file installs (no download) the install phase uses the
        // full 0%→100% range instead.
        let downloading = downloadHelper.isDownloading
        let dlProgress = Double(downloadHelper.downloadProgress)
        let installProgress = Double(installProgressPercentage)

        let fraction: Double
        let indeterminate: Bool

        if downloading {
            // Download phase: 0% → 80%
            fraction = 0.8 * dlProgress
            indeterminate = false
        } else if installprogressVisible {
            if dlProgress > 0.01 {
                // URL install — download finished, install in progress: 80% → 100%
                fraction = 0.8 + 0.2 * installProgress
                indeterminate = false
            } else if installProgress > 0 {
                // Local-file install (no download): 0% → 100%
                fraction = installProgress
                indeterminate = false
            } else {
                // Very start before any progress ticks
                indeterminate = true
                fraction = 0
            }
        } else {
            indeterminate = true
            fraction = 0
        }

        return FlekInstallState(
            name: sharedModel.installingName,
            iconURL: sharedModel.installingIconURL,
            fraction: fraction,
            indeterminate: indeterminate
        )
    }

    func cancelHomeInstall() {
        downloadHelper.cancel()
        installprogressVisible = false
        sharedModel.installingName = nil
        sharedModel.installingIconURL = nil
    }

    func handleHomeTap(_ item: FlekHomeItem) {
        switch item {
        case .defaultApp(let kind):
            let isMultitaskAvailable: Bool = {
                guard #available(iOS 16.0, *) else { return false }
                let mode = MultitaskMode(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCMultitaskMode")) ?? .virtualWindow
                return mode == .virtualWindow && sharedModel.multiLCStatus != 2
            }()
            if #available(iOS 16.0, *), isMultitaskAvailable {
                openInternalPageForKind(kind)
            } else {
                switch kind {
                case .settings:
                    showSettingsCover = true
                case .installer:
                    installerPreselectFlekstore = false
                    showInstallerCover = true
                case .flekstore:
                    installerPreselectFlekstore = true
                    showInstallerCover = true
                }
            }
        case .installed(let app):
            FlekLaunchTracker.shared.markLaunched(app)
            let mode = FlekLaunchModeStore.shared.mode(for: app)
            if mode == nil, isGame(app) {
                gameWarningTarget = FlekGameWarningTarget(app: app)
            } else {
                let parallel = mode != nil ? (mode == .parallel) : app.shouldLaunchInMultitaskMode
                Task { await launchHomeApp(app, parallel: parallel) }
            }
        case .installing, .placeholder:
            break
        }
    }

    @available(iOS 16.0, *)
    private func openInternalPageForKind(_ kind: FlekDefaultAppKind) {
        let dockManager = MultitaskDockManager.shared
        
        switch kind {
        case .settings:
            dockManager.openInternalPage(kind: "settings", uuid: "internal-settings", name: "lc.tabView.settings".loc) {
                StandaloneSettingsView()
                    .environmentObject(sharedModel)
                    .environmentObject(sceneDelegate)
            }
        case .installer:
            dockManager.openInternalPage(kind: "installer", uuid: "internal-installer", name: "Installer") {
                FlekInstallerView(preselectFlekstore: false) {
                    dockManager.closeApp(uuid: "internal-installer")
                }
                .environmentObject(sharedModel)
                .environmentObject(sceneDelegate)
            }
        case .flekstore:
            // FlekStore reuses the installer UUID — if already open, bring to front
            if dockManager.apps.contains(where: { $0.appUUID == "internal-installer" }) {
                let _ = dockManager.bringMultitaskViewToFront(uuid: "internal-installer")
            } else {
                dockManager.openInternalPage(kind: "flekstore", uuid: "internal-installer", name: "FlekSt0re") {
                    FlekInstallerView(preselectFlekstore: true) {
                        dockManager.closeApp(uuid: "internal-installer")
                    }
                    .environmentObject(sharedModel)
                    .environmentObject(sceneDelegate)
                }
            }
        }
    }

    // moveHomeItem is no longer needed — Dragula handles reordering
    // directly via the bound items array, and persistHomeOrder() saves
    // the result on drop completion.

    func isGame(_ app: LCAppModel) -> Bool {
        if let info = app.appInfo.info(), let cat = info["LSApplicationCategoryType"] as? String {
            return cat.localizedCaseInsensitiveContains("game")
        }
        return false
    }

    func launchHomeApp(_ app: LCAppModel, parallel: Bool) async {
        if app.appInfo.isLocked && !sharedModel.isHiddenAppUnlocked {
            do {
                if !(try await LCUtils.authenticateUser()) { return }
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
                return
            }
        }
        do {
            if #available(iOS 16.0, *), sharedModel.multiLCStatus != 2, parallel {
                try await app.runApp(multitask: true)
            } else {
                try await app.runApp(multitask: false)
            }
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }

    // MARK: - Home context menu

    @ViewBuilder
    // MARK: - UIKit Context Menu (for UIKit springboard)

    func homeUIMenu(for item: FlekHomeItem) -> UIMenu? {
        switch item {
        case .defaultApp(let kind):
            guard kind != .settings && kind != .installer else { return nil }
            let moveCards = UIAction(
                title: "lc.appBanner.moveCards".loc,
                image: UIImage(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            ) { [self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    isEditing = true
                }
            }
            return UIMenu(title: "", children: [moveCards])
        case .installed(let app):
            return installedUIMenu(app)
        case .installing:
            let cancel = UIAction(
                title: "lc.flek.cancelInstall".loc,
                image: UIImage(systemName: "xmark.circle"),
                attributes: .destructive
            ) { [self] _ in
                cancelHomeInstall()
            }
            return UIMenu(title: "", children: [cancel])
        case .placeholder:
            return nil
        }
    }

    private func installedUIMenu(_ app: LCAppModel) -> UIMenu {
        let runSingle = UIAction(
            title: "lc.appBanner.runSingle".loc,
            image: UIImage(systemName: "macwindow")
        ) { [self] _ in
            FlekLaunchModeStore.shared.set(.single, for: app)
            homeRefreshToggle.toggle()
            FlekLaunchTracker.shared.markLaunched(app)
            Task { await launchHomeApp(app, parallel: false) }
        }
        let runParallel = UIAction(
            title: "lc.appBanner.runParallel".loc,
            image: UIImage(systemName: "macwindow.on.rectangle")
        ) { [self] _ in
            FlekLaunchModeStore.shared.set(.parallel, for: app)
            homeRefreshToggle.toggle()
            FlekLaunchTracker.shared.markLaunched(app)
            Task { await launchHomeApp(app, parallel: true) }
        }
        var launchGroup = UIMenu(title: "", options: .displayInline, children: [runSingle, runParallel])
        if #available(iOS 16.0, *) {
            launchGroup.preferredElementSize = .medium
        }

        let copyUrl = UIAction(
            title: "lc.appBanner.copyLaunchUrl".loc,
            image: UIImage(systemName: "link")
        ) { [self] _ in
            homeCopyLaunchUrl(app)
        }
        let saveIcon = UIAction(
            title: "lc.appBanner.saveAppIcon".loc,
            image: UIImage(systemName: "square.and.arrow.down")
        ) { [self] _ in
            Task { await homeSaveIcon(app) }
        }
        let createClip = UIAction(
            title: "lc.appBanner.createAppClip".loc,
            image: UIImage(systemName: "appclip")
        ) { [self] _ in
            Task { await homeCreateAppClip(app) }
        }
        let addToHomeScreen = UIMenu(
            title: "lc.appBanner.addToHomeScreen".loc,
            image: UIImage(systemName: "plus.app"),
            children: [copyUrl, saveIcon, createClip]
        )

        let settings = UIAction(
            title: "lc.tabView.settings".loc,
            image: UIImage(systemName: "gear")
        ) { [self] _ in
            openNavigationView(view: AnyView(LCAppSettingsView(model: app, appDataFolders: $appDataFolderNames, tweakFolders: $tweakFolderNames)))
        }

        let moveCards = UIAction(
            title: "lc.appBanner.moveCards".loc,
            image: UIImage(systemName: "arrow.up.and.down.and.arrow.left.and.right")
        ) { [self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                isEditing = true
            }
        }

        var children: [UIMenuElement] = [launchGroup, addToHomeScreen, settings, moveCards]

        if !app.uiIsShared {
            let uninstall = UIAction(
                title: "lc.appBanner.uninstall".loc,
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [self] _ in
                Task { await requestUninstall(app) }
            }
            children.append(uninstall)
        }

        return UIMenu(title: "", children: children)
    }

    @ViewBuilder
    func homeContextMenu(for item: FlekHomeItem) -> some View {
        switch item {
        case .defaultApp:
            // Built-in apps: only the "arrange" action is offered (they can be
            // moved but not removed, have no launch mode / settings / uninstall).
            Button {
                // Delay so the context menu dismissal animation finishes
                // before the view switches to edit mode.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    isEditing = true
                }
            } label: {
                Label("lc.appBanner.moveCards".loc, systemImage: "arrow.up.and.down.and.arrow.left.and.right")
            }
        case .installed(let app):
            installedContextMenu(app)
        case .installing, .placeholder:
            EmptyView()
        }
    }

    @ViewBuilder
    private func installedContextMenu(_ app: LCAppModel) -> some View {
        if #available(iOS 16.0, *) {
            ControlGroup {
                Button {
                    FlekLaunchModeStore.shared.set(.single, for: app)
                    homeRefreshToggle.toggle()
                    FlekLaunchTracker.shared.markLaunched(app)
                    Task { await launchHomeApp(app, parallel: false) }
                } label: {
                    Label("lc.appBanner.runSingle".loc, systemImage: "macwindow")
                }
                Button {
                    FlekLaunchModeStore.shared.set(.parallel, for: app)
                    homeRefreshToggle.toggle()
                    FlekLaunchTracker.shared.markLaunched(app)
                    Task { await launchHomeApp(app, parallel: true) }
                } label: {
                    Label("lc.appBanner.runParallel".loc, systemImage: "macwindow.on.rectangle")
                }
            }
        } else {
            Button {
                FlekLaunchModeStore.shared.set(.single, for: app)
                homeRefreshToggle.toggle()
                FlekLaunchTracker.shared.markLaunched(app)
                Task { await launchHomeApp(app, parallel: false) }
            } label: {
                Label("lc.appBanner.runSingle".loc, systemImage: "macwindow")
            }
        }

        Divider()

        Menu {
            Button {
                homeCopyLaunchUrl(app)
            } label: {
                Label("lc.appBanner.copyLaunchUrl".loc, systemImage: "link")
            }
            Button {
                Task { await homeSaveIcon(app) }
            } label: {
                Label("lc.appBanner.saveAppIcon".loc, systemImage: "square.and.arrow.down")
            }
            Button {
                Task { await homeCreateAppClip(app) }
            } label: {
                Label("lc.appBanner.createAppClip".loc, systemImage: "appclip")
            }
        } label: {
            Label("lc.appBanner.addToHomeScreen".loc, systemImage: "plus.app")
        }

        Button {
            // Delay so the context menu dismissal animation finishes
            // before the view switches to edit mode.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                isEditing = true
            }
        } label: {
            Label("lc.appBanner.moveCards".loc, systemImage: "arrow.up.and.down.and.arrow.left.and.right")
        }

        Button {
            openNavigationView(view: AnyView(LCAppSettingsView(model: app, appDataFolders: $appDataFolderNames, tweakFolders: $tweakFolderNames)))
        } label: {
            Label("lc.tabView.settings".loc, systemImage: "gear")
        }

        if !app.uiIsShared {
            Button(role: .destructive) {
                Task { await requestUninstall(app) }
            } label: {
                Label("lc.appBanner.uninstall".loc, systemImage: "trash")
            }
        }
    }

    func homeCopyLaunchUrl(_ app: LCAppModel) {
        guard let path = app.appInfo.relativeBundlePath else { return }
        if let fn = app.uiSelectedContainer?.folderName {
            UIPasteboard.general.string = "livecontainer://livecontainer-launch?bundle-name=\(path)&container-folder-name=\(fn)"
        } else {
            UIPasteboard.general.string = "livecontainer://livecontainer-launch?bundle-name=\(path)"
        }
    }

    func homeSaveIcon(_ app: LCAppModel) async {
        guard let style = await promptForGeneratedIconStyle() else { return }
        guard let img = app.appInfo.generateLiveContainerWrappedIcon(with: style) else { return }
        homeSaveIconFile = ImageDocument(uiImage: img)
        homeSaveIconExporterShow = true
    }

    func homeCreateAppClip(_ app: LCAppModel) async {
        guard let style = await promptForGeneratedIconStyle() else { return }
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: app.appInfo.generateWebClipConfig(withContainerId: app.uiSelectedContainer?.folderName, iconStyle: style)!,
                format: .xml, options: 0)
            installMdm(data: data)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }

    func requestUninstall(_ app: LCAppModel) async {
        do {
            if let r = await homeUninstallAlert.open(), !r { return }

            var doRemoveFolder = false
            let containers = app.appInfo.containers
            if !containers.isEmpty {
                if let r = await homeUninstallFolderAlert.open() { doRemoveFolder = r }
            }

            let fm = FileManager()
            try fm.removeItem(atPath: app.appInfo.bundlePath()!)
            removeApp(app: app)
            if doRemoveFolder {
                for container in containers {
                    let dataUUID = container.folderName
                    let dataFolderPath = LCPath.dataPath.appendingPathComponent(dataUUID)
                    try? fm.removeItem(at: dataFolderPath)
                    LCUtils.removeAppKeychain(dataUUID: dataUUID)
                    DispatchQueue.main.async {
                        self.appDataFolderNames.removeAll { $0 == dataUUID }
                    }
                }
            }
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }

    var JITEnablingModal : some View {
        NavigationView {
            ScrollViewReader { proxy in
                ScrollView {
                    Text("lc.appBanner.waitForJitMsg".loc)
                        .padding(.vertical)
                        .id(0)
                    
                    HStack {
                        Text(jitLog)
                            .font(.system(size: 12).monospaced())
                            .fixedSize(horizontal: false, vertical: false)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .onAppear {
                    proxy.scrollTo(0)
                }
            }
            .navigationTitle("lc.appBanner.waitForJitTitle".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("lc.common.cancel".loc, role: .cancel) {
                        jitAlert.close(result: false)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        jitAlert.close(result: true)
                    } label: {
                        Text("lc.appBanner.jitLaunchNow".loc)
                    }
                }
            }
        }
    }
    
    func onOpenWebViewTapped() async {
        guard let urlToOpen = await webViewUrlInput.open(), urlToOpen != "" else {
            return
        }
        await openWebView(urlString: urlToOpen)
        
    }
    func onAppear() {
        for app in sharedModel.apps {
            app.delegate = self
        }
        for app in sharedModel.hiddenApps {
            app.delegate = self
        }
        didAppear = true
    }
    
    
    func openWebView(urlString: String) async {
        guard var urlToOpen = URLComponents(string: urlString), urlToOpen.url != nil else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        if urlToOpen.scheme == nil || urlToOpen.scheme! == "" {
            urlToOpen.scheme = "https"
        }
        
        if urlToOpen.scheme?.lowercased() == "itms-services" {
            await installFromPlist(urlStr: urlString)
            return
        }
        
        if urlToOpen.scheme != "https" && urlToOpen.scheme != "http" {
            var appToLaunch : LCAppModel? = nil
            var appListsToConsider = [sharedModel.apps]
            if sharedModel.isHiddenAppUnlocked || !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
                appListsToConsider.append(sharedModel.hiddenApps)
            }
        appLoop:
            for appList in appListsToConsider {
                for app in appList {
                    if let schemes = app.appInfo.urlSchemes() {
                        for scheme in schemes {
                            if let scheme = scheme as? String, scheme == urlToOpen.scheme {
                                appToLaunch = app
                                break appLoop
                            }
                        }
                    }
                }
            }
            
            
            guard let appToLaunch = appToLaunch else {
                errorInfo = "lc.appList.schemeCannotOpenError %@".localizeWithFormat(urlToOpen.scheme!)
                errorShow = true
                return
            }
            
            if appToLaunch.appInfo.isLocked && !sharedModel.isHiddenAppUnlocked {
                do {
                    if !(try await LCUtils.authenticateUser()) {
                        return
                    }
                } catch {
                    errorInfo = error.localizedDescription
                    errorShow = true
                    return
                }
            }
            
            do {
                try await appToLaunch.runApp(urlStr: urlToOpen.url!.absoluteString)
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            
            return
        }
        webViewURL = urlToOpen.url!
        if webViewOpened {
            webViewOpened = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: {
                webViewOpened = true
            })
        } else {
            webViewOpened = true
        }
    }
    
    
    
    func startInstallApp(_ fileUrl:URL) async {
        do {
            self.installprogressVisible = true
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            try await installIpaFile(fileUrl)
            try FileManager.default.removeItem(at: fileUrl)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            self.installprogressVisible = false
        }
    }
    
    nonisolated func decompress(_ path: String, _ destination: String ,_ progress: Progress) async -> Int32 {
        extract(path, destination, progress)
    }
    
    func installIpaFile(_ url:URL) async throws {
        let fm = FileManager()
        
        let installProgress = Progress.discreteProgress(totalUnitCount: 100)
        self.installProgressPercentage = 0.0
        self.installObserver = installProgress.observe(\.fractionCompleted) { p, v in
            DispatchQueue.main.async {
                self.installProgressPercentage = Float(p.fractionCompleted)
            }
        }
        let decompressProgress = Progress.discreteProgress(totalUnitCount: 100)
        installProgress.addChild(decompressProgress, withPendingUnitCount: 80)
        let payloadPath = fm.temporaryDirectory.appendingPathComponent("Payload")
        if fm.fileExists(atPath: payloadPath.path) {
            try fm.removeItem(at: payloadPath)
        }
        
        // decompress
        guard await decompress(url.path, fm.temporaryDirectory.path, decompressProgress) == 0 else {
            throw "lc.appList.urlFileIsNotIpaError".loc
        }

        let payloadContents = try fm.contentsOfDirectory(atPath: payloadPath.path)
        var appBundleName : String? = nil
        for fileName in payloadContents {
            if fileName.hasSuffix(".app") {
                appBundleName = fileName
                break
            }
        }
        guard let appBundleName = appBundleName else {
            throw "lc.appList.bundleNotFondError".loc
        }
        
        let appFolderPath = payloadPath.appendingPathComponent(appBundleName)
        
        guard let newAppInfo = LCAppInfo(bundlePath: appFolderPath.path) else {
            throw "lc.appList.infoPlistCannotReadError".loc
        }

        // Show bundle ID customization if enabled in settings
        if LCUtils.appGroupUserDefault.bool(forKey: "LCCustomBundleIdEnabled") {
            guard let chosenBundleId = await bundleIdInput.open(
                initVal: newAppInfo.bundleIdentifier()!
            ) else {
                // User cancelled
                self.installprogressVisible = false
                try fm.removeItem(at: payloadPath)
                return
            }
            let trimmed = chosenBundleId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed != newAppInfo.bundleIdentifier()! {
                newAppInfo.overrideBundleIdentifier(trimmed)
            }
        }

        var appRelativePath = "\(newAppInfo.bundleIdentifier()!.sanitizeNonACSII()).app"
        var outputFolder = LCPath.bundlePath.appendingPathComponent(appRelativePath)
        var appToReplace : LCAppModel? = nil
        // Folder exist! show alert for user to choose which bundle to replace
        var sameBundleIdApp = sharedModel.apps.filter { app in
            return app.appInfo.bundleIdentifier()! == newAppInfo.bundleIdentifier()
        }
        if sameBundleIdApp.count == 0 {
            sameBundleIdApp = sharedModel.hiddenApps.filter { app in
                return app.appInfo.bundleIdentifier()! == newAppInfo.bundleIdentifier()
            }
            
            // we found a hidden app, we need to authenticate before proceeding
            if sameBundleIdApp.count > 0 && !sharedModel.isHiddenAppUnlocked {
                do {
                    if !(try await LCUtils.authenticateUser()) {
                        self.installprogressVisible = false
                        return
                    }
                } catch {
                    errorInfo = error.localizedDescription
                    errorShow = true
                    self.installprogressVisible = false
                    return
                }
            }
            
        }
        
        if fm.fileExists(atPath: outputFolder.path) || sameBundleIdApp.count > 0 {
            appRelativePath = "\(newAppInfo.bundleIdentifier()!)_\(Int(CFAbsoluteTimeGetCurrent())).app"
            
            self.installOptions = [AppReplaceOption(isReplace: false, nameOfFolderToInstall: appRelativePath)]
            
            for app in sameBundleIdApp {
                self.installOptions.append(AppReplaceOption(isReplace: true, nameOfFolderToInstall: app.appInfo.relativeBundlePath, appToReplace: app))
            }
            
            guard let installOptionChosen = await installReplaceAlert.open() else {
                // user cancelled
                self.installprogressVisible = false
                try fm.removeItem(at: payloadPath)
                return
            }
            
            if let appToReplace = installOptionChosen.appToReplace, appToReplace.uiIsShared {
                outputFolder = LCPath.lcGroupBundlePath.appendingPathComponent(installOptionChosen.nameOfFolderToInstall)
            } else {
                outputFolder = LCPath.bundlePath.appendingPathComponent(installOptionChosen.nameOfFolderToInstall)
            }
            appRelativePath = installOptionChosen.nameOfFolderToInstall
            appToReplace = installOptionChosen.appToReplace
            if installOptionChosen.isReplace {
                try fm.removeItem(at: outputFolder)
            }
        }
        // Move it!
        try fm.moveItem(at: appFolderPath, to: outputFolder)
        let finalNewApp = LCAppInfo(bundlePath: outputFolder.path)
        finalNewApp?.relativeBundlePath = appRelativePath
        
        guard let finalNewApp else {
            errorInfo = "lc.appList.appInfoInitError".loc
            errorShow = true
            return
        }
        
        // patch and sign it
        var signError : String? = nil
        var signSuccess = false
        await withUnsafeContinuation({ c in
            if appToReplace?.uiDontSign ?? false || LCUtils.appGroupUserDefault.bool(forKey: "LCDontSignApp") {
                finalNewApp.dontSign = true
            }
            finalNewApp.patchExecAndSignIfNeed(completionHandler: { success, error in
                signError = error
                signSuccess = success
                c.resume()
            }, progressHandler: { signProgress in
                installProgress.addChild(signProgress!, withPendingUnitCount: 20)
            }, forceSign: false)
        })
        
        // we leave it unsigned even if signing failed
        if let signError {
            if signSuccess {
                errorInfo = "\("lc.appList.signSuccessWithError".loc)\n\n\(signError)"
            } else {
                errorInfo = signError.loc
            }
            errorShow = true
        }
        
        if let appToReplace {
            // copy previous configration to new app
            finalNewApp.autoSaveDisabled = true
            finalNewApp.isLocked = appToReplace.appInfo.isLocked
            finalNewApp.isHidden = appToReplace.appInfo.isHidden
            finalNewApp.isJITNeeded = appToReplace.appInfo.isJITNeeded
            finalNewApp.isShared = appToReplace.appInfo.isShared
            finalNewApp.spoofSDKVersion = appToReplace.appInfo.spoofSDKVersion
            finalNewApp.doSymlinkInbox = appToReplace.appInfo.doSymlinkInbox
            finalNewApp.containerInfo = appToReplace.appInfo.containerInfo
            finalNewApp.tweakFolder = appToReplace.appInfo.tweakFolder
            finalNewApp.selectedLanguage = appToReplace.appInfo.selectedLanguage
            finalNewApp.dataUUID = appToReplace.appInfo.dataUUID
            finalNewApp.orientationLock = appToReplace.appInfo.orientationLock
            finalNewApp.dontInjectTweakLoader = appToReplace.appInfo.dontInjectTweakLoader
            finalNewApp.hideLiveContainer = appToReplace.appInfo.hideLiveContainer
            finalNewApp.dontLoadTweakLoader = appToReplace.appInfo.dontLoadTweakLoader
            finalNewApp.doUseLCBundleId = appToReplace.appInfo.doUseLCBundleId
            finalNewApp.fixFilePickerNew = appToReplace.appInfo.fixFilePickerNew
            finalNewApp.fixLocalNotification = appToReplace.appInfo.fixLocalNotification
            finalNewApp.lastLaunched = appToReplace.appInfo.lastLaunched
            finalNewApp.jitLaunchScriptJs = appToReplace.appInfo.jitLaunchScriptJs
            finalNewApp.multitaskSpecified = appToReplace.appInfo.multitaskSpecified
            finalNewApp.autoSaveDisabled = false
            finalNewApp.save()
        } else {
            // enable SDK version spoof by defalut
            finalNewApp.spoofSDKVersion = true
        }
        finalNewApp.installationDate = Date.now
        
        await MainActor.run {
            // Mark this URL as successfully installed so the installer row
            // can show a checkmark animation before reverting to the download button.
            sharedModel.lastCompletedInstallURL = sharedModel.installingURL

            // Remove the installing card before adding the new app so that
            // homeItems never contains both .installing and the new .installed
            // item at the same time (which caused an empty grid slot).
            // Using MainActor.run (not DispatchQueue.main.async) so this
            // completes before installIpaFile returns – otherwise callers
            // with a defer that clears installprogressVisible would remove
            // the installing card one frame before the new app appears.
            self.installprogressVisible = false

            if let appToReplace {
                let newAppModel = LCAppModel(appInfo: finalNewApp, delegate: self)
                
                if appToReplace.uiIsHidden {
                    sharedModel.hiddenApps.removeAll { $0 == appToReplace }
                    sharedModel.hiddenApps.append(newAppModel)
                } else {
                    sharedModel.apps.removeAll { $0 == appToReplace }
                    sharedModel.apps.append(newAppModel)
                }
                
            } else {
                let newAppModel = LCAppModel(appInfo: finalNewApp, delegate: self)
                sharedModel.apps.append(newAppModel)
                
                // add url schemes
                if let urlSchemes = finalNewApp.urlSchemes(), urlSchemes.count > 0 {
                    UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                        .addObjects(from: urlSchemes as! [Any])
                }
            }
            
            // Explicitly rebuild home items so the new app icon appears
            // immediately (onChange handlers may miss it due to batching).
            rebuildOrderedHomeItems()
        }
    }
    
    func startInstallFromUrl() async {
        guard let installUrlStr = await installUrlInput.open(), installUrlStr.count > 0 else {
            return
        }
        if let url = URL(string:installUrlStr), url.scheme?.lowercased() == "itms-services" {
            await installFromPlist(urlStr: installUrlStr)
            return
        }
        await installFromUrl(urlStr: installUrlStr)
    }
    
    func installFromPlist(urlStr: String) async {
        if self.installprogressVisible {
            return
        }
        
        if sharedModel.multiLCStatus == 2 {
            errorInfo = "lc.appList.manageInPrimaryTip".loc
            errorShow = true
            return
        }
        
        var plistUrlStr = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if plistUrlStr.lowercased().hasPrefix("itms-services://") {
            if let urlComponents = URLComponents(string: plistUrlStr),
               let queryItems = urlComponents.queryItems,
               let urlParam = queryItems.first(where: { $0.name == "url" })?.value {
                plistUrlStr = urlParam
            } else {
                errorInfo = "lc.appList.plistInvalidError".loc
                errorShow = true
                return
            }
        }
        
        guard let plistUrl = URL(string: plistUrlStr) else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: plistUrl)
            
            guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let items = plist["items"] as? [[String: Any]],
                  let firstItem = items.first,
                  let assets = firstItem["assets"] as? [[String: Any]] else {
                errorInfo = "lc.appList.plistParseError".loc
                errorShow = true
                return
            }
            
            var ipaUrlStr: String?
            for asset in assets {
                if let kind = asset["kind"] as? String, kind == "software-package",
                   let url = asset["url"] as? String {
                    ipaUrlStr = url
                    break
                }
            }
            
            guard let ipaUrlStr else {
                errorInfo = "lc.appList.plistNoIpaError".loc
                errorShow = true
                return
            }
            
            await installFromUrl(urlStr: ipaUrlStr)
            
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }
    
    func installFromUrl(urlStr: String) async {
        // ignore any install request if we are installing another app
        if self.installprogressVisible {
            return
        }
        
        if sharedModel.multiLCStatus == 2 {
            errorInfo = "lc.appList.manageInPrimaryTip".loc
            errorShow = true
            return
        }
        
        guard let installUrl = URL(string: urlStr) else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        
        self.installprogressVisible = true
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            self.installprogressVisible = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
        
        if installUrl.isFileURL {
            // install from local, we directly call local install method
            if !installUrl.lastPathComponent.hasSuffix(".ipa") && !installUrl.lastPathComponent.hasSuffix(".tipa") {
                errorInfo = "lc.appList.urlFileIsNotIpaError".loc
                errorShow = true
                return
            }
            
            let fm = FileManager.default
            if !fm.isReadableFile(atPath: installUrl.path) && !installUrl.startAccessingSecurityScopedResource() {
                errorInfo = "lc.appList.ipaAccessError".loc
                errorShow = true
                return
            }
            
            defer {
                installUrl.stopAccessingSecurityScopedResource()
            }
            
            do {
                try await installIpaFile(installUrl)
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            
            do {
                // delete ipa if it's in inbox
                var shouldDelete = false
                if let documentsDirectory = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
                    let inboxURL = documentsDirectory.appendingPathComponent("Inbox")
                    let fileURL = inboxURL.appendingPathComponent(installUrl.lastPathComponent)
                    
                    shouldDelete = fm.fileExists(atPath: fileURL.path)
                }
                if shouldDelete {
                    try fm.removeItem(at: installUrl)
                }
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            return
        }
        
        do {
            let fileManager = FileManager.default
            let destinationURL = fileManager.temporaryDirectory.appendingPathComponent(installUrl.lastPathComponent)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            
            try await downloadHelper.download(url: installUrl, to: destinationURL)
            if downloadHelper.cancelled {
                return
            }
            try await installIpaFile(destinationURL)
            try fileManager.removeItem(at: destinationURL)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
        
    }
    
    func removeApp(app: LCAppModel) {
        DispatchQueue.main.async {
            sharedModel.apps.removeAll { now in
                return app == now
            }
            sharedModel.hiddenApps.removeAll { now in
                return app == now
            }
            
        }
    }
    
    func changeAppVisibility(app: LCAppModel) {
        DispatchQueue.main.async {
            if app.appInfo.isHidden {
                sharedModel.apps.removeAll { now in
                    return app == now
                }
                if !sharedModel.hiddenApps.contains(app) {
                    sharedModel.hiddenApps.append(app)
                }
                UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                    .removeObjects(in: app.appInfo.urlSchemes() as! [Any])
            } else {
                sharedModel.hiddenApps.removeAll { now in
                    return app == now
                }
                if !sharedModel.apps.contains(app) {
                    sharedModel.apps.append(app)
                }
                UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                    .addObjects(from: app.appInfo.urlSchemes() as! [Any])
            }
            
        }
    }
    
    func launchAppWithBundleId(bundleId : String, container : String?, forceJIT: Bool? = nil) async {
        if bundleId == "" {
            return
        }
        var appFound : LCAppModel? = nil
        var isFoundAppLocked = false
        for app in sharedModel.apps {
            if app.appInfo.relativeBundlePath == bundleId {
                appFound = app
                if app.appInfo.isLocked {
                    isFoundAppLocked = true
                }
                break
            }
        }
        if appFound == nil && !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
            for app in sharedModel.hiddenApps {
                if app.appInfo.relativeBundlePath == bundleId {
                    appFound = app
                    isFoundAppLocked = true
                    break
                }
            }
        }
        
        if isFoundAppLocked && !sharedModel.isHiddenAppUnlocked {
            do {
                let result = try await LCUtils.authenticateUser()
                if !result {
                    return
                }
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
        }
        
        guard let appFound else {
            errorInfo = "lc.appList.appNotFoundError".loc
            errorShow = true
            return
        }

        do {
            try await appFound.runApp(multitask: nil, containerFolderName: container, forceJIT: forceJIT)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
        
    }
    
    func authenticateUser() async {
        do {
            if !(try await LCUtils.authenticateUser()) {
                return
            }
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            return
        }
    }
    
    func jitLaunch(appName: String) async {
        await jitLaunch(withScript: "", appName: appName)
    }

    func jitLaunch(withScript script: String, appName: String) async {
        await MainActor.run {
            jitLog = ""
        }
        let enableJITTask = Task {
            
            let _ = await LCUtils.askForJIT(withScript: script, appName: appName) { newMsg in
                Task { await MainActor.run {
                    self.jitLog += "\(newMsg)\n"
                }}
            }
            guard let _ = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")) else {
                return
            }
        }
        guard let result = await jitAlert.open(), result else {
            UserDefaults.standard.removeObject(forKey: "selected")
            enableJITTask.cancel()
            return
        }
        LCSharedUtils.launchToGuestApp()

    }
    
    func jitLaunch(withPID pid: Int, withScript script: String? = nil, appName: String) async {
        await MainActor.run {
            let encodedData = script?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                
            
            if let jitEnabler = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")) {
                if jitEnabler == .StosDebug || jitEnabler == .StosDebugLC {
                    let encoded = encodedData.map { "&script=\($0)" } ?? ""
                    if jitEnabler == .StosDebugLC {
                        if let app = sharedModel.apps.first(where: { app in
                            return app.appInfo.urlSchemes().contains("stosdebug") &&
                            (sharedModel.multiLCStatus != 2 || app.appInfo.isShared)
                        }) {
                            if var url = URL(string: "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(appName)&pid=\(pid)&relaunchApp=false& forcePID=true\(encoded)") {
                                Task { await openWebView(urlString: url.absoluteString) }
                            }
                        } else {
                            errorInfo = "StosDebug is not found. Please install it first and switch it to shared app."
                            errorShow = true
                            return
                        }
                    } else {
                        if var url = URL(string: "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(appName)&pid=\(pid)&forcePID=true\(encoded)") {
                            UIApplication.shared.open(url)
                        }
                    }
                    return
                }
                
                let encoded = encodedData.map { "&script-data=\($0)" } ?? ""
                if let url = URL(string: "stikjit://enable-jit?bundle-id=\(Bundle.main.bundleIdentifier!)&pid=\(pid)\(encoded)") {
                    if jitEnabler == .StikJITLC {
                        if let app = sharedModel.apps.first(where: { app in
                            return app.appInfo.urlSchemes().contains("stikjit") &&
                            (sharedModel.multiLCStatus != 2 || app.appInfo.isShared)
                        }) {
                            Task { await openWebView(urlString: url.absoluteString) }
                        } else {
                            errorInfo = "StikDebug is not found. Please install it first and switch it to shared app."
                            errorShow = true
                            return
                        }
                    } else {
                        UIApplication.shared.open(url)
                    }
                }
            }
        }
    }

    func showRunWhenMultitaskAlert() async -> Bool? {
        return await runWhenMultitaskAlert.open()
    }
    
    func installMdm(data: Data) {
        safariViewURL = URL(string:"data:application/x-apple-aspen-config;base64,\(data.base64EncodedString())")!
        safariViewOpened = true
    }
    
    func openNavigationView(view: AnyView) {
        navigationTarget = NavigationTarget(view: view)
    }
    
    func promptForGeneratedIconStyle() async -> GeneratedIconStyle? {
        if #available(iOS 18.0, *) {
            return await generatedIconStyleSelector.open()
        } else {
            return .Light
        }
        
    }
    
    func closeNavigationView() {
        navigationTarget = nil
    }
    
    func copyError() {
        UIPasteboard.general.string = errorInfo
    }
    
    func handleURL(url : URL) {
        if url.isFileURL {
            Task { await installFromUrl(urlStr: url.absoluteString) }
            return
        }
        
        if url.scheme == "sidestore" && UserDefaults.sideStoreExist() {
            UserDefaults.standard.setValue(url.absoluteString, forKey: "launchAppUrlScheme")
            LCUtils.openSideStore(delegate: self)
            return
        }
        
        if url.host == "open-web-page" || url.host == "open-url" {
            if let urlComponent = URLComponents(url: url, resolvingAgainstBaseURL: false), let queryItem = urlComponent.queryItems?.first {
                if queryItem.value?.isEmpty ?? true {
                    return
                }
                
                if let decodedData = Data(base64Encoded: queryItem.value ?? ""),
                   let decodedUrl = String(data: decodedData, encoding: .utf8) {
                    Task { await openWebView(urlString: decodedUrl) }
                }
            }
        } else if url.host == "livecontainer-launch" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var bundleId : String? = nil
                var containerName : String? = nil
                var forceJIT: Bool? = nil
                for queryItem in components.queryItems ?? [] {
                    if queryItem.name == "bundle-name", let bundleId1 = queryItem.value {
                        bundleId = bundleId1
                    } else if queryItem.name == "container-folder-name", let containerName1 = queryItem.value {
                        containerName = containerName1
                    } else if queryItem.name == "jit", let forceJIT1 = queryItem.value {
                        if forceJIT1 == "true" {
                            forceJIT = true
                        } else if forceJIT1 == "false" {
                            forceJIT = false
                        }
                    }
                }
                if let bundleId, bundleId != "ui"{
                    Task { await launchAppWithBundleId(bundleId: bundleId, container: containerName, forceJIT: forceJIT) }
                }
            }
        } else if url.host == "install" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var installUrl : String? = nil
                for queryItem in components.queryItems ?? [] {
                    if queryItem.name == "url", let installUrl1 = queryItem.value {
                        installUrl = installUrl1
                    }
                }
                if let installUrl {
                    Task { await installFromUrl(urlStr: installUrl) }
                }
            }
        }
    }
    
}

extension View {
    func apply<V: View>(@ViewBuilder _ block: (Self) -> V) -> V { block(self) }
}
