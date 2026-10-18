# Worktrees

Parallel agents each get their own worktree and their own branch. The
integration branch is `teams-package`. Pull request 3 tracks it. A worker
does not commit on `teams-package`, does not commit on `main`, and does not
merge pull request 2.

## Where the worktree lives

Grok starts a subagent in an isolated worktree. Use that worktree. Do not
also run `git worktree add` inside that subagent.

Other agents use `.worktrees/<branch>` in this repository. `.worktrees/` is
gitignored. Create the branch from `origin/teams-package`.

```bash
git fetch origin teams-package
git worktree add .worktrees/lane-example -b lane/example origin/teams-package
```

Branch names start with `lane/`. One branch per task. Do not reuse a branch
that another live worktree has checked out.

## Which files a lane may edit

Write the file list before the lane starts. Two live lanes must not list
the same path. A new test file is safe: `tests/run-all.ps1` runs every
`tests/*.Tests.ps1`.

These paths have one owner at a time. A second lane waits.

- `packages/teams/Invoke-Teams.ps1`
- `runner/`
- `packages/action-probe/`
- `bootstrap.ps1` and `collectors/`
- `.github/workflows/`
- `scripts/ci/`

A new application is a new directory, `packages/<name>/`, plus its own
`tests/<name>-*.Tests.ps1` and `releases/<name>.json`. That lane does not
edit an existing package.

Workers do not edit `docs/STATUS.md` or `docs/plans/`. The integrator
updates those files when the lane joins `teams-package`. Two lanes editing
the status file is the conflict this rule exists to avoid.

## Joining the integration branch

The integrator takes one lane at a time.

1. `git fetch origin teams-package`
2. In the lane worktree, `git rebase origin/teams-package`
3. Fast-forward `teams-package` to that commit.
4. Update `docs/STATUS.md` and the plan checkboxes on `teams-package` if the task finished.
5. Run `pwsh -NoProfile -File tests/run-all.ps1`.
6. Push `teams-package`.

A rebase conflict means the file lists overlapped. Stop that lane, give the
file to one branch, and replay the other change onto the new tip.

Workers may push `lane/<name>`. They do not push `teams-package`.
