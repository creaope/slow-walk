import Hummingbird
import Logging
import SlowWalkAPIContracts
import SlowWalkDataInterfaces
import SlowWalkLocationRisk
import SlowWalkMedicineKnowledge
import SlowWalkMedicinePipeline
import SlowWalkRiskEngine

public func makeSlowWalkApplication(
    configuration: SlowWalkServerConfiguration = .init(),
    riskEngine: any RiskAssessing = MedicationRiskEngine(),
    dateProvider: any DateProviding = SystemDateProvider(),
    uuidProvider: any UUIDProviding = SystemUUIDProvider(),
    medicineCatalogLoader: any MedicineCatalogLoading =
        BundledDemoMedicineCatalogLoader(),
    medicineCache: any MedicineCache = InMemoryMedicineCache(),
    medicineKnowledgeSearcher:
        (any MedicineKnowledgeSearching)? = nil,
    locationRiskAssessor:
        (any LocationRiskAssessing)? = nil,
    locationRiskConfiguration:
        LocationRiskConfiguration = .demo
) throws -> some ApplicationProtocol {
    let evidenceExtractor: any MedicinePackageEvidenceExtracting
    do {
        evidenceExtractor = try ZhipuVisionClient()
    } catch ZhipuVisionClientError.missingCredential {
        // Recognition remains available as an explicit provider-unavailable
        // response when runtime credentials are intentionally absent.
        evidenceExtractor = UnavailableMedicinePackageEvidenceExtractor()
    }
    return try makeSlowWalkApplication(
        configuration: configuration,
        riskEngine: riskEngine,
        dateProvider: dateProvider,
        uuidProvider: uuidProvider,
        medicineCatalogLoader: medicineCatalogLoader,
        medicineCache: medicineCache,
        medicineKnowledgeSearcher: medicineKnowledgeSearcher,
        locationRiskAssessor: locationRiskAssessor,
        locationRiskConfiguration: locationRiskConfiguration,
        medicinePackageEvidenceExtractor: evidenceExtractor
    )
}

func makeSlowWalkApplication(
    configuration: SlowWalkServerConfiguration = .init(),
    riskEngine: any RiskAssessing = MedicationRiskEngine(),
    dateProvider: any DateProviding = SystemDateProvider(),
    uuidProvider: any UUIDProviding = SystemUUIDProvider(),
    medicineCatalogLoader: any MedicineCatalogLoading =
        BundledDemoMedicineCatalogLoader(),
    medicineCache: any MedicineCache = InMemoryMedicineCache(),
    medicineKnowledgeSearcher:
        (any MedicineKnowledgeSearching)? = nil,
    locationRiskAssessor:
        (any LocationRiskAssessing)? = nil,
    locationRiskConfiguration:
        LocationRiskConfiguration = .demo,
    medicinePackageEvidenceExtractor:
        any MedicinePackageEvidenceExtracting,
    medicineRecognitionTimeout:
        Duration = RemoteMedicineRecognitionService.defaultTimeout,
    logger: Logger? = nil
) throws -> some ApplicationProtocol {
    // Validate the bundled catalog at composition time. A missing or unsafe
    // resource prevents startup instead of silently serving an empty catalog.
    let medicineCatalog =
        try medicineCatalogLoader.loadCatalog()
    let configuredKnowledgeSearcher:
        any MedicineKnowledgeSearching
    if let medicineKnowledgeSearcher {
        configuredKnowledgeSearcher =
            medicineKnowledgeSearcher
    } else {
        let transport = DemoMockHTTPTransport(
            medicines: medicineCatalog.medicines,
            fetchedAt: dateProvider.now()
        )
        let sources: [any MedicineKnowledgeSource] = [
            try MockAuthoritativeMedicineSource(
                transport: transport,
                clock: dateProvider
            ),
            try MockSecondaryMedicineSource(
                transport: transport,
                clock: dateProvider
            ),
        ]
        configuredKnowledgeSearcher =
            try MedicineKnowledgeService(
                sources: sources,
                policy: .demo,
                clock: dateProvider
            )
    }

    let router = Router(context: SlowWalkRequestContext.self)
    router.middlewares.add(
        PathOnlyRequestLoggingMiddleware<SlowWalkRequestContext>(.info)
    )

    router.get("/health") { _, _ in
        HealthResponseDTO()
    }

    let medicinePipeline = MedicinePipeline(
        catalogLoader: medicineCatalogLoader,
        cache: medicineCache,
        dateProvider: dateProvider,
        uuidProvider: uuidProvider,
        riskAssessor: riskEngine,
        knowledgeSearcher:
            configuredKnowledgeSearcher
    )
    let medicineController = MedicinePipelineController(
        pipeline: medicinePipeline,
        uuidProvider: uuidProvider,
        knowledgeSearcher:
            configuredKnowledgeSearcher
    )
    router.post(
        RouterPath(SlowWalkAPI.Endpoint.medicineSearch.path)
    ) {
        request,
        context in
        try await medicineController.search(
            request: request,
            context: context
        )
    }
    router.post(
        RouterPath(SlowWalkAPI.Endpoint.medicineResolve.path)
    ) {
        request,
        context in
        try await medicineController.resolve(
            request: request,
            context: context
        )
    }
    router.post(
        RouterPath(SlowWalkAPI.Endpoint.medicineAssess.path)
    ) {
        request,
        context in
        try await medicineController.assess(
            request: request,
            context: context
        )
    }

    let medicineRecognitionService = RemoteMedicineRecognitionService(
        extractor: medicinePackageEvidenceExtractor,
        resolver: try RemoteMedicineCandidateResolver(
            catalog: medicineCatalog
        ),
        timeout: medicineRecognitionTimeout
    )
    let medicineRecognitionController =
        RemoteMedicineRecognitionController(
            service: medicineRecognitionService,
            dateProvider: dateProvider,
            uuidProvider: uuidProvider
        )
    router.post(
        RouterPath(SlowWalkAPI.Endpoint.medicineRecognize.path)
    ) {
        request,
        context in
        try await medicineRecognitionController.handle(
            request: request,
            context: context
        )
    }

    let configuredLocationRiskAssessor:
        any LocationRiskAssessing =
        locationRiskAssessor
        ?? LocationRiskEngine(
            clock: dateProvider,
            configuration: locationRiskConfiguration
        )
    let locationController = LocationAssessmentController(
        assessor: configuredLocationRiskAssessor,
        validator: LocationAssessmentRequestValidator(
            configuration: locationRiskConfiguration
        ),
        dateProvider: dateProvider,
        uuidProvider: uuidProvider
    )
    router.post(
        RouterPath(SlowWalkAPI.Endpoint.locationAssess.path)
    ) {
        request,
        context in
        try await locationController.handle(
            request: request,
            context: context
        )
    }

    return Application(
        router: router,
        configuration: .init(
            address: .hostname(configuration.host, port: configuration.port),
            serverName: configuration.serverName
        ),
        logger: logger
    )
}

public func runSlowWalkServer() async throws {
    try await runSlowWalkServer(
        configuration: SlowWalkServerConfiguration.load()
    )
}

public func runSlowWalkServer(
    configuration: SlowWalkServerConfiguration
) async throws {
    let application = try makeSlowWalkApplication(
        configuration: configuration
    )
    try await application.runService()
}
