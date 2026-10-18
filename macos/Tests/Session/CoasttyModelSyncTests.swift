//
//  CoasttyModelSyncTests.swift
//  Ghostty
//
//  Coverage for the operations the GUI reports to coastty-host: the field
//  lists they carry and the order they have to arrive in. Building them is
//  deliberately separate from sending them, so none of this needs a daemon.
//

import Foundation
import GhosttyKit
import Testing
@testable import Ghostty

struct CoasttyModelSyncTests {
    private typealias Space = CoasttyModelSync.Operation.SpaceSnapshot
    private typealias Tab = CoasttyModelSync.Operation.TabSnapshot

    private static func space(name: String, tabs: [Tab]) -> Space {
        .init(id: UUID(), name: name, tabs: tabs)
    }

    private static func tab(panes: Int) -> Tab {
        .init(id: UUID(), name: "", hostIDs: (0..<panes).map { "surface:\($0)" })
    }

    @Test func recreatingReportsEveryTabSoNoSpaceArrivesEmpty() {
        let operations = CoasttyModelSync.Operation.operationsRecreating([
            Self.space(name: "work", tabs: [Self.tab(panes: 1), Self.tab(panes: 1)]),
            Self.space(name: "bah", tabs: [Self.tab(panes: 1)]),
        ])

        #expect(operations.filter { $0.op == GHOSTTY_HOST_MODEL_OP_SPACE_NEW }.count == 2)
        #expect(operations.filter { $0.op == GHOSTTY_HOST_MODEL_OP_TAB_NEW }.count == 3)
    }

    @Test func aTabNeverArrivesBeforeTheSpaceHoldingIt() {
        let operations = CoasttyModelSync.Operation.operationsRecreating([
            Self.space(name: "work", tabs: [Self.tab(panes: 1)]),
            Self.space(name: "bah", tabs: [Self.tab(panes: 1)]),
        ])

        for (index, operation) in operations.enumerated() where operation.op == GHOSTTY_HOST_MODEL_OP_TAB_NEW {
            let spaceID = operation.fields[0]
            #expect(operations[..<index].contains {
                $0.op == GHOSTTY_HOST_MODEL_OP_SPACE_NEW && $0.fields[0] == spaceID
            })
        }
    }

    @Test func aSpaceReportsTheNameItShows() {
        let operations = CoasttyModelSync.Operation.operationsRecreating([
            Self.space(name: "work", tabs: [Self.tab(panes: 1)]),
        ])

        #expect(operations.first { $0.op == GHOSTTY_HOST_MODEL_OP_SPACE_NEW }?.fields[1] == "work")
    }

    @Test func aTabWhosePanesAreAllLocalIsNotReportedAtAll() {
        let operations = CoasttyModelSync.Operation.operationsRecreating([
            Self.space(name: "work", tabs: [Self.tab(panes: 0), Self.tab(panes: 1)]),
        ])

        #expect(operations.filter { $0.op == GHOSTTY_HOST_MODEL_OP_TAB_NEW }.count == 1)
    }

    @Test func aSpaceWithNoTabLeftToReportIsLeftOutOfTheModelEntirely() {
        let operations = CoasttyModelSync.Operation.operationsRecreating([
            Self.space(name: "ghost", tabs: [Self.tab(panes: 0)]),
        ])

        #expect(operations.isEmpty)
    }

    @Test func aDroppedSpaceDoesNotLeaveAGapInTheOrderOfTheRest() {
        let operations = CoasttyModelSync.Operation.operationsRecreating([
            Self.space(name: "ghost", tabs: [Self.tab(panes: 0)]),
            Self.space(name: "real", tabs: [Self.tab(panes: 1)]),
        ])

        #expect(operations.first { $0.op == GHOSTTY_HOST_MODEL_OP_SPACE_MOVE }?.fields[1] == "0")
    }
}


struct CoasttySessionRestorePruneTests {
    private static func model(_ spaces: [CoasttyHostModel.Space]) -> CoasttyHostModel {
        .init(runID: "run", revision: 1, spaces: spaces)
    }

    private static func space(id: String, tabs: [CoasttyHostModel.Tab]) -> CoasttyHostModel.Space {
        .init(id: id, name: "n", defaultName: "n", hidden: false, restoreIndex: 0, tabs: tabs)
    }

    private static func tab(id: String, panes: Int) -> CoasttyHostModel.Tab {
        .init(id: id, name: "", panes: (0..<panes).map {
            .init(id: "surface:\($0)", directory: "/tmp", title: "")
        })
    }

    private static let spaceID = "B0A2C6A8-0000-4000-8000-000000000001"
    private static let tabID = "B0A2C6A8-0000-4000-8000-000000000002"

    @Test func aSpaceWhoseTabsAllHoldNothingIsEndedRatherThanRebuilt() {
        let pruned = CoasttySessionRestore.pruningEmpties(
            Self.model([Self.space(id: Self.spaceID, tabs: [Self.tab(id: Self.tabID, panes: 0)])]))

        #expect(pruned.spaces.isEmpty)
        #expect(pruned.operations.count == 1)
        #expect(pruned.operations.first?.op == GHOSTTY_HOST_MODEL_OP_SPACE_CLOSE)
        #expect(pruned.operations.first?.fields == [Self.spaceID])
    }

    @Test func anEmptyTabIsEndedWithoutTakingTheSpaceHoldingIt() {
        let pruned = CoasttySessionRestore.pruningEmpties(Self.model([
            Self.space(id: Self.spaceID, tabs: [Self.tab(id: Self.tabID, panes: 0), Self.tab(id: "live", panes: 1)])
        ]))

        #expect(pruned.spaces.count == 1)
        #expect(pruned.spaces.first?.tabs.count == 1)
        #expect(pruned.operations.map(\.op) == [GHOSTTY_HOST_MODEL_OP_TAB_CLOSE])
    }

    @Test func aSpaceThatStillHoldsPanesIsLeftExactlyAsItWas() {
        let pruned = CoasttySessionRestore.pruningEmpties(Self.model([
            Self.space(id: Self.spaceID, tabs: [Self.tab(id: Self.tabID, panes: 2)])
        ]))

        #expect(pruned.operations.isEmpty)
        #expect(pruned.spaces.first?.tabs.first?.panes.count == 2)
    }
}
