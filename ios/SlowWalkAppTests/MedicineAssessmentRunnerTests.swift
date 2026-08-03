import Combine
import Foundation
import SlowWalkAPIContracts
import SlowWalkClientCore
import SlowWalkDomain
import Testing
@testable import SlowWalkApp

@MainActor
struct MedicineAssessmentRunnerTests {
    @Test func startCompletesCanonicalAssessmentAtExactGenerationAfterReset()
        async throws
    {
        let backend = ControlledMedicineBackend(plans: [.resolved])
        let (runner, session) = try await makeRunner(backend: backend)

        #expect(await runner.start(try makeAssessmentInvocation(runner)))

        #expect(await waitForGate(session, state: .result))
        #expect(session.assessmentGate?.latestUpdate?.sequenceNumber == 2)
        #expect(await backend.requests.count == 1)
        #expect(await backend.requests.first?.input.recognizedTexts == ["Test Medicine"])
    }

    @Test func captureFirstGateStartsRunnerWithoutMedicineIdentity()
        async throws
    {
        let backend = ControlledMedicineBackend(plans: [.resolved])
        let recognizer = CountingMedicineRecognizer()
        let environment = makeProductionEnvironment(
            backend: backend,
            recognizer: recognizer
        )
        try await enterProductionAssessmentGate(environment.companion)

        #expect(
            environment.companion.assessmentGate?
                .preAssessmentSelection == nil
        )
        #expect(environment.careRecords.events.contains { event in
            if case .medicineConfirmed = event.kind { return true }
            return false
        } == false)

        let invocation = environment.medicineAssessmentRunner
            .makeAssessmentInvocation(
                imageInput: RunnerFixtures.image,
                userProfile: RunnerFixtures.profile
            )
        #expect(await environment.medicineAssessmentRunner.start(invocation))
        #expect(await recognizer.callCount == 1)
        #expect(await backend.requests.count == 1)
        #expect(await waitForGate(environment.companion, state: .result))
    }

    @Test func startRejectsNilAndAnInvocationWithAnInvalidatedGateLease()
        async throws
    {
        let backend = ControlledMedicineBackend(plans: [.resolved])
        let recognizer = CountingMedicineRecognizer()
        let (runner, session) = try await makeRunner(
            backend: backend, recognizer: recognizer
        )

        #expect(await runner.start(nil) == false)
        let invocation = try makeAssessmentInvocation(runner)
        session.reconsiderMedicineChoice()
        #expect(await runner.start(invocation) == false)

        #expect(await recognizer.callCount == 0)
        #expect(await backend.requests.isEmpty)
    }

    @Test func captureSubmitterHandsProvidersAndImageToOneCanonicalOCR()
        async throws
    {
        let backend = ControlledMedicineBackend(plans: [.resolved])
        let recognizer = CountingMedicineRecognizer()
        let (runner, _) = try await makeRunner(
            backend: backend, recognizer: recognizer
        )
        let input = OCRImageInput(
            data: Data([0xA3, 0x01]),
            orientation: .leftMirrored,
            capturedAt: Date(timeIntervalSince1970: 987)
        )
        let record = MedicationRecord(
            id: UUID(), medicineID: "provider-record",
            activeIngredientIDs: ["provider-ingredient"],
            recordedAt: RunnerFixtures.date,
            eventType: .confirmedIntake, source: .manualEntry
        )
        var profileCalls = 0
        var recordCalls = 0
        let submitter = MedicineAssessmentCaptureSubmitter(
            runner: runner,
            userHealthProfileProvider: {
                profileCalls += 1
                return RunnerFixtures.profile
            },
            medicationRecordsProvider: {
                recordCalls += 1
                return [record]
            }
        )
        let viewModel = MedicineCaptureViewModel(processor: submitter)

        viewModel.capture(
            imageData: input.data,
            orientation: input.orientation,
            capturedAt: input.capturedAt
        )
        #expect(await waitForCaptureSubmission(viewModel))
        await backend.waitForAssessments(1)

        #expect(await recognizer.callCount == 1)
        #expect(await recognizer.inputs == [input])
        #expect(profileCalls == 1)
        #expect(recordCalls == 1)
        #expect(await backend.requests.first?.userProfile.id == RunnerFixtures.profile.id)
        #expect(await backend.requests.first?.recentRecords.map(\.id) == [record.id])
        #expect(viewModel.assessmentSubmissionStatus == .submitted)
        guard case .recognizing = viewModel.state else {
            Issue.record("canonical handoff must not publish Capture success")
            return
        }
    }

    @Test func submitterRejectsUnavailableGateBeforeOCR() async throws {
        let backend = ControlledMedicineBackend(plans: [.resolved])
        let recognizer = CountingMedicineRecognizer()
        let (runner, session) = try await makeRunner(
            backend: backend, recognizer: recognizer
        )
        let submitter = MedicineAssessmentCaptureSubmitter(
            runner: runner,
            userHealthProfileProvider: { RunnerFixtures.profile },
            medicationRecordsProvider: { [] }
        )
        session.reconsiderMedicineChoice()

        do {
            _ = try await submitter.process(RunnerFixtures.image)
            Issue.record("expected assessment gate rejection")
        } catch let failure as MedicineCaptureProcessingFailure {
            #expect(failure == .assessmentGateUnavailable)
        }

        #expect(await recognizer.callCount == 0)
        #expect(await backend.requests.isEmpty)
    }

    @Test func submitterReportsRunnerRejectionWhenItsGateLeaseExpires()
        async throws
    {
        let backend = ControlledMedicineBackend(
            plans: [.resolved], blockedAssessmentCalls: [1]
        )
        let recognizer = CountingMedicineRecognizer()
        let (runner, session) = try await makeRunner(
            backend: backend, recognizer: recognizer
        )
        let firstInvocation = try makeAssessmentInvocation(runner)
        let first = Task { await runner.start(firstInvocation) }
        await backend.waitForAssessments(1)
        let stop = Task { await runner.stop() }
        let providerEntered = MainActorEntryFlag()
        let submitter = MedicineAssessmentCaptureSubmitter(
            runner: runner,
            userHealthProfileProvider: {
                providerEntered.value = true
                return RunnerFixtures.profile
            },
            medicationRecordsProvider: { [] }
        )
        let queued = Task { try await submitter.process(RunnerFixtures.image) }
        #expect(await waitForEntry(providerEntered))

        _ = try replaceAssessmentGate(in: session, candidateAt: 1)
        await backend.releaseAssessment(1)
        await stop.value
        _ = await first.value

        guard case .failure(let error) = await queued.result else {
            Issue.record("runner rejection must not report submission success")
            return
        }
        #expect(
            error as? MedicineCaptureProcessingFailure
                == .assessmentSubmissionRejected
        )
        #expect(await recognizer.callCount == 1)
    }

    @Test func explicitSubmitterCancelJoinsRunnerStopBeforeReturning() async throws {
        let backend = ControlledMedicineBackend(
            plans: [.resolved, .resolved], blockedAssessmentCalls: [1]
        )
        let (runner, _) = try await makeRunner(backend: backend)
        let submitter = MedicineAssessmentCaptureSubmitter(
            runner: runner,
            userHealthProfileProvider: { RunnerFixtures.profile },
            medicationRecordsProvider: { [] }
        )
        #expect(
            try await submitter.process(RunnerFixtures.image)
                == .submittedForAssessment
        )
        await backend.waitForAssessments(1)

        let cancellation = Task { await submitter.cancel() }
        await backend.releaseAssessment(1)
        await cancellation.value
        #expect(await backend.completedAssessmentCount == 1)
        #expect(
            try await submitter.process(RunnerFixtures.image)
                == .submittedForAssessment
        )
        await backend.waitForAssessments(2)
        #expect(await backend.completedAssessmentCount == 2)
    }

    @Test func replacementStartCancelsAndJoinsPredecessorBeforeStartingNext()
        async throws
    {
        let backend = ControlledMedicineBackend(
            plans: [.resolved, .resolved],
            blockedAssessmentCalls: [1]
        )
        let (runner, session) = try await makeRunner(backend: backend)
        let firstInvocation = try makeAssessmentInvocation(runner)
        let first = Task { await runner.start(firstInvocation) }
        await backend.waitForAssessments(1)

        let secondInvocation = try makeAssessmentInvocation(runner)
        let second = Task { await runner.start(secondInvocation) }
        await repeatedlyYield()
        #expect(await backend.requests.count == 1)

        await backend.releaseAssessment(1)
        _ = await second.value
        _ = await first.value

        #expect(await backend.requests.count == 2)
        #expect(await waitForGate(session, state: .result))
        #expect(session.assessmentGate?.latestUpdate?.sequenceNumber == 4)
    }

    @Test func stopDoesNotReturnBeforeCancelledOperationHasExited() async throws {
        let backend = ControlledMedicineBackend(
            plans: [.resolved], blockedAssessmentCalls: [1]
        )
        let (runner, _) = try await makeRunner(backend: backend)
        let invocation = try makeAssessmentInvocation(runner)
        let start = Task { await runner.start(invocation) }
        await backend.waitForAssessments(1)
        let stopped = CompletionFlag()
        let stop = Task {
            await runner.stop()
            await stopped.markComplete()
        }

        await repeatedlyYield()
        #expect(await stopped.isComplete == false)
        #expect(await backend.completedAssessmentCount == 0)

        await backend.releaseAssessment(1)
        await stop.value
        _ = await start.value
        #expect(await stopped.isComplete)
        #expect(await backend.completedAssessmentCount == 1)
    }

    @Test func stopReturnsOnlyAfterCoordinatorResetIsPublished() async throws {
        let backend = ControlledMedicineBackend(plans: [.resolved, .resolved])
        let (runner, session) = try await makeRunner(backend: backend)
        await runner.start(try makeAssessmentInvocation(runner))
        #expect(await waitForGate(session, state: .result))

        await runner.stop()
        #expect(await runner.start(try makeAssessmentInvocation(runner)))
        #expect(await waitForGate(session, state: .result))

        #expect(session.assessmentGate?.latestUpdate?.sequenceNumber == 5)
    }

    @Test func consecutiveStopsShareOneStoppingBarrierAndOneReset() async throws {
        let backend = ControlledMedicineBackend(
            plans: [.resolved, .resolved], blockedAssessmentCalls: [1]
        )
        let (runner, session) = try await makeRunner(backend: backend)
        let invocation = try makeAssessmentInvocation(runner)
        let start = Task { await runner.start(invocation) }
        await backend.waitForAssessments(1)

        async let firstStop: Void = runner.stop()
        async let secondStop: Void = runner.stop()
        await repeatedlyYield()
        await backend.releaseAssessment(1)
        _ = await (firstStop, secondStop)
        _ = await start.value

        #expect(await runner.start(try makeAssessmentInvocation(runner)))
        #expect(await waitForGate(session, state: .result))
        #expect(session.assessmentGate?.latestUpdate?.sequenceNumber == 5)
    }

    @Test func startDuringStopWaitsForBarrierBeforeResetAndAssessment()
        async throws
    {
        let backend = ControlledMedicineBackend(
            plans: [.resolved, .resolved], blockedAssessmentCalls: [1]
        )
        let (runner, session) = try await makeRunner(backend: backend)
        let firstInvocation = try makeAssessmentInvocation(runner)
        let first = Task { await runner.start(firstInvocation) }
        await backend.waitForAssessments(1)
        let stop = Task { await runner.stop() }
        let replacementInvocation = try makeAssessmentInvocation(runner)
        let replacement = Task { await runner.start(replacementInvocation) }

        await repeatedlyYield()
        #expect(await backend.requests.count == 1)
        await backend.releaseAssessment(1)
        _ = await replacement.value
        await stop.value
        _ = await first.value

        #expect(await backend.requests.count == 2)
        #expect(await waitForGate(session, state: .result))
        #expect(session.assessmentGate?.latestUpdate?.sequenceNumber == 5)
    }

    @Test func cancelledPredecessorLateResultNeverReachesCompanion() async throws {
        let backend = ControlledMedicineBackend(
            plans: [.resolved, .resolved], blockedAssessmentCalls: [1]
        )
        let (runner, session) = try await makeRunner(backend: backend)
        let firstInvocation = try makeAssessmentInvocation(runner)
        let first = Task { await runner.start(firstInvocation) }
        await backend.waitForAssessments(1)
        let replacementInvocation = try makeAssessmentInvocation(runner)
        let replacement = Task { await runner.start(replacementInvocation) }
        await backend.releaseAssessment(1)
        _ = await replacement.value
        _ = await first.value

        let requests = await backend.requests
        #expect(requests.count == 2)
        #expect(await waitForGate(session, state: .result))
        guard requests.count == 2 else { return }
        guard case .result(let result) = session.assessmentGate?.assessmentState else {
            Issue.record("Expected the replacement result.")
            return
        }
        #expect(result.response.requestID == requests[1].requestID)
        #expect(result.response.requestID != requests[0].requestID)
    }

    @Test func oldOperationGenerationIsRejectedAfterReplacement() async throws {
        let backend = ControlledMedicineBackend(
            plans: [.resolved, .resolved], blockedAssessmentCalls: [1]
        )
        let (runner, session) = try await makeRunner(backend: backend)
        let firstInvocation = try makeAssessmentInvocation(runner)
        let first = Task { await runner.start(firstInvocation) }
        await backend.waitForAssessments(1)
        let replacementInvocation = try makeAssessmentInvocation(runner)
        let replacement = Task { await runner.start(replacementInvocation) }
        await backend.releaseAssessment(1)
        _ = await replacement.value
        _ = await first.value

        #expect(await waitForGate(session, state: .result))
        #expect(session.assessmentGate?.latestUpdate?.sequenceNumber == 4)
        #expect(session.assessmentGate?.assessmentState.isResult == true)
    }

    @Test func updateAboveExpectedGenerationIsRejectedRatherThanAdopted()
        async throws
    {
        let backend = ControlledMedicineBackend(plans: [.resolved])
        let (session, _) = await sessionAtAssessmentGate()
        let coordinator = MedicineAssessmentCoordinator(
            recognizer: StaticMedicineRecognizer(),
            mapper: MedicineRecognitionInputMapper(
                configuration: try MedicineRecognitionMappingConfiguration(
                    minimumConfidence: 0.5,
                    lowConfidenceHandling: .discard
                )
            ),
            requester: backend,
            confirmer: backend,
            clock: AppFixedClock(fixedDate: RunnerFixtures.date)
        )
        let runner = MedicineAssessmentRunner(
            session: session,
            coordinator: coordinator
        )
        #expect(await runner.start(try makeAssessmentInvocation(runner)))
        #expect(await waitForGate(session, state: .result))
        let accepted = try #require(session.assessmentGate?.latestUpdate)
        #expect(accepted.sequenceNumber == 2)

        await coordinator.reset()
        await repeatedlyYield()

        #expect(await coordinator.currentStateUpdate.sequenceNumber == 3)
        #expect(session.assessmentGate?.latestUpdate == accepted)
    }

    @Test func mismatchedResponseRequestIDIsRejected() async throws {
        let backend = ControlledMedicineBackend(
            plans: [.mismatchedResponse(RunnerFixtures.foreignRequestID)]
        )
        let (runner, session) = try await makeRunner(backend: backend)

        await runner.start(try makeAssessmentInvocation(runner))
        await repeatedlyYield()

        #expect(session.assessmentGate?.assessmentState.isAssessing == true)
        #expect(session.assessmentGate?.assessmentState.isResult == false)
    }

    @Test func mismatchedFailureRequestIDIsRejected() async throws {
        let backend = ControlledMedicineBackend(
            plans: [.failure(RunnerFixtures.foreignRequestID)]
        )
        let (runner, session) = try await makeRunner(backend: backend)

        await runner.start(try makeAssessmentInvocation(runner))
        await repeatedlyYield()

        #expect(session.assessmentGate?.assessmentState.isAssessing == true)
        #expect(session.assessmentGate?.assessmentState.isFailure == false)
    }

    @Test func currentAmbiguousResponseCandidateCanBeConfirmed() async throws {
        let backend = ControlledMedicineBackend(plans: [.ambiguous([RunnerFixtures.candidateA])])
        let (runner, session) = try await makeRunner(backend: backend)
        await runner.start(try makeAssessmentInvocation(runner))
        #expect(await waitForGate(session, state: .confirmation))
        #expect(session.assessmentGate?.assessmentState.isResult == false)

        let confirmation = try makeConfirmationInvocation(
            runner, candidate: RunnerFixtures.candidateA
        )
        let accepted = await runner.confirmMedicine(confirmation)

        #expect(accepted)
        #expect(await waitForGate(session, state: .result))
        #expect(session.assessmentGate?.latestUpdate?.sequenceNumber == 3)
    }

    @Test func currentUnresolvedResponseCandidateCanBeConfirmed() async throws {
        let backend = ControlledMedicineBackend(plans: [.unresolved([RunnerFixtures.candidateA])])
        let (runner, session) = try await makeRunner(backend: backend)
        await runner.start(try makeAssessmentInvocation(runner))
        #expect(await waitForGate(session, state: .confirmation))

        #expect(
            await runner.confirmMedicine(
                try makeConfirmationInvocation(
                    runner, candidate: RunnerFixtures.candidateA
                )
            )
        )
        #expect(await waitForGate(session, state: .result))
    }

    @Test func candidateOutsideCurrentResponseIsRejected() async throws {
        let backend = ControlledMedicineBackend(plans: [.ambiguous([RunnerFixtures.candidateA])])
        let (runner, session) = try await makeRunner(backend: backend)
        await runner.start(try makeAssessmentInvocation(runner))
        #expect(await waitForGate(session, state: .confirmation))

        #expect(
            await runner.confirmMedicine(
                try makeConfirmationInvocation(
                    runner, candidate: RunnerFixtures.candidateB
                )
            ) == false
        )
        #expect(await backend.confirmationCommands.isEmpty)
    }

    @Test func candidateFromOldResponseIsRejectedInNewContext() async throws {
        let backend = ControlledMedicineBackend(
            plans: [
                .ambiguous([RunnerFixtures.candidateA]),
                .ambiguous([RunnerFixtures.candidateB]),
            ]
        )
        let (runner, session) = try await makeRunner(backend: backend)
        await runner.start(try makeAssessmentInvocation(runner))
        await runner.start(try makeAssessmentInvocation(runner))
        #expect(await waitForGate(session, state: .confirmation))

        #expect(
            await runner.confirmMedicine(
                try makeConfirmationInvocation(
                    runner, candidate: RunnerFixtures.candidateA
                )
            ) == false
        )
        #expect(await backend.confirmationCommands.isEmpty)
    }

    @Test func sameNameWithDifferentMedicineIdentityIsRejected() async throws {
        let backend = ControlledMedicineBackend(plans: [.ambiguous([RunnerFixtures.candidateA])])
        let (runner, session) = try await makeRunner(backend: backend)
        await runner.start(try makeAssessmentInvocation(runner))
        #expect(await waitForGate(session, state: .confirmation))

        #expect(
            await runner.confirmMedicine(
                try makeConfirmationInvocation(
                    runner,
                    candidate: RunnerFixtures.sameNameDifferentIdentity
                )
            ) == false
        )
        #expect(await backend.confirmationCommands.isEmpty)
    }

    @Test func sameCandidateIDWithDifferentCanonicalIdentityIsRejected()
        async throws
    {
        let backend = ControlledMedicineBackend(plans: [.ambiguous([RunnerFixtures.candidateA])])
        let (runner, session) = try await makeRunner(backend: backend)
        await runner.start(try makeAssessmentInvocation(runner))
        #expect(await waitForGate(session, state: .confirmation))

        #expect(
            await runner.confirmMedicine(
                try makeConfirmationInvocation(
                    runner,
                    candidate: RunnerFixtures.sameIDDifferentIdentity
                )
            ) == false
        )
        #expect(await backend.confirmationCommands.isEmpty)
    }

    @Test func confirmationPreservesPendingContextAndUsesExactGPlusOne()
        async throws
    {
        let backend = ControlledMedicineBackend(plans: [.ambiguous([RunnerFixtures.candidateA])])
        let (runner, session) = try await makeRunner(backend: backend)
        await runner.start(try makeAssessmentInvocation(runner))
        #expect(await waitForGate(session, state: .confirmation))
        let before = session.assessmentGate?.latestUpdate?.sequenceNumber

        #expect(
            await runner.confirmMedicine(
                try makeConfirmationInvocation(
                    runner, candidate: RunnerFixtures.candidateA
                )
            )
        )
        #expect(await waitForGate(session, state: .result))

        #expect(before == 2)
        #expect(session.assessmentGate?.latestUpdate?.sequenceNumber == 3)
    }

    @Test func confirmationReusesOriginalAssessmentRequestID() async throws {
        let backend = ControlledMedicineBackend(plans: [.ambiguous([RunnerFixtures.candidateA])])
        let (runner, session) = try await makeRunner(backend: backend)
        await runner.start(try makeAssessmentInvocation(runner))
        #expect(await waitForGate(session, state: .confirmation))
        let originalID = await backend.requests.first?.requestID

        #expect(
            await runner.confirmMedicine(
                try makeConfirmationInvocation(
                    runner, candidate: RunnerFixtures.candidateA
                )
            )
        )
        guard case .result(let result) = session.assessmentGate?.assessmentState else {
            Issue.record("Expected confirmed result.")
            return
        }
        #expect(await backend.confirmationCommands.first?.originalRequestID == originalID)
        #expect(result.response.requestID == originalID)
    }

    @Test func completedConfirmationDoesNotRetainCandidateContext() async throws {
        let backend = ControlledMedicineBackend(plans: [.ambiguous([RunnerFixtures.candidateA])])
        let (runner, session) = try await makeRunner(backend: backend)
        await runner.start(try makeAssessmentInvocation(runner))
        #expect(await waitForGate(session, state: .confirmation))

        let confirmation = try makeConfirmationInvocation(
            runner, candidate: RunnerFixtures.candidateA
        )
        #expect(await runner.confirmMedicine(confirmation))
        #expect(
            await runner.confirmMedicine(
                runner.makeConfirmationInvocation(RunnerFixtures.candidateA)
            ) == false
        )
        #expect(await backend.confirmationCommands.count == 1)
    }

    @Test func blockedGateAUpdateCannotEnterReplacementGate() async throws {
        try await verifyBlockedGateReplacement(at: 1)
    }

    @Test func sameCandidateRebuildStillMintsANewLease() async throws {
        try await verifyBlockedGateReplacement(at: 0)
    }

    @Test func invalidTransitionDoesNotRevokeCurrentGateLease() async throws {
        let (runner, session) = try await makeRunner(
            backend: ControlledMedicineBackend(plans: [.resolved])
        )
        _ = runner
        let lease = try #require(session.currentAssessmentGateLease)

        #expect(session.startCompanion() == false)
        #expect(session.currentAssessmentGateLease == lease)
    }

    @Test func staleConfirmationGPlusOneCannotEnterReplacementGate() async throws {
        let backend = ControlledMedicineBackend(
            plans: [.ambiguous([RunnerFixtures.candidateA])],
            blockedConfirmationCalls: [1]
        )
        let (runner, session) = try await makeRunner(backend: backend)
        await runner.start(try makeAssessmentInvocation(runner))
        #expect(await waitForGate(session, state: .confirmation))
        let invocation = try makeConfirmationInvocation(
            runner, candidate: RunnerFixtures.candidateA
        )
        let confirmation = Task { await runner.confirmMedicine(invocation) }
        await backend.waitForConfirmations(1)

        let leases = try replaceAssessmentGate(
            in: session,
            candidateAt: 1
        )
        #expect(leases.old != leases.new)
        let stop = Task { await runner.stop() }
        await backend.releaseConfirmation(1)
        await stop.value
        _ = await confirmation.value

        #expect(session.assessmentGate?.latestUpdate == nil)
        #expect(session.canDepart == false)
        #expect(session.canCompleteMedicineCheck == false)
    }

    @Test func replacementStartWaitsForInvalidatedGateStop() async throws {
        let backend = ControlledMedicineBackend(
            plans: [.resolved, .resolved], blockedAssessmentCalls: [1]
        )
        let (runner, session) = try await makeRunner(backend: backend)
        let firstInvocation = try makeAssessmentInvocation(runner)
        let first = Task { await runner.start(firstInvocation) }
        await backend.waitForAssessments(1)
        _ = try replaceAssessmentGate(
            in: session,
            candidateAt: 1
        )
        let replacementInvocation = try makeAssessmentInvocation(runner)
        let replacement = Task { await runner.start(replacementInvocation) }

        await repeatedlyYield()
        #expect(await backend.requests.count == 1)
        await backend.releaseAssessment(1)
        _ = await replacement.value
        _ = await first.value

        let requests = await backend.requests
        #expect(requests.count == 2)
        guard case .result(let result) = session.assessmentGate?.assessmentState,
              requests.count == 2 else {
            Issue.record("Expected only the replacement result in gate B.")
            return
        }
        #expect(result.response.requestID == requests[1].requestID)
        #expect(session.assessmentGate?.latestUpdate?.sequenceNumber == 5)
    }

    @Test func queuedStaleStartCannotBorrowReplacementGateLease() async throws {
        try await verifyQueuedStaleStart(
            gateACandidateIndex: 1,
            gateBCandidateIndex: 0
        )
    }

    @Test func sameCandidateQueuedStaleStartCannotBorrowNewLease() async throws {
        try await verifyQueuedStaleStart(
            gateACandidateIndex: 0,
            gateBCandidateIndex: 0
        )
    }

    @Test func queuedStaleConfirmationCannotEnterReplacementGate() async throws {
        let backend = ControlledMedicineBackend(
            plans: [.ambiguous([RunnerFixtures.candidateA])],
            blockedConfirmationCalls: [1]
        )
        let (runner, session) = try await makeRunner(backend: backend)
        await runner.start(try makeAssessmentInvocation(runner))
        #expect(await waitForGate(session, state: .confirmation))
        let firstInvocation = try makeConfirmationInvocation(
            runner, candidate: RunnerFixtures.candidateA
        )
        let staleInvocation = try makeConfirmationInvocation(
            runner, candidate: RunnerFixtures.candidateA
        )
        let first = Task { await runner.confirmMedicine(firstInvocation) }
        await backend.waitForConfirmations(1)

        let stopEntered = MainActorEntryFlag()
        let stop = Task { @MainActor in
            stopEntered.value = true
            await runner.stop()
        }
        #expect(await waitForEntry(stopEntered))
        let queuedEntered = MainActorEntryFlag()
        let queued = Task { @MainActor in
            queuedEntered.value = true
            return await runner.confirmMedicine(staleInvocation)
        }
        #expect(await waitForEntry(queuedEntered))

        let leases = try replaceAssessmentGate(in: session, candidateAt: 1)
        #expect(leases.old != leases.new)
        await backend.releaseConfirmation(1)
        await stop.value
        _ = await first.value
        #expect(await queued.value == false)

        #expect(await backend.confirmationCommands.count == 1)
        #expect(session.assessmentGate?.latestUpdate == nil)
        #expect(session.assessmentGate?.assessmentState.isResult == false)
        #expect(session.canDepart == false)
        #expect(session.canCompleteMedicineCheck == false)
    }

    @Test func validQueuedStartContinuesWhenLeaseDoesNotChange() async throws {
        try await verifyValidQueuedStart(rejectTransition: false)
    }

    @Test func rejectedTransitionPreservesValidQueuedStart() async throws {
        try await verifyValidQueuedStart(rejectTransition: true)
    }

    @Test func appEnvironmentProvidesProductionDemoHealthContext() {
        let environment = AppEnvironment(
            clock: AppFixedClock(fixedDate: RunnerFixtures.date)
        )

        #expect(
            environment.currentUserHealthProfile.id.uuidString
                == "10000000-0000-0000-0000-000000000001"
        )
        #expect(environment.currentUserHealthProfile.age == 72)
        #expect(environment.currentMedicationRecords.isEmpty)
    }

    @Test func productionCaptureAndEnvironmentStopShareCanonicalRunnerLifecycle()
        async throws
    {
        let backend = ControlledMedicineBackend(
            plans: [.resolved], blockedAssessmentCalls: [1]
        )
        let recognizer = CountingMedicineRecognizer()
        let record = RunnerFixtures.medicationRecord
        let environment = makeProductionEnvironment(
            backend: backend,
            recognizer: recognizer,
            medicationRecords: [record]
        )
        try await enterProductionAssessmentGate(environment.companion)
        let gateLease = try #require(
            environment.companion.currentAssessmentGateLease
        )
        let closed = MainActorSignal()
        let viewModel = environment.makeMedicineCaptureViewModel {
            closed.signal()
        }
        let input = OCRImageInput(
            data: Data("production-photo".utf8),
            orientation: .downMirrored,
            capturedAt: RunnerFixtures.date
        )

        viewModel.capture(
            imageData: input.data,
            orientation: input.orientation,
            capturedAt: input.capturedAt
        )
        await closed.wait()
        await backend.waitForAssessments(1)

        #expect(viewModel.assessmentSubmissionStatus == .submitted)
        #expect(closed.count == 1)
        #expect(await recognizer.callCount == 1)
        #expect(await recognizer.inputs == [input])
        #expect(await backend.requests.first?.userProfile.id == RunnerFixtures.profile.id)
        #expect(await backend.requests.first?.recentRecords.map(\.id) == [record.id])
        guard case let .awaitingMedicineAssessment(gate) = environment.companion.state else {
            Issue.record("accepted handoff must reveal the canonical assessment page")
            return
        }
        #expect(gate.assessmentState.isResult == false)
        #expect(environment.companion.canDepart == false)
        #expect(environment.companion.canCompleteMedicineCheck == false)
        #expect(environment.careRecords.events.contains { event in
            if case .careActionShown = event.kind { return true }
            return false
        } == false)
        #expect(environment.careRecords.events.contains { event in
            if case .medicineConfirmed = event.kind { return true }
            return false
        } == false)

        await viewModel.dismiss()
        await viewModel.dismiss()
        #expect(await backend.completedAssessmentCount == 0)

        let stopEntered = MainActorEntryFlag()
        let stopCompleted = CompletionFlag()
        let stop = Task { @MainActor in
            stopEntered.value = true
            await environment.medicineAssessmentRunner.stop()
            await stopCompleted.markComplete()
        }
        #expect(await waitForEntry(stopEntered))
        await repeatedlyYield()

        #expect(await stopCompleted.isComplete == false)
        #expect(await recognizer.callCount == 1)
        #expect(await backend.requests.count == 1)
        #expect(environment.companion.currentAssessmentGateLease == gateLease)

        await backend.releaseAssessment(1)
        await stop.value

        #expect(await stopCompleted.isComplete)
        #expect(await backend.completedAssessmentCount == 1)
        #expect(await recognizer.callCount == 1)
        #expect(await backend.requests.count == 1)
        #expect(environment.companion.currentAssessmentGateLease == gateLease)
    }

    @Test func productionCameraUsesTheSameCanonicalSubmitterAndOneOCR()
        async throws
    {
        let backend = ControlledMedicineBackend(
            plans: [.resolved], blockedAssessmentCalls: [1]
        )
        let recognizer = CountingMedicineRecognizer()
        let environment = makeProductionEnvironment(
            backend: backend, recognizer: recognizer
        )
        try await enterProductionAssessmentGate(environment.companion)
        let closed = MainActorSignal()
        let cameraInput = OCRImageInput(
            data: Data("production-camera".utf8),
            orientation: .left,
            capturedAt: RunnerFixtures.date
        )
        let camera = ImmediateCameraCaptureService(input: cameraInput)
        let viewModel = environment.makeMedicineCaptureViewModel(
            captureService: camera,
            onAssessmentSubmissionAccepted: { closed.signal() }
        )

        viewModel.capturePhoto()
        await closed.wait()
        await backend.waitForAssessments(1)

        #expect(await recognizer.callCount == 1)
        #expect(await recognizer.inputs == [cameraInput])
        #expect(await backend.requests.count == 1)
        #expect(closed.count == 1)

        await viewModel.dismiss()
        await backend.releaseAssessment(1)
        await environment.medicineAssessmentRunner.stop()
    }

    @Test func productionGateRejectionKeepsCaptureOpenWithStableFailure()
        async throws
    {
        let backend = ControlledMedicineBackend(plans: [.resolved])
        let recognizer = CountingMedicineRecognizer()
        let environment = makeProductionEnvironment(
            backend: backend, recognizer: recognizer
        )
        try await enterProductionAssessmentGate(environment.companion)
        environment.companion.endEarly()
        let closed = MainActorSignal()
        let viewModel = environment.makeMedicineCaptureViewModel {
            closed.signal()
        }

        viewModel.capture(
            imageData: Data("rejected".utf8),
            orientation: .up,
            capturedAt: RunnerFixtures.date
        )
        let failure = await captureFailure(from: viewModel)

        #expect(failure == .assessmentGateUnavailable)
        #expect(closed.count == 0)
        #expect(await recognizer.callCount == 0)
        #expect(await backend.requests.isEmpty)
        guard case .recognizing = viewModel.state else {
            Issue.record("submission rejection must not publish capture success")
            return
        }

        await viewModel.dismiss()
    }

    @Test func productionReplacementJoinsOldOCRAndOnlyLatestInputCloses()
        async throws
    {
        let backend = ControlledMedicineBackend(
            plans: [.resolved, .resolved], blockedAssessmentCalls: [1, 2]
        )
        let recognizer = CountingMedicineRecognizer()
        let environment = makeProductionEnvironment(
            backend: backend, recognizer: recognizer
        )
        try await enterProductionAssessmentGate(environment.companion)
        let activeInvocation = try #require(
            environment.medicineAssessmentRunner.makeAssessmentInvocation(
                imageInput: RunnerFixtures.image,
                userProfile: RunnerFixtures.profile
            )
        )
        let active = Task {
            await environment.medicineAssessmentRunner.start(activeInvocation)
        }
        await backend.waitForAssessments(1)
        let closed = MainActorSignal()
        let viewModel = environment.makeMedicineCaptureViewModel {
            closed.signal()
        }

        viewModel.capture(
            imageData: Data("old".utf8), orientation: .up,
            capturedAt: RunnerFixtures.date
        )
        viewModel.capture(
            imageData: Data("latest".utf8), orientation: .right,
            capturedAt: RunnerFixtures.date
        )
        await backend.releaseAssessment(1)
        _ = await active.value
        await closed.wait()
        await backend.waitForAssessments(2)

        #expect(await recognizer.callCount == 2)
        #expect(await recognizer.inputs.map(\.data) == [
            RunnerFixtures.image.data,
            Data("latest".utf8),
        ])
        #expect(await backend.requests.count == 2)
        #expect(closed.count == 1)
        #expect(viewModel.assessmentSubmissionStatus == .submitted)

        await viewModel.dismiss()
        await backend.releaseAssessment(2)
        await environment.medicineAssessmentRunner.stop()
    }

    @Test func productionUserCancelStopsRunnerWithoutClosingAsAccepted()
        async throws
    {
        let backend = ControlledMedicineBackend(
            plans: [.resolved], blockedAssessmentCalls: [1]
        )
        let recognizer = CountingMedicineRecognizer()
        let environment = makeProductionEnvironment(
            backend: backend, recognizer: recognizer
        )
        try await enterProductionAssessmentGate(environment.companion)
        let activeInvocation = try #require(
            environment.medicineAssessmentRunner.makeAssessmentInvocation(
                imageInput: RunnerFixtures.image,
                userProfile: RunnerFixtures.profile
            )
        )
        let active = Task {
            await environment.medicineAssessmentRunner.start(activeInvocation)
        }
        await backend.waitForAssessments(1)
        let closed = MainActorSignal()
        let viewModel = environment.makeMedicineCaptureViewModel {
            closed.signal()
        }

        viewModel.cancel()
        #expect(viewModel.state == .cancelled)
        await backend.releaseAssessment(1)
        await viewModel.dismiss()
        _ = await active.value

        #expect(closed.count == 0)
        #expect(await backend.requests.count == 1)
        #expect(environment.companion.canDepart == false)
        #expect(environment.companion.canCompleteMedicineCheck == false)
    }
}

