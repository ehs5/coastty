import SwiftUI

/// Reports a drag-reorderable row/tab's own on-screen frame, keyed by id, so a drag in progress can tell which slot it's currently over.
struct CoasttyRowFramePreferenceKey<ID: Hashable>: PreferenceKey {
    static var defaultValue: [ID: CGRect] { [:] }

    static func reduce(value: inout [ID: CGRect], nextValue: () -> [ID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Shared bookkeeping for a tab-bar/sidebar drag-to-reorder gesture.
struct CoasttyDragReorderState<ID: Hashable> {
    var draggingID: ID?
    var translation: CGFloat = 0

    /// Call from a drag gesture's `onChanged`. Runs `onStart` once, the instant `id` becomes the item being dragged.
    mutating func changed(id: ID, translation: CGFloat, onStart: () -> Void) {
        if draggingID != id {
            draggingID = id
            onStart()
        }
        self.translation = translation
    }

    /// Call from a drag gesture's `onEnded` to return to the no-drag state.
    mutating func reset() {
        draggingID = nil
        translation = 0
    }

    /// Bounds `translation` so the dragged row/tab's own offset can't carry it past the list's first or last slot.
    func clampedTranslation(originalIndex: Int, count: Int, slotSize: CGFloat) -> CGFloat {
        let minOffset = -CGFloat(originalIndex) * slotSize
        let maxOffset = CGFloat(count - 1 - originalIndex) * slotSize
        return min(max(translation, minOffset), maxOffset)
    }

    /// The offset to apply to a sibling row/tab reflowing out of the dragged item's way, given the drag's current source/target slot and one slot's size.
    static func siblingOffset(forIndexAt index: Int, originalIndex: Int, targetIndex: Int, slotSize: CGFloat) -> CGFloat {
        if targetIndex > originalIndex, index > originalIndex, index <= targetIndex { return -slotSize }
        if targetIndex < originalIndex, index < originalIndex, index >= targetIndex { return slotSize }
        return 0
    }
}

extension View {
    /// Fires on mouse-down alone (`minimumDistance: 0`), so a plain click still just selects while movement reorders.
    ///
    /// `coordinateSpace` must be the list's own, not `.local`: the row is
    /// offset by the very translation measured here, so its local space
    /// moves with each event and the previous offset gets subtracted from
    /// the next reading, leaving the row at about half the pointer's travel.
    func coasttyDragToReorder(
        axis: Axis,
        coordinateSpace: CoordinateSpace,
        onChanged: @escaping (CGFloat) -> Void,
        onEnded: @escaping () -> Void
    ) -> some View {
        gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: coordinateSpace)
                .onChanged { onChanged(axis == .horizontal ? $0.translation.width : $0.translation.height) }
                .onEnded { _ in onEnded() }
        )
    }

    /// Hides instantly the moment a drag starts, then fades back in once it settles.
    func coasttyFadeDuringDrag(_ isDragging: Bool) -> some View {
        opacity(isDragging ? 0 : 1)
            .animation(isDragging ? nil : .easeInOut(duration: 0.2), value: isDragging)
    }

    /// The dragged row snaps to every translation change so it tracks the
    /// cursor 1:1; siblings ease whenever their offset actually changes.
    ///
    /// One modifier rather than an `if`/`else` on `isDragging`: each branch
    /// is its own view identity, so switching would rebuild the row (and its
    /// gesture and hover state) at the very moment a drag starts or ends.
    func coasttyReorderRowAnimation(isDragging: Bool, translation: CGFloat) -> some View {
        animation(isDragging ? nil : .easeInOut(duration: 0.2), value: translation)
    }
}
