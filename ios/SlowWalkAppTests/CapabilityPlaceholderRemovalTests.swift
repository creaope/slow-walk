import Foundation
import Testing
@testable import SlowWalkApp

/// Guards for the final competition-reachable UI consolidation.
///
/// Capability placeholder vocabulary ("尚未接入" / "暂不可用") must not reach a
/// screen the judges see; demo reminders must read as demos; and the
/// contact-someone recovery path must be hidden — not relabelled — when trusted
/// contacts are unavailable.
///
/// Source-level guards because SwiftUI view bodies cannot be asserted on
/// directly, the same approach used elsewhere in this target. The behaviour
/// tests on `CompanionRecoveryOption.isReachable(in:)` prove the contact path is
/// actually filtered out, not merely shown with different wording.
struct CapabilityPlaceholderRemovalTests {

    // MARK: - A. CareSettingsView

    @Test func careSettingsHidesUnavailableCareCapabilities() throws {
        let source = try appSource("Features/Settings/CareSettingsView.swift")

        // The care section is gated on at least one capability being available,
        // and the detail line only includes available capabilities.
        #expect(source.contains("availability != .unavailable"))

        // No disabled-placeholder vocabulary reaches this page.
        #expect(source.contains("尚未接入") == false)
        #expect(source.contains("暂不可用") == false)
    }

    // MARK: - B. CareRecordsView

    @Test func careRecordsShowsHonestInMemoryLabel() throws {
        let source = try appSource("Features/CareRecords/CareRecordsView.swift")

        // Honest wording: records live in this run only.
        #expect(source.contains("本次运行内保存"))

        // The placeholder badge and its VoiceOver line are gone.
        #expect(source.contains("尚未接入") == false)
        #expect(source.contains("persistenceStatus.shortLabel") == false)
        #expect(source.contains("persistenceStatus.summaryLine") == false)

        // No false claim of persistent storage.
        #expect(source.contains("已持久化") == false)
        #expect(source.contains("持久化保存") == false)
    }

    // MARK: - C. MedicationReminderView

    @Test func medicationReminderIsExplicitlyADemo() throws {
        let source = try appSource(
            "Features/Companion/MedicationReminderView.swift"
        )

        // The reminder is labelled as a demo, with an honest footer.
        #expect(source.contains("演示提醒"))
        #expect(source.contains("当前为演示安排，不会发送系统通知。"))

        // No placeholder vocabulary, and the capability badge / its VoiceOver
        // line are no longer rendered.
        #expect(source.contains("尚未接入") == false)
        #expect(source.contains("暂不可用") == false)
        #expect(source.contains("reminderStatus.shortLabel") == false)
        #expect(source.contains("reminderStatus.summaryLine") == false)
    }

    // MARK: - D. CompanionRecoveryOption reachability

    @Test func contactSomeoneNotReachableWhenTrustedContactsUnavailable() {
        // phase0 ships trustedContacts as .unavailable.
        let catalog = CapabilityCatalog.phase0
        #expect(
            CompanionRecoveryOption.contactSomeone.isReachable(in: catalog)
                == false
        )
    }

    @Test func contactSomeoneReachableWhenTrustedContactsAvailable() {
        let catalog = CapabilityCatalog(
            availability: [.trustedContacts: .simulated]
        )
        #expect(
            CompanionRecoveryOption.contactSomeone.isReachable(in: catalog)
        )
    }

    @Test func retryPhotoAndChooseFromListAlwaysReachable() {
        let unavailable = CapabilityCatalog.phase0
        #expect(
            CompanionRecoveryOption.retryPhoto.isReachable(in: unavailable)
        )
        #expect(
            CompanionRecoveryOption.chooseFromList.isReachable(in: unavailable)
        )

        let available = CapabilityCatalog(
            availability: [.trustedContacts: .simulated]
        )
        #expect(
            CompanionRecoveryOption.retryPhoto.isReachable(in: available)
        )
        #expect(
            CompanionRecoveryOption.chooseFromList.isReachable(in: available)
        )
    }

    // MARK: - Helpers

    /// Reads a source file under the app target, relative to `SlowWalkApp/`.
    private func appSource(_ relativePath: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SlowWalkApp")
        for component in relativePath.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
