import Foundation
import SlowWalkAPIContracts
import SlowWalkClientCore
import SlowWalkMedicinePipeline
import XCTest

final class OnlineMedicineRecognitionResponseMapperTests: XCTestCase {
    private let mapper = OnlineMedicineRecognitionResponseMapper()
    private let requestID = clientTestUUID(80)

    func testRequestBoundaryContainsOnlyImageAndCorrelationID() {
        let request = makeRequest()

        XCTAssertEqual(
            Set(Mirror(reflecting: request).children.compactMap(\.label)),
            ["image", "requestID"]
        )
        XCTAssertEqual(request.image, makeOCRImageInput())
        XCTAssertEqual(request.requestID, requestID)
    }

    func testRecognizedResponseMapsStableEvidenceAndCanonicalIdentity()
        throws
    {
        let capturedAt = Date(timeIntervalSince1970: 1_700_123_456)
        let request = OnlineMedicineRecognitionRequest(
            image: OCRImageInput(
                data: Data([9, 8, 7]),
                orientation: .left,
                capturedAt: capturedAt
            ),
            requestID: requestID
        )
        let response = makeResponse(
            evidence: makeEvidence(
                visibleTexts: [" ACETAMINOPHEN ", "500 mg"],
                probableProductNames: [" Tylenol "],
                probableGenericNames: ["Acetaminophen", "TYLENOL"]
            )
        )

        let result = try mapper.map(response, for: request)

        XCTAssertEqual(result.requestID, requestID)
        XCTAssertEqual(
            result.recognitionInput.recognizedTexts,
            ["Tylenol", "Acetaminophen", "500 mg"]
        )
        XCTAssertEqual(result.recognitionInput.capturedAt, capturedAt)
        XCTAssertNil(result.recognitionInput.languageCode)
        XCTAssertEqual(
            result.recognitionInput.rawConfidence,
            ResolverConfiguration.standard.minimumRecognitionConfidence
        )
        XCTAssertEqual(
            result.expectedCanonicalMedicineID,
            "demo-acetaminophen"
        )
        XCTAssertEqual(
            result.expectedCanonicalMedicineName,
            "Acetaminophen"
        )
    }

    func testRecognizedResponseAllowsMaximumBoundedRelevantEvidence()
        throws
    {
        let products = (0 ..< 16).map { "Product \($0)" }
        let generics = ["Acetaminophen"]
            + (1 ..< 16).map { "Generic \($0)" }
        let visible = (0 ..< 64).map { "Visible \($0)" }
        let response = makeResponse(
            evidence: makeEvidence(
                visibleTexts: visible,
                probableProductNames: products,
                probableGenericNames: generics
            )
        )

        let result = try mapper.map(response, for: makeRequest())

        XCTAssertEqual(result.recognitionInput.recognizedTexts.count, 96)
        XCTAssertEqual(
            result.recognitionInput.recognizedTexts,
            products + generics + visible
        )
    }

    func testEnvelopeMustMatchRequestAndAPIVersion() {
        assertFailure(
            .invalidResponse,
            response: makeResponse(requestID: clientTestUUID(81))
        )
        assertFailure(
            .invalidResponse,
            response: makeResponse(apiVersion: "v999")
        )
    }

    func testRecognizedResponseRequiresCoherentCanonicalFields() {
        let invalidResponses = [
            makeResponse(evidencePresent: false),
            makeResponse(evidence: makeEvidence(imageReadable: false)),
            makeResponse(
                evidence: makeEvidence(uncertainRegionsPresent: true)
            ),
            makeResponse(canonicalResolutionPresent: false),
            makeResponse(
                canonicalResolution: makeCanonical(status: .ambiguous)
            ),
            makeResponse(
                canonicalResolution: makeCanonical(id: " ")
            ),
            makeResponse(
                canonicalResolution: makeCanonical(name: " ")
            ),
            makeResponse(
                canonicalResolution: makeCanonical(id: " padded ")
            ),
            makeResponse(
                canonicalResolution: makeCanonical(
                    id: String(repeating: "i", count: 129)
                )
            ),
            makeResponse(
                canonicalResolution: makeCanonical(
                    name: String(repeating: "n", count: 161)
                )
            ),
            makeResponse(candidates: []),
            makeResponse(
                candidates: [makeCandidate(id: "another-medicine")]
            ),
            makeResponse(
                candidates: [makeCandidate(name: "Different Name")]
            ),
            makeResponse(unresolvedReason: .canonicalResolutionFailed),
            makeResponse(allowsLocalFallback: true),
            makeResponse(errorCode: .medicineRecognitionFailed),
        ]

        for response in invalidResponses {
            assertFailure(.invalidResponse, response: response)
        }
    }

