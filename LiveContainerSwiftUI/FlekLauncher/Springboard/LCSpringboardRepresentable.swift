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
    var installState: FlekInstallState
    var onTap: (FlekHomeItem) -> Void
    var onDelete: (FlekHomeItem) -> Void
    var onReorder: () -> Void
    @Binding var scrollToPage: Int?

    func makeUIViewController(context: Context) -> LCSpringboardViewController {
        let vc = LCSpringboardViewController()
        vc.darkModeIcon = darkModeIcon
        vc.installState = installState
        vc.onTap = onTap
        vc.onDelete = onDelete
        vc.onReorder = { [self] newItems in
            items = newItems
            onReorder()
        }
        vc.onEditingChanged = { editing in
            isEditing = editing
        }
        return vc
    }

    func updateUIViewController(_ vc: LCSpringboardViewController, context: Context) {
        // Only call updateItems when the SET of items changes
        // (app added/removed), not when order changes (reorder).
        // Compare as sets so reorder doesn't trigger re-pagination.
        if !vc.dragManager.isDragging {
            let currentSet = Set(vc.flatItems.map(\.id))
            let newSet = Set(items.map(\.id))
            if currentSet != newSet {
                vc.updateItems(items)
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

        // Install state (progress updates frequently during download)
        vc.installState = installState
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
