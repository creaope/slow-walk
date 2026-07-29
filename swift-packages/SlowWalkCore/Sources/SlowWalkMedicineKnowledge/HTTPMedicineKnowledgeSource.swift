import Foundation
import SlowWalkDomain

@available(macOS 14.0, iOS 17.0, *)
public struct HTTPMedicineKnowledgeSourceConfiguration:
    Sendable,
    Equatable
{
    public let identifier: String
    public let displayName: String
    public let priority: Int
    public let isAuthoritative: Bool
    public let supportedDataVersion: String
    public let baseURL: URL
    public let searchPath: String
    public let medicinePath: String
    public let documentTitle: String
    public let referenceURL: URL?
    public let requestTimeout: TimeInterval
    public let maximumResponseBytes: Int
    public let retryPolicy: HTTPRetryPolicy

    public init(
        identifier: String,
        displayName: String,
        priority: Int,
        isAuthoritative: Bool,
        supportedDataVersion: String,
        baseURL: URL,
        searchPath: String = "search",
        medicinePath: String = "medicines",
        documentTitle: String,
        referenceURL: URL? = nil,
        requestTimeout: TimeInterval = 5,
        maximumResponseBytes: Int = 512 * 1_024,
        retryPolicy: HTTPRetryPolicy = .standard
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.priority = priority
        self.isAuthoritative = isAuthoritative
        self.supportedDataVersion = supportedDataVersion
        self.baseURL = baseURL
        self.searchPath = searchPath
        self.medicinePath = medicinePath
        self.documentTitle = documentTitle
        self.referenceURL = referenceURL
        self.requestTimeout = requestTimeout
        self.maximumResponseBytes = maximumResponseBytes
        self.retryPolicy = retryPolicy
    }
}