@MainActor
private func makeAssessmentInvocation(
    _ runner: MedicineAssessmentRunner,
    imageInput: OCRImageInput = RunnerFixtures.image
) throws -> MedicineAssessmentRunner.AssessmentInvocation {
    try #require(
        runner.makeAssessmentInvocation(
            imageInput: imageInput,
            userProfile: RunnerFixtures.profile
        )
    )
}

@MainActor
private func makeConfirmationInvocation(
    _ runner: MedicineAssessmentRunner,
    candidate: SlowWalkDomain.MedicineCandidate
) throws -> MedicineAssessmentRunner.ConfirmationInvocation {
    try #require(runner.makeConfirmationInvocation(candidate))
}

@MainActor
private func makeRunner(
    backend: ControlledMedicineBackend,
    recognizer: any MedicineTextRecognizing = StaticMedicineRecognizer()
) async throws -> (MedicineAssessmentRunner, CompanionSessionModel) {
    let (session, _) = await sessionAtAssessmentGate()
    let mapping = try MedicineRecognitionMappingConfiguration(
        minimumConfidence: 0.5,
        lowConfidenceHandling: .discard
    )
    return (
        MedicineAssessmentRunner(
            session: session,
            recognizer: recognizer,
            mapper: MedicineRecognitionInputMapper(configuration: mapping),
            requester: backend,
            confirmer: backend,
            clock: AppFixedClock(fixedDate: RunnerFixtures.date)
        ),
        session
    )
}

