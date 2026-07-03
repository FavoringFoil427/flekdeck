//
//  LCSpringboardIconCell.swift
//  LiveContainerSwiftUI
//
//  UICollectionViewCell rendering a single app icon in the UIKit springboard.
//  Simple iOS-style: squircle icon + name label underneath.
//

import UIKit

final class LCSpringboardIconCell: UICollectionViewCell {

    // MARK: - Subviews

    let iconImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        return iv
    }()

    let nameLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .label
        label.textAlignment = .center
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.78
        return label
    }()

    

    /// Delete button shown in edit mode (top-left of icon).
    let deleteButton: UIButton = {
        let btn = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
        btn.setImage(UIImage(systemName: "minus", withConfiguration: config), for: .normal)
        btn.tintColor = .white
        btn.backgroundColor = UIColor.darkGray.withAlphaComponent(0.85)
        btn.isHidden = true
        btn.alpha = 0
        return btn
    }()

    /// Dimming overlay + spinner for `.installing` state.
    private let installOverlay: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        v.isHidden = true
        return v
    }()

    private let activityIndicator: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = .white
        spinner.hidesWhenStopped = true
        return spinner
    }()

    // MARK: - State

    private(set) var isAnimating = false
    var onDeleteTap: (() -> Void)?
    var onTap: (() -> Void)?

    /// Whether this cell represents a placeholder (invisible).
    private(set) var isPlaceholderCell = false

    /// The item this cell was last configured with.
    /// Used by the drag manager to read back cell order after moves.
    private(set) var configuredItem: FlekHomeItem?

    /// Liquid Glass (iOS 26+) or thin material card background.
    private var glassBackgroundView: UIVisualEffectView?

    // MARK: - Layout constants

    static let iconSize: CGFloat = 60
    private static let iconCornerRadius: CGFloat = 13.4 // ~0.2237 * 60
    private static let deleteButtonSize: CGFloat = 24
    
    private static let cardCorner: CGFloat = 20
    private static let cardPadding: CGFloat = 10
    private static let iconTopPadding: CGFloat = 16
    private static let labelTopSpacing: CGFloat = 6
    private static let labelHeight: CGFloat = 16

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        clipsToBounds = false
        contentView.clipsToBounds = false

        setupGlassBackground()

        contentView.addSubview(iconImageView)
        contentView.addSubview(nameLabel)
        contentView.addSubview(deleteButton)

        // Install overlay on top of icon
        iconImageView.addSubview(installOverlay)
        installOverlay.addSubview(activityIndicator)

        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)

        let tap = UITapGestureRecognizer(target: self, action: #selector(cellTapped))
        contentView.addGestureRecognizer(tap)
    }

    private func setupGlassBackground() {
        let effectView: UIVisualEffectView
        if #available(iOS 26, *) {
            effectView = UIVisualEffectView(effect: UIGlassEffect())
        } else {
            effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        }
        effectView.layer.cornerRadius = Self.cardCorner
        effectView.layer.cornerCurve = .continuous
        effectView.clipsToBounds = true

        // On pre-iOS 26, add a white tint overlay for the frosted look
        if #unavailable(iOS 26) {
            let tint = UIView()
            tint.backgroundColor = UIColor.white.withAlphaComponent(0.45)
            tint.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            effectView.contentView.addSubview(tint)

            // Subtle border
            effectView.layer.borderWidth = 0.5
            effectView.layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
        }

        contentView.insertSubview(effectView, at: 0)
        glassBackgroundView = effectView
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let bounds = contentView.bounds
        let cardSide = bounds.width

        // Square glass card, offset down to leave room for delete button overhang
        let cardY = (bounds.height - cardSide) / 2
        let cardFrame = CGRect(x: 0, y: cardY, width: cardSide, height: cardSide)
        glassBackgroundView?.frame = cardFrame
        glassBackgroundView?.layer.cornerRadius = Self.cardCorner

        // Content block: icon + spacing + label
        let iconS = Self.iconSize
        let contentHeight = iconS + Self.labelTopSpacing + Self.labelHeight
        let contentY = cardY + (cardSide - contentHeight) / 2

        let iconX = (bounds.width - iconS) / 2
        iconImageView.frame = CGRect(x: iconX, y: contentY, width: iconS, height: iconS)
        applySquircleMask()

        installOverlay.frame = iconImageView.bounds
        activityIndicator.center = CGPoint(x: iconS / 2, y: iconS / 2)

        nameLabel.frame = CGRect(
            x: 4,
            y: contentY + iconS + Self.labelTopSpacing,
            width: bounds.width - 8,
            height: Self.labelHeight
        )

        let dbSize = Self.deleteButtonSize
        deleteButton.frame = CGRect(
            x: cardFrame.minX - (dbSize / 3),
            y: cardFrame.minY - (dbSize / 3),
            width: dbSize,
            height: dbSize
        )
        deleteButton.layer.cornerRadius = dbSize / 2
        deleteButton.layer.masksToBounds = true
    }

    private func applySquircleMask() {
        let path = UIBezierPath(
            roundedRect: iconImageView.bounds,
            cornerRadius: Self.iconCornerRadius
        )
        let mask = CAShapeLayer()
        mask.path = path.cgPath
        iconImageView.layer.mask = mask
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stopJiggle()
        iconImageView.image = nil
        nameLabel.text = nil
        deleteButton.isHidden = true
        deleteButton.alpha = 0
        installOverlay.isHidden = true
        activityIndicator.stopAnimating()
        contentView.alpha = 1
        contentView.isHidden = false
        glassBackgroundView?.isHidden = false
        isUserInteractionEnabled = true
        isPlaceholderCell = false
        onDeleteTap = nil
        onTap = nil
    }

    // MARK: - Configuration

    func configure(with item: FlekHomeItem, darkMode: Bool) {
        configuredItem = item
        switch item {
        case .defaultApp(let kind):
            iconImageView.image = UIImage(named: kind.iconAssetName)
            nameLabel.text = kind.title
            isPlaceholderCell = false

        case .installed(let app):
            iconImageView.image = app.appInfo.iconIsDarkIcon(darkMode)
            nameLabel.text = app.appInfo.displayName()
            isPlaceholderCell = false

        case .installing:
            iconImageView.image = nil
            nameLabel.text = "Installing..."
            installOverlay.isHidden = false
            activityIndicator.startAnimating()
            isPlaceholderCell = false

        case .placeholder:
            iconImageView.image = nil
            nameLabel.text = nil
            contentView.alpha = 0
            glassBackgroundView?.isHidden = true
            isUserInteractionEnabled = false
            isPlaceholderCell = true
        }
    }

    // MARK: - Edit mode

    func setDeleteButtonVisible(_ visible: Bool, animated: Bool = true) {
        if visible {
            deleteButton.isHidden = false
            if animated {
                UIView.animate(withDuration: 0.25) {
                    self.deleteButton.alpha = 1
                }
            } else {
                deleteButton.alpha = 1
            }
        } else {
            if animated {
                UIView.animate(withDuration: 0.25, animations: {
                    self.deleteButton.alpha = 0
                }, completion: { _ in
                    self.deleteButton.isHidden = true
                })
            } else {
                deleteButton.alpha = 0
                deleteButton.isHidden = true
            }
        }
    }

    // MARK: - Jiggle animation (from jSpringBoard)

    func startJiggle() {
        guard !isAnimating else { return }
        isAnimating = true

        let posAnim = CAKeyframeAnimation(keyPath: "position")
        posAnim.values = [
            CGPoint(x: -1, y: -1),
            CGPoint(x: 0, y: 0),
            CGPoint(x: -1, y: 0),
            CGPoint(x: 0, y: -1),
            CGPoint(x: -1, y: -1)
        ]
        posAnim.calculationMode = .linear
        posAnim.isAdditive = true

        let rotAnim = CAKeyframeAnimation(keyPath: "transform")
        rotAnim.valueFunction = CAValueFunction(name: .rotateZ)
        rotAnim.values = [-0.03525565, 0.03525565, -0.03525565]
        rotAnim.calculationMode = .linear
        rotAnim.isAdditive = true

        let group = CAAnimationGroup()
        group.duration = 0.25
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        group.beginTime = CACurrentMediaTime() + Double.random(in: 0...0.25)
        group.animations = [posAnim, rotAnim]

        contentView.layer.add(group, forKey: "jitterAnimation")
    }

    func stopJiggle() {
        guard isAnimating else { return }
        isAnimating = false
        contentView.layer.removeAnimation(forKey: "jitterAnimation")
        contentView.transform = .identity
    }

    // MARK: - Custom snapshot (mirrors jSpringBoard's HomeItemCell.snapshotView())

    /// Creates a snapshot by individually snapshotting each subview and
    /// reconstructing them in a custom container. This avoids the dark/black
    /// artefact that `UIView.snapshotView(afterScreenUpdates:)` produces
    /// when capturing `UIVisualEffectView` blur/glass backgrounds.
    func dragSnapshotView() -> LCIconCellSnapshotView {
        let container = LCIconCellSnapshotView(frame: bounds)
        container.clipsToBounds = false

        // 1. Card background — recreate instead of snapshotting
        // (UIVisualEffectView snapshots are unreliable, especially UIGlassEffect)
        if let glass = glassBackgroundView {
            let bgCopy: UIVisualEffectView
            if #available(iOS 26, *) {
                bgCopy = UIVisualEffectView(effect: UIGlassEffect())
            } else {
                bgCopy = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
                let tint = UIView()
                tint.backgroundColor = UIColor.white.withAlphaComponent(0.45)
                tint.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                bgCopy.contentView.addSubview(tint)
                bgCopy.layer.borderWidth = 0.5
                bgCopy.layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
            }
            bgCopy.frame = glass.frame
            bgCopy.layer.cornerRadius = Self.cardCorner
            bgCopy.layer.cornerCurve = .continuous
            bgCopy.clipsToBounds = true
            container.addSubview(bgCopy)
        }

        // 2. Icon
        if let snap = iconImageView.snapshotView(afterScreenUpdates: true) {
            snap.frame = iconImageView.frame
            container.addSubview(snap)
        }

        // 3. Name label
        if let snap = nameLabel.snapshotView(afterScreenUpdates: true) {
            snap.frame = nameLabel.frame
            container.addSubview(snap)
        }

        // 4. Delete button — capture with identity transform, then restore
        let originalTransform = deleteButton.transform
        deleteButton.transform = .identity
        if let snap = deleteButton.snapshotView(afterScreenUpdates: true) {
            snap.frame = deleteButton.frame
            snap.transform = originalTransform
            snap.alpha = deleteButton.alpha
            snap.isHidden = deleteButton.isHidden
            container.addSubview(snap)
            container.deleteButtonSnapshot = snap
        }
        deleteButton.transform = originalTransform

        return container
    }

    // MARK: - Actions

    @objc private func deleteTapped() {
        onDeleteTap?()
    }

    @objc private func cellTapped() {
        onTap?()
    }
}

// MARK: - Snapshot container (mirrors jSpringBoard's HomeItemCellSnapshotView)

final class LCIconCellSnapshotView: UIView {
    /// Reference to the delete button snapshot for animate-in during drag.
    var deleteButtonSnapshot: UIView?
}
