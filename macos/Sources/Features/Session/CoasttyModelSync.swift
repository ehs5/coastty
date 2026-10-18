import Foundation
import GhosttyKit

/// Reporting structural changes - Spaces, tabs, which panes sit in which tab - to the model coastty-host owns. The GUI reports; the daemon decides what a change means for the model.
///
/// Kept apart from the controller that calls it so the field lists each operation travels with are testable without a live daemon or a window.
enum CoasttyModelSync {
    /// One structural change, with its fields in the order the daemon reads them (see `SPACE`/`TAB`/`PANE` in `host/wire.zig`).
    struct Operation: Equatable {
        let op: ghostty_host_model_op_e
        let fields: [String]
    }
}

// MARK: Building operations

extension CoasttyModelSync.Operation {
    typealias Operation = CoasttyModelSync.Operation

    static func spaceNew(id: UUID, name: String) -> Operation {
        .init(op: GHOSTTY_HOST_MODEL_OP_SPACE_NEW, fields: [id.uuidString, name])
    }

    static func spaceClose(id: UUID) -> Operation {
        .init(op: GHOSTTY_HOST_MODEL_OP_SPACE_CLOSE, fields: [id.uuidString])
    }

    static func spaceRename(id: UUID, name: String) -> Operation {
        .init(op: GHOSTTY_HOST_MODEL_OP_SPACE_RENAME, fields: [id.uuidString, name])
    }

    static func spaceMove(id: UUID, to index: Int) -> Operation {
        .init(op: GHOSTTY_HOST_MODEL_OP_SPACE_MOVE, fields: [id.uuidString, String(index)])
    }

    static func spaceHide(id: UUID) -> Operation {
        .init(op: GHOSTTY_HOST_MODEL_OP_SPACE_HIDE, fields: [id.uuidString])
    }

    static func spaceShow(id: UUID) -> Operation {
        .init(op: GHOSTTY_HOST_MODEL_OP_SPACE_SHOW, fields: [id.uuidString])
    }

    static func tabNew(spaceID: UUID, tabID: UUID, name: String) -> Operation {
        .init(op: GHOSTTY_HOST_MODEL_OP_TAB_NEW, fields: [spaceID.uuidString, tabID.uuidString, name])
    }

    static func tabClose(id: UUID) -> Operation {
        .init(op: GHOSTTY_HOST_MODEL_OP_TAB_CLOSE, fields: [id.uuidString])
    }

    static func tabRename(id: UUID, name: String) -> Operation {
        .init(op: GHOSTTY_HOST_MODEL_OP_TAB_RENAME, fields: [id.uuidString, name])
    }

    static func tabMove(id: UUID, to index: Int) -> Operation {
        .init(op: GHOSTTY_HOST_MODEL_OP_TAB_MOVE, fields: [id.uuidString, String(index)])
    }

    static func paneMove(hostID: String, toTab tabID: UUID, at index: Int) -> Operation {
        .init(op: GHOSTTY_HOST_MODEL_OP_PANE_MOVE, fields: [hostID, tabID.uuidString, String(index)])
    }

    /// Where every pane in `tree` sits in `tabID`, in order. Locally spawned panes have no daemon id and are skipped.
    static func operationsPlacingPanes(
        of tree: SplitTree<Ghostty.SurfaceView>,
        inTab tabID: UUID
    ) -> [Operation] {
        let hostIDs = CoasttyPaneLifecycle.hostIDs(of: tree.map(\.closingPane))
        return hostIDs.enumerated().map { paneMove(hostID: $1, toTab: tabID, at: $0) }
    }

    /// One Space as the model cares about it: what it is called, and which of its tabs hold panes the daemon owns.
    ///
    /// Taken off the live Spaces before any operation is built, so what gets reported can be decided without a window or a running pane behind it.
    struct SpaceSnapshot: Equatable {
        let id: UUID
        let name: String
        let tabs: [TabSnapshot]

        init(_ space: CoasttySpace) {
            self.id = space.id
            self.name = space.name
            self.tabs = space.tabs.map(TabSnapshot.init)
        }

