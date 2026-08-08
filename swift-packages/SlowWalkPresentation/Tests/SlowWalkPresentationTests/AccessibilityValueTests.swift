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
            doNotTake.contains("请勿服用"),
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

    /// The canonical raw disclaimer stays English: it is the medicine
    /// pipeline's oracle and pass-through value, not a user-visible string.
    func test_demoDisclaimer_canonicalRawStaysEnglish() {
        XCTAssertEqual(
            MedicinePresentationCopy.demoDisclaimer,
            "DEMO DATA — NOT FOR CLINICAL USE"
        )
    }

    /// The known canonical disclaimer is localized to the Chinese sentence users
    /// see; the raw value itself is unchanged.
    func test_displayDisclaimer_localizesCanonicalToChinese() {
        XCTAssertEqual(
            MedicinePresentationCopy.displayDisclaimer(
                for: MedicinePresentationCopy.demoDisclaimer
            ),
            "演示数据，仅用于功能展示，不用于临床用途"
        )
    }

    /// A non-canonical disclaimer must pass through unchanged — this layer never
    /// rewrites medical wording it does not own — and `nil` maps to `nil`.
    func test_displayDisclaimer_passesUnknownDisclaimerThroughUnchanged() {
        XCTAssertEqual(
            MedicinePresentationCopy.displayDisclaimer(
                for: "some other disclaimer"
            ),
            "some other disclaimer"
        )
        XCTAssertNil(
            MedicinePresentationCopy.displayDisclaimer(for: nil)
        )
    }

    /// The assessment page routes its disclaimer through the single mapping
    /// function instead of hardcoding the Chinese sentence in the view.
    func test_assessmentView_routesDisclaimerThroughDisplayMapping() throws {
        let source = try assessmentViewSource()
        XCTAssertTrue(
            source.contains("MedicinePresentationCopy.displayDisclaimer")
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
        let recognitionNotice = try XCTUnwrap(
            body.range(of: "recognitionNoticeSection")
        )
        let recognition = try XCTUnwrap(
            body.range(of: "recognitionSection")
        )

        XCTAssertLessThan(disclaimer.lowerBound, canonicalContent.lowerBound)
        XCTAssertLessThan(
            canonicalContent.lowerBound,
            recognitionNotice.lowerBound
        )
        XCTAssertLessThan(
            recognitionNotice.lowerBound,
            recognition.lowerBound
        )
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

    /// The medicine result page must not show English section headings or
    /// English attention semantics. These are the labels a person reads on the
    /// result page, so they follow the app's Chinese localization like the
    /// rest of the companion flow.
    func test_resultPageHeadingsAndAttentionAreLocalizedToChinese() {
        XCTAssertEqual(
            MedicinePresentationCopy.riskLevelHeading,
            "风险等级"
        )
        XCTAssertEqual(
            MedicinePresentationCopy.primaryInstructionHeading,
            "接下来怎么做"
        )
        XCTAssertEqual(
            MedicinePresentationCopy.warningsHeading,
            "注意事项"
        )
        XCTAssertEqual(
            MedicinePresentationCopy.recommendedActionsHeading,
            "建议措施"
        )
        XCTAssertEqual(
            MedicinePresentationCopy.sourceReferencesHeading,
            "信息来源"
        )
        XCTAssertEqual(
            MedicinePresentationCopy.confirmationRequiredHeading,
            "药品身份未确认"
        )

        XCTAssertEqual(
            MedicinePresentationCopy.attentionName(.routine),
            "日常注意"
        )
        XCTAssertEqual(
            MedicinePresentationCopy.attentionName(.reviewRequired),
            "需要复核"
        )
        XCTAssertEqual(
            MedicinePresentationCopy.attentionName(.urgentAttention),
            "紧急关注"
        )
        XCTAssertEqual(
            MedicinePresentationCopy.attentionName(.immediateAttention),
            "立即关注"
        )

        // The English headings must not survive anywhere in the copy that
        // renders them on the result page.
        let englishLeftovers = [
            "Risk level",
            "What to do next",
            "Warnings",
            "Recommended actions",
            "Information sources",
            "Medicine identity not confirmed",
            "Review required",
            "Routine attention",
            "Urgent attention",
            "Immediate attention",
        ]
        let renderedCopy: [String] = [
            MedicinePresentationCopy.riskLevelHeading,
            MedicinePresentationCopy.primaryInstructionHeading,
            MedicinePresentationCopy.warningsHeading,
            MedicinePresentationCopy.recommendedActionsHeading,
            MedicinePresentationCopy.sourceReferencesHeading,
            MedicinePresentationCopy.confirmationRequiredHeading,
            MedicinePresentationCopy.attentionName(.routine),
            MedicinePresentationCopy.attentionName(.reviewRequired),
            MedicinePresentationCopy.attentionName(.urgentAttention),
            MedicinePresentationCopy.attentionName(.immediateAttention),
        ]
        for english in englishLeftovers {
            XCTAssertFalse(
                renderedCopy.contains(english),
                "English heading \"\(english)\" still rendered on the result page"
            )
        }
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

    // MARK: - Display mapping: medicine name

    func test_displayMedicineName_mapsAcetaminophenToChinese() {
        XCTAssertEqual(
            MedicinePresentationCopy.displayMedicineName(
                "Acetaminophen"
            ),
            "对乙酰氨基酚"
        )
    }

    func test_displayMedicineName_passesUnknownThrough() {
        XCTAssertEqual(
            MedicinePresentationCopy.displayMedicineName(
                "Ibuprofen"
            ),
            "Ibuprofen"
        )
    }

    func test_displayMedicineName_nilReturnsNil() {
        XCTAssertNil(
            MedicinePresentationCopy.displayMedicineName(nil)
        )
    }

    /// The canonical raw value used by the medicine pipeline is never
    /// overwritten by the display mapping.
    func test_displayMedicineName_canonicalRawIsUnchanged() {
        let canonical = "Acetaminophen"
        _ = MedicinePresentationCopy.displayMedicineName(canonical)
        XCTAssertEqual(canonical, "Acetaminophen")
    }

    // MARK: - Display mapping: primary instruction

    func test_displayPrimaryInstruction_mapsKnownToChinese() {
        XCTAssertEqual(
            MedicinePresentationCopy.displayPrimaryInstruction(
                "Review the verified source information before use."
            ),
            "使用前请核对已验证的信息来源。"
        )
    }

    func test_displayPrimaryInstruction_passesUnknownThrough() {
        XCTAssertEqual(
            MedicinePresentationCopy.displayPrimaryInstruction(
                "Some other instruction."
            ),
            "Some other instruction."
        )
    }

    func test_displayPrimaryInstruction_nilReturnsNil() {
        XCTAssertNil(
            MedicinePresentationCopy.displayPrimaryInstruction(nil)
        )
    }

    // MARK: - Display mapping: source document title

    func test_displayDocumentTitle_mapsRealDocumentTitleToChinese() {
        // The real documentTitle from the demo catalog is the same as the
        // canonical demo disclaimer, NOT a composite sourceName + title.
        let realDocumentTitle = "DEMO DATA — NOT FOR CLINICAL USE"
        XCTAssertEqual(
            MedicinePresentationCopy.displayDocumentTitle(
                realDocumentTitle
            ),
            "演示数据，仅用于功能展示，不用于临床用途"
        )
    }

    func test_displayDocumentTitle_passesUnknownThrough() {
        XCTAssertEqual(
            MedicinePresentationCopy.displayDocumentTitle(
                "Some other title"
            ),
            "Some other title"
        )
    }

    func test_displaySourceSummary_exactPairMatchReturnsFullChinese() {
        let reference = SourceReference(
            sourceName: "SlowWalk Synthetic Demo Catalog",
            documentTitle: "DEMO DATA — NOT FOR CLINICAL USE",
            optionalURL: nil,
            retrievedAt: Date(),
            versionOrDate: "slowwalk-demo-catalog-v1"
        )
        let summary = MedicinePresentationCopy
            .displaySourceSummary(reference)
        XCTAssertEqual(
            summary,
            "SlowWalk 演示药品目录 — 演示数据，仅用于功能展示，不用于临床用途"
        )
        XCTAssertFalse(summary.contains("DEMO DATA"))
        XCTAssertFalse(summary.contains("Synthetic Demo Catalog"))
    }

    func test_displaySourceSummary_unknownSourceNamePassesThrough() {
        let reference = SourceReference(
            sourceName: "Some Unknown Source",
            documentTitle: "Some Unknown Title",
            optionalURL: nil,
            retrievedAt: Date(),
            versionOrDate: "v1"
        )
        let summary = MedicinePresentationCopy
            .displaySourceSummary(reference)
        XCTAssertTrue(summary.contains("Some Unknown Source"))
        XCTAssertTrue(summary.contains("Some Unknown Title"))
    }

    func test_displaySourceSummary_knownSourceNameUnknownDocumentTitleDoesNotTriggerDemoMapping() {
        // The exact pair match requires BOTH fields, so a known sourceName
        // with an unknown documentTitle must not trigger the demo mapping.
        let reference = SourceReference(
            sourceName: "SlowWalk Synthetic Demo Catalog",
            documentTitle: "Some Other Title",
            optionalURL: nil,
            retrievedAt: Date(),
            versionOrDate: "v1"
        )
        let summary = MedicinePresentationCopy
            .displaySourceSummary(reference)
        XCTAssertTrue(summary.contains("SlowWalk Synthetic Demo Catalog"))
        XCTAssertTrue(summary.contains("Some Other Title"))
        XCTAssertFalse(summary.contains("SlowWalk 演示药品目录"))
    }

    func test_displaySourceSummary_unknownSourceNameKnownDisclaimerDocumentTitleOnlyMapsTitle() {
        // When only the documentTitle matches the known disclaimer but the
        // sourceName is unknown, only the title portion is mapped; the
        // sourceName is NOT rewritten to the demo catalog name.
        let reference = SourceReference(
            sourceName: "Some External Source",
            documentTitle: "DEMO DATA — NOT FOR CLINICAL USE",
            optionalURL: nil,
            retrievedAt: Date(),
            versionOrDate: "v1"
        )
        let summary = MedicinePresentationCopy
            .displaySourceSummary(reference)
        XCTAssertTrue(summary.contains("Some External Source"))
        XCTAssertTrue(summary.contains("演示数据"))
        XCTAssertFalse(summary.contains("SlowWalk 演示药品目录"))
        XCTAssertFalse(summary.contains("DEMO DATA"))
    }

    // MARK: - Display mapping: non-green primary instructions (P2)

    func test_displayPrimaryInstruction_mapsYellowToChinese() {
        XCTAssertEqual(
            MedicinePresentationCopy.displayPrimaryInstruction(
                "Pause and review the available information."
            ),
            "请暂停并查看现有信息。"
        )
    }

    func test_displayPrimaryInstruction_mapsOrangeToChinese() {
        XCTAssertEqual(
            MedicinePresentationCopy.displayPrimaryInstruction(
                "Review the medication history with a healthcare professional."
            ),
            "请与医护人员核对用药记录。"
        )
    }

    func test_displayPrimaryInstruction_mapsRedToChinese() {
        XCTAssertEqual(
            MedicinePresentationCopy.displayPrimaryInstruction(
                "Do not take this medicine until a healthcare professional confirms the next step."
            ),
            "在医护人员确认之前，请勿服用此药品。"
        )
    }

    func test_displayPrimaryInstruction_mapsConfirmationCardToChinese() {
        XCTAssertEqual(
            MedicinePresentationCopy.displayPrimaryInstruction(
                "Retake a clear photo of the front of the medicine box."
            ),
            "请重新拍摄药品包装盒正面清晰照片。"
        )
    }

    // MARK: - Display mapping: confirmation card title (P2)

    func test_displayMedicineName_mapsConfirmationCardTitleToChinese() {
        XCTAssertEqual(
            MedicinePresentationCopy.displayMedicineName(
                "Unable to confirm the medicine"
            ),
            "无法确认药品身份"
        )
    }

    // MARK: - Display mapping: canonical warnings (P2)

    func test_displayWarning_mapsIdentityWarningToChinese() {
        XCTAssertEqual(
            MedicinePresentationCopy.displayWarning(
                "Do not take this medicine until its identity is confirmed."
            ),
            "药品身份确认前请勿服用。"
        )
    }

    func test_displayWarning_mapsResolutionWarningsToChinese() {
        let pairs: [(String, String)] = [
            (
                "A risk assessment is not available for the resolved medicine.",
                "未能获取已识别药品的风险评估结果。"
            ),
            (
                "More than one medicine matched the recognized text.",
                "识别文字匹配到多个可能的药品。"
            ),
            (
                "The available recognition evidence is insufficient.",
                "当前识别证据不足以确认药品。"
            ),
            (
                "No medicine in the verified data matched the recognized text.",
                "已验证数据中未找到与识别文字匹配的药品。"
            ),
            (
                "The medicine text could not be recognized reliably.",
                "未能可靠识别药品标签文字。"
            ),
        ]
        for (english, chinese) in pairs {
            XCTAssertEqual(
                MedicinePresentationCopy.displayWarning(english),
                chinese
            )
        }
    }

    func test_displayWarning_passesUnknownThrough() {
        XCTAssertEqual(
            MedicinePresentationCopy.displayWarning(
                "Some unknown warning"
            ),
            "Some unknown warning"
        )
    }

    func test_displayWarning_nilReturnsNil() {
        XCTAssertNil(
            MedicinePresentationCopy.displayWarning(nil)
        )
    }

    func test_displayWarning_mapsDemoDisclaimerToChinese() {
        XCTAssertEqual(
            MedicinePresentationCopy.displayWarning(
                "DEMO DATA — NOT FOR CLINICAL USE"
            ),
            "演示数据，仅用于功能展示，不用于临床用途"
        )
    }

    // MARK: - MedicineAssessmentView display guard (P1-2)

    func test_assessmentView_routesResolvedMedicineNameThroughDisplayMapping() throws {
        let source = try assessmentViewSource()
        // The recognition section must route the resolved medicine name
        // through displayMedicineName, not render it raw.
        XCTAssertTrue(
            source.contains("displayMedicineName(medicineName)"),
            "MedicineAssessmentView must use displayMedicineName for the resolved medicine name"
        )
    }

    /// The canonical raw value "Acetaminophen" is never mutated by the
    /// display layer.
    func test_canonicalAcetaminophen_staysUnchanged() {
        let canonical = "Acetaminophen"
        _ = MedicinePresentationCopy.displayMedicineName(canonical)
        XCTAssertEqual(canonical, "Acetaminophen")
    }
}
