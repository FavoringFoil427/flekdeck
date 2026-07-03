//
//  LCSpringboardDragManager.swift
//  LiveContainerSwiftUI
//
//  Drag-and-drop state machine for the UIKit springboard.
//  Faithfully follows jSpringBoard's AppGridManager + AppGridManager+DragOperations
//  pattern, including savedState undo and moveLastItem cascade.
//

import UIKit

// MARK: - Drag operation state

final class LCDragOperation {
    /// The actual item being dragged.
    let item: FlekHomeItem
    var itemId: String { item.id }
    let placeholderView: UIView
    let dragOffset: CGSize
    let originalPage: Int
    let originalIndex: Int
    var currentPage: Int
    var currentIndex: Int
    /// When true, the item moved to a new page and the target PageCell
    /// hasn't appeared yet. updateDrag short-circuits until willDisplay fires.
    var needsUpdate: Bool = false
    /// Snapshot of vc.pages before a cascade overflow. Restored if the item
    /// moves to yet another page (undo previous cascade before doing a new one).
    var savedState: [[FlekHomeItem]]?

    init(item: FlekHomeItem, placeholderView: UIView, dragOffset: CGSize,
         originalPage: Int, originalIndex: Int) {
        self.item = item
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

        let touchInView = gesture.location(in: vc.view)
        guard let (pageIndex, pageCell) = vc.pageCellAtPoint(touchInView) else { return }

        let touchInPage = gesture.location(in: pageCell.collectionView)
        guard let indexPath = pageCell.collectionView.indexPathForItem(at: touchInPage),
              let iconCell = pageCell.collectionView.cellForItem(at: indexPath) as? LCSpringboardIconCell,
              !iconCell.isPlaceholderCell else { return }

        let item = pageCell.items[indexPath.item]
        guard item.isDraggable else { return }

        // Offset so the snapshot stays centered under the finger
        let dragOffset = CGSize(
            width: iconCell.center.x - touchInPage.x,
            height: iconCell.center.y - touchInPage.y
        )

        let snapshot = iconCell.snapshotView(afterScreenUpdates: true) ?? UIView(frame: iconCell.bounds)
        var snapshotCenter = touchInView
        snapshotCenter.x += dragOffset.width
        snapshotCenter.y += dragOffset.height
        snapshot.center = snapshotCenter
        vc.view.addSubview(snapshot)

        iconCell.isHidden = true

        if !vc.isInEditMode {
            vc.setEditing(true, fromDrag: true)
        }

        feedbackGenerator.impactOccurred()

        UIView.animate(withDuration: 0.25) {
            snapshot.transform = CGAffineTransform(scaleX: 1.3, y: 1.3)
            snapshot.alpha = 0.8
        }

        currentOperation = LCDragOperation(
            item: item,
            placeholderView: snapshot,
            dragOffset: dragOffset,
            originalPage: pageIndex,
            originalIndex: indexPath.item
        )

        pageCell.draggedItemId = item.id
    }

    // MARK: - Update (within-page: moveItem only, no data model changes)

    private func updateDrag(_ gesture: UILongPressGestureRecognizer) {
        guard let vc = viewController, let op = currentOperation else { return }

        let touchInView = gesture.location(in: vc.view)

        // Move snapshot to follow touch
        var snapshotCenter = touchInView
        snapshotCenter.x += op.dragOffset.width
        snapshotCenter.y += op.dragOffset.height
        op.placeholderView.center = snapshotCenter

        // If a cross-page scroll is pending, don't do any rearrangement
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

        // Don't move onto a placeholder
        if destIndex < pageCell.items.count && pageCell.items[destIndex].isPlaceholder { return }

        let fromIP = IndexPath(item: op.currentIndex, section: 0)
        let toIP = IndexPath(item: destIndex, section: 0)

        let numberOfItems = pageCell.collectionView.numberOfItems(inSection: 0)
        guard op.currentIndex < numberOfItems && destIndex < numberOfItems else { return }

        // jSpringBoard pattern: only call moveItem, do NOT touch the data model.
        // The data model is synced at end-of-drag via updateState().
        pageCell.collectionView.moveItem(at: fromIP, to: toIP)
        op.currentIndex = destIndex

        feedbackGenerator.impactOccurred(intensity: 0.5)
    }

    // MARK: - End

