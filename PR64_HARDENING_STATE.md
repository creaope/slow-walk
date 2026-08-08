# PR64 Hardening State

## Baseline

- Repository: `creaope/slow-walk`
- Working directory: `~/Developer/slow-walk-zhipu-night`
- Branch: `feature/zhipu-online-medicine-mainline`
- Local HEAD at start: `c769917023f46a1b04941550765488179402bf3f`
- Remote feature HEAD at start: `c769917023f46a1b04941550765488179402bf3f`
- `origin/develop` HEAD: `1e382ab2e31d3fe2fbb9eb6068aeaae95428e894`
- PR number: `#64`
- PR state at start: `OPEN`, `DRAFT`, base `develop`, auto-merge disabled
- Start time: `2026-08-06 09:00:56 +0800` (`Asia/Shanghai`)
- Worktree cleanliness: `CLEAN`; no tracked modifications, staged changes, or
  untracked files were present.
- Git operation state: no merge, rebase, cherry-pick, or revert was in progress.
- PR #64 preservation check: local and remote feature refs matched the fixed
  starting HEAD, and both `git diff --name-status` and
  `git ls-files --others --exclude-standard` were empty.
- Stage 0 checkpoint pre-existence check:
  `checkpoint/pr64-hardening-0-baseline` did not exist at the start.
- Existing checkpoint audit: `PASS` (`7/7` present after
  `git fetch origin --prune --tags`):
  - `checkpoint/zhipu-night-0-preflight`
  - `checkpoint/zhipu-night-2a-evidence`
  - `checkpoint/zhipu-night-2b-resolution`
  - `checkpoint/zhipu-night-2c-server-api`
  - `checkpoint/zhipu-night-3-ios-client`
  - `checkpoint/zhipu-night-4-composition`
  - `checkpoint/zhipu-night-5-final`

## Deployment Decision

- Deployment mode: `LOCAL_MACHINE_DEMO`
- Simulator topology:
  `iOS Simulator -> http://127.0.0.1:<port> -> SlowWalk Server on the current Mac -> Zhipu Provider`
- Physical-device topology:
  `iPhone -> same trusted LAN as Server Mac -> http://<Mac LAN IP>:<port> -> SlowWalk Server -> Zhipu Provider`
- Public exposure: `FORBIDDEN`
- Port forwarding: `FORBIDDEN`
- Public tunnel: `FORBIDDEN`
- Public domain: `NOT CONFIGURED`
- Internet-facing listener: `FORBIDDEN`
- Provider key location: Server process environment only for this demo, through
  `ZHIPU_API_KEY`. The implementation's macOS debug Keychain fallback is not the
  selected deployment source.
- iOS key location: `NONE`; a Zhipu API key in the app, app configuration, or app
  bundle is `FORBIDDEN`.
- Trusted LAN requirement: the iPhone and Server Mac must share the same trusted
  local network.
- macOS firewall requirement: allow only the local-network access needed for the
  bounded demo.
- Server shutdown requirement: stop the Server immediately after the demo.
- Health-data rule: user health profiles and medication records must not be sent
  to the Provider.
- Recognition request boundary: App-to-Server Medicine Recognition requests may
  contain only the image, MIME type, request ID, API version, and non-health
  client capability information. The Server-to-Provider request is narrower and
  must contain no health profile.

The following remain explicitly out of scope for this local demo baseline:

- User accounts
- Public API Gateway
- Long-lived static client credentials
- OAuth
- Complex distributed rate limiting
- Cloud deployment
- Public certificate configuration

The following controls remain required:

- Request-body and decoded-image size limits
- Timeouts and cancellation propagation
- Redirect rejection
- Redacted, path-only request logging
- Server-only Provider credential storage
- Fail-closed on-device-only behavior when the local service URL is missing or
  invalid
- Local OCR fallback only for explicitly recoverable failures; the open P1 below
  means the current implementation does not yet satisfy this invariant

## Current Findings

