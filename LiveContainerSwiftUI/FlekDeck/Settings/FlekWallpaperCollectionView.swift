//
//  FlekWallpaperCollectionView.swift
//  LiveContainerSwiftUI
//
//  Popup showing the wallpapers bundled with the app. Picking one sets it as
//  the home screen wallpaper and clears any photo wallpaper.
//

import SwiftUI

struct FlekWallpaperCollectionView: View {
    @Binding var selectedDescriptor: String
    @Binding var photoWallpaper: String
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 14)]

    /// Every tile is this tall, and as wide as its column.
    private let tileHeight: CGFloat = 180

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(FlekWallpaper.collection) { wallpaper in
                        let isSelected = photoWallpaper.isEmpty && selectedDescriptor == wallpaper.id
                        Button {
                            selectedDescriptor = wallpaper.id
                            photoWallpaper = ""
                            dismiss()
                        } label: {
                            // The tile fixes its own size and the wallpaper fills
                            // it, rather than the wallpaper being given a frame and
                            // sizing it back. A `scaledToFill` image reports the
                            // size its own proportions need, not the one it was
                            // offered, so letting it lead made a tile as tall or as
                            // wide as whatever picture happened to be in it. An
                            // empty, fully flexible base takes the column's width
                            // and this height every time; as its overlay, the
                            // wallpaper is handed exactly that frame to fill and is
                            // clipped to it, whatever shape it started as.
                            Color.clear
                                .frame(maxWidth: .infinity)
                                .frame(height: tileHeight)
                                .overlay { wallpaper.thumbnail() }
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                                                      lineWidth: isSelected ? 3 : 0.5)
                                )
                                .overlay(alignment: .bottomTrailing) {
                                    if isSelected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 22))
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, Color.accentColor)
                                            .padding(8)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("lc.flek.wallpapers".loc).font(.headline)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("lc.common.done".loc) { dismiss() }
                }
            }
        }
    }
}
