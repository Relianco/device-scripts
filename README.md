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
- **No NinjaOne calls from packages.** The runners and packages read and write no NinjaOne field and call no NinjaOne API. A package reports one JSON line on stdout and an exit code.
- **Field writers are named.** Only `Invoke-RelianReadJob` (its result line), the inventory collectors, and `windows/collectors/runner-report-field.ps1` (the storage ProfileReport) write NinjaOne fields.
- **Secrets stay off the command line, with one exception.** A package that needs a secret reads an environment variable its caller sets, such as `AuthKey` for Tailscale or `PdfXchangeKeyData` for PDF-XChange. `autoelevate` also accepts a `LicenseKey` package argument, which NinjaOne keeps in activity history; prefer `AE_LICENSE_KEY`.
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

- **Output:** the full JSON goes to the field the collector's field (`relianHardwareInventory`, `relianCpuBenchmark`, `relianNetworkAudit`, `relianStorageHealth`; Multi-line text, script Read/Write) through `Ninja-Property-Set-Piped`, and one short JSON summary line goes to stdout.
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
- `autoelevate`: installs or upgrades the AutoElevate agent and stops its services before an upgrade. A fresh install needs `CompanyName`, `LocationName` and the license key (`LicenseKey` argument or `AE_LICENSE_KEY` variable). `Section` `Evidence` is read-only. See `docs/autoelevate.md`.
- `chrome`: Google Chrome.
- `edge`: Microsoft Edge.
- `everything`: Everything, the file search tool.
- `firefox`: Mozilla Firefox.
- `git`: Git for Windows.
- `global-secure-access`: replaces older Global Secure Access clients with a verified Microsoft bundle. Install and Update only. See [the notes](windows/packages/global-secure-access/README.md).
- `microsoft-365`: Microsoft 365 Apps with the Office Deployment Tool and a pinned `configuration.xml`. The Office payloads download at install time and are not pinned.
- `notepadpp`: Notepad++.
- `pdf-xchange`: PDF-XChange PRO, or an in-place upgrade of V10 or V11. The licence comes only from the `PdfXchangeKeyData` variable; the vendor updater is turned off. On a PC with full Adobe Acrobat it leaves the `.pdf` default alone.
- `putty`: PuTTY.
- `quicklook`: QuickLook.
- `sysmon`: Sysmon.
- `tailscale`: the Tailscale client, joined with `ClientTag`. The auth key comes only from the `AuthKey` variable.
- `teams`: Microsoft Teams from a pinned bootstrapper and MSIX.
- `vlc`: VLC.
- `wau`: Winget-AutoUpdate. Updates only the app IDs in the allow list at `ListUrl`; self-update is off. Install `winget` first, or it exits 1618.
- `wazuh`: the Wazuh agent. `Enroll` (for Intune) enrolls a fresh install from `RELIAN_WAZUH_*` variables and never re-enrolls or downgrades.
- `winget`: Microsoft App Installer (winget) only.
- `wireguard-client`: WireGuard and one split tunnel as a service. The private key is made and kept on the device; the run prints the public key. See `docs/wireguard-client.md`.
- `zoom`: Zoom.

### Settings and policy

These change settings when you ask, and most have a read-only mode.

