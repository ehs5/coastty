import Foundation

/// The pure display data + action hooks for coastty's own tab bar
/// (issue #12, coastty repo). Kept decoupled from `Ghostty`/`AppKit` types
/// so the SwiftUI tab bar view has no dependency on how tabs are actually
/// implemented — `TerminalController` is the only thing that knows tabs
/// are backed by `CoasttyTab`/`SplitTree`.
final class CoasttyTabBarModel: ObservableObject {
    struct Tab: Identifiable, Equatable {
        let id: UUID
        var title: String
        /// e.g. "⌘1" for the first 9 tabs, matching the keyboard-shortcut
        /// badge Ghostty's native tab bar already shows per tab (see the
        /// visual reference, `prototypes/native-tabs-reference.png` in the
        /// coastty repo) — nil for tabs beyond the goto_tab:1-9 range.
        var shortcutLabel: String?
        /// This tab's agent status, shown in the tab's leading icon slot —
        /// the same slot/icon set already specced for the sidebar's
        /// Spaces/Agents rows. `nil` renders the neutral "no agent" dot,
        /// whether because nothing in this tab has an agent running or no
        /// detection check has run yet.
        var status: CoasttyAgentStatus
    }

    @Published var tabs: [Tab] = []
    @Published var activeTabID: UUID?

    /// Called with the tab's id when the user clicks a tab to switch to it.
    var onSelect: ((UUID) -> Void)?
    /// Called with the tab's id when the user clicks its close (×) control.
    var onClose: ((UUID) -> Void)?
    /// Called when the user clicks the new-tab control.
    var onNew: (() -> Void)?
    /// Called with the tab's old and new index once a drag-to-reorder gesture ends somewhere new.
    var onMove: ((Int, Int) -> Void)?

    // MARK: - Context menu (mirrors Ghostty's native tab context menu)

    /// Called with the tab's id when "Close Other Tabs" is chosen from its
    /// right-click menu.
    var onCloseOthers: ((UUID) -> Void)?
    /// Called with the tab's id when "Close Tabs to the Right" is chosen.
    var onCloseToRight: ((UUID) -> Void)?
    /// Called with the tab's id when "Rename Tab..." is chosen.
    var onRename: ((UUID) -> Void)?
}
