//
//  FlekInstallingCard.swift
//  LiveContainerSwiftUI
//
//  The "app installing" tile shown on the home screen while a download/sign is
//  in progress. Matches the FlekSign design: a dimmed app icon with a centered
//  percentage + progress bar while downloading, or a round spinner during
//  intermediate steps (request / decompress / signing).
//

import SwiftUI

private let flekBlue = Color(red: 0/255, green: 117/255, blue: 255/255)

/// Dimmed-icon + progress overlay, reused by the grid card and the list row.
struct FlekInstallIcon: View {
    let state: FlekInstallState
    var size: CGFloat
    var corner: CGFloat

    var body: some View {
        ZStack {
            Group {
                if let urlStr = state.iconURL, let url = URL(string: urlStr) {
                    AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: {
                        Color(white: 0.85)
                    }
                } else {
                    Color(white: 0.85)
                }
            }
            .overlay(Color.black.opacity(0.5))

            if state.indeterminate {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(size > 60 ? 1.4 : 1.0)
            } else {
                // Centered percentage (Figma: bold 18, white, centered on the icon)
                Text("\(Int((state.fraction * 100).rounded()))%")
                    .font(.system(size: size > 60 ? 18 : 13, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottom) {
            // Progress pill near the bottom of the icon (only on the large grid icon)
            if !state.indeterminate && size > 60 {
                let trackW = size * 0.78          // ≈ 58 on a 74pt icon
                let trackH: CGFloat = 18
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(Capsule().fill(Color.white.opacity(0.5)))
                        .frame(width: trackW, height: trackH)
                    Capsule()
                        .fill(flekBlue)
                        .frame(width: max(trackH - 4, (trackW - 4) * state.fraction), height: trackH - 4)
                        .padding(.leading, 2)
                }
                .padding(.bottom, 6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// Springboard grid card for the in-progress install.
struct FlekInstallingCard: View {
    let state: FlekInstallState

    var body: some View {
        VStack(spacing: FlekTheme.cardInnerSpacing) {
            FlekInstallIcon(state: state, size: FlekTheme.iconSize, corner: FlekTheme.iconCorner)
            Text(state.name ?? "lc.flek.installing".loc)
                .font(.system(size: FlekTheme.labelSize, weight: .medium))
                .foregroundStyle(.black)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.top, FlekTheme.cardTopPadding)
        .padding(.bottom, FlekTheme.cardBottomPadding)
        .padding(.horizontal, FlekTheme.cardHPadding)
        .frame(maxWidth: .infinity)
        .frame(height: FlekTheme.cardHeight)
        .flekGlassCard()
    }
}