| Item | Current behavior | Evidence path | Status | Required follow-up |
| --- | --- | --- | --- | --- |
| Server bind address | The stock executable uses `127.0.0.1`; `Application` receives the configured hostname directly. | `server/Sources/SlowWalkServer/SlowWalkServerConfiguration.swift:6`; `server/Sources/SlowWalkServer/ApplicationFactory.swift:204`; `server/Sources/SlowWalkServerApp/main.swift:5` | `PASS_SIMULATOR`; `BLOCKED_PHYSICAL_DEVICE` | Preserve loopback as the default. Add a bounded, explicit trusted-LAN host injection path before device testing. |
| Server port configuration | Default port is `8080`. The public Swift initializer accepts another integer, but the stock executable has no environment or CLI loader. | `server/Sources/SlowWalkServer/SlowWalkServerConfiguration.swift:6`; `server/Sources/SlowWalkServerApp/main.swift:5`; `server/README.md:12` | `FOLLOW_UP_REQUIRED` | Add validated runtime host/port configuration while retaining safe defaults. |
| Public bind guard | The stock executable cannot be switched by environment to a public bind. The public configuration accepts arbitrary host strings and has no loopback/private-LAN allowlist. | `server/Sources/SlowWalkServer/SlowWalkServerConfiguration.swift:1`; `server/Sources/SlowWalkServerApp/main.swift:5` | `SAFE_BY_DEFAULT`; `GUARD_MISSING_FOR_FUTURE_INJECTION` | When host injection is added, reject wildcard/public addresses and document trusted-LAN-only use. |
| iOS Base URL injection | Priority is explicit URL, `ProcessInfo` environment, then generated Info.plist. No URL is committed in the shared scheme or app build settings. | `ios/SlowWalkApp/Services/MedicineRecognition/MedicineRecognitionServerConfiguration.swift:15`; `ios/SlowWalkApp.xcodeproj/xcshareddata/xcschemes/SlowWalkApp.xcscheme:54`; `ios/README.md:62` | `PARTIAL` | Define a non-secret launch/runbook injection for each local topology; do not commit a machine-specific IP. |
| Simulator loopback URL | App policy accepts HTTP only for `localhost`, `127.0.0.1`, and `::1`. Inject `SLOWWALK_MEDICINE_RECOGNITION_BASE_URL=http://127.0.0.1:<port>` into the app launch environment. It is not injected by default. | `ios/SlowWalkApp/Services/MedicineRecognition/MedicineRecognitionServerConfiguration.swift:72`; `ios/SlowWalkApp/Services/MedicineRecognition/URLSessionOnlineMedicineRecognitionRequester.swift:396`; `ios/SlowWalkAppTests/MedicineRecognition/MedicineRecognitionServerConfigurationTests.swift:51` | `CONFIGURABLE_NOT_RUNTIME_VALIDATED` | Run a real Simulator-to-loopback Server check and record the observed ATS result. |
| Physical-device LAN URL | The same base URL key is the intended injection point, but both iOS URL policy layers reject plaintext HTTP to a non-loopback LAN IP. The stock Server also remains loopback-only. | `ios/SlowWalkApp/Services/MedicineRecognition/MedicineRecognitionServerConfiguration.swift:72`; `ios/SlowWalkApp/Services/MedicineRecognition/URLSessionOnlineMedicineRecognitionRequester.swift:396`; `server/Sources/SlowWalkServer/SlowWalkServerConfiguration.swift:6` | `BLOCKED` | Add a narrowly validated trusted-LAN HTTP policy, a safe Server LAN bind path, and physical-device tests. |
| ATS | The app uses a generated Info.plist. No `NSAppTransportSecurity`, `NSAllowsLocalNetworking`, arbitrary-load, or exception-domain setting exists. Whether an ATS local-network exception is required for the selected Simulator/device runtime cannot be established from this repository. | `ios/SlowWalkApp.xcodeproj/project.pbxproj:464`; `ios/SlowWalkApp.xcodeproj/project.pbxproj:509` | `UNKNOWN` | Validate on the target Simulator and physical iOS version; add only the narrowest required local-network setting. |
| Local Network permission | No `NSLocalNetworkUsageDescription`, `NSBonjourServices`, entitlement, or Bonjour discovery configuration is committed. Direct-LAN runtime behavior and the exact declaration required cannot be established from this repository. | `ios/SlowWalkApp.xcodeproj/project.pbxproj:464`; `ios/SlowWalkWidget/Info.plist:5` | `UNKNOWN` | Resolve through target-device validation before the LAN demo and add a truthful purpose string if required. |
| Provider credential loading | Server reads `ZHIPU_API_KEY`; if the key is absent, macOS may use the named debug Keychain item. An explicitly empty environment value fails instead of falling through. iOS production code does not load the key or construct Provider authorization. | `server/Sources/SlowWalkServer/Vision/ZhipuVisionRuntimeConfiguration.swift:63`; `server/Sources/SlowWalkServer/Vision/ZhipuVisionRuntimeConfiguration.swift:82`; `server/Sources/SlowWalkServer/Vision/ZhipuVisionClient.swift:428`; `ios/SlowWalkAppTests/MedicineRecognition/MedicineRecognitionServerConfigurationTests.swift:143` | `PASS` | For this frozen demo, supply the key only through the Server environment. Never place a real key in `.env.example`, iOS settings, or the app bundle. |
| Missing-configuration fallback | Missing, blank, or invalid iOS base URL produces `.unavailable`; `AppEnvironment` constructs local recognition and forces submission mode to `.onDeviceOnly`. | `ios/SlowWalkApp/Services/MedicineRecognition/MedicineRecognitionServerConfiguration.swift:18`; `ios/SlowWalkApp/App/AppEnvironment.swift:138`; `ios/SlowWalkApp/App/AppEnvironment.swift:167` | `PASS` | Preserve fail-closed behavior while adding local-demo configuration. |
| Logging boundary | Request middleware logs method and path only, not query/header/body. Recognition logs contain request ID, status, stable error code, and HTTP status. Actual external log backend and retention are not defined in the repository. | `server/Sources/SlowWalkServer/PathOnlyRequestLoggingMiddleware.swift:13`; `server/Sources/SlowWalkServer/MedicineRecognition/RemoteMedicineRecognitionController.swift:143`; `server/Sources/SlowWalkServer/MedicineRecognition/RemoteMedicineRecognitionController.swift:258` | `CODE_BOUNDARY_PASS`; `RUNTIME_BACKEND_UNKNOWN` | Preserve redaction and verify local runtime log collection/retention before real smoke. |
| Health-data boundary | The strict App-to-Server DTO contains image Base64, MIME, request ID, optional non-health fallback capability, and API version; unknown fields are rejected. The Server-to-Provider body contains the evidence prompt and image but no health profile, medication record, or risk assessment input. | `swift-packages/SlowWalkCore/Sources/SlowWalkAPIContracts/MedicineRecognitionDTOs.swift:42`; `swift-packages/SlowWalkCore/Sources/SlowWalkClientCore/OnlineMedicineRecognitionContracts.swift:4`; `server/Sources/SlowWalkServer/Vision/VisionRequestModels.swift:114` | `PASS` | Keep this compile-time and decoding boundary; inspect the bounded real smoke payload without logging image content. |
| Request safeguards | iOS has a 4 MiB upload limit, 40-second request/resource timeout, cancellation checks, and redirect rejection. Server has 6 MiB body and 4 MiB decoded-image limits plus recognition timeout/cancellation. Server magic-byte validation remains absent. | `ios/SlowWalkApp/Services/MedicineRecognition/URLSessionOnlineMedicineRecognitionRequester.swift:5`; `ios/SlowWalkApp/Services/MedicineRecognition/URLSessionOnlineMedicineRecognitionRequester.swift:29`; `server/Sources/SlowWalkServer/MedicineRecognition/MedicineRecognitionAPIRequestValidator.swift:18`; `server/Sources/SlowWalkServer/MedicineRecognition/RemoteMedicineRecognitionService.swift:25` | `PARTIAL`; `P2_OPEN` | Preserve existing controls and add Server-side image magic-byte validation in the planned P2 stage. |

