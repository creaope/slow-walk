import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The OpenAI-compatible response envelope. Only the first choice's content
/// is consumed by ``ZhipuVisionClient``.
struct VisionChatCompletionResponse: Decodable, Sendable {
    struct Choice: Decodable, Sendable {
        struct Message: Decodable, Sendable {
            let content: String?
        }

        let message: Message
    }

    let choices: [Choice]
}

/// Strict, non-clinical output accepted from the model's JSON content.
struct VisionVisibleTextResult: Decodable, Sendable, Equatable {
    static let maximumVisibleTextCount = 64
    static let maximumVisibleTextLength = 256
    static let maximumTotalVisibleTextLength = 2_048

    let visibleTexts: [String]
    let imageReadable: Bool
    let uncertainRegionsPresent: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case visibleTexts
        case imageReadable
        case uncertainRegionsPresent
    }

    init(from decoder: any Decoder) throws {
        let rawContainer = try decoder.container(keyedBy: ArbitraryCodingKey.self)
        let actualKeys = Set(rawContainer.allKeys.map(\.stringValue))
        let expectedKeys = Set(CodingKeys.allCases.map(\.rawValue))
        guard actualKeys == expectedKeys else {
            throw Self.validationError(
                decoder, "Unexpected model payload fields."
            )
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let visibleTexts = try container.decode([String].self, forKey: .visibleTexts)
        guard visibleTexts.count <= Self.maximumVisibleTextCount else {
            throw Self.validationError(decoder, "Too many visible text entries.")
        }

        var totalLength = 0
        for text in visibleTexts {
            let length = text.count
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                length <= Self.maximumVisibleTextLength,
                totalLength <= Self.maximumTotalVisibleTextLength - length
            else {
                throw Self.validationError(decoder, "Visible text limits were exceeded.")
            }
            totalLength += length
        }

        self.visibleTexts = visibleTexts
        imageReadable = try container.decode(Bool.self, forKey: .imageReadable)
        uncertainRegionsPresent = try container.decode(
            Bool.self, forKey: .uncertainRegionsPresent
        )
    }

    private static func validationError(
        _ decoder: any Decoder,
        _ description: String
    ) -> DecodingError {
        .dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: description
        ))
    }
}

/// Strict visual evidence and catalog-search clues extracted from medicine
/// packaging. Nothing in this contract can carry canonical identity or a
/// clinical conclusion.
struct RemoteMedicinePackageEvidence: Codable, Sendable, Equatable {
    static let maximumVisibleTextCount = 64
    static let maximumNamedEvidenceCount = 16
    static let maximumPackagingFeatureCount = 24
    static let maximumSearchQueryCount = 8
    static let maximumVisibleTextLength = 256
    static let maximumEvidenceTextLength = 160
    static let maximumPackagingFeatureLength = 256
    static let maximumSearchQueryLength = 96
    static let maximumTotalSearchQueryCharacterCount = 384
    static let maximumTotalCharacterCount = 4_096

