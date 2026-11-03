# Unified Windows Installer P1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the offline-testable contract, discovery/evaluator, planner, rendering, recovery model, and deterministic preview builder for the unified Windows installer.

**Architecture:** Validated data records feed pure policy functions; a narrow read-only probe boundary supplies observations to the same evaluator in runtime and generated detection. A local builder resolves immutable inputs once and emits a digest-bound preview with no deployment entrypoint. Windows execution and durable storage, bundle transport, and Intune delivery follow in P2, P3, and P4 respectively.

**Tech Stack:** PowerShell; plain offline `pwsh` tests without Pester; .NET cryptography and ZIP APIs for the build. Runtime, shared discovery, and generated detector source must use the Windows PowerShell 5.1/.NET Framework 4.8 API and language subset; build/test tooling uses PowerShell 7.4 or newer. Actual 5.1 execution remains a P2 gate, including Unicode/JSON and command-line behavior.

**Spec:** [Reviewed foundation](../specs/2026-11-02-unified-installer-design.md), [recipe specimens](../../design/unified-installer/recipes.md), and [complete scenario matrix](../../design/unified-installer/scenarios.md). Read all three before implementation.

## Global Constraints

- Public documents contain no client names, device IDs, secrets, or home paths.
- Retain PSAppDeployToolkit 4.1.8 as the researched baseline; verify exact API claims.
- Provider APIs stay outside the execution engine. System and User scope are first-class.
- Unknown state is not absence; success requires postcondition verification.
- No runtime imports from live main, ambient modules, or “latest” URLs.
- A hash mismatch exits 1 and is not retried. Reject URL userinfo before any download, including disabled legacy requests.
- Recipes are strict JSON data, interpreted by versioned, reviewed engine primitives. No evaluated expression or executable command string is accepted.
- The initial specimens declare only `ensurePresent`; qualification stays `pending`. Null `minimumOsBuild` blocks release. Initial PSADT pin is `80b45fb8e518ee98774e16e44599d470e4069a0695a6a359022f954edaa83360` for `4.1.8`.
- V1 supports explicit/provider re-entry using a protected resume entry point and operation ID. It does not promise autonomous after-reboot execution.
- Intune publication requires a qualified `ensureAbsent` capability and real uninstall entrypoint; do not generate a dummy/no-op uninstall.
- No device execution, tenant mutation, binary publication, merging, or changes to the legacy runner/packages are authorized by this plan. P1 does not implement mutation, ACL application, atomic disk journals, toolkit sessions, reboot scheduling, or installer launch.
- Tests are offline plain PowerShell scripts discovered recursively beneath `tests/windows` by `tests/run-all.ps1`. Runtime scripts are dot-sourced with `RELIAN_DEPLOY_TEST=1`; no `Mandatory` parameters or import-time effects.
- Workers use isolated `lane/` worktrees, own nonoverlapping paths, and do not edit `docs/STATUS.md` or `docs/plans/`. Commit as `Relian Technologies <112814130+Relianco@users.noreply.github.com>` without a coauthor trailer or AI footer.

## Review Focus

1. Duplicate/case-colliding JSON keys and coercion (`"false"`, arrays instead of integers) must fail before probes; Task 1 tests both raw JSON and record validation.
2. Partially unreadable evidence must retain successful observations and errors without manufacturing absence; Task 2 tests mixed-view failures and malformed versions.
3. A copied operation ID or caller-selected user profile must not change identity/configuration or authorize another SID; Tasks 1 and 6 test binding and reconciliation.
4. Locale, source checkout location, and build timestamps must not alter release bytes; Task 7 tests shuffled object keys, two roots, and cultures.
5. An apparently successful install or detector must not suppress uncertainty or an unresolved operation; Tasks 3, 5, and 8 separately test product truth, operation truth, and generated detector output.

---

## Boundaries and file map

Evidence baseline: design PR 85 remains open at `3d80e18`; PowerShell and secret checks passed, while AI review failed because its source filter found no reviewable source files. That failure is not a successful AI review. GSA PR 84 remains separate at `db87fa6` with four outstanding comments; do not fix it here. Main `ef12f67` contains unrelated read-only diagnostics after the design baseline. Preserve those changes when integrating lanes. There is currently no `docs/worktrees.md`; use the isolation rules above rather than assuming that file exists.

All paths below are new unless marked existing. `windows/installer/` is separate from existing single-script packages.

| Files | Responsibility / owner task |
| --- | --- |
| `windows/installer/contracts/recipe-v1.schema.json`, `request-v1.schema.json`, `release-input-v1.schema.json`, `state-v1.schema.json` | Closed record definitions, nullable fields and bounds; Task 1 owns recipe/request/input, Task 6 owns state. |
| `windows/installer/core/Json.ps1`, `Contract.ps1`, `Primitives.ps1` | Strict parsing, canonical bytes, typed record validation, fixed primitive/profile catalog; Task 1. |
| `windows/installer/core/Discovery.ps1`, `Evaluate.ps1`, `ReadOnlyProbes.ps1` | Observations, identity/version/configuration evaluation, native read-only registry/file/host probes; Task 2. |
| `windows/installer/core/Plan.ps1` | Read-only proposed stages and policy requirements; Task 3. |
| `windows/installer/core/Arguments.ps1` | EXE/MSI command descriptors and Windows argument rendering; Task 4. |
| `windows/installer/core/Outcome.ps1` | Pure result normalization and engine/provider projections; Task 5. |
| `windows/installer/core/Recovery.ps1` | Validated recovery records and pure transitions/reconciliation; Task 6. |
| `windows/installer/build/Build-InstallerPreview.ps1`, `Resolve.ps1`, `Artifacts.ps1` | Local-only resolution, hashes, deterministic preview archive/detector/metadata; Task 7. |
| `windows/installer/README.md` | Interfaces, preview usage, compatibility and phase gates; Task 8. |
| `tests/windows/installer/TestSupport.ps1`, `fixtures/*.json` | Assertions, complete fixture factories, immutable synthetic probe snapshots and release inputs; created by Task 1, extended by each owner. |
| `tests/windows/installer/contract.Tests.ps1`, `discovery.Tests.ps1`, `plan.Tests.ps1`, `arguments.Tests.ps1`, `outcome.Tests.ps1`, `recovery.Tests.ps1`, `build.Tests.ps1`, `parity.Tests.ps1`, `mutations.Tests.ps1` | One test suite per boundary, followed by end-to-end parity and negative controls. |
| `windows/releases/psadt.json`, `tests/run-all.ps1`, `windows/runner/Invoke-RelianRunner.ps1` (existing, read only) | Source pin, recursive test discovery, legacy compatibility reference. |

Generated files live in a caller-selected temporary/output directory and are never committed. No runtime binaries or toolkit archives are test fixtures. Fixture bytes stand for content only and cannot establish vendor signature or Windows qualification.

