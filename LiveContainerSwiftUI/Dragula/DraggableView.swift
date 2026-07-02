//
//  DraggableView.swift
//  https://github.com/mufasayc/Dragula
//  MIT License - Created by Mustafa Yusuf on 05/06/25.
//

import SwiftUI
import UIKit

struct DraggableView<Preview: View, DropView: View>: UIViewRepresentable {

    let preview: () -> Preview
    let dropView: () -> DropView
    let itemProvider: () -> NSItemProvider
    let onDragWillBegin: (() -> Void)?
    let onDragWillEnd: (() -> Void)?
    /// When true, the view shows the drop placeholder instead of the full
    /// preview. This is needed for cross-page drags: SwiftUI destroys and
    /// recreates the DraggableView when the item moves to a different page's
    /// ForEach, so the UIKit visibility state from willAnimateLiftWith is lost.
    let isBeingDragged: Bool

    init(
        @ViewBuilder preview: @escaping () -> Preview,
        @ViewBuilder dropView: @escaping () -> DropView,
        itemProvider: @escaping () -> NSItemProvider,
        isBeingDragged: Bool = false,
        onDragWillBegin: (() -> Void)? = nil,
        onDragWillEnd: (() -> Void)? = nil
    ) {
        self.preview = preview
        self.dropView = dropView
        self.itemProvider = itemProvider
        self.isBeingDragged = isBeingDragged
        self.onDragWillBegin = onDragWillBegin
        self.onDragWillEnd = onDragWillEnd
    }

    func makeUIView(context: Context) -> DraggableUIView<Preview, DropView> {
        let view = DraggableUIView(
            preview: preview,
            dropView: dropView,
            itemProvider: itemProvider,
            onDragWillBegin: onDragWillBegin,
            onDragWillEnd: onDragWillEnd
        )
        return view
    }

    func updateUIView(_ uiView: DraggableUIView<Preview, DropView>, context: Context) {
        uiView.cornerRadius = context.environment.dragPreviewCornerRadius
        uiView.setDraggedAppearance(isBeingDragged)
    }
}

class DraggableUIView<Preview: View, DropView: View>: UIView, UIDragInteractionDelegate {

    var cornerRadius: CGFloat = 12
    private let preview: () -> Preview
    private let dropView: () -> DropView
    private let itemProvider: () -> NSItemProvider
    private let onDragWillBegin: (() -> Void)?
    private let onDragWillEnd: (() -> Void)?

    private var previewHostingController: UIHostingController<Preview>?
    private var dropViewHostingController: UIHostingController<DropView>?

    /// Whether this view instance has an active local drag (i.e. it was the
    /// view that initiated the UIDragInteraction). Prevents updateUIView from
    /// interfering with the normal drag lifecycle on the original view.
    private var hasLocalDrag = false

