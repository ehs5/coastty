import Foundation
import GhosttyKit

/// The real, owning "Space" model — issue #12 (coastty repo), Round 4's
/// corrected architecture note: Spaces are nested *inside* a window, not
/// aliased to one, and they don't span windows either.
///
/// The real hierarchy: a coastty window can have multiple Spaces, a Space
/// has its own tabs, a tab has its own panes (panes already exist via the
/// existing `SplitTree`, unchanged). Concretely, `TerminalController` holds
/// `coasttySpaces: [CoasttySpace]` + `coasttyActiveSpaceIndex` instead of a
/// single flat tab list — this type is what each entry in that array owns:
/// its own `tabs`/`activeTabIndex`, the same two things `TerminalController`
/// used to own directly (as `coasttyTabs`/`coasttyActiveTabIndex`) before a
/// window could hold more than one Space.
///
/// A value type, for the same reason `CoasttyTab` is one: `TerminalController.UndoState`
/// stores a frozen snapshot of every Space in the window, and a struct makes
/// that snapshot a real, independent copy instead of a shared reference that
/// could be mutated out from under it.
struct CoasttySpace: Identifiable, Codable {
    let id: UUID

    /// This Space's own tabs. A Space is never empty in practice — every
    /// path that creates one (`TerminalController.coasttyNewSpace`, initial
    /// window seeding) gives it exactly one starter tab — but this isn't
    /// enforced by the type itself, the same way `coasttyTabs` never
    /// enforced it before this Round either.
    var tabs: [CoasttyTab]

    /// The index into `tabs` of the tab this Space last showed. Restored
    /// when this Space becomes active again, mirroring the role
    /// `TerminalController.coasttyActiveTabIndex` played for the whole
    /// window before a window could hold more than one Space.
    var activeTabIndex: Int

    /// A user-chosen name set via the sidebar's "Rename..." context menu
    /// item, overriding `initialFolderName` below until cleared (empty
    /// input restores the default) — mirrors `CoasttyTab.titleOverride`'s
    /// own override-with-empty-to-clear convention.
    var nameOverride: String?

    /// This Space's default name — its starter tab's folder (e.g. "work"
    /// for `~/dev/work`, "~" for the home directory itself), captured once
    /// at creation time and never recomputed afterward. A Space's identity
    /// shouldn't drift just because a later tab gets added, an existing
    /// tab's pwd changes, or a running program sets its own title — only
    /// an explicit "Rename..." (`nameOverride`) changes the displayed name
    /// after creation.
    let initialFolderName: String

    init(id: UUID = UUID(), tabs: [CoasttyTab], activeTabIndex: Int = 0, nameOverride: String? = nil, initialFolderName: String) {
        self.id = id
        self.tabs = tabs
        self.activeTabIndex = activeTabIndex
        self.nameOverride = nameOverride
        self.initialFolderName = initialFolderName
    }

    /// This Space's own name: `nameOverride` if the user has set one via
    /// "Rename...", otherwise `initialFolderName`.
    var name: String {
        if let nameOverride, !nameOverride.isEmpty {
            return nameOverride
        }
        return initialFolderName
    }

    /// True if any tab in this Space needs close confirmation (a running
    /// foreground process) — checked for every Space a window owns, not
    /// just the active one, so closing the window can't silently kill a
    /// backgrounded Space's process without asking. Mirrors
    /// `CoasttyTab.needsConfirmQuit`, aggregated across the whole Space.
    var needsConfirmQuit: Bool {
        tabs.contains(where: { $0.needsConfirmQuit })
    }

    /// The Space-wide version of `CoasttyTab.needsConfirmAppQuit`.
    var needsConfirmAppQuit: Bool {
        tabs.contains(where: { $0.needsConfirmAppQuit })
    }

    /// Every pane in every tab of this Space, as the close paths see them.
    var closingPanes: [CoasttyPaneLifecycle.Pane] {
        tabs.flatMap(\.closingPanes)
    }
}
