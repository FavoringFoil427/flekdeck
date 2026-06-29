//
//  FlekSpringboardView.swift
//  LiveContainerSwiftUI
//
//  iOS-style paged home screen grid. Uses Dragula's DraggableView for smooth
//  UIKit-backed drag interactions. Supports cross-page icon movement via
//  edge auto-scroll zones (0.7 s timer, mirroring real SpringBoard).
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
    @State private var draggedItem: FlekHomeItem?
    @State private var edgeScrollTimer: Timer?

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
            let pages = paginatedItems(perPage: perPage)

            VStack(spacing: 8) {
                TabView(selection: $currentPage) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, pageItems in
                        ZStack {
                            LazyVGrid(columns: columns, alignment: .center, spacing: spacing) {
                                ForEach(pageItems) { item in
                                    if isEditing {
                                        editCardWithDrag(for: item, cardHeight: cardHeight)
                                    } else {
                                        cardButton(for: item, cardHeight: cardHeight)
                                    }
                                }
                            }
                            .padding(.horizontal, FlekTheme.screenHPadding)
                            .frame(maxHeight: .infinity, alignment: .top)

                            // Edge drop zones for cross-page auto-scroll
                            if isEditing {
                                edgeZones(pageIndex: index, pageCount: pages.count)
                            }
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                if pages.count > 1 || isEditing {
                    FlekPageIndicator(count: pages.count, current: currentPage)
                        .padding(.bottom, 4)
                }
            }
            .onChange(of: isEditing) { editing in
                if !editing {
                    // Exiting edit mode: clean up empty trailing pages
                    edgeScrollTimer?.invalidate()
                    edgeScrollTimer = nil
                    draggedItem = nil
                    // Clamp page if empty pages were removed
                    let newPages = chunk(items, size: perPage)
                    if currentPage >= newPages.count {
                        currentPage = max(0, newPages.count - 1)
                    }
                }
            }
        }
    }

    // MARK: - Pagination

    /// Chunks items into pages. In edit mode, ensures an empty trailing page
    /// exists so the user can drag icons to create a new screen.
    private func paginatedItems(perPage: Int) -> [[FlekHomeItem]] {
        var pages = chunk(items, size: perPage)
        if isEditing {
            if pages.isEmpty || (pages.last?.count ?? 0) > 0 {
                pages.append([])
            }
        }
        return pages
    }

    // MARK: - Edge Auto-Scroll Zones

    /// Invisible drop targets at the left/right edges of each page that
    /// trigger timed auto-scroll to adjacent pages during drag, mirroring
    /// iOS SpringBoard's 0.7 s edge dwell behaviour.
    @ViewBuilder
    private func edgeZones(pageIndex: Int, pageCount: Int) -> some View {
        HStack(spacing: 0) {
            // Left edge
            Color.clear
                .frame(width: 36)
                .contentShape(Rectangle())
                .onDrop(of: [UTType.text], delegate: EdgeScrollDelegate(
                    direction: -1,
                    currentPage: $currentPage,
                    maxPage: pageCount,
                    onStartTimer: { dir in startEdgeTimer(direction: dir) },
                    onCancelTimer: { cancelEdgeTimer() }
                ))

            Spacer()

            // Right edge
            Color.clear
                .frame(width: 36)
                .contentShape(Rectangle())
                .onDrop(of: [UTType.text], delegate: EdgeScrollDelegate(
                    direction: 1,
                    currentPage: $currentPage,
                    maxPage: pageCount,
                    onStartTimer: { dir in startEdgeTimer(direction: dir) },
                    onCancelTimer: { cancelEdgeTimer() }
                ))
        }
    }

    private func startEdgeTimer(direction: Int) {
        guard edgeScrollTimer == nil else { return }
        edgeScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { _ in
            let nextPage = currentPage + direction
            guard nextPage >= 0 else { edgeScrollTimer = nil; return }
            withAnimation {
                currentPage = nextPage
            }
            edgeScrollTimer = nil
        }
    }

    private func cancelEdgeTimer() {
        edgeScrollTimer?.invalidate()
        edgeScrollTimer = nil
    }

    // MARK: - Edit Mode Card (DraggableView-backed)

    @ViewBuilder
    private func editCardWithDrag(for item: FlekHomeItem, cardHeight: CGFloat) -> some View {
        if case .installing = item {
            FlekInstallingCard(state: installState, cardHeight: cardHeight)
        } else if item.isDraggable {
            editCard(for: item, cardHeight: cardHeight)
                .hidden()
                .overlay {
                    DraggableView(
                        preview: { editCard(for: item, cardHeight: cardHeight) },
                        dropView: { cardDropPlaceholder(cardHeight: cardHeight) },
                        itemProvider: { item.getItemProvider() },
                        onDragWillBegin: { draggedItem = item },
                        onDragWillEnd: {
                            draggedItem = nil
                            cancelEdgeTimer()
                            onDropCompleted()
                        }
                    )
                }
                .onDrop(of: [UTType.text], delegate: SpringboardReorderDelegate(
                    item: item,
                    items: $items,
                    draggedItem: $draggedItem
                ))
                .environment(\.dragPreviewCornerRadius, FlekTheme.cardCorner)
        } else {
            editCard(for: item, cardHeight: cardHeight)
        }
    }

    @ViewBuilder
    private func editCard(for item: FlekHomeItem, cardHeight: CGFloat) -> some View {
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

    /// Ghost placeholder shown in the original position while a card is dragged.
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

    // MARK: - Normal Mode Card

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
        return false
    }

    private func chunk<T>(_ array: [T], size: Int) -> [[T]] {
        guard size > 0 else { return [array] }
        if array.isEmpty { return [[]] }
        return stride(from: 0, to: array.count, by: size).map {
            Array(array[$0 ..< min($0 + size, array.count)])
        }
    }
}

// MARK: - Drop Delegates

/// Reorders items in the flat array as one is dragged over another.
/// Works across pages since both items are looked up by ID in the full array.
struct SpringboardReorderDelegate: DropDelegate {
    let item: FlekHomeItem
    @Binding var items: [FlekHomeItem]
    @Binding var draggedItem: FlekHomeItem?

    private let generator = UIImpactFeedbackGenerator(style: .rigid)

    func dropEntered(info: DropInfo) {
        guard let dragged = draggedItem, dragged.id != item.id else { return }
        guard let fromIndex = items.firstIndex(where: { $0.id == dragged.id }),
              let toIndex = items.firstIndex(where: { $0.id == item.id }) else { return }

        withAnimation(.spring) {
            items.move(fromOffsets: IndexSet(integer: fromIndex),
                       toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        }

        generator.prepare()
        generator.impactOccurred()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedItem != nil
    }
}

/// Detects drag-dwell at the left/right screen edge and triggers timed
/// auto-scroll to the adjacent page (0.7 s, matching iOS SpringBoard).
struct EdgeScrollDelegate: DropDelegate {
    let direction: Int
    @Binding var currentPage: Int
    let maxPage: Int
    let onStartTimer: (Int) -> Void
    let onCancelTimer: () -> Void

    func dropEntered(info: DropInfo) {
        let nextPage = currentPage + direction
        guard nextPage >= 0 && nextPage < maxPage else { return }
        onStartTimer(direction)
    }

    func dropExited(info: DropInfo) {
        onCancelTimer()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        false
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
