import AppKit
import GhosttyKit

/// The dialogs about coastty-host found at launch: Zig decides whether it is kept or restarted, and this tells the user.
enum CoasttyDaemonUpdate {
    /// Shows a modal alert with an OK button.
    @MainActor
    private static func showAlert(_ title: String, _ text: String, style: NSAlert.Style = .warning) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = style
        alert.runModal()
    }

    /// Explains that the daemon is of another version and could not be stopped.
    @MainActor
    private static func showRestartFailed() {
        showAlert(
            "Coastty couldn't restart its background service",
            "The background service that keeps your shells running needs a restart, and Coastty couldn't stop it. Restart your Mac, or quit Coastty, run \"pkill -x coastty-host\" in Terminal and open Coastty again.")
    }

    /// Explains a restart of the daemon, after it happened.
    @MainActor
    private static func showRestarted() {
        showAlert(
            "Coastty restarted its background service",
            "This update included a new version of the service that keeps your shells running. Running shells were restarted.",
            style: .informational)
    }

    /// Tells the user what happened to the daemon found at launch, if anything; called whenever a window becomes key, since the first contact with the daemon can come from any launch path.
    @MainActor
    static func showLaunchNotice() {
        switch ghostty_host_take_daemon_notice() {
        case GHOSTTY_HOST_DAEMON_NOTICE_RESTARTED:
            showRestarted()

        case GHOSTTY_HOST_DAEMON_NOTICE_RESTART_FAILED:
            showRestartFailed()

        default:
            break
        }
    }
}