        init(id: UUID, name: String, tabs: [TabSnapshot]) {
            self.id = id
            self.name = name
            self.tabs = tabs
        }
    }

    struct TabSnapshot: Equatable {
        let id: UUID
        let name: String
        let hostIDs: [String]

        init(_ tab: CoasttyTab) {
            self.id = tab.id
            self.name = tab.titleOverride ?? ""
            self.hostIDs = CoasttyPaneLifecycle.hostIDs(of: tab.closingPanes)
        }

        init(id: UUID, name: String, hostIDs: [String]) {
            self.id = id
            self.name = name
            self.hostIDs = hostIDs
        }
    }

    /// Every operation that recreates `spaces` from an empty model, in the order they have to be applied: a tab needs its Space to exist, a pane needs its tab.
    ///
    /// A tab holding only locally spawned panes is left out along with them. They have no daemon id, so nothing would follow the tab into the model, and what the daemon would be left holding is a tab no client can show and no close path removes. A Space with no tab left is dropped the same way. Hidden Spaces are not represented: the GUI has no hidden state to report yet.
    static func operationsRecreating(_ spaces: [SpaceSnapshot]) -> [Operation] {
        var operations: [Operation] = []
        var spaceIndex = 0

        for space in spaces {
            let tabs = space.tabs.filter { !$0.hostIDs.isEmpty }
            guard !tabs.isEmpty else { continue }

            operations.append(spaceNew(id: space.id, name: space.name))
            operations.append(spaceMove(id: space.id, to: spaceIndex))
            spaceIndex += 1

            for tab in tabs {
                operations.append(tabNew(spaceID: space.id, tabID: tab.id, name: tab.name))

                for (paneIndex, hostID) in tab.hostIDs.enumerated() {
                    operations.append(paneMove(hostID: hostID, toTab: tab.id, at: paneIndex))
                }
            }
        }
        return operations
    }

    static func operationsRecreating(_ spaces: [CoasttySpace]) -> [Operation] {
        operationsRecreating(spaces.map(SpaceSnapshot.init))
    }

}

// MARK: Sending

extension CoasttyModelSync {

    /// Reports one change. Off the main thread: this is a socket round trip, and a structural change happens on a UI gesture.
    static func send(_ operation: Operation) {
        send([operation])
    }

    /// Reports several changes in the order given, so a tab never reaches the daemon before the Space it belongs to.
    ///
    /// The queue is serial, which is what holds that order across separate calls too: creating a Space reports the Space, then its tab, and installing that tab reports the pane in it from a second call. On a concurrent queue the pane can win the race and be refused for a tab the daemon does not have yet.
    static func send(_ operations: [Operation]) {
        guard !operations.isEmpty else { return }
        queue.async {
            for operation in operations {
                withCStringArray(operation.fields) { pointer, count in
                    _ = ghostty_host_model_op(operation.op, pointer, count)
                }
            }
        }
    }

    private static let queue = DispatchQueue(label: "com.coastty.model-sync", qos: .utility)

    /// Reports `operations` and does not return until the daemon has them.
    ///
    /// Only for the one caller that has to read the model back immediately - seeding it at launch from the session file an upgrade brought along. Everything else should not block a UI gesture on a socket round trip.
    static func sendBlocking(_ operations: [Operation]) {
        for operation in operations {
            withCStringArray(operation.fields) { pointer, count in
                _ = ghostty_host_model_op(operation.op, pointer, count)
            }
        }
    }

    /// Calls `body` with `fields` as the C string array the host function takes; the pointers are only valid for the call.
    private static func withCStringArray(
        _ fields: [String],
        _ body: (UnsafePointer<UnsafePointer<CChar>?>?, Int) -> Void
    ) {
        let duplicated = fields.map { strdup($0) }
        defer { duplicated.forEach { free($0) } }

        duplicated.withUnsafeBufferPointer { buffer in
            buffer.withMemoryRebound(to: UnsafePointer<CChar>?.self) { rebound in
                body(rebound.baseAddress, fields.count)
            }
        }
    }
}
