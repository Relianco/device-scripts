# Teams package

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a machine-wide Microsoft Teams package that the existing deploy runner can install, update, repair, uninstall, and reinstall, with a hash-pinned bootstrapper and x64 MSIX.

**Architecture:** The runner on branch `deploy-runner` already downloads one package script plus the toolkit and brand pack. This plan does not change the runner. The Teams script makes the version decision, downloads the two pinned payloads with the same retry and cancel rules, and calls `teamsbootstrapper.exe`. PSAppDeployToolkit 4.1.8 shows one deferral when Teams or Outlook is running. Tests are plain `pwsh` scripts with the network and the toolkit replaced by hooks.

**Tech Stack:** Windows PowerShell 5.1 on the device, `pwsh` for tests, PSAppDeployToolkit 4.1.8, `teamsbootstrapper.exe`, an x64 Teams MSIX.

**Spec:** This plan is the authority. There is no separate spec document.

## Global Constraints

- Work on branch `teams-package`, cut from `deploy-runner` at `61e6ec4`. Do not commit to `main`. Do not push. Do not open a pull request. Do not merge pull request 2.
- Do not run anything on a client device. Do not pass `-Publish`.
- Do not modify `bootstrap.ps1`, `collectors/`, `runner/Invoke-RelianRunner.ps1`, or `packages/action-probe/`.
- The package does not call `Ninja-Property-Get`, `Ninja-Property-Set`, or any NinjaOne API. It does not read `relian_git_deploy_token`.
- A payload URL with userinfo (`scheme://user@host`) exits 1 before any download. A hash mismatch exits 1 and does not run the bootstrapper. Neither case is retried.
- Download retries: 3 attempts, only timeout, connection, or DNS failure, or HTTP 408, 429, 500, 502, 503, 504. Waits are 5 seconds then 20 seconds. `$script:RetryDelay` and `$script:DownloadFile` are the test hooks. Error text names the label (`bootstrapper` or `msix`) and never includes the URL.
- Cancel is `RELIAN_DEPLOY_CANCEL=1` or `-CancelPath`, checked before each attempt and during each wait. Exit 130. Do not kill a bootstrapper process that has started.
- Empty or whitespace `PinVersion` exits 0 and changes nothing, for every action.
- An unparseable `PinVersion` exits 1 and changes nothing.
- Action `Reinstall` is not implemented in the package. The runner already sends Uninstall, then Install. A package call with Action `Reinstall` exits 1 and changes nothing.
- Vendor build newer than the pin stays installed. Do not run `-p` in that case. Write the marker to the installed version. Do not log `Install`.
- Repair re-registers the installed package in place. It does not pass `-x`, does not call `Reset-AppxPackage`, and does not download the MSIX.
- Uninstall is `teamsbootstrapper.exe -x` with a full path to the exe. That command removes Teams and the meeting add-in, and it deletes the Teams user cache.
- Install and update use `teamsbootstrapper.exe -p -o "<full path to msix>" --installTMA`. Do not use `-p` without `-o`.
- Set `HKLM\SOFTWARE\Microsoft\Teams\IsWVDEnvironment` to DWORD `1` when the value is missing or is not `1`. Do not set `disableAutoUpdate`. Do not download or install the WebRTC redirector (`MsRdcWebRTCSvc` must not appear in the package).
- Classic Teams removal runs only after a successful new-Teams provision, or when new Teams is already present. Product codes, only if that product is installed: 64-bit `{731F6BAA-A986-45A4-8936-7C3AAAAA760B}`, 32-bit `{39AF0813-FA7B-4860-ADBE-93B9B214B914}`, via `msiexec.exe /x <code> /quiet /norestart`. Per-user classic uses `Update.exe` at `AppData\Local\Microsoft\Teams\Update.exe` with arguments `-uninstall -s`. A classic-removal failure exits 1 and leaves the marker unchanged.
- Marker file is `marker.txt` under the marker root. Default root is `$env:ProgramData\Relian\teams`. The file contains the installed four-part version and nothing else. Write it only after the action's mutating steps succeed. Exit 1 leaves it unchanged.
- Log file is `toolkit.log` in that root. Append `Install` only when `-p -o` runs and exits 0. Append `Repair` only when a re-register runs and exits 0. Append `Uninstall` only when `-x` exits 0 and the marker is then removed.
- Close-process names, without `.exe`: `ms-teams`, `Teams`, `OUTLOOK`. Put only the names that are running into `AppProcessesToClose`. An empty list is removed with `Remove-ADTHashtableNullOrEmptyValues` before `Open-ADTSession`.
- Show the welcome only when one of those processes is running and some session state is `Active`. `-AllowDefer -DeferTimes 1`. No logged-on user, or no listed process running: skip the welcome and continue. A session state `Disc` while a listed process is running, and the deferral is still unused: exit 1 before `Open-ADTSession` and do not count a deferral.
- Notice, install and update: `Teams will close for an update. You can wait once. The next run will close it and continue.`
- Notice, repair, only when a listed process is running: `Teams will close for a repair. You can wait once. The next run will close it and continue.`
- Notice, uninstall, and the uninstall half of a runner reinstall: `Teams will close. You can wait once. The next run will close it and continue. This removes the Teams sign-in on this PC.`
- Toolkit exit 1602 maps to package exit 1 and does not write the marker.
- Dot-source with `RELIAN_DEPLOY_TEST=1` defines functions and does not start work. Parameter blocks are not `Mandatory`.
- Tests are `tests/*.Tests.ps1`. They exit 0 on success and 1 on failure. No Pester. No network. `tests/run-all.ps1` already runs every test file.
- The shell is zsh. Never put command arguments in a scalar variable. `az` uses `--auth-mode login` and an argument array. Never put a key in a command.
- Do not commit `teamsbootstrapper.exe`, the MSIX, or anything under `releases/cache/`.
- Commit as `Relian Technologies <112814130+Relianco@users.noreply.github.com>`. No `Co-Authored-By` trailer.
- Source URLs, followed with redirects at pin time: bootstrapper `https://go.microsoft.com/fwlink/?linkid=2243204&clcid=0x409`, x64 MSIX `https://go.microsoft.com/fwlink/?linkid=2196106`. Device download base is `https://relianpub.blob.core.windows.net/pub/sec/`. Blob names are `teamsbootstrapper-<sha256>.exe` and `MSTeams-x64-<sha256>.msix`.

