import AppKit

/// Persists the sidebar's own width across launches.
///
/// Deliberately shaped like `CoasttySidebarSplitRatioStore` (one shared
/// instance, clamp on write, an explicit `persist()` separate from the live
/// update): both describe the same kind of state — a sidebar dimension the
/// user drags — so they behave the same way.
final class CoasttySidebarWidthStore: ObservableObject {
    /// Shared across every window: dragging one window's sidebar sets the
    /// width new windows open at, matching how the Spaces/Agents divider
    /// already behaves.
    static let shared = CoasttySidebarWidthStore()

    private static let defaultsKey = "CoasttySidebarWidth"

    private let defaults: UserDefaults

    /// The sidebar's current width in points.
    @Published private(set) var width: CGFloat

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.object(forKey: Self.defaultsKey) as? Double {
            // Only the floor is applied here — the ceiling depends on the
            // window's own width, and there is no window yet.
            self.width = max(CoasttySidebarView.minimumWidth, CGFloat(stored))
        } else {
            self.width = CoasttySidebarView.defaultWidth
        }
    }

    /// Updates the in-memory width immediately, for live feedback while the
    /// sidebar's edge is being dragged. Does not touch persisted state —
    /// call `persist()` once the drag ends.
    ///
    /// - Parameter maximum: The ceiling to clamp against, supplied by the
    ///   caller because it's derived from the window the drag is happening
    ///   in, which this store has no view of.
    func updateWidth(_ width: CGFloat, maximum: CGFloat) {
        // A window narrower than twice the minimum would put the ceiling
        // below the floor, leaving the clamp inverted.
        let ceiling = max(CoasttySidebarView.minimumWidth, maximum)
        self.width = min(ceiling, max(CoasttySidebarView.minimumWidth, width))
    }

    /// Persists the current width so it survives relaunch. Intended to be
    /// called once per drag gesture, not on every intermediate frame.
    func persist() {
        defaults.set(Double(width), forKey: Self.defaultsKey)
    }

    /// Puts the sidebar back to the width it ships at, for the View menu's
    /// "Reset Sidebar Width". Every window follows, since they all observe
    /// this one store.
    func resetToDefault() {
        width = CoasttySidebarView.defaultWidth
        persist()
    }
}
