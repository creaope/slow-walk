import Foundation
import SlowWalkDataInterfaces
import SlowWalkDomain
import Testing
@testable import SlowWalkApp

@Suite("UserProfileSession")
@MainActor
struct UserProfileSessionTests {
    @Test func initialStateIsIdle() {
        let session = makeSession(store: UserProfileStoreDouble())

        #expect(session.state == .idle)
    }

    @Test func loadMissingProfileNeedsOnboarding() async {
        let store = UserProfileStoreDouble()
        let session = makeSession(store: store)

        await session.load()

        #expect(session.state == .needsOnboarding)
        #expect(await store.snapshot().loadCallCount == 1)
    }

    @Test func loadValidProfilePublishesExactBundle() async {
        let profile = makeBundle(source: .userEnteredLocal, token: 11)
        let store = UserProfileStoreDouble(loadResult: profile)
        let session = makeSession(store: store)

        await session.load()

        #expect(session.state == .ready(profile))
        #expect(await store.snapshot().loadCallCount == 1)
    }

    @Test func loadInvalidBundleSchemaFailsWithoutSideEffects() async {
        let profile = makeBundle(
            source: .userEnteredLocal,
            token: 12,
            bundleSchemaVersion: 99
        )
        let store = UserProfileStoreDouble(loadResult: profile)

        await confirmation(expectedCount: 0) { uuidConfirmation in
            await confirmation(expectedCount: 0) { clockConfirmation in
                let session = makeSession(
                    store: store,
                    demo: makeBundle(source: .bundledDemo, token: 92),
                    uuidProvider: ConfirmingUUIDProvider(
                        returning: fixedUUID(93),
                        onCall: { uuidConfirmation() }
                    ),
                    clock: ConfirmingClock(
                        returning: Date(timeIntervalSince1970: 9_300),
                        onCall: { clockConfirmation() }
                    )
                )

                await session.load()

                let snapshot = await store.snapshot()
                #expect(session.state == .failed(.invalidStoredProfile))
                #expect(snapshot.loadCallCount == 1)
                #expect(snapshot.saveCallCount == 0)
                #expect(snapshot.deleteCallCount == 0)
            }
        }
    }

    @Test func loadInvalidHealthSchemaFailsWithoutSideEffects() async {
        let profile = makeBundle(
            source: .userEnteredLocal,
            token: 13,
            healthProfileSchemaVersion: 99
        )
        let store = UserProfileStoreDouble(loadResult: profile)

        await confirmation(expectedCount: 0) { uuidConfirmation in
            await confirmation(expectedCount: 0) { clockConfirmation in
                let session = makeSession(
                    store: store,
                    demo: makeBundle(source: .bundledDemo, token: 94),
                    uuidProvider: ConfirmingUUIDProvider(
                        returning: fixedUUID(95),
                        onCall: { uuidConfirmation() }
                    ),
                    clock: ConfirmingClock(
                        returning: Date(timeIntervalSince1970: 9_500),
                        onCall: { clockConfirmation() }
                    )
                )

                await session.load()

                let snapshot = await store.snapshot()
                #expect(session.state == .failed(.invalidStoredProfile))
                #expect(snapshot.loadCallCount == 1)
                #expect(snapshot.saveCallCount == 0)
                #expect(snapshot.deleteCallCount == 0)
            }
        }
    }

