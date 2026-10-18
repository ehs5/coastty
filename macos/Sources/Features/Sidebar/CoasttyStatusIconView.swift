import SwiftUI

/// One of coastty's status icons — reproducing the visual reference
/// exactly, not reinterpreting it:
///
/// - `.done`, `.idle`, `.blocked` are plain circles, no glow.
/// - `.working` is a small square outline with a dashed stroke that
///   animates around its actual perimeter — real corners, not a smooth
///   rotation.
///
/// `nil` renders the neutral dot used when a space has no agent running
/// in it at all.
/// Where a status icon is being drawn. herdr renders the same state
/// differently in its agents list than in its space rollups, and coastty
/// follows: the agents list gets the expressive form (an animated working
/// indicator, a checkmark), while tab and space rows get a plain filled
/// dot that stays readable at a glance among many.
enum CoasttyStatusIconContext {
    case agents
    case compact
}

struct CoasttyStatusIconView: View {
    let status: CoasttyAgentStatus
    let palette: CoasttyPalette
    var context: CoasttyStatusIconContext = .compact

    static let diameter: CGFloat = 7

    var body: some View {
        switch status {
        case .working:
            if context == .agents {
                CoasttyWorkingIndicatorView(color: palette.stateWorking)
            } else {
                Circle()
                    .fill(palette.stateWorking)
                    .frame(width: Self.diameter, height: Self.diameter)
            }
        case .done:
            Circle()
                .fill(palette.stateDone)
                .frame(width: Self.diameter, height: Self.diameter)
        case .idle:
            if context == .agents {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(palette.stateIdle)
                    .frame(width: Self.diameter, height: Self.diameter)
            } else {
                // Hollow, matching herdr's `○` for a seen idle agent: the
                // filled dot is reserved for `.done`, so "finished, go look"
                // and "finished, already looked" stay distinguishable at a
                // glance even though both are green.
                Circle()
                    .strokeBorder(palette.stateIdle, lineWidth: 1.5)
                    .frame(width: Self.diameter, height: Self.diameter)
            }
        case .blocked:
            Circle()
                .fill(palette.stateBlocked)
                .frame(width: Self.diameter, height: Self.diameter)
        case .unknown:
            Circle()
                .fill(palette.textTertiary.opacity(0.35))
                .frame(width: Self.diameter, height: Self.diameter)
        }
    }
}

/// The "Working" status icon: a small square outline whose dashed stroke
/// animates around the square's actual perimeter. The dash/gap lengths (8pt
/// on, 24pt off) sum to exactly the perimeter of the square they trace, so
/// exactly one dash segment is visible at a time as it travels around the
/// four real corners — matching the visual reference's `snake-dash`
/// keyframe animation (`stroke-dashoffset` on an SVG `<rect>`), not a
/// circular spinner.
struct CoasttyWorkingIndicatorView: View {
    let color: Color

    private let side: CGFloat = 8
    private let strokeWidth: CGFloat = 1.6
    private var perimeter: CGFloat { side * 4 }

    @State private var dashPhase: CGFloat = 0

    var body: some View {
        Rectangle()
            .stroke(
                color,
                style: StrokeStyle(lineWidth: strokeWidth, dash: [8, 24], dashPhase: dashPhase)
            )
            .frame(width: side, height: side)
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    dashPhase = -perimeter
                }
            }
    }
}
