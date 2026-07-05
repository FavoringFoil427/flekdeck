//
//  LCSettingsView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Foundation
import SwiftUI
import UserNotifications

enum JITEnablerType : Int, CaseIterable, Identifiable {
    var id: Int { rawValue }
    case SideJITServer = 0
    case StikJIT = 1
    case JITStreamerEBLegacy = 2
    case StikJITLC = 3
    case SideStore = 4
    case StosDebug = 5
    case StosDebugLC = 6
    
    var displayName: String {
        switch self {
        case .StikJIT: "StikDebug"
        case .StikJITLC: "StikDebug (Another LiveContainer)"
        case .StosDebug: "StosDebug"
        case .StosDebugLC: "StosDebug (Another LiveContainer)"
        case .SideStore: "SideStore"
        case .JITStreamerEBLegacy: "JitStreamer-EB (Relaunch)"
        case .SideJITServer: "SideJITServer/JITStreamer 2.0"
        }
    }
}

struct LCSettingsView: View {
    @State var errorShow = false
    @State var errorInfo = ""
    @State var successShow = false
    @State var successInfo = ""
    @State private var udid: String = ""
    
    @State private var subscriptionEndDate: String?
    @State private var hasSubscription: Bool = false
    @State private var isSubscriptionLoading: Bool = false
    
    @Binding var appDataFolderNames: [String]
    @Binding var tweakFolderNames: [String]
    
    
    @StateObject private var installLC2Alert = AlertHelper<Int>()
    @State private var certificateDataFound = false
    
    @StateObject private var certificateImportAlert = YesNoHelper()
    @StateObject private var certificateImportFromBuiltInSideStoreAlert = YesNoHelper()
    @StateObject private var certificateRemoveAlert = YesNoHelper()
    @StateObject private var certificateImportFileAlert = AlertHelper<URL>()
    @StateObject private var certificateImportPasswordAlert = InputHelper()
    