    func testRecognizedResponseRejectsDuplicateAndExcessCandidates() {
        assertFailure(
            .invalidResponse,
            response: makeResponse(
                candidates: [makeCandidate(), makeCandidate()]
            )
        )
        let candidates = (0 ..< 9).map {
            makeCandidate(id: "medicine-\($0)", name: "Medicine \($0)")
        }
        assertFailure(
            .invalidResponse,
            response: makeResponse(
                canonicalResolution: makeCanonical(
                    id: "medicine-0",
                    name: "Medicine 0"
                ),
                candidates: candidates
            )
        )
    }

    func testRecognizedResponseRejectsEmptyOrConflictingCandidateEvidence() {
        assertFailure(
            .invalidResponse,
            response: makeResponse(
                candidates: [makeCandidate(exactEvidence: [])]
            )
        )

        let conflict = makeMatch(
            observedText: "Ibuprofen",
            normalizedObservedText: "ibuprofen",
            catalogText: "Ibuprofen"
        )
        let evidence = makeEvidence(
            probableGenericNames: ["Acetaminophen", "Ibuprofen"]
        )
        assertFailure(
            .invalidResponse,
            response: makeResponse(
                evidence: evidence,
                candidates: [
                    makeCandidate(conflictingEvidence: [conflict]),
                ]
            )
        )
        assertFailure(
            .invalidResponse,
            response: makeResponse(
                evidence: evidence,
                candidates: [
                    makeCandidate(),
                    makeCandidate(
                        id: "demo-ibuprofen",
                        name: "Ibuprofen",
                        exactEvidence: [],
                        conflictingEvidence: [conflict]
                    ),
                ]
            )
        )
    }

    func testRecognizedResponseRequiresServerValidStrongExactMatch() {
        let nonStrongExact = makeMatch(
            source: .probableProductName,
            observedText: "Paracetamol",
            normalizedObservedText: "paracetamol",
            catalogField: .alias,
            catalogText: "Paracetamol"
        )
        assertFailure(
            .invalidResponse,
            response: makeResponse(
                evidence: makeEvidence(
                    probableProductNames: ["Paracetamol"]
                ),
                candidates: [
                    makeCandidate(exactEvidence: [nonStrongExact]),
                ]
            )
        )

        let mismatchedCatalog = makeMatch(catalogText: "Ibuprofen")
        assertFailure(
            .invalidResponse,
            response: makeResponse(
                candidates: [
                    makeCandidate(exactEvidence: [mismatchedCatalog]),
                ]
            )
        )
    }

    func testRecognizedResponseAcceptsAliasWithIndependentCorroboration()
        throws
    {
        let alias = makeMatch(
            source: .probableProductName,
            observedText: "Paracetamol",
            normalizedObservedText: "paracetamol",
            catalogField: .alias,
            catalogText: "Paracetamol"
        )
        let manufacturer = makeMatch(
            source: .manufacturerName,
            observedText: "Example Pharma",
            normalizedObservedText: "example pharma",
            catalogField: .manufacturerName,
            catalogText: "Example Pharma"
        )
        let response = makeResponse(
            evidence: makeEvidence(
                visibleTexts: [],
                probableProductNames: ["Paracetamol"],
                probableGenericNames: [],
                manufacturerNames: ["Example Pharma"]
            ),
            candidates: [
                makeCandidate(
                    exactEvidence: [],
                    supportingEvidence: [alias, manufacturer]
                ),
            ]
        )

        let result = try mapper.map(response, for: makeRequest())

        XCTAssertEqual(
            result.expectedCanonicalMedicineID,
            "demo-acetaminophen"
        )
        XCTAssertEqual(
            result.recognitionInput.recognizedTexts,
            ["Paracetamol"]
        )
    }

