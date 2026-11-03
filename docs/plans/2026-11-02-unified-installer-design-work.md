# Unified installer design work

## Scope

Produce the architecture, scenario matrix, example recipes, phased migration,
and acceptance/Windows validation plan requested in the design discussion.
This is a design deliverable, not authorization to implement the engine or
deploy installers. Use subagent research, independent authoring, task review,
and a final broad review.

## Global Constraints

- Public documents contain no client names, device IDs, secrets, or home paths.
- Design only: no runtime edits, installer runs, tenant changes, or binary publication.
- Retain PSAppDeployToolkit 4.1.8 as the researched baseline; verify exact API claims.
- Provider APIs stay outside the execution engine. System and User scope are first-class.
- Examples cover GSA 2.34.222, machine-wide 7-Zip, and an evidenced per-user application.
- Unknown state is not absence; success requires postcondition verification.
- Build on current repository constraints, including single-script runner delivery.
- Claims about actual Windows execution must be distinguished from source evidence.
- Workers use isolated lane worktrees and do not edit docs/STATUS.md or docs/plans/.

## Tasks

- [x] Task 1: Parallel read-only evidence gathering for engine, PSADT experience, and Intune/context.
- [x] Task 2: Author an integrated design under docs/superpowers/specs/ with scenario and recipe appendices.
- [x] Task 3: Independent task review for requirement coverage and architectural quality; resolve findings.
- [x] Task 4: Whole-branch builder review, documentation validation, status update, and pull request.

## Validation

Verify cited local source anchors and upstream references. Check relative links,
example JSON syntax where used, whitespace, and public-content safety. No tests
that merely assert document wording. Existing runtime code remains unchanged.

## Result

Design: [Unified Windows installer foundation](../superpowers/specs/2026-11-02-unified-installer-design.md).
Three research agents, one author, a task reviewer, and a final builder reviewer
completed the design workflow. Both independent reviews reported no findings.
Four JSON examples, relative links, whitespace, and public-content checks passed.
Runtime implementation and Windows/Intune qualification remain future phases.