## Calls made in this plan

- Windows 365 still needs `IsWVDEnvironment=1` on a one-person Cloud PC. The WebRTC redirector is not installed. Microsoft ended support for that redirector on 2026-10-01.
- Autoupdate stays on. `disableAutoUpdate` is for non-persistent hosts.
- `--installTMA` is part of install and update. `-p -o` alone does not install the Outlook meeting add-in for the machine.
- Uninstall is `-x`, not `-x -m`. The current bootstrapper document uses `-x` to remove Teams and the meeting add-in.
- Rollback to an older pin is not a task. A later pin commit is how the published version moves.
- The dashboard, the Ninja stub hop, and `rmm-agent` are not in this plan.

## Review Focus

- A Teams build newer than the pin must not be replaced. The marker becomes that newer version, and `Install` is not logged.
- `teamsbootstrapper.exe -x` deletes the local Teams profile. The uninstall notice has to say that the sign-in is removed before the bootstrapper starts.
- Classic Teams is removed only after new Teams is actually present. Removing the machine-wide installer first can leave the PC with no Teams client.
- A disconnected session with Teams still running must exit 1 without consuming the one deferral.
- An empty `AppProcessesToClose` must be removed before `Open-ADTSession`. Toolkit 4.1.8 rejects it.

---

### Task 1: Pin the bootstrapper and the x64 MSIX

