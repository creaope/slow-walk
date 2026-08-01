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
    private let observedAtTransform: @Sendable (Date) -> Date
    private let executionProbe: @Sendable () -> Void
    private let recognitionGate: @Sendable () async -> Void

    /// - Parameters:
    ///   - observedAtTransform: Derives `observedAt` from `capturedAt`;
    ///     identity in production.
    ///   - executionProbe: Test-only hook invoked immediately before the
    ///     blocking `perform(_:)` call, on the executor that actually runs
    ///     the Vision work. Empty in production.
    ///   - recognitionGate: Test-only hook awaited before recognition starts
    ///     so cancellation can be delivered deterministically mid-flight.
    ///     Empty in production.
    init(
        configuration: Configuration = .default,
        observedAtTransform: @escaping @Sendable (Date) -> Date = { $0 },
        executionProbe: @escaping @Sendable () -> Void = {},
        recognitionGate: @escaping @Sendable () async -> Void = {}
    ) {
        self.configuration = configuration
        self.observedAtTransform = observedAtTransform
        self.executionProbe = executionProbe
        self.recognitionGate = recognitionGate
    }

    // Isolation boundaries (the app target compiles with default MainActor
    // isolation and complete strict concurrency):
    // - Entry (this function): caller isolation. Only cheap, non-blocking
    //   validation and cancellation checks happen here.
    // - Vision work (`performRecognition`): `@concurrent`, so the blocking
    //   `VNImageRequestHandler.perform(_:)` runs on the cooperative thread
    //   pool instead of the caller's executor. The non-Sendable Vision
    //   objects (request, handler) are created, used, and destroyed inside
    //   that function and never cross an actor boundary.
    // - Result: `[RecognizedTextObservation]` is Sendable and is the only
    //   value that crosses back to the caller.
    func recognizeText(
        in input: OCRImageInput
    ) async throws -> [SlowWalkClientCore.RecognizedTextObservation] {
        guard !input.data.isEmpty else {
            throw Failure.emptyImageData
        }
        try Task.checkCancellation()
        return try await Self.performRecognition(
            data: input.data,
            orientation: input.orientation,
            configuration: configuration,
            observedAt: observedAtTransform(input.capturedAt),
            executionProbe: executionProbe,
            recognitionGate: recognitionGate
        )
    }

    @concurrent
    private static func performRecognition(
        data: Data,
        orientation: OCRImageOrientation,
        configuration: Configuration,
        observedAt: Date,
        executionProbe: @Sendable () -> Void,
        recognitionGate: @Sendable () async -> Void
    ) async throws -> [SlowWalkClientCore.RecognizedTextObservation] {
        try Task.checkCancellation()
        await recognitionGate()
        try Task.checkCancellation()
        executionProbe()

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

        let handler = VNImageRequestHandler(
            data: data,
            orientation: orientation.cgImageOrientation
        )
        do {
            try handler.perform([request])
        } catch {
            // The failure reason must not carry `localizedDescription`:
            // Vision errors can embed image-derived or privacy-sensitive
            // details. A stable, content-free reason is sufficient.
            throw Failure.recognitionFailed("vision_text_recognition_failed")
        }
        // A task cancelled while `perform(_:)` was blocked must not publish
        // a stale success result.
        try Task.checkCancellation()

        return (request.results ?? []).map {
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