    init(
        preview: @escaping () -> Preview,
        dropView: @escaping () -> DropView,
        itemProvider: @escaping () -> NSItemProvider,
        onDragWillBegin: (() -> Void)?,
        onDragWillEnd: (() -> Void)?
    ) {
        self.preview = preview
        self.dropView = dropView
        self.itemProvider = itemProvider
        self.onDragWillBegin = onDragWillBegin
        self.onDragWillEnd = onDragWillEnd
        super.init(frame: .zero)
        clipsToBounds = false

        let previewHC = UIHostingController(rootView: preview())
        previewHC.view.backgroundColor = .clear
        previewHC.view.clipsToBounds = false
        previewHC.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(previewHC.view)
        NSLayoutConstraint.activate([
            previewHC.view.topAnchor.constraint(equalTo: topAnchor),
            previewHC.view.bottomAnchor.constraint(equalTo: bottomAnchor),
            previewHC.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            previewHC.view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        self.previewHostingController = previewHC

        let dropHC = UIHostingController(rootView: dropView())
        dropHC.view.backgroundColor = .clear
        dropHC.view.clipsToBounds = false
        dropHC.view.translatesAutoresizingMaskIntoConstraints = false
        dropHC.view.isHidden = true
        addSubview(dropHC.view)
        NSLayoutConstraint.activate([
            dropHC.view.topAnchor.constraint(equalTo: topAnchor),
            dropHC.view.bottomAnchor.constraint(equalTo: bottomAnchor),
            dropHC.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            dropHC.view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        self.dropViewHostingController = dropHC

        let dragInteraction = UIDragInteraction(delegate: self)
        addInteraction(dragInteraction)
    }

    /// Called from updateUIView to show the drop placeholder for items that
    /// are currently being dragged but were recreated on a different page.
    func setDraggedAppearance(_ dragged: Bool) {
        // Don't override if this view instance owns the active drag session –
        // the normal willAnimateLiftWith / willEndWith callbacks handle it.
        guard !hasLocalDrag else { return }
        previewHostingController?.view.isHidden = dragged
        dropViewHostingController?.view.isHidden = !dragged
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        disableAncestorClipping()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        disableAncestorClipping()
    }

    /// Walk up the view hierarchy and disable clipping on SwiftUI-managed
    /// wrapper views so that content extending beyond cell bounds (delete
    /// buttons, wiggle rotation, badges) is never cut off.
    private func disableAncestorClipping() {
        var v: UIView? = superview
        while let parent = v {
            if parent.clipsToBounds {
                parent.clipsToBounds = false
            }
            v = parent.superview
        }
    }

    // MARK: - UIDragInteractionDelegate

    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
        let provider = itemProvider()
        let item = UIDragItem(itemProvider: provider)
        return [item]
    }

    func dragInteraction(_ interaction: UIDragInteraction, itemsForAddingTo session: UIDragSession, withTouchAt point: CGPoint) -> [UIDragItem] {
        []
    }

    func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem, session: UIDragSession) -> UITargetedDragPreview? {
        guard let previewView = previewHostingController?.view else { return nil }
        let params = UIDragPreviewParameters()
        params.backgroundColor = .clear
        params.visiblePath = UIBezierPath(roundedRect: previewView.bounds, cornerRadius: cornerRadius)
        let target = UIDragPreviewTarget(container: self, center: CGPoint(x: bounds.midX, y: bounds.midY))
        guard let snapshot = previewView.snapshot() else { return nil }
        return UITargetedDragPreview(view: UIImageView(image: snapshot), parameters: params, target: target)
    }

    func dragInteraction(_ interaction: UIDragInteraction, willAnimateLiftWith animator: UIDragAnimating, session: UIDragSession) {
        hasLocalDrag = true
        onDragWillBegin?()
        animator.addCompletion { position in
            if position == .end {
                self.previewHostingController?.view.isHidden = true
                self.dropViewHostingController?.view.isHidden = false
            }
        }
    }

    func dragInteraction(_ interaction: UIDragInteraction, previewForCancelling item: UIDragItem, withDefault defaultPreview: UITargetedDragPreview) -> UITargetedDragPreview? {
        guard let previewView = previewHostingController?.view else { return nil }
        let params = UIDragPreviewParameters()
        params.backgroundColor = .clear
        params.visiblePath = UIBezierPath(roundedRect: previewView.bounds, cornerRadius: cornerRadius)
        let target = UIDragPreviewTarget(container: self, center: CGPoint(x: bounds.midX, y: bounds.midY))
        guard let snapshot = previewView.snapshot() else { return nil }
        return UITargetedDragPreview(view: UIImageView(image: snapshot), parameters: params, target: target)
    }

    func dragInteraction(_ interaction: UIDragInteraction, prefersFullSizePreviewsFor session: UIDragSession) -> Bool {
        true
    }

    func dragInteraction(_ interaction: UIDragInteraction, willAnimateCancelWith animator: UIDragAnimating) {
        animator.addCompletion { _ in
            self.hasLocalDrag = false
            self.previewHostingController?.view.isHidden = false
            self.dropViewHostingController?.view.isHidden = true
        }
    }

    func dragInteraction(_ interaction: UIDragInteraction, session: UIDragSession, willEndWith operation: UIDropOperation) {
        hasLocalDrag = false
        previewHostingController?.view.isHidden = false
        dropViewHostingController?.view.isHidden = true
        onDragWillEnd?()
    }

    func dragInteraction(_ interaction: UIDragInteraction, sessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool {
        true
    }
}

private extension UIView {
    func snapshot() -> UIImage? {
        let renderer = UIGraphicsImageRenderer(size: bounds.size)
        return renderer.image { _ in
            layer.render(in: UIGraphicsGetCurrentContext()!)
        }
    }
}
