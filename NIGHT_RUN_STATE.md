# Zhipu Online Medicine Recognition Night Run

## Run Metadata

- Fixed baseline SHA: `1e382ab2e31d3fe2fbb9eb6068aeaae95428e894`
- Branch: `feature/zhipu-online-medicine-mainline`
- Start time: `2026-08-05 23:55:56 CST (+0800)`
- Current phase: `Phase 2C - Server medicine recognition API`
- Overall status: `IN_PROGRESS`
- Initial `origin/develop` SHA: `1e382ab2e31d3fe2fbb9eb6068aeaae95428e894` (verified against remote with `git ls-remote`)
- Final `origin/develop` SHA: `PENDING`
- Did develop move during the run: `PENDING`
- Real network smoke run: `NO - SKIPPED (required credential environment variable is absent)`
- Real API key used: `NO`

## Phase Status

| Phase | Status | Implementation commit | State-record commit | Checkpoint tag | Tests |
| --- | --- | --- | --- | --- | --- |
| 0 - Preflight | PASSED_WITH_LIMITATION | `775de0f2ec82ee1e1779f94c021011639ae29593` | `23032be22ef00ca8ffa0e4721bbfe5396f6d8040` | `checkpoint/zhipu-night-0-preflight` | Branch/baseline/remote/architecture/CI/assets audit passed; archive gates passed |
| 2A - Structured package evidence | PASSED | `cdf1c11ea450328144c4515c8ea5f403e2eb6200` | `1a33db77b7682290fc698de4263a26e7b561cf2c` | `checkpoint/zhipu-night-2a-evidence` | Full Server suite: 171 passed, 1 live smoke skipped, 0 failed |
| 2B - Controlled retrieval and verification | PASSED | `e35eaa58116500cc212ba9797f61e6720fe8ae82` | `9a0d2d0bb9770aa373c6ffe1b1e5eeb40880f80a` | `checkpoint/zhipu-night-2b-resolution` | Focused 22/22 and full Server 193 passed; 1 live smoke skipped; 0 failed |
| 2C - Server recognition API | PASSED | PENDING | PENDING | PENDING | Core 365/365 and Server 209/209 passed; 1 live smoke skipped |
| 3 - iOS remote adapter | NOT_STARTED | PENDING | PENDING | PENDING | NOT_RUN |
| 4 - Remote-first composition | NOT_STARTED | PENDING | PENDING | PENDING | NOT_RUN |
| 5 - Full regression and smoke | NOT_STARTED | PENDING | PENDING | PENDING | NOT_RUN |

## Preflight Findings And Plan

### Planned New Files

- `server/Sources/SlowWalkServer/Vision/RemoteMedicinePackageEvidence.swift`
- `server/Sources/SlowWalkServer/MedicineRecognition/MedicineEvidenceModels.swift`
- `server/Sources/SlowWalkServer/MedicineRecognition/MedicineEvidenceSearchProvider.swift`
- `server/Sources/SlowWalkServer/MedicineRecognition/RemoteMedicineCandidateResolver.swift`
- `server/Sources/SlowWalkServer/MedicineRecognition/RemoteMedicineRecognitionService.swift`
- `server/Sources/SlowWalkServer/MedicineRecognition/MedicineRecognitionController.swift`
- `server/Sources/SlowWalkServer/MedicineRecognition/MedicineRecognitionRequestValidator.swift`
- Focused Server tests under `server/Tests/SlowWalkServerTests/Vision/` and `server/Tests/SlowWalkServerTests/MedicineRecognition/`
- `swift-packages/SlowWalkCore/Sources/SlowWalkAPIContracts/MedicineRecognitionDTOs.swift`
- `swift-packages/SlowWalkCore/Sources/SlowWalkClientCore/MedicineRecognitionRequestContracts.swift`
- `swift-packages/SlowWalkCore/Sources/SlowWalkClientCore/OnlineFirstMedicineRecognitionRequester.swift`
- Focused Core contract/composition tests under `swift-packages/SlowWalkCore/Tests/`
- `ios/SlowWalkApp/Services/Network/MedicineRecognitionNetworkConfiguration.swift`
- `ios/SlowWalkApp/Services/Network/RemoteMedicineRecognitionClient.swift`
- Focused iOS network and composition tests under `ios/SlowWalkAppTests/Network/`

