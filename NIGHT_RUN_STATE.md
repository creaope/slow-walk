# Zhipu Online Medicine Recognition Night Run

## Run Metadata

- Fixed baseline SHA: `1e382ab2e31d3fe2fbb9eb6068aeaae95428e894`
- Branch: `feature/zhipu-online-medicine-mainline`
- Start time: `2026-08-05 23:55:56 CST (+0800)`
- Current phase: `Phase 5 - full regression and smoke`
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
| 2C - Server recognition API | PASSED | `758b6bdc8027d16b19b6baa52390de8377774ad9` | `90123f98d4e6877147b396e9c2e4c6e078a5fe61` | `checkpoint/zhipu-night-2c-server-api` | Core 365/365 and Server 209/209 passed; 1 live smoke skipped |
| 3 - iOS remote adapter | PASSED | `27342c40dee61da1d77603e4d48b60ff05886b1b` | `817f11f34ff151f6f40a6cf17fe00830c7b137af` | `checkpoint/zhipu-night-3-ios-client` | Core 392/392, Server 211/211, and iOS Simulator 29/29 passed; 1 credential-gated live test skipped |
| 4 - Remote-first composition | PASSED_WITH_LIMITATION | `50b469c5fde1badca493befb11fa52f939a5ab2e` | `4776fdf5775b29db41dd2bbf9403f090aa5be481` | `checkpoint/zhipu-night-4-composition` | Core 414/414, Presentation 74/74, Server 211/211, and final iOS composition 89/89 passed; P0=0, P1=0, P2=2 |
| 5 - Full regression and smoke | IN_PROGRESS | PENDING | PENDING | PENDING | Core 414/414, Presentation 74/74, Server 212/212, and iOS Simulator 387/387 passed; final independent review pending |

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
- Phase 5 phase-specific tests: `PASSED` (Core 414/414, Presentation 74/74, Server 212/212; 0 failures)
- Phase 5 `git diff --check`: `PASSED`
- Phase 5 full regression: `PASSED` (all required SwiftPM and iOS suites passed)
- Phase 5 iOS Simulator tests: `PASSED` (387/387 across 26 suites; workflow-selected iPhone Air, iOS 26.5; `** TEST SUCCEEDED **`)
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
- Phase 3 read-only client/image/transport audit: `PASSED` (dedicated health-free boundary required; no manifest, project, dependency, composition, risk, or presentation change required)
- Phase 3 Core response-mapper tests: `PASSED` (27/27 focused; 392/392 full Core, independently re-run)
- Phase 3 Server projection compatibility tests: `PASSED` (2/2 focused; 211/211 full Server, 1 live network test skipped by explicit opt-in gate)
- Phase 3 iOS image preparation tests: `PASSED` (9/9 focused Simulator tests)
- Phase 3 iOS URLSession requester tests: `PASSED` (20/20 focused Simulator tests)
- Phase 3 final independent iOS Simulator run: `PASSED` (29/29 across image preparation and URLSession requester on workflow-selected iPhone Air, iOS 26.5; `** TEST SUCCEEDED **`)
- Phase 3 final architecture/security review: `PASSED_WITH_LIMITATION` (`P0=0`, `P1=0`, three non-blocking `P2` items recorded below)
- Phase 3 post-state archive test gate: `PASSED` (Core mapper 27/27, Server projection 2/2, iOS Simulator 29/29)
- Phase 3 `git diff --check`: `PASSED`
- Phase 3 changed-file/stat review: `PASSED` (10 files; staged snapshot before these result lines was `+4710/-13`)
- Phase 3 prohibited-file review: `PASSED` (no CI, signing, entitlement, project, Onboarding, Profile, risk-rule, ActionCard mapping, or Presentation file modified)
- Phase 3 secret-pattern review: `PASSED` (no credential value found; the sole broad-pattern hit was the defensive `baseURL.password == nil` check)
- Phase 3 canonical-implementation review: `PASSED` (one existing MedicineResolver, MedicinePipeline, MedicationRiskEngine, and ActionCardFactory implementation remains)
- Phase 4 Core routing/composition tests: `PASSED` (19/19 focused; 414/414 full Core)
- Phase 4 Presentation source-notice tests: `PASSED` (6/6 focused, 1/1 view order; 74/74 full Presentation)
- Phase 4 Server regression: `PASSED` (211/211, 0 failures; 1 live network test skipped by explicit opt-in gate)
- Phase 4 iOS focused composition tests: `PASSED` (73/73 across four suites after one localized asynchronous test synchronization fix; 0 failures)
- Phase 4 independent iOS privacy/configuration review: `PASSED` (14/14; `P0=0`, `P1=0`)
- Phase 4 neutral capability/configuration regression: `PASSED` (26/26 across two suites on iPhone 17 Pro Simulator, iOS 26.5; `** TEST SUCCEEDED **`)
- Phase 4 final combined iOS composition gate: `PASSED` (89/89 across five suites on iPhone 17 Pro Simulator, iOS 26.5; 0 failures; `** TEST SUCCEEDED **`)
- Phase 4 repository `git diff --check`: `PASSED` after the final privacy-copy correction
- Phase 4 staged `git diff --check`: `PASSED` (all tracked and newly added files)
- Phase 4 changed-file/stat review: `PASSED` (28 files; staged snapshot before final state additions was `+2958/-130`)
- Phase 4 prohibited-file review: `PASSED` (no CI workflow, Package manifest, entitlement, Onboarding, Profile, risk-rule, or ActionCard file modified)
- Phase 4 project-setting review: `PASSED` (`project.pbxproj` changes are limited to Debug/Release camera and photo-library usage descriptions; no signing, team, entitlement, or bundle identifier change)
- Phase 4 secret/log review: `PASSED` (no production logging calls or credential value; the only broad-pattern hit is the explicit fake `Bearer not-a-real-token` negative test fixture)
- Phase 4 canonical-implementation review: `PASSED` (one existing MedicineResolver, MedicinePipeline, MedicationRiskEngine, and ActionCardFactory implementation remains)
- Phase 5 iOS CI command audit: `PASSED` (read from `.github/workflows/ios-app.yml`; `SlowWalkApp` scheme, dynamically selected available iPhone Simulator, signing disabled)
- Phase 5 full Core suite: `PASSED` (414 executed, 0 failures; repeated after request-log remediation)
- Phase 5 full Presentation suite: `PASSED` (74 executed, 0 failures; repeated after request-log remediation)
- Phase 5 full Server suite: `PASSED` (212 executed, 0 failures; 1 live network test skipped by explicit opt-in gate after request-log remediation)
- Phase 5 workflow-equivalent iOS suite: `PASSED` (387 executed, 0 failures on dynamically selected iPhone Air, iOS 26.5)
- Phase 5 post-remediation iOS applicability audit: `PASSED` (the remediation changes Server-only source/tests and run state; no iOS/Core/Presentation source changed after the 387/387 Simulator gate)
- Phase 5 fixed demo asset audit: `PASSED` (`acetaminophen-clean-v1.png`, 922218 bytes, SHA-256 `ca50f3f9e570df70b6ac7109076f2075e141279025349a39bdd233858a47164f`, unchanged from baseline)
- Phase 5 real Zhipu smoke decision: `SKIPPED` (`RUN_ZHIPU_LIVE_SMOKE`, `ZHIPU_API_KEY`, and `BIGMODEL_API_KEY` are absent; no real request was attempted)
- Phase 5 cumulative changed-file/stat review: `PASSED` (55 files; committed snapshot before final state records was `+12591/-137`)
- Phase 5 prohibited-file review: `PASSED` (no CI, Package manifest, entitlement, Onboarding, Profile, risk-rule, or ActionCard file modified)
- Phase 5 canonical-implementation review: `PASSED` (one MedicineResolver, MedicinePipeline, MedicationRiskEngine, and ActionCardFactory implementation remains)
- Phase 5 recognition logging review: `PASSED` after remediation (global request logs now record path and method only; recognition logs contain request ID, stable recognition/error code, and HTTP status only; no query, image, response body, API key, Authorization, or health value)
- Phase 5 secret-pattern review: `PASSED` (no credential value; two broad-pattern hits are explicit negative-test markers: `Bearer not-a-real-token` and `provider-body-secret Bearer api-key-secret`)
- Phase 5 remote checkpoint audit: `PASSED` (all Phase 0/2A/2B/2C/3/4 annotated tags exist remotely and dereference to their recorded implementation commits)
- Phase 5 interim develop check: `PASSED` (`origin/develop` remains `1e382ab2e31d3fe2fbb9eb6068aeaae95428e894`)
- Phase 5 request-log P1 remediation attempt 1: `FAILED` at compile time because the new middleware/factory/test did not explicitly import the existing transitive `Logging` module; no test or production request ran. The next targeted repair adds explicit imports and Context specialization without changing the design.
- Phase 5 request-log P1 remediation attempt 2: `PASSED` (application-level captured-log regression 1/1; fixed path and method retained, query image/health keys and markers absent from every log entry)
- Phase 5 request-log enhanced regression: `PASSED` (1/1 after adding an Authorization marker; query image/health markers and authorization header value are absent from all captured logs)
- Phase 5 resolved review finding: the prior global logger rendered complete URIs; it is replaced by a path-only middleware and the full Server suite passed 212/212. Current review count returns to `P1=0` pending independent confirmation.
- Phase 5 independent request-log review: `PASSED` (`P0=0`, `P1=0`; targeted 1/1 and Server 212/212 independently repeated). The identified test-only body Base64 canary gap was closed and targeted 1/1 plus full Server 212/212 passed again.
- Phase 5 final staged `git diff --check`: `PASSED` (all tracked and newly added Phase 5 files)
- Phase 5 final changed-file/stat review: `PASSED` (4 files; staged snapshot before these gate-result lines was `+227/-15`)
- Phase 5 final cumulative stat review: `PASSED` (56 files from fixed baseline; snapshot before these gate-result lines was `+12805/-139`)
- Phase 5 final prohibited/security/architecture review: `PASSED` (`P0=0`, `P1=0`; no prohibited path, credential, complete-URI log, or duplicate canonical/pipeline/risk/ActionCard implementation)

