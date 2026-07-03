//
//  LCSpringboardViewController.swift
//  LiveContainerSwiftUI
//
//  Main UIViewController hosting the paged springboard grid.
//  Outer UICollectionView pages horizontally; each page cell contains
//  an inner grid of app icons. Adapted from jSpringBoard's HomeViewController.
//

import UIKit

final class LCSpringboardViewController: UIViewController {

    // MARK: - Public data

    /// Flat list of all items (source of truth from SwiftUI).
    var flatItems: [FlekHomeItem] = []

    /// Paginated items (computed from flatItems).
    var pages: [[FlekHomeItem]] = [[]]

    /// Whether edit / jiggle mode is active.
    private(set) var isInEditMode: Bool = false

    var darkModeIcon: Bool = false
    var installState: FlekInstallState?
    

    // MARK: - Callbacks (set by Representable)

    var onTap: ((FlekHomeItem) -> Void)?
    var onDelete: ((FlekHomeItem) -> Void)?
    var onReorder: (([FlekHomeItem]) -> Void)?
    var onEditingChanged: ((Bool) -> Void)?

    // MARK: - UI

    private(set) var outerCollectionView: UICollectionView!
    private var pageControl: UIPageControl!
    private(set) var dragManager: LCSpringboardDragManager!
    private var longPressGesture: UILongPressGestureRecognizer!

    private var currentPage: Int = 0

    // MARK: - Layout config

    private(set) var itemsPerPage: Int = 15
    private let columns: Int = LCSpringboardPageCell.columns

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        setupOuterCollectionView()
        setupPageControl()
        setupDragManager()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let pageControlHeight: CGFloat = 30
        let cvHeight = view.bounds.height - pageControlHeight