### Planned Modified Files

- `server/Sources/SlowWalkServer/Vision/VisionRequestModels.swift`
- `server/Sources/SlowWalkServer/Vision/ZhipuVisionClient.swift`
- `server/Sources/SlowWalkServer/ApplicationFactory.swift`
- `server/Sources/SlowWalkServerApp/main.swift` only if live dependency assembly cannot remain in `ApplicationFactory`
- `server/README.md`
- Existing Vision regression tests where behavior preservation is asserted
- `swift-packages/SlowWalkCore/Sources/SlowWalkAPIContracts/SlowWalkAPI.swift`
- `swift-packages/SlowWalkCore/Sources/SlowWalkAPIContracts/APIErrorDTO.swift`
- `swift-packages/SlowWalkCore/Sources/SlowWalkClientCore/MedicineAssessmentCoordinator.swift`
- `swift-packages/SlowWalkCore/Sources/SlowWalkClientCore/ClientViewStates.swift`
- `ios/SlowWalkApp/App/AppEnvironment.swift`
- `ios/SlowWalkApp/Features/Companion/MedicineAssessmentRunner.swift` only for recognition-provider injection/source propagation
- `ios/SlowWalkApp/Features/Settings/CareSettingsView.swift` only for a privacy/local-only control if the existing setting boundary is suitable
- Existing Core, iOS, and Presentation tests needed to freeze source/fallback semantics
- Presentation model/mapper/copy only for a non-medical fallback-source notice; ActionCard medical mapping stays unchanged

### File Conflict Matrix

| File/boundary | Phases | Conflict level | Control |
| --- | --- | --- | --- |
| `ZhipuVisionClient.swift` | 2A, regression in 2C/5 | Medium | Refactor one shared request/retry executor in 2A; later phases consume it without another loop |
| `ApplicationFactory.swift` | 2C, 5 | Medium | Add recognition dependencies/routes once; preserve the single pipeline and risk engine |
| `SlowWalkAPI.swift` / API errors | 2C, consumed by 3/4 | Medium | Freeze the wire contract in 2C before the iOS adapter |
| Client recognition contracts | 3, 4 | Medium | Define remote transport semantics in 3; add composition policy without changing wire semantics in 4 |
| `MedicineAssessmentCoordinator.swift` | 4, 5 | High | Preserve its one active task, generation, cancellation, and stale-result gates |
| `AppEnvironment.swift` | 4, 5 | High | Remain the sole URL/client/privacy composition root; no construction in views |
| Presentation mapper/copy | 4, 5 | Medium | Add source notice only; do not duplicate or alter ActionCard/risk mapping |
| `project.pbxproj` | 4 only if privacy usage text must change | High | Avoid if possible; if required, narrow to usage strings and verify signing/bundle settings untouched |
| Onboarding/Profile/Risk rules | None | Prohibited | Must remain unmodified |

### Target Data Flow

```text
MedicineCapture image
  -> one MedicineAssessmentRunner / MedicineAssessmentCoordinator task
  -> online-first recognition provider (image + request ID only)
     -> iOS RemoteMedicineRecognitionClient
     -> POST /api/v1/medicine/recognize
     -> Zhipu structured package evidence (visual evidence only)
     -> bounded controlled catalog search and cross-check
     -> existing MedicineResolver (only canonical selector)
     -> recognition input/outcome returned to iOS
  -> on approved recoverable failure only: Apple Vision + existing mapper
  -> existing LocalMedicineAssessmentRequester
  -> existing MedicinePipeline
  -> existing MedicationRiskEngine
  -> existing ActionCardFactory and Presentation mapper
```

