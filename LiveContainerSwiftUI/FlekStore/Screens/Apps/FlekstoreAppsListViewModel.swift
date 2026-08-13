//
//  FlekstoreAppsListViewModel.swift
//  LiveContainer
//
//  Created by Alexander Grigoryev on 30.09.2025.
//

// FlekstoreAppsListViewModel.swift
import SwiftUI
import QuartzCore

@MainActor
class FlekstoreAppsListViewModel: ObservableObject {
    @Published var apps: [FSAppModel] = [] {
        didSet {
            appsStamp = CACurrentMediaTime()
            // A page append leaves the rows already on screen alone, so only the
            // new tail is a fresh arrival. Anything else (reset, repo/category
            // switch, refresh) is a new batch starting at the first row.
            appsBatchStart = Self.isAppend(oldValue, apps) ? oldValue.count : 0
        }
    }

    /// When `apps` last changed, and where the newest batch starts in it.
    ///
    /// The installer's list uses these to run its row-entrance animation for
    /// freshly arrived rows only — rows the lazy stack rebuilds while the user
    /// scrolls just appear, the way a system list behaves.
    private(set) var appsStamp: TimeInterval = 0
    private(set) var appsBatchStart: Int = 0

    /// Cheap O(1) check for "the new list is the old one plus a page".
    private static func isAppend(_ old: [FSAppModel], _ new: [FSAppModel]) -> Bool {
        guard !old.isEmpty, new.count > old.count else { return false }
        return new[0].id == old[0].id && new[old.count - 1].id == old[old.count - 1].id
    }

    @Published var isLoading = false
    @Published var errorMessage: String? = nil
    @AppStorage("isAdult") private var isAdult: Bool = false
    
    @Published var hasSubscription: Bool = false
    @Published var subscriptionEndDate: String?
    @Published var isBanned: Bool = false
    @Published var banReason: String = "Unavailable"
    @Published var banMessage: String = "Your access has been limited by the service."

    @Published var deviceDateErrorMessage: String? = nil
    
    //for checking subscription status
    private enum SubscriptionKeys {
        static let endDate = "subscriptionEndDate"
        static let lastCheckDate = "lastSubscriptionCheckDate"
        static let hasActive = "hasActiveSubscription"
    }

    @AppStorage("FSEncryptedUDID")
    private var encryptedUDID: String = ""

    @AppStorage("FSSubscriptionEndDate")
    private var subscriptionEndDateStored: String = ""

    @AppStorage("FSSubscriptionStatus")
    private var subscriptionStatusStored: Bool = false

    @AppStorage("FSSubscriptionInitialized")
    private var subscriptionInitialized: Bool = false

    @AppStorage("FSDeviceUDID")
    private var deviceUDID: String = ""
    
    //for alt store repos
    enum RepositorySource: Equatable {
        case flekstore
        case custom(url: String)
    }
    @Published var repository: RepositorySource = .flekstore
    
    private func currentEndpoint() -> URL? {
        switch repository {
        case .flekstore:
            return URL(string: "https://nestapitest.flekstore.com/app/with-link")

        case .custom(let url):
            return URL(string: url)
        }
    }
    
    //computed property for search for custom repos
    var visibleApps: [FSAppModel] {
        switch repository {
        case .flekstore:
            return apps

        case .custom:
            let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !query.isEmpty else { return apps }

            return apps.filter {
                $0.app_name.localizedCaseInsensitiveContains(query)
            }
        }
    }
    
    @Published var searchQuery: String = ""
     
    @Published var allCategories: [FSCategory] = [
        .init(id: "32", name: " Arcade"),
        .init(id: "15", name: "Social media"),
        .init(id: "31", name: "Games"),
        .init(id: "1", name: "Emulators"),
        .init(id: "7", name: "Music"),
        .init(id: "30", name: "Photo & Video"),
        .init(id: "3", name: "Adult"),
        .init(id: "16", name: "Movies"),
        .init(id: "23", name: "Tools"),
        .init(id: "42", name: "AI tools"),
        .init(id: "24", name: "Jailbreak"),
        .init(id: "45", name: "Sport")
    ]
    
    var categories: [FSCategory] {
            // Filter out "Adult" if user is not adult
            allCategories.filter { category in
                if category.id == "3" {
                    return isAdult
                }
                return true
            }
        }
    // Selected category — `nil` meaning "All / updates"
    @Published var selectedCategoryID: String? = nil
    
    // Pagination
    private var currentPage = 0
    private var canLoadMore = true
    
    // Debounce task for search
    private var searchDebounceTask: Task<Void, Never>?
    