    func testRecognizedResponseAcceptsBoundedPartialUnresolvedEvidence()
        throws
    {
        let response = makeResponse(
            evidence: makeEvidence(
                visibleTexts: ["Acetaminophen", "Lot 123"]
            ),
            unresolvedEvidence: [
                makeObservation(
                    observedText: "Lot 123",
                    normalizedText: "lot 123"
                ),
            ]
        )

        let result = try mapper.map(response, for: makeRequest())

        XCTAssertEqual(
            result.expectedCanonicalMedicineID,
            "demo-acetaminophen"
        )
    }

    func testRecognizedResponseRejectsUnresolvedEvidenceAlreadyMatched()
    {
        assertFailure(
            .invalidResponse,
            response: makeResponse(
                unresolvedEvidence: [
                    makeObservation(
                        source: .probableGenericName
                    ),
                ]
            )
        )
    }

    func testCandidateMatchCategoriesAreBoundedAndDeduplicated() {
        let repeatedExact = Array(repeating: makeExactMatch(), count: 17)
        for candidate in [
            makeCandidate(exactEvidence: repeatedExact),
            makeCandidate(
                exactEvidence: [],
                supportingEvidence: repeatedExact
            ),
            makeCandidate(conflictingEvidence: repeatedExact),
            makeCandidate(unresolvedEvidence: repeatedExact),
        ] {
            assertFailure(
                .invalidResponse,
                response: makeResponse(candidates: [candidate])
            )
        }
        assertFailure(
            .invalidResponse,
            response: makeResponse(
                candidates: [
                    makeCandidate(
                        exactEvidence: [makeExactMatch(), makeExactMatch()]
                    ),
                ]
            )
        )
    }

    func testCandidateMatchStringsAndSourcePairsAreValidated() {
        let invalidMatches = [
            makeMatch(normalizedObservedText: "wrong"),
            makeMatch(catalogText: " "),
            makeMatch(catalogText: String(repeating: "c", count: 257)),
            makeMatch(catalogText: "Ibuprofen"),
            makeMatch(observedText: "Not in package"),
            makeMatch(
                source: .manufacturerName,
                catalogField: .canonicalName
            ),
        ]
        for match in invalidMatches {
            assertFailure(
                .invalidResponse,
                response: makeResponse(
                    evidence: makeEvidence(
                        manufacturerNames: ["Acetaminophen"]
                    ),
                    candidates: [makeCandidate(exactEvidence: [match])]
                )
            )
        }

        let searchConflict = makeMatch(
            source: .searchQuery,
            catalogText: "Acetaminophen"
        )
        assertFailure(
            .invalidResponse,
            response: makeResponse(
                evidence: makeEvidence(searchQueries: ["Acetaminophen"]),
                candidates: [
                    makeCandidate(conflictingEvidence: [searchConflict]),
                ]
            )
        )
    }

    func testRelevantEvidenceCountLimitsAreEnforcedBeforeMapping() {
        let responses = [
            makeResponse(
                evidence: makeEvidence(
                    probableProductNames: (0 ... 16).map { "p\($0)" }
                )
            ),
            makeResponse(
                evidence: makeEvidence(
                    probableGenericNames: (0 ... 16).map { "g\($0)" }
                )
            ),
            makeResponse(
                evidence: makeEvidence(
                    visibleTexts: (0 ... 64).map { "v\($0)" }
                )
            ),
            makeResponse(
                evidence: makeEvidence(
                    manufacturerNames: (0 ... 16).map { "m\($0)" }
                )
            ),
            makeResponse(
                evidence: makeEvidence(
                    approvalIdentifiers: (0 ... 16).map { "a\($0)" }
                )
            ),
            makeResponse(
                evidence: makeEvidence(
                    dosageFormTexts: (0 ... 16).map { "d\($0)" }
                )
            ),
            makeResponse(
                evidence: makeEvidence(
                    packagingFeatures: (0 ... 24).map { "f\($0)" }
                )
            ),
            makeResponse(
                evidence: makeEvidence(
                    searchQueries: (0 ... 8).map { "q\($0)" }
                )
            ),
        ]

        for response in responses {
            assertFailure(.invalidResponse, response: response)
        }
    }