- `ad-group-member`: adds one AD user to one group on a domain controller, optionally until `ExpiresInDays` or `ExpiresOn`. Privileged groups are refused. `Section` `Evidence` is read-only.
- `ad-stale-computers`: lists stale AD workstations (`Mode` `Report`, the default). `Mode` `Apply` disables at most 10 named in `Names`, after printing their BitLocker and LAPS secrets encrypted to `RecipientKey`. It never deletes.
- `apply-action`: applies one registry action from `windows/actions/<id>.json`. The pin is `<id>:<sha256 of that file>`.
- `browser-extension`: force-installs one extension in Chrome, Edge, Brave or Firefox through policy. The pin is `<browser>-<extension id>`.
- `comet-vss-provider`: keeps `COMET_FORCE_VSS_PROVIDER=system` for Comet Backup on QEMU guests. See `docs/comet-vss-provider.md`.
- `eventlog-source`: registers one event log `Source` as SYSTEM, so a program stops asking for admin rights. Uninstall removes only that source.
- `gpo-baseline`: applies an embedded GPO `Definition` on the PDC emulator, after a backup. Plan-only unless `Apply` is `true`.
- `msi-repair`: repairs one installed MSI product (`msiexec /f`) by `ProductCode` or `DisplayName`. `Section` `Evidence` is read-only.
- `printer-tcp`: adds a TCP/IP printer from `PrinterName`, `PrinterAddress` and `PrinterModel`. Empty values exit 0.
- `s1-rebind`: re-binds a SentinelOne agent that lost its console with `SiteToken`, or reinstalls a signed installer when `Reinstall` is `true`. `Section` `Report` is read-only. It never reboots.
- `thin-manager`: adds or removes one Startup shortcut. It installs nothing.
- `unity`: Unity Accounting and esiLaw elevation prompt evidence and guarded repairs. See [the notes](windows/packages/unity/README.md).
- `user-check`: a dialog that asks the person for a code, or opens Microsoft sign-in. The pin is the code, or `microsoft-sign-in`.
- `wireguard-network-guard`: stops WireGuard tunnels on a trusted office network and starts them off it. See `docs/wireguard-network-guard.md`.
- `wu-policy`: finds local policy values that turn off automatic Windows Update. `Fix` `true` removes them after a backup. Skips WSUS-managed devices.
- `bc-timezone`: checks whether a device is still on `Pacific Standard Time` (or on the `Yukon Standard Time` fallback once the `British Columbia Standard Time` update is installed). `Fix` `true` switches it to `British Columbia Standard Time` when available, else `Yukon Standard Time` (both permanent UTC-7). Devices on other time zones are left alone.

### Maintenance

These report by default and change the device only when you ask. None reboots unless named.

- `storage-maintenance`: disk use and cleanup candidates. `Mode` `Cleanup` with `Tier` `Safe` or `Aggressive` frees caches and leftovers, never user files. `ProfileReport` `true` adds a per-profile census. Profile removal is a separate, gated opt-in. See `docs/maintenance.md`.
- `update-maintenance`: update services, policy and servicing state. `Mode` `Repair` repairs them. Never starts Setup.
- `feature-update`: why Windows Update has not offered the next feature update. `Fix` `true` re-enables only the appraiser tasks.
- `feature-upgrade`: an in-place Windows upgrade from a pinned ISO (`IsoUrl`, `IsoSha256`). Setup runs detached as a scheduled task.
- `restart-notice`: restarts a device with a pending restart after a notice. `ReportOnly` `true` restarts nothing.
- `outlook-autocomplete`: counts matching rows in Classic Outlook autocomplete caches. `Fix` `true` removes them.

### Diagnostics and evidence

All read-only, and each prints bounded JSON. The five under `windows/read/` also run through `Invoke-RelianReadJob`. The two test tools at the end are not read-only.

- `diagnose-feature-upgrade` (read): a failed or running feature upgrade. `Section` is `Summary`, `Rollback`, `Servicing`, `Setup`, `Boot` or `Maintenance`.
- `diagnose-windows-update` (read): Windows Update state. `Section` is `Summary`, `History`, `Events`, `Policy`, `Service` or `ServicingHistory` (a CBS and DISM error digest).
- `gpo-evidence` (read): Group Policy state for a domain. `Section` is `Summary`, `Gpos`, `Policy` or `Rsop`; `Gpo` picks one. A `cpassword` is counted, never printed.
- `maintenance-evidence` (read): reads back stored storage and update maintenance reports, in pages.
- `wake-device` (read): sends a Wake-on-LAN packet from an online peer to `Mac` on the same subnet. A sent packet does not prove the target woke.
- `endpoint-evidence`: device and user state that Intune or a script should have set. `Sections` picks the checks. Silent.
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
- `reset-windowsupdate-auto-policy`: backs up the WindowsUpdate policy key, then removes only `NoAutoUpdate` and `AUOptions`. A failed backup deletes nothing.
- `restore-windowsupdate-auto-policy`: the undo. Writes those two values back from the newest backup and deletes nothing.

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
