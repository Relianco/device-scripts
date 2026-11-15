# Windows maintenance

The storage and Windows Update packages run as SYSTEM through `windows/runner/Invoke-RelianRunner.ps1`. Each package is a single hash-pinned script. They use the staged PSAppDeployToolkit 4.1.8 and Relian branding to display the current phase to a signed-in user. A missing user session or failed notification is recorded separately from diagnostic results.

Start with a report. Both packages default to reporting, even when the runner action is Repair. Explicit package arguments enable cleanup or repairs. An active USB upgrade, staged upgrade, pending servicing restart or uncertain safety check defers mutations. Neither package starts an upgrade or reboots. Reports distinguish a completed command from a verified repair.

## Reading storage results

The compact stdout JSON includes measured before/after volume free bytes, a few top file/folder consumers, age-qualified temp opportunities and profile decision counts. Item/string limits and any byte-cap fallback are explicitly marked as truncated; the local JSON retains full evidence. During Setup, stdout still includes the permitted volume snapshot while scans are withheld.

Logical file size is not guaranteed recoverable space. Sparse files, compression, hard links and online-only files can make it differ substantially from allocated space. Do not add parent directory totals to their children or add overlapping cache categories. Before/after free-space measurements include concurrent Windows activity.

Temp cleanup retains recent files. Profile removal is separate and disabled by default; its default inactivity threshold is 60 days, configurable with ProfileAgeDays, with fresh eligibility checks. Directory modification dates from a WizTree export do not establish profile inactivity. Keep exclusions for accounts whose local data must remain. Mail stores, unsynced documents and application state require review before an entire profile is removed.

Browser/WebView/Teams caches can dwarf general temporary files. The report identifies these opportunities, but app cache resets require application-specific handling. Outlook OST/PST, Office offline files, security logs, Windows Search databases, installer repair caches and OEM recovery payloads are not generic disposable temp files. Windows.old, setup staging, rollback and recovery files remain protected.

A bounded scan marks incomplete coverage. During active Setup, only a light snapshot is collected. A broader scan should run after the upgrade finishes and the device has restarted successfully. Existing WizTree exports can supplement the bounded report without competing with Setup on the device.

## Reading update results

Recent update events run in a read-only worker with a 15-second observation deadline and servicing guard checks between waits. Timeout, unavailable history and a Setup transition are reported as omitted evidence; a transition defers further work.

A successful search returning zero applicable updates does not establish that Windows is current or that a feature upgrade should be offered. Distinguish search errors, paused or targeted releases, update-source management, compatibility safeguards, servicing/reboot state, and an unsupported installed Windows release. Recent Defender or application updates do not establish current OS cumulative servicing, but they also do not support a claim that every Ninja update mechanism is broken.

Windows 11 Home/Pro 22H2 and 23H2 are past their support periods. An in-place upgrade to a supported release can be necessary even when the old release reports no available updates. Lifecycle facts depend on edition; do not apply Home/Pro dates to Enterprise/Education or assume every unfamiliar release is supported.

`AUOptions=2` means notify before downloading. A stopped demand-start service is not automatically faulty. WSUS, MDM/GPO sources, feature targeting and safeguard holds are diagnostic evidence, not permission to erase policy. Repairs preserve those controls and identify management changes that need an administrator's review.

Optional cache reset keeps uniquely named backups and may reset displayed update history. Image repair uses DISM followed by SFC and can take substantial time. A command that exceeds the observation deadline is reported as still running or incomplete; it is not killed or treated as successful. Do not start another servicing operation until that state is resolved.

## Sources

