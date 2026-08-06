import Combine
import Foundation
import SlowWalkDomain

enum SlowWalkOnboardingStep: CaseIterable, Hashable {
    case welcome
    case preferredName
    case age
    case conditions
    case allergies
    case medicines
    case review
    case complete

    private static let formSteps: [Self] = [
        .preferredName, .age, .conditions, .allergies, .medicines, .review,
    ]

    static let flowOrder: [Self] = [
        .welcome, .preferredName, .age, .conditions, .allergies, .medicines, .review, .complete,
    ]

    var next: Self? {
        switch self {
        case .welcome: .preferredName
        case .preferredName: .age
        case .age: .conditions
        case .conditions: .allergies
        case .allergies: .medicines
        case .medicines: .review
        case .review: .complete
        case .complete: nil
        }
    }

    var previous: Self? {
        switch self {
        case .welcome: nil
        case .preferredName: .welcome
        case .age: .preferredName
        case .conditions: .age
        case .allergies: .conditions
        case .medicines: .allergies
        case .review: .medicines
        case .complete: .review
        }
    }

    var formPosition: Int? { Self.formSteps.firstIndex(of: self).map { $0 + 1 } }

    var formStepCount: Int { Self.formSteps.count }

    var title: String {
        switch self {
        case .welcome: "欢迎使用慢行"
        case .preferredName: "怎么称呼您？"
        case .age: "您的年龄"
        case .conditions: "健康情况"
        case .allergies: "过敏情况"
        case .medicines: "当前用药"
        case .review: "确认资料"
        case .complete: "设置完成"
        }
    }

    var systemImage: String {
        switch self {
        case .welcome: "figure.walk"
        case .preferredName: "person.text.rectangle"
        case .age: "calendar"
        case .conditions: "heart.text.square"
        case .allergies: "allergens"
        case .medicines: "pills"
        case .review: "checklist"
        case .complete: "checkmark.circle"
        }
    }
}

struct SlowWalkOnboardingFlowState: Equatable {
    var step: SlowWalkOnboardingStep

    init(step: SlowWalkOnboardingStep = .welcome) { self.step = step }

    mutating func advance() {
        guard let next = step.next else { return }
        step = next
    }

    mutating func goBack() {
        guard let previous = step.previous else { return }
        step = previous
    }
}

enum SlowWalkOnboardingListField: CaseIterable, Equatable {
    case conditions
    case allergies
    case medicines

    var accessibilityName: String {
        switch self {
        case .conditions: "健康情况"
        case .allergies: "过敏情况"
        case .medicines: "当前用药"
        }
    }

    func deleteAccessibilityLabel(for value: String) -> String { "删除\(accessibilityName)：\(value)" }
}

enum SlowWalkOnboardingTextField: CaseIterable, Equatable {
    case preferredName
    case age
    case conditions
    case allergies
    case medicines

    var accessibilityLabel: String {
        switch self {
        case .preferredName: "称呼"
        case .age: "年龄"
        case .conditions: "健康情况"
        case .allergies: "过敏情况"
        case .medicines: "当前用药"
        }
    }

    var accessibilityHint: String {
        switch self {
        case .preferredName: "例如王阿姨"
        case .age: "例如六十八"
        case .conditions: "例如高血压"
        case .allergies: "例如青霉素或花生"
        case .medicines: "请填写药盒上的名称"
        }
    }
}

enum SlowWalkOnboardingListMutation {
    static func removing(at index: Int, from items: [String]) -> [String] {
        guard items.indices.contains(index) else { return items }
        var updated = items
        updated.remove(at: index)
        return updated
    }
}

enum SlowWalkOnboardingItemIssue: Error, Equatable {
    case empty
    case duplicate
    case tooLong
    case tooMany

    var message: String {
        switch self {
        case .empty: "请先输入内容。"
        case .duplicate: "这项内容已经添加。"
        case .tooLong: "每项最多可填写 80 个字符。"
        case .tooMany: "每组最多可添加 30 项。"
        }
    }
}

enum SlowWalkOnboardingInputRules {
    static func normalizedDraft(_ draft: UserProfileDraft) -> UserProfileDraft {
        var normalized = draft
        normalized.diagnosedConditions = cleanedUniqueItems(draft.diagnosedConditions)
        normalized.allergies = cleanedUniqueItems(draft.allergies)
        normalized.currentMedicineNames = cleanedUniqueItems(draft.currentMedicineNames)
        return normalized
    }