**Files:**
- Create: `releases/teams.json`
- Create: `scripts/pin-teams.ps1`
- Create: `tests/teams-pin.Tests.ps1`
- Modify: `.gitignore` (add `releases/cache/`)

**Interfaces:**
- Consumes: nothing
- Produces: `Get-TeamsPinHash -Path <file>` returns lowercase SHA256. `releases/teams.json` keys, all required: `name`, `arch`, `bootstrapperSourceUrl`, `bootstrapperFile`, `bootstrapperSha256`, `bootstrapperSize`, `msixSourceUrl`, `msixFile`, `msixSha256`, `msixSize`, `blobBase`. `arch` is `x64`. `name` is `Microsoft Teams`. `blobBase` is the base in Global Constraints. The two source URLs are the fwlinks in Global Constraints. Both hashes are 64 lowercase hex characters. Both sizes are integers greater than zero.

- [ ] **Step 1: Write the failing test**

`tests/teams-pin.Tests.ps1` dot-sources `scripts/pin-teams.ps1` under `RELIAN_DEPLOY_TEST=1`. It writes a temp file whose bytes are `teams-pin`, asserts `Get-TeamsPinHash` equals the SHA256 of those bytes, and asserts a json fixture with a short hash or a missing `msixSha256` makes `Test-TeamsPinRecord` return `$false`. It then loads `releases/teams.json` and asserts `Test-TeamsPinRecord` returns `$true`. It does not download.

- [ ] **Step 2: Run the test and confirm it fails**

Run: `pwsh -NoProfile -File tests/teams-pin.Tests.ps1`
Expected: FAIL because `pin-teams.ps1` does not exist.

- [ ] **Step 3: Implement the pin script and fill `releases/teams.json`**

`Get-TeamsPinHash` uses `Get-FileHash -Algorithm SHA256` and returns lowercase hex. `Test-TeamsPinRecord` checks the keys and formats above.

Download each source URL once, following redirects, into `releases/cache/`, with `curl` flags inline. Hash with `sha256sum` and size with `wc -c`. If either download fails, stop with status BLOCKED and do not invent a hash. Write `releases/teams.json` from those two results. Do not commit `releases/cache/`.

- [ ] **Step 4: Run the test and the suite**

Run: `pwsh -NoProfile -File tests/teams-pin.Tests.ps1`
Expected: exit 0.
Run: `pwsh -NoProfile -File tests/run-all.ps1`
Expected: exit 0.

- [ ] **Step 5: Commit**

`Add the Teams installer pin`

### Task 2: Publish the two blobs

**Files:**
- Create: `scripts/publish-teams.ps1`
- Create: `tests/teams-publish.Tests.ps1`

**Interfaces:**
- Consumes: `releases/teams.json` from Task 1
- Produces: `Get-TeamsBlobName -Kind bootstrapper|msix -Sha256 <hex>` returns `teamsbootstrapper-<hex>.exe` or `MSTeams-x64-<hex>.msix`. With `-Publish` omitted, the script prints both blob URLs and returns before `az`. `$script:InvokeAz` receives a string array.

- [ ] **Step 1: Write the failing test**

The test dot-sources the script under `RELIAN_DEPLOY_TEST=1` with a temp json and temp files whose hashes match that json. It sets `$script:InvokeAz` to record its argument array and throw if called. A run without `-Publish` prints both URLs under `https://relianpub.blob.core.windows.net/pub/sec/` and does not call `InvokeAz`. A second run with `-Publish` and a fake `InvokeAz` that reports the blob missing then present asserts the upload arguments include `--auth-mode`, `login`, the account `relianpub`, the container `pub`, and the blob name, as separate array elements. A hash mismatch throws before `InvokeAz`.

- [ ] **Step 2: Run the test and confirm it fails**

Run: `pwsh -NoProfile -File tests/teams-publish.Tests.ps1`
Expected: FAIL because the script does not exist.

- [ ] **Step 3: Implement `scripts/publish-teams.ps1`**