@MainActor
private func makeProductionEnvironment(
    backend: ControlledMedicineBackend,
    recognizer: any MedicineTextRecognizing,
    medicationRecords: [MedicationRecord] = []
) -> AppEnvironment {
    AppEnvironment(
        clock: AppFixedClock(fixedDate: RunnerFixtures.date),
        plan: .demo,
        simulator: MockMedicineScanSimulator(
            scriptedOutcomes: [
                .findsCandidates(MedicineCandidate.demoCandidates),
            ]
        ),
        readDelay: ImmediateMedicineReadDelay(),
        capabilities: .phase0,
        medicineRecognizer: recognizer,
        medicineRequester: backend,
        medicineConfirmer: backend,
        userHealthProfile: RunnerFixtures.profile,
        medicationRecords: medicationRecords
    )
}

@MainActor
private func enterProductionAssessmentGate(
    _ session: CompanionSessionModel
) async throws {
    try #require(session.startCompanion())
    try #require(session.beginMedicineCaptureAssessment())
    #expect(session.assessmentGate?.preAssessmentSelection == nil)
    try #require(session.currentAssessmentGateLease != nil)
}

@MainActor
private func captureFailure(
    from viewModel: MedicineCaptureViewModel
) async -> MedicineCaptureProcessingFailure {
    for await status in viewModel.$assessmentSubmissionStatus.values {
        if case let .failed(failure) = status { return failure }
    }
    return .processingFailed
}

