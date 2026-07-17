//
//  FlekInstallerView.swift
//  LiveContainerSwiftUI
//
//  Redesigned Installer (reimagining of LiveContainer's Catalog). Reuses the
//  existing FlekstoreAppsListViewModel for fetching/paging/categories and the
//  saved-repositories store; only the UI is new:
//   - a horizontal source carousel (Telegram-style) + a "manage sources" button
//   - a category switcher (FlekSt0re source only)
//   - app rows with a download button
//   - a bottom bar with Import IPA, a back-to-home chevron, and search
//
//  Installs are triggered through LCInstallQueue.shared so multiple downloads
//  can run concurrently while installs run serially.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Kingfisher

struct FlekInstallerView: View {
    var preselectFlekstore: Bool
    var preselectRepoURL: String? = nil
    var onClose: () -> Void

    @EnvironmentObject private var sharedModel: SharedModel
    @ObservedObject private var installQueue = LCInstallQueue.shared
    @StateObject private var viewModel = FlekstoreAppsListViewModel()
    @StateObject private var repoSearch = MultiRepoSearchModel()

    @State private var repos: [AppRepository] = []
    @State private var selectedRepoID: UUID?
    @State private var showSources = false
    @State private var showPremium = false
    @State private var searchActive = false
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var importURLInput = false
    @FocusState private var searchFocused: Bool
    @StateObject private var importUrlHelper = InputHelper()
    @State private var choosingIPA = false
    @State private var switcherBarVisible = true
    @State private var barIsLandscape = false
    /// Bumped to (re)center the selected repo in the pill after the sources
    /// sheet is dismissed, so the shift animation plays once it's visible.
    @State private var pillRecenterNonce = 0
    /// Measured width of the manage-sources button, used to end the carousel
    /// exactly at the button's leading edge (so repos can't scroll under it).
    @State private var manageButtonWidth: CGFloat = 0

    /// The bottom bar/blur only need to make room when the switcher bar actually
    /// sits along the bottom edge — i.e. portrait. In landscape the bar is on the
    /// right edge, so bottom content stays pinned to the bottom edge.
    private var barOccupiesBottom: Bool { switcherBarVisible && !barIsLandscape }

    /// Repo selected during this app session. A static resets on process
    /// relaunch, so the installer defaults back to FlekSt0re after an app
    /// restart while still remembering the choice within a session.
    private static var sessionSelectedRepoURL: String?

    private static let flekBlue = Color(red: 0/255, green: 117/255, blue: 255/255)
    private static let screenBG = Color(.systemGroupedBackground)

