//
//  Dragula.swift
//  https://github.com/mufasayc/Dragula
//  MIT License - Created by Mustafa Yusuf on 05/06/25.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A protocol representing a section that contains drag-and-droppable items.
public protocol DragulaSection: Identifiable {
    associatedtype Item: DragulaItem
    var items: [Item] { get set }
}

/// A protocol for individual drag-and-droppable items.
public protocol DragulaItem: Identifiable {
    /// Override to make an item not draggable, default value is `true`
    var isDraggable: Bool { get }
    /// Override to provide a meaningful item provider for drag sessions.
    func getItemProvider() -> NSItemProvider
}

extension DragulaItem {
    public var isDraggable: Bool { true }

    public func getItemProvider() -> NSItemProvider {
        .init()
    }
}

/// A reusable SwiftUI view that supports sectioned drag-and-drop reordering of items.
public struct DragulaSectionedView<Header: View,
                                   Card: View,
                                   DropView: View,
                                   Section: DragulaSection>: View {

    @Binding private var sections: [Section]
    @Binding private var items: [Section.Item]
    @State private var draggedItems: [Section.Item] = []

    private let header: (Section) -> Header
    private let card: (Section.Item) -> Card
    private let dropView: ((Section.Item) -> DropView)?
    private let dropCompleted: () -> Void

    private let supportedUTTypes: [UTType] = []

    public init(
        sections: Binding<[Section]>,
        @ViewBuilder header: @escaping (Section) -> Header,
        @ViewBuilder card: @escaping (Section.Item) -> Card,
        @ViewBuilder dropView: @escaping (Section.Item) -> DropView,
        dropCompleted: @escaping () -> Void
    ) {
        self._sections = sections
        self._items = .constant([])
        self.header = header
        self.card = card
        self.dropView = dropView
        self.dropCompleted = dropCompleted
    }

    public init(
        items: Binding<[Section.Item]>,
        @ViewBuilder header: @escaping (Section) -> Header,
        @ViewBuilder card: @escaping (Section.Item) -> Card,
        @ViewBuilder dropView: @escaping (Section.Item) -> DropView,
        dropCompleted: @escaping () -> Void
    ) {
        self._sections = .constant([])
        self._items = items
        self.header = header
        self.card = card
        self.dropView = dropView
        self.dropCompleted = dropCompleted
    }

    public var body: some View {
        ForEach(sections) { section in
            header(section)
                .onDrop(
                    of: supportedUTTypes,
                    delegate: DragulaSectionDropDelegate(
                        item: nil,
                        sectionID: section.id,
                        sections: $sections,
                        draggedItems: $draggedItems
                    )
                )

            ForEach(section.items) { item in
                card(item)
                    .hidden(item.isDraggable)
                    .overlay {
                        if item.isDraggable {
                            DraggableView(
                                preview: {
                                    card(item)
                                }, dropView: {
                                    dropView?(item)
                                }, itemProvider: {
                                    item.getItemProvider()
                                }, onDragWillBegin: {
                                    self.draggedItems.append(item)
                                }, onDragWillEnd: {
                                    self.draggedItems = []
                                    self.dropCompleted()
                                })
                        }
                    }
                    .onDrop(
                        of: supportedUTTypes,
                        delegate: DragulaSectionDropDelegate(
                            item: item,
                            sectionID: section.id,
                            sections: $sections,
                            draggedItems: $draggedItems
                        )
                    )
            }
        }
    }
}

/// A reusable SwiftUI view that supports drag-and-drop reordering of a flat list of items.
public struct DragulaView<Card: View, DropView: View, Item: DragulaItem>: View {

    @State private var draggedItems: [Item] = []

    @Binding var items: [Item]
    private let card: (Item) -> Card
    private let dropView: ((Item) -> DropView)?
    private let dropCompleted: () -> Void

    private let supportedUTTypes: [UTType] = []

    public init(
        items: Binding<[Item]>,
        @ViewBuilder card: @escaping (Item) -> Card,
        @ViewBuilder dropView: @escaping (Item) -> DropView,
        dropCompleted: @escaping () -> Void
    ) {
        self._items = items
        self.card = card
        self.dropView = dropView
        self.dropCompleted = dropCompleted
    }

    public var body: some View {
        ForEach(items) { item in
            card(item)
                .hidden(item.isDraggable)
                .overlay {
                    if item.isDraggable {
                        DraggableView(
                            preview: {
                                card(item)
                            }, dropView: {
                                dropView?(item)
                            }, itemProvider: {
                                item.getItemProvider()
                            }, onDragWillBegin: {
                                self.draggedItems.append(item)
                            }, onDragWillEnd: {
                                self.draggedItems = []
                                self.dropCompleted()
                            })
                    }
                }
                .onDrop(
                    of: supportedUTTypes,
                    delegate: DragulaDropDelegate(
                        item: item,
                        items: $items,
                        draggedItems: $draggedItems
                    )
                )
        }
    }
}

// MARK: - Drop Delegates

