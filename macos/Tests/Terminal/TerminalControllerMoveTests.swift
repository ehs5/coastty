//
//  TerminalControllerMoveTests.swift
//  Ghostty
//
//  Coverage for TerminalController.coasttyReordered - the pure reordering
//  primitive behind coasttyMoveTab/coasttyMoveSpace.
//

import Foundation
import Testing
@testable import Ghostty

private struct CoasttyReorderTestItem: Identifiable, Equatable {
    let id: Int
}

struct TerminalControllerMoveTests {
    private static func items(_ ids: Int...) -> [CoasttyReorderTestItem] {
        ids.map { CoasttyReorderTestItem(id: $0) }
    }

    @Test func reorderedMovesTheItemToItsNewIndex() {
        let result = TerminalController.coasttyReordered(Self.items(1, 2, 3, 4), fromIndex: 0, toIndex: 2, activeID: nil)
        #expect(result?.items.map(\.id) == [2, 3, 1, 4])
    }

    @Test func reorderedTracksTheActiveItemByIdWhenSomethingElseMoves() {
        // Moving item 1 past the active item (2) should shift the active
        // index down by one even though 2 itself never moved.
        let result = TerminalController.coasttyReordered(Self.items(1, 2, 3), fromIndex: 0, toIndex: 1, activeID: 2)
        #expect(result?.items.map(\.id) == [2, 1, 3])
        #expect(result?.activeIndex == 0)
    }

    @Test func reorderedTracksTheActiveItemByIdWhenTheActiveItemIsTheOneMoved() {
        let result = TerminalController.coasttyReordered(Self.items(1, 2, 3), fromIndex: 0, toIndex: 2, activeID: 1)
        #expect(result?.items.map(\.id) == [2, 3, 1])
        #expect(result?.activeIndex == 2)
    }

    @Test func reorderedLeavesTheActiveIndexUntouchedWhenNeitherEndpointAffectsIt() {
        let result = TerminalController.coasttyReordered(Self.items(1, 2, 3, 4), fromIndex: 2, toIndex: 3, activeID: 1)
        #expect(result?.activeIndex == 0)
    }

    @Test func reorderedReturnsNilActiveIndexWhenNoActiveIDIsGiven() {
        let result = TerminalController.coasttyReordered(Self.items(1, 2, 3), fromIndex: 0, toIndex: 1, activeID: nil)
        #expect(result?.activeIndex == nil)
    }

    @Test func reorderedReturnsNilForAnOutOfRangeFromIndex() {
        #expect(TerminalController.coasttyReordered(Self.items(1, 2, 3), fromIndex: 5, toIndex: 1, activeID: nil) == nil)
    }

    @Test func reorderedReturnsNilForAnOutOfRangeToIndex() {
        #expect(TerminalController.coasttyReordered(Self.items(1, 2, 3), fromIndex: 0, toIndex: 5, activeID: nil) == nil)
    }

    @Test func reorderedReturnsNilWhenFromAndToAreTheSame() {
        #expect(TerminalController.coasttyReordered(Self.items(1, 2, 3), fromIndex: 1, toIndex: 1, activeID: nil) == nil)
    }
}
