import AppKit
import Combine
import SwiftUI

/// Wraps Ghostty's terminal window content in a split view with coastty's
/// attention sidebar as one pane (full window height, on the left) and
/// coastty's own tab bar + terminal content as the other — per issue #12
/// (coastty repo).
///
/// Ghostty's native `NSWindowTabGroup` tabs are turned off entirely for
/// these windows (see `TerminalController.windowDidLoad`, which sets
/// `window.tabbingMode = .disallowed`): native tabs are titlebar chrome
/// that always spans the full window width, so there's no way to keep
/// them while also getting a full-height sidebar. coastty now owns tab
/// switching/creation/closing/ordering itself instead — see
/// `CoasttyTab`/`CoasttyTabBarModel` and `TerminalController`'s
/// `coastty*Tab*` methods. This controller only owns the *visual*
/// arrangement (sidebar | tab bar + content); the tab list itself lives on
/// `TerminalController`.
final class CoasttyTerminalSplitViewController: NSSplitViewController {
    private let ghostty: Ghostty.App
    private let coasttySplitView = CoasttySplitView()
    private let sidebarHostingController: NSHostingController<CoasttySidebarView>
    private let tabBarHostingController: NSHostingController<CoasttyTabBarView>
    private let terminalPaneView: CoasttyTerminalPaneView
    private let onNewSpace: () -> Void
    private let onSelectSpace: (UUID) -> Void
    private let onCloseSpace: (UUID) -> Void
    private let onRenameSpace: (UUID) -> Void
    private let onMoveSpace: (Int, Int) -> Void
    private let onSelectAgent: (UUID) -> Void

    /// Kept so its thickness can follow the sidebar's width as it's dragged.
    private var sidebarItem: NSSplitViewItem?
    private var widthObserver: AnyCancellable?
    private let resizeHandle = CoasttySidebarResizeHandleView(widthStore: CoasttySidebarWidthStore.shared)

