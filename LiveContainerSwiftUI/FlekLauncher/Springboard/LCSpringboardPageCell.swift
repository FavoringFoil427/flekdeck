//
//  LCSpringboardPageCell.swift
//  LiveContainerSwiftUI
//
//  One page of the springboard grid. Contains an inner UICollectionView
//  showing LCSpringboardIconCells in a grid layout.
//  Modelled after jSpringBoard's PageCell.
//

import UIKit

protocol LCSpringboardPageCellDelegate: AnyObject {
    func pageCell(_ pageCell: LCSpringboardPageCell, didTapItem item: FlekHomeItem)
    func pageCell(_ pageCell: LCSpringboardPageCell, didTapDeleteFor item: FlekHomeItem)
    func pageCell(_ pageCell: LCSpringboardPageCell, contextMenuFor item: FlekHomeItem) -> UIMenu?
}

final class LCSpringboardPageCell: UICollectionViewCell {

    // MARK: - Public state

    weak var delegate: LCSpringboardPageCellDelegate?

    var items: [FlekHomeItem] = []
    var draggedItemId: String?
    var darkModeIcon: Bool = false
    private(set) var isEditing = false
    private var isContextMenuActive = false
    private var pendingReloadItems: [FlekHomeItem]?

    // MARK: - Inner collection view

