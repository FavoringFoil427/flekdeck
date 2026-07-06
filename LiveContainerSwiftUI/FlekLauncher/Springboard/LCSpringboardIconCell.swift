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
        btn.isHidden = true
        btn.alpha = 0
        return btn
    }()

    /// Badge for single-mode apps (top-right of icon).
    private let singleBadge: UILabel = {
        let label = UILabel()
        label.text = "1"
        label.font = .systemFont(ofSize: 12, weight: .bold)
        label.textColor = .white
        label.textAlignment = .center
        label.backgroundColor = .systemBlue
        label.isHidden = true
        return label
    }()

    /// Dimming overlay for `.installing` state (covers icon).
    private let installOverlay: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        v.isHidden = true
        return v
    }()

    /// Spinner for indeterminate install state.
    private let activityIndicator: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = .white
        spinner.hidesWhenStopped = true
        return spinner
    }()

    /// Percentage label centered on icon during download.
    private let progressLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 13, weight: .bold)
        label.textColor = .white
        label.textAlignment = .center
        label.isHidden = true
        return label
    }()

    /// Blue progress bar near bottom of icon.
    private let progressTrack: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.white.withAlphaComponent(0.5)
        v.isHidden = true
        return v
    }()

    private let progressFill: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor(red: 0/255, green: 117/255, blue: 255/255, alpha: 1)
        return v
    }()

    /// Current icon URL loading task.
    private var iconLoadTask: URLSessionDataTask?
    /// URL string of the icon currently being loaded (or already loaded).
    /// Used to avoid cancelling + restarting the same load on every
    /// progress update (configureInstallState is called very frequently).
    private var loadingIconURL: String?

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

    // MARK: - Suppress default highlight

    override var isHighlighted: Bool {
        get { super.isHighlighted }
        set { /* No highlight visual for springboard icons */ }
    }

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
        contentView.addSubview(singleBadge)
        contentView.addSubview(deleteButton)

        // Install overlay on top of icon
        iconImageView.addSubview(installOverlay)
        installOverlay.addSubview(activityIndicator)
        installOverlay.addSubview(progressLabel)
        progressTrack.addSubview(progressFill)
        installOverlay.addSubview(progressTrack)

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

        // Glass card fills the full cell bounds
        glassBackgroundView?.frame = bounds
        glassBackgroundView?.layer.cornerRadius = Self.cardCorner

        // Content block: icon + spacing + label
        let iconS = Self.iconSize
        let contentHeight = iconS + Self.labelTopSpacing + Self.labelHeight
        let contentY = (bounds.height - contentHeight) / 2

        let iconX = (bounds.width - iconS) / 2
        iconImageView.frame = CGRect(x: iconX, y: contentY, width: iconS, height: iconS)
        applySquircleMask()

        installOverlay.frame = iconImageView.bounds
        installOverlay.layer.cornerRadius = Self.iconCornerRadius
        installOverlay.clipsToBounds = true
        activityIndicator.center = CGPoint(x: iconS / 2, y: iconS / 2)
        progressLabel.frame = CGRect(x: 0, y: 0, width: iconS, height: iconS)

        // Progress bar near bottom of icon
        let trackW = iconS * 0.78
        let trackH: CGFloat = 14
        let trackX = (iconS - trackW) / 2
        let trackY = iconS - trackH - 6
        progressTrack.frame = CGRect(x: trackX, y: trackY, width: trackW, height: trackH)
        progressTrack.layer.cornerRadius = trackH / 2
        progressTrack.clipsToBounds = true
        updateProgressFillWidth()

        nameLabel.frame = CGRect(
            x: 4,
            y: contentY + iconS + Self.labelTopSpacing,
            width: bounds.width - 8,
            height: Self.labelHeight
        )

        // Single-mode badge (top-right of icon)
        let badgeSize: CGFloat = 20
        singleBadge.frame = CGRect(
            x: iconImageView.frame.maxX - badgeSize / 2,
            y: iconImageView.frame.minY - badgeSize / 3,
            width: badgeSize,
            height: badgeSize
        )
        singleBadge.layer.cornerRadius = badgeSize / 2
        singleBadge.layer.masksToBounds = true

        let dbSize = Self.deleteButtonSize
        deleteButton.frame = CGRect(
            x: -(dbSize / 3),
            y: -(dbSize / 3),
            width: dbSize,
            height: dbSize
        )
        deleteButton.layer.cornerRadius = dbSize / 2
        deleteButton.layer.masksToBounds = true

        updateDeleteButtonColors()
    }

    private func updateDeleteButtonColors() {
        let isDark = traitCollection.userInterfaceStyle == .dark
        deleteButton.tintColor = isDark ? .white : .black
        deleteButton.backgroundColor = isDark
            ? UIColor(white: 0.25, alpha: 1)
            : UIColor(white: 0.85, alpha: 1)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            updateDeleteButtonColors()
        }
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
        singleBadge.isHidden = true
        installOverlay.isHidden = true
        activityIndicator.stopAnimating()
        progressLabel.isHidden = true
        progressTrack.isHidden = true
        iconLoadTask?.cancel()
        iconLoadTask = nil
        loadingIconURL = nil
        currentFraction = 0
        contentView.alpha = 1
        contentView.isHidden = false
        glassBackgroundView?.isHidden = false
        isUserInteractionEnabled = true
        isPlaceholderCell = false
        onDeleteTap = nil
        onTap = nil
    }

    // MARK: - Configuration

    /// Current install fraction for progress fill layout.
    private var currentFraction: Double = 0

    func configure(with item: FlekHomeItem, darkMode: Bool, installState: FlekInstallState? = nil) {
        configuredItem = item
        switch item {
        case .defaultApp(let kind):
            iconImageView.image = UIImage(named: kind.iconAssetName)
            nameLabel.text = kind.title
            isPlaceholderCell = false

        case .installed(let app):
            iconImageView.image = app.appInfo.iconIsDarkIcon(darkMode)
            nameLabel.text = app.appInfo.displayName()
            singleBadge.isHidden = !FlekLaunchModeStore.shared.showsSingleBadge(for: app)
            isPlaceholderCell = false

        case .installing:
            isPlaceholderCell = false
            configureInstallState(installState)

        case .placeholder:
            iconImageView.image = nil
            nameLabel.text = nil
            contentView.alpha = 0
            glassBackgroundView?.isHidden = true
            isUserInteractionEnabled = false
            isPlaceholderCell = true
        }
    }

    /// Update just the install state (progress/icon) without full reconfigure.
    func updateInstallState(_ state: FlekInstallState?) {
        guard case .installing = configuredItem else { return }
        configureInstallState(state)
    }

    private func configureInstallState(_ state: FlekInstallState?) {
        // Name
        nameLabel.text = state?.name ?? "Installing..."

        // Icon from URL — only start a new load when the URL changes.
        // configureInstallState is called on every progress tick, so
        // cancelling + restarting the load each time prevented the
        // icon from ever finishing its download.
        if let urlStr = state?.iconURL, let url = URL(string: urlStr) {
            if urlStr != loadingIconURL || iconImageView.image == nil {
                loadingIconURL = urlStr
                iconLoadTask?.cancel()
                iconLoadTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                    guard let data, let image = UIImage(data: data) else { return }
                    DispatchQueue.main.async {
                        self?.iconImageView.image = image
                    }
                }
                iconLoadTask?.resume()
            }
        } else if state?.iconURL == nil && loadingIconURL != nil {
            // URL was removed — clear the icon
            loadingIconURL = nil
            iconLoadTask?.cancel()
            iconLoadTask = nil
            iconImageView.image = nil
        }

        // Show overlay
        installOverlay.isHidden = false

        if let state, !state.indeterminate {
            // Determinate: show percentage + progress bar
            activityIndicator.stopAnimating()
            progressLabel.isHidden = false
            progressLabel.text = "\(Int((state.fraction * 100).rounded()))%"
            progressTrack.isHidden = false
            currentFraction = state.fraction
            updateProgressFillWidth()
        } else {
            // Indeterminate: show spinner
            activityIndicator.startAnimating()
            progressLabel.isHidden = true
            progressTrack.isHidden = true
            currentFraction = 0
        }
    }

    private func updateProgressFillWidth() {
        let trackW = progressTrack.bounds.width
        let trackH = progressTrack.bounds.height
        guard trackW > 0 else { return }
        let fillW = max(trackH - 4, (trackW - 4) * currentFraction)
        progressFill.frame = CGRect(x: 2, y: 2, width: fillW, height: trackH - 4)
        progressFill.layer.cornerRadius = (trackH - 4) / 2
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

    func startJiggle(force: Bool = false) {
        guard !isAnimating || force else { return }
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
        // jSpringBoard: small absolute time (far in the past) makes CA start
        // instantly at a random phase offset.
        group.beginTime = Double.random(in: 0...0.25)
        group.animations = [posAnim, rotAnim]

        contentView.layer.add(group, forKey: "jitterAnimation")
    }

    func stopJiggle() {
        isAnimating = false
        contentView.layer.removeAllAnimations()
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
