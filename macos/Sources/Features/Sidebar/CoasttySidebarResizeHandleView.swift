import AppKit

/// The grab target for resizing the sidebar.
///
/// Straddles the sidebar panel's trailing edge — see
/// `CoasttyTerminalSplitViewController.layoutResizeHandle` for why that
/// edge and not the boundary between the panes. Being able to grab it from
/// either side is why this is an AppKit view rather than part of the
/// SwiftUI sidebar: a SwiftUI overlay is confined to the sidebar's own
/// hosting view, and can't extend past the edge it straddles.
///
/// It is not the `NSSplitView`'s own divider either. That divider is drawn
/// zero-thickness on purpose (`CoasttySplitView.dividerThickness`), so it
/// has no hit area, and dragging it means letting `NSSplitViewController`
/// own the pane widths — which it re-solves from Auto Layout on every
/// layout pass, discarding whatever the user dragged to. Driving a store
/// that the split view item's thickness follows keeps the dragged width
/// authoritative instead.
final class CoasttySidebarResizeHandleView: NSView {
    /// How wide the strip is in total, split evenly either side of the
    /// edge it straddles. Narrow enough that it stays within the sidebar's
    /// empty trailing margin, so it never covers a row.
    static let width: CGFloat = 12

    private let widthStore: CoasttySidebarWidthStore

    /// The sidebar width and pointer position when the drag began. Deltas
    /// are taken from these rather than accumulated per event, so rounding
    /// can't drift over a long drag.
    private var dragStartWidth: CGFloat?
    private var dragStartX: CGFloat?

    init(widthStore: CoasttySidebarWidthStore) {
        self.widthStore = widthStore
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    /// Cursor rects are cached against the old frame, so moving the handle
    /// (the sidebar was resized, or the window was) has to invalidate them
    /// or the resize cursor keeps appearing where the handle used to be.
    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartWidth = widthStore.width
        dragStartX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartWidth, let dragStartX else { return }
        widthStore.updateWidth(dragStartWidth + (event.locationInWindow.x - dragStartX), maximum: maximumWidth)
    }

    /// Half the area the sidebar and terminal pane actually share, which is
    /// this handle's own superview — the split view. Not half the screen:
    /// in a window taking up half the display, that would be the entire
    /// window.
    private var maximumWidth: CGFloat {
        guard let available = superview?.bounds.width, available > 0 else {
            return CoasttySidebarView.defaultWidth
        }

        return available * CoasttySidebarView.maximumWidthWindowFraction
    }

    override func mouseUp(with event: NSEvent) {
        dragStartWidth = nil
        dragStartX = nil
        widthStore.persist()
    }
}