    static func validationMessage(for step: SlowWalkOnboardingStep, draft: UserProfileDraft)
        -> String?
    {
        switch step {
        case .preferredName:
            let name = clean(draft.preferredName)
            if name.isEmpty { return "请填写希望我们使用的称呼。" }
            if name.count > UserProfileDraftValidator.maximumPreferredNameLength {
                return "称呼最多可填写 30 个字符。"
            }
        case .age:
            let ageText = clean(draft.ageText)
            guard let age = Int(ageText) else { return "请填写数字年龄。" }
            if !UserProfileDraftValidator.validAgeRange.contains(age) { return "年龄需在 1 到 120 岁之间。" }
        case .welcome, .conditions, .allergies, .medicines, .review, .complete: break
        }
        return nil
    }

    static func appending(_ rawValue: String, to items: [String]) -> Result<
        [String], SlowWalkOnboardingItemIssue
    > {
        let value = clean(rawValue)
        guard !value.isEmpty else { return .failure(.empty) }
        guard value.count <= UserProfileDraftValidator.maximumItemLength else {
            return .failure(.tooLong)
        }

        let normalizedItems: [String]
        switch validatedNormalizedItems(items) {
        case .success(let items): normalizedItems = items
        case .failure(let issue): return .failure(issue)
        }

        let comparisonKey = value.lowercased()
        let containsValue = normalizedItems.contains { $0.lowercased() == comparisonKey }
        guard !containsValue else { return .failure(.duplicate) }
        guard normalizedItems.count < UserProfileDraftValidator.maximumItemsPerGroup else {
            return .failure(.tooMany)
        }

        return .success(normalizedItems + [value])
    }

    static func presentation(for issue: UserProfileValidationIssue) -> (
        step: SlowWalkOnboardingStep, message: String
    ) {
        switch issue {
        case .emptyPreferredName: (.preferredName, "请填写希望我们使用的称呼。")
        case .preferredNameTooLong: (.preferredName, "称呼最多可填写 30 个字符。")
        case .ageNotANumber: (.age, "请填写数字年龄。")
        case .ageOutOfRange: (.age, "年龄需在 1 到 120 岁之间。")
        case .tooManyAllergies: (.allergies, "过敏情况最多可添加 30 项。")
        case .allergyTooLong: (.allergies, "每项过敏情况最多可填写 80 个字符。")
        case .tooManyDiagnosedConditions: (.conditions, "健康情况最多可添加 30 项。")
        case .diagnosedConditionTooLong: (.conditions, "每项健康情况最多可填写 80 个字符。")
        case .tooManyCurrentMedicineNames: (.medicines, "当前用药最多可添加 30 项。")
        case .currentMedicineNameTooLong: (.medicines, "每个药名最多可填写 80 个字符。")
        @unknown default: (.review, "请检查填写的资料后再试。")
        }
    }

    private static func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanedUniqueItems(_ items: [String]) -> [String] {
        var result = [String]()
        var seen = Set<String>()
        for item in items {
            let value = clean(item)
            guard !value.isEmpty else { continue }
            if seen.insert(value.lowercased()).inserted { result.append(value) }
        }
        return result
    }

    private static func validatedNormalizedItems(_ items: [String]) -> Result<
        [String], SlowWalkOnboardingItemIssue
    > {
        let normalized = cleanedUniqueItems(items)
        guard normalized.allSatisfy({ $0.count <= UserProfileDraftValidator.maximumItemLength })
        else { return .failure(.tooLong) }
        guard normalized.count <= UserProfileDraftValidator.maximumItemsPerGroup else {
            return .failure(.tooMany)
        }
        return .success(normalized)
    }
}

enum SlowWalkOnboardingSubmissionKind: Equatable, Sendable {
    case profile
    case demo

    var loadingText: String {
        switch self {
        case .profile: "正在保存资料"
        case .demo: "正在载入演示资料"
        }
    }

    var failureTitle: String {
        switch self {
        case .profile: "暂时无法保存"
        case .demo: "暂时无法载入演示资料"
        }
    }

    var retryTitle: String {
        switch self {
        case .profile: "重试保存"
        case .demo: "重试演示资料"
        }
    }