        outerCollectionView.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: cvHeight)

        // Update flow layout item size to match collection view size
        if let layout = outerCollectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            let newSize = CGSize(width: view.bounds.width, height: cvHeight)
            if layout.itemSize != newSize {
                layout.itemSize = newSize
                layout.invalidateLayout()
            }
        }

        let pageControlTopPadding: CGFloat = 20
        pageControl.frame = CGRect(
            x: 0,
            y: cvHeight + pageControlTopPadding,
            width: view.bounds.width,
            height: pageControlHeight - pageControlTopPadding
        )

        // Recalculate items-per-page metric (does NOT re-paginate)
        recalculateItemsPerPage()
    }

    // MARK: - Setup

    private func setupOuterCollectionView() {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.itemSize = CGSize(width: view.bounds.width, height: view.bounds.height - 30)

        outerCollectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        outerCollectionView.isPagingEnabled = true
        outerCollectionView.showsHorizontalScrollIndicator = false
        outerCollectionView.backgroundColor = .clear
        outerCollectionView.clipsToBounds = false
        outerCollectionView.register(LCSpringboardPageCell.self, forCellWithReuseIdentifier: "PageCell")
        outerCollectionView.dataSource = self
        outerCollectionView.delegate = self

        view.addSubview(outerCollectionView)
    }

    private func setupPageControl() {
        pageControl = UIPageControl()
        pageControl.currentPageIndicatorTintColor = .white
        pageControl.pageIndicatorTintColor = UIColor.white.withAlphaComponent(0.35)
        pageControl.hidesForSinglePage = true
        pageControl.isUserInteractionEnabled = true
        pageControl.addTarget(self, action: #selector(pageControlTapped(_:)), for: .valueChanged)

        view.addSubview(pageControl)
    }

    private func setupDragManager() {
        dragManager = LCSpringboardDragManager()
        dragManager.viewController = self

        longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPressGesture.minimumPressDuration = 0.3
        view.addGestureRecognizer(longPressGesture)
    }

    // MARK: - Data update

    /// Called by the Representable when SwiftUI items genuinely change
    /// (items added or removed, NOT just reordered).
    func updateItems(_ newItems: [FlekHomeItem]) {
        flatItems = newItems
        recalculateItemsPerPage()
        paginateFromFlatItems()
        outerCollectionView.reloadData()
        pageControl.numberOfPages = pages.count
        pageControl.currentPage = min(currentPage, max(0, pages.count - 1))
    }

    /// Recalculate the `itemsPerPage` metric from current layout dimensions.
    /// Does NOT re-paginate — the page structure is preserved.
    /// Only called from `viewDidLayoutSubviews`.
    private func recalculateItemsPerPage() {
        let pageControlHeight: CGFloat = 30
        let pageHeight = view.bounds.height - pageControlHeight
        guard pageHeight > 0 else { return }

        let inset = LCSpringboardPageCell.horizontalInset
        let cols = CGFloat(columns)
        let spacing: CGFloat = 12
        let availableWidth = view.bounds.width - inset * 2 - spacing * (cols - 1)
        let cellWidth = floor(availableWidth / cols)
        let cellHeight = cellWidth + 10 // matches PageCell's updateFlowLayout
        let topInset: CGFloat = 12
        let bottomInset: CGFloat = 12
        let lineSpacing: CGFloat = 8
        let availableHeight = pageHeight - topInset - bottomInset
        let rows = max(1, Int((availableHeight + lineSpacing) / (cellHeight + lineSpacing)))
        itemsPerPage = rows * columns
    }

    /// Distribute `flatItems` into fixed-size pages.
    /// Only called from `updateItems` when genuinely new items arrive from SwiftUI.
    private func paginateFromFlatItems() {
        guard itemsPerPage > 0 else { return }
        var newPages: [[FlekHomeItem]] = []
        var i = 0
        while i < flatItems.count {
            let end = min(i + itemsPerPage, flatItems.count)
            newPages.append(Array(flatItems[i..<end]))
            i = end
        }
        if newPages.isEmpty {
            newPages = [[]]
        }
        pages = newPages
    }

    // MARK: - Editing (matches jSpringBoard's enterEditingMode / leaveEditingMode)

    func setEditing(_ editing: Bool, fromDrag: Bool = false) {
        guard editing != isInEditMode else { return }
        isInEditMode = editing

        if editing {
            // Add a trailing empty page for reorder target
            // (jSpringBoard: items.append([]) + insertItems)
            if let last = pages.last, !last.isEmpty {
                pages.append([])
                outerCollectionView.insertItems(at: [IndexPath(item: pages.count - 1, section: 0)])
                pageControl.numberOfPages = pages.count
            }

            for cell in outerCollectionView.visibleCells {
                (cell as? LCSpringboardPageCell)?.enterEditingMode()
            }
        } else {
            for cell in outerCollectionView.visibleCells {
                (cell as? LCSpringboardPageCell)?.leaveEditingMode()
            }

            // jSpringBoard: remove the last page if empty, after a 0.25s delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                if self.pages.count > 1, let last = self.pages.last, last.isEmpty || last.allSatisfy({ $0.isPlaceholder }) {
                    self.pages.removeLast()
                    self.outerCollectionView.deleteItems(at: [IndexPath(item: self.pages.count, section: 0)])
                    self.pageControl.numberOfPages = self.pages.count
                }

                // Sync flatItems from pages so SwiftUI binding stays consistent
                let newFlat = self.pages.flatMap { $0 }
                if newFlat.map(\.id) != self.flatItems.map(\.id) {
                    self.flatItems = newFlat
                    self.onReorder?(self.flatItems)
                }
            }
        }

        onEditingChanged?(editing)
    }

    // MARK: - Page overflow (jSpringBoard's moveLastItem)

    /// Moves the last item from `pages[page]` to the front of `pages[page+1]`.
    /// Recurses if the next page overflows. Exactly matches jSpringBoard.
    func moveLastItem(inPage page: Int) {
        guard page + 1 < pages.count else { return }

        let item = pages[page].removeLast()
        pages[page + 1].insert(item, at: 0)

        if pages[page + 1].count > itemsPerPage {
            moveLastItem(inPage: page + 1)
        }
    }

    // MARK: - Install state update

    /// Updates install progress on visible installing cells without full reload.
    func updateInstallProgress() {
        for cell in outerCollectionView.visibleCells {
            guard let pageCell = cell as? LCSpringboardPageCell else { continue }
            pageCell.installState = installState
            for iconCell in pageCell.collectionView.visibleCells {
                guard let ic = iconCell as? LCSpringboardIconCell else { continue }
                ic.updateInstallState(installState)
            }
        }
    }

    // MARK: - Scroll to page

    func scrollToPage(_ page: Int, animated: Bool = true) {
        guard page >= 0 && page < pages.count else { return }
        let offset = CGPoint(x: outerCollectionView.bounds.width * CGFloat(page), y: 0)
        outerCollectionView.setContentOffset(offset, animated: animated)
    }

    // MARK: - Helpers

    /// Returns the page cell and its index for a given point in the VC's view.
    func pageCellAtPoint(_ point: CGPoint) -> (pageIndex: Int, cell: LCSpringboardPageCell)? {
        let convertedPoint = view.convert(point, to: outerCollectionView)
        guard let indexPath = outerCollectionView.indexPathForItem(at: convertedPoint),
              let cell = outerCollectionView.cellForItem(at: indexPath) as? LCSpringboardPageCell else {
            // Fallback to current visible cell
            guard let visibleCell = outerCollectionView.visibleCells.first as? LCSpringboardPageCell,
                  let ip = outerCollectionView.indexPath(for: visibleCell) else { return nil }
            return (ip.item, visibleCell)
        }
        return (indexPath.item, cell)
    }

    /// Returns the visible page cell for a given page index (if currently on screen).
    func visiblePageCell(forPage page: Int) -> LCSpringboardPageCell? {
        let ip = IndexPath(item: page, section: 0)
        return outerCollectionView.cellForItem(at: ip) as? LCSpringboardPageCell
    }

    // MARK: - Gesture handlers

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        dragManager.handleLongPress(gesture)
    }

    @objc private func pageControlTapped(_ sender: UIPageControl) {
        scrollToPage(sender.currentPage)
    }
}