### Phase 5 Final Validation

- Online success recognition: `PASSED_WITH_LIMITATION` (Fake Provider Server integration resolves through the canonical resolver; iOS composition calls remote once, local zero times, and reports `remote`; real Provider smoke was not credential-enabled).
- Recoverable online failure enters local fallback: `PASSED` (offline, timeout, 429, Server unavailable, and Provider unavailable are whitelisted; result provenance is `localFallback`).
- Ambiguous/no-candidate/conflicting result is not silently covered by local recognition: `PASSED` (semantic outcomes call local zero times and remain confirmation/unresolved states).
- Cancellation prevents late-result publication: `PASSED` (generation and cancellation barriers reject predecessor results after replacement).
- Rapid duplicate submission is suppressed: `PASSED` (the full Simulator suite includes the rapid-shutter one-capture/one-recognition regression).
- Image, Authorization, Provider body, and health markers are absent from recognition logs: `PASSED` (path-only global logging plus application-level query/header/body canaries; strict DTO rejects health/profile fields).
- Recognition continues through the existing MedicinePipeline: `PASSED` (the router returns the existing `MedicineRecognitionInput`; `LocalMedicineAssessmentRequester` remains the single pipeline adapter).
- RiskEngine remains singular and unchanged: `PASSED` (one `MedicationRiskEngine` implementation; no risk-rule file changed).
- Presentation mapping remains singular: `PASSED` (one `MedicineStateMapper`; only non-medical source/degradation notice added, no ActionCard semantic mapping added).
- Onboarding and Profile remain unmodified: `PASSED` (baseline-to-current changed-path audit has no matching file).
- Final independent review: `P0=0`, `P1=0`, `P2=9` (three permitted operational/data/deployment limitations and six non-blocking technical limitations listed below).

