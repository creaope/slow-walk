import SlowWalkClientCore
import SlowWalkDomain
import SlowWalkPresentation
import XCTest

/// Verifies that accessibility requirements are satisfied at the value level.
///
/// SwiftUI view rendering cannot be unit-tested directly, but every
/// accessibility token — labels, symbols, shape tokens, hit-target constants,
/// and heading strings — is a pure value produced by
/// `MedicinePresentationCopy` or `MedicineHitTarget`.  Testing these values
/// proves the views cannot regress on their accessibility contract.
final class AccessibilityValueTests: XCTestCase {

    // MARK: - Test 25: 风险标签包含文字语义

    func test_riskLevel_hasTextSemantics() {
        for level in RiskLevel.allCases {
            let name = MedicinePresentationCopy.levelName(level)
            XCTAssertFalse(
                name.isEmpty,
                "\(level) has no text name"
            )
            // Text must be a word, not a rawValue symbol.
            XCTAssertNotEqual(name, level.rawValue)
        }
    }

    func test_attentionSemantics_hasTextForEveryLevel() {
        for level in RiskLevel.allCases {
            let presentation = RiskPresentation(level: level)
            let name = MedicinePresentationCopy.attentionName(
                presentation.attention
            )
            XCTAssertFalse(
                name.isEmpty,
                "\(level) attention has no text name"
            )
        }
    }

    /// The four canonical levels must read as four different words.
    ///
    /// Without this, renaming `orange` to "Yellow" — a compression of the
    /// canonical four-level scale into three — passes every other test,
    /// because each name is only checked for being non-empty and unequal to
    /// its own raw value.
    func test_levelNames_areDistinctPerLevel() {
        let names = RiskLevel.allCases.map {
            MedicinePresentationCopy.levelName($0)
        }

        XCTAssertEqual(
            Set(names).count,
            RiskLevel.allCases.count,
            """
            Two reminder levels share a display name (\
            \(names.joined(separator: ", "))). The canonical four-level \
            scale must not be collapsed in presentation.
            """
        )
    }

    func test_yellowAndOrange_haveDistinctLevelNames() {
        XCTAssertNotEqual(
            MedicinePresentationCopy.levelName(.yellow),
            MedicinePresentationCopy.levelName(.orange),
            "Yellow and orange share the same display name"
        )
    }

    /// Each canonical `RiskAttentionSemantics` case must read distinctly, so
    /// the non-color severity vocabulary cannot be collapsed either.
    func test_attentionNames_areDistinctPerCase() {
        let names = RiskAttentionSemantics.allCases.map {
            MedicinePresentationCopy.attentionName($0)
        }

        XCTAssertEqual(
            Set(names).count,
            RiskAttentionSemantics.allCases.count,
            """
            Two attention semantics share a display name (\
            \(names.joined(separator: ", "))).
            """
        )
    }

    /// The full badge reading must differ per level across all four channels
    /// combined, which is what a VoiceOver user actually hears.
    func test_riskAccessibilityLabels_areDistinctPerLevel() {
        let labels = RiskLevel.allCases.map {
            MedicinePresentationCopy.riskAccessibilityLabel(
                RiskPresentation(level: $0)
            )
        }

        XCTAssertEqual(
            Set(labels).count,
            RiskLevel.allCases.count,
            "Two reminder levels produce the same VoiceOver reading"
        )
    }

    // MARK: - Test 26: 风险标签包含非颜色冗余

    func test_riskLevel_hasNonColorRedundancy() {
        for level in RiskLevel.allCases {
            // Each level gets a distinct SF Symbol silhouette.
            let symbol = MedicinePresentationCopy.symbolName(level)
            XCTAssertFalse(
                symbol.isEmpty,
                "\(level) has no symbol name"
            )
            XCTAssertTrue(
                symbol.contains("."),
                "\(level) symbol name is not a valid SF Symbol reference"
            )
        }

        // Distinct levels must not share the same symbol, so a user who
        // cannot perceive color still gets four distinguishable shapes.
        let symbols = Set(
            RiskLevel.allCases.map {
                MedicinePresentationCopy.symbolName($0)
            }
        )
        XCTAssertEqual(
            symbols.count,
            RiskLevel.allCases.count,
            "Risk levels share a symbol — shapes are not distinct"
        )
    }

    func test_shapeTokens_areDistinctPerLevel() {
        let tokens = Set(
            RiskLevel.allCases.map {
                MedicinePresentationCopy.shapeToken($0)
            }
        )
        XCTAssertEqual(
            tokens.count,
            RiskLevel.allCases.count,
            "Risk levels share a shape token"
        )
    }