## Shared contracts decided here

Functions accept validated `[hashtable]` records and return `[hashtable]` records, with arrays explicitly retained even for zero/one element. “Typed” means strict recursive validation against closed schemas plus semantic checks, not permissive PowerShell casts. No caller may bypass validation by supplying a hashtable. Invalid input throws an ErrorRecord with `FullyQualifiedErrorId=InstallerContract.<Code>`, stable `Code` and field path; the CLI catches it and exits 1. Avoid emitting incidental success-stream objects. Functions never call `exit`; only generated detector/build wrappers do.

**JSON/schema.** Accept UTF-8 JSON, maximum 1 MiB and nesting 32, integers only for numeric fields, ordinal names, no duplicate or case-colliding names at any level, and no unknown fields. Validate raw tokens before `ConvertFrom-Json` can discard duplicates; use a small strict token walker compatible with 5.1, not `System.Text.Json` or `-AsHashtable`. Only `schemaVersion=1`, `requestVersion=1`, `engineCompatibility.major=1` are understood. A new minor vocabulary must be explicitly recognized; reject unknown version representations. Positive recipe revisions; IDs match `[a-z0-9][a-z0-9._-]{0,127}`; lowercase SHA256 is exactly 64 hex characters. OS builds are null or positive integers, timeouts 1–86400 seconds, wait 0–3600 seconds, token arrays at most 128 items of at most 4096 characters, parameters at most 64 names. Reject NUL/CR/LF in executable arguments, paths and identifiers. Versions are strings, not JSON numbers. Closed recipe field names and enum values come from the specimens, with `exact` also recognized for comparison and explicit capabilities for `ensureAbsent`, `repair`, `reinstall`; recognition alone does not supply an implementation or qualification.

**Primitive catalog.** Fixed engine-owned IDs only: discovery `gsaBundleV1`, `sevenZipMsiV1`, `vscodeOwningUserV1`; postconditions `gsaReplacementV1`, `sevenZipInstalledV1`, `vscodeUserInstalledV1`; commands `stagedExe`, `machineMsiInstall`, `validatedGsaCachedBundle`. The catalog maps each ID to code revision/digest, supported scope/actions, required evidence fields and allowed replay points. No naming-based imports, ScriptBlock conversion, dynamic source URLs or executable override. P1 command primitives produce descriptors only. Missing commercial/MSI identity rules, signer evidence, process allowlist or OS qualification are explicit unresolved inputs; preview accepts them as blockers, never invents them. Production registry extension requires reviewed source plus tests and a new source digest.

**Resolved inputs.** `ReleaseInputV1` contains recipe, resolved nonsecret configuration, engine source file inventory, discovery source inventory, PSADT version/hash, brand hash, payload and vendor-cache dependency inventories (`relativePath`, `sha256`, `size`, `role`), qualification evidence references, identity-rule fixtures, trusted profiles, parameter bindings, and `buildFormatVersion=1`. Local absolute paths are builder arguments only, never serialized. Resolver opens local supplied bytes, verifies every hash/size and source binding, and performs no downloads. HTTPS URLs are immutable provenance, not instructions to fetch; reject userinfo, mutable/latest endpoints, unsupported schemes and unresolved `releaseInput` names. Any required signature remains `unverified` until a trusted Windows verification result bound to those bytes exists. External evidence hashes identify evidence; a user-writable JSON claim of `passed` is not release authorization. A caller-provided evidence catalog must itself be trusted by the future release process; P1 only models that check.

**Request and identity.** JSON request is exactly `requestVersion`, `operationId`, `releaseId`, `operation`, `profile`, optional `targetSid`, and `parameters`. `Resolve-InstallerRequest(Request, Release, Invocation)` takes an adapter-owned `Invocation` separately: verified caller SID, SYSTEM flag, elevation, OS/build/architecture, allowed profile IDs, trusted release catalog binding, and trusted parameter policy. Request data cannot supply these claims. Catalog `releaseId` resolves a core digest and bytes, not a mutable URL. `standalone-machine` means SYSTEM/machine/eligible session; `standalone-user` means non-elevated owning user/user/eligible session; `intune-machine` means SYSTEM/machine/Silent; `intune-user` means non-elevated owning user/user/Silent. The standalone-user profile names the native user path implied by the design; it does not impersonate. User target SID must equal the verified caller SID; machine target SID must be absent. Reject elevated administrator as SYSTEM, wrong architecture, unapproved profile or undeclared override before any registry probe. Profiles reduce notification rights; they cannot expand recipe scope. Canonical `requestBindingDigest` binds operation ID, core digest, operation, profile, scope/SID, the release-locked configuration digest, and the canonical effective-parameter digest. Deployment identity for deferral is separately adapter-owned and stable across run IDs.

**Request configuration binding.** Reviewed primitive catalog entries classify each declared parameter as `observable`, `transport`, or `commandOnly`; resolved core `parameterBindings` locks that classification and, for observable parameters, the configuration field path. A caller or adapter policy cannot reclassify a parameter. Resolve defaults and validate types/policy first, then require every observable request value to equal the selected core's resolved configuration value using typed canonical equality. A policy-allowed but differing value fails with `ConfigurationReleaseMismatch` before probes or any effects. Request resolution never patches release configuration or only changes a request digest to accept the mismatch. To change observable configuration, build a new core and detector together and explicitly select that release through the trusted catalog; both `Get-InstallerEvaluation(Release, Observations)` and generated detection then use that core's configuration. The returned request's configuration is exactly the locked release configuration. Transport parameters may select only preapproved locations for identical pinned bytes (for example `contentSource`); command-only parameters may vary only reviewed execution details proven not to change identity, installed version, scope, observable configuration or postconditions. Both remain bounded and enter the effective-parameter digest; neither enters the detection projection. If an option can affect desired state, classify it as observable and require a rebuilt release. Missing or unreviewed classification is invalid.

**Observation and evaluation.** `ObservationSetV1` has collector source digest, caller SID/scope, OS/architecture, requested coverage, and probe records. Each probe records `kind`, explicit hive/view or normalized root, SID, candidate identity, status (`found`, `notFound`, `error`), raw values, and structured error (`category`, native code, safe message/reference). Include a UTC observation time for freshness checks, but not in deterministic release inputs. Preserve each raw version and normalized components. Errors and all candidate identities survive aggregation. Empty candidates mean `Absent` only when every required probe completed successfully with sufficient coverage. Conflicting incompatible candidates yield `Ambiguous`; missing required binary with valid registration yields `Damaged`; unreadable/malformed evidence yields `Unknown` and cannot be hidden by another good candidate. Preserve subordinate reasons when multiple conditions exist; blocker order is `Unknown`, `Ambiguous`, `Damaged`, then `Present`/`Absent`. Neither success markers nor journals are inputs to product evaluation.