    let visibleTexts: [String]
    let probableProductNames: [String]
    let probableGenericNames: [String]
    let manufacturerNames: [String]
    let approvalIdentifiers: [String]
    let dosageFormTexts: [String]
    let packagingFeatures: [String]
    let searchQueries: [String]
    let imageReadable: Bool
    let uncertainRegionsPresent: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case visibleTexts
        case probableProductNames
        case probableGenericNames
        case manufacturerNames
        case approvalIdentifiers
        case dosageFormTexts
        case packagingFeatures
        case searchQueries
        case imageReadable
        case uncertainRegionsPresent
    }

    init(
        visibleTexts: [String],
        probableProductNames: [String],
        probableGenericNames: [String],
        manufacturerNames: [String],
        approvalIdentifiers: [String],
        dosageFormTexts: [String],
        packagingFeatures: [String],
        searchQueries: [String],
        imageReadable: Bool,
        uncertainRegionsPresent: Bool
    ) throws {
        try Self.validate(
            visibleTexts: visibleTexts,
            probableProductNames: probableProductNames,
            probableGenericNames: probableGenericNames,
            manufacturerNames: manufacturerNames,
            approvalIdentifiers: approvalIdentifiers,
            dosageFormTexts: dosageFormTexts,
            packagingFeatures: packagingFeatures,
            searchQueries: searchQueries
        )
        self.visibleTexts = visibleTexts
        self.probableProductNames = probableProductNames
        self.probableGenericNames = probableGenericNames
        self.manufacturerNames = manufacturerNames
        self.approvalIdentifiers = approvalIdentifiers
        self.dosageFormTexts = dosageFormTexts
        self.packagingFeatures = packagingFeatures
        self.searchQueries = searchQueries
        self.imageReadable = imageReadable
        self.uncertainRegionsPresent = uncertainRegionsPresent
    }

    init(from decoder: any Decoder) throws {
        let rawContainer = try decoder.container(keyedBy: ArbitraryCodingKey.self)
        let actualKeys = Set(rawContainer.allKeys.map(\.stringValue))
        let expectedKeys = Set(CodingKeys.allCases.map(\.rawValue))
        guard actualKeys == expectedKeys else {
            throw Self.decodingError(decoder, "Unexpected model payload fields.")
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                visibleTexts: container.decode([String].self, forKey: .visibleTexts),
                probableProductNames: container.decode(
                    [String].self, forKey: .probableProductNames
                ),
                probableGenericNames: container.decode(
                    [String].self, forKey: .probableGenericNames
                ),
                manufacturerNames: container.decode(
                    [String].self, forKey: .manufacturerNames
                ),
                approvalIdentifiers: container.decode(
                    [String].self, forKey: .approvalIdentifiers
                ),
                dosageFormTexts: container.decode(
                    [String].self, forKey: .dosageFormTexts
                ),
                packagingFeatures: container.decode(
                    [String].self, forKey: .packagingFeatures
                ),
                searchQueries: container.decode(
                    [String].self, forKey: .searchQueries
                ),
                imageReadable: container.decode(Bool.self, forKey: .imageReadable),
                uncertainRegionsPresent: container.decode(
                    Bool.self, forKey: .uncertainRegionsPresent
                )
            )
        } catch is ValidationFailure {
            throw Self.decodingError(decoder, "Model payload limits were exceeded.")
        }
    }

    private struct TextCollection {
        let values: [String]
        let maximumCount: Int
        let maximumLength: Int
    }

    private enum ValidationFailure: Error { case invalidTextCollection }

    private static func validate(
        visibleTexts: [String],
        probableProductNames: [String],
        probableGenericNames: [String],
        manufacturerNames: [String],
        approvalIdentifiers: [String],
        dosageFormTexts: [String],
        packagingFeatures: [String],
        searchQueries: [String]
    ) throws {
        let totalSearchQueryCharacterCount = searchQueries.reduce(0) {
            $0 + $1.count
        }
        guard totalSearchQueryCharacterCount
                <= maximumTotalSearchQueryCharacterCount
        else {
            throw ValidationFailure.invalidTextCollection
        }

        let collections = [
            TextCollection(
                values: visibleTexts,
                maximumCount: maximumVisibleTextCount,
                maximumLength: maximumVisibleTextLength
            ),
            TextCollection(
                values: probableProductNames,
                maximumCount: maximumNamedEvidenceCount,
                maximumLength: maximumEvidenceTextLength
            ),
            TextCollection(
                values: probableGenericNames,
                maximumCount: maximumNamedEvidenceCount,
                maximumLength: maximumEvidenceTextLength
            ),
            TextCollection(
                values: manufacturerNames,
                maximumCount: maximumNamedEvidenceCount,
                maximumLength: maximumEvidenceTextLength
            ),
            TextCollection(
                values: approvalIdentifiers,
                maximumCount: maximumNamedEvidenceCount,
                maximumLength: maximumEvidenceTextLength
            ),
            TextCollection(
                values: dosageFormTexts,
                maximumCount: maximumNamedEvidenceCount,
                maximumLength: maximumEvidenceTextLength
            ),
            TextCollection(
                values: packagingFeatures,
                maximumCount: maximumPackagingFeatureCount,
                maximumLength: maximumPackagingFeatureLength
            ),
            TextCollection(
                values: searchQueries,
                maximumCount: maximumSearchQueryCount,
                maximumLength: maximumSearchQueryLength
            ),
        ]

        var totalCharacterCount = 0
        for collection in collections {
            guard collection.values.count <= collection.maximumCount else {
                throw ValidationFailure.invalidTextCollection
            }
            for value in collection.values {
                let length = value.count
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      length <= collection.maximumLength,
                      totalCharacterCount <= maximumTotalCharacterCount - length
                else {
                    throw ValidationFailure.invalidTextCollection
                }
                totalCharacterCount += length
            }
        }
    }

    private static func decodingError(
        _ decoder: any Decoder,
        _ description: String
    ) -> DecodingError {
        .dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: description
        ))
    }
}

