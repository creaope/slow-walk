import SlowWalkAPIContracts
import SlowWalkClientCore
import SlowWalkDomain
import SlowWalkPresentation
import XCTest

/// Verifies that each of the five canonical demo fixtures maps to its
/// documented presentation variant, and that the demo disclaimer is
/// carried into the display state.
///
/// Every test runs the real `MedicineAssessmentCoordinator` through
/// `CoordinatorHarness`, then maps the result with `MedicineStateMapper`.
/// No fixture ID, action-card title, or warning sentence is used as a
/// signal — the mapper reads only canonical enum cases and verdicts.
final class FixtureMappingTests: XCTestCase {

    /// The canonical disclaimer all demo callers supply.
    private static let disclaimer =
        MedicinePresentationCopy.demoDisclaimer

    // MARK: - Test 1: normal

    func test_normalFixture_mapsToNormal() async throws {
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

        XCTAssertEqual(display.variant, .normal)
        XCTAssertNotNil(display.actionCard)
        XCTAssertEqual(
            display.actionCard?.riskLevel,
            .green
        )
        XCTAssertFalse(display.requiresMedicineConfirmation)
        XCTAssertNil(display.failure)
        // Demo disclaimer is carried into the display.
        XCTAssertEqual(
            display.demoDisclaimer,
            Self.disclaimer
        )
    }

    // MARK: - Test 2: ambiguous

    func test_ambiguousFixture_mapsToAmbiguous() async throws {
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

        XCTAssertEqual(display.variant, .ambiguous)
        XCTAssertNotNil(display.actionCard)
        XCTAssertTrue(display.requiresMedicineConfirmation)
        XCTAssertNil(display.failure)
        // The ambiguous fixture does not carry the disclaimer in
        // actionCard.warnings, but the display state still carries it
        // because the demo caller passes it explicitly.
        XCTAssertEqual(
            display.demoDisclaimer,
            Self.disclaimer
        )
    }

    // MARK: - Test 3: healthWarning

    func test_healthWarningFixture_mapsToHealthWarning() async throws {
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

        XCTAssertEqual(
            display.variant,
            .healthWarning
        )
        XCTAssertNotNil(display.actionCard)
        // Health-warning fixture carries yellow, not green.
        XCTAssertEqual(
            display.actionCard?.riskLevel,
            .yellow
        )
        XCTAssertNil(display.failure)
        XCTAssertEqual(
            display.demoDisclaimer,
            Self.disclaimer
        )
    }

    // MARK: - Test 4: knowledgeWarning

    func test_knowledgeWarningFixture_mapsToKnowledgeWarning() async throws {
        let payload = try PresentationFixtureLoader.load(
            "medicine-source-warning.json"
        )
        let viewState = try await CoordinatorHarness.viewState(
            for: payload
        )
        let display = MedicineStateMapper.map(
            viewState,
            demoDisclaimer: Self.disclaimer
        )

        XCTAssertEqual(
            display.variant,
            .knowledgeWarning
        )
        XCTAssertNotNil(display.actionCard)
        XCTAssertTrue(display.requiresMedicineConfirmation)
        XCTAssertNil(display.failure)
        XCTAssertEqual(
            display.demoDisclaimer,
            Self.disclaimer
        )
    }

    // MARK: - Test 5: redRisk

    func test_redRiskFixture_mapsToRedRisk() async throws {
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

        XCTAssertEqual(display.variant, .redRisk)
        XCTAssertNotNil(display.actionCard)
        XCTAssertEqual(
            display.actionCard?.riskLevel,
            .red
        )
        XCTAssertNil(display.failure)
        XCTAssertEqual(
            display.demoDisclaimer,
            Self.disclaimer
        )
    }

    // MARK: - All fixtures load

    func test_allFiveFixtures_loadWithoutErrorAndProduceActionCards() async throws {
        let payloads = try PresentationFixtureLoader.loadAll()

        XCTAssertEqual(payloads.count, 5)

        for payload in payloads {
            let viewState = try await CoordinatorHarness.viewState(
                for: payload
            )
            let display = MedicineStateMapper.map(
                viewState,
                demoDisclaimer: Self.disclaimer
            )

            // Every fixture produces a display state with a variant
            // that is not idle, recognizing, or assessing.
            switch display.variant {
            case .normal,
                 .ambiguous,
                 .healthWarning,
                 .knowledgeWarning,
                 .redRisk:
                XCTAssertNotNil(
                    display.actionCard,
                    "\(payload.fixtureID) missing action card"
                )
            default:
                XCTFail(
                    "\(payload.fixtureID) mapped to unexpected variant \(display.variant)"
                )
            }

            // Every demo display carries the disclaimer.
            XCTAssertEqual(
                display.demoDisclaimer,
                Self.disclaimer,
                "\(payload.fixtureID) missing demo disclaimer in display"
            )
        }
    }

    // MARK: - Production default

    func test_productionCaller_defaultsToNoDisclaimer() async throws {
        let payload = try PresentationFixtureLoader.load(
            "medicine-normal.json"
        )
        let viewState = try await CoordinatorHarness.viewState(
            for: payload
        )
        // Production callers omit demoDisclaimer; the default is nil.
        let display = MedicineStateMapper.map(viewState)

        XCTAssertNil(display.demoDisclaimer)
    }
}
