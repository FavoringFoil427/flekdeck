//
//  FlekSearchView.swift
//  LiveContainerSwiftUI
//
//  Springboard search. Presented as an overlay over the (dimmed, blurred) home
//  screen: results fill from the top and the search field sits in a bottom bar
//  just above the keyboard, matching the FlekSign design. Searches installed
//  apps; per-source (Installer) results are added with the Installer rework.
//

import SwiftUI

struct FlekSearchView: View {
    @Binding var isPresented: Bool
    let apps: [LCAppModel]
    let darkModeIcon: Bool
    var onSelect: (LCAppModel) -> Void
    var onInstallStoreApp: (FSAppModel) -> Void = { _ in }

    @State private var query = ""
    @State private var debouncedQuery = ""
    @State private var debounceTask: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool
    @StateObject private var repoSearch = MultiRepoSearchModel()
    @Environment(\.colorScheme) private var colorScheme

    private var results: [LCAppModel] {
        guard !debouncedQuery.isEmpty else { return [] }
        return apps.filter { app in
            (app.appInfo.displayName()?.localizedCaseInsensitiveContains(debouncedQuery) ?? false) ||
            (app.appInfo.bundleIdentifier()?.localizedCaseInsensitiveContains(debouncedQuery) ?? false)
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(colorScheme == .dark ? 0.5 : 0.3).ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                resultsArea
                bottomBar
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        }
        .onAppear {
            fieldFocused = true
            repoSearch.setup()
            Task { await MultiRepoSearchModel.prefetchAllRepos() }
        }
        .onChange(of: query) { q in
            debounceTask?.cancel()
            let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                debouncedQuery = ""
                repoSearch.cancelSearch()
                return
            }
            debounceTask = Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                debouncedQuery = trimmed
                repoSearch.search(trimmed)
            }
        }
    }

    @ViewBuilder
    private var resultsArea: some View {
        if debouncedQuery.isEmpty {
            Spacer()
        } else if results.isEmpty && repoSearch.sections.isEmpty && !repoSearch.isLoading {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "app.grid")
                    .font(.system(size: 48, weight: .thin))
                    .foregroundStyle(Color.white.opacity(0.4))
                Text("lc.flek.noResults".loc)
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            Spacer()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !results.isEmpty {
                        section(title: "lc.flek.installed".loc) {
                            ForEach(results, id: \.self) { app in
                                Button {
                                    onSelect(app)
                                    close()
                                } label: {
                                    FlekSearchRow(app: app, darkModeIcon: darkModeIcon)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    ForEach(repoSearch.sections) { repoSection in
                        section(title: repoSection.name, iconUrl: repoSection.iconUrl) {
                            ForEach(repoSection.apps) { app in
                                Button {
                                    if repoSection.isFlekstore {
                                        FlekstoreAppsListViewModel.recordDownload(appId: app.app_id)
                                    }
                                    onInstallStoreApp(app)
                                    close()
                                } label: {
                                    FlekStoreSearchRow(app: app)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if repoSearch.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 80)
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, iconUrl: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let iconUrl, let url = URL(string: iconUrl) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.clear
                    }
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
            .padding(.leading, 6)
            content()
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            // Search field pill
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.primary.opacity(0.5))
                TextField("lc.flek.search".loc, text: $query)
                    .font(.system(size: 18))
                    .foregroundStyle(Color.primary)
                    .focused($fieldFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.primary.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .modifier(SearchPillBackground())

            // Clear + close button (returns to the home screen)
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.primary.opacity(0.6))
                    .frame(width: 50, height: 50)
                    .modifier(SearchCloseBackground())
            }
            .buttonStyle(.plain)
        }
    }

    private func close() {
        debounceTask?.cancel()
        query = ""
        debouncedQuery = ""
        fieldFocused = false
        isPresented = false
    }
}

// MARK: - Multi-repo search model

@MainActor
class MultiRepoSearchModel: ObservableObject {
    struct RepoSection: Identifiable {
        let id: String          // repo sourceURL
        let name: String
        let iconUrl: String
        let isFlekstore: Bool
        let apps: [FSAppModel]
    }

    @Published var sections: [RepoSection] = []
    @Published var isLoading = false

    private var repos: [AppRepository] = []
    private var cachedApps: [String: [FSAppModel]] = [:] // keyed by sourceURL
    private var flekstoreVM = FlekstoreAppsListViewModel()
    private var searchTask: Task<Void, Never>?

    func setup() {
        repos = FlekInstallerView.loadRepos()
        cachedApps = RepoCatalogCache.shared.loadAllCached(repos: repos)
        flekstoreVM.repository = .flekstore
        Task { await flekstoreVM.refreshSubscriptionStatus() }
    }

    func search(_ query: String) {
        searchTask?.cancel()

        guard !query.isEmpty else {
            sections = []
            isLoading = false
            return
        }

        isLoading = true

        searchTask = Task {
            await performSearch(query)
        }
    }

    func cancelSearch() {
        searchTask?.cancel()
        sections = []
        isLoading = false
    }

    /// Fetches all custom-repo catalogs and writes them to disk cache.
    /// Skips if called again within the cooldown interval (5 minutes).
    private static var lastPrefetchDate: Date?
    private static let prefetchCooldown: TimeInterval = 300 // 5 minutes

    static func prefetchAllRepos() async {
        if let last = lastPrefetchDate, Date().timeIntervalSince(last) < prefetchCooldown {
            return
        }
        lastPrefetchDate = Date()

        let repos = FlekInstallerView.loadRepos()
        let cache = RepoCatalogCache.shared
        await withTaskGroup(of: Void.self) { group in
            for repo in repos where !FlekInstallerView.isFlekstore(repo) {
                let url = repo.sourceURL
                group.addTask { @MainActor in
                    let vm = FlekstoreAppsListViewModel()
                    vm.repository = .custom(url: url)
                    await vm.fetchApps()
                    if !vm.apps.isEmpty {
                        cache.store(apps: vm.apps, for: url)
                    }
                }
            }
        }
    }

    private func performSearch(_ query: String) async {
        // Reload disk cache (may have been updated by background pre-fetch)
        let cache = RepoCatalogCache.shared
        for repo in repos where !FlekInstallerView.isFlekstore(repo) {
            if cachedApps[repo.sourceURL] == nil,
               let apps = cache.cachedApps(for: repo.sourceURL) {
                cachedApps[repo.sourceURL] = apps
            }
        }

        // Fetch any custom repos that still aren't cached
        let uncachedRepos = repos.filter { !FlekInstallerView.isFlekstore($0) && cachedApps[$0.sourceURL] == nil }
        if !uncachedRepos.isEmpty {
            await withTaskGroup(of: (String, [FSAppModel]).self) { group in
                for repo in uncachedRepos {
                    let url = repo.sourceURL
                    group.addTask { @MainActor in
                        let vm = FlekstoreAppsListViewModel()
                        vm.repository = .custom(url: url)
                        await vm.fetchApps()
                        return (url, vm.apps)
                    }
                }
                for await (url, apps) in group {
                    if !apps.isEmpty {
                        cachedApps[url] = apps
                        cache.store(apps: apps, for: url)
                    }
                }
            }
        }

        guard !Task.isCancelled else { return }

        // Filter custom repos locally
        var results: [RepoSection] = []
        for repo in repos where !FlekInstallerView.isFlekstore(repo) {
            if let allApps = cachedApps[repo.sourceURL] {
                let filtered = allApps.filter { $0.app_name.localizedCaseInsensitiveContains(query) }
                if !filtered.isEmpty {
                    results.append(RepoSection(id: repo.sourceURL, name: repo.name, iconUrl: repo.iconUrl, isFlekstore: false, apps: filtered))
                }
            }
        }

        if !Task.isCancelled {
            sections = results
        }

        // FlekStore: server-side search (requires API call)
        flekstoreVM.searchQuery = query
        await flekstoreVM.resetAndFetchApps()

        guard !Task.isCancelled else { return }

        if let flekRepo = repos.first(where: { FlekInstallerView.isFlekstore($0) }),
           !flekstoreVM.apps.isEmpty {
            results.insert(RepoSection(id: flekRepo.sourceURL, name: "FlekSt0re", iconUrl: flekRepo.iconUrl, isFlekstore: true, apps: flekstoreVM.apps), at: 0)
        }

        if !Task.isCancelled {
            sections = results
            isLoading = false
        }
    }
}

// MARK: - Row views

private struct FlekSearchRow: View {
    let app: LCAppModel
    let darkModeIcon: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(uiImage: app.appInfo.iconIsDarkIcon(darkModeIcon))
                .resizable().scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(app.appInfo.displayName() ?? "?")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                Text("\(app.appInfo.version() ?? "?") - \(app.appInfo.bundleIdentifier() ?? "?")")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.6))
                .padding(.trailing, 10)
        }
        .padding(.horizontal, 6)
        .frame(height: 74)
        .background(Color(.systemBackground).opacity(0.2), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct FlekStoreSearchRow: View {
    let app: FSAppModel

    var body: some View {
        HStack(spacing: 12) {
            FlekRemoteIcon(url: app.app_icon, size: 64, corner: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.app_name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                Text("\(app.app_version)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .lineLimit(1)

            }
            Spacer(minLength: 4)
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 24))
                .foregroundStyle(Color.white)
                .padding(.trailing, 10)
        }
        .padding(.horizontal, 6)
        .frame(height: 74)
        .background(Color(.systemBackground).opacity(0.2), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Glass background modifiers

/// Applies Liquid Glass capsule on iOS 26+, thin material fallback otherwise.
private struct SearchPillBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .glassEffect(.regular, in: .capsule)
        } else {
            let tint = colorScheme == .dark ? 0.15 : 0.45
            content
                .background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().fill(Color.white.opacity(tint)).allowsHitTesting(false))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5).allowsHitTesting(false))
                .compositingGroup()
        }
    }
}

/// Applies Liquid Glass circle on iOS 26+, thin material fallback otherwise.
private struct SearchCloseBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .glassEffect(.regular, in: .circle)
        } else {
            let tint = colorScheme == .dark ? 0.15 : 0.45
            content
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().fill(Color.white.opacity(tint)).allowsHitTesting(false))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5).allowsHitTesting(false))
                .shadow(color: .black.opacity(0.25), radius: 20, y: 4)
        }
    }
}