private struct ArbitraryCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// Stable error categories that never retain provider bodies or request data.
enum ZhipuVisionClientError:
    Error,
    Sendable,
    Equatable,
    LocalizedError,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    case missingCredential
    case invalidRequest(providerIdentifier: String, statusCode: Int?)
    case unauthorized(providerIdentifier: String, statusCode: Int)
    case rateLimited(providerIdentifier: String, statusCode: Int)
    case serverFailure(providerIdentifier: String, statusCode: Int)
    case timeout(providerIdentifier: String)
    case transportFailure(providerIdentifier: String)
    case malformedProviderResponse(providerIdentifier: String)
    case invalidModelPayload(providerIdentifier: String)

    var errorDescription: String? { description }

    var description: String {
        var message = "Zhipu vision request failed: \(category)"
        if let providerIdentifier {
            message += " (provider: \(providerIdentifier)"
            if let statusCode {
                message += ", HTTP status: \(statusCode)"
            }
            message += ")"
        }
        return message + "."
    }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "category": category,
                "providerIdentifier": providerIdentifier ?? "none",
                "statusCode": statusCode.map { String($0) } ?? "none",
            ],
            displayStyle: .enum
        )
    }

    private var category: String {
        switch self {
        case .missingCredential: "missingCredential"
        case .invalidRequest: "invalidRequest"
        case .unauthorized: "unauthorized"
        case .rateLimited: "rateLimited"
        case .serverFailure: "serverFailure"
        case .timeout: "timeout"
        case .transportFailure: "transportFailure"
        case .malformedProviderResponse: "malformedProviderResponse"
        case .invalidModelPayload: "invalidModelPayload"
        }
    }

    private var providerIdentifier: String? {
        switch self {
        case .missingCredential:
            nil
        case .invalidRequest(let provider, _),
             .unauthorized(let provider, _),
             .rateLimited(let provider, _),
             .serverFailure(let provider, _),
             .timeout(let provider),
             .transportFailure(let provider),
             .malformedProviderResponse(let provider),
             .invalidModelPayload(let provider):
            provider
        }
    }

    private var statusCode: Int? {
        switch self {
        case .invalidRequest(_, let statusCode): statusCode
        case .unauthorized(_, let statusCode),
             .rateLimited(_, let statusCode),
             .serverFailure(_, let statusCode): statusCode
        default: nil
        }
    }
}

