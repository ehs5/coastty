//
//  CoasttySidebarModelTests.swift
//  Ghostty
//
//  Coverage for coastty's sidebar data model — issue #12 (coastty repo).
//

import Foundation
import Testing
@testable import Ghostty

struct CoasttySidebarModelTests {
    // MARK: - CoasttyAgentTab

    @Test func agentlessTabHasNoStatusEvenIfOneIsPassed() {
        // A tab with no agent can never show a status, regardless of what
        // the caller passes — the invariant is enforced in the
        // initializer so no call site can violate it by mistake.
        let tab = CoasttyAgentTab(tabName: "docs", agentName: nil, status: .blocked)
        #expect(tab.status == .unknown)
        #expect(tab.hasAgent == false)
    }

    @Test func agentTabKeepsItsStatus() {
        let tab = CoasttyAgentTab(tabName: "web", agentName: "Claude", status: .done)
        #expect(tab.status == .done)
        #expect(tab.hasAgent == true)
    }

    // MARK: - CoasttySpaceSummary.aggregatedStatus

    @Test func aggregatedStatusIsUnknownWithNoAgentTabsAtAll() {
        let space = CoasttySpaceSummary(name: "cc-vuejs", tabs: [
            CoasttyAgentTab(tabName: "scaffold"),
        ])
        #expect(space.aggregatedStatus == .unknown)
    }

    @Test func aggregatedStatusIsUnknownForAnEmptySpace() {
        let space = CoasttySpaceSummary(name: "empty", tabs: [])
        #expect(space.aggregatedStatus == .unknown)
    }

    @Test func aggregatedStatusPicksBlockedOverEverythingElse() {
        // Priority order matches herdr's `status_priority`: blocked, done,
        // working, idle, unknown - read from `agent-detection` in
        // production, passed explicitly here.
        let space = CoasttySpaceSummary(name: "no-crm-troax-ab", tabs: [
            CoasttyAgentTab(tabName: "one", agentName: "Claude", status: .idle, priority: 1),
            CoasttyAgentTab(tabName: "two", agentName: "Claude", status: .working, priority: 2),
            CoasttyAgentTab(tabName: "three", agentName: "Claude", status: .blocked, priority: 4),
            CoasttyAgentTab(tabName: "four", agentName: "Claude", status: .done, priority: 3),
        ])
        #expect(space.aggregatedStatus == .blocked)
    }

    @Test func aggregatedStatusPicksDoneOverWorkingAndIdle() {
        let space = CoasttySpaceSummary(name: "plainkey", tabs: [
            CoasttyAgentTab(tabName: "one", agentName: "Claude", status: .idle, priority: 1),
            CoasttyAgentTab(tabName: "two", agentName: "Claude", status: .working, priority: 2),
            CoasttyAgentTab(tabName: "three", agentName: "Claude", status: .done, priority: 3),
        ])
        #expect(space.aggregatedStatus == .done)
    }

    @Test func aggregatedStatusPicksWorkingOverIdle() {
        let space = CoasttySpaceSummary(name: "coastty", tabs: [
            CoasttyAgentTab(tabName: "one", agentName: "Claude", status: .idle, priority: 1),
            CoasttyAgentTab(tabName: "two", agentName: "Claude", status: .working, priority: 2),
        ])
        #expect(space.aggregatedStatus == .working)
    }

    @Test func aggregatedStatusFallsBackToCheckmarkWhenEverythingIsResolved() {
        let space = CoasttySpaceSummary(name: "plainkey", tabs: [
            CoasttyAgentTab(tabName: "docs", agentName: "Claude", status: .idle, priority: 1),
        ])
        #expect(space.aggregatedStatus == .idle)
    }

    @Test func aggregatedStatusIgnoresAgentlessTabsMixedInWithAgentTabs() {
        let space = CoasttySpaceSummary(name: "coastty", tabs: [
            CoasttyAgentTab(tabName: "ghostty-fork"), // no agent
            CoasttyAgentTab(tabName: "main", agentName: "Claude", status: .working, priority: 2),
        ])
        #expect(space.aggregatedStatus == .working)
    }

