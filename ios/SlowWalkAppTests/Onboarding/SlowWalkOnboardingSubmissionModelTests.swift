import Foundation
import SlowWalkDomain
import Testing

@testable import SlowWalkApp

@MainActor private final class ControlledOnboardingCallback {
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Void, Error>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    private(set) var callIDs: [Int] = []
    var callCount: Int { callIDs.count }

    func call() async throws {
        nextID += 1
        let callID = nextID
        callIDs.append(callID)
        let readyWaiters = waiters.filter { $0.0 <= callCount }
        waiters.removeAll { $0.0 <= callCount }
        for (_, continuation) in readyWaiters { continuation.resume() }

        return try await withCheckedThrowingContinuation { continuation in
            pending[callID] = continuation
        }
    }

    func waitForCallCount(_ count: Int) async {
        guard callCount < count else { return }
        await withCheckedContinuation { continuation in waiters.append((count, continuation)) }
    }

    func succeed(_ callID: Int) { pending.removeValue(forKey: callID)?.resume() }

    func fail(_ callID: Int, with error: any Error) {
        pending.removeValue(forKey: callID)?.resume(throwing: error)
    }
}

@MainActor struct SlowWalkOnboardingSubmissionModelTests {
    private enum TestFailure: Error { case unavailable }

    @Test func profileRapidDoubleTapCallsExternalCallbackOnce() async {
        let profile = ControlledOnboardingCallback()
        let model = makeModel(profile: profile)

        #expect(model.start(.profile, draft: Self.draft))
        #expect(model.start(.profile, draft: Self.draft) == false)
        await profile.waitForCallCount(1)
        #expect(profile.callCount == 1)

        profile.succeed(profile.callIDs[0])
        await waitUntil { model.state.isSucceeded(as: .profile) }
    }

    @Test func demoRapidDoubleTapCallsExternalCallbackOnce() async {
        let demo = ControlledOnboardingCallback()
        let model = makeModel(demo: demo)

        #expect(model.start(.demo, draft: Self.draft))
        #expect(model.start(.demo, draft: Self.draft) == false)
        await demo.waitForCallCount(1)
        #expect(demo.callCount == 1)
        #expect(model.state.activeKind == .demo)
        #expect(model.state.activeKind?.loadingText == "正在载入演示资料")

        demo.succeed(demo.callIDs[0])
        await waitUntil { model.state.isSucceeded(as: .demo) }
    }

    @Test func retryRapidDoubleTapKeepsTheOriginalProfileOperation() async {
        let profile = ControlledOnboardingCallback()
        let demo = ControlledOnboardingCallback()
        let model = makeModel(profile: profile, demo: demo)

        #expect(model.start(.profile, draft: Self.draft))
        await profile.waitForCallCount(1)
        profile.fail(profile.callIDs[0], with: TestFailure.unavailable)
        await waitUntil { model.state.failedKind == .profile }

        #expect(model.retry(draft: Self.draft))
        #expect(model.retry(draft: Self.draft) == false)
        await profile.waitForCallCount(2)
        #expect(profile.callCount == 2)
        #expect(demo.callCount == 0)

        profile.succeed(profile.callIDs[1])
        await waitUntil { model.state.isSucceeded(as: .profile) }
    }

    @Test func demoFailureAndRetryRemainDemoOperations() async {
        let profile = ControlledOnboardingCallback()
        let demo = ControlledOnboardingCallback()
        let model = makeModel(profile: profile, demo: demo)

        #expect(model.start(.demo, draft: Self.draft))
        await demo.waitForCallCount(1)
        demo.fail(demo.callIDs[0], with: TestFailure.unavailable)
        await waitUntil { model.state.failedKind == .demo }
        #expect(model.state.failureMessage?.contains("演示资料") == true)

        #expect(model.retry(draft: Self.draft))
        #expect(model.retry(draft: Self.draft) == false)
        await demo.waitForCallCount(2)
        #expect(demo.callCount == 2)
        #expect(profile.callCount == 0)

        demo.succeed(demo.callIDs[1])
        await waitUntil { model.state.isSucceeded(as: .demo) }
    }

    @Test func demoValidationErrorNeverNavigatesToAProfileField() async {
        let demo = ControlledOnboardingCallback()
        let model = makeModel(demo: demo)

        #expect(model.start(.demo, draft: Self.draft))
        await demo.waitForCallCount(1)
        demo.fail(demo.callIDs[0], with: UserProfileValidationIssue.ageOutOfRange)
        await waitUntil { model.state.failedKind == .demo }

        if case .profileValidation = model.state {
            Issue.record("Demo validation error leaked into profile field mapping")
        }
        #expect(model.state.failureMessage?.contains("演示资料") == true)
    }

    @Test func profileValidationErrorKeepsTheTypedDomainIssue() async {
        let profile = ControlledOnboardingCallback()
        let model = makeModel(profile: profile)

        #expect(model.start(.profile, draft: Self.draft))
        await profile.waitForCallCount(1)
        profile.fail(profile.callIDs[0], with: UserProfileValidationIssue.ageOutOfRange)
        await waitUntil {
            if case .profileValidation = model.state { return true }
            return false
        }

        guard case .profileValidation(let issue, _) = model.state else {
            Issue.record("Expected profile validation state")
            return
        }
        #expect(issue == .ageOutOfRange)
    }

    @Test func staleCompletionAfterLeavingCannotChangeState() async {
        let profile = ControlledOnboardingCallback()
        let model = makeModel(profile: profile)

        #expect(model.start(.profile, draft: Self.draft))
        await profile.waitForCallCount(1)
        model.invalidate()
        profile.succeed(profile.callIDs[0])
        await Task.yield()
        await Task.yield()

        #expect(model.state == .idle)
    }

    @Test func inverseCompletionsKeepOnlyTheCurrentOperation() async {
        let profile = ControlledOnboardingCallback()
        let model = makeModel(profile: profile)

        #expect(model.start(.profile, draft: Self.draft))
        await profile.waitForCallCount(1)
        model.invalidate()
        #expect(model.start(.profile, draft: Self.draft))
        await profile.waitForCallCount(2)

        let firstID = profile.callIDs[0]
        let secondID = profile.callIDs[1]
        profile.succeed(secondID)
        await waitUntil { model.state.isSucceeded(as: .profile) }
        let currentState = model.state

        profile.succeed(firstID)
        await Task.yield()
        await Task.yield()
        #expect(model.state == currentState)
    }

    private static let draft = UserProfileDraft(preferredName: "王阿姨", ageText: "68")

    private func makeModel(
        profile: ControlledOnboardingCallback = ControlledOnboardingCallback(),
        demo: ControlledOnboardingCallback = ControlledOnboardingCallback()
    ) -> SlowWalkOnboardingSubmissionModel {
        SlowWalkOnboardingSubmissionModel(
            onSubmit: { _ in try await profile.call() },
            onUseDemoData: { try await demo.call() }
        )
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for onboarding submission state")
    }
}

extension SlowWalkOnboardingSubmissionState {
    fileprivate func isSucceeded(as kind: SlowWalkOnboardingSubmissionKind) -> Bool {
        if case .succeeded(let currentKind, _) = self { return currentKind == kind }
        return false
    }
}
