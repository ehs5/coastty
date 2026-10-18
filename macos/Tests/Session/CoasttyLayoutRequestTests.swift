//
//  CoasttyLayoutRequestTests.swift
//  Ghostty
//
//  Coverage for decoding the requests coastty-host hands the app when a
//  layout command asks for a change. The JSON is the daemon's own `request`
//  event, so these break if the two sides drift apart.
//

import Foundation
import Testing
@testable import Ghostty

struct CoasttyLayoutRequestTests {
    private static let spaceID = "B0A2C6A8-0000-4000-8000-000000000001"
    private static let tabID = "B0A2C6A8-0000-4000-8000-000000000002"

    private static func decode(_ json: String) -> CoasttyLayoutRequest? {
        CoasttyLayoutRequest.decode(Data(json.utf8))
    }

    @Test func aTabNewRequestDecodesIntoTheNewTabAction() {
        let request = Self.decode("""
            {"event":"request","scope":"tab","op":"new","near":"surface:A","space":"\(Self.spaceID)",\
            "tab":"\(Self.tabID)","name":"build","directory":"/tmp","focus":true}
            """)

        #expect(request == .newTab(.init(
            spaceID: UUID(uuidString: Self.spaceID)!,
            tabID: UUID(uuidString: Self.tabID)!,
            name: "build",
            directory: "/tmp",
            focus: true)))
    }

    @Test func aRequestFromOutsideCoasttyDecodesTheSame() {
        let request = Self.decode("""
            {"event":"request","scope":"tab","op":"new","near":"","space":"\(Self.spaceID)",\
            "tab":"\(Self.tabID)","name":"","directory":"/Users/me","focus":false}
            """)

        guard case .newTab(let newTab) = request else {
            Issue.record("expected a new tab request")
            return
        }
        #expect(newTab.name.isEmpty)
        #expect(!newTab.focus)
    }

    @Test func closeRenameAndMoveRequestsDecodeIntoTheirActions() {
        let tabID = UUID(uuidString: Self.tabID)!

        #expect(Self.decode("""
            {"event":"request","scope":"tab","op":"close","tab":"\(Self.tabID)"}
            """) == .closeTab(id: tabID))
        #expect(Self.decode("""
            {"event":"request","scope":"tab","op":"rename","tab":"\(Self.tabID)","name":"tests"}
            """) == .renameTab(id: tabID, name: "tests"))
        #expect(Self.decode("""
            {"event":"request","scope":"tab","op":"rename","tab":"\(Self.tabID)","name":""}
            """) == .renameTab(id: tabID, name: ""))
        #expect(Self.decode("""
            {"event":"request","scope":"tab","op":"move","tab":"\(Self.tabID)","index":2}
            """) == .moveTab(id: tabID, index: 2))
    }

    @Test func aSpaceNewRequestDecodesIntoTheNewSpaceAction() {
        let besideID = "B0A2C6A8-0000-4000-8000-000000000003"
        let request = Self.decode("""
            {"event":"request","scope":"space","op":"new","beside":"\(besideID)","space":"\(Self.spaceID)",\
            "tab":"\(Self.tabID)","name":"task","directory":"/tmp","focus":false}
            """)

        #expect(request == .newSpace(.init(
            spaceID: UUID(uuidString: Self.spaceID)!,
            tabID: UUID(uuidString: Self.tabID)!,
            windowID: nil,
            besideSpaceID: UUID(uuidString: besideID)!,
            name: "task",
            directory: "/tmp",
            focus: false)))
    }

    @Test func aSpaceNewFromOutsideCoasttyNamesNoWindow() {
        let request = Self.decode("""
            {"event":"request","scope":"space","op":"new","beside":"","space":"\(Self.spaceID)",\
            "tab":"\(Self.tabID)","name":"","directory":"/Users/me","focus":true}
            """)

        guard case .newSpace(let newSpace) = request else {
            Issue.record("expected a new Space request")
            return
        }
        #expect(newSpace.besideSpaceID == nil)
        #expect(newSpace.focus)
    }

    @Test func spaceCloseRenameAndMoveRequestsDecodeIntoTheirActions() {
        let spaceID = UUID(uuidString: Self.spaceID)!
        let afterID = "B0A2C6A8-0000-4000-8000-000000000004"

        #expect(Self.decode("""
            {"event":"request","scope":"space","op":"close","space":"\(Self.spaceID)"}
            """) == .closeSpace(id: spaceID))
        #expect(Self.decode("""
            {"event":"request","scope":"space","op":"rename","space":"\(Self.spaceID)","name":""}
            """) == .renameSpace(id: spaceID, name: ""))
        #expect(Self.decode("""
            {"event":"request","scope":"space","op":"move","space":"\(Self.spaceID)","index":1,"after":["\(afterID)"]}
            """) == .moveSpace(.init(id: spaceID, index: 1, after: [UUID(uuidString: afterID)!], windowID: nil)))
    }

    @Test func aSpaceNewNamingAWindowDecodesIt() {
        let windowID = "B0A2C6A8-0000-4000-8000-000000000006"
        let request = Self.decode("""
            {"event":"request","scope":"space","op":"new","beside":"","window":"\(windowID)","space":"\(Self.spaceID)",\
            "tab":"\(Self.tabID)","name":"","directory":"/tmp","focus":false}
            """)

        guard case .newSpace(let newSpace) = request else {
            Issue.record("expected a new Space request")
            return
        }
        #expect(newSpace.windowID == UUID(uuidString: windowID))
    }

    @Test func aSpaceMoveToAWindowDecodesTheWindow() {
        let windowID = "B0A2C6A8-0000-4000-8000-000000000006"
        let afterID = "B0A2C6A8-0000-4000-8000-000000000004"

        #expect(Self.decode("""
            {"event":"request","scope":"space","op":"move","space":"\(Self.spaceID)","index":0,"after":["\(afterID)"],\
            "window":"\(windowID)"}
            """) == .moveSpace(.init(
                id: UUID(uuidString: Self.spaceID)!,
                index: 0,
                after: [UUID(uuidString: afterID)!],
                windowID: UUID(uuidString: windowID)!)))
        #expect(Self.decode("""
            {"event":"request","scope":"space","op":"move","space":"\(Self.spaceID)","index":0,"after":[],"window":"win-1"}
            """) == nil)
    }

    @Test func aSpaceMoveWithoutItsAnchorsIsIgnored() {
        #expect(Self.decode("""
            {"event":"request","scope":"space","op":"move","space":"\(Self.spaceID)","index":1}
            """) == nil)
    }

    @Test func aMoveWithoutAnIndexIsIgnored() {
        #expect(Self.decode("""
            {"event":"request","scope":"tab","op":"move","tab":"\(Self.tabID)"}
            """) == nil)
    }

    @Test func aPaneSplitRequestDecodesIntoTheSplitAction() {
        let surfaceID = "B0A2C6A8-0000-4000-8000-000000000005"
        let request = Self.decode("""
            {"event":"request","scope":"pane","op":"split","pane":"surface:A","tab":"\(Self.tabID)",\
            "surface":"\(surfaceID)","direction":"down","directory":"/tmp","focus":true}
            """)

        #expect(request == .splitPane(.init(
            paneID: "surface:A",
            surfaceID: UUID(uuidString: surfaceID)!,
            direction: .down,
            directory: "/tmp",
            focus: true)))
    }

    @Test func aPaneSplitInADirectionThisBuildDoesNotKnowIsIgnored() {
        #expect(Self.decode("""
            {"event":"request","scope":"pane","op":"split","pane":"surface:A","tab":"\(Self.tabID)",\
            "surface":"\(Self.spaceID)","direction":"sideways","directory":"/tmp","focus":false}
            """) == nil)
    }

    @Test func aPaneCloseRequestDecodesIntoTheCloseAction() {
        #expect(Self.decode("""
            {"event":"request","scope":"pane","op":"close","pane":"surface:A"}
            """) == .closePane(id: "surface:A"))
    }

    @Test func focusRequestsDecodeIntoTheirFocusActions() {
        #expect(Self.decode("""
            {"event":"request","scope":"space","op":"focus","space":"\(Self.spaceID)"}
            """) == .focusSpace(id: UUID(uuidString: Self.spaceID)!))
        #expect(Self.decode("""
            {"event":"request","scope":"tab","op":"focus","tab":"\(Self.tabID)"}
            """) == .focusTab(id: UUID(uuidString: Self.tabID)!))
        #expect(Self.decode("""
            {"event":"request","scope":"pane","op":"focus","pane":"surface:A"}
            """) == .focusPane(id: "surface:A"))
        #expect(Self.decode("""
            {"event":"request","scope":"tab","op":"focus","tab":"tab-1"}
            """) == nil)
    }

    @Test func anEventThatIsNotARequestIsIgnored() {
        #expect(Self.decode(#"{"event":"model_changed","revision":3}"#) == nil)
    }

    @Test func anOpThisBuildDoesNotKnowIsIgnored() {
        #expect(Self.decode("""
            {"event":"request","scope":"tab","op":"juggle","near":"","tab":"\(Self.tabID)"}
            """) == nil)
    }

    @Test func aRequestNamingAnIdThatIsNotAUUIDIsIgnored() {
        #expect(Self.decode("""
            {"event":"request","scope":"tab","op":"new","near":"","space":"space-a",\
            "tab":"\(Self.tabID)","name":"","directory":"/tmp","focus":false}
            """) == nil)
    }
}