Match the argument-array shape in `scripts/publish-relian-packs.ps1`. Default is dry-run. `-Publish` checks hash and size against `releases/teams.json`, skips a blob that already exists, and uploads from `releases/cache/`. Do not run `-Publish` in this task.

- [ ] **Step 4: Run the test and the suite**

Run: `pwsh -NoProfile -File tests/teams-publish.Tests.ps1` then `pwsh -NoProfile -File tests/run-all.ps1`
Expected: both exit 0.

- [ ] **Step 5: Commit**

`Add the Teams blob publisher`

### Task 3: Decide the action before anything runs

**Files:**
- Create: `packages/teams/Invoke-Teams.ps1`
- Create: `tests/teams-plan.Tests.ps1`

**Interfaces:**
- Consumes: nothing from Tasks 1 and 2 at runtime. The test builds the inputs itself.
- Produces: `Get-TeamsPlan` with parameters `Action`, `PinVersion`, `InstalledVersion`, `MarkerVersion`, `ClassicPresent`. `InstalledVersion` and `MarkerVersion` are strings. An absent install or marker is an empty string. `ClassicPresent` is a bool. The function returns one object with these properties: `ExitCode` (int, or `$null` when work remains), `RunBootstrapper` (`install`, `uninstall`, or empty), `RemoveClassic` (bool), `Reregister` (bool), `WriteMarker` (version string or empty), `Log` (`Install`, `Repair`, `Uninstall`, or empty).

`Get-TeamsPlan` does not touch disk, the registry, or the network.

Decision table, and the test asserts every row:

| Action | Pin | Installed | Marker | Classic | Result |
|---|---|---|---|---|---|
| Install | empty | any | any | any | ExitCode 0, no work |
| Install | `nope` | empty | empty | false | ExitCode 1, no work |
| Reinstall | `1.0.0.0` | `1.0.0.0` | `1.0.0.0` | false | ExitCode 1, no work |
| Install | `2.0.0.0` | empty | empty | true | RunBootstrapper `install`, RemoveClassic false, WriteMarker empty |
| Install | `2.0.0.0` | `2.0.0.0` | empty | false | no bootstrapper, WriteMarker `2.0.0.0`, Log empty |
| Install | `2.0.0.0` | `3.0.0.0` | `2.0.0.0` | false | no bootstrapper, WriteMarker `3.0.0.0`, Log empty |
| Install | `2.0.0.0` | `1.0.0.0` | `1.0.0.0` | false | RunBootstrapper `install`, WriteMarker empty |
| Install | `2.0.0.0` | `2.0.0.0` | empty | true | no bootstrapper, RemoveClassic true, WriteMarker `2.0.0.0`, Log empty |
| Install | `2.0.0.0` | `2.0.0.0` | `2.0.0.0` | true | no bootstrapper, RemoveClassic true, WriteMarker empty |
| Install | `2.0.0.0` | `3.0.0.0` | `2.0.0.0` | true | no bootstrapper, RemoveClassic true, WriteMarker `3.0.0.0`, Log empty |
| Repair | `2.0.0.0` | empty | `2.0.0.0` | false | ExitCode 1, no work |
| Repair | `2.0.0.0` | `2.0.0.0` | `2.0.0.0` | true | Reregister true, RemoveClassic true, WriteMarker empty, Log `Repair` |
| Repair | `2.0.0.0` | `2.0.0.0` | `2.0.0.0` | false | Reregister true, Log `Repair`, WriteMarker empty |
| Repair | `2.0.0.0` | `3.0.0.0` | `2.0.0.0` | false | Reregister true, WriteMarker `3.0.0.0`, Log `Repair`, RunBootstrapper empty |
| Repair | `2.0.0.0` | `1.0.0.0` | `1.0.0.0` | false | Reregister true, no bootstrapper, WriteMarker empty, Log `Repair` |
| Uninstall | `2.0.0.0` | `2.0.0.0` | `2.0.0.0` | true | RunBootstrapper `uninstall`, RemoveClassic true, Log `Uninstall` |
| Uninstall | `2.0.0.0` | empty | `2.0.0.0` | false | no bootstrapper, Log `Uninstall` |
| Uninstall | `2.0.0.0` | empty | empty | false | ExitCode 0, no work |
| Update | `2.0.0.0` | `1.0.0.0` | `1.0.0.0` | false | same object as Install for that row |

