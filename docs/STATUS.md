# Status

Updated: 2026-10-17

This file is the resume point. Do not put a client name, a device id, a
token, or a home-directory path here.

`AGENTS.md` and `.agents/` are local to the machine doing the work. Git
ignores both. A checkout of this repository does not include them. On a
machine that has them, read `AGENTS.md`, then `.agents/memory/MEMORY.md`.

## Now

- Branch: `teams-package` (local only, not pushed). Confirm with
  `git status -sb` and `git log -1 --oneline`.
- The Teams plan commit sits under the resume documents. Confirm with
  `git log --oneline`.
- Plan: `docs/plans/2026-10-17-teams-package.md`
- The maintainer accepted that plan on 2026-10-17.
- The maintainer asked on 2026-10-17 to push this branch, add GitHub Actions,
  and run the Teams package through those tests. That push is allowed. The
  pull request base is `deploy-runner`, not `main`. Do not merge pull request
  2. Do not install Teams on a client device.
- Next task: Task 3, Decide the action before anything runs. Tasks 1 and 2
  are committed. Do not pass `-Publish`. The installer files stay in
  `releases/cache/`.

## Already on `deploy-runner`

The runner plan `docs/plans/2026-10-17-deploy-runner.md` is implemented.
`deploy-runner` is pull request 2 against `main`:
<https://github.com/Relianco/device-scripts/pull/2>

Do not merge that pull request. `bootstrap.ps1` follows `main` and does not
check a hash.

## CI

GitHub-hosted `ubuntu-24.04`. There is no self-hosted runner in this repo.

- `pr-verify.yml` installs PowerShell and runs `pwsh -NoProfile -File tests/run-all.ps1`, then `node --test scripts/ci/ai-pr-review.test.mjs`.
- `ai-pr-review.yml` reviews a same-repository pull request with `gpt-6.1-sol`. A docs-only push posts `AI review skipped for this push:` and does not call the model again.
- `secret-scan.yml` runs betterleaks 1.8.1 on the pull request delta. The policy is generated in the job and has no allowlist.

## While you work

- One plan task at a time, on `teams-package`.
- When a task commit lands, check its box in the plan and set **Next task**
  in this file to the following task. Commit this file with the task.
- If you stop mid-task, say so here: what passed, what failed, and which
  files are dirty.
- Uploading blobs and running the package on a client device wait for the
  maintainer to ask. Pushing `teams-package` is allowed: the maintainer asked
  on 2026-10-17. The pull request base is `deploy-runner`.

## After Task 6

The controller still has to upload the two blobs and ask before any client
device runs the package. Pull request 2 stays open.
