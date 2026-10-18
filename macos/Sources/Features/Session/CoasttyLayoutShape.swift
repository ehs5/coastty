import AppKit

/// Turning a live split tree into the shape a window remembers, and back again once the daemon has said which panes the tab holds.
///
/// The two halves are deliberately separate: the daemon owns which panes are in a tab, a window owns how they are arranged. Rebuilding is the one place they meet.
enum CoasttyLayoutShape {
    /// The arrangement of `tree`, with nothing about which panes fill it. Nil for a tree of one pane (or none), which needs no arrangement remembered.
    static func shape(of tree: SplitTree<Ghostty.SurfaceView>) -> CoasttyWindowLayout.Shape? {
        guard let root = tree.root else { return nil }
        let shape = shape(of: root)
        return shape.slotCount > 1 ? shape : nil
    }

    private static func shape(of node: SplitTree<Ghostty.SurfaceView>.Node) -> CoasttyWindowLayout.Shape {
        switch node {
        case .leaf:
            return .slot

        case .split(let split):
            return .split(
                direction: split.direction == .horizontal ? .horizontal : .vertical,
                ratio: split.ratio,
                left: shape(of: split.left),
                right: shape(of: split.right))
        }
    }

    /// Rebuilds a tree that arranges `panes` the way `shape` describes.
    ///
    /// A shape expecting a different number of panes than the daemon reports is discarded rather than forced: the panes are what actually exist, so they are laid out left to right instead of dropped to fit a stale arrangement.
    static func tree(
        panes: [Ghostty.SurfaceView],
        shape: CoasttyWindowLayout.Shape?
    ) -> SplitTree<Ghostty.SurfaceView> {
        guard !panes.isEmpty else { return .init() }

        if let shape, shape.slotCount == panes.count {
            var remaining = panes[...]
            if let root = fill(shape, from: &remaining) {
                return .init(root: root, zoomed: nil)
            }
        }

        return .init(root: evenlySplit(panes[...]), zoomed: nil)
    }

    /// Walks `shape`, taking one pane per slot in order.
    private static func fill(
        _ shape: CoasttyWindowLayout.Shape,
        from panes: inout ArraySlice<Ghostty.SurfaceView>
    ) -> SplitTree<Ghostty.SurfaceView>.Node? {
        switch shape {
        case .slot:
            guard let pane = panes.popFirst() else { return nil }
            return .leaf(view: pane)

        case .split(let direction, let ratio, let left, let right):
            guard let leftNode = fill(left, from: &panes) else { return nil }
            guard let rightNode = fill(right, from: &panes) else { return leftNode }
            return .split(.init(
                direction: direction == .horizontal ? .horizontal : .vertical,
                ratio: ratio,
                left: leftNode,
                right: rightNode))
        }
    }

    /// A balanced arrangement, for when there is no remembered shape to honour.
    private static func evenlySplit(
        _ panes: ArraySlice<Ghostty.SurfaceView>
    ) -> SplitTree<Ghostty.SurfaceView>.Node? {
        guard let first = panes.first else { return nil }
        guard panes.count > 1 else { return .leaf(view: first) }

        let middle = panes.startIndex + panes.count / 2
        guard let left = evenlySplit(panes[panes.startIndex..<middle]) else { return nil }
        guard let right = evenlySplit(panes[middle...]) else { return left }
        return .split(.init(direction: .horizontal, ratio: 0.5, left: left, right: right))
    }
}