    func testRelevantEvidenceLengthAndAggregateLimitsAreEnforced() {
        let overlongName = String(repeating: "a", count: 161)
        let overlongVisible = String(repeating: "b", count: 257)
        let overlongSearch = String(repeating: "q", count: 97)
        let aggregateOverflow = (0 ..< 17).map { index in
            String(repeating: Character(String(index % 10)), count: 256)
        }
        let responses = [
            makeResponse(
                evidence: makeEvidence(
                    probableProductNames: [overlongName]
                )
            ),
            makeResponse(
                evidence: makeEvidence(
                    probableGenericNames: [overlongName]
                )
            ),
            makeResponse(
                evidence: makeEvidence(visibleTexts: [overlongVisible])
            ),
            makeResponse(
                evidence: makeEvidence(manufacturerNames: [overlongName])
            ),
            makeResponse(
                evidence: makeEvidence(approvalIdentifiers: [overlongName])
            ),
            makeResponse(
                evidence: makeEvidence(dosageFormTexts: [overlongName])
            ),
            makeResponse(
                evidence: makeEvidence(
                    packagingFeatures: [overlongVisible]
                )
            ),
            makeResponse(
                evidence: makeEvidence(searchQueries: [overlongSearch])
            ),
            makeResponse(
                evidence: makeEvidence(
                    searchQueries: (0 ..< 5).map {
                        "\($0)" + String(repeating: "q", count: 79)
                    }
                )
            ),
            makeResponse(
                evidence: makeEvidence(visibleTexts: aggregateOverflow)
            ),
            makeResponse(
                evidence: makeEvidence(probableProductNames: ["   "])
            ),
            makeResponse(
                evidence: makeEvidence(packagingFeatures: ["\n"])
            ),
        ]

        for response in responses {
            assertFailure(.invalidResponse, response: response)
        }
    }

    func testNormalizerEmptyEvidenceIsFilteredBeforeStableDeduplication()
        throws
    {
        let response = makeResponse(
            evidence: makeEvidence(
                visibleTexts: ["---", "Acetaminophen"],
                probableGenericNames: ["ACETAMINOPHEN"]
            ),
            candidates: [
                makeCandidate(
                    exactEvidence: [
                        makeMatch(
                            source: .probableGenericName,
                            observedText: "ACETAMINOPHEN"
                        ),
                    ]
                ),
            ]
        )

        let result = try mapper.map(response, for: makeRequest())

        XCTAssertEqual(
            result.recognitionInput.recognizedTexts,
            ["ACETAMINOPHEN"]
        )
        assertFailure(
            .invalidResponse,
            response: makeResponse(
                evidence: makeEvidence(
                    visibleTexts: ["---"],
                    probableGenericNames: []
                )
            )
        )
    }

