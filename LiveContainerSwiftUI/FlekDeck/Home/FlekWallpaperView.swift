//
//  FlekWallpaperView.swift
//  LiveContainerSwiftUI
//
//  Renders the home screen wallpaper. Supports a bundled wallpaper, a built-in
//  gradient preset, or a user-picked photo stored in the app group.
//

import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// A selectable wallpaper. Persisted as a single string descriptor:
///   - "asset:<name>"     bundled image asset
///   - "gradient:<id>"    built-in gradient preset
/// Photo wallpapers are tracked separately via `FlekDeckKeys.wallpaperPhoto`.
enum FlekWallpaper: Identifiable, Equatable {
    case asset(String)
    case gradient(String, [Color])

    var id: String {
        switch self {
        case .asset(let n): return "asset:\(n)"
        case .gradient(let g, _): return "gradient:\(g)"
        }
    }

    static let defaultDescriptor = "asset:wallpaper0"

    static let collection: [FlekWallpaper] = [
        .asset("wallpaper0"),
        .asset("FlekWallpaperDefault"),
        .asset("wallpaper1"),
        .asset("wallpaper2"),
        .asset("wallpaper3"),
        .asset("wallpaper4"),
        .asset("wallpaper5"),
        .asset("wallpaper6"),
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
        return .asset("wallpaper0")
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
    @AppStorage(FlekDeckKeys.wallpaperName, store: LCUtils.appGroupUserDefault)
    private var wallpaperDescriptor: String = FlekWallpaper.defaultDescriptor
    @AppStorage(FlekDeckKeys.wallpaperPhoto, store: LCUtils.appGroupUserDefault)
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

// MARK: - CIGaussianBlur helper

private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

/// Applies CIGaussianBlur to a UIImage. Returns nil on failure.
func ciGaussianBlur(_ image: UIImage, radius: CGFloat) -> UIImage? {
    guard let ciImage = CIImage(image: image) else { return nil }
    let filter = CIFilter.gaussianBlur()
    // Edge pixels stretched outward before blurring, so the kernel has something
    // to average against out there. An image has nothing beyond its bounds — the
    // filter reads transparent black — and near an edge more and more of the
    // kernel falls into that emptiness, darkening and fading the border into the
    // vignette that framed every blurred wallpaper and switcher backdrop.
    // Clamping is free: the extended image is infinite but only the part the crop
    // below asks for is ever rendered.
    filter.inputImage = ciImage.clampedToExtent()
    filter.radius = Float(radius)
    guard let output = filter.outputImage else { return nil }
    // CIGaussianBlur expands the image; crop back to original extent
    let cropped = output.cropped(to: ciImage.extent)
    guard let cgImage = ciContext.createCGImage(cropped, from: cropped.extent) else { return nil }
    return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
}

/// Renders a gradient to a UIImage so it can be blurred with CIGaussianBlur.
private func renderGradient(colors: [Color], size: CGSize) -> UIImage? {
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { ctx in
        let cgColors = colors.map { UIColor($0).cgColor }
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: cgColors as CFArray,
                                        locations: nil) else { return }
        ctx.cgContext.drawLinearGradient(
            gradient,
            start: .zero,
            end: CGPoint(x: size.width, y: size.height),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }
}

/// Bottom gradient blur overlay using CIGaussianBlur — pure blur, no tint.
struct FlekBlurredWallpaperOverlay: View {
    @AppStorage(FlekDeckKeys.wallpaperName, store: LCUtils.appGroupUserDefault)
    private var wallpaperDescriptor: String = FlekWallpaper.defaultDescriptor
    @AppStorage(FlekDeckKeys.wallpaperPhoto, store: LCUtils.appGroupUserDefault)
    private var wallpaperPhoto: String = ""

    var radius: CGFloat = 20

    @State private var blurredImage: UIImage?

    var body: some View {
        GeometryReader { geo in
            if let blurred = blurredImage {
                Image(uiImage: blurred)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height + 6)
                    .clipped()
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.8),
                                .init(color: .white, location: 1.0),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        }
        .ignoresSafeArea()
        .onAppear { generateBlurred() }
        .onChange(of: wallpaperDescriptor) { _ in generateBlurred() }
        .onChange(of: wallpaperPhoto) { _ in generateBlurred() }
    }

    /// Blurred wallpapers, keyed by what produced them. `generateBlurred` runs on
    /// every appear — including each return from an app — and a Gaussian blur over a
    /// full-screen image is not cheap to repeat for a result that cannot have changed.
    private static let blurCache = NSCache<NSString, UIImage>()

    static func clearBlurCache() {
        blurCache.removeAllObjects()
    }

    private func generateBlurred() {
        let cacheKey = "\(wallpaperPhoto)|\(wallpaperDescriptor)|\(radius)" as NSString
        if let cached = Self.blurCache.object(forKey: cacheKey) {
            blurredImage = cached
            return
        }

        let screenSize = UIScreen.main.bounds.size
        let sourceImage: UIImage?

        if !wallpaperPhoto.isEmpty {
            sourceImage = FlekWallpaperStore.loadPhoto(named: wallpaperPhoto)
        } else {
            let wp = FlekWallpaper.from(descriptor: wallpaperDescriptor)
            switch wp {
            case .asset(let name):
                sourceImage = UIImage(named: name)
            case .gradient(_, let colors):
                sourceImage = renderGradient(colors: colors, size: screenSize)
            }
        }

        guard let source = sourceImage else {
            blurredImage = nil
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let result = ciGaussianBlur(source, radius: radius)
            DispatchQueue.main.async {
                if let result { Self.blurCache.setObject(result, forKey: cacheKey) }
                blurredImage = result
            }
        }
    }
}

