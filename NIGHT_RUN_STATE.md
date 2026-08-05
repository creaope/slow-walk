# Zhipu Online Medicine Recognition Night Run

## Run Metadata

- Fixed baseline SHA: `1e382ab2e31d3fe2fbb9eb6068aeaae95428e894`
- Branch: `feature/zhipu-online-medicine-mainline`
- Start time: `2026-08-05 23:55:56 CST (+0800)`
- Current phase: `Phase 2A - structured medicine package evidence`
- Overall status: `IN_PROGRESS`
- Initial `origin/develop` SHA: `1e382ab2e31d3fe2fbb9eb6068aeaae95428e894` (verified against remote with `git ls-remote`)
- Final `origin/develop` SHA: `PENDING`
- Did develop move during the run: `PENDING`
- Real network smoke run: `NO - SKIPPED (required credential environment variable is absent)`
- Real API key used: `NO`

## Phase Status

| Phase | Status | Implementation commit | State-record commit | Checkpoint tag | Tests |
| --- | --- | --- | --- | --- | --- |
| 0 - Preflight | PASSED_WITH_LIMITATION | `775de0f2ec82ee1e1779f94c021011639ae29593` | PENDING (this record commit) | `checkpoint/zhipu-night-0-preflight` | Branch/baseline/remote/architecture/CI/assets audit passed; archive gates passed |
| 2A - Structured package evidence | IN_PROGRESS | PENDING | PENDING | PENDING | NOT_RUN |
| 2B - Controlled retrieval and verification | NOT_STARTED | PENDING | PENDING | PENDING | NOT_RUN |
| 2C - Server recognition API | NOT_STARTED | PENDING | PENDING | PENDING | NOT_RUN |
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

## Known Issues

- None identified yet.
- Real provider behavior cannot be verified in this run because no API key is available; Fake Client coverage remains required.
- The controlled demo catalog has no trusted manufacturer or approval identifiers; production matching for those fields remains unavailable until controlled metadata is supplied.
- The iOS app currently has no Server base URL configuration. Fake transport coverage and local fallback are not blocked; real iOS online smoke remains unavailable without an externally supplied URL.

## Blockers

- None.

## Next Action

- Implement the strict structured medicine package evidence contract by reusing the existing Zhipu transport/retry/cancellation boundary, then run the focused Vision regressions.

## Safety Record

- Force push used: `NO`
- Pushed history amended or rebased: `NO`
- Tests bypassed: `NO`
- Auto-merge enabled: `NO`
- develop modified or merged: `NO`
- Secrets observed or committed: `NO`