No user profile, medication history, risk result, or ActionCard crosses the remote recognition boundary.

### Error And Fallback Mapping

| Condition | Stable client category | Local fallback |
| --- | --- | --- |
| Privacy/local-only mode | local-only selection | Yes, without a network attempt |
| Offline / connection lost | `offline` | Yes |
| Request timeout | `timeout` | Yes |
| Provider 429 | `rateLimited` | Yes; Provider request is not retried |
| Provider bounded 5xx exhaustion | `serverUnavailable` / `providerUnavailable` | Yes |
| Provider transport/config outage | `providerUnavailable` | Yes |
| User/task cancellation | `cancelled` | No; propagate cancellation |
| Image unreadable | `unreadable` | No automatic medicine substitution |
| No controlled candidate | `noCandidate` | No automatic medicine substitution |
| Multiple/conflicting candidates | `ambiguous` / conflict | No automatic medicine substitution |
| Invalid Server JSON, oversized response, request-ID mismatch | `invalidResponse` | No; protocol failures are not hidden |
| Unsupported request/MIME/oversized image | stable validation error | No |

### Scope And Estimates

- Estimated changed lines: `3,800-5,400` including focused tests and run-state records.
- `Package.swift` changes required: `NO` under the planned source-only design; SwiftPM and Xcode synchronized groups discover new Swift files automatically.
- Third-party dependencies required: `NO`.
- CI workflow changes required: `NO`.
- Architecture blocker: `NO`.
- Audit limitation: the bundled canonical catalog has no trusted manufacturer or approval metadata. The Server evidence index will reference existing `Medicine.id` values only, default production metadata will remain empty, and tests will inject controlled metadata. No production approval identifier will be invented.
- Audit limitation: structured model evidence has no numeric confidence. A documented evidence-assurance policy will permit high resolver confidence only from controlled exact/corroborated evidence; it will not select a medicine itself. Uncertain/conflicting/fuzzy evidence remains unresolved.
- Prohibited-scope check: `PASSED`; planned work excludes CI, signing, entitlements, bundle identifiers, medical risk rules, user profile storage, Onboarding, and ActionCard medical semantics.

## Test Results