    func testAmbiguousReasonsMapWithoutAllowingFallback() {
        let alias = makeMatch(
            source: .probableProductName,
            observedText: "Paracetamol",
            normalizedObservedText: "paracetamol",
            catalogField: .alias,
            catalogText: "Paracetamol"
        )
        let sharedAlias = makeMatch(
            source: .probableProductName,
            observedText: "Cold Relief",
            normalizedObservedText: "cold relief",
            catalogField: .alias,
            catalogText: "Cold Relief"
        )
        let ibuprofen = makeMatch(
            observedText: "Ibuprofen",
            normalizedObservedText: "ibuprofen",
            catalogText: "Ibuprofen"
        )
        let responses = [
            makeResponse(
                status: .ambiguous,
                evidence: makeEvidence(
                    visibleTexts: [],
                    probableProductNames: ["Paracetamol"],
                    probableGenericNames: []
                ),
                canonicalResolutionPresent: false,
                candidates: [
                    makeCandidate(
                        exactEvidence: [],
                        supportingEvidence: [alias]
                    ),
                ],
                unresolvedReason: .supportingEvidenceOnly,
                errorCode: .medicineInsufficientEvidence
            ),
            makeResponse(
                status: .ambiguous,
                evidence: makeEvidence(
                    visibleTexts: [],
                    probableProductNames: ["Cold Relief"],
                    probableGenericNames: []
                ),
                canonicalResolutionPresent: false,
                candidates: [
                    makeCandidate(
                        exactEvidence: [],
                        supportingEvidence: [sharedAlias]
                    ),
                    makeCandidate(
                        id: "demo-ibuprofen",
                        name: "Ibuprofen",
                        exactEvidence: [],
                        supportingEvidence: [sharedAlias]
                    ),
                ],
                unresolvedReason: .ambiguousCandidates,
                errorCode: .medicineAmbiguous
            ),
            makeResponse(
                status: .ambiguous,
                evidence: makeEvidence(
                    probableGenericNames: ["Acetaminophen", "Ibuprofen"]
                ),
                canonicalResolutionPresent: false,
                candidates: [
                    makeCandidate(conflictingEvidence: [ibuprofen]),
                ],
                unresolvedReason: .conflictingEvidence,
                errorCode: .sourceConflict
            ),
            makeResponse(
                status: .ambiguous,
                evidence: makeEvidence(uncertainRegionsPresent: true),
                canonicalResolutionPresent: false,
                unresolvedReason: .uncertainEvidence,
                errorCode: .medicineInsufficientEvidence
            ),
            makeResponse(
                status: .ambiguous,
                evidence: makeEvidence(
                    visibleTexts: [],
                    probableProductNames: ["Paracetamol"],
                    probableGenericNames: []
                ),
                canonicalResolutionPresent: false,
                candidates: [
                    makeCandidate(
                        exactEvidence: [],
                        unresolvedEvidence: [alias]
                    ),
                ],
                unresolvedReason: .canonicalResolutionFailed,
                errorCode: .medicineInsufficientEvidence
            ),
            makeResponse(
                status: .ambiguous,
                canonicalResolutionPresent: false,
                unresolvedReason: .canonicalResolutionFailed,
                errorCode: .medicineRecognitionFailed
            ),
        ]

        for response in responses {
            assertFailure(
                .ambiguous,
                response: response
            )
        }
    }

    func testUncertainEvidenceCanBeAmbiguousWithoutCandidates() {
        assertFailure(
            .ambiguous,
            response: makeResponse(
                status: .ambiguous,
                evidence: makeEvidence(uncertainRegionsPresent: true),
                canonicalResolutionPresent: false,
                candidates: [],
                unresolvedReason: .uncertainEvidence,
                errorCode: .medicineInsufficientEvidence
            )
        )
    }

    func testAmbiguousResponseRejectsMismatchedReasonAndFields() {
        let responses = [
            makeResponse(
                status: .ambiguous,
                canonicalResolutionPresent: false,
                unresolvedReason: .ambiguousCandidates,
                errorCode: .sourceConflict
            ),
            makeResponse(
                status: .ambiguous,
                canonicalResolutionPresent: false,
                candidates: [],
                unresolvedReason: .ambiguousCandidates,
                errorCode: .medicineAmbiguous
            ),
            makeResponse(
                status: .ambiguous,
                canonicalResolutionPresent: false,
                unresolvedReason: .uncertainEvidence,
                errorCode: .medicineInsufficientEvidence
            ),
            makeResponse(
                status: .ambiguous,
                evidence: makeEvidence(uncertainRegionsPresent: true),
                canonicalResolutionPresent: false,
                unresolvedReason: .conflictingEvidence,
                errorCode: .sourceConflict
            ),
            makeResponse(
                status: .ambiguous,
                canonicalResolutionPresent: false,
                unresolvedReason: .conflictingEvidence,
                errorCode: .sourceConflict
            ),
            makeResponse(
                status: .ambiguous,
                canonicalResolutionPresent: false,
                unresolvedReason: .ambiguousCandidates,
                allowsLocalFallback: true,
                errorCode: .medicineAmbiguous
            ),
        ]

        for response in responses {
            assertFailure(.invalidResponse, response: response)
        }
    }

