import Foundation
import SlowWalkDomain

@available(macOS 14.0, iOS 17.0, *)
public actor MockHTTPTransport: HTTPTransporting {
    public typealias Handler = @Sendable (
        HTTPTransportRequest
    ) async throws -> HTTPTransportResponse

    private let handler: Handler
    private var recordedRequests: [HTTPTransportRequest]

    public init(handler: @escaping Handler) {
        self.handler = handler
        recordedRequests = []
    }

    public func send(
        _ request: HTTPTransportRequest
    ) async throws -> HTTPTransportResponse {
        recordedRequests.append(request)
        return try await handler(request)
    }

    public func requests() -> [HTTPTransportRequest] {
        recordedRequests
    }
}

@available(macOS 14.0, iOS 17.0, *)
public actor DemoMockHTTPTransport: HTTPTransporting {
    private let medicines: [Medicine]
    private let fetchedAt: Date

    public init(
        medicines: [Medicine],
        fetchedAt: Date
    ) {
        self.medicines = medicines
        self.fetchedAt = fetchedAt
    }

    public func send(
        _ request: HTTPTransportRequest
    ) async throws -> HTTPTransportResponse {
        try Task.checkCancellation()
        guard let host = request.url.host else {
            return HTTPTransportResponse(statusCode: 400)
        }
        let source: DemoSourceDefinition
        switch host {
        case MockAuthoritativeMedicineSource.host:
            source = .authoritative
        case MockSecondaryMedicineSource.host:
            source = .secondary
        default:
            return HTTPTransportResponse(statusCode: 403)
        }

        if request.headers["If-None-Match"] == source.etag {
            return HTTPTransportResponse(
                statusCode: 304,
                headers: source.headers
            )
        }

        let selectedMedicines: [Medicine]
        if request.url.path.contains("/search") {
            let query = URLComponents(
                url: request.url,
                resolvingAgainstBaseURL: false
            )?
            .queryItems?
            .first { $0.name == "query" }?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
            selectedMedicines = medicines.filter {
                Self.matches($0, query: query)
            }
        } else if let identifier = request.url.pathComponents.last {
            selectedMedicines = medicines.filter {
                $0.id == identifier
            }
        } else {
            selectedMedicines = []
        }

        guard !selectedMedicines.isEmpty else {
            return HTTPTransportResponse(
                statusCode: 404,
                headers: source.headers
            )
        }

        let reference = SourceReference(
            sourceName: source.displayName,
            documentTitle:
                MedicineKnowledgeSafety.demoDisclaimer,
            optionalURL: nil,
            retrievedAt: fetchedAt,
            versionOrDate: source.dataVersion
        )
        let records = selectedMedicines.map {
            MedicineKnowledgeRecord(
                canonicalMedicineIdentifier: $0.id,
                canonicalName: $0.canonicalName,
                aliases: $0.aliases,
                activeIngredientIDs:
                    $0.activeIngredientIDs,
                category: $0.medicineCategory,
                warnings: Self.stableStrings(
                    $0.warnings
                        + [
                            MedicineKnowledgeSafety
                                .demoDisclaimer,
                        ]
                ),
                contraindicationTags:
                    $0.contraindicationTags,
                dosageTextFromSource:
                    $0.dosageTextFromSource,
                sourceIdentifier: source.identifier,
                sourceReference: reference,
                sourceDocumentVersion: source.dataVersion,
                fetchedAt: fetchedAt,
                completeness: 0.95,
                validationStatus: .valid
            )
        }
        let payload = MedicineKnowledgeHTTPPayload(
            sourceIdentifier: source.identifier,
            sourceReference: reference,
            sourceDocumentVersion: source.dataVersion,
            fetchedAt: fetchedAt,
            completeness: 0.95,
            validationStatus: .valid,
            records: records
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return HTTPTransportResponse(
            statusCode: 200,
            headers: source.headers,
            body: try encoder.encode(payload)
        )
    }

    private static func matches(
        _ medicine: Medicine,
        query: String
    ) -> Bool {
        guard !query.isEmpty else {
            return false
        }
        let names = [medicine.canonicalName] + medicine.aliases
        return names.contains {
            let value = $0
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                .lowercased()
            return value == query
                || value.contains(query)
                || query.contains(value)
        }
    }

    private static func stableStrings(
        _ values: [String]
    ) -> [String] {
        Array(Set(values)).sorted()
    }
}

@available(macOS 14.0, iOS 17.0, *)
public struct MockAuthoritativeMedicineSource:
    MedicineKnowledgeSource,
    Sendable
{
    public static let identifier =
        "mock-authoritative-medicine-source"
    public static let host = "authoritative.demo.invalid"
    public static let dataVersion =
        "demo-authoritative-v1"

    public var identifier: String {
        Self.identifier
    }

    public var displayName: String {
        "Mock Authoritative Medicine Source"
    }

    public var priority: Int {
        100
    }

    public var isAuthoritative: Bool {
        true
    }

    public var supportedDataVersion: String {
        Self.dataVersion
    }

    private let source: HTTPMedicineKnowledgeSource

    public init(
        transport: any HTTPTransporting,
        clock: any Clock
    ) throws {
        source = try HTTPMedicineKnowledgeSource(
            configuration:
                HTTPMedicineKnowledgeSourceConfiguration(
                    identifier: Self.identifier,
                    displayName:
                        "Mock Authoritative Medicine Source",
                    priority: 100,
                    isAuthoritative: true,
                    supportedDataVersion: Self.dataVersion,
                    baseURL: URL(
                        string:
                            "https://\(Self.host)/api/v1/"
                    )!,
                    documentTitle:
                        MedicineKnowledgeSafety.demoDisclaimer,
                    retryPolicy: HTTPRetryPolicy(
                        maximumAttempts: 1,
                        retryableStatusCodes: []
                    )
                ),
            transport: transport,
            clock: clock
        )
    }

    public func search(
        query: MedicineKnowledgeSourceQuery
    ) async throws -> MedicineKnowledgeSourceResponse {
        try await source.search(query: query)
    }

    public func fetchMedicine(
        identifier: String
    ) async throws -> MedicineKnowledgeSourceResponse {
        try await source.fetchMedicine(identifier: identifier)
    }
}

@available(macOS 14.0, iOS 17.0, *)
public struct MockSecondaryMedicineSource:
    MedicineKnowledgeSource,
    Sendable
{
    public static let identifier =
        "mock-secondary-medicine-source"
    public static let host = "secondary.demo.invalid"
    public static let dataVersion = "demo-secondary-v1"

    public var identifier: String {
        Self.identifier
    }

    public var displayName: String {
        "Mock Secondary Medicine Source"
    }

    public var priority: Int {
        50
    }

    public var isAuthoritative: Bool {
        false
    }

    public var supportedDataVersion: String {
        Self.dataVersion
    }

    private let source: HTTPMedicineKnowledgeSource

    public init(
        transport: any HTTPTransporting,
        clock: any Clock
    ) throws {
        source = try HTTPMedicineKnowledgeSource(
            configuration:
                HTTPMedicineKnowledgeSourceConfiguration(
                    identifier: Self.identifier,
                    displayName:
                        "Mock Secondary Medicine Source",
                    priority: 50,
                    isAuthoritative: false,
                    supportedDataVersion: Self.dataVersion,
                    baseURL: URL(
                        string: "https://\(Self.host)/api/v1/"
                    )!,
                    documentTitle:
                        MedicineKnowledgeSafety.demoDisclaimer,
                    retryPolicy: HTTPRetryPolicy(
                        maximumAttempts: 1,
                        retryableStatusCodes: []
                    )
                ),
            transport: transport,
            clock: clock
        )
    }

    public func search(
        query: MedicineKnowledgeSourceQuery
    ) async throws -> MedicineKnowledgeSourceResponse {
        try await source.search(query: query)
    }

    public func fetchMedicine(
        identifier: String
    ) async throws -> MedicineKnowledgeSourceResponse {
        try await source.fetchMedicine(identifier: identifier)
    }
}

private enum DemoSourceDefinition {
    case authoritative
    case secondary

    var identifier: String {
        switch self {
        case .authoritative:
            MockAuthoritativeMedicineSource.identifier
        case .secondary:
            MockSecondaryMedicineSource.identifier
        }
    }

    var displayName: String {
        switch self {
        case .authoritative:
            "Mock Authoritative Medicine Source"
        case .secondary:
            "Mock Secondary Medicine Source"
        }
    }

    var dataVersion: String {
        switch self {
        case .authoritative:
            MockAuthoritativeMedicineSource.dataVersion
        case .secondary:
            MockSecondaryMedicineSource.dataVersion
        }
    }

    var etag: String {
        "\"\(dataVersion)\""
    }

    var headers: [String: String] {
        [
            "Content-Type": "application/json; charset=utf-8",
            "ETag": etag,
            "Last-Modified": "Thu, 24 Jul 2025 00:00:00 GMT",
            "X-Source-Data-Version": dataVersion,
        ]
    }
}