## Audit Answers

1. Simulator injection: use the app process environment key
   `SLOWWALK_MEDICINE_RECOGNITION_BASE_URL` with
   `http://127.0.0.1:<port>`. There is no committed default injection.
2. Physical-device injection: the same key is the intended non-secret source for
   `http://<Mac LAN IP>:<port>`, but the current iOS policy rejects that URL and
   the stock Server cannot bind to the LAN. This topology is currently blocked.
3. Current Server default: `127.0.0.1:8080`.
4. Server host/port environment support: `NO`. Only programmatic initializer
   arguments exist.
5. Current iOS local HTTP support: application policy allows named loopback only;
   LAN HTTP is rejected. Actual loopback transport under ATS is `UNKNOWN` until
   runtime validation.
6. ATS local-network exception requirement: `UNKNOWN` from repository evidence.
7. `NSLocalNetworkUsageDescription` requirement: the declaration is absent; the
   exact runtime requirement is `UNKNOWN` from repository evidence and must be
   resolved before physical-device validation.
8. Missing configuration behavior: `YES`, it fails closed to on-device-only and
   does not create the online requester.
9. Provider API key boundary: `YES`, production loading and Provider
   authorization occur only in Server code. No iOS production key was found.
10. Accidental public binding: not through the stock executable or environment;
    however, the public configuration accepts an arbitrary explicit host and has
    no address allowlist.