@MainActor
private struct ImmediateMedicineReadDelay: MedicineReadDelaying {
    func wait() async throws {}
}

@MainActor
private final class MainActorSignal {
    private(set) var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func signal() {
        count += 1
        let ready = waiters.filter { $0.0 <= count }
        waiters.removeAll { $0.0 <= count }
        ready.forEach { $0.1.resume() }
    }

    func wait(for target: Int = 1) async {
        if count >= target { return }
        await withCheckedContinuation { continuation in
            waiters.append((target, continuation))
        }
    }
}

private actor ImmediateCameraCaptureService: CameraCaptureServicing {
    private let input: OCRImageInput

    init(input: OCRImageInput) {
        self.input = input
    }

    func start(sessionID: UUID) async throws {}
    func stop(sessionID: UUID) async {}

    func capturePhoto(
        requestID: UUID,
        orientation: OCRImageOrientation,
        capturedAt: Date
    ) async throws -> CameraCaptureResult {
        CameraCaptureResult(
            imageData: input.data,
            orientation: input.orientation,
            capturedAt: input.capturedAt
        )
    }

    func cancelPendingCapture(requestID: UUID) async {}
}

@MainActor
private func verifyBlockedGateReplacement(
    at replacementIndex: Int
) async throws {
    let backend = ControlledMedicineBackend(
        plans: [.resolved], blockedAssessmentCalls: [1]
    )
    let (runner, session) = try await makeRunner(backend: backend)
    let invocation = try makeAssessmentInvocation(runner)
    let assessment = Task { await runner.start(invocation) }
    await backend.waitForAssessments(1)
    #expect(await waitForGate(session, state: .assessing))
    let staleUpdate = try #require(session.assessmentGate?.latestUpdate)
    let leases = try replaceAssessmentGate(
        in: session, candidateAt: replacementIndex
    )

    #expect(leases.old != leases.new)
    session.applyAssessmentStateUpdate(staleUpdate, forGateLease: leases.old)
    #expect(session.assessmentGate?.latestUpdate == nil)
    let stop = Task { await runner.stop() }
    await backend.releaseAssessment(1)
    await stop.value
    _ = await assessment.value
    #expect(session.assessmentGate?.latestUpdate == nil)
    #expect(session.canDepart == false)
    #expect(session.canCompleteMedicineCheck == false)
}

