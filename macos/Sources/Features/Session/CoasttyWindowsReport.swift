import Foundation
import GhosttyKit

/// Telling coastty-host which windows are open and the Spaces each shows, so layout commands can name a window. Zig skips a report that repeats the last one and resends it when the daemon reconnects.
enum CoasttyWindowsReport {
    /// One open window: its id, its active Space and every Space it shows, in order.
    struct Window: Equatable {
        let id: UUID
        let activeSpaceID: UUID?
        let spaceIDs: [UUID]
    }

    /// Reports every open window, replacing whatever was reported before.
    static func send(_ windows: [Window]) {
        let body = body(for: windows)
        queue.async {
            body.utf8CString.withUnsafeBufferPointer { buffer in
                // The count includes the C string's terminator, which is not part of the body.
                ghostty_host_report_windows(buffer.baseAddress, buffer.count - 1)
            }
        }
    }

    /// The `WINDOWS` body for `windows`: one line per window, its id, active Space and Spaces NUL-separated (see `host/wire.zig`).
    static func body(for windows: [Window]) -> String {
        windows.map { window in
            let fields = [window.id.uuidString, window.activeSpaceID?.uuidString ?? ""] + window.spaceIDs.map(\.uuidString)
            return fields.joined(separator: "\0")
        }.joined(separator: "\n")
    }

    /// Serial, so reports reach the daemon in the order windows changed.
    private static let queue = DispatchQueue(label: "com.coastty.windows-report", qos: .utility)
}