Version primitive is invariant decimal-component comparison: 1–4 nonnegative components, each <= 2147483647, pad missing trailing components with zero; no suffix/prerelease/culture parsing. `26.04` equals `26.04.00.0`. Unsupported vendor forms remain `Unknown` until a reviewed version primitive is added. `EvaluationV1` returns state, all matches, evidence/reasons, version comparison, configuration status (`Satisfied`, `Unsatisfied`, `Unknown`, `NotDeclared`), and boolean `desiredStateSatisfied`. Only supported identity/scope/architecture and declared postconditions can satisfy; arguments are not observable configuration proof.

**Read-only plan.** `PlanV1` contains outcome/reason, binding digest, evaluation, ordered stage descriptors, unresolved requirements, and active-operation reference. Stages are data (`StageContent`, `AcquireLock`, `Recheck`, `Remove`, `Install`, `Verify`), never authority to execute. Active unresolved intent takes priority over `AlreadySatisfied`, while detector remains product-only. Storage, free space, process/session observations and offline closure are supplied snapshots or listed preflight requirements. A dry plan may propose GSA removal/install with `StageContent` unresolved; it cannot fetch content to make that requirement disappear.

**OutcomeV1.** Required fields are `outcome`, `reason`, `phase`, `operationId`, `desiredStateSatisfied`, `mutationStarted`, `rebootRequired`, `retryEligible`, `vendorCode`, `toolkitCode`, `diagnosticReferences`. Raw codes are nullable integers. Satisfied outcomes require proven postconditions; `AlreadySatisfied` also requires no unresolved operation and no mutation in this attempt. `CompleteRebootRequired` requires satisfied postconditions and reboot required. `RebootRequiredIncomplete` requires unsatisfied state and a retained recovery reference in `diagnosticReferences`. `PartialFailure` requires a known completed destructive substep; `NeedsRecovery` includes uncertain effects. Unsafe replay always forces `retryEligible=false`; a newer request may be retryable `Busy` only because it did no work, not because the active operation is replayable. Unknown intent is not cancellation or deferral.

**RecoveryV1.** Closed state fields: `schemaVersion`, `operationId`, `requestBindingDigest`, `releaseCoreDigest`, `configurationDigest`, `discoveryDigest`, `applicationId`, `scope`, `targetSid`, `phase`, `intendedPrimitive`, `attempt`, `bootIdentity`, `precondition`, `expectedPostconditions`, `completionResult`, `retainedDigests`, `activeReference`, `cancelRequested`, `resumeAction`. The nullable resume action is `Install` or `Verify`; it cannot authorize another removal after reboot. Nullable fields are target SID for machine work, intent/completion before those events, and active reference only before reservation. Digests bind exact input bytes; attempt starts at zero and increments on a permitted intent. No executable path, argv or script body. Allowed phases: `Planned`, `Staged`, `Ready`, `Removing`, `Installing`, `Verifying`, `AwaitingReboot`, `NeedsReconciliation`, `Complete`, `NeedsRecovery`, `Abandoned`. A state plus a typed event returns a new record and effect *descriptions*, never writes. An `Intent` event requires verified closure, writable-result proof and identity/lock/recheck proofs; it precedes any future destructive effect. Input proofs are model evidence, not P1 claims about actual ACLs, locks or durability.

## Tasks and dependencies

Execute 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8. Dependencies are explicit; initial execution should be serial because contracts and shared fixtures change together. Every task gets an independent review before the next task starts. Each suite uses `TestSupport.ps1`: `Assert-Equal -Actual <value> -Expected <value> -Label <string>` performs type-aware deep equality; `Assert-Throws -Action <scriptblock> -Code <string> -Label <string>` requires the specific contract error. Assertions throw labeled failures and the script returns a nonzero process exit; no network and no installer launch.

### Task 1: Strict contracts, canonical data and trusted bindings

**Files:** Create the Task 1 files in the map and `contract.Tests.ps1`. Add synthetic fixture builders in `TestSupport.ps1`, including fixtures for each design specimen that preserve their actual proposed versions, arguments and `pending` status.

**Interfaces:** Produce `Read-InstallerJson([string] Json) -> hashtable`, `ConvertTo-InstallerCanonicalBytes([object] Value) -> byte[]`, `Assert-InstallerContract([string] Kind,[hashtable] Value) -> void`, `Get-InstallerPrimitiveCatalog() -> hashtable`, `Resolve-InstallerRequest([hashtable] Request,[hashtable] Release,[hashtable] Invocation) -> hashtable`. The returned request includes release-locked configuration, effective parameters, their separate digests and the request binding digest. Canonical JSON sorts object keys ordinally, preserves array order, uses invariant integers, UTF-8 without BOM, no whitespace/final newline, and deterministic JSON string escaping. No floats, DateTime objects or host-specific paths.

- [ ] **Write failing tests.** `StrictJsonRejectsLossyInput` rejects duplicate nested keys, `scope`/`Scope`, unknown keys, version 2, float timeout, numeric version, string boolean and excessive depth. `BindingPrecedesProbes` rejects SYSTEM→user, differing SID, caller-supplied executable/hash/profile claims and unknown override fields; probe counter stays 0. `ObservableOverrideRequiresRelease` supplies a declared, policy-allowed observable value B against core configuration A and requires `ConfigurationReleaseMismatch` with probe/effect counts 0; matching A succeeds. `NonObservableOptions` permits a classified transport option selecting the same bytes, preserves configuration digest and changes effective-parameter/request binding digests; unclassified options fail. A rebuilt core with configuration B changes the binding digest; rejecting reuse of an existing operation ID belongs to Task 6. `CatalogIsClosed` rejects unknown primitives and unsupported action combinations. `CanonicalBytesAreStable` compares literal expected UTF-8 bytes under shuffled keys and non-English culture.
- [ ] **Run red:** `pwsh -NoProfile -File tests/windows/installer/contract.Tests.ps1`; expect a named missing contract/function failure, not a syntax error.
- [ ] **Implement** the five interfaces and closed schemas, including every field in the specimens. Separate syntactic validity from release readiness: null OS and pending qualification parse, but return explicit release blockers in resolution. Reject command-line secret channels; retain only approved reference IDs, never resolved secret values.
- [ ] **Run green:** the same command exits 0 with all labeled assertions reached. Verify source parses without 7-only syntax/API dependencies; defer actual 5.1 execution to P2.
- [ ] **Commit:** `feat(installer): define strict v1 contracts and request binding` using only this task's explicit paths, then obtain independent task review.

Representative assertion after arranging Task 1 fixtures:

```powershell
Assert-Throws -Action { Read-InstallerJson '{"schemaVersion":1,"schemaVersion":2}' } -Code 'DuplicateKey' -Label 'StrictJsonRejectsLossyInput'
```

### Task 2: Shared read-only observations and evaluation

