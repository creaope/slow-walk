import SlowWalkClientCore
import SlowWalkDomain
import SwiftUI

/// Renders one canonical `ActionCard` verbatim.
///
/// Every medical sentence on screen is a canonical field: `title`,
/// `primaryInstruction`, each entry of `warnings`, each `recommendedActions`
/// case, each `sourceReferences` entry, and `riskLevel`. The view adds section
/// headings only.
///
/// Accessibility rules enforced here:
///
/// - No `dynamicTypeSize` clamp, so Accessibility text sizes are honored.
/// - Each canonical field is its own accessibility element, so VoiceOver reads
///   the title, the primary instruction, the warnings, the actions, and the
///   sources separately.
/// - `accessibilityElement(children: .combine)` is never applied to a
///   container that holds a control.
public struct MedicineActionCardView: View {
    private let actionCard: ActionCard
    private let requiresMedicineConfirmation: Bool
    private let demoDisclaimer: String?
    private let confirmAction: (() -> Void)?

    public init(
        actionCard: ActionCard,
        requiresMedicineConfirmation: Bool,
        demoDisclaimer: String? = nil,
        confirmAction: (() -> Void)? = nil
    ) {
        self.actionCard = actionCard
        self.requiresMedicineConfirmation =
            requiresMedicineConfirmation
        self.demoDisclaimer = demoDisclaimer
        self.confirmAction = confirmAction
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let disclaimer = demoDisclaimer {
                demoDisclaimerBanner(disclaimer)
            }

            header
            primaryInstruction

            if actionCard.mustConfirmMedicine {
                mustConfirmBadge
            }

            if !actionCard.warnings.isEmpty {
                warningsSection
            }

            if !actionCard.recommendedActions.isEmpty {
                recommendedActionsSection
            }

            sourceReferencesSection

            if requiresMedicineConfirmation {
                confirmationSection
            }
        }
    }

    // MARK: - Demo disclaimer

    /// Dedicated banner rendered only when the caller explicitly supplies a
    /// demo disclaimer string.  Production assessments never pass one, so
    /// real users never see a fake "DEMO" label.
    private func demoDisclaimerBanner(
        _ text: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(text)
                .font(.footnote)
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.secondary, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        // The banner is its own accessibility element — never merged into
        // a header, a hint, or a warning.
    }

    // MARK: - Must confirm medicine badge

    /// Rendered only when the canonical `ActionCard.mustConfirmMedicine` is
    /// `true`, independently of the coordinator-confirmation requirement.
    /// The two signals are distinct: a card can require confirmation at any
    /// risk level, and a confirmation can be required with no card at all.
    private var mustConfirmBadge: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "person.text.rectangle.fill")
                .accessibilityHidden(true)

            Text(MedicinePresentationCopy.mustConfirmLabel)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.secondary, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            MedicinePresentationCopy.mustConfirmLabel
        )
    }

    // MARK: - Header

    private var header: some View {
        // Grouped as one element without `.combine` on any container holding a
        // control: this subtree has none.
        VStack(alignment: .leading, spacing: 8) {
            Text(actionCard.title)
                .font(.title2)
                .fontWeight(.semibold)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
                .accessibilityAddTraits(.isHeader)

            RiskLevelBadge(level: actionCard.riskLevel)
        }
    }

    // MARK: - Primary instruction

    private var primaryInstruction: some View {
        Text(actionCard.primaryInstruction)
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(
                """
                \(MedicinePresentationCopy
                    .primaryInstructionHeading): \
                \(actionCard.primaryInstruction)
                """
            )
    }

    // MARK: - Warnings

    private var warningsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading(
                MedicinePresentationCopy.warningsHeading
            )

            // Each canonical warning stays a separate element so VoiceOver
            // never merges two distinct warnings into one utterance.
            ForEach(
                Array(actionCard.warnings.enumerated()),
                id: \.offset
            ) { _, warning in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(
                        systemName:
                            "exclamationmark.triangle.fill"
                    )
                    .accessibilityHidden(true)

                    Text(warning)
                        .fixedSize(
                            horizontal: false,
                            vertical: true
                        )
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: - Recommended actions

    private var recommendedActionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading(
                MedicinePresentationCopy
                    .recommendedActionsHeading
            )

            ForEach(
                actionCard.recommendedActions,
                id: \.rawValue
            ) { action in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "checklist")
                        .accessibilityHidden(true)

                    Text(
                        MedicinePresentationCopy
                            .actionName(action)
                    )
                    .fixedSize(
                        horizontal: false,
                        vertical: true
                    )
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: - Source references

    private var sourceReferencesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading(
                MedicinePresentationCopy
                    .sourceReferencesHeading
            )

            if actionCard.sourceReferences.isEmpty {
                Text(
                    MedicinePresentationCopy
                        .noSourceReferencesText
                )
                .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(
                    Array(
                        actionCard.sourceReferences
                            .enumerated()
                    ),
                    id: \.offset
                ) { _, reference in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            MedicinePresentationCopy
                                .sourceSummary(reference)
                        )
                        .fixedSize(
                            horizontal: false,
                            vertical: true
                        )

                        Text(
                            MedicinePresentationCopy
                                .sourceVersionSummary(
                                    reference
                                )
                        )
                        .font(.footnote)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: - Confirmation

    private var confirmationSection: some View {
        // The heading is a sibling of the Button, never merged with it, so the
        // Button stays an independent VoiceOver control.
        VStack(alignment: .leading, spacing: 12) {
            Text(
                MedicinePresentationCopy
                    .confirmationRequiredHeading
            )
            .font(.subheadline)
            .fontWeight(.semibold)
            .fixedSize(horizontal: false, vertical: true)

            if let confirmAction {
                Button(
                    MedicinePresentationCopy
                        .confirmMedicineButtonTitle,
                    action: confirmAction
                )
                .buttonStyle(.bordered)
                .medicineMinimumHitTarget()
                .accessibilityHint(
                    MedicinePresentationCopy
                        .confirmMedicineAccessibilityHint
                )
            }
        }
    }

    // MARK: - Support

    private func sectionHeading(
        _ text: String
    ) -> some View {
        Text(text)
            .font(.subheadline)
            .fontWeight(.semibold)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// Guarantees the documented 44×44 point minimum touch target.
    func medicineMinimumHitTarget() -> some View {
        frame(
            minWidth: MedicineHitTarget.minimumSide,
            minHeight: MedicineHitTarget.minimumSide
        )
        .contentShape(Rectangle())
    }
}

/// The minimum interactive control side length, in points.
public enum MedicineHitTarget {
    public static let minimumSide: CGFloat = 44
}
