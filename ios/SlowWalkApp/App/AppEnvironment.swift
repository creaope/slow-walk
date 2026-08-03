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
    let medicineCaptureSubmitter: MedicineAssessmentCaptureSubmitter
    let currentUserHealthProfile: UserHealthProfile
    let currentMedicationRecords: [MedicationRecord]

    /// What this build can really do — the app's single capability source.
    ///
    /// Every screen that states a capability reads it from here, or from
    /// `companion.capabilities`, which is this same value. `CapabilityCatalog`
    /// has no static default anywhere else and no view names `.phase0`: the
    /// default is chosen once, on this initialiser's parameter, so a test can
    /// describe a different build by constructing one environment and have the
    /// whole app — behaviour and wording together — follow it.
    let capabilities: CapabilityCatalog

    convenience init(
        clock: any SlowWalkDomain.Clock = AppSystemClock(),
        plan: TodayPlan = .demo,
        simulator: MockMedicineScanSimulator = .demo,
        capabilities: CapabilityCatalog = .phase0
    ) {
        let requester = LocalMedicineAssessmentRequester.demo(clock: clock)
        self.init(
            clock: clock,
            plan: plan,
            simulator: simulator,
            readDelay: ContinuousMedicineReadDelay(),
            capabilities: capabilities,
            medicineRecognizer: AppleVisionMedicineTextRecognizer(),
            medicineRequester: requester,
            medicineConfirmer: requester,
            userHealthProfile: Self.productionDemoUserHealthProfile,
            medicationRecords: []
        )
    }

    init(
        clock: any SlowWalkDomain.Clock,
        plan: TodayPlan,
        simulator: MockMedicineScanSimulator,
        readDelay: any MedicineReadDelaying,
        capabilities: CapabilityCatalog,
        medicineRecognizer: any MedicineTextRecognizing,
        medicineRequester: any MedicineAssessmentRequesting,
        medicineConfirmer: (any MedicineCandidateConfirming)?,
        userHealthProfile: UserHealthProfile,
        medicationRecords: [MedicationRecord]
    ) {
        self.clock = clock
        self.plan = plan
        self.capabilities = capabilities
        currentUserHealthProfile = userHealthProfile
        currentMedicationRecords = medicationRecords

        let store = InMemoryCareRecordStore(clock: clock)
        careRecords = store
        let careActionShownRecorder = CareActionShownRecorder(records: store)
        self.careActionShownRecorder = careActionShownRecorder
        let companion = CompanionSessionModel(
            records: store,
            careActionShownRecorder: careActionShownRecorder,
            simulator: simulator,
            plan: plan,
            readDelay: readDelay,
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
        let runner = MedicineAssessmentRunner(
            session: companion,
            recognizer: medicineRecognizer,
            mapper: MedicineRecognitionInputMapper(
                configuration: mappingConfiguration
            ),
            requester: medicineRequester,
            confirmer: medicineConfirmer,
            clock: clock
        )
        medicineAssessmentRunner = runner
        medicineCaptureSubmitter = MedicineAssessmentCaptureSubmitter(
            runner: runner,
            userHealthProfileProvider: { userHealthProfile },
            medicationRecordsProvider: { medicationRecords }
        )
    }

    func makeMedicineCaptureViewModel(
        previewSource: CameraPreviewSource = CameraPreviewSource(),
        captureService: (any CameraCaptureServicing)? = nil,
        onAssessmentSubmissionAccepted: @escaping @MainActor () -> Void = {}
    ) -> MedicineCaptureViewModel {
        MedicineCaptureViewModel(
            processor: medicineCaptureSubmitter,
            previewSource: previewSource,
            captureService: captureService,
            onAssessmentSubmissionAccepted: onAssessmentSubmissionAccepted
        )
    }

    /// Deterministic environment for previews.
    static func preview(
        fixedDate: Date = Date(timeIntervalSince1970: 1_753_000_000)
    ) -> AppEnvironment {
        AppEnvironment(clock: AppFixedClock(fixedDate: fixedDate))
    }

    /// Current production demo composition. Values mirror
    /// `shared/fixtures/profile-complete.json`; medication history mirrors
    /// `shared/fixtures/medication-history-empty.json`.
    private static let productionDemoUserHealthProfile = UserHealthProfile(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
        age: 72,
        allergies: ["synthetic-pollen"],
        diagnosedConditions: ["synthetic-condition-a"],
        currentMedicineIngredientIDs: ["synthetic-ingredient-b"],
        bodyMetrics: BodyMetrics(
            systolicBloodPressure: 120,
            diastolicBloodPressure: 80,
            heartRate: 70,
            measuredAt: Date(timeIntervalSince1970: 1_753_314_900),
            source: "demo_data",
            deviceIdentifier: "synthetic-device-01"
        ),
        updatedAt: Date(timeIntervalSince1970: 1_753_314_900),
        createdAt: Date(timeIntervalSince1970: 1_752_969_600)
    )
}