**Files:** Create `Discovery.ps1`, `Evaluate.ps1`, `ReadOnlyProbes.ps1`, `discovery.Tests.ps1`; extend synthetic fixtures.

**Interfaces:** Consume Task 1 contracts/catalog. Produce `Get-InstallerObservations([hashtable] Release,[hashtable] Invocation,[hashtable] ProbeApi) -> hashtable`, `Get-InstallerEvaluation([hashtable] Release,[hashtable] Observations) -> hashtable`, `Get-InstallerReadOnlyProbeApi() -> hashtable`. `ProbeApi` is an engine-owned/test-injected table with only `ReadRegistry`, `ReadFileEvidence`, `ReadHostEvidence`; it is never serialized in recipes/requests. Native implementation explicitly opens registry views, reads local file identity/version/signature evidence, and returns structured failures; it does not repair, invoke an uninstaller, enumerate all users or use Win32_Product.

- [ ] **Write failing tests.** `UnknownIsNotAbsent` asserts access denied plus historical marker ⇒ `Unknown`, unsatisfied, preserved native error and view; a successful second view cannot erase the failure. `CompleteAbsence` requires all required successful not-found probes. `IdentityConflicts` checks x86/x64 and multiple incompatible identities ⇒ `Ambiguous`, every candidate retained. `DamagedRegistration` checks valid registration/missing binary ⇒ `Damaged`. `VersionEvidence` checks missing/overflow/suffix versions ⇒ `Unknown`, `26.04` equals `26.04.00.0`, newer minimum satisfied, newer exact unsupported. `UserScope` rejects wrong SID before `ReadRegistry`, and another user's installation cannot satisfy. `ConfigurationEvidence` rejects success inferred only from install arguments.
- [ ] **Run red:** `pwsh -NoProfile -File tests/windows/installer/discovery.Tests.ps1`; expect missing observation/evaluation behavior with zero forbidden effects.
- [ ] **Implement** collectors and evaluator with explicit primitive-selected identity evidence. Preserve unresolved identity rules as blockers; tests use synthetic reviewed-rule fixtures and never call them commercial qualification. Capture observation provenance and structured errors before normalization. Diagnostic formatting redacts URL credentials/query values and unsafe exception text while retaining native error codes.
- [ ] **Run green:** same command exits 0; snapshots before/after are equal and counters for download/write/UI/process-close/launch all remain 0. Exact production collector/evaluator source becomes the detector input in Task 7.
- [ ] **Commit:** `feat(installer): share read-only discovery and evaluation`, then independent review.

Representative assertions with the unreadable-view fixture:

```powershell
$result = Get-InstallerEvaluation -Release $release -Observations $observations
Assert-Equal -Actual $result.state -Expected 'Unknown' -Label 'UnreadableEvidenceIsUnknown'
Assert-Equal -Actual $result.desiredStateSatisfied -Expected $false -Label 'UnknownIsNotCompliant'
```

### Task 3: Read-only planning and session/process policy

**Files:** Create `Plan.ps1`, `plan.Tests.ps1`; extend fixtures.

**Interfaces:** Consume validated request, evaluation and optional active `RecoveryV1` snapshot (full validation added in Task 6). Produce `Get-InstallerPlan([hashtable] Release,[hashtable] Request,[hashtable] Evaluation,[hashtable] Environment,[hashtable] ActiveOperation) -> hashtable`. Environment contains supplied session/process/storage/prerequisite/enrollment evidence plus UTC time and adapter-owned retry/deployment policy. Null active operation is permitted.

- [ ] **Write failing tests.** `PlanHasNoEffects` with older GSA and missing replacement returns remove/install stages and unresolved closure; all forbidden counters 0 and snapshot unchanged. `PriorIntentWins` returns reconciliation despite satisfied product. `SatisfiedSkipsInteraction` returns `AlreadySatisfied` with no stages even if app running. `UnsafeStatesBlock` covers unknown/damaged/ambiguous, unsupported repair and newer exact. `PresencePolicy` covers unknown/locked/disconnected/multiple affected users, wrong process owner and app reopening ⇒ block; confirmed no user permits only safe machine silent work. `IntuneIsSilent` and `EnrollmentGate` prohibit welcome/force-close/local restart and require enrollmentSafe. `DeferralPolicy` shares history across operation IDs by deployment/action/SID, uses UTC across DST, never offers Later without retry owner, and defaults deadline expiry to block. `GsaSafety` blocks mixed identity/invalid cached bundle and Intune possible-intermediate-reboot even if this run might not reboot.
- [ ] **Run red:** `pwsh -NoProfile -File tests/windows/installer/plan.Tests.ps1`; expect the specific policy assertions to fail.
- [ ] **Implement** the pure planner; unresolved free space, old-cache dependency validation and writable-result path become named requirements before mutation. Do not acquire locks, close processes, create sessions, resolve secrets, write journals or stage payloads. Explicitly distinguish not applicable, unsupported action, unknown evidence and missing preflight proof.
- [ ] **Run green:** same command exits 0; all no-effect assertions must be evaluated on successful plans as well as rejected ones.
- [ ] **Commit:** `feat(installer): add read-only deployment planner`, then independent review.

Representative assertion with older GSA and missing replacement:

```powershell
Assert-Equal -Actual $effectCounts -Expected @{ download=0; write=0; ui=0; close=0; launch=0 } -Label 'PlanHasNoEffects'
```

### Task 4: Structured executable and MSI rendering

**Files:** Create `Arguments.ps1`, `arguments.Tests.ps1`.

**Interfaces:** Produce `Get-InstallerCommandDescriptor([hashtable] Release,[string] Primitive,[hashtable] BoundContent,[hashtable] Parameters) -> hashtable` and `ConvertTo-InstallerWindowsCommandLine([string[]] Tokens) -> string`. Descriptor fields: primitive ID, pinned executable reference, token array, timeout, success/reboot codes and restart policy. MSI properties are string values under validated uppercase property names, sorted ordinally; primitive owns `/i`, trusted payload reference, `/qn`, and `REBOOT=ReallySuppress`. A remove primitive only accepts a validated cached-bundle reference from observations, never raw `UninstallString`.

- [ ] **Write failing tests.** `ArgvRoundTrip` uses an independent Windows argv parser oracle and literal expected encodings for empty token, spaces, embedded quotes, Unicode and trailing backslashes (including backslashes before a quote). `MsiProperties` verifies one token per `KEY=value`, disallows switch/key injection and conflicting restart/UI properties. `DescriptorPinning` rejects executable override, shell expressions as executable/primitive, raw uninstall strings and unknown parameters; metacharacters inside an allowed value remain literal. `SecretChannelRejected` ensures no resolved secret can appear in argv or diagnostics.
- [ ] **Run red:** `pwsh -NoProfile -File tests/windows/installer/arguments.Tests.ps1`; expect missing renderer/descriptor failures.
- [ ] **Implement** Windows CRT-style quoting: quote empty/whitespace/quote-containing tokens, double backslashes preceding closing quotes, and escape embedded quotes with the requisite backslashes. Do not run cmd, PowerShell evaluation or Start-Process to test it. This specifies a renderer, not proof that every vendor parses CRT argv; P2 must run a recorder and each qualified installer.
- [ ] **Run green:** same command exits 0; fixtures assert the complete command line and recovered tokens, not only substrings.
- [ ] **Commit:** `feat(installer): render bounded command descriptors`, then independent review.

