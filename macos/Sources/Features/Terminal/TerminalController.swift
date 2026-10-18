import Foundation
import Cocoa
import SwiftUI
import Combine
import GhosttyKit

private extension CoasttyAgentStatus {
    /// This status as it crosses the C API - see `agent_detection.AgentStatus`.
    var cValue: ghostty_agent_status_e {
        switch self {
        case .idle: return GHOSTTY_AGENT_STATUS_IDLE
        case .working: return GHOSTTY_AGENT_STATUS_WORKING
        case .blocked: return GHOSTTY_AGENT_STATUS_BLOCKED
        case .done: return GHOSTTY_AGENT_STATUS_DONE
        case .unknown: return GHOSTTY_AGENT_STATUS_UNKNOWN
        }
    }
}

private extension NSWindow {
    /// Hides the 1pt separator bar AppKit draws under the titlebar. AppKit has no public handle on it, so it is found by its layer name.
    func coasttyHideTitlebarSeparatorBar() {
        guard let frameLayer = contentView?.superview?.layer else { return }
        coasttyHideSeparatorBar(in: frameLayer)
    }

    private func coasttyHideSeparatorBar(in layer: CALayer) {
        if layer.name == "CUIWindowSeparatorBarLayer" { layer.isHidden = true }
        for sublayer in layer.sublayers ?? [] {
            coasttyHideSeparatorBar(in: sublayer)
        }
    }
}

/// A classic, tabbed terminal experience.
class TerminalController: BaseTerminalController {
    override var windowNibName: NSNib.Name? {
        let defaultValue = "Terminal"

        guard let appDelegate = NSApp.delegate as? AppDelegate else { return defaultValue }
        let config = appDelegate.ghostty.config

        // If we have no window decorations, there's no reason to do anything but
        // the default titlebar (because there will be no titlebar).
        if !config.windowDecorations {
            return defaultValue
        }

        let nib = switch config.macosTitlebarStyle {
        case .native: "Terminal"
        case .hidden: "TerminalHiddenTitlebar"
        case .transparent: "TerminalTransparentTitlebar"
        case .tabs:
            // Issue #12 (coastty repo): `.tabs` used to merge AppKit's
            // native tab bar into the titlebar via `TerminalTabsTitlebarTahoe`/
            // `TerminalTabsTitlebarVentura` (see `TitlebarTabsTahoeTerminalWindow`/
            // `TitlebarTabsVenturaTerminalWindow`). Native tabbing is now always
            // disallowed (`window.tabbingMode = .disallowed` in `windowDidLoad`)
            // in favor of coastty's own full-height sidebar + tab bar, so AppKit
            // never gives those windows a tab bar to merge — they'd just show a
            // vestigial, blank titlebar strip above coastty's own UI. Fall back
            // to the plain native titlebar instead; coastty's tab bar lives in
            // the content area regardless of this setting.
            "Terminal"
        }

        return nib
    }

    /// The initial window presentation is deferred by one runloop turn in a few places so
    /// AppKit can settle tab/window state first. Close actions must cancel it to avoid
    /// re-showing a tab that was already closed.
    private var pendingInitialPresentation: DispatchWorkItem?

    /// This window's own id, which layout commands name it by; restored windows keep the one they had.
    let coasttyWindowID: UUID

    /// This is set to false by init if the window managed by this controller should not be restorable.
    /// For example, terminals executing custom scripts are not restorable.
    private var restorable: Bool = true

    /// Whether this window belongs in a saved session snapshot - same
    /// exclusion `restorable` already applies.
    var coasttySessionPersistable: Bool { restorable }

    /// coastty's sidebar split view controller for this window, once
    /// `windowDidLoad` has installed it.
    private var sidebarSplitViewController: CoasttyTerminalSplitViewController?

    /// Set once by `newWindow`, right after this controller is created,
    /// when the new window's spawn directory was inherited from whichever
    /// surface was previously focused app-wide — the outgoing surface's
    /// own already-resolved title, for `windowDidLoad`'s seed-tab creation
    /// to use as its `inheritedTitleHint`. Consumed (set back to nil)
    /// there; nil for any window created another way (e.g. restored from
    /// a saved surface tree), which has no such "previous" surface to
    /// guess from anyway.
    private var pendingInheritedTitleHint: String?

    /// This window's own Spaces — issue #12 (coastty repo), Round 4's
    /// corrected architecture: a coastty window can have multiple Spaces,
    /// each with its own independent tab list, replacing the single flat
    /// tab array this window used to own directly. Always has at least one
    /// entry once `windowDidLoad` has run. The Space at
    /// `coasttyActiveSpaceIndex` is whichever one is currently shown in
    /// this window's tab bar/terminal content — see `coasttyActivateSpace(at:)`.
    ///
    /// Every Space and every tab within it - not just the active one -
    /// is what `UndoState` captures and what `CoasttySessionPersistence`
    /// then writes to disk, so this full array survives both undo/redo
    /// within a session and a full app relaunch.
    private var coasttySpaces: [CoasttySpace] = []

    /// The index into `coasttySpaces` of the Space currently shown in this
    /// window's tab bar/terminal content.
    private var coasttyActiveSpaceIndex: Int = 0

    /// coastty's own tabs *within the active Space* — issue #12 (coastty
    /// repo) architecture note: coastty owns tab switching/creation/
    /// closing/ordering itself, instead of `NSWindowTabGroup` joining
    /// separate `NSWindow`s (see `windowDidLoad`, which sets
    /// `window.tabbingMode = .disallowed`).
    ///
    /// This is a forwarding seam onto `coasttySpaces` (Round 4), not its
    /// own storage: the bulk of this controller's existing per-tab logic
    /// (new/close/goto/move tab, undo/redo, etc.) was all written before a
    /// window could hold more than one Space, and doesn't need to know
    /// Spaces exist at all — it just operates on "whichever Space is
    /// active right now," which is exactly what this property (and
    /// `coasttyActiveTabIndex` below) resolve to. The entry at
    /// `coasttyActiveTabIndex` is the one currently installed as
    /// `self.surfaceTree` — the same property that already drives the
    /// SwiftUI terminal view, so switching tabs is just swapping which
    /// tab's tree is installed there. See `coasttyActivateTab(at:)`.
    private var coasttyTabs: [CoasttyTab] {
        get { coasttySpaces[safe: coasttyActiveSpaceIndex]?.tabs ?? [] }
        set {
            guard coasttySpaces.indices.contains(coasttyActiveSpaceIndex) else { return }
            coasttySpaces[coasttyActiveSpaceIndex].tabs = newValue
        }
    }

    /// The active Space's own active-tab index — see `coasttyTabs` above
    /// for why this forwards onto `coasttySpaces` instead of being its own
    /// storage.
    private var coasttyActiveTabIndex: Int {
        get { coasttySpaces[safe: coasttyActiveSpaceIndex]?.activeTabIndex ?? 0 }
        set {
            guard coasttySpaces.indices.contains(coasttyActiveSpaceIndex) else { return }
            coasttySpaces[coasttyActiveSpaceIndex].activeTabIndex = newValue
        }
    }

    /// The number of coastty tabs this window currently owns — issue #12
    /// (coastty repo), Round 3: `Ghostty.App.gotoTab`/`moveTab` need this to
    /// decide whether goto/move-tab actions are performable now that tabs
    /// are no longer `NSWindowTabGroup` members (`window.tabGroup` is always
    /// nil for coastty windows; see `windowDidLoad`), instead of the
    /// `window.tabGroup?.windows.count` check those call sites used before
    /// coastty owned tabs itself.
    var coasttyTabCount: Int { coasttyTabs.count }

    /// The number of coastty Spaces this window currently owns — mirrors
    /// `coasttyTabCount` above, used by `Ghostty.App.gotoSpace` for the
    /// same reason.
    var coasttySpaceCount: Int { coasttySpaces.count }

    /// The display data + action hooks for coastty's own tab bar. Kept up
    /// to date by `coasttyRefreshUI()` whenever `coasttyTabs` changes.
    private let coasttyTabBarModel = CoasttyTabBarModel()

    /// The configuration derived from the Ghostty config so we don't need to rely on references.
    private(set) var derivedConfig: DerivedConfig

    /// The notification cancellable for focused surface property changes.
    private var surfaceAppearanceCancellables: Set<AnyCancellable> = []

    /// Keeps coastty's own tab bar/sidebar rows in sync with the focused
    /// surface's title/pwd as they change live, refreshing the UI the
    /// moment the shell reports something real rather than waiting for
    /// the next tab/space lifecycle event.
    private var coasttyTabRefreshCancellables: Set<AnyCancellable> = []

    /// Per-pane "has the user seen this agent's last completion"
    /// bookkeeping — mirrors herdr's `PaneState.seen`
    /// (`src/pane/state.rs`) and its transition rules in
    /// `apply_pane_state_change` (`src/app/actions.rs`). A pane not yet in
    /// this dictionary defaults to seen (`true`), matching `PaneState::new`.
    /// Never proactively cleaned up when a pane closes — same
    /// harmless-once-unreferenced reasoning as `coasttyTabRefreshCancellables`
    /// above.
    private var coasttyPaneSeen: [UUID: Bool] = [:]

    /// The panes this window last told the daemon the user is looking at.
    private var coasttyViewedSurfaceIDs: Set<UUID> = []

    /// The last agent state observed for each pane, kept only to detect a
    /// genuine completion transition (Working/Blocked -> Idle) the next
    /// time it changes — see `coasttyHandleAgentStateChange`.
    private var coasttyPanePreviousAgentState: [UUID: Ghostty.Action.CoasttyAgentStateChange.State] = [:]