@MainActor
private func verifyQueuedStaleStart(
    gateACandidateIndex: Int,
    gateBCandidateIndex: Int
) async throws {
    let backend = ControlledMedicineBackend(
        plans: [.resolved], blockedAssessmentCalls: [1]
    )
    let recognizer = CountingMedicineRecognizer()
    let (runner, session) = try await makeRunner(
        backend: backend,
        recognizer: recognizer
    )
    let firstInvocation = try makeAssessmentInvocation(runner)
    let first = Task { await runner.start(firstInvocation) }
    await backend.waitForAssessments(1)

    let gateA = try replaceAssessmentGate(
        in: session, candidateAt: gateACandidateIndex
    )
    let invocationA = try makeAssessmentInvocation(runner)
    let queuedEntered = MainActorEntryFlag()
    let queuedA = Task { @MainActor in
        queuedEntered.value = true
        return await runner.start(invocationA)
    }
    #expect(await waitForEntry(queuedEntered))
    #expect(await backend.requests.count == 1)

    let gateB = try replaceAssessmentGate(
        in: session, candidateAt: gateBCandidateIndex
    )
    #expect(gateA.new == gateB.old)
    #expect(gateA.new != gateB.new)
    await backend.releaseAssessment(1)
    _ = await first.value
    #expect(await queuedA.value == false)

    #expect(await recognizer.callCount == 1)
    #expect(await backend.requests.count == 1)
    #expect(session.assessmentGate?.latestUpdate == nil)
    #expect(session.assessmentGate?.assessmentState == .idle)
    #expect(session.canDepart == false)
    #expect(session.canCompleteMedicineCheck == false)
}