    @Test func productionStoreUnsupportedSchemaMapsToInvalidStoredProfile()
        async throws
    {
        let directory = try preparedProfileDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = profileURL(in: directory)
        let sensitiveValues = [
            "SESSION-PRIVATE-NAME-7F31",
            "SESSION-SECRET-MEDICINE-92C4",
            "SESSION-SENSITIVE-SCHEMA-7719",
        ]
        let profile = makeBundle(
            source: .userEnteredLocal,
            token: 14,
            bundleSchemaVersion: 99,
            preferredName: sensitiveValues[0],
            canonicalAllergies: [sensitiveValues[2]],
            unresolvedMedicineNames: [sensitiveValues[1]]
        )
        let originalData = try encodeForProtectedStore(profile)
        try originalData.write(to: fileURL)
        let store = ProtectedFileLocalUserProfileStore(
            baseDirectory: directory
        )

        await confirmation(expectedCount: 0) { uuidConfirmation in
            await confirmation(expectedCount: 0) { clockConfirmation in
                let session = makeSession(
                    store: store,
                    demo: makeBundle(source: .bundledDemo, token: 96),
                    uuidProvider: ConfirmingUUIDProvider(
                        returning: fixedUUID(97),
                        onCall: { uuidConfirmation() }
                    ),
                    clock: ConfirmingClock(
                        returning: Date(timeIntervalSince1970: 9_700),
                        onCall: { clockConfirmation() }
                    )
                )

                await session.load()

                #expect(session.state == .failed(.invalidStoredProfile))
                #expect(session.state != .ready(profile))
                guard case let .failed(failure) = session.state else {
                    Issue.record("Expected a stable session failure.")
                    return
                }
                for description in errorDescriptions(for: failure) {
                    for sensitiveValue in sensitiveValues {
                        #expect(!description.contains(sensitiveValue))
                    }
                    #expect(!description.contains(fileURL.path))
                    #expect(!description.contains("unsupportedSchemaVersion"))
                    #expect(!description.contains("found"))
                    #expect(!description.contains("99"))
                }
            }
        }

        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try Data(contentsOf: fileURL) == originalData)
    }

    @Test func productionStoreCorruptedJSONMapsToLoadFailed() async throws {
        let directory = try preparedProfileDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = profileURL(in: directory)
        let corruptedData = Data(
            #"{"preferredName":"SESSION-PRIVATE-NAME-7F31""#.utf8
        )
        try corruptedData.write(to: fileURL)
        let session = makeSession(
            store: ProtectedFileLocalUserProfileStore(
                baseDirectory: directory
            )
        )

        await session.load()

        #expect(session.state == .failed(.loadFailed))
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try Data(contentsOf: fileURL) == corruptedData)
    }

    @Test func loadErrorMapsToStableFailure() async {
        let store = UserProfileStoreDouble(failures: [.load])
        let session = makeSession(store: store)

        await session.load()

        #expect(session.state == .failed(.loadFailed))
        #expect(await store.snapshot().loadCallCount == 1)
    }

    @Test func loadErrorNeverUsesDemoProfile() async {
        let demo = makeBundle(source: .bundledDemo, token: 90)
        let store = UserProfileStoreDouble(failures: [.load])
        let session = makeSession(store: store, demo: demo)

        await session.load()

        let snapshot = await store.snapshot()
        #expect(session.state == .failed(.loadFailed))
        #expect(snapshot.saveArguments.isEmpty)
        #expect(snapshot.deleteCallCount == 0)
    }

    @Test func repeatedLoadWhileLoadingStartsOneRead() async {
        let store = UserProfileStoreDouble(paused: [.load])
        let session = makeSession(store: store)
        let firstLoad = Task { await session.load() }
        await store.waitUntilParked(.load)

        #expect(session.state == .loading)
        await session.load()
        #expect(await store.snapshot().loadCallCount == 1)

        await store.release(.load)
        await firstLoad.value
        #expect(session.state == .needsOnboarding)
    }

    @Test func createValidatesAndSavesInjectedIdentityAndTime() async throws {
        let store = UserProfileStoreDouble()
        let id = fixedUUID(21)
        let now = Date(timeIntervalSince1970: 2_000)
        let session = makeSession(store: store, id: id, date: now)
        let draft = UserProfileDraft(
            preferredName: "  Test User  ",
            ageText: " 72 ",
            allergies: [" 花粉 ", "花粉", "青霉素"],
            diagnosedConditions: [" Test Condition "],
            currentMedicineNames: [" Test Tablet "]
        )
        await session.load()

        try await session.create(from: draft)

        let snapshot = await store.snapshot()
        let saved = try #require(snapshot.saveArguments.first)
        #expect(snapshot.saveArguments.count == 1)
        #expect(saved.preferredName == "Test User")
        #expect(saved.healthProfile.id == id)
        #expect(saved.createdAt == now)
        #expect(saved.updatedAt == now)
        #expect(saved.healthProfile.createdAt == now)
        #expect(saved.healthProfile.updatedAt == now)
        #expect(
            saved.unresolvedAllergyDescriptions == ["花粉", "青霉素"]
        )
        #expect(saved.healthProfile.allergies.isEmpty)
        #expect(saved.unresolvedMedicineNames == ["Test Tablet"])
        #expect(saved.healthProfile.currentMedicineIngredientIDs.isEmpty)
        #expect(session.state == .ready(saved))
    }

    @Test func createReadsUUIDAndClockExactlyOnce() async throws {
        let store = UserProfileStoreDouble()
        let id = fixedUUID(22)
        let now = Date(timeIntervalSince1970: 2_100)

        try await confirmation(expectedCount: 1) { uuidConfirmation in
            try await confirmation(expectedCount: 1) { clockConfirmation in
                let session = makeSession(
                    store: store,
                    uuidProvider: ConfirmingUUIDProvider(
                        returning: id,
                        onCall: { uuidConfirmation() }
                    ),
                    clock: ConfirmingClock(
                        returning: now,
                        onCall: { clockConfirmation() }
                    )
                )
                await session.load()

                try await session.create(from: makeDraft())

                let snapshot = await store.snapshot()
                let saved = try #require(snapshot.saveArguments.first)
                #expect(snapshot.saveCallCount == 1)
                #expect(saved.healthProfile.id == id)
                #expect(saved.createdAt == now)
                #expect(saved.updatedAt == now)
                #expect(saved.healthProfile.createdAt == now)
                #expect(saved.healthProfile.updatedAt == now)
            }
        }
    }

    @Test func createPublishesReadyOnlyAfterSaveCompletes() async throws {
        let store = UserProfileStoreDouble(paused: [.save])
        let session = makeSession(store: store)
        await session.load()
        let create = Task { try await session.create(from: makeDraft()) }
        await store.waitUntilParked(.save)

        #expect(session.state == .loading)
        #expect(await store.snapshot().saveArguments.count == 1)

        await store.release(.save)
        try await create.value
        guard case .ready = session.state else {
            Issue.record("Expected ready after the save completed.")
            return
        }
    }

    @Test func createValidationFailureDoesNotSaveAndPreservesState() async {
        let store = UserProfileStoreDouble()
        let session = makeSession(store: store)
        await session.load()
        #expect(session.state == .needsOnboarding)

        let issue = await captureValidationIssue {
            try await session.create(
                from: UserProfileDraft(preferredName: " ", ageText: "72")
            )
        }

        #expect(issue == .emptyPreferredName)
        #expect(session.state == .needsOnboarding)
        #expect(await store.snapshot().saveArguments.isEmpty)
    }

    @Test func createSaveFailureEntersFailed() async {
        let store = UserProfileStoreDouble(failures: [.save])
        let session = makeSession(store: store)
        await session.load()

        let failure = await captureSessionFailure {
            try await session.create(from: makeDraft())
        }

        #expect(failure == .saveFailed)
        #expect(session.state == .failed(.saveFailed))
        #expect(await store.snapshot().saveArguments.count == 1)
    }

    @Test func createKeepsMedicineNamesUnresolved() async throws {
        let store = UserProfileStoreDouble()
        let session = makeSession(store: store)
        await session.load()

        try await session.create(
            from: makeDraft(medicineNames: [" Test Tablet ", "test tablet"])
        )

        let saved = try #require(await store.snapshot().saveArguments.first)
        #expect(saved.unresolvedMedicineNames == ["Test Tablet"])
        #expect(saved.healthProfile.currentMedicineIngredientIDs.isEmpty)
    }

    @Test func createRejectsReadyProfileWithoutSideEffects() async {
        let existing = makeBundle(source: .userEnteredLocal, token: 23)
        let store = UserProfileStoreDouble(loadResult: existing)

        await confirmation(expectedCount: 0) { uuidConfirmation in
            await confirmation(expectedCount: 0) { clockConfirmation in
                let session = makeSession(
                    store: store,
                    uuidProvider: ConfirmingUUIDProvider(
                        returning: fixedUUID(24),
                        onCall: { uuidConfirmation() }
                    ),
                    clock: ConfirmingClock(
                        returning: Date(timeIntervalSince1970: 2_400),
                        onCall: { clockConfirmation() }
                    )
                )
                await session.load()

                let failure = await captureSessionFailure {
                    try await session.create(from: makeDraft())
                }

                let snapshot = await store.snapshot()
                #expect(failure == .profileAlreadyExists)
                #expect(session.state == .ready(existing))
                #expect(snapshot.saveCallCount == 0)
                #expect(snapshot.deleteCallCount == 0)
            }
        }
    }

    @Test func profileCreationFromIdleIsRejectedWithoutSideEffects() async {
        let store = UserProfileStoreDouble()

        await confirmation(expectedCount: 0) { uuidConfirmation in
            await confirmation(expectedCount: 0) { clockConfirmation in
                let session = makeSession(
                    store: store,
                    uuidProvider: ConfirmingUUIDProvider(
                        returning: fixedUUID(25),
                        onCall: { uuidConfirmation() }
                    ),
                    clock: ConfirmingClock(
                        returning: Date(timeIntervalSince1970: 2_500),
                        onCall: { clockConfirmation() }
                    )
                )

                let createFailure = await captureSessionFailure {
                    try await session.create(from: makeDraft())
                }
                let demoFailure = await captureSessionFailure {
                    try await session.useBundledDemoProfile()
                }

                let snapshot = await store.snapshot()
                #expect(createFailure == .profileStateUnresolved)
                #expect(demoFailure == .profileStateUnresolved)
                #expect(session.state == .idle)
                #expect(snapshot.loadCallCount == 0)
                #expect(snapshot.saveCallCount == 0)
                #expect(snapshot.deleteCallCount == 0)
            }
        }
    }

    @Test func profileCreationFromFailedIsRejectedWithoutSideEffects() async {
        let store = UserProfileStoreDouble(failures: [.load])

        await confirmation(expectedCount: 0) { uuidConfirmation in
            await confirmation(expectedCount: 0) { clockConfirmation in
                let session = makeSession(
                    store: store,
                    uuidProvider: ConfirmingUUIDProvider(
                        returning: fixedUUID(26),
                        onCall: { uuidConfirmation() }
                    ),
                    clock: ConfirmingClock(
                        returning: Date(timeIntervalSince1970: 2_600),
                        onCall: { clockConfirmation() }
                    )
                )
                await session.load()

                let createFailure = await captureSessionFailure {
                    try await session.create(from: makeDraft())
                }
                let demoFailure = await captureSessionFailure {
                    try await session.useBundledDemoProfile()
                }

                let snapshot = await store.snapshot()
                #expect(createFailure == .profileStateUnresolved)
                #expect(demoFailure == .profileStateUnresolved)
                #expect(session.state == .failed(.loadFailed))
                #expect(snapshot.loadCallCount == 1)
                #expect(snapshot.saveCallCount == 0)
                #expect(snapshot.deleteCallCount == 0)
            }
        }
    }

    @Test func updatePreservesCanonicalContextAndIdentity() async throws {
        let bundleCreatedAt = Date(timeIntervalSince1970: 1_000)
        let healthProfileCreatedAt = Date(timeIntervalSince1970: 900)
        let oldUpdatedAt = Date(timeIntervalSince1970: 1_100)
        let newUpdatedAt = Date(timeIntervalSince1970: 2_000)
        let bodyMetrics = BodyMetrics(
            systolicBloodPressure: 126,
            diastolicBloodPressure: 78,
            heartRate: 64,
            measuredAt: Date(timeIntervalSince1970: 800),
            source: "trusted-device",
            deviceIdentifier: "device-31"
        )
        let existing = makeBundle(
            source: .userEnteredLocal,
            token: 31,
            createdAt: bundleCreatedAt,
            healthProfileCreatedAt: healthProfileCreatedAt,
            updatedAt: oldUpdatedAt,
            canonicalAllergies: ["canonical-allergy-31"],
            canonicalMedicineIngredientIDs: ["ingredient-31"],
            bodyMetrics: bodyMetrics
        )
        let store = UserProfileStoreDouble(loadResult: existing)
        let session = makeSession(store: store, id: fixedUUID(99), date: newUpdatedAt)
        await session.load()

        try await session.update(
            from: UserProfileDraft(
                preferredName: "  Updated User  ",
                ageText: " 72 ",
                allergies: [" Synthetic Unresolved Allergy "],
                diagnosedConditions: [" Synthetic Condition "],
                currentMedicineNames: [" Synthetic Medicine "]
            )
        )

        let saved = try #require(await store.snapshot().saveArguments.first)
        #expect(saved.preferredName == "Updated User")
        #expect(saved.schemaVersion == LocalUserProfileBundle.currentSchemaVersion)
        #expect(saved.healthProfile.id == existing.healthProfile.id)
        #expect(saved.healthProfile.schemaVersion == existing.healthProfile.schemaVersion)
        #expect(saved.source == .userEnteredLocal)
        #expect(saved.createdAt == bundleCreatedAt)
        #expect(saved.healthProfile.createdAt == healthProfileCreatedAt)
        #expect(saved.updatedAt == newUpdatedAt)
        #expect(saved.healthProfile.updatedAt == newUpdatedAt)
        #expect(saved.updatedAt != oldUpdatedAt)
        #expect(saved.healthProfile.age == existing.healthProfile.age)
        #expect(
            saved.healthProfile.diagnosedConditions
                == existing.healthProfile.diagnosedConditions
        )
        #expect(saved.healthProfile.allergies == existing.healthProfile.allergies)
        #expect(
            saved.healthProfile.currentMedicineIngredientIDs
                == existing.healthProfile.currentMedicineIngredientIDs
        )
        #expect(saved.healthProfile.bodyMetrics == bodyMetrics)
        #expect(
            saved.unresolvedAllergyDescriptions
                == existing.unresolvedAllergyDescriptions
        )
        #expect(saved.unresolvedMedicineNames == existing.unresolvedMedicineNames)
        #expect(session.state == .ready(saved))
    }

    @Test func updateReadsClockOnceAndNeverReadsUUID() async throws {
        let bundleCreatedAt = Date(timeIntervalSince1970: 1_200)
        let healthProfileCreatedAt = Date(timeIntervalSince1970: 1_100)
        let oldUpdatedAt = Date(timeIntervalSince1970: 1_300)
        let newUpdatedAt = Date(timeIntervalSince1970: 2_200)
        let existing = makeBundle(
            source: .userEnteredLocal,
            token: 34,
            createdAt: bundleCreatedAt,
            healthProfileCreatedAt: healthProfileCreatedAt,
            updatedAt: oldUpdatedAt
        )
        let store = UserProfileStoreDouble(loadResult: existing)

        try await confirmation(expectedCount: 0) { uuidConfirmation in
            try await confirmation(expectedCount: 1) { clockConfirmation in
                let session = makeSession(
                    store: store,
                    uuidProvider: ConfirmingUUIDProvider(
                        returning: fixedUUID(98),
                        onCall: { uuidConfirmation() }
                    ),
                    clock: ConfirmingClock(
                        returning: newUpdatedAt,
                        onCall: { clockConfirmation() }
                    )
                )
                await session.load()

                try await session.update(
                    from: makeDraft(name: "Counted Update")
                )

                let snapshot = await store.snapshot()
                let saved = try #require(snapshot.saveArguments.first)
                #expect(snapshot.saveCallCount == 1)
                #expect(saved.healthProfile.id == existing.healthProfile.id)
                #expect(saved.createdAt == bundleCreatedAt)
                #expect(
                    saved.healthProfile.createdAt == healthProfileCreatedAt
                )
                #expect(saved.updatedAt == newUpdatedAt)
                #expect(saved.healthProfile.updatedAt == newUpdatedAt)
                #expect(session.state == .ready(saved))
            }
        }
    }

    @Test(
        arguments: [
            UpdateTimestampCase(
                bundleCreatedAt: 5_000,
                healthProfileCreatedAt: 1_000,
                bundleUpdatedAt: 2_000,
                healthProfileUpdatedAt: 3_000,
                clockNow: 500,
                expectedUpdatedAt: 5_000
            ),
            UpdateTimestampCase(
                bundleCreatedAt: 1_000,
                healthProfileCreatedAt: 6_000,
                bundleUpdatedAt: 2_000,
                healthProfileUpdatedAt: 3_000,
                clockNow: 500,
                expectedUpdatedAt: 6_000
            ),
            UpdateTimestampCase(
                bundleCreatedAt: 1_000,
                healthProfileCreatedAt: 900,
                bundleUpdatedAt: 7_000,
                healthProfileUpdatedAt: 3_000,
                clockNow: 500,
                expectedUpdatedAt: 7_000
            ),
            UpdateTimestampCase(
                bundleCreatedAt: 1_000,
                healthProfileCreatedAt: 900,
                bundleUpdatedAt: 3_000,
                healthProfileUpdatedAt: 8_000,
                clockNow: 500,
                expectedUpdatedAt: 8_000
            ),
        ]
    )
    func updateTimestampNeverRegresses(testCase: UpdateTimestampCase) async throws {
        let existing = makeBundle(
            source: .userEnteredLocal,
            token: 35,
            createdAt: testCase.bundleCreatedAt,
            healthProfileCreatedAt: testCase.healthProfileCreatedAt,
            updatedAt: testCase.bundleUpdatedAt,
            healthProfileUpdatedAt: testCase.healthProfileUpdatedAt
        )
        let store = UserProfileStoreDouble(loadResult: existing)
        let session = makeSession(store: store, date: testCase.clockNow)
        await session.load()

        try await session.update(from: makeDraft(name: "Monotonic Update"))

        let saved = try #require(await store.snapshot().saveArguments.first)
        #expect(saved.updatedAt == testCase.expectedUpdatedAt)
        #expect(saved.healthProfile.updatedAt == testCase.expectedUpdatedAt)
        #expect(saved.updatedAt >= existing.createdAt)
        #expect(saved.updatedAt >= existing.updatedAt)
        #expect(saved.healthProfile.updatedAt >= existing.healthProfile.createdAt)
        #expect(saved.healthProfile.updatedAt >= existing.healthProfile.updatedAt)
    }

    @Test func updateSavesValidatorOutput() async throws {
        let bodyMetrics = BodyMetrics(
            systolicBloodPressure: 118,
            diastolicBloodPressure: 72,
            heartRate: 66,
            measuredAt: Date(timeIntervalSince1970: 700)
        )
        let existing = makeBundle(
            source: .userEnteredLocal,
            token: 32,
            bodyMetrics: bodyMetrics
        )
        let store = UserProfileStoreDouble(loadResult: existing)
        let session = makeSession(store: store)
        await session.load()

        try await session.update(
            from: UserProfileDraft(
                preferredName: "  Updated User  ",
                ageText: " 73 ",
                allergies: [" Pollen ", "pollen"],
                diagnosedConditions: [" Test Condition "],
                currentMedicineNames: []
            )
        )

        let snapshot = await store.snapshot()
        let saved = try #require(snapshot.saveArguments.first)
        #expect(snapshot.saveArguments.count == 1)
        #expect(saved.preferredName == "Updated User")
        #expect(saved.healthProfile.age == 73)
        #expect(saved.unresolvedAllergyDescriptions == ["Pollen"])
        #expect(saved.unresolvedMedicineNames.isEmpty)
        #expect(saved.healthProfile.allergies == existing.healthProfile.allergies)
        #expect(saved.healthProfile.diagnosedConditions == ["Test Condition"])
        #expect(
            saved.healthProfile.currentMedicineIngredientIDs
                == existing.healthProfile.currentMedicineIngredientIDs
        )
        #expect(saved.healthProfile.bodyMetrics == bodyMetrics)
        #expect(!saved.healthProfile.allergies.contains("Pollen"))
    }

    @Test func updateValidationFailureDoesNotSaveAndKeepsOldReady() async {
        let existing = makeBundle(source: .userEnteredLocal, token: 33)
        let store = UserProfileStoreDouble(loadResult: existing)
        let session = makeSession(store: store)
        await session.load()

        let issue = await captureValidationIssue {
            try await session.update(
                from: UserProfileDraft(preferredName: "Test", ageText: "0")
            )
        }

        #expect(issue == .ageOutOfRange)
        #expect(session.state == .ready(existing))
        #expect(await store.snapshot().saveArguments.isEmpty)
    }

    @Test func updateWithoutReadyThrowsNoCurrentProfile() async {
        let store = UserProfileStoreDouble()
        let session = makeSession(store: store)

        let failure = await captureSessionFailure {
            try await session.update(from: makeDraft())
        }

        #expect(failure == .noCurrentProfile)
        #expect(session.state == .idle)
        #expect(await store.snapshot().saveArguments.isEmpty)
    }

    @Test func editingDemoCreatesUserEnteredProfile() async throws {
        let bundleCreatedAt = Date(timeIntervalSince1970: 700)
        let healthProfileCreatedAt = Date(timeIntervalSince1970: 600)
        let demo = makeBundle(
            source: .bundledDemo,
            token: 41,
            createdAt: bundleCreatedAt,
            healthProfileCreatedAt: healthProfileCreatedAt
        )
        let store = UserProfileStoreDouble(loadResult: demo)
        let session = makeSession(store: store)
        await session.load()

        try await session.update(from: makeDraft(name: "Edited Demo"))

        let saved = try #require(await store.snapshot().saveArguments.first)
        #expect(saved.source == .userEnteredLocal)
        #expect(saved.healthProfile.id == demo.healthProfile.id)
        #expect(saved.createdAt == bundleCreatedAt)
        #expect(saved.healthProfile.createdAt == healthProfileCreatedAt)
    }

    @Test func updateKeepsMedicineNamesUnresolved() async throws {
        let existing = makeBundle(source: .userEnteredLocal, token: 42)
        let store = UserProfileStoreDouble(loadResult: existing)
        let session = makeSession(store: store)
        await session.load()

        try await session.update(
            from: makeDraft(medicineNames: [" Updated Tablet "])
        )

        let saved = try #require(await store.snapshot().saveArguments.first)
        #expect(saved.unresolvedMedicineNames == ["Updated Tablet"])
        #expect(
            saved.healthProfile.currentMedicineIngredientIDs
                == existing.healthProfile.currentMedicineIngredientIDs
        )
        #expect(
            !saved.healthProfile.currentMedicineIngredientIDs.contains(
                "Updated Tablet"
            )
        )
    }

    @Test func updateSaveFailureRecordsValidatedProfileAndEntersFailed() async throws {
        let bundleCreatedAt = Date(timeIntervalSince1970: 1_400)
        let healthProfileCreatedAt = Date(timeIntervalSince1970: 1_300)
        let newUpdatedAt = Date(timeIntervalSince1970: 2_400)
        let existing = makeBundle(
            source: .bundledDemo,
            token: 43,
            createdAt: bundleCreatedAt,
            healthProfileCreatedAt: healthProfileCreatedAt,
            updatedAt: Date(timeIntervalSince1970: 1_500)
        )
        let store = UserProfileStoreDouble(
            loadResult: existing,
            failures: [.save]
        )
        let session = makeSession(store: store, date: newUpdatedAt)
        await session.load()

        let failure = await captureSessionFailure {
            try await session.update(from: makeDraft(name: "Failed Update"))
        }

        let snapshot = await store.snapshot()
        let saved = try #require(snapshot.saveArguments.first)
        #expect(failure == .saveFailed)
        #expect(snapshot.saveCallCount == 1)
        #expect(saved.healthProfile.id == existing.healthProfile.id)
        #expect(saved.createdAt == bundleCreatedAt)
        #expect(saved.healthProfile.createdAt == healthProfileCreatedAt)
        #expect(saved.updatedAt == newUpdatedAt)
        #expect(saved.healthProfile.updatedAt == newUpdatedAt)
        #expect(saved.source == .userEnteredLocal)
        #expect(saved.healthProfile.allergies == existing.healthProfile.allergies)
        #expect(saved.unresolvedAllergyDescriptions == ["Pollen"])
        #expect(
            saved.healthProfile.currentMedicineIngredientIDs
                == existing.healthProfile.currentMedicineIngredientIDs
        )
        #expect(saved.unresolvedMedicineNames == ["Test Tablet"])
        #expect(session.state == .failed(.saveFailed))
    }

    @Test func useDemoSavesAndPublishesExactBundleUnchanged() async throws {
        let demo = makeBundle(
            source: .bundledDemo,
            token: 51,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let store = UserProfileStoreDouble()
        let session = makeSession(
            store: store,
            demo: demo,
            id: fixedUUID(99),
            date: Date(timeIntervalSince1970: 9_999)
        )
        await session.load()
        #expect(session.state == .needsOnboarding)

        try await session.useBundledDemoProfile()

        let saved = try #require(await store.snapshot().saveArguments.first)
        #expect(demo.source == .bundledDemo)
        #expect(!demo.unresolvedAllergyDescriptions.isEmpty)
        #expect(!demo.unresolvedMedicineNames.isEmpty)
        #expect(saved == demo)
        #expect(saved.healthProfile.id == demo.healthProfile.id)
        #expect(saved.createdAt == demo.createdAt)
        #expect(saved.updatedAt == demo.updatedAt)
        #expect(session.state == .ready(demo))
    }

    @Test func useDemoNeverReadsUUIDOrClock() async throws {
        let demo = makeBundle(source: .bundledDemo, token: 54)
        let store = UserProfileStoreDouble()

        try await confirmation(expectedCount: 0) { uuidConfirmation in
            try await confirmation(expectedCount: 0) { clockConfirmation in
                let session = makeSession(
                    store: store,
                    demo: demo,
                    uuidProvider: ConfirmingUUIDProvider(
                        returning: fixedUUID(97),
                        onCall: { uuidConfirmation() }
                    ),
                    clock: ConfirmingClock(
                        returning: Date(timeIntervalSince1970: 9_700),
                        onCall: { clockConfirmation() }
                    )
                )
                await session.load()

                try await session.useBundledDemoProfile()

                let snapshot = await store.snapshot()
                let saved = try #require(snapshot.saveArguments.first)
                #expect(snapshot.saveCallCount == 1)
                #expect(saved == demo)
                #expect(session.state == .ready(demo))
            }
        }
    }

    @Test func invalidDemoSourceIsRejectedWithoutSave() async {
        let invalidDemo = makeBundle(source: .userEnteredLocal, token: 52)
        let store = UserProfileStoreDouble()
        let session = makeSession(store: store, demo: invalidDemo)
        await session.load()

        let failure = await captureSessionFailure {
            try await session.useBundledDemoProfile()
        }

        #expect(failure == .invalidBundledDemoProfile)
        #expect(session.state == .failed(.invalidBundledDemoProfile))
        #expect(await store.snapshot().saveArguments.isEmpty)
    }

    @Test func invalidDemoSchemaIsRejectedWithoutSave() async {
        let invalidDemo = makeBundle(
            source: .bundledDemo,
            token: 53,
            bundleSchemaVersion: 99
        )
        let store = UserProfileStoreDouble()
        let session = makeSession(store: store, demo: invalidDemo)
        await session.load()

        let failure = await captureSessionFailure {
            try await session.useBundledDemoProfile()
        }

        #expect(failure == .invalidBundledDemoProfile)
        #expect(session.state == .failed(.invalidBundledDemoProfile))
        #expect(await store.snapshot().saveArguments.isEmpty)
    }

    @Test func invalidDemoHealthProfileSchemaIsRejectedWithoutSave() async {
        let invalidDemo = makeBundle(
            source: .bundledDemo,
            token: 55,
            bundleSchemaVersion: LocalUserProfileBundle.currentSchemaVersion,
            healthProfileSchemaVersion: 99
        )
        let store = UserProfileStoreDouble()

        await confirmation(expectedCount: 0) { uuidConfirmation in
            await confirmation(expectedCount: 0) { clockConfirmation in
                let session = makeSession(
                    store: store,
                    demo: invalidDemo,
                    uuidProvider: ConfirmingUUIDProvider(
                        returning: fixedUUID(96),
                        onCall: { uuidConfirmation() }
                    ),
                    clock: ConfirmingClock(
                        returning: Date(timeIntervalSince1970: 9_600),
                        onCall: { clockConfirmation() }
                    )
                )
                await session.load()

                let failure = await captureSessionFailure {
                    try await session.useBundledDemoProfile()
                }

                let snapshot = await store.snapshot()
                #expect(failure == .invalidBundledDemoProfile)
                #expect(
                    session.state == .failed(.invalidBundledDemoProfile)
                )
                #expect(snapshot.saveCallCount == 0)
                #expect(snapshot.saveArguments.isEmpty)
            }
        }
    }

    @Test func useDemoRejectsReadyProfileWithoutSideEffects() async {
        let existing = makeBundle(source: .userEnteredLocal, token: 56)
        let demo = makeBundle(source: .bundledDemo, token: 57)
        let store = UserProfileStoreDouble(loadResult: existing)

        await confirmation(expectedCount: 0) { uuidConfirmation in
            await confirmation(expectedCount: 0) { clockConfirmation in
                let session = makeSession(
                    store: store,
                    demo: demo,
                    uuidProvider: ConfirmingUUIDProvider(
                        returning: fixedUUID(58),
                        onCall: { uuidConfirmation() }
                    ),
                    clock: ConfirmingClock(
                        returning: Date(timeIntervalSince1970: 5_800),
                        onCall: { clockConfirmation() }
                    )
                )
                await session.load()

                let failure = await captureSessionFailure {
                    try await session.useBundledDemoProfile()
                }

                let snapshot = await store.snapshot()
                #expect(failure == .profileAlreadyExists)
                #expect(session.state == .ready(existing))
                #expect(snapshot.saveCallCount == 0)
                #expect(snapshot.deleteCallCount == 0)
            }
        }
    }

    @Test func demoSaveFailureEntersFailed() async {
        let store = UserProfileStoreDouble(failures: [.save])
        let session = makeSession(store: store)
        await session.load()

        let failure = await captureSessionFailure {
            try await session.useBundledDemoProfile()
        }

        #expect(failure == .saveFailed)
        #expect(session.state == .failed(.saveFailed))
        #expect(await store.snapshot().saveArguments.count == 1)
    }

    @Test func deleteCallsStoreOnceAndNeedsOnboarding() async throws {
        let profile = makeBundle(source: .userEnteredLocal, token: 61)
        let store = UserProfileStoreDouble(loadResult: profile)
        let session = makeSession(store: store)
        await session.load()

        try await session.deleteCurrentProfile()

        let snapshot = await store.snapshot()
        #expect(snapshot.deleteCallCount == 1)
        #expect(session.state == .needsOnboarding)
    }

    @Test func deleteWithNoCurrentProfileRemainsSuccessful() async throws {
        let store = UserProfileStoreDouble()
        let session = makeSession(store: store)

        try await session.deleteCurrentProfile()

        #expect(await store.snapshot().deleteCallCount == 1)
        #expect(session.state == .needsOnboarding)
    }

    @Test func deleteFailureDoesNotClaimDeletionOrUseDemo() async {
        let store = UserProfileStoreDouble(failures: [.delete])
        let session = makeSession(store: store)

        let failure = await captureSessionFailure {
            try await session.deleteCurrentProfile()
        }

        let snapshot = await store.snapshot()
        #expect(failure == .deleteFailed)
        #expect(session.state == .failed(.deleteFailed))
        #expect(snapshot.deleteCallCount == 1)
        #expect(snapshot.saveArguments.isEmpty)
    }

    @Test func mutatingOperationsWhileBusyThrowWithoutStoreCalls() async {
        let store = UserProfileStoreDouble(paused: [.load])
        let session = makeSession(store: store)
        let load = Task { await session.load() }
        await store.waitUntilParked(.load)

        let createFailure = await captureSessionFailure {
            try await session.create(from: makeDraft())
        }
        let updateFailure = await captureSessionFailure {
            try await session.update(from: makeDraft())
        }
        let demoFailure = await captureSessionFailure {
            try await session.useBundledDemoProfile()
        }
        let deleteFailure = await captureSessionFailure {
            try await session.deleteCurrentProfile()
        }

        let snapshot = await store.snapshot()
        #expect(createFailure == .operationInProgress)
        #expect(updateFailure == .operationInProgress)
        #expect(demoFailure == .operationInProgress)
        #expect(deleteFailure == .operationInProgress)
        #expect(snapshot.loadCallCount == 1)
        #expect(snapshot.saveArguments.isEmpty)
        #expect(snapshot.deleteCallCount == 0)
        #expect(session.state == .loading)

        await store.release(.load)
        await load.value
        #expect(session.state == .needsOnboarding)
    }

    @Test func busyStateIsReleasedAfterSuccess() async throws {
        let store = UserProfileStoreDouble()
        let session = makeSession(store: store)

        await session.load()
        try await session.create(from: makeDraft())

        let snapshot = await store.snapshot()
        #expect(snapshot.loadCallCount == 1)
        #expect(snapshot.saveArguments.count == 1)
        guard case .ready = session.state else {
            Issue.record("Expected a second operation after load to succeed.")
            return
        }
    }

    @Test func busyStateIsReleasedAfterFailure() async {
        let store = UserProfileStoreDouble(failures: [.load])
        let session = makeSession(store: store)
        await session.load()
        #expect(session.state == .failed(.loadFailed))
        await store.setFailure(.load, enabled: false)

        await session.load()

        #expect(session.state == .needsOnboarding)
        #expect(await store.snapshot().loadCallCount == 2)
    }

    @Test func failureDescriptionsContainOnlyStableCodes() {
        let failures: [UserProfileSessionFailure] = [
            .loadFailed,
            .saveFailed,
            .deleteFailed,
            .invalidStoredProfile,
            .invalidBundledDemoProfile,
            .profileAlreadyExists,
            .profileStateUnresolved,
            .noCurrentProfile,
            .operationInProgress,
        ]
        let expectedCodes = [
            "loadFailed",
            "saveFailed",
            "deleteFailed",
            "invalidStoredProfile",
            "invalidBundledDemoProfile",
            "profileAlreadyExists",
            "profileStateUnresolved",
            "noCurrentProfile",
            "operationInProgress",
        ]
        let descriptions = failures.map(\.description)

        #expect(descriptions == expectedCodes)
        let sensitiveValues = [
            "SESSION-PRIVATE-NAME-7F31",
            "SESSION-SECRET-MEDICINE-92C4",
            "SESSION-SENSITIVE-SCHEMA-7719",
            "/Application Support/private-profile.json",
            #"{"preferredName":"SESSION-PRIVATE-NAME-7F31"}"#,
            #"{"preferredName""#,
            "preferredName",
            "ProtectedLocalUserProfileStoreError",
            "unsupportedSchemaVersion",
            "corruptedJSON",
            "readFailed",
            "directoryProtectionFailed",
            "found: 99",
            "99",
        ]
        for failure in failures {
            for description in errorDescriptions(for: failure) {
                for sensitiveValue in sensitiveValues {
                    #expect(!description.contains(sensitiveValue))
                }
            }
        }
    }
}

