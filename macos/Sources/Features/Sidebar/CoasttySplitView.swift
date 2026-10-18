import AppKit

/// The root split view for a coastty terminal window: coastty's sidebar
/// (full window height) as one pane, coastty's own tab bar + Ghostty's
/// existing terminal content (`CoasttyTerminalPaneView`) as the other.
///
/// Forwards `intrinsicContentSize` from the terminal pane (plus the
/// sidebar's current width and the divider) so window-sizing logic —
/// `window-width`/`window-height`, "Return to Default Size" — keeps
/// working exactly as it did when the terminal container was the window's
/// content view directly. See `TerminalController.DefaultSize`, which
/// reads `window.contentView.intrinsicContentSize`.
final class CoasttySplitView: NSSplitView {
    /// The terminal pane's view, kept only to read its intrinsic size.
    weak var terminalContainer: NSView?

    /// The sidebar's resize handle, an overlay rather than a pane. Kept so
    /// `hitTest` can hand it clicks that would otherwise land on whichever
    /// pane happens to sit above it — see below.
    weak var resizeHandle: NSView?


    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // This view's own intrinsicContentSize below forwards a real size
        // too — same reasoning as CoasttyTerminalPaneView's own
        // compression-resistance override: without lowering this,
        // AutoLayout's default priority resists shrinking the window
        // below it, well above where stock Ghostty allows.
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// AppKit draws its own divider line between the sidebar and content
    /// panes by default (a dark hairline, especially in dark appearances).
    /// coastty's sidebar is rendered as its own rounded panel(s) with a
    /// margin around it — that AppKit divider just reads as a stray extra
    /// border, not a real interactive resize affordance, so it's hidden
    /// entirely. The sidebar is resizable, but via its own handle in that
    /// margin (`CoasttySidebarResizeHandleView`), not via this divider.
    override var dividerColor: NSColor { .clear }

    /// `dividerColor` alone only makes the divider invisible — AppKit
    /// still reserves its `dividerThickness` (1pt for `.thin`) as a real
    /// gap between the two panes' content. With the color transparent,
    /// that gap shows whatever's behind the window instead of either
    /// pane, which read as a stray 1px fully-transparent seam running the
    /// full height of the window. Zeroing the thickness too removes the
    /// gap itself, not just its color.
    override var dividerThickness: CGFloat { 0 }

    /// Routes clicks on the sidebar's resize handle to it directly. The
    /// handle is an overlay subview, and `NSSplitView` re-orders its
    /// subviews when items are added, so it can end up underneath a pane
    /// and never see a click. Testing it first makes that ordering
    /// irrelevant.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let resizeHandle, resizeHandle.superview === self else {
            return super.hitTest(point)
        }

        // `point` arrives in the superview's coordinate space.
        let local = convert(point, from: superview)
        guard resizeHandle.frame.contains(local) else { return super.hitTest(point) }

        return resizeHandle
    }

    override var intrinsicContentSize: NSSize {
        guard let terminalContainer else {
            return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }

        let terminalSize = terminalContainer.intrinsicContentSize
        guard terminalSize.width != NSView.noIntrinsicMetric,
              terminalSize.height != NSView.noIntrinsicMetric else {
            return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }

        // The sidebar is user-resizable, so this reads the width it's
        // actually at rather than a constant — otherwise "Return to
        // Default Size" and `window-width` would be off by however far the
        // user had dragged it.
        return NSSize(
            width: terminalSize.width + CoasttySidebarWidthStore.shared.width + dividerThickness,
            height: terminalSize.height
        )
    }
}
