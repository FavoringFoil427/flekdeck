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
//  Installs are triggered through sharedModel.urlToInstall so they run on the
//  home engine (and keep running) even while the Installer cover is shown.
//

import SwiftUI
import UniformTypeIdentifiers

struct FlekInstallerView: View {
    var preselectFlekstore: Bool
    var onClose: () -> Void

    @EnvironmentObject private var sharedModel: SharedModel
    @StateObject private var viewModel = FlekstoreAppsListViewModel()

    @State private var repos: [AppRepository] = []
    @State private var selectedRepoID: UUID?
    @State private var showSources = false
    @State private var showPremium = false
    @State private var searchActive = false
    @State private var importURLInput = false
    @FocusState private var searchFocused: Bool
    @StateObject private var importUrlHelper = InputHelper()
    @State private var choosingIPA = false

    private static let flekBlue = Color(red: 0/255, green: 117/255, blue: 255/255)
    private static let screenBG = Color(.systemGroupedBackground)

    var body: some View {
        ZStack {
            Self.screenBG.ignoresSafeArea()

            VStack(spacing: 0) {
                sourceCarousel
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                if viewModel.repository == .flekstore && !searchActive {
                    categoryBar.padding(.top, 8)
                }

                content
            }
            .overlay(alignment: .bottom) {
                bottomBar
                    .padding(.horizontal, 25)
                    .padding(.bottom, 12)
            }
        }
        .task {
            repos = Self.loadRepos()
            if preselectFlekstore, let flek = repos.first(where: { Self.isFlekstore($0) }) {
                selectedRepoID = flek.id
                viewModel.repository = .flekstore
            } else if let selected = repos.first(where: { $0.isSelected }) {
                selectedRepoID = selected.id
                viewModel.repository = Self.source(for: selected)
            } else {
                viewModel.repository = .flekstore
            }
            await viewModel.refreshSubscriptionStatus()
            await viewModel.resetAndFetchApps()
        }
        .sheet(isPresented: $showSources, onDismiss: { repos = Self.loadRepos() }) {
            FlekSourcesPopup(repos: $repos) { repo in
                selectedRepoID = repo.id
                Task { await switchTo(repo) }
            }
        }
        .sheet(isPresented: $showPremium) {
            PremiumRequiredView()
        }
        .betterFileImporter(isPresented: $choosingIPA, types: [.ipa, .tipa], multiple: false, callback: { urls in
            if let u = urls.first { sharedModel.urlToInstall = u.absoluteString }
        }, onDismiss: { choosingIPA = false })
        .textFieldAlert(
            isPresented: $importUrlHelper.show,
            title: "lc.appList.installUrlInputTip".loc,
            text: $importUrlHelper.initVal,
            placeholder: "https://",
            action: { newText in
                importUrlHelper.close(result: newText)
                if let t = newText, !t.isEmpty { sharedModel.urlToInstall = t }
            },
            actionCancel: { _ in importUrlHelper.close(result: nil) }
        )
    }

    // MARK: Source carousel

