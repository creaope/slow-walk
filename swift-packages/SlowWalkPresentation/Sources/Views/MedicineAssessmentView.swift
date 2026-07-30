import SlowWalkClientCore
import SlowWalkDomain
import SwiftUI

/// The medicine assessment page.
///
/// It renders exactly one canonical `MedicineDisplayState`. Notably absent:
/// no `dynamicTypeSize` clamp anywhere, so Accessibility text sizes work; and
/// no `accessibilityElement(children: .combine)` on any container that holds
/// the retry or confirm Button.
public struct MedicineAssessmentView: View {
    private let state: MedicineDisplayState
    private let retryAction: (() -> Void)?
    private let confirmAction: (() -> Void)?

    public init(
        state: MedicineDisplayState,
        retryAction: (() -> Void)? = nil,
        confirmAction: (() -> Void)? = nil
    ) {
        self.state = state
        self.retryAction = retryAction
        self.confirmAction = confirmAction
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content
            }
            .frame(
                maxWidth: .infinity,
                alignment: .leading
            )
            .padding(20)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state.variant {
        case .idle:
            statusText(MedicinePresentationCopy.idleText)

        case .recognizing:
            progressText(
                MedicinePresentationCopy.recognizingText
            )

        case .assessing:
            progressText(
                MedicinePresentationCopy.assessingText
            )

        case .cancelled:
            statusText(
                MedicinePresentationCopy.cancelledText
            )

        case .timeout, .failed:
            failureContent

        case .normal,
             .ambiguous,
             .healthWarning,
             .knowledgeWarning,
             .redRisk,
             .elevatedRisk:
            resultContent
        }
    }

    // MARK: - Result

    @ViewBuilder
    private var resultContent: some View {
        if let actionCard = state.actionCard {
            MedicineActionCardView(
                actionCard: actionCard,
                requiresMedicineConfirmation:
                    state.requiresMedicineConfirmation,
                demoDisclaimer: state.demoDisclaimer,
                confirmAction: confirmAction
            )
        } else {
            // A confirmation can be required with no response at all. The page
            // must not fabricate a card, a level, or an instruction.
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    MedicinePresentationCopy
                        .confirmationRequiredHeading
                )
                .font(.title3)
                .fontWeight(.semibold)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
                .accessibilityAddTraits(.isHeader)

                statusText(
                    MedicinePresentationCopy
                        .noResultAvailableText
                )

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
    }

    // MARK: - Failure

    @ViewBuilder
    private var failureContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Text siblings each stay their own element; the Button below is
            // never merged into them.
            if let failure = state.failure {
                HStack(
                    alignment: .firstTextBaseline,
                    spacing: 8
                ) {
                    Image(
                        systemName:
                            "exclamationmark.triangle.fill"
                    )
                    .accessibilityHidden(true)

                    Text(
                        MedicinePresentationCopy
                            .failureName(
                                failure.failure.kind
                            )
                    )
                    .fixedSize(
                        horizontal: false,
                        vertical: true
                    )
                }
                .accessibilityElement(children: .combine)
            }

            statusText(
                MedicinePresentationCopy
                    .noResultAvailableText
            )

            if state.failure?.allowsRetry == true,
               let retryAction
            {
                Button(
                    MedicinePresentationCopy
                        .retryButtonTitle,
                    action: retryAction
                )
                .buttonStyle(.bordered)
                .medicineMinimumHitTarget()
                .accessibilityHint(
                    MedicinePresentationCopy
                        .retryAccessibilityHint
                )
            }
        }
    }

    // MARK: - Support

    private func statusText(
        _ text: String
    ) -> some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func progressText(
        _ text: String
    ) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .accessibilityHidden(true)

            Text(text)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
        }
        .accessibilityElement(children: .combine)
    }
}