11. Minimum file range before a physical-device demo: Server runtime
    host/port configuration plus tests; the two iOS URL-policy points plus tests;
    the generated app Info.plist build settings only if ATS/local-network
    validation proves them necessary; and the two deployment runbooks. Device
    signing requirements remain `UNKNOWN` and must be handled separately.
12. Tests possible without code changes: Server SwiftPM unit/integration tests;
    iOS Simulator build and `SlowWalkAppTests`; mocked URLSession tests for base
    URL, timeout, cancellation, redirect, size, and DTO boundaries; Server
    loopback `/health`; missing-credential fail-closed checks; and a real
    Simulator loopback attempt. The guarded Zhipu live smoke can run only with
    explicit network opt-in and a Server-side credential, but it is not a full
    Medicine Recognition or iOS-to-Server end-to-end test. Physical-device LAN
    end-to-end is not currently possible.

## Known PR #64 Findings

These findings are carried forward as open. Stage 0 does not resolve them.

| Priority | Finding | Status | Evidence or note |
| --- | --- | --- | --- |
| P1 | Provider contract violation may enter local fallback | `OPEN` | Provider malformed/invalid payload mappings remain fallback-eligible in `server/Sources/SlowWalkServer/MedicineRecognition/RemoteMedicineRecognitionController.swift:331`. |
| P1 | Deployment model previously undefined | `OPEN` | The local-machine decision is frozen here, but implementation, runbook, ATS, and device validation remain incomplete. |
| P2 | Server image magic-byte validation | `OPEN` | Server validator checks declared MIME, Base64, and size, but not image magic bytes. |
| P2 | RiskEngine zero-call spy | `OPEN` | Carried forward; not changed or re-audited in Stage 0. |
| P2 | Shared Server/iOS fixtures | `OPEN` | Carried forward; not changed or re-audited in Stage 0. |
| P2 | End-to-end extreme projection fixture | `OPEN` | Carried forward; not changed or re-audited in Stage 0. |
| Validation | Real Provider smoke not yet run | `OPEN` | Existing opt-in smoke is narrower than the full recognition endpoint. |
| Validation | iOS-to-Server real end-to-end not yet run | `OPEN` | Simulator runtime remains unverified; physical-device LAN is blocked by current configuration. |

No P0 finding was recorded at the Stage 0 baseline. This is not a new independent
P0/P1/P2 review.

## Planned Stages

1. Fix fallback contract
2. Finalize local deployment configuration
3. Run bounded real Zhipu smoke
4. Run Simulator and physical-device end-to-end validation
5. Address high-value P2 items
6. Independent review and PR readiness decision

## Stage 0 Result

- Status: `PASS` for the fixed-head audit and local deployment baseline record.
- Files changed: only `PR64_HARDENING_STATE.md` was added.
- Tests/checks: specified Git baseline commands, operation-marker audit,
  checkpoint audit, target-tag absence check, PR state/auto-merge check,
  repository-wide deployment configuration searches, and scoped static code
  review. No build, unit, integration, live Provider, Simulator runtime, or
  physical-device test was executed in Stage 0.
- Commit SHA: intentionally resolved from Git after commit; a commit cannot
  embed its own SHA in its committed tree. The authoritative value is the commit
  referenced by the checkpoint tag and the Stage 0 final report.
- Checkpoint tag: `checkpoint/pr64-hardening-0-baseline`
- Remaining blockers: both open P1 findings; physical-device Server binding and
  iOS LAN HTTP policy; ATS and Local Network `UNKNOWN` items; real Provider smoke;
  real Simulator and physical-device end-to-end validation; all listed P2 work.
- Next action: Stage 1 may modify only the fallback-contract path and focused
  tests needed to prove non-recoverable Provider contract violations never enter
  local OCR fallback. Do not enter Stage 1 as part of this checkpoint.