    // MARK: - CoasttySidebarModel.agentRows

    @Test func agentRowsExcludesTabsWithNoAgent() {
        let model = CoasttySidebarModel(spaces: [
            CoasttySpaceSummary(name: "coastty", tabs: [
                CoasttyAgentTab(tabName: "main", agentName: "Claude", status: .working),
                CoasttyAgentTab(tabName: "ghostty-fork"), // no agent, excluded
            ]),
            CoasttySpaceSummary(name: "plainkey", tabs: [
                CoasttyAgentTab(tabName: "web", agentName: "Claude", status: .done),
                CoasttyAgentTab(tabName: "api"), // no agent, excluded
                CoasttyAgentTab(tabName: "docs", agentName: "Claude", status: .idle),
            ]),
        ])

        let rows = model.agentRows
        #expect(Set(rows.map(\.tab.tabName)) == ["main", "web", "docs"])

        let spaceNameByTabName = Dictionary(uniqueKeysWithValues: rows.map { ($0.tab.tabName, $0.spaceName) })
        #expect(spaceNameByTabName["main"] == "coastty")
        #expect(spaceNameByTabName["web"] == "plainkey")
        #expect(spaceNameByTabName["docs"] == "plainkey")
    }

    @Test func agentRowsIsEmptyWhenNoSpaceHasAnAgent() {
        let model = CoasttySidebarModel(spaces: [
            CoasttySpaceSummary(name: "cc-vuejs", tabs: [
                CoasttyAgentTab(tabName: "scaffold"),
            ]),
        ])
        #expect(model.agentRows.isEmpty)
    }

    @Test func agentRowsIsEmptyForAModelWithNoSpaces() {
        let model = CoasttySidebarModel()
        #expect(model.spaces.isEmpty)
        #expect(model.agentRows.isEmpty)
    }

    @Test func agentRowsSortsByStatusPriorityBeforeAnythingElse() {
        // Priority order: blocked, done, working, idle, unknown - matches
        // `agent-detection`'s `AgentStatus.priority` (herdr's
        // `status_priority`), regardless of which space or tab position
        // each row started in.
        let model = CoasttySidebarModel(spaces: [
            CoasttySpaceSummary(name: "coastty", tabs: [
                CoasttyAgentTab(tabName: "idle-one", agentName: "Claude", status: .idle, priority: 1),
                CoasttyAgentTab(tabName: "working-one", agentName: "Claude", status: .working, priority: 2),
            ]),
            CoasttySpaceSummary(name: "plainkey", tabs: [
                CoasttyAgentTab(tabName: "blocked-one", agentName: "Claude", status: .blocked, priority: 4),
                CoasttyAgentTab(tabName: "done-one", agentName: "Claude", status: .done, priority: 3),
            ]),
        ])

        let rows = model.agentRows
        #expect(rows.map(\.tab.tabName) == ["blocked-one", "done-one", "working-one", "idle-one"])
    }

    @Test func agentRowsBreaksAStatusPriorityTieByMostRecentlyChangedFirst() {
        // Same tier (both `.working`) - the higher `statusChangeSeq` (more
        // recently changed) sorts first.
        let model = CoasttySidebarModel(spaces: [
            CoasttySpaceSummary(name: "coastty", tabs: [
                CoasttyAgentTab(tabName: "stale", agentName: "Claude", status: .working, priority: 2, statusChangeSeq: 1),
                CoasttyAgentTab(tabName: "fresh", agentName: "Claude", status: .working, priority: 2, statusChangeSeq: 5),
                CoasttyAgentTab(tabName: "middling", agentName: "Claude", status: .working, priority: 2, statusChangeSeq: 3),
            ]),
        ])

        let rows = model.agentRows
        #expect(rows.map(\.tab.tabName) == ["fresh", "middling", "stale"])
    }