### Phase 5 Implementation

- Added: `server/Sources/SlowWalkServer/PathOnlyRequestLoggingMiddleware.swift`.
- Modified: `server/Sources/SlowWalkServer/ApplicationFactory.swift` to install path-only request logging and accept an internal test logger.
- Modified: `server/Tests/SlowWalkServerTests/MedicineRecognition/RemoteMedicineRecognitionServerTests.swift` with application-level query/header/body log canaries.
- Business/test diff excluding the run-state file before final state additions: `+175/-5`.
- Package manifest, dependency, route, DTO, medical rule, canonical resolver, pipeline, RiskEngine, ActionCard, CI, signing, entitlement, bundle identifier, Onboarding, and Profile changes: `NONE`.

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
- Implementation commit: `758b6bdc8027d16b19b6baa52390de8377774ad9` (pushed)
- Annotated checkpoint: `checkpoint/zhipu-night-2c-server-api` (pushed and verified to dereference to the implementation commit)

### Phase 3 Audit

- Planned Core additions: health-free online recognition request/result/failure protocol and strict Server-response mapper.
- Planned iOS additions: bounded orientation-normalizing JPEG preparer and URLSession requester with redirect rejection and a 1 MiB response ceiling.
- Phase boundary: `AppEnvironment`, capture ownership, online/local composition, canonical conflict handling, and visible fallback source remain Phase 4 work.
- Existing stale/duplicate ownership: `MedicineCaptureViewModel` already owns one processing task, generation checks, cancellation barriers, and late-result suppression; Phase 3 remains a stateless adapter.
- Package/project changes required: `NONE` (SwiftPM and Xcode synchronized groups auto-discover sources/tests).
- Third-party dependencies required: `NONE`.

