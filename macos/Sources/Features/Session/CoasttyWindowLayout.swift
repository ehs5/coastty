import Foundation

/// What one window makes of the model coastty-host owns: where it sits, which Spaces it shows, and where the split dividers are.
///
/// Deliberately holds no Spaces, tabs or pane membership - those exist whether or not any window is showing them, and the daemon owns them. What is here is only meaningful relative to a window on a screen, which is why the daemon never sees it.
struct CoasttyWindowLayout: Codable {
    /// The window's own id, kept across launches so layout commands can name it. Nil in a layout saved before windows had one.
    var windowID: String?
    var frame: NSRect
    var tabColor: TerminalTabColor

    /// Which of the model's Spaces this window shows, in the order it shows them. Ids the model no longer has are skipped on restore.
    var spaces: [Space]

    /// Index into `spaces` of the one showing.
    var activeSpaceIndex: Int

    struct Space: Codable {
        var spaceID: String

        /// Index into the model's tabs for this Space.
        var activeTabIndex: Int
        var tabs: [Tab]
    }

    struct Tab: Codable {
        var tabID: String

        /// The pane that regains focus when this tab is shown again.
        var focusedPaneID: String?

        /// How this tab's panes are arranged. Nil means a single pane, which needs no arrangement.
        var shape: Shape?
    }

    /// The shape of a tab's splits, with nothing about which panes fill it: leaves are slots, taken in order from the panes the model says the tab holds.
    ///
    /// Keeping identity out is what lets the daemon own membership while a window keeps its own geometry - the same tab can be arranged differently in two windows, and a pane moving between tabs does not have to be reconciled here.
    indirect enum Shape: Codable {
        case slot
        case split(direction: Direction, ratio: Double, left: Shape, right: Shape)

        enum Direction: String, Codable {
            case horizontal
            case vertical
        }

        /// How many panes this shape arranges.
        var slotCount: Int {
            switch self {
            case .slot: return 1
            case .split(_, _, let left, let right): return left.slotCount + right.slotCount
            }
        }
    }
}