    @Test func agentRowsRecencyTiebreakOnlyAppliesWithinAPriorityTier() {
        // A blocked tab with an old `statusChangeSeq` still outranks a
        // freshly-changed working tab - recency only breaks ties, it never
        // overrides priority.
        let model = CoasttySidebarModel(spaces: [
            CoasttySpaceSummary(name: "coastty", tabs: [
                CoasttyAgentTab(tabName: "old-blocked", agentName: "Claude", status: .blocked, priority: 4, statusChangeSeq: 1),
                CoasttyAgentTab(tabName: "new-working", agentName: "Claude", status: .working, priority: 2, statusChangeSeq: 99),
            ]),
        ])

        let rows = model.agentRows
        #expect(rows.map(\.tab.tabName) == ["old-blocked", "new-working"])
    }

    // MARK: - CoasttySidebarModel.urgentAgentDestination

    @Test func urgentAgentDestinationIsNilWhenThereAreNoAgentRowsAtAll() {
        let model = CoasttySidebarModel()
        #expect(model.urgentAgentDestination(focusedSurfaceID: nil) == nil)
    }

    @Test func urgentAgentDestinationIsNilWhenNoAgentIsBlockedOrDone() {
        let working = CoasttyAgentTab(
            tabName: "working", agentName: "Claude", status: .working,
            destination: .init(spaceID: UUID(), tabID: UUID(), surfaceID: UUID()), priority: 2
        )
        let idle = CoasttyAgentTab(
            tabName: "idle", agentName: "Claude", status: .idle,
            destination: .init(spaceID: UUID(), tabID: UUID(), surfaceID: UUID()), priority: 1
        )
        let model = CoasttySidebarModel(spaces: [
            CoasttySpaceSummary(name: "coastty", tabs: [idle, working]),
        ])

        // Neither pane is blocked/done - working/idle never qualify, even
        // as a fallback.
        #expect(model.urgentAgentDestination(focusedSurfaceID: nil) == nil)
    }

    @Test func urgentAgentDestinationJumpsToTheMostUrgentWhenFocusIsNotInTheUrgentList() {
        let blocked = CoasttyAgentTab(
            tabName: "blocked", agentName: "Claude", status: .blocked,
            destination: .init(spaceID: UUID(), tabID: UUID(), surfaceID: UUID()), priority: 4
        )
        let working = CoasttyAgentTab(
            tabName: "working", agentName: "Claude", status: .working,
            destination: .init(spaceID: UUID(), tabID: UUID(), surfaceID: UUID()), priority: 2
        )
        let model = CoasttySidebarModel(spaces: [
            CoasttySpaceSummary(name: "coastty", tabs: [working, blocked]),
        ])

        // Focused on the working pane, which isn't blocked/done at all.
        #expect(model.urgentAgentDestination(focusedSurfaceID: working.id) == blocked.destination)
        // No focus at all lands the same place.
        #expect(model.urgentAgentDestination(focusedSurfaceID: nil) == blocked.destination)
    }

    @Test func urgentAgentDestinationCyclesBlockedBeforeDoneNeverInterleavedAndWraps() {
        let blockedOld = CoasttyAgentTab(
            tabName: "blocked-old", agentName: "Claude", status: .blocked,
            destination: .init(spaceID: UUID(), tabID: UUID(), surfaceID: UUID()), priority: 4, statusChangeSeq: 1
        )
        let blockedNew = CoasttyAgentTab(
            tabName: "blocked-new", agentName: "Claude", status: .blocked,
            destination: .init(spaceID: UUID(), tabID: UUID(), surfaceID: UUID()), priority: 4, statusChangeSeq: 5
        )
        let done = CoasttyAgentTab(
            tabName: "done", agentName: "Claude", status: .done,
            destination: .init(spaceID: UUID(), tabID: UUID(), surfaceID: UUID()), priority: 3, statusChangeSeq: 2
        )
        let model = CoasttySidebarModel(spaces: [
            CoasttySpaceSummary(name: "coastty", tabs: [done, blockedOld, blockedNew]),
        ])

        // Most-recently-blocked first, then the older blocked one, then
        // done - only wrapping back to the top once every blocked pane has
        // been visited.
        #expect(model.urgentAgentDestination(focusedSurfaceID: nil) == blockedNew.destination)
        #expect(model.urgentAgentDestination(focusedSurfaceID: blockedNew.id) == blockedOld.destination)
        #expect(model.urgentAgentDestination(focusedSurfaceID: blockedOld.id) == done.destination)
        #expect(model.urgentAgentDestination(focusedSurfaceID: done.id) == blockedNew.destination)
    }