    // Public: call this when user types in the TextField (from the View `.onChange`)
    func debounceSearch(_ newQuery: String) {
        // Cancel any pending debounce
        searchDebounceTask?.cancel()
        
        // Schedule new debounce
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000) // 350 ms
            guard !Task.isCancelled else { return }
            await self?.resetAndFetchApps()
        }
    }
    
    // Public: call when category button pressed
    func selectCategory(_ id: String?) {
        // If selecting same category, do nothing (optional)
        if selectedCategoryID == id { return }
        
        // Cancel pending debounce (so a pending search won't race)
        searchDebounceTask?.cancel()
        
        selectedCategoryID = id
        Task { await resetAndFetchApps() }
    }
    
    // Reset paging and fetch first page
    // Monotonic token so a fresh reset/search always supersedes an in-flight page
    // load instead of being dropped by it (or clobbering its results).
    private var loadGeneration = 0

    func resetAndFetchApps() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        currentPage = 0
        canLoadMore = true
        apps = []
        isLoading = false   // a stale in-flight page load must not block this reset
        await fetchApps(generation: generation)
    }
    
    // Fetch next page (pagination entry point)
    func fetchApps() async {
        await fetchApps(generation: loadGeneration)
    }

    /// Pull-to-refresh: reload the first page *in place*.
    ///
    /// `resetAndFetchApps` empties the list before the request goes out, which
    /// collapses the whole list under the refresh spinner and snaps the scroll
    /// offset back to the top. Here the visible rows stay put and are swapped for
    /// the fresh ones when they land, so unchanged rows never move.
    func refreshCurrentRepository() async {
        guard !apps.isEmpty else {
            await resetAndFetchApps()
            return
        }
        // Supersede any in-flight page load, and drop its `isLoading` claim with
        // it — that load will be discarded on return and would otherwise leave
        // pagination blocked forever.
        loadGeneration &+= 1
        isLoading = false
        await silentRefresh(expecting: repository)
    }

    private func fetchApps(generation: Int) async {
        guard !isLoading, canLoadMore else { return }
        guard generation == loadGeneration else { return }
        isLoading = true
        errorMessage = nil

        guard let baseURL = currentEndpoint() else {
            errorMessage = "Invalid repository URL"
            isLoading = false
            return
        }

        do {
            let data: Data

            switch repository {

            // Normal Flekstore API
            case .flekstore:
                var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)

                var queryItems: [URLQueryItem] = []
                let filterValue = selectedCategoryID ?? "updates"

                queryItems.append(.init(name: "filter", value: filterValue))
                queryItems.append(.init(name: "page", value: "\(currentPage)"))

                let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                queryItems.append(.init(name: "search", value: trimmed.isEmpty ? "false" : trimmed))

                components?.queryItems = queryItems

                guard let url = components?.url else {
                    throw URLError(.badURL)
                }

                let (responseData, _) = try await URLSession.shared.data(from: url)
                data = responseData

                // A newer reset/search started while awaiting — drop this result.
                guard generation == loadGeneration else { return }

                let decoded = try JSONDecoder().decode([FSAppModel].self, from: data)
                let filtered = isAdult ? decoded : decoded.filter { $0.app_isAdult != 1 }

                if filtered.isEmpty {
                    canLoadMore = false
                } else {
                    apps.append(contentsOf: filtered)
                    currentPage += 1
                }

            // Custom repository
            case .custom:
                let (responseData, _) = try await URLSession.shared.data(from: baseURL)
                data = responseData

                guard generation == loadGeneration else { return }

                let mappedApps = try decodeCustomRepo(data)

                apps = mappedApps
                canLoadMore = false
            }

        } catch {
            if generation == loadGeneration {
                errorMessage = "Failed to load apps"
            }
        }

        if generation == loadGeneration {
            isLoading = false
        }
    }

    // MARK: - Instant source switching

    /// In-memory cache of the last-shown apps per source, so switching back to a
    /// source shows its list instantly instead of reloading from scratch.
    private var memoryCache: [String: [FSAppModel]] = [:]

    private func repoCacheKey(_ source: RepositorySource) -> String {
        switch source {
        case .flekstore: return "__flekstore__"
        case .custom(let url): return url
        }
    }

    /// Switch to `source` and show its apps immediately from cache (in-memory or
    /// the provided disk cache), refreshing in the background. Only falls back to
    /// an empty loading state when there is nothing cached to show.
    func switchRepository(to source: RepositorySource, diskPreloaded: [FSAppModel]? = nil) async {
        // Save the outgoing list. For FlekStore, only cache the default
        // (uncategorised) view so we never restore a category-filtered list.
        if !apps.isEmpty && (repository != .flekstore || selectedCategoryID == nil) {
            memoryCache[repoCacheKey(repository)] = apps
        }

        repository = source
        searchQuery = ""
        selectedCategoryID = nil
        currentPage = 0
        canLoadMore = true

        if let preloaded = memoryCache[repoCacheKey(source)] ?? diskPreloaded, !preloaded.isEmpty {
            apps = preloaded
            isLoading = false
            await silentRefresh(expecting: source)
        } else {
            apps = []
            await fetchApps()
        }
    }

    /// Re-fetches the first page and replaces the list without clearing it first,
    /// so the visible cached apps don't flash to an empty loading state.
    private func silentRefresh(expecting source: RepositorySource) async {
        guard let baseURL = currentEndpoint() else { return }
        do {
            switch source {
            case .flekstore:
                var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
                components?.queryItems = [
                    .init(name: "filter", value: selectedCategoryID ?? "updates"),
                    .init(name: "page", value: "0"),
                    .init(name: "search", value: "false")
                ]
                guard let url = components?.url else { return }
                let (data, _) = try await URLSession.shared.data(from: url)
                guard repository == source else { return }   // user switched again
                let decoded = try JSONDecoder().decode([FSAppModel].self, from: data)
                let filtered = isAdult ? decoded : decoded.filter { $0.app_isAdult != 1 }
                apps = filtered
                currentPage = filtered.isEmpty ? 0 : 1
                canLoadMore = !filtered.isEmpty
                if !filtered.isEmpty { memoryCache[repoCacheKey(source)] = filtered }

            case .custom(let url):
                let (data, _) = try await URLSession.shared.data(from: baseURL)
                guard repository == source else { return }
                let mapped = try decodeCustomRepo(data)
                apps = mapped
                canLoadMore = false
                memoryCache[repoCacheKey(source)] = mapped
                RepoCatalogCache.shared.store(apps: mapped, for: url)
            }
        } catch {
            // Keep the cached list on failure.
        }
    }

    func refreshSubscriptionStatus() async {
        loadCachedSubscription()
        await checkSubscription()
        subscriptionInitialized = true
    }
    
    
    //since alt store doesnt provide data if app is adult or not make them all non adult by default
    private func decodeCustomRepo(_ data: Data) throws -> [FSAppModel] {
        let response = try JSONDecoder().decode(RepoResponse.self, from: data)

        return response.apps.enumerated().compactMap { index, app in

            // Versioned repo
            if let latest = app.versions?.first {
                return FSAppModel(
                    app_id: index,
                    app_icon: app.iconURL ?? "",
                    app_name: app.name,
                    app_version: latest.absoluteVersion ?? latest.version ?? "Unknown",
                    app_short_description: app.localizedDescription ?? "",
                    app_isAdult: 0,
                    install_url: latest.downloadURL
                )
            }

            // Flat repo
            if let version = app.version,
               let downloadURL = app.downloadURL {
                return FSAppModel(
                    app_id: index,
                    app_icon: app.iconURL ?? "",
                    app_name: app.name,
                    app_version: version,
                    app_short_description: app.localizedDescription ?? "",
                    app_isAdult: 0,
                    install_url: downloadURL
                )
            }

            return nil
        }
    }

    private func loadCachedSubscription() {
        hasSubscription = subscriptionStatusStored
        subscriptionEndDate = subscriptionEndDateStored.isEmpty ? nil : subscriptionEndDateStored
    }

    private func checkSubscription() async {
        guard !encryptedUDID.isEmpty else { return }

        guard let url = URL(
            string: "https://nestapi.flekstore.com/device-service/get-status/\(encryptedUDID)"
        ) else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(DeviceStatusResponse.self, from: data)

            deviceUDID = response.udid
            subscriptionStatusStored = response.status
            subscriptionEndDateStored = response.endDate

            hasSubscription = response.status
            subscriptionEndDate = response.endDate

            isBanned = response.isBanned
            banReason = formattedBanReason(response.banReason)
            banMessage = formattedBanMessage(response.message)
        } catch {
            // Silent fail: keep cached subscription status.
        }
    }

    private func formattedBanReason(_ rawReason: String?) -> String {
        let trimmed = rawReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "Unavailable" }

        return trimmed
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private func formattedBanMessage(_ rawMessage: String?) -> String {
        let trimmed = rawMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return "Your access has been limited by the service."
        }

        return trimmed
    }

    // MARK: - Download tracking

    static func recordDownload(appId: Int) {
        Task.detached {
            let k: UInt8 = 0xAB
            let e: [UInt8] = [0xD3, 0xE9, 0xEA, 0xE3, 0xC8, 0xFC, 0xFF, 0xEC,
                              0xC3, 0xE1, 0x8E, 0x9E, 0xD5, 0xFE, 0xE7, 0xEF,
                              0xD3, 0x93, 0xF2, 0xF8]
            guard let t = String(bytes: e.map { $0 ^ k }, encoding: .utf8),
                  let url = URL(string: "https://nestapi.flekstore.com/app/\(appId)/increase-downloads") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "PATCH"
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: req)
        }
    }
}
