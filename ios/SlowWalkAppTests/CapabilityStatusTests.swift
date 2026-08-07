import Testing
import SlowWalkClientCore
@testable import SlowWalkApp

/// Tests for the capability status model.
///
/// The point of these is not that the table parses — it is that each entry
/// matches what the app can really do, and that the four availability values
/// can never be confused for one another on screen. A capability marked
/// available with nothing behind it is exactly the defect this model exists to
/// prevent, so the tests check the claims against the production types that
/// implement them.
@MainActor
struct CapabilityStatusTests {

    // MARK: - 8. Each capability's stated status matches the implementation

    /// Nothing in this build may be described as `.online`.
    ///
    /// The server is not a default runtime dependency, and no code in the app
    /// target opens a connection to anything. A capability appearing as
    /// `.online` would mean the app had grown a network dependency without the
    /// table being revisited.
    @Test func noCapabilityClaimsToBeOnline() {
        for status in CapabilityCatalog.phase0.allStatuses {
            #expect(
                status.availability != .online,
                "\(status.displayName) claims to need the network"
            )
        }
    }

    /// The server is not required for the app to run.
    ///
    /// Stated as `.unavailable`: the app does not reach the server at all, so
    /// it cannot be a dependency. The wording must say so plainly rather than
    /// leaving a reader to infer it.
    @Test func serverIsNotADefaultDependency() {
        let catalog = CapabilityCatalog.phase0
        #expect(catalog.availability(of: .serverDependency) == .unavailable)

        guard let detail = catalog.detail(of: .serverDependency) else {
            Issue.record("the server's status needs an explanation")
            return
        }
        #expect(detail.contains("不是本 App 的默认运行依赖"))
    }

    /// Medicine recognition is `.simulated`, matching
    /// `MockMedicineScanSimulator`.
    ///
    /// Checked against the production simulator rather than asserted in
    /// isolation: the demo script is what makes this capability simulated, so
    /// the test reads it. If a real recognizer ever replaces the script, the
    /// script disappears and this test has to be revisited deliberately.
    @Test func medicineRecognitionIsSimulatedNotReal() {
        let catalog = CapabilityCatalog.phase0
        let availability = catalog.availability(of: .medicineRecognition)

        #expect(availability == .simulated)
        // "Simulated" means it runs, but not on real input.
        #expect(availability.isImplemented)
        #expect(availability.isRealImplementation == false)

        // What makes it simulated: a fixed script, consulted by attempt number.
        let scripted = MockMedicineScanSimulator.demo
        #expect(scripted.outcome(forAttemptNumber: 1) != nil)
        #expect(scripted.outcome(forAttemptNumber: 2) != nil)
    }

    /// Risk assessment is not available, and is not described as device-local.
    ///
    /// `MedicinePipeline` exists in `SlowWalkCore`, but no adapter in this
    /// target reaches it, so the app cannot assess anything. Marking this
    /// `.deviceLocal` before `LocalMedicineAssessmentRequester` lands would be
    /// the single most misleading entry in the table.
    @Test func riskAssessmentIsNotYetAvailable() {
        let catalog = CapabilityCatalog.phase0
        #expect(catalog.availability(of: .medicineRiskAssessment) == .unavailable)
        #expect(catalog.availability(of: .medicineRiskAssessment) != .deviceLocal)

        // And the explanation names the stage it arrives in, so the status is
        // an entry point rather than a dead end.
        guard let detail = catalog.detail(of: .medicineRiskAssessment) else {
            Issue.record("the assessment status needs an explanation")
            return
        }
        #expect(detail.contains("下一阶段"))
    }

    /// The unimplemented Apple capabilities are all reported unavailable.
    ///
    /// `ios/README.md` records that no Vision, CoreLocation, or protected
    /// storage adapter exists, and no arrival is observed. Each must say so.
    @Test func unimplementedCapabilitiesAreReportedUnavailable() {
        let catalog = CapabilityCatalog.phase0
        let expectedUnavailable: [AppCapability] = [
            .medicationReminder,
            .visionOCR,
            .coreLocation,
            .arrivalReminder,
            .careRecordPersistence,
            .trustedContacts,
        ]

        for capability in expectedUnavailable {
            let availability = catalog.availability(of: capability)
            #expect(
                availability == .unavailable,
                "\(capability.displayName) claims to work"
            )
            #expect(availability.isImplemented == false)
            #expect(availability.isRealImplementation == false)
        }
    }

    /// Every capability is described, and none is left to a default.
    ///
    /// The catalog reports an unlisted capability as `.unavailable`, which is
    /// the safe direction — but a capability that is genuinely unavailable and
    /// one that was simply forgotten should not be indistinguishable, so every
    /// case must carry an explanation.
    @Test func everyCapabilityIsDescribed() {
        let catalog = CapabilityCatalog.phase0
        #expect(catalog.allStatuses.count == AppCapability.allCases.count)

        for status in catalog.allStatuses {
            #expect(
                status.displayName.isEmpty == false,
                "\(status.capability) has no name"
            )
            #expect(
                status.detail?.isEmpty == false,
                "\(status.displayName) has no explanation"
            )
        }
    }

    /// An unlisted capability is understated, never overstated.
    @Test func unlistedCapabilityDefaultsToUnavailable() {
        let empty = CapabilityCatalog(availability: [:])
        for capability in AppCapability.allCases {
            #expect(empty.availability(of: capability) == .unavailable)
        }
    }

    // MARK: - 9. The four availability values cannot be confused

    /// Every availability has a distinct label.
    ///
    /// Two capabilities in different states must never read the same on screen.
    @Test func availabilityLabelsAreAllDistinct() {
        let labels = CapabilityAvailability.allCases.map(\.shortLabel)
        #expect(Set(labels).count == CapabilityAvailability.allCases.count)
        #expect(labels.allSatisfy { $0.isEmpty == false })
    }

    /// No label is a prefix or substring of another.
    ///
    /// Distinctness alone is not enough: if "模拟" were a substring of the
    /// device-local label, a truncated badge or a partial VoiceOver reading
    /// could turn one status into the other. This is the assertion that keeps
    /// simulated from ever being read as device-local.
    @Test func noAvailabilityLabelContainsAnother() {
        let labels = CapabilityAvailability.allCases.map(\.shortLabel)
        for outer in labels {
            for inner in labels where inner != outer {
                #expect(
                    outer.contains(inner) == false,
                    "\"\(outer)\" contains \"\(inner)\""
                )
            }
        }
    }

    /// The four values answer "is this real" correctly.
    ///
    /// `.simulated` is the trap: it is implemented, so a check for "does
    /// anything happen" says yes, but it does not work on real input, so any
    /// claim about the world must consult `isRealImplementation` instead.
    @Test func simulatedIsImplementedButNotReal() {
        #expect(CapabilityAvailability.simulated.isImplemented)
        #expect(CapabilityAvailability.simulated.isRealImplementation == false)

        #expect(CapabilityAvailability.deviceLocal.isImplemented)
        #expect(CapabilityAvailability.deviceLocal.isRealImplementation)

        #expect(CapabilityAvailability.online.isImplemented)
        #expect(CapabilityAvailability.online.isRealImplementation)

        #expect(CapabilityAvailability.unavailable.isImplemented == false)
        #expect(CapabilityAvailability.unavailable.isRealImplementation == false)
    }

    /// A displayed status line carries both the name and the real state.
    @Test func summaryLineStatesNameAndAvailability() {
        let status = CapabilityStatus(
            capability: .medicineRecognition,
            availability: .simulated,
            detail: "候选药名来自固定演示脚本。"
        )
        #expect(status.summaryLine.contains("药品识别"))
        #expect(status.summaryLine.contains(CapabilityAvailability.simulated.shortLabel))
        #expect(status.summaryLine.contains("候选药名来自固定演示脚本。"))

        // Without a detail, the line is still complete.
        let bare = CapabilityStatus(
            capability: .visionOCR,
            availability: .unavailable,
            detail: nil
        )
        #expect(bare.summaryLine.contains("尚未接入"))
    }

    // MARK: - Copy is derived from the table, not written twice

    /// The flow's wording follows whatever table it is given.
    ///
    /// This replaces an earlier test that asserted
    /// `CompanionCopy.capabilities == .phase0`. That assertion described the
    /// defect rather than the guarantee: `CompanionCopy` holding its own catalog
    /// was itself the second source of truth, so the wording stayed fixed on the
    /// shipping table while the session ran against an injected one.
    ///
    /// The real guarantee is that the wording has no table of its own — it can
    /// only describe the one passed in. Proven by passing two different catalogs
    /// and requiring the sentence to change.
    @Test func gateWordingFollowsTheCatalogItIsGiven() {
        let gate = MedicineAssessmentGateTests.makeGate(
            latestUpdate: MedicineAssessmentStateUpdate(
                sequenceNumber: 1,
                state: .failed(MedicineAssessmentGateTests.clientFailure)
            )
        )
        let state = CompanionFlowState.awaitingMedicineAssessment(gate)

        let shipping = CompanionCopy.situation(for: state, capabilities: .phase0)
        let injected = CompanionCopy.situation(
            for: state,
            capabilities: TestCapabilityCatalogs.allMarked
        )

        // The shipping wording carries the shipping explanation...
        #expect(shipping.contains("下一阶段"))
        #expect(shipping.contains(TestCapabilityCatalogs.marker) == false)
        // ...and the injected one carries the injected explanation. A
        // `CompanionCopy` with its own catalog produces the same string twice.
        #expect(injected.contains(TestCapabilityCatalogs.marker))
        #expect(injected != shipping)
    }

    /// The flow never describes a capability it does not have.
    ///
    /// Sweeps the wording for every state and rejects the specific claims that
    /// were previously made — reading a photo, recording a route, reminding on
    /// arrival, having assessed the medicine. Each is checked against the
    /// capability that would have to be real for it to be true.
    @Test func noStateClaimsAnUnavailableCapability() {
        let catalog = CapabilityCatalog.phase0

        // Claim -> the capability that must be real for it to be honest.
        let forbiddenClaims: [(claim: String, requires: AppCapability)] = [
            ("正在读取照片", .visionOCR),
            ("读取药盒上的文字", .visionOCR),
            ("路线正在记录", .coreLocation),
            ("正在使用真实定位", .coreLocation),
            ("到站时会自动提醒", .arrivalReminder),
            ("到站前会提前提醒", .arrivalReminder),
            ("已完成药品评估", .medicineRiskAssessment),
            ("已保存健康记录", .careRecordPersistence),
        ]

        for state in MedicineAssessmentGateTests.everyState {
            let wording = [
                CompanionCopy.stepLabel(for: state),
                CompanionCopy.situation(for: state, capabilities: catalog),
                CompanionCopy.nextStep(for: state),
                CompanionCopy.reason(for: state) ?? "",
            ].joined(separator: " ")

            for (claim, capability) in forbiddenClaims
            where catalog.availability(of: capability).isRealImplementation == false {
                let badge = catalog.availability(of: capability).shortLabel
                #expect(
                    wording.contains(claim) == false,
                    """
                    \(state) claims "\(claim)" but \
                    \(capability.displayName) is \(badge)
                    """
                )
            }
        }
    }

    /// The simulated read says it is simulated.
    ///
    /// The absence of a false claim is not the same as the presence of a true
    /// one: a screen that said nothing at all would pass the sweep above while
    /// still leaving a person to assume their photo was being read.
    @Test func scanningStateSaysItIsSimulated() {
        let wording = CompanionCopy.situation(
            for: .scanningMedicine(.first),
            capabilities: .phase0
        )
        #expect(wording.contains("模拟"))
        #expect(wording.contains("不读取照片"))
    }

    /// The travelling state says the location is a demo one.
    @Test func travellingStateSaysLocationIsDemoOnly() {
        let situation = CompanionCopy.situation(
            for: .travelling,
            capabilities: .phase0
        )
        #expect(situation.contains("演示位置"))
        #expect(situation.contains("不记录真实路线"))

        // And that arrival is not announced automatically.
        let nextStep = CompanionCopy.nextStep(for: .travelling)
        #expect(nextStep.contains("不会自动提醒"))
    }
}
