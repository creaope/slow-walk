import SlowWalkClientCore
import SlowWalkDomain
import SwiftUI

/// Reminder-level badge that never relies on color alone.
///
/// Four independent channels carry the level: a distinct SF Symbol silhouette,
/// a text shape token, the canonical level name, and the canonical attention
/// semantics. `yellow` and `orange` therefore stay distinguishable in
/// grayscale, under any color-vision deficiency, and with symbols unavailable.
public struct RiskLevelBadge: View {
    private let presentation: RiskPresentation

    public init(presentation: RiskPresentation) {
        self.presentation = presentation
    }

    public init(level: RiskLevel) {
        presentation = RiskPresentation(level: level)
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(
                systemName: MedicinePresentationCopy
                    .symbolName(presentation.level)
            )
            .imageScale(.medium)

            Text(
                MedicinePresentationCopy.shapeToken(
                    presentation.level
                )
            )

            Text(
                MedicinePresentationCopy.levelName(
                    presentation.level
                )
            )
            .fontWeight(.semibold)

            Text(
                MedicinePresentationCopy.attentionName(
                    presentation.attention
                )
            )
        }
        .font(.subheadline)
        .foregroundStyle(foregroundStyle)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay {
            // A visible border keeps the badge readable when the fill color
            // is not perceived.
            Capsule().strokeBorder(
                foregroundStyle,
                lineWidth: borderWidth
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            MedicinePresentationCopy
                .riskAccessibilityLabel(presentation)
        )
    }

    /// Color reinforces the level; it is never the only carrier.
    private var foregroundStyle: Color {
        switch presentation.level {
        case .green:
            return .green
        case .yellow:
            return .yellow
        case .orange:
            return .orange
        case .red:
            return .red
        }
    }

    /// A thicker border for levels that require attention gives a further
    /// non-color cue.
    private var borderWidth: CGFloat {
        presentation.requiresImmediateAttention ? 2 : 1
    }
}