    func testSupportingOnlyRequiresExactlyOneUncorroboratedSupportingCandidate()
    {
        let alias = makeMatch(
            source: .probableProductName,
            observedText: "Paracetamol",
            normalizedObservedText: "paracetamol",
            catalogField: .alias,
            catalogText: "Paracetamol"
        )
        let manufacturer = makeMatch(
            source: .manufacturerName,
            observedText: "Example Pharma",
            normalizedObservedText: "example pharma",
            catalogField: .manufacturerName,
            catalogText: "Example Pharma"
        )
        let evidence = makeEvidence(
            visibleTexts: [],
            probableProductNames: ["Paracetamol"],
            probableGenericNames: ["Acetaminophen"],
            manufacturerNames: ["Example Pharma"]
        )
        let invalidCandidates = [
            [makeCandidate()],
            [
                makeCandidate(
                    exactEvidence: [],
                    supportingEvidence: [alias]
                ),
                makeCandidate(
                    id: "demo-ibuprofen",
                    name: "Ibuprofen",
                    exactEvidence: [],
                    supportingEvidence: [alias]
                ),
            ],
            [
                makeCandidate(
                    exactEvidence: [],
                    supportingEvidence: [alias, manufacturer]
                ),
            ],
        ]

        for candidates in invalidCandidates {
            assertFailure(
                .invalidResponse,
                response: makeResponse(
                    status: .ambiguous,
                    evidence: evidence,
                    canonicalResolutionPresent: false,
                    candidates: candidates,
                    unresolvedReason: .supportingEvidenceOnly,
                    errorCode: .medicineInsufficientEvidence
                )
            )
        }
    }

    func testUnreadableResponseMapsWithPartialUnresolvedEvidence() {
        let response = makeResponse(
            status: .unreadable,
            evidence: makeEvidence(
                visibleTexts: ["Unknown medicine"],
                probableGenericNames: [],
                imageReadable: false
            ),
            canonicalResolutionPresent: false,
            candidates: [],
            unresolvedEvidence: [
                makeObservation(
                    observedText: "Unknown medicine",
                    normalizedText: "unknown medicine"
                ),
            ],
            unresolvedReason: .imageUnreadable,
            errorCode: .medicineRecognitionFailed
        )

        assertFailure(.unreadable, response: response)
    }

    func testUnreadableResponseRejectsReadableImageAndFallback() {
        assertFailure(
            .invalidResponse,
            response: makeResponse(
                status: .unreadable,
                canonicalResolutionPresent: false,
                candidates: [],
                unresolvedReason: .imageUnreadable,
                errorCode: .medicineRecognitionFailed
            )
        )
        assertFailure(
            .invalidResponse,
            response: makeResponse(
                status: .unreadable,
                evidence: makeEvidence(imageReadable: false),
                canonicalResolutionPresent: false,
                candidates: [makeCandidate()],
                unresolvedReason: .imageUnreadable,
                errorCode: .medicineRecognitionFailed
            )
        )
        assertFailure(
            .invalidResponse,
            response: makeResponse(
                status: .unreadable,
                evidence: makeEvidence(imageReadable: false),
                canonicalResolutionPresent: false,
                candidates: [],
                unresolvedReason: .imageUnreadable,
                allowsLocalFallback: true,
                errorCode: .medicineRecognitionFailed
            )
        )
    }

    func testUnresolvedObservationBoundsAreEnforced() {
        assertFailure(
            .invalidResponse,
            response: makeResponse(
                status: .unreadable,
                evidence: makeEvidence(imageReadable: false),
                canonicalResolutionPresent: false,
                candidates: [],
                unresolvedEvidence: Array(
                    repeating: makeObservation(),
                    count: 33
                ),
                unresolvedReason: .imageUnreadable,
                errorCode: .medicineRecognitionFailed
            )
        )
    }

    func testNoCandidateReasonsRequireMatchingUnresolvedEvidence() {
        assertFailure(
            .noCandidate,
            response: makeResponse(
                status: .noCandidate,
                evidence: makeEvidence(
                    visibleTexts: [],
                    probableGenericNames: []
                ),
                canonicalResolutionPresent: false,
                candidates: [],
                unresolvedReason: .noEvidence,
                errorCode: .medicineNotFound
            )
        )
        assertFailure(
            .noCandidate,
            response: makeResponse(
                status: .noCandidate,
                evidence: makeEvidence(
                    visibleTexts: ["Unknown medicine"],
                    probableGenericNames: []
                ),
                canonicalResolutionPresent: false,
                candidates: [],
                unresolvedEvidence: [
                    makeObservation(
                        observedText: "Unknown medicine",
                        normalizedText: "unknown medicine"
                    ),
                ],
                unresolvedReason: .noCandidate,
                errorCode: .medicineNotFound
            )
        )
    }