    init(_ ghostty: Ghostty.App,
         withBaseConfig base: Ghostty.SurfaceConfiguration? = nil,
         withSurfaceTree tree: SplitTree<Ghostty.SurfaceView>? = nil,
         withSpaces spaces: [CoasttySpace]? = nil,
         activeSpaceIndex: Int = 0,
         windowID: UUID? = nil,
         parent: NSWindow? = nil
    ) {
        self.coasttyWindowID = windowID ?? UUID()

        // The window we manage is not restorable if we've specified a command
        // to execute. We do this because the restored window is meaningless at the
        // time of writing this: it'd just restore to a shell in the same directory
        // as the script. We may want to revisit this behavior when we have scrollback
        // restoration.
        self.restorable = (base?.command ?? "") == ""

        // Setup our initial derived config based on the current app config
        self.derivedConfig = DerivedConfig(ghostty.config)

        // Before `super.init`, which is already far enough on to load the
        // window: `windowDidLoad` seeds a Space of its own when it finds none,
        // and it runs inside this initializer rather than at the `showWindow` a
        // restore reaches later. Assigned any later, the seeded Space is left
        // behind in the model with the restored one having taken its pane.
        if let spaces, !spaces.isEmpty {
            self.coasttySpaces = spaces
            self.coasttyActiveSpaceIndex = spaces.indices.contains(activeSpaceIndex) ? activeSpaceIndex : 0
        }

        super.init(ghostty, baseConfig: base, surfaceTree: tree)

        // Setup our notifications for behaviors
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(onToggleFullscreen),
            name: Ghostty.Notification.ghosttyToggleFullscreen,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onMoveTab),
            name: .ghosttyMoveTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onMoveSpace),
            name: .ghosttyMoveSpace,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onGotoTab),
            name: Ghostty.Notification.ghosttyGotoTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onGotoSpace),
            name: Ghostty.Notification.ghosttyGotoSpace,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onNewSpace),
            name: Ghostty.Notification.ghosttyNewSpace,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onGotoUrgentAgent),
            name: Ghostty.Notification.ghosttyGotoUrgentAgent,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onPreviousAgent),
            name: Ghostty.Notification.ghosttyPreviousAgent,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onNextAgent),
            name: Ghostty.Notification.ghosttyNextAgent,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseTab),
            name: .ghosttyCloseTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseOtherTabs),
            name: .ghosttyCloseOtherTabs,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseTabsOnTheRight),
            name: .ghosttyCloseTabsOnTheRight,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseSpace),
            name: .ghosttyCloseSpace,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseOtherSpaces),
            name: .ghosttyCloseOtherSpaces,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseSpacesOnTheRight),
            name: .ghosttyCloseSpacesOnTheRight,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onResetWindowSize),
            name: .ghosttyResetWindowSize,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(ghosttyConfigDidChange(_:)),
            name: .ghosttyConfigDidChange,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(onCloseWindow),
            name: .ghosttyCloseWindow,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    deinit {
        // Remove all of our notificationcenter subscriptions
        let center = NotificationCenter.default
        center.removeObserver(self)
    }

    private func cancelPendingInitialPresentation() {
        pendingInitialPresentation?.cancel()
        pendingInitialPresentation = nil
    }

    private func scheduleInitialPresentation(_ block: @escaping () -> Void) {
        cancelPendingInitialPresentation()

        var scheduledWorkItem: DispatchWorkItem?
        scheduledWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            defer { self.pendingInitialPresentation = nil }
            guard pendingInitialPresentation?.isCancelled == false else { return }
            block()
        }

        let workItem = scheduledWorkItem!
        pendingInitialPresentation = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    // MARK: Base Controller Overrides

    override func surfaceTreeDidChange(from: SplitTree<Ghostty.SurfaceView>, to: SplitTree<Ghostty.SurfaceView>) {
        super.surfaceTreeDidChange(from: from, to: to)

        // Whenever our surface tree changes in any way (new split, close split, etc.)
        // we want to invalidate our state.
        invalidateRestorableState()

        // A split made or closed changes which panes a tab holds, which is the
        // daemon's to know. Credited to the tab whose tree this is, not to
        // whichever index happens to be active - see `coasttyShowingTabID`.
        coasttyReportPaneMembershipIfNeeded(tree: to)

        // Update our zoom state
        if let window = window as? TerminalWindow {
            window.surfaceIsZoomed = to.zoomed != nil
        }

        // If our surface tree is now nil then we close our window.
        if to.isEmpty {
            self.window?.close()
        }
    }

    override func replaceSurfaceTree(
        _ newTree: SplitTree<Ghostty.SurfaceView>,
        moveFocusTo newView: Ghostty.SurfaceView? = nil,
        moveFocusFrom oldView: Ghostty.SurfaceView? = nil,
        undoAction: String? = nil
    ) {
        // An emptied tree closes the tab outright, so the tab close path (and the panes it ends) runs rather than leaving an empty tab behind.
        if newTree.isEmpty {
            closeTabImmediately()
            return
        }

        super.replaceSurfaceTree(newTree, moveFocusTo: newView, moveFocusFrom: oldView, undoAction: undoAction)
    }

    /// Where a `replaceSurfaceTree` undo/redo should apply - captured once per edit so it stays correct across Space/tab switches, in either direction.
    private struct SurfaceTreeLocation {
        let spaceID: UUID
        let tabID: UUID
    }

    override func captureSurfaceTreeUndoContext() -> Any? {
        guard let spaceID = coasttySpaces[safe: coasttyActiveSpaceIndex]?.id,
              let tabID = coasttyTabs[safe: coasttyActiveTabIndex]?.id else { return nil }
        return SurfaceTreeLocation(spaceID: spaceID, tabID: tabID)
    }

    /// Installs `tree` into the Space/tab `context` identifies, live only if it's the active one; returns false if either no longer exists.
    @discardableResult
    override func installSurfaceTree(_ tree: SplitTree<Ghostty.SurfaceView>, context: Any?) -> Bool {
        guard let location = context as? SurfaceTreeLocation else { return false }
        guard let spaceIndex = coasttySpaces.firstIndex(where: { $0.id == location.spaceID }) else { return false }
        guard let tabIndex = coasttySpaces[spaceIndex].tabs.firstIndex(where: { $0.id == location.tabID }) else { return false }

        guard spaceIndex == coasttyActiveSpaceIndex, tabIndex == coasttyActiveTabIndex else {
            coasttySpaces[spaceIndex].tabs[tabIndex].tree = tree
            CoasttySessionSaveScheduler.shared.markDirty()
            CoasttyModelSync.send(CoasttyModelSync.Operation.operationsPlacingPanes(of: tree, inTab: location.tabID))
            return true
        }

        surfaceTree = tree
        return true
    }

    // MARK: Terminal Creation

    /// Returns all the available terminal controllers present in the app currently.
    /// Excludes windows mid-close - `close()` doesn't synchronously drop them from
    /// `NSApplication.shared.windows`, but `coasttySpaces` is already cleared by then.
    static var all: [TerminalController] {
        return NSApplication.shared.windows.compactMap {
            guard let controller = $0.windowController as? TerminalController else { return nil }
            guard !controller.coasttySpaces.isEmpty else { return nil }
            return controller
        }
    }

    // Keep track of the last point that our window was launched at so that new
    // windows "cascade" over each other and don't just launch directly on top
    // of each other.
    private static var lastCascadePoint = NSPoint(x: 0, y: 0)

    private static func applyCascade(to window: NSWindow, hasFixedPos: Bool) {
        if hasFixedPos { return }

        if all.count > 1 {
            lastCascadePoint = window.cascadeTopLeft(from: lastCascadePoint)
        } else {
            // We assume the window frame is already correct at this point,
            // so we pass .zero to let cascade use the current frame position.
            lastCascadePoint = window.cascadeTopLeft(from: .zero)
        }
    }

    // The preferred parent terminal controller.
    static var preferredParent: TerminalController? {
        let usableLastMain = lastMain.flatMap { $0.coasttySpaces.isEmpty ? nil : $0 }
        return all.first {
            $0.window?.isMainWindow ?? false
        } ?? usableLastMain ?? all.last
    }

    // The last controller to be main. We use this when paired with "preferredParent"
    // to find the preferred window to attach new tabs, perform actions, etc. We
    // always prefer the main window but if there isn't any (because we're triggered
    // by something like an App Intent) then we prefer the most previous main.
    static private(set) weak var lastMain: TerminalController?

    /// Replicates Ghostty's own `window-inherit-working-directory`
    /// behavior (`apprt/surface.zig`'s `newConfig`/
    /// `shouldInheritWorkingDirectory(context: .window, ...)`) for a
    /// brand-new window, app-wide rather than scoped to one window's own
    /// tabs. The real mechanism inherits from `app.focusedSurface()`;
    /// `preferredParent` is the closest Swift-side equivalent.
    private static func inheritedWorkingDirectoryConfig(
        _ ghostty: Ghostty.App,
        baseConfig: Ghostty.SurfaceConfiguration?,
        previouslyFocused: Ghostty.SurfaceView?
    ) -> Ghostty.SurfaceConfiguration? {
        if let baseConfig, baseConfig.workingDirectory != nil {
            return baseConfig
        }
        guard ghostty.config.windowInheritWorkingDirectory,
              let pwd = previouslyFocused?.pwd, !pwd.isEmpty else {
            return baseConfig
        }

        var config = baseConfig ?? Ghostty.SurfaceConfiguration()
        config.workingDirectory = pwd
        return config
    }

    /// The "new window" action.
    static func newWindow(
        _ ghostty: Ghostty.App,
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration? = nil,
        withParent explicitParent: NSWindow? = nil
    ) -> TerminalController {
        // Snapshotted once, before `c` exists, so `preferredParent` can't
        // possibly resolve to the window we're in the middle of creating -
        // this is "whoever was focused right before this call", matching
        // the real core mechanism's own `app.focusedSurface()` semantics.
        let previouslyFocused = preferredParent?.focusedSurface
        let effectiveConfig = inheritedWorkingDirectoryConfig(ghostty, baseConfig: baseConfig, previouslyFocused: previouslyFocused)
        let c = TerminalController.init(ghostty, withBaseConfig: effectiveConfig)
        // An immediate guess so this window's initial tab doesn't sit on
        // "Terminal" while its shell starts up. Not gated on
        // `effectiveConfig?.workingDirectory` - pwd (OSC 7) and title
        // (OSC 0/1/2) are separate sequences a shell can send
        // independently, so a live title is usable here even when pwd
        // itself never resolves.
        // "👻" isn't a real title - see CoasttyTab.title's own doc comment
        // on the same exclusion - so it's no better a hint than having
        // none at all.
        let liveTitle = previouslyFocused?.title ?? ""
        if !liveTitle.isEmpty, liveTitle != "👻" {
            c.pendingInheritedTitleHint = liveTitle
        } else if let workingDirectory = effectiveConfig?.workingDirectory {
            c.pendingInheritedTitleHint = Self.abbreviatingHome(in: workingDirectory)
        }

        // Get our parent. Our parent is the one explicitly given to us,
        // otherwise the focused terminal, otherwise an arbitrary one.
        let parent: NSWindow? = explicitParent ?? preferredParent?.window
        if let parentController = parent?.windowController as? TerminalController {
            c.isBackgroundOpaque = parentController.isBackgroundOpaque
        }

        if let parent, parent.styleMask.contains(.fullScreen) {
            // If our previous window was fullscreen then we want our new window to
            // be fullscreen. This behavior actually doesn't match the native tabbing
            // behavior of macOS apps where new windows create tabs when in native
            // fullscreen but this is how we've always done it. This matches iTerm2
            // behavior.
            c.toggleFullscreen(mode: .native)
        } else if let fullscreenMode = ghostty.config.windowFullscreen {
            switch fullscreenMode {
            case .native:
                // Native has to be done immediately so that our stylemask contains
                // fullscreen for the logic later in this method.
                c.toggleFullscreen(mode: .native)

            case .nonNative, .nonNativeVisibleMenu, .nonNativePaddedNotch:
                // If we're non-native then we have to do it on a later loop
                // so that the content view is setup.
                DispatchQueue.main.async {
                    c.toggleFullscreen(mode: fullscreenMode)
                }
            }
        }

        // We're dispatching this async because otherwise the lastCascadePoint doesn't
        // take effect. Our best theory is there is some next-event-loop-tick logic
        // that Cocoa is doing that we need to be after.
        c.scheduleInitialPresentation {
            c.showWindow(self)

            // Only cascade if we aren't fullscreen.
            if let window = c.window {
                if !window.styleMask.contains(.fullScreen) {
                    let hasFixedPos = c.derivedConfig.windowPositionX != nil && c.derivedConfig.windowPositionY != nil
                    Self.applyCascade(to: window, hasFixedPos: hasFixedPos)
                }
            }

            // All new_window actions force our app to be active, so that the new
            // window is focused and visible.
            NSApp.activate(ignoringOtherApps: true)
        }

        // Setup our undo
        if let undoManager = c.undoManager {
            undoManager.setActionName("New Window")
            undoManager.registerUndo(
                withTarget: c,
                expiresAfter: c.undoExpiration
            ) { target in
                // Close the window when undoing
                undoManager.disableUndoRegistration {
                    target.closeWindow(nil)
                }

                // Register redo action
                undoManager.registerUndo(
                    withTarget: ghostty,
                    expiresAfter: target.undoExpiration
                ) { ghostty in
                    _ = TerminalController.newWindow(
                        ghostty,
                        withBaseConfig: baseConfig,
                        withParent: explicitParent)
                }
            }
        }

        return c
    }

    /// Create a new window with an existing split tree.
    /// The window will be sized to match the tree's current view bounds if available.
    /// - Parameters:
    ///   - ghostty: The Ghostty app instance.
    ///   - tree: The split tree to use for the new window.
    ///   - position: Optional screen position (top-left corner) for the new window.
    ///               If nil, the window will cascade from the last cascade point.
    static func newWindow(
        _ ghostty: Ghostty.App,
        tree: SplitTree<Ghostty.SurfaceView>,
        position: NSPoint? = nil,
        confirmUndo: Bool = true,
        inheritBackgroundOpacity: Bool? = nil
    ) -> TerminalController {
        // Calculate the target frame based on the tree's view bounds
        // before moving into the new window
        let treeSize: CGSize? = tree.root?.viewBounds()

        let c = TerminalController.init(ghostty, withSurfaceTree: tree)
        if let inheritBackgroundOpacity {
            c.isBackgroundOpaque = inheritBackgroundOpacity
        }

        c.scheduleInitialPresentation {
            c.showWindow(self)
            if let window = c.window {
                // If we have a tree size, resize the window's content to match
                if let treeSize, treeSize.width > 0, treeSize.height > 0 {
                    window.setContentSize(treeSize)
                    window.constrainToScreen()
                }

                if !window.styleMask.contains(.fullScreen) {
                    if let position {
                        window.setFrameTopLeftPoint(position)
                        window.constrainToScreen()
                    } else {
                        let hasFixedPos = c.derivedConfig.windowPositionX != nil && c.derivedConfig.windowPositionY != nil
                        Self.applyCascade(to: window, hasFixedPos: hasFixedPos)
                    }
                }
            }
        }

        // Setup our undo
        if let undoManager = c.undoManager {
            undoManager.setActionName("New Window")
            undoManager.registerUndo(
                withTarget: c,
                expiresAfter: c.undoExpiration
            ) { target in
                undoManager.disableUndoRegistration {
                    if confirmUndo {
                        target.closeWindow(nil)
                    } else {
                        target.closeWindowImmediately()
                    }
                }

                undoManager.registerUndo(
                    withTarget: ghostty,
                    expiresAfter: target.undoExpiration
                ) { ghostty in
                    _ = TerminalController.newWindow(
                        ghostty,
                        tree: tree,
                        inheritBackgroundOpacity: inheritBackgroundOpacity
                    )
                }
            }
        }

        return c
    }

    /// The "new tab" action. Per issue #12's architecture note (coastty
    /// repo), a tab is no longer a separate `NSWindow` joined via
    /// `NSWindowTabGroup` — this just appends a new `CoasttyTab` to the
    /// parent window's own `TerminalController` and returns that same
    /// controller (there is exactly one controller per window now, tabs
    /// or not).
    ///
    /// If `parent` isn't a coastty-owned terminal window (or is nil), we
    /// have nothing to append a tab to, so we create a new window instead
    /// — matching the previous fallback behavior.
    static func newTab(
        _ ghostty: Ghostty.App,
        from parent: NSWindow? = nil,
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration? = nil
    ) -> TerminalController? {
        guard let parent,
              let parentController = parent.windowController as? TerminalController else {
            return newWindow(ghostty, withBaseConfig: baseConfig, withParent: parent)
        }

        // If the parent is miniaturized, then macOS exhibits really strange behaviors
        // so we have to bring it back out.
        if parent.isMiniaturized { parent.deminiaturize(self) }

        parentController.coasttyNewTab(baseConfig: baseConfig)
        parentController.showWindowSafely(self)
        NSApp.activate(ignoringOtherApps: true)

        return parentController
    }

    // MARK: - Methods

    @objc private func ghosttyConfigDidChange(_ notification: Notification) {
        // Get our managed configuration object out
        guard let config = notification.userInfo?[
            Notification.Name.GhosttyConfigChangeKey
        ] as? Ghostty.Config else { return }

        // If this is an app-level config update then we update some things.
        if notification.object == nil {
            // Update our derived config
            self.derivedConfig = DerivedConfig(config)

            // If we have no surfaces in our window (is that possible?) then we update
            // our window appearance based on the root config. If we have surfaces, we
            // don't call this because focused surface changes will trigger appearance updates.
            if surfaceTree.isEmpty {
                syncAppearance(.init(config))
            }

            return
        }
        /// Surface-level config will be updated in
        /// ``Ghostty/Ghostty/SurfaceView/derivedConfig`` then
        /// ``TerminalController/focusedSurfaceDidChange(to:)``
    }

    /// Refreshes coastty's own UI — the sidebar and tab bar — from the
    /// current `coasttyTabs`/`coasttyActiveTabIndex`. Called whenever the
    /// tab list changes (create/close/reorder/switch) and when the key
    /// window changes.
    func relabelTabs() {
        coasttyRefreshUI()
    }

    // MARK: coastty Tabs

    /// Creates a new coastty-owned tab in this window and activates it —
    /// issue #12 (coastty repo): "coastty now owns tab switching/
    /// creation/closing/ordering itself", so this appends to our own
    /// `coasttyTabs` instead of creating a new `NSWindow` joined via
    /// `NSWindowTabGroup`. Unlike the old native-tab path, this works
    /// fine even in non-native fullscreen, since it never touches
    /// `NSWindowTabGroup`'s fullscreen tab stack.
    @discardableResult
    func coasttyNewTab(baseConfig: Ghostty.SurfaceConfiguration? = nil) -> CoasttyTab? {
        guard let ghostty_app = ghostty.app else { return nil }

        let effectiveConfig = coasttyInheritedWorkingDirectoryConfig(baseConfig)
        let newSurface = Ghostty.SurfaceView(ghostty_app, baseConfig: effectiveConfig)
        var newTab = CoasttyTab(tree: .init(view: newSurface), focusedSurfaceID: newSurface.id)
        // See coasttyInheritedWorkingDirectoryConfig's doc comment - the
        // outgoing tab's own title is already correctly formatted for the
        // same directory this new tab is (almost certainly) starting in,
        // so it's an accurate immediate guess, not just a placeholder.
        if effectiveConfig?.workingDirectory != nil, coasttyTabs.indices.contains(coasttyActiveTabIndex) {
            newTab.inheritedTitleHint = coasttyTabs[coasttyActiveTabIndex].title
        }
        coasttyObserveSurfaceIfNeeded(newSurface)

        coasttySnapshotActiveTab()
        coasttyTabs.append(newTab)
        if let space = coasttySpaces[safe: coasttyActiveSpaceIndex] {
            CoasttyModelSync.send(.tabNew(spaceID: space.id, tabID: newTab.id, name: newTab.titleOverride ?? ""))
        }
        coasttyActivateTab(at: coasttyTabs.count - 1)
        CoasttySessionSaveScheduler.shared.markDirty()

        if let undoManager {
            undoManager.setActionName("New Tab")
            undoManager.registerUndo(withTarget: self, expiresAfter: undoExpiration) { target in
                if let idx = target.coasttyTabs.firstIndex(where: { $0.id == newTab.id }) {
                    undoManager.disableUndoRegistration {
                        target.coasttyCloseTab(at: idx, withConfirmation: false)
                    }
                }

                undoManager.registerUndo(withTarget: target, expiresAfter: target.undoExpiration) { target in
                    target.coasttyNewTab(baseConfig: baseConfig)
                }
            }
        }

        return newTab
    }

    /// Adds the tab a layout command asked for at the end of its Space, leaving focus where it is unless the request asks for it.
    private func coasttyAddRequestedTab(_ request: CoasttyLayoutRequest.NewTab) {
        // Without a running Ghostty app there is no surface to start the shell in.
        guard let ghostty_app = ghostty.app else { return }
        // The Space may have closed between the caller finding this window and now.
        guard let spaceIndex = coasttySpaces.firstIndex(where: { $0.id == request.spaceID }) else { return }

        var config = Ghostty.SurfaceConfiguration()

        config.workingDirectory = request.directory

        let newSurface = Ghostty.SurfaceView(ghostty_app, baseConfig: config)
        coasttyObserveSurfaceIfNeeded(newSurface)

        var newTab = CoasttyTab(id: request.tabID, tree: .init(view: newSurface), focusedSurfaceID: newSurface.id)

        if !request.name.isEmpty {
            newTab.titleOverride = request.name
        }

        coasttySpaces[spaceIndex].tabs.append(newTab)
        // The pane is placed now rather than when the tab is first shown, so a tab nobody has looked at yet still holds its pane.
        CoasttyModelSync.send(
            [.tabNew(spaceID: request.spaceID, tabID: newTab.id, name: request.name)]
                + CoasttyModelSync.Operation.operationsPlacingPanes(of: newTab.tree, inTab: newTab.id))
        CoasttySessionSaveScheduler.shared.markDirty()

        guard request.focus else {
            coasttyRefreshUI()
            return
        }
        coasttyActivateSpace(at: spaceIndex)
        coasttyActivateTab(at: coasttySpaces[spaceIndex].tabs.count - 1)
    }

    /// Where the tab with this id sits in this window, if it does.
    private func coasttyLocateTab(_ id: UUID) -> (space: Int, tab: Int)? {
        for (spaceIndex, space) in coasttySpaces.enumerated() {
            guard let tabIndex = space.tabs.firstIndex(where: { $0.id == id }) else { continue }
            return (spaceIndex, tabIndex)
        }
        return nil
    }

    /// Takes a tab out of the Space at `spaceIndex`, ending its processes and telling the daemon it closed.
    private func coasttyRemoveTab(inSpaceAt spaceIndex: Int, at index: Int) {
        let closedTab = coasttySpaces[spaceIndex].tabs.remove(at: index)
        CoasttyPaneLifecycle.kill(CoasttyPaneLifecycle.hostIDs(of: closedTab.closingPanes))
        CoasttyModelSync.send(.tabClose(id: closedTab.id))
    }

    /// Stores a tab's own name, in any Space, and reports it to the tab bar, the session save and the daemon.
    private func coasttySetTitleOverride(_ override: String?, spaceIndex: Int, tabIndex: Int) {
        coasttySpaces[spaceIndex].tabs[tabIndex].titleOverride = override
        coasttyRefreshUI()
        CoasttySessionSaveScheduler.shared.markDirty()
        CoasttyModelSync.send(.tabRename(
            id: coasttySpaces[spaceIndex].tabs[tabIndex].id,
            name: override ?? ""))
    }

    /// Closes a tab in a Space this window isn't showing, and the Space with it when that was its last tab.
    private func coasttyCloseBackgroundTab(spaceIndex: Int, tabIndex: Int) {
        // A Space that isn't showing is never the window's last, so closing it leaves the window open.
        guard coasttySpaces[spaceIndex].tabs.count > 1 else {
            coasttyCloseSpaceImmediately(at: spaceIndex)
            return
        }

        coasttyRemoveTab(inSpaceAt: spaceIndex, at: tabIndex)

        // The Space keeps its remembered tab, or the one that slid into a closed remembered slot.
        var activeIndex = coasttySpaces[spaceIndex].activeTabIndex
        if tabIndex < activeIndex {
            activeIndex -= 1
        }
        coasttySpaces[spaceIndex].activeTabIndex = min(activeIndex, coasttySpaces[spaceIndex].tabs.count - 1)

        coasttyRefreshUI()
        CoasttySessionSaveScheduler.shared.markDirty()
    }

    /// Closes the tab a layout command asked to close without prompting, since the daemon already made the running check.
    private func coasttyCloseRequestedTab(_ id: UUID) {
        // The tab may have closed between the caller finding this window and now.
        guard let location = coasttyLocateTab(id) else { return }

        // A hidden Space has no installed tree to swap or window to close, so it skips the showing-tab bookkeeping.
        guard location.space == coasttyActiveSpaceIndex else {
            coasttyCloseBackgroundTab(spaceIndex: location.space, tabIndex: location.tab)
            return
        }
        coasttyCloseTabImmediately(at: location.tab)
    }

    /// Renames the tab a layout command named; an empty name clears it.
    private func coasttyRenameRequestedTab(_ id: UUID, name: String) {
        // The tab may have closed between the caller finding this window and now.
        guard let location = coasttyLocateTab(id) else { return }

        let override = name.isEmpty ? nil : name

        // The showing tab's name lives in the window's own titleOverride, which reports itself.
        if location.space == coasttyActiveSpaceIndex && location.tab == coasttyActiveTabIndex {
            titleOverride = override
            titleOverrideDidChange()
            return
        }

        coasttySetTitleOverride(override, spaceIndex: location.space, tabIndex: location.tab)
    }

    /// Moves the tab a layout command named to `index` within its own Space.
    private func coasttyMoveRequestedTab(_ id: UUID, to index: Int) {
        // The tab may have closed between the caller finding this window and now.
        guard let location = coasttyLocateTab(id) else { return }
        coasttyMoveTab(inSpaceAt: location.space, fromIndex: location.tab, toIndex: index)
    }

    /// Adds the Space a layout command asked for at the end of this window's Spaces, leaving focus where it is unless the request asks for it.
    private func coasttyAddRequestedSpace(_ request: CoasttyLayoutRequest.NewSpace) {
        // Without a running Ghostty app there is no surface to start the shell in.
        guard let ghostty_app = ghostty.app else { return }

        var config = Ghostty.SurfaceConfiguration()

        config.workingDirectory = request.directory

        let newSurface = Ghostty.SurfaceView(ghostty_app, baseConfig: config)
        coasttyObserveSurfaceIfNeeded(newSurface)

        let newTab = CoasttyTab(id: request.tabID, tree: .init(view: newSurface), focusedSurfaceID: newSurface.id)
        let newSpace = CoasttySpace(
            id: request.spaceID,
            tabs: [newTab],
            nameOverride: request.name.isEmpty ? nil : request.name,
            initialFolderName: Self.folderDisplayName(for: request.directory))

        coasttySpaces.append(newSpace)
        // The name as asked, so an unnamed Space takes the daemon's default; the pane is placed now, as for a requested tab.
        CoasttyModelSync.send(
            [
                .spaceNew(id: newSpace.id, name: request.name),
                .tabNew(spaceID: newSpace.id, tabID: newTab.id, name: ""),
            ] + CoasttyModelSync.Operation.operationsPlacingPanes(of: newTab.tree, inTab: newTab.id))
        CoasttySessionSaveScheduler.shared.markDirty()

        guard request.focus else {
            coasttyRefreshUI()
            return
        }
        coasttyActivateSpace(at: coasttySpaces.count - 1)
    }

    /// Closes the Space a layout command asked to close without prompting, since the daemon already made the running check.
    private func coasttyCloseRequestedSpace(_ id: UUID) {
        // The Space may have closed between the caller finding this window and now.
        guard let index = coasttySpaces.firstIndex(where: { $0.id == id }) else { return }

        // The showing tab's live tree only reaches its Space on a snapshot, and its panes have to be among those the close ends.
        coasttySnapshotActiveTab()
        coasttyCloseSpaceImmediately(at: index)
    }

    /// Renames the Space a layout command named; an empty name clears it.
    private func coasttyRenameRequestedSpace(_ id: UUID, name: String) {
        // The Space may have closed between the caller finding this window and now.
        guard let index = coasttySpaces.firstIndex(where: { $0.id == id }) else { return }

        coasttySpaces[index].nameOverride = name.isEmpty ? nil : name
        coasttyRefreshUI()
        CoasttySessionSaveScheduler.shared.markDirty()
        // The name as asked, so a cleared name reaches the daemon empty rather than as the folder default.
        CoasttyModelSync.send(.spaceRename(id: id, name: name))
    }

    /// Moves the Space a layout command named among this window's Spaces, and to the asked position among the daemon's visible Spaces.
    private func coasttyMoveRequestedSpace(_ request: CoasttyLayoutRequest.MoveSpace) {
        // The Space may have closed between the caller finding this window and now.
        guard let fromIndex = coasttySpaces.firstIndex(where: { $0.id == request.id }) else { return }

        // A window shows only its own Spaces, so the Space lands after those of them the daemon says precede it.
        let toIndex = coasttySpaces.filter { $0.id != request.id && request.after.contains($0.id) }.count
        coasttyReorderSpaces(fromIndex: fromIndex, toIndex: toIndex)
        CoasttyModelSync.send(.spaceMove(id: request.id, to: request.index))
    }

    /// Where a Space moving within or into this window lands: right after the last of this window's other Spaces in `anchors`, else first.
    private func coasttyLandingIndex(after anchors: [UUID], moving id: UUID) -> Int {
        let others = coasttySpaces.filter { $0.id != id }
        guard let last = others.lastIndex(where: { anchors.contains($0.id) }) else { return 0 }
        return last + 1
    }

    /// Takes the Space a layout command moved to this window from the window holding it, landing it after the Spaces in `after` without ending anything in it.
    private func coasttyTakeRequestedSpace(_ request: CoasttyLayoutRequest.MoveSpace, from holder: TerminalController) {
        // Already here, it only changes place among this window's Spaces.
        guard holder !== self else {
            guard let fromIndex = coasttySpaces.firstIndex(where: { $0.id == request.id }) else { return }
            coasttyReorderSpaces(fromIndex: fromIndex, toIndex: coasttyLandingIndex(after: request.after, moving: request.id))
            CoasttyModelSync.send(.spaceMove(id: request.id, to: request.index))
            return
        }

        guard let space = holder.coasttyReleaseSpace(request.id) else { return }

        coasttySnapshotActiveTab()
        let index = coasttyLandingIndex(after: request.after, moving: request.id)
        coasttySpaces.insert(space, at: index)
        // The showing Space keeps showing when one lands before it.
        if index <= coasttyActiveSpaceIndex { coasttyActiveSpaceIndex += 1 }

        coasttyRefreshUI()
        CoasttySessionSaveScheduler.shared.markDirty()
        CoasttyModelSync.send(.spaceMove(id: request.id, to: request.index))
    }

    /// Takes the Space with this id out of this window for another window to show, ending nothing in it; a window left with no Space closes.
    private func coasttyReleaseSpace(_ id: UUID) -> CoasttySpace? {
        guard let index = coasttySpaces.firstIndex(where: { $0.id == id }) else { return nil }

        // The showing tab's live tree only reaches its Space on a snapshot, and it travels with the Space.
        coasttySnapshotActiveTab()
        let space = coasttySpaces.remove(at: index)

        guard coasttySpaces.isEmpty else {
            coasttyReactivateAfterRemovingSpace(at: index)
            return space
        }

        // The Space and its panes live on in the other window, so nothing is ended or reported closed.
        cancelPendingInitialPresentation()
        surfaceTree = .init()
        window?.close()
        return space
    }

    /// Where a pane sits in this window: its view, its Space and tab, and whether that tab is the one showing.
    private struct CoasttyPaneLocation {
        let view: Ghostty.SurfaceView
        let space: Int
        let tab: Int
        let showing: Bool
    }

    /// Where the pane with this daemon id sits in this window, if it does.
    private func coasttyLocatePane(_ hostID: String) -> CoasttyPaneLocation? {
        // The showing tab's live tree is newer than its stored copy, so it is searched instead of it.
        if let showingID = coasttyShowingTabID,
           let view = surfaceTree.first(where: { $0.hostPaneID == hostID }),
           let location = coasttyLocateTab(showingID) {
            return .init(view: view, space: location.space, tab: location.tab, showing: true)
        }

        for (spaceIndex, space) in coasttySpaces.enumerated() {
            for (tabIndex, tab) in space.tabs.enumerated() {
                // Already searched above, in its live tree.
                if tab.id == coasttyShowingTabID { continue }
                guard let view = tab.tree.first(where: { $0.hostPaneID == hostID }) else { continue }
                return .init(view: view, space: spaceIndex, tab: tabIndex, showing: false)
            }
        }
        return nil
    }

    /// Splits the pane a layout command named, starting the user's shell beside it and leaving focus where it is unless the request asks for it.
    private func coasttySplitRequestedPane(_ request: CoasttyLayoutRequest.SplitPane) {
        // Without a running Ghostty app there is no surface to start the shell in.
        guard let ghostty_app = ghostty.app else { return }
        // The pane may have closed between the caller finding this window and now.
        guard let location = coasttyLocatePane(request.paneID) else { return }

        // Checked before a surface exists, so a split that can't happen never creates a pane only to drop it.
        let tree = location.showing ? surfaceTree : coasttySpaces[location.space].tabs[location.tab].tree
        guard tree.contains(location.view) else {
            Ghostty.logger.warning("split request: pane \(request.paneID, privacy: .public) is not in its tab's tree")
            return
        }

        var config = Ghostty.SurfaceConfiguration()

        config.workingDirectory = request.directory

        // The daemon's id for the new pane is derived from this surface's own id, which is what the command waits to see.
        let newView = Ghostty.SurfaceView(ghostty_app, baseConfig: config, uuid: request.surfaceID)
        coasttyObserveSurfaceIfNeeded(newView)

        let direction: SplitTree<Ghostty.SurfaceView>.NewDirection = switch request.direction {
        case .right: .right
        case .down: .down
        }

        if location.showing {
            guard let newTree = try? surfaceTree.inserting(view: newView, at: location.view, direction: direction) else {
                Ghostty.logger.warning("split request: inserting beside \(request.paneID, privacy: .public) failed")
                return
            }
            replaceSurfaceTree(
                newTree,
                moveFocusTo: request.focus ? newView : focusedSurface,
                moveFocusFrom: focusedSurface,
                undoAction: "New Split")
            return
        }

        let tab = coasttySpaces[location.space].tabs[location.tab]
        guard let newTree = try? tab.tree.inserting(view: newView, at: location.view, direction: direction) else { return }

        coasttySpaces[location.space].tabs[location.tab].tree = newTree
        CoasttyModelSync.send(CoasttyModelSync.Operation.operationsPlacingPanes(of: newTree, inTab: tab.id))
        CoasttySessionSaveScheduler.shared.markDirty()

        guard request.focus else {
            coasttyRefreshUI()
            return
        }
        coasttySpaces[location.space].tabs[location.tab].focusedSurfaceID = newView.id
        coasttyActivateSpace(at: location.space)
        coasttyActivateTab(at: location.tab)
    }

    /// Closes the pane a layout command asked to close without prompting, since the daemon already made the running check.
    private func coasttyCloseRequestedPane(_ hostID: String) {
        // The pane may have closed between the caller finding this window and now.
        guard let location = coasttyLocatePane(hostID) else { return }

        // An emptied live tree closes its tab, as when the user closes the last split.
        if location.showing {
            closeSurface(location.view, withConfirmation: false)
            return
        }

        let tab = coasttySpaces[location.space].tabs[location.tab]
        guard let node = tab.tree.root?.node(view: location.view) else { return }

        let remaining = tab.tree.removing(node)
        guard !remaining.isEmpty else {
            coasttyCloseRequestedTab(tab.id)
            return
        }

        CoasttyPaneLifecycle.kill(CoasttyPaneLifecycle.hostIDs(of: [location.view.closingPane]))
        coasttySpaces[location.space].tabs[location.tab].tree = remaining

        // The tab shows its remembered pane when switched to, so it must remember one it still holds.
        if tab.focusedSurfaceID == location.view.id {
            coasttySpaces[location.space].tabs[location.tab].focusedSurfaceID = remaining.first?.id
        }

        coasttyRefreshUI()
        CoasttySessionSaveScheduler.shared.markDirty()
    }

    /// Brings this window to the front and makes coastty the active app, as switching to it by hand would.
    private func coasttyBringToFront() {
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Shows the Space a layout command asked to focus and brings this window to the front.
    private func coasttyFocusRequestedSpace(_ id: UUID) {
        // The Space may have closed between the caller finding this window and now.
        guard let index = coasttySpaces.firstIndex(where: { $0.id == id }) else { return }
        coasttyActivateSpace(at: index)
        coasttyBringToFront()
    }

    /// Shows the tab a layout command asked to focus, in its Space, and brings this window to the front.
    private func coasttyFocusRequestedTab(_ id: UUID) {
        // The tab may have closed between the caller finding this window and now.
        guard let location = coasttyLocateTab(id) else { return }
        coasttyActivateSpace(at: location.space)
        coasttyActivateTab(at: location.tab)
        coasttyBringToFront()
    }

    /// Shows the tab holding the pane a layout command asked to focus, brings this window to the front and moves keyboard focus to the pane.
    private func coasttyFocusRequestedPane(_ hostID: String) {
        // The pane may have closed between the caller finding this window and now.
        guard let location = coasttyLocatePane(hostID) else { return }

        // A tab not showing installs the pane it remembers, so it is told to remember this one first.
        if !location.showing {
            coasttySpaces[location.space].tabs[location.tab].focusedSurfaceID = location.view.id
            coasttyActivateSpace(at: location.space)
            coasttyActivateTab(at: location.tab)
        }
        coasttyBringToFront()
        focusSurface(location.view)
    }

    /// The window holding the pane with this daemon id, or nil once it has closed.
    private static func coasttyHolder(ofPane hostID: String) -> TerminalController? {
        all.first { $0.coasttyLocatePane(hostID) != nil }
    }

    /// The window holding the tab with this id, or nil once it has closed.
    private static func coasttyHolder(ofTab id: UUID) -> TerminalController? {
        all.first { $0.coasttyLocateTab(id) != nil }
    }

    /// The window holding the Space with this id, or nil once it has closed.
    private static func coasttyHolder(ofSpace id: UUID) -> TerminalController? {
        all.first { $0.coasttySpaces.contains { $0.id == id } }
    }

    /// The window with this id, or nil once it has closed.
    private static func coasttyHolder(ofWindow id: UUID) -> TerminalController? {
        all.first { $0.coasttyWindowID == id }
    }

    /// Tells the daemon which windows are open and the Spaces each shows, leaving out `closing`, which is on its way out.
    private static func coasttyReportWindows(closing: TerminalController? = nil) {
        let windows = all.filter { $0 !== closing }.map { controller in
            CoasttyWindowsReport.Window(
                id: controller.coasttyWindowID,
                activeSpaceID: controller.coasttySpaces[safe: controller.coasttyActiveSpaceIndex]?.id,
                spaceIDs: controller.coasttySpaces.map(\.id))
        }
        CoasttyWindowsReport.send(windows)
    }

    /// Carries out a layout command's request in the window holding the Space or tab it names.
    static func coasttyCarryOut(_ request: CoasttyLayoutRequest) {
        switch request {
        case .newSpace(let newSpace):
            // The window named, else the caller's window when its Space is still open, else wherever the user is working.
            let holder = newSpace.windowID.flatMap(coasttyHolder(ofWindow:))
                ?? newSpace.besideSpaceID.flatMap(coasttyHolder(ofSpace:))
                ?? preferredParent
            holder?.coasttyAddRequestedSpace(newSpace)
        case .closeSpace(let id):
            coasttyHolder(ofSpace: id)?.coasttyCloseRequestedSpace(id)
        case .renameSpace(let id, let name):
            coasttyHolder(ofSpace: id)?.coasttyRenameRequestedSpace(id, name: name)
        case .moveSpace(let move):
            // The Space may have closed between the daemon resolving the request and now.
            guard let holder = coasttyHolder(ofSpace: move.id) else { return }
            guard let windowID = move.windowID else {
                holder.coasttyMoveRequestedSpace(move)
                return
            }
            // A window closed since the daemon checked it has nowhere to take the Space.
            coasttyHolder(ofWindow: windowID)?.coasttyTakeRequestedSpace(move, from: holder)
        case .focusSpace(let id):
            coasttyHolder(ofSpace: id)?.coasttyFocusRequestedSpace(id)
        case .newTab(let newTab):
            // A Space closed since the daemon resolved the request has no window left to add to.
            coasttyHolder(ofSpace: newTab.spaceID)?.coasttyAddRequestedTab(newTab)
        case .closeTab(let id):
            coasttyHolder(ofTab: id)?.coasttyCloseRequestedTab(id)
        case .renameTab(let id, let name):
            coasttyHolder(ofTab: id)?.coasttyRenameRequestedTab(id, name: name)
        case .moveTab(let id, let index):
            coasttyHolder(ofTab: id)?.coasttyMoveRequestedTab(id, to: index)
        case .focusTab(let id):
            coasttyHolder(ofTab: id)?.coasttyFocusRequestedTab(id)
        case .splitPane(let split):
            coasttyHolder(ofPane: split.paneID)?.coasttySplitRequestedPane(split)
        case .closePane(let id):
            coasttyHolder(ofPane: id)?.coasttyCloseRequestedPane(id)
        case .focusPane(let id):
            coasttyHolder(ofPane: id)?.coasttyFocusRequestedPane(id)
        }
    }

    /// Saves the currently-displayed tab's live state (its split tree and
    /// focused surface) back into `coasttyTabs` before we swap away from
    /// it. Must be called before mutating `coasttyActiveTabIndex` or
    /// `surfaceTree` directly for tab-switching purposes.
    private func coasttySnapshotActiveTab() {
        guard coasttyTabs.indices.contains(coasttyActiveTabIndex) else { return }

        // Guard against a stale active-tab index writing the live tree into the wrong tab's stored state.
        let storedSurfaceIDs = Set(coasttyTabs[coasttyActiveTabIndex].tree.map(\.id))
        guard surfaceTree.contains(where: { storedSurfaceIDs.contains($0.id) }) else { return }

        coasttyTabs[coasttyActiveTabIndex].tree = surfaceTree
        coasttyTabs[coasttyActiveTabIndex].focusedSurfaceID = focusedSurface?.id
        coasttyTabs[coasttyActiveTabIndex].titleOverride = titleOverride
    }

    /// Keeps coastty's own per-tab title storage/tab bar in sync whenever
    /// "Rename Tab..." changes `titleOverride` — see the override's doc
    /// comment on `BaseTerminalController.titleOverrideDidChange()`.
    /// Without this, a rename took effect (readable again next time the
    /// prompt is reopened, since `titleOverride` itself did persist) but
    /// never appeared in the tab bar, which reads `CoasttyTab.title`, not
    /// this per-controller property directly.
    override func titleOverrideDidChange() {
        super.titleOverrideDidChange()
        guard coasttyTabs.indices.contains(coasttyActiveTabIndex) else { return }
        coasttySetTitleOverride(titleOverride, spaceIndex: coasttyActiveSpaceIndex, tabIndex: coasttyActiveTabIndex)
    }

    /// Activates the tab at `index`: installs its split tree as this
    /// controller's own `surfaceTree` — the same `@Published` property
    /// `TerminalView` already renders from — and restores its remembered
    /// focus. The previously-active tab's surfaces are not destroyed:
    /// they stay alive, retained by `coasttyTabs`, just detached from the
    /// visible view until their tab is activated again (the same way a
    /// backgrounded native tab's surfaces stayed alive before).
    ///
    /// Some callers (post-close reindexing in `coasttyCloseTabImmediately`,
    /// clicking the already-active tab) pass an `index` that's already
    /// `coasttyActiveTabIndex` — they just want the tab bar/sidebar
    /// bookkeeping refreshed, not a real switch. That case must return
    /// early, before touching `surfaceTree`/`focusedSurface` at all: the
    /// live values are already correct and may be *newer* than whatever's
    /// stored in `coasttyTabs[index].tree` (e.g. a split made since the
    /// last snapshot) — installing the stored copy here would silently
    /// revert it.
    func coasttyActivateTab(at index: Int) {
        guard coasttyTabs.indices.contains(index) else { return }

        guard index != coasttyActiveTabIndex else {
            coasttyRefreshUI()
            return
        }

        coasttySnapshotActiveTab()
        coasttyActiveTabIndex = index
        coasttyInstallActiveTab(coasttyTabs[index])
        coasttyRefreshUI()
        CoasttySessionSaveScheduler.shared.markDirty()
    }

    /// Installs `tab` as the live state this controller's (Space-unaware)
    /// terminal-view machinery renders from: its split tree, its own
    /// title-rename override, and its remembered focus. Shared by
    /// `coasttyActivateTab(at:)` and `coasttyActivateSpace(at:)` - both are
    /// "switch which tab is showing," just reached differently, and every
    /// per-tab property installed here needs restoring on both paths or it
    /// silently carries over from whichever tab was active before -
    /// `titleOverride` is a per-controller property underneath, so a stale
    /// value here would leak one tab's rename onto whichever tab/Space is
    /// switched to next.
    private func coasttyInstallActiveTab(_ tab: CoasttyTab) {
        coasttyMarkSeen(tab)
        coasttyShowingTabID = tab.id
        coasttyReportedPaneIDs = []
        surfaceTree = tab.tree
        titleOverride = tab.titleOverride

        let target = tab.focusedSurfaceID.flatMap { id in tab.tree.first(where: { $0.id == id }) } ?? tab.tree.first
        if let target {
            focusedSurface = target
            DispatchQueue.main.async {
                Ghostty.moveFocus(to: target, from: nil)
            }
        }
    }

    /// Closes the tab at `index`, ending every process in it. If it's the
    /// last tab in its Space, this closes the Space instead (or the
    /// window, if this is the only Space). Pass `withConfirmation: false`
    /// for already-confirmed closes and `true` for user-initiated ones,
    /// which should prompt if the tab has a running process.
    func coasttyCloseTab(at index: Int, withConfirmation: Bool) {
        guard coasttyTabs.indices.contains(index) else { return }

        guard coasttyTabs.count > 1 else {
            coasttyCloseLastTabInSpace(at: index, withConfirmation: withConfirmation)
            return
        }

        guard withConfirmation, coasttyTabs[index].needsConfirmQuit else {
            coasttyCloseTabImmediately(at: index)
            return
        }

        confirmClose(
            messageText: "Close Tab?",
            informativeText: "The terminal still has a running process. If you close the tab the process will be killed."
        ) {
            self.coasttyCloseTabImmediately(at: index)
        }
    }

    /// Removes the active Space (jumping to whatever `coasttyCloseSpaceImmediately`
    /// picks), or closes the window if this is the only Space.
    private func coasttyCloseLastTabInSpace(at index: Int, withConfirmation: Bool) {
        guard coasttySpaces.count > 1 else {
            if withConfirmation {
                closeWindow(nil)
            } else {
                closeWindowImmediately()
            }
            return
        }

        guard withConfirmation, coasttyTabs[index].needsConfirmQuit else {
            coasttyCloseLastTabInSpaceImmediately(at: index)
            return
        }

        confirmClose(
            messageText: "Close Tab?",
            informativeText: "The terminal still has a running process. If you close the tab the process will be killed."
        ) {
            self.coasttyCloseLastTabInSpaceImmediately(at: index)
        }
    }

    /// Tears down the sole remaining tab before removing its now-empty Space, mirroring `coasttyCloseTabImmediately`.
    private func coasttyCloseLastTabInSpaceImmediately(at index: Int) {
        guard coasttyTabs.indices.contains(index) else { return }

        cancelPendingInitialPresentation()
        // Structural, not functional: with one tab left, index == coasttyActiveTabIndex, so this snapshots the very tab removed next.
        coasttySnapshotActiveTab()
        // Killed here, not by the Space close below: the tab is already out of the Space by then, so its panes wouldn't be in the set that close collects.
        coasttyRemoveTab(inSpaceAt: coasttyActiveSpaceIndex, at: index)
        coasttyCloseSpaceImmediately(at: coasttyActiveSpaceIndex)
    }

    /// Closes the tab at `index`, ending every process it held. No undo, since the processes are gone.
    private func coasttyCloseTabImmediately(at index: Int) {
        guard coasttyTabs.indices.contains(index) else { return }
        guard coasttyTabs.count > 1 else {
            if coasttySpaces.count > 1 {
                coasttyCloseLastTabInSpaceImmediately(at: index)
            } else {
                closeWindowImmediately()
            }
            return
        }

        cancelPendingInitialPresentation()

        // If we're closing the active tab, make sure its live state is
        // captured in the snapshot we're about to remove (rather than
        // whatever stale tree it had the last time it was backgrounded).
        if index == coasttyActiveTabIndex {
            coasttySnapshotActiveTab()
        }

        coasttyRemoveTab(inSpaceAt: coasttyActiveSpaceIndex, at: index)

        // Figure out which tab should become active post-removal: if we
        // closed something before the active tab, its index just shifted
        // down by one; if we closed the active tab itself, prefer the tab
        // that slid into its old slot (i.e. the next tab, or the new last
        // tab if it was rightmost); otherwise the active tab didn't move.

        // Correct coasttyActiveTabIndex before marking dirty below - it's briefly stale here and would alias the wrong tab.
        let newActiveIndex: Int
        if index < coasttyActiveTabIndex {
            newActiveIndex = coasttyActiveTabIndex - 1
            // The active tab itself didn't change, only its index shifted
            // down because something before it was removed. Update the
            // index in place *before* calling `coasttyActivateTab` below,
            // so it sees `index == coasttyActiveTabIndex` and treats this
            // as a no-op re-activation rather than a real switch. Otherwise
            // it would call `coasttySnapshotActiveTab()` against the stale,
            // pre-removal index, which — after the array shrank — now
            // refers to a *different* tab (the one that used to sit right
            // after the active one), silently overwriting that tab's saved
            // `SplitTree` with the active tab's.
            coasttyActiveTabIndex = newActiveIndex
        } else if index == coasttyActiveTabIndex {
            newActiveIndex = min(index, coasttyTabs.count - 1)
            // Unlike the branch above, this *is* a real switch: we just
            // closed the active tab itself, so whichever tab now sits at
            // `newActiveIndex` is a genuinely different tab that happens
            // to land on the same numeric slot. `coasttyActivateTab`'s
            // no-op guard only compares `index == coasttyActiveTabIndex`,
            // so left alone it would misread this as "nothing changed" and
            // skip installing the new tab's surfaceTree — leaving the
            // window showing the just-closed tab's now-stale content.
            // Invalidate the stored index first so that guard can't fire.
            coasttyActiveTabIndex = -1
        } else {
            newActiveIndex = coasttyActiveTabIndex
        }
        coasttyActivateTab(at: max(0, min(newActiveIndex, coasttyTabs.count - 1)))
        CoasttySessionSaveScheduler.shared.markDirty()
    }

    // MARK: coastty Spaces

    /// Creates a new coastty Space in this window — with exactly one
    /// starter tab of its own — and makes it the active Space, so the tab
    /// bar switches to show that single tab. Issue #12 (coastty repo),
    /// Round 4: the Spaces section's "+ New" control creates a whole new
    /// Space, not a new tab in the current one (that was the previous,
    /// incorrect behavior) and not a new window either.
    @discardableResult
    func coasttyNewSpace(baseConfig: Ghostty.SurfaceConfiguration? = nil) -> CoasttySpace? {
        guard let ghostty_app = ghostty.app else { return nil }

        let effectiveConfig = coasttyInheritedWorkingDirectoryConfig(baseConfig)
        let newSurface = Ghostty.SurfaceView(ghostty_app, baseConfig: effectiveConfig)
        var newTab = CoasttyTab(tree: .init(view: newSurface), focusedSurfaceID: newSurface.id)
        if effectiveConfig?.workingDirectory != nil, coasttyTabs.indices.contains(coasttyActiveTabIndex) {
            newTab.inheritedTitleHint = coasttyTabs[coasttyActiveTabIndex].title
        }
        let startingPath = Self.startingFolderPath(effectiveConfig?.workingDirectory)
        let newSpace = CoasttySpace(tabs: [newTab], initialFolderName: Self.folderDisplayName(for: startingPath))
        coasttyObserveSurfaceIfNeeded(newSurface)

        coasttySnapshotActiveTab()
        coasttySpaces.append(newSpace)

        // Before activating: activating installs the starter tab's tree, and
        // that reports the pane in it. The tab has to exist by then or the
        // placement is refused and the Space is left with nothing in it.
        CoasttyModelSync.send([
            .spaceNew(id: newSpace.id, name: newSpace.name),
            .spaceMove(id: newSpace.id, to: coasttySpaces.count - 1),
            .tabNew(spaceID: newSpace.id, tabID: newTab.id, name: newTab.titleOverride ?? ""),
        ])
        coasttyActivateSpace(at: coasttySpaces.count - 1)
        CoasttySessionSaveScheduler.shared.markDirty()

        if let undoManager {
            undoManager.setActionName("New Space")
            undoManager.registerUndo(withTarget: self, expiresAfter: undoExpiration) { target in
                if let idx = target.coasttySpaces.firstIndex(where: { $0.id == newSpace.id }) {
                    undoManager.disableUndoRegistration {
                        target.coasttyCloseSpaceImmediately(at: idx)
                    }
                }

                undoManager.registerUndo(withTarget: target, expiresAfter: target.undoExpiration) { target in
                    target.coasttyNewSpace(baseConfig: baseConfig)
                }
            }
        }

        return newSpace
    }

    /// Activates the Space at `index`: saves the currently-active Space's
    /// live tab state, then switches which Space's tabs/active-tab the
    /// rest of this controller's (Space-unaware) tab logic operates on —
    /// see `coasttyTabs`/`coasttyActiveTabIndex`'s own doc comments. This
    /// installs that Space's own active tab's tree as `self.surfaceTree`,
    /// exactly like `coasttyActivateTab(at:)` does when switching tabs
    /// within a single Space.
    ///
    /// Mirrors `coasttyActivateTab(at:)`'s no-op guard: a caller passing
    /// an `index` that's already `coasttyActiveSpaceIndex` just wants the
    /// tab bar/sidebar bookkeeping refreshed, not a real switch.
    func coasttyActivateSpace(at index: Int) {
        guard coasttySpaces.indices.contains(index) else { return }

        guard index != coasttyActiveSpaceIndex else {
            coasttyRefreshUI()
            return
        }

        // Relies on coasttySnapshotActiveTab()'s own guard for a -1 index (see coasttyCloseSpaceImmediately), or this would snapshot into the Space that slid into the removed slot.
        coasttySnapshotActiveTab()
        coasttyActiveSpaceIndex = index

        let space = coasttySpaces[index]
        guard let tab = space.tabs[safe: space.activeTabIndex] ?? space.tabs.first else {
            coasttyRefreshUI()
            return
        }
        coasttyInstallActiveTab(tab)
        coasttyRefreshUI()
        CoasttySessionSaveScheduler.shared.markDirty()
    }

    /// Closes the Space at `index`, asking first when anything in it is still running - a Space can hold many tabs, and that is a lot to lose on one click.
    private func coasttyCloseSpace(at index: Int) {
        guard coasttySpaces.indices.contains(index) else { return }

        // The showing tab's live tree only reaches its Space on a snapshot; without this a process running in it wouldn't count towards the confirmation below.
        coasttySnapshotActiveTab()

        guard CoasttyPaneLifecycle.needsCloseConfirmation(coasttySpaces[index].closingPanes) else {
            coasttyCloseSpaceImmediately(at: index)
            return
        }

        confirmClose(
            messageText: "Close Space?",
            informativeText: "This Space still has a running process. If you close it the process will be killed."
        ) {
            self.coasttyCloseSpaceImmediately(at: index)
        }
    }

    /// Removes the Space at `index` and reactivates a sane remaining one, or closes the window if it was the last. Ends every process in every tab it held; no undo, since they're gone.
    private func coasttyCloseSpaceImmediately(at index: Int) {
        guard coasttySpaces.indices.contains(index) else { return }
        guard coasttySpaces.count > 1 else {
            closeWindowImmediately()
            return
        }

        let closedSpace = coasttySpaces.remove(at: index)
        CoasttyPaneLifecycle.kill(CoasttyPaneLifecycle.hostIDs(of: closedSpace.closingPanes))
        CoasttyModelSync.send(.spaceClose(id: closedSpace.id))
        coasttyReactivateAfterRemovingSpace(at: index)
    }

    /// Activates a sane remaining Space once the one at `index` has been removed from `coasttySpaces`.
    private func coasttyReactivateAfterRemovingSpace(at index: Int) {
        // Correct coasttyActiveSpaceIndex before marking dirty - it's briefly stale here and would alias the wrong Space's tab.
        let newActiveIndex: Int
        if index < coasttyActiveSpaceIndex {
            newActiveIndex = coasttyActiveSpaceIndex - 1
            coasttyActiveSpaceIndex = newActiveIndex
        } else if index == coasttyActiveSpaceIndex {
            newActiveIndex = min(index, coasttySpaces.count - 1)
            coasttyActiveSpaceIndex = -1
        } else {
            newActiveIndex = coasttyActiveSpaceIndex
        }
        coasttyActivateSpace(at: max(0, min(newActiveIndex, coasttySpaces.count - 1)))
        CoasttySessionSaveScheduler.shared.markDirty()
    }

    /// Closes every Space except the active one, asking first if any of them still has a running process. Mirrors `closeOtherTabs`, applied to `coasttySpaces`.
    private func closeOtherSpaces() {
        guard coasttySpaces.count > 1 else { return }

        coasttyCloseSpacesBatch(
            indices: coasttySpaces.indices.filter { $0 != coasttyActiveSpaceIndex },
            messageText: "Close Other Spaces?",
            informativeText: "At least one other Space still has a running process. If you close it the process will be killed.")
    }

    /// Closes every Space to the right of the active one, asking first if any of them still has a running process.
    private func closeSpacesOnTheRight() {
        guard coasttyActiveSpaceIndex < coasttySpaces.count - 1 else { return }

        coasttyCloseSpacesBatch(
            indices: coasttySpaces.indices.filter { $0 > coasttyActiveSpaceIndex },
            messageText: "Close Spaces to the Right?",
            informativeText: "At least one Space to the right still has a running process. If you close it the process will be killed.")
    }

    /// Closes `indices` from the end (so removing a higher index never invalidates one not yet processed), behind a single confirmation covering the whole batch.
    private func coasttyCloseSpacesBatch(
        indices: [Int],
        messageText: String,
        informativeText: String
    ) {
        coasttySnapshotActiveTab()

        let panes = indices.flatMap { coasttySpaces[$0].closingPanes }
        guard CoasttyPaneLifecycle.needsCloseConfirmation(panes) else {
            for index in indices.sorted(by: >) { coasttyCloseSpaceImmediately(at: index) }
            return
        }

        confirmClose(messageText: messageText, informativeText: informativeText) {
            for index in indices.sorted(by: >) { self.coasttyCloseSpaceImmediately(at: index) }
        }
    }

    /// Prompts to rename the Space at `index` — the sidebar row's
    /// "Rename..." context menu item. Mirrors `promptTabTitle()`'s own
    /// alert/textfield shape exactly (leave blank to restore the default,
    /// same wording), just writing to `CoasttySpace.nameOverride` instead
    /// of `titleOverride`. Ghostty core has no equivalent action here —
    /// Spaces are coastty's own invention, with no upstream `prompt_surface_title`
    /// counterpart — so this is plain Swift/AppKit, not a Zig-core ticket.
    private func coasttyPromptSpaceTitle(for id: UUID) {
        guard let window else { return }
        guard let index = coasttySpaces.firstIndex(where: { $0.id == id }) else { return }

        let space = coasttySpaces[index]
        let alert = NSAlert()
        alert.messageText = "Change Space Name"
        alert.informativeText = "Leave blank to restore the default."
        alert.alertStyle = .informational

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        textField.stringValue = space.nameOverride ?? space.name
        alert.accessoryView = textField

        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        alert.window.initialFirstResponder = textField

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else { return }
            guard let index = self.coasttySpaces.firstIndex(where: { $0.id == id }) else { return }

            let newName = textField.stringValue
            self.coasttySpaces[index].nameOverride = newName.isEmpty ? nil : newName
            self.coasttyRefreshUI()
            CoasttySessionSaveScheduler.shared.markDirty()
            CoasttyModelSync.send(.spaceRename(
                id: self.coasttySpaces[index].id,
                name: self.coasttySpaces[index].name))
        }
    }

    /// Rebuilds coastty's tab bar model and sidebar model from
    /// `coasttyTabs`/`coasttyActiveTabIndex`. Call after any change to
    /// the tab list or the active tab.
    private func coasttyRefreshUI() {
        coasttyObserveUnobservedSurfaces()
        coasttyReportPaneMembershipIfNeeded()
        coasttySyncViewed()
        coasttyReportFocus()
        Self.coasttyReportWindows()

        coasttyTabBarModel.tabs = coasttyTabs.enumerated().map { index, tab in
            CoasttyTabBarModel.Tab(
                id: tab.id,
                title: tab.title,
                shortcutLabel: coasttyShortcutLabel(forTabIndex: index),
                status: coasttyAgentStatus(for: tab)
            )
        }
        coasttyTabBarModel.activeTabID = coasttyTabs.indices.contains(coasttyActiveTabIndex)
            ? coasttyTabs[coasttyActiveTabIndex].id
            : nil

        sidebarSplitViewController?.updateSidebarModel(makeSidebarModel())
    }

    /// Formats a live `KeyboardShortcut` as its on-screen label (e.g. "⌘U").
    private static func coasttyShortcutLabel(for shortcut: KeyboardShortcut) -> String {
        var label = ""
        if shortcut.modifiers.contains(.command) { label += "⌘" }
        if shortcut.modifiers.contains(.control) { label += "⌃" }
        if shortcut.modifiers.contains(.option) { label += "⌥" }
        if shortcut.modifiers.contains(.shift) { label += "⇧" }
        label += String(shortcut.key.character).uppercased()
        return label
    }

    /// e.g. "⌘1" for the first 9 tabs, mirroring whatever `goto_tab:N`
    /// keybinding is actually configured (respecting user rebinds) rather
    /// than hardcoding the default.
    private func coasttyShortcutLabel(forTabIndex index: Int) -> String? {
        guard index < 9 else { return nil }
        guard let shortcut = ghostty.config.keyboardShortcut(for: "goto_tab:\(index + 1)") else { return nil }
        return Self.coasttyShortcutLabel(for: shortcut)
    }

    /// Same as `coasttyShortcutLabel(forTabIndex:)` above, but for
    /// `goto_space:N` — the real default is `⌃⇧1`-`⌃⇧9`, but this still
    /// reads the live config rather than hardcoding that, for the same
    /// respects-rebinds reasoning.
    private func coasttyShortcutLabel(forSpaceIndex index: Int) -> String? {
        guard index < 9 else { return nil }
        guard let shortcut = ghostty.config.keyboardShortcut(for: "goto_space:\(index + 1)") else { return nil }
        return Self.coasttyShortcutLabel(for: shortcut)
    }

    /// Same again, for a bare action with no `:N` index.
    private func coasttyShortcutLabel(forAction action: String) -> String? {
        guard let shortcut = ghostty.config.keyboardShortcut(for: action) else { return nil }
        return Self.coasttyShortcutLabel(for: shortcut)
    }

    /// Builds coastty's sidebar data model from this window's own Spaces —
    /// issue #12 (coastty repo), Round 4: every Space this window owns
    /// gets its own summary row now, not just the one implicit Space a
    /// window used to be limited to.
    private func makeSidebarModel() -> CoasttySidebarModel {
        let summaries = coasttySpaces.enumerated().map { index, space in
            CoasttySpaceSummary(
                id: space.id,
                name: space.name,
                tabs: space.tabs.flatMap { tab in
                    coasttyAgentPanes(in: tab, space: space)
                },
                shortcutLabel: coasttyShortcutLabel(forSpaceIndex: index)
            )
        }

        var model = CoasttySidebarModel(
            spaces: summaries,
            activeSpaceID: coasttySpaces[safe: coasttyActiveSpaceIndex]?.id
        )
        if model.hasUsefulUrgentAgentJump(focusedSurfaceID: focusedSurface?.id) {
            model.agentsShortcutLabel = coasttyShortcutLabel(forAction: "goto_urgent_agent")
        }
        return model
    }

    /// One entry per pane in `tab`. A split tab runs one agent per pane, so
    /// each pane gets its own row rather than the whole tab collapsing into
    /// one - matching herdr, whose `pane_details` walks every pane of every
    /// tab (`src/workspace/aggregate.rs`).
    private func coasttyAgentPanes(in tab: CoasttyTab, space: CoasttySpace) -> [CoasttyAgentTab] {
        // The live tree is the truth for the tab currently installed; the
        // stored one goes stale as soon as a split changes.
        let tree = tab.id == coasttyTabs[safe: coasttyActiveTabIndex]?.id ? surfaceTree : tab.tree
        let isActiveTab = space.id == coasttySpaces[safe: coasttyActiveSpaceIndex]?.id
            && tab.id == coasttyTabs[safe: coasttyActiveTabIndex]?.id

        return tree.map { surface in
            let status = coasttyAttention(of: surface)
            return CoasttyAgentTab(
                id: surface.id,
                tabName: tab.title,
                agentName: surface.coasttyDetectedAgent?.displayName,
                status: status,
                isActive: isActiveTab && surface.id == focusedSurface?.id,
                destination: .init(spaceID: space.id, tabID: tab.id, surfaceID: surface.id),
                priority: coasttyStatusPriority(status),
                statusChangeSeq: coasttyStatusChangeSeq(for: surface)
            )
        }
    }

    /// Brings the pane behind an Agents-section row to the front: its
    /// space, then its tab within that space, then the pane itself.
    private func coasttyActivateAgentDestination(_ destination: CoasttyAgentDestination) {
        guard let spaceIndex = coasttySpaces.firstIndex(where: { $0.id == destination.spaceID })
        else { return }

        // Point the tab at the pane we are heading for *before* activating
        // it. `coasttyActivateTab` restores the tab's own remembered pane
        // and schedules the focus move itself, so focusing afterwards would
        // race that one - and lose, landing on whichever pane the tab was
        // last left on.
        if let tabIndex = coasttySpaces[spaceIndex].tabs.firstIndex(where: { $0.id == destination.tabID }) {
            coasttySpaces[spaceIndex].tabs[tabIndex].focusedSurfaceID = destination.surfaceID
        }

        if spaceIndex != coasttyActiveSpaceIndex {
            coasttyActivateSpace(at: spaceIndex)
        }

        if let tabIndex = coasttyTabs.firstIndex(where: { $0.id == destination.tabID }),
           tabIndex != coasttyActiveTabIndex {
            coasttyActivateTab(at: tabIndex)
        }

        // Still needed for the already-on-this-tab case, where neither
        // activation ran. Harmless otherwise: both now target the same pane.
        guard let surface = surfaceTree.first(where: { $0.id == destination.surfaceID })
        else { return }

        let previous = focusedSurface
        focusedSurface = surface
        Ghostty.moveFocus(to: surface, from: previous)
    }

    /// Keeps the Agents section's active-pane highlight on whichever pane
    /// actually has focus.
    override func focusedSurfaceDidChange() {
        coasttyRefreshUI()
    }

    /// A directory path's short display name — its last path component
    /// (e.g. "coastty", "plainkey"). The one exception is the home
    /// directory itself: without this, `lastPathComponent` on
    /// `/Users/alice` returns "alice" (the username), not anything that
    /// reads as "home."
    static func folderDisplayName(for path: String) -> String {
        if path == NSHomeDirectory() { return "~" }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// The best synchronously-known starting folder for a new Space's name
    /// — `path` if one's already inherited/explicit, otherwise the home
    /// directory, matching where a freshly spawned shell actually starts
    /// when nothing else is configured. Always resolvable immediately,
    /// unlike a new surface's own pwd (which only arrives once its shell
    /// reports one) — see `coasttyNewSpace`/the initial window-seed path.
    static func startingFolderPath(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return NSHomeDirectory() }
        return path
    }

    /// Abbreviates a path's home-directory prefix to "~", mirroring the
    /// same convention `tmux/coastty.tmux.conf`'s `set-titles-string`
    /// already uses (`#{s|^$HOME|~|:pane_current_path}`) — one consistent
    /// rule for "how coastty shortens a real path," here and once tmux
    /// (ticket #15) is wired in.
    static func abbreviatingHome(in path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    override func syncAppearance() {
        // When our focus changes, we update our window appearance based on the
        // currently focused surface.
        guard let focusedSurface else { return }
        syncAppearance(focusedSurface.derivedConfig)
    }

    private func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        // Let our window handle its own appearance
        guard let window = window as? TerminalWindow else { return }

        // Sync our zoom state for splits
        window.surfaceIsZoomed = surfaceTree.zoomed != nil

        // Set the font for the window and tab titles.
        if let titleFontName = surfaceConfig.windowTitleFontFamily {
            window.titlebarFont = NSFont(name: titleFontName, size: NSFont.systemFontSize)
        } else {
            window.titlebarFont = nil
        }

        // Call this last in case it uses any of the properties above.
        window.syncAppearance(surfaceConfig)

        // A recoloured titlebar is redrawn with AppKit's separator bar, whatever `titlebarSeparatorStyle` says; the bar only exists once that redraw has run, so it is hidden on the next turn.
        DispatchQueue.main.async { [weak window] in
            window?.coasttyHideTitlebarSeparatorBar()
        }
        terminalViewContainer?.ghosttyConfigDidChange(ghostty.config, preferredBackgroundColor: window.preferredBackgroundColor)
    }

    /// Adjusts the given frame for the configured window position.
    func adjustForWindowPosition(frame: NSRect, on screen: NSScreen) -> NSRect {
        guard let x = derivedConfig.windowPositionX else { return frame }
        guard let y = derivedConfig.windowPositionY else { return frame }

        // Convert top-left coordinates to bottom-left origin using our utility extension
        let origin = screen.origin(
            fromTopLeftOffsetX: CGFloat(x),
            offsetY: CGFloat(y),
            windowSize: frame.size)

        // Clamp the origin to ensure the window stays fully visible on screen
        var safeOrigin = origin
        let vf = screen.visibleFrame
        safeOrigin.x = min(max(safeOrigin.x, vf.minX), vf.maxX - frame.width)
        safeOrigin.y = min(max(safeOrigin.y, vf.minY), vf.maxY - frame.height)

        // Return our new origin
        var result = frame
        result.origin = safeOrigin
        return result
    }

    /// This is called anytime a node in the surface tree is being removed.
    override func closeSurface(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        withConfirmation: Bool = true
    ) {
        // If this isn't the root then we're dealing with a split closure.
        if surfaceTree.root != node {
            super.closeSurface(node, withConfirmation: withConfirmation)
            return
        }

        coasttyCloseTab(at: coasttyActiveTabIndex, withConfirmation: withConfirmation)
    }

    /// Closes the currently-active tab immediately and without
    /// confirmation. If it's the last tab, this closes the whole window
    /// instead.
    func closeTabImmediately() {
        coasttyCloseTabImmediately(at: coasttyActiveTabIndex)
    }

    /// Closes a batch of tabs (`indices`). Shared by `closeOtherTabsImmediately` and `closeTabsOnTheRightImmediately`.
    private func coasttyCloseTabsBatchImmediately(indices: some Sequence<Int>) {
        guard coasttyTabs.indices.contains(coasttyActiveTabIndex) else { return }

        // Close from the end so removing a higher index never invalidates
        // an index we haven't processed yet.
        for index in indices.sorted(by: >) {
            coasttyCloseTabImmediately(at: index)
        }
    }

    private func closeOtherTabsImmediately() {
        guard coasttyTabs.count > 1 else { return }

        coasttyCloseTabsBatchImmediately(indices: coasttyTabs.indices.filter { $0 != coasttyActiveTabIndex })
    }

    private func closeTabsOnTheRightImmediately() {
        guard coasttyActiveTabIndex < coasttyTabs.count - 1 else { return }

        coasttyCloseTabsBatchImmediately(indices: coasttyTabs.indices.filter { $0 > coasttyActiveTabIndex })
    }

    /// Closes the current window (including every Space it owns, and every
    /// tab within each of those) immediately and without confirmation,
    /// ending every process it held. No undo, since the processes are gone.
    func closeWindowImmediately() {
        guard let window = window else { return }

        cancelPendingInitialPresentation()

        // Snapshot first so the active tab's live tree is in the Space it belongs to, or its panes wouldn't be in the set collected below.
        coasttySnapshotActiveTab()
        CoasttyPaneLifecycle.kill(CoasttyPaneLifecycle.hostIDs(of: coasttySpaces.flatMap(\.closingPanes)))

        // These Spaces are being ended, not put down for a quit to pick up
        // again, so the daemon has to lose them too. Closing the last Space in
        // a window arrives here rather than in `coasttyCloseSpaceImmediately`,
        // which is why the report cannot live there alone.
        CoasttyModelSync.send(coasttySpaces.map { .spaceClose(id: $0.id) })

        // Clear out every Space's state (not just the active one) to
        // ensure there's no lingering undo state. Setting `surfaceTree` to
        // empty also triggers this controller's own window close via
        // `surfaceTreeDidChange`.
        coasttySpaces.removeAll()
        surfaceTree = .init()

        window.close()
    }

    /// Close all windows, asking for confirmation if necessary.
    static func closeAllWindows() {
        // The window we use for confirmations. Try to find the first window
        // that needs quit confirmation, checking every Space this window
        // owns and every tab within each of those (not just the active
        // Space's active tab) since a backgrounded Space/tab's running
        // process shouldn't be silently killed without asking either.
        guard let confirmController = all.first(where: { controller in
            controller.coasttySnapshotActiveTab()
            return controller.coasttySpaces.contains(where: { $0.needsConfirmQuit })
        }), let confirmWindow = confirmController.window
        else {
            closeAllWindowsImmediately()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Close All Windows?"
        alert.informativeText = "All terminal sessions will be terminated."
        alert.addButton(withTitle: "Close All Windows")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: confirmWindow, completionHandler: { response in
            if response == .alertFirstButtonReturn {
                // This is important so that we avoid losing focus when Stage
                // Manager is used (#8336)
                alert.window.orderOut(nil)
                closeAllWindowsImmediately()
            }
        })
    }

    static private func closeAllWindowsImmediately() {
        all.forEach { $0.closeWindowImmediately() }
    }

    /// Checks every Space and tab this window owns, not just the active one: a backgrounded tab's process is just as dead after a quit, so it deserves the same warning.
    override var needsConfirmAppQuit: Bool {
        coasttySnapshotActiveTab()
        return coasttySpaces.contains(where: \.needsConfirmAppQuit)
    }

    /// What this window makes of the model: where it sits, which Spaces it shows, and where its split dividers are. Nil for a window with nothing to show.
    var coasttyWindowLayout: CoasttyWindowLayout? {
        guard let window else { return nil }
        coasttySnapshotActiveTab()
        guard !coasttySpaces.isEmpty else { return nil }

        let spaces = coasttySpaces.map { space in
            CoasttyWindowLayout.Space(
                spaceID: space.id.uuidString,
                activeTabIndex: space.activeTabIndex,
                tabs: space.tabs.map { tab in
                    CoasttyWindowLayout.Tab(
                        tabID: tab.id.uuidString,
                        focusedPaneID: tab.focusedSurfaceID?.uuidString,
                        shape: CoasttyLayoutShape.shape(of: tab.tree))
                })
        }

        return .init(
            windowID: coasttyWindowID.uuidString,
            frame: window.frame,
            tabColor: (window as? TerminalWindow)?.tabColor ?? .none,
            spaces: spaces,
            activeSpaceIndex: coasttyActiveSpaceIndex)
    }

    /// Which tab's tree is currently installed as `surfaceTree`, by id.
    ///
    /// Attribution cannot use `coasttyActiveTabIndex`: `coasttyTabs` forwards onto whichever Space is active, and the close and switch paths deliberately leave those indices stale or -1 for a moment. A tree change landing in that window would be credited to a tab in the wrong Space. An id does not shift when an array reindexes.
    private var coasttyShowingTabID: UUID?

    /// The panes last reported for the showing tab, so a refresh only reaches the daemon when membership actually changed.
    private var coasttyReportedPaneIDs: [String] = []

    /// The Space and tab a window seeded for itself, held back until it has a pane to put in them.
    ///
    /// A window built around an empty tree closes itself again the moment that is noticed, and takes no close path with it - so a Space reported the instant the window loaded would outlive the window with nothing left to remove it. Waiting for a pane means only a window that really came up is ever in the model.
    private var coasttyPendingSeedReport: [CoasttyModelSync.Operation]?

    /// Reports which panes the showing tab holds, if that differs from what the daemon was last told.
    ///
    /// A tree change is not the only thing that moves this. A pane gets a daemon id when its process starts, which is after the tab holding it was reported - so a freshly created tab's pane is invisible at the moment the tree is installed and only becomes reportable a beat later. Re-checking on refresh catches it, and the comparison keeps a spinner frame from turning into a socket round trip.
    private func coasttyReportPaneMembershipIfNeeded(tree: SplitTree<Ghostty.SurfaceView>? = nil) {
        guard let tabID = coasttyShowingTabID else { return }
        let hostIDs = CoasttyPaneLifecycle.hostIDs(of: (tree ?? surfaceTree).map(\.closingPane))
        guard hostIDs != coasttyReportedPaneIDs else { return }
        coasttyReportedPaneIDs = hostIDs
        guard !hostIDs.isEmpty else { return }

        let seed = coasttyPendingSeedReport ?? []
        coasttyPendingSeedReport = nil
        CoasttyModelSync.send(seed + hostIDs.enumerated().map { index, hostID in
            .paneMove(hostID: hostID, toTab: tabID, at: index)
        })
    }

    /// Reports the structure every open window holds to the daemon's model. Without it the daemon only ever hears about changes made after launch, and the first move would name a Space it has never seen.
    static func coasttySeedHostModel() {
        var operations: [CoasttyModelSync.Operation] = []
        for controller in all {
            // The showing tab's live tree only reaches its Space on a snapshot.
            controller.coasttySnapshotActiveTab()
            operations += CoasttyModelSync.Operation.operationsRecreating(controller.coasttySpaces)
        }
        CoasttyModelSync.send(operations)
    }

    /// Every coastty-host pane every open window currently holds - what the daemon is handed after a restore so it can end whatever else it still carries.
    static func claimedHostPaneIDs() -> [String] {
        var panes: [CoasttyPaneLifecycle.Pane] = []
        for controller in all {
            // The active tab's live tree only reaches its Space on a snapshot; without this its panes would look unclaimed.
            controller.coasttySnapshotActiveTab()
            panes.append(contentsOf: controller.coasttySpaces.flatMap(\.closingPanes))
        }
        return CoasttyPaneLifecycle.hostIDs(of: panes)
    }

    // MARK: Undo/Redo

    /// The state that we require to recreate a TerminalController from an
    /// undo. Captures *every* Space this window owns, and every tab within
    /// each of those (not just the active Space's active tab) — issue #12
    /// (coastty repo) made a tab an in-window concept instead of a separate
    /// `NSWindow`, and Round 4 further nested tabs inside Spaces, so
    /// restoring "the window" now means restoring its whole Space/tab
    /// hierarchy, which used to be handled by restoring several separate
    /// windows into one tab group.
    struct UndoState: Codable {
        /// Nil in a session saved before windows had an id.
        let windowID: UUID?
        let frame: NSRect
        let spaces: [CoasttySpace]
        let activeSpaceIndex: Int
        let tabColor: TerminalTabColor
    }

    convenience init(_ ghostty: Ghostty.App, with undoState: UndoState) {
        let activeSpace = undoState.spaces[safe: undoState.activeSpaceIndex]
        let activeTree = activeSpace?.tabs[safe: activeSpace?.activeTabIndex ?? 0]?.tree ?? .init()
        self.init(
            ghostty,
            withSurfaceTree: activeTree,
            withSpaces: undoState.spaces,
            activeSpaceIndex: undoState.activeSpaceIndex,
            windowID: undoState.windowID)

        // Reinstall before showWindow - it triggers a markDirty() that would otherwise snapshot these back to nil.
        let activeTab = coasttyTabs[safe: coasttyActiveTabIndex]
        self.titleOverride = activeTab?.titleOverride
        if let focusedID = activeTab?.focusedSurfaceID,
           let focusTarget = activeTab?.tree.first(where: { $0.id == focusedID }) {
            self.focusedSurface = focusTarget
        } else {
            self.focusedSurface = surfaceTree.first
        }

        // Show the window and restore its frame
        showWindow(nil)
        if let window {
            window.setFrame(undoState.frame, display: true)
            if let terminalWindow = window as? TerminalWindow {
                terminalWindow.tabColor = undoState.tabColor
            }

            window.makeKeyAndOrderFront(nil)

            // focusedSurface is already correct (set above); this just moves the responder chain to match.
            if let focusedSurface {
                DispatchQueue.main.async {
                    Ghostty.moveFocus(to: focusedSurface, from: nil)
                }
            }

            coasttyRefreshUI()
        }
    }

    /// The current undo state for this controller, covering every Space
    /// this window owns and every tab within each of those.
    var undoState: UndoState? {
        guard let window else { return nil }
        coasttySnapshotActiveTab()
        guard !coasttySpaces.isEmpty else { return nil }
        return .init(
            windowID: coasttyWindowID,
            frame: window.frame,
            spaces: coasttySpaces,
            activeSpaceIndex: coasttyActiveSpaceIndex,
            tabColor: (window as? TerminalWindow)?.tabColor ?? .none)
    }

    // MARK: - NSWindowController

    override func windowWillLoad() {
        // We do NOT want to cascade because we handle this manually from the manager.
        shouldCascadeWindows = false
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        guard let window else { return }

        // I copy this because we may change the source in the future but also because
        // I regularly audit our codebase for "ghostty.config" access because generally
        // you shouldn't use it. Its safe in this case because for a new window we should
        // use whatever the latest app-level config is.
        let config = ghostty.config

        // Native restoration can race coastty's own restore and clobber session.json; coastty owns persistence now.
        window.isRestorable = false

        // If we have only a single surface (no splits) and there is a default size then
        // we should resize to that default size.
        if case let .leaf(view) = surfaceTree.root {
            // If this is our first surface then our focused surface will be nil
            // so we force the focused surface to the leaf.
            focusedSurface = view
        }

        // Initialize our content view to the SwiftUI root
        let container = TerminalViewContainer {
            TerminalView(ghostty: ghostty, viewModel: self, delegate: self)
        }

        // Set the initial content size on the container so that
        // intrinsicContentSize returns the correct value immediately,
        // without waiting for @FocusedValue to propagate through the
        // SwiftUI focus chain.
        container.initialContentSize = focusedSurface?.initialSize

        // coastty owns tab switching/creation/closing/ordering itself now
        // (issue #12, coastty repo architecture note) instead of relying
        // on macOS's own `NSWindowTabGroup`: native tabs are titlebar
        // chrome that always spans the full window width, which rules out
        // a full-height sidebar, and there's no supported way to block
        // their drag-to-detach behavior (which we don't want anyway).
        // Disallowing tabbing entirely means this window never gets a
        // native tab strip and never joins/receives a tab group.
        window.tabbingMode = .disallowed

        // Seed our own Space list from whatever surface tree we were
        // constructed with — a single Space with a single starter tab —
        // unless an undo restore already populated this (see
        // `init(_:with:)`), in which case we keep it.
        if coasttySpaces.isEmpty {
            var seedTab = CoasttyTab(tree: surfaceTree, focusedSurfaceID: focusedSurface?.id)
            seedTab.inheritedTitleHint = pendingInheritedTitleHint
            pendingInheritedTitleHint = nil
            // Keeps the UI refreshing once this surface's shell reports
            // its real title/pwd, same as `coasttyNewTab`/`coasttyNewSpace`
            // already do for their own new surfaces.
            if let focusedSurface {
                coasttyObserveSurfaceIfNeeded(focusedSurface)
            }
            let startingPath = Self.startingFolderPath(focusedSurface?.pwd)
            let seedSpace = CoasttySpace(tabs: [seedTab], initialFolderName: Self.folderDisplayName(for: startingPath))
            coasttySpaces = [seedSpace]
            coasttyActiveSpaceIndex = 0

            // This window's tree is already installed rather than installed by
            // us, so nothing else names the tab it belongs to or reports the
            // Space holding it. Its pane follows once its process starts.
            coasttyShowingTabID = seedTab.id
            coasttyPendingSeedReport = [
                .spaceNew(id: seedSpace.id, name: seedSpace.name),
                .tabNew(spaceID: seedSpace.id, tabID: seedTab.id, name: ""),
            ]

            // `focusedSurface` is often still nil here, so the subscription
            // above it covers nothing. Without one the starter pane's shell
            // reports its pwd to no-one, and the refresh that would notice the
            // pane is now the daemon's never runs.
            coasttyObserveUnobservedSurfaces()
        } else {
            // A restored window had its active tab's tree installed for it, so nothing has yet named the tab that is showing; without it a split or a pane report lands in the tab's stored copy instead of the live tree.
            coasttyShowingTabID = coasttyTabs[safe: coasttyActiveTabIndex]?.id
        }
        CoasttySessionSaveScheduler.shared.markDirty()

        // Wrap the terminal content in coastty's sidebar split view: the
        // sidebar as one pane spanning the window's full height, coastty's
        // own tab bar + this window's existing terminal content as the
        // other (see `CoasttyTerminalSplitViewController`).
        let splitViewController = CoasttyTerminalSplitViewController(
            ghostty: ghostty,
            sidebarModel: makeSidebarModel(),
            tabBarModel: coasttyTabBarModel,
            terminalContent: container,
            onNewSpace: { [weak self] in self?.coasttyNewSpace() },
            onSelectSpace: { [weak self] id in
                guard let self, let index = self.coasttySpaces.firstIndex(where: { $0.id == id }) else { return }
                self.coasttyActivateSpace(at: index)
            },
            onCloseSpace: { [weak self] id in
                guard let self, let index = self.coasttySpaces.firstIndex(where: { $0.id == id }) else { return }
                self.coasttyCloseSpace(at: index)
            },
            onRenameSpace: { [weak self] id in
                self?.coasttyPromptSpaceTitle(for: id)
            },
            onMoveSpace: { [weak self] fromIndex, toIndex in
                self?.coasttyMoveSpace(fromIndex: fromIndex, toIndex: toIndex)
            },
            onSelectAgent: { [weak self] rowID in
                guard let self,
                      let destination = self.makeSidebarModel().agentDestination(for: rowID)
                else { return }
                self.coasttyActivateAgentDestination(destination)
            }
        )
        self.sidebarSplitViewController = splitViewController
        window.contentViewController = splitViewController

        // AppKit's default (`.automatic`) draws a 1px hairline under the
        // titlebar for windows whose content view controller is an
        // NSSplitViewController - true here (`CoasttyTerminalSplitViewController`),
        // showing up as a stray dark line right above coastty's own tab
        // bar. coastty already draws its own chrome; suppress AppKit's.
        window.titlebarSeparatorStyle = .none

        // Overrides whatever minimum size AppKit's Auto Layout would
        // otherwise derive from the content view's own constraint chain —
        // issue #12 (coastty repo): unlike stock Ghostty (where
        // TerminalViewContainer is window.contentView directly, with no
        // edge-pinning constraints of its own to derive a minimum FROM),
        // coastty's split view wraps it in several layers
        // (CoasttyTerminalPaneView, CoasttySplitView) that DO pin edges
        // with required-priority constraints, giving AppKit's automatic
        // constraint-based window-sizing a real minimum to compute and
        // enforce - which explicit minimumThickness/compression-resistance
        // tweaks on the split view items alone didn't override. Setting
        // this directly on the window is the actually-authoritative
        // override; width leaves room for the narrowest the sidebar can be
        // dragged to plus a sliver of terminal pane, height is a token
        // non-zero floor.
        window.contentMinSize = NSSize(width: CoasttySidebarView.minimumWidth + 40, height: 100)

        coasttyTabBarModel.onSelect = { [weak self] id in
            guard let self, let index = self.coasttyTabs.firstIndex(where: { $0.id == id }) else { return }
            self.coasttyActivateTab(at: index)
        }
        coasttyTabBarModel.onClose = { [weak self] id in
            guard let self, let index = self.coasttyTabs.firstIndex(where: { $0.id == id }) else { return }
            self.coasttyCloseTab(at: index, withConfirmation: true)
        }
        coasttyTabBarModel.onNew = { [weak self] in
            self?.coasttyNewTab()
        }
        // closeOtherTabs/closeTabsOnTheRight/promptTabTitle all act
        // relative to coasttyActiveTabIndex (or the focused tab, for
        // rename) rather than taking an explicit target - activating the
        // right-clicked tab first (a no-op if it's already active) makes
        // "other"/"to the right" resolve relative to the tab the context
        // menu was actually opened on, matching native tab-menu semantics.
        coasttyTabBarModel.onCloseOthers = { [weak self] id in
            guard let self, let index = self.coasttyTabs.firstIndex(where: { $0.id == id }) else { return }
            self.coasttyActivateTab(at: index)
            self.closeOtherTabs(self)
        }
        coasttyTabBarModel.onCloseToRight = { [weak self] id in
            guard let self, let index = self.coasttyTabs.firstIndex(where: { $0.id == id }) else { return }
            self.coasttyActivateTab(at: index)
            self.closeTabsOnTheRight(self)
        }
        coasttyTabBarModel.onRename = { [weak self] id in
            guard let self, let index = self.coasttyTabs.firstIndex(where: { $0.id == id }) else { return }
            self.coasttyActivateTab(at: index)
            self.promptTabTitle()
        }
        coasttyTabBarModel.onMove = { [weak self] fromIndex, toIndex in
            self?.coasttyMoveTab(fromIndex: fromIndex, toIndex: toIndex)
        }
        coasttyRefreshUI()

        // If we have a default size, we want to apply it.
        if let defaultSize {
            defaultSize.apply(to: window)

            if case .contentIntrinsicSize = defaultSize {
                if let screen = window.screen ?? NSScreen.main {
                    let frame = self.adjustForWindowPosition(frame: window.frame, on: screen)
                    window.setFrameOrigin(frame.origin)
                }
            }
        } else {
            // Issue #12 (coastty repo), Round 4 follow-up: `defaultSize` is
            // nil whenever we don't have a real size to apply - and, traced
            // into the ghostty core (`Surface.recomputeInitialSize`), that's
            // not a rare race-loser: `window-width`/`window-height` both
            // default to 0, and the core returns early without ever setting
            // `initialSize` at all unless one of those is explicitly
            // configured. So this branch is the ROUTINE path for any
            // default install, not an edge case - it used to mean doing
            // nothing here, leaving the window at whatever minimal size
            // SwiftUI's own layout produces before real content exists -
            // the actual "opens tiny" bug, hit on every default-config
            // launch, not occasionally.
            //
            // Apply a sane floor size synchronously instead: the window is
            // never tiny regardless of whether `initialSize` was ever going
            // to arrive, and for the minority of configs that DO set
            // window-width/window-height, the async re-check below (or
            // LastWindowPosition restoring a saved size in showWindow right
            // after this) still upgrades this floor to the precise size
            // once/if it lands - a minor adjustment, not the original
            // "starts broken" symptom.
            window.setContentSize(Self.fallbackWindowContentSize)
            if let screen = window.screen ?? NSScreen.main {
                let frame = self.adjustForWindowPosition(frame: window.frame, on: screen)
                window.setFrameOrigin(frame.origin)
            }
        }

        // Issue #12 (coastty repo), Round 4: "first launch sometimes opens
        // a tiny window that has to be manually resized." Root cause: the
        // synchronous `container.initialContentSize = focusedSurface?.initialSize`
        // above races the underlying ghostty core's own initial-size
        // callback (`Ghostty.App.setInitialSize`), which populates
        // `focusedSurface.initialSize` asynchronously — and, for anyone
        // who's explicitly configured `window-width`/`window-height`
        // (they default to 0, so most installs never trigger this at all —
        // see the fallback-size branch above for the routine case), this
        // re-check is what upgrades the floor to the precise configured
        // size if `initialSize` lands within one runloop turn. It only
        // narrows that specific race, doesn't close it (a slower cold start
        // could still miss this single re-check) — the fallback-size branch
        // above is what actually guarantees the window is never tiny,
        // regardless of this timing. For the common default-config case,
        // `focusedSurface?.initialSize` never becomes non-nil, so this
        // block runs every launch but is a permanent, harmless no-op there.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            container.initialContentSize = self.focusedSurface?.initialSize
            if let defaultSize = self.defaultSize {
                defaultSize.apply(to: window)
            }
        }

        // Apply any additional appearance-related properties to the new window. We
        // apply this based on the root config but change it later based on surface
        // config (see focused surface change callback).
        syncAppearance(.init(config))
    }

    /// Setup correct window frame before showing the window
    override func showWindow(_ sender: Any?) {
        guard let terminalWindow = window as? TerminalWindow else { return }

        // Set the initial window position. This must happen after the window
        // is fully set up (content view, toolbar, default size) so that
        // decorations added by subclass awakeFromNib (e.g. toolbar for tabs
        // style) don't change the frame after the position is restored.
        let originChanged = terminalWindow.setInitialWindowPosition(
            x: derivedConfig.windowPositionX,
            y: derivedConfig.windowPositionY,
        )
        let restored = LastWindowPosition.shared.restore(
            terminalWindow,
            origin: !originChanged,
            size: defaultSize == nil,
        )

        // If nothing is changed for the frame,
        // we should center the window
        if !originChanged, !restored {
            // This doesn't work in `windowDidLoad` somehow
            terminalWindow.center()
        }

        super.showWindow(sender)

        syncAppearance()
    }

    // AppKit's native tab bar "+" button, which no longer exists for this
    // window (`window.tabbingMode = .disallowed` — see `windowDidLoad`).
    // Kept as a defensive redirect to coastty's own new-tab action in
    // case AppKit still invokes it through some other path.
    override func newWindowForTab(_ sender: Any?) {
        coasttyNewTab()
    }

    // MARK: NSWindowDelegate

    // Issue #12 (coastty repo): this used to route through
    // `TabGroupCloseCoordinator` to disambiguate "close one tab" vs. "close
    // the whole window" by counting simultaneous close requests across
    // `window.tabGroup.windows` — needed because AppKit's native tab close
    // button (the "red X" on a tab) and a window's own traffic-light close
    // button both funnel through `windowShouldClose`. Native tabbing is now
    // always disallowed (`window.tabbingMode = .disallowed` in
    // `windowDidLoad`), so `window.tabGroup` is always nil and there is
    // nothing left to coordinate: every coastty window hosts exactly one
    // native window, and "close the window" here always means "close its
    // active coastty tab" — which itself already closes the whole window
    // when it's the last tab (see `coasttyCloseTab(at:withConfirmation:)`).
    // This mirrors `closeTab(nil)`, the same path ⌘W (`onCloseTab`) uses.
    override func windowShouldClose(_ sender: NSWindow) -> Bool {
        closeTab(nil)

        // We will always explicitly close (the tab, and transitively the
        // window if it was the last tab) using the above.
        return false
    }

    override func windowWillClose(_ notification: Notification) {
        super.windowWillClose(notification)
        cancelPendingInitialPresentation()
        self.relabelTabs()
        CoasttySessionSaveScheduler.shared.markDirty()
        Self.coasttyReportWindows(closing: self)
        CoasttyFocusReport.clear(from: self)

        // If we remove a window, we reset the cascade point to the key window so that
        // the next window cascade's from that one.
        if let focusedWindow = NSApplication.shared.keyWindow {
            // If we are NOT the focused window, then we are a tabbed window. If we
            // are closing a tabbed window, we want to set the cascade point to be
            // the next cascade point from this window.
            if focusedWindow != window {
                // The cascadeTopLeft call below should NOT move the window. Starting with
                // macOS 15, we found that specifically when used with the new window snapping
                // features of macOS 15, this WOULD move the frame. So we keep track of the
                // old frame and restore it if necessary. Issue:
                // https://github.com/ghostty-org/ghostty/issues/2565
                let oldFrame = focusedWindow.frame

                Self.lastCascadePoint = focusedWindow.cascadeTopLeft(from: .zero)

                if focusedWindow.frame != oldFrame {
                    focusedWindow.setFrame(oldFrame, display: true)
                }

                return
            }

            // If we are the focused window, then we set the last cascade point to
            // our own frame so that it shows up in the same spot.
            let frame = focusedWindow.frame
            Self.lastCascadePoint = NSPoint(x: frame.minX, y: frame.maxY)
        }
    }

    override func windowDidBecomeKey(_ notification: Notification) {
        super.windowDidBecomeKey(notification)
        self.relabelTabs()
        terminalViewContainer?.updateGlassTintOverlay(isKeyWindow: true)

        // Regaining window focus counts as looking at the active tab again
        // — mirrors herdr's `OuterFocusGained` handling, which calls
        // `mark_active_tab_seen()` for the same reason (`src/app/runtime.rs`).
        if let activeTab = coasttyTabs[safe: coasttyActiveTabIndex] {
            coasttyMarkSeen(activeTab)
            coasttyRefreshUI()
        }
    }

    override func windowDidResignKey(_ notification: Notification) {
        super.windowDidResignKey(notification)
        terminalViewContainer?.updateGlassTintOverlay(isKeyWindow: false)
        coasttySyncViewed()
    }

    override func windowDidMove(_ notification: Notification) {
        super.windowDidMove(notification)

        // Whenever we move save our last position for the next start.
        LastWindowPosition.shared.save(window)
    }

    override func windowDidResize(_ notification: Notification) {
        super.windowDidResize(notification)

        // Whenever we resize save our last position and size for the next start.
        LastWindowPosition.shared.save(window)
    }

    func windowDidBecomeMain(_ notification: Notification) {
        // Whenever we get focused, use that as our last window position for
        // restart. This differs from Terminal.app but matches iTerm2 behavior
        // and I think its sensible.
        LastWindowPosition.shared.save(window)

        // Remember our last main
        Self.lastMain = self
    }

    // MARK: First Responder

    @IBAction func newWindow(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.newWindow(surface: surface)
    }

    @IBAction func newTab(_ sender: Any?) {
        coasttyNewTab()
    }

    @IBAction func closeTab(_ sender: Any?) {
        coasttyCloseTab(at: coasttyActiveTabIndex, withConfirmation: true)
    }

    @IBAction func closeSpace(_ sender: Any?) {
        coasttyCloseSpace(at: coasttyActiveSpaceIndex)
    }

    @IBAction func closeOtherTabs(_ sender: Any?) {
        // If we only have one tab then we have no other tabs to close.
        guard coasttyTabs.count > 1 else { return }

        // Check if we have to confirm close: any tab other than the active
        // one (backgrounded tabs included) with a running process.
        let needsConfirm = coasttyTabs.enumerated().contains { index, tab in
            index != coasttyActiveTabIndex && tab.needsConfirmQuit
        }

        guard needsConfirm else {
            self.closeOtherTabsImmediately()
            return
        }

        confirmClose(
            messageText: "Close Other Tabs?",
            informativeText: "At least one other tab still has a running process. If you close the tab the process will be killed."
        ) {
            self.closeOtherTabsImmediately()
        }
    }

    @IBAction func closeTabsOnTheRight(_ sender: Any?) {
        let tabsToClose = coasttyTabs.enumerated().filter { $0.offset > coasttyActiveTabIndex }
        guard !tabsToClose.isEmpty else { return }

        let needsConfirm = tabsToClose.contains { _, tab in tab.needsConfirmQuit }

        if !needsConfirm {
            self.closeTabsOnTheRightImmediately()
            return
        }

        confirmClose(
            messageText: "Close Tabs on the Right?",
            informativeText: "At least one tab to the right still has a running process. If you close the tab the process will be killed."
        ) {
            self.closeTabsOnTheRightImmediately()
        }
    }

    @IBAction func returnToDefaultSize(_ sender: Any?) {
        guard let window, let defaultSize else { return }
        defaultSize.apply(to: window)
    }

    @IBAction override func closeWindow(_ sender: Any?) {
        // Check every Space this window owns, and every tab within each of
        // those, for confirmation — not just the active Space's active tab
        // — a backgrounded Space/tab's running process shouldn't be
        // silently killed without asking either.
        coasttySnapshotActiveTab()
        guard coasttySpaces.contains(where: { $0.needsConfirmQuit }) else {
            closeWindowImmediately()
            return
        }

        confirmClose(
            messageText: "Close Window?",
            informativeText: "All terminal sessions in this window will be terminated.",
        ) {
            self.closeWindowImmediately()
        }
    }

    @IBAction func toggleGhosttyFullScreen(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.toggleFullscreen(surface: surface)
    }

    @IBAction func toggleTerminalInspector(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.toggleTerminalInspector(surface: surface)
    }

    // MARK: - TerminalViewDelegate

    override func focusedSurfaceDidChange(to: Ghostty.SurfaceView?) {
        super.focusedSurfaceDidChange(to: to)

        // We always cancel our event listener
        surfaceAppearanceCancellables.removeAll()

        // When our focus changes, we update our window appearance based on the
        // currently focused surface.
        guard let focusedSurface else { return }
        syncAppearance(focusedSurface.derivedConfig)

        // We also want to get notified of certain changes to update our appearance.
        focusedSurface.$derivedConfig
            .dropFirst()
            .sink { [weak self, weak focusedSurface] _ in self?.syncAppearanceOnPropertyChange(focusedSurface) }
            .store(in: &surfaceAppearanceCancellables)
        focusedSurface.$backgroundColor
            .dropFirst()
            .sink { [weak self, weak focusedSurface] _ in self?.syncAppearanceOnPropertyChange(focusedSurface) }
            .store(in: &surfaceAppearanceCancellables)

    }

    /// Subscribes to a surface's title/pwd/agent state for the rest of its
    /// lifetime and refreshes coastty's tab bar/sidebar whenever any of
    /// them changes — most notably, the first time its shell reports a
    /// real title/pwd shortly after launch (a brand-new surface has
    /// neither yet, so starts out on the "Terminal" placeholder — see
    /// `CoasttyTab.title`), and every time the agent-detection engine
    /// publishes a new agent state for it.
    ///
    /// Deliberately NOT hung off `focusedSurfaceDidChange` (tried first;
    /// confirmed by testing not to reliably land in time for a
    /// freshly-created tab — that delegate callback is driven by SwiftUI's
    /// own `.onChange(of: focusedSurface)` in `TerminalView`, whose exact
    /// timing relative to a brand-new surface's shell startup isn't
    /// guaranteed). Subscribing here, at the exact moment the surface is
    /// created — before the event loop can even tick, let alone the shell
    /// report anything — is the only timing that's actually guaranteed
    /// correct. Call this at every point a `Ghostty.SurfaceView` is
    /// created for a coastty tab (see `coasttyNewTab`/`coasttyNewSpace`).
    /// Cancellables are never proactively removed; they just stop firing
    /// (harmlessly) once the surface itself deallocates.
    /// Surfaces already wired up by `coasttyObserveTitlePwdAndAgentState`.
    /// A surface can be reached from more than one place, and subscribing
    /// twice would run every refresh twice.
    private var coasttyObservedSurfaceIDs: Set<UUID> = []

    /// Subscribes every surface this window can currently reach that isn't
    /// observed yet.
    ///
    /// `coasttyNewTab`/`coasttyNewSpace` only ever subscribe the one
    /// surface they just built, so a surface born any other way - a split
    /// within an existing tab, a window restored with its Spaces already
    /// populated, a starter tab whose `focusedSurface` wasn't assigned yet
    /// at window-setup time - was never observed. Its agent state still
    /// arrived and still updated the model; nothing just asked the UI to
    /// redraw, so the icon only moved when some unrelated event happened to
    /// call `coasttyRefreshUI()`.
    private func coasttyObserveUnobservedSurfaces() {
        for space in coasttySpaces {
            for tab in space.tabs {
                for surface in tab.tree {
                    coasttyObserveSurfaceIfNeeded(surface)
                }
            }
        }

        // The active tab's live tree isn't folded back into `coasttySpaces`
        // until the next `coasttySnapshotActiveTab()`, so a just-created
        // split only exists here.
        for surface in surfaceTree {
            coasttyObserveSurfaceIfNeeded(surface)
        }
    }

    private func coasttyObserveSurfaceIfNeeded(_ surface: Ghostty.SurfaceView) {
        guard !coasttyObservedSurfaceIDs.contains(surface.id) else { return }
        coasttyObservedSurfaceIDs.insert(surface.id)
        coasttyObserveTitlePwdAndAgentState(for: surface)
    }

    /// `@Published` emits from `willSet`, so a sink runs *before* the
    /// property it fired for has been written. Every one of these
    /// subscriptions ends in `coasttyRefreshUI()`, which rebuilds the models
    /// by reading the current values straight off the surfaces - so
    /// delivering synchronously means the refresh reads the state it is
    /// reacting to as its previous value, leaving the UI one update behind
    /// until some unrelated refresh happens along.
    ///
    /// Hopping to the next main-queue turn lets `willSet` finish first, so
    /// the refresh sees what it was notified about.
    private func coasttyObserveTitlePwdAndAgentState(for surface: Ghostty.SurfaceView) {
        surface.$title
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.coasttyRefreshUI() }
            .store(in: &coasttyTabRefreshCancellables)
        surface.$pwd
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.coasttyRefreshUI() }
            .store(in: &coasttyTabRefreshCancellables)
        surface.$coasttyAgentState
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak surface] change in
                guard let self, let surface else { return }
                self.coasttyHandleAgentStateChange(change?.state ?? .unknown, for: surface)
            }
            .store(in: &coasttyTabRefreshCancellables)
    }

    /// Applies one pane's freshly detected agent state, mirroring herdr's
    /// `apply_pane_state_change` (`src/app/actions.rs`): any non-Idle state
    /// marks the pane seen (nothing to acknowledge yet), and a genuine
    /// completion transition (Working/Blocked -> Idle) sets `seen` to
    /// whether the pane's tab was actually being looked at when it
    /// happened — the active tab of the active Space, in a key window
    /// (mirrors `active_tab_suppresses_notifications`/`pane_is_in_active_tab`
    /// in the same file). Anything else (e.g. already Idle, or Idle after
    /// Unknown) leaves `seen` untouched, same as herdr.
    private func coasttyHandleAgentStateChange(
        _ state: Ghostty.Action.CoasttyAgentStateChange.State,
        for surface: Ghostty.SurfaceView
    ) {
        // The daemon owns this pane and has already decided seen and recency.
        if surface.coasttyAgentState?.hostAttention != nil {
            coasttyRefreshUI()
            return
        }

        let previous = coasttyPanePreviousAgentState[surface.id] ?? .unknown
        coasttyPanePreviousAgentState[surface.id] = state

        if state != .idle {
            coasttyPaneSeen[surface.id] = true
        } else if previous == .working || previous == .blocked {
            // No window is realistically nil here — a controller always
            // has one once its content has loaded — but `?? true` (not
            // `?? false`) is still the deliberate default: herdr's own
            // equivalent (`outer_terminal_focus: Option<bool>`) treats
            // "focus unknown" as focused (`!= Some(false)`), the same
            // conservative direction, not this file's unrelated
            // `preferredParent` check above (whose "unknown" case means
            // "not this one, keep looking," not "focused or not").
            let isKeyWindow = window?.isKeyWindow ?? true
            coasttyPaneSeen[surface.id] = coasttyPaneIsInActiveTab(surface.id) && isKeyWindow
        }

        coasttyUpdateStatus(for: surface, state: state, seen: coasttyPaneSeen[surface.id] ?? true)
        coasttyRefreshUI()
    }

    /// Whether `surfaceID` belongs to the active tab of the active Space —
    /// the only tab actually visible right now. Mirrors herdr's
    /// `pane_is_in_active_tab` (`src/app/actions.rs`), which likewise
    /// requires both: the pane's own Space being the one on screen, and
    /// its tab being the active one within it.
    private func coasttyPaneIsInActiveTab(_ surfaceID: UUID) -> Bool {
        guard let activeTab = coasttyTabs[safe: coasttyActiveTabIndex] else { return false }
        return activeTab.tree.contains(where: { $0.id == surfaceID })
    }

    /// Tells each pane whether the user is looking at it - in the active tab, in the key window, the same test seen uses - so the daemon marks it seen for every client.
    private func coasttySyncViewed() {
        let isKeyWindow = window?.isKeyWindow ?? false
        let viewed: Set<UUID> = isKeyWindow ? Set(surfaceTree.map(\.id)) : []
        if viewed == coasttyViewedSurfaceIDs { return }

        // The live tree first: a split just made in the showing tab is not in its stored tree yet.
        let surfaces = Array(surfaceTree) + coasttySpaces.flatMap { space in space.tabs.flatMap { Array($0.tree) } }
        var handled: Set<UUID> = []
        for surface in surfaces {
            // A pane reached both ways is told once.
            if !handled.insert(surface.id).inserted { continue }

            // Only panes whose answer changed.
            let isViewed = viewed.contains(surface.id)
            if isViewed == coasttyViewedSurfaceIDs.contains(surface.id) { continue }

            guard let handle = surface.surface else { continue }
            ghostty_surface_set_viewed(handle, isViewed)
        }
        coasttyViewedSurfaceIDs = viewed
    }

    /// Tells the daemon which Space, tab and pane this window shows: while it is the key window, or while coastty is in the background and this is the window the user was last in. Any other window leaves the report alone.
    private func coasttyReportFocus() {
        let lastIn = !NSApplication.shared.isActive && CoasttyFocusReport.reporter == ObjectIdentifier(self)
        guard window?.isKeyWindow == true || lastIn else { return }
        guard let space = coasttySpaces[safe: coasttyActiveSpaceIndex],
              let tab = coasttyTabs[safe: coasttyActiveTabIndex] else { return }
        CoasttyFocusReport.send(from: self, spaceID: space.id, tabID: tab.id, paneID: focusedSurface?.hostPaneID ?? "")
    }

    /// Marks every pane in `tab` as seen — mirrors herdr's
    /// `Workspace::switch_tab` marking a newly-active tab's panes seen
    /// (`src/workspace.rs`) and `AppState::mark_active_tab_seen` doing the
    /// same for the already-active tab when outer focus is regained
    /// (`src/app/actions.rs`).
    private func coasttyMarkSeen(_ tab: CoasttyTab) {
        for surface in tab.tree {
            coasttyPaneSeen[surface.id] = true
            coasttyUpdateStatus(for: surface, state: surface.coasttyDetectedAgentState, seen: true)
        }
    }

    /// Maps a raw detected `(state, seen)` pair to the sidebar/tab-bar's
    /// icon vocabulary — mirrors herdr's `pane_agent_status`
    /// (`src/app/api_helpers.rs`): Idle+unseen is "done" (green, not yet
    /// acknowledged), Idle+seen is the fully-resolved "idle" (checkmark),
    /// Working and Blocked are unconditional, and Unknown (no agent
    /// identified) has no status at all.
    private func coasttyAgentStatus(
        state: Ghostty.Action.CoasttyAgentStateChange.State,
        seen: Bool
    ) -> CoasttyAgentStatus {
        switch state {
        case .blocked: return .blocked
        case .working: return .working
        case .idle: return seen ? .idle : .done
        case .unknown: return .unknown
        }
    }

    /// What `surface` shows: the daemon's attention state for a pane it owns, otherwise this window's own fold of state and seen.
    private func coasttyAttention(of surface: Ghostty.SurfaceView) -> CoasttyAgentStatus {
        if let hostAttention = surface.coasttyAgentState?.hostAttention { return hostAttention }
        return coasttyAgentStatus(state: surface.coasttyDetectedAgentState, seen: coasttyPaneSeen[surface.id] ?? true)
    }

    /// Computes `surface`'s effective status from `(state, seen)` and records it via `coasttyNoteStatusChange`.
    private func coasttyUpdateStatus(
        for surface: Ghostty.SurfaceView,
        state: Ghostty.Action.CoasttyAgentStateChange.State,
        seen: Bool
    ) {
        coasttyNoteStatusChange(on: surface, status: coasttyAgentStatus(state: state, seen: seen))
    }

    /// Reports `surface`'s current status to `agent-detection`, which bumps
    /// its recency sequence only if the status actually changed - see
    /// `coasttyStatusChangeSeq(for:)`, which reads that sequence back.
    private func coasttyNoteStatusChange(on surface: Ghostty.SurfaceView, status: CoasttyAgentStatus) {
        guard let handle = surface.surface else { return }
        ghostty_surface_agent_status_note(handle, status.cValue)
    }

    /// This tab's agent status, aggregated across its own panes —
    /// "whatever is most pressing wins," mirroring herdr's
    /// `tab_attention_priority` (`src/app/api_helpers.rs`) and
    /// `pane_attention_priority` (`src/workspace/aggregate.rs`), which agree
    /// on the same ordering `agent-detection`'s `AgentStatus.priority` now
    /// owns.
    private func coasttyAgentStatus(for tab: CoasttyTab) -> CoasttyAgentStatus {
        let statuses = tab.tree.map { coasttyAttention(of: $0) }
        return statuses.max { coasttyStatusPriority($0) < coasttyStatusPriority($1) } ?? .unknown
    }

    /// `status`'s ranking for picking which one is most pressing - read from
    /// `agent-detection` rather than reimplemented here.
    private func coasttyStatusPriority(_ status: CoasttyAgentStatus) -> Int {
        Int(ghostty_agent_status_priority(status.cValue))
    }

    /// `surface`'s current recency stamp, as last set by
    /// `coasttyNoteStatusChange` - 0 before its first status note.
    private func coasttyStatusChangeSeq(for surface: Ghostty.SurfaceView) -> Int {
        guard let handle = surface.surface else { return 0 }
        return Int(ghostty_surface_agent_status_change_seq(handle))
    }

    /// This tab's agent display name, or nil if no pane in it has an
    /// identified agent. Coastty currently detects only Claude (the
    /// `agent-detection` Zig port has a single `Agent` case), so there's
    /// only one label to show — once a second agent joins, this needs the
    /// identified agent's own label from the detection engine rather than
    /// a hardcoded name.
    private func coasttyAgentName(for tab: CoasttyTab) -> String? {
        // Agent presence comes from the detection's own agent field, not
        // from `state`: during the startup grace window the agent is known
        // and its state is still `.unknown`, and reading `state` here would
        // hide the row for that whole period.
        for surface in tab.tree {
            if let agent = surface.coasttyDetectedAgent { return agent.displayName }
        }
        return nil
    }

    /// Replicates Ghostty's own `tab-inherit-working-directory` behavior
    /// (`apprt/surface.zig`'s `newConfig`/`shouldInheritWorkingDirectory`,
    /// checked against `Ghostty.Config.tabInheritWorkingDirectory`) for
    /// coastty's own tab creation, which — being driven directly from
    /// Swift rather than dispatched through the core's `new_tab` action —
    /// doesn't go through that mechanism at all otherwise and would
    /// silently ignore the setting.
    ///
    /// If the caller already specified an explicit `workingDirectory`
    /// (e.g. a dock-drop "open in this folder" action), that's respected
    /// untouched — this only fills in the gap for the plain "just make me
    /// a new tab" case, exactly like the real mechanism only overrides
    /// when building a fresh config from scratch.
    private func coasttyInheritedWorkingDirectoryConfig(
        _ baseConfig: Ghostty.SurfaceConfiguration?
    ) -> Ghostty.SurfaceConfiguration? {
        if let baseConfig, baseConfig.workingDirectory != nil {
            return baseConfig
        }
        guard ghostty.config.tabInheritWorkingDirectory,
              let pwd = focusedSurface?.pwd, !pwd.isEmpty else {
            return baseConfig
        }

        var config = baseConfig ?? Ghostty.SurfaceConfiguration()
        config.workingDirectory = pwd
        return config
    }

    private func syncAppearanceOnPropertyChange(_ surface: Ghostty.SurfaceView?) {
        guard let surface else { return }
        DispatchQueue.main.async { [weak self, weak surface] in
            guard let surface else { return }
            guard let self else { return }
            guard self.focusedSurface == surface else { return }
            self.syncAppearance(surface.derivedConfig)
        }
    }

    /// Moves a tab from `fromIndex` to `toIndex` within the active Space - the shared primitive behind the `move_tab` keybind and the tab bar's drag-to-reorder.
    func coasttyMoveTab(fromIndex: Int, toIndex: Int) {
        coasttyMoveTab(inSpaceAt: coasttyActiveSpaceIndex, fromIndex: fromIndex, toIndex: toIndex)
    }

    /// Moves a tab from `fromIndex` to `toIndex` within the Space at `spaceIndex`, whether or not it is showing.
    private func coasttyMoveTab(inSpaceAt spaceIndex: Int, fromIndex: Int, toIndex: Int) {
        // A request can race a Space closing.
        guard coasttySpaces.indices.contains(spaceIndex) else { return }

        // Snapshot before computing the reorder, not after, or a stale pre-snapshot copy overwrites it below.
        coasttySnapshotActiveTab()

        let space = coasttySpaces[spaceIndex]
        let activeTabID = space.tabs[safe: space.activeTabIndex]?.id
        guard let result = Self.coasttyReordered(space.tabs, fromIndex: fromIndex, toIndex: toIndex, activeID: activeTabID) else { return }

        let movedTabID = result.items[toIndex].id
        coasttySpaces[spaceIndex].tabs = result.items
        if let activeIndex = result.activeIndex {
            coasttySpaces[spaceIndex].activeTabIndex = activeIndex
        }
        coasttyRefreshUI()
        CoasttySessionSaveScheduler.shared.markDirty()
        CoasttyModelSync.send(.tabMove(id: movedTabID, to: toIndex))
    }

    /// Mirrors `coasttyMoveTab(fromIndex:toIndex:)` for the `move_space` keybind and the sidebar's drag-to-reorder.
    func coasttyMoveSpace(fromIndex: Int, toIndex: Int) {
        guard let movedSpaceID = coasttyReorderSpaces(fromIndex: fromIndex, toIndex: toIndex) else { return }
        CoasttyModelSync.send(.spaceMove(id: movedSpaceID, to: toIndex))
    }

    /// Moves a Space within this window's own order without telling the daemon, returning its id, or nil when out of range or already there.
    @discardableResult
    private func coasttyReorderSpaces(fromIndex: Int, toIndex: Int) -> UUID? {
        // See coasttyMoveTab(fromIndex:toIndex:) above - same reasoning.
        coasttySnapshotActiveTab()

        let activeSpaceID = coasttySpaces[safe: coasttyActiveSpaceIndex]?.id
        guard let result = Self.coasttyReordered(coasttySpaces, fromIndex: fromIndex, toIndex: toIndex, activeID: activeSpaceID) else { return nil }

        coasttySpaces = result.items
        if let activeIndex = result.activeIndex {
            coasttyActiveSpaceIndex = activeIndex
        }
        coasttyRefreshUI()
        CoasttySessionSaveScheduler.shared.markDirty()
        return result.items[toIndex].id
    }

    /// Moves `items[fromIndex]` to `toIndex`, returning the reordered array and where `activeID` (tracked by identity, not index) ended up - nil if the indices are out of range or a no-op.
    static func coasttyReordered<T: Identifiable>(_ items: [T], fromIndex: Int, toIndex: Int, activeID: T.ID?) -> (items: [T], activeIndex: Int?)? {
        guard items.indices.contains(fromIndex), items.indices.contains(toIndex), fromIndex != toIndex else { return nil }

        var reordered = items
        let moved = reordered.remove(at: fromIndex)
        reordered.insert(moved, at: toIndex)

        let activeIndex = activeID.flatMap { id in reordered.firstIndex { $0.id == id } }
        return (reordered, activeIndex)
    }

    // MARK: - Notifications

    @objc private func onMoveTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }

        // Get the move action
        guard let action = notification.userInfo?[Notification.Name.GhosttyMoveTabKey] as? Ghostty.Action.MoveTab else { return }
        guard action.amount != 0 else { return }

        let selectedIndex = coasttyActiveTabIndex
        guard coasttyTabs.indices.contains(selectedIndex) else { return }

        // Determine the final index we want to move our tab to.
        let finalIndex: Int
        if action.amount < 0 {
            finalIndex = selectedIndex - min(selectedIndex, -action.amount)
        } else {
            let remaining = coasttyTabs.count - 1 - selectedIndex
            finalIndex = selectedIndex + min(remaining, action.amount)
        }

        coasttyMoveTab(fromIndex: selectedIndex, toIndex: finalIndex)
    }

    @objc private func onMoveSpace(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }

        // Get the move action
        guard let action = notification.userInfo?[Notification.Name.GhosttyMoveSpaceKey] as? Ghostty.Action.MoveSpace else { return }
        guard action.amount != 0 else { return }

        let selectedIndex = coasttyActiveSpaceIndex
        guard coasttySpaces.indices.contains(selectedIndex) else { return }

        // Determine the final index we want to move our Space to.
        let finalIndex: Int
        if action.amount < 0 {
            finalIndex = selectedIndex - min(selectedIndex, -action.amount)
        } else {
            let remaining = coasttySpaces.count - 1 - selectedIndex
            finalIndex = selectedIndex + min(remaining, action.amount)
        }

        coasttyMoveSpace(fromIndex: selectedIndex, toIndex: finalIndex)
    }

    @objc private func onGotoTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }

        // Get the tab index from the notification
        guard let tabEnumAny = notification.userInfo?[Ghostty.Notification.GotoTabKey] else { return }
        guard let tabEnum = tabEnumAny as? ghostty_action_goto_tab_e else { return }
        let tabIndex: Int32 = tabEnum.rawValue

        guard !coasttyTabs.isEmpty else { return }

        // This will be the index we want to actually go to
        let finalIndex: Int

        // An index that is invalid is used to signal some special values.
        if tabIndex <= 0 {
            let selectedIndex = coasttyActiveTabIndex

            if tabIndex == GHOSTTY_GOTO_TAB_PREVIOUS.rawValue {
                finalIndex = selectedIndex == 0 ? coasttyTabs.count - 1 : selectedIndex - 1
            } else if tabIndex == GHOSTTY_GOTO_TAB_NEXT.rawValue {
                finalIndex = selectedIndex == coasttyTabs.count - 1 ? 0 : selectedIndex + 1
            } else if tabIndex == GHOSTTY_GOTO_TAB_LAST.rawValue {
                finalIndex = coasttyTabs.count - 1
            } else {
                return
            }
        } else {
            // The configured value is 1-indexed.
            guard tabIndex >= 1 else { return }

            // If our index is outside our boundary then we use the max
            finalIndex = min(Int(tabIndex - 1), coasttyTabs.count - 1)
        }

        guard finalIndex >= 0 else { return }
        coasttyActivateTab(at: finalIndex)
    }

    @objc private func onGotoSpace(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }

        // Get the Space index from the notification
        guard let spaceEnumAny = notification.userInfo?[Ghostty.Notification.GotoSpaceKey] else { return }
        guard let spaceEnum = spaceEnumAny as? ghostty_action_goto_space_e else { return }
        let spaceIndex: Int32 = spaceEnum.rawValue

        guard !coasttySpaces.isEmpty else { return }

        // This will be the index we want to actually go to
        let finalIndex: Int

        // An index that is invalid is used to signal some special values.
        if spaceIndex <= 0 {
            let selectedIndex = coasttyActiveSpaceIndex

            if spaceIndex == GHOSTTY_GOTO_SPACE_PREVIOUS.rawValue {
                finalIndex = selectedIndex == 0 ? coasttySpaces.count - 1 : selectedIndex - 1
            } else if spaceIndex == GHOSTTY_GOTO_SPACE_NEXT.rawValue {
                finalIndex = selectedIndex == coasttySpaces.count - 1 ? 0 : selectedIndex + 1
            } else if spaceIndex == GHOSTTY_GOTO_SPACE_LAST.rawValue {
                finalIndex = coasttySpaces.count - 1
            } else {
                return
            }
        } else {
            // The configured value is 1-indexed.
            guard spaceIndex >= 1 else { return }

            // If our index is outside our boundary then we use the max
            finalIndex = min(Int(spaceIndex - 1), coasttySpaces.count - 1)
        }

        guard finalIndex >= 0 else { return }
        coasttyActivateSpace(at: finalIndex)
    }

    @objc private func onNewSpace(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }

        _ = coasttyNewSpace()
    }

    /// Jumps to (or cycles within) the agent-bearing panes needing attention; a silent no-op when there are none.
    @objc private func onGotoUrgentAgent(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }

        guard let destination = makeSidebarModel().urgentAgentDestination(focusedSurfaceID: focusedSurface?.id)
        else { return }

        coasttyActivateAgentDestination(destination)
    }

    /// Cycles to the previous agent-bearing pane, in the sidebar's own priority+recency order; a silent no-op with no agent-bearing panes at all.
    @objc private func onPreviousAgent(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }

        guard let destination = makeSidebarModel().previousAgentDestination(focusedSurfaceID: focusedSurface?.id)
        else { return }

        coasttyActivateAgentDestination(destination)
    }

    /// Same as `onPreviousAgent`, the other direction.
    @objc private func onNextAgent(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }

        guard let destination = makeSidebarModel().nextAgentDestination(focusedSurfaceID: focusedSurface?.id)
        else { return }

        coasttyActivateAgentDestination(destination)
    }

    @objc private func onCloseTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeTab(self)
    }

    @objc private func onCloseOtherTabs(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeOtherTabs(self)
    }

    @objc private func onCloseTabsOnTheRight(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeTabsOnTheRight(self)
    }

    @objc private func onCloseSpace(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        coasttyCloseSpace(at: coasttyActiveSpaceIndex)
    }

    @objc private func onCloseOtherSpaces(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeOtherSpaces()
    }

    @objc private func onCloseSpacesOnTheRight(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeSpacesOnTheRight()
    }

    @objc private func onCloseWindow(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeWindow(self)
    }

    @objc private func onResetWindowSize(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        returnToDefaultSize(nil)
    }

    @objc private func onToggleFullscreen(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }

        // Get the fullscreen mode we want to toggle
        let fullscreenMode: FullscreenMode
        if let any = notification.userInfo?[Ghostty.Notification.FullscreenModeKey],
           let mode = any as? FullscreenMode {
            fullscreenMode = mode
        } else {
            Ghostty.logger.warning("no fullscreen mode specified or invalid mode, doing nothing")
            return
        }

        toggleFullscreen(mode: fullscreenMode)
    }

    struct DerivedConfig {
        let backgroundColor: Color
        let macosWindowButtons: Ghostty.MacOSWindowButtons
        let macosTitlebarStyle: Ghostty.Config.MacOSTitlebarStyle
        let maximize: Bool
        let windowPositionX: Int16?
        let windowPositionY: Int16?

        init() {
            self.backgroundColor = Color(NSColor.windowBackgroundColor)
            self.macosWindowButtons = .visible
            self.macosTitlebarStyle = .default
            self.maximize = false
            self.windowPositionX = nil
            self.windowPositionY = nil
        }

        init(_ config: Ghostty.Config) {
            self.backgroundColor = config.backgroundColor
            self.macosWindowButtons = config.macosWindowButtons
            self.macosTitlebarStyle = config.macosTitlebarStyle
            self.maximize = config.maximize
            self.windowPositionX = config.windowPositionX
            self.windowPositionY = config.windowPositionY
        }
    }
}