nonisolated struct UpdateTimestampCase: Sendable {
    let bundleCreatedAt: Date
    let healthProfileCreatedAt: Date
    let bundleUpdatedAt: Date
    let healthProfileUpdatedAt: Date
    let clockNow: Date
    let expectedUpdatedAt: Date

    init(
        bundleCreatedAt: TimeInterval,
        healthProfileCreatedAt: TimeInterval,
        bundleUpdatedAt: TimeInterval,
        healthProfileUpdatedAt: TimeInterval,
        clockNow: TimeInterval,
        expectedUpdatedAt: TimeInterval
    ) {
        self.bundleCreatedAt = Date(timeIntervalSince1970: bundleCreatedAt)
        self.healthProfileCreatedAt = Date(
            timeIntervalSince1970: healthProfileCreatedAt
        )
        self.bundleUpdatedAt = Date(timeIntervalSince1970: bundleUpdatedAt)
        self.healthProfileUpdatedAt = Date(
            timeIntervalSince1970: healthProfileUpdatedAt
        )
        self.clockNow = Date(timeIntervalSince1970: clockNow)
        self.expectedUpdatedAt = Date(timeIntervalSince1970: expectedUpdatedAt)
    }
}

private nonisolated enum StoreOperation: Hashable, Sendable {
    case load
    case save
    case delete
}