@MainActor
private func verifyValidQueuedStart(
    rejectTransition: Bool
) async throws {
    let backend = ControlledMedicineBackend(
        plans: [.resolved, .resolved], blockedAssessmentCalls: [1]
    )
    let (runner, session) = try await makeRunner(backend: backend)
    let firstInvocation = try makeAssessmentInvocation(runner)
    let first = Task { await runner.start(firstInvocation) }
    await backend.waitForAssessments(1)

    let stopEntered = MainActorEntryFlag()
    let stop = Task { @MainActor in
        stopEntered.value = true
        await runner.stop()
    }
    #expect(await waitForEntry(stopEntered))
    let lease = try #require(session.currentAssessmentGateLease)
    let queuedInvocation = try makeAssessmentInvocation(runner)
    let queuedEntered = MainActorEntryFlag()
    let queued = Task { @MainActor in
        queuedEntered.value = true
        return await runner.start(queuedInvocation)
    }
    #expect(await waitForEntry(queuedEntered))
    #expect(await backend.requests.count == 1)

    if rejectTransition {
        #expect(session.startCompanion() == false)
        #expect(session.currentAssessmentGateLease == lease)
    }
    await backend.releaseAssessment(1)
    await stop.value
    _ = await first.value
    #expect(await queued.value)

    #expect(await backend.requests.count == 2)
    #expect(session.currentAssessmentGateLease == lease)
    #expect(session.assessmentGate?.assessmentState.isResult == true)
    #expect(session.assessmentGate?.latestUpdate?.sequenceNumber == 5)
}

