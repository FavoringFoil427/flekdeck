//
//  FlekScreenshotViewer.swift
//  LiveContainerSwiftUI
//
//  Full-screen screenshot browser opened by tapping a shot on an app's page.
//  Pages between them, and drags away downwards like the system photo viewer.
//

import SwiftUI
import Kingfisher

struct FlekScreenshotViewer: View {
    let photos: [String]
    /// Which shot was tapped.
    @State var index: Int
    /// Shape of the gallery this opened from, so a shot still loading is held by
    /// a block of roughly the right size rather than a spinner in empty space.
    var aspect: CGFloat = FlekAppDetailModel.fallbackAspect

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGFloat = 0

    /// How far down the sheet has to travel before letting go dismisses it.
    private static let dismissDistance: CGFloat = 120

    /// Backdrop thins out as the viewer is dragged away, so the page underneath
    /// shows through and the gesture feels attached to something.
    private var backdropOpacity: Double {
        let progress = min(abs(dragOffset) / (Self.dismissDistance * 2), 1)
        return 1 - progress * 0.4
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(backdropOpacity)
                .ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(photos.enumerated()), id: \.offset) { position, photo in
                    KFImage(URL(string: photo))
                        .placeholder {
                            GeometryReader { geo in
                                let width = min(geo.size.width, geo.size.height * aspect)
                                FlekImagePlaceholder(cornerRadius: 10)
                                    .frame(width: width, height: width / aspect)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        // Memory only, as in the gallery this opens from — so
                        // the shot tapped is already there, and nothing about
                        // it is left on disk afterwards.
                        .cacheMemoryOnly()
                        .fade(duration: 0.15)
                        .resizable()
                        .scaledToFit()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 44)
                        .tag(position)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .always : .never))
            .pageIndicatorOnDarkBackground()
        }
        .offset(y: dragOffset)
        // Runs alongside the pager's own horizontal gesture; vertical intent is
        // checked below so a sideways swipe still turns the page.
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onChanged { value in
                    guard abs(value.translation.height) > abs(value.translation.width) else { return }
                    // Downwards dismisses; upwards is rubber-banded so the
                    // gesture doesn't feel dead in the wrong direction.
                    dragOffset = value.translation.height > 0
                        ? value.translation.height
                        : value.translation.height / 4
                }
                .onEnded { value in
                    if value.translation.height > Self.dismissDistance {
                        dismiss()
                    } else {
                        withAnimation(reduceMotion ? .easeOut(duration: 0.2)
                                                   : .spring(response: 0.35, dampingFraction: 0.85)) {
                            dragOffset = 0
                        }
                    }
                }
        )
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.18)))
                    .background(Circle().fill(.ultraThinMaterial))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 18)
            .padding(.top, 10)
            .accessibilityLabel("lc.common.close".loc)
        }
    }
}

private extension View {
    /// White page dots with a visible track, which the default style doesn't
    /// give against a black backdrop.
    // Erased to AnyView so the iOS-specific index-view style modifier isn't
    // baked into a caller's static type — the same hazard the installer's
    // availability helpers document.
    func pageIndicatorOnDarkBackground() -> AnyView {
        AnyView(self.indexViewStyle(.page(backgroundDisplayMode: .interactive)))
    }
}
