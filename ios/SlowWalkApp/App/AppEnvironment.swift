import Foundation
import SlowWalkClientCore
import SlowWalkDomain

/// The app's composition root.
///
/// Platform implementations and demo doubles are assembled here and handed to
/// features. Views and models never construct a clock, a store, or a network
/// client themselves.
///
/// This stage wires the on-device Vision medicine recognizer and local demo
/// assessment pipeline. `ios/README.md` records the remaining platform work,
/// including CoreLocation, protected storage, and speech.
@Observable
@MainActor
final class AppEnvironment {
    let clock: any SlowWalkDomain.Clock
    let plan: TodayPlan
    let careRecords: InMemoryCareRecordStore
    let careActionShownRecorder: CareActionShownRecorder
    let companion: CompanionSessionModel
    let medicineAssessmentRunner: MedicineAssessmentRunner

    /// What this build can really do — the app's single capability source.
    ///
    /// Every screen that states a capability reads it from here, or from
    /// `companion.capabilities`, which is this same value. `CapabilityCatalog`
    /// has no static default anywhere else and no view names `.phase0`: the
    /// default is chosen once, on this initialiser's parameter, so a test can
    /// describe a different build by constructing one environment and have the
    /// whole app — behaviour and wording together — follow it.
    let capabilities: CapabilityCatalog

    init(
        clock: any SlowWalkDomain.Clock = AppSystemClock(),
        plan: TodayPlan = .demo,
        simulator: MockMedicineScanSimulator = .demo,
        capabilities: CapabilityCatalog = .phase0
    ) {
        self.clock = clock
        self.plan = plan
        self.capabilities = capabilities

        let store = InMemoryCareRecordStore(clock: clock)
        careRecords = store
        let careActionShownRecorder = CareActionShownRecorder(records: store)
        self.careActionShownRecorder = careActionShownRecorder
        let companion = CompanionSessionModel(
            records: store,
            careActionShownRecorder: careActionShownRecorder,
            simulator: simulator,
            plan: plan,
            capabilities: capabilities
        )
        self.companion = companion

        let mappingConfiguration: MedicineRecognitionMappingConfiguration
        do {
            mappingConfiguration = try MedicineRecognitionMappingConfiguration(
                minimumConfidence: 0,
                lowConfidenceHandling: .retainAsEvidence
            )
        } catch {
            preconditionFailure(
                "Invalid built-in medicine recognition mapping configuration."
            )
        }
        let requester = LocalMedicineAssessmentRequester.demo(clock: clock)
        medicineAssessmentRunner = MedicineAssessmentRunner(
            session: companion,
            recognizer: AppleVisionMedicineTextRecognizer(),
            mapper: MedicineRecognitionInputMapper(
                configuration: mappingConfiguration
            ),
            requester: requester,
            confirmer: requester,
            clock: clock
        )
    }

    /// Deterministic environment for previews.
    static func preview(
        fixedDate: Date = Date(timeIntervalSince1970: 1_753_000_000)
    ) -> AppEnvironment {
        AppEnvironment(clock: AppFixedClock(fixedDate: fixedDate))
    }
}
