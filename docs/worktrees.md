# Worktrees

Parallel agents each get their own worktree and their own branch. The
integration branch is `main`. A worker does not commit on `main`.

## Where the worktree lives

Grok starts a subagent in an isolated worktree. Use that worktree. Do not
also run `git worktree add` inside that subagent.

Other agents use `.worktrees/<branch>` in this repository. `.worktrees/` is
gitignored. Create the branch from `origin/main`.

```bash
git fetch origin main
git worktree add .worktrees/lane-example -b lane/example origin/main
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
updates those files after the lane merges to `main`. Two lanes editing
the status file is the conflict this rule exists to avoid.

## Joining `main`

The integrator takes one lane at a time.

1. `git fetch origin main`
2. In the lane worktree, `git rebase origin/main`
3. Push `lane/<name>` and open a pull request with base `main`.
4. Wait until the checks are green, then merge.
5. On `main`, update `docs/STATUS.md` if the task finished.
6. Run `pwsh -NoProfile -File tests/run-all.ps1` before that status push.

A rebase conflict means the file lists overlapped. Stop that lane, give the
file to one branch, and replay the other change onto the new tip.

Workers may push `lane/<name>`. They do not push `main`. A pull request is
how `ai-pr-review.yml` runs. A direct push to `main` skips that review.

## Before you push

Run `scripts/scan-secrets.sh` in the worktree. It scans commits that are not
on `origin/main` with betterleaks 1.8.1 and `.betterleaks.toml`.

Once per clone:

```bash
git config core.hooksPath .githooks
```

That runs the same scan before `git push`. CI runs it again. A missing
local binary does not skip CI.
