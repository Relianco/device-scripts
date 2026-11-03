# P1 plan: PAL consensus review

## Review scope and evidence

The maintainer requested PAL **consensus** and a thorough handoff for implementation in a new conversation. This session reviews and revises documentation only. No engine implementation, device installation, tenant change, binary publication or merge is included.

Initial reviewed checkout: `205fd57` on `lane/installer-design`; plan content last changed at `c0c4ce2`. All reviewers received the complete [P1 plan](../superpowers/plans/2026-11-03-unified-installer-p1.md), [architecture](../superpowers/specs/2026-11-02-unified-installer-design.md), [specimens](../design/unified-installer/recipes.md) and [scenario matrix](../design/unified-installer/scenarios.md). The prompt asked for concrete triggering inputs, consequences, smallest changes and falsifiable tests, including failures shared by runtime and detector.

PAL consensus consultation completed successfully for all three models on 2026-11-03:

| Model | Stance | Initial verdict |
| --- | --- | --- |
| `gpt-6.1-sol` | Neutral | Not ready: targeted recovery, provenance, parsing and rendering changes needed. |
| `claude-opus-5-5` | Adversarial, evidence-based | Ready with changes: fixture feasibility, serialization, host compatibility and task interfaces. |
| `gemini-4-argon` | Neutral | Ready with changes: recovery edges, shared-evaluator coverage, task dependencies and artifacts. |

Initial PAL continuation ID: `1e50dc4a-55f6-4a6c-934d-2b8f66fbf620`. The final PAL tool response marked consensus gathering complete after three successful model consultations. The recommendations below are the integrator's synthesis and dispositions, not a claim that a fourth model independently approved them. Raw responses are retained in local project memory; public documentation records every distinct finding and resolution.

## Agreement, differences and recommendation

All reviewers supported the provider-independent architecture, immutable observable configuration, noncircular digest graph, nondeployable previews, explicit re-entry and P1/P2/P3/P4 separation. They agreed that runtime/detector parity needs independent expected-truth tests and that serialization/host assumptions must be explicit.

Their readiness labels differed in severity, not in recommending immediate unchanged execution: one said Not ready, two said Ready with changes. The integrator therefore required plan revisions before handoff. Some reports overstated existing intent: cancellation already said only before destructive work, and matching MSI defaults were not explicitly prohibited. The gaps were the record representation, transition guards and merge rules needed to implement that intent consistently.

Not every proposed remedy was adopted literally. Exact original-key enumeration and ordinal validation can support ordinary PowerShell hashtable inputs; rejecting every case-insensitive container is unnecessary. UTF-8 with BOM supports non-ASCII Windows PowerShell scripts without requiring ASCII-only output. The first revision chose an exact qualified ZIP writer environment. Re-review exposed that this would make ordinary CI/developer test runs fail on different runtime patch levels. The final revision therefore specifies a bounded portable stored-ZIP writer with fixed bytes and independent readback, identified by source digest and format version rather than host identity. The hashtable and BOM alternatives remain accepted; the archive decision changed in response to that concrete integration problem.

## Finding dispositions

`O` identifies OpenAI findings 1–6; `C` identifies Claude findings 1–12 plus its low-severity newline observation as C13; `G` identifies Gemini findings 1–5. Overlapping findings are grouped without omitting their distinct requirements. The implementation plan contains the operative contract and named tests; this table explains why they are present.