- [Windows 11 Home and Pro lifecycle](https://learn.microsoft.com/en-us/lifecycle/products/windows-11-home-and-pro)
- [Windows Update policy settings](https://learn.microsoft.com/en-us/windows/deployment/update/waas-wu-settings)
- [Windows Update and WSUS scan sources](https://learn.microsoft.com/en-us/windows/deployment/update/wufb-wsus)
- [Safeguard holds](https://learn.microsoft.com/en-us/windows/deployment/update/safeguard-holds)
- [Repair a Windows image](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/repair-a-windows-image)

## Profile age evidence

Windows servicing can change filesystem timestamps without a person signing in. `Win32_UserProfile.LastUseTime` alone is not an interactive-login audit. Modern Windows tracks profile-service load/unload and cleanup-check timestamps in each SID's ProfileList registry key. The report must show timestamp provenance and uncertainty, rather than treating a recently touched profile directory as a recent user login or treating missing evidence as old enough to delete. See [Microsoft's profile-age guidance](https://learn.microsoft.com/en-us/troubleshoot/windows-server/support-tools/scripts-to-retrieve-profile-age). A coherent old load/unload pair supplies the age; recent NTUSER changes alone remain diagnostic. Recent CIM conflicts, invalid registry evidence, uncertain sessions or a failed evidence probe require review. Recent exact-SID interactive logon evidence protects a profile; absent or rotated event history does not prove inactivity.

## Build a pinned runner invocation

From a published checkout, select one package and encode its arguments. This example creates the Parameters string for the existing Ninja runner; it does not execute anything. All values are non-secret. The commit must be available on GitHub before a device can download it.

```powershell
$commit = (git rev-parse HEAD).Trim()
$package = 'windows/packages/storage-maintenance/Invoke-StorageMaintenance.ps1'
$options = @{ Mode = 'Report'; ProfileAgeDays = '60' }
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($options | ConvertTo-Json -Compress)))
$packageHash = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant()
$toolkitHash = '80b45fb8e518ee98774e16e44599d470e4069a0695a6a359022f954edaa83360'
$brandHash = 'ccc1d462983bfcdd05fd6cbb201e78c1ce50ad9f5a6e0aedb5009d2f22fe0984'
$arguments = @(
    '-PackageUrl "https://raw.githubusercontent.com/Relianco/device-scripts/{0}/{1}"' -f $commit, $package
    '-PackageSha256 "{0}"' -f $packageHash
    '-ToolkitUrl "https://relianpub.blob.core.windows.net/pub/sec/PSAppDeployToolkit-4.1.8-{0}.zip"' -f $toolkitHash
    '-ToolkitSha256 "{0}"' -f $toolkitHash
    '-BrandPackUrl "https://relianpub.blob.core.windows.net/pub/sec/relian-brand-{0}.zip"' -f $brandHash
    '-BrandPackSha256 "{0}"' -f $brandHash
    '-Action "Repair"'
    '-PinVersion "1.0.0"'
    '-PackageArguments "{0}"' -f $encoded
)
$arguments -join ' '
```

For storage cleanup, use `Mode='Cleanup'`. Profile removal additionally requires `RemoveProfiles='true'` and every gate in [Profile removal](#profile-removal-off-by-default); optional `ExcludeProfiles` is a comma-separated exact SID/full-profile-path list. Keep profile removal off until two report runs have been reviewed. Optional `ComponentCleanup='true'` asks Windows to perform supported component cleanup after safety checks. It never uses ResetBase. To free disk space, add `Tier='Safe'`; see [Free disk space: cleanup tiers](#free-disk-space-cleanup-tiers).

### Profile report (report only)

`ProfileReport='true'` adds a per-profile census and prints a compact schema-v2 JSON (under 9.5 KB) for a device custom field instead of the v1 summary. When it would not fit, the lowest-ranked entries lose their detail first (keeping SID, decision, age and size), then whole entries drop; the summary still counts every profile. It requires `Mode='Report'` with `RemoveProfiles` and `ComponentCleanup` false; the package refuses any other combination, and a report run never enters the cleanup branch. Pass `ProfileAgeDays='90'` for the shared-device threshold.

#### Write the report to a NinjaOne custom field

The package only prints, and neither the package nor the runner calls NinjaOne. To store the JSON in a device custom field, schedule one script, `windows/collectors/runner-report-field.ps1`, in place of `Invoke-RelianRunner.ps1`:

1. Create a device custom field of type **Multi-line text** (a plain text field is too short for 9.5 KB), for example `relianProfileReport`. Permissions: Automation **Read/Write**, API **Read-only**. The name must match `^[A-Za-z][A-Za-z0-9]{0,39}$`.
2. Paste `windows/collectors/runner-report-field.ps1` into the NinjaOne script library and run it as **System**.
3. Parameters: `-RunnerUrl` (raw URL of `windows/runner/Invoke-RelianRunner.ps1` at a pinned commit), `-RunnerSha256` (64 lowercase hex characters), `-ReportCustomField "relianProfileReport"`, then every runner parameter exactly as for the runner. Use `-PackageArguments` for `{"ProfileReport":"true","Mode":"Report"}`. An empty `-RunnerSha256` exits 0 and downloads nothing, like the runner. An empty `-PackageSha256`, `-ToolkitSha256` or `-BrandPackSha256` also exits 0, because Windows PowerShell 5.1 would drop the empty value before the runner saw it.
4. Use it for report runs only: it refuses `-Action Uninstall` and any forwarded URL with a user name, before downloading anything. Run an uninstall through the runner.
5. The script downloads the runner, checks its hash, runs it as a child with `-ReportOutputPath` set, and returns the runner's exit code and output unchanged.

How it stays safe:

- The runner saves the report only after exit 0, only when the package arguments are exactly `ProfileReport` `true` with `Mode` `Report` (or no `Mode`) and no `RemoveProfiles` or `ComponentCleanup`, and not for `Uninstall`. For any other run it parses and saves nothing.
- Marker contract: the package output must hold exactly one line that starts with `{"schemaVersion":2,"package":"storage-maintenance",`. It is saved unchanged, never re-serialised or cut.
- The script reads the saved file only if it was written after the run started, is not a link, is one line of at most 9,500 UTF-8 bytes with that marker and mode `Report`. It then writes the field and deletes the file. The folder is readable by SYSTEM and Administrators only and is removed after every run.
- A missing `Ninja-Property-Set` cmdlet or a failed write prints one line naming only the field. The exit code and output are unchanged.

- `SharedDevices`: comma-separated computer names that are shared or loaner PCs. A device not on the list reports a stale profile as `KeepNotSharedDevice`; personal devices never delete profiles.
- `PrimaryUserHint`: optional account name or UPN of the RMM's last-logged-on user.

Per profile it reports local bytes (total, OST, PST, OneDrive hydrated and online-only, Teams and browser caches, Temp, Downloads, the SID's Recycle Bin, files left in the profile's own Desktop, Documents and Pictures), the last 4624 logon in the window, the ProfileList unload age, primary-user, admin and service flags, and the decision a delete run would take. Sizes come from directory metadata: no file is opened or recalled, junctions and symlinks are never entered, and cloud directories that would populate on open are never entered; one of those, or any unexpected link, marks the size partial. Windows' own hidden+system compatibility junctions (`My Documents`, `Documents\My Music` and the like) do not. The walk has its own `MaxFiles`/`MaxSeconds` budget, so allow about twice `MaxSeconds` plus evidence time in the RMM timeout.

The age engine's `StaleCandidate` only narrows from there. A primary user (Intune enrollment UPN, the top interactive 4624 SID, or the hint) is `KeepPrimaryUser`. Local Administrators members and names matching `opadmin*`, `admin*`, `svc*`, `*$` or the LAPS account are `Protected`. On a shared device, unknown admin membership, no primary-user source, Security log coverage shorter than `ProfileAgeDays` (or a newest event in the future or older than 2 days), and a PST that is present or not ruled out each give a `Review*` decision. Then come the OneDrive gates, each with its own code:

- `ReviewKfmUnknown`: the profile's `NTUSER.DAT` could not be read (locked, missing, behind a link, over 64 MB, malformed) or is dirty (it needs its transaction logs). The hive is parsed from bytes for age-stale profiles only; it is never loaded or mounted.
- `ReviewKfmNotRedirected`: Desktop, Documents or Pictures (`User Shell Folders`, the legacy name and, where present, the known-folder GUID value) does not resolve strictly inside a OneDrive account's `UserFolder` (`Software\Microsoft\OneDrive\Accounts\Business*` or `Personal`).
- `ReviewKfmSyncRootNotWalked`: the folders are in a sync root that is not a top-level `OneDrive*` folder of the profile, so the listing did not cover it.
- `ReviewKfmUploadUnproven`: a `OneDrive*` folder still holds local files (`desktop.ini`, `~$` owner files and the sync-root marker are ignored). A listing cannot prove a local file is uploaded, since a placeholder keeps its tag while an edit waits for sync. Only online-only content counts as in the cloud, so a candidate needs its OneDrive files dehydrated (Storage Sense dehydration does this for old profiles).
- `ReviewOutsideKfm`: files remain in the profile's own Desktop, Documents or Pictures.
- `ReviewUserFoldersNotEmpty`: a file (other than `desktop.ini`) is in the profile's own Downloads, Videos or Music folder. This is an owner gate held in one switch, `$script:SmMediaFolderGate` in the package; setting it to `$false` drops this gate and nothing else.

A profile that passes every gate is `StaleCandidate`. In a `ProfileReport` run that is only a report line: a report run never enters the cleanup branch. Each report run also writes its decisions to the audit log and prints the hash of its sealing line as `audit.reportHash`; that hash is what the owner approves (see below).

### Profile removal (off by default)

Removal happens only in `Mode='Cleanup'` with `RemoveProfiles='true'`, which nothing in this repository sets. A profile is removed only when all of these hold:

1. The device's computer name is in `SharedDevices`. The list is a parameter, never a constant in the package.
2. The gate matrix above, evaluated from fresh evidence in the same run, gives `StaleCandidate`.
3. The same SID at the same profile path was a `StaleCandidate` in both report runs named by `ReviewedReports`. Those two runs must be on this device's audit chain, at least 7 days apart and not dated after the device clock. A profile that was a candidate in only one of them is not approved.
4. The audit chain verifies, and no earlier removal intent is left without an outcome.
5. The cooldown allows: no removal run in the last `RemovalCooldownDays` (default 1), and the cooldown marker agrees with the chain.
6. Fewer than 5 removals have been attempted in this run. The cap is fixed in the package (`$script:SmProfileRemovalCap`).

Immediately before each removal the run reads the profile again: the same SID and path in `Win32_UserProfile`, unloaded, no session and no loaded hive, the same ProfileList load/unload pair, the gate matrix again from fresh evidence, and the same newest 4624 logon for the SID. A change skips that profile and is recorded as `vetoed`. A removal that fails, or an audit write that fails, stops every further removal in the run. A profile path with a link or junction in it, or a profile whose size walk met an unexpected link, never becomes a candidate; no link is followed.

The run's `ProfileRemoval` summary gives the plan code (`Ready`, or the first gate that refused: `NotSharedDevice`, `ReviewedReportsMissing`, `ReviewedReportNotInChain`, `ReviewedReportsTooClose`, `ClockSkew`, `UnresolvedIntent`, `CooldownActive`, `CooldownMarkerMissing`, `CooldownMarkerMalformed`, `CooldownMarkerMismatch`, an `Audit*` code, or `NoApprovedCandidate`), the number of candidates, attempts and removals.

**What the owner sets to enable removal** (on the shared-device policy only, never fleet-wide):

- `Mode='Cleanup'`, `RemoveProfiles='true'`, `ProfileAgeDays='90'`.
- `SharedDevices`: the shared PCs' computer names, comma-separated.
- `ReviewedReports`: the two `audit.reportHash` values, comma-separated, from two `ProfileReport` runs on that device that were reviewed and are at least 7 days apart. Only profiles listed as `StaleCandidate` in both are approved, so a new stale profile needs two new reviewed reports.
- Optional `RemovalCooldownDays` (1 to 365).
- Each removal walks the profile again inside the run's `MaxSeconds`; when that budget runs out, the remaining candidates wait for a later run. Size `MaxSeconds` and the RMM timeout for up to five walks.

Clearing `ReviewedReports` or setting `RemoveProfiles='false'` stops removal.

### Profile audit log

`ProgramData\RelianMaintenance\Profiles\audit.jsonl` (SYSTEM and Administrators only) gets one JSON line per decision in a report or removal run, a `report` line sealing each report run, and `removalRun`, `intent`, `removed`, `failed`, `vetoed` and `reconciled` lines for removals. A line holds the time, run id, SID, a 16-hex hash of the lower-cased profile path, decision and reason codes, a byte count and the previous line's hash; never a name, account, UPN or path. Its `hash` is SHA-256 over a fixed-order canonical form of those fields, so the chain does not depend on the JSON serializer.

`audit.head` holds the last line's sequence number and hash, and `audit.lock` is held, unshared, while a run verifies and appends. The verifier refuses an edited, deleted, inserted, duplicated or reordered line, a torn last line, a missing or changed head, a cut tail and an extra field. A head exactly one line behind is accepted: that is a crash between appending a line and updating the head. At 1 MB the file is renamed `audit-<first seq>.jsonl` and the chain continues in a new `audit.jsonl`; archives are never pruned, because a missing archive breaks the chain. After 100 files the package refuses to write; move the directory aside by hand.

An `intent` line is written before each removal and `removed` or `failed` after it. If a run stops between the two, the next removal run records `reconciled` (`StillPresent` or `Absent`) for that SID and removes nothing in that run. `cooldown.json` is replaced atomically (temp file, then rename). A missing, malformed or disagreeing marker allows no removal in that run and is rewritten from the chain; report runs also seed a missing marker.

The chain makes tampering visible; it does not prevent it. An administrator can rewrite the whole directory, chain and head together. The copy that leaves the device (the run's printed `audit` block, and the planned `relianProfileAudit` custom field) is the anchor. To start over after a broken chain, move the `Profiles` directory aside after reviewing it; the new chain then needs two new reviewed reports before any removal.

The normal scan budget is 20,000 entries and 30 seconds. `MaxFiles` and `MaxSeconds` allow a longer explicitly requested scan; partial coverage remains visible. Long scans belong after the upgrade, and the RMM job timeout must allow the requested budget plus diagnostics and cleanup.

For updates, select `windows/packages/update-maintenance/Invoke-UpdateMaintenance.ps1`. Start with `Mode='Report'`; use explicit `Mode='Repair'` for guarded service recovery and scan verification. `ResetCache='true'` enables cache backup/reset and `RepairImage='true'` enables DISM/SFC. `Scan='true'` requests an online search from Report mode only when guards pass. Timeouts are configurable via `ScanTimeoutSeconds` and `NativeTimeoutSeconds` (10–3600 seconds). Do not use cache reset or image repair as an automatic response to an empty update list.

Native servicing logs use OS file handles owned by the child, with inheritance restricted to its log and NUL input handles. They remain writable after the launching PowerShell exits. Native markers retain the exact PID, creation time and executable; a timeout never authorizes starting another servicing operation.

Maintenance owns `ProgramData\RelianMaintenance` directly: storage reports/logs are under `Storage`, update run directories under `Update`, and the shared native marker is `native-active.json` at that root. A pre-existing untrusted owned root is refused. Initialization does not inspect or change the unrelated `ProgramData\Relian` ACL. Legacy `Relian\Maintenance\native-active.json` remains read-only fail-closed guard evidence, and the existing `Relian\FeatureUpgrade\state.json` is still read for upgrade safety. Do not delete an old marker to bypass a deferred result; reconcile its exact process identity first. The default pilot remains Report with a 60-day profile threshold and profile removal disabled.


A retained marker requires administrator reconciliation; packages do not clear one automatically. A missing PID is insufficient evidence that servicing and descendants finished. For a deferred `native-active marker present` result:

1. Read the marker without changing it. Retain its PID, UTC creation time, executable, phase, start time and log paths with the maintenance report. Compare all three identity fields with the running process; a reused PID is a different process. If identity cannot be queried, keep the marker and defer.
2. If the recorded process is still running, wait for completion. Inspect its stdout/stderr and Windows servicing logs; do not kill servicing to unblock maintenance. Confirm that Setup and servicing workers have finished. If that cannot be established, keep the marker. An administrator may instead arrange a separately authorized restart, then verify that the current boot is later than the marker and review servicing/reboot state again.
3. In an exclusive maintenance window with no concurrent runner, retain the completed marker as evidence outside either active marker filename, within the trusted maintenance evidence directory. Archive only after completion is established and no active or unknown servicing remains. Apply the same review to a legacy marker; do not change unrelated directory ACLs to clear it. Record who reconciled it and the completion evidence.
4. Run Report again. Active Setup, staged upgrade, pending reboot or unknown state must still defer work. Review that fresh report before explicitly requesting Repair or Cleanup.

This is a deliberate recovery boundary: a timed-out operation is not proof of completion or success. Automatic PID-only cleanup would discard evidence while servicing may still be active.

## Free disk space: cleanup tiers

Use this when a PC runs low on disk space. It frees space from caches, old temporary files and Windows leftovers. It never deletes user files or user profiles.

### When it runs

- **Automatic:** the NinjaOne low-space condition on the workstation policy (C: free at or below 10 %) runs the Safe tier. See [Low-space trigger](#low-space-trigger).
- **By hand:** a technician runs it from NinjaOne. See [Run it by hand](#run-it-by-hand).

### What each tier deletes

A tier needs `Mode='Cleanup'`. `Tier='None'` (the default) adds nothing to the existing temp cleanup.

Each file category deletes only files older than `TempAgeDays` (default 7 days). A file counts as old only when both its write time and its creation time are old. Two steps have no age filter: the Delivery Optimization cache (Windows downloads it again on demand) and Disk Cleanup in the Aggressive tier, which applies its own rules per handler.

**Safe** (`Tier='Safe'`):

- **Temp:** `Windows\Temp` and each profile's `AppData\Local\Temp`.
- **AppCache:** cache folders of Edge, Chrome and Teams (new and classic). Only folders named `Cache`, `Code Cache`, `GPUCache`, `CacheStorage`, `ShaderCache`, `GrShaderCache` and the `Dawn*Cache` folders. Cookies, logins, history, IndexedDB and Local Storage are not caches and stay.
- **WindowsUpdateDownload:** `Windows\SoftwareDistribution\Download`.
- **DeliveryOptimization:** Windows' own `Delete-DeliveryOptimizationCache`.
- **CrashDumps:** minidumps, `MEMORY.DMP`, live kernel reports, Windows Error Reporting queues and each profile's `AppData\Local\CrashDumps`.
- **ServicingLogs:** rotated logs in `Windows\Logs\CBS` and `Windows\Logs\DISM`. The live `CBS.log` and `dism.log` stay.
- **RecycleBin:** items deleted more than `TempAgeDays` ago. The age is the deletion date, not the file's own date.
- **FeatureUpgradeIso:** the ISO that the `feature-upgrade` package leaves after a failed, rolled-back or already-current attempt older than `TempAgeDays`. A running or staged attempt keeps its ISO. A finished attempt removes its own ISO.
- **Component cleanup:** `DISM /StartComponentCleanup`, the same step as `ComponentCleanup='true'`. Never `/ResetBase`.

**Aggressive** (`Tier='Aggressive'`) does everything in Safe, then:

- **Cleanmgr:** Disk Cleanup with a fixed handler list (sageset 77). The list never includes Downloads, the Recycle Bin or File History. Each run rewrites the list, so a handler added by hand is removed again.
- **Windows.old:** included in Cleanmgr only when both `Windows.old` and the upgrade are older than the rollback window. The window is the device's `UninstallWindow` setting, at least 10 days. An unknown date or window keeps `Windows.old`. Removing it removes the option to go back to the previous Windows version.
- **ShadowStorage:** shrinks the restore-point space on C: to 5 % when its limit is higher. Windows deletes the oldest restore points to fit.

### What it never touches

- User profiles. Profile removal stays a separate opt-in. See [Profile removal](#profile-removal-off-by-default).
- Documents, Desktop, Downloads, Pictures, OneDrive folders, Outlook data (OST and PST).
- `hiberfil.sys`, `pagefile.sys` and `swapfile.sys`.
- Upgrade files while an upgrade is running or staged: `$WINDOWS.~BT`, `$WINDOWS.~WS`, `C:\ESD`, the feature-upgrade ISO.
- Any folder reached through a junction or symbolic link, and any OneDrive online-only file.

### Safety checks

- The whole tier is withheld when the servicing checks are not clear. That covers a running Setup, DISM or TrustedInstaller, a staged upgrade, a pending restart or pending file renames.
- The checks run again before each category. A category that starts while Setup appears is withheld.
- The path and each parent folder are checked for junctions right before each delete.
- `CleanupSeconds` (60 to 3600, default 600) bounds the tier. Component cleanup waits up to five more minutes.
- A second run straight after the first deletes nothing new.

### Reading the result

The stdout JSON has a `Categories` list. Each entry has:

- **Name:** the category.
- **Status:** `done`, `partial` or `withheld`. `partial` means some files could not be deleted (often because they are in use), the time budget ran out, or a root was refused. The reason is in **Error**.
- **Files:** files deleted.
- **FreedBytes:** C: free space after the category minus before it. Other activity on the PC can change it.

The full report, with logical bytes per category, stays under `ProgramData\RelianMaintenance\Storage`.

### Run it by hand

Build the Parameters string as in [Build a pinned runner invocation](#build-a-pinned-runner-invocation), with these options:

```powershell
$options = @{
    Mode = 'Cleanup'
    Tier = 'Safe'
    TempAgeDays = '7'
    CleanupSeconds = '600'
}
```

Then, in NinjaOne:

1. Open the device.
2. Choose **Run** and pick the script **Invoke-RelianRunner**.
3. Run as **System**. Paste the Parameters string.
4. Read the result in the device's **Activities**.

Use `Tier='Aggressive'` only for a single PC, after you read a Safe result.

### Low-space trigger

NinjaOne's API cannot edit a policy's conditions, so make these changes in the NinjaOne web console:

1. Go to **Administration**, then **Policies**, and open the Windows workstation policy.
2. Open **Conditions** and edit the existing **Disk Free Space** condition for C: (at or below 10 % for 15 minutes).
3. Under **Automations**, add **Invoke-RelianRunner**, run as **System**, with the Safe-tier Parameters string.
4. Remove the automations that the Safe tier replaces: **Delete Temporary Files**, **Run Windows Cleanup**, **Empty Recycle Bin** and **Empty Downloads Older 6 Months**. Keep **Clear-MdmCache**, the two OneDrive online-only scripts and the alert.
5. Set the condition's **Reset threshold** so it fires again only after recovery, and set **Auto-reset** to 24 hours. That limits it to about one run a day.
6. Keep the condition's **Severity** and **Notification** so a technician hears about it.
7. Save.

The old Run Windows Cleanup automation started Disk Cleanup without checking for a running upgrade. Disk Cleanup can delete `$WINDOWS.~BT` while Setup uses it. The Safe tier waits instead.

### If the disk is still full

- **Upgrade in progress:** a feature upgrade needs 20 to 30 GB while it runs. Let it finish and restart, then run the Safe tier again.
- **OneDrive:** check the user's OneDrive folder size. Files the user opened are kept on the PC. Turn on Storage Sense with "make online-only after 60 days", or run the NinjaOne OneDrive online-only script for that user.
- **User data:** ask the user to move or delete large files in Downloads, Desktop or Documents. Never delete them for the user.
- **Large mailbox:** a large OST is Outlook's offline copy. Reduce the offline period in Outlook.
- **Old Windows:** after the 10-day rollback period, run the Aggressive tier once.
- **Hardware:** a 256 GB disk with less than 15 % free after cleanup needs a bigger disk or a replacement PC.

## Retrieve stored evidence

`windows/packages/maintenance-evidence/Invoke-MaintenanceEvidence.ps1` runs through the same pinned runner to read an existing report without starting maintenance. Set `Package` to `Storage` or `Update`, and `ReportId` to the exact Storage filename without `.json` or Update run-directory identifier from the original ReportPath. It accepts only those owned report locations; it does not accept arbitrary paths. The reader checks ownership, modification rights and reparse ancestors, refuses concurrent writers and caps report size at 16 MiB.

Start with `Section='Index'`, then choose `Guards`, `Snapshot`, `Policy`, `ProfileIndex`, `Profiles`, `Scan`, `ActionSummary`, `Actions`, `Errors`, `Evidence` or `Omissions`. `Profiles` uses a zero-based `Ordinal`; `Page` defaults to zero. Each bounded JSON response contains a base64 UTF-8 JSON byte page, page count, offset, section length/hash and report length/hash. Concatenate decoded bytes in page order and verify the section SHA256 and length before parsing; all pages must refer to the same report hash. Do not review deletion candidates from aggregate counts alone.

The reader performs no new scan, notification, repair or deletion. Maintenance operations retain their PSADT notifications. Missing, changed, untrusted, oversized or invalid evidence fails closed; a failed fetch does not authorize a cleanup.

## Post-upgrade evidence and restarts

`Invoke-DiagnoseFeatureUpgrade.ps1` accepts `Section='Maintenance'` for bounded read-only evidence: completed-image state, current and source OS versions/install dates, exact Setup and numeric MoSetup inputs, pending-reboot indicators, sanitized rename examples, servicing processes and native-marker presence. Unknown or failed probes remain explicit; this diagnostic does not change a guard or authorize a repair.

Historical upgrade-state classification is an inference from corroborating evidence, not a claim that a registry value alone proves success. Maintenance preserves active-process, native-marker, staging and reboot vetoes. It requires complete image state and coherent build/install/boot evidence before treating a previous upgrade's metadata as historical; unknown or malformed evidence still defers work. No marker or MoSetup metadata is deleted. A `feature-upgrade` marker that still says `staged` after the install restart counts as residue only when its target build is the running build and the same proofs pass; a staged marker for a build not yet installed still defers work.

After a maintainer authorizes a restart, the existing restart-notice package accepts optional `MaintenanceRestart='true'`. This mode recognizes pending file-rename pairs and refuses a prompt or reboot when servicing is active or unknown. It preserves the usual snooze and countdown, but the parent controls the countdown and rechecks safety immediately before shutdown. A late safety failure returns `deferred`; no automatic retry is scheduled. The default restart-notice behavior is unchanged. Do not dispatch other maintenance while a reboot job is running.

`ProfileIndex` lists stored profile-row ordinals, decisions and eligibility so full evidence can be fetched for the relevant rows. `ActionSummary` groups stored action outcomes and counts, provides known logical-byte coverage and bounded error examples, and distinguishes missing evidence. Logical bytes include withheld actions and are never a reclaimed-space claim. These summaries describe stored rows; assess the parent report guards, status and omissions before treating them as complete device coverage.

Both maintenance packages persist final evidence and emit their summary before terminal `Close-ADTSession`, which closes the toolkit client/server lifetime. The chosen success/deferred/failure exit code is retained. A returning session-close exception yields an operator error and marks durable evidence failed; do not accept an earlier summary over a later failure or failed runner outcome.
