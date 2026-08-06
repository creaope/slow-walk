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
        Group {
            if let disclaimer = demoDisclaimer {
                Section {
                    MedicineDemoDisclaimerRow(text: disclaimer)
                }
            }

            Section {
                Text(actionCard.title)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                RiskLevelBadge(level: actionCard.riskLevel)

                if actionCard.mustConfirmMedicine {
                    mustConfirmRow
                }
            }

            Section {
                primaryInstructionRow
            } header: {
                sectionHeading(
                    MedicinePresentationCopy
                        .primaryInstructionHeading
                )
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

    // MARK: - Must confirm medicine

    private var mustConfirmRow: some View {
        Label {
            Text(MedicinePresentationCopy.mustConfirmLabel)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "person.text.rectangle")
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            MedicinePresentationCopy.mustConfirmLabel
        )
    }

    // MARK: - Primary instruction

    private var primaryInstructionRow: some View {
        Label {
            Text(actionCard.primaryInstruction)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "arrow.forward.circle")
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            """
            \(MedicinePresentationCopy.primaryInstructionHeading): \
            \(actionCard.primaryInstruction)
            """
        )
    }

    // MARK: - Warnings

    private var warningsSection: some View {
        Section {
            // Each canonical warning stays a separate element so VoiceOver
            // never merges two distinct warnings into one utterance.
            ForEach(
                Array(actionCard.warnings.enumerated()),
                id: \.offset
            ) { _, warning in
                Label {
                    Text(warning)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            sectionHeading(
                MedicinePresentationCopy.warningsHeading
            )
        }
    }

    // MARK: - Recommended actions

    private var recommendedActionsSection: some View {
        Section {
            ForEach(
                actionCard.recommendedActions,
                id: \.rawValue
            ) { action in
                Label {
                    Text(
                        MedicinePresentationCopy
                            .actionName(action)
                    )
                    .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checklist")
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            sectionHeading(
                MedicinePresentationCopy
                    .recommendedActionsHeading
            )
        }
    }

    // MARK: - Source references

    private var sourceReferencesSection: some View {
        Section {
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
        } header: {
            sectionHeading(
                MedicinePresentationCopy
                    .sourceReferencesHeading
            )
        }
    }

    // MARK: - Confirmation

    private var confirmationSection: some View {
        Section {
            Label {
                Text(
                    MedicinePresentationCopy
                        .confirmationRequiredHeading
                )
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "questionmark.circle")
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)

            if let confirmAction {
                Button(action: confirmAction) {
                    Label(
                        MedicinePresentationCopy
                            .confirmMedicineButtonTitle,
                        systemImage: "checkmark.circle"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
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

/// Standard form row used wherever a caller supplies demo assessment data.
struct MedicineDemoDisclaimerRow: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
                .font(.footnote)
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
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