| Finding IDs | Issue / triggering case | Required disposition in revised plan |
| --- | --- | --- |
| O1, G1, C10 | Removal succeeds, operation returns Ready, then cancellation arrives | Lifetime destructive history survives phase changes. Only genuinely pre-intent cancellation can terminate with Cancelled. Post-removal cancellation retains recovery references/reservation and reports incomplete work. Removal completion selects Install, never another removal. |
| O2 | Crash after successful install but before completion record | Explicit completion evidence and terminal effects, preserving immutable identity and applying ownership release once; repeated terminal reconciliation cannot double-release or fabricate success. |
| C9 | Removal intent has no completion record | Reconcile fresh product/process/content/boot evidence. No blind removal replay. Permit install only at a proven safe transition; uncertainty remains recovery. |
| C8, G3 | Planner consumes recovery records before their schema exists | State record shape belongs to Task 1; Task 3 validates active-operation dispatch; Task 6 owns transition semantics. Same ID with changed binding is invalid; foreign mutated work is Busy. |
| O3 | Valid-looking observations from wrong release, SID, epoch or incomplete coverage | Bind provenance and coverage to trusted expected context, including explicit time/freshness inputs; reject or return unknown without compliance. Never trust observations merely because they contain a digest. |
| C7, G2 | Runtime and detector share a bug or omit a required probe/postcondition | Independent literal expected-truth and expected-coverage fixtures; include coexistence/postconditions in detection projection; test missing views and GSA old-bundle/file conditions. |
| O4, C2, G5 | Date-shaped strings, malformed UTF-8, escaped duplicate keys, surrogate or escaping drift | Direct strict JSON materialization with explicit byte/string rules; stable canonical escaping, Unicode and numeric semantics; independent literal-byte oracles. |
| C3 | Wrong-case keys appear valid through case-insensitive lookup | Validate actual original keys ordinally before lookup; reject decoded duplicates/case collisions and unknown spelling. Copy validated records into controlled representation. Do not infer original JSON validity from a lossy caller container. |
| C4, C13, G5 | Non-ASCII generated script or platform line endings change meaning/hashes | Explicit 5.1-compatible script encoding, fixed source and output newline policies, byte tests; canonical JSON remains a distinct BOM-less representation. |
| C1 | Real vendor/toolkit hashes paired with synthetic fixture bytes | Separate specimen parse/blocker fixtures from resolvable synthetic inventories. Missing real content is ContentUnavailable. Test actual integrity against actual synthetic hashes without a public bypass of production pins. |
| C5 | User detector has no trusted caller SID at build time | Detector constructs invocation from its own verified token/host context at execution; no caller-controlled SID or ambient test parameter. Actual Windows context remains a qualification gate. |
| C6 | Test harness changes unspecified parts of generated detector | One explicit test boundary with exact match count and byte equality outside it; production artifact exposes no fixture channel. |
| O5, G4 | MSI properties with unsupported characters or duplicate enforced defaults | Conservative supported MSI grammar and independent expected encodings; matching enforced ALLUSERS/REBOOT defaults deduplicate, conflicting values reject. EXE adversarial argv tests remain separate. |
| O6 | Signature-chain checks cause implicit network IO | Read-only probes are local-only; unavailable required trust remains unknown/unverified. Distinguish signer extraction from trust proof and test provider/network call counts. |
| C11 | A pwsh 7 parser accepts source that 5.1 cannot run | Compatibility lint has negative controls for known unsupported syntax/APIs; it does not replace actual Windows PowerShell qualification. |
| C12 | ZIP writer/runtime variations change bytes | Portable bounded stored-ZIP format, writer source digest/version, fixed headers and independent golden bytes/readback on supported hosts. No host-specific golden or skipped CI check; no platform ZipArchive output assumption. |

## Source checks and limits

Microsoft documents the [UTF-8 BOM requirement for non-ASCII Windows PowerShell source](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_character_encoding). Its [ConvertFrom-Json documentation](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/convertfrom-json) describes timestamp conversion and the later DateKind control. These support the encoding and direct-materialization decisions; actual 5.1 execution remains untested here.

A local read-only PowerShell probe confirmed that a normal hashtable preserves the original key `Scope` while `ContainsKey('scope')` also returns true. This supports validating enumerated original names rather than treating successful lookup as exact-schema compliance. It does not prove duplicate detection after a caller has already discarded duplicate input.

Actual Windows token/registry behavior, Authenticode/network isolation, ACL/reparse races, atomic disk journals, locks, surviving child processes, vendor parsing, reboot and offline recovery, PSADT sessions, and IME/provider behavior remain P2–P4 proofs. No consensus approval can waive those gates.

## Revised-plan review

The first consolidated revision is `4d04778` (author commit `9b06e83`). A second full PAL consensus reviewed a fresh snapshot under the same continuation:

- OpenAI: Ready; all original groups resolved or reasonably adjudicated; handoff actionable.
- Gemini: Ready; all 24 original numbered findings resolved; no remaining blocker identified.
- Claude: Ready with changes; original concerns addressed, but three final clarifications requested. Its response explicitly said the separate handoff/disposition drafts were not visible, so this is not counted as its approval of those drafts.

The remaining changes are exact native-boundary ownership in Task 2, portable archive bytes across ordinary test hosts, and explicit successful/cancelled terminal-evidence shapes. Small nonblocking notes also clarify Int64/negative-zero input, inclusive freshness bounds, LF checkout policy and retained content after administrative abandonment. These are planning clarifications, not runtime fixes.

## Final review and handoff status

Final reviewed plan commit: **`6c52814`** (author commit `40e4308`). A third, focused PAL consensus supplied the exact replacement paragraphs and the complete handoff inline so all models could inspect it, including Claude. All three consultations succeeded:

| Model | Final verdict | Scope |
| --- | --- | --- |
| `gpt-6.1-sol` | Ready | Named closure changes verified; full handoff adequate. |
| `claude-opus-5-5` | Ready | All targeted findings closed; full handoff adequate; two nonblocking implementation reminders below. |
| `gemini-4-argon` | Ready | Named closure changes verified; full handoff adequate. |

**No planning blockers remain.** PAL consensus gathering completed; the integrator recommends starting P1 at Task 1 in a new conversation when the maintainer explicitly instructs execution. This is not implementation approval by test evidence and does not certify Windows/provider behavior.

The two nonblocking reminders are carried into the handoff: reject terminal records supplied as active with an explicit error, never a null/absent fallthrough; preserve/append any existing `.gitattributes` rather than overwrite it. Binary artifacts remain outside installer source. No model-requested finding was silently discarded.

Implementation remains unstarted. All task checkboxes are unchecked. Use the [execution handoff](../handoffs/2026-11-03-unified-installer-p1.md) and `docs/STATUS.md` to resume. The status commit follows the reviewed plan commit and records validation/CI separately.
