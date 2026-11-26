# device-scripts

Public scripts that a managed device downloads and runs without a login. A technician pastes one small loader into NinjaOne; the loader downloads one script from this repo at a pinned commit and runs it.

The one rule: nothing runs unless its SHA256 matches the hash the caller passed. On the runners and the job loader, an empty hash is the off switch: the run exits 0 and downloads nothing.

## Which script do I paste?

Each loader does a different job. Paste the one that matches the task.

- **Install, repair or run a package (Windows):** `windows/runner/Invoke-RelianRunner.ps1`.
- **A recurring fix on a schedule (Windows):** `windows/runner/Invoke-RelianJob.ps1`.
- **Read-only evidence for the forge (Windows):** `windows/runner/Invoke-RelianReadJob.ps1`.
- **CPU, hardware, network or storage inventory (Windows):** `Invoke-RelianJob.ps1`, with a collector from `windows/collectors/`.
- **Linux:** `linux/runner/relian-runner.sh`.
- **macOS:** `macos/runner/relian-runner.sh`.

Run every one as System (Windows) or root (Linux, macOS).

## The hash rule

Every loader refuses to run bytes it has not hashed.

1. You pass a URL at a commit and the SHA256 of that file.
2. The loader downloads the file and compares the hash.
3. It runs the file only when the hash matches.

The rules, the same on every platform:

- **Empty hash:** exit 0, nothing downloaded. This is how you switch a deployment off. `Invoke-RelianReadJob` has no off switch: it refuses an empty hash with exit 1.
- **Hash mismatch:** exit 1, no retry.
- **URL with userinfo** (`https://user@host`, or `https://@host`): exit 1 before any download. All four entry points check this before the empty-hash exit, because the credential already sits in NinjaOne's activity history.
- **Retries:** three attempts for a timeout, a connection or DNS failure, or HTTP 408, 429, 500, 502, 503 or 504. Any other status gets one attempt.
- **Pin a commit, not a branch.** A branch moves and the hash then fails.
- **Get the hash:** `git show <commit>:<path> | sha256sum`.

In the examples below, `<raw>` means `https://raw.githubusercontent.com/Relianco/device-scripts/<commit>`. Put all flags on one line in the NinjaOne Parameters box.

## Security rules

A pasted loader can run only what you pinned. This is what each piece can and cannot do.

- **Pinned bytes.** A pin names exact bytes, so moving `main` cannot change what a pinned device runs.
- **No NinjaOne calls from packages, with one exception.** The runners and packages read and write no NinjaOne field and call no NinjaOne API. A package reports one JSON line on stdout and an exit code. The exception: `autoelevate` reads its licence key (and, when asked, its company and location names) from the NinjaOne fields named in `LicenseKeyField`, `CompanyNameField` and `LocationNameField`, with `Ninja-Property-Get`, so the key never goes on a command line.
- **Field writers are named.** Only `Invoke-RelianReadJob` (its result line), the inventory collectors, and `windows/collectors/runner-report-field.ps1` (the storage ProfileReport) write NinjaOne fields.
- **Secrets stay off the command line, with one exception.** A package that needs a secret reads an environment variable its caller sets, such as `AuthKey` for Tailscale or `PdfXchangeKeyFile` for PDF-XChange. `autoelevate` also accepts a `LicenseKey` package argument, which NinjaOne keeps in activity history; prefer `LicenseKeyField` (a NinjaOne secure field) or `AE_LICENSE_KEY`.
- **Read-only means tested.** Read-only packages are scanned for write commands or run against stubs.
- **Changing packages say so.** Each header names what it changes, what it backs up first, and what it never does.
- **No installs in CI.** CI runs the tests. It does not install an application.
- **No private data in the repo.** This repo is public. It holds no client name, device id, token, password or home-directory path.

## Windows

Every Windows path starts with `windows/`. Windows PowerShell 5.1 is the floor. Run every loader as **System** in NinjaOne.

### Install or run a package: Invoke-RelianRunner

Use it to run one package once, with a progress dialog for the signed-in user. Paste `windows/runner/Invoke-RelianRunner.ps1` into the NinjaOne script library.

Parameters (the last three are optional):

