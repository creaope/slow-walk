import Foundation
import SlowWalkDomain
import Testing

@testable import SlowWalkApp

@MainActor struct SlowWalkOnboardingFlowStateTests {
    @Test func flowVisitsEveryScreenInOrder() {
        var state = SlowWalkOnboardingFlowState()
        var visited = [state.step]
        let expected: [SlowWalkOnboardingStep] = [
            .welcome, .preferredName, .age, .conditions, .allergies, .medicines, .review, .complete,
        ]

        for _ in 1..<expected.count {
            state.advance()
            visited.append(state.step)
        }

        #expect(visited == expected)
        #expect(SlowWalkOnboardingStep.flowOrder == expected)
        state.advance()
        #expect(state.step == .complete)
    }

    @Test func backNavigationStopsAtWelcome() {
        var state = SlowWalkOnboardingFlowState(step: .age)
        state.goBack()
        #expect(state.step == .preferredName)
        state.goBack()
        #expect(state.step == .welcome)
        state.goBack()
        #expect(state.step == .welcome)
    }

    @Test func progressCoversOnlyEditableStepsAndReview() {
        #expect(SlowWalkOnboardingStep.welcome.formPosition == nil)
        #expect(SlowWalkOnboardingStep.preferredName.formPosition == 1)
        #expect(SlowWalkOnboardingStep.review.formPosition == 6)
        #expect(SlowWalkOnboardingStep.complete.formPosition == nil)
    }

    @Test func requiredFieldsUseDomainLimits() {
        var draft = UserProfileDraft()
        #expect(
            SlowWalkOnboardingInputRules.validationMessage(for: .preferredName, draft: draft) != nil
        )

        draft.preferredName = "王阿姨"
        draft.ageText = "abc"
        #expect(
            SlowWalkOnboardingInputRules.validationMessage(for: .preferredName, draft: draft) == nil
        )
        #expect(
            SlowWalkOnboardingInputRules.validationMessage(for: .age, draft: draft) == "请填写数字年龄。"
        )

        draft.ageText = "121"
        #expect(
            SlowWalkOnboardingInputRules.validationMessage(for: .age, draft: draft)
                == "年龄需在 1 到 120 岁之间。"
        )

        draft.ageText = "68"
        #expect(SlowWalkOnboardingInputRules.validationMessage(for: .age, draft: draft) == nil)
    }

    @Test func itemEntryTrimsAndRejectsDuplicates() throws {
        let first = try SlowWalkOnboardingInputRules.appending("  青霉素  ", to: []).get()
        #expect(first == ["青霉素"])

        let duplicate = SlowWalkOnboardingInputRules.appending("青霉素", to: first)
        #expect(duplicate == .failure(.duplicate))
    }

    @Test func itemEntryEnforcesDomainCountAndLengthLimits() {
        let longValue = String(
            repeating: "a",
            count: UserProfileDraftValidator.maximumItemLength + 1
        )
        #expect(SlowWalkOnboardingInputRules.appending(longValue, to: []) == .failure(.tooLong))

        let fullGroup = (0..<UserProfileDraftValidator.maximumItemsPerGroup).map(String.init)
        #expect(SlowWalkOnboardingInputRules.appending("下一项", to: fullGroup) == .failure(.tooMany))
        #expect(SlowWalkOnboardingInputRules.appending("0", to: fullGroup) == .failure(.duplicate))
    }

    @Test func initialListsUseDomainCompatibleCleaningAndStableDeduplication() {
        let normalized = SlowWalkOnboardingInputRules.normalizedDraft(
            UserProfileDraft(
                preferredName: "王阿姨",
                ageText: "68",
                allergies: [" 青霉素 ", "", "青霉素", "花生"],
                diagnosedConditions: [" 高血压 ", "高血压"],
                currentMedicineNames: [" 二甲双胍片 ", "\n"]
            )
        )

        #expect(normalized.allergies == ["青霉素", "花生"])
        #expect(normalized.diagnosedConditions == ["高血压"])
        #expect(normalized.currentMedicineNames == ["二甲双胍片"])
    }

    @Test func uiAppendedItemsRemainValidUnderDomainValidator() throws {
        let allergies = try SlowWalkOnboardingInputRules.appending(" 花生 ", to: ["青霉素", "", "青霉素"])
            .get()
        let draft = UserProfileDraft(preferredName: "王阿姨", ageText: "68", allergies: allergies)

        let bundle = try UserProfileDraftValidator()
            .validate(
                draft,
                id: UUID(),
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 1)
            )

        #expect(bundle.unresolvedAllergyDescriptions == ["青霉素", "花生"])
    }

    @Test func visibleDeleteContractRemovesOnlyTheChosenItem() {
        let items = ["高血压", "糖尿病", "冠心病"]

        #expect(SlowWalkOnboardingListMutation.removing(at: 1, from: items) == ["高血压", "冠心病"])
        #expect(SlowWalkOnboardingListMutation.removing(at: 8, from: items) == items)
        #expect(
            SlowWalkOnboardingListField.allergies.deleteAccessibilityLabel(for: "花生") == "删除过敏情况：花生"
        )
    }

    @Test func textFieldsHavePurposeLabelsHintsAndLiteralFocusOrder() {
        let fields: [SlowWalkOnboardingTextField] = [
            .preferredName, .age, .conditions, .allergies, .medicines,
        ]

        #expect(SlowWalkOnboardingTextField.allCases == fields)
        #expect(fields.map(\.accessibilityLabel) == ["称呼", "年龄", "健康情况", "过敏情况", "当前用药"])
        #expect(fields.allSatisfy { !$0.accessibilityHint.isEmpty })
        #expect(SlowWalkLayout.minimumTapTarget >= 44)
    }

    @Test func onboardingSourceKeepsVisibleDeleteAndReviewEditControls() throws {
        let source = try Self.onboardingViewSource()

        #expect(source.contains("Button(role: .destructive)"))
        #expect(source.contains("field.deleteAccessibilityLabel"))
        #expect(source.contains("SlowWalkLayout.minimumTapTarget"))
        #expect(source.contains("修改基本资料"))
        #expect(source.contains("修改健康情况"))
        #expect(source.contains("修改过敏情况"))
        #expect(source.contains("修改当前用药"))
    }

    @Test func domainValidationIssuesReturnUserFacingStep() {
        let age = SlowWalkOnboardingInputRules.presentation(for: .ageOutOfRange)
        #expect(age.step == .age)
        #expect(age.message.contains("1 到 120"))

        let medicine = SlowWalkOnboardingInputRules.presentation(for: .tooManyCurrentMedicineNames)
        #expect(medicine.step == .medicines)
        #expect(medicine.message.contains("30"))
    }

    private static func onboardingViewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SlowWalkApp").appendingPathComponent("Features")
            .appendingPathComponent("Onboarding")
            .appendingPathComponent("SlowWalkOnboardingView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