@available(macOS 14.0, iOS 17.0, *)
public struct HTTPMedicineKnowledgeSource:
    MedicineKnowledgeSource,
    Sendable
{
    public var identifier: String {
        configuration.identifier
    }

    public var displayName: String {
        configuration.displayName
    }

    public var priority: Int {
        configuration.priority
    }

    public var isAuthoritative: Bool {
        configuration.isAuthoritative
    }

    public var supportedDataVersion: String {
        configuration.supportedDataVersion
    }

    private let configuration:
        HTTPMedicineKnowledgeSourceConfiguration
    private let transport: any HTTPTransporting
    private let clock: any Clock

    public init(
        configuration: HTTPMedicineKnowledgeSourceConfiguration,
        transport: any HTTPTransporting,
        clock: any Clock
    ) throws {
        guard configuration.baseURL.scheme?.lowercased() == "https",
            configuration.baseURL.host != nil,
            configuration.requestTimeout.isFinite,
            configuration.requestTimeout > 0,
            configuration.maximumResponseBytes > 0
        else {
            throw MedicineKnowledgeError.invalidSourceResponse(
                sourceIdentifier: configuration.identifier
            )
        }
        self.configuration = configuration
        self.transport = transport
        self.clock = clock
    }

    public func search(
        query: MedicineKnowledgeSourceQuery
    ) async throws -> MedicineKnowledgeSourceResponse {
        let normalizedQuery = query.normalizedQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            throw MedicineKnowledgeError.malformedRequest
        }

        var components = URLComponents(
            url: configuration.baseURL
                .appendingPathComponent(configuration.searchPath),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "query", value: normalizedQuery),
        ]
        guard let url = components?.url else {
            throw MedicineKnowledgeError.invalidSourceResponse(
                sourceIdentifier: identifier
            )
        }
        let response = try await send(
            url: url,
            validationMetadata: query.validationMetadata
        )
        return try decode(
            response,
            fallbackMetadata: query.validationMetadata
        )
    }

    public func fetchMedicine(
        identifier: String
    ) async throws -> MedicineKnowledgeSourceResponse {
        let value = identifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !value.isEmpty else {
            throw MedicineKnowledgeError.malformedRequest
        }
        let url = configuration.baseURL
            .appendingPathComponent(configuration.medicinePath)
            .appendingPathComponent(value)
        let response = try await send(
            url: url,
            validationMetadata: nil
        )
        return try decode(response, fallbackMetadata: nil)
    }

    private func send(
        url: URL,
        validationMetadata: MedicineSourceValidationMetadata?
    ) async throws -> HTTPTransportResponse {
        var headers = ["Accept": "application/json"]
        if let etag = validationMetadata?.etag {
            headers["If-None-Match"] = etag
        }
        if let lastModified = validationMetadata?.lastModified {
            headers["If-Modified-Since"] = lastModified
        }
        let request = HTTPTransportRequest(
            url: url,
            headers: headers,
            timeout: configuration.requestTimeout
        )

        var attempt = 0
        while attempt < configuration.retryPolicy.maximumAttempts {
            attempt += 1
            do {
                try Task.checkCancellation()
                let response = try await transport.send(request)
                if configuration.retryPolicy.retryableStatusCodes
                    .contains(response.statusCode),
                    attempt < configuration.retryPolicy.maximumAttempts
                {
                    continue
                }
                return response
            } catch is CancellationError {
                throw MedicineKnowledgeError.requestCancelled
            } catch let error as HTTPTransportError {
                switch error {
                case .cancelled:
                    throw MedicineKnowledgeError.requestCancelled
                case .timeout:
                    if attempt
                        < configuration.retryPolicy.maximumAttempts
                    {
                        continue
                    }
                    throw MedicineKnowledgeError
                        .knowledgeSourceTimeout(
                            sourceIdentifier: identifier
                        )
                case .invalidResponse:
                    throw MedicineKnowledgeError
                        .invalidSourceResponse(
                            sourceIdentifier: identifier
                        )
                case .networkFailure:
                    if attempt
                        < configuration.retryPolicy.maximumAttempts
                    {
                        continue
                    }
                    throw MedicineKnowledgeError
                        .knowledgeSourceUnavailable(
                            sourceIdentifier: identifier
                        )
                }
            } catch let error as MedicineKnowledgeError {
                throw error
            } catch {
                if attempt
                    < configuration.retryPolicy.maximumAttempts
                {
                    continue
                }
                throw MedicineKnowledgeError
                    .knowledgeSourceUnavailable(
                        sourceIdentifier: identifier
                    )
            }
        }
        throw MedicineKnowledgeError.knowledgeSourceUnavailable(
            sourceIdentifier: identifier
        )
    }

    private func decode(
        _ response: HTTPTransportResponse,
        fallbackMetadata: MedicineSourceValidationMetadata?
    ) throws -> MedicineKnowledgeSourceResponse {
        if response.statusCode == 304 {
            return MedicineKnowledgeSourceResponse(
                sourceIdentifier: identifier,
                records: [],
                sourceReference: makeSourceReference(
                    retrievedAt: clock.now()
                ),
                sourceDocumentVersion:
                    fallbackMetadata?.dataVersion
                    ?? supportedDataVersion,
                fetchedAt: clock.now(),
                completeness: 1,
                validationStatus: .notModified,
                validationMetadata: makeValidationMetadata(
                    response,
                    fallback: fallbackMetadata
                )
            )
        }
        if response.statusCode == 404 {
            throw MedicineKnowledgeError.medicineNotFound
        }
        if response.statusCode == 408
            || response.statusCode == 504
        {
            throw MedicineKnowledgeError.knowledgeSourceTimeout(
                sourceIdentifier: identifier
            )
        }
        guard (200 ... 299).contains(response.statusCode) else {
            throw MedicineKnowledgeError
                .knowledgeSourceUnavailable(
                    sourceIdentifier: identifier
                )
        }
        guard let contentType = response.header("Content-Type") else {
            throw MedicineKnowledgeError.invalidSourceResponse(
                sourceIdentifier: identifier
            )
        }
        let mediaType = String(
            contentType.split(
                separator: ";",
                maxSplits: 1
            ).first ?? ""
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        guard mediaType == "application/json" else {
            throw MedicineKnowledgeError.invalidSourceResponse(
                sourceIdentifier: identifier
            )
        }
        guard !response.body.isEmpty,
            response.body.count
                <= configuration.maximumResponseBytes
        else {
            throw MedicineKnowledgeError.invalidSourceResponse(
                sourceIdentifier: identifier
            )
        }

        let payload: MedicineKnowledgeHTTPPayload
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            payload = try decoder.decode(
                MedicineKnowledgeHTTPPayload.self,
                from: response.body
            )
        } catch {
            throw MedicineKnowledgeError.invalidSourceResponse(
                sourceIdentifier: identifier
            )
        }

        return MedicineKnowledgeSourceResponse(
            sourceIdentifier: payload.sourceIdentifier,
            records: payload.records,
            sourceReference: payload.sourceReference,
            sourceDocumentVersion:
                payload.sourceDocumentVersion,
            fetchedAt: payload.fetchedAt,
            completeness: payload.completeness,
            validationStatus: payload.validationStatus,
            validationMetadata: makeValidationMetadata(
                response,
                fallback: MedicineSourceValidationMetadata(
                    dataVersion:
                        payload.sourceDocumentVersion
                )
            )
        )
    }

    private func makeValidationMetadata(
        _ response: HTTPTransportResponse,
        fallback: MedicineSourceValidationMetadata?
    ) -> MedicineSourceValidationMetadata {
        MedicineSourceValidationMetadata(
            etag: response.header("ETag") ?? fallback?.etag,
            lastModified:
                response.header("Last-Modified")
                ?? fallback?.lastModified,
            dataVersion:
                response.header("X-Source-Data-Version")
                ?? fallback?.dataVersion
                ?? supportedDataVersion
        )
    }

    private func makeSourceReference(
        retrievedAt: Date
    ) -> SourceReference {
        SourceReference(
            sourceName: displayName,
            documentTitle: configuration.documentTitle,
            optionalURL: configuration.referenceURL,
            retrievedAt: retrievedAt,
            versionOrDate: supportedDataVersion
        )
    }
}

@available(macOS 14.0, iOS 17.0, *)
public struct MedicineKnowledgeHTTPPayload:
    Codable,
    Sendable,
    Equatable,
    Hashable
{
    public let sourceIdentifier: String
    public let sourceReference: SourceReference
    public let sourceDocumentVersion: String
    public let fetchedAt: Date
    public let completeness: Double
    public let validationStatus: MedicineKnowledgeValidationStatus
    public let records: [MedicineKnowledgeRecord]

    public init(
        sourceIdentifier: String,
        sourceReference: SourceReference,
        sourceDocumentVersion: String,
        fetchedAt: Date,
        completeness: Double,
        validationStatus: MedicineKnowledgeValidationStatus,
        records: [MedicineKnowledgeRecord]
    ) {
        self.sourceIdentifier = sourceIdentifier
        self.sourceReference = sourceReference
        self.sourceDocumentVersion = sourceDocumentVersion
        self.fetchedAt = fetchedAt
        self.completeness = completeness
        self.validationStatus = validationStatus
        self.records = records
    }
}
