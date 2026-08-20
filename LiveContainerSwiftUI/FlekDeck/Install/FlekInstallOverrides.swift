//
//  FlekInstallOverrides.swift
//  LiveContainerSwiftUI
//
//  Changes the user asks for on an app's page before installing it — a custom
//  icon, a different springboard name, a different bundle ID. They are carried
//  on the queued install and applied to the extracted bundle on its way in,
//  because none of them can be applied earlier: the IPA's own Info.plist only
//  exists once the download has been unpacked.
//

import UIKit

struct FlekInstallOverrides: Equatable {
    /// Springboard label. Nil leaves the app's own name alone.
    var displayName: String?
    /// Nil keeps the IPA's bundle ID.
    var bundleID: String?
    /// A copy owned by us — the file the picker hands over is security-scoped
    /// and may be gone by the time the install actually runs.
    var iconFileURL: URL?

    var isEmpty: Bool {
        displayName == nil && bundleID == nil && iconFileURL == nil
    }

    /// Icon written next to the bundle's generated caches.
    ///
    /// Deliberately *not* `LCAppIconLight.png`: that is the generated cache, and
    /// Settings › Data Management › Clear Icon Cache deletes it. A custom icon
    /// has to outlive that, so it gets its own name and `LCAppInfo` prefers it.
    static let customIconFileName = "LCCustomIcon.png"

    /// Largest edge the stored icon is scaled to. Icons are drawn at 74pt at
    /// most, so anything beyond this is wasted space in the bundle.
    private static let iconMaxDimension: CGFloat = 256

    /// Folder holding picked icons until their install runs.
    static var stagingDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("FlekInstallIcons", isDirectory: true)
    }

    /// Copies a picked image somewhere we control, and returns that copy.
    static func stageIcon(from pickedURL: URL) -> URL? {
        let fm = FileManager.default
        let needsScope = !fm.isReadableFile(atPath: pickedURL.path)
        if needsScope, !pickedURL.startAccessingSecurityScopedResource() { return nil }
        defer { if needsScope { pickedURL.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: pickedURL),
              let image = UIImage(data: data),
              let png = scaled(image).pngData() else { return nil }

        do {
            try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            let destination = stagingDirectory.appendingPathComponent("\(UUID().uuidString).png")
            try png.write(to: destination)
            return destination
        } catch {
            return nil
        }
    }

    private static func scaled(_ image: UIImage) -> UIImage {
        let longestEdge = max(image.size.width, image.size.height)
        guard longestEdge > iconMaxDimension, longestEdge > 0 else { return image }
        let ratio = iconMaxDimension / longestEdge
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        return UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Applies the name and icon to a freshly extracted bundle.
    ///
    /// Must run *before* `LCAppInfo` is created for the bundle: it reads
    /// Info.plist once at init, so a later edit would not be seen. The bundle ID
    /// is the exception — it goes through `overrideBundleIdentifier`, which also
    /// records the original for LiveContainer.
    func applyNameAndIcon(toBundleAt bundleURL: URL) {
        if let displayName, !displayName.isEmpty {
            let plistURL = bundleURL.appendingPathComponent("Info.plist")
            if let plist = NSMutableDictionary(contentsOf: plistURL) {
                plist["CFBundleDisplayName"] = displayName
                plist["CFBundleName"] = displayName
                // Written binary, matching how LiveContainer rewrites this file
                // elsewhere.
                if let data = try? PropertyListSerialization.data(
                    fromPropertyList: plist, format: .binary, options: 0) {
                    try? data.write(to: plistURL)
                }
            }
        }

        if let iconFileURL, let data = try? Data(contentsOf: iconFileURL) {
            let destination = bundleURL.appendingPathComponent(Self.customIconFileName)
            try? data.write(to: destination)
        }
    }

    /// Drops the staged icon once its install is done with it.
    func cleanUpStagedIcon() {
        guard let iconFileURL else { return }
        try? FileManager.default.removeItem(at: iconFileURL)
    }
}