// MARK: NSMenuItemValidation

extension TerminalController {
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(closeTabsOnTheRight):
            return coasttyActiveTabIndex < coasttyTabs.count - 1

        case #selector(returnToDefaultSize):
            guard let window else { return false }

            // Native fullscreen windows can't revert to default size.
            if window.styleMask.contains(.fullScreen) {
                return false
            }

            // If we're fullscreen at all then we can't change size
            if fullscreenStyle?.isFullscreen ?? false {
                return false
            }

            // If our window is already the default size or we don't have a
            // default size, then disable.
            return defaultSize?.isChanged(for: window) ?? false

        default:
            return super.validateMenuItem(item)
        }
    }
}

// MARK: Default Size

extension TerminalController {
    /// The possible default sizes for a terminal. The size can't purely be known as a
    /// window frame because if we set `window-width/height` then it is based
    /// on content size.
    enum DefaultSize {
        /// A frame, set with `window.setFrame`
        case frame(NSRect)

        /// A content size, set with `window.setContentSize`
        case contentIntrinsicSize

        func isChanged(for window: NSWindow) -> Bool {
            switch self {
            case .frame(let rect):
                return window.frame != rect
            case .contentIntrinsicSize:
                guard let view = window.contentView else {
                    return false
                }

                return view.frame.size != view.intrinsicContentSize
            }
        }