### Phase 3 Implementation

- Added: `swift-packages/SlowWalkCore/Sources/SlowWalkClientCore/OnlineMedicineRecognitionContracts.swift`
- Added: `swift-packages/SlowWalkCore/Sources/SlowWalkClientCore/OnlineMedicineRecognitionResponseMapper.swift`
- Added: `swift-packages/SlowWalkCore/Tests/SlowWalkClientCoreTests/OnlineMedicineRecognitionResponseMapperTests.swift`
- Added: `ios/SlowWalkApp/Services/MedicineRecognition/MedicineRecognitionImagePreparer.swift`
- Added: `ios/SlowWalkApp/Services/MedicineRecognition/URLSessionOnlineMedicineRecognitionRequester.swift`
- Added: `ios/SlowWalkAppTests/MedicineRecognition/MedicineRecognitionImagePreparerTests.swift`
- Added: `ios/SlowWalkAppTests/MedicineRecognition/URLSessionOnlineMedicineRecognitionRequesterTests.swift`
- Modified: `server/Sources/SlowWalkServer/MedicineRecognition/RemoteMedicineRecognitionController.swift`
- Modified: `server/Tests/SlowWalkServerTests/MedicineRecognition/RemoteMedicineRecognitionServerTests.swift`
- Business/test lines before final state updates: `+4665/-8`.
- Core request boundary contains image and correlation ID only; health/profile/history values cannot be represented.
- iOS transport normalizes to bounded JPEG, uses an ephemeral URLSession, rejects redirects, requires HTTPS except loopback development URLs, caps streamed responses at 1 MiB, and never retries.
- Stable transport/semantic errors remain distinct; cancellation propagates as `CancellationError`.
- Resolved review finding: recognized responses cannot promote empty, conflicting, ordinary-alias-only, malformed, or out-of-bound evidence into the canonical pipeline.
- Resolved review finding: HTTP success/provider status pairs, content type, request ID, API version, response URL, redirects, cancellation races, and declared/streamed response sizes are strictly validated.
- Resolved review finding: Server bounded summaries always retain the selected canonical candidate and the alias plus independent packaging/manufacturer witnesses needed to validate corroborated recognition.
- Package manifest and Xcode project changes: `NONE`.
- Final review findings: `P0=0, P1=0, P2=3`.
- Implementation commit: `27342c40dee61da1d77603e4d48b60ff05886b1b` (pushed and remote branch verified).
- Annotated checkpoint: `checkpoint/zhipu-night-3-ios-client` (pushed and verified to dereference to the implementation commit).

### Phase 4 Audit