/// Builds, sends, retries, and strictly parses Zhipu vision requests.
struct ZhipuVisionClient:
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    typealias RetryDelay = @Sendable (_ retryNumber: Int) async throws -> Void

    private static let maximumProviderResponseBytes = 1_048_576
    private static let maximumModelContentBytes = 32_768

    private let runtimeConfiguration: ZhipuVisionRuntimeConfiguration
    private let transport: any VisionHTTPTransport
    private let retryDelay: RetryDelay

    init(
        runtimeConfiguration: ZhipuVisionRuntimeConfiguration,
        transport: any VisionHTTPTransport,
        retryDelay: @escaping RetryDelay = ZhipuVisionClient.defaultRetryDelay
    ) {
        self.runtimeConfiguration = runtimeConfiguration
        self.transport = transport
        self.retryDelay = retryDelay
    }

    /// Loads the existing environment/Keychain configuration boundary.
    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any VisionHTTPTransport = URLSessionVisionHTTPTransport()
    ) throws {
        let runtimeConfiguration: ZhipuVisionRuntimeConfiguration
        do {
            runtimeConfiguration = try .load(environment: environment)
        } catch ZhipuVisionRuntimeConfigurationError.apiKeyMissing,
                ZhipuVisionRuntimeConfigurationError.apiKeyEmpty {
            throw ZhipuVisionClientError.missingCredential
        } catch {
            throw ZhipuVisionClientError.invalidRequest(
                providerIdentifier: ZhipuVisionRuntimeConfiguration.providerIdentifier,
                statusCode: nil
            )
        }
        self.init(
            runtimeConfiguration: runtimeConfiguration,
            transport: transport
        )
    }

    func extractVisibleTexts(
        from image: VisionImagePayload
    ) async throws -> VisionVisibleTextResult {
        let configuration = runtimeConfiguration.primary
        let response = try await execute(
            image: image,
            instruction: VisionChatCompletionRequestBody.instruction
        )
        return try parse(
            response,
            as: VisionVisibleTextResult.self,
            providerIdentifier: configuration.providerIdentifier
        )
    }

    func extractMedicinePackageEvidence(
        from image: VisionImagePayload
    ) async throws -> RemoteMedicinePackageEvidence {
        let configuration = runtimeConfiguration.primary
        let response = try await execute(
            image: image,
            instruction: VisionChatCompletionRequestBody
                .medicinePackageEvidenceInstruction
        )
        return try parse(
            response,
            as: RemoteMedicinePackageEvidence.self,
            providerIdentifier: configuration.providerIdentifier
        )
    }

    private func execute(
        image: VisionImagePayload,
        instruction: String
    ) async throws -> VisionHTTPResponse {
        let configuration = runtimeConfiguration.primary
        let provider = configuration.providerIdentifier
        let request: VisionTransportRequest
        do {
            request = try .chatCompletion(
                configuration: configuration,
                image: image,
                credential: runtimeConfiguration.credential,
                instruction: instruction
            )
        } catch {
            throw ZhipuVisionClientError.invalidRequest(
                providerIdentifier: provider,
                statusCode: nil
            )
        }

        for attempt in 1 ... configuration.maxAttempts {
            try Task.checkCancellation()

            let response: VisionHTTPResponse
            do {
                response = try await transport.send(request)
                try Task.checkCancellation()
            } catch let cancellation as CancellationError {
                throw cancellation
            } catch let urlError as URLError where urlError.code == .cancelled {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                let (mappedError, retryable) = mapTransportError(
                    error, providerIdentifier: provider
                )
                guard retryable, attempt < configuration.maxAttempts else {
                    throw mappedError
                }
                try await retryDelay(attempt)
                try Task.checkCancellation()
                continue
            }

            guard (200 ..< 300).contains(response.statusCode) else {
                let mappedError = mapHTTPError(
                    statusCode: response.statusCode, providerIdentifier: provider
                )
                guard Self.isRetryable(statusCode: response.statusCode),
                      attempt < configuration.maxAttempts
                else {
                    throw mappedError
                }
                try await retryDelay(attempt)
                try Task.checkCancellation()
                continue
            }
            return response
        }

        throw ZhipuVisionClientError.transportFailure(
            providerIdentifier: provider
        )
    }

    var description: String {
        "ZhipuVisionClient(providerIdentifier: "
            + "\(runtimeConfiguration.primary.providerIdentifier), model: "
            + "\(runtimeConfiguration.primary.model))"
    }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "providerIdentifier":
                    runtimeConfiguration.primary.providerIdentifier,
                "model": runtimeConfiguration.primary.model,
            ],
            displayStyle: .struct
        )
    }

    private func parse<Payload: Decodable>(
        _ response: VisionHTTPResponse,
        as type: Payload.Type,
        providerIdentifier: String
    ) throws -> Payload {
        let malformedResponse = ZhipuVisionClientError
            .malformedProviderResponse(providerIdentifier: providerIdentifier)
        guard response.body.count <= Self.maximumProviderResponseBytes else {
            throw malformedResponse
        }
        let completion: VisionChatCompletionResponse
        do {
            completion = try JSONDecoder().decode(
                VisionChatCompletionResponse.self, from: response.body
            )
        } catch {
            throw malformedResponse
        }
        guard let content = completion.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw malformedResponse
        }

        let contentData = Data(content.utf8)
        let invalidPayload = ZhipuVisionClientError
            .invalidModelPayload(providerIdentifier: providerIdentifier)
        guard contentData.count <= Self.maximumModelContentBytes else {
            throw invalidPayload
        }
        do {
            return try JSONDecoder().decode(
                type, from: contentData
            )
        } catch {
            throw invalidPayload
        }
    }

    private func mapHTTPError(
        statusCode: Int,
        providerIdentifier: String
    ) -> ZhipuVisionClientError {
        switch statusCode {
        case 401, 403:
            .unauthorized(providerIdentifier: providerIdentifier, statusCode: statusCode)
        case 429:
            .rateLimited(providerIdentifier: providerIdentifier, statusCode: statusCode)
        case 500 ... 599:
            .serverFailure(providerIdentifier: providerIdentifier, statusCode: statusCode)
        case 400 ... 499:
            .invalidRequest(providerIdentifier: providerIdentifier, statusCode: statusCode)
        default:
            .transportFailure(providerIdentifier: providerIdentifier)
        }
    }

    private func mapTransportError(
        _ error: any Error,
        providerIdentifier: String
    ) -> (ZhipuVisionClientError, retryable: Bool) {
        guard let urlError = error as? URLError else {
            return (
                .transportFailure(providerIdentifier: providerIdentifier), false
            )
        }
        if urlError.code == .timedOut {
            return (.timeout(providerIdentifier: providerIdentifier), true)
        }
        let retryableCodes: Set<URLError.Code> = [
            .cannotFindHost,
            .cannotConnectToHost,
            .dnsLookupFailed,
            .networkConnectionLost,
            .notConnectedToInternet,
            .resourceUnavailable,
        ]
        return (
            .transportFailure(providerIdentifier: providerIdentifier),
            retryableCodes.contains(urlError.code)
        )
    }

    private static func isRetryable(statusCode: Int) -> Bool {
        [500, 502, 503, 504].contains(statusCode)
    }

    static func defaultRetryDelay(_ retryNumber: Int) async throws {
        try await Task<Never, Never>.sleep(
            nanoseconds: UInt64(retryNumber) * 50_000_000
        )
    }
}
