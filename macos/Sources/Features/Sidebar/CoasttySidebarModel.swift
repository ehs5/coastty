import Foundation

/// An agent's status as the sidebar and tab bar present it: the detected
/// `AgentState` folded together with whether the user has seen the result.
///
/// Named for what each case means, not for how it looks - a single status
/// draws differently depending on where it appears (see
/// `CoasttyStatusIconContext`).
///
/// modelled on: `AgentStatus` in herdr's `src/api/schema/common.rs`, mapped
/// by `pane_agent_status` in `src/app/api_helpers.rs`
enum CoasttyAgentStatus: Equatable, CaseIterable {
    /// Actively processing right now.
    case working
    /// Finished, not yet seen by the user.
    case done
    /// Finished and acknowledged - the fully-resolved state.
    case idle
    /// Needs the user's attention (e.g. a permission prompt).
    case blocked
    /// No agent identified in this pane.
    case unknown
}

/// One *pane*, as coastty's sidebar's "Agents" section describes it.
///
/// A pane, not a tab: a tab can be split, and each pane in it can be
/// running its own agent. herdr lists agents per pane too - its
/// `AgentPanelEntry` carries a `pane_id` and its `pane_details` walks
/// `tab.panes.values()` (`src/workspace/aggregate.rs`).
///
/// A pane with no agent (`agentName == nil`) never appears in the Agents
/// section and never contributes to its space's aggregated status.
struct CoasttyAgentTab: Identifiable, Equatable {
    /// The pane's own surface id, so each pane is a distinct row.
    let id: UUID
    /// The owning tab's name/title, as shown in coastty's tab bar.
    var tabName: String
    /// The agent's display name (e.g. "Claude"), or nil if no agent is
    /// running in this pane.
    var agentName: String?
    /// The agent's current status. Always `.unknown` when `agentName` is nil.
    var status: CoasttyAgentStatus
    /// Whether this pane is the focused pane of the active tab of the
    /// active space - the one actually in front of the user.
    ///
    /// modelled on: `AppState::is_active_pane` in herdr's
    /// `src/app/actions.rs`, which the agents panel uses to pick out the
    /// row for the pane you are looking at (`src/ui/sidebar.rs`)
    var isActive: Bool
    /// Where to go when this row is clicked.
    var destination: CoasttyAgentDestination?
    /// `status`'s ranking for picking which row is most pressing - read
    /// from `agent-detection` (`ghostty_agent_status_priority`), not
    /// computed here; `aggregatedStatus` and `agentRows` both sort by it.
    var priority: Int
    /// Monotonic recency counter bumped when `status` last changed; `agentRows` sorts by it within a priority tier.
    var statusChangeSeq: Int

    init(
        id: UUID = UUID(),
        tabName: String,
        agentName: String? = nil,
        status: CoasttyAgentStatus = .unknown,
        isActive: Bool = false,
        destination: CoasttyAgentDestination? = nil,
        priority: Int = 0,
        statusChangeSeq: Int = 0
    ) {
        self.id = id
        self.tabName = tabName
        self.agentName = agentName
        // An agent-less pane can never have a status - keep the invariant
        // enforced here rather than trusting every call site to respect it.
        self.status = agentName != nil ? status : .unknown
        self.isActive = isActive
        self.destination = destination
        self.priority = agentName != nil ? priority : 0
        self.statusChangeSeq = statusChangeSeq
    }

    var hasAgent: Bool { agentName != nil }
}

/// Everything needed to bring a pane to the front: its space, its tab
/// within that space, and the pane itself.
struct CoasttyAgentDestination: Equatable {
    var spaceID: UUID
    var tabID: UUID
    var surfaceID: UUID
}

/// One workspace, as the "Spaces" section shows it: a single collapsed
/// row, never a nested tab list.
///
/// This is display data only — a read-only summary of a real `CoasttySpace`
/// (issue #12, coastty repo, Round 4), rendered by `CoasttySidebarView`.
/// Kept as a distinct type (rather than reusing `CoasttySpace` itself) so
/// the sidebar view has no dependency on `CoasttyTab`/`SplitTree`/AppKit —
/// same reasoning as `CoasttyTabBarModel.Tab` vs. `CoasttyTab`. Its `id`
/// mirrors the real `CoasttySpace.id` it was built from (see
/// `TerminalController.makeSidebarModel()`), so `CoasttySidebarModel.activeSpaceID`
/// can be matched against it for the row's selected-state highlight.
struct CoasttySpaceSummary: Identifiable, Equatable {
    let id: UUID
    var name: String
    var tabs: [CoasttyAgentTab]

    /// The real, currently-configured keyboard shortcut for jumping straight
    /// to this Space (e.g. "⌃⇧1"), or nil past the 9th Space/if the user has
    /// rebound or removed it — mirrors `CoasttyTabBarModel.Tab.shortcutLabel`'s
    /// own "read the real config, don't hardcode the default" reasoning.
    var shortcutLabel: String?

    init(id: UUID = UUID(), name: String, tabs: [CoasttyAgentTab] = [], shortcutLabel: String? = nil) {
        self.id = id
        self.name = name
        self.tabs = tabs
        self.shortcutLabel = shortcutLabel
    }

    /// The single status icon this space's row shows, or nil when nothing
    /// in this space has an agent running at all (rendered as the neutral
    /// "none" dot). Mirrors the visual reference's `aggregatedState()`.
    ///
    /// "Whatever is most pressing wins" - the status of whichever tab has
    /// the highest `priority`, per `CoasttyAgentTab.priority`.
    var aggregatedStatus: CoasttyAgentStatus {
        tabs.max { $0.priority < $1.priority }?.status ?? .unknown
    }
}