@MainActor
private func replaceAssessmentGate(
    in session: CompanionSessionModel,
    candidateAt index: Int
) throws -> (old: MedicineAssessmentGateLease, new: MedicineAssessmentGateLease) {
    let candidate = MedicineCandidate.demoCandidates[index]
    let old = try #require(session.currentAssessmentGateLease)
    session.reconsiderMedicineChoice()
    session.confirmMedicine(candidate)
    let new = try #require(session.currentAssessmentGateLease)
    return (old, new)
}

@MainActor
private func sessionAtAssessmentGate()
    async -> (CompanionSessionModel, RecordingCareRecordStore)
{
    let delay = ControllableReadDelay()
    let store = RecordingCareRecordStore()
    let session = CompanionSessionModel(
        records: store,
        simulator: SpyScanSimulator(
            scriptedOutcome: .findsCandidates(MedicineCandidate.demoCandidates)
        ),
        plan: .demo,
        readDelay: delay,
        capabilities: .phase0
    )
    session.startCompanion()
    session.beginMedicineRead()
    await delay.waitForInstall()
    delay.release()
    if let task = session.pendingReadTask { await task.value }
    session.confirmMedicine(MedicineCandidate.demoCandidates[0])
    return (session, store)
}

@MainActor
private func waitForGate(
    _ session: CompanionSessionModel,
    state expected: RunnerObservedState
) async -> Bool {
    for _ in 0..<2_000 {
        if RunnerObservedState(session.assessmentGate?.assessmentState) == expected {
            return true
        }
        await Task.yield()
    }
    return false
}

@MainActor
private func waitForCaptureSubmission(
    _ viewModel: MedicineCaptureViewModel
) async -> Bool {
    for await status in viewModel.$assessmentSubmissionStatus.values {
        if status == .submitted { return true }
        if case .failed = status { return false }
    }
    return false
}

@MainActor
private func waitForEntry(_ flag: MainActorEntryFlag) async -> Bool {
    for _ in 0..<2_000 {
        if flag.value { return true }
        await Task.yield()
    }
    return false
}

private func repeatedlyYield() async {
    for _ in 0..<100 { await Task.yield() }
}

private enum RunnerObservedState: Equatable {
    case idle, recognizing, assessing, confirmation, result, failure, cancelled

    init(_ state: MedicineAssessmentViewState?) {
        switch state {
        case .idle, nil: self = .idle
        case .recognizing: self = .recognizing
        case .assessing: self = .assessing
        case .requiresMedicineConfirmation: self = .confirmation
        case .result: self = .result
        case .failed: self = .failure
        case .cancelled: self = .cancelled
        }
    }
}

private extension MedicineAssessmentViewState {
    var isAssessing: Bool {
        if case .assessing = self { return true }
        return false
    }

