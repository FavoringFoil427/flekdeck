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

    init(
        @ViewBuilder preview: @escaping () -> Preview,
        @ViewBuilder dropView: @escaping () -> DropView,
        itemProvider: @escaping () -> NSItemProvider,
        onDragWillBegin: (() -> Void)? = nil,
        onDragWillEnd: (() -> Void)? = nil
    ) {
        self.preview = preview
        self.dropView = dropView
        self.itemProvider = itemProvider
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

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
            self.previewHostingController?.view.isHidden = false
            self.dropViewHostingController?.view.isHidden = true
        }
    }

    func dragInteraction(_ interaction: UIDragInteraction, session: UIDragSession, willEndWith operation: UIDropOperation) {
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
