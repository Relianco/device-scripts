# device-scripts
Cross-platform scripts for automated device data collection, hardware benchmarking, and endpoint management. Run via bootstrap or standalone.

## Agents

Engineering status for a new session is [docs/STATUS.md](docs/STATUS.md). Parallel agents use [docs/worktrees.md](docs/worktrees.md): one worktree per branch, and two lanes do not edit the same file. `AGENTS.md` and `.agents/` stay on the machine that is doing the work. Git ignores both, so a GitHub checkout does not include them.

## Deploy runner

The runner is `runner/Invoke-RelianRunner.ps1`. The three pins are `PackageSha256`, `ToolkitSha256`, and `BrandPackSha256`. An empty pin exits 0 and downloads nothing. There are three download attempts. A bad hash is not retried. Cancel exits 130. The blob base URL is `https://relianpub.blob.core.windows.net/pub/sec/`. bootstrap.ps1 remains the collector loader. `scripts/publish-relian-packs.ps1` prints those URLs and does not upload unless `-Publish` is set.