    var isResult: Bool {
        if case .result = self { return true }
        return false
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

private struct StaticMedicineRecognizer: MedicineTextRecognizing {
    func recognizeText(
        in input: OCRImageInput
    ) async throws -> [RecognizedTextObservation] {
        [
            RecognizedTextObservation(
                text: "Test Medicine",
                confidence: 0.99,
                boundingRegion: nil,
                languageCode: "en",
                observedAt: input.capturedAt
            )
        ]
    }
}

@MainActor
private final class MainActorEntryFlag {
    var value = false
}

private actor CountingMedicineRecognizer: MedicineTextRecognizing {
    private(set) var callCount = 0
    private(set) var inputs: [OCRImageInput] = []

    func recognizeText(
        in input: OCRImageInput
    ) async throws -> [RecognizedTextObservation] {
        callCount += 1
        inputs.append(input)
        return try await StaticMedicineRecognizer().recognizeText(in: input)
    }
}

private actor CompletionFlag {
    private(set) var isComplete = false

    func markComplete() {
        isComplete = true
    }
}

private actor ControlledMedicineBackend:
    MedicineAssessmentRequesting,
    MedicineCandidateConfirming
{
    enum Plan: Sendable {
        case resolved
        case ambiguous([SlowWalkDomain.MedicineCandidate])
        case unresolved([SlowWalkDomain.MedicineCandidate])
        case mismatchedResponse(UUID)
        case failure(UUID)
    }

    private let plans: [Plan]
    private let blockedAssessmentCalls: Set<Int>
    private let blockedConfirmationCalls: Set<Int>
    private var assessmentContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var assessmentWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var confirmationContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var confirmationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var requests: [MedicineAssessmentRequestDTO] = []
    private(set) var confirmationCommands: [MedicineCandidateConfirmationCommand] = []
    private(set) var completedAssessmentCount = 0

    init(
        plans: [Plan],
        blockedAssessmentCalls: Set<Int> = [],
        blockedConfirmationCalls: Set<Int> = []
    ) {
        self.plans = plans
        self.blockedAssessmentCalls = blockedAssessmentCalls
        self.blockedConfirmationCalls = blockedConfirmationCalls
    }

    func assess(
        request: MedicineAssessmentRequestDTO
    ) async throws -> MedicineAssessmentResponseDTO {
        requests.append(request)
        let call = requests.count
        signalAssessmentWaiters()
        if blockedAssessmentCalls.contains(call) {
            await withCheckedContinuation {
                assessmentContinuations[call] = $0
            }
        }
        completedAssessmentCount += 1

        let plan = plans[min(call - 1, plans.count - 1)]
        switch plan {
        case .resolved:
            return RunnerFixtures.response(
                requestID: request.requestID,
                status: .resolved,
                candidates: [RunnerFixtures.candidateA],
                selected: RunnerFixtures.candidateA.medicine
            )
        case .ambiguous(let candidates):
            return RunnerFixtures.response(
                requestID: request.requestID,
                status: .ambiguous,
                candidates: candidates,
                selected: nil
            )
        case .unresolved(let candidates):
            return RunnerFixtures.response(
                requestID: request.requestID,
                status: .notFound,
                candidates: candidates,
                selected: nil
            )
        case .mismatchedResponse(let requestID):
            return RunnerFixtures.response(
                requestID: requestID,
                status: .resolved,
                candidates: [RunnerFixtures.candidateA],
                selected: RunnerFixtures.candidateA.medicine
            )
        case .failure(let requestID):
            throw ClientAPIError(
                error: APIErrorDTO(
                    code: .internalError,
                    message: "Test failure",
                    requestID: requestID,
                    details: nil
                )
            )
        }
    }

    func confirmMedicine(
        command: MedicineCandidateConfirmationCommand
    ) async throws -> MedicineAssessmentResponseDTO {
        confirmationCommands.append(command)
        let call = confirmationCommands.count
        signalConfirmationWaiters()
        if blockedConfirmationCalls.contains(call) {
            await withCheckedContinuation {
                confirmationContinuations[call] = $0
            }
        }
        let candidate = [RunnerFixtures.candidateA, RunnerFixtures.candidateB]
            .first { $0.medicine.id == command.candidateID }
            ?? RunnerFixtures.candidateA
        return RunnerFixtures.response(
            requestID: command.originalRequestID,
            status: .resolved,
            candidates: [candidate],
            selected: candidate.medicine
        )
    }

    func waitForAssessments(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation {
            assessmentWaiters.append((count, $0))
        }
    }

    func releaseAssessment(_ call: Int) {
        let continuation = assessmentContinuations.removeValue(forKey: call)
        continuation?.resume()
    }

    func waitForConfirmations(_ count: Int) async {
        if confirmationCommands.count >= count { return }
        await withCheckedContinuation {
            confirmationWaiters.append((count, $0))
        }
    }

    func releaseConfirmation(_ call: Int) {
        confirmationContinuations.removeValue(forKey: call)?.resume()
    }

    private func signalAssessmentWaiters() {
        let ready = assessmentWaiters.filter { $0.0 <= requests.count }
        assessmentWaiters.removeAll { $0.0 <= requests.count }
        ready.forEach { $0.1.resume() }
    }

    private func signalConfirmationWaiters() {
        let ready = confirmationWaiters.filter {
            $0.0 <= confirmationCommands.count
        }
        confirmationWaiters.removeAll {
            $0.0 <= confirmationCommands.count
        }
        ready.forEach { $0.1.resume() }
    }
}

private enum RunnerFixtures {
    nonisolated static let date = Date(timeIntervalSince1970: 1_753_000_000)
    nonisolated static let foreignRequestID = UUID(
        uuidString: "00000000-0000-0000-0000-0000000000F1"
    )!
    nonisolated static let image = OCRImageInput(
        data: Data([0x01]),
        orientation: .right,
        capturedAt: date
    )
    nonisolated static let profile = UserHealthProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
        age: 70,
        allergies: [],
        diagnosedConditions: [],
        currentMedicineIngredientIDs: [],
        bodyMetrics: nil,
        updatedAt: date
    )
    nonisolated static let medicationRecord = MedicationRecord(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!,
        medicineID: "provider-record",
        activeIngredientIDs: ["provider-ingredient"],
        recordedAt: date,
        eventType: .confirmedIntake,
        source: .demoData
    )

    nonisolated static let candidateA = candidate(
        id: "candidate-a", name: "Shared Name"
    )
    nonisolated static let candidateB = candidate(
        id: "candidate-b", name: "Other Medicine"
    )
    nonisolated static let sameNameDifferentIdentity = candidate(
        id: "candidate-foreign",
        name: "Shared Name"
    )
    nonisolated static let sameIDDifferentIdentity = candidate(
        id: "candidate-a",
        name: "Altered Canonical Identity",
        dataVersion: "foreign-v2"
    )

    nonisolated static func candidate(
        id: String,
        name: String,
        dataVersion: String = "test-v1"
    ) -> SlowWalkDomain.MedicineCandidate {
        SlowWalkDomain.MedicineCandidate(
            medicine: Medicine(
                id: id,
                canonicalName: name,
                aliases: [],
                activeIngredientIDs: [],
                medicineCategory: .other,
                sourceReferences: [],
                dosageTextFromSource: nil,
                contraindicationTags: [],
                dataVersion: dataVersion
            ),
            matchScore: 0.9,
            matchedAlias: nil,
            matchReasons: [.canonicalExact]
        )
    }

    nonisolated static func response(
        requestID: UUID,
        status: MedicineResolutionStatus,
        candidates: [SlowWalkDomain.MedicineCandidate],
        selected: Medicine?
    ) -> MedicineAssessmentResponseDTO {
        let evidence = MedicineResolutionEvidence(
            recognizedTexts: ["Test Medicine"],
            normalizedText: "test medicine",
            normalizedQuery: "test medicine",
            languageCode: "en",
            rawConfidence: 0.99,
            dosageForms: [],
            removedSpecifications: [],
            discardedNoise: [],
            matcherVersion: "test-v1",
            sourceDataVersions: ["test-v1"]
        )
        let resolution = MedicineResolution(
            status: status,
            candidates: candidates,
            selectedMedicine: selected,
            evidence: evidence,
            requiresUserConfirmation: status != .resolved
        )
        let actionCard = ActionCard(
            title: "TEST CARD",
            primaryInstruction: "TEST INSTRUCTION",
            warnings: [],
            recommendedActions: [.consultHealthcareProfessional],
            riskLevel: .yellow,
            sourceReferences: [],
            mustConfirmMedicine: status != .resolved,
            generatedAt: date
        )
        let assessment = selected.map { _ in
            RiskAssessment(
                level: .yellow,
                reasons: [],
                recommendedActions: [.consultHealthcareProfessional],
                assessedAt: date,
                requiresProfessionalAdvice: false,
                requiresFamilyAttention: false,
                evidenceCompleteness: .partial
            )
        }
        return MedicineAssessmentResponseDTO(
            requestID: requestID,
            resolution: resolution,
            assessment: assessment,
            actionCard: actionCard,
            cacheHit: false,
            resolutionCacheStatus: .miss,
            sourceDataVersion: "test-v1",
            generatedAt: date,
            apiVersion: "v1"
        )
    }
}
