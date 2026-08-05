import Foundation
import SlowWalkClientCore
import SlowWalkDomain
import SlowWalkPresentation
import XCTest

final class RecognitionNoticeTests: XCTestCase {
    private static let fallbackNotice =
        "在线识别暂不可用，已改用设备内识别。"
    private static let onDeviceOnlyNotice =
        "本次仅在设备上识别。"

    func test_copyUsesExactNonTechnicalRecognitionNotices() {
        XCTAssertEqual(
            MedicinePresentationCopy.localFallbackRecognitionNotice,
            Self.fallbackNotice
        )
        XCTAssertEqual(
            MedicinePresentationCopy.onDeviceOnlyRecognitionNotice,
            Self.onDeviceOnlyNotice
        )

        for notice in [Self.fallbackNotice, Self.onDeviceOnlyNotice] {
            for forbiddenTerm in ["智谱", "Provider", "HTTP", "429", "5xx"] {
                XCTAssertFalse(
                    notice.localizedCaseInsensitiveContains(forbiddenTerm)
                )
            }
        }
    }

    func test_remoteResultHasNoRecognitionNotice() throws {
        let payload = try PresentationFixtureLoader.load(
            "medicine-normal.json"
        )
        let state = MedicineAssessmentViewState.result(
            MedicineAssessmentPresentation(
                response: payload.response,
                recognitionContext: .remote
            )
        )

        XCTAssertNil(MedicineStateMapper.map(state).recognitionNotice)
    }

    func test_allRecoverableFallbackReasonsUseOneGenericNotice() throws {
        let payload = try PresentationFixtureLoader.load(
            "medicine-normal.json"
        )
        let reasons: [MedicineRecognitionFallbackReason] = [
            .offline,
            .timeout,
            .rateLimited,
            .serverUnavailable,
            .providerUnavailable,
        ]

        for reason in reasons {
            let state = MedicineAssessmentViewState.result(
                MedicineAssessmentPresentation(
                    response: payload.response,
                    recognitionContext: MedicineRecognitionContext(
                        source: .localFallback,
                        fallbackReason: reason
                    )
                )
            )

            XCTAssertEqual(
                MedicineStateMapper.map(state).recognitionNotice,
                Self.fallbackNotice,
                "Unexpected copy for \(reason)"
            )
        }
    }

    func test_onDeviceOnlyConfirmationShowsNoticeWithoutRecognitionText() {
        let input = MedicineRecognitionInput(
            recognizedTexts: [],
            capturedAt: Date(timeIntervalSince1970: 0),
            languageCode: nil,
            rawConfidence: nil
        )
        let state = MedicineAssessmentViewState
            .requiresMedicineConfirmation(
                MedicineConfirmationRequirement(
                    reason: .noRecognizedText,
                    recognitionInput: input,
                    response: nil,
                    recognitionContext: .onDeviceOnly
                )
            )

        let display = MedicineStateMapper.map(state)
        XCTAssertNil(display.recognition)
        XCTAssertEqual(
            display.recognitionNotice,
            Self.onDeviceOnlyNotice
        )
    }

    func test_confirmationFallbackUsesGenericNotice() {
        let input = MedicineRecognitionInput(
            recognizedTexts: ["sample"],
            capturedAt: Date(timeIntervalSince1970: 0),
            languageCode: "en",
            rawConfidence: 1
        )
        let state = MedicineAssessmentViewState
            .requiresMedicineConfirmation(
                MedicineConfirmationRequirement(
                    reason: .unresolvedMedicine,
                    recognitionInput: input,
                    response: nil,
                    recognitionContext: MedicineRecognitionContext(
                        source: .localFallback,
                        fallbackReason: .timeout
                    )
                )
            )

        XCTAssertEqual(
            MedicineStateMapper.map(state).recognitionNotice,
            Self.fallbackNotice
        )
    }

    func test_displayStateKeepsRecognitionNoticeOptionalByDefault() {
        let display = MedicineDisplayState(
            variant: .idle,
            actionCard: nil,
            failure: nil,
            requiresMedicineConfirmation: false
        )

        XCTAssertNil(display.recognitionNotice)
    }
}