/// One row in the sidebar's "Agents" section: an agent-bearing tab, plus
/// the name of the space it lives in (for the `folder · tab` line).
struct CoasttyAgentRow: Identifiable, Equatable {
    var id: UUID { tab.id }
    var spaceName: String
    var tab: CoasttyAgentTab
}

extension CoasttySidebarModel {
    /// The destination for a row, by row id - what a click on it should
    /// bring to the front.
    func agentDestination(for rowID: UUID) -> CoasttyAgentDestination? {
        agentRows.first { $0.id == rowID }?.tab.destination
    }

    /// `agentRows` narrowed to what actually needs the user - blocked or
    /// done-unseen. Working/idle agents never qualify, even as a fallback.
    /// Already sorted blocked-before-done, most-recently-changed first
    /// within each, since it's built from `agentRows`' own ordering.
    var urgentAgentRows: [CoasttyAgentRow] {
        agentRows.filter { $0.tab.status == .blocked || $0.tab.status == .done }
    }

    /// Whether `goto_urgent_agent` would actually take the user somewhere
    /// new right now - so its shortcut hint can hide otherwise. False both
    /// when nothing is urgent and when the only urgent agent is the one
    /// already focused (cycling a single-item list just lands back on
    /// itself, which isn't a useful jump).
    func hasUsefulUrgentAgentJump(focusedSurfaceID: UUID?) -> Bool {
        guard let destination = urgentAgentDestination(focusedSurfaceID: focusedSurfaceID) else { return false }
        return destination.surfaceID != focusedSurfaceID
    }

    /// Next destination for the "jump to urgent agent" keybind; re-derives from current focus every call rather than a stored cursor, so it can't go stale.
    func urgentAgentDestination(focusedSurfaceID: UUID?) -> CoasttyAgentDestination? {
        let urgent = urgentAgentRows
        guard !urgent.isEmpty else { return nil }

        guard let focusedSurfaceID,
              let focusedIndex = urgent.firstIndex(where: { $0.id == focusedSurfaceID })
        else { return urgent[0].tab.destination }

        return urgent[(focusedIndex + 1) % urgent.count].tab.destination
    }

    /// Shared step logic for `nextAgentDestination`/`previousAgentDestination`.
    /// `step` is +1 or -1; with nothing agent-related focused, +1 lands on
    /// the top of the sort and -1 on the bottom.
    private func agentCycleDestination(focusedSurfaceID: UUID?, step: Int) -> CoasttyAgentDestination? {
        let rows = agentRows
        guard !rows.isEmpty else { return nil }

        guard let focusedSurfaceID,
              let focusedIndex = rows.firstIndex(where: { $0.id == focusedSurfaceID })
        else { return (step > 0 ? rows.first : rows.last)?.tab.destination }

        let nextIndex = ((focusedIndex + step) % rows.count + rows.count) % rows.count
        return rows[nextIndex].tab.destination
    }

    /// Next destination for the `next_agent` keybind - cycles every
    /// agent-bearing pane in `agentRows`' own order (working/idle included,
    /// unlike `urgentAgentDestination`). Re-derives from current focus
    /// every call, same reasoning as `urgentAgentDestination`.
    func nextAgentDestination(focusedSurfaceID: UUID?) -> CoasttyAgentDestination? {
        agentCycleDestination(focusedSurfaceID: focusedSurfaceID, step: 1)
    }

    /// Previous destination for the `previous_agent` keybind. See
    /// `nextAgentDestination(focusedSurfaceID:)`.
    func previousAgentDestination(focusedSurfaceID: UUID?) -> CoasttyAgentDestination? {
        agentCycleDestination(focusedSurfaceID: focusedSurfaceID, step: -1)
    }
}

/// The sidebar's whole data model: every space, in display order.
///
/// This is pure data — it has no opinion about how it was populated. A
/// `TerminalController` builds one directly from its own window's own
/// Spaces, with agent status from real detected state (see
/// `TerminalController.makeSidebarModel()`).
struct CoasttySidebarModel: Equatable {
    var spaces: [CoasttySpaceSummary]

    /// The `id` of whichever Space is currently active in this window, or
    /// nil if none is (e.g. an empty model) — issue #12 (coastty repo),
    /// Round 4: lets `CoasttySidebarView` highlight the active Space's row,
    /// now that a window can hold more than one.
    var activeSpaceID: UUID?

    /// Live keyboard shortcut for `goto_urgent_agent` (e.g. "⌘U"), or nil if unbound - mirrors `CoasttySpaceSummary.shortcutLabel`.
    var agentsShortcutLabel: String?

    init(spaces: [CoasttySpaceSummary] = [], activeSpaceID: UUID? = nil, agentsShortcutLabel: String? = nil) {
        self.spaces = spaces
        self.activeSpaceID = activeSpaceID
        self.agentsShortcutLabel = agentsShortcutLabel
    }

    /// Every agent-bearing tab across every space, sorted by `priority` then by `statusChangeSeq` recency.
    var agentRows: [CoasttyAgentRow] {
        let rows = spaces.flatMap { space in
            space.tabs
                .filter { $0.hasAgent }
                .map { CoasttyAgentRow(spaceName: space.name, tab: $0) }
        }

        return rows.sorted { lhs, rhs in
            if lhs.tab.priority != rhs.tab.priority { return lhs.tab.priority > rhs.tab.priority }
            return lhs.tab.statusChangeSeq > rhs.tab.statusChangeSeq
        }
    }
}
