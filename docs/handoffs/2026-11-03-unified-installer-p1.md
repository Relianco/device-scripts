# Unified Windows installer P1 execution handoff

This is the resume guide for a new implementation conversation. Planning and review do not establish Windows support. No engine has been implemented and no P1 implementation task is complete.

## Start here

1. Read `docs/STATUS.md` in the design lane. It identifies the current reviewed plan and next task; trust it over a pasted historical commit.
2. Read the checkout's local `AGENTS.md`, then `.agents/memory/MEMORY.md` and its relevant linked facts, especially `unified-installer-design.md`. The local files are gitignored and are not present in a public clone.
3. Read the [architecture](../superpowers/specs/2026-11-02-unified-installer-design.md), [recipe specimens](../design/unified-installer/recipes.md), and [33-scenario matrix](../design/unified-installer/scenarios.md).
4. Read the complete [P1 implementation plan](../superpowers/plans/2026-11-03-unified-installer-p1.md), especially Global Constraints, shared contracts, task Interfaces, and phase gates. The checkboxes are the work list.
5. Read the [PAL consensus record](../reviews/2026-11-03-unified-installer-p1-pal-consensus.md). It distinguishes review findings, chosen fixes and deferred Windows evidence.
6. Fetch `origin`, inspect branch status/logs and worktrees, and recheck PRs [85](https://github.com/Relianco/device-scripts/pull/85) and [84](https://github.com/Relianco/device-scripts/pull/84), including CI and review comments. Do not assume their recorded states are still current.

The selected execution method is **subagent-driven development**. Preserve it; do not ask the maintainer to choose a workflow again. An explicit instruction to execute P1 in the new conversation authorizes the local pure implementation work described here. It does not authorize later deployment phases.

## Repository and branch state

- Repository: `Relianco/device-scripts`; target branch `main`.
- Reviewed design/P1 planning lane: `lane/installer-design`; linked worktree `.worktrees/lane-installer-design`; PR85 targets main.
- Initial PAL review input: planning handoff `205fd57`, with plan content from `c0c4ce2`. The first consensus revision is `4d04778`; the final PAL-reviewed plan is **`6c52814`**. All three models marked it Ready with no planning blockers. Follow `docs/STATUS.md` for the handoff commit or later changes; do not execute an older snapshot.
- Design ancestry starts from `40fb716`. At this handoff's initial fetch, `origin/main` was `ef12f67`; those intervening changes concerned unrelated diagnostics.
- Local root main was `22eb903`, behind origin/main, with pre-existing untracked root `brand/` and `releases/`. Preserve them. Do not reset or clean the root checkout.
- The existing author lane `.worktrees/lane-installer-p1-author` contains documentation commits only. It is not an implementation lane and must not be mistaken for completed P1 work.
- Exact local paths and later machine-specific state belong in `.agents/STATUS.md` and `.agents/memory/`, never public source.

Create a new implementation lane from current `origin/main` with a `lane/` branch. If PR85 has merged, its design/plan should already be present: verify and avoid replaying those commits. If PR85 is still open, explicitly integrate its reviewed documentation commits into the new lane without merging PR85 or changing main. Use `git log origin/main..lane/installer-design` to identify the complete documentation range, including consensus fixes, review record, and this handoff. Check that only intended documentation is carried over; preserve newer main changes. Do not force-push main or reuse a busy lane.

## What P1 builds

P1 builds a provider-independent, offline-testable foundation under `windows/installer/`. It does not replace the existing runner or package scripts.

| Order | Deliverable | Review boundary |
| --- | --- | --- |
| 1 | Strict versioned recipes/requests/release inputs/state records, canonical data, trusted request binding | Invalid input cannot bypass validation or change identity/configuration. |
| 2 | Shared read-only collection and evaluation | Error/provenance/coverage fidelity; independent product-truth assertions. |
| 3 | Read-only planning and process/session policy | No writes, downloads, UI, process closure or mutation; active-operation precedence. |
| 4 | Structured EXE/MSI descriptors and bounded rendering | Executable provenance, quoting or supported grammar, enforced MSI defaults. |
| 5 | Structured outcomes and code projections | Exit codes cannot fabricate postconditions, cancellation, deferral or replay safety. |
| 6 | Pure recovery/reconciliation/retention transitions | Lifetime mutation history, safe reboot re-entry, cancellation and exact terminal effects. |
| 7 | Local resolved inputs and deterministic preview generation | Bound sources/configuration, no digest cycles, no false vendor-byte verification. |
| 8 | Integrated detector parity, independent truth checks, mutations and documentation | Guard sensitivity, full branch checks and final independent review. |

Start at **Task 1: write and run the failing contract test** after the resume checks and lane setup. Execute in order. Each task has its own red/green cycle and independent review. Do not dispatch concurrent implementation tasks against shared contracts or fixtures. The integrator owns central status/plan tracking; workers own their assigned nonoverlapping paths in isolated lanes. After a reviewed commit, record the actual commit and check result in a durable local execution ledger before starting the next task. After interruption or compaction, inspect that ledger and git history before redispatching work.

## Decisions that must survive the handoff

- PSADT baseline remains **4.1.8**, with the repository pin. No implicit upgrade.
- Runtime/shared discovery/generated detector source targets the Windows PowerShell **5.1 / .NET Framework 4.8** subset. Build and test tooling uses `pwsh` **7.4+**, with the plan's portable deterministic artifact format. A passing Linux run or compatibility lint is not actual 5.1 proof.
- Recipe data is closed and versioned. No evaluated expressions, arbitrary script hooks, executable override or registry `UninstallString` execution.
- Execution identity, installation scope and notification audience are independent. Native user execution means the verified owning standard user, not impersonation from SYSTEM. Another user's installation cannot satisfy detection.
- Observable parameter changes require a rebuilt trusted release and detector. Transport and command-only options cannot silently alter desired-state truth. User input cannot change parameter classification.
- Discovery distinguishes `Absent`, `Present`, `Unknown`, `Ambiguous` and `Damaged`. Unreadable evidence never becomes absence. Preserve every candidate/error and validate provenance, coverage and freshness against trusted context.
- Product detection is journal-independent. Runtime planning gives unresolved operations priority over `AlreadySatisfied`, even if the installed product looks compliant.
- Independent expected-state/probe-coverage fixtures are required in addition to runtime/detector parity. Two callers sharing the same wrong evaluator is not evidence of correctness.
- Stage and verify the entire required replacement closure before destructive operations in future execution. No hash-mismatch retry. P1 only models those prerequisites; it does not perform removals or staging on devices.
- Recovery retains immutable identity/configuration and lifetime destructive history. Same-boot re-entry cannot repeat removal or proceed across a required reboot. Interrupted work must be reconciled from current evidence, including surviving-process uncertainty.
- Verification-only re-entry cannot install/remove again. Pre-mutation supersession has an explicit terminal transition and releases only its own references/reservation; it cannot delete shared content or rewrite the old binding.
- A terminal `Complete` record with `Cancelled` outcome has no successful completion evidence and cannot reconcile into success. Successful completion uses the separate typed `CompleteVerified` event and once-only model ownership effects.
- `CompleteRebootRequired` means postconditions are satisfied. `RebootRequiredIncomplete` means replacement is incomplete. Bare vendor/toolkit exit codes are insufficient to infer completion, user deferral or replay safety.
- Real specimen pins remain real. Synthetic byte-resolution tests use separately identified synthetic inputs. Never fetch binaries in tests or weaken integrity checks to make fixtures pass.
- P1 emits `relian.windows.bundle.preview` version 1, `deployable=false`, no action entrypoint, and no dummy uninstall. Publishing remains blocked even if fixture qualification claims passed.
- The future `relian.windows.bundle` protocol is explicit and coexists with the legacy single-script runner; P1 does not alter that runner's behavior.
- Intune is silent with provider-owned notifications and restart behavior. Publication requires separately qualified `ensureAbsent` and real uninstall. Unqualified intermediate-reboot replacement is blocked before removal.
- V1 has explicit/provider re-entry, no autonomous resume scheduler. Specimens remain unqualified and promise no rollback.

Two final review reminders belong in task briefs: Task 3 must reject terminal records supplied as active with a stable explicit error (such as `TerminalOperation`), never return null/absence and allow conflicting work; Task 1 must preserve and append to an existing root `.gitattributes` if one exists. Keep binary artifacts outside `windows/installer/` source paths.

## Test and evidence requirements

Use the exact task commands from the plan. Tests are plain offline PowerShell scripts under `tests/windows/installer/`, discovered recursively by `tests/run-all.ps1`; no Pester. Dot-source runtime scripts with `RELIAN_DEPLOY_TEST=1`, without Mandatory parameter prompts or import-time effects.

For each task, record a failure that reaches the intended assertion, then the passing run. Rejection tests must show zero prohibited calls and valid surrounding prerequisites; an unrelated later exception is not proof. Model-based recovery evidence must remain labeled as such. Keep fixture data synthetic and free of machine/client identifiers.

The baseline six mutation controls remove hash validation, collapse unknown to absence, remove SID/scope validation, skip postconditions, permit same-boot continuation, and perturb generated detection version. Preserve additional consensus-required negative controls in the revised plan. Every mutation must fail for its named reason, with an unmodified passing control and exactly one intended mutation site.

Final branch commands:

```sh
pwsh -NoProfile -File tests/run-all.ps1
node --test tests/ai-pr-review.test.mjs tests/secret-scan.test.mjs
scripts/scan-secrets.sh
git diff --check
git status -sb
git log --oneline origin/main..HEAD
```

The Node paths above reflect current repository layout; the local AGENTS command list has older paths. `docs/worktrees.md` is absent in the reviewed checkout; use the actual local lane rules. Configure `core.hooksPath=.githooks` if needed. Commit as `Relian Technologies <112814130+Relianco@users.noreply.github.com>` without a coauthor trailer or AI footer. Do not commit generated binaries, toolkit archives, `.agents/`, `AGENTS.md` or `CLAUDE.md`.

## Review and CI interpretation

The design had independent research, authoring, task review and whole-branch review. Initial P1 reviews corrected configuration binding, verification-only re-entry and supersession. PAL subsequently reviewed the plan across OpenAI, Anthropic and Google models; the linked consensus record is the authoritative disposition list, including any qualifications or unresolved findings. A consensus result is planning evidence, not software qualification.

At `205fd57`, hosted PowerShell and secret CI passed. AI review failed because its filter found no reviewable source files in a documentation-only PR; no model review occurred in that CI job. PAL is separate from that job and does not waive it. Recheck current checks; never report that required CI is wholly green merely because external reviewers approved.

P1 exit requires all planned offline tests, mutation controls, deterministic comparisons, task reviews and final whole-branch review. Fix findings and rerun affected checks. Record real output and known limitations rather than inferring success from code inspection.

## Deferred work and authorization limits

P2 implements and qualifies real privileged storage/execution, ACL/reparse protections, atomic journals, locks, supervised PSADT sessions, Windows argument parsing, signatures, identities and postconditions, cancellation/timeouts, interruption, reboot and offline recovery. It requires separately authorized isolated Windows VMs. P1 does not certify these behaviors.

P3 adds bundle delivery alongside the legacy runner and pilots allowlisted qualified releases. P4 changes the separate CIPP adapter and proves IME targeting, bitness, notifications, return codes and continuation before any tenant pilot. P5 capabilities such as mixed scope, MSIX, downgrade, repair and autonomous resume need separate design/qualification.

Do not run an installer on any device, change a tenant, publish binaries, merge a PR or force-push main based on this handoff. Do not use historical live-device permissions as authorization in the new session. An implementation PR is reviewable work; deploying it is a separate action.

## Separate GSA work

PR84 remains separate on `lane/gsa`, worktree `.worktrees/lane-gsa`, recorded HEAD `db87fa6`. It adds standalone GSA 2.34.222. Its temporary content is deleted on intermediate-reboot exit, so it does not implement the proposed durable recovery.

At the last check it was open with passing CI and four automated review comments: a userinfo URL test can pass for the wrong reason, transient download retry behavior, unsupported Uninstall, and lowercase hash formatting. Those comments were inspected, not fixed or accepted as requirements for this plan. Inspect current state before any separate GSA work; do not merge it into P1 or assume it is a qualified recipe.

## End the implementation conversation cleanly

Update and commit `docs/STATUS.md` with branch, reviewed implementation HEAD, completed/next task, test/review evidence and uncommitted files. Update local memory when machine-specific facts change. Preserve interrupted-operation and qualification limitations. Open/update the implementation PR into main, report current CI accurately, and stop before any unauthorized later phase.