Representative literal quoting assertion (single-quoted PowerShell strings):

```powershell
Assert-Equal -Actual (ConvertTo-InstallerWindowsCommandLine -Tokens @('', 'hello world')) -Expected '"" "hello world"' -Label 'EmptyAndSpacedTokens'
```

### Task 5: Outcomes and provider code projections

**Files:** Create `Outcome.ps1`, `outcome.Tests.ps1`.

**Interfaces:** Produce `Get-InstallerOutcome([hashtable] Attempt,[hashtable] Evaluation) -> hashtable`, `Assert-InstallerOutcome([hashtable] Result) -> void`, `Get-InstallerExitCode([hashtable] Result,[string] Profile) -> int`. Attempt supplies operation/phase, explicit UI decision/source, raw codes, mutation facts, uncertainty, postconditions, reboot and retry evidence; missing facts fail closed.

| Outcome | Engine exit |
| --- | --- |
| Succeeded / AlreadySatisfied | 0 |
| CompleteRebootRequired | 3010 |
| RebootRequiredIncomplete | 69010 |
| Deferred | 69011 |
| Cancelled | 69012 |
| Busy / Retryable | 69013 |
| BlockedBySession / BlockedByRunningProcess | 69014 |
| NotApplicable / UnsupportedOperation | 69015 |
| NeedsRecovery / PartialFailure | 69016 |
| InvalidRequest / IntegrityFailure / Failed | 1 |

- [ ] **Write failing tests.** `ZeroIsNotSuccess` checks vendor 0/missing target ⇒ Failed (or PartialFailure after known removal). `RebootNeedsProof` checks install 3010+satisfied ⇒ CompleteRebootRequired; unsatisfied ⇒ incomplete; raw 1641 never automatically succeeds. `CodeSourceMatters` separates explicit defer1602, vendor cancellation1602, unexplained toolkit1602, toolkit timeout1618 and verified MSI contention. `RetryIsBounded` disallows integrity retry and timeout/surviving-child replay. `ResultInvariants` rejects fabricated satisfied booleans and missing recovery reference. `IntuneProjection` leaves 69010/69011 failures, permits 3010 only for complete reboot, and allows 69013 retry only with safe retry evidence.
- [ ] **Run red:** `pwsh -NoProfile -File tests/windows/installer/outcome.Tests.ps1`; expect missing normalization/invariant failures.
- [ ] **Implement** normalized reason/phase preservation and the table exactly. Intune mappings are metadata, not tenant configuration: success 0; soft reboot 3010; retry 69013 only under safe conditions; other nonzero failure. Default defer/timeout values are PSADT 4.1.8 facts, never inferred user intent. No local restart owner is selected by an exit code.
- [ ] **Run green:** same command exits 0, including output/redaction assertions and rejection of invalid combinations.
- [ ] **Commit:** `feat(installer): define outcome invariants and exit mapping`, then independent review.

Representative outcome assertion with vendor 0 and missing target:

```powershell
$result = Get-InstallerOutcome -Attempt $attempt -Evaluation $missingTarget
Assert-Equal -Actual $result.outcome -Expected 'Failed' -Label 'ExitZeroMissingTargetCannotSucceed'
Assert-Equal -Actual (Get-InstallerExitCode -Result $result -Profile 'standalone-machine') -Expected 1 -Label 'FailedExit'
```

### Task 6: Pure recovery and retention state machine

**Files:** Create `state-v1.schema.json`, `Recovery.ps1`, `recovery.Tests.ps1`; integrate full active-record validation into `Plan.ps1`.

**Interfaces:** Produce `Move-InstallerOperation([hashtable] State,[hashtable] Event) -> hashtable` returning `{ state, effects }`, and `Get-InstallerReconciliation([hashtable] State,[hashtable] Release,[hashtable] Request,[hashtable] Evidence) -> hashtable` returning `{ decision, reason, nextPhase, retainedDigests, activeReference }`. Evidence includes current boot identity, process state (`running`, `none`, `unknown`), fresh evaluation, content verification, trusted state provenance and lock/context proof. Decisions are `Complete`, `WaitForBoot`, `WaitForProcess`, `ResumeInstall`, `NeedsRecovery`, `SupersedeBeforeMutation`, `Busy`; none launches a command.

