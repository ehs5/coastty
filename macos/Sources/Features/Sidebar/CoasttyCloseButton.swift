import SwiftUI

/// The small "×" close control used by both tab items and Space rows —
/// issue #12 (coastty repo). Shared so both get the identical hover
/// treatment: a faint ring appears around the glyph and the glyph itself
/// brightens to the theme's primary text color, instead of just relying
/// on the parent row's own hover background to signal "clickable".
struct CoasttyCloseButton: View {
    let palette: CoasttyPalette
    let action: () -> Void

    private static let diameter: CGFloat = 16

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(isHovering ? palette.textPrimary : palette.textSecondary)
                .frame(width: Self.diameter, height: Self.diameter)
                .background(
                    Circle()
                        .strokeBorder(isHovering ? palette.textSecondary.opacity(0.4) : Color.clear, lineWidth: 1)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
