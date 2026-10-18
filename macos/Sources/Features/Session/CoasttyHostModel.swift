import Foundation
import GhosttyKit

/// The model coastty-host owns, as this app reads it: which Spaces exist, the tabs in each, and the panes in each tab.
///
/// This is the structure half of a session. What a window makes of it - where it sits, which Spaces it shows, where the split dividers are - is the GUI's own, and lives in `CoasttyWindowLayout`.
struct CoasttyHostModel: Decodable {
    /// Identifies the daemon's current run. A different one than the app last saw means the daemon restarted, so anything the app cached about it is stale.
    let runID: String

    /// Increases on every change to the model.
    let revision: Int

    let spaces: [Space]

    struct Space: Decodable {
        let id: String
        let name: String

        /// Derived from the Space's starter pane, used when the user has not named it.
        let defaultName: String
        let hidden: Bool
        let restoreIndex: Int
        let tabs: [Tab]

        enum CodingKeys: String, CodingKey {
            case id, name, hidden, tabs
            case defaultName = "default_name"
            case restoreIndex = "restore_index"
        }
    }

    struct Tab: Decodable {
        let id: String
        let name: String
        let panes: [Pane]
    }

    struct Pane: Decodable {
        /// The daemon's id, e.g. `surface:<uuid>`.
        let id: String

        /// Where a fresh shell comes back in, if this pane's process is gone.
        let directory: String

        /// What the live process last set, empty when it has set none.
        let title: String
    }

    enum CodingKeys: String, CodingKey {
        case revision, spaces
        case runID = "run_id"
    }

    /// True when the daemon holds nothing - a first run, or a dev daemon that has never been told anything.
    var isEmpty: Bool { spaces.isEmpty }

    /// Asks coastty-host for its model, starting it first if it is not running: a window is built from what the daemon holds, so waiting for a pane to need one would be backwards.
    ///
    /// Nil means no daemon answered, which is a reason to leave the existing session alone rather than to treat the model as empty.
    static func fetch() -> CoasttyHostModel? {
        guard ghostty_host_ensure_running() else { return nil }

        var capacity = 64 * 1024
        for _ in 0..<2 {
            var buffer = [CChar](repeating: 0, count: capacity)
            let length = ghostty_host_model_snapshot(&buffer, capacity)
            guard length > 0 else { return nil }

            // Too small: the call reports what it needed, so the retry fits.
            if length > capacity {
                capacity = length
                continue
            }

            let bytes = buffer[0..<length].map { UInt8(bitPattern: $0) }
            return try? JSONDecoder().decode(CoasttyHostModel.self, from: Data(bytes))
        }
        return nil
    }
}
