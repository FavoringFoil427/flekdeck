//
//  FlekHomeListView.swift
//  LiveContainerSwiftUI
//
//  The "List" home screen layout (Personalization → Home Screen Layout → List).
//  Shows the same items as the springboard as glass rows with a RUN button.
//

import SwiftUI

struct FlekHomeListView<Menu: View>: View {
    let items: [FlekHomeItem]
    let darkModeIcon: Bool
    @Binding var isEditing: Bool
    var isNew: (LCAppModel) -> Bool
    var onTap: (FlekHomeItem) -> Void
    var onDelete: (FlekHomeItem) -> Void
    @ViewBuilder var contextMenu: (FlekHomeItem) -> Menu

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(items) { item in
                    FlekAppRow(
                        title: title(for: item),
                        subtitle: subtitle(for: item),
                        isNew: newDot(for: item),
                        isEditing: isEditing,
                        canDelete: canDelete(item),
                        onRun: { onTap(item) },
                        onDelete: { onDelete(item) },
                        icon: { iconView(for: item) }
                    )
                    .contextMenu { contextMenu(item) }
                }
            }
            .padding(.horizontal, FlekTheme.screenHPadding)
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func iconView(for item: FlekHomeItem) -> some View {
        switch item {
        case .defaultApp(let kind):
            Image(kind.iconAssetName).resizable().scaledToFill()
        case .installed(let app):
            Image(uiImage: app.appInfo.iconIsDarkIcon(darkModeIcon)).resizable().scaledToFill()
        }
    }

    private func title(for item: FlekHomeItem) -> String {
        switch item {
        case .defaultApp(let kind): return kind.title
        case .installed(let app): return app.appInfo.displayName() ?? "?"
        }
    }

    private func subtitle(for item: FlekHomeItem) -> String? {
        if case .installed(let app) = item {
            return "\(app.appInfo.version() ?? "?") - \(app.appInfo.bundleIdentifier() ?? "?")"
        }
        return nil
    }

    private func newDot(for item: FlekHomeItem) -> Bool {
        if case .installed(let app) = item { return isNew(app) }
        return false
    }

    private func canDelete(_ item: FlekHomeItem) -> Bool {
        if case .installed = item { return true }
        return false
    }
}

struct FlekAppRow<Icon: View>: View {
    let title: String
    var subtitle: String?
    var isNew: Bool = false
    var isEditing: Bool = false
    var canDelete: Bool = true
    var onRun: () -> Void
    var onDelete: () -> Void
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        HStack(spacing: 12) {
            if isEditing && canDelete {
                Button(action: onDelete) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 22))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }

            icon()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if isNew {
                        Circle().fill(Color.blue).frame(width: 7, height: 7)
                    }
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.black)
                        .lineLimit(1)
                }
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.black.opacity(0.55))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if isEditing {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.black.opacity(0.35))
            } else {
                Button(action: onRun) {
                    Text("lc.appBanner.run".loc)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.black.opacity(0.8))
                        .padding(.horizontal, 18)
                        .frame(height: 32)
                        .background(Capsule().fill(Color.white.opacity(0.55)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 72)
        .flekGlassCard(cornerRadius: 18)
    }
}