    /// - Parameters:
    ///   - ghostty: The app instance, threaded down to the sidebar and tab
    ///     bar so their colors track the live configured theme.
    ///   - sidebarModel: The initial data to render in the sidebar.
    ///   - tabBarModel: The tab bar's display data + action hooks, owned
    ///     and kept up to date by `TerminalController`.
    ///   - terminalContent: Ghostty's existing terminal content view
    ///     (a `TerminalViewContainer`), which becomes the tab bar's
    ///     content pane, completely unmodified itself.
    ///   - onNewSpace: Called when the user clicks the Spaces section's
    ///     "+ New" control — creates a whole new Space (issue #12, coastty
    ///     repo, Round 4), not just a new tab in the current one.
    ///   - onSelectSpace: Called with a Space's `id` when the user clicks
    ///     its row in the sidebar, to make it the active Space.
    ///   - onCloseSpace: Called with a Space's `id` when the user closes it
    ///     via its row's close control or right-click menu.
    ///   - onRenameSpace: Called with a Space's `id` when the user picks
    ///     "Rename..." from its row's right-click menu.
    ///   - onMoveSpace: Called with a Space's (fromIndex, toIndex) once a
    ///     drag-to-reorder in the sidebar ends with its index changed.
    init(
        ghostty: Ghostty.App,
        sidebarModel: CoasttySidebarModel,
        tabBarModel: CoasttyTabBarModel,
        terminalContent: NSView,
        onNewSpace: @escaping () -> Void = {},
        onSelectSpace: @escaping (UUID) -> Void = { _ in },
        onCloseSpace: @escaping (UUID) -> Void = { _ in },
        onRenameSpace: @escaping (UUID) -> Void = { _ in },
        onMoveSpace: @escaping (Int, Int) -> Void = { _, _ in },
        onSelectAgent: @escaping (UUID) -> Void = { _ in }
    ) {
        self.ghostty = ghostty
        self.onNewSpace = onNewSpace
        self.onSelectSpace = onSelectSpace
        self.onCloseSpace = onCloseSpace
        self.onRenameSpace = onRenameSpace
        self.onMoveSpace = onMoveSpace
        self.onSelectAgent = onSelectAgent
        self.sidebarHostingController = NSHostingController(
            rootView: CoasttySidebarView(model: sidebarModel, ghostty: ghostty, onNewSpace: onNewSpace, onSelectSpace: onSelectSpace, onSelectAgent: onSelectAgent, onCloseSpace: onCloseSpace, onRenameSpace: onRenameSpace, onMoveSpace: onMoveSpace)
        )
        self.tabBarHostingController = NSHostingController(
            rootView: CoasttyTabBarView(model: tabBarModel, ghostty: ghostty)
        )
        self.terminalPaneView = CoasttyTerminalPaneView(
            tabBar: tabBarHostingController.view,
            terminalContent: terminalContent
        )

        super.init(nibName: nil, bundle: nil)

        coasttySplitView.isVertical = true
        coasttySplitView.dividerStyle = .thin
        // The split view forwards its intrinsic size from this pane, which
        // itself already accounts for the tab bar's height on top of the
        // terminal content's own intrinsic size — see
        // `CoasttyTerminalPaneView.intrinsicContentSize`.
        coasttySplitView.terminalContainer = terminalPaneView
        // Must be set before this controller's view loads — see
        // NSSplitViewController.splitView's documentation.
        self.splitView = coasttySplitView

        // Pinning minimum == maximum thickness makes AppKit hold the
        // sidebar at exactly this width and give all remaining space to the
        // terminal pane. The sidebar is user-resizable, so that width
        // tracks the store rather than a constant — see
        // `observeSidebarWidth`. Left as a hard pin rather than a real
        // min/max range on purpose: with a range, NSSplitViewController
        // re-solves the pane widths from Auto Layout on every layout pass
        // and a dragged width gets discarded, snapping back to an even
        // split. The drag itself lives in
        // `CoasttySidebarResizeHandleView`.
        let sidebarItem = NSSplitViewItem(viewController: sidebarHostingController)
        sidebarItem.minimumThickness = CoasttySidebarWidthStore.shared.width
        sidebarItem.maximumThickness = CoasttySidebarWidthStore.shared.width
        sidebarItem.canCollapse = false
        self.sidebarItem = sidebarItem

        let terminalViewController = NSViewController()
        terminalViewController.view = terminalPaneView
        let terminalItem = NSSplitViewItem(viewController: terminalViewController)
        // Explicitly 1, not unset — issue #12 (coastty repo): a 200pt
        // floor was added during Round 4's "tiny window on first launch"
        // investigation, since removed (now handled independently by a
        // synchronous floor on the window's own initial content size —
        // see `TerminalController.fallbackWindowContentSize`). Leaving
        // minimumThickness unset entirely still didn't let the window
        // shrink as small as stock Ghostty (no split view at all) does —
        // NSSplitViewItem's own fallback computation when this isn't
        // explicitly set apparently doesn't defer to the content view's
        // AutoLayout compression-resistance the way plain AutoLayout
        // resolution would. Setting it explicitly, to the smallest
        // meaningful value, is what actually removes the floor.
        terminalItem.minimumThickness = 1

        // Sidebar first so it lands on the leading (left) side, and spans
        // the split view's full height — the tab bar lives only inside
        // the terminal pane on the right, never above the sidebar.
        addSplitViewItem(sidebarItem)
        addSplitViewItem(terminalItem)

        observeSidebarWidth()
    }