    private var sourceCarousel: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(repos) { repo in
                        let selected = repo.id == selectedRepoID
                        Button {
                            selectedRepoID = repo.id
                            Task { await switchTo(repo) }
                        } label: {
                            HStack(spacing: 8) {
                                FlekRemoteIcon(url: repo.iconUrl, size: 30, corner: 8)
                                Text(repo.name)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(
                                Capsule().fill(selected ? Color(.systemGray5) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
            }
            .frame(height: 52)
            .background(
                Capsule().fill(Color(.secondarySystemGroupedBackground))
                    .shadow(color: .black.opacity(0.12), radius: 20, y: 8)
            )

            Button {
                showSources = true
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.7))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
            }
            .buttonStyle(.plain)
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
    }

    private func categoryPill(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? .white : .primary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(selected ? Self.flekBlue : Color(.secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isBanned {
            AccessBlockedView(reason: viewModel.banReason, message: viewModel.banMessage)
                .frame(maxHeight: .infinity)
        } else if viewModel.apps.isEmpty && viewModel.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = viewModel.errorMessage, viewModel.apps.isEmpty {
            VStack(spacing: 12) {
                Text(error).foregroundColor(.red).multilineTextAlignment(.center)
                Button("Retry") { Task { await viewModel.resetAndFetchApps() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if viewModel.visibleApps.isEmpty && searchActive && !viewModel.searchQuery.isEmpty && !viewModel.isLoading {
            VStack(spacing: 12) {
                Image(systemName: "square.dashed")
                    .font(.system(size: 56))
                    .foregroundStyle(Color(.systemGray3))
                Text("Nothing found")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color(.systemGray))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.visibleApps) { app in
                        FlekInstallerRow(
                            app: app,
                            accent: Self.flekBlue,
                            installState: sharedModel.installingURL == app.install_url
                                ? FlekInstallState(name: app.app_name, iconURL: app.app_icon,
                                                   fraction: sharedModel.installFraction,
                                                   indeterminate: sharedModel.installIndeterminate)
                                : nil,
                            onInstall: { install(app) },
                            onCancel: { sharedModel.cancelInstallRequested = true }
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
                .padding(.top, 10)
                .padding(.bottom, 80)
            }
            .refreshable { await viewModel.resetAndFetchApps() }
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
        HStack {
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
                    Text("lc.flek.importIpa".loc).font(.system(size: 16))
                }
                .foregroundStyle(.primary.opacity(0.75))
                .padding(12)
                .frame(height: 50)
                .background(Capsule().fill(Color(.secondarySystemGroupedBackground)).shadow(color: .black.opacity(0.25), radius: 20, y: 4))
            }

            Spacer()

            FlekGlassCircleButton(systemImage: "chevron.down", size: 44, iconScale: 0.42) {
                onClose()
            }

            Spacer()

            FlekGlassCircleButton(systemImage: "magnifyingglass", size: 50, iconScale: 0.5) {
                withAnimation { searchActive = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { searchFocused = true }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16))
                .foregroundStyle(Color(.systemGray))

            TextField("lc.flek.search".loc, text: $viewModel.searchQuery)
                .font(.system(size: 17))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($searchFocused)
                .onChange(of: viewModel.searchQuery) { q in
                    viewModel.debounceSearch(q)
                }

            if !viewModel.searchQuery.isEmpty {
                Button {
                    viewModel.searchQuery = ""
                    Task { await viewModel.resetAndFetchApps() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color(.systemGray))
                }
                .buttonStyle(.plain)
            }

            Button {
                withAnimation {
                    searchFocused = false
                    searchActive = false
                    viewModel.searchQuery = ""
                    Task { await viewModel.resetAndFetchApps() }
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.7))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color(.systemGray5)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(
            Capsule().fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.25), radius: 20, y: 4)
        )
        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
    }



    // MARK: Actions

    private func install(_ app: FSAppModel) {
        if viewModel.repository != .flekstore && !viewModel.hasSubscription {
            showPremium = true
            return
        }
        sharedModel.installingName = app.app_name
        sharedModel.installingIconURL = app.app_icon
        sharedModel.installingURL = app.install_url
        sharedModel.urlToInstall = app.install_url
        if viewModel.repository == .flekstore {
            FlekstoreAppsListViewModel.recordDownload(appId: app.app_id)
        }
    }

    private func switchTo(_ repo: AppRepository) async {
        viewModel.searchQuery = ""
        searchActive = false
        searchFocused = false
        viewModel.repository = Self.source(for: repo)
        await viewModel.resetAndFetchApps()
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

/// App row in the installer: icon, name, version·bundle, description, download.
/// While this app is installing, the download button is replaced by a circular
/// progress indicator (tap to cancel) — mirroring the home screen install state.
struct FlekInstallerRow: View {
    let app: FSAppModel
    let accent: Color
    var installState: FlekInstallState? = nil
    var onInstall: () -> Void
    var onCancel: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            FlekRemoteIcon(url: app.app_icon, size: 74, corner: 17)
            VStack(alignment: .leading, spacing: 6) {
                Text(app.app_name).font(.system(size: 18, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                Text(app.app_version).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
                if !app.app_short_description.isEmpty {
                    Text(app.app_short_description).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let installState {
                Button(action: onCancel) {
                    FlekRowProgress(state: installState, accent: accent)
                }
                .buttonStyle(.plain)
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
    }
}

/// Circular install progress shown in an installer row (determinate ring while
/// downloading, spinner during prepare/sign). Tapping it cancels.
struct FlekRowProgress: View {
    let state: FlekInstallState
    let accent: Color

    var body: some View {
        ZStack {
            if state.indeterminate {
                ProgressView().progressViewStyle(.circular)
            } else {
                Circle().stroke(accent.opacity(0.25), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(0.02, state.fraction))
                    .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(accent)
            }
        }
        .frame(width: 30, height: 30)
    }
}

/// Async remote icon with a placeholder.
struct FlekRemoteIcon: View {
    let url: String
    var size: CGFloat
    var corner: CGFloat

    var body: some View {
        AsyncImage(url: URL(string: url)) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                RoundedRectangle(cornerRadius: corner, style: .continuous).fill(Color(.systemGray5))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}
