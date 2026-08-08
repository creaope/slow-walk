import SlowWalkAPIContracts
import SlowWalkClientCore
import SlowWalkDomain
import SlowWalkPresentation
import XCTest

/// Verifies that every canonical `ActionCard` field is preserved verbatim
/// through `MedicineStateMapper` into `MedicineDisplayState`, that the
/// demo disclaimer is carried into the display, and that
/// `mustConfirmMedicine` has an independent UI label.
final class CanonicalContentTests: XCTestCase {

    private static let disclaimer =
        MedicinePresentationCopy.demoDisclaimer

    // MARK: - Test 17: title 完整传递

    func test_actionCardTitle_isPreserved() async throws {
        let payload = try PresentationFixtureLoader.load(
            "medicine-normal.json"
        )
        let viewState = try await CoordinatorHarness.viewState(
            for: payload
        )
        let display = MedicineStateMapper.map(
            viewState,
            demoDisclaimer: Self.disclaimer
        )

        XCTAssertEqual(
            display.actionCard?.title,
            payload.response.actionCard.title
        )
    }

    func test_resultRecognitionEvidence_isPreserved() async throws {
        let payload = try PresentationFixtureLoader.load(
            "medicine-normal.json"
        )
        let viewState = try await CoordinatorHarness.viewState(
            for: payload
        )
        let display = MedicineStateMapper.map(viewState)

        XCTAssertEqual(
            display.recognition?.recognizedTexts,
            payload.response.resolution.evidence.recognizedTexts
        )
        XCTAssertEqual(
            display.recognition?.resolvedMedicineName,
            payload.response.resolution.selectedMedicine?.canonicalName
        )
        XCTAssertFalse(display.requiresMedicineConfirmation)
        XCTAssertEqual(
            MedicinePresentationCopy.medicineNameLabel(
                requiresMedicineConfirmation:
                    display.requiresMedicineConfirmation
            ),
            MedicinePresentationCopy.resolvedMedicineLabel
        )
    }

    func test_serverConfirmationUsesPendingLabelWithoutChangingMedicineName()
        async throws
    {
        let payload = try PresentationFixtureLoader.load(
            "medicine-source-warning.json"
        )
        let viewState = try await CoordinatorHarness.viewState(
            for: payload
        )
        guard case let .requiresMedicineConfirmation(requirement) = viewState
        else {
            return XCTFail("Expected server confirmation state")
        }
        XCTAssertEqual(requirement.reason, .serverRequiresConfirmation)

        let selectedName = try XCTUnwrap(
            requirement.response?.resolution.selectedMedicine?.canonicalName
        )
        let display = MedicineStateMapper.map(viewState)

        XCTAssertTrue(display.requiresMedicineConfirmation)
        XCTAssertEqual(
            display.recognition?.resolvedMedicineName,
            selectedName
        )
        XCTAssertEqual(
            MedicinePresentationCopy.medicineNameLabel(
                requiresMedicineConfirmation:
                    display.requiresMedicineConfirmation
            ),
            MedicinePresentationCopy.pendingMedicineLabel
        )
    }

    func test_ambiguousRecognitionEvidence_isPreservedWithoutInventingMedicine()
        async throws
    {
        let payload = try PresentationFixtureLoader.load(
            "medicine-ambiguous.json"
        )
        let viewState = try await CoordinatorHarness.viewState(
            for: payload
        )
        let display = MedicineStateMapper.map(viewState)

        XCTAssertEqual(
            display.recognition?.recognizedTexts,
            payload.request.input.recognizedTexts
        )
        XCTAssertNil(payload.response.resolution.selectedMedicine)
        XCTAssertNil(display.recognition?.resolvedMedicineName)
    }

    // MARK: - Test 18: primaryInstruction 完整传递

    func test_actionCardPrimaryInstruction_isPreserved() async throws {
        let payload = try PresentationFixtureLoader.load(
            "medicine-normal.json"
        )
        let viewState = try await CoordinatorHarness.viewState(
            for: payload
        )
        let display = MedicineStateMapper.map(
            viewState,
            demoDisclaimer: Self.disclaimer
        )

        XCTAssertEqual(
            display.actionCard?.primaryInstruction,
            payload.response.actionCard.primaryInstruction
        )
    }

    // MARK: - Test 19: warnings 完整传递

    func test_actionCardWarnings_arePreserved() async throws {
        let payload = try PresentationFixtureLoader.load(
            "medicine-health-warning.json"
        )
        let viewState = try await CoordinatorHarness.viewState(
            for: payload
        )
        let display = MedicineStateMapper.map(
            viewState,
            demoDisclaimer: Self.disclaimer
        )

        let displayWarnings = try XCTUnwrap(
            display.actionCard?.warnings
        )
        XCTAssertEqual(
            displayWarnings,
            payload.response.actionCard.warnings
        )
        // The fixture has multiple warnings including non-disclaimer ones.
        XCTAssertGreaterThan(displayWarnings.count, 1)
    }

    // MARK: - Test 20: recommendedActions 完整传递

    func test_actionCardRecommendedActions_arePreserved() async throws {
        let payload = try PresentationFixtureLoader.load(
            "medicine-red-risk.json"
        )
        let viewState = try await CoordinatorHarness.viewState(
            for: payload
        )
        let display = MedicineStateMapper.map(
            viewState,
            demoDisclaimer: Self.disclaimer
        )

        XCTAssertEqual(
            display.actionCard?.recommendedActions,
            payload.response.actionCard.recommendedActions
        )
        XCTAssertFalse(
            display.actionCard?.recommendedActions.isEmpty == true
        )
    }