- `-PackageUrl`, `-PackageSha256`: the package script and its hash.
- `-ToolkitUrl`, `-ToolkitSha256`: the PSAppDeployToolkit 4.1.8 zip.
- `-BrandPackUrl`, `-BrandPackSha256`: the Relian dialog pack zip.
- `-Action`: `Install`, `Update`, `Repair`, `Reinstall` or `Uninstall`. `Reinstall` is an uninstall then an install.
- `-PinVersion`: a version, or another pin the package defines. A package that ignores the pin accepts any text, such as `1.0.0`.
- `-CancelPath`: a file path. If the file exists, the run exits 130. `RELIAN_DEPLOY_CANCEL=1` does the same.
- `-PackageArguments`: base64 of a flat JSON object of string values. See [Package arguments](#package-arguments).
- `-ReportOutputPath`: an absolute path. After a `storage-maintenance` ProfileReport run, the runner saves the report line there. Empty saves nothing.

The toolkit and brand pack zips come from `https://relianpub.blob.core.windows.net/pub/sec/`. See [Toolkit, brand pack and pins](#toolkit-brand-pack-and-pins).

Exit codes: 0 success or empty hash, 1 failure (a toolkit deferral, 1602, counts as 1), 130 cancelled.

Example: `gpo-evidence`, Summary section, on a domain controller.

```
-PackageUrl "<raw>/windows/read/gpo-evidence/Invoke-GpoEvidence.ps1"
-PackageSha256 "<package-sha256>"
-ToolkitUrl "<toolkit-url>" -ToolkitSha256 "<toolkit-sha256>"
-BrandPackUrl "<brand-url>" -BrandPackSha256 "<brand-sha256>"
-Action "Install" -PinVersion "1.0.0"
-PackageArguments "eyJTZWN0aW9uIjoiU3VtbWFyeSJ9"
```

That base64 is `{"Section":"Summary"}`. A read-only package treats `Install` as "run now" and `Uninstall` as a no-op.

### Package arguments

NinjaOne rejects `& | ; $ > < \` !` in the Parameters box, so extra values travel as base64.

- **Windows:** base64 of a JSON object whose values are all strings. Make it with `printf '%s' '{"Section":"Summary"}' | base64 -w0`.
- **Linux:** base64 of `Name=Value` lines.
- **macOS:** none.

Invalid arguments exit 1 and download nothing. An empty hash still exits 0 first.

### Recurring fixes: Invoke-RelianJob

Use it for a fix that runs every few hours. It has no toolkit and no dialog, downloads the module once, caches it, and then uses no network.

Parameters:

- `-ModuleUrl`: a job under `windows/jobs/` or a collector under `windows/collectors/`, at a commit.
- `-ModuleSha256`: its hash, 64 lowercase hex characters.
- `-ReportOnly`: optional switch. Detect drift and change nothing.

```
-ModuleUrl "<raw>/windows/jobs/scansnap-update-prompts.ps1"
-ModuleSha256 "<module-sha256>" -ReportOnly
```

Drop `-ReportOnly` to let the job fix the drift.

How it runs:

- **Cache:** `%ProgramData%\Relian\Jobs\<sha256>.ps1`, SYSTEM only. Every run re-checks the owner, the ACL and the hash, then runs the bytes it hashed, in process.
- **Refused, exit 1:** a non-`https` URL, a missing parameter, a malformed hash, a wrong cache ACL, Constrained Language Mode.
- **Run as System only.** A row set to Current user is skipped and shows as success.
- **Job output:** one JSON line with a `status`. Exit 0 healthy or changed and re-checked, 1 drift under `-ReportOnly`, 2 failed. Collectors differ; see [Inventory](#inventory-collectors).

Scheduling in a NinjaOne policy:

- Add an "Every N hours" row (1 hour minimum), an "On System Startup" row, and an "On User Login" row for laptops, all with the same Parameters.
- NinjaOne does not replay a run missed while the device was off. The startup and login rows narrow that gap.
- A failed run shows as FAILURE in activity and raises no alert.
- To bump a version, commit the module, hash it, and edit every row. An unedited row keeps its cached version.

### Read-only evidence: Invoke-RelianReadJob

Use it when the forge must ask a device a question and must not be able to change it. The loader holds no job table: the forge passes a URL and hash from its reviewed allowlist.

Paste it as a new library script, separate from `Invoke-RelianJob`. Parameters, in this order:

- `-PackageUrl`: `<raw>/windows/read/<job>/Invoke-<Name>.ps1`, with a 40-hex commit. No branch, query, fragment, `%`, `..`, backslash or whitespace.
- `-PackageSha256`: 64 lowercase hex characters.
- `-Job`: the `<job>` folder name from the URL.
- `-JobArguments`: base64 of a flat JSON object of strings, at most 16 keys. Keys that PowerShell could bind to `Action`, `Fix`, `Mode`, `ReportOnly` and similar are refused.
- `-RequestId`: 32 lowercase hex characters, echoed in the result.

How it runs:

- **Refused, exit 1:** any invalid parameter, a hash mismatch, a package over 1 MiB, a redirect, a bad cache ACL. There is no empty-hash off switch.
- **Child process:** the cached package runs in a child `powershell` with `-Action Install`, no toolkit, and a 120-second kill timer.
- **Result:** one JSON line, at most 8000 bytes, printed and written to the device field `relianJobResult` (multi-line text).
- **One job at a time per device.** The field holds only the latest line, so match `requestId` before you trust it.

To add a read job, commit a package under `windows/read/<job>/`, hash it at a commit on `main`, and add that pin to the forge allowlist. The loader itself is pasted again only for a loader fix.

### Inventory: collectors

Collectors are job modules. Schedule each one with `Invoke-RelianJob`, a commit URL and its SHA256, like any other job. There is no pin record, as with the other jobs.

Collectors: `cpu-benchmark`, `hardware-inventory`, `network-audit`, `storage-health`.

```
-ModuleUrl "<raw>/windows/collectors/hardware-inventory.ps1"
-ModuleSha256 "<module-sha256>"
```

- **Output:** the full JSON goes to the collector's field (`relianHardwareInventory`, `relianCpuBenchmark`, `relianNetworkAudit`, `relianStorageHealth`; WYSIWYG, script Read/Write) through `Ninja-Property-Set-Piped`, and one short JSON summary line goes to stdout.
- **Field format:** the value is `<pre>` plus the HTML-encoded JSON plus `</pre>`. The field shows it as preformatted text, and `text` from the API is the plain JSON, which parses directly.
- **Size limit:** the field holds 200000 characters, measured on the whole HTML string. A larger result is not truncated: the run throws and exits 1, and the JSON is printed to the run output.
- **`-ReportOnly`:** collects and prints the JSON without writing the field.
- **Failure:** a failed collection or field write exits 1.

`runner-report-field.ps1` in the same folder is not a job module. Paste it on its own: it runs the hash-pinned runner and writes the `storage-maintenance` ProfileReport to a device field. Steps are in `docs/maintenance.md`.

### Toolkit, brand pack and pins

The runner needs two zips besides the package. Both are content-addressed, so the hash is in the file name.

- **Where:** `https://relianpub.blob.core.windows.net/pub/sec/`. Each file name ends with its SHA256 before `.zip`.
- **URLs:** `scripts/publish-relian-packs.ps1` prints them. It uploads only with `-Publish`.
- **Toolkit pin:** `windows/releases/psadt.json` (PSAppDeployToolkit 4.1.8).
- **Brand pack source:** `windows/brand/relian/`, built by `windows/brand/build-relian-pack.ps1`.
- **Pin records:** `windows/releases/<name>.json` holds the source URL, file name, SHA256, size and version of each vendor installer. A device never reads it; the same values are inlined in the script, and tests fail when the two disagree.

### TLS

Old hosts (Server 2016 on Windows PowerShell 5.1) default to TLS 1.0 and 1.1, which Azure Storage refuses. Every script that downloads adds TLS 1.2 for the process when the host offers neither 1.2 nor 1.3. It writes nothing to the registry.

### Applications

Each downloads a hash-pinned vendor installer, pinned in the script and in `windows/releases/<name>.json`. Most also carry `Detect-<Name>.ps1` and `intune.json` for Intune.

- `7-zip`: 7-Zip.
- `acrobat`: Adobe Acrobat. `Edition` picks the edition.
- `adobe-reader`: Adobe Acrobat Reader.
- `app-cleanup`: read-only report of stale Firefox copies and classic Teams 1.x; with `Fix` `true` it removes a machine-wide old Firefox copy that is not running and is beside a current one or unused for `IdleDays` (90), and the classic Teams machine-wide installer (never new Teams). Per-user copies are report-only (`user-context`): remove them in the user session. Arguments: `Target` (`firefox`, `teams`, `all`), `Fix`, `CurrentMajor`, `IdleDays`.
- `autoelevate`: installs or upgrades the AutoElevate agent and stops its services before an upgrade. A fresh install needs `CompanyName`, `LocationName` and the license key (`LicenseKeyField` naming a NinjaOne secure field, the `AE_LICENSE_KEY` variable, or the `LicenseKey` argument). `Section` `Evidence` is read-only. `Section` `RemoveInstallLog` deletes `C:\AEInstallLog.log`, the vendor NinjaOne script's install log. See `docs/autoelevate.md`.
- `chrome`: Google Chrome, from a copy on relianpub (`sec/googlechromestandaloneenterprise64-<sha256>.msi`), because Google's URL always serves the latest MSI and would break the hash at every release. To bump: download the MSI from the `sourceUrl` in `windows/releases/chrome.json`, hash it, upload it with `az storage blob upload --auth-mode login --account-name relianpub -c pub -n sec/googlechromestandaloneenterprise64-<sha256>.msi -f <file>`, then update the sha256, size, version and `InstallerUrl` in `chrome.json`, `Invoke-Chrome.ps1` and the chrome tests.
- `departed-user-firefox`: one-off for a departed user's per-user Firefox. Always reports the profile size and the files outside OneDrive; with `Fix` `true` it removes only that user's Firefox program folder and its HKLM uninstall entry, and refuses unless the account is disabled in the directory, no interactive session exists, nothing runs from the folder and no reparse point is on the path. Never touches the profile. Arguments: `User`, `Fix`.
- `duo-winlogon`: Duo Authentication for Windows Logon from Duo's pinned MSI (no key on any command line). Installs, or upgrades an older build in place only when its archived MSI is pinned for rollback; writes the integration settings passed in-process as `-Settings` and EnableSSPRFix 1 (Entra "Reset password" at sign-in, 6.0.0+); checks version, credential provider and settings after, and undoes a failed install or upgrade. Installs the pinned VC++ 2015-2022 runtime when missing. No restart.
- `edge`: Microsoft Edge.
- `everything`: Everything, the file search tool.
- `firefox`: Mozilla Firefox.
- `git`: Git for Windows.
- `global-secure-access`: replaces older Global Secure Access clients with a verified Microsoft bundle. Install and Update only. See [the notes](windows/packages/global-secure-access/README.md).
- `microsoft-365`: Microsoft 365 Apps with the Office Deployment Tool and a pinned `configuration.xml`. The Office payloads download at install time and are not pinned.
- `notepadpp`: Notepad++.
- `pdf-xchange`: PDF-XChange PRO, or an in-place upgrade of V10 or V11. The licence comes only from the `PdfXchangeKeyFile` variable (base64 of the `.xcvault` KeyFile), which XCVault reads from a SYSTEM-and-Administrators-only temp file, never from a command line; the vendor updater is turned off. On a PC with full Adobe Acrobat it leaves the `.pdf` default alone.
- `putty`: PuTTY.
- `quicklook`: QuickLook.
- `sysmon`: Sysmon.
- `tailscale`: the Tailscale client, joined with `ClientTag`. The auth key comes only from the `AuthKey` variable.
- `teams`: Microsoft Teams from a pinned bootstrapper and MSIX.
- `vlc`: VLC.
- `wau`: Winget-AutoUpdate. Updates only the app IDs in the allow list at `ListUrl`; self-update is off. Install `winget` first, or it exits 1618.
- `wazuh`: the Wazuh agent. `Enroll` (for Intune) enrolls a fresh install from `RELIAN_WAZUH_*` variables and never re-enrolls or downgrades.
- `winget`: Microsoft App Installer (winget) only.
- `wireguard-client`: WireGuard and one split tunnel as a service. The private key is made and kept on the device; the run prints the public key. Also an Intune app (key only) and a Remediation that applies a signed address map. See `docs/wireguard-client.md`.
- `zoom`: Zoom.

### Settings and policy

These change settings when you ask, and most have a read-only mode.

- `ad-group-member`: adds one AD user to one group on a domain controller, optionally until `ExpiresInDays` or `ExpiresOn`. Privileged groups are refused. `Section` `Evidence` is read-only.
- `ad-user-offboard`: reports (`Mode` `Report`, the default) or disables (`Mode` `Disable`) the AD accounts named in `Users`, on a domain controller. `Disable` backs up the before-state to `C:\Relian\Offboard\<date>\`, sets `Description` (default "Disabled by Relian <date>"), optionally moves to an existing `TargetOu`, reads back, and refuses Domain/Enterprise/Schema Admins, built-in, break-glass and sync accounts. It never deletes, removes memberships or touches mailboxes. Follow-ups it does not do, run by the operator: revoke the user's Entra sign-in sessions (Graph `revokeSignInSessions`), then push the disable to Entra with a directory sync (`Start-ADSyncSyncCycle -PolicyType Delta` on the Entra Connect server; Cloud Sync tenants sync on their own schedule).
- `ad-user-identity`: re-points one AD user's names, UPN, mail, SMTP proxyAddresses and sAMAccountName and moves it between OUs, so it can be hard-matched to a cloud-only Entra user. `Mode` `Plan` (the default) prints the current and planned values, the conflicting AD objects and the objectGUID base64 (ImmutableId), and changes nothing. `Apply` refuses on a conflict, backs up to `%ProgramData%\Relian\ad-user-identity\`, then writes only the given values; `Rollback` restores the newest (or a named `Backup`) file. Never touches the password, groups or enabled state.
- `ad-stale-computers`: lists stale AD workstations (`Mode` `Report`, the default). `Mode` `Apply` disables at most 10 named in `Names`, after printing their BitLocker and LAPS secrets encrypted to `RecipientKey`. It never deletes.
- `onedrive-admx`: refreshes `OneDrive.admx` and the en-US `OneDrive.adml` in a domain controller's Group Policy Central Store (`SYSVOL\<domain>\Policies\PolicyDefinitions`, which must already exist). `Mode` `Plan` (the default) reports current and new revisions and changes nothing. `Apply` first copies the current two files to `C:\Relian\AdmxBackup\<UTC timestamp>\` (hash-checked), writes the .adml then the .admx through temp files, and reads both back against the source; files that already match are left alone. The source is the newest machine-wide OneDrive install on the DC, or a pinned download given as `AdmxUrl`, `AdmxSha256`, `AdmlUrl`, `AdmlSha256`. No other file in the store is touched.
- `apply-action`: applies one registry action from `windows/actions/<id>.json`. The pin is `<id>:<sha256 of that file>`.
- `browser-extension`: force-installs one extension in Chrome, Edge, Brave or Firefox through policy. The pin is `<browser>-<extension id>`.
- `comet-vss-provider`: keeps `COMET_FORCE_VSS_PROVIDER=system` for Comet Backup on QEMU guests. See `docs/comet-vss-provider.md`.
- `virtio-guest-tools`: installs or updates the virtio-win guest tools (VirtIO drivers and the QEMU guest agent) on a QEMU/Proxmox guest, then sets the `QEMU-GA` service to Automatic and starts it. `PinVersion` is the virtio-win version, such as `0.1.302`. Exits 0 and changes nothing on other hardware. It never restarts the machine; `RebootRequired` says when drivers want one. No `Uninstall`. `VssOption` `5` sets the agent's VSS backups to copy-only. On a guest that runs Comet Backup, run `comet-vss-provider` too. See `docs/virtio-guest-tools.md`.
- `component-store-repair`: component store (WinSxS) work in a SYSTEM scheduled task that is never killed and never restarts the machine. `Mode` `Scan` runs DISM ScanHealth. `Repair` needs `BackupDate` (a verified backup from the last 7 days) and runs RestoreHealth, then local sources with `/LimitAccess` (the expanded LCU in `MsuPath`, or the image in `WimPath` that matches build and edition), then `sfc /scannow`. `InstallMsu` runs DISM `/Add-Package /NoRestart` on the `.msu` files in `MsuPath` (`wusa /quiet /norestart` on Server 2016-2022 and Windows 10). Progress goes to `%ProgramData%\Relian\ComponentStore\state.json`; read it with `component-store`.
- `eventlog-source`: registers one event log `Source` as SYSTEM, so a program stops asking for admin rights. Uninstall removes only that source.
- `gpo-baseline`: applies an embedded GPO `Definition` on the PDC emulator, after a backup. Plan-only unless `Apply` is `true`.
- `gpo-registry-value`: sets (`Mode` `Apply`, with `Value` and `Type` `DWord` or `String`) or removes (`Mode` `Rollback`) one registry policy value, `Key` and `ValueName`, in one existing GPO named by `Gpo` (GUID or display name). `Mode` `Plan`, the default, only reads. `Key` must be an HKLM or HKCU `Software\Policies` (or `CurrentVersion\Policies`) key. Each change runs `Backup-GPO` first, to the `gpo-baseline` backup folder, and reads the value back. For a one-off value that no `gpo-baseline` definition covers. An empty `PinVersion` exits 0 and does nothing.
- `msi-repair`: repairs one installed MSI product (`msiexec /f`) by `ProductCode` or `DisplayName`. `Section` `Evidence` is read-only.
- `ninja-reset`: removes a broken or orphaned NinjaOne agent (services, install folders, `NinjaRMM LLC` registry identity, following NinjaOne's own removal script) and installs a fresh agent from the generic MSI with the location token in `RELIAN_NINJA_TOKENID`. Report-only unless `Apply` is `true`. Writes `C:\ProgramData\Relian\ninja-reset\done.txt`, which `Detect-NinjaReset.ps1` checks, so it runs once per device. See [the notes](windows/packages/ninja-reset/README.md).
- `printer-tcp`: adds a TCP/IP printer from `PrinterName`, `PrinterAddress` and `PrinterModel`, with optional printing defaults `PrinterColor` (`Color`, `Monochrome` or `Grayscale`), `PrinterDuplex` (`OneSided`, `TwoSidedLongEdge` or `TwoSidedShortEdge`) and `PrinterTray` (`Auto`, `Tray1`..`Tray4`, `Manual` or `Lct`). Empty values exit 0.
- `s1-rebind`: re-binds a SentinelOne agent that lost its console with `SiteToken`, or reinstalls a signed installer when `Reinstall` is `true`. `Section` `Report` is read-only. It never reboots.
- `thin-manager`: adds or removes one Startup shortcut. It installs nothing.
- `unity`: Unity Accounting and esiLaw elevation prompt evidence and guarded repairs. See [the notes](windows/packages/unity/README.md).
- `user-check`: a dialog that asks the person for a code, or opens Microsoft sign-in. The pin is the code, or `microsoft-sign-in`.
- `wireguard-network-guard`: stops WireGuard tunnels on a trusted office network and starts them off it. See `docs/wireguard-network-guard.md`.
- `wu-policy`: finds local policy values that turn off automatic Windows Update. `Fix` `true` removes them after a backup. Skips WSUS-managed devices.
- `bc-timezone`: checks whether a device on `FromZone` (default `Pacific Standard Time`) is on `TargetZone` (default `British Columbia Standard Time`, permanent UTC-7). `Fix` `true` switches it, then restarts the Comet services `backup.delegate` and `backup.elevator` if installed. If the target zone is missing the run exits 3: the device needs the cumulative update that adds it. `FallbackZone` (for example `Yukon Standard Time`) opts in to a fallback instead. Devices on other time zones are left alone.

### Maintenance

These report by default and change the device only when you ask. None reboots unless named.

- `storage-maintenance`: disk use and cleanup candidates. `Mode` `Cleanup` with `Tier` `Safe` or `Aggressive` frees caches and leftovers, never user files. `ProfileReport` `true` adds a per-profile census. Profile removal is a separate, gated opt-in. See `docs/maintenance.md`.
- `extend-system-volume`: extends C: online into unallocated space right after it, after the virtual disk was grown on the host. Refuses when a partition follows C:, never shrinks, moves or deletes a partition. `Section` `Evidence` is read-only.
- `update-maintenance`: update services, policy and servicing state. `Mode` `Repair` repairs them. Never starts Setup.
- `feature-update`: why Windows Update has not offered the next feature update. `Fix` `true` re-enables only the appraiser tasks.
- `feature-upgrade`: an in-place Windows upgrade from a pinned ISO (`IsoUrl`, `IsoSha256`). Setup runs detached as a scheduled task.
- `restart-notice`: restarts a device with a pending restart after a notice. `ReportOnly` `true` restarts nothing. `Force` `true` restarts with nothing pending, after the same notice.
- `mdm-checkin`: shows why a device's Intune check-in is late, or starts one. The default `Mode` `Report` is read-only: the MDM enrollment's EnterpriseMgmt task times, the `NoCloudApplicationNotification` policy values, and the push and IME services and log. `CheckIn` starts the enrollment's "Schedule #3" check-in task and restarts the IntuneManagementExtension service, nothing else.
- `gsa-private-access`: the Global Secure Access client's per-user "Private Access disabled" switch (`IsPrivateAccessDisabledByUser`). The default `Mode` `Report` is read-only: the value per signed-in user (UPN), the GSA services, and with `DnsName` whether that name resolves into the Private Access range 6.6.0.0/16. `Disable` or `Enable` (the undo) changes it for one signed-in `User` (UPN) and restarts the running GSA services. Internet and Microsoft traffic are not affected.
- `stay-awake`: keeps a device awake on AC power for a maintenance window. `Mode` `Hold` saves the sleep-after and unattended-sleep timeouts and sets both AC values to never; `Restore` (or `Uninstall`) puts the saved values back. The default, `Report`, changes nothing.
- `hybrid-join`: Microsoft Entra hybrid join of a domain-joined device through a client-side SCP. The default `Mode` `Report` is read-only: dsregcmd device facts, the `CDJ\AAD` `TenantId` and `TenantName` values, the Automatic-Device-Join task and AD domain reachability. `Scp` writes those two values from `TenantId` (a GUID) and `TenantName` (a domain name), after a backup under `C:\ProgramData\Relian\hybrid-join\`; `Join` does the same when both are given, then starts the join task. It refuses a device that is not domain-joined and leaves an already joined one alone. Undo by restoring the backed-up values or deleting the key; `dsregcmd /leave` is left to the operator.
- `outlook-autocomplete`: counts matching rows in Classic Outlook autocomplete caches. `Fix` `true` removes them.

### Diagnostics and evidence

All read-only, and each prints bounded JSON. The six under `windows/read/` also run through `Invoke-RelianReadJob`. The two test tools at the end are not read-only.

- `ad-evidence` (read, runner 374 only, not in the read-job allowlist): Active Directory facts for a hybrid join or sync review; the domain comes from RootDSE. `Section` is `Inventory` (computers and users with OU, enabled, last logon, OS, `userCertificate` count, UPN suffix and immutableId; `SearchBase` scopes it, paged by `Offset`) or `Scp` (the Device Registration connection point's `azureADId` and `azureADName`); `Name` runs `Reach` for one computer (AD, DNS, DHCP lease, ping and TCP 135/445/3389/5985, ARP, 4768/4624 events, and an `sc.exe query` of `Services`).
- `component-store` (read): component store health. DISM CheckHealth, a CBS.log summary (corruption rows, totals, top HRESULT codes, last errors), Windows Update events 20 and 31 by error code, build and UBR, pending restart state, and the last `component-store-repair` run.
- `diagnose-feature-upgrade` (read): a failed or running feature upgrade. `Section` is `Summary`, `Rollback`, `Servicing`, `Setup`, `Boot` or `Maintenance`.
- `diagnose-windows-update` (read): Windows Update state. `Section` is `Summary`, `History`, `Events`, `Policy`, `Service` or `ServicingHistory` (a CBS and DISM error digest).
- `duo-config` (read): Duo Authentication for Windows Logon products and versions, and the values of its installer and policy settings keys, with whether standard users can read them. `SKey` is reported only as present, its length and an 8-character SHA-256 prefix; `IKey` is masked; other text values except `Host` are reported by length.
- `folder-inventory` (read): one folder or share before a file-share migration. `Section` is `Discover` (shares, GPO drive maps, logon-script drive lines, AD home drives), `Summary` (file types, Excel count, database and lock-file families and the folders they cluster in, largest files, paths over 250 and 400 characters, SharePoint-invalid names, age), `Tree` or `Acl` (paged by `Offset`), `Access` (AD group expansion), `Open` (SMB open files) or `TopLevel` (the root's child folders with fast totals, paged by `Offset`, for a share too big to walk in one run). `Folder` names it (default `Accounting`); `Pick` chooses among matches. For a name with a space or a path, pass `FolderHex` instead: the hex of its UTF-8 bytes, a name, a relative path or a full local path such as `F:\Some Share\Sub Folder`, split into `FolderHex`, `FolderHex2` ... `FolderHex8` of at most 64 characters each (PowerShell: `-join ([Text.Encoding]::UTF8.GetBytes('F:\Some Share') | ForEach-Object { '{0:x2}' -f $_ })`; bash: `printf '%s' 'F:\Some Share' | xxd -p | tr -d '\n'`). Extend the file families in `$script:FiFamilies`.
- `gpo-evidence` (read): Group Policy state for a domain. `Section` is `Summary`, `Gpos`, `Policy`, `Rsop`, `Store`, `Profiles` or `Dc`; `Gpo` picks one GPO, `RsopUser` runs Rsop for that user (no RSAT needed, so it runs on a PC). A `cpassword` is counted, never printed.
- `hyperv-inventory` (read): a Hyper-V host before a server or network refresh. Host model, RAM, logical processors and OS; per VM state, generation, vCPU, memory, uptime, start action, disks, network adapters (switch, MAC, VLAN, IPs), guest OS and FQDN from KVP and enabled integration services; virtual switches, host NIC link speeds, host IPv4 addresses and DHCP Server scope and lease counts. VMs are paged by `Offset` (the previous run's `nextOffset`). Without the Hyper-V module it reports `hyperVAbsent`.
- `maintenance-evidence` (read): reads back stored storage and update maintenance reports, in pages.
- `wake-device` (read): sends a Wake-on-LAN packet from an online peer to `Mac` on the same subnet. A sent packet does not prove the target woke.
- `s1-install-logs` (read, runner 374 only, plain text, not in the read-job allowlist): SentinelOne installer and upgrade logs (file list, newest tails) and SentinelOne/MsiInstaller events from the last `Days` days, to explain an installer exit code. Token-shaped text is redacted.
- `endpoint-evidence`: device and user state that Intune or a script should have set. `Sections` picks the checks; `all` adds `OfficeLicence` (Office licence files and activation state) and `Kfm` (Known Folder Move targets, file counts and blockers) to the others. `UserPrt` (the signed-in user's PRT from `dsregcmd /status`) is opt-in only: it runs a hidden one-shot scheduled task in each user's session and removes it. E-mail addresses are hashed. Silent.
- `outlook-suggestion-sources`: where on a PC one address (`Match`) could surface in Classic Outlook suggestions. Never prints the address or matched text.

Test tools. These write to the device.

- `net-path-test`: before and after network timings for a remote-access change, run as the signed-in user. It toggles Private Access or a tunnel during the run, restores them, and keeps results under `%ProgramData%\Relian\NetTest`.
- `action-probe`: writes a marker file to prove the runner passed the right action and pin.

### Registry actions

`apply-action` reads these from `windows/actions/`. Each sets one or a few registry values.

`avd-logon-timeouts`, `azure-ad-sso-zone`, `cloud-kerberos-ticket`, `edge-startup-boost-off`, `fast-startup-off`, `fslogix-cleanup-invalid-sessions`, `fslogix-no-roam-recycle-bin`, `long-paths`, `mapped-drive-reconnect`, `onedrive-dehydrate-team-sites`, `teams-avd-media`.

### Jobs

One module per file under `windows/jobs/`, run by `Invoke-RelianJob`.

- `scansnap-update-prompts`: stops ScanSnap Online Update from prompting staff who cannot install updates.
- `nable-agent-removal`: removes the retired N-able N-sight agent and its parts, vendor uninstallers first. Leftover uninstall keys are deleted only after a backup under `%ProgramData%\Relian\NableUninstallKeyBackup`. It refuses anything that names NinjaOne, SentinelOne, Global Secure Access, WireGuard or Wazuh. Remove any GPO that reinstalls the agent first.
- `inspect-nable-uninstall-keys`: read-only report of leftover N-able uninstall keys and services, for when `nable-agent-removal` keeps one. Writes nothing; `-ReportOnly` is accepted and ignored.
- `read-nable-msi-log`: read-only report on the newest `nable-msi-*.log` in `C:\ProgramData\Relian\NableMsiLogs` (no other path), for when an N-able MSI uninstall fails. It reports facts, never the raw file: encoding (UTF-16 LE or ANSI), the first `Return value 3` windows, error lines, custom action return values, the deciding properties and the last 40 lines, with user paths, emails, SIDs, IPs, the machine name and secret property values masked. Lines are cut at 300 characters and the JSON at about 60 KB (`truncated`). No log gives status `ok` with `file` null. Writes nothing; `-ReportOnly` is accepted and ignored.
- `nable-force-cleanup`: forced removal of N-able registrations that `nable-agent-removal` could not remove; run it only after that job failed. The loader forwards only `-ReportOnly`, so this is its own module and always forces. It starts no process and runs no `msiexec` or vendor binary; it only deletes registry keys and files, and only for a product that matches the N-able name lists, is not NinjaOne, SentinelOne, Global Secure Access, WireGuard or Wazuh, is still registered, with no N-able service present. First it backs up everything it will delete under `C:\ProgramData\Relian\NableForceBackup\<UTC time>-<product code>` (JSON, a registry listing, and a verified copy of the cached package and the bootstrapper folder; SYSTEM only, never overwritten); a failed backup deletes nothing (exit 2). Then it removes the Installer product and UserData keys, the Add/Remove Programs keys, component and upgrade-code keys where the product is the only client (others are kept and reported), the cached package only when it sits directly in `C:\Windows\Installer` with a hex `.msi` name and no other product uses it, and the `C:\ProgramData\{GUID}` folder of a matched key's `Agent.exe` unless it is a link. `-ReportOnly` deletes nothing and lists in `removed` what it would delete (`drift`, exit 1). Output keys: `job`, `status` (`compliant`, `removed`, `drift`, `failed`), `removed`, `backups`, `left`, `error`. A matched key still present afterwards is `failed`.
- `inspect-secret-read-access`: read-only report of who can read the places a licence key or script body can land: the channel access (SDDL, translated ACEs, a staff-readable flag for Everyone, Authenticated Users, Users and INTERACTIVE, and Event Log Readers apart) of `Microsoft-Windows-PowerShell/Operational`, `Windows PowerShell`, `Security` and `Microsoft-Windows-Sysmon/Operational`, any EventLog `ChannelAccess` policy, the count and time span of PowerShell 4104 events (no event text), the ACL and value names (never values) of the AutoElevate, PDF-XChange Vault and Tracker Software keys, the ACL of `C:\Windows\Installer` and one cached `.msi`, the last 5 lines of the AutoElevate install log as shapes only (timestamp, length, a redaction-marker flag and a key-shaped flag, never the text), and the Administrators and Event Log Readers members. Writes nothing; `-ReportOnly` is accepted and ignored.
- `inspect-ime-script-launch`: read-only report from the Intune Management Extension logs (AppWorkload, AgentExecutor, IntuneManagementExtension) of how IME ran apps named `Relian Managed - ...`: per app its id, name, last time seen and fixed markers (`PowerShellScript`, `runAs32Bit`, `AgentExecutor`, `System32`, `SysWOW64`, `Sysnative`, `msiexec`, `cmd.exe`), and the last 20 IMECache script launches with the `powershell.exe` path IME used and the `.ps1` file name. Never prints log text or command lines. Writes nothing; `-ReportOnly` is accepted and ignored.
- `reset-windowsupdate-auto-policy`: backs up the WindowsUpdate policy key, then removes only `NoAutoUpdate` and `AUOptions`. A failed backup deletes nothing.
- `reset-wazuh-enrollment`: forces a fresh Wazuh enrolment. Stops `WazuhSvc` (60 second wait), copies `client.keys` to `%ProgramData%\Relian\wazuh\client.keys.bak-<UTC time>` (SYSTEM and Administrators only, set before the copy), empties `client.keys` and leaves the service stopped, so the Intune Wazuh app fails detection and enrols the agent again. `-ReportOnly` is the check: service status, `client.keys` length, whether `authd.pass` exists and the agent folder, never file contents (`drift`, exit 1, while keys are present). Undo is in the file header.
- `restore-windowsupdate-auto-policy`: the undo. Writes those two values back from the newest backup and deletes nothing.
- `hide-recovery-partitions`: removes drive letters assigned to Windows Recovery or EFI System partitions (4 GiB or smaller) after writing a backup under `C:\ProgramData\Relian\RecoveryPartitionLetterBackup`. A failed backup changes nothing.
- `remove-eol-dotnet`: removes end-of-life Microsoft .NET 5 and .NET 7 runtimes (Runtime, Windows Desktop Runtime, ASP.NET Core Shared Framework, Host, Host FX Resolver) after writing a SYSTEM-only backup under `C:\ProgramData\Relian\EolDotnetBackup`. Verified WiX Burn bundles under `C:\ProgramData\Package Cache\{GUID}\*.exe` run silently first, then any remaining matched Windows Installer `{GUID}` products run via `msiexec.exe /x`. Leaves .NET 6, .NET 8, .NET 9, .NET 10, .NET Framework and third-party runtimes untouched. `-ReportOnly` changes and writes nothing (`drift`, exit 1).
- `remove-eol-dotnet-6`: opt-in sibling of `remove-eol-dotnet`, identical except one line, that also removes .NET 6 (end of life 2024-11-12): Runtime, Windows Desktop Runtime, ASP.NET Core Shared Framework, Host, Host FX Resolver, and the ASP.NET Core Hosting Bundle (`Microsoft .NET 6.x.y - Windows Server Hosting` and `Hosting Bundle Options`). All Hosting Bundles share one IIS ASP.NET Core Module, so it refuses the Hosting Bundle (exit 2, nothing run; `-ReportOnly` shows the reason in `error`) while an installed `IIS\Asp.Net Core Module\V2\aspnetcorev2.dll` has a file version below 18 (the module from .NET 8). Install a current Hosting Bundle first. It is a separate module because the loader forwards only `-ReportOnly`. Same backup and safety checks; never .NET 8 or later. Run `-ReportOnly` first and check no IIS site still needs .NET 6.

## Linux

Paste `linux/runner/relian-runner.sh` as a shell script and run it as root. It follows the hash rule above.

Parameters (the last is optional):

- `--package-url`, `--package-sha256`
- `--action`: `Install`, `Update`, `Repair`, `Reinstall` or `Uninstall`
- `--pin-version`
- `--package-arguments-b64`: base64 of `Name=Value` lines, at most 4096 bytes. Values reach the package as environment variables. Names like `PATH` or `LD_*` are refused.

An unknown or missing parameter exits 1. The runner prints no trace, so arguments stay out of the log.

```
--package-url "<raw>/linux/packages/tailscale/tailscale.sh"
--package-sha256 "<package-sha256>"
--action "Install" --pin-version "1.104.4"
--package-arguments-b64 "Q2xpZW50VGFnPXRhZzpjbGllbnQtZXhhbXBsZQ=="
```

That base64 is `ClientTag=tag:client-example`. Put the auth key in the runner's `AuthKey` environment variable, never in package arguments: those are kept in activity history.

Packages in `linux/packages/`, pinned in `linux/releases/<name>.json`:

- `tailscale`: Tailscale from the signed apt repo on Debian and Proxmox VE, joined with a tag. The pin is a floor. The key reaches tailscale through a `0600` file. It never touches the firewall, sshd or Proxmox config.
- `wazuh`: the Wazuh agent from the official repo, key pinned by fingerprint. The pin is a floor and is never downgraded. Reads `WazuhManager`, `WazuhGroup`, `WazuhNamePrefix` and `WazuhPasswordFile` from the environment.
- `diagnose-pve`: read-only plain-text diagnostics for Proxmox VE and Debian hosts: memory, ZFS, RAID, LVM and sampled disk activity.
- `noop`: installs nothing and exits 0. Proves the runner, the pin and the NinjaOne wiring work.

## macOS

Paste `macos/runner/relian-runner.sh` as a shell script and run it as root. It matches the Linux runner, but takes no `--package-arguments-b64` and hashes with `shasum -a 256`.

Parameters, all required: `--package-url`, `--package-sha256`, `--action`, `--pin-version`.

```
--package-url "<raw>/macos/packages/noop/noop.sh"
--package-sha256 "<package-sha256>"
--action "Install" --pin-version "1.0.0"
```

Packages in `macos/packages/`, pinned in `macos/releases/<name>.json`:

- `noop`: installs nothing and exits 0. It tests the runner.

## Operator tools

Scripts in `scripts/` run on an admin machine or a server, never on a device.

- `scripts/remote-sessions.ps1` drafts Invoice Ninja remote-support tasks from NinjaOne session records and Wazuh activity. The default is a dry run: `pwsh -NoProfile -File scripts/remote-sessions.ps1 -Days 3`. `-Apply -ClientMap <file>` also creates Backlog tasks; it never sends, invoices or emails. Credentials come from environment variables only (see the script's help).

## CI and review gates

A pull request into `main` needs four green checks: `PowerShell tests`, `Windows maintenance regressions`, `Secret scan (betterleaks)` and `review`.

- **PR verify** (`pr-verify.yml`): on Ubuntu, the PowerShell suite, the reviewer tests and the Linux and macOS runner tests. On `windows-2022`, the tests that need real NTFS ACLs or Windows PowerShell 5.1.
- **Secret scan** (`secret-scan.yml`): betterleaks scans the PR's commits with the policy from the base commit, so a PR cannot weaken it.
- **AI PR review** (`ai-pr-review.yml`): a model reviews each changed file and posts one review. It passes when the body starts with `LGTM`.

How the review treats a PR:

- **Code PR:** reviewed in full, at most 20 files. Keep a PR under 20 files, or the review says "AI review incomplete", which is not a pass. A later push that changes only docs keeps the earlier verdict.
- **Docs-only PR:** a docs check for client names, device ids, home paths, secrets and contradictions of the code rules. Clean is `LGTM (docs review)`. Findings start with `Docs review by ChatGPT` and block until fixed.
- **What counts as docs:** `*.md` and `LICENSE`, by extension only. `docs/x.ps1` is code.

## Contribute and test

New work is a branch from `origin/main` and a pull request into `main`. Never force-push `main`.

1. Once per clone, run `git config core.hooksPath .githooks`. The pre-push hook scans your commits with betterleaks.
2. Commit as `Relian Technologies <112814130+Relianco@users.noreply.github.com>`.
3. Stage files by name. Keep client names, device ids, tokens and home-directory paths out of files and PR text.
4. Do not run an installer on a device unless the maintainer asks.

### Add a package

A Windows package is one folder with one script, a pin record and a test.

```
windows/packages/<name>/Invoke-<Name>.ps1
windows/releases/<name>.json
tests/windows/<name>-plan.Tests.ps1
```

An application also carries `Detect-<Name>.ps1` (exit 0 when present) and `intune.json` (install and uninstall lines). A read job goes under `windows/read/<job>/` instead.

Rules for the script:

1. **It runs alone.** The runner copies only this file, so inline every URL, hash and setting.
2. **No `Mandatory` parameters.** They prompt when a test dot-sources the file. Take `DeploymentType`, `Action`, `PinVersion` and your own values as strings.
3. **Off switch first, then hash.** An empty pin exits 0 before the installer URL is read. On the download path, exit 1 on a hash mismatch or a userinfo URL. Carry the TLS guard line.
4. **No NinjaOne.** `tests/windows/ninja-agnostic.Tests.ps1` fails on a field read or write, `ninjarmm-cli`, the API or the deploy token.
5. **Windows PowerShell 5.1 compatible.**
6. **Bounded output.** NinjaOne truncates long output, so print one JSON line.

Linux and macOS packages are `<platform>/packages/<name>/<name>.sh` plus `<platform>/releases/<name>.json`.

Then list it in this README, in its platform section, as a bullet that starts with the folder name in backticks. `tests/readme-inventory.Tests.ps1` fails otherwise.

### Run the tests

Tests are plain scripts with no Pester and no network.

```
pwsh -NoProfile -File tests/run-all.ps1
bash tests/linux/run-tests.sh
bash tests/macos/run-tests.sh
node --test tests/ai-pr-review.test.mjs \
  tests/secret-scan.test.mjs
scripts/scan-secrets.sh
```

- `tests/run-all.ps1` runs `tests/*.Tests.ps1` and `tests/windows/*.Tests.ps1`. A test exits non-zero to fail.
- To test a PowerShell script, set `RELIAN_DEPLOY_TEST=1` and dot-source it. It defines its functions and runs nothing.
- Write the failing test first, then the code.
