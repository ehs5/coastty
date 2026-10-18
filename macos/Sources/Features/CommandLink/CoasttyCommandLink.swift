import AppKit
import GhosttyKit

/// The app menu's install and uninstall of the `coastty` command for other terminals: Zig decides what may change at the link path, this asks for admin rights when needed and reports the outcome.
enum CoasttyCommandLink {
    static let linkPath = "/usr/local/bin/coastty"

    /// How an admin command ended: the link result to report and, on failure, the message to show.
    private typealias AdminOutcome = (result: ghostty_command_link_result_e, error: String)

    /// Wraps `value` in single quotes for /bin/sh.
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Makes `value` an AppleScript string literal.
    private static func appleScriptQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    /// The alert text for a failure: the admin command's own message, or a generic hint when there is none.
    private static func failureText(_ error: String) -> String {
        if error.isEmpty { return "Something went wrong changing \(linkPath). Check that /usr/local/bin is a folder you can write to." }
        return error
    }

    /// Shows a modal alert.
    @MainActor
    private static func showAlert(_ title: String, _ text: String, style: NSAlert.Style = .warning) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = style
        alert.runModal()
    }

    /// Tells the user how an install went; `error` is the admin command's message, if it failed.
    @MainActor
    private static func reportInstall(_ result: ghostty_command_link_result_e, error: String = "") {
        switch result {
        case GHOSTTY_COMMAND_LINK_OK:
            showAlert(
                "The 'coastty' command is installed",
                "\(linkPath) now points to this copy of Coastty. Open a new terminal window to use it.",
                style: .informational)

        case GHOSTTY_COMMAND_LINK_FOREIGN:
            showAlert(
                "Couldn't install the 'coastty' command",
                "\(linkPath) already exists and doesn't belong to Coastty, so it was left alone. Remove it and try again.")

        case GHOSTTY_COMMAND_LINK_TRANSLOCATED:
            showAlert(
                "Move Coastty to Applications first",
                "macOS is running this copy of Coastty from a temporary location, so a link to it would stop working. Move Coastty to the Applications folder, open it from there and try again.")

        default:
            showAlert("Couldn't install the 'coastty' command", failureText(error))
        }
    }

    /// Tells the user how an uninstall went; `error` is the admin command's message, if it failed.
    @MainActor
    private static func reportUninstall(_ result: ghostty_command_link_result_e, error: String = "") {
        switch result {
        case GHOSTTY_COMMAND_LINK_OK:
            showAlert("The 'coastty' command is uninstalled", "\(linkPath) has been removed.", style: .informational)

        case GHOSTTY_COMMAND_LINK_NOT_INSTALLED:
            showAlert("The 'coastty' command isn't installed", "There is nothing at \(linkPath) to remove.", style: .informational)

        case GHOSTTY_COMMAND_LINK_FOREIGN:
            showAlert(
                "Couldn't uninstall the 'coastty' command",
                "\(linkPath) doesn't point to Coastty, so it was left alone.")

        default:
            showAlert("Couldn't uninstall the 'coastty' command", failureText(error))
        }
    }

    /// Reads how a finished osascript run went; nil when the user cancelled the password prompt.
    private static func adminOutcome(of process: Process, stderr: Pipe) -> AdminOutcome? {
        let status = process.terminationStatus
        if status == 0 { return (GHOSTTY_COMMAND_LINK_OK, "") }

        let data = stderr.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        // -128 is AppleScript's "User canceled", the user's own choice rather than a failure.
        if message.contains("(-128)") { return nil }
        return (GHOSTTY_COMMAND_LINK_FAILED, message.isEmpty ? "The admin command exited with status \(status)." : message)
    }

    /// Runs `command` as root behind the system's admin password prompt; nil when the user cancels it.
    private static func runAsAdmin(_ command: String, prompt: String) async -> AdminOutcome? {
        let script = "do shell script \(appleScriptQuoted(command)) with prompt \(appleScriptQuoted(prompt)) with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: adminOutcome(of: $0, stderr: stderr)) }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: (GHOSTTY_COMMAND_LINK_FAILED, error.localizedDescription))
            }
        }
    }

    /// Points the link at this app's executable, asking for admin rights only when the folder needs them.
    @MainActor
    static func install() async {
        // Without the executable's own path there is nothing to link to.
        guard let target = Bundle.main.executablePath else {
            reportInstall(GHOSTTY_COMMAND_LINK_FAILED)
            return
        }

        let result = ghostty_command_link_install(linkPath, target)
        if result != GHOSTTY_COMMAND_LINK_NEEDS_ADMIN {
            reportInstall(result)
            return
        }

        // Re-checked as root, since the path can change while the password prompt is open.
        let guardCommand = "if [ -e \(linkPath) ] && [ ! -L \(linkPath) ]; then echo '\(linkPath) is not a link, so it was left alone.' >&2; exit 1; fi"
        let command = "\(guardCommand); /bin/mkdir -p /usr/local/bin && /bin/ln -sfn \(shellQuoted(target)) \(linkPath)"
        let outcome = await runAsAdmin(command, prompt: "Coastty wants to install the 'coastty' command in /usr/local/bin.")

        // A cancelled password prompt is the user's choice, so there is nothing to report.
        guard let outcome else { return }
        reportInstall(outcome.result, error: outcome.error)
    }

    /// Removes the link if it points into a coastty bundle, asking for admin rights only when the folder needs them.
    @MainActor
    static func uninstall() async {
        let result = ghostty_command_link_uninstall(linkPath)
        if result != GHOSTTY_COMMAND_LINK_NEEDS_ADMIN {
            reportUninstall(result)
            return
        }

        // Re-checked as root, since the path can change while the password prompt is open.
        let command = "case \"$(/usr/bin/readlink \(linkPath))\" in *.app/Contents/MacOS/coastty) /bin/rm -f \(linkPath) ;; *) echo '\(linkPath) is not a coastty link, so it was left alone.' >&2; exit 1 ;; esac"
        let outcome = await runAsAdmin(command, prompt: "Coastty wants to remove the 'coastty' command from /usr/local/bin.")

        // A cancelled password prompt is the user's choice, so there is nothing to report.
        guard let outcome else { return }
        reportUninstall(outcome.result, error: outcome.error)
    }
}