    func testNoCandidateRejectsInvalidSemanticFields() {
        assertFailure(
            .invalidResponse,
            response: makeResponse(
                status: .noCandidate,
                evidence: makeEvidence(uncertainRegionsPresent: true),
                canonicalResolutionPresent: false,
                candidates: [],
                unresolvedReason: .noEvidence,
                errorCode: .medicineNotFound
            )
        )
        assertFailure(
            .invalidResponse,
            response: makeResponse(
                status: .noCandidate,
                evidence: makeEvidence(
                    visibleTexts: ["Unknown medicine"],
                    probableGenericNames: []
                ),
                canonicalResolutionPresent: false,
                candidates: [],
                unresolvedReason: .noCandidate,
                errorCode: .medicineNotFound
            )
        )
    }

    func testRecoverableProviderFailuresMapExactly() {
        let cases: [(APIErrorCode, OnlineMedicineRecognitionFailure)] = [
            (.providerRateLimited, .rateLimited),
            (.providerTimeout, .timeout),
            (.providerUnavailable, .providerUnavailable),
        ]

        for (errorCode, expectedFailure) in cases {
            assertFailure(
                expectedFailure,
                response: makeProviderResponse(errorCode: errorCode)
            )
        }
    }

    func testInvalidProviderResponseFailsClosed() {
        assertFailure(
            .invalidResponse,
            response: makeProviderResponse(
                allowsLocalFallback: false,
                errorCode: .invalidProviderResponse
            )
        )
        assertFailure(
            .invalidResponse,
            response: makeProviderResponse(
                allowsLocalFallback: true,
                errorCode: .invalidProviderResponse
            )
        )
    }

    func testProviderFailureRejectsSemanticOrFallbackMismatch() {
        assertFailure(
            .invalidResponse,
            response: makeProviderResponse(
                errorCode: .medicineRecognitionFailed
            )
        )
        assertFailure(
            .invalidResponse,
            response: makeProviderResponse(
                evidence: makeEvidence(),
                errorCode: .providerUnavailable
            )
        )
        assertFailure(
            .invalidResponse,
            response: makeProviderResponse(
                allowsLocalFallback: false,
                errorCode: .providerUnavailable
            )
        )
    }

    private func makeRequest() -> OnlineMedicineRecognitionRequest {
        OnlineMedicineRecognitionRequest(
            image: makeOCRImageInput(),
            requestID: requestID
        )
    }

    private func makeResponse(
        status: MedicineRecognitionStatusDTO = .recognized,
        requestID: UUID? = nil,
        evidence: MedicinePackageEvidenceDTO? = nil,
        evidencePresent: Bool = true,
        canonicalResolution:
            MedicineCanonicalResolutionSummaryDTO? = nil,
        canonicalResolutionPresent: Bool = true,
        candidates: [MedicineEvidenceCandidateSummaryDTO]? = nil,
        unresolvedEvidence:
            [MedicineRecognitionEvidenceObservationDTO] = [],
        unresolvedReason:
            MedicineRecognitionUnresolvedReasonDTO? = nil,
        allowsLocalFallback: Bool = false,
        errorCode: APIErrorCode? = nil,
        apiVersion: String = SlowWalkAPI.version
    ) -> MedicineRecognitionAPIResponseDTO {
        MedicineRecognitionAPIResponseDTO(
            status: status,
            requestID: requestID ?? self.requestID,
            packageEvidence:
                evidencePresent ? (evidence ?? makeEvidence()) : nil,
            canonicalResolution: canonicalResolutionPresent
                ? (canonicalResolution ?? makeCanonical())
                : nil,
            candidates: candidates ?? [makeCandidate()],
            unresolvedEvidence: unresolvedEvidence,
            unresolvedReason: unresolvedReason,
            allowsLocalFallback: allowsLocalFallback,
            errorCode: errorCode,
            apiVersion: apiVersion
        )
    }

