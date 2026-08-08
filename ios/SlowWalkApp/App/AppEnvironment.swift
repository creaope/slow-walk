import Foundation
import SlowWalkClientCore
import SlowWalkDomain

/// The app's composition root.
///
/// Platform implementations and demo doubles are assembled here and handed to
/// features. Views and models never construct a clock, a store, or a network
/// client themselves.
///
/// Medicine package recognition is remote-first only when a validated endpoint
/// is configured. Risk assessment remains in the existing local pipeline.
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
    let medicineRecognitionPreferences: MedicineRecognitionPreferences
    let medicineRecognitionServerConfiguration:
        MedicineRecognitionServerConfiguration
    let currentUserHealthProfile: UserHealthProfile
    let currentMedicationRecords: [MedicationRecord]

    /// What this build can really do — the app's single capability source.
    ///
    /// Every screen that states a capability reads it from here, or from
    /// `companion.capabilities`, which is this same value. `CapabilityCatalog`
    /// remains injectable for tests. When omitted, production facts are
    /// derived once from the validated recognition configuration so behaviour
    /// and wording follow the same catalog.
    let capabilities: CapabilityCatalog

    convenience init(
        clock: any SlowWalkDomain.Clock = AppSystemClock(),
        plan: TodayPlan = .demo,
        simulator: MockMedicineScanSimulator = .demo,
        capabilities: CapabilityCatalog? = nil,
        medicineRecognitionPreferences: MedicineRecognitionPreferences =
            .init(),
        medicineRecognitionServerConfiguration:
            MedicineRecognitionServerConfiguration = .init()
    ) {
        let requester = LocalMedicineAssessmentRequester.demo(clock: clock)
        let effectiveCapabilities = capabilities
            ?? .medicineRecognitionMainline(
                onlineRecognitionConfigured:
                    medicineRecognitionServerConfiguration.baseURL != nil
            )
        self.init(
            clock: clock,
            plan: plan,
            simulator: simulator,
            readDelay: ContinuousMedicineReadDelay(),
            capabilities: effectiveCapabilities,
            medicineRecognizer: AppleVisionMedicineTextRecognizer(),
            medicineRequester: requester,
            medicineConfirmer: requester,
            userHealthProfile:
                BundledDemoUserProfile.profile.healthProfile,
            medicationRecords: [],
            medicineRecognitionPreferences:
                medicineRecognitionPreferences,
            medicineRecognitionServerConfiguration:
                medicineRecognitionServerConfiguration
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
        medicationRecords: [MedicationRecord],
        medicineRecognitionPreferences: MedicineRecognitionPreferences =
            .init(),
        medicineRecognitionServerConfiguration:
            MedicineRecognitionServerConfiguration = .unavailable,
        onlineMedicineRecognitionRequester:
            (any OnlineMedicineRecognitionRequesting)? = nil,
        recognitionRouter: (any MedicineRecognitionRouting)? = nil
    ) {
        self.clock = clock
        self.plan = plan
        self.capabilities = capabilities
        self.medicineRecognitionPreferences =
            medicineRecognitionPreferences
        self.medicineRecognitionServerConfiguration =
            medicineRecognitionServerConfiguration
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
        let mapper = MedicineRecognitionInputMapper(
            configuration: mappingConfiguration
        )
        let runner: MedicineAssessmentRunner
        if let recognitionRouter {
            runner = MedicineAssessmentRunner(
                session: companion,
                recognitionRouter: recognitionRouter,
                requester: medicineRequester,
                confirmer: medicineConfirmer,
                clock: clock
            )
        } else if let baseURL =
            medicineRecognitionServerConfiguration.baseURL
        {
            let onlineRequester = onlineMedicineRecognitionRequester
                ?? URLSessionOnlineMedicineRecognitionRequester(
                    baseURL: baseURL
                )
            runner = MedicineAssessmentRunner(
                session: companion,
                recognitionRouter: RemoteFirstMedicineRecognitionRouter(
                    remoteRequester: onlineRequester,
                    localRecognizer: medicineRecognizer,
                    localMapper: mapper
                ),
                requester: medicineRequester,
                confirmer: medicineConfirmer,
                clock: clock
            )
        } else {
            runner = MedicineAssessmentRunner(
                session: companion,
                recognizer: medicineRecognizer,
                mapper: mapper,
                requester: medicineRequester,
                confirmer: medicineConfirmer,
                clock: clock
            )
        }
        medicineAssessmentRunner = runner
        let remoteRoutingAvailable = recognitionRouter != nil
            || medicineRecognitionServerConfiguration.baseURL != nil
        medicineCaptureSubmitter = MedicineAssessmentCaptureSubmitter(
            runner: runner,
            userHealthProfileProvider: { userHealthProfile },
            medicationRecordsProvider: { medicationRecords },
            recognitionModeProvider: {
                guard remoteRoutingAvailable else {
                    return .onDeviceOnly
                }
                return medicineRecognitionPreferences.mode
            }
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
}
