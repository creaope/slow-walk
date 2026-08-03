import Foundation
import SlowWalkAPIContracts
import SlowWalkClientCore
import SlowWalkPresentation
import SwiftUI

/// Holds one continuous companion session from start to finish.
///
/// Every step shows the same three things in the same order: what happened,
/// what to do first, and — when it helps — why. The step-specific controls
/// follow underneath.
struct CompanionView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isMedicineCapturePresented = false
    @State private var medicineCaptureViewModel: MedicineCaptureViewModel?
    private let sessionOverride: CompanionSessionModel?

    init(session: CompanionSessionModel? = nil) {
        sessionOverride = session
    }

    private var session: CompanionSessionModel {
        sessionOverride ?? environment.companion
    }

    var body: some View {
        rootContent
            .fullScreenCover(
                isPresented: $isMedicineCapturePresented,
                onDismiss: { medicineCaptureViewModel = nil }
            ) {
                if let medicineCaptureViewModel {
                    MedicineCaptureView(viewModel: medicineCaptureViewModel)
                }
            }
            .onChange(of: session.currentAssessmentGateLease) {
                oldLease, newLease in
                guard isMedicineCapturePresented,
                      oldLease != nil,
                      oldLease != newLease
                else { return }
                isMedicineCapturePresented = false
            }
    }

    @ViewBuilder
    private var rootContent: some View {
        switch session.state {
        case let .awaitingMedicineAssessment(gate):
            assessmentPage(gate)
        default:
            companionFlowPage
        }
    }

    private var companionFlowPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DemoDataBanner()
                stepHeader
                stepControls
                if session.canEndEarly {
                    endEarlyButton
                }
                NotADiagnosisNotice()
            }
            .padding()
        }
    }

    // MARK: - Medicine assessment

    private func assessmentPage(
        _ gate: MedicineAssessmentGate
    ) -> some View {
        let displayState = MedicineStateMapper.map(
            gate.assessmentState,
            demoDisclaimer: CompanionCopy.demoDataNotice
        )

        return VStack(spacing: 0) {
            // Action cards render the mapped disclaimer themselves. States
            // without a card keep the app-level banner, so every assessment
            // page carries exactly one clear demo-data notice.
            if displayState.actionCard == nil {
                DemoDataBanner()
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
            }

            assessmentPresentation(
                gate: gate,
                displayState: displayState
            )
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            assessmentActions(gate)
        }
    }

    @ViewBuilder
    private func assessmentPresentation(
        gate: MedicineAssessmentGate,
        displayState: MedicineDisplayState
    ) -> some View {
        switch AssessmentPresentationIdentity(gate.assessmentState) {
        case let .result(requestID):
            MedicineAssessmentView(
                state: displayState,
                retryAction: {
                    presentMedicineCapture()
                },
                confirmAction: assessmentCandidateConfirmationAction
            )
            .id(requestID)
            .onAppear {
                _ = session.medicineAssessmentResultDidDisplay()
            }

        case .nonResult:
            MedicineAssessmentView(
                state: displayState,
                retryAction: {
                    presentMedicineCapture()
                },
                confirmAction: assessmentCandidateConfirmationAction
            )
        }
    }

    private func assessmentActions(
        _ gate: MedicineAssessmentGate
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let continuation = AssessmentContinuation(
                canDepart: session.canDepart,
                canCompleteMedicineCheck: session.canCompleteMedicineCheck
            ) {
                primaryButton(continuation.title) {
                    _ = continuation.perform(on: session)
                }
            }

            primaryButton(CompanionCopy.reconsiderMedicineTitle) {
                session.reconsiderMedicineChoice()
            }

            if presentationShowsRetry(for: gate.assessmentState) == false {
                secondaryButton(CompanionCopy.retryPhotoTitle) {
                    presentMedicineCapture()
                }
            }

            if session.canEndEarly {
                endEarlyButton
            }

            NotADiagnosisNotice()
        }
        .padding(20)
        .background(.background)
    }

    private func presentationShowsRetry(
        for state: MedicineAssessmentViewState
    ) -> Bool {
        guard case let .failed(failure) = state else { return false }
        return failure.isRecoverable
    }

    /// The canonical confirmation callback has no candidate identity, so this
    /// flow cannot safely connect it to `session.confirmMedicine(_:)`.
    var assessmentCandidateConfirmationAction: (() -> Void)? { nil }

    enum AssessmentPresentationIdentity: Equatable {
        case result(UUID)
        case nonResult

        init(_ state: MedicineAssessmentViewState) {
            if case let .result(presentation) = state {
                self = .result(presentation.response.requestID)
            } else {
                self = .nonResult
            }
        }
    }

    enum AssessmentContinuation: Equatable {
        case outing
        case medicineCheck

        init?(
            canDepart: Bool,
            canCompleteMedicineCheck: Bool
        ) {
            switch (canDepart, canCompleteMedicineCheck) {
            case (true, false):
                self = .outing
            case (false, true):
                self = .medicineCheck
            case (false, false), (true, true):
                return nil
            }
        }

        var title: String {
            switch self {
            case .outing:
                CompanionCopy.continueCompanionTitle
            case .medicineCheck:
                CompanionCopy.completeMedicineCheckTitle
            }
        }

        @MainActor
        @discardableResult
        func perform(on session: CompanionSessionModel) -> Bool {
            switch self {
            case .outing:
                session.continueToOuting()
            case .medicineCheck:
                session.completeMedicineCheck()
            }
        }
    }

    // MARK: - Header

    private var stepHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.stepLabel)
                .font(.title2)
                .fontWeight(.semibold)

            Text(session.situation)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            Text(session.nextStep)
                .font(.body)
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)

            if let reason = session.reason {
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [
                session.stepLabel,
                session.situation,
                session.nextStep,
                session.reason,
            ]
            .compactMap(\.self)
            .joined(separator: " ")
        )
    }

    // MARK: - Step controls

    @ViewBuilder
    private var stepControls: some View {
        switch session.state {
        case .notStarted:
            primaryButton(CompanionCopy.startCompanionTitle) {
                session.startCompanion()
            }

        case .preDepartureCheck:
            primaryButton(CompanionCopy.beginMedicineReadTitle) {
                session.beginMedicineRead()
            }

        case let .scanningMedicine(attempt):
            if attempt.isAwaitingRecovery {
                recoveryControls
            } else {
                readingIndicator
            }

        case let .awaitingMedicineConfirmation(prompt):
            confirmationControls(prompt)

        case .awaitingMedicineAssessment:
            EmptyView()

        case .travelling:
            primaryButton(CompanionCopy.approachStopTitle) {
                session.approachStop()
            }

        case .approachingStop:
            primaryButton(CompanionCopy.arriveSafelyTitle) {
                session.arriveSafely()
            }

        case .completed:
            completedControls
        }
    }

    private var readingIndicator: some View {
        HStack(spacing: 10) {
            ProgressView()
                .accessibilityHidden(true)
            // Says "模拟识别", not "正在读取": nothing is being read.
            Text("正在模拟识别，请稍等")
                .font(.body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在按演示脚本模拟识别药名，请稍等。本阶段不读取照片。")
    }

    /// Recovery paths after a read that did not succeed.
    ///
    /// No medicine conclusion is offered here — only ways forward.
    private var recoveryControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(session.recoveryOptions) { option in
                switch option {
                case .retryPhoto:
                    primaryButton(option.title) {
                        session.retryMedicineRead()
                    }
                case .chooseFromList:
                    secondaryButton(option.title) {
                        session.chooseFromFrequentList()
                    }
                case .contactSomeone:
                    VStack(alignment: .leading, spacing: 4) {
                        secondaryButton(option.title) {
                            // Contacting someone is a later stage; the button
                            // is present so the recovery path is visible and
                            // reviewable now.
                        }
                        .disabled(true)
                        Text(CompanionCopy.contactSomeoneHint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        // The "not wired up" line comes from the session's
                        // capability table rather than being written here, so
                        // it cannot drift from what the rest of the app says.
                        if let detail = session.capabilities
                            .detail(of: .trustedContacts)
                        {
                            Text(detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func confirmationControls(_ prompt: MedicineConfirmationPrompt) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(prompt.candidates) { candidate in
                Button {
                    session.confirmMedicine(candidate)
                    presentMedicineCapture()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(candidate.displayName)
                            .font(.title3)
                        Text(candidate.recognitionHint)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("选择 \(candidate.displayName)，\(candidate.recognitionHint)")
            }

            Text("如果都对不上，可以重新试一次。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            secondaryButton(CompanionCopy.retryPhotoTitle) {
                session.retakeMedicinePhoto()
            }
        }
    }

    private func presentMedicineCapture() {
        guard case .awaitingMedicineAssessment = session.state,
              session.currentAssessmentGateLease != nil,
              !isMedicineCapturePresented
        else { return }

        medicineCaptureViewModel = environment.makeMedicineCaptureViewModel {
            isMedicineCapturePresented = false
        }
        isMedicineCapturePresented = true
    }

    private var completedControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("这次陪伴的记录已经保存在本次运行中。")
                .font(.body)
            secondaryButton(CompanionCopy.startCompanionTitle) {
                session.startCompanion()
            }
        }
    }

    private var endEarlyButton: some View {
        Button(CompanionCopy.endEarlyTitle) {
            session.endEarly()
        }
        .font(.body)
        // A bare text button is roughly text-height; pad it so the tap target
        // clears 44pt at the default text size.
        .padding(.vertical, 12)
        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
        .accessibilityHint("结束这次陪伴，记录会保存下来。")
    }

    // MARK: - Button helpers

    private func primaryButton(
        _ title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel(title)
    }

    private func secondaryButton(
        _ title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(title)
    }
}

#Preview {
    NavigationStack {
        CompanionView()
            .navigationTitle("陪伴")
    }
    .environment(AppEnvironment.preview())
}