- [ ] **Write failing tests.** `IntentRequired` rejects completion without intent and destructive transitions without closure/result-write/recheck proof. `NoSameBootReplay` models remove3010 ⇒ AwaitingReboot, same boot ⇒ WaitForBoot with no Remove/Install effect; changed boot plus valid closure/fresh absent observation ⇒ ResumeInstall once. `VerifyOnlyAfterReboot` starts with incomplete install3010 and `resumeAction=Verify`: same boot returns WaitForBoot; after changed boot and all other valid prerequisites, satisfied postconditions return Complete/nextPhase Complete, unsatisfied return NeedsRecovery/VerificationFailed, and unknown return NeedsRecovery/VerificationUnknown. Applying each decision through Reconciled yields no Install or Remove effect; install/remove counters remain 0 in every case. `InterruptedIntent` with absent process alone never replays; satisfied postconditions can complete, surviving/unknown child blocks. `DigestBinding` rejects changed engine/recipe/configuration/discovery/payload, SID, scope, arbitrary phase or executable injection; mismatched release requests return Busy with original reference after mutation. `Supersession` allows authorized replacement only in Planned/Staged, releases old references and requires fresh plan. `CancelAndTimeout` preserves content after removal, marks known partial failure versus unknown recovery. `Retention` never evicts active/incomplete references on disk pressure or rollout disable; terminal unreferenced content alone is eligible for expiry, abandonment requires explicit administrative evidence.
- [ ] **Run red:** `pwsh -NoProfile -File tests/windows/installer/recovery.Tests.ps1`; expect intended transition failures.
- [ ] **Implement** a closed transition/event table: removal3010/1641 ⇒ AwaitingReboot(next Install); incomplete install3010 ⇒ AwaitingReboot(next Verify); missing completion after destructive intent ⇒ NeedsReconciliation. Changed boot is necessary, not sufficient: verify pinned release/content, identity, process absence and fresh postconditions first. For `resumeAction=Verify`, consume the supplied fresh evaluation directly after a confirmed boot change: satisfied postconditions select `Complete`/nextPhase `Complete`; unsatisfied or unknown select `NeedsRecovery`/nextPhase `NeedsRecovery` with `VerificationFailed` or `VerificationUnknown` respectively. This verification-only branch never selects `ResumeInstall`, transitions to Ready, or emits Install/Remove effects. It needs no additional verification decision or reconciliation-to-Verifying edge because fresh verification evidence is already supplied. Unexpected boot change or unknown product state never guesses a replay. Same operation ID with different binding is InvalidRequest; a different operation requesting the busy application/scope is Busy. User-written records cannot be promoted to trusted machine state. No disk persistence, mutex, scheduler, ACL or process waiting is implemented here.

 The event vocabulary is closed; each event is a record with `kind` and the explicitly required evidence above. Invalid source phase or missing proof rejects without changing state. Implement these legal edges; reconciliation decisions authorize data transitions only, never process launch:

 | Event | Allowed source → destination |
 | --- | --- |
 | `StageVerified` | Planned → Staged, verified closure retained. |
 | `ReadyVerified` | Staged → Ready, fresh identity/lock/session/result-path proofs. |
 | `IntentRemove` / `IntentInstall` | Ready → Removing / Installing; intent binds the primitive and attempt and must match the planned action or retained resumeAction. |
 | `RemoveCompleted` | Removing → Ready only with absence/removal proof and fresh recheck required; 3010/1641 → AwaitingReboot; uncertain → NeedsReconciliation; known failure → NeedsRecovery. |
 | `InstallCompleted` | Installing → Verifying; uncertain → NeedsReconciliation. |
 | `Verified` | Verifying → Complete only with postconditions; unsatisfied reboot case → AwaitingReboot(next Verify); other failure → NeedsRecovery. |
 | `Interrupted` | Removing/Installing/Verifying → NeedsReconciliation; retain intent and content. |
 | `Reconciled` | AwaitingReboot/NeedsReconciliation → Ready only for ResumeInstall with resumeAction Install; Complete with proven postconditions; otherwise NeedsRecovery. The resumeAction Verify branch resolves directly to Complete or NeedsRecovery from fresh evaluation and emits no Install/Remove effects; wait decisions leave state unchanged. |
 | `CancelRequested` | Planned/Staged/Ready → Complete with Cancelled only before destructive work; later phases retain cancellation flag until a safe boundary and emit incomplete outcome. |
 | `AbandonAuthorized` | Nonterminal recovery state → Abandoned only with explicit administrative evidence; never implies installed compliance or automatic content deletion. |

- [ ] **Run green:** same command plus `pwsh -NoProfile -File tests/windows/installer/plan.Tests.ps1` exit 0; effects arrays contain only validated descriptions and no code/path override.
- [ ] **Commit:** `feat(installer): model recovery reconciliation and retention`, then independent review.

Representative same-boot assertion with otherwise valid resume evidence:

```powershell
$result = Get-InstallerReconciliation -State $awaitingRemovalReboot -Release $release -Request $request -Evidence $sameBoot
Assert-Equal -Actual $result.decision -Expected 'WaitForBoot' -Label 'SameBootHasNoInstallEffect'
```

### Task 7: Resolved local inputs and deterministic preview artifacts

**Files:** Create build files and `build.Tests.ps1`. Generated detector embeds exact Task 1/2 source and a resolved detection projection; no separately maintained detection logic.

**Interfaces:** Produce `Resolve-InstallerRelease([hashtable] Input,[string] ContentRoot,[hashtable] TrustedEvidence) -> hashtable`, `Test-InstallerReleaseGate([hashtable] Release,[string] Profile,[string] Mode) -> hashtable` (`allowed`, ordered `blockers`), `New-InstallerArtifacts([hashtable] Release,[string] OutputRoot) -> hashtable` (artifact relative paths/digests). CLI `Build-InstallerPreview.ps1 -InputPath <local-json> -ContentRoot <local-root> -OutputRoot <local-root>` only builds previews. No download/upload/publish flags. `Mode` in the gate is `Preview` or `Publish`; P1 always rejects Publish with `ExecutionNotQualified` in addition to recipe/profile-specific blockers.

**Digest graph (no self-reference):**

1. Hash actual source/dependency/payload bytes. Canonicalize resolved recipe and effective configuration separately to obtain recipe/configuration digests. Reject inventory path collisions under Windows case folding, absolute/drive/UNC paths, `..`, alternate data streams, and symlink/reparse claims escaping root; actual Windows checks remain P2.
2. Canonical `release-core.json` contains format/schema versions, recipe/configuration and their digests, exact source/dependency inventories, qualification state/evidence references, identity rules, parameter bindings and approved profiles. It contains no build time, absolute path, output digest or self digest. Its SHA256 is `releaseCoreDigest`; immutable human `releaseId` maps to it through the trusted catalog, not by embedding the catalog into core.
3. Generate `Detect.ps1`, `requirements.json`, `metadata.preview.json` and `manifest.preview.json` from core. Each binds `releaseCoreDigest`. Detector also binds discovery-source and detection-configuration digests; outputs exactly `RelianDetected` plus one newline and exit 0 on satisfied evidence, otherwise no stdout and exit 1. Success stderr is empty. It loads no toolkit/cache/network and has no runtime override/test-input channel in production output. Tests provide a harness by replacing the trusted probe boundary in a temporary copy, never through a generated public parameter.
4. Preview manifest format is `relian.windows.bundle.preview`, version 1, `deployable=false`, and `entrypoint=null`. Future P3 deployment format is separately `relian.windows.bundle`, version 1, with qualified action entrypoint; the legacy script URL is never reinterpreted. P1 preview includes core, engine source, detector and metadata/requirements; synthetic payload bytes are only fixtures. No Install.ps1/Uninstall.ps1 that merely succeeds. Future deployment template fields stay absent until execution exists.
5. Generate `release-lock.json` containing core digest and sorted `(path,size,sha256)` for every preview member except the lock itself. The lock does not contain archive/own digest. ZIP includes this lock plus listed members. Sort entries ordinally with `/` separators, fixed DOS timestamp `1980-01-01T00:00:00`, fixed attributes, UTF-8 names, no compression; use one fixed serialization path and fail unsupported writer environments. Hash final ZIP bytes.
6. External canonical `provenance.json` records builder source digest, format version, core digest, lock digest, ZIP digest, detector digest and metadata digest. It is not inside the ZIP and contains neither its own hash nor wall-clock time. Output manifest returns its hash if needed. Signatures/catalog authentication are future release-process concerns; checksums alone are not authenticity.

