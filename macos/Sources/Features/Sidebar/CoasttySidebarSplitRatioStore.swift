import Foundation

/// Persists the height ratio between coastty's sidebar's "Spaces" and
/// "Agents" sections across launches. Defaults to giving "Agents" exactly
/// the bottom half of the sidebar, per the visual reference.
final class CoasttySidebarSplitRatioStore: ObservableObject {
    /// Shared across every sidebar in the app — there is one divider
    /// position, not one per window, matching how the visual reference's
    /// prototype persisted a single `splitRatio` across renders.
    static let shared = CoasttySidebarSplitRatioStore()

    private static let defaultsKey = "CoasttySidebarAgentsRatio"
    private static let defaultRatio: CGFloat = 0.5
    private static let minRatio: CGFloat = 0.15
    private static let maxRatio: CGFloat = 0.85

    private let defaults: UserDefaults

    /// The fraction of the sidebar's height given to the "Agents" section.
    /// The "Spaces" section gets the remainder.
    @Published private(set) var agentsRatio: CGFloat

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.object(forKey: Self.defaultsKey) as? Double {
            self.agentsRatio = Self.clamp(CGFloat(stored))
        } else {
            self.agentsRatio = Self.defaultRatio
        }
    }

    /// Updates the in-memory ratio immediately, for live feedback while
    /// the divider is being dragged. Does not touch persisted state — call
    /// `persist()` once the drag ends.
    func updateRatio(_ ratio: CGFloat) {
        agentsRatio = Self.clamp(ratio)
    }

    /// Persists the current ratio so it survives relaunch. Intended to be
    /// called once per drag gesture, not on every intermediate frame.
    func persist() {
        defaults.set(Double(agentsRatio), forKey: Self.defaultsKey)
    }

    private static func clamp(_ ratio: CGFloat) -> CGFloat {
        min(maxRatio, max(minRatio, ratio))
    }
}