- Composition point: extend the existing `MedicineAssessmentCoordinator` recognition-input boundary; retain its single active task, generation, cancellation, and state stream.
- Planned Core addition: a stateless remote-first recognition router returning the existing `MedicineRecognitionInput`, source provenance, optional fallback reason, and remote expected canonical identity.
- Approved fallback only: local-only/privacy mode, offline, timeout, rate limit, Server unavailable, and Provider unavailable.
- Prohibited fallback: ambiguous, no candidate, unreadable, invalid response, invalid/oversized image, canonical conflict, and cancellation.
- Canonical safety: the existing local assessment requester still runs the sole MedicinePipeline/MedicineResolver/RiskEngine/ActionCardFactory; a remote result is published only when that pipeline's selected ID and name agree with the Server expectation.
- Provenance: `remote` or `localFallback` must survive pending confirmation and reach Presentation as non-medical context; fallback copy must not expose Provider or HTTP terminology.
- Privacy mode semantics: the mode is snapshotted for a submitted assessment; Settings changes affect the next submission rather than racing an active operation.
- Configuration limitation: the repository has no production iOS Server base URL. Composition will accept an externally supplied HTTPS URL and remain local-only when absent; no URL or credential will be invented.
- Privacy wording requirement: current capability/permission copy claims device-only behavior and must be updated wherever online recognition is enabled; any Xcode project edit is limited to usage-description text and must not touch signing, entitlements, or bundle identifiers.
- Package manifest changes required: `NONE`.
- Third-party dependencies required: `NONE`.
- Implementation ownership is split across non-overlapping boundaries: Core routing/coordinator, iOS preference/configuration, and Presentation source notice. `AppEnvironment`, runner, submitter, Settings, capability wording, and privacy usage descriptions remain the single root-agent composition pass after those types stabilize.
- Privacy usage-description correction completed: Debug and Release camera/photo prompts now disclose conditional upload to the configured recognition service and the device-only setting. No signing, entitlement, bundle identifier, or capability setting changed.
- Capability-source update completed: the historical `.phase0` fixture remains intact, while the current composition can now truthfully distinguish device-only operation from optional online-first recognition with a real local fallback. This availability vocabulary is not connected to risk levels or medical rules.
- Capability model tests added for distinct hybrid/local/online semantics and configuration-dependent mainline status; the final combined Simulator gate passed `89/89`.
- Presentation source/degradation mapping completed: remote success remains quiet; local-only and recoverable fallback use fixed non-technical notices that also render without recognition text. Focused notice tests passed 6/6, view-order test passed 1/1, full Presentation passed 74/74, and Presentation `git diff --check` passed.
- Core remote-first routing and canonical cross-check implementation passed its hardened gate: routing/Coordinator focused 19/19, full Core 414/414, and repository `git diff --check` passed. Candidate confirmation rejects a response whose selected ID differs from the exact user-selected candidate; request-ID mismatch, unknown-error no-fallback, stale return value, and resolved fallback-context regressions are directly covered.
- iOS composition implementation is wired and Simulator-validated: only a validated configured endpoint creates the remote requester; absent configuration forces the existing local-only coordinator; privacy mode is snapshotted once per submission; Settings copy distinguishes device-only, configured-online, and unconfigured-local behavior.
- iOS runbook updated with the endpoint configuration key and precedence, HTTPS/loopback policy, local-only behavior when unconfigured, privacy-mode snapshot semantics, health-data isolation, fallback whitelist, and current adapter validation limits.
- Phase 4 iOS focused Simulator first run: `69/70` passed. The sole failure was an existing confirmation test reading the asynchronously consumed state immediately after the runner completed; it was localized and the test now waits for the current gate's `.result` without weakening production validation. The targeted and complete focused reruns then passed; the first run is retained as diagnostic history and is not counted as a passed gate.
- Phase 4 iOS focused Simulator complete rerun: `73/73` across four suites, `0` failures, `xcodebuild` exit `0`. Covered configured remote success, recoverable Server failure to local fallback, remote ambiguity without local overwrite, configured privacy mode, missing endpoint local-only behavior, one-time mode snapshot, and nil/foreign request-ID filtering.
- Phase 4 root SwiftPM gate: full Core `414/414`, full Presentation `74/74`, and full Server `211/211` passed with `0` failures; the single Server live-network test remained skipped behind its explicit opt-in credential gate.
- iOS composition author review: `P0=0`, `P1=0`; focused Simulator `73/73`, Swift 6 configuration typecheck, whitespace checks, and production log/credential/body scans passed. `P2`: no production Server URL is stored in the repository; deployment must inject the documented key, and missing/invalid configuration intentionally stays device-only.
- Independent iOS review: `P0=0`, `P1=0`; independent privacy/configuration Simulator checks passed `14/14`. The reviewer found that configured capability copy said "online preferred" even when the user selected device-only mode; the capability copy was changed to neutral "online and offline available" wording and its focused regression passed `26/26`.
- Independent Core review: `P0=0`, `P1=0`; fallback whitelist, canonical witness rejection, confirmation binding, generation/cancellation, and single-pipeline boundaries passed. One non-blocking `P2` remains: public routing context initializers can represent combinations that production routers never emit; production constructors are valid and the broader API refactor is intentionally deferred.
- Architecture blocker: `NO` for implementation and Fake integration tests; real iOS online smoke remains limited by the absent deployment URL and Provider credential.

### Phase 4 Implementation