    @Test func urgentAgentDestinationIsNilWhenTheFocusedUrgentTabHasNoDestination() {
        let blocked = CoasttyAgentTab(tabName: "blocked", agentName: "Claude", status: .blocked, priority: 4)
        let model = CoasttySidebarModel(spaces: [
            CoasttySpaceSummary(name: "coastty", tabs: [blocked]),
        ])

        #expect(model.urgentAgentDestination(focusedSurfaceID: blocked.id) == nil)
    }

    // MARK: - CoasttySidebarModel.nextAgentDestination / previousAgentDestination

    @Test func nextAndPreviousAgentDestinationAreNilWhenThereAreNoAgentRowsAtAll() {
        let model = CoasttySidebarModel()
        #expect(model.nextAgentDestination(focusedSurfaceID: nil) == nil)
        #expect(model.previousAgentDestination(focusedSurfaceID: nil) == nil)
    }

    @Test func nextAndPreviousAgentDestinationIncludeWorkingAndIdlePanes() {
        // Unlike `urgentAgentDestination`, nothing here is blocked/done -
        // next/previous still cycle them, since the full cycle covers
        // every agent-bearing pane.
        let working = CoasttyAgentTab(
            tabName: "working", agentName: "Claude", status: .working,
            destination: .init(spaceID: UUID(), tabID: UUID(), surfaceID: UUID()), priority: 2
        )
        let idle = CoasttyAgentTab(
            tabName: "idle", agentName: "Claude", status: .idle,
            destination: .init(spaceID: UUID(), tabID: UUID(), surfaceID: UUID()), priority: 1
        )
        let model = CoasttySidebarModel(spaces: [
            CoasttySpaceSummary(name: "coastty", tabs: [idle, working]),
        ])

        #expect(model.nextAgentDestination(focusedSurfaceID: nil) == working.destination)
        #expect(model.previousAgentDestination(focusedSurfaceID: nil) == idle.destination)
    }

    @Test func nextAgentDestinationLandsOnTheTopOfTheSortWhenNothingIsFocused() {
        let low = CoasttyAgentTab(
            tabName: "low", agentName: "Claude", status: .idle,
            destination: .init(spaceID: UUID(), tabID: UUID(), surfaceID: UUID()), priority: 1
        )
        let high = CoasttyAgentTab(
            tabName: "high", agentName: "Claude", status: .blocked,
            destination: .init(spaceID: UUID(), tabID: UUID(), surfaceID: UUID()), priority: 4
        )
        let model = CoasttySidebarModel(spaces: [
            CoasttySpaceSummary(name: "coastty", tabs: [low, high]),
        ])

        #expect(model.nextAgentDestination(focusedSurfaceID: nil) == high.destination)
    }

    @Test func previousAgentDestinationLandsOnTheBottomOfTheSortWhenNothingIsFocused() {
        let low = CoasttyAgentTab(
            tabName: "low", agentName: "Claude", status: .idle,
            destination: .init(spaceID: UUID(), tabID: UUID(), surfaceID: UUID()), priority: 1
        )
        let high = CoasttyAgentTab(
            tabName: "high", agentName: "Claude", status: .blocked,
            destination: .init(spaceID: UUID(), tabID: UUID(), surfaceID: UUID()), priority: 4
        )
        let model = CoasttySidebarModel(spaces: [
            CoasttySpaceSummary(name: "coastty", tabs: [low, high]),
        ])

        #expect(model.previousAgentDestination(focusedSurfaceID: nil) == low.destination)
    }

