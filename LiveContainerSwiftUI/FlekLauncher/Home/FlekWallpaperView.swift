//
//  FlekWallpaperView.swift
//  LiveContainerSwiftUI
//
//  Renders the home screen wallpaper. Supports a bundled wallpaper, a built-in
//  gradient preset, or a user-picked photo stored in the app group.
//

import SwiftUI

/// A selectable wallpaper. Persisted as a single string descriptor:
///   - "asset:<name>"     bundled image asset
///   - "gradient:<id>"    built-in gradient preset
/// Photo wallpapers are tracked separately via `FlekLauncherKeys.wallpaperPhoto`.
enum FlekWallpaper: Identifiable, Equatable {
    case asset(String)
    case gradient(String, [Color])

    var id: String {
        switch self {
        case .asset(let n): return "asset:\(n)"
        case .gradient(let g, _): return "gradient:\(g)"
        }
    }

    static let defaultDescriptor = "asset:FlekWallpaperDefault"

    static let collection: [FlekWallpaper] = [
        .asset("FlekWallpaperDefault"),
        .gradient("sunset", [Color(red: 1.0, green: 0.45, blue: 0.45), Color(red: 0.6, green: 0.2, blue: 0.6)]),
        .gradient("ocean", [Color(red: 0.20, green: 0.55, blue: 0.95), Color(red: 0.05, green: 0.20, blue: 0.45)]),
        .gradient("mint", [Color(red: 0.35, green: 0.85, blue: 0.70), Color(red: 0.10, green: 0.45, blue: 0.55)]),
        .gradient("dusk", [Color(red: 0.35, green: 0.30, blue: 0.55), Color(red: 0.10, green: 0.10, blue: 0.20)]),
        .gradient("peach", [Color(red: 1.0, green: 0.75, blue: 0.55), Color(red: 0.95, green: 0.45, blue: 0.55)]),
        .gradient("graphite", [Color(red: 0.30, green: 0.30, blue: 0.33), Color(red: 0.08, green: 0.08, blue: 0.10)]),
    ]

    static func from(descriptor: String) -> FlekWallpaper {
        if descriptor.hasPrefix("gradient:") {
            let id = String(descriptor.dropFirst("gradient:".count))
            if let match = collection.first(where: { if case .gradient(let g, _) = $0 { return g == id } else { return false } }) {
                return match
            }
        }
        if descriptor.hasPrefix("asset:") {
            return .asset(String(descriptor.dropFirst("asset:".count)))
        }
        return .asset("FlekWallpaperDefault")
    }

    @ViewBuilder
    func thumbnail() -> some View {
        switch self {
        case .asset(let name):
            Image(name).resizable().scaledToFill()
        case .gradient(_, let colors):
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

struct FlekWallpaperView: View {
    @AppStorage(FlekLauncherKeys.wallpaperName, store: LCUtils.appGroupUserDefault)
    private var wallpaperDescriptor: String = FlekWallpaper.defaultDescriptor
    @AppStorage(FlekLauncherKeys.wallpaperPhoto, store: LCUtils.appGroupUserDefault)
    private var wallpaperPhoto: String = ""

    var body: some View {
        GeometryReader { geo in
            Group {
                if !wallpaperPhoto.isEmpty, let img = FlekWallpaperStore.loadPhoto(named: wallpaperPhoto) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    FlekWallpaper.from(descriptor: wallpaperDescriptor).thumbnail()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
    }
}

/// Stores user-picked photo wallpapers in the app group container.
enum FlekWallpaperStore {
    static var directory: URL {
        let url = LCPath.lcGroupDocPath.appendingPathComponent("Wallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func loadPhoto(named name: String) -> UIImage? {
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    @discardableResult
    static func savePhoto(_ image: UIImage) -> String? {
        let name = "wallpaper-\(Int(Date().timeIntervalSince1970)).jpg"
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        do {
            try data.write(to: directory.appendingPathComponent(name))
            return name
        } catch {
            return nil
        }
    }
}