    var failureMessage: String {
        switch self {
        case .profile: "资料没有保存成功。请检查当前设备状态后重试，" + "已经填写的内容会保留在此页面。"
        case .demo: "演示资料暂时无法载入。请检查当前设备状态后重试，" + "演示资料不会替代真实用户资料。"
        }
    }
}

enum SlowWalkOnboardingSubmissionState: Equatable {
    case idle
    case submitting(kind: SlowWalkOnboardingSubmissionKind, operationID: UUID)
    case failed(kind: SlowWalkOnboardingSubmissionKind, message: String)
    case succeeded(kind: SlowWalkOnboardingSubmissionKind, operationID: UUID)
    case profileValidation(issue: UserProfileValidationIssue, operationID: UUID)

    var isSubmitting: Bool {
        if case .submitting = self { return true }
        return false
    }

    var activeKind: SlowWalkOnboardingSubmissionKind? {
        if case .submitting(let kind, _) = self { return kind }
        return nil
    }

    var failedKind: SlowWalkOnboardingSubmissionKind? {
        if case .failed(let kind, _) = self { return kind }
        return nil
    }

    var failureMessage: String? {
        if case .failed(_, let message) = self { return message }
        return nil
    }
}

@MainActor final class SlowWalkOnboardingSubmissionModel: ObservableObject {
    typealias DraftSubmission = @MainActor (UserProfileDraft) async throws -> Void
    typealias DemoSelection = @MainActor () async throws -> Void

    @Published private(set) var state: SlowWalkOnboardingSubmissionState = .idle

    private let onSubmit: DraftSubmission
    private let onUseDemoData: DemoSelection
    private var activeTask: Task<Void, Never>?

    init(onSubmit: @escaping DraftSubmission, onUseDemoData: @escaping DemoSelection) {
        self.onSubmit = onSubmit
        self.onUseDemoData = onUseDemoData
    }

    @discardableResult func start(_ kind: SlowWalkOnboardingSubmissionKind, draft: UserProfileDraft)
        -> Bool
    {
        guard activeTask == nil, !state.isSubmitting else { return false }

        let operationID = UUID()
        state = .submitting(kind: kind, operationID: operationID)
        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                switch kind {
                case .profile: try await self.onSubmit(draft)
                case .demo: try await self.onUseDemoData()
                }
                try Task.checkCancellation()
                self.finishSuccess(kind: kind, operationID: operationID)
            } catch is CancellationError {
                self.finishCancellation(kind: kind, operationID: operationID)
            } catch let issue as UserProfileValidationIssue {
                if kind == .profile {
                    self.finishProfileValidation(issue, operationID: operationID)
                } else {
                    self.finishFailure(kind: kind, operationID: operationID)
                }
            } catch { self.finishFailure(kind: kind, operationID: operationID) }
        }
        return true
    }

    @discardableResult func retry(draft: UserProfileDraft) -> Bool {
        guard case .failed(let kind, _) = state else { return false }
        return start(kind, draft: draft)
    }

    func clearFailure() {
        guard case .failed = state else { return }
        state = .idle
    }

    func invalidate() {
        activeTask?.cancel()
        activeTask = nil
        state = .idle
    }

    private func finishSuccess(kind: SlowWalkOnboardingSubmissionKind, operationID: UUID) {
        guard owns(kind: kind, operationID: operationID) else { return }
        activeTask = nil
        state = .succeeded(kind: kind, operationID: operationID)
    }

    private func finishProfileValidation(_ issue: UserProfileValidationIssue, operationID: UUID) {
        guard owns(kind: .profile, operationID: operationID) else { return }
        activeTask = nil
        state = .profileValidation(issue: issue, operationID: operationID)
    }

    private func finishFailure(kind: SlowWalkOnboardingSubmissionKind, operationID: UUID) {
        guard owns(kind: kind, operationID: operationID) else { return }
        activeTask = nil
        state = .failed(kind: kind, message: kind.failureMessage)
    }

    private func finishCancellation(kind: SlowWalkOnboardingSubmissionKind, operationID: UUID) {
        guard owns(kind: kind, operationID: operationID) else { return }
        activeTask = nil
        state = .idle
    }

    private func owns(kind: SlowWalkOnboardingSubmissionKind, operationID: UUID) -> Bool {
        guard case .submitting(let currentKind, let currentID) = state else { return false }
        return currentKind == kind && currentID == operationID
    }
}