    let collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 8
        layout.minimumInteritemSpacing = 0

        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .clear
        cv.clipsToBounds = false
        cv.isScrollEnabled = false
        cv.showsVerticalScrollIndicator = false
        cv.contentInsetAdjustmentBehavior = .never
        cv.register(LCSpringboardIconCell.self, forCellWithReuseIdentifier: "IconCell")
        return cv
    }()

    // MARK: - Layout config

    /// Columns for a given width.
    ///
    /// Cell width is simply the available width divided by this, so a fixed count
    /// meant iPad's far greater width went into making three enormous cells rather
    /// than fitting more of them — a 75pt icon adrift in a 254pt card. iPhone keeps
    /// its three; iPad scales with the width it actually has, which also covers
    /// split-view and Slide Over rather than assuming a full screen.
    static func columns(forWidth width: CGFloat) -> Int {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return 3 }
        // Derived from a target cell size rather than bucketed by width, so a cell is
        // about the same size whichever way the iPad is held. Fixed buckets kept six
        // columns in landscape too, stretching each cell to 181pt around a 112pt card
        // — the icons stayed put while the gaps between them grew.
        let sidePadding: CGFloat = width >= 390 ? 16 : 12
        let available = width - (sidePadding * 2) + interitemSpacing
        let count = (available / (targetCellWidth + interitemSpacing)).rounded()
        return max(3, Int(count))
    }

    /// Cell size the column count aims for: what iPad portrait already produces, so
    /// portrait is unchanged and other widths converge on it.
    private static let targetCellWidth: CGFloat = 121
    static let interitemSpacing: CGFloat = 12

    /// Space kept below the last row for the page dots, which are pinned near the
    /// bottom of the springboard view. Portrait rarely fills the height so the old
    /// 12pt was never noticed; landscape does, and the last row ran into the dots.
    /// `rowsPerPage` subtracts this too, so a row is dropped rather than overlapping
    /// if the reserved space no longer leaves room.
    static let gridBottomInset: CGFloat = 34

    /// Most rows a page may hold.
    ///
    /// Rows are otherwise purely derived — available height divided by cell height —
    /// which on iPad's tall screen fits eight and reads as a dense wall of icons.
    /// Capping keeps the grid to a comfortable page; iPhone is unaffected, its height
    /// never reaching the cap.
    static func maxRows(forWidth width: CGFloat) -> Int {
        UIDevice.current.userInterfaceIdiom == .pad ? 7 : .max
    }

    /// The most icons a page may hold, fixed to what *portrait* fits however the
    /// device is held.
    ///
    /// Landscape fits more per row and fewer rows, so its natural capacity differs
    /// from portrait's — 45 against 42 on an iPad Air. Letting the number change with
    /// orientation repaginates everything on rotation: icons cross page boundaries and
    /// the stored page sizes no longer describe the layout. Pinning it to portrait
    /// keeps a page holding the same items; landscape simply leaves its last row
    /// short.
    static func maxItemsPerPage(screenSize: CGSize, topSafeInset: CGFloat) -> Int {
        let portraitWidth = min(screenSize.width, screenSize.height)
        let portraitHeight = max(screenSize.width, screenSize.height)

        let cellWidth = computeCellWidth(forWidth: portraitWidth)
        let cellHeight = floor(cellWidth * 64.0 / 59.0)
        let lineSpacing: CGFloat = 8
        let pageControlHeight: CGFloat = 30
        let topPad: CGFloat = 8

        let pageHeight = portraitHeight - topSafeInset - topPad - pageControlHeight
        let fitting = Int((pageHeight + lineSpacing) / (cellHeight + lineSpacing))
        let rows = min(max(1, fitting), maxRows(forWidth: portraitWidth))
        return max(1, min(rows * columns(forWidth: portraitWidth), absoluteMaxItemsPerPage))
    }

    /// Ceiling on page capacity across every device.
    ///
    /// Capacity is otherwise derived from the screen, so it varies by model — 35 on an
    /// iPad mini, 42 on an Air, 56 on a Pro 13. Since page boundaries are persisted in
    /// `homeScreenPageSizes` and shared through the app group, a layout arranged on a
    /// larger device repaginates when opened on a smaller one. Pinning the ceiling to
    /// the common iPad capacity keeps a page meaning the same thing everywhere; a
    /// smaller device still gets less if that is all it fits.
    static let absoluteMaxItemsPerPage: Int = 42

    /// Dynamic cell width with tight margins to maximise icon size.
    static func computeCellWidth(forWidth width: CGFloat) -> CGFloat {
        let screenWidth = max(width, 320)
        let sidePadding: CGFloat = screenWidth >= 390 ? 16 : 12
        let cols = CGFloat(columns(forWidth: screenWidth))
        let totalSpacing: CGFloat = interitemSpacing * (cols - 1)
        let availableWidth = screenWidth - (sidePadding * 2) - totalSpacing
        return floor(availableWidth / cols)
    }

    /// Horizontal margin: centres the grid with leftover space.
    static func computeHorizontalInset(forWidth width: CGFloat) -> CGFloat {
        let screenWidth = max(width, 320)
        let cols = CGFloat(columns(forWidth: screenWidth))
        let totalSpacing: CGFloat = interitemSpacing * (cols - 1)
        let cellWidth = computeCellWidth(forWidth: screenWidth)
        return max(4, (screenWidth - (cellWidth * cols) - totalSpacing) / 2)
    }

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)

        clipsToBounds = false
        contentView.clipsToBounds = false

        contentView.addSubview(collectionView)
        collectionView.dataSource = self
        collectionView.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        collectionView.frame = contentView.bounds
        updateFlowLayout()
    }

    private func updateFlowLayout() {
        guard let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout else { return }

        let width = contentView.bounds.width
        let cellWidth = Self.computeCellWidth(forWidth: width)
        let inset = Self.computeHorizontalInset(forWidth: width)

        layout.itemSize = CGSize(width: cellWidth, height: floor(cellWidth * 64.0 / 59.0))
        layout.sectionInset = UIEdgeInsets(top: 0, left: inset,
                                           bottom: Self.gridBottomInset, right: inset)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 8
    }

    // MARK: - Edit mode

    func enterEditingMode() {
        guard !isEditing else { return }
        isEditing = true
        for cell in collectionView.visibleCells {
            guard let iconCell = cell as? LCSpringboardIconCell, !iconCell.isPlaceholderCell else { continue }
            let idx = collectionView.indexPath(for: iconCell)?.item ?? 0
            let deletable = idx < items.count && items[idx].canDelete
            iconCell.startJiggle()
            iconCell.setDeleteButtonVisible(deletable, animated: true)
        }
    }

    func leaveEditingMode() {
        guard isEditing else { return }
        isEditing = false
        for cell in collectionView.visibleCells {
            guard let iconCell = cell as? LCSpringboardIconCell else { continue }
            iconCell.stopJiggle()
            iconCell.setDeleteButtonVisible(false, animated: true)
        }
    }

    // MARK: - Helpers

    /// Calculates how many rows fit in the current page height.
    func rowsPerPage() -> Int {
        guard let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout else { return 5 }
        let cellHeight = layout.itemSize.height
        let topInset = layout.sectionInset.top
        let lineSpacing = layout.minimumLineSpacing
        let bottomInset = layout.sectionInset.bottom
        let availableHeight = contentView.bounds.height - topInset - bottomInset
        let fitting = Int((availableHeight + lineSpacing) / (cellHeight + lineSpacing))
        return min(max(1, fitting), Self.maxRows(forWidth: contentView.bounds.width))
    }

    func itemsPerPage() -> Int {
        let fitting = rowsPerPage() * Self.columns(forWidth: contentView.bounds.width)
        let topSafe = window?.safeAreaInsets.top ?? 0
        return min(fitting, Self.maxItemsPerPage(screenSize: UIScreen.main.bounds.size,
                                                 topSafeInset: topSafe))
    }

    /// Reload items, deferring if a context menu is active to avoid cell reuse glitches.
    /// When a single item is deleted, applies jSpringBoard's shrink-to-zero animation.
    func safeReloadItems(_ newItems: [FlekHomeItem]) {
        if isContextMenuActive {
            pendingReloadItems = newItems
            return
        }

        // Delete animation: shrink icon to ~0, then batch-delete so
        // remaining icons shift smoothly. Only the icon is scaled —
        // applying a transform to the full contentView causes liquid
        // glass visual artefacts.
        if newItems.count == items.count - 1 {
            let oldIDs = Set(items.map(\.id))
            let newIDs = Set(newItems.map(\.id))
            let removed = oldIDs.subtracting(newIDs)
            if removed.count == 1, let removedID = removed.first,
               let index = items.firstIndex(where: { $0.id == removedID }),
               let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? LCSpringboardIconCell {
                UIView.animate(withDuration: 0.25, animations: {
                    cell.iconImageView.transform = CGAffineTransform.identity.scaledBy(x: 0.0001, y: 0.0001)
                    cell.nameLabel.alpha = 0
                    cell.contentView.alpha = 0
                }, completion: { _ in
                    self.items = newItems
                    self.collectionView.performBatchUpdates({
                        self.collectionView.deleteItems(at: [IndexPath(item: index, section: 0)])
                    }, completion: { _ in
                        cell.iconImageView.transform = .identity
                        cell.nameLabel.alpha = 1
                        cell.contentView.alpha = 1
                    })
                })
                return
            }
        }

        items = newItems
        collectionView.reloadData()
    }
}

