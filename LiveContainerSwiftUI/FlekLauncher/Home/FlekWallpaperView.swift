//
//  FlekWallpaperView.swift
//  LiveContainerSwiftUI
//
//  Renders the home screen wallpaper. Supports a bundled wallpaper (selected
//  from the in-app collection) or a user-picked photo stored in the app group.
//

import SwiftUI

struct FlekWallpaperView: View {
    @AppStorage(FlekLauncherKeys.wallpaperName, store: LCUtils.appGroupUserDefault)
    private var wallpaperName: String = "FlekWallpaperDefault"
    @AppStorage(FlekLauncherKeys.wallpaperPhoto, store: LCUtils.appGroupUserDefault)
    private var wallpaperPhoto: String = ""

    var body: some View {
        GeometryReader { geo in
            Group {
                if !wallpaperPhoto.isEmpty, let img = FlekWallpaperStore.loadPhoto(named: wallpaperPhoto) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Image(wallpaperName).resizable().scaledToFill()
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
