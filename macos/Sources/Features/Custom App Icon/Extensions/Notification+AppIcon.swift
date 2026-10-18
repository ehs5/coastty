import AppKit

extension Notification.Name {
    /// Distributed Notification for DockTilePlugin to update icon
    ///
    /// coastty -> DockTilePlugin
    ///
    /// Named for coastty, not "com.mitchellh.ghostty.iconDidChange":
    /// distributed notifications are system-wide, so sharing upstream's name
    /// with a side-by-side Ghostty install has each app's icon changes
    /// driving the other's dock tile.
    static let coasttyIconDidChange = Notification.Name("com.espensteen.coastty.iconDidChange")
}
