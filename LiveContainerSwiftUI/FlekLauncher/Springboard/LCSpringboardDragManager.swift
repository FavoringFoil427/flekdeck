//
//  LCSpringboardDragManager.swift
//  LiveContainerSwiftUI
//
//  Drag-and-drop state machine for the UIKit springboard.
//  Adapted from jSpringBoard's AppGridManager+DragOperations.
//  Handles: long press → snapshot → move → cross-page scroll → drop.
//

import UIKit

// MARK: - Drag operation state

final class LCDragOperation {
    let itemId: String
    let placeholderView: UIView
    let dragOffset: CGSize
    let originalPage: Int
    let originalIndex: Int
    var currentPage: Int
    var currentIndex: Int
    /// Set to true when a page scroll is in progress and the target page cell
    /// needs to adopt this drag operation in `willDisplay`.
    var needsUpdate: Bool = false

    init(itemId: String, placeholderView: UIView, dragOffset: CGSize,
         originalPage: Int, originalIndex: Int) {
        self.itemId = itemId
        self.placeholderView = placeholderView
        self.dragOffset = dragOffset
        self.originalPage = originalPage
        self.originalIndex = originalIndex
        self.currentPage = originalPage
        self.currentIndex = originalIndex
    }
}

// MARK: - Drag manager

final class LCSpringboardDragManager {

    weak var viewController: LCSpringboardViewController?

