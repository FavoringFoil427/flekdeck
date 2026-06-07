//
//  FlekPersonalizationView.swift
//  LiveContainerSwiftUI
//
//  New "Personalization" settings page (not present in LiveContainer). Lets the
//  user pick a home screen wallpaper (built-in collection or a photo) and choose
//  the home screen layout (grid of cards or a list).
//

import SwiftUI
import PhotosUI

struct FlekPersonalizationView: View {
    @AppStorage(FlekLauncherKeys.wallpaperName, store: LCUtils.appGroupUserDefault)
    private var wallpaperDescriptor: String = FlekWallpaper.defaultDescriptor
    @AppStorage(FlekLauncherKeys.wallpaperPhoto, store: LCUtils.appGroupUserDefault)
    private var wallpaperPhoto: String = ""
    @AppStorage(FlekLauncherKeys.homeLayout, store: LCUtils.appGroupUserDefault)
    private var homeLayout: String = FlekHomeLayout.grid.rawValue

    @State private var showCollection = false
    @State private var showPhotoPicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // MARK: Wallpapers
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("lc.flek.wallpapers".loc)

                    HStack(spacing: 12) {
                        currentPreview
                        VStack(spacing: 12) {
                            actionTile(title: "lc.flek.chooseFromCollection".loc, systemImage: "square.grid.2x2.fill") {
                                showCollection = true
                            }
                            actionTile(title: "lc.flek.chooseFromPhotos".loc, systemImage: "photo.badge.plus") {
                                showPhotoPicker = true
                            }
                        }
                    }
                    .padding(14)
                    .background(card)
                }

                // MARK: Home Screen Layout
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("lc.flek.homeScreenLayout".loc)

                    HStack(spacing: 12) {
                        layoutOption(.grid, title: "lc.flek.layoutGrid".loc)
                        layoutOption(.list, title: "lc.flek.layoutList".loc)
                    }
                    .padding(14)
                    .background(card)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("lc.flek.personalization".loc)
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showCollection) {
            FlekWallpaperCollectionView(selectedDescriptor: $wallpaperDescriptor, photoWallpaper: $wallpaperPhoto)
        }
        .sheet(isPresented: $showPhotoPicker) {
            FlekPhotoPicker { image in
                if let name = FlekWallpaperStore.savePhoto(image) {
                    wallpaperPhoto = name
                }
            }
        }
    }

    // MARK: Pieces

    private var currentPreview: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if !wallpaperPhoto.isEmpty, let img = FlekWallpaperStore.loadPhoto(named: wallpaperPhoto) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    FlekWallpaper.from(descriptor: wallpaperDescriptor).thumbnail()
                }
            }
            .frame(width: 96, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text("lc.flek.current".loc)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(.ultraThinMaterial))
                .padding(6)
        }
    }

    private func actionTile(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 22))
                Text(title).font(.system(size: 13, weight: .medium)).multilineTextAlignment(.center)
            }
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity)
            .frame(height: 69)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.tertiarySystemFill)))
        }
        .buttonStyle(.plain)
    }

    private func layoutOption(_ layout: FlekHomeLayout, title: String) -> some View {
        let selected = homeLayout == layout.rawValue
        return Button {
            homeLayout = layout.rawValue
        } label: {
            VStack(spacing: 10) {
                LayoutGlyph(layout: layout, selected: selected)
                    .frame(width: 64, height: 92)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? .white : Color.primary)
                    .padding(.horizontal, 14).padding(.vertical, 4)
                    .background(
                        Capsule().fill(selected ? Color.accentColor : Color(.tertiarySystemFill))
                    )
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.tertiarySystemFill).opacity(0.5)))
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text).font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground))
    }
}

/// Small phone illustration showing a grid or list arrangement.
private struct LayoutGlyph: View {
    let layout: FlekHomeLayout
    let selected: Bool

    var body: some View {
        let tint = selected ? Color.accentColor : Color.secondary
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(tint, lineWidth: 2)
            .overlay {
                if layout == .grid {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(10), spacing: 4), count: 3), spacing: 4) {
                        ForEach(0 ..< 9, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 10, height: 10)
                        }
                    }
                    .padding(10)
                } else {
                    VStack(spacing: 5) {
                        ForEach(0 ..< 5, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 2).fill(tint).frame(height: 6)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 10)
                }
            }
    }
}

/// PHPicker wrapper that returns a single chosen image.
struct FlekPhotoPicker: UIViewControllerRepresentable {
    var onPick: (UIImage) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: FlekPhotoPicker
        init(_ parent: FlekPhotoPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
            provider.loadObject(ofClass: UIImage.self) { [weak self] obj, _ in
                guard let img = obj as? UIImage else { return }
                DispatchQueue.main.async { self?.parent.onPick(img) }
            }
        }
    }
}