    // MARK: - Test 21: sourceReferences 完整传递

    func test_actionCardSourceReferences_arePreserved() async throws {
        let payload = try PresentationFixtureLoader.load(
            "medicine-normal.json"
        )
        let viewState = try await CoordinatorHarness.viewState(
            for: payload
        )
        let display = MedicineStateMapper.map(
            viewState,
            demoDisclaimer: Self.disclaimer
        )

        XCTAssertEqual(
            display.actionCard?.sourceReferences,
            payload.response.actionCard.sourceReferences
        )
        // Normal fixture has two source references.
        XCTAssertEqual(
            display.actionCard?.sourceReferences.count,
            2
        )
    }

    // MARK: - Test 22: riskLevel 完整传递

    func test_actionCardRiskLevel_isPreserved() async throws {
        for filename in PresentationFixtureLoader
            .allJSONFixtureFilenames
        {
            let payload = try PresentationFixtureLoader.load(
                filename
            )
            let viewState = try await CoordinatorHarness
                .viewState(for: payload)
            let display = MedicineStateMapper.map(
                viewState,
                demoDisclaimer: Self.disclaimer
            )

            XCTAssertEqual(
                display.actionCard?.riskLevel,
                payload.response.actionCard.riskLevel,
                "\(filename) riskLevel mismatch"
            )
        }
    }

    // MARK: - Test 23: mustConfirmMedicine 完整传递

    func test_actionCardMustConfirmMedicine_isPreserved() async throws {
        // Ambiguous fixture: mustConfirmMedicine == true.
        let ambiguousPayload = try PresentationFixtureLoader
            .load("medicine-ambiguous.json")
        let ambiguousState = try await CoordinatorHarness
            .viewState(for: ambiguousPayload)
        let ambiguousDisplay = MedicineStateMapper.map(
            ambiguousState,
            demoDisclaimer: Self.disclaimer
        )
        XCTAssertEqual(
            ambiguousDisplay.actionCard?.mustConfirmMedicine,
            true
        )

        // Normal fixture: mustConfirmMedicine == false.
        let normalPayload = try PresentationFixtureLoader.load(
            "medicine-normal.json"
        )
        let normalState = try await CoordinatorHarness.viewState(
            for: normalPayload
        )
        let normalDisplay = MedicineStateMapper.map(
            normalState,
            demoDisclaimer: Self.disclaimer
        )
        XCTAssertEqual(
            normalDisplay.actionCard?.mustConfirmMedicine,
            false
        )
    }

    // MARK: - Test 24: Demo disclaimer 保留

    func test_demoDisclaimer_isCarriedIntoDisplayState() async throws {
        // All five fixtures: the display state carries the canonical
        // disclaimer string regardless of whether actionCard.warnings
        // happens to include it.
        for filename in PresentationFixtureLoader
            .allJSONFixtureFilenames
        {
            let payload = try PresentationFixtureLoader.load(
                filename
            )
            let viewState = try await CoordinatorHarness
                .viewState(for: payload)
            let display = MedicineStateMapper.map(
                viewState,
                demoDisclaimer: Self.disclaimer
            )

            XCTAssertEqual(
                display.demoDisclaimer,
                Self.disclaimer,
                "\(filename) display missing demo disclaimer"
            )
        }
    }

    /// The ambiguous fixture is the only one whose actionCard.warnings
    /// does not contain the disclaimer. The display must still carry it.
    func test_ambiguousFixture_demoDisclaimer_isInDisplayEvenWithoutCardWarning() async throws {
        let payload = try PresentationFixtureLoader.load(
            "medicine-ambiguous.json"
        )
        // Confirm the card itself lacks the disclaimer.
        XCTAssertFalse(
            payload.response.actionCard.warnings.contains(
                "DEMO DATA — NOT FOR CLINICAL USE"
            ),
            "Precondition: ambiguous fixture card must not contain the disclaimer in its warnings"
        )

        let viewState = try await CoordinatorHarness.viewState(
            for: payload
        )
        let display = MedicineStateMapper.map(
            viewState,
            demoDisclaimer: Self.disclaimer
        )

        // The display still carries it because the demo caller passes it.
        XCTAssertEqual(display.demoDisclaimer, Self.disclaimer)
    }

    // MARK: - mustConfirmMedicine independent UI label

    func test_mustConfirmLabel_isNonEmptyAndDistinct() {
        XCTAssertFalse(
            MedicinePresentationCopy.mustConfirmLabel.isEmpty
        )
        // Must not be identical to the confirmation requirement heading.
        XCTAssertNotEqual(
            MedicinePresentationCopy.mustConfirmLabel,
            MedicinePresentationCopy.confirmationRequiredHeading
        )
    }

    // MARK: - Empty source references handled

    func test_emptySourceReferences_producesEmptyListNotNil() async throws {
        let payload = try PresentationFixtureLoader.load(
            "medicine-ambiguous.json"
        )
        let viewState = try await CoordinatorHarness.viewState(
            for: payload
        )
        let display = MedicineStateMapper.map(
            viewState,
            demoDisclaimer: Self.disclaimer
        )

        // The ambiguous fixture has empty source references.
        XCTAssertEqual(
            display.actionCard?.sourceReferences.isEmpty,
            true
        )
    }
}