- Initial worktree check: `PASSED` (clean; correct branch and baseline)
- Remote develop baseline check: `PASSED` (`1e382ab2e31d3fe2fbb9eb6068aeaae95428e894`)
- PR #53 Vision Gateway presence: `PASSED` (`40b9191` is in the fixed baseline)
- Required demo asset presence: `PASSED` (`shared/demo-assets/medicine/images/acetaminophen-clean-v1.png`)
- Canonical identity/resolver/pipeline/risk/presentation uniqueness audit: `PASSED`
- Server route/DTO/test architecture audit: `PASSED`
- iOS capture/composition/cancellation architecture audit: `PASSED_WITH_LIMITATION` (a dedicated image-to-recognition boundary must be added before remote wiring)
- CI-equivalent iOS command discovery: `PASSED` (workflow-derived scheme and dynamically selected simulator)
- Phase 0 `git diff --check`: `PASSED`
- Phase 0 changed-file/stat review: `PASSED` (`NIGHT_RUN_STATE.md`, 167 lines before gate-result update)
- Phase 0 prohibited-file review: `PASSED` (no prohibited file modified)
- Phase-specific tests: `NOT_RUN`
- `git diff --check`: `NOT_RUN`
- Full regression: `NOT_RUN`
- iOS Simulator tests: `NOT_RUN`
- Real Zhipu smoke: `SKIPPED` (no supported API key environment variable present)
- Phase 2A focused evidence parsing tests: `PASSED` (15/15)
- Phase 2A Zhipu client regressions: `PASSED` (33/33)
- Phase 2A Vision request-model regressions: `PASSED` (12/12)
- Phase 2A full Server suite: `PASSED` (171 executed, 0 failures; 1 live network test skipped by explicit opt-in gate)
- Phase 2A `git diff --check`: `PASSED` (tracked and newly added files)
- Phase 2A changed-file/stat review: `PASSED` (5 files; gate snapshot before these result lines was `+774/-14`)
- Phase 2A prohibited-file review: `PASSED` (Vision implementation/tests and the run-state file only)
- Phase 2B focused controlled-search/resolver tests: `PASSED` (22/22)
- Phase 2B full Server suite: `PASSED` (193 executed, 0 failures; 1 live network test skipped by explicit opt-in gate)
- Phase 2B independent full Server re-run: `PASSED` (193 executed, 0 failures; 1 live network test skipped)
- Phase 2B `git diff --check`: `PASSED` (tracked and newly added files)
- Phase 2B changed-file/stat review: `PASSED` (4 files; gate snapshot before these result lines was `+1291/-4`)
- Phase 2B prohibited-file and secret review: `PASSED` (controlled recognition source/tests and run-state file only; no secret pattern found)
- Phase 2C focused recognition API/integration tests: `PASSED` (16/16)
- Phase 2C Server route regressions: `PASSED` (5/5)
- Phase 2C full Core suite: `PASSED` (365 executed, 0 failures)
- Phase 2C full Server suite: `PASSED` (209 executed, 0 failures; 1 live network test skipped by explicit opt-in gate)
- Phase 2C `git diff --check`: `PASSED`
- Phase 2C changed-file/stat review: `PASSED` (16 files including run state; gate snapshot `+2657/-6`)
- Phase 2C prohibited-file review: `PASSED` (no CI, signing, entitlement, project, Onboarding, Profile, risk-rule, or ActionCard mapping file modified)
- Phase 2C secret-pattern review: `PASSED` (no credential-like added value found)
- Phase 2C architecture/security review: `PASSED_WITH_LIMITATION` (`P0=0`, `P1=0`, three non-blocking `P2` limitations recorded below)

## Phase Change Records

### Phase 2A

- Modified: `server/Sources/SlowWalkServer/Vision/VisionRequestModels.swift`
- Modified: `server/Sources/SlowWalkServer/Vision/ZhipuVisionClient.swift`
- Modified: `server/Tests/SlowWalkServerTests/Vision/ZhipuVisionClientTests.swift`
- Added: `server/Tests/SlowWalkServerTests/Vision/RemoteMedicinePackageEvidenceTests.swift`
- Business/test diff before state updates: `+754/-10`
- Archived phase commit diff: `+777/-14` including state updates.
- Review findings: `P0=0, P1=0, P2=0`
- Limitation: the preflight plan anticipated a separate evidence source file; the final bounded type is colocated with the existing Zhipu client. This does not alter module ownership or behavior.

### Phase 2B

- Added: `server/Sources/SlowWalkServer/MedicineRecognition/MedicineEvidenceSearchProvider.swift`
- Added: `server/Sources/SlowWalkServer/MedicineRecognition/RemoteMedicineCandidateResolver.swift`
- Added: `server/Tests/SlowWalkServerTests/MedicineRecognition/RemoteMedicineCandidateResolverTests.swift`
- Business/test diff before state updates: `+1273/-0`
- Archived phase commit diff: `+1294/-4` including state updates.
- Final review findings: `P0=0, P1=0, P2=0`
- Resolved review finding: auxiliary-only evidence now participates in cross-medicine conflict detection while remaining unable to recall a candidate alone.
- Resolved review finding: a strong overlay match cannot open the resolver gate for a different medicine that shares an ordinary alias; cross-ID identity matches remain ambiguous.
- Package manifest changes: `NONE`

### Phase 2C