    @Test func nextAndPreviousAgentDestinationWrapAtBothEnds() {
        let first = CoasttyAgentTab(
            tabName: "first", agentName: "Claude", status: .blocked,
            destination: .init(spaceID: UUID(), tabID: UUID(), surfaceID: UUID()), priority: 4, statusChangeSeq: 2
        )
        let second = CoasttyAgentTab(
            tabName: "second", agentName: "Claude", status: .blocked,
            destination: .init(spaceID: UUID(), tabID: UUID(), surfaceID: UUID()), priority: 4, statusChangeSeq: 1
        )
        let model = CoasttySidebarModel(spaces: [
            CoasttySpaceSummary(name: "coastty", tabs: [first, second]),
        ])

        // Forward from the last row wraps to the first; backward from the
        // first row wraps to the last.
        #expect(model.nextAgentDestination(focusedSurfaceID: second.id) == first.destination)
        #expect(model.previousAgentDestination(focusedSurfaceID: first.id) == second.destination)
    }

    @Test func nextAndPreviousAgentDestinationDeriveFromWhicheverPaneIsActuallyFocused() {
        let a = CoasttyAgentTab(
            tabName: "a", agentName: "Claude", status: .blocked,
            destination: .init(spaceID: UUID(), tabID: UUID(), surfaceID: UUID()), priority: 4, statusChangeSeq: 3
        )
        let b = CoasttyAgentTab(
            tabName: "b", agentName: "Claude", status: .blocked,
            destination: .init(spaceID: UUID(), tabID: UUID(), surfaceID: UUID()), priority: 4, statusChangeSeq: 2
        )
        let c = CoasttyAgentTab(
            tabName: "c", agentName: "Claude", status: .blocked,
            destination: .init(spaceID: UUID(), tabID: UUID(), surfaceID: UUID()), priority: 4, statusChangeSeq: 1
        )
        let model = CoasttySidebarModel(spaces: [
            CoasttySpaceSummary(name: "coastty", tabs: [a, b, c]),
        ])

        // Focus jumped straight to "c" some other way (e.g. a click) -
        // next/previous re-derive from there, not from a stale cursor left
        // over from an earlier press.
        #expect(model.nextAgentDestination(focusedSurfaceID: c.id) == a.destination)
        #expect(model.previousAgentDestination(focusedSurfaceID: c.id) == b.destination)
    }

    @Test func nextAndPreviousAgentDestinationAreNilWhenTheFocusedTabHasNoDestination() {
        let onlyTab = CoasttyAgentTab(tabName: "only", agentName: "Claude", status: .idle, priority: 1)
        let model = CoasttySidebarModel(spaces: [
            CoasttySpaceSummary(name: "coastty", tabs: [onlyTab]),
        ])

        #expect(model.nextAgentDestination(focusedSurfaceID: onlyTab.id) == nil)
        #expect(model.previousAgentDestination(focusedSurfaceID: onlyTab.id) == nil)
    }

    // MARK: - CoasttySidebarModel.hasUsefulUrgentAgentJump

    @Test func hasUsefulUrgentAgentJumpIsTrueWithABlockedOrDoneAgentNotFocused() {
        let blocked = CoasttyAgentTab(
            tabName: "blocked", agentName: "Claude", status: .blocked,
            destination: .init(spaceID: UUID(), tabID: UUID(), surfaceID: UUID()), priority: 4
        )
        let model = CoasttySidebarModel(spaces: [.init(name: "s", tabs: [blocked])])

        #expect(model.hasUsefulUrgentAgentJump(focusedSurfaceID: nil))
    }

    @Test func hasUsefulUrgentAgentJumpIsFalseWithNoUrgentAgentOrNoAgentsAtAll() {
        let working = CoasttyAgentTab(
            tabName: "working", agentName: "Claude", status: .working,
            destination: .init(spaceID: UUID(), tabID: UUID(), surfaceID: UUID()), priority: 2
        )
        let idle = CoasttyAgentTab(
            tabName: "idle", agentName: "Claude", status: .idle,
            destination: .init(spaceID: UUID(), tabID: UUID(), surfaceID: UUID()), priority: 1
        )

        #expect(!CoasttySidebarModel(spaces: [.init(name: "s", tabs: [working, idle])]).hasUsefulUrgentAgentJump(focusedSurfaceID: nil))
        #expect(!CoasttySidebarModel().hasUsefulUrgentAgentJump(focusedSurfaceID: nil))
    }

