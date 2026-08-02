import SwiftUI

/// What the person is shown while an assessment is pending or its result is
/// waiting for the later presentation step.
///
/// This replaces the placeholder that stood where a care action would go. That
/// placeholder was titled "用药提示" and led to a "知道了，继续出发" button, so a
/// confirmed medicine *name* produced something that looked like a care action
/// and permitted departure. This panel is the opposite by design: it describes
/// the current canonical lifecycle state and offers only ways back.
///
/// Deliberately absent, and to remain absent until the later result-presentation
/// step is implemented:
/// - risk levels, severity semantics, and any colour mapping
/// - warnings, dosage, and source references
/// - medicine wording drawn from a knowledge source
/// - any control that continues the outing
///
/// The formal `MedicineActionCard` is owned by `SlowWalkPresentation`. C1 can
/// state that a result exists, but cannot claim the later showing step occurred.
struct MedicineAssessmentPendingPanel: View {
    let gate: MedicineAssessmentGate
    /// The assessment capability's real state, supplied by the caller.
    ///
    /// Passed in rather than looked up here: this panel renders and decides
    /// nothing, and a view that fetches its own capability state is a second
    /// source of truth waiting to disagree with the session driving it.
    let assessmentStatus: CapabilityStatus

    var body: some View {
        let heading = CompanionCopy.assessmentGateHeading(gate)

        VStack(alignment: .leading, spacing: 12) {
            Text(heading)
                .font(.headline)

            Text("已确认药名：\(gate.confirmed.candidate.displayName)")
                .font(.body)

            // The badge and its explanation both come from the capability
            // table, so this panel cannot claim a different state from the
            // capability list in Settings.
            CapabilityStatusRow(status: assessmentStatus)

            Text("本阶段不显示风险等级、剂量或用药结论，也不会因为确认了药名就允许继续出发。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(CompanionCopy.demoDataNotice)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator, style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            """
            \(heading)。已确认药名 \(gate.confirmed.candidate.displayName)。
            \(assessmentStatus.summaryLine)
            本阶段不显示风险等级、剂量或用药结论，也不允许继续出发。
            \(CompanionCopy.demoDataNotice)
            """
        )
    }
}

/// One capability and what it can really do.
///
/// A pure presentation row: it renders a `CapabilityStatus` and decides
/// nothing. Status is carried by wording, never by colour alone.
struct CapabilityStatusRow: View {
    let status: CapabilityStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(status.displayName)
                    .font(.body)
                Spacer(minLength: 8)
                Text(status.shortLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let detail = status.detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.summaryLine)
    }
}

/// The full capability list: what works, what is simulated, what is not there.
struct CapabilityStatusList: View {
    let catalog: CapabilityCatalog

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(catalog.allStatuses) { status in
                CapabilityStatusRow(status: status)
            }
        }
    }
}

#Preview("Assessment pending") {
    MedicineAssessmentPendingPanel(
        gate: MedicineAssessmentGate(
            confirmed: ConfirmedMedicine(
                candidate: MedicineCandidate.demoCandidates[0],
                origin: .readFromPhoto
            ),
            prompt: MedicineConfirmationPrompt(
                candidates: MedicineCandidate.demoCandidates,
                origin: .readFromPhoto,
                attemptNumber: 1
            ),
            latestUpdate: nil
        ),
        assessmentStatus: CapabilityCatalog.phase0
            .status(of: .medicineRiskAssessment)
    )
    .padding()
}

#Preview("Capability list") {
    ScrollView {
        CapabilityStatusList(catalog: .phase0)
            .padding()
    }
}
