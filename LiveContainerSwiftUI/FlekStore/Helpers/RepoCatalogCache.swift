//
//  RepoCatalogCache.swift
//  LiveContainerSwiftUI
//
//  Persists custom-repo app catalogs to disk so search can filter locally
//  instead of fetching every repo on each query. FlekStore is excluded
//  because it uses server-side search with pagination.
//

import Foundation
import CryptoKit

final class RepoCatalogCache {
    static let shared = RepoCatalogCache()

    private let directoryName = "RepoCatalogCache"

    // MARK: - Read

    func cachedApps(for url: String) -> [FSAppModel]? {
        guard let fileURL = cacheFileURL(for: url),
              let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode([FSAppModel].self, from: data)
    }

    func loadAllCached(repos: [AppRepository]) -> [String: [FSAppModel]] {
        var result: [String: [FSAppModel]] = [:]
        for repo in repos {
            if let apps = cachedApps(for: repo.sourceURL) {
                result[repo.sourceURL] = apps
            }
        }
        return result
    }

    // MARK: - Write

    func store(apps: [FSAppModel], for url: String) {
        guard let fileURL = cacheFileURL(for: url),
              let data = try? JSONEncoder().encode(apps) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Cache directory

    private func cacheFileURL(for url: String) -> URL? {
        guard let directory = ensureCacheDirectory() else { return nil }
        let data = Data(url.utf8)
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hex).json")
    }

    private func ensureCacheDirectory() -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = caches.appendingPathComponent(directoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }
}
