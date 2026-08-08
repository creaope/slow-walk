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
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    """
                    \(MedicinePresentationCopy.shapeToken(
                        presentation.level
                    )) \(MedicinePresentationCopy.levelName(
                        presentation.level
                    ))
                    """
                )
                .font(.headline)

                Text(
                    MedicinePresentationCopy.attentionName(
                        presentation.attention
                    )
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        } icon: {
            Image(
                systemName: MedicinePresentationCopy
                    .symbolName(presentation.level)
            )
            .imageScale(.large)
            .foregroundStyle(foregroundStyle)
            .accessibilityHidden(true)
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
}