    var body: some View {
        ZStack {
            Self.screenBG.ignoresSafeArea()

            // App list fills the whole area and scrolls *behind* the bars,
            // which float on top with transparent backgrounds.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Top-edge blur: sits above the list but below the bars so the
            // content fades out as it scrolls up under the pill/category bar.
            topEdgeBlur

            VStack(spacing: 0) {
                // Hide the top bars while searching by fading them out rather than
                // removing them from the hierarchy. Structurally tearing down the
                // source carousel's ScrollViewReader at the same moment the search
                // field takes focus was dropping the keyboard's first responder, so
                // typed text never registered. Kept mounted + non-interactive, the
                // focus stays put.
                Group {
                    sourceCarousel
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                    if viewModel.repository == .flekstore {
                        categoryBar.padding(.top, 8)
                    }
                }
                .opacity(searchActive ? 0 : 1)
                .allowsHitTesting(!searchActive)

                Spacer(minLength: 0)
            }
            .overlay(alignment: .bottom) {
                if !searchActive {
                    // Real progressive blur behind the bottom bar (same CAFilter variable blur as the top edge):
                    // clear at the top, ramping to full blur at the bottom. Sized
                    // so its top edge sits ~30pt above the Import IPA / search
                    // buttons (48pt button + 12pt bottom padding + 30pt, past the
                    // safe area).
                    GeometryReader { geo in
                        VariableBlurView(maxBlurRadius: 12, direction: .bottom)
                            .frame(height: geo.safeAreaInsets.bottom + 96)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .ignoresSafeArea(edges: .bottom)
                            .offset(y: barOccupiesBottom ? 0 : 52)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                bottomBar
                    .padding(.horizontal, 10)
                    // -18 (not -20) leaves a 2pt margin above the bottom edge for
                    // the buttons; the blur keeps its own separate offset.
                    .padding(.bottom, barOccupiesBottom ? 12 : -18)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .multitaskBarVisibilityChanged)) { _ in
            updateSwitcherBarState()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            updateSwitcherBarState()
        }
        .onAppear {
            updateSwitcherBarState()
        }
        .task {
            repoSearch.setup()
            repos = Self.loadRepos()
            if let repoURL = preselectRepoURL, let match = repos.first(where: { $0.sourceURL == repoURL }) {
                selectedRepoID = match.id
                viewModel.repository = Self.source(for: match)
            } else if preselectFlekstore, let flek = repos.first(where: { Self.isFlekstore($0) }) {
                selectedRepoID = flek.id
                viewModel.repository = .flekstore
            } else if let sessionURL = Self.sessionSelectedRepoURL,
                      let match = repos.first(where: { $0.sourceURL == sessionURL }) {
                // Remember the pick within this app session only.
                selectedRepoID = match.id
                viewModel.repository = Self.source(for: match)
            } else if let flek = repos.first(where: { Self.isFlekstore($0) }) {
                // Fresh launch (or nothing to restore): default to FlekSt0re.
                selectedRepoID = flek.id
                viewModel.repository = .flekstore
            } else {
                viewModel.repository = .flekstore
            }
            await viewModel.refreshSubscriptionStatus()
            await viewModel.resetAndFetchApps()
            Task { await MultiRepoSearchModel.prefetchAllRepos() }
        }
        .sheet(isPresented: $showSources, onDismiss: {
            // AppRepository.id is a fresh UUID on every decode, so reloading
            // from disk renumbers the repos. Re-anchor the selection on the
            // stable sourceURL so the pill highlight survives the reload.
            let selectedURL = repos.first(where: { $0.id == selectedRepoID })?.sourceURL
            repos = Self.loadRepos()
            if let selectedURL, let match = repos.first(where: { $0.sourceURL == selectedURL }) {
                selectedRepoID = match.id
            }
            // Let the sheet finish dismissing and repos reload before scrolling
            // so the centering animation is actually visible in the pill.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                pillRecenterNonce += 1
            }
        }) {
            FlekSourcesPopup(repos: $repos) { repo in
                selectedRepoID = repo.id
                Task { await switchTo(repo) }
            }
        }
        .sheet(isPresented: $showPremium) {
            PremiumRequiredView()
        }
        .betterFileImporter(isPresented: $choosingIPA, types: [.ipa, .tipa], multiple: false, callback: { urls in
            if let u = urls.first {
                LCInstallQueue.shared.enqueue(url: u.absoluteString, name: nil, iconURL: nil)
            }
        }, onDismiss: { choosingIPA = false })
        .textFieldAlert(
            isPresented: $importUrlHelper.show,
            title: "lc.appList.installUrlInputTip".loc,
            text: $importUrlHelper.initVal,
            placeholder: "https://",
            action: { newText in
                importUrlHelper.close(result: newText)
                if let t = newText, !t.isEmpty {
                    LCInstallQueue.shared.enqueue(url: t, name: nil, iconURL: nil)
                }
            },
            actionCancel: { _ in importUrlHelper.close(result: nil) }
        )
    }

    /// Distance from the top safe-area edge down to the bottom of the floating
    /// bars (source pill + category bar when shown).
    private var barsBottomInset: CGFloat {
        // During search both floating top bars (source pill + category bar) are
        // hidden, so reserve only a small top margin for the results list.
        guard !searchActive else { return 8 }
        var inset: CGFloat = 8 + 52          // pill top padding + pill height
        if viewModel.repository == .flekstore {
            inset += 8 + 44                  // category bar top padding + height
        }
        return inset
    }

    /// Height reserved at the top so the first list row starts just below the
    /// floating bars, which overlay the scrolling list instead of pushing it down.
    private var barsTopInset: CGFloat { barsBottomInset + 10 }

    /// Progressive blur from the very top edge of the screen (through the safe
    /// area) down to the bottom of the category bar — strongest at the top,
    /// easing to clear for an organic falloff. Material + gradient-alpha mask
    /// (the pre-iOS-26 native approach, matching the bottom blur in this view).
    /// iOS 26 could instead use `scrollEdgeEffectStyle(.soft, for: .top)`.
    private var topEdgeBlur: some View {
        GeometryReader { geo in
            let total = max(geo.safeAreaInsets.top + barsBottomInset + 50, 1)
            // Real progressive blur: radius ramps from strong at the top edge to
            // none ~50pt below the bottom of the category bar.
            VariableBlurView(maxBlurRadius: 20, direction: .top)
                .frame(height: total)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(edges: .top)
        }
        .allowsHitTesting(false)
    }

    // MARK: Source carousel

    private var sourceCarousel: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(repos) { repo in
                            let selected = repo.id == selectedRepoID
                            Button {
                                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                                    selectedRepoID = repo.id
                                }
                                Task { await switchTo(repo) }
                            } label: {
                                HStack(spacing: 10) {
                                    FlekRemoteIcon(url: repo.iconUrl, size: 30, corner: 10)
                                    Text(repo.name)
                                        .font(.system(size: 15, weight: .medium))
                                        .tracking(-0.23)
                                        .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.9))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .repoChipSelection(selected)
                            }
                            .buttonStyle(.plain)
                            .id(repo.id)
                        }
                    }
                    .padding(4)
                }
                // End the scrollable area at the button's leading edge, so repos
                // stop right before the button instead of scrolling under it.
                .padding(.trailing, manageButtonWidth)

                // Progressive blur behind the manage-sources button: the same
                // variable blur used on the installer's top/bottom edges, here
                // horizontal — strongest at the right edge, fading to clear on the
                // left. Sits above the scrolling carousel but below the icon.
                VariableBlurView(maxBlurRadius: 9, direction: .trailing)
                    .frame(width: 64, height: 52)
                    .allowsHitTesting(false)

                // Manage-sources icon pinned to the right, sitting on the blur
                // (no opaque background) so the carousel frosts out beneath it.
                Button {
                    showSources = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.7))
                        // Smaller left margin, original right margin / full height.
                        .padding(.leading, 6)
                        .padding(.trailing, 14)
                        .frame(height: 52)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Measure the button's width (invisibly) so the carousel can inset
                // its trailing edge by exactly this much.
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ManageButtonWidthKey.self, value: geo.size.width)
                    }
                )
            }
            .frame(height: 52)
            .onPreferenceChange(ManageButtonWidthKey.self) { manageButtonWidth = $0 }
            .repoPillGlass()
            .shadow(color: .black.opacity(0.08), radius: 16, y: 4)
            .shadow(color: .black.opacity(0.15), radius: 4, y: 1)  // tighter contact shadow for contrast over the blur
            // Center the tapped repo (skip while the sources sheet is open so the
            // move plays *after* dismissal instead of behind the sheet).
            .onChange(of: selectedRepoID) { id in
                guard let id, !showSources else { return }
                centerSelectedRepo(id, proxy: proxy)
            }
            // Fired after the sources sheet closes: replay the shift for a repo
            // chosen from the manage-sources menu.
            .onChange(of: pillRecenterNonce) { _ in
                guard let id = selectedRepoID else { return }
                centerSelectedRepo(id, proxy: proxy)
            }
        }
    }

    private func centerSelectedRepo(_ id: UUID, proxy: ScrollViewProxy) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    // MARK: Category bar

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                categoryPill("Updates", selected: viewModel.selectedCategoryID == nil) { viewModel.selectCategory(nil) }
                categoryPill("Top", selected: viewModel.selectedCategoryID == "downloads") { viewModel.selectCategory("downloads") }
                ForEach(viewModel.categories) { cat in
                    categoryPill(cat.name, selected: viewModel.selectedCategoryID == cat.id) { viewModel.selectCategory(cat.id) }
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 44)
        .scrollClipDisabledIfAvailable()  // let each pill's shadow draw past the 44pt scroll bounds (no bottom cutout)
    }

    private func categoryPill(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? .white : .primary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(
                    Capsule().fill(selected ? Self.flekBlue : Color(.secondarySystemGroupedBackground))
                        .shadow(color: .black.opacity(0.10), radius: 3, y: 1)  // subtle per-pill contact shadow (kept tight so neighbours don't bleed)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isBanned {
            AccessBlockedView(reason: viewModel.banReason, message: viewModel.banMessage)
                .frame(maxHeight: .infinity)
        } else if searchActive {
            searchContent
        } else if viewModel.apps.isEmpty && viewModel.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = viewModel.errorMessage, viewModel.apps.isEmpty {
            VStack(spacing: 12) {
                Text(error).foregroundColor(.red).multilineTextAlignment(.center)
                Button("Retry") { Task { await viewModel.resetAndFetchApps() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.visibleApps) { app in
                        FlekInstallerRow(
                            app: app,
                            accent: Self.flekBlue,
                            installState: LCInstallQueue.shared.item(for: app.install_url)?.installState,
                            isCompleted: LCInstallQueue.shared.completedURLs.contains(app.install_url),
                            onInstall: { install(app) },
                            onCancel: {
                                LCInstallQueue.shared.cancel(url: app.install_url)
                            }
                        )
                        .onAppear {
                            if app.id == viewModel.visibleApps.last?.id {
                                Task { await viewModel.fetchApps() }
                            }
                        }
                    }
                    if viewModel.isLoading && !viewModel.apps.isEmpty {
                        ProgressView().padding()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, barsTopInset)
                .padding(.bottom, 80)
            }
            .refreshable { await viewModel.resetAndFetchApps() }
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        if viewModel.searchQuery.isEmpty {
            Spacer()
        } else if repoSearch.sections.isEmpty && !repoSearch.isLoading {
            VStack(spacing: 12) {
                Image(systemName: "app.grid")
                    .font(.system(size: 56, weight: .thin))
                    .foregroundStyle(Color(.systemGray3))
                Text("Nothing found")
                    .font(.system(size: 20))
                    .foregroundStyle(Color(.label))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(repoSearch.sections) { repoSection in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                FlekRemoteIcon(url: repoSection.iconUrl, size: 20, corner: 4)
                                Text(repoSection.name)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.primary)
                            }
                            .padding(.horizontal, 4)

                            ForEach(repoSection.apps) { app in
                                FlekInstallerRow(
                                    app: app,
                                    accent: Self.flekBlue,
                                    installState: LCInstallQueue.shared.item(for: app.install_url)?.installState,
                                    isCompleted: LCInstallQueue.shared.completedURLs.contains(app.install_url),
                                    onInstall: { installSearchResult(app, fromFlekstore: repoSection.isFlekstore) },
                                    onCancel: {
                                        LCInstallQueue.shared.cancel(url: app.install_url)
                                    }
                                )
                            }
                        }
                    }
                    if repoSearch.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, barsTopInset)
                .padding(.bottom, 80)
            }
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        Group {
            if searchActive {
                searchBar
            } else {
                defaultBottomBar
            }
        }
        .animation(.easeInOut(duration: 0.25), value: searchActive)
    }

    private var defaultBottomBar: some View {
        HStack(spacing: 12) {
            Menu {
                Button {
                    choosingIPA = true
                } label: {
                    Label("lc.appList.installFromIpa".loc, systemImage: "doc.badge.plus")
                }
                Button {
                    Task { _ = await importUrlHelper.open() }
                } label: {
                    Label("lc.appList.installFromUrl".loc, systemImage: "link.badge.plus")
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 16, weight: .medium))
                    Text("lc.flek.importIpa".loc)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                }
                .foregroundStyle(Color(.label))
                .padding(.horizontal, 16)
                .frame(height: 48)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(Capsule().fill(Color(.systemBackground).opacity(0.5)))
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.08), radius: 16, y: 4)
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 1)  // tighter contact shadow for contrast over the blur
                )
            }

            Spacer()

            Button {
                withAnimation { searchActive = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { searchFocused = true }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.7))
                    .frame(width: 50, height: 50)
                    .background(
                        Circle()
                            .fill(.ultraThinMaterial)
                            .overlay(Circle().fill(Color(.systemBackground).opacity(0.5)))
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.08), radius: 16, y: 4)
                            .shadow(color: .black.opacity(0.15), radius: 4, y: 1)  // tighter contact shadow for contrast over the blur
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            // Search pill
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20))
                    .foregroundStyle(Color(.systemGray))

                TextField("lc.flek.search".loc, text: $viewModel.searchQuery)
                    .font(.system(size: 17))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($searchFocused)
                    .onChange(of: viewModel.searchQuery) { q in
                        searchDebounceTask?.cancel()
                        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            repoSearch.cancelSearch()
                            return
                        }
                        searchDebounceTask = Task {
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            guard !Task.isCancelled else { return }
                            repoSearch.search(trimmed)
                        }
                    }

                if !viewModel.searchQuery.isEmpty {
                    Button {
                        viewModel.searchQuery = ""
                        Task { await viewModel.resetAndFetchApps() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 19))
                            .foregroundStyle(Color(.systemGray))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().fill(Color(.systemBackground).opacity(0.5)))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.08), radius: 16, y: 4)
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 1)  // tighter contact shadow for contrast over the blur
            )

            // Close button — separate circle to the right
            Button {
                withAnimation {
                    searchFocused = false
                    searchActive = false
                    viewModel.searchQuery = ""
                    Task { await viewModel.resetAndFetchApps() }
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(.primary.opacity(0.7))
                    .frame(width: 48, height: 48)
                    .background(
                        Circle()
                            .fill(.ultraThinMaterial)
                            .overlay(Circle().fill(Color(.systemBackground).opacity(0.5)))
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.08), radius: 16, y: 4)
                            .shadow(color: .black.opacity(0.15), radius: 4, y: 1)  // tighter contact shadow for contrast over the blur
                    )
            }
            .buttonStyle(.plain)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
    }



    // MARK: Actions

    private func install(_ app: FSAppModel) {
        if viewModel.repository != .flekstore && !viewModel.hasSubscription {
            showPremium = true
            return
        }
        LCInstallQueue.shared.enqueue(
            url: app.install_url,
            name: app.app_name,
            iconURL: app.app_icon
        )
        if viewModel.repository == .flekstore {
            FlekstoreAppsListViewModel.recordDownload(appId: app.app_id)
        }
    }

    private func installSearchResult(_ app: FSAppModel, fromFlekstore: Bool) {
        if !fromFlekstore && !viewModel.hasSubscription {
            showPremium = true
            return
        }
        LCInstallQueue.shared.enqueue(
            url: app.install_url,
            name: app.app_name,
            iconURL: app.app_icon
        )
        if fromFlekstore {
            FlekstoreAppsListViewModel.recordDownload(appId: app.app_id)
        }
    }

    private func switchTo(_ repo: AppRepository) async {
        searchActive = false
        searchFocused = false
        let source = Self.source(for: repo)
        Self.sessionSelectedRepoURL = repo.sourceURL
        // Custom repos are pre-fetched to disk; show that cache instantly and
        // refresh in the background instead of flashing an empty loading state.
        var disk: [FSAppModel]? = nil
        if case .custom(let url) = source {
            disk = RepoCatalogCache.shared.cachedApps(for: url)
        }
        await viewModel.switchRepository(to: source, diskPreloaded: disk)
    }

    private func updateSwitcherBarState() {
        // Read the interface orientation directly so it is always current — the
        // dock manager's cached flag only updates while the bar is visible and
        // can be stale when the page first opens in landscape.
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? (UIApplication.shared.connectedScenes.first as? UIWindowScene) {
            barIsLandscape = scene.interfaceOrientation.isLandscape
        }
        if #available(iOS 16.0, *) {
            let mgr = MultitaskDockManager.shared
            // Only override the default when the dock is actually set up;
            // keeps the safe default (true → 12pt padding) during setup.
            guard mgr.isVisible else { return }
            switcherBarVisible = mgr.isSwitcherBarVisible
        }
    }

    // MARK: Repo helpers

    static func isFlekstore(_ repo: AppRepository) -> Bool {
        repo.sourceURL == "Default app catalog" || repo.name.localizedCaseInsensitiveContains("FlekSt0re")
    }

    static func source(for repo: AppRepository) -> FlekstoreAppsListViewModel.RepositorySource {
        isFlekstore(repo) ? .flekstore : .custom(url: repo.sourceURL)
    }

    static func loadRepos() -> [AppRepository] {
        guard let data = UserDefaults.standard.data(forKey: "savedRepositories"),
              let decoded = try? JSONDecoder().decode([AppRepository].self, from: data) else {
            return []
        }
        return decoded
    }
}

