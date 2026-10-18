import SwiftUI

/// Shared layout constants for the sidebar/tab bar — coastty's answer to a
/// CSS stylesheet's custom properties (`--radius: 12px`, reused everywhere
/// instead of typed out fresh each time). Change a value here once instead
/// of hunting down every place that used to hardcode it.
///
/// Colors already have this treatment (`CoasttyPalette`) — this is the same
/// idea, just for the corner radii and shapes used across
/// `CoasttySidebarView`/`CoasttyTabBarView`/etc.
///
/// There are two rounding vocabularies here, and mixing them is what makes
/// a layout look inconsistent even when every radius is "reasonable":
///
/// - **Regions** — list rows, selection backgrounds, the panels — take a
///   small fixed radius. They sit in a continuous list or hold other
///   content, and rounding them hard makes them read as detached floating
///   objects.
/// - **Controls** — tabs, pills, badges — are capsules. They're discrete
///   things you act on.
///
/// Finder is the reference: its sidebar selection is ~6pt on a 32pt row,
/// while the path-bar pill beside it, at essentially the same height, is a
/// full capsule. Roundness tracks what the element *is*, not how big it is.
enum CoasttyMetrics {
    /// The corner radius a row in one of the sidebar's lists uses for its
    /// hover/selected background — Spaces and Agents alike.
    ///
    /// Also keeps the curves concentric with the panel behind them:
    /// `panelCornerRadius` minus the 6pt the rows are inset by.
    static let listRowCornerRadius: CGFloat = 6

    /// The large rounded-card radius the sidebar's two panels
    /// (Spaces/Agents) use for their own outer corners.
    static let panelCornerRadius: CGFloat = 12

    /// The shape of a row in one of the sidebar's lists.
    static var listRowShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: listRowCornerRadius, style: .continuous)
    }

    /// The shape of one of the sidebar's rounded panels.
    static var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
    }

    /// The shape of a control — a tab, or anything else that reads as a
    /// discrete object rather than a region.
    ///
    /// A shape and not a radius, unlike the two above: a capsule's radius
    /// is always half its height, so there is no number to centralize. That
    /// height-dependence is exactly why regions can't use it - the same
    /// capsule rule applied to rows of different heights gives visibly
    /// different corners.
    static var controlShape: Capsule {
        Capsule(style: .continuous)
    }

    /// The type size for a row's primary line — Space row names, tab
    /// titles, and an Agent row's folder/tab name alike — so all three read
    /// at one consistent size instead of drifting apart as separate magic
    /// numbers.
    static let titleFontSize: CGFloat = 12
}
