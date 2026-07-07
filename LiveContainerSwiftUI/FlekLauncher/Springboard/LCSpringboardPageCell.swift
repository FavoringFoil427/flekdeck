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
    var installState: FlekInstallState?
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

    static let columns: Int = 3

    /// jSpringBoard dynamic cell width: 30pt side padding for screens ≥390pt, 24pt otherwise.
    static func computeCellWidth(forWidth width: CGFloat) -> CGFloat {
        let screenWidth = max(width, 320)
        let sidePadding: CGFloat = screenWidth >= 390 ? 30 : 24
        let cols = CGFloat(columns)
        let totalSpacing: CGFloat = 12 * (cols - 1)
        let availableWidth = screenWidth - (sidePadding * 2) - totalSpacing
        return floor(availableWidth / cols)
    }

    /// jSpringBoard horizontal margin: centers the grid with leftover space, min 16pt.
    static func computeHorizontalInset(forWidth width: CGFloat) -> CGFloat {
        let screenWidth = max(width, 320)
        let cols = CGFloat(columns)
        let totalSpacing: CGFloat = 12 * (cols - 1)
        let cellWidth = computeCellWidth(forWidth: screenWidth)
        return max(16, (screenWidth - (cellWidth * cols) - totalSpacing) / 2)
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

        layout.itemSize = CGSize(width: cellWidth, height: cellWidth)
        layout.sectionInset = UIEdgeInsets(top: 12, left: inset, bottom: 12, right: inset)
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
        return max(1, Int((availableHeight + lineSpacing) / (cellHeight + lineSpacing)))
    }

    func itemsPerPage() -> Int {
        return rowsPerPage() * Self.columns
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

        cell.configure(with: item, darkMode: darkModeIcon, installState: installState)

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

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard !isEditing else { return nil }
        let item = items[indexPath.item]
        guard !item.isPlaceholder else { return nil }
        guard let menu = delegate?.pageCell(self, contextMenuFor: item) else { return nil }

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
        return UITargetedPreview(view: cell.iconImageView, parameters: params)
    }

    func collectionView(_ collectionView: UICollectionView, willDisplayContextMenu configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        isContextMenuActive = true
    }

    func collectionView(_ collectionView: UICollectionView, willEndContextMenuInteraction configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
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