`Update` uses the Install column for every other Install row. The test loops those rows with Action `Update` and asserts the same properties. In a result, "no work" means `RunBootstrapper` empty, `RemoveClassic` false, `Reregister` false, `WriteMarker` empty, and `Log` empty. A property the row does not mention is empty or false.

- [ ] **Step 1: Write the failing test** for the table above.
- [ ] **Step 2: Run it.** Expected: FAIL because `Invoke-Teams.ps1` does not exist.
- [ ] **Step 3: Implement `Get-TeamsPlan` only.** The file may define the function and return immediately under `RELIAN_DEPLOY_TEST=1`. No toolkit call yet.
- [ ] **Step 4: Run `pwsh -NoProfile -File tests/teams-plan.Tests.ps1` and `tests/run-all.ps1`.** Expected: both exit 0.
- [ ] **Step 5: Commit** `Decide the Teams action from the installed version`

### Task 4: Download the two payloads

**Files:**
- Modify: `packages/teams/Invoke-Teams.ps1`
- Create: `tests/teams-download.Tests.ps1`

**Interfaces:**
- Consumes: `Get-TeamsPlan` from Task 3. Blob names from Task 2.
- Produces: `Save-TeamsPayload -Url -Destination -Sha256 -Label -CancelPath`. Returns 0, 1, or 130. `$script:DownloadFile` and `$script:RetryDelay` are replaceable. Empty `Sha256` returns 0 and does not call `DownloadFile`.

- [ ] **Step 1: Write the failing test**

Cover: matching hash returns 0; mismatch returns 1 and does not leave the destination; userinfo URL returns 1 with zero download calls; HTTP 404 returns 1 after one attempt; HTTP 503 then success returns 0 and sleeps once via `$script:RetryDelay`; three HTTP 503 results return 1; `RELIAN_DEPLOY_CANCEL=1` before the second attempt returns 130. Assert the error text does not contain `https://`.

- [ ] **Step 2: Run it.** Expected: FAIL because `Save-TeamsPayload` does not exist.
- [ ] **Step 3: Implement `Save-TeamsPayload`** with the retry rules in Global Constraints. Copy the status list from `runner/Invoke-RelianRunner.ps1`. Do not dot-source the runner.
- [ ] **Step 4: Run `tests/teams-download.Tests.ps1` and `tests/run-all.ps1`.** Expected: both exit 0.
- [ ] **Step 5: Commit** `Download the Teams payloads with retries`

### Task 5: Build the bootstrapper command and the classic-removal list

**Files:**
- Modify: `packages/teams/Invoke-Teams.ps1`
- Create: `tests/teams-command.Tests.ps1`

**Interfaces:**
- Consumes: `Get-TeamsPlan`
- Produces: `Get-TeamsBootstrapperArgumentList -Mode install|uninstall -MsixPath <full path>` returns a string array. Install returns `-p`, `-o`, the full MSIX path, `--installTMA`. Uninstall returns `-x` only. `Get-TeamsClassicProductCodes` returns the two product codes in Global Constraints. `Get-TeamsClassicUserUninstall` returns the argument string `-uninstall -s`.

- [ ] **Step 1: Write the failing test** for those three functions, including that install does not contain `-x` and uninstall does not contain `-p` or `--installTMA`.
- [ ] **Step 2: Run it.** Expected: FAIL.
- [ ] **Step 3: Implement the three functions.** Reject a relative MSIX path by returning `$null` from `Get-TeamsBootstrapperArgumentList` when `-o` is required and the path is not rooted.
- [ ] **Step 4: Run `tests/teams-command.Tests.ps1` and `tests/run-all.ps1`.** Expected: both exit 0.
- [ ] **Step 5: Commit** `Pin the Teams bootstrapper arguments`

