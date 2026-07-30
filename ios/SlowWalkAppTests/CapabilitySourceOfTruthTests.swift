import Foundation
import Testing
@testable import SlowWalkApp

/// Tests that the capability table is a *single* source of truth.
///
/// The defect these exist to prevent: `CompanionCopy` used to hold a
/// `static let capabilities: CapabilityCatalog = .phase0` while
/// `CompanionSessionModel` took an injected one. Both agreed by default, so
/// nothing looked wrong — but injecting a different table changed what the
/// session *did* while every screen kept describing the shipping build. A person
/// could then be held at a gate whose own badge contradicted the reason they
/// were being held.
///
/// The shape of every test here is the same: assemble an app with a table that
/// is *not* `.phase0`, then check that behaviour and wording moved together. A
/// screen reading a hardcoded `.phase0` fails, because the injected tables are
/// built to be detectable (see `TestCapabilityCatalogs`).
@MainActor
struct CapabilitySourceOfTruthTests {

    // MARK: - Session and wording agree

    /// Session behaviour and view wording come from the same table.
    ///
    /// Requirement 7's first case. The session is driven to the assessment gate
    /// with `allMarked` injected; the wording a view would render must carry that
    /// table's marker. Before the fix this sentence came from `.phase0` while the
    /// session's own `capabilities` was `allMarked`.
    @Test func injectedCatalogDrivesBothBehaviourAndWording() async {
        let session = await Self.sessionAtGate(
            capabilities: TestCapabilityCatalogs.allMarked
        )

        // The session really is running against the injected table...
        #expect(session.capabilities == TestCapabilityCatalogs.allMarked)

        // ...and it acted on it: the missing capability was reported, which is
        // the behaviour half of "behaviour and wording agree".
        #expect(session.assessmentGate?.progress == .couldNotAssess(.notWiredUpYet))

        // The sentence the view shows came from that table, not from `.phase0`.
        #expect(session.situation.contains(TestCapabilityCatalogs.marker))
        #expect(session.situation.contains("下一阶段") == false)
    }

    /// The panel's badge and the session's sentence describe one build.
    ///
    /// `CompanionView` builds the panel's status from `session.capabilities`.
    /// This asserts on that exact value, so a view reverting to a hardcoded table
    /// shows a badge that no longer matches the status asserted here.
    @Test func panelStatusComesFromTheSessionsTable() async {
        let session = await Self.sessionAtGate(
            capabilities: TestCapabilityCatalogs.allMarked
        )

        let status = session.capabilities.status(of: .medicineRiskAssessment)
        #expect(status.detail?.contains(TestCapabilityCatalogs.marker) == true)

        // The badge and the surrounding sentence agree, because both derive from
        // the one table the session holds.
        #expect(session.situation.contains(TestCapabilityCatalogs.marker))
    }

    /// Today's summary describes the same build as the Companion screen.
    ///
    /// Today renders its own sentence through `TodayStatusSummary`. It is a
    /// separate call site, so it is a separate chance to reach for `.phase0`.
    @Test func todaySummaryUsesTheSameTableAsTheSession() async {
        let session = await Self.sessionAtGate(
            capabilities: TestCapabilityCatalogs.allMarked
        )

        let summary = TodayStatusSummary(
            state: session.state,
            capabilities: session.capabilities
        )

        #expect(summary.situation == session.situation)
        #expect(summary.situation.contains(TestCapabilityCatalogs.marker))
    }

    /// The whole app is assembled from one table.
    ///
    /// `AppEnvironment` is the only place a default is chosen. Constructing one
    /// with an injected table must hand that same table to the session, so every
    /// screen reading `environment.capabilities` and every screen reading
    /// `session.capabilities` see the same value.
    @Test func environmentHandsOneTableToEverything() {
        let environment = AppEnvironment(
            clock: AppFixedClock(fixedDate: Date(timeIntervalSince1970: 1_753_000_000)),
            capabilities: TestCapabilityCatalogs.allMarked
        )

        #expect(environment.capabilities == TestCapabilityCatalogs.allMarked)
        // Identity of value, not just of content: the session was given the
        // environment's table rather than constructing its own default.
        #expect(environment.companion.capabilities == environment.capabilities)
    }

    /// The shipping app is assembled from `.phase0`.
    ///
    /// The counterpart to the test above: removing the second source must not
    /// have changed what the real app describes.
    @Test func defaultEnvironmentUsesPhase0() {
        let environment = AppEnvironment(
            clock: AppFixedClock(fixedDate: Date(timeIntervalSince1970: 1_753_000_000))
        )

        #expect(environment.capabilities == .phase0)
        #expect(environment.companion.capabilities == .phase0)
    }

