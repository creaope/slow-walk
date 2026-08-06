import Foundation
import SlowWalkAPIContracts
import SlowWalkClientCore
import SlowWalkDomain
import SlowWalkPresentation
import SwiftUI

/// Holds one continuous companion session from start to finish.
///
/// Every step shows the same three things in the same order: what happened,
/// what to do first, and — when it helps — why. The step-specific controls
/// follow underneath.
struct CompanionView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var medicineCapturePresentation =
        MedicineCapturePresentationLifecycle()
    @State private var medicineCaptureViewModel: MedicineCaptureViewModel?
    @State private var medicineCaptureViewModelToken: UUID?
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
                isPresented: isMedicineCapturePresented,
                onDismiss: { completeMedicineCaptureDismissal() }
            ) {
                if let identity = medicineCapturePresentation.current,
                   identity.viewModelToken == medicineCaptureViewModelToken,
                   let medicineCaptureViewModel
                {
                    MedicineCaptureView(viewModel: medicineCaptureViewModel)
                        .onDisappear {
                            medicineCapturePresentation.requestDismissal(
                                for: identity
                            )
                        }
                }
            }
            .onChange(of: session.currentAssessmentGateLease) {
                oldLease, newLease in
                medicineCapturePresentation.gateLeaseDidChange(
                    from: oldLease,
                    to: newLease
                )
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
        let page = AssessmentPagePresentation(gate.assessmentState)

        return assessmentPresentation(
            gate: gate,
            displayState: page.displayState
        )
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
                confirmAction: nil
            )
            .id(requestID)
            .onAppear {
                _ = session.medicineAssessmentResultDidDisplay(
                    requestID: requestID
                )
            }

        case .nonResult:
            MedicineAssessmentView(
                state: displayState,
                retryAction: {
                    presentMedicineCapture()
                },
                confirmAction: nil
            )
        }
    }

    private func assessmentActions(
        _ gate: MedicineAssessmentGate
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let confirmation = CanonicalCandidateConfirmation(
                gate.assessmentState
            ) {
                canonicalCandidateControls(confirmation.candidates)
            }

            if let continuation = AssessmentContinuation(
                canDepart: session.canDepart,
                canCompleteMedicineCheck: session.canCompleteMedicineCheck
            ) {
                primaryButton(continuation.title) {
                    _ = continuation.perform(on: session)
                }
            }

            if gate.preAssessmentSelection == nil {
                secondaryButton(CompanionCopy.chooseFromListTitle) {
                    session.chooseFromFrequentList()
                }
            } else {
                secondaryButton(CompanionCopy.reconsiderMedicineTitle) {
                    session.reconsiderMedicineChoice()
                }
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

    /// The Presentation package is the sole demo-disclaimer owner for every
    /// medicine assessment state. The App does not add a second banner.
    struct AssessmentPagePresentation: Equatable {
        let displayState: MedicineDisplayState

        init(
            _ state: MedicineAssessmentViewState,
            demoDisclaimer: String? = CompanionCopy.demoDataNotice
        ) {
            displayState = MedicineStateMapper.map(
                state,
                demoDisclaimer: demoDisclaimer
            )
        }
    }

    struct CanonicalCandidateConfirmation: Equatable {
        let candidates: [SlowWalkDomain.MedicineCandidate]

        init?(_ state: MedicineAssessmentViewState) {
            guard case let .requiresMedicineConfirmation(requirement) = state,
                  let response = requirement.response,
                  !response.resolution.candidates.isEmpty
            else { return nil }

            switch requirement.reason {
            case .ambiguousMedicine, .unresolvedMedicine:
                candidates = response.resolution.candidates
            case .noRecognizedText, .serverRequiresConfirmation:
                return nil
            }
        }
    }

    enum MedicineCaptureEntryAction {
        @MainActor
        static func perform(
            on session: CompanionSessionModel,
            startingSession: Bool = false
        ) -> Bool {
            if startingSession, !session.startCompanion() {
                return false
            }
            return session.beginMedicineCaptureAssessment()
        }
    }

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

    struct MedicineCapturePresentationIdentity: Equatable {
        let token: UUID
        let gateLease: MedicineAssessmentGateLease
        let viewModelToken: UUID
    }

    struct MedicineCapturePresentationLifecycle {
        private(set) var current: MedicineCapturePresentationIdentity?
        private(set) var isPresented = false
        private var pendingDismissals: [MedicineCapturePresentationIdentity] = []

        mutating func present(
            _ identity: MedicineCapturePresentationIdentity
        ) {
            current = identity
            isPresented = true
        }

        @discardableResult
        mutating func assessmentSubmissionAccepted(
            for identity: MedicineCapturePresentationIdentity,
            currentGateLease: MedicineAssessmentGateLease?,
            currentViewModelToken: UUID?
        ) -> Bool {
            guard isPresented,
                  current == identity,
                  currentGateLease == identity.gateLease,
                  currentViewModelToken == identity.viewModelToken
            else { return false }

            requestDismissal(for: identity)
            return true
        }

        mutating func gateLeaseDidChange(
            from oldLease: MedicineAssessmentGateLease?,
            to newLease: MedicineAssessmentGateLease?
        ) {
            guard oldLease != newLease,
                  let oldLease,
                  let current,
                  current.gateLease == oldLease
            else { return }
            requestDismissal(for: current)
        }

        mutating func requestCurrentDismissal() {
            guard let current else { return }
            requestDismissal(for: current)
        }

        mutating func requestDismissal(
            for identity: MedicineCapturePresentationIdentity
        ) {
            guard current == identity else { return }
            if !pendingDismissals.contains(identity) {
                pendingDismissals.append(identity)
            }
            isPresented = false
        }

        mutating func completeNextDismissal()
            -> MedicineCapturePresentationIdentity? {
            guard !pendingDismissals.isEmpty else { return nil }
            let dismissed = pendingDismissals.removeFirst()
            if current == dismissed {
                current = nil
                isPresented = false
            }
            return dismissed
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
                beginMedicineCapture(startingSession: true)
            }

        case .preDepartureCheck:
            primaryButton(CompanionCopy.beginMedicineReadTitle) {
                beginMedicineCapture()
            }
            secondaryButton(CompanionCopy.chooseFromListTitle) {
                session.chooseFromFrequentList()
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

    private func canonicalCandidateControls(
        _ candidates: [SlowWalkDomain.MedicineCandidate]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(candidates, id: \.medicine.id) { candidate in
                Button {
                    confirmCanonicalMedicine(candidate)
                } label: {
                    Text(candidate.medicine.canonicalName)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(
                    "确认药名：\(candidate.medicine.canonicalName)"
                )
            }
        }
    }

    private func confirmCanonicalMedicine(
        _ candidate: SlowWalkDomain.MedicineCandidate
    ) {
        let runner = environment.medicineAssessmentRunner
        guard let invocation = runner.makeConfirmationInvocation(candidate)
        else { return }
        Task { @MainActor in
            _ = await runner.confirmMedicine(invocation)
        }
    }

    private func beginMedicineCapture(startingSession: Bool = false) {
        guard MedicineCaptureEntryAction.perform(
            on: session,
            startingSession: startingSession
        ) else { return }
        presentMedicineCapture()
    }

    private func presentMedicineCapture() {
        guard case .awaitingMedicineAssessment = session.state,
              let gateLease = session.currentAssessmentGateLease,
              !medicineCapturePresentation.isPresented
        else { return }

        let identity = MedicineCapturePresentationIdentity(
            token: UUID(),
            gateLease: gateLease,
            viewModelToken: UUID()
        )
        let viewModel = environment.makeMedicineCaptureViewModel {
            _ = medicineCapturePresentation.assessmentSubmissionAccepted(
                for: identity,
                currentGateLease: session.currentAssessmentGateLease,
                currentViewModelToken: medicineCaptureViewModelToken
            )
        }
        medicineCaptureViewModel = viewModel
        medicineCaptureViewModelToken = identity.viewModelToken
        medicineCapturePresentation.present(identity)
    }

    private var isMedicineCapturePresented: Binding<Bool> {
        Binding(
            get: { medicineCapturePresentation.isPresented },
            set: { shouldPresent in
                guard !shouldPresent else { return }
                medicineCapturePresentation.requestCurrentDismissal()
            }
        )
    }

    private func completeMedicineCaptureDismissal() {
        guard let dismissed =
                medicineCapturePresentation.completeNextDismissal(),
              medicineCaptureViewModelToken == dismissed.viewModelToken
        else { return }
        medicineCaptureViewModel = nil
        medicineCaptureViewModelToken = nil
    }

    private var completedControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("这次陪伴的记录已经保存在本次运行中。")
                .font(.body)
            secondaryButton(CompanionCopy.startCompanionTitle) {
                beginMedicineCapture(startingSession: true)
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