    private func makeProviderResponse(
        evidence: MedicinePackageEvidenceDTO? = nil,
        allowsLocalFallback: Bool = true,
        errorCode: APIErrorCode
    ) -> MedicineRecognitionAPIResponseDTO {
        MedicineRecognitionAPIResponseDTO(
            status: .providerUnavailable,
            requestID: requestID,
            packageEvidence: evidence,
            canonicalResolution: nil,
            candidates: [],
            unresolvedEvidence: [],
            unresolvedReason: .providerUnavailable,
            allowsLocalFallback: allowsLocalFallback,
            errorCode: errorCode,
            apiVersion: SlowWalkAPI.version
        )
    }

    private func makeEvidence(
        visibleTexts: [String] = ["Acetaminophen"],
        probableProductNames: [String] = [],
        probableGenericNames: [String] = ["Acetaminophen"],
        manufacturerNames: [String] = [],
        approvalIdentifiers: [String] = [],
        dosageFormTexts: [String] = [],
        packagingFeatures: [String] = [],
        searchQueries: [String] = [],
        imageReadable: Bool = true,
        uncertainRegionsPresent: Bool = false
    ) -> MedicinePackageEvidenceDTO {
        MedicinePackageEvidenceDTO(
            visibleTexts: visibleTexts,
            probableProductNames: probableProductNames,
            probableGenericNames: probableGenericNames,
            manufacturerNames: manufacturerNames,
            approvalIdentifiers: approvalIdentifiers,
            dosageFormTexts: dosageFormTexts,
            packagingFeatures: packagingFeatures,
            searchQueries: searchQueries,
            imageReadable: imageReadable,
            uncertainRegionsPresent: uncertainRegionsPresent
        )
    }

    private func makeCanonical(
        id: String = "demo-acetaminophen",
        name: String = "Acetaminophen",
        status: MedicineCanonicalResolutionStatusDTO = .resolved
    ) -> MedicineCanonicalResolutionSummaryDTO {
        MedicineCanonicalResolutionSummaryDTO(
            canonicalMedicineID: id,
            canonicalName: name,
            status: status
        )
    }

    private func makeCandidate(
        id: String = "demo-acetaminophen",
        name: String = "Acetaminophen",
        exactEvidence: [MedicineRecognitionEvidenceMatchDTO]? = nil,
        supportingEvidence: [MedicineRecognitionEvidenceMatchDTO] = [],
        conflictingEvidence: [MedicineRecognitionEvidenceMatchDTO] = [],
        unresolvedEvidence: [MedicineRecognitionEvidenceMatchDTO] = []
    ) -> MedicineEvidenceCandidateSummaryDTO {
        MedicineEvidenceCandidateSummaryDTO(
            canonicalMedicineID: id,
            canonicalName: name,
            exactEvidence: exactEvidence ?? [makeExactMatch()],
            supportingEvidence: supportingEvidence,
            conflictingEvidence: conflictingEvidence,
            unresolvedEvidence: unresolvedEvidence
        )
    }

    private func makeMatch(
        source: MedicineRecognitionEvidenceSourceDTO =
            .probableGenericName,
        observedText: String = "Acetaminophen",
        normalizedObservedText: String = "acetaminophen",
        catalogField: MedicineRecognitionCatalogFieldDTO = .canonicalName,
        catalogText: String = "Acetaminophen"
    ) -> MedicineRecognitionEvidenceMatchDTO {
        MedicineRecognitionEvidenceMatchDTO(
            source: source,
            observedText: observedText,
            normalizedObservedText: normalizedObservedText,
            catalogField: catalogField,
            catalogText: catalogText
        )
    }

    private func makeExactMatch()
        -> MedicineRecognitionEvidenceMatchDTO
    {
        makeMatch()
    }

    private func makeObservation(
        source: MedicineRecognitionEvidenceSourceDTO = .visibleText,
        observedText: String = "Acetaminophen",
        normalizedText: String = "acetaminophen"
    )
        -> MedicineRecognitionEvidenceObservationDTO
    {
        MedicineRecognitionEvidenceObservationDTO(
            source: source,
            observedText: observedText,
            normalizedText: normalizedText
        )
    }

    private func assertFailure(
        _ expected: OnlineMedicineRecognitionFailure,
        response: MedicineRecognitionAPIResponseDTO,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try mapper.map(response, for: makeRequest())
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let failure as OnlineMedicineRecognitionFailure {
            XCTAssertEqual(failure, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error type", file: file, line: line)
        }
    }
}