// MARK: - UICollectionViewDataSource

extension LCSpringboardViewController: UICollectionViewDataSource {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return pages.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "PageCell", for: indexPath) as! LCSpringboardPageCell
        cell.items = pages[indexPath.item]
        cell.delegate = self
        cell.darkModeIcon = darkModeIcon
        cell.installState = installState
    
        cell.draggedItemId = dragManager.currentOperation?.itemId
        cell.collectionView.reloadData()

        if isInEditMode {
            cell.enterEditingMode()
        } else {
            cell.leaveEditingMode()
        }

        return cell
    }
}

// MARK: - UICollectionViewDelegate

extension LCSpringboardViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let pageCell = cell as? LCSpringboardPageCell else { return }

        // If a drag is in progress and needs to adopt this page
        dragManager.adoptDragOnVisiblePage(pageCell, pageIndex: indexPath.item)

        pageCell.installState = installState
        pageCell.draggedItemId = dragManager.currentOperation?.itemId
        pageCell.collectionView.reloadData()

        if isInEditMode {
            pageCell.enterEditingMode()
        } else {
            pageCell.leaveEditingMode()
        }
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let pageCell = cell as? LCSpringboardPageCell else { return }
        if isInEditMode {
            pageCell.leaveEditingMode()
        }
    }
}

// MARK: - UIScrollViewDelegate (page tracking)

extension LCSpringboardViewController: UIScrollViewDelegate {

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.frame.width > 0 else { return }
        let page = Int(round(scrollView.contentOffset.x / scrollView.frame.width))
        if page != currentPage && page >= 0 && page < pages.count {
            currentPage = page
            pageControl.currentPage = page
        }
    }
}

// MARK: - LCSpringboardPageCellDelegate

extension LCSpringboardViewController: LCSpringboardPageCellDelegate {

    func pageCell(_ pageCell: LCSpringboardPageCell, didTapItem item: FlekHomeItem) {
        guard !isInEditMode else { return }
        onTap?(item)
    }

    func pageCell(_ pageCell: LCSpringboardPageCell, didTapDeleteFor item: FlekHomeItem) {
        onDelete?(item)
    }
}
