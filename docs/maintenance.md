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

For storage cleanup, use `Mode='Cleanup'`. Profile removal additionally requires `RemoveProfiles='true'` and the chosen `ProfileAgeDays`; optional `ExcludeProfiles` is a comma-separated exact SID/full-profile-path list. Keep profile removal off until the report's candidates and evidence are reviewed. Optional `ComponentCleanup='true'` asks Windows to perform supported component cleanup after safety checks. It never uses ResetBase.

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

## Retrieve stored evidence

`windows/packages/maintenance-evidence/Invoke-MaintenanceEvidence.ps1` runs through the same pinned runner to read an existing report without starting maintenance. Set `Package` to `Storage` or `Update`, and `ReportId` to the exact Storage filename without `.json` or Update run-directory identifier from the original ReportPath. It accepts only those owned report locations; it does not accept arbitrary paths. The reader checks ownership, modification rights and reparse ancestors, refuses concurrent writers and caps report size at 16 MiB.

Start with `Section='Index'`, then choose `Guards`, `Snapshot`, `Policy`, `Profiles`, `Scan`, `Actions`, `Errors`, `Evidence` or `Omissions`. `Profiles` uses a zero-based `Ordinal`; `Page` defaults to zero. Each bounded JSON response contains a base64 UTF-8 JSON byte page, page count, offset, section length/hash and report length/hash. Concatenate decoded bytes in page order and verify the section SHA256 and length before parsing; all pages must refer to the same report hash. Do not review deletion candidates from aggregate counts alone.

The reader performs no new scan, notification, repair or deletion. Maintenance operations retain their PSADT notifications. Missing, changed, untrusted, oversized or invalid evidence fails closed; a failed fetch does not authorize a cleanup.