/// Reports the manage-sources button's measured width up to the carousel.
private struct ManageButtonWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension View {
    /// iOS 17+: let content (e.g. pill shadows) draw outside the scroll view's
    /// bounds instead of being clipped. No-op below iOS 17 (shadow stays clipped).
    @ViewBuilder
    func scrollClipDisabledIfAvailable() -> some View {
        if #available(iOS 17.0, *) { self.scrollClipDisabled() } else { self }
    }

    /// The source pill surface: native Liquid Glass on iOS 26+, and a frosted
    /// white material capsule (matching the FlekSign design) on older versions.
    @ViewBuilder
    func repoPillGlass() -> some View {
        if #available(iOS 26, *) {
            self
                .clipShape(Capsule())
                .glassEffect(.regular, in: Capsule())
        } else {
            self
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(Capsule().fill(Color.white.opacity(0.5)))
                )
                .clipShape(Capsule())
        }
    }

    /// The selected repo chip: a native Liquid Glass thumb on iOS 26+, and the
    /// FlekSign #EDEDED capsule on older versions. Unselected repos are clear.
    @ViewBuilder
    func repoChipSelection(_ selected: Bool) -> some View {
        if #available(iOS 26, *) {
            if selected {
                // Subtle grey tint so the selected thumb reads against the glass pill.
                self.glassEffect(.regular.tint(Color.gray.opacity(0.3)), in: Capsule())
            } else {
                self
            }
        } else {
            self.background(
                Capsule().fill(selected ? Color(red: 0.929, green: 0.929, blue: 0.929) : Color.clear)
            )
        }
    }
}