### Task 6: Open the toolkit session and apply the plan

**Files:**
- Modify: `packages/teams/Invoke-Teams.ps1`
- Create: `tests/teams-session.Tests.ps1`

**Interfaces:**
- Consumes: `Get-TeamsPlan`, `Save-TeamsPayload`, `Get-TeamsBootstrapperArgumentList`, `releases/teams.json` defaults copied into the script parameters `BootstrapperUrl`, `BootstrapperSha256`, `MsixUrl`, `MsixSha256`.
- Produces: `Test-TeamsDeferralBlock -SessionStates <string[]> -CloseProcessRunning <bool> -DeferralAlreadyUsed <bool>` returns `$true` only for the disconnected-and-running-and-unused case. `Get-TeamsCloseList -RunningNames <string[]>` returns the subset of `ms-teams`, `Teams`, `OUTLOOK` that is running. `Get-TeamsNotice -Action` returns the sentence from Global Constraints (`Update` uses the install sentence).

The script's executed path, which tests assert by reading the source:

1. Missing required bound names `DeploymentType`, `Action`, `PinVersion` exit 1. Names are not `Mandatory`.
2. `RELIAN_DEPLOY_TEST=1` and a dot-source return before `Import-Module`.
3. `AppProcessesToClose` is the running subset. `Remove-ADTHashtableNullOrEmptyValues -Hashtable $adtSession` runs after import and before `Open-ADTSession @adtSession`.
4. `Test-TeamsDeferralBlock` runs before `Open-ADTSession`. A `$true` result exits 1.
5. Welcome runs only when `Get-TeamsCloseList` is non-empty, with `-AllowDefer -DeferTimes 1`, and the notice from `Get-TeamsNotice`.
6. After a successful session, the code calls `Get-TeamsPlan`. When `RunBootstrapper` is `install` and that hook returns 0, it calls `Get-TeamsPlan` again with the installed version refreshed, then runs `Reregister` and `RemoveClassic` from that second object. Hook order is `SetOptimizationKey`, then `StartBootstrapper` or `ReregisterTeams`, then `RemoveClassicTeams`. The first non-zero hook exits 1 and skips the rest. The marker and the log are written only after the last hook returns 0. `$script:StartBootstrapper`, `$script:ReregisterTeams`, `$script:RemoveClassicTeams`, and `$script:SetOptimizationKey` are the hooks. The optimization hook is the only registry write, and the source sets `IsWVDEnvironment` to `1`. The source does not contain `disableAutoUpdate`, `MsRdcWebRTCSvc`, or `Reset-AppxPackage`.
7. Toolkit exit 1602 becomes package exit 1 with the marker unchanged.

- [ ] **Step 1: Write the failing test** for `Test-TeamsDeferralBlock`, `Get-TeamsCloseList`, `Get-TeamsNotice`, the default URL and hash parameters matching `releases/teams.json`, and the source assertions above.
- [ ] **Step 2: Run it.** Expected: FAIL.
- [ ] **Step 3: Implement the session path and the four hooks.** On success, write `marker.txt` from `WriteMarker` when that property is non-empty, append `Log` when that property is non-empty, and delete `marker.txt` when `Log` is `Uninstall`. A hook returning non-zero exits 1 and does not write the marker.
- [ ] **Step 4: Run `tests/teams-session.Tests.ps1` and `tests/run-all.ps1`.** Expected: both exit 0.
- [ ] **Step 5: Commit** `Add the Teams package session`

## Controller after Task 6

Uploading the blobs, pushing `teams-package`, and any run on a client device are controller steps. They are not implementer tasks. Pull request 2 stays open.
