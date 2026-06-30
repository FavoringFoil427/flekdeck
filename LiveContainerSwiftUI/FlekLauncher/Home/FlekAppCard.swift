//
//  FlekAppCard.swift
//  LiveContainerSwiftUI
//
//  A single springboard tile: a frosted glass card holding an app icon and
//  its label. Used for both built-in apps and installed guest apps.
//

import SwiftUI

struct FlekAppCard<Icon: View>: View {
    let title: String
    /// Shows the blue "new / not yet launched" dot before the title.
    var isNew: Bool = false
    /// Shows the single-mode (non-multitask) launch badge on the icon.
    var showsSingleModeBadge: Bool = false
    /// Whether the card is wiggling in edit mode.
    var isEditing: Bool = false
    /// Shows the delete (–) button in edit mode (hidden for default apps).
    var canDelete: Bool = true
    /// Height the card should occupy; the contents scale to fit it.
    var cardHeight: CGFloat = FlekTheme.cardHeight
    var onDelete: (() -> Void)? = nil
    @ViewBuilder var icon: () -> Icon

    @State private var wigglePhase = false
    /// Random delay so each card wiggles at a different phase, like real iOS.
    @State private var wiggleDelay: Double = 0

    private var scale: CGFloat { cardHeight / FlekTheme.cardHeight }

    var body: some View {
        VStack(spacing: FlekTheme.cardInnerSpacing * scale) {
            ZStack(alignment: .topTrailing) {
                icon()
                    .frame(width: FlekTheme.iconSize * scale, height: FlekTheme.iconSize * scale)
                    .clipShape(RoundedRectangle(cornerRadius: FlekTheme.iconCorner * scale, style: .continuous))

                if showsSingleModeBadge {
                    Image(systemName: "1.circle.fill")
                        .font(.system(size: 16 * scale))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .background(Circle().fill(Color.white))
                        .offset(x: 6, y: -6)
                }
            }

            HStack(spacing: 4) {
                if isNew {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 7 * scale, height: 7 * scale)
                }
                Text(title)
                    .font(.system(size: FlekTheme.labelSize * scale, weight: .medium))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.top, FlekTheme.cardTopPadding * scale)
        .padding(.bottom, FlekTheme.cardBottomPadding * scale)
        .padding(.horizontal, FlekTheme.cardHPadding)
        .frame(maxWidth: .infinity)
        .frame(height: cardHeight)
        .flekGlassCard(cornerRadius: FlekTheme.cardCorner * min(1, scale))
        .overlay(alignment: .topLeading) {
            if isEditing && canDelete {
                Button {
                    onDelete?()
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color(white: 0.85)))
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .offset(x: -6, y: -6)
                .transition(.scale.combined(with: .opacity))
            }
        }
        // Gentle jiggle: small rotation, no position offset to avoid cards touching.
        .rotationEffect(.degrees(isEditing ? (wigglePhase ? 0.5 : -0.5) : 0))
        .animation(isEditing
                   ? .easeInOut(duration: 0.2).repeatForever(autoreverses: true).delay(wiggleDelay)
                   : .default,
                   value: wigglePhase)
        .onChange(of: isEditing) { editing in
            wigglePhase = editing
        }
        .onAppear {
            wiggleDelay = Double.random(in: 0...0.24)
            if isEditing { wigglePhase = true }
        }
    }
}