- Added: `ios/SlowWalkApp/Services/MedicineRecognition/MedicineRecognitionPreferences.swift`
- Added: `ios/SlowWalkApp/Services/MedicineRecognition/MedicineRecognitionServerConfiguration.swift`
- Added: `ios/SlowWalkAppTests/MedicineRecognition/MedicineRecognitionPreferencesTests.swift`
- Added: `ios/SlowWalkAppTests/MedicineRecognition/MedicineRecognitionServerConfigurationTests.swift`
- Added: `swift-packages/SlowWalkCore/Sources/SlowWalkClientCore/MedicineRecognitionRouting.swift`
- Added: `swift-packages/SlowWalkCore/Tests/SlowWalkClientCoreTests/MedicineAssessmentCoordinatorRoutingTests.swift`
- Added: `swift-packages/SlowWalkCore/Tests/SlowWalkClientCoreTests/MedicineRecognitionRoutingTests.swift`
- Added: `swift-packages/SlowWalkPresentation/Tests/SlowWalkPresentationTests/RecognitionNoticeTests.swift`
- Modified iOS composition: `ios/README.md`, `ios/SlowWalkApp.xcodeproj/project.pbxproj`, `AppEnvironment.swift`, `AppCapability.swift`, `MedicineAssessmentRunner.swift`, `MedicineAssessmentCaptureSubmitter.swift`, and `CareSettingsView.swift`.
- Modified iOS tests: `CapabilitySourceOfTruthTests.swift`, `CapabilityStatusTests.swift`, and `MedicineAssessmentRunnerTests.swift`.
- Modified Core: `ClientFailures.swift`, `ClientViewStates.swift`, `MedicineAssessmentCoordinator.swift`, and `ClientFailureMapperTests.swift`.
- Modified Presentation: `MedicinePresentationCopy.swift`, `MedicineStateMapper.swift`, `MedicineDisplayState.swift`, `MedicineAssessmentView.swift`, and `AccessibilityValueTests.swift`.
- Business/test diff excluding the run-state file: `+2931/-125`.
- Archived Phase 4 implementation diff: 28 files, `+2987/-134` including run-state updates.
- Final pre-archive review: `P0=0`, `P1=0`, `P2=2` (deployment URL injection and public routing-context representability limitations recorded below).
- Package manifest, CI workflow, signing, entitlement, bundle identifier, Onboarding, Profile, risk-rule, and ActionCard semantic changes: `NONE`.
- Third-party dependency changes: `NONE`.
- Implementation commit: `50b469c5fde1badca493befb11fa52f939a5ab2e` (pushed and remote branch verified).
- Annotated checkpoint: `checkpoint/zhipu-night-4-composition` (pushed and verified to dereference to the implementation commit).

## Known Issues

- P2 (operational): real Provider behavior cannot be verified because no API key is available; Fake Client coverage passed and the real smoke is `SKIPPED`.
- P2 (data): the controlled demo catalog has no trusted manufacturer or approval identifiers; production matching for those fields remains unavailable until controlled metadata is supplied.
- P2 (deployment): the repository intentionally contains no production iOS Server base URL value. The validated environment/Info dictionary configuration mechanism is implemented, but real iOS online smoke remains unavailable until deployment injects a URL.
- P2: the Server validates declared MIME and size but does not inspect image magic bytes; bytes are only forwarded through the bounded Provider request and never executed or decoded on the Server.
- P2: 2C has no explicit RiskEngine zero-call spy; its recognition controller/service dependency graph contains no RiskEngine or assessment dependency, and strict request decoding rejects health fields.
- P2: a deliberately cancellation-ignoring extractor task can remain alive briefly after the API timeout; the API returns without waiting, late output cannot be published, and the production URLSession transport cooperates with cancellation.
- P2: the strict iOS response mapper mirrors Server evidence-assurance rules for protocol validation; future rule changes require shared contract fixtures or an explicit stable assurance witness to prevent drift.
- P2: the Server's over-limit candidate/witness projection is covered at helper level; a controller-to-DTO-to-iOS-mapper extreme integration fixture remains a Phase 4/5 hardening opportunity.
- P2: public `MedicineRecognitionContext`/routing outcome initializers can represent inconsistent source/reason or missing-witness combinations, although the production remote-first and local-only routers emit only valid combinations.

## Blockers

- None.

## Next Action

- Create and push the Phase 5 implementation commit and annotated final checkpoint, then complete the final develop/state/cleanliness record in a state-only archive commit.

## Safety Record

- Force push used: `NO`
- Pushed history amended or rebased: `NO`
- Tests bypassed: `NO`
- Auto-merge enabled: `NO`
- develop modified or merged: `NO`
- Secrets observed or committed: `NO`