    // MARK: - A capability becoming available changes the wording

    /// When assessment becomes `.deviceLocal`, nothing says "尚未接入".
    ///
    /// Requirement 7's second case. This is the change the next stage will make,
    /// tested now: the badge and its explanation must both stop describing an
    /// unwired capability, without either being edited.
    ///
    /// Note which sentence is checked and why. With the capability marked
    /// available and no adapter behind it, `beginMedicineAssessment()` correctly
    /// declines to report a setback, so the gate stays at `.notStarted` and says
    /// only that it is waiting — see `assessmentAvailableStillCannotDepart`. The
    /// catalog-derived sentence is the one shown when an assessment *was* owed
    /// and could not be produced, so that is the state driven here.
    @Test func deviceLocalAssessmentNoLongerReadsAsNotWiredUp() async {
        let notWiredUp = CapabilityAvailability.unavailable.shortLabel
        let catalog = TestCapabilityCatalogs.assessmentAvailable
        let session = await Self.sessionAtGate(capabilities: catalog)

        let status = catalog.status(of: .medicineRiskAssessment)
        #expect(status.availability == .deviceLocal)
        #expect(status.shortLabel == CapabilityAvailability.deviceLocal.shortLabel)
        #expect(status.shortLabel != notWiredUp)

        // Neither the badge nor its explanation may still say it is missing.
        #expect(status.summaryLine.contains(notWiredUp) == false)
        #expect(status.detail?.contains("尚未接入") == false)

        // While it waits, the gate claims nothing either way.
        #expect(session.situation.contains("尚未接入") == false)
        #expect(session.situation.contains("正在等待正式的用药风险评估"))

        // And the sentence for a setback carries the new explanation, not the
        // "will be wired up later" one.
        let couldNotAssess = CompanionFlowState.awaitingMedicineAssessment(
            MedicineAssessmentGateTests.makeGate(
                progress: .couldNotAssess(.notWiredUpYet)
            )
        )
        let wording = CompanionCopy.situation(
            for: couldNotAssess,
            capabilities: catalog
        )
        #expect(wording.contains("设备内评估已接入"))
        #expect(wording.contains("尚未接入") == false)
        #expect(wording.contains("下一阶段") == false)
    }

    /// The default build still reports the assessment as not wired up.
    ///
    /// Requirement 7's third case, and the guard against the test above being
    /// satisfied by wording that never mentions availability at all.
    @Test func defaultBuildStillReportsAssessmentUnavailable() async {
        let session = await Self.sessionAtGate(capabilities: .phase0)

        let status = session.capabilities.status(of: .medicineRiskAssessment)
        #expect(status.availability == .unavailable)
        #expect(status.shortLabel == "尚未接入")
        #expect(session.situation.contains("尚未完成风险评估"))
        #expect(session.situation.contains("下一阶段"))
        #expect(session.situation.contains("设备内评估已接入") == false)
    }

    /// A table claiming assessment works still cannot open the gate.
    ///
    /// The capability table describes availability; it is not permission. With
    /// `.medicineRiskAssessment` marked `.deviceLocal` but no adapter behind it,
    /// the session must stay held: no result exists, so no departure and no
    /// record of an assessment. This is what stops the single-source refactor
    /// from becoming a way to talk the safety gate open.
    @Test func assessmentAvailableStillCannotDepart() async {
        let (session, store) = await Self.sessionAndStoreAtGate(
            capabilities: TestCapabilityCatalogs.assessmentAvailable
        )

        #expect(session.assessmentGate != nil)
        #expect(session.canDepart == false)
        #expect(session.state != .travelling)

        // No care action was shown, and no assessment outcome was recorded:
        // the gate is simply still waiting.
        let claimsSomething = store.kinds.contains { kind in
            switch kind {
            case .careActionShown, .medicineAssessmentDidNotSucceed: true
            default: false
            }
        }
        #expect(claimsSomething == false)
        #expect(session.assessmentGate?.progress == .notStarted)
    }

    // MARK: - No screen keeps its own table

