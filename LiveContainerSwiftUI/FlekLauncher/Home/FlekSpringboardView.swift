//
//  FlekSpringboardView.swift
//  LiveContainerSwiftUI
//
//  The iOS-style home screen grid of app cards. Uses Dragula for smooth
//  UIKit-backed drag-and-drop reordering of all cards (including built-in
//  apps like Settings and Installer). Paginated in normal mode, scrollable
//  in edit mode for full drag support.
//

import SwiftUI
import UniformTypeIdentifiers

struct FlekSpringboardView<Menu: View>: View {
    @Binding var items: [FlekHomeItem]
    let darkModeIcon: Bool
    @Binding var isEditing: Bool
    var isNew: (LCAppModel) -> Bool
    var isSingleMode: (LCAppModel) -> Bool
    var onTap: (FlekHomeItem) -> Void
    var onDelete: (FlekHomeItem) -> Void
    var onDropCompleted: () -> Void = {}
    var installState: FlekInstallState = FlekInstallState(name: nil, iconURL: nil, fraction: 0, indeterminate: true)
    var onCancelInstall: () -> Void = {}
    @ViewBuilder var contextMenu: (FlekHomeItem) -> Menu

    @State private var currentPage = 0
    @State private var draggedItems: [FlekHomeItem] = []

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: FlekTheme.gridSpacing),
              count: FlekTheme.gridColumns)
    }

    var body: some View {
        GeometryReader { geo in
            let spacing = FlekTheme.gridSpacing
            let reserve: CGFloat = 34
            let available = max(FlekTheme.cardHeight, geo.size.height - reserve)
            let baseRow = FlekTheme.cardHeight + spacing
            let fitRows = max(1, Int((available + spacing) / baseRow))
            let rows = max(5, fitRows)
            let cardHeight = min(FlekTheme.cardHeight, (available - CGFloat(rows - 1) * spacing) / CGFloat(rows))
            let perPage = max(1, rows * FlekTheme.gridColumns)

            if isEditing {
                // Scrollable grid during edit mode for Dragula drag-and-drop
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .center, spacing: spacing) {
                        DragulaView(items: $items) { item in
                            editCard(for: item, cardHeight: cardHeight)
                        } dropView: { item in
                            cardDropPlaceholder(cardHeight: cardHeight)
                        } dropCompleted: {
                            onDropCompleted()
                        }
                    }
                    .padding(.horizontal, FlekTheme.screenHPadding)
                }
                .environment(\.dragPreviewCornerRadius, FlekTheme.cardCorner)
            } else {
                // Paginated grid for normal browsing
                let pages = chunk(items, size: perPage)

                VStack(spacing: 8) {
                    TabView(selection: $currentPage) {
                        ForEach(Array(pages.enumerated()), id: \.offset) { index, pageItems in
                            LazyVGrid(columns: columns, alignment: .center, spacing: spacing) {
                                ForEach(pageItems) { item in
                                    cardButton(for: item, cardHeight: cardHeight)
                                }
                            }
                            .padding(.horizontal, FlekTheme.screenHPadding)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))

                    if pages.count > 1 {
                        FlekPageIndicator(count: pages.count, current: currentPage)
                            .padding(.bottom, 4)
                    }
                }
            }
        }
    }

    // MARK: - Edit Mode Card (used by DragulaView)

    @ViewBuilder
    private func editCard(for item: FlekHomeItem, cardHeight: CGFloat) -> some View {
        if case .installing = item {
            FlekInstallingCard(state: installState, cardHeight: cardHeight)
        } else {
            FlekAppCard(
                title: title(for: item),
                isNew: newDot(for: item),
                showsSingleModeBadge: singleBadge(for: item),
                isEditing: true,
                canDelete: canDelete(item),
                cardHeight: cardHeight,
                onDelete: { onDelete(item) },
                icon: { iconView(for: item) }
            )
        }
    }

    /// Ghost placeholder shown in the original position while a card is being dragged.
    @ViewBuilder
    private func cardDropPlaceholder(cardHeight: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: FlekTheme.cardCorner, style: .continuous)
            .fill(Color.white.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: FlekTheme.cardCorner, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1, antialiased: true)
            )
            .frame(height: cardHeight)
    }

    // MARK: - Normal Mode Card (tappable with context menu)

    @ViewBuilder
    private func cardButton(for item: FlekHomeItem, cardHeight: CGFloat) -> some View {
        if case .installing = item {
            FlekInstallingCard(state: installState, cardHeight: cardHeight)
                .contextMenu {
                    Button(role: .destructive) {
                        onCancelInstall()
                    } label: {
                        Label("lc.flek.cancelInstall".loc, systemImage: "xmark.circle")
                    }
                }
        } else {
            let card = FlekAppCard(
                title: title(for: item),
                isNew: newDot(for: item),
                showsSingleModeBadge: singleBadge(for: item),
                isEditing: false,
                canDelete: canDelete(item),
                cardHeight: cardHeight,
                onDelete: { onDelete(item) },
                icon: { iconView(for: item) }
            )

            Button {
                onTap(item)
            } label: {
                card
            }
            .buttonStyle(.plain)
            .contextMenu { contextMenu(item) }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func iconView(for item: FlekHomeItem) -> some View {
        switch item {
        case .defaultApp(let kind):
            Image(kind.iconAssetName)
                .resizable()
                .scaledToFill()
        case .installed(let app):
            Image(uiImage: app.appInfo.iconIsDarkIcon(darkModeIcon))
                .resizable()
                .scaledToFill()
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

    private func newDot(for item: FlekHomeItem) -> Bool {
        if case .installed(let app) = item { return isNew(app) }
        return false
    }

    private func singleBadge(for item: FlekHomeItem) -> Bool {
        if case .installed(let app) = item { return isSingleMode(app) }
        return false
    }

    private func canDelete(_ item: FlekHomeItem) -> Bool {
        if case .installed = item { return true }
        return false // built-in apps cannot be removed
    }

    private func chunk<T>(_ array: [T], size: Int) -> [[T]] {
        guard size > 0 else { return [array] }
        if array.isEmpty { return [[]] }
        return stride(from: 0, to: array.count, by: size).map {
            Array(array[$0 ..< min($0 + size, array.count)])
        }
    }
}

/// Simple iOS-style page dots.
struct FlekPageIndicator: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0 ..< count, id: \.self) { i in
                Circle()
                    .fill(Color.white.opacity(i == current ? 0.95 : 0.4))
                    .frame(width: 7, height: 7)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
