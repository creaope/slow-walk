import Foundation
import SlowWalkClientCore
import Vision

/// Apple Vision adapter that performs text recognition only.
///
/// It never resolves medicines, evaluates health risk, or persists the
/// original image bytes.
struct AppleVisionMedicineTextRecognizer: MedicineTextRecognizing {
    struct Configuration: Sendable, Equatable {
        enum LanguageCorrection: Sendable, Equatable {
            case automatic
            case disabled
        }

        var recognitionLevel: VNRequestTextRecognitionLevel = .accurate
        var languageCorrection: LanguageCorrection = .automatic
        var recognitionLanguages: [String] = []
        var minimumTextHeight: Float?

        static let `default` = Configuration()
    }

    enum Failure: Error, Equatable {
        case emptyImageData
        case recognitionFailed(String)
    }

    let configuration: Configuration
    private let observationFactory: @Sendable (Date) -> Date

    init(
        configuration: Configuration = .default,
        observationFactory: @escaping @Sendable (Date) -> Date = { $0 }
    ) {
        self.configuration = configuration
        self.observationFactory = observationFactory
    }

    func recognizeText(
        in input: OCRImageInput
    ) async throws -> [SlowWalkClientCore.RecognizedTextObservation] {
        guard !input.data.isEmpty else {
            throw Failure.emptyImageData
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = configuration.recognitionLevel
        request.usesLanguageCorrection =
            configuration.languageCorrection == .automatic
        if !configuration.recognitionLanguages.isEmpty {
            request.recognitionLanguages = configuration.recognitionLanguages
        }
        if let minimumTextHeight = configuration.minimumTextHeight {
            request.minimumTextHeight = minimumTextHeight
        }

        let observedAt = observationFactory(input.capturedAt)
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<
                [SlowWalkClientCore.RecognizedTextObservation],
                Error
            >) in
            let handler = VNImageRequestHandler(
                data: input.data,
                orientation: input.orientation.cgImageOrientation
            )
            do {
                try handler.perform([request])
                let mapped = (request.results ?? []).map {
                    // Vision does not expose a per-observation language, so
                    // the platform-neutral contract field stays nil here.
                    SlowWalkClientCore.RecognizedTextObservation(
                        text: $0.topCandidates(1).first?.string ?? "",
                        confidence: Double(
                            $0.topCandidates(1).first?.confidence ?? 0
                        ),
                        boundingRegion: OCRBoundingRegion(
                            x: Double($0.boundingBox.origin.x),
                            y: Double(1 - $0.boundingBox.origin.y
                                - $0.boundingBox.size.height),
                            width: Double($0.boundingBox.size.width),
                            height: Double($0.boundingBox.size.height)
                        ),
                        languageCode: nil,
                        observedAt: observedAt
                    )
                }
                continuation.resume(returning: mapped)
            } catch {
                continuation.resume(
                    throwing: Failure.recognitionFailed(
                        error.localizedDescription
                    )
                )
            }
        }
    }
}

extension OCRImageOrientation {
    nonisolated fileprivate var cgImageOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        }
    }
}
