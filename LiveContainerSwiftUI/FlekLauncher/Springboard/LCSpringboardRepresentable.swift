//
//  LCSpringboardRepresentable.swift
//  LiveContainerSwiftUI
//
//  UIViewControllerRepresentable bridge wrapping LCSpringboardViewController
//  for use inside LCAppListView, replacing FlekSpringboardView.
//

import SwiftUI

struct LCSpringboardRepresentable: UIViewControllerRepresentable {

    @Binding var items: [FlekHomeItem]
    let darkModeIcon: Bool
    @Binding var isEditing: Bool
    var onTap: (FlekHomeItem) -> Void
    var onDelete: (FlekHomeItem) -> Void
    var onReorder: () -> Void
    var contextMenuProvider: ((FlekHomeItem) -> UIMenu?)?
    var onPageSettled: (() -> Void)?
    @Binding var scrollToPage: Int?

    func makeUIViewController(context: Context) -> LCSpringboardViewController {
        let vc = LCSpringboardViewController()
        vc.darkModeIcon = darkModeIcon
        vc.onTap = onTap
        vc.onDelete = onDelete
        vc.onReorder = { [self] newItems in
            items = newItems
            onReorder()
        }
        vc.onEditingChanged = { editing in
            isEditing = editing
        }
        vc.contextMenuProvider = contextMenuProvider
        vc.onPageSettled = onPageSettled
        return vc
    }

    func updateUIViewController(_ vc: LCSpringboardViewController, context: Context) {
        // Always store the latest items so viewWillAppear can catch up
        // after being hidden behind a fullScreenCover.
        vc.pendingItems = items

        // Only call updateItems when the SET of items changes
        // (app added/removed), not when order changes (reorder).
        // Compare as sets so reorder doesn't trigger re-pagination.
        if !vc.dragManager.isDragging {
            let currentSet = Set(vc.flatItems.map(\.id))
            let newSet = Set(items.map(\.id))
            if currentSet != newSet {
                vc.updateItems(items)
                vc.pendingItems = nil
            }
        }

        // Sync editing state (may be toggled from SwiftUI "Done" button)
        if vc.isInEditMode != isEditing {
            vc.setEditing(isEditing)
        }

        // Dark mode icon
        if vc.darkModeIcon != darkModeIcon {
            vc.darkModeIcon = darkModeIcon
            vc.outerCollectionView?.reloadData()
        }

        // Install progress (the VC observes the queue directly for
        // frequent progress ticks; this call handles structural changes)
        vc.updateInstallProgress()

        // Closures that may have captured new state
        vc.onTap = onTap
        vc.onDelete = onDelete
        vc.onReorder = { [self] newItems in
            items = newItems
            onReorder()
        }
        vc.onEditingChanged = { editing in
            isEditing = editing
        }
        vc.contextMenuProvider = contextMenuProvider
        vc.onPageSettled = onPageSettled

        // Scroll-to-page request from SwiftUI
        if let page = scrollToPage {
            DispatchQueue.main.async {
                scrollToPage = nil
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                vc.scrollToPage(page)
            }
        }
    }
}
