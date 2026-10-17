# Status

Updated: 2026-10-17

This file is the resume point. Do not put
a client name, a device id, a token, or a home-directory path here.

## Now

- Branch: `teams-package` (local only, not pushed). Confirm with
  `git status -sb` and `git log -1 --oneline`.
- Parent of the resume documents: `c7d3edb` `Add the Teams package plan`.
- Plan: `docs/plans/2026-10-17-teams-package.md`
- The maintainer accepted that plan on 2026-10-17 and asked for this resume
  file so a new session can continue.
- Next task: Task 1, Pin the bootstrapper and the x64 MSIX. No task has
  been started. Every checkbox in the plan is open.
- Uncommitted: `docs/ninja-script-variables.md` is an untracked local note.
  Leave it untracked unless the maintainer asks to commit it.

## Already on `deploy-runner`

The runner plan `docs/plans/2026-10-17-deploy-runner.md` is implemented.
`deploy-runner` is pull request 2 against `main`:
<https://github.com/Relianco/device-scripts/pull/2>

Do not merge that pull request. `bootstrap.ps1` follows `main` and does not
check a hash. There is no GitHub Actions workflow on this repo. Tests are
local: `pwsh -NoProfile -File tests/run-all.ps1`.

## While you work

- One plan task at a time, on `teams-package`.
- When a task commit lands, check its box in the plan and set **Next task**
  in this file to the following task. Commit this file with the task.
- If you stop mid-task, say so here: what passed, what failed, and which
  files are dirty.
- Uploading blobs, pushing, and running the package on a client device are
  controller steps. They wait for the maintainer to ask.

## After Task 6

The controller still has to upload the two blobs, push `teams-package`, and
ask before any client device runs the package. Pull request 2 stays open.