    func test_yellowAndOrange_haveDistinctSymbols() {
        let yellowSymbol = MedicinePresentationCopy.symbolName(.yellow)
        let orangeSymbol = MedicinePresentationCopy.symbolName(.orange)
        XCTAssertNotEqual(
            yellowSymbol,
            orangeSymbol,
            "Yellow and orange share the same symbol"
        )
    }

    func test_yellowAndOrange_haveDistinctShapeTokens() {
        let yellowToken = MedicinePresentationCopy.shapeToken(.yellow)
        let orangeToken = MedicinePresentationCopy.shapeToken(.orange)
        XCTAssertNotEqual(
            yellowToken,
            orangeToken,
            "Yellow and orange share the same shape token"
        )
    }

    // MARK: - Test 27: Button 的 accessibility label

    func test_confirmButton_hasAccessibilityLabel() {
        XCTAssertFalse(
            MedicinePresentationCopy
                .confirmMedicineButtonTitle.isEmpty
        )
        XCTAssertFalse(
            MedicinePresentationCopy
                .confirmMedicineAccessibilityHint.isEmpty
        )
    }

    func test_retryButton_hasAccessibilityLabel() {
        XCTAssertFalse(
            MedicinePresentationCopy.retryButtonTitle.isEmpty
        )
        XCTAssertFalse(
            MedicinePresentationCopy
                .retryAccessibilityHint.isEmpty
        )
    }

    // MARK: - Test 28: canonical 内容的 accessibility 分组合理

    func test_sectionHeadings_areDistinct() {
        let headings: Set<String> = [
            MedicinePresentationCopy.recognitionHeading,
            MedicinePresentationCopy.riskLevelHeading,
            MedicinePresentationCopy
                .primaryInstructionHeading,
            MedicinePresentationCopy.warningsHeading,
            MedicinePresentationCopy
                .recommendedActionsHeading,
            MedicinePresentationCopy
                .sourceReferencesHeading,
            MedicinePresentationCopy
                .confirmationRequiredHeading,
        ]
        // All seven section headings exist and carry distinct text.
        XCTAssertEqual(headings.count, 7)
        for heading in headings {
            XCTAssertFalse(heading.isEmpty)
        }
    }

    func test_riskAccessibilityLabel_includesLevelAndAttention() {
        for level in RiskLevel.allCases {
            let presentation = RiskPresentation(level: level)
            let label = MedicinePresentationCopy
                .riskAccessibilityLabel(presentation)

            XCTAssertTrue(
                label.contains(
                    MedicinePresentationCopy.levelName(level)
                ),
                "Accessibility label missing level name for \(level)"
            )
            XCTAssertTrue(
                label.contains(
                    MedicinePresentationCopy.attentionName(
                        presentation.attention
                    )
                ),
                "Accessibility label missing attention for \(level)"
            )
        }
    }

    func test_actionNames_areAllNonEmptyAndDistinct() {
        var names = Set<String>()
        for action in RecommendedAction.allCases {
            let name = MedicinePresentationCopy.actionName(action)
            XCTAssertFalse(
                name.isEmpty,
                "\(action) has no display name"
            )
            names.insert(name)
        }
        // Every recommended action has a distinct label — VoiceOver
        // users can distinguish them.
        XCTAssertEqual(
            names.count,
            RecommendedAction.allCases.count
        )
    }

    /// `actionName()` must read each canonical `RecommendedAction` faithfully:
    /// no case may borrow another case's wording, and in particular the
    /// restrictive `doNotTakeUntilMedicineConfirmed` must never be softened
    /// into a different action's label.
    func test_actionName_coversEveryCanonicalCaseWithoutExtras() {
        var seen: [String: RecommendedAction] = [:]
        for action in RecommendedAction.allCases {
            let name = MedicinePresentationCopy.actionName(action)
            if let previous = seen[name] {
                XCTFail(
                    """
                    \(action) and \(previous) both render as "\(name)". \
                    Each canonical action must keep its own wording.
                    """
                )
            }
            seen[name] = action
        }

        XCTAssertEqual(
            seen.count,
            RecommendedAction.allCases.count,
            "actionName() does not cover every RecommendedAction case"
        )

        // The restrictive action must state the restriction it names.
        let doNotTake = MedicinePresentationCopy.actionName(
            .doNotTakeUntilMedicineConfirmed
        )
        XCTAssertTrue(
            doNotTake.lowercased().contains("do not take"),
            """
            doNotTakeUntilMedicineConfirmed renders as "\(doNotTake)", \
            which drops the canonical restriction.
            """
        )
    }

    // MARK: - Demo disclaimer accessibility

