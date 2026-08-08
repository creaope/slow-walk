import SlowWalkDomain
import SwiftUI

struct SlowWalkOnboardingView: View {
    typealias DraftSubmission = SlowWalkOnboardingSubmissionModel.DraftSubmission
    typealias DemoSelection = SlowWalkOnboardingSubmissionModel.DemoSelection
    typealias Completion = @MainActor () -> Void

    private let onComplete: Completion

    @StateObject private var submission: SlowWalkOnboardingSubmissionModel
    @State private var draft: UserProfileDraft
    @State private var flow: SlowWalkOnboardingFlowState
    @State private var conditionText = ""
    @State private var allergyText = ""
    @State private var medicineText = ""
    @State private var validationMessage: String?
    @State private var listInputMessage: String?
    @State private var completedWithDemoData = false
    @State private var reviewEditStep: SlowWalkOnboardingStep?
    @AccessibilityFocusState private var focusedStep: SlowWalkOnboardingStep?
    @AccessibilityFocusState private var validationMessageIsFocused: Bool

    init(
        initialDraft: UserProfileDraft = UserProfileDraft(),
        initialStep: SlowWalkOnboardingStep = .welcome,
        onSubmit: @escaping DraftSubmission,
        onUseDemoData: @escaping DemoSelection,
        onComplete: @escaping Completion
    ) {
        _draft = State(initialValue: SlowWalkOnboardingInputRules.normalizedDraft(initialDraft))
        _flow = State(initialValue: SlowWalkOnboardingFlowState(step: initialStep))
        _submission = StateObject(
            wrappedValue: SlowWalkOnboardingSubmissionModel(
                onSubmit: onSubmit,
                onUseDemoData: onUseDemoData
            )
        )
        self.onComplete = onComplete
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if submission.state.failureMessage == nil {
                    progressHeader
                    stepContent
                } else {
                    submissionFailureContent
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }.navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline).navigationBarBackButtonHidden(true)
            .toolbar {
                if showsBackButton {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            goBack()
                        } label: {
                            Label("返回", systemImage: "chevron.backward")
                        }
                        .labelStyle(.iconOnly).accessibilityLabel("返回上一步")
                        .disabled(submission.state.isSubmitting)
                    }
                }
            }
            .interactiveDismissDisabled(submission.state.isSubmitting)
            .onAppear { focusedStep = flow.step }
            .onChange(of: flow.step) { _, newStep in focusedStep = newStep }
            .onChange(of: draft.preferredName) { clearValidationMessage(for: .preferredName) }
            .onChange(of: draft.ageText) { clearValidationMessage(for: .age) }
            .onChange(of: submission.state) { _, state in handleSubmissionState(state) }
            .onDisappear { submission.invalidate() }
        }
    }

    @ViewBuilder private var progressHeader: some View {
        if let position = flow.step.formPosition {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(position), total: Double(flow.step.formStepCount))
                Text("第 \(position) 步，共 \(flow.step.formStepCount) 步").font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal).padding(.vertical, 8)
            .background(Color(uiColor: .systemGroupedBackground))
            .accessibilityElement(children: .ignore).accessibilityLabel("资料设置进度")
            .accessibilityValue("第 \(position) 步，共 \(flow.step.formStepCount) 步")
        }
    }

    @ViewBuilder private var stepContent: some View {
        switch flow.step {
        case .welcome: welcomeContent
        case .preferredName: preferredNameContent
        case .age: ageContent
        case .conditions:
            itemsContent(
                step: .conditions,
                text: $conditionText,
                items: $draft.diagnosedConditions,
                placeholder: "例如：高血压",
                sectionTitle: "医生已告知的健康情况",
                emptyText: "没有需要补充的内容时，可以直接继续。",
                field: .conditions
            )
        case .allergies:
            itemsContent(
                step: .allergies,
                text: $allergyText,
                items: $draft.allergies,
                placeholder: "例如：青霉素或花生",
                sectionTitle: "药物或食物过敏",
                emptyText: "不清楚或没有需要补充的内容时，可以直接继续。",
                field: .allergies
            )
        case .medicines:
            itemsContent(
                step: .medicines,
                text: $medicineText,
                items: $draft.currentMedicineNames,
                placeholder: "输入药盒上的名称",
                sectionTitle: "正在使用的药品名称",
                emptyText: "药名会先作为待确认信息保存，" + "不会自动转换为药品成分。",
                field: .medicines
            )
        case .review: reviewContent
        case .complete: completionContent
        }
    }

    private var welcomeContent: some View {
        List {
            Section {
                VStack(spacing: 16) {
                    Image(systemName: SlowWalkOnboardingStep.welcome.systemImage).font(.largeTitle)
                        .foregroundStyle(.tint).accessibilityHidden(true)

                    Text(SlowWalkOnboardingStep.welcome.title).font(.largeTitle.bold())
                        .multilineTextAlignment(.center)

                    Text("用大约一分钟补充基本资料，" + "让陪伴信息更符合您的情况。").foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 24)
                .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
                .accessibilityFocused($focusedStep, equals: .welcome).slowWalkReadableContent()
            }

            Section("接下来") {
                onboardingSummaryRow(
                    "填写称呼和年龄",
                    detail: "用于页面问候和基本信息展示。",
                    systemImage: "person.text.rectangle"
                )
                onboardingSummaryRow(
                    "补充健康与用药信息",
                    detail: "不清楚的项目可以留空，之后再完善。",
                    systemImage: "heart.text.square"
                )
                onboardingSummaryRow("确认后再保存", detail: "进入主页前会提供一页完整摘要。", systemImage: "checklist")
            }
        }
        .listStyle(.insetGrouped)
    }

    private var preferredNameContent: some View {
        List {
            introduction(for: .preferredName, detail: "这个称呼会用于页面问候。")

            Section {
                TextField(
                    SlowWalkOnboardingTextField.preferredName.accessibilityLabel,
                    text: $draft.preferredName,
                    prompt: Text("例如：王阿姨")
                )
                .textContentType(.nickname).submitLabel(.next).onSubmit(goForward)
                .accessibilityLabel(SlowWalkOnboardingTextField.preferredName.accessibilityLabel)
                .accessibilityHint(SlowWalkOnboardingTextField.preferredName.accessibilityHint)
                .slowWalkReadableContent()
            } header: {
                Text("称呼")
            } footer: {
                validationFooter("最多 30 个字符。")
            }
        }
        .listStyle(.insetGrouped).scrollDismissesKeyboard(.interactively)
    }

    private var ageContent: some View {
        List {
            introduction(for: .age, detail: "年龄用于后续资料校验和个性化展示。")

            Section {
                TextField(
                    SlowWalkOnboardingTextField.age.accessibilityLabel,
                    text: $draft.ageText,
                    prompt: Text("例如：68")
                )
                .keyboardType(.numberPad).textContentType(.none)
                .accessibilityLabel(SlowWalkOnboardingTextField.age.accessibilityLabel)
                .accessibilityHint(SlowWalkOnboardingTextField.age.accessibilityHint)
                .slowWalkReadableContent()
            } header: {
                Text("年龄")
            } footer: {
                validationFooter("请填写 1 到 120 之间的数字。")
            }
        }
        .listStyle(.insetGrouped).scrollDismissesKeyboard(.interactively)
    }

    private func itemsContent(
        step: SlowWalkOnboardingStep,
        text: Binding<String>,
        items: Binding<[String]>,
        placeholder: String,
        sectionTitle: String,
        emptyText: String,
        field: SlowWalkOnboardingListField
    ) -> some View {
        List {
            introduction(for: step, detail: introductionDetail(for: field))

            Section {
                HStack(alignment: .firstTextBaseline) {
                    TextField(field.accessibilityName, text: text, prompt: Text(placeholder))
                        .submitLabel(.done).onSubmit { addItem(text.wrappedValue, to: field) }
                        .accessibilityLabel(field.accessibilityName)
                        .accessibilityHint(textField(for: field).accessibilityHint)

                    Button("添加") { addItem(text.wrappedValue, to: field) }
                        .disabled(
                            text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
                        )
                }
                .slowWalkReadableContent()
            } header: {
                Text(sectionTitle)
            } footer: {
                if let listInputMessage {
                    Text(listInputMessage).foregroundStyle(.red)
                        .accessibilityFocused($validationMessageIsFocused)
                } else {
                    Text(emptyText)
                }
            }

            if !items.wrappedValue.isEmpty {
                Section("已添加") {
                    ForEach(items.wrappedValue.indices, id: \.self) { index in
                        HStack(alignment: .center, spacing: 12) {
                            Text(items.wrappedValue[index])
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)

                            Button(role: .destructive) {
                                removeItem(at: index, from: field)
                            } label: {
                                Image(systemName: "trash")
                                    .frame(
                                        minWidth: SlowWalkLayout.minimumTapTarget,
                                        minHeight: SlowWalkLayout.minimumTapTarget
                                    )
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(
                                field.deleteAccessibilityLabel(for: items.wrappedValue[index])
                            )
                        }
                        .slowWalkReadableContent()
                    }
                    .onDelete { offsets in items.wrappedValue.remove(atOffsets: offsets) }
                }
            }
        }
        .listStyle(.insetGrouped).scrollDismissesKeyboard(.interactively)
    }

    private var reviewContent: some View {
        List {
            introduction(for: .review, detail: "请核对以下内容。保存前可以返回修改。")

            Section("基本资料") {
                LabeledContent("称呼", value: draft.preferredName).slowWalkReadableContent()
                LabeledContent("年龄", value: "\(draft.ageText) 岁").slowWalkReadableContent()
                reviewEditButton("修改基本资料", step: .preferredName, returnAfter: .age)
            }

            Section("健康资料") {
                reviewRow("健康情况", values: draft.diagnosedConditions)
                reviewEditButton("修改健康情况", step: .conditions)
                reviewRow("过敏情况", values: draft.allergies)
                reviewEditButton("修改过敏情况", step: .allergies)
                reviewRow("当前用药", values: draft.currentMedicineNames)
                reviewEditButton("修改当前用药", step: .medicines)
            }

            Section {
                Label {
                    Text("药品名称会作为待确认信息保存，" + "不会自动转换为成分、剂量或用药建议。")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle").foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine).slowWalkReadableContent()
            } header: {
                Text("信息边界")
            }
        }
        .listStyle(.insetGrouped)
    }

    private var completionContent: some View {
        List {
            Section {
                ContentUnavailableView {
                    Label(
                        completedWithDemoData ? "演示资料已就绪" : "资料已保存",
                        systemImage: "checkmark.circle"
                    )
                } description: {
                    Text(completedWithDemoData ? "现在可以进入慢行，体验完整的演示流程。" : "现在可以进入慢行。")
                }
                .accessibilityFocused($focusedStep, equals: .complete).slowWalkReadableContent()
            }

            Section("您可以继续") {
                onboardingSummaryRow("查看今天的安排", detail: "首页会汇总当前状态和待办事项。", systemImage: "sun.max")
                onboardingSummaryRow("使用陪伴功能", detail: "按需进入用药守护或出行陪伴。", systemImage: "figure.walk")
            }
        }
        .listStyle(.insetGrouped)
    }

    private var submissionFailureContent: some View {
        let kind = submission.state.failedKind ?? .profile
        return List {
            Section {
                ContentUnavailableView {
                    Label(kind.failureTitle, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(submission.state.failureMessage ?? kind.failureMessage)
                }
                .slowWalkReadableContent()
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder private var actionBar: some View {
        VStack(spacing: 12) {
            if let failedKind = submission.state.failedKind {
                primaryButton(
                    failedKind.retryTitle,
                    systemImage: "arrow.clockwise",
                    submissionKind: failedKind
                ) { retrySubmission() }

                Button("返回检查资料") {
                    let returnStep: SlowWalkOnboardingStep
                    switch failedKind {
                    case .demo: returnStep = .welcome
                    case .profile: returnStep = .review
                    }
                    submission.clearFailure()
                    flow.step = returnStep
                }
                .buttonStyle(.bordered).controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: SlowWalkLayout.minimumTapTarget)
            } else {
                switch flow.step {
                case .welcome:
                    primaryButton("开始设置", systemImage: "arrow.forward") { goForward() }

                    secondarySubmissionButton("使用演示资料", systemImage: "play.rectangle", kind: .demo)
                    { beginSubmission(.demo) }
                case .review:
                    primaryButton("保存并继续", systemImage: "checkmark", submissionKind: .profile) {
                        beginSubmission(.profile)
                    }
                case .complete: primaryButton("进入慢行", systemImage: "arrow.forward") { onComplete() }
                case .preferredName, .age, .conditions, .allergies, .medicines:
                    primaryButton(
                        reviewEditStep == flow.step ? "返回确认资料" : "继续",
                        systemImage: "arrow.forward"
                    ) { goForward() }
                }
            }
        }
        .padding(.horizontal).padding(.vertical, 12).background(.bar)
    }

    private func primaryButton(
        _ title: String,
        systemImage: String,
        submissionKind: SlowWalkOnboardingSubmissionKind? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let isCurrentSubmission =
            submission.state.activeKind == submissionKind && submissionKind != nil
        return Button(action: action) {
            if isCurrentSubmission, let submissionKind {
                HStack {
                    ProgressView()
                    Text(submissionKind.loadingText)
                }
                .frame(maxWidth: .infinity)
            } else {
                Label(title, systemImage: systemImage).frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent).controlSize(.large)
        .frame(minHeight: SlowWalkLayout.minimumTapTarget).disabled(submission.state.isSubmitting)
        .accessibilityLabel(isCurrentSubmission ? submissionKind?.loadingText ?? title : title)
    }

    private func secondarySubmissionButton(
        _ title: String,
        systemImage: String,
        kind: SlowWalkOnboardingSubmissionKind,
        action: @escaping () -> Void
    ) -> some View {
        let isCurrentSubmission = submission.state.activeKind == kind
        return Button(action: action) {
            if isCurrentSubmission {
                HStack {
                    ProgressView()
                    Text(kind.loadingText)
                }
                .frame(maxWidth: .infinity)
            } else {
                Label(title, systemImage: systemImage).frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered).controlSize(.large)
        .frame(minHeight: SlowWalkLayout.minimumTapTarget).disabled(submission.state.isSubmitting)
        .accessibilityLabel(isCurrentSubmission ? kind.loadingText : title)
    }

    private func introduction(for step: SlowWalkOnboardingStep, detail: String) -> some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 6) {
                    Text(step.title).font(.title2.bold())
                    Text(detail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: step.systemImage).font(.title2).foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 8).accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader).accessibilityFocused($focusedStep, equals: step)
            .slowWalkReadableContent()
        }
    }

    private func validationFooter(_ fallback: String) -> some View {
        Group {
            if let validationMessage {
                Text(validationMessage).foregroundStyle(.red)
                    .accessibilityFocused($validationMessageIsFocused)
            } else {
                Text(fallback)
            }
        }
    }

    private func reviewRow(_ title: String, values: [String]) -> some View {
        LabeledContent {
            Text(values.isEmpty ? "未填写" : values.joined(separator: "、"))
                .foregroundStyle(values.isEmpty ? .secondary : .primary)
                .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
        } label: {
            Text(title)
        }
        .accessibilityElement(children: .combine).slowWalkReadableContent()
    }

    private func reviewEditButton(
        _ title: String,
        step: SlowWalkOnboardingStep,
        returnAfter: SlowWalkOnboardingStep? = nil
    ) -> some View {
        Button {
            reviewEditStep = returnAfter ?? step
            flow.step = step
        } label: {
            Label(title, systemImage: "pencil")
        }
        .frame(minHeight: SlowWalkLayout.minimumTapTarget).accessibilityHint("修改后返回确认资料。")
        .slowWalkReadableContent()
    }

    private func onboardingSummaryRow(_ title: String, detail: String, systemImage: String)
        -> some View
    {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: systemImage).foregroundStyle(.tint).accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine).slowWalkReadableContent()
    }

    private var navigationTitle: String {
        guard let failedKind = submission.state.failedKind else { return flow.step.title }
        return failedKind == .profile ? "保存资料" : "演示资料"
    }

    private var showsBackButton: Bool {
        submission.state.failureMessage == nil && flow.step != .welcome && flow.step != .complete
    }

    private func introductionDetail(for field: SlowWalkOnboardingListField) -> String {
        switch field {
        case .conditions: "只填写医生已经告知的情况，不确定时可以留空。"
        case .allergies: "可填写已知的药物或食物过敏，不确定时可以留空。"
        case .medicines: "请照着药盒填写名称，不需要填写剂量或自行判断成分。"
        }
    }

    private func goForward() {
        if let message = SlowWalkOnboardingInputRules.validationMessage(
            for: flow.step,
            draft: draft
        ) {
            validationMessage = message
            validationMessageIsFocused = true
            return
        }

        validationMessage = nil
        listInputMessage = nil
        if reviewEditStep == flow.step {
            reviewEditStep = nil
            flow.step = .review
        } else {
            flow.advance()
        }
    }

    private func goBack() {
        validationMessage = nil
        listInputMessage = nil
        if reviewEditStep != nil {
            reviewEditStep = nil
            flow.step = .review
        } else {
            flow.goBack()
        }
    }

    private func clearValidationMessage(for step: SlowWalkOnboardingStep) {
        guard flow.step == step else { return }
        validationMessage = nil
    }

    private func addItem(_ rawValue: String, to field: SlowWalkOnboardingListField) {
        let currentItems: [String]
        switch field {
        case .conditions: currentItems = draft.diagnosedConditions
        case .allergies: currentItems = draft.allergies
        case .medicines: currentItems = draft.currentMedicineNames
        }

        switch SlowWalkOnboardingInputRules.appending(rawValue, to: currentItems) {
        case .success(let items):
            listInputMessage = nil
            switch field {
            case .conditions:
                draft.diagnosedConditions = items
                conditionText = ""
            case .allergies:
                draft.allergies = items
                allergyText = ""
            case .medicines:
                draft.currentMedicineNames = items
                medicineText = ""
            }
        case .failure(let issue):
            listInputMessage = issue.message
            validationMessageIsFocused = true
        }
    }

    private func removeItem(at index: Int, from field: SlowWalkOnboardingListField) {
        switch field {
        case .conditions:
            draft.diagnosedConditions = SlowWalkOnboardingListMutation.removing(
                at: index,
                from: draft.diagnosedConditions
            )
        case .allergies:
            draft.allergies = SlowWalkOnboardingListMutation.removing(
                at: index,
                from: draft.allergies
            )
        case .medicines:
            draft.currentMedicineNames = SlowWalkOnboardingListMutation.removing(
                at: index,
                from: draft.currentMedicineNames
            )
        }
        listInputMessage = nil
    }

    private func textField(for field: SlowWalkOnboardingListField) -> SlowWalkOnboardingTextField {
        switch field {
        case .conditions: .conditions
        case .allergies: .allergies
        case .medicines: .medicines
        }
    }

    private func beginSubmission(_ kind: SlowWalkOnboardingSubmissionKind) {
        _ = submission.start(kind, draft: draft)
    }

    private func retrySubmission() { _ = submission.retry(draft: draft) }

    private func handleSubmissionState(_ state: SlowWalkOnboardingSubmissionState) {
        switch state {
        case .succeeded(let kind, _):
            completedWithDemoData = kind == .demo
            validationMessage = nil
            listInputMessage = nil
            reviewEditStep = nil
            flow.step = .complete
        case .profileValidation(let issue, _):
            let presentation = SlowWalkOnboardingInputRules.presentation(for: issue)
            reviewEditStep = nil
            flow.step = presentation.step
            validationMessage = presentation.message
            validationMessageIsFocused = true
        case .idle, .submitting, .failed: break
        }
    }
}

#Preview("欢迎") { SlowWalkOnboardingView(onSubmit: { _ in }, onUseDemoData: {}, onComplete: {}) }

#Preview("确认资料 - 深色 AX5") {
    SlowWalkOnboardingView(
        initialDraft: UserProfileDraft(
            preferredName: "王阿姨",
            ageText: "68",
            allergies: ["青霉素"],
            diagnosedConditions: ["高血压"],
            currentMedicineNames: ["药盒上的示例名称"]
        ),
        initialStep: .review,
        onSubmit: { _ in },
        onUseDemoData: {},
        onComplete: {}
    )
    .preferredColorScheme(.dark).dynamicTypeSize(.accessibility5)
}
