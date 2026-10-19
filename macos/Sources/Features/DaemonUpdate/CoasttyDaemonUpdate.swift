import AppKit
import GhosttyKit

/// The dialogs about coastty-host found at launch: Zig decides whether it is kept, kept with an update to offer, or restarted, and this tells the user and carries out a restart they choose.
enum CoasttyDaemonUpdate {
    /// Set once the user chose a restart, so quitting skips its confirmation and relaunches the app.
    private(set) static var relaunchOnTerminate = false

    /// Shows a modal alert with an OK button.
    @MainActor
    private static func showAlert(_ title: String, _ text: String, style: NSAlert.Style = .warning) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = style
        alert.runModal()
    }

    /// Explains that the daemon is from an incompatible build and could not be stopped.
    @MainActor
    private static func showRestartFailed() {
        showAlert(
            "Coastty couldn't restart its background service",
            "The background service that keeps your shells and agents running needs a restart, and Coastty couldn't stop it. Restart your Mac, or quit Coastty, run \"pkill -x coastty-host\" in Terminal and open Coastty again.")
    }

    /// Explains a restart that could not be avoided, after it happened.
    @MainActor
    private static func showRestarted() {
        showAlert(
            "Your shells and agents were restarted",
            "This version of Coastty can't talk to the background service the previous version left running, the one that keeps your shells and agents running. Coastty had to restart it, which ended every running shell and agent. Your Spaces and tabs are back, each with a fresh shell in the directory it was in.",
            style: .informational)
    }

    /// Stops the daemon, then quits so the relaunch starts the new one and brings every Space and tab back.
    @MainActor
    private static func restartNow() {
        guard ghostty_host_stop_for_restart() else {
            showRestartFailed()
            return
        }

        relaunchOnTerminate = true
        NSApp.terminate(nil)
    }

    /// Offers the daemon update, and restarts only when the user clicks Restart now.
    @MainActor
    private static func askToRestart() {
        let alert = NSAlert()
        alert.messageText = "Restart panes to update"
        alert.informativeText = "The background service that keeps your shells and agents running has an update. Restarting it ends every running shell and agent. Your Spaces and tabs come back, each with a fresh shell in the directory it was in, and Coastty reopens.\n\nUntil then Coastty keeps using the current one. Restarting your Mac also updates it."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Restart now")
        alert.addButton(withTitle: "Later")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        restartNow()
    }

    /// Tells the user what happened to the daemon found at launch, if anything; called whenever a window becomes key, since the first contact with the daemon can come from any launch path.
    @MainActor
    static func showLaunchNotice() {
        switch ghostty_host_take_daemon_notice() {
        case GHOSTTY_HOST_DAEMON_NOTICE_UPDATE_AVAILABLE:
            askToRestart()

        case GHOSTTY_HOST_DAEMON_NOTICE_RESTARTED:
            showRestarted()

        case GHOSTTY_HOST_DAEMON_NOTICE_RESTART_FAILED:
            showRestartFailed()

        default:
            break
        }
    }

    /// Opens the app again after it exits, when quitting finishes a restart the user chose.
    static func relaunchIfRestarting() {
        guard relaunchOnTerminate else { return }
        ghostty_host_relaunch_after_exit(Bundle.main.bundlePath)
    }
}