    private func endDrag(_ gesture: UILongPressGestureRecognizer) {
        guard let vc = viewController, let op = currentOperation else { return }

        cancelPageScrollTimer()

        // jSpringBoard pattern: read the UI state back into the data model.
        if let pageCell = vc.visiblePageCell(forPage: op.currentPage) {
            updateState(forPageCell: pageCell, pageIndex: op.currentPage)
        }

        // Sync flatItems and notify SwiftUI
        vc.flatItems = vc.pages.flatMap { $0 }
        vc.onReorder?(vc.flatItems)

        // Animate snapshot back into position
        if let pageCell = vc.visiblePageCell(forPage: op.currentPage),
           op.currentIndex < pageCell.collectionView.numberOfItems(inSection: 0),
           let targetCell = pageCell.collectionView.cellForItem(at: IndexPath(item: op.currentIndex, section: 0)) {

            let convertedFrame = pageCell.collectionView.convert(targetCell.frame, to: vc.view)
            UIView.animate(withDuration: 0.25, animations: {
                op.placeholderView.transform = .identity
                op.placeholderView.alpha = 1
                op.placeholderView.frame = convertedFrame
            }, completion: { _ in
                targetCell.isHidden = false
                op.placeholderView.removeFromSuperview()
                self.currentOperation = nil
                pageCell.draggedItemId = nil
            })
        } else {
            op.placeholderView.removeFromSuperview()
            currentOperation = nil
        }

        // Unhide all cells and refresh
        for cell in vc.outerCollectionView.visibleCells {
            guard let pageCell = cell as? LCSpringboardPageCell else { continue }
            pageCell.draggedItemId = nil
            pageCell.collectionView.reloadData()
        }
    }

    // MARK: - Read cell order back from UICollectionView (jSpringBoard's updateState)

    private func updateState(forPageCell pageCell: LCSpringboardPageCell, pageIndex: Int) {
        guard let vc = viewController else { return }

        var items: [FlekHomeItem] = []
        let count = pageCell.collectionView.numberOfItems(inSection: 0)
        for i in 0..<count {
            let indexPath = IndexPath(item: i, section: 0)
            if let cell = pageCell.collectionView.cellForItem(at: indexPath) as? LCSpringboardIconCell,
               let item = cell.configuredItem {
                items.append(item)
            }
        }

        if !items.isEmpty {
            pageCell.items = items
            vc.pages[pageIndex] = items
        }
    }

    // MARK: - Page scroll timer (cross-page drag)

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

    /// Cross-page move handler. Faithfully follows jSpringBoard's pageTimerHandler:
    /// 1. Sync current page from cells (within-page moveItem didn't update data)
    /// 2. Find the dragged item by ID in the data array
    /// 3. If savedState exists, restore it (undo previous cascade)
    /// 4. Remove item from current page
    /// 5. If destination page is full, save state and cascade overflow
    /// 6. Append item to destination page
    /// 7. Update current page cell, scroll to destination
    @objc private func pageScrollTimerFired(_ timer: Timer) {
        guard let vc = viewController,
              let op = currentOperation,
              let direction = timer.userInfo as? Int else { return }

        pageScrollTimer = nil

        let nextPage = op.currentPage + direction
        guard nextPage >= 0 && nextPage < vc.pages.count else { return }

        // Step 1: Sync current page from cells (moveItem didn't update data)
        if let currentPageCell = vc.visiblePageCell(forPage: op.currentPage) {
            updateState(forPageCell: currentPageCell, pageIndex: op.currentPage)
        }

        // Step 2: Find the dragged item's actual index in the data array
        guard let currentIndex = vc.pages[op.currentPage].firstIndex(where: { $0.id == op.itemId }) else { return }
        let currentPageInitialCount = vc.pages[op.currentPage].count

        // Step 3: If savedState exists, restore it (undo previous cascade)
        if let savedState = op.savedState {
            vc.pages = savedState
            op.savedState = nil
        } else {
            // Step 4: Remove item from current page
            vc.pages[op.currentPage].remove(at: currentIndex)
        }

        // Step 5: If destination page is full, save state and cascade
        if vc.pages[nextPage].count >= vc.itemsPerPage {
            op.savedState = vc.pages
            vc.moveLastItem(inPage: nextPage)
        }

        // Step 6: Append item to destination page
        vc.pages[nextPage].append(op.item)

        // Step 7: Update current page cell visuals
        if let currentPageCell = vc.visiblePageCell(forPage: op.currentPage) {
            currentPageCell.items = vc.pages[op.currentPage]
            op.needsUpdate = true

            if vc.pages[op.currentPage].count < currentPageInitialCount {
                currentPageCell.collectionView.performBatchUpdates({
                    currentPageCell.collectionView.deleteItems(at: [IndexPath(item: currentIndex, section: 0)])
                }, completion: nil)
            } else {
                currentPageCell.collectionView.reloadData()
            }
        }

        op.currentPage = nextPage
        op.needsUpdate = true

        // Scroll to destination page
        let offset = CGPoint(x: vc.outerCollectionView.bounds.width * CGFloat(nextPage), y: 0)
        vc.outerCollectionView.setContentOffset(offset, animated: true)
    }

    /// Called by the VC when a page cell becomes visible during a drag (willDisplay).
    /// Matches jSpringBoard's willDisplay logic.
    func adoptDragOnVisiblePage(_ pageCell: LCSpringboardPageCell, pageIndex: Int) {
        guard let vc = viewController,
              let op = currentOperation,
              op.needsUpdate,
              op.currentPage == pageIndex else { return }

        pageCell.items = vc.pages[pageIndex]
        pageCell.draggedItemId = op.itemId
        // The dragged item was appended last, so its index is count - 1
        op.currentIndex = pageCell.collectionView(pageCell.collectionView, numberOfItemsInSection: 0) - 1
        op.needsUpdate = false

        pageCell.collectionView.reloadData()
    }
}
