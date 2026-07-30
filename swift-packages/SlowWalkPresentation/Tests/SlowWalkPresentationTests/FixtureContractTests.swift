import SlowWalkAPIContracts
import SlowWalkClientCore
import SlowWalkDomain
import SlowWalkPresentation
import XCTest

/// Enforces each fixture's frozen `expectation` block against the state the
/// real coordinator and the mapper actually produce.
///
/// Without this file the `expectation` block is decoded but never asserted, so
/// the frozen contract in `demo-fixtures/README.md` documents behavior that
/// nothing checks. Two regressions in particular become invisible:
///
/// - renaming a `MedicineDisplayVariant` case, because no test decodes
///   `expectedPresentationVariant` into the enum;
/// - editing an `expectation` block to match a changed implementation instead
///   of fixing the implementation.
///
/// Every assertion below compares a canonical value to the fixture string:
/// a `MedicineDisplayVariant` raw value, a `RiskLevel` raw value, a
/// `MedicineAssessmentViewState` case name, the canonical `ActionCard` title
/// and `primaryInstruction`, and membership in the canonical
/// `recommendedActions`. No medical rule is re-derived, and no expectation is
/// recomputed from the same code path it is meant to constrain.
final class FixtureContractTests: XCTestCase {

    // MARK: - Presentation variant

    /// The fixture string is decoded into `MedicineDisplayVariant` through its
    /// raw value, so renaming a case fails here instead of drifting silently.
    func test_everyFixture_matchesExpectedPresentationVariant() async throws {
        for payload in try PresentationFixtureLoader.loadAll() {
            let expected = try XCTUnwrap(
                MedicineDisplayVariant(
                    rawValue: payload.expectation
                        .expectedPresentationVariant
                ),
                """
                Fixture "\(payload.fixtureID)" expects presentation \
                variant "\(payload.expectation.expectedPresentationVariant)", \
                which is not a MedicineDisplayVariant case. Either the enum \
                case was renamed or the fixture is stale.
                """
            )

            let display = MedicineStateMapper.map(
                try await CoordinatorHarness.viewState(for: payload)
            )

            XCTAssertEqual(
                display.variant,
                expected,
                "\(payload.fixtureID) mapped to \(display.variant)"
            )
        }
    }

    // MARK: - Risk level

    /// The canonical reminder level must survive as its own level. A fixture
    /// frozen at `yellow` or `orange` can therefore never be presented as
    /// `green`.
    func test_everyFixture_matchesExpectedRiskLevel() async throws {
        for payload in try PresentationFixtureLoader.loadAll() {
            let expected = try XCTUnwrap(
                RiskLevel(
                    rawValue: payload.expectation.expectedRiskLevel
                ),
                """
                Fixture "\(payload.fixtureID)" expects risk level \
                "\(payload.expectation.expectedRiskLevel)", which is not a \
                canonical RiskLevel case.
                """
            )

            let display = MedicineStateMapper.map(
                try await CoordinatorHarness.viewState(for: payload)
            )

            XCTAssertEqual(
                display.riskLevel,
                expected,
                "\(payload.fixtureID) risk level mismatch"
            )
            // The card carries the same canonical level; the display never
            // re-derives one from the variant.
            XCTAssertEqual(
                display.actionCard?.riskLevel,
                expected,
                "\(payload.fixtureID) action card risk level mismatch"
            )
        }
    }

    // MARK: - Coordinator view state

    /// Guards the other half of the frozen contract: the canonical coordinator
    /// state the fixture documents. A fixture that starts landing on a
    /// different page fails here even when the variant still matches.
    func test_everyFixture_matchesExpectedCoordinatorViewState() async throws {
        for payload in try PresentationFixtureLoader.loadAll() {
            let viewState = try await CoordinatorHarness.viewState(
                for: payload
            )

            XCTAssertEqual(
                Self.caseName(of: viewState),
                payload.expectation.expectedViewState,
                "\(payload.fixtureID) coordinator view state mismatch"
            )
        }
    }

