import Foundation
import GhosttyKit

/// Telling coastty-host which Space, tab and pane the user was last in, so a layout command run from another terminal can target them. The report stays while coastty is in the background and goes only when the window it came from closes. Zig skips a report that repeats the last one and resends it when the daemon reconnects.
enum CoasttyFocusReport {
    /// The window whose Space, tab and pane the daemon holds now.
    private(set) static var reporter: ObjectIdentifier?

    /// Reports `window`'s active Space, its active tab and that tab's focused pane.
    static func send(from window: TerminalController, spaceID: UUID, tabID: UUID, paneID: String) {
        reporter = ObjectIdentifier(window)
        let space = spaceID.uuidString
        let tab = tabID.uuidString
        queue.async { ghostty_host_report_focus(space, tab, paneID) }
    }

    /// Clears the report when the window it came from closes; a report from another window is left alone.
    static func clear(from window: TerminalController) {
        guard reporter == ObjectIdentifier(window) else { return }
        reporter = nil
        queue.async { ghostty_host_report_focus("", "", "") }
    }

    /// Serial, so a clear always lands before the report that follows it.
    private static let queue = DispatchQueue(label: "com.coastty.focus-report", qos: .utility)
}