    private(set) var currentOperation: LCDragOperation?
    private var pageScrollTimer: Timer?
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)

    // Edge detection
    private let edgeMargin: CGFloat = 36
    private let pageScrollDelay: TimeInterval = 0.7

    var isDragging: Bool { currentOperation != nil }

    // MARK: - Gesture handler

    func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            beginDrag(gesture)
        case .changed:
            updateDrag(gesture)
        default:
            endDrag(gesture)
        }
    }

    // MARK: - Begin

    private func beginDrag(_ gesture: UILongPressGestureRecognizer) {
        guard let vc = viewController else { return }

        feedbackGenerator.prepare()

        // Find which page cell and inner icon cell was touched
        let touchInView = gesture.location(in: vc.view)
        guard let (pageIndex, pageCell) = vc.pageCellAtPoint(touchInView) else { return }

        let touchInPage = gesture.location(in: pageCell.collectionView)
        guard let indexPath = pageCell.collectionView.indexPathForItem(at: touchInPage),
              let iconCell = pageCell.collectionView.cellForItem(at: indexPath) as? LCSpringboardIconCell,
              !iconCell.isPlaceholderCell else { return }

        let item = pageCell.items[indexPath.item]
        guard item.isDraggable else { return }

        // Calculate drag offset so the snapshot stays centered under touch
        let dragOffset = CGSize(
            width: iconCell.center.x - touchInPage.x,
            height: iconCell.center.y - touchInPage.y
        )

        // Create snapshot
        let snapshot = iconCell.snapshotView(afterScreenUpdates: true) ?? UIView(frame: iconCell.bounds)
        var snapshotCenter = touchInView
        snapshotCenter.x += dragOffset.width
        snapshotCenter.y += dragOffset.height
        snapshot.center = snapshotCenter
        vc.view.addSubview(snapshot)

        // Hide original
        iconCell.contentView.isHidden = true

        // Enter edit mode
        if !vc.isInEditMode {
            vc.setEditing(true, fromDrag: true)
        }

        feedbackGenerator.impactOccurred()

        UIView.animate(withDuration: 0.25) {
            snapshot.transform = CGAffineTransform(scaleX: 1.3, y: 1.3)
            snapshot.alpha = 0.8
        }

        currentOperation = LCDragOperation(
            itemId: item.id,
            placeholderView: snapshot,
            dragOffset: dragOffset,
            originalPage: pageIndex,
            originalIndex: indexPath.item
        )

        // Tell page cell which item is dragged
        pageCell.draggedItemId = item.id
    }

    // MARK: - Update

    private func updateDrag(_ gesture: UILongPressGestureRecognizer) {
        guard let vc = viewController, let op = currentOperation else { return }

        let touchInView = gesture.location(in: vc.view)

        // Move snapshot to follow touch
        var snapshotCenter = touchInView
        snapshotCenter.x += op.dragOffset.width
        snapshotCenter.y += op.dragOffset.height
        op.placeholderView.center = snapshotCenter

        if op.needsUpdate {
            return
        }

        // Check edge zones for page scrolling
        let outerCV = vc.outerCollectionView!
        let touchInOuter = gesture.location(in: outerCV)
        let pageWidth = outerCV.bounds.width

        let leftEdge = outerCV.contentOffset.x + edgeMargin
        let rightEdge = outerCV.contentOffset.x + pageWidth - edgeMargin

        if touchInOuter.x < leftEdge && op.currentPage > 0 {
            if pageScrollTimer == nil {
                startPageScrollTimer(direction: -1)
            }
            return
        } else if touchInOuter.x > rightEdge && op.currentPage < vc.pages.count - 1 {
            if pageScrollTimer == nil {
                startPageScrollTimer(direction: 1)
            }
            return
        } else {
            cancelPageScrollTimer()
        }

        // Find current page cell
        guard let pageCell = vc.visiblePageCell(forPage: op.currentPage) else { return }
        let touchInPage = gesture.location(in: pageCell.collectionView)

        // Hit-test destination
        guard let destIndexPath = pageCell.collectionView.indexPathForItem(at: touchInPage) else { return }

        let destIndex = destIndexPath.item
        if destIndex == op.currentIndex { return }

        // Don't swap onto placeholder
        if destIndex < pageCell.items.count && pageCell.items[destIndex].isPlaceholder { return }

        // Perform move
        let fromIP = IndexPath(item: op.currentIndex, section: 0)
        let toIP = IndexPath(item: destIndex, section: 0)

        let numberOfItems = pageCell.collectionView.numberOfItems(inSection: 0)
        guard op.currentIndex < numberOfItems && destIndex < numberOfItems else { return }

        pageCell.items.swapAt(op.currentIndex, destIndex)
        pageCell.collectionView.moveItem(at: fromIP, to: toIP)
        op.currentIndex = destIndex

        // Update the VC's data model
        vc.pages[op.currentPage] = pageCell.items

        feedbackGenerator.impactOccurred(intensity: 0.5)
    }

    // MARK: - End

    private func endDrag(_ gesture: UILongPressGestureRecognizer) {
        guard let vc = viewController, let op = currentOperation else { return }

        cancelPageScrollTimer()

        // Find the cell at the current position to animate back to
        if let pageCell = vc.visiblePageCell(forPage: op.currentPage),
           op.currentIndex < pageCell.collectionView.numberOfItems(inSection: 0),
           let targetCell = pageCell.collectionView.cellForItem(at: IndexPath(item: op.currentIndex, section: 0)) {

            let convertedFrame = pageCell.collectionView.convert(targetCell.frame, to: vc.view)
            UIView.animate(withDuration: 0.25, animations: {
                op.placeholderView.transform = .identity
                op.placeholderView.alpha = 1
                op.placeholderView.frame = convertedFrame
            }, completion: { _ in
                targetCell.contentView.isHidden = false
                op.placeholderView.removeFromSuperview()
                self.currentOperation = nil
                pageCell.draggedItemId = nil

                // Notify reorder completion
                vc.onReorder?(vc.pages.flatMap { $0 })
            })
        } else {
            // Fallback: just remove snapshot
            op.placeholderView.removeFromSuperview()
            currentOperation = nil
            vc.onReorder?(vc.pages.flatMap { $0 })
        }

        // Refresh all visible page cells
        for cell in vc.outerCollectionView.visibleCells {
            guard let pageCell = cell as? LCSpringboardPageCell else { continue }
            pageCell.draggedItemId = nil
            pageCell.collectionView.reloadData()
        }
    }

    // MARK: - Page scroll timer

    private func startPageScrollTimer(direction: Int) {
        cancelPageScrollTimer()
        pageScrollTimer = Timer.scheduledTimer(
            timeInterval: pageScrollDelay,
            target: self,
            selector: #selector(pageScrollTimerFired(_:)),
            userInfo: direction,
            repeats: false
        )
    }

    private func cancelPageScrollTimer() {
        pageScrollTimer?.invalidate()
        pageScrollTimer = nil
    }

    @objc private func pageScrollTimerFired(_ timer: Timer) {
        guard let vc = viewController,
              let op = currentOperation,
              let direction = timer.userInfo as? Int else { return }

        pageScrollTimer = nil

        let targetPage = op.currentPage + direction
        guard targetPage >= 0 && targetPage < vc.pages.count else { return }

        // Remove item from current page
        guard op.currentIndex < vc.pages[op.currentPage].count else { return }
        vc.pages[op.currentPage].remove(at: op.currentIndex)

        // Add to target page
        vc.pages[targetPage].append(vc.pages[op.currentPage].count >= 0 ? FlekHomeItem.placeholder("__drag__") : FlekHomeItem.placeholder("__drag__"))
        // Actually, we want to move the dragged item, not a placeholder
        // Remove the placeholder we just added and add the actual item
        if let lastIdx = vc.pages[targetPage].lastIndex(where: { $0.id == "__drag__" || ($0.isPlaceholder && $0.id == "placeholder.__drag__") }) {
            vc.pages[targetPage].remove(at: lastIdx)
        }

        // Find the dragged item from flatItems
        let draggedItem: FlekHomeItem
        if let found = vc.flatItems.first(where: { $0.id == op.itemId }) {
            draggedItem = found
        } else {
            return
        }

        vc.pages[targetPage].append(draggedItem)

        // Update current page cell
        if let currentPageCell = vc.visiblePageCell(forPage: op.currentPage) {
            currentPageCell.items = vc.pages[op.currentPage]
            currentPageCell.draggedItemId = nil
            currentPageCell.collectionView.reloadData()
        }

        op.currentPage = targetPage
        op.currentIndex = vc.pages[targetPage].count - 1
        op.needsUpdate = true

        // Scroll to target page
        let offset = CGPoint(x: vc.outerCollectionView.bounds.width * CGFloat(targetPage), y: 0)
        vc.outerCollectionView.setContentOffset(offset, animated: true)
    }

    /// Called by the VC when a page cell becomes visible during a drag.
    /// Adopts the drag operation onto the newly visible page.
    func adoptDragOnVisiblePage(_ pageCell: LCSpringboardPageCell, pageIndex: Int) {
        guard let op = currentOperation, op.needsUpdate, op.currentPage == pageIndex else { return }

        pageCell.items = viewController?.pages[pageIndex] ?? []
        pageCell.draggedItemId = op.itemId
        op.currentIndex = max(0, pageCell.items.count - 1)
        op.needsUpdate = false

        pageCell.collectionView.reloadData()
    }
}