    /// Production holds exactly one `.phase0`, in the composition root.
    ///
    /// Scans the shipping source rather than trusting the refactor. A view or
    /// model naming `.phase0` again — the failure mode this whole file exists for
    /// — is caught here even if it happens to agree with the environment today.
    ///
    /// Comments are stripped before scanning, and `#Preview` bodies are skipped.
    /// A comment explaining why a screen must *not* hold a catalog is not a
    /// second source of truth, and a preview is a debug harness that assembles
    /// its own throwaway app — the same role `AppEnvironment` plays at runtime.
    @Test func onlyTheCompositionRootNamesPhase0() throws {
        let sources = try Self.productionSwiftSources()
        #expect(sources.isEmpty == false, "no source files were scanned")

        var offenders: [String] = []
        for (path, contents) in sources {
            let isRoot = path.hasSuffix("AppEnvironment.swift")
            var inPreview = false
            for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.contains("#Preview") { inPreview = true }
                guard !inPreview else { continue }

                let code = Self.strippingComment(from: String(line))
                guard code.contains(".phase0") else { continue }
                // The declaration itself, and the composition root's default.
                let isDeclaration = code.contains("static let phase0")
                if !isDeclaration, !isRoot {
                    offenders.append("\(path): \(code.trimmingCharacters(in: .whitespaces))")
                }
            }
        }

        let listed = offenders.joined(separator: "\n")
        #expect(
            offenders.isEmpty,
            """
            `.phase0` may only be named by its declaration and by \
            AppEnvironment. Found:
            \(listed)
            """
        )
    }

    /// No production type keeps a `CapabilityCatalog` of its own.
    ///
    /// The stronger form of the test above: a screen could hold a static catalog
    /// built inline, never naming `.phase0`, and be just as much a second source
    /// of truth. Only `AppEnvironment` and the catalog's own file may declare a
    /// stored or static one.
    @Test func noProductionTypeStoresItsOwnCatalog() throws {
        let sources = try Self.productionSwiftSources()

        var offenders: [String] = []
        for (path, contents) in sources {
            guard !path.hasSuffix("AppEnvironment.swift"),
                  !path.hasSuffix("AppCapability.swift")
            else { continue }

            for line in contents.split(separator: "\n") {
                let trimmed = Self.strippingComment(from: String(line))
                    .trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("static"), trimmed.contains("CapabilityCatalog")
                else { continue }
                offenders.append("\(path): \(trimmed)")
            }
        }

        let listed = offenders.joined(separator: "\n")
        #expect(
            offenders.isEmpty,
            """
            only AppEnvironment may hold a CapabilityCatalog. Found:
            \(listed)
            """
        )
    }

    // MARK: - Fixtures

    /// Reads the shipping app's Swift sources from disk.
    ///
    /// Uses `#filePath` to find the repository, so the scan follows the checkout
    /// rather than a path baked in at build time.
    static func productionSwiftSources() throws -> [(path: String, contents: String)] {
        let testsDirectory = URL(filePath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory
            .deletingLastPathComponent() // SlowWalkAppTests
            .appending(path: "SlowWalkApp")

        let manager = FileManager.default
        guard let walker = manager.enumerator(
            at: appDirectory,
            includingPropertiesForKeys: nil
        ) else {
            throw CapabilityScanError.couldNotEnumerate(appDirectory.path())
        }

        var sources: [(path: String, contents: String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            sources.append((url.path(), try String(contentsOf: url, encoding: .utf8)))
        }
        return sources
    }

    enum CapabilityScanError: Error {
        case couldNotEnumerate(String)
    }

    /// Drops a trailing `//` comment so a line is scanned as code.
    ///
    /// Deliberately simple: it does not understand `//` inside a string literal
    /// or a block comment. Both would make the scan *stricter* than intended
    /// rather than weaker — it would keep scanning text it should have dropped —
    /// so the failure direction is safe. Also used by
    /// `noProductionTypeStoresItsOwnCatalog`.
    static func strippingComment(from line: String) -> String {
        guard let marker = line.range(of: "//") else { return line }
        return String(line[line.startIndex..<marker.lowerBound])
    }

    /// Walks the real flow to the assessment gate with a given capability table.
    static func sessionAndStoreAtGate(
        capabilities: CapabilityCatalog
    ) async -> (CompanionSessionModel, RecordingCareRecordStore) {
        let delay = ControllableReadDelay()
        let store = RecordingCareRecordStore()
        let session = CompanionSessionModel(
            records: store,
            simulator: SpyScanSimulator(
                scriptedOutcome: .findsCandidates(MedicineCandidate.demoCandidates)
            ),
            plan: .demo,
            readDelay: delay,
            capabilities: capabilities
        )

        session.startCompanion()
        session.beginMedicineRead()
        await delay.waitForInstall()
        delay.release()
        if let task = session.pendingReadTask { await task.value }
        session.confirmMedicine(MedicineCandidate.demoCandidates[0])

        return (session, store)
    }

    static func sessionAtGate(
        capabilities: CapabilityCatalog
    ) async -> CompanionSessionModel {
        await sessionAndStoreAtGate(capabilities: capabilities).0
    }
}
