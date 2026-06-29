//
//  FlekHomeListView.swift
//  LiveContainerSwiftUI
//
//  The "List" home screen layout (Personalization → Home Screen Layout → List).
//  Shows the same items as the springboard as glass rows with a RUN button.
//  Uses Dragula for smooth drag-and-drop reordering in edit mode.
//

import SwiftUI
import UniformTypeIdentifiers

struct FlekHomeListView<Menu: View>: View {
    @Binding var items: [FlekHomeItem]
    let darkModeIcon: Bool
    @Binding var isEditing: Bool
    var isNew: (LCAppModel) -> Bool
    var onTap: (FlekHomeItem) -> Void
    var onDelete: (FlekHomeItem) -> Void
    var onDropCompleted: () -> Void = {}
    var installState: FlekInstallState = FlekInstallState(name: nil, iconURL: nil, fraction: 0, indeterminate: true)
    var onCancelInstall: () -> Void = {}
    @ViewBuilder var contextMenu: (FlekHomeItem) -> Menu

    @State private var draggedItem: FlekHomeItem?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(items) { item in
                    if isEditing {
                        editRowWithDrag(for: item)
                    } else {
                        rowButton(for: item)
                    }
                }
            }
            .padding(.horizontal, FlekTheme.screenHPadding)
            .padding(.top, 8)
        }
    }

    // MARK: - Edit Mode Row (DraggableView-backed)

    @ViewBuilder
    private func editRowWithDrag(for item: FlekHomeItem) -> some View {
        if case .installing = item {
            FlekInstallRow(state: installState)
        } else if item.isDraggable {
            editRow(for: item)
                .hidden()
                .overlay {
                    DraggableView(
                        preview: { editRow(for: item) },
                        dropView: { rowDropPlaceholder() },
                        itemProvider: { item.getItemProvider() },
                        onDragWillBegin: { draggedItem = item },
                        onDragWillEnd: {
                            draggedItem = nil
                            onDropCompleted()
                        }
                    )
                }
                .onDrop(of: [UTType.text], delegate: SpringboardReorderDelegate(
                    item: item,
                    items: $items,
                    draggedItem: $draggedItem
                ))
                .environment(\.dragPreviewCornerRadius, 20)
        } else {
            editRow(for: item)
        }
    }

    @ViewBuilder
    private func editRow(for item: FlekHomeItem) -> some View {
        FlekAppRow(
            title: title(for: item),
            subtitle: subtitle(for: item),
            isNew: newDot(for: item),
            isEditing: true,
            canDelete: canDelete(item),
            onRun: {},
            onDelete: { onDelete(item) },
            icon: { iconView(for: item) }
        )
    }

    /// Placeholder shown while a row is being dragged.
    @ViewBuilder
    private func rowDropPlaceholder() -> some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color.white.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1, antialiased: true)
            )
            .frame(height: 68)
    }

    // MARK: - Normal Mode Row (tappable with context menu)

    @ViewBuilder
    private func rowButton(for item: FlekHomeItem) -> some View {
        if case .installing = item {
            FlekInstallRow(state: installState)
                .contextMenu {
                    Button(role: .destructive) { onCancelInstall() } label: {
                        Label("lc.flek.cancelInstall".loc, systemImage: "xmark.circle")
                    }
                }
        } else {
            FlekAppRow(
                title: title(for: item),
                subtitle: subtitle(for: item),
                isNew: newDot(for: item),
                isEditing: false,
                canDelete: canDelete(item),
                onRun: { onTap(item) },
                onDelete: { onDelete(item) },
                icon: { iconView(for: item) }
            )
            .contextMenu { contextMenu(item) }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func iconView(for item: FlekHomeItem) -> some View {
        switch item {
        case .defaultApp(let kind):
            Image(kind.iconAssetName).resizable().scaledToFill()
        case .installed(let app):
            Image(uiImage: app.appInfo.iconIsDarkIcon(darkModeIcon)).resizable().scaledToFill()
        case .installing:
            Color.clear
        }
    }

    private func title(for item: FlekHomeItem) -> String {
        switch item {
        case .defaultApp(let kind): return kind.title
        case .installed(let app): return app.appInfo.displayName() ?? "?"
        case .installing: return installState.name ?? ""
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
        HStack(spacing: 14) {
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
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if isNew {
                        Circle().fill(Color.blue).frame(width: 7, height: 7)
                    }
                    Text(title)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if isEditing {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.tertiary)
            } else {
                Button(action: onRun) {
                    Text("lc.appBanner.run".loc)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.85))
                        .padding(.horizontal, 16)
                        .frame(height: 30)
                        .background(
                            Capsule()
                                .fill(.ultraThinMaterial)
                                .overlay(Capsule().fill(Color.white.opacity(0.35)))
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.4), lineWidth: 0.5))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 68)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
        }
    }
}

/// List-layout row for the in-progress install.
struct FlekInstallRow: View {
    let state: FlekInstallState

    var body: some View {
        HStack(spacing: 14) {
            FlekInstallIcon(state: state, size: 48, corner: 12)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.name ?? "lc.flek.installing".loc)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if state.indeterminate {
                    Text("lc.flek.installing".loc)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView(value: state.fraction).tint(Color(red: 0, green: 117/255, blue: 1))
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "xmark.circle.fill").font(.system(size: 22)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(height: 68)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
        }
    }
}