    @Test func hasUsefulUrgentAgentJumpIsFalseWhenAlreadyFocusedOnTheOnlyUrgentAgent() {
        // The reported bug: one blocked agent, already looking at it -
        // cycling a single-item list just lands back on itself, so the
        // shortcut hint shouldn't claim it would do something. The pane's
        // own id and its destination's surfaceID are the same real surface
        // in production (TerminalController.coasttyAgentPanes) - match
        // that here rather than two unrelated random UUIDs.
        let surfaceID = UUID()
        let blocked = CoasttyAgentTab(
            id: surfaceID, tabName: "blocked", agentName: "Claude", status: .blocked,
            destination: .init(spaceID: UUID(), tabID: UUID(), surfaceID: surfaceID), priority: 4
        )
        let model = CoasttySidebarModel(spaces: [.init(name: "s", tabs: [blocked])])

        #expect(!model.hasUsefulUrgentAgentJump(focusedSurfaceID: surfaceID))
    }

    @Test func hasUsefulUrgentAgentJumpIsTrueWhenFocusedOnOneOfSeveralUrgentAgents() {
        let surfaceA = UUID()
        let blockedA = CoasttyAgentTab(
            id: surfaceA, tabName: "blocked-a", agentName: "Claude", status: .blocked,
            destination: .init(spaceID: UUID(), tabID: UUID(), surfaceID: surfaceA), priority: 4
        )
        let surfaceB = UUID()
        let blockedB = CoasttyAgentTab(
            id: surfaceB, tabName: "blocked-b", agentName: "Claude", status: .blocked,
            destination: .init(spaceID: UUID(), tabID: UUID(), surfaceID: surfaceB), priority: 4
        )
        let model = CoasttySidebarModel(spaces: [.init(name: "s", tabs: [blockedA, blockedB])])

        #expect(model.hasUsefulUrgentAgentJump(focusedSurfaceID: surfaceA))
    }

    // MARK: - CoasttySidebarModel.activeSpaceID
    //
    // A window can hold more than one Space now (issue #12, coastty repo,
    // Round 4) — `activeSpaceID` is what lets `CoasttySidebarView` know
    // which of this window's Space rows to highlight as selected.

    @Test func activeSpaceIDDefaultsToNil() {
        let model = CoasttySidebarModel(spaces: [
            CoasttySpaceSummary(name: "coastty"),
        ])
        #expect(model.activeSpaceID == nil)
    }

    @Test func activeSpaceIDMatchesOneOfTheSpaceSummariesOwnID() {
        let active = CoasttySpaceSummary(name: "coastty")
        let other = CoasttySpaceSummary(name: "plainkey")
        let model = CoasttySidebarModel(spaces: [active, other], activeSpaceID: active.id)

        #expect(model.activeSpaceID == active.id)
        #expect(model.activeSpaceID != other.id)
    }

    // MARK: - TerminalController.abbreviatingHome
    //
    // Not `private`, so tab titles and the tmux-integration path can reuse
    // it — kept independently testable here rather than only exercised
    // through those AppKit-heavy call sites.

    @Test func abbreviatingHomeCollapsesTheHomeDirectoryItselfToATilde() {
        #expect(TerminalController.abbreviatingHome(in: NSHomeDirectory()) == "~")
    }

    @Test func abbreviatingHomeCollapsesAPathUnderHomeToATildePrefix() {
        let path = NSHomeDirectory() + "/dev/coastty"
        #expect(TerminalController.abbreviatingHome(in: path) == "~/dev/coastty")
    }

    @Test func abbreviatingHomeLeavesAPathOutsideHomeUntouched() {
        #expect(TerminalController.abbreviatingHome(in: "/opt/homebrew/bin") == "/opt/homebrew/bin")
    }
}