    func test_demoDisclaimer_isNonEmpty() {
        XCTAssertFalse(
            MedicinePresentationCopy.demoDisclaimer.isEmpty
        )
    }

    func test_assessmentView_prioritizesSafetyContentBeforeRecognition() throws {
        let source = try assessmentViewSource()
        let bodyEnd = try XCTUnwrap(
            source.range(of: "// MARK: - Demo disclaimer")
        )
        let body = source[..<bodyEnd.lowerBound]
        let disclaimer = try XCTUnwrap(
            body.range(of: "demoDisclaimerSection")
        )
        let canonicalContent = try XCTUnwrap(
            body.range(of: "content")
        )
        let recognition = try XCTUnwrap(
            body.range(of: "recognitionSection")
        )

        XCTAssertLessThan(disclaimer.lowerBound, canonicalContent.lowerBound)
        XCTAssertLessThan(canonicalContent.lowerBound, recognition.lowerBound)
    }

    func test_assessmentView_hasOneTopLevelDisclaimerRow() throws {
        let source = try assessmentViewSource()
        let row = "MedicineDemoDisclaimerRow(text: disclaimer)"
        let occurrenceCount = source.components(separatedBy: row).count - 1

        XCTAssertEqual(occurrenceCount, 1)
    }

    func test_recognitionEvidence_usesNativeDisclosure() throws {
        let source = try assessmentViewSource()
        let recognitionStart = try XCTUnwrap(
            source.range(of: "private var recognitionSection")
        )
        let contentStart = try XCTUnwrap(
            source.range(of: "private var content")
        )
        let recognitionSource = source[
            recognitionStart.lowerBound ..< contentStart.lowerBound
        ]

        XCTAssertTrue(recognitionSource.contains("DisclosureGroup"))
    }

    func test_idleAssessmentText_isLocalized() {
        let visibleText = MedicinePresentationCopy.idleText

        XCTAssertEqual(visibleText, "尚未开始药品评估。")
        XCTAssertFalse(
            visibleText.contains(
                "No medicine assessment has been started."
            )
        )
    }

    // MARK: - mustConfirmMedicine independent label

    func test_mustConfirmLabel_isNonEmptyAndAccessible() {
        let label = MedicinePresentationCopy.mustConfirmLabel
        XCTAssertFalse(label.isEmpty)
        // The label must not reuse the confirmation-requirement heading.
        XCTAssertNotEqual(
            label,
            MedicinePresentationCopy.confirmationRequiredHeading
        )
    }

    // MARK: - Test 29: 交互控件具有至少 44pt 触控区域

    func test_minimumHitTarget_is44Points() {
        XCTAssertGreaterThanOrEqual(
            MedicineHitTarget.minimumSide,
            44
        )
    }

    // MARK: - Test 30: 不限制 Accessibility Dynamic Type

    func test_sourceFiles_doNotClampDynamicTypeSize() throws {
        // Walk the Sources/Views directory and verify no Swift file
        // contains a `.dynamicTypeSize` restriction.
        let viewsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Views")

        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: viewsURL,
                includingPropertiesForKeys: nil
            )
        )

        var violations: [String] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "swift" else { continue }
            let content = try String(
                contentsOf: url,
                encoding: .utf8
            )
            if content.contains(".dynamicTypeSize(") {
                violations.append(url.lastPathComponent)
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            The following view files clamp Dynamic Type, \
            which prevents Accessibility text sizes: \
            \(violations.joined(separator: ", "))
            """
        )
    }

    private func assessmentViewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Views")
            .appendingPathComponent("MedicineAssessmentView.swift")

        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Failure names are all present

    func test_failureNames_areAllNonEmptyAndDistinct() {
        var names = Set<String>()
        for kind in ClientFailureKind.allCases {
            let name = MedicinePresentationCopy.failureName(kind)
            XCTAssertFalse(
                name.isEmpty,
                "\(kind) has no display name"
            )
            names.insert(name)
        }
        XCTAssertEqual(names.count, ClientFailureKind.allCases.count)
    }

    // MARK: - Source reference rendering

    func test_sourceSummary_includesSourceNameAndDocumentTitle() {
        let reference = SourceReference(
            sourceName: "Test Source",
            documentTitle: "Test Document",
            optionalURL: nil,
            retrievedAt: Date(),
            versionOrDate: "v1"
        )
        let summary = MedicinePresentationCopy.sourceSummary(
            reference
        )
        XCTAssertTrue(summary.contains("Test Source"))
        XCTAssertTrue(summary.contains("Test Document"))
    }

    func test_noSourceReferencesText_isNotEmpty() {
        XCTAssertFalse(
            MedicinePresentationCopy
                .noSourceReferencesText.isEmpty
        )
    }
}