    @AppStorage("LCFrameShortcutIcons") var frameShortIcon = false
    @AppStorage("LCSwitchAppWithoutAsking") var silentSwitchApp = false
    @AppStorage("LCOpenWebPageWithoutAsking") var silentOpenWebPage = false
    @AppStorage("LCDontSignApp", store: LCUtils.appGroupUserDefault) var dontSignApp = false
    @AppStorage("LCCustomBundleIdEnabled", store: LCUtils.appGroupUserDefault) var customBundleIdEnabled = false
    @AppStorage("LCStrictHiding", store: LCUtils.appGroupUserDefault) var strictHiding = false
    @AppStorage("dynamicColors", store: LCUtils.appGroupUserDefault) var dynamicColors = true
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) var darkModeIcon = false
    
    @AppStorage("LCMultitaskMode", store: LCUtils.appGroupUserDefault) var multitaskMode: MultitaskMode = .virtualWindow
    @AppStorage("LCLaunchInMultitaskMode") var launchInMultitaskMode = true
    @AppStorage("LCLaunchMultitaskMaximized") var launchMultitaskMaximized = false
    @AppStorage("LCMultitaskBottomWindowBar", store: LCUtils.appGroupUserDefault) var bottomWindowBar = false
    @AppStorage("LCAutoEndPiP", store: LCUtils.appGroupUserDefault) var autoEndPiP = false
    @AppStorage("LCSkipTerminatedScreen", store: LCUtils.appGroupUserDefault) var skipTerminatedScreen = true
    @AppStorage("LCRestartTerminatedApp", store: LCUtils.appGroupUserDefault) var restartTerminatedApp = true
    @AppStorage("LCMaxOneAppOnStage", store: LCUtils.appGroupUserDefault) var onlyOneAppOnStage = false
    @AppStorage("LCDockWidth", store: LCUtils.appGroupUserDefault) var dockWidth: Double = 80
    @AppStorage("LCRedirectURLToHost", store: LCUtils.appGroupUserDefault) var redirectURLToHost = false
    
    @AppStorage("LCSideJITServerAddress", store: LCUtils.appGroupUserDefault) var sideJITServerAddress : String = ""
    @AppStorage("LCDeviceUDID", store: LCUtils.appGroupUserDefault) var deviceUDID: String = ""
    @AppStorage("FSDeviceUDID") private var fsDeviceUDID: String = ""
    @AppStorage("LCJITEnablerType", store: LCUtils.appGroupUserDefault) var JITEnabler: JITEnablerType = .SideJITServer
    
    @State var store : Store = .Unknown
    
    @AppStorage("LCLoadTweaksToSelf") var injectToLCItelf = false
    @AppStorage("LCIgnoreJITOnLaunch") var ignoreJITOnLaunch = false
    #if is32BitSupported
    @AppStorage("selected32BitLayer") var liveExec32Path : String = ""
    #endif
    @AppStorage("LCKeepSelectedWhenQuit") var keepSelectedWhenQuit = false
    @AppStorage("LCWaitForDebugger") var waitForDebugger = false
    @AppStorage("LCSharePrivateDataWithLiveProcess") var sharePrivateDataWithLiveProcess = false
    @AppStorage("BKNoWatchdogs") var disableLiveProcessWatchdog = false
    
    ///Flekstore user defaults
    @AppStorage("FSEncryptedUDID")
    private var encryptedUDID: String = ""

    @AppStorage("FSSubscriptionEndDate")
    private var subscriptionEndDateStored: String = ""

    @AppStorage("FSSubscriptionStatus")
    private var subscriptionStatusStored: Bool = false
    
    @AppStorage("FSSubscriptionInitialized")
    private var subscriptionInitialized: Bool = false
    
    @AppStorage("LCBetaBannerOverride", store: LCUtils.appGroupUserDefault) private var betaBannerOverride: Int = 0

    @EnvironmentObject private var sharedModel : SharedModel
    
    @State private var isViewAppeared = false
    
    let storeName = LCUtils.getStoreName()
    
    init(appDataFolderNames: Binding<[String]>, tweakFolderNames: Binding<[String]>) {
        _certificateDataFound = State(initialValue: LCSharedUtils.certificatePassword() != nil)
        _store = State(initialValue: LCUtils.store())

        _appDataFolderNames = appDataFolderNames
        _tweakFolderNames = tweakFolderNames
    }
    
    let fsPassword: String = {
        if let dict = Bundle.main.infoDictionary,
           let value = dict["fsPassword"] as? String,
           !value.isEmpty {
            return value
        }
        return "12345"
    }()

    private static let subscriptionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    private func formattedSubscriptionDate(_ dateString: String) -> String {
        if let date = DateFormatter.deviceServiceFormatter.date(from: dateString) {
            return Self.subscriptionDateFormatter.string(from: date)
        }

        if let dateOnly = dateString.split(separator: " ").first {
            return String(dateOnly)
        }

        return dateString
    }
    
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "wallet.pass.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.blue)
                            .cornerRadius(8)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("UDID")
                                .font(.body)
                            
                            Text(udid)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .scaledToFit()
                                .minimumScaleFactor(0.3)
                        }
                        Spacer()
                        
                        if udid.isEmpty {
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                Task {
                                    await checkSubscription()
                                }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 18))
                                    .foregroundColor(.blue)
                            }
                            .disabled(isSubscriptionLoading)
                        } else {
                            Button(action: {
                                UIPasteboard.general.string = udid
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 18))
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    
                    // MARK: - Subscription Status
                    HStack(spacing: 12) {
                        Image("premiumLogo")
                            .resizable()
                            .frame(width: 36, height: 36)
                            .cornerRadius(8)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Premium Subscription")
                                .font(.body)

                            if isSubscriptionLoading {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Checking…")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            } else if hasSubscription, let endDate = subscriptionEndDate {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                        .font(.subheadline)
                                    Text("Valid till \(formattedSubscriptionDate(endDate))")
                                        .font(.subheadline)
                                        .foregroundColor(.green)
                                }
                            } else if let endDate = subscriptionEndDate {
                                Text("Ended \(formattedSubscriptionDate(endDate))")
                                    .font(.subheadline)
                                    .foregroundColor(.red)
                            } else {
                                Text("No active subscription")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                            }
                        }

                        Spacer()

                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            Task {
                                if !udid.isEmpty {
                                    await checkSubscription()
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 18))
                                .foregroundColor(.blue)
                        }
                        .disabled(isSubscriptionLoading)
                    }
                    .padding(.vertical, 6)
                }
                // MARK: - Certificate (shown only when no certificate is detected)
                if sharedModel.multiLCStatus != 2 && !certificateDataFound {
                    Section {
                        Button("Import Flekstore certificate") {
                            Task { await importEmbeddedCertificate() }
                        }
                        
                        Button("lc.settings.importCertificate".loc) {
                            Task { await importCertificate() }
                        }
                    } header: {
                        Text("lc.settings.jitLess".loc)
                    } footer: {
                        Text("lc.settings.jitLessDesc".loc)
                    }
                }
                // MARK: - Categories
                Section {
                    NavigationLink { FlekPersonalizationView() } label: {
                        categoryRow("lc.flek.personalization".loc, "paintbrush.fill", .purple)
                    }
                    NavigationLink { launchBehaviorPage } label: {
                        categoryRow("lc.flek.cat.launch".loc, "app.grid", .blue)
                    }
                    if #available(iOS 16.1, *) {
                        NavigationLink { multitaskPage } label: {
                            categoryRow("lc.flek.cat.multitask".loc, "macwindow.on.rectangle", .green)
                        }
                    }
                    NavigationLink { jitPage } label: {
                        categoryRow("lc.flek.cat.jit".loc, "j.circle", .blue)
                    }
                    NavigationLink { contentRestrictionsPage } label: {
                        categoryRow("lc.flek.cat.content".loc, "nosign", .red)
                    }
                    NavigationLink { signingPage } label: {
                        categoryRow("lc.flek.cat.signing".loc, "signature", .mint)
                    }
                    NavigationLink { LCTweaksView(tweakFolders: $tweakFolderNames) } label: {
                        categoryRow("Tweaks", "wrench.and.screwdriver.fill", .orange)
                    }
                }
                Section {
                    HStack {
                        Image("GitHub")
                        Button("LiveContainer/LiveContainer") {
                            openGitHub()
                        }
                    }
                    HStack {
                        Image("GitHub")
                        Button("Huge_Black") {
                            openGitHub2()
                        }
                    }
                    
                    HStack {
                        Image("Twitter")
                        Button("khanhduytran0") {
                            openTwitter()
                        }
                    }
                } footer: {
                    Text("lc.settings.warning".loc)
                }
                
                VStack{
                    Text(LCUtils.getVersionInfo())
                        .foregroundStyle(.gray)
                        .onTapGesture(count: 5) {
                            sharedModel.developerMode = true
                        }
                    
                    HStack(spacing:0){
                        Text("Build: ")
                            .foregroundStyle(.gray)
                        Link("FlekSt0re", destination: URL(string: "https://flekstore.com")!)
                    }
                    
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .background(Color(UIColor.systemGroupedBackground))
                .listRowInsets(EdgeInsets())

                if isBetaiOS {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("iOS Beta Detected")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.red)
                                Text("Beta versions of iOS may cause certificate revocation. Apps and features may not work correctly. Please roll back to the stable release version.")
                                    .font(.caption)
                                    .foregroundStyle(.red.opacity(0.8))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if sharedModel.developerMode {
                    Section {
                        Toggle(isOn: $injectToLCItelf) {
                            Text("lc.settings.injectLCItself".loc)
                        }
                        Toggle(isOn: $ignoreJITOnLaunch) {
                            Text("Ignore JIT on Launching App")
                        }
                        Toggle(isOn: $keepSelectedWhenQuit) {
                            Text("Keep Selected App when Quit")
                        }
                        Toggle(isOn: $waitForDebugger) {
                            Text("Wait For Debugger")
                        }
                        Toggle(isOn: $sharePrivateDataWithLiveProcess) {
                            Text("Allow Private Data access from LiveProcess")
                        }
                        Toggle(isOn: $disableLiveProcessWatchdog) {
                            Text("Disable LiveProcess watchdog termination")
                        }
                        Button {
                            export()
                        } label: {
                            Text("Export Cert")
                        }
                        Button {
                            exportDyld()
                        } label: {
                            Text("Export Dyld")
                        }
                        Button {
                            Task { await nukeSideStore() }
                        } label: {
                            Text("Nuke SideStore")
                        }
                        Button {
                            exportMainBundle()
                        } label: {
                            Text("Export Main Bundle")
                        }
                        Button {
                            resetSymbolOffsets()
                        } label: {
                            Text("Reset Symbol Offsets")
                        }
                        Button {
                            presentFLEXOverlay()
                        } label: {
                            Text("Show FLEX Overlay")
                        }
                        .disabled(NSClassFromString("FLEXManager") == nil)
                        #if is32BitSupported
                        HStack {
                            Text("LiveExec32 .app path")
                            Spacer()
                            TextField("", text: $liveExec32Path)
                                .multilineTextAlignment(.trailing)
                        }
                        #endif
                    } header: {
                        Text("Developer Settings")
                    } footer: {
                        Text("lc.settings.injectLCItselfDesc".loc)
                    }
                }
            }
            .navigationTitle("lc.tabView.settings".loc)
            .navigationBarTitleDisplayMode(.large)
            .onAppear {
                loadEncryptedUDIDFromPlist()
                hydrateSubscriptionStateFromStorage()

                // Fetch once for initial subscription bootstrap only.
                if !subscriptionInitialized {
                    Task {
                        await checkSubscription()
                        subscriptionInitialized = true
                    }
                }
            }
            .onChange(of: deviceUDID) { newValue in
                udid = newValue
            }
            .onChange(of: subscriptionStatusStored) { newValue in
                hasSubscription = newValue
            }
            .onChange(of: subscriptionEndDateStored) { newValue in
                subscriptionEndDate = newValue.isEmpty ? nil : newValue
            }
            .alert("lc.common.error".loc, isPresented: $errorShow){
            } message: {
                Text(errorInfo)
            }
            .alert("lc.common.success".loc, isPresented: $successShow){
            } message: {
                Text(successInfo)
            }
            .alert("lc.settings.importCertificate".loc, isPresented: $certificateImportAlert.show) {
                Button {
                    certificateImportAlert.close(result: true)
                } label: {
                    Text("lc.common.ok".loc)
                }
                
                Button("lc.common.cancel".loc, role: .cancel) {
                    certificateImportAlert.close(result: false)
                }
            } message: {
                Text("lc.settings.importCertificateDesc".loc)
            }
            .alert("lc.settings.removeCertificate".loc, isPresented: $certificateRemoveAlert.show) {
                Button(role: .destructive) {
                    certificateRemoveAlert.close(result: true)
                } label: {
                    Text("lc.common.ok".loc)
                }
                
                Button("lc.common.cancel".loc, role: .cancel) {
                    certificateRemoveAlert.close(result: false)
                }
            } message: {
                Text("lc.settings.removeCertificateDesc".loc)
            }
            .alert("lc.settings.importCertFromBuiltinSideStore".loc, isPresented: $certificateImportFromBuiltInSideStoreAlert.show) {
                Button {
                    certificateImportFromBuiltInSideStoreAlert.close(result: true)
                } label: {
                    Text("lc.common.ok".loc)
                }
                Button("lc.common.cancel".loc, role: .cancel) {
                    certificateImportFromBuiltInSideStoreAlert.close(result: false)
                }
            } message: {
                Text("lc.settings.importCertFromBuiltinSideStoreDesc".loc)
            }
            .betterFileImporter(isPresented: $certificateImportFileAlert.show, types: [.p12], multiple: false, callback: { fileUrls in
                certificateImportFileAlert.close(result: fileUrls[0])
            }, onDismiss: {
                certificateImportFileAlert.close(result: nil)
            })
            .textFieldAlert(
                isPresented: $certificateImportPasswordAlert.show,
                title: "lc.settings.importCertificateInputPassword".loc,
                text: $certificateImportPasswordAlert.initVal,
                placeholder: "",
                action: { newText in
                    certificateImportPasswordAlert.close(result: newText)
                },
                actionCancel: {_ in
                    certificateImportPasswordAlert.close(result: nil)
                    certificateImportPasswordAlert.show = false
                }
            )
        }
        .onAppear {
            if !certificateDataFound {
                Task { await importEmbeddedCertificate() }
            }
            if !isViewAppeared {
                guard sharedModel.selectedTab == .settings, let link = sharedModel.deepLink else { return }
                sharedModel.deepLink = nil
                handleURL(url: link)
                isViewAppeared = true
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onChange(of: sharedModel.deepLink) { link in
            guard sharedModel.selectedTab == .settings, let link else { return }
            sharedModel.deepLink = nil
            handleURL(url: link)
        }
    }

    private var isBetaiOS: Bool {
        guard let buildVersion = UIDevice.current.buildVersion,
              let lastChar = buildVersion.last else { return false }
        return lastChar.isLowercase
    }

    @ViewBuilder
    private func categoryRow(_ title: String, _ systemImage: String, _ color: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color))
        }
    }

    @ViewBuilder private var launchBehaviorPage: some View {
        Form {
                Section {
                    Toggle(isOn: $silentSwitchApp) {
                        Text("lc.settings.silentSwitchApp".loc)
                    }
                } footer: {
                    Text("lc.settings.silentSwitchAppDesc".loc)
                }
                
                Section {
                    Toggle(isOn: $silentOpenWebPage) {
                        Text("lc.settings.silentOpenWebPage".loc)
                    }
                } footer: {
                    Text("lc.settings.silentOpenWebPageDesc".loc)
                }
                
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("lc.flek.cat.launch".loc).font(.headline) } }
    }

    @ViewBuilder private var multitaskPage: some View {
        Form {
                if #available(iOS 16.1, *) {
                    Section {
                        if(UIApplication.shared.supportsMultipleScenes) {
                            Picker(selection: $multitaskMode) {
                                Text("lc.settings.multitaskMode.virtualWindow".loc).tag(MultitaskMode.virtualWindow)
                                Text("lc.settings.multitaskMode.nativeWindow".loc).tag(MultitaskMode.nativeWindow)
                            } label: {
                                Text("lc.settings.multitaskMode".loc)
                            }
                        }
                        Toggle(isOn: $launchInMultitaskMode) {
                            Text("lc.settings.autoLaunchInMultitaskMode".loc)
                        }
                        
                        if multitaskMode == .virtualWindow {
                            Toggle(isOn: $launchMultitaskMaximized) {
                                Text("lc.settings.launchMultitaskMaximized".loc)
                            }
                            if launchMultitaskMaximized {
                                Toggle(isOn: $onlyOneAppOnStage) {
                                    Text("lc.settings.onlyOneAppOnStage".loc)
                                }
                            }
                            Toggle(isOn: $autoEndPiP) {
                                Text("lc.settings.autoEndPiP".loc)
                            }
                            Toggle(isOn: $skipTerminatedScreen) {
                                Text("lc.settings.skipTerminatedScreen".loc)
                            }
                            if skipTerminatedScreen {
                                Toggle(isOn: $restartTerminatedApp) {
                                    Text("lc.settings.restartTerminatedApp".loc)
                                }
                            }
                            Toggle(isOn: $bottomWindowBar) {
                                Text("lc.settings.bottomWindowBar".loc)
                            }
                            Toggle(isOn: $redirectURLToHost) {
                                Text("lc.settings.redirectURLToHost".loc)
                            }
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("lc.settings.dockWidth".loc)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Text("\(Int(dockWidth))px")
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                }
                                Slider(value: $dockWidth, in: 60...110) {
                                    Text("lc.settings.dockWidth".loc)
                                }
                                .tint(.accentColor)
                            }
                            .padding(.vertical, 4)
                        }
                    } footer: {
                        Text("lc.settings.multitaskDesc".loc)
                    }
                }
                
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("lc.flek.cat.multitask".loc).font(.headline) } }
    }

    @ViewBuilder private var jitPage: some View {
        Form {
                if sharedModel.multiLCStatus != 2 {
                    Section {
                        if !certificateDataFound {
                            Button("lc.settings.importCertificate".loc) {
                                Task { await importCertificate() }
                            }
                        } else {
                            Button("lc.settings.removeCertificate".loc) {
                                Task { await removeCertificate() }
                            }
                        }
                        
                        NavigationLink {
                            LCJITLessDiagnoseView()
                        } label: {
                            Text("lc.settings.jitlessDiagnose".loc)
                        }
                    } header: {
                        Text("lc.settings.jitLess".loc)
                    } footer: {
                        Text("lc.settings.jitLessDesc".loc)
                    }
                }
                Section {
                    if JITEnabler == .SideJITServer || JITEnabler == .JITStreamerEBLegacy {
                        HStack {
                            Text("lc.settings.JitAddress".loc)
                            Spacer()
                            TextField(JITEnabler == .SideJITServer ? "http://x.x.x.x:8080" : "http://[fd00::]:9172", text: $sideJITServerAddress)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    if JITEnabler == .SideJITServer {
                        HStack {
                            Text("lc.settings.JitUDID".loc)
                            Spacer()
                            TextField("", text: $deviceUDID)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    Picker(selection: $JITEnabler) {
                        Text("SideJITServer/JITStreamer 2.0").tag(JITEnablerType.SideJITServer)
                        Text("StikDebug").tag(JITEnablerType.StikJIT)
                        Text("StikDebug (Another LiveContainer)").tag(JITEnablerType.StikJITLC)
                        Text("SideStore").tag(JITEnablerType.SideStore)
                        Text("JitStreamer-EB (Relaunch)").tag(JITEnablerType.JITStreamerEBLegacy)
                    } label: {
                        Text("lc.settings.jitEnabler".loc)
                    }
                    
                } header: {
                    Text("JIT")
                } footer: {
                    Text("lc.settings.JitDesc".loc)
                }
                
                
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("lc.flek.cat.jit".loc).font(.headline) } }
    }

    @ViewBuilder private var contentRestrictionsPage: some View {
        Form {
                Section{
                    AgeConfirmationView()
                } header: {
                    Text("Sensitive Content")
                } footer: {
                    Text("Enabling this option will grant access to applications with strict age restrictions and the \"Adult\" category.")
                }
                
                if sharedModel.isHiddenAppUnlocked {
                    Section {
                        Toggle(isOn: $strictHiding) {
                            Text("lc.settings.strictHiding".loc)
                        }
                    } footer: {
                        Text("lc.settings.strictHidingDesc".loc)
                    }
                }
                
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("lc.flek.cat.content".loc).font(.headline) } }
    }

    @ViewBuilder private var signingPage: some View {
        Form {
                Section {
                    Toggle(isOn: $dontSignApp) {
                        Text("lc.settings.dontSign".loc)
                    }
                } footer: {
                    Text("lc.settings.dontSignDesc".loc)
                }
                
                Section {
                    Toggle(isOn: $customBundleIdEnabled) {
                        Text("lc.settings.customBundleId".loc)
                    }
                } footer: {
                    Text("lc.settings.customBundleIdDesc".loc)
                }
                
                Section {
                    NavigationLink {
                        LCDataManagementView(appDataFolderNames: $appDataFolderNames)
                    } label: {
                        Text("lc.settings.dataManagement".loc)
                    }
                }
                
                if (store != .Unknown && store != .ADP) || LCUtils.isAppGroupAltStoreLike() {
                    Section{
                        NavigationLink {
                            LCMultiLCManagementView()
                        } label: {
                            if sharedModel.multiLCStatus == 0 {
                                Text("lc.settings.multiLCInstall".loc)
                            } else if sharedModel.multiLCStatus == 2 {
                                Text("lc.settings.multiLCIsSecond".loc)
                            }
                            
                        }
                        .disabled(sharedModel.multiLCStatus == 2)
                        
                        if(sharedModel.multiLCStatus == 2) {
                            NavigationLink {
                                LCJITLessDiagnoseView()
                            } label: {
                                Text("lc.settings.jitlessDiagnose".loc)
                            }
                        }
                    } header: {
                        Text("lc.settings.multiLC".loc)
                    } footer: {
                        Text("lc.settings.multiLCDesc".loc)
                    }
                }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("lc.flek.cat.signing".loc).font(.headline) } }
    }

    
    func openGitHub() {
        UIApplication.shared.open(URL(string: "https://github.com/LiveContainer/LiveContainer")!)
    }
    
    func openGitHub2() {
        UIApplication.shared.open(URL(string: "https://github.com/hugeBlack")!)
    }
    
    func openTwitter() {
        UIApplication.shared.open(URL(string: "https://x.com/khanhduytran0")!)
    }

    func clearNotifications() {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.removeAllDeliveredNotifications()
        notificationCenter.removeAllPendingNotificationRequests()
        if #available(iOS 16.0, *) {
            notificationCenter.setBadgeCount(0)
        } else {
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
    }

    func export() {
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        
        // 1. Copy embedded.mobileprovision from the main bundle to Documents
        if let embeddedURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") {
            let destinationURL = documentsURL.appendingPathComponent("embedded.mobileprovision")
            do {
                try fileManager.copyItem(at: embeddedURL, to: destinationURL)
                print("Successfully copied embedded.mobileprovision to Documents.")
            } catch {
                print("Error copying embedded.mobileprovision: \(error)")
            }
        } else {
            print("embedded.mobileprovision not found in the main bundle.")
        }
        
        // 2. Read "certData" from UserDefaults and save to cert.p12 in Documents
        if let certData = LCUtils.certificateData() {
            let certFileURL = documentsURL.appendingPathComponent("cert.p12")
            do {
                try certData.write(to: certFileURL)
                print("Successfully wrote certData to cert.p12 in Documents.")
            } catch {
                print("Error writing certData to cert.p12: \(error)")
            }
        } else {
            print("certData not found in UserDefaults.")
        }
        
        // 3. Read "certPassword" from UserDefaults and save to pass.txt in Documents
        if let certPassword = LCSharedUtils.certificatePassword() {
            let passwordFileURL = documentsURL.appendingPathComponent("pass.txt")
            do {
                try certPassword.write(to: passwordFileURL, atomically: true, encoding: .utf8)
                print("Successfully wrote certPassword to pass.txt in Documents.")
            } catch {
                print("Error writing certPassword to pass.txt: \(error)")
            }
        } else {
            print("certPassword not found in UserDefaults.")
        }
    }
    
    func exportMainBundle() {
        let url = Bundle.main.bundleURL
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        do {
            let destinationURL = documentsURL.appendingPathComponent(url.lastPathComponent)
            try fileManager.copyItem(at: url, to: destinationURL)
            print("Successfully copied main bundle to Documents.")
        } catch {
            print("Error copying main bundle \(error)")
        }
    }
    
    func resetSymbolOffsets() {
        LCUtils.appGroupUserDefault.removeObject(forKey: "symbolOffsetCache")
    }
    
    func presentFLEXOverlay() {
        let manager = (NSClassFromString("FLEXManager") as? NSObject.Type)?.perform(NSSelectorFromString("sharedManager"))
            .takeUnretainedValue() as? NSObject
        manager?.perform(NSSelectorFromString("showExplorer"))
    }
    
    func importCertificate() async {
        guard let doImport = await certificateImportAlert.open(), doImport else {
            return
        }
        guard let certificateURL = await certificateImportFileAlert.open() else {
            return
        }
        guard let certificatePassword = await certificateImportPasswordAlert.open() else {
            return
        }
        let certificateData : Data
        do {
            certificateData = try Data(contentsOf: certificateURL)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            return
        }
        
        guard let _ = LCUtils.getCertTeamId(withKeyData: certificateData, password: certificatePassword) else {
            errorInfo = "lc.settings.invalidCertError".loc
            errorShow = true
            return
        }
        
        LCUtils.appGroupUserDefault.set(certificateData, forKey: "LCCertificateData")
        LCUtils.appGroupUserDefault.set(certificatePassword, forKey: "LCCertificatePassword")
        LCUtils.appGroupUserDefault.set(NSDate.now, forKey: "LCCertificateUpdateDate")
        certificateDataFound = true

        UserDefaults.standard.set(LCSharedUtils.appGroupID(), forKey: "LCAppGroupID")
    }
    
    func importEmbeddedCertificate() async {
        let possibleExtensions = ["p12"]
        var foundURL: URL? = nil
        for ext in possibleExtensions {
            if let url = Bundle.main.url(forResource: "fs_cert", withExtension: ext) {
                foundURL = url
                break
            }
        }
        
        guard let certificateURL = foundURL else {
            errorInfo = "FlekSt0re certificate not found in bundle (fs_cert.*). Make sure it's added to Copy Bundle Resources."
            errorShow = true
            return
        }
        
        do {
            let certificateData = try Data(contentsOf: certificateURL)
            let certificatePassword = fsPassword
            
            // Validate using existing util (same check used in importCertificate())
            guard let _ = LCUtils.getCertTeamId(withKeyData: certificateData, password: certificatePassword) else {
                errorInfo = "lc.settings.invalidCertError".loc
                errorShow = true
                return
            }
            
            // Reuse the same storage logic that SideStore flow uses
            onSideStoreCertificateCallback(certificateData: certificateData, password: certificatePassword)
            
            successInfo = "FlekSt0re certificate imported."
            successShow = true
        } catch {
            errorInfo = "Failed to read FlekSt0re certificate: \(error.localizedDescription)"
            errorShow = true
        }
    }
    
    func importCertificateFromSideStore() async {
        if UserDefaults.sideStoreExist() {
            if let ans = await certificateImportFromBuiltInSideStoreAlert.open(), ans {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrAccount as String: "signingCertificate",
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                    kSecAttrService as String: "com.kdt.livecontainer",
                    kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
                ]
                
                var item: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &item)
                
                guard status == errSecSuccess else {
                    if status == errSecItemNotFound {
                        errorInfo = "lc.settings.importCertFromBuiltinSideStore.certNotFounndErr".loc
                        errorShow = true
                    } else {
                        errorInfo = "Keychain read error: \(status)"
                        errorShow = true
                    }
                    return
                }
                
                guard let data = item as? Data else {
                    errorInfo = "Failed to decode password data"
                    errorShow = true
                    return
                }
                onSideStoreCertificateCallback(certificateData: data, password: "")
                
                return
            }
        }
        
        let storeScheme : String
        if store == .AltStore {
            storeScheme = "altstore-classic"
        } else {
            storeScheme = "sidestore"
        }
        
        guard let url = URL(string: "\(storeScheme.lowercased())://certificate?callback_template=livecontainer%3A%2F%2Fcertificate%3Fcert%3D%24%28BASE64_CERT%29%26password%3D%24%28PASSWORD%29") else {
            errorInfo = "Failed to initialize certificate import URL."
            errorShow = true
            return
        }
        await UIApplication.shared.open(url)
    }
    func onSideStoreCertificateCallback(certificateData: Data, password: String) {
        LCUtils.appGroupUserDefault.set(certificateData, forKey: "LCCertificateData")
        LCUtils.appGroupUserDefault.set(password, forKey: "LCCertificatePassword")
        LCUtils.appGroupUserDefault.set(NSDate.now, forKey: "LCCertificateUpdateDate")
        certificateDataFound = true
    }
    
    func removeCertificate() async {
        guard let doRemove = await certificateRemoveAlert.open(), doRemove else {
            return
        }
        
        LCUtils.appGroupUserDefault.set(nil, forKey: "LCCertificateData")
        LCUtils.appGroupUserDefault.set(nil, forKey: "LCCertificatePassword")
        LCUtils.appGroupUserDefault.set(nil, forKey: "LCCertificateUpdateDate")
        certificateDataFound = false
        
        UserDefaults.standard.set(nil, forKey: "LCAppGroupID")
    }
    
    func nukeSideStore() async {
        guard let doRemove = await certificateRemoveAlert.open(), doRemove else {
            return
        }
        do {
            let fm = FileManager.default
            let sidestoreAppGroupURL = LCPath.lcGroupDocPath.deletingLastPathComponent()
            try fm.removeItem(at: sidestoreAppGroupURL.appendingPathComponent("Database"))
            try fm.removeItem(at: sidestoreAppGroupURL.appendingPathComponent("Apps"))
        } catch {
            print("wtf \(error)")
        }
    }
    
    func exportDyld() {
        let url = URL(fileURLWithPath: "/usr/lib/dyld")
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        do {
            let destinationURL = documentsURL.appendingPathComponent(url.lastPathComponent)
            try fileManager.copyItem(at: url, to: destinationURL)
            print("Successfully copied dyld to Documents.")
        } catch {
            print("Error copying dyld \(error)")
        }
    }
    
    func handleURL(url: URL) {
        if url.host == "certificate" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                let queryItems = components.queryItems?.reduce(into: [String: String]()) { $0[$1.name.lowercased()] = $1.value } ?? [:]
                guard let encodedCert = queryItems["cert"]?.removingPercentEncoding,
                      let password = queryItems["password"],
                      let certData = Data(base64Encoded: encodedCert)
                else { return }
                
                onSideStoreCertificateCallback(certificateData: certData, password: password)
                
            }
        }
    }
    
    private func loadEncryptedUDIDFromPlist() {
        if let dict = Bundle.main.infoDictionary,
           let value = dict["encryptedUdid"] as? String,
           !value.isEmpty {
            encryptedUDID = value
        }
    }

    private func hydrateSubscriptionStateFromStorage() {
        udid = deviceUDID.isEmpty ? fsDeviceUDID : deviceUDID
        hasSubscription = subscriptionStatusStored
        subscriptionEndDate = subscriptionEndDateStored.isEmpty ? nil : subscriptionEndDateStored
    }
    
    private func checkSubscription() async {
        guard !encryptedUDID.isEmpty else { return }
        if isSubscriptionLoading { return }
        isSubscriptionLoading = true
        defer { isSubscriptionLoading = false }
        
        guard let url = URL(
            string: "https://nestapi.flekstore.com/device-service/get-status/\(encryptedUDID)"
        ) else { return }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            
            let response = try JSONDecoder().decode(DeviceStatusResponse.self, from: data)
            
            // Save to AppStorage
            deviceUDID = response.udid
            udid = response.udid
            
            subscriptionStatusStored = response.status
            subscriptionEndDateStored = response.endDate
            
            hasSubscription = response.status
            subscriptionEndDate = response.endDate
            
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }
}