        func apply(to window: NSWindow) {
            switch self {
            case .frame(let rect):
                window.setFrame(rect, display: true)
            case .contentIntrinsicSize:
                // Issue #12 (coastty repo), Round 4: guard against applying
                // a nonsense (`NSView.noIntrinsicMetric`, i.e. -1x-1) size —
                // this used to be unreachable when the terminal container
                // was the window's content view directly, but the coastty
                // split view's own `intrinsicContentSize` chain
                // (`CoasttySplitView` -> `CoasttyTerminalPaneView` ->
                // the terminal content) can legitimately still be
                // unresolved this early. Applying it as-is previously
                // produced a "tiny window" instead of just doing nothing.
                guard let size = window.contentView?.intrinsicContentSize,
                      size.width != NSView.noIntrinsicMetric,
                      size.height != NSView.noIntrinsicMetric else {
                    return
                }

                window.setContentSize(size)
                window.constrainToScreen()
            }
        }
    }

    /// A deliberately generic "reasonable terminal window" size, used only
    /// as a synchronous floor when the real size isn't known yet (see
    /// `windowDidLoad`'s `defaultSize == nil` branch). Not meant to match
    /// any particular font/column/row configuration precisely - just large
    /// enough that the window never reads as broken while the real size is
    /// still in flight.
    private static let fallbackWindowContentSize = NSSize(width: 900, height: 600)

    private var defaultSize: DefaultSize? {
        if derivedConfig.maximize, let screen = window?.screen ?? NSScreen.main {
            // Maximize takes priority, we take up the full screen we're on.
            return .frame(screen.visibleFrame)
        } else if focusedSurface?.initialSize != nil {
            // Initial size as requested by the configuration (e.g. `window-width`)
            // takes next priority.
            return .contentIntrinsicSize
        } else {
            return nil
        }
    }
}
