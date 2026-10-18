//
//  CoasttyPaneLifecycleTests.swift
//  Ghostty
//
//  Coverage for the two decisions every close path makes: which
//  coastty-host panes the close ends, and whether ending them warrants
//  confirming first. Both are pure, so they're exercised directly here -
//  the daemon's own "what's orphaned" set difference is tested on the Zig
//  side, where it's actually computed.
//

import Foundation
import Testing
@testable import Ghostty

struct CoasttyPaneLifecycleTests {
    private static func pane(_ hostID: String, running: Bool = false) -> CoasttyPaneLifecycle.Pane {
        .init(hostID: hostID, hasRunningProcess: running)
    }

    @Test func hostIDsKeepsEveryHostBackedPaneInOrder() {
        let ids = CoasttyPaneLifecycle.hostIDs(of: [
            Self.pane("/a#0"),
            Self.pane("/b#0"),
            Self.pane("/c#0"),
        ])
        #expect(ids == ["/a#0", "/b#0", "/c#0"])
    }

    @Test func hostIDsDropsLocallySpawnedPanes() {
        let ids = CoasttyPaneLifecycle.hostIDs(of: [
            Self.pane(""),
            Self.pane("/a#0"),
            Self.pane(""),
        ])
        #expect(ids == ["/a#0"])
    }

    @Test func hostIDsDeduplicatesRepeatedIDs() {
        let ids = CoasttyPaneLifecycle.hostIDs(of: [
            Self.pane("/a#0"),
            Self.pane("/a#0"),
            Self.pane("/b#0"),
        ])
        #expect(ids == ["/a#0", "/b#0"])
    }

    @Test func hostIDsOfNothingIsEmpty() {
        #expect(CoasttyPaneLifecycle.hostIDs(of: []).isEmpty)
    }

    @Test func closeNeedsConfirmationWhenAnyPaneIsStillRunning() {
        #expect(CoasttyPaneLifecycle.needsCloseConfirmation([
            Self.pane("/a#0", running: false),
            Self.pane("/b#0", running: true),
        ]))
    }

    @Test func closeNeedsNoConfirmationWhenNothingIsRunning() {
        #expect(!CoasttyPaneLifecycle.needsCloseConfirmation([
            Self.pane("/a#0", running: false),
            Self.pane("", running: false),
        ]))
    }

    // A locally spawned pane has no id to kill, but closing its tab still
    // ends it - so it counts towards the confirmation even though it never
    // shows up in the kill request.
    @Test func closeNeedsConfirmationForARunningLocallySpawnedPane() {
        #expect(CoasttyPaneLifecycle.needsCloseConfirmation([Self.pane("", running: true)]))
    }

    @Test func closingNothingNeedsNoConfirmation() {
        #expect(!CoasttyPaneLifecycle.needsCloseConfirmation([]))
    }
}