/// App row in the installer: icon, name, version·bundle, description, download.
/// While installing, the app icon shows a dimmed overlay with progress (same as
/// the springboard). A checkmark overlay appears on the icon when done.
struct FlekInstallerRow: View {
    let app: FSAppModel
    let accent: Color
    var installState: FlekInstallState? = nil
    var isCompleted: Bool = false
    var onInstall: () -> Void
    var onCancel: () -> Void = {}

    @State private var showCheckmark = false

    var body: some View {
        HStack(spacing: 8) {
            // Icon — shows progress overlay when installing
            if let installState {
                FlekInstallIcon(state: installState, size: 74, corner: 17)
            } else {
                FlekRemoteIcon(url: app.app_icon, size: 74, corner: 17)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(app.app_name).font(.system(size: 18, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                Text(app.app_version).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
                if !app.app_short_description.isEmpty {
                    Text(app.app_short_description).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if installState != nil {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else if showCheckmark {
                FlekRowCheckmark(accent: accent)
            } else {
                Button(action: onInstall) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 8).padding(.trailing, 14).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        .onChange(of: isCompleted) { completed in
            if completed {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                    showCheckmark = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation { showCheckmark = false }
                }
            }
        }
    }
}

/// Animated checkmark shown briefly after a successful install.
struct FlekRowCheckmark: View {
    let accent: Color
    @State private var trimEnd: CGFloat = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.green)
            CheckmarkShape()
                .trim(from: 0, to: trimEnd)
                .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .padding(8)
        }
        .frame(width: 30, height: 30)
        .onAppear {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeOut(duration: 0.35).delay(0.1)) {
                trimEnd = 1
            }
        }
    }
}

/// A checkmark shape for stroke animation.
private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        path.move(to: CGPoint(x: w * 0.2, y: h * 0.5))
        path.addLine(to: CGPoint(x: w * 0.42, y: h * 0.72))
        path.addLine(to: CGPoint(x: w * 0.8, y: h * 0.28))
        return path
    }
}

/// Async remote icon with a placeholder. Uses Kingfisher (already a project
/// dependency) so icons are cached in memory + on disk and keyed by URL. A
/// cached icon renders on the first frame — no placeholder flash — even when
/// the hosting row is torn down and rebuilt (e.g. after the repo list is
/// re-decoded and every repo gets a new identity).
struct FlekRemoteIcon: View {
    let url: String
    var size: CGFloat
    var corner: CGFloat

    var body: some View {
        KFImage(URL(string: url))
            .placeholder {
                RoundedRectangle(cornerRadius: corner, style: .continuous).fill(Color(.systemGray5))
            }
            .cacheOriginalImage()
            .fade(duration: 0.15)   // only animates on a network load, not on a cache hit
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}