- Modified: `server/README.md`
- Modified: `server/Sources/SlowWalkServer/ApplicationFactory.swift`
- Added: `server/Sources/SlowWalkServer/MedicineRecognition/MedicinePackageEvidenceExtracting.swift`
- Added: `server/Sources/SlowWalkServer/MedicineRecognition/MedicineRecognitionAPIRequestValidator.swift`
- Added: `server/Sources/SlowWalkServer/MedicineRecognition/RemoteMedicineRecognitionController.swift`
- Added: `server/Sources/SlowWalkServer/MedicineRecognition/RemoteMedicineRecognitionService.swift`
- Modified: `server/Tests/SlowWalkServerTests/SlowWalkServerTests.swift`
- Added: `server/Tests/SlowWalkServerTests/MedicineRecognition/RemoteMedicineRecognitionServerTests.swift`
- Modified: `swift-packages/SlowWalkCore/Sources/SlowWalkAPIContracts/APIErrorDTO.swift`
- Modified: `swift-packages/SlowWalkCore/Sources/SlowWalkAPIContracts/SlowWalkAPI.swift`
- Added: `swift-packages/SlowWalkCore/Sources/SlowWalkAPIContracts/MedicineRecognitionDTOs.swift`
- Modified: `swift-packages/SlowWalkCore/Sources/SlowWalkClientCore/ClientFailures.swift`
- Modified: `swift-packages/SlowWalkCore/Tests/SlowWalkAPIContractsTests/APIContractsTests.swift`
- Added: `swift-packages/SlowWalkCore/Tests/SlowWalkAPIContractsTests/MedicineRecognitionDTOTests.swift`
- Added: `swift-packages/SlowWalkCore/Tests/SlowWalkClientCoreTests/ClientFailureMapperTests.swift`
- Business/test diff before final state updates: `+2616/-2`
- Phase commit gate snapshot: `+2657/-6` across 16 files including state updates.
- Review findings: `P0=0, P1=0, P2=3`
- Resolved review finding: timeout no longer waits for an extractor that ignores cancellation, and caller cancellation wins over a nearly simultaneous Provider error.
- Resolved review finding: invalid upstream Provider payloads remain fallback-eligible, while malformed future Server responses remain a distinct non-recoverable client protocol failure.
- Resolved review finding: the shared request DTO strictly rejects unknown top-level and capability fields, including health/profile fields; the duplicate Server-side wire contract was removed.
- API `requestID` semantics: correlation-only with no idempotency cache; repeated IDs are reprocessed and this is documented and tested.
- Package manifest changes: `NONE`

## Known Issues

- Real provider behavior cannot be verified in this run because no API key is available; Fake Client coverage remains required.
- The controlled demo catalog has no trusted manufacturer or approval identifiers; production matching for those fields remains unavailable until controlled metadata is supplied.
- The iOS app currently has no Server base URL configuration. Fake transport coverage and local fallback are not blocked; real iOS online smoke remains unavailable without an externally supplied URL.
- P2: the Server validates declared MIME and size but does not inspect image magic bytes; bytes are only forwarded through the bounded Provider request and never executed or decoded on the Server.
- P2: 2C has no explicit RiskEngine zero-call spy; its recognition controller/service dependency graph contains no RiskEngine or assessment dependency, and strict request decoding rejects health fields.
- P2: a deliberately cancellation-ignoring extractor task can remain alive briefly after the API timeout; the API returns without waiting, late output cannot be published, and the production URLSession transport cooperates with cancellation.

## Blockers

- None.

## Next Action

- Complete the Phase 2C diff/prohibited-scope/secret gates, create and push the phase commit and annotated checkpoint, then archive its SHA in a state-only commit before beginning the iOS remote adapter.

## Safety Record

- Force push used: `NO`
- Pushed history amended or rebased: `NO`
- Tests bypassed: `NO`
- Auto-merge enabled: `NO`
- develop modified or merged: `NO`
- Secrets observed or committed: `NO`