private struct ConfirmingUUIDProvider: UUIDProviding, Sendable {
    private let value: UUID
    private let onCall: @Sendable () -> Void

    init(returning value: UUID, onCall: @escaping @Sendable () -> Void) {
        self.value = value
        self.onCall = onCall
    }

    func makeUUID() -> UUID {
        onCall()
        return value
    }
}

private struct ConfirmingClock: SlowWalkDomain.Clock, Sendable {
    private let value: Date
    private let onCall: @Sendable () -> Void

    init(returning value: Date, onCall: @escaping @Sendable () -> Void) {
        self.value = value
        self.onCall = onCall
    }

    func now() -> Date {
        onCall()
        return value
    }
}

private actor UserProfileStoreDouble: LocalUserProfileStore {
    struct Snapshot: Sendable {
        let loadCallCount: Int
        let saveArguments: [LocalUserProfileBundle]
        let deleteCallCount: Int

        var saveCallCount: Int {
            saveArguments.count
        }
    }

    private enum StubError: Error {
        case expected
    }

    private var loadResult: LocalUserProfileBundle?
    private var failures: Set<StoreOperation>
    private var paused: Set<StoreOperation>
    private var loadCallCount = 0
    private var saveArguments: [LocalUserProfileBundle] = []
    private var deleteCallCount = 0
    private var parked: [StoreOperation: [CheckedContinuation<Void, Never>]] = [:]
    private var parkingWaiters:
        [StoreOperation: [CheckedContinuation<Void, Never>]] = [:]

    init(
        loadResult: LocalUserProfileBundle? = nil,
        failures: Set<StoreOperation> = [],
        paused: Set<StoreOperation> = []
    ) {
        self.loadResult = loadResult
        self.failures = failures
        self.paused = paused
    }

    func loadCurrentProfile() async throws -> LocalUserProfileBundle? {
        loadCallCount += 1
        await parkIfNeeded(.load)
        guard !failures.contains(.load) else { throw StubError.expected }
        return loadResult
    }

    func saveCurrentProfile(_ profile: LocalUserProfileBundle) async throws {
        saveArguments.append(profile)
        await parkIfNeeded(.save)
        guard !failures.contains(.save) else { throw StubError.expected }
        loadResult = profile
    }

    func deleteCurrentProfile() async throws {
        deleteCallCount += 1
        await parkIfNeeded(.delete)
        guard !failures.contains(.delete) else { throw StubError.expected }
        loadResult = nil
    }

    func snapshot() -> Snapshot {
        Snapshot(
            loadCallCount: loadCallCount,
            saveArguments: saveArguments,
            deleteCallCount: deleteCallCount
        )
    }

    func setFailure(_ operation: StoreOperation, enabled: Bool) {
        if enabled {
            failures.insert(operation)
        } else {
            failures.remove(operation)
        }
    }

    func waitUntilParked(_ operation: StoreOperation) async {
        guard parked[operation, default: []].isEmpty else { return }
        await withCheckedContinuation { continuation in
            parkingWaiters[operation, default: []].append(continuation)
        }
    }

    func release(_ operation: StoreOperation) {
        paused.remove(operation)
        let continuations = parked.removeValue(forKey: operation) ?? []
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func parkIfNeeded(_ operation: StoreOperation) async {
        guard paused.contains(operation) else { return }
        await withCheckedContinuation { continuation in
            parked[operation, default: []].append(continuation)
            let waiters = parkingWaiters.removeValue(forKey: operation) ?? []
            for waiter in waiters {
                waiter.resume()
            }
        }
    }
}

@MainActor
private func makeSession(
    store: any LocalUserProfileStore,
    demo: LocalUserProfileBundle = makeBundle(
        source: .bundledDemo,
        token: 80
    ),
    id: UUID = fixedUUID(70),
    date: Date = Date(timeIntervalSince1970: 5_000),
    uuidProvider: (any UUIDProviding)? = nil,
    clock: (any SlowWalkDomain.Clock)? = nil
) -> UserProfileSession {
    UserProfileSession(
        store: store,
        validator: UserProfileDraftValidator(),
        bundledDemoProfile: demo,
        uuidProvider: uuidProvider ?? FixedUUIDProvider(fixedUUID: id),
        clock: clock ?? FixedClock(fixedDate: date)
    )
}

private nonisolated func errorDescriptions(
    for failure: UserProfileSessionFailure
) -> [String] {
    [
        failure.description,
        String(describing: failure),
        failure.localizedDescription,
    ]
}

private nonisolated func preparedProfileDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "slowwalk-user-profile-session-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return directory
}

