import Foundation

struct RemoteMedicineRecognitionResult: Sendable, Equatable {
    let packageEvidence: RemoteMedicinePackageEvidence
    let candidateResolution: RemoteMedicineCandidateResolution
}

enum RemoteMedicineRecognitionServiceError:
    Error,
    Sendable,
    Equatable
{
    case timedOut
}

/// Runs bounded visual evidence extraction, then delegates identity selection
/// to the existing canonical resolver. It performs no risk assessment.
struct RemoteMedicineRecognitionService: Sendable {
    typealias TimeoutTask = @Sendable () async throws -> Void

    static let defaultTimeout: Duration = .seconds(95)

    private let extractor: any MedicinePackageEvidenceExtracting
    private let resolver: RemoteMedicineCandidateResolver
    private let timeoutTask: TimeoutTask

    init(
        extractor: any MedicinePackageEvidenceExtracting,
        resolver: RemoteMedicineCandidateResolver,
        timeout: Duration = Self.defaultTimeout
    ) {
        self.init(
            extractor: extractor,
            resolver: resolver,
            timeoutTask: {
                try await Task<Never, Never>.sleep(for: timeout)
            }
        )
    }

    init(
        extractor: any MedicinePackageEvidenceExtracting,
        resolver: RemoteMedicineCandidateResolver,
        timeoutTask: @escaping TimeoutTask
    ) {
        self.extractor = extractor
        self.resolver = resolver
        self.timeoutTask = timeoutTask
    }

    func recognize(
        image: VisionImagePayload,
        capturedAt: Date = Date()
    ) async throws -> RemoteMedicineRecognitionResult {
        let evidence = try await extractWithTimeout(image: image)
        try Task.checkCancellation()
        return RemoteMedicineRecognitionResult(
            packageEvidence: evidence,
            candidateResolution: resolver.resolve(
                evidence: evidence,
                capturedAt: capturedAt
            )
        )
    }

    private func extractWithTimeout(
        image: VisionImagePayload
    ) async throws -> RemoteMedicinePackageEvidence {
        let completion = ExtractionCompletionGate()
        let extractionTask = Task {
            do {
                completion.resolve(
                    .success(
                        try await extractor
                            .extractMedicinePackageEvidence(from: image)
                    )
                )
            } catch {
                completion.resolve(
                    .failure(UncheckedSendableError(error))
                )
            }
        }
        let deadlineTask = Task {
            do {
                try await timeoutTask()
                completion.resolve(
                    .failure(
                        UncheckedSendableError(
                            RemoteMedicineRecognitionServiceError.timedOut
                        )
                    )
                )
            } catch is CancellationError {
                // The extractor completed first.
            } catch {
                completion.resolve(
                    .failure(UncheckedSendableError(error))
                )
            }
        }

        return try await withTaskCancellationHandler {
            defer {
                extractionTask.cancel()
                deadlineTask.cancel()
            }
            do {
                return try await completion.value()
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            extractionTask.cancel()
            deadlineTask.cancel()
            completion.resolve(
                .failure(UncheckedSendableError(CancellationError()))
            )
        }
    }
}

private struct UncheckedSendableError: Error, @unchecked Sendable {
    let underlying: any Error

    init(_ underlying: any Error) {
        self.underlying = underlying
    }
}

/// A first-result-wins gate lets the timeout return without awaiting a provider
/// implementation that does not cooperate with task cancellation.
private final class ExtractionCompletionGate: @unchecked Sendable {
    typealias Completion = Result<
        RemoteMedicinePackageEvidence,
        UncheckedSendableError
    >

    private let lock = NSLock()
    private var completion: Completion?
    private var continuation:
        CheckedContinuation<Completion, Never>?

    func resolve(_ newCompletion: Completion) {
        let continuationToResume: CheckedContinuation<Completion, Never>?
        lock.lock()
        if completion != nil {
            continuationToResume = nil
        } else if let continuation {
            self.continuation = nil
            completion = newCompletion
            continuationToResume = continuation
        } else {
            completion = newCompletion
            continuationToResume = nil
        }
        lock.unlock()
        continuationToResume?.resume(returning: newCompletion)
    }

    func value() async throws -> RemoteMedicinePackageEvidence {
        let result = await withCheckedContinuation { continuation in
            let immediate: Completion?
            lock.lock()
            if let completion {
                immediate = completion
            } else {
                self.continuation = continuation
                immediate = nil
            }
            lock.unlock()
            if let immediate {
                continuation.resume(returning: immediate)
            }
        }
        switch result {
        case .success(let evidence):
            return evidence
        case .failure(let error):
            throw error.underlying
        }
    }
}
