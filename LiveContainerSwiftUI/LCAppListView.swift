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
    @State var installProgressPercentage : Float = 0.0
    @State var installObserver : NSKeyValueObservation?
    
    @State var installOptions: [AppReplaceOption]
    @StateObject var installReplaceAlert = AlertHelper<AppReplaceOption>()
    
    @State var webViewOpened = false
    @State var webViewURL : URL = URL(string: "about:blank")!
    @StateObject private var webViewUrlInput = InputHelper()
    
    @StateObject private var downloadHelper = DownloadHelper()
    @StateObject private var installUrlInput = InputHelper()
    
    @State private var jitLog = ""
    @StateObject private var jitAlert = YesNoHelper()
    
    @StateObject private var runWhenMultitaskAlert = YesNoHelper()
    
    @StateObject private var generatedIconStyleSelector = AlertHelper<GeneratedIconStyle>()
    
    @State var safariViewOpened = false
    @State var safariViewURL = URL(string: "https://google.com")!
    
    @State private var navigateTo : AnyView?
    @State private var isNavigationActive = false
    
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

    @EnvironmentObject private var sharedModel : SharedModel
    @EnvironmentObject private var sharedAppSortManager : LCAppSortManager
    
    
    @EnvironmentObject private var flekstoreSharedModel: FlekstoreSharedModel
    
    @AppStorage("LCMultitaskMode", store: LCUtils.appGroupUserDefault) var multitaskMode: MultitaskMode = .virtualWindow
    @AppStorage("LCLaunchInMultitaskMode") var launchInMultitaskMode = false
    
    @State private var isViewAppeared = false
    
    @ObservedObject var searchContext = SearchContext()
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
    
    init(appDataFolderNames: Binding<[String]>, tweakFolderNames: Binding<[String]>) {
        _installOptions = State(initialValue: [])
        _appDataFolderNames = appDataFolderNames
        _tweakFolderNames = tweakFolderNames
    }
    
    var body: some View {
        ZStack {
            FlekWallpaperView()

            Group {
                if homeLayout == FlekHomeLayout.list.rawValue {
                    FlekHomeListView(
                        items: homeItems,
                        darkModeIcon: darkModeIcon,
                        isEditing: $isEditing,
                        isNew: { FlekLaunchTracker.shared.isNew($0) },
                        onTap: { handleHomeTap($0) },
                        onDelete: { item in
                            if case .installed(let app) = item { Task { await requestUninstall(app) } }
                        },
                        contextMenu: { item in homeContextMenu(for: item) }
                    )
                } else {
                    FlekSpringboardView(
                        items: homeItems,
                        darkModeIcon: darkModeIcon,
                        isEditing: $isEditing,
                        isNew: { FlekLaunchTracker.shared.isNew($0) },
                        isSingleMode: { FlekLaunchModeStore.shared.showsSingleBadge(for: $0) },
                        onTap: { handleHomeTap($0) },
                        onDelete: { item in
                            if case .installed(let app) = item { Task { await requestUninstall(app) } }
                        },
                        contextMenu: { item in homeContextMenu(for: item) }
                    )
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 84)
            .id(homeRefreshToggle)
            .blur(radius: showSearch ? 20 : 0)

            if !showSearch {
            VStack {
                Spacer()
                if isEditing {
                    Button {
                        withAnimation { isEditing = false }
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
                    FlekGlassCircleButton(systemImage: "magnifyingglass",
                                          size: FlekTheme.searchPillSize, iconScale: 0.5) {
                        showSearch = true
                    }
                    .padding(.bottom, 10)
                }
            }
            }

            if installprogressVisible {
                VStack {
                    ProgressView(value: installProgressPercentage)
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .padding(.horizontal, 24)
                        .padding(.top, 60)
                    Spacer()
                }
            }

            if showSearch {
                FlekSearchView(
                    isPresented: $showSearch,
                    apps: sortedApps,
                    darkModeIcon: darkModeIcon,
                    onSelect: { app in handleHomeTap(.installed(app)) }
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
        .sheet(isPresented: $isNavigationActive) {
            if let navigateTo { navigateTo }
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
        .downloadAlert(helper: downloadHelper)
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

    var homeItems: [FlekHomeItem] {
        var items: [FlekHomeItem] = [
            .defaultApp(.flekstore),
            .defaultApp(.settings),
            .defaultApp(.installer)
        ]
        items.append(contentsOf: sortedApps.map { .installed($0) })
        return items
    }

    func handleHomeTap(_ item: FlekHomeItem) {
        switch item {
        case .defaultApp(let kind):
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
        case .installed(let app):
            FlekLaunchTracker.shared.markLaunched(app)
            let parallel = FlekLaunchModeStore.shared.mode(for: app) == .parallel
            Task { await launchHomeApp(app, parallel: parallel) }
        }
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
    func homeContextMenu(for item: FlekHomeItem) -> some View {
        switch item {
        case .defaultApp:
            // Built-in apps: only the "arrange" action is offered (they can be
            // moved but not removed, have no launch mode / settings / uninstall).
            Button {
                withAnimation { isEditing = true }
            } label: {
                Label("lc.appBanner.moveCards".loc, systemImage: "square.grid.2x2")
            }
        case .installed(let app):
            installedContextMenu(app)
        }
    }

    @ViewBuilder
    private func installedContextMenu(_ app: LCAppModel) -> some View {
        let mode = FlekLaunchModeStore.shared.mode(for: app) ?? .single
        Button {
            FlekLaunchModeStore.shared.set(.single, for: app)
            homeRefreshToggle.toggle()
            FlekLaunchTracker.shared.markLaunched(app)
            Task { await launchHomeApp(app, parallel: false) }
        } label: {
            Label("lc.appBanner.runSingle".loc, systemImage: mode == .single ? "checkmark" : "1.square")
        }
        if #available(iOS 16.0, *) {
            Button {
                FlekLaunchModeStore.shared.set(.parallel, for: app)
                homeRefreshToggle.toggle()
                FlekLaunchTracker.shared.markLaunched(app)
                Task { await launchHomeApp(app, parallel: true) }
            } label: {
                Label("lc.appBanner.runParallel".loc, systemImage: mode == .parallel ? "checkmark" : "square.on.square")
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
            withAnimation { isEditing = true }
        } label: {
            Label("lc.appBanner.moveCards".loc, systemImage: "square.grid.2x2")
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
            
            UserDefaults.standard.setValue(urlToOpen.url!.absoluteString, forKey: "launchAppUrlScheme")
            do {
                try await appToLaunch.runApp(multitask: launchInMultitaskMode)
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
            finalNewApp.autoSaveDisabled = false
            finalNewApp.save()
        } else {
            // enable SDK version spoof by defalut
            finalNewApp.spoofSDKVersion = true
        }
        finalNewApp.installationDate = Date.now
        
        DispatchQueue.main.async {
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
            
            self.installprogressVisible = false
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
            } else {
                sharedModel.hiddenApps.removeAll { now in
                    return app == now
                }
                if !sharedModel.apps.contains(app) {
                    sharedModel.apps.append(app)
                }
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
            if #available(iOS 16.0, *), launchInMultitaskMode {
                try await appFound.runApp(multitask: true, containerFolderName: container, forceJIT: forceJIT)
            } else {
                try await appFound.runApp(multitask: false, containerFolderName: container, forceJIT: forceJIT)
            }
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
    
    func jitLaunch() async {
        await jitLaunch(withScript: "")
    }

    func jitLaunch(withScript script: String) async {
        await MainActor.run {
            jitLog = ""
        }
        let enableJITTask = Task {
            let _ = await LCUtils.askForJIT(withScript: script) { newMsg in
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
    
    func jitLaunch(withPID pid: Int, withScript script: String? = nil) async {
        await MainActor.run {
            let encoded = script?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                .map { "&script-data=\($0)" } ?? ""
            if let url = URL(string: "stikjit://enable-jit?bundle-id=\(Bundle.main.bundleIdentifier!)&pid=\(pid)\(encoded)") {
                if let jitEnabler = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")), jitEnabler == .StikJITLC {
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

    func showRunWhenMultitaskAlert() async -> Bool? {
        return await runWhenMultitaskAlert.open()
    }
    
    func installMdm(data: Data) {
        safariViewURL = URL(string:"data:application/x-apple-aspen-config;base64,\(data.base64EncodedString())")!
        safariViewOpened = true
    }
    
    func openNavigationView(view: AnyView) {
        navigateTo = view
        isNavigationActive = true
    }
    
    func promptForGeneratedIconStyle() async -> GeneratedIconStyle? {
        if #available(iOS 18.0, *) {
            return await generatedIconStyleSelector.open()
        } else {
            return .Light
        }
        
    }
    
    func closeNavigationView() {
        isNavigationActive = false
        navigateTo = nil
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
