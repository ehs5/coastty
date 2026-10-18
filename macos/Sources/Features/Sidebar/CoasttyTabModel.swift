import Foundation
import GhosttyKit

/// One tab that coastty owns and manages directly.
///
/// Per issue #12's architecture note (coastty repo): "a tab is no longer a
/// separate `NSWindow` — coastty now owns tab switching/creation/
/// closing/ordering itself, backed by Ghostty's existing per-window
/// surface-tree machinery." Concretely: a `TerminalController` (one
/// `NSWindow`) now holds an array of `CoasttyTab`s instead of relying on
/// `NSWindowTabGroup` to join separate windows. Switching tabs swaps which
/// tab's `tree` is installed as the controller's own
/// `BaseTerminalController.surfaceTree` — the same property that already
/// drives the SwiftUI terminal view — so a backgrounded tab's surfaces
/// (and their running processes) stay alive, just not attached to the
/// visible view, exactly like a backgrounded native tab did.
///
/// A value type, deliberately: `UndoState.tabs` (see `TerminalController`)
/// stores an array of these as a frozen undo snapshot. A reference type here
/// would make that snapshot's safety depend on the implicit invariant "a tab
/// is removed from `coasttyTabs` at the exact moment its `UndoState`
/// captures it" — true today, but not enforced by the type system, and easy
/// to violate silently in a future change that captures `undoState` without
/// immediately removing/closing the tab. A struct removes this class of bug
/// entirely: copying `coasttyTabs` into `UndoState.tabs` is a real,
/// independent snapshot, so later mutation of the live tab can never bleed
/// into it.
struct CoasttyTab: Identifiable, Codable {
    let id: UUID

    /// This tab's own split tree. When this tab isn't the active one, this
    /// is the only place its surfaces are referenced from — keeping them
    /// alive without rendering them.
    var tree: SplitTree<Ghostty.SurfaceView>

    /// The surface within `tree` that should regain focus when this tab
    /// becomes active again.
    var focusedSurfaceID: UUID?

    /// A user-set override for this tab's title (via "Rename Tab..."),
    /// mirroring `BaseTerminalController.titleOverride` — but per-tab,
    /// since that property is per-*controller* (one per window) and
    /// coastty windows can now hold many tabs. Snapshotted/restored
    /// alongside `tree`/`focusedSurfaceID` on every tab switch (see
    /// `TerminalController.coasttySnapshotActiveTab`/`coasttyActivateTab`).
    var titleOverride: String?

    /// A best-guess initial title for a brand-new tab, copied from
    /// whichever tab it was created from — Ghostty's core spawns a new
    /// tab's shell in the same working directory as the current one by
    /// default, so this is an accurate guess, not just a placeholder.
    /// Only used until `representativeSurface`'s own live title resolves,
    /// which then takes over completely — see `title`.
    var inheritedTitleHint: String?

    init(id: UUID = UUID(), tree: SplitTree<Ghostty.SurfaceView>, focusedSurfaceID: UUID? = nil) {
        self.id = id
        self.tree = tree
        self.focusedSurfaceID = focusedSurfaceID
    }

    /// The surface whose title/pwd represent this tab as a whole: the
    /// remembered focused surface if it's still in the tree, else the
    /// tree's first surface.
    private var representativeSurface: Ghostty.SurfaceView? {
        if let focusedSurfaceID, let match = tree.first(where: { $0.id == focusedSurfaceID }) {
            return match
        }
        return tree.first
    }

    /// This tab's own name/title, as Ghostty's native tab bar would have
    /// shown it.
    var title: String {
        if let titleOverride, !titleOverride.isEmpty {
            return titleOverride
        }
        // "👻" isn't a real title - it's SurfaceView's own placeholder for
        // "no OSC title arrived within its grace period", which it sets
        // as a genuine (non-empty) value on `title` itself. Treating it
        // as one here would let it beat inheritedTitleHint/pwd below,
        // which are actually informative, the moment that timer fires.
        let liveTitle = representativeSurface?.title ?? ""
        if !liveTitle.isEmpty, liveTitle != "👻" {
            return liveTitle
        }
        if let inheritedTitleHint, !inheritedTitleHint.isEmpty {
            return inheritedTitleHint
        }
        // No title yet (OSC 0/1/2, sent explicitly by the shell/prompt) -
        // but the working directory (OSC 7, or known from the pty spawn
        // itself) is a separate, often-earlier-available signal. Falls
        // back to that instead of the bare "Terminal" placeholder.
        if let workingDirectoryURL {
            return TerminalController.abbreviatingHome(in: workingDirectoryURL.standardizedFileURL.path)
        }
        return "Terminal"
    }

    /// This tab's real working directory (the pty's current directory),
    /// or nil if not yet known (e.g. the shell hasn't reported one yet).
    var workingDirectoryURL: URL? {
        guard let pwd = representativeSurface?.pwd, !pwd.isEmpty else { return nil }
        return URL(fileURLWithPath: pwd)
    }

    /// True if any surface in this tab needs close confirmation (a running
    /// foreground process) — checked for every tab, not just the active
    /// one, so closing the window can't silently kill a backgrounded tab's
    /// process without asking.
    var needsConfirmQuit: Bool {
        tree.contains(where: { $0.needsConfirmQuit })
    }

    /// True if quitting would actually end something in this tab - a host-attached pane wouldn't, since it keeps running on the daemon and gets reattached next launch.
    var needsConfirmAppQuit: Bool {
        tree.contains(where: { $0.needsConfirmQuit && !$0.processPersistsAfterQuit })
    }

    /// Every pane in this tab, as the close paths see them.
    var closingPanes: [CoasttyPaneLifecycle.Pane] {
        tree.map(\.closingPane)
    }
}