// MARK: - UICollectionViewDataSource

extension LCSpringboardPageCell: UICollectionViewDataSource {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "IconCell", for: indexPath) as! LCSpringboardIconCell
        let item = items[indexPath.item]

        cell.configure(with: item, darkMode: darkModeIcon)

        // Edit mode state
        if isEditing && !cell.isPlaceholderCell {
            cell.startJiggle()
            cell.setDeleteButtonVisible(item.canDelete, animated: false)
        } else {
            cell.stopJiggle()
            cell.setDeleteButtonVisible(false, animated: false)
        }

        // Hide cell's contentView if it's being dragged (jSpringBoard pattern)
        if let dragId = draggedItemId, item.id == dragId {
            cell.contentView.isHidden = true
        } else if !cell.isPlaceholderCell {
            cell.contentView.isHidden = false
        }

        // Callbacks
        cell.onTap = { [weak self] in
            guard let self else { return }
            self.delegate?.pageCell(self, didTapItem: item)
        }
        cell.onDeleteTap = { [weak self] in
            guard let self else { return }
            self.delegate?.pageCell(self, didTapDeleteFor: item)
        }

        return cell
    }
}

// MARK: - UICollectionViewDelegate

extension LCSpringboardPageCell: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        return false
    }

    /// The currently active context menu interaction, used to live-update
    /// the menu (e.g. toggling launch mode) without dismissing it.
    private(set) static weak var activeContextMenuInteraction: UIContextMenuInteraction?
    private static var activeContextMenuRefresh: (() -> UIMenu?)?
    private static weak var activeContextMenuPageCell: LCSpringboardPageCell?
    private static var activeContextMenuIndexPath: IndexPath?

    /// Rebuilds the currently visible context menu in-place so that state
    /// changes (like launch-mode toggles) are reflected immediately.
    static func refreshActiveContextMenu() {
        guard #available(iOS 16.0, *),
              let interaction = activeContextMenuInteraction,
              let refresh = activeContextMenuRefresh else { return }
        interaction.updateVisibleMenu { _ in
            refresh() ?? UIMenu(children: [])
        }
    }

    /// Updates the badge on the icon cell that currently has an active
    /// context menu, without reloading the entire cell.
    static func refreshActiveCellBadge() {
        guard let pageCell = activeContextMenuPageCell,
              let ip = activeContextMenuIndexPath,
              let cell = pageCell.collectionView.cellForItem(at: ip) as? LCSpringboardIconCell else { return }
        cell.updateBadge()
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard !isEditing else { return nil }
        let item = items[indexPath.item]
        guard !item.isPlaceholder else { return nil }
        guard let menu = delegate?.pageCell(self, contextMenuFor: item) else { return nil }

        // Store references so the menu and badge can be updated while visible.
        Self.activeContextMenuPageCell = self
        Self.activeContextMenuIndexPath = indexPath
        Self.activeContextMenuRefresh = { [weak self] in
            guard let self else { return nil }
            return self.delegate?.pageCell(self, contextMenuFor: item)
        }

        return UIContextMenuConfiguration(identifier: indexPath as NSCopying, previewProvider: nil) { _ in
            menu
        }
    }

    func collectionView(_ collectionView: UICollectionView, previewForHighlightingContextMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        guard let indexPath = configuration.identifier as? IndexPath,
              let cell = collectionView.cellForItem(at: indexPath) as? LCSpringboardIconCell else { return nil }
        let params = UIPreviewParameters()
        params.backgroundColor = .clear
        params.visiblePath = UIBezierPath(
            roundedRect: cell.iconImageView.bounds,
            cornerRadius: 13.4
        )
        params.shadowPath = UIBezierPath()
        return UITargetedPreview(view: cell.iconImageView, parameters: params)
    }

    func collectionView(_ collectionView: UICollectionView, previewForDismissingContextMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        guard let indexPath = configuration.identifier as? IndexPath,
              let cell = collectionView.cellForItem(at: indexPath) as? LCSpringboardIconCell else { return nil }
        let params = UIPreviewParameters()
        params.backgroundColor = .clear
        params.visiblePath = UIBezierPath(
            roundedRect: cell.iconImageView.bounds,
            cornerRadius: 13.4
        )
        params.shadowPath = UIBezierPath()
        return UITargetedPreview(view: cell.iconImageView, parameters: params)
    }

    func collectionView(_ collectionView: UICollectionView, willDisplayContextMenu configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        isContextMenuActive = true
        // Grab the UIContextMenuInteraction so we can call updateVisibleMenu later.
        for interaction in collectionView.interactions {
            if let cmi = interaction as? UIContextMenuInteraction {
                Self.activeContextMenuInteraction = cmi
                break
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, willEndContextMenuInteraction configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        Self.activeContextMenuInteraction = nil
        Self.activeContextMenuRefresh = nil
        Self.activeContextMenuPageCell = nil
        Self.activeContextMenuIndexPath = nil
        animator?.addCompletion { [weak self] in
            guard let self else { return }
            self.isContextMenuActive = false
            if let pending = self.pendingReloadItems {
                self.pendingReloadItems = nil
                self.items = pending
                self.collectionView.reloadData()
            }
        }
        // Fallback if no animator
        if animator == nil {
            isContextMenuActive = false
            if let pending = pendingReloadItems {
                pendingReloadItems = nil
                items = pending
                collectionView.reloadData()
            }
        }
    }
}
