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
    var isNew: (LCAppModel) -> Bool
    var onTap: (FlekHomeItem) -> Void
    var onDelete: (FlekHomeItem) -> Void
    var onReorder: () -> Void
    @Binding var scrollToPage: Int?

    func makeUIViewController(context: Context) -> LCSpringboardViewController {
        let vc = LCSpringboardViewController()
        vc.darkModeIcon = darkModeIcon
        vc.isNewCheck = isNew
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
        // Update items if they changed
        let currentIds = vc.flatItems.map(\.id)
        let newIds = items.map(\.id)
        if currentIds != newIds {
            vc.updateItems(items)
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

        // Closures that may have captured new state
        vc.isNewCheck = isNew
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
