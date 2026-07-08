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

    /// Latest items from SwiftUI, even if updateItems() hasn't been called yet.
    /// Used to catch up when the view reappears after being behind a cover.
    var pendingItems: [FlekHomeItem]?

    /// Paginated items (computed from flatItems).
    var pages: [[FlekHomeItem]] = [[]]

    /// Whether edit / jiggle mode is active.
    private(set) var isInEditMode: Bool = false

    var darkModeIcon: Bool = false
    

    // MARK: - Callbacks (set by Representable)

    var onTap: ((FlekHomeItem) -> Void)?
    var onDelete: ((FlekHomeItem) -> Void)?
    var onReorder: (([FlekHomeItem]) -> Void)?
    var onEditingChanged: ((Bool) -> Void)?
    var contextMenuProvider: ((FlekHomeItem) -> UIMenu?)?

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

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // When the view reappears (e.g. after a fullScreenCover is dismissed),
        // apply any items that were synced while we were hidden.
        if let pending = pendingItems {
            let currentIDs = flatItems.map(\.id)
            let pendingIDs = pending.map(\.id)
            if currentIDs != pendingIDs {
                updateItems(pending)
                // If the pending items include .installing, scroll to its page
                // (the original scroll-to-page may have been consumed behind the cover).
                if let idx = pending.firstIndex(where: { $0.id.hasPrefix("installing.") }) {
                    let page = pageForFlatIndex(idx)
                    if page < pages.count {
                        DispatchQueue.main.async { [weak self] in
                            self?.scrollToPage(page)
                        }
                    }
                }
            }
            pendingItems = nil
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // The outer CV fills the full view height so that overflowing rows
        // (clipsToBounds = false) remain interactive — their cells are
        // within the CV's bounds and receive tap events.
        let cvHeight = view.bounds.height

        outerCollectionView.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: cvHeight)

        // Update flow layout item size to match collection view size
        if let layout = outerCollectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            let newSize = CGSize(width: view.bounds.width, height: cvHeight)
            if layout.itemSize != newSize {
                layout.itemSize = newSize
                layout.invalidateLayout()
            }
        }

        // Page control overlays the bottom of the CV.
        let pageControlTopPadding: CGFloat = 20
        let pageControlHeight: CGFloat = 10
        pageControl.frame = CGRect(
            x: 0,
            y: cvHeight - pageControlHeight - pageControlTopPadding,
            width: view.bounds.width,
            height: pageControlHeight
        )
        // Recalculate items-per-page; re-paginate if it changed.
        let oldIPP = itemsPerPage
        recalculateItemsPerPage()
        if itemsPerPage != oldIPP && !flatItems.isEmpty {
            paginateFromFlatItems()
            outerCollectionView.reloadData()
            pageControl.numberOfPages = pages.count
            // Restore scroll position after re-pagination
            if currentPage > 0 && currentPage < pages.count {
                let offset = CGPoint(x: outerCollectionView.bounds.width * CGFloat(currentPage), y: 0)
                outerCollectionView.setContentOffset(offset, animated: false)
            }
        }
    }

    // MARK: - Setup

    private func setupOuterCollectionView() {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.itemSize = CGSize(width: view.bounds.width, height: view.bounds.height)

        outerCollectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        outerCollectionView.isPagingEnabled = true
        outerCollectionView.showsHorizontalScrollIndicator = false
        outerCollectionView.contentInsetAdjustmentBehavior = .never
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
        pageControl.backgroundStyle = .minimal
        pageControl.hidesForSinglePage = true
        pageControl.isUserInteractionEnabled = true
        pageControl.addTarget(self, action: #selector(pageControlTapped(_:)), for: .valueChanged)
        pageControl.transform = CGAffineTransform(scaleX: 1.25, y: 1.25)

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
        let oldPageCount = pages.count
        flatItems = newItems
        recalculateItemsPerPage()
        paginateFromFlatItems()

        // In edit mode, preserve the trailing empty page so that the page
        // count stays stable after a deletion. Without this,
        // paginateFromFlatItems strips the empty page, causing a page-count
        // mismatch that forces a full reloadData (no smooth shift animation).
        if isInEditMode {
            if pages.last?.isEmpty != true {
                pages.append([])
            }
        }

        // If the page count is unchanged, update visible page cells in-place
        // instead of reloading the outer collection view (which destroys cells
        // and causes a visible flash, e.g. when an installing item is cancelled).
        if pages.count == oldPageCount {
            let visiblePageCells = outerCollectionView.visibleCells.compactMap { $0 as? LCSpringboardPageCell }
            if visiblePageCells.isEmpty {
                // View is off-screen (e.g. behind a fullScreenCover);
                // reload so cells pick up the new data when they appear.
                outerCollectionView.reloadData()
            } else {
                for pageCell in visiblePageCells {
                    guard let indexPath = outerCollectionView.indexPath(for: pageCell) else { continue }
                    let pageIndex = indexPath.item
                    guard pageIndex < pages.count else { continue }
                    pageCell.safeReloadItems(pages[pageIndex])
                }
            }
        } else {
            outerCollectionView.reloadData()
            // Preserve scroll position after page count change
            if currentPage > 0 && currentPage < pages.count {
                let offset = CGPoint(x: outerCollectionView.bounds.width * CGFloat(currentPage), y: 0)
                outerCollectionView.setContentOffset(offset, animated: false)
            }
        }
        pageControl.numberOfPages = pages.count
        pageControl.currentPage = min(currentPage, max(0, pages.count - 1))
    }

    /// Recalculate the `itemsPerPage` metric from screen dimensions.
    ///
    /// Uses the full screen height minus the top safe area and a small top
    /// padding, rather than the constrained `view.bounds.height`. This gives
    /// more rows because the grid extends beyond the page cell via
    /// `clipsToBounds = false`, allowing the last row to overflow into the
    /// dock area — matching the real iOS SpringBoard's compact spacing.
    private func recalculateItemsPerPage() {
        let screenH = UIScreen.main.bounds.height
        let topSafe = view.window?.safeAreaInsets.top ?? 59
        let topPad: CGFloat = 8
        let effectiveHeight = screenH - topSafe - topPad
        guard effectiveHeight > 0 else { return }

        let pageControlHeight: CGFloat = 30
        let pageHeight = effectiveHeight - pageControlHeight

        let cellWidth = LCSpringboardPageCell.computeCellWidth(forWidth: view.bounds.width)
        let cellHeight = floor(cellWidth * 64.0 / 59.0)
        let lineSpacing: CGFloat = 8
        let rows = max(1, Int((pageHeight + lineSpacing) / (cellHeight + lineSpacing)))
        itemsPerPage = rows * columns
    }

    /// Flatten `pages` back into a single array, padding non-last pages
    /// with placeholders up to `itemsPerPage` so that page boundaries
    /// survive the round-trip through `persistHomeOrder` / `rebuildOrderedHomeItems`.
    func flatItemsPreservingPageBoundaries() -> [FlekHomeItem] {
        guard itemsPerPage > 0 else { return pages.flatMap { $0 } }
        var result: [FlekHomeItem] = []
        for (i, page) in pages.enumerated() {
            result.append(contentsOf: page)
            // Pad intermediate pages that are shorter than itemsPerPage
            if i < pages.count - 1 {
                let padding = max(0, itemsPerPage - page.count)
                for j in 0..<padding {
                    result.append(.placeholder("pad.\(i).\(j)"))
                }
            }
        }
        return result
    }

    /// Syncs the current page layout back to SwiftUI, persisting both the
    /// padded flat items and page sizes so that page boundaries survive
    /// through `rebuildOrderedHomeItems` and `paginateFromFlatItems`.
    func syncPagesToSwiftUI() {
        flatItems = flatItemsPreservingPageBoundaries()
        // Save page sizes matching the padded flat layout.
        // Non-last pages are padded to itemsPerPage (just like the flat
        // array), so paginateFromFlatItems splits items at the right
        // boundaries when reading these sizes back.
        var sizes: [Int] = []
        for (i, page) in pages.enumerated() {
            if i < pages.count - 1 {
                sizes.append(max(page.count, itemsPerPage))
            } else {
                sizes.append(page.count)
            }
        }
        while sizes.last == 0 { sizes.removeLast() }
        if !sizes.isEmpty {
            LCUtils.appGroupUserDefault.set(sizes, forKey: FlekLauncherKeys.homeScreenPageSizes)
        }
        onReorder?(flatItems)
    }

    /// Distribute `flatItems` into pages.
    /// Uses stored per-page sizes when available so that custom page
    /// boundaries (from drag-and-drop reorder) are preserved. Falls back
    /// to uniform chunking by `itemsPerPage` when no sizes are stored.
    ///
    /// When items exist beyond the stored sizes (e.g. a newly installed app),
    /// the last page is filled up to `itemsPerPage` before a new page is
    /// created — matching real iOS SpringBoard behaviour.
    private func paginateFromFlatItems() {
        guard itemsPerPage > 0 else { return }

        let storedSizes = LCUtils.appGroupUserDefault.array(
            forKey: FlekLauncherKeys.homeScreenPageSizes
        ) as? [Int]

        var newPages: [[FlekHomeItem]] = []
        var offset = 0

        if let sizes = storedSizes, !sizes.isEmpty {
            for size in sizes where offset < flatItems.count {
                let count = min(size, flatItems.count - offset)
                newPages.append(Array(flatItems[offset..<(offset + count)]))
                offset += count
            }

            // Fill the last page up to itemsPerPage before creating new pages.
            // The last stored page size is the actual item count (not padded),
            // so there may be room for more items (e.g. a newly installed app).
            if !newPages.isEmpty && offset < flatItems.count {
                let lastPageCount = newPages[newPages.count - 1].count
                let room = itemsPerPage - lastPageCount
                if room > 0 {
                    let toAdd = min(room, flatItems.count - offset)
                    newPages[newPages.count - 1].append(
                        contentsOf: flatItems[offset..<(offset + toAdd)]
                    )
                    offset += toAdd
                }
            }
        }

        // Remaining items (beyond stored sizes + last-page fill, or no sizes stored)
        while offset < flatItems.count {
            let end = min(offset + itemsPerPage, flatItems.count)
            newPages.append(Array(flatItems[offset..<end]))
            offset = end
        }

        // Strip placeholder padding so the UIKit collection view only
        // contains real items. This matches jSpringBoard (which has no
        // placeholder concept) and ensures clean moveItem animations
        // during within-page rearrangement. Placeholders are re-added
        // by flatItemsPreservingPageBoundaries() when syncing back to
        // SwiftUI for persistence.
        for i in newPages.indices {
            newPages[i].removeAll(where: { $0.isPlaceholder })
        }
        // Remove trailing empty pages left after stripping
        while newPages.count > 1 && (newPages.last?.isEmpty ?? true) {
            newPages.removeLast()
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

            pageControl.backgroundStyle = .prominent
        } else {
            for cell in outerCollectionView.visibleCells {
                (cell as? LCSpringboardPageCell)?.leaveEditingMode()
            }

            pageControl.backgroundStyle = .minimal

            // Remove trailing empty pages after edit animations settle.
            // Uses reloadData instead of deleteItems to avoid conflicts
            // with ongoing leaveEditingMode animations.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }

                var removedPages = false
                while self.pages.count > 1,
                      let last = self.pages.last,
                      last.isEmpty || last.allSatisfy({ $0.isPlaceholder }) {
                    self.pages.removeLast()
                    removedPages = true
                }

                if removedPages {
                    // Clamp currentPage if the user was on a removed page
                    let maxPage = max(0, self.pages.count - 1)
                    if self.currentPage > maxPage {
                        self.currentPage = maxPage
                    }
                    self.outerCollectionView.reloadData()
                    self.pageControl.numberOfPages = self.pages.count
                    self.pageControl.currentPage = self.currentPage
                    // Scroll to valid page
                    let offset = CGPoint(
                        x: self.outerCollectionView.bounds.width * CGFloat(self.currentPage),
                        y: 0
                    )
                    self.outerCollectionView.setContentOffset(offset, animated: true)
                }

                // Always sync page sizes and flat items back to SwiftUI
                // so page boundaries survive through persistence and rebuild.
                self.syncPagesToSwiftUI()
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

    /// Applies any pending item changes that were deferred while dragging.
    func applyPendingItemsIfNeeded() {
        guard let pending = pendingItems else { return }
        let currentSet = Set(flatItems.map(\.id))
        let newSet = Set(pending.map(\.id))
        if currentSet != newSet {
            updateItems(pending)
        }
        pendingItems = nil
    }

    // MARK: - Install state update

    /// Updates install progress on visible installing cells without full reload.
    func updateInstallProgress() {
        for cell in outerCollectionView.visibleCells {
            guard let pageCell = cell as? LCSpringboardPageCell else { continue }
            for iconCell in pageCell.collectionView.visibleCells {
                guard let ic = iconCell as? LCSpringboardIconCell else { continue }
                ic.updateInstallState()
            }
        }
    }

    // MARK: - Scroll to page

    func scrollToPage(_ page: Int, animated: Bool = true) {
        guard page >= 0 && page < pages.count else { return }
        let offset = CGPoint(x: outerCollectionView.bounds.width * CGFloat(page), y: 0)
        outerCollectionView.setContentOffset(offset, animated: animated)
    }

    // MARK: - Page index calculation

    /// Returns the page index for a flat-array position, using stored page
    /// sizes and filling the last page up to `itemsPerPage` — matching
    /// `paginateFromFlatItems()` exactly.
    func pageForFlatIndex(_ index: Int) -> Int {
        guard itemsPerPage > 0 else { return 0 }

        let sizes = LCUtils.appGroupUserDefault.array(
            forKey: FlekLauncherKeys.homeScreenPageSizes
        ) as? [Int] ?? []

        if !sizes.isEmpty {
            var offset = 0
            for (page, size) in sizes.enumerated() {
                offset += size
                if index < offset { return page }
            }
            // Beyond stored sizes: the last page can still hold items
            // up to itemsPerPage (mirroring paginateFromFlatItems).
            let lastPageSize = sizes.last ?? 0
            let room = max(0, itemsPerPage - lastPageSize)
            let beyondStored = index - offset
            if beyondStored < room {
                return sizes.count - 1
            }
            // Truly new pages beyond the last stored page's capacity
            let beyondLastPage = beyondStored - room
            return sizes.count + beyondLastPage / itemsPerPage
        }

        return index / itemsPerPage
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

        pageCell.items = pages[indexPath.item]
        pageCell.draggedItemId = dragManager.currentOperation?.itemId
        pageCell.collectionView.reloadData()

        if isInEditMode {
            pageCell.enterEditingMode()
        } else {
            pageCell.leaveEditingMode()
        }
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        // Note: Do NOT call leaveEditingMode() here. When the user swipes
        // between pages during edit mode, leaveEditingMode() starts an animated
        // hide of delete buttons. If the page scrolls back into view before the
        // animation completes, the stale completion handler sets isHidden = true
        // after enterEditingMode() has already shown the buttons, causing them
        // to randomly disappear. The willDisplay/cellForItemAt callbacks already
        // handle restoring edit mode state correctly when pages reappear.
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

    func pageCell(_ pageCell: LCSpringboardPageCell, contextMenuFor item: FlekHomeItem) -> UIMenu? {
        return contextMenuProvider?(item)
    }
}
