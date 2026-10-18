import Foundation
import GhosttyKit

/// Ending coastty-host panes when the UI that held them goes away. Kept apart from the Space/Tab tree walking that feeds it, so the close decisions are testable without a live surface.
enum CoasttyPaneLifecycle {
    /// One pane as the close paths see it.
    struct Pane: Equatable {
        /// The daemon's id for this pane, or "" for a locally spawned one.
        let hostID: String

        /// Whether something is still running in it.
        let hasRunningProcess: Bool
    }

    /// The host pane ids to name in one `KILL`/`SWEEP` request, in order, minus locally spawned panes (no id to send) and repeats of an id already listed.
    static func hostIDs(of panes: [Pane]) -> [String] {
        var seen: Set<String> = []
        var ids: [String] = []
        for pane in panes {
            // A locally spawned pane dies with the GUI; there's nothing to ask the daemon about.
            if pane.hostID.isEmpty { continue }
            if seen.contains(pane.hostID) { continue }
            seen.insert(pane.hostID)
            ids.append(pane.hostID)
        }
        return ids
    }

    /// True if closing `panes` would end something still running, which is what warrants asking first.
    static func needsCloseConfirmation(_ panes: [Pane]) -> Bool {
        panes.contains(where: \.hasRunningProcess)
    }

    /// Ends the named panes on coastty-host in one request, off the main thread: the daemon only answers once the processes are actually gone, which for one ignoring SIGTERM takes seconds.
    static func kill(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            withCStringArray(ids) { pointer, count in
                ghostty_host_kill_panes(pointer, count)
            }
        }
    }

    /// Hands coastty-host every pane the GUI still wants and lets it end the rest - which of its panes are orphaned is the daemon's own computation, not ours.
    static func sweep(keeping ids: [String]) {
        DispatchQueue.global(qos: .utility).async {
            withCStringArray(ids) { pointer, count in
                ghostty_host_sweep_panes(pointer, count)
            }
        }
    }

    /// Calls `body` with `ids` as the C string array the host functions take; the pointers are only valid for the call.
    private static func withCStringArray(
        _ ids: [String],
        _ body: (UnsafePointer<UnsafePointer<CChar>?>?, Int) -> Void
    ) {
        let duplicated = ids.map { strdup($0) }
        defer { duplicated.forEach { free($0) } }

        duplicated.withUnsafeBufferPointer { buffer in
            buffer.withMemoryRebound(to: UnsafePointer<CChar>?.self) { rebound in
                body(rebound.baseAddress, ids.count)
            }
        }
    }
}