Detection projection contains only resolved app identity, version/comparison, scope/SID policy, observable configuration, applicable host rules and primitive inputs. Secret references or values are not emitted. Metadata models install context, 64-bit host/detection preference, requirements, return codes, Silent mode, provider restart ownership and upgrade owner; no independent detector `runAsAccount`. Preview metadata declares itself nonpublishable and omits install/uninstall commands. P4 materializes qualified commands and explicit 64-bit launching (including Sysnative from a 32-bit agent), complete Intune closure and tenant fields in the separate adapter.

- [ ] **Write failing tests.** `ResolveLocalBytes` verifies hashes/sizes, terminal mismatch/no retries, missing releaseInput/dependencies, PSADT exact pin, URL userinfo rejection before any read/download, and signer/OS/identity blockers. `PreviewCannotShip` checks pending specimens, P1 Publish rejection, missing ensureAbsent, no dummy uninstall, GSA continuation gate and recipe/provider duplicate-removal ownership. `StableArtifacts` builds twice in different roots/cultures with shuffled input keys and compares every byte/digest; changes target/config/source individually and asserts core, detector where applicable, bundle and metadata binding regenerate. `NoCircularDigest` independently rehashes every lock entry and final archive/provenance. `HostileMembers` tests traversal, case collision and malformed inventory. `DetectorIsolation` runs before installation with absent toolkit/cache and network trap; no mutable imports or secret leakage.
- [ ] **Run red:** `pwsh -NoProfile -File tests/windows/installer/build.Tests.ps1`; expect missing resolver/generator behavior, not missing external downloads.
- [ ] **Implement** the interfaces and exact graph. Emit ordered release blockers in previews; reject tampered bytes even in Preview mode. Keep qualified evidence and syntactic fixture acceptance separate. The trusted profile restricts Intune to Silent and blocks possible intermediate-reboot replacement until separately qualified continuation ownership exists; no P1 flag bypass.
- [ ] **Run green:** same command exits 0 and two independent output trees match byte-for-byte. Read ZIP members back and check pins/digests independently of builder helpers.
- [ ] **Commit:** `feat(installer): build deterministic nondeployable previews`, then independent review.

Representative publication-gate assertion, including a syntactically valid fixture claiming passed qualification:

```powershell
$gate = Test-InstallerReleaseGate -Release $release -Profile 'intune-machine' -Mode 'Publish'
Assert-Equal -Actual $gate.allowed -Expected $false -Label 'PreviewCannotShip'
Assert-Equal -Actual ($gate.blockers -contains 'ExecutionNotQualified') -Expected $true -Label 'P1HasNoPublishBypass'
```

### Task 8: Integrated parity, mutation controls and phase handoff

**Files:** Create `parity.Tests.ps1`, `mutations.Tests.ps1`, and `windows/installer/README.md`; extend fixtures only as needed. Do not modify existing runner behavior or its tests to make the new protocol appear shipped.

**Interfaces:** Consume all prior interfaces. Add a test-only mutation harness which copies source into a temporary tree, applies one targeted mutation, runs one designated child test process, and deletes the copy in `finally`. No mutation switches ship in production modules. Each child test prints a unique assertion label before it fails; harness checks the expected label and nonzero exit, not merely any exception.

- [ ] **Write failing parity tests.** Feed identical synthetic observations to runtime evaluator and generated detector for every state, each recipe, raw/missing/malformed version, minimum/exact, wrong scope/SID, declared configuration and unknown probe. Assert matching desired-state truth, exact stdout/stderr/exit contract, and source/config digest binding. `RebuiltObservableConfigurationParity` builds core/detector A and core/detector B for one declared observable field with different values: B requested against A must fail before probes, while B requested against trusted rebuilt B succeeds. Against identical observations of B, runtime B and detector B both satisfy, while runtime A and detector A both report unsatisfied; reverse the observations and require the converse. Verify changed core/configuration/detector digests and matching configuration projection rather than changing a runtime-only option. A compliant product with unresolved journal has positive product detection but planner reconciliation. Check the production detector source is otherwise byte-identical to the tested generated code; only the temporary trusted probe implementation differs.
- [ ] **Run red:** `pwsh -NoProfile -File tests/windows/installer/parity.Tests.ps1`; add a deliberate stale detection projection to demonstrate the mismatch assertion catches it, then remove that deliberate test setup when adding the production fix.
- [ ] **Implement** any missing glue in its owning module; document callable interfaces, local preview example, fixed host floor, no mutation entrypoint, evidence format and P2/P3/P4 gates. Preserve all six critical negative controls below as automated tests.

| Mutation in copied source | Designated assertion that must fail |
| --- | --- |
| Remove payload hash comparison | `TamperedPayloadRejectedBeforeEffects`; corrupt fixture bytes would otherwise resolve, no unrelated mock allowed. |
| Convert unreadable discovery to absent | `UnreadableEvidenceIsUnknown`; assert state and original native error, not just no install. |
| Remove SID/scope validation | `ForeignSidRejectedBeforeRegistry`; valid remainder of request reaches counted probe and proves the guard mattered. |
| Skip postcondition requirement | `ExitZeroMissingTargetCannotSucceed`; fully valid result except missing target. |
| Allow same-boot continuation | `SameBootHasNoInstallEffect`; valid retained content and all other resume prerequisites supplied. |
| Perturb embedded detection target version | `GeneratedRuntimeVersionParity`; boundary fixture between old/new target produces differing truth. |

- [ ] **Run green:** `pwsh -NoProfile -File tests/windows/installer/parity.Tests.ps1` and `pwsh -NoProfile -File tests/windows/installer/mutations.Tests.ps1`; all six mutants must be killed for their named reason and unmodified control must pass. No silently skipped mutant or source-edit pattern that matched zero/multiple locations.
- [ ] **Run branch checks:** `pwsh -NoProfile -File tests/run-all.ps1`; `node --test tests/ai-pr-review.test.mjs tests/secret-scan.test.mjs`; `scripts/scan-secrets.sh`; `git diff --check`. Expected exit 0. These Node paths reflect current repository layout; older local instructions name stale paths. Inspect diff/status for generated binaries, public identifiers and accidental legacy changes.
- [ ] **Commit:** `test(installer): prove parity and critical guard sensitivity`, then independent task review and a separate whole-branch review. Reviewer rechecks contracts against the design, all phase assignments below and actual check output. Do not treat passing pure tests as Windows qualification.

Representative detector assertions for the satisfied fixture (capture child stdout/stderr separately):

```powershell
Assert-Equal -Actual $detectorExit -Expected 0 -Label 'SatisfiedDetectorExit'
Assert-Equal -Actual $detectorStdout -Expected ("RelianDetected" + [Environment]::NewLine) -Label 'SingleSuccessToken'
Assert-Equal -Actual $detectorStderr -Expected '' -Label 'SuccessHasNoStderr'
```

## Full scenario traceability and qualification gates

Rows follow the design matrix order. “Model” means P1 verifies a decision over supplied evidence only. A later phase is still required even when the corresponding model passes.

