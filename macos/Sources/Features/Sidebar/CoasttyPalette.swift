import SwiftUI
import AppKit

/// Color tokens for coastty's sidebar and tab bar, drawn from Ghostty's own
/// live configured theme — issue #12 (coastty repo): "Sidebar colors ...
/// are drawn from Ghostty's own live configured theme/appearance, not a
/// fixed palette — it must look like part of the same app, not a visually
/// disconnected panel." The same requirement applies to the tab bar.
///
/// Every token below is derived from `Ghostty.Config`'s `background`,
/// `foreground`, and `palette` settings — never a literal hex constant —
/// so switching the user's configured theme (light, dark, or any of
/// Ghostty's many named themes) changes these automatically, with no
/// separate "coastty theme" to keep in sync.
struct CoasttyPalette {
    private let config: Ghostty.Config

    init(_ config: Ghostty.Config) {
        self.config = config
    }

    private var isDark: Bool {
        !OSColor(config.backgroundColor).isLightColor
    }

    // MARK: - Structural colors (background/foreground derived)

    /// Same background the terminal itself uses — this is what makes the
    /// sidebar and tab bar read as part of the same app rather than a
    /// bolted-on panel.
    var backgroundSidebar: Color { config.backgroundColor }

    /// A subtle step up from the background, for row hover — nudged
    /// toward white (dark themes) or black (light themes) rather than a
    /// fixed swatch, so it stays proportionate for any configured
    /// background brightness.
    var backgroundHover: Color {
        Self.mix(config.backgroundColor, toward: isDark ? .white : .black, amount: 0.08)
    }

    /// A slightly stronger step than hover, for the active tab / selected
    /// row.
    var backgroundSelected: Color {
        Self.mix(config.backgroundColor, toward: isDark ? .white : .black, amount: 0.14)
    }

    /// The tab bar's "+" button fill — deliberately always mixed toward
    /// *black*, unlike `backgroundHover`/`backgroundSelected` above (which
    /// lighten on dark themes). It's meant to read as a distinct, solid
    /// darker control, not a highlight, regardless of theme.
    var backgroundNewTabButton: Color {
        Self.mix(config.backgroundColor, toward: .black, amount: 0.18)
    }

    /// An inactive tab's resting-state fill — previously fully transparent
    /// (blending straight into the bar's own background until hovered);
    /// every tab now always has a visible card behind it. Also used as the
    /// tab *bar's own* background (see `CoasttyTabBarView.backgroundColor`)
    /// so the whole strip reads as one continuous tinted bar rather than
    /// a series of separately-colored islands.
    ///
    /// Same direction as `backgroundHover`/`backgroundSelected` (lightens
    /// on dark themes, unlike `backgroundNewTabButton`, which deliberately
    /// goes the other way) — a smaller step than `backgroundHover` (0.08),
    /// so resting < hover < selected forms one consistent, ordered family
    /// instead of resting being a different color relationship entirely.
    var backgroundTabResting: Color {
        Self.mix(config.backgroundColor, toward: isDark ? .white : .black, amount: 0.04)
    }

    var backgroundNewTabButtonHover: Color {
        Self.mix(config.backgroundColor, toward: .black, amount: 0.28)
    }

    /// A step up from the plain background, used only as the fill for
    /// the sidebar's own rounded "panel" card (see `CoasttySidebarView`).
    /// Matches `backgroundHover`'s own amount so the panel stays visibly
    /// distinct from the canvas around it at any `backgroundOpacity`.
    var backgroundSidebarPanel: Color {
        Self.mix(config.backgroundColor, toward: isDark ? .white : .black, amount: 0.08)
    }

    /// Hover fill for rows that sit directly on top of the sidebar panel
    /// (Space rows, Agent rows) — `backgroundHover` shares its mix amount
    /// with `backgroundSidebarPanel` above, so a row using it renders
    /// identical to the panel behind it and the hover reads as invisible.
    /// This one only needs to clear the panel's own amount while staying
    /// under `backgroundSelected`'s, so panel rows get a real resting →
    /// hover → selected progression.
    var backgroundRowHover: Color {
        Self.mix(config.backgroundColor, toward: isDark ? .white : .black, amount: 0.11)
    }

    var textPrimary: Color { config.foregroundColor }

    /// Foreground pulled partway toward the background — the classic way
    /// to derive a "secondary text" tone from a theme that only defines
    /// one foreground color.
    var textSecondary: Color {
        Self.mix(config.foregroundColor, toward: config.backgroundColor, amount: 0.35)
    }

    var textTertiary: Color {
        Self.mix(config.foregroundColor, toward: config.backgroundColor, amount: 0.55)
    }

    /// Reuses the same live-theme-derived divider color Ghostty already
    /// computes for split panes, so coastty's dividers match exactly.
    var divider: Color { config.splitDividerColor }

    // MARK: - Accent / state colors (ANSI palette derived)

    /// index 12 = bright blue in the standard 16-color ANSI layout.
    var accent: Color { paletteColor(12, fallback: textPrimary) }
    /// index 11 = bright yellow, matching herdr's `p.yellow` for a working
    /// agent. Deliberately not `accent`: the accent also drives unrelated
    /// chrome, and the working state needs to move independently of it.
    var stateWorking: Color { paletteColor(11, fallback: textPrimary) }
    /// index 14 = bright cyan, standing in for herdr's `p.teal` on the
    /// "finished, not looked at yet" state. Kept bright because this is the
    /// one idle state that still wants the eye.
    var stateDone: Color { paletteColor(14, fallback: textPrimary) }
    /// index 9 = bright red.
    var stateBlocked: Color { paletteColor(9, fallback: textPrimary) }
    /// index 2 = green (not bright green): the fully-resolved state, so it
    /// reads as settled next to the brighter states that still want
    /// attention. herdr colors both idle states and leaves only `Unknown`
    /// neutral, and this follows that.
    var stateIdle: Color { paletteColor(2, fallback: textPrimary) }

    private func paletteColor(_ index: Int, fallback: Color) -> Color {
        let palette = config.palette
        guard palette.indices.contains(index) else { return fallback }
        return palette[index]
    }

    /// Linearly blends `base` toward `mixColor` by `amount` (0...1) in
    /// sRGB space. Used instead of HSB brightness scaling so it behaves
    /// sanely even for a pure-black or pure-white configured background,
    /// where brightness-based scaling can't move at all.
    private static func mix(_ base: Color, toward mixColor: Color, amount: Double) -> Color {
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        var mr: CGFloat = 0, mg: CGFloat = 0, mb: CGFloat = 0, ma: CGFloat = 0
        let baseNS = (OSColor(base).usingColorSpace(.sRGB) ?? OSColor(base))
        let mixNS = (OSColor(mixColor).usingColorSpace(.sRGB) ?? OSColor(mixColor))
        baseNS.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        mixNS.getRed(&mr, green: &mg, blue: &mb, alpha: &ma)

        let t = CGFloat(min(max(amount, 0), 1))
        return Color(
            red: Double(br + (mr - br) * t),
            green: Double(bg + (mg - bg) * t),
            blue: Double(bb + (mb - bb) * t)
        )
    }
}