private nonisolated func profileURL(in directory: URL) -> URL {
    directory.appendingPathComponent(
        ProtectedFileLocalUserProfileStore.fileName,
        isDirectory: false
    )
}

private nonisolated func encodeForProtectedStore(
    _ profile: LocalUserProfileBundle
) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(profile)
}

private nonisolated func makeDraft(
    name: String = "Test User",
    medicineNames: [String] = ["Test Tablet"]
) -> UserProfileDraft {
    UserProfileDraft(
        preferredName: name,
        ageText: "72",
        allergies: ["Pollen"],
        diagnosedConditions: ["Test Condition"],
        currentMedicineNames: medicineNames
    )
}

private nonisolated func makeBundle(
    source: UserProfileSource,
    token: UInt8,
    bundleSchemaVersion: Int = LocalUserProfileBundle.currentSchemaVersion,
    healthProfileSchemaVersion: Int = UserHealthProfile.currentSchemaVersion,
    createdAt: Date = Date(timeIntervalSince1970: 1_000),
    healthProfileCreatedAt: Date? = nil,
    updatedAt: Date = Date(timeIntervalSince1970: 1_500),
    healthProfileUpdatedAt: Date? = nil,
    preferredName: String = "Synthetic Profile",
    canonicalAllergies: [String] = ["Synthetic Canonical Allergy"],
    unresolvedAllergyDescriptions: [String] = [
        "Synthetic Unresolved Allergy",
    ],
    canonicalMedicineIngredientIDs: [String] = [
        "synthetic-ingredient-id",
    ],
    unresolvedMedicineNames: [String] = ["Synthetic Medicine"],
    bodyMetrics: BodyMetrics? = nil
) -> LocalUserProfileBundle {
    let resolvedHealthProfileCreatedAt = healthProfileCreatedAt ?? createdAt
    let resolvedHealthProfileUpdatedAt = healthProfileUpdatedAt ?? updatedAt
    return LocalUserProfileBundle(
        schemaVersion: bundleSchemaVersion,
        source: source,
        preferredName: preferredName,
        healthProfile: UserHealthProfile(
            id: fixedUUID(token),
            age: 72,
            allergies: canonicalAllergies,
            diagnosedConditions: ["Synthetic Condition"],
            currentMedicineIngredientIDs: canonicalMedicineIngredientIDs,
            bodyMetrics: bodyMetrics,
            updatedAt: resolvedHealthProfileUpdatedAt,
            createdAt: resolvedHealthProfileCreatedAt,
            schemaVersion: healthProfileSchemaVersion
        ),
        unresolvedAllergyDescriptions: unresolvedAllergyDescriptions,
        unresolvedMedicineNames: unresolvedMedicineNames,
        createdAt: createdAt,
        updatedAt: updatedAt
    )
}

private nonisolated func fixedUUID(_ token: UInt8) -> UUID {
    UUID(
        uuid: (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, token
        )
    )
}

@MainActor
private func captureSessionFailure(
    _ operation: () async throws -> Void
) async -> UserProfileSessionFailure? {
    do {
        try await operation()
        Issue.record("Expected a stable session failure.")
        return nil
    } catch let failure as UserProfileSessionFailure {
        return failure
    } catch {
        Issue.record("Expected UserProfileSessionFailure.")
        return nil
    }
}

@MainActor
private func captureValidationIssue(
    _ operation: () async throws -> Void
) async -> UserProfileValidationIssue? {
    do {
        try await operation()
        Issue.record("Expected a validation issue.")
        return nil
    } catch let issue as UserProfileValidationIssue {
        return issue
    } catch {
        Issue.record("Expected UserProfileValidationIssue.")
        return nil
    }
}