| # / scenario | P1 owner and proof | Remaining mandatory evidence |
| --- | --- | --- |
| 1 Plan older GSA / missing replacement | T3 no-effect counts, unresolved staging | P2 real staging/command boundaries. |
| 2 Unknown + success marker | T2/T8 unknown and parity | P2 unreadable registry/version behavior. |
| 3 Compliant + unresolved intent | T3/T6/T8 operation precedence | P2 interrupted real operation. |
| 4 Damaged / ambiguous architectures | T2 distinct states/all candidates | P2 registry/filesystem mutation. |
| 5 Equal/newer + running process | T3 no interaction; exact rejects | P2 actual no UI/process changes. |
| 6 Repair / identity / architecture | T1/T3 pre-probe guards | P2 token/SID/registry audit. |
| 7 Userinfo empty legacy hash / corruption | T7 new input/hash controls; existing legacy suite unchanged | P3 new/legacy transport counters and terminal integrity failure. |
| 8 Archive escape / unsafe cache | T7 lexical/model rejection | P2 actual ACL/reparse/race protection; P3 extraction boundary. |
| 9 Quoting / secrets | T4 oracle and output scans | P2 Windows recorder/vendor parsing and secret channel audit. |
| 10 Journal injection | T6 closed records/binding | P2 protected atomic journal/ACL attack tests. |
| 11 Different versions / awaiting reboot | T6 Busy/model reservation | P2 actual cross-process and reboot reservation. |
| 12 External MSI busy | T5 bounded Busy model only | P2 real contention, elapsed bounds, no process kill. |
| 13 GSA coexist/cache invalid | T2/T3 identity/cache blockers | P2 signer and vendor cache layout proof. |
| 14 Network lost after removal | T7 required closure inventory only | P2 real offline replacement/recovery; missing proof blocks release. |
| 15 Removal3010 / same/new boot | T5/T6 transition/count model | P2 actual reboot, re-detection and exactly-once safe continuation. |
| 16 Removal1641 / abrupt power loss | T6 intent/reconciliation model | P2 interruption before launch/during/after removal, retained content. |
| 17 Install finished/no commit / child lives | T6 postcondition/process decisions | P2 real crash and surviving child lifetimes. |
| 18 Cancellation / timeout | T5/T6 safety boundary model | P2 actual waits, state and retained content. |
| 19 Exit0 missing target / install3010 | T5 invariants | P2 actual recipe postconditions. |
| 20 Defer /1602 /1618 | T5 source/stage distinctions | P2 supervised PSADT4.1.8 child/session proof. |
| 21 Unlocked then lock/logoff | T3 eligibility snapshots | P2 transitions, audience and token/UI evidence. |
| 22 Console/disconnected/RDP/unknown | T3 ownership blockers | P2 multi-session process/filesystem isolation. |
| 23 No user / OOBE / ESP | T3 silent/enrollment policy | P2 sessions; P4 IME/enrollment delivery. |
| 24 Reopen / unsaved / deadline | T3 recheck/deadline default | P2 document sentinel and actual process behavior. |
| 25 Stable defer identity / DST | T3 UTC/retry-owner model | P2 toolkit history; P3 real provider retry scheduling. |
| 26 7-Zip versions/ProductCode | T2 synthetic normalized comparison, T5 rejects unproven1638 | P2 MSI identities, same ProductCode and stale DisplayVersion qualification. |
| 27 VS Code users/coexist/running | T1–T3 scope/process model | P2 commercial identity, no elevation/data loss; P4 user targeting. |
| 28 Repeat build / changed config | T7 byte equality and binding | P3 trusted catalog/publication/retained artifact verification. |
| 29 Detector no cache /32-bit agent | T7/T8 isolated generated detector | P2 actual 5.1; P4 IME bitness, Sysnative and registry views. |
| 30 Intune GSA continuation | T3/T7 blocked capability | P4 cannot publish without separately owned/qualified continuation. |
| 31 Duplicate removal ownership | T7 metadata gate/local prereq model | P4 supersedence/dependency configuration and assignments. |
| 32 Missing ensureAbsent | T7 publication rejection/no dummy | P2 real uninstall qualification; P4 generated command/lab proof. |
| 33 Rollout off / disk pressure | T6 retention/no legacy fallback model | P2 real storage pressure; P3 rollout selection and recovery preservation. |

P1 exit requires all offline tests, six intentional mutants, deterministic artifact comparisons and independent reviews to pass. It produces no qualified release. P2 must implement and prove privileged IO/execution, actual result-write failure handling, locks/atomic journals/ACLs, supervised toolkit sessions, all three application identities/postconditions and interruption boundaries. P2 requires separately authorized isolated Windows VMs; record scope/SID, boot, sessions, raw results and recovery content, including no-network runs and retained-byte tampering. Runtime support is not established by a 5.1-compatible syntax check alone.

P3 implements the explicit bundle selector and authenticated catalog/entrypoint verification alongside untouched legacy script semantics, then pilots allowlisted P1/P2-qualified releases. Keep legacy empty-hash no-op and URL-userinfo ordering; bundle protocol uses structured new outcomes, never legacy two-child Reinstall. Rollout rollback stops new selections but preserves original pinned recovery content; it is not application downgrade.

P4 belongs to the separate CIPP adapter. It consumes qualified generated artifacts, real ensureAbsent commands, requirements, correct machine/user targeting and 64-bit launch/detection, code mappings and one provider restart owner. It requires P1/P2 evidence and IME lab proof before tenant pilot. Initial specimens remain nonpublishable; GSA intermediate-reboot replacement remains gated. P5 capabilities (mixed scope, repair/downgrade, MSIX, autonomous resume) require separate design/qualification.

## Execution handoff

- [ ] Maintainer reviews this plan before implementation. The selected method is already subagent-driven; do not ask them to choose again. This planning change is not permission to run an installer.
- [ ] Integrator establishes isolated implementation lane(s) from `origin/main`, integrates the reviewed design/plan by explicit commits, and assigns nonoverlapping paths. Fresh task author and fresh task reviewer work serially through dependencies; review required fixes before accepting each commit. Workers do not update central status/plans.
- [ ] After Task 8, a fresh whole-branch reviewer independently checks spec coverage, source/digest trust, false compliance, destructive replay models, host compatibility and deferred claims. Resolve findings and rerun affected checks.
- [ ] Integrator updates the committed resume status with branch/HEAD, checks, uncommitted files and next P2 task, opens a PR into main, and reports required CI accurately. Do not merge as part of P1 or waive the existing documentation-only AI-filter failure without an explicit repository decision.

Plan-author self-review: checked spec coverage against all 33 scenario rows; matched function signatures and record fields across tasks; kept each task's red/green/commit/review boundary; assigned all five Review Focus cases; and kept this document to contracts and assertions rather than implementation bodies. All future work remains unchecked.
