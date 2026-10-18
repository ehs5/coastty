import Foundation

/// On-disk shape of a whole coastty session, modelled on herdr's
/// `SessionSnapshot`. Reuses `TerminalController.UndoState` per window
/// instead of a parallel DTO - it already carries what a window needs to
/// be rebuilt, and is already exercised by close-window undo.
struct CoasttySessionSnapshot: Codable {
    /// Mirrors herdr's `SNAPSHOT_VERSION` - lets a newer file be ignored
    /// instead of misread.
    static let currentVersion = 1

    var version: Int
    var windows: [TerminalController.UndoState]

    init(windows: [TerminalController.UndoState]) {
        self.version = Self.currentVersion
        self.windows = windows
    }
}
