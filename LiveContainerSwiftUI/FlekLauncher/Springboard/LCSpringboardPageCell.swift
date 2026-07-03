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
}

final class LCSpringboardPageCell: UICollectionViewCell {

    // MARK: - Public state

    weak var delegate: LCSpringboardPageCellDelegate?

    var items: [FlekHomeItem] = []
    var draggedItemId: String?
    var darkModeIcon: Bool = false
    private(set) var isEditing = false

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
        cv.register(LCSpringboardIconCell.self, forCellWithReuseIdentifier: "IconCell")
        return cv
    }()

    // MARK: - Layout config

    static let columns: Int = 3
    static let horizontalInset: CGFloat = 16

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

        let cols = CGFloat(Self.columns)
        let inset = Self.horizontalInset
        let spacing: CGFloat = 12
        let availableWidth = contentView.bounds.width - inset * 2 - spacing * (cols - 1)
        let cellWidth = floor(availableWidth / cols)
        // Card height: iconTopPadding(16) + icon(60) + labelSpacing(6) + label(16) + bottomPad(8) = 106
        // Plus some spacing below the card for the "new" dot area
        let cellHeight = cellWidth + 10

        layout.itemSize = CGSize(width: cellWidth, height: cellHeight)
        layout.sectionInset = UIEdgeInsets(top: 12, left: inset, bottom: 12, right: inset)
        layout.minimumInteritemSpacing = spacing
        layout.minimumLineSpacing = 8
    }

    // MARK: - Edit mode

    func enterEditingMode() {
        guard !isEditing else { return }
        isEditing = true
        for cell in collectionView.visibleCells {
            guard let iconCell = cell as? LCSpringboardIconCell, !iconCell.isPlaceholderCell else { continue }
            iconCell.startJiggle()
            iconCell.setDeleteButtonVisible(true, animated: true)
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
            cell.setDeleteButtonVisible(true, animated: false)
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

extension LCSpringboardPageCell: UICollectionViewDelegate { }
