import Foundation
import Hummingbird
import SlowWalkAPIContracts
import SlowWalkDataInterfaces
import SlowWalkDomain

/// HTTP boundary for evidence-only package recognition and canonical lookup.
/// It never receives health context and never invokes the risk pipeline.
struct RemoteMedicineRecognitionController: Sendable {
    static let maximumCandidateCount = 8
    static let maximumMatchesPerCategory = 16
    static let maximumUnresolvedObservationCount = 32

    private let service: RemoteMedicineRecognitionService
    private let validator: MedicineRecognitionAPIRequestValidator
    private let dateProvider: any DateProviding
    private let uuidProvider: any UUIDProviding

    init(
        service: RemoteMedicineRecognitionService,
        validator: MedicineRecognitionAPIRequestValidator = .init(),
        dateProvider: any DateProviding = SystemDateProvider(),
        uuidProvider: any UUIDProviding = SystemUUIDProvider()
    ) {
        self.service = service
        self.validator = validator
        self.dateProvider = dateProvider
        self.uuidProvider = uuidProvider
    }

    func handle(
        request: Request,
        context: SlowWalkRequestContext
    ) async throws -> Response {
        let fallbackRequestID = uuidProvider.makeUUID()
        guard hasJSONContentType(request) else {
            return try errorResponse(
                code: .unsupportedMediaType,
                message: "Content-Type must be application/json.",
                requestID: fallbackRequestID,
                details: nil,
                status: .badRequest,
                request: request,
                context: context
            )
        }

        let decodedRequest: MedicineRecognitionAPIRequestDTO
        do {
            if requestContentLengthExceedsLimit(request) {
                return try requestBodyTooLargeResponse(
                    requestID: fallbackRequestID,
                    request: request,
                    context: context
                )
            }
            let body = try await request.body.collect(
                upTo: MedicineRecognitionAPIRequestValidator
                    .maximumRequestBodyBytes
            )
            decodedRequest = try SlowWalkJSONCoding.makeDecoder().decode(
                MedicineRecognitionAPIRequestDTO.self,
                from: Data(body.readableBytesView)
            )
        } catch let error as any HTTPResponseError
            where error.status == .contentTooLarge {
            return try requestBodyTooLargeResponse(
                requestID: fallbackRequestID,
                request: request,
                context: context
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try errorResponse(
                code: .malformedRequest,
                message: "The medicine recognition request is not valid JSON.",
                requestID: fallbackRequestID,
                details: nil,
                status: .badRequest,
                request: request,
                context: context
            )
        }

        guard SlowWalkAPI.supports(
            bodyVersion: decodedRequest.apiVersion,
            for: .medicineRecognize
        ) else {
            return try errorResponse(
                code: .unsupportedAPIVersion,
                message: "The requested API version is not supported.",
                requestID: decodedRequest.requestID,
                details: [
                    APIErrorDetailDTO(
                        field: "apiVersion",
                        code: "unsupported",
                        message:
                            "Supported API version: \(SlowWalkAPI.version)."
                    ),
                ],
                status: .badRequest,
                request: request,
                context: context
            )
        }

        let validated: ValidatedMedicineRecognitionRequest
        do {
            validated = try validator.validate(decodedRequest)
        } catch MedicineRecognitionRequestValidationFailure.imageTooLarge {
            return try errorResponse(
                code: .imageTooLarge,
                message: "The decoded image exceeds the 4 MiB limit.",
                requestID: decodedRequest.requestID,
                details: nil,
                status: .contentTooLarge,
                request: request,
                context: context
            )
        } catch MedicineRecognitionRequestValidationFailure
            .invalidFields(let details) {
            return try errorResponse(
                code: .validationError,
                message: "One or more recognition request fields are invalid.",
                requestID: decodedRequest.requestID,
                details: details,
                status: .unprocessableContent,
                request: request,
                context: context
            )
        }

        do {
            let result = try await service.recognize(
                image: validated.image,
                capturedAt: dateProvider.now()
            )
            let output = makeRecognitionResponse(
                result,
                requestID: validated.requestID
            )
            context.logger.info(
                "medicine_recognition_completed",
                metadata: [
                    "slowwalk.api_request_id": .string(
                        validated.requestID.uuidString
                    ),
                    "slowwalk.recognition_status": .string(
                        output.status.rawValue
                    ),
                ]
            )
            return try jsonResponse(
                output,
                status: .ok,
                request: request,
                context: context
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            return try providerFailureResponse(
                error,
                requestID: validated.requestID,
                request: request,
                context: context
            )
        }
    }

    private func makeRecognitionResponse(
        _ result: RemoteMedicineRecognitionResult,
        requestID: UUID
    ) -> MedicineRecognitionAPIResponseDTO {
        let candidateResolution = result.candidateResolution
        let status: MedicineRecognitionStatusDTO
        let unresolvedReason: MedicineRecognitionUnresolvedReasonDTO?
        let errorCode: APIErrorCode?

        if candidateResolution.resolution.selectedMedicine != nil,
           candidateResolution.assurance.permitsResolverSelection {
            status = .recognized
            unresolvedReason = nil
            errorCode = nil
        } else {
            switch candidateResolution.assurance {
            case .unreadable:
                status = .unreadable
                unresolvedReason = .imageUnreadable
                errorCode = .medicineRecognitionFailed
            case .noEvidence:
                status = .noCandidate
                unresolvedReason = .noEvidence
                errorCode = .medicineNotFound
            case .unresolved:
                if candidateResolution.searchResult.candidates.isEmpty {
                    status = .noCandidate
                    unresolvedReason = .noCandidate
                    errorCode = .medicineNotFound
                } else {
                    status = .ambiguous
                    unresolvedReason = .canonicalResolutionFailed
                    errorCode = .medicineInsufficientEvidence
                }
            case .supportingOnly:
                status = .ambiguous
                unresolvedReason = .supportingEvidenceOnly
                errorCode = .medicineInsufficientEvidence
            case .ambiguous:
                status = .ambiguous
                unresolvedReason = .ambiguousCandidates
                errorCode = .medicineAmbiguous
            case .conflicting:
                status = .ambiguous
                unresolvedReason = .conflictingEvidence
                errorCode = .sourceConflict
            case .uncertain:
                status = .ambiguous
                unresolvedReason = .uncertainEvidence
                errorCode = .medicineInsufficientEvidence
            case .corroborated, .exact:
                status = .ambiguous
                unresolvedReason = .canonicalResolutionFailed
                errorCode = .medicineRecognitionFailed
            }
        }

        let canonicalResolution = canonicalResolutionDTO(
            candidateResolution
        )
        let responseCandidates = Self.boundedCandidates(
            candidateResolution.searchResult.candidates,
            selectedMedicineID: canonicalResolution?.canonicalMedicineID
        )

        return MedicineRecognitionAPIResponseDTO(
            status: status,
            requestID: requestID,
            packageEvidence: packageEvidenceDTO(
                result.packageEvidence
            ),
            canonicalResolution: canonicalResolution,
            candidates: responseCandidates.map(candidateDTO),
            unresolvedEvidence: Array(
                candidateResolution.searchResult.unresolvedEvidence
                    .prefix(Self.maximumUnresolvedObservationCount)
            ).map(observationDTO),
            unresolvedReason: unresolvedReason,
            allowsLocalFallback: false,
            errorCode: errorCode,
            apiVersion: SlowWalkAPI.version
        )
    }

    private func providerFailureResponse(
        _ error: any Error,
        requestID: UUID,
        request: Request,
        context: SlowWalkRequestContext
    ) throws -> Response {
        let mapping = providerFailureMapping(error)
        context.logger.warning(
            "medicine_recognition_provider_failed",
            metadata: [
                "slowwalk.api_request_id": .string(requestID.uuidString),
                "slowwalk.error_code": .string(mapping.code.rawValue),
                "slowwalk.http_status": .string(
                    String(mapping.status.code)
                ),
            ]
        )
        return try jsonResponse(
            MedicineRecognitionAPIResponseDTO(
                status: .providerUnavailable,
                requestID: requestID,
                packageEvidence: nil,
                canonicalResolution: nil,
                candidates: [],
                unresolvedEvidence: [],
                unresolvedReason: .providerUnavailable,
                allowsLocalFallback: mapping.allowsFallback,
                errorCode: mapping.code,
                apiVersion: SlowWalkAPI.version
            ),
            status: mapping.status,
            request: request,
            context: context
        )
    }

    private func providerFailureMapping(
        _ error: any Error
    ) -> ProviderFailureMapping {
        if error is RemoteMedicineRecognitionServiceError {
            return .init(
                code: .providerTimeout,
                status: .gatewayTimeout,
                allowsFallback: true
            )
        }
        guard let error = error as? ZhipuVisionClientError else {
            return .init(
                code: .invalidProviderResponse,
                status: .badGateway,
                allowsFallback: false
            )
        }
        switch error {
        case .rateLimited:
            return .init(
                code: .providerRateLimited,
                status: .tooManyRequests,
                allowsFallback: true
            )
        case .timeout:
            return .init(
                code: .providerTimeout,
                status: .gatewayTimeout,
                allowsFallback: true
            )
        case .missingCredential, .unauthorized, .serverFailure,
             .transportFailure:
            return .init(
                code: .providerUnavailable,
                status: .serviceUnavailable,
                allowsFallback: true
            )
        case .malformedProviderResponse, .invalidModelPayload,
             .invalidRequest:
            return .init(
                code: .invalidProviderResponse,
                status: .badGateway,
                allowsFallback: false
            )
        }
    }

    private func packageEvidenceDTO(
        _ evidence: RemoteMedicinePackageEvidence
    ) -> MedicinePackageEvidenceDTO {
        MedicinePackageEvidenceDTO(
            visibleTexts: evidence.visibleTexts,
            probableProductNames: evidence.probableProductNames,
            probableGenericNames: evidence.probableGenericNames,
            manufacturerNames: evidence.manufacturerNames,
            approvalIdentifiers: evidence.approvalIdentifiers,
            dosageFormTexts: evidence.dosageFormTexts,
            packagingFeatures: evidence.packagingFeatures,
            searchQueries: evidence.searchQueries,
            imageReadable: evidence.imageReadable,
            uncertainRegionsPresent:
                evidence.uncertainRegionsPresent
        )
    }

    private func canonicalResolutionDTO(
        _ result: RemoteMedicineCandidateResolution
    ) -> MedicineCanonicalResolutionSummaryDTO? {
        guard let medicine = result.resolution.selectedMedicine,
              result.assurance.permitsResolverSelection,
              let status = MedicineCanonicalResolutionStatusDTO(
                rawValue: result.resolution.status.rawValue
              )
        else {
            return nil
        }
        return MedicineCanonicalResolutionSummaryDTO(
            canonicalMedicineID: medicine.id,
            canonicalName: medicine.canonicalName,
            status: status
        )
    }

    private func candidateDTO(
        _ candidate: MedicineEvidenceCandidate
    ) -> MedicineEvidenceCandidateSummaryDTO {
        MedicineEvidenceCandidateSummaryDTO(
            canonicalMedicineID: candidate.medicine.id,
            canonicalName: candidate.medicine.canonicalName,
            exactEvidence: boundedMatches(candidate.exactEvidence),
            supportingEvidence: boundedMatches(
                Self.boundedSupportingMatches(
                    candidate.supportingEvidence
                )
            ),
            conflictingEvidence: boundedMatches(
                candidate.conflictingEvidence
            ),
            unresolvedEvidence: boundedMatches(
                candidate.unresolvedEvidence
            )
        )
    }

    private func boundedMatches(
        _ matches: [MedicineEvidenceMatch]
    ) -> [MedicineRecognitionEvidenceMatchDTO] {
        Array(matches.prefix(Self.maximumMatchesPerCategory)).map {
            MedicineRecognitionEvidenceMatchDTO(
                source: MedicineRecognitionEvidenceSourceDTO(
                    rawValue: $0.source.rawValue
                )!,
                observedText: $0.observedText,
                normalizedObservedText: $0.normalizedObservedText,
                catalogField: MedicineRecognitionCatalogFieldDTO(
                    rawValue: $0.catalogField.rawValue
                )!,
                catalogText: $0.catalogText
            )
        }
    }

    /// A corroborated resolution needs both witnesses to remain inspectable
    /// after the response-size projection. The source list is already stable;
    /// only over-limit lists are reordered, and only when both witnesses exist.
    static func boundedSupportingMatches(
        _ matches: [MedicineEvidenceMatch]
    ) -> [MedicineEvidenceMatch] {
        guard matches.count > Self.maximumMatchesPerCategory,
              let alias = matches.first(where: {
                  $0.catalogField == .alias && $0.source != .searchQuery
              }),
              let independent = matches.first(where: {
                  $0.source != .searchQuery
                      && [.manufacturerName, .packagingText]
                          .contains($0.catalogField)
              })
        else {
            return Array(matches.prefix(Self.maximumMatchesPerCategory))
        }

        var selected = [alias, independent]
        for match in matches where !selected.contains(match) {
            guard selected.count < Self.maximumMatchesPerCategory else {
                break
            }
            selected.append(match)
        }
        return selected
    }

    /// The canonical identity must always have a corresponding candidate
    /// summary, even when explanatory candidates exceed the wire limit.
    static func boundedCandidates(
        _ candidates: [MedicineEvidenceCandidate],
        selectedMedicineID: String?
    ) -> [MedicineEvidenceCandidate] {
        let prefix = Array(candidates.prefix(Self.maximumCandidateCount))
        guard let selectedMedicineID,
              !prefix.contains(where: {
                  $0.medicine.id == selectedMedicineID
              }),
              let selected = candidates.first(where: {
                  $0.medicine.id == selectedMedicineID
              })
        else {
            return prefix
        }

        return [selected] + prefix.prefix(Self.maximumCandidateCount - 1)
    }

    private func observationDTO(
        _ observation: MedicineEvidenceObservation
    ) -> MedicineRecognitionEvidenceObservationDTO {
        MedicineRecognitionEvidenceObservationDTO(
            source: MedicineRecognitionEvidenceSourceDTO(
                rawValue: observation.source.rawValue
            )!,
            observedText: observation.observedText,
            normalizedText: observation.normalizedText
        )
    }

    private func hasJSONContentType(_ request: Request) -> Bool {
        guard let header = request.headers[.contentType],
              let mediaType = MediaType(from: header)
        else {
            return false
        }
        return mediaType.isType(.applicationJson)
    }

    private func requestContentLengthExceedsLimit(
        _ request: Request
    ) -> Bool {
        guard let header = request.headers[.contentLength],
              let length = Int(header)
        else {
            return false
        }
        return length
            > MedicineRecognitionAPIRequestValidator.maximumRequestBodyBytes
    }

    private func requestBodyTooLargeResponse(
        requestID: UUID,
        request: Request,
        context: SlowWalkRequestContext
    ) throws -> Response {
        try errorResponse(
            code: .requestBodyTooLarge,
            message: "The request body exceeds the 6 MiB limit.",
            requestID: requestID,
            details: nil,
            status: .contentTooLarge,
            request: request,
            context: context
        )
    }

    private func errorResponse(
        code: APIErrorCode,
        message: String,
        requestID: UUID,
        details: [APIErrorDetailDTO]?,
        status: HTTPResponse.Status,
        request: Request,
        context: SlowWalkRequestContext
    ) throws -> Response {
        context.logger.warning(
            "medicine_recognition_rejected",
            metadata: [
                "slowwalk.api_request_id": .string(requestID.uuidString),
                "slowwalk.error_code": .string(code.rawValue),
                "slowwalk.http_status": .string(String(status.code)),
            ]
        )
        return try jsonResponse(
            APIErrorDTO(
                code: code,
                message: message,
                requestID: requestID,
                details: details
            ),
            status: status,
            request: request,
            context: context
        )
    }

    private func jsonResponse<Value: Encodable>(
        _ value: Value,
        status: HTTPResponse.Status,
        request: Request,
        context: SlowWalkRequestContext
    ) throws -> Response {
        var response = try context.responseEncoder.encode(
            value,
            from: request,
            context: context
        )
        response.status = status
        return response
    }
}

private struct ProviderFailureMapping {
    let code: APIErrorCode
    let status: HTTPResponse.Status
    let allowsFallback: Bool
}
