import Testing
import Foundation

/// Source-level copy guards for the two competition-reachable surfaces fixed
/// in P1: the demo-data label (`DemoDataBanner` / `DemoDataFooter`) and the
/// safety/capability page (`SafetyInformationView`).
///
/// The demo-data label must read as natural Chinese and keep the clinical-use
/// boundary; the capability page must hide `.unavailable` capabilities rather
/// than show them as "尚未接入" placeholders.
///
/// A source-level guard because SwiftUI view bodies cannot be asserted on
/// directly — the same approach used by the companion demo tests. The
/// canonical `CompanionCopy.demoDataNotice` constant is intentionally left in
/// English for the medicine pipeline; these checks only cover the two files
/// whose user-visible copy was localized in P1.
struct DemoAndSafetyCopyTests {

    // MARK: - DemoDataBanner / DemoDataFooter (P1-1)

    @Test func demoDataLabelIsChineseAndKeepsClinicalBoundary() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SlowWalkApp")
            .appendingPathComponent("App")
            .appendingPathComponent("DemoDataBanner.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        // The English canonical stamp is no longer shown to users, and the
        // banner no longer reaches for the English canonical constant.
        #expect(source.contains("DEMO DATA — NOT FOR CLINICAL USE") == false)
        #expect(source.contains("CompanionCopy.demoDataNotice") == false)

        // Natural Chinese, with the clinical-use boundary intact.
        #expect(source.contains("演示数据"))
        #expect(source.contains("不用于临床用途"))
    }

    // MARK: - SafetyInformationView (P1-2)

    @Test func safetyInformationHidesUnavailableCapabilities() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SlowWalkApp")
            .appendingPathComponent("Components")
            .appendingPathComponent("SafetyInformationView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        // Unavailable capabilities are filtered out, never shown as placeholders.
        #expect(source.contains("availability != .unavailable"))

        // The disabled-placeholder vocabulary is absent from this page.
        #expect(source.contains("尚未接入") == false)
        #expect(source.contains("暂不可用") == false)
        #expect(source.contains("未来提供") == false)
        #expect(source.contains("当前阶段未") == false)

        // The section describes what can be experienced, not a status table.
        #expect(source.contains("本次可体验能力"))
        #expect(source.contains("当前能力状态") == false)
    }

    // MARK: - CompanionView canonical confirmation uses display mapping (P2-1)

    @Test func companionCanonicalConfirmationUsesDisplayMappingForLabel() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SlowWalkApp")
            .appendingPathComponent("Features")
            .appendingPathComponent("Companion")
            .appendingPathComponent("CompanionView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        // The confirmation button label routes through displayMedicineName.
        #expect(source.contains("displayMedicineName"))

        // The selection action still passes the raw candidate, not the
        // display-mapped string — canonical identity is preserved.
        #expect(source.contains("confirmCanonicalMedicine(candidate)"))
    }
}
