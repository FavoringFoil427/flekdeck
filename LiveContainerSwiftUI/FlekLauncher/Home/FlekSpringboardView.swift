//
//  FlekSpringboardView.swift
//  LiveContainerSwiftUI
//
//  The iOS-style paged home screen grid of app cards. Built-in apps come
//  first, followed by installed guest apps. When the apps overflow a page a
//  new horizontal page is created with a page indicator, mirroring iOS.
//

import SwiftUI
import UniformTypeIdentifiers

struct FlekSpringboardView<Menu: View>: View {
    let items: [FlekHomeItem]
    let darkModeIcon: Bool
    @Binding var isEditing: Bool
    var isNew: (LCAppModel) -> Bool
    var isSingleMode: (LCAppModel) -> Bool
    var onTap: (FlekHomeItem) -> Void
    var onDelete: (FlekHomeItem) -> Void
    var onMove: (FlekHomeItem, FlekHomeItem) -> Void = { _, _ in }
    @ViewBuilder var contextMenu: (FlekHomeItem) -> Menu

    @State private var currentPage = 0
    @State private var dragging: FlekHomeItem?

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: FlekTheme.gridSpacing),
              count: FlekTheme.gridColumns)
    }

    var body: some View {
        GeometryReader { geo in
            let rowHeight = FlekTheme.cardHeight + FlekTheme.gridSpacing
            let rowsPerPage = max(1, Int((geo.size.height + FlekTheme.gridSpacing) / rowHeight))
            let perPage = max(1, rowsPerPage * FlekTheme.gridColumns)
            let pages = chunk(items, size: perPage)

            VStack(spacing: 8) {
                TabView(selection: $currentPage) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, pageItems in
                        LazyVGrid(columns: columns, alignment: .center, spacing: FlekTheme.gridSpacing) {
                            ForEach(pageItems) { item in
                                cardButton(for: item)
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

    @ViewBuilder
    private func cardButton(for item: FlekHomeItem) -> some View {
        let card = FlekAppCard(
            title: title(for: item),
            isNew: newDot(for: item),
            showsSingleModeBadge: singleBadge(for: item),
            isEditing: isEditing,
            canDelete: canDelete(item),
            onDelete: { onDelete(item) },
            icon: { iconView(for: item) }
        )

        Button {
            if isEditing { return }
            onTap(item)
        } label: {
            card
        }
        .buttonStyle(.plain)
        .contextMenu { contextMenu(item) }
        .apply { v in
            if isEditing, case .installed = item {
                v.onDrag {
                    dragging = item
                    return NSItemProvider(object: item.id as NSString)
                }
                .onDrop(of: [UTType.text], delegate: FlekReorderDropDelegate(item: item, dragging: $dragging, onMove: onMove))
            } else {
                v
            }
        }
    }

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
        }
    }

    private func title(for item: FlekHomeItem) -> String {
        switch item {
        case .defaultApp(let kind): return kind.title
        case .installed(let app): return app.appInfo.displayName() ?? "?"
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

/// Reorders installed app cards live as one is dragged over another.
struct FlekReorderDropDelegate: DropDelegate {
    let item: FlekHomeItem
    @Binding var dragging: FlekHomeItem?
    let onMove: (FlekHomeItem, FlekHomeItem) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging.id != item.id else { return }
        if case .installed = item { onMove(dragging, item) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
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
