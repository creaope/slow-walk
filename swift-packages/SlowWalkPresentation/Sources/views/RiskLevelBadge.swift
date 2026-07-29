import SwiftUI

/// A colored badge displaying the current risk level.
/// Adapts to both light and dark mode automatically via Color.
public struct RiskLevelBadge: View {
    public let level: DisplayRiskLevel
    public var showLabel: Bool

    public init(level: DisplayRiskLevel, showLabel: Bool = true) {
        self.level = level
        self.showLabel = showLabel
    }

    public var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(level.displayColor)
                .frame(width: 10, height: 10)

            if showLabel {
                Text(level.displayLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(level.displayColor.opacity(0.15))
        )
        .accessibilityLabel("风险等级：\(level.displayLabel)")
        .accessibilityAddTraits(level == .highRed ? .isButton : [])
    }
}

#Preview {
    VStack(spacing: 12) {
        RiskLevelBadge(level: .lowGreen)
        RiskLevelBadge(level: .yellow)
        RiskLevelBadge(level: .orange)
        RiskLevelBadge(level: .highRed)
    }
    .padding()
    #if canImport(UIKit)
    .background(Color(.systemBackground))
    #else
    .background(Color(nsColor: .windowBackgroundColor))
    #endif
}