    /// A faithful reading of the canonical `MedicineAssessmentViewState` case,
    /// using the same names `demo-fixtures/README.md` records.
    private static func caseName(
        of state: MedicineAssessmentViewState
    ) -> String {
        switch state {
        case .idle:
            return "idle"
        case .recognizing:
            return "recognizing"
        case .requiresMedicineConfirmation:
            return "requiresMedicineConfirmation"
        case .assessing:
            return "assessing"
        case .result:
            return "result"
        case .failed:
            return "failed"
        case .cancelled:
            return "cancelled"
        }
    }

    // MARK: - Canonical card text

    /// The rendered medical sentences are the fixture's own, verbatim.
    func test_everyFixture_matchesExpectedCardText() async throws {
        for payload in try PresentationFixtureLoader.loadAll() {
            let display = MedicineStateMapper.map(
                try await CoordinatorHarness.viewState(for: payload)
            )
            let card = try XCTUnwrap(
                display.actionCard,
                "\(payload.fixtureID) produced no action card"
            )

            XCTAssertEqual(
                card.title,
                payload.expectation.expectedActionCardTitle,
                "\(payload.fixtureID) title mismatch"
            )
            XCTAssertEqual(
                card.primaryInstruction,
                payload.expectation
                    .expectedActionCardPrimaryInstruction,
                "\(payload.fixtureID) primary instruction mismatch"
            )
        }
    }

    // MARK: - Recommended contact expectations

    /// The two contact expectations are pure membership checks against the
    /// canonical `recommendedActions`. Nothing is inferred from a risk level
    /// or a warning sentence.
    func test_everyFixture_matchesExpectedContactRecommendations() async throws {
        for payload in try PresentationFixtureLoader.loadAll() {
            let display = MedicineStateMapper.map(
                try await CoordinatorHarness.viewState(for: payload)
            )
            let actions = try XCTUnwrap(
                display.actionCard?.recommendedActions,
                "\(payload.fixtureID) produced no action card"
            )

            XCTAssertEqual(
                actions.contains(.notifyFamilyMember),
                payload.expectation.recommendContactFamily,
                "\(payload.fixtureID) family contact expectation mismatch"
            )
            XCTAssertEqual(
                actions.contains(
                    .consultHealthcareProfessional
                ),
                payload.expectation
                    .recommendContactHealthcareProfessional,
                """
                \(payload.fixtureID) healthcare professional contact \
                expectation mismatch
                """
            )
        }
    }

    /// A fixture the demo script may not narrate as an ordinary result must
    /// never reach the `normal` presentation.
    ///
    /// This is asserted as a one-way implication on purpose: the fixture flag
    /// constrains the presentation, and no rule deciding the flag is
    /// reinvented here.
    func test_fixturesWithoutOrdinaryExplanation_neverMapToNormal() async throws {
        for payload in try PresentationFixtureLoader.loadAll()
            where payload.expectation
                .allowsOrdinaryExplanation == false
        {
            let display = MedicineStateMapper.map(
                try await CoordinatorHarness.viewState(for: payload)
            )

            XCTAssertNotEqual(
                display.variant,
                .normal,
                """
                \(payload.fixtureID) forbids an ordinary explanation but \
                mapped to the normal presentation
                """
            )
        }
    }

    // MARK: - Fixture coverage

    /// The frozen table lists five JSON fixtures and each must map to a
    /// distinct presentation variant, so no two scenarios can quietly merge.
    func test_fixtureVariants_areDistinct() async throws {
        var variants: Set<MedicineDisplayVariant> = []
        for payload in try PresentationFixtureLoader.loadAll() {
            let display = MedicineStateMapper.map(
                try await CoordinatorHarness.viewState(for: payload)
            )
            variants.insert(display.variant)
        }

        XCTAssertEqual(
            variants.count,
            PresentationFixtureLoader
                .allJSONFixtureFilenames.count,
            "Two fixtures collapsed onto the same presentation variant"
        )
    }
}