struct DragulaDropDelegate<Item: DragulaItem>: DropDelegate {

    private let generator = UIImpactFeedbackGenerator(style: .rigid)

    private let item: Item
    @Binding private var items: [Item]
    @Binding private var draggedItems: [Item]

    private let animation: Animation = .spring

    init(
        item: Item,
        items: Binding<[Item]>,
        draggedItems: Binding<[Item]>
    ) {
        self.item = item
        self._items = items
        self._draggedItems = draggedItems
    }

    func performDrop(info: DropInfo) -> Bool {
        !draggedItems.isEmpty
    }

    private func index(of item: Item) -> Int? {
        items.firstIndex(where: { $0.id == item.id })
    }

    func dropEntered(info: DropInfo) {
        guard !draggedItems.isEmpty else {
            return
        }

        guard draggedItems.allSatisfy({ $0.id != item.id }) else {
            return
        }

        var didPerformAnyChanges: Bool = false

        withAnimation(animation) {
            for dragged in draggedItems {
                if let fromIndex = index(of: dragged),
                   let toIndex = index(of: item) {
                    didPerformAnyChanges = true
                    items.move(
                        fromOffsets: IndexSet(integer: fromIndex),
                        toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
                    )
                }
            }
        }

        if didPerformAnyChanges {
            playHaptic()
        }
    }

    func playHaptic() {
        generator.prepare()
        generator.impactOccurred()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .cancel)
    }
}

fileprivate struct DragulaSectionDropDelegate<Section: DragulaSection>: DropDelegate {

    private let generator = UIImpactFeedbackGenerator(style: .rigid)

    private let item: Section.Item?
    private let sectionID: Section.ID
    @Binding private var sections: [Section]
    @Binding private var draggedItems: [Section.Item]

    private let animation: Animation = .spring

    init(
        item: Section.Item?,
        sectionID: Section.ID,
        sections: Binding<[Section]>,
        draggedItems: Binding<[Section.Item]>
    ) {
        self.item = item
        self.sectionID = sectionID
        self._sections = sections
        self._draggedItems = draggedItems
    }

    func performDrop(info: DropInfo) -> Bool {
        !draggedItems.isEmpty
    }

    private func sectionIndex(for item: Section.Item) -> Int? {
        sections.firstIndex(where: { section in
            section.items.contains { $0.id == item.id }
        })
    }

    private func itemIndex(for item: Section.Item) -> Int? {
        for section in sections {
            if let index = section.items.firstIndex(where: { $0.id == item.id }) {
                return index
            }
        }
        return nil
    }

    func dropEntered(info: DropInfo) {
        guard !draggedItems.isEmpty else {
            return
        }

        guard draggedItems.allSatisfy({ $0.id != item?.id }) else {
            return
        }

        let toSectionIndex: Int
        if let item, let index = sectionIndex(for: item) {
            toSectionIndex = index
        } else if let index = sections.firstIndex(where: { $0.id == sectionID }) {
            toSectionIndex = index
        } else {
            return
        }

        var didPerformAnyChanges: Bool = false

        withAnimation(animation) {
            for draggedItem in draggedItems {
                if let fromSectionIndex = sectionIndex(for: draggedItem),
                   let fromIndex = itemIndex(for: draggedItem) {
                    let toIndex: Int
                    if let item, let index = itemIndex(for: item) {
                        toIndex = index
                    } else {
                        toIndex = .zero
                    }

                    if fromSectionIndex == toSectionIndex {
                        if fromIndex != toIndex {
                            didPerformAnyChanges = true
                            sections[toSectionIndex].items.move(
                                fromOffsets: IndexSet(integer: fromIndex),
                                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
                            )
                        }
                    } else {
                        didPerformAnyChanges = true
                        sections[fromSectionIndex].items.remove(at: fromIndex)
                        sections[toSectionIndex].items.insert(draggedItem, at: toIndex)
                    }
                }
            }
        }

        if didPerformAnyChanges {
            playHaptic()
        }
    }

    func playHaptic() {
        generator.prepare()
        generator.impactOccurred()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .cancel)
    }

    func validateDrop(info: DropInfo) -> Bool {
        if item == nil {
            let sectionIndices = Set(draggedItems.compactMap { sectionIndex(for: $0) })
            if sectionIndices.count == 1,
               let sectionIndex = sectionIndices.first,
               sections[sectionIndex].id == sectionID {
                return false
            } else {
                return true
            }
        }

        return true
    }
}

/// An environment key to customize the corner radius of the drag preview.
private struct DragPreviewCornerRadiusKey: EnvironmentKey {
    static let defaultValue: CGFloat = 12
}

extension EnvironmentValues {
    public var dragPreviewCornerRadius: CGFloat {
        get { self[DragPreviewCornerRadiusKey.self] }
        set { self[DragPreviewCornerRadiusKey.self] = newValue }
    }
}

fileprivate extension View {
    @ViewBuilder
    func hidden(_ isHidden: Bool) -> some View {
        if isHidden {
            self.hidden()
        } else {
            self
        }
    }
}
