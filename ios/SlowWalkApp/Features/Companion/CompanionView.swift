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
    @State private var companionDestination: CompanionDestination?
    @State private var isEndEarlyConfirmationPresented = false
    @AccessibilityFocusState private var accessibilityFocus:
        AccessibilityFocusTarget?
    private let sessionOverride: CompanionSessionModel?

    private enum AccessibilityFocusTarget: Hashable {
        case step
        case assessment
    }

    private enum CompanionDestination: Hashable, Identifiable {
        case reminders
        case intake
        case arrivalReminder

        var id: Self { self }

        var title: String {
            switch self {
            case .reminders: "用药提醒"
            case .intake: "用药录入"
            case .arrivalReminder: "开始完整陪伴"
            }
        }

        var accessibilityHint: String {
            switch self {
            case .reminders: "查看今天的用药安排与提醒状态。"
            case .intake: "进入药品识别、安全检查和用药信息录入流程。"
            case .arrivalReminder: "先完成出发前检查，再进入到站提醒。"
            }
        }
    }

    private static let medicineCompanionDestinations: [
        CompanionDestination
    ] = [.reminders, .intake]

    init(session: CompanionSessionModel? = nil) {
        sessionOverride = session
    }

    private var session: CompanionSessionModel {
        sessionOverride ?? environment.companion
    }

    var body: some View {
        rootContent
            .onChange(of: session.currentAssessmentGateLease) {
                oldLease, newLease in
                medicineCapturePresentation.gateLeaseDidChange(
                    from: oldLease,
                    to: newLease
                )
                if !medicineCapturePresentation.isPresented {
                    completeMedicineCaptureDismissal()
                }
            }
            .onChange(of: session.state) { _, newState in
                moveAccessibilityFocus(for: newState)
            }
            .alert(
                CompanionCopy.endEarlyTitle,
                isPresented: $isEndEarlyConfirmationPresented
            ) {
                Button("继续陪伴", role: .cancel) {}
                Button("确认结束", role: .destructive) {
                    session.endEarly()
                }
            } message: {
                Text("结束后不会继续后面的步骤。")
            }
    }

    private var rootContent: some View {
        companionHubPage
            .navigationDestination(item: $companionDestination) {
                destination in
                companionDestinationView(destination)
            }
    }

    private var medicineCompanionPage: some View {
        Group {
            if medicineCapturePresentation.isAssessmentPresented {
                activeMedicineAssessmentPage
            } else {
                companionFlowPage
            }
        }
        .navigationTitle("用药录入")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var companionHubPage: some View {
        List {
            if case .completed = session.state {
                Section("最近一次") {
                    LabeledContent("状态", value: session.stepLabel)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            "最近一次陪伴，\(session.stepLabel)"
                        )
                        .slowWalkReadableContent()

                    Label {
                        Text(session.situation)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                    }
                    .accessibilityElement(children: .combine)
                    .slowWalkReadableContent()
                }
            }

            Section {
                companionFeatureCard(
                    title: "用药陪伴",
                    detail: "查看今天的提醒，或录入药品并完成安全检查。",
                    systemImage: "pills",
                    status: nil
                ) {
                    medicineCompanionEntryButtons
                }
            } header: {
                Text("陪伴功能")
            }

            Section {
                companionFeatureCard(
                    title: "实景导航",
                    detail: "用于未来的实景方向提示；当前版本不提供真实导航。",
                    systemImage: "viewfinder",
                    status: "尚未接入"
                ) {
                    Button {} label: {
                        Label("暂不可用", systemImage: "lock")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(true)
                    .accessibilityHint("当前版本尚未接入实景导航。")
                }
            }

            Section {
                companionFeatureCard(
                    title: "到站提醒",
                    detail: "完成出发前检查后，进入演示出行与到站提醒。",
                    systemImage: "bell.badge",
                    status: "流程内演示"
                ) {
                    companionDestinationButton(.arrivalReminder)
                }
            }

            Section {
                companionFeatureCard(
                    title: "防诈守护",
                    detail: "用于未来的可疑信息识别；当前版本尚未接入。",
                    systemImage: "shield",
                    status: "尚未接入"
                ) {
                    Button {} label: {
                        Label("暂不可用", systemImage: "lock")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(true)
                    .accessibilityHint("当前版本尚未接入防诈识别。")
                }
            }

            Section {
                NotADiagnosisNotice()
                    .slowWalkReadableContent()
            } header: {
                Text("安全提醒")
            } footer: {
                DemoDataFooter()
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(12)
    }

    private func companionFeatureCard<ActionContent: View>(
        title: String,
        detail: String,
        systemImage: String,
        status: String?,
        @ViewBuilder action: () -> ActionContent
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    if let status {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                [title, status].compactMap(\.self).joined(separator: "，")
            )

            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            action()
        }
        .frame(maxWidth: .infinity, minHeight: 196, alignment: .topLeading)
        .listRowInsets(
            EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        )
    }

    private var medicineCompanionEntryButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                ForEach(Self.medicineCompanionDestinations) { destination in
                    companionDestinationButton(destination)
                }
            }

            VStack(spacing: 12) {
                ForEach(Self.medicineCompanionDestinations) { destination in
                    companionDestinationButton(destination)
                }
            }
        }
    }

    private func companionDestinationButton(
        _ destination: CompanionDestination
    ) -> some View {
        Button {
            companionDestination = destination
        } label: {
            Text(destination.title)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.accentColor)
        .controlSize(.large)
        .frame(maxWidth: .infinity)
        .frame(minHeight: SlowWalkLayout.minimumTapTarget)
        .accessibilityHint(destination.accessibilityHint)
    }

    @ViewBuilder
    private func companionDestinationView(
        _ destination: CompanionDestination
    ) -> some View {
        switch destination {
        case .reminders:
            MedicationReminderView(
                medicines: environment.plan.medicines,
                reminderStatus: environment.capabilities.status(
                    of: .medicationReminder
                )
            )
        case .intake:
            medicineCompanionPage
        case .arrivalReminder:
            medicineCompanionPage
                .navigationTitle("完整陪伴")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var companionFlowPage: some View {
        List {
            Section("当前步骤") {
                stepSummary
                    .slowWalkReadableContent()
            }

            stepControls

            if session.canEndEarly {
                Section {
                    endEarlyButton
                        .slowWalkReadableContent()
                }
            }

            Section {
                NotADiagnosisNotice()
                    .slowWalkReadableContent()
            } header: {
                Text("安全提醒")
            } footer: {
                DemoDataFooter()
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Medicine assessment

    var activeMedicineAssessmentPage: some View {
        MedicineAssessmentGateReader(session: session) { gate in
            assessmentPage(
                gate,
                retryAction: { returnToMedicineCapture() }
            )
        } unavailable: {
            ContentUnavailableView {
                Label("识别已结束", systemImage: "checkmark.circle")
            } description: {
                Text("返回陪伴页查看当前状态。")
            }
        }
    }

    private func assessmentPage(
        _ gate: MedicineAssessmentGate,
        retryAction: @escaping () -> Void
    ) -> some View {
        let page = AssessmentPagePresentation(gate.assessmentState)

        return assessmentPresentation(
            gate: gate,
            displayState: page.displayState,
            retryAction: retryAction
        )
        .accessibilityFocused(
            $accessibilityFocus,
            equals: .assessment
        )
        .slowWalkReadableContent()
    }

    @ViewBuilder
    private func assessmentPresentation(
        gate: MedicineAssessmentGate,
        displayState: MedicineDisplayState,
        retryAction: @escaping () -> Void
    ) -> some View {
        switch AssessmentPresentationIdentity(gate.assessmentState) {
        case let .result(requestID):
            MedicineAssessmentView(
                state: displayState,
                retryAction: retryAction,
                confirmAction: nil,
                contextContent: {
                    assessmentContextSection
                },
                actionContent: {
                    assessmentActionSections(
                        gate,
                        retryAction: retryAction
                    )
                }
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
                retryAction: retryAction,
                confirmAction: nil,
                contextContent: {
                    assessmentContextSection
                },
                actionContent: {
                    assessmentActionSections(
                        gate,
                        retryAction: retryAction
                    )
                }
            )
        }
    }

    private var assessmentContextSection: some View {
        Section("当前步骤") {
            stepSummary
                .slowWalkReadableContent()
        }
    }

    @ViewBuilder
    private func assessmentActionSections(
        _ gate: MedicineAssessmentGate,
        retryAction: @escaping () -> Void
    ) -> some View {
        let confirmation = CanonicalCandidateConfirmation(
            gate.assessmentState
        )
        let continuation = AssessmentContinuation(
            canDepart: session.canDepart,
            canCompleteMedicineCheck: session.canCompleteMedicineCheck
        )

        if let confirmation {
            Section("请选择药名") {
                canonicalCandidateControls(confirmation.candidates)
            }

            Section("其他方式") {
                secondaryButton(
                    CompanionCopy.retryPhotoTitle,
                    systemImage: "camera"
                ) {
                    retryAction()
                }
            }
        } else if let continuation {
            Section {
                primaryButton(
                    continuation.title,
                    systemImage: "arrow.forward.circle"
                ) {
                    _ = continuation.perform(on: session)
                }

                medicineSelectionButton(for: gate)
            }
        } else if presentationShowsRetry(for: gate.assessmentState) {
            Section("其他方式") {
                medicineSelectionButton(for: gate)
            }
        } else {
            Section("下一步") {
                primaryButton(
                    CompanionCopy.retryPhotoTitle,
                    systemImage: "camera"
                ) {
                    retryAction()
                }

                medicineSelectionButton(for: gate)
            }
        }

        if session.canEndEarly {
            Section {
                endEarlyButton
            }
        }

        Section("安全提醒") {
            NotADiagnosisNotice()
        }
    }

    @ViewBuilder
    private func medicineSelectionButton(
        for gate: MedicineAssessmentGate
    ) -> some View {
        if gate.preAssessmentSelection == nil {
            secondaryButton(
                CompanionCopy.chooseFromListTitle,
                systemImage: "list.bullet"
            ) {
                session.chooseFromFrequentList()
            }
        } else {
            secondaryButton(
                CompanionCopy.reconsiderMedicineTitle,
                systemImage: "arrow.triangle.2.circlepath"
            ) {
                session.reconsiderMedicineChoice()
            }
        }
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
        private(set) var isAssessmentPresented = false
        private var pendingDismissals: [MedicineCapturePresentationIdentity] = []

        mutating func present(
            _ identity: MedicineCapturePresentationIdentity
        ) {
            current = identity
            isPresented = true
            isAssessmentPresented = false
        }

        @discardableResult
        mutating func inputSubmissionStarted(
            for identity: MedicineCapturePresentationIdentity,
            currentGateLease: MedicineAssessmentGateLease?,
            currentViewModelToken: UUID?
        ) -> Bool {
            guard isPresented,
                  current == identity,
                  currentGateLease == identity.gateLease,
                  currentViewModelToken == identity.viewModelToken
            else { return false }

            isAssessmentPresented = true
            return true
        }

        @discardableResult
        mutating func returnToCapture(
            for identity: MedicineCapturePresentationIdentity
        ) -> Bool {
            guard isPresented,
                  current == identity,
                  isAssessmentPresented
            else { return false }

            isAssessmentPresented = false
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
            isAssessmentPresented = false
            isPresented = false
        }

        mutating func completeNextDismissal()
            -> MedicineCapturePresentationIdentity? {
            guard !pendingDismissals.isEmpty else { return nil }
            let dismissed = pendingDismissals.removeFirst()
            if current == dismissed {
                current = nil
                isPresented = false
                isAssessmentPresented = false
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

    // MARK: - Step summary

    private var stepSummary: some View {
        Group {
            LabeledContent("进度", value: session.stepLabel)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("当前步骤，\(session.stepLabel)")
                .accessibilityFocused(
                    $accessibilityFocus,
                    equals: .step
                )

            Label {
                Text(session.situation)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)

            Label {
                Text(session.nextStep)
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "arrow.forward.circle.fill")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)

            if let reason = session.reason {
                Label {
                    Text(reason)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: - Step controls

    @ViewBuilder
    private var stepControls: some View {
        switch session.state {
        case .notStarted:
            Section("选择识别方式") {
                medicineCaptureSourceActions(startingSession: true)
            }

        case .preDepartureCheck:
            Section("选择确认方式") {
                medicineCaptureSourceActions(startingSession: false)

                secondaryButton(
                    CompanionCopy.chooseFromListTitle,
                    systemImage: "list.bullet"
                ) {
                    session.chooseFromFrequentList()
                }
                .slowWalkReadableContent()
            }

        case let .scanningMedicine(attempt):
            Section(attempt.isAwaitingRecovery ? "重新确认" : "识别状态") {
                if attempt.isAwaitingRecovery {
                    recoveryControls
                } else {
                    readingIndicator
                }
            }

        case let .awaitingMedicineConfirmation(prompt):
            Section("请选择药名") {
                confirmationControls(prompt)
            }

        case .awaitingMedicineAssessment:
            Section("识别与评估") {
                Button(action: showCurrentMedicineAssessment) {
                    Label(
                        "继续查看识别与评估",
                        systemImage: "doc.text.magnifyingglass"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(minHeight: SlowWalkLayout.minimumTapTarget)
                .accessibilityHint("在当前用药陪伴页面继续查看。")

                medicineCaptureSourceActions(startingSession: false)
            }

        case .travelling:
            Section {
                primaryButton(
                    CompanionCopy.approachStopTitle,
                    systemImage: "bell"
                ) {
                    session.approachStop()
                }
                .slowWalkReadableContent()
            }

        case .approachingStop:
            Section {
                primaryButton(
                    CompanionCopy.arriveSafelyTitle,
                    systemImage: "checkmark.circle"
                ) {
                    session.arriveSafely()
                }
                .slowWalkReadableContent()
            }

        case .completed:
            Section("本次陪伴") {
                completedControls
            }
        }
    }

    private var readingIndicator: some View {
        ProgressView("正在模拟识别，请稍等")
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "正在按演示脚本模拟识别药名，请稍等。本阶段不读取照片。"
            )
            .slowWalkReadableContent()
    }

    /// Recovery paths after a read that did not succeed.
    ///
    /// No medicine conclusion is offered here — only ways forward.
    private var recoveryControls: some View {
        ForEach(session.recoveryOptions) { option in
            switch option {
            case .retryPhoto:
                primaryButton(
                    option.title,
                    systemImage: "arrow.clockwise"
                ) {
                    session.retryMedicineRead()
                }
                .slowWalkReadableContent()
            case .chooseFromList:
                secondaryButton(
                    option.title,
                    systemImage: "list.bullet"
                ) {
                    session.chooseFromFrequentList()
                }
                .slowWalkReadableContent()
            case .contactSomeone:
                LabeledContent {
                    Text(
                        session.capabilities
                            .status(of: .trustedContacts)
                            .shortLabel
                    )
                    .foregroundStyle(.secondary)
                } label: {
                    Label(option.title, systemImage: "person.crop.circle")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    session.capabilities
                        .status(of: .trustedContacts)
                        .summaryLine
                )
                .slowWalkReadableContent()

                Text(CompanionCopy.contactSomeoneHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .slowWalkReadableContent()
            }
        }
    }

    @ViewBuilder
    private func confirmationControls(
        _ prompt: MedicineConfirmationPrompt
    ) -> some View {
        ForEach(prompt.candidates) { candidate in
            Button {
                session.confirmMedicine(candidate)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(candidate.displayName)
                            .fontWeight(.semibold)
                        Text(candidate.recognitionHint)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } icon: {
                    Image(systemName: "pills")
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)
            .frame(minHeight: SlowWalkLayout.minimumTapTarget)
            .contentShape(Rectangle())
            .accessibilityLabel("选择 \(candidate.displayName)，\(candidate.recognitionHint)")
            .accessibilityHint("确认后进入用药检查。")
            .slowWalkReadableContent()
        }

        Text("如果都对不上，可以重新试一次。")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .slowWalkReadableContent()

        secondaryButton(
            CompanionCopy.retryPhotoTitle,
            systemImage: "camera"
        ) {
            session.retakeMedicinePhoto()
        }
        .slowWalkReadableContent()
    }

    @ViewBuilder
    private func canonicalCandidateControls(
        _ candidates: [SlowWalkDomain.MedicineCandidate]
    ) -> some View {
        ForEach(candidates, id: \.medicine.id) { candidate in
            Button {
                confirmCanonicalMedicine(candidate)
            } label: {
                Label(
                    candidate.medicine.canonicalName,
                    systemImage: "pills"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .frame(minHeight: SlowWalkLayout.minimumTapTarget)
            .accessibilityLabel(
                "确认药名：\(candidate.medicine.canonicalName)"
            )
            .accessibilityHint("使用这个候选药名继续评估。")
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

    private func medicineCaptureSourceActions(
        startingSession: Bool
    ) -> some View {
        MedicineCaptureSourceActions { imageData in
            submitMedicineImage(
                imageData,
                startingSession: startingSession
            )
        }
        .slowWalkReadableContent()
    }

    private func submitMedicineImage(
        _ imageData: Data,
        startingSession: Bool
    ) {
        guard !imageData.isEmpty else { return }

        if case .awaitingMedicineAssessment = session.state {
            // The existing gate belongs to a candidate confirmation or retry.
        } else {
            guard MedicineCaptureEntryAction.perform(
                on: session,
                startingSession: startingSession
            ) else { return }
        }

        guard let gateLease = session.currentAssessmentGateLease,
              let context = captureContext(for: gateLease)
        else { return }

        context.viewModel.capture(
            imageData: imageData,
            orientation: .up,
            capturedAt: Date()
        )
        _ = medicineCapturePresentation.inputSubmissionStarted(
            for: context.identity,
            currentGateLease: session.currentAssessmentGateLease,
            currentViewModelToken: medicineCaptureViewModelToken
        )
    }

    private func captureContext(
        for gateLease: MedicineAssessmentGateLease
    ) -> (
        identity: MedicineCapturePresentationIdentity,
        viewModel: MedicineCaptureViewModel
    )? {
        if medicineCapturePresentation.isPresented,
           let identity = medicineCapturePresentation.current,
           identity.gateLease == gateLease,
           identity.viewModelToken == medicineCaptureViewModelToken,
           let medicineCaptureViewModel
        {
            medicineCaptureViewModel.reset()
            return (identity, medicineCaptureViewModel)
        }

        if medicineCapturePresentation.isPresented {
            medicineCapturePresentation.requestCurrentDismissal()
            completeMedicineCaptureDismissal()
        }

        let identity = MedicineCapturePresentationIdentity(
            token: UUID(),
            gateLease: gateLease,
            viewModelToken: UUID()
        )
        let viewModel = environment.makeMedicineCaptureViewModel()
        medicineCaptureViewModel = viewModel
        medicineCaptureViewModelToken = identity.viewModelToken
        medicineCapturePresentation.present(identity)
        return (identity, viewModel)
    }

    private func showCurrentMedicineAssessment() {
        guard let gateLease = session.currentAssessmentGateLease else {
            return
        }

        if medicineCapturePresentation.isPresented,
           let identity = medicineCapturePresentation.current,
           identity.gateLease == gateLease,
           identity.viewModelToken == medicineCaptureViewModelToken
        {
            _ = medicineCapturePresentation.inputSubmissionStarted(
                for: identity,
                currentGateLease: gateLease,
                currentViewModelToken: medicineCaptureViewModelToken
            )
            return
        }

        guard let context = captureContext(for: gateLease) else { return }
        _ = medicineCapturePresentation.inputSubmissionStarted(
            for: context.identity,
            currentGateLease: gateLease,
            currentViewModelToken: medicineCaptureViewModelToken
        )
    }

    private func returnToMedicineCapture() {
        guard let identity = medicineCapturePresentation.current,
              medicineCapturePresentation.returnToCapture(for: identity)
        else { return }
        medicineCaptureViewModel?.reset()
    }

    private func completeMedicineCaptureDismissal() {
        guard let dismissed =
                medicineCapturePresentation.completeNextDismissal(),
              medicineCaptureViewModelToken == dismissed.viewModelToken
        else { return }
        let dismissedViewModel = medicineCaptureViewModel
        medicineCaptureViewModel = nil
        medicineCaptureViewModelToken = nil
        Task { @MainActor in
            await dismissedViewModel?.dismiss()
        }
    }

    private var completedControls: some View {
        Group {
            Label(
                "这次陪伴的记录已经保存在本次运行中。",
                systemImage: "checkmark.circle"
            )
            .fixedSize(horizontal: false, vertical: true)
            .slowWalkReadableContent()

            medicineCaptureSourceActions(startingSession: true)
        }
    }

    private var endEarlyButton: some View {
        Button(role: .destructive) {
            isEndEarlyConfirmationPresented = true
        } label: {
            Label(CompanionCopy.endEarlyTitle, systemImage: "xmark.circle")
        }
        .frame(minHeight: SlowWalkLayout.minimumTapTarget)
        .accessibilityHint("显示确认选项。")
    }

    // MARK: - Button helpers

    private func primaryButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .frame(minHeight: SlowWalkLayout.minimumTapTarget)
        .accessibilityLabel(title)
    }

    private func secondaryButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .frame(minHeight: SlowWalkLayout.minimumTapTarget)
        .accessibilityLabel(title)
    }

    private func moveAccessibilityFocus(for state: CompanionFlowState) {
        Task { @MainActor in
            await Task.yield()
            if case .awaitingMedicineAssessment = state {
                accessibilityFocus = .assessment
            } else {
                accessibilityFocus = .step
            }
        }
    }
}

/// Reads the live assessment gate inside the page's own observation scope, so
/// a long-running assessment cannot leave stale content on screen.
private struct MedicineAssessmentGateReader<
    Content: View,
    Unavailable: View
>: View {
    let session: CompanionSessionModel
    private let content: (MedicineAssessmentGate) -> Content
    private let unavailable: () -> Unavailable

    init(
        session: CompanionSessionModel,
        @ViewBuilder content: @escaping (MedicineAssessmentGate) -> Content,
        @ViewBuilder unavailable: @escaping () -> Unavailable
    ) {
        self.session = session
        self.content = content
        self.unavailable = unavailable
    }

    @ViewBuilder
    var body: some View {
        if let gate = session.assessmentGate {
            content(gate)
        } else {
            unavailable()
        }
    }
}

#Preview {
    NavigationStack {
        CompanionView()
            .navigationTitle("陪伴")
    }
    .environment(AppEnvironment.preview())
}