    /// The resize handle is installed here rather than in `init` because
    /// its constraints reference the sidebar pane's view, and
    /// `NSSplitViewController` doesn't put an item's view into the split
    /// view until its own view loads. Constraining two views with no
    /// common ancestor yet throws, which aborted window creation and left
    /// the app running with no window at all.
    override func viewDidLoad() {
        super.viewDidLoad()

        // A plain subview, deliberately not an *arranged* one — NSSplitView
        // lays out only its arranged subviews as panes, so this rides on
        // top of both of them instead of becoming a third pane.
        coasttySplitView.addSubview(resizeHandle)
        // Hit testing walks subviews top-down, and adding a split view item
        // re-orders them, so z-order alone can't be relied on to keep the
        // handle clickable. The split view routes hits to it explicitly.
        coasttySplitView.resizeHandle = resizeHandle
        constrainResizeHandle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Centers the handle on the sidebar panel's trailing edge, so it can
    /// be grabbed from either side of it.
    ///
    /// Not on the boundary between the two panes, which is `panelSideMargin`
    /// further right: the sidebar's canvas is drawn in the terminal's own
    /// background color, so that boundary is invisible and centering there
    /// puts the resize cursor a margin's width off the edge the user sees.
    ///
    /// Constraints rather than a frame set from `viewDidLayout`, so the
    /// handle tracks the sidebar's edge through every layout pass without
    /// this controller having to notice each one.
    private func constrainResizeHandle() {
        resizeHandle.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            resizeHandle.widthAnchor.constraint(equalToConstant: CoasttySidebarResizeHandleView.width),
            resizeHandle.topAnchor.constraint(equalTo: coasttySplitView.topAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: coasttySplitView.bottomAnchor),
            resizeHandle.centerXAnchor.constraint(
                equalTo: sidebarHostingController.view.trailingAnchor,
                constant: -CoasttySidebarView.panelSideMargin
            ),
        ])
    }

    /// Keeps the sidebar pane's thickness on the width the user is
    /// dragging to. `CoasttySidebarResizeHandleView` writes to the shared
    /// store; this is the other half, moving the AppKit pane that hosts
    /// the sidebar. Without it the SwiftUI view would resize inside a pane
    /// that stayed put, and simply be clipped.
    ///
    /// Deliberately not hopped through `DispatchQueue.main`: the drag
    /// events already arrive there, and deferring the pane by a runloop
    /// turn lands it behind the drag it is supposed to be following. The
    /// layout itself is left to AppKit's own pass rather than forced
    /// synchronously here — forcing it re-laid out the terminal surface on
    /// every mouse event instead of once per frame.
    private func observeSidebarWidth() {
        widthObserver = CoasttySidebarWidthStore.shared.$width
            .sink { [weak self] width in
                guard let sidebarItem = self?.sidebarItem else { return }

                sidebarItem.minimumThickness = width
                sidebarItem.maximumThickness = width
            }
    }

    /// Re-renders the sidebar with fresh data — call whenever this
    /// window's coastty tab list (or, once wired, workspace/agent state)
    /// changes.
    func updateSidebarModel(_ model: CoasttySidebarModel) {
        sidebarHostingController.rootView = CoasttySidebarView(model: model, ghostty: ghostty, onNewSpace: onNewSpace, onSelectSpace: onSelectSpace, onSelectAgent: onSelectAgent, onCloseSpace: onCloseSpace, onRenameSpace: onRenameSpace, onMoveSpace: onMoveSpace)
    }
}

/// The terminal pane's own view: coastty's tab bar pinned to the top,
/// Ghostty's existing terminal content filling the rest. Exists so the
/// split view can treat "tab bar + content" as a single pane without the
/// tab bar affecting the sidebar (see `CoasttyTerminalSplitViewController`
/// doc comment).
final class CoasttyTerminalPaneView: NSView {
    private let tabBar: NSView
    private let terminalContent: NSView

    init(tabBar: NSView, terminalContent: NSView) {
        self.tabBar = tabBar
        self.terminalContent = terminalContent
        super.init(frame: .zero)

        addSubview(tabBar)
        addSubview(terminalContent)
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        terminalContent.translatesAutoresizingMaskIntoConstraints = false

        // This view's own intrinsicContentSize below forwards the real
        // terminal size — AutoLayout's default compression-resistance
        // priority (750) treats that as a real floor it resists shrinking
        // below, which NSSplitView's own pane-sizing respects far more
        // strictly than plain NSWindow frame-dragging does (stock
        // Ghostty's content view is the window's contentView directly,
        // with no split view in the chain at all, so this never bit it).
        // Lowering it here is what actually lets the window shrink as
        // small as stock Ghostty allows again.
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            // Sized to `totalHeight`, not `height` alone - `totalHeight`
            // includes the breathing-room gap below the tab row, which
            // `CoasttyTabBarView` draws itself as part of its own
            // background fill (so it stays theme/opacity-aware).
            tabBar.heightAnchor.constraint(equalToConstant: CoasttyTabBarView.totalHeight),

            terminalContent.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            terminalContent.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalContent.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalContent.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Forwards the terminal content's own intrinsic size, plus the tab
    /// bar's fixed height — see `CoasttySplitView.intrinsicContentSize`,
    /// which reads this to keep `window-width`/`window-height` and
    /// "Return to Default Size" working.
    override var intrinsicContentSize: NSSize {
        let terminalSize = terminalContent.intrinsicContentSize
        guard terminalSize.width != NSView.noIntrinsicMetric,
              terminalSize.height != NSView.noIntrinsicMetric else {
            return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }

        return NSSize(width: terminalSize.width, height: terminalSize.height + CoasttyTabBarView.totalHeight)
    }
}
