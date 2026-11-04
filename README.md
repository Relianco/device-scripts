# device-scripts

NinjaOne installs software by pasting `windows/runner/Invoke-RelianRunner.ps1`. That file is the installer. `windows/bootstrap.ps1` loads an inventory collector. It is not the installer.

## Deploy runner

The runner is `windows/runner/Invoke-RelianRunner.ps1`. Paste that file into NinjaOne. Each run passes the package script URL and `PackageSha256`, the toolkit URL and `ToolkitSha256`, and the brand pack URL and `BrandPackSha256`, plus `Action` and `PinVersion`. The package URL is one script under `windows/packages/`. An empty pin exits 0 and downloads nothing. There are three download attempts. A bad hash is not retried. Cancel exits 130. The toolkit and the brand pack are downloaded from `https://relianpub.blob.core.windows.net/pub/sec/`. bootstrap.ps1 remains the collector loader. It follows `main`, checks no file hash, and can put a git token in the download URL. `PackageArguments` is an optional base64 JSON object of extra package parameters. An empty value adds none. Invalid package arguments exit 1 and download nothing. An empty hash still exits 0 before those arguments are read.

`scripts/publish-relian-packs.ps1` prints the toolkit and brand-pack URLs and does not upload unless `-Publish` is set.

## Shell runners

`linux/runner/relian-runner.sh` is the Linux script to paste. It is not the macOS runner.

### Linux package arguments

`--package-arguments-b64` is optional. It carries extra package settings in one parameter. Its value is base64 of newline-separated `Name=Value` lines. A name matches `^[A-Za-z][A-Za-z0-9_]*$`. Names that change how a process runs or loads code are refused, in any case: `PATH`, `IFS`, `SHELL`, `HOME`, `USER`, `ENV`, `TERM`, `TMPDIR`, `LANG*`, `LC_*`, `LD_*`, `BASH_*`, `PYTHON*`, `PERL*`, `RUBY*`, `NODE_*`, `RELIAN_*`, `NINJA_*`, the shell's own control variables, and the runner's variable names. A value is any text without a newline or NUL. Invalid base64, more than 4096 decoded bytes, an empty name, a line with no `=`, or a repeated name exits 1 and downloads nothing. An empty value or no flag adds nothing.

Each pair is set in the environment of the package process only. The runner's own later steps do not see it. A pair wins over a NinjaOne script variable of the same name, and a script variable still works when no pair names it. The runner prints the count and the names, never the values or the blob, and turns off shell tracing.

The values are not secret. They are on the runner's command line. Keep secrets in NinjaOne Secure custom fields.

For the Tailscale package, the decoded text is:

```
ClientTag=tag:client-example
AuthKeyField=tailscaleAuthKey
```

Build the parameter with `printf 'ClientTag=tag:client-example\nAuthKeyField=tailscaleAuthKey\n' | base64 -w0` and pass `--package-arguments-b64 <output>`. base64 output has no characters that NinjaOne refuses in a parameter.

`macos/runner/relian-runner.sh` is the macOS script to paste. It is not the Windows runner and not the Linux runner.

## TCP printer

`windows/packages/printer-tcp/Invoke-PrinterTcp.ps1` installs one local raw TCP/IP queue on port 9100. Pass `PrinterName`, `PrinterAddress`, and `PrinterModel` in `PackageArguments`. An empty name, address, model, or pin exits 0 and downloads nothing.

`PrinterModel` is `BrotherHlL2370Dw` or `KonicaUniversalPcl`. The driver pins are in `windows/releases/printer-tcp.json`. SNMP on the new port is turned off. `Add-Printer` receives the queue name, the driver, and the port. Uninstall removes that queue and removes the port when no other queue uses it. The driver stays installed.

## Tailscale

`windows/packages/tailscale/Invoke-Tailscale.ps1` installs the pinned Tailscale MSI with `TS_UNATTENDEDMODE=always` and joins the tailnet with `tailscale up --advertise-tags=<ClientTag> --hostname=<COMPUTERNAME> --unattended --accept-dns=false --accept-routes=false`. Pass `ClientTag`, such as `tag:client-example`, in `PackageArguments`. Do not pass the auth key there: package arguments become the child command line.

The auth key comes from one of two places. The NinjaOne script variable `AuthKey` on the runner is used when it is set. Otherwise the package reads the organization-level Secure custom field `tailscaleAuthKey` with `Ninja-Property-Get`. Pass `AuthKeyField` in `PackageArguments` to use another field name. The field needs automation read permission and can be read only while an automation runs. Its limit is 200 characters. The package removes `AuthKey` from its environment, checks that the value is one `tskey-` token, never prints or writes it, and blanks it from `tailscale up` output. The key is on the `tailscale.exe up` command line only while that process runs, and process auditing can record it. Use tagged, pre-approved, short-lived keys.

A node that is Running with exactly that tag exits 0 with no change. A node with any other tag, or joined without a tag, exits 1 and is not re-joined. A join with no key in either place exits 1 before anything is downloaded. Uninstall and Reinstall exit 1. An empty pin exits 0.

## Tailscale on Linux

`linux/packages/tailscale/tailscale.sh` installs Tailscale on Debian bookworm or trixie hosts, including Proxmox VE. It writes the Tailscale apt key to `/usr/share/keyrings/tailscale-archive-keyring.gpg` after checking the key's sha256 against the pin in `linux/releases/tailscale.json`. It adds `/etc/apt/sources.list.d/tailscale.list` with `signed-by`, refreshes only that source, and installs `tailscale` from the stable repo. The pin version is a minimum. apt installs the newest version in the repo. Then it runs `tailscale up --auth-key=file:<key file> --advertise-tags=<ClientTag> --hostname=<short hostname> --accept-dns=false --accept-routes=false --ssh=false`.

The values come from the package environment: pass them in `--package-arguments-b64` (see Linux package arguments), or as NinjaOne script variables on the runner. `ClientTag` is required. The auth key is the `AuthKey` script variable when set. Otherwise the package reads the organization-level Secure custom field `tailscaleAuthKey` with `ninjarmm-cli get`. Set `AuthKeyField` to use another field name. The field needs automation read permission and can be read only while an automation runs. Its limit is 200 characters. The key is never on a command line. The package writes it to a mode 0600 file in a private temp directory, passes that path to `tailscale up`, and removes the file when the command finishes or the script exits. Use tagged, pre-approved, short-lived keys.

A node that is Running with exactly that tag gets `tailscale set` with the same preferences and exits 0. A node that is Stopped with that tag is brought up without a key. A node with any other tag, or joined without a tag, exits 1 and is not re-joined. A status that cannot be read on an installed node exits 1. Uninstall and Reinstall exit 1. An empty pin exits 0. The package does not change the Proxmox firewall, sshd, or anything else on the host. Those changes stay manual.

## Proxmox and Debian diagnostics

`linux/packages/diagnose-pve/diagnose-pve.sh` is a read-only, low-impact health report for Proxmox VE and Debian hosts. It is meant for live client production servers. It prints plain text to stdout, which NinjaOne keeps as the script output, and it always exits 0. Each section is capped and says when it cut lines, so the whole report stays under about 24 KB.

What it collects, one section each:

1. Identity: hostname, kernel, Debian version, uptime, load, date, timezone, `pveversion`.
2. CPU and pressure: `lscpu` model, sockets, cores, threads and MHz lines, `/proc/pressure/{cpu,io,memory}`, and the top 8 processes by CPU and by RSS from `ps -eo pcpu=,pmem=,rss=,comm=`. Only the command name is read, never the full command line.
3. Memory: `free -m`, `/proc/swaps`, the ZFS ARC size and limits, `vm.swappiness`, and the transparent huge page settings.
4. Storage: `lsblk -d` with rotational, model, scheduler and request queue size, the SCSI queue depth from `/sys`, `df -hT` without tmpfs, `/proc/mdstat`, the file system under `/var/lib/vz`, `zpool status -x` and `zpool list`, `vgs --readonly` and `lvs --readonly`, and the ZFS `compression`, `recordsize`, `volblocksize` and `sync` properties.
5. I/O sample: `/proc/diskstats` read twice, `Sample` seconds apart, then read and write MB/s, IOPS, average wait in ms and utilisation for each whole device that did I/O.
6. Network: `ip -br address`, the default route, MTU and error and drop counters from `/sys/class/net`, link speed and duplex from plain `ethtool <interface>` for physical NICs, `ss -s`, and the Tailscale state, peer count and own tags.
7. Proxmox, only when `pveversion` exists: `pvesm status`, `qm list`, `pct list`, an allowlisted part of `qm config <id>` for each VM, the backup jobs from `pvesh get /cluster/backup`, the non-comment lines of `/etc/vzdump.conf`, the last 15 tasks, and whether a backup task is running now.
8. Backup agents: `systemctl is-active` and `systemctl show -p MemoryCurrent,NRestarts` for `backup-tool` and `cometd`.

From `qm config`, only these keys are printed: `name`, `memory`, `balloon`, `cores`, `sockets`, `cpu`, `scsihw`, `agent`, `boot`, `ostype`, and the numbered `scsi`, `virtio`, `sata`, `ide`, `efidisk`, `tpmstate` and `net` keys. A key that contains `pass`, `key`, `secret` or `token` is never printed. A last pass replaces anything shaped like a Tailscale auth key or `password=<value>` with `<redacted>`.

Every command runs under `timeout 10`, at `nice -n 19` and in the idle I/O class where `ionice` is available. No command starts after 43 seconds, so a run ends in about 45 seconds at most. A normal run takes the sample time plus a few seconds. A command that is missing, fails or times out prints `[unavailable: <command>]`, and the report goes on. The last lines list the sections that ran, with their times, and the total time.

`Sample` is the only setting: whole seconds, default 5, clamped to 1 to 10. Pass it in `--package-arguments-b64`. For `Sample=5`, `printf 'Sample=5\n' | base64 -w0` gives `U2FtcGxlPTUK`, so the runner parameters are:

```
--package-url <raw URL of diagnose-pve.sh> --package-sha256 <sha256 from linux/releases/diagnose-pve.json> --action Install --pin-version 1 --package-arguments-b64 U2FtcGxlPTUK
```

The runner's action and pin version are ignored. The package does not:

- write, create, or delete any file, or use a temp file
- start, stop, restart, enable, or reload any service
- install, update, or remove packages
- change kernel settings, load modules, or write to `/proc` or `/sys`
- run SMART reads, `hdparm`, benchmarks, scrubs, trims, or anything else that scans, wakes, or locks disks
- take LVM locks
- start, stop, migrate, back up, or change a VM or container, or call any `pvesh` method other than `get`
- change network settings or use `ethtool` with any option
- connect to the network. Only `tailscale status` and `pvesh get` talk to their local daemons.
- print full process command lines, VM descriptions, cloud-init passwords, SSH keys, or Tailscale keys

`tests/linux/diagnose-pve-test.sh` scans the script for forbidden commands, redirects and subcommands, and runs it against fake commands and fixture files only.

## Feature update readiness

`windows/packages/feature-update/Invoke-FeatureUpdate.ps1` says why Windows Update has not offered a device the next feature update. Run it through the deploy runner (NinjaOne script 374) as SYSTEM on Windows PowerShell 5.1, not through the Bootstrap loader: the loader follows `main` with no hash check, and it writes `relian_<name>` fields, which NinjaOne rejects because field names are alphanumeric.

It reads the OS build, Windows Update policy, the compatibility appraiser's safeguard holds, TPM, Secure Boot, free disk space, a Windows Update search, recent Windows Update client errors, and logs from earlier setup attempts. It writes one line of compact JSON to the device field `relianFeatureUpdate` with `ninjarmm-cli set --stdin` and a read-back check, and prints the same line last on stdout.

Actions: `Install`, `Update`, `Repair` and `Reinstall` all run the same read-only check. `Uninstall` exits 0 and changes nothing, because nothing was installed. The runner turns `Reinstall` into an uninstall and then an install.

Fix mode is off unless the package arguments are `{"Fix":"true"}`, base64 `eyJGaXgiOiJ0cnVlIn0=`, passed as `-PackageArguments`. Fix only enables the `Microsoft Compatibility Appraiser` and `Microsoft Compatibility Appraiser Exp` scheduled tasks when they are disabled, and starts one appraiser run without waiting when its data is stale. It never touches DiagTrack, update policy or pins, never reboots, and never starts an upgrade. A second run changes nothing. The runner still needs the toolkit and brand-pack parameters: it downloads and checks all three pins before it starts any package.

`windows/releases/feature-update.json` records the field name and the package arguments. The package hash is not stored in the repo; it goes in the runner's `-PackageSha256`.

## Windows Update policy

`windows/packages/wu-policy/Invoke-WuPolicy.ps1` finds local policy that turns automatic updates off. Run it through the deploy runner (NinjaOne script 374) as SYSTEM. By default it is read-only: it reports the values under `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate` and its `AU` subkey, the machine `Registry.pol` (size, date, entry count, and which of the values it holds), and the appraiser task state. It writes one line of compact JSON to the device field `relianWuPolicy` and prints the same line last on stdout.

Fix mode is off unless the package arguments are `{"Fix":"true"}`, base64 `eyJGaXgiOiJ0cnVlIn0=`. Fix acts only when `NoAutoUpdate` is 1, `AUOptions` is below 3, or `DisableWindowsUpdateAccess` is 1, and does nothing on a WSUS-managed device (`UseWUServer` 1 or `WUServer` set). It first exports the policy key and copies `Registry.pol` to `C:\relian\wu-policy-backup-<yyyyMMdd-HHmmss>`. It then deletes those values and `SetDisableUXWUAccess` when it is 1, and renames `Registry.pol` to `Registry.pol.bak-<stamp>` only when every entry in the file re-applies one of the values being deleted; a file with any other policy is left, because removing it can drop that policy too. Last it runs `gpupdate /target:computer /force` and reads the values again. A run where a value is still set exits 1. Target release, deferral, pause, `DisableOSUpgrade` and WSUS values are reported and left alone. It never reboots and never starts an upgrade. A second run changes nothing.

`windows/releases/wu-policy.json` records the field name and the package arguments. The package hash goes in the runner's `-PackageSha256`.

## Feature upgrade from a pinned ISO

`windows/packages/feature-upgrade/Invoke-FeatureUpgrade.ps1` upgrades Windows in place from an ISO named by the package arguments. Run it through the deploy runner (NinjaOne script 374) as SYSTEM. Nothing about a release is built in: the ISO's build is read from the mounted image (`install.wim`/`install.esd`, else `setup.exe`), so any Windows ISO works.

Package arguments, base64 of the JSON in `-PackageArguments`:

```json
{"IsoUrl":"https://example.com/Win11.iso","IsoSha256":"<64 hex>","BypassHardwareCheck":"false"}
```

`IsoUrl` must be https with no userinfo; `IsoSha256` must be 64 hex characters. A missing or malformed value exits 1 before anything is touched. `BypassHardwareCheck` is optional; `"true"` adds `/product server`, which skips setup's CPU, TPM and Secure Boot check.

One run takes the mutex `Global\RelianFeatureUpgrade`, reports any earlier attempt instead of starting another, stops if Windows already has a reboot pending, checks free space (ISO size plus 20 GB), and downloads the ISO to `%ProgramData%\Relian\FeatureUpgrade` with a streamed download that resumes from a `.part` file on the next run. A file whose SHA256 already matches is reused; a mismatch deletes the file and exits 1. It mounts the ISO to read the build and dismounts. At or below the running build it exits 0 with `alreadyCurrent`.

Setup runs detached, because it can outlast a NinjaOne job. The run copies the script into the working folder (owner and ACL reset to SYSTEM and Administrators) and starts it as the one-shot SYSTEM task `Relian Feature Upgrade` with `-Worker true`, then exits 0 with `started`. The worker checks the hash again, mounts the ISO, runs `setup.exe /auto upgrade /quiet /noreboot /eula accept /dynamicupdate disable /copylogs <dir>\logs` with `Start-Process -PassThru`, waits up to 6 hours for the real exit code, always dismounts, records the result in `state.json` and the field, and removes its task. It never reboots, and never touches security services, safe mode, Windows Update folders or IFEO.

Every run prints one JSON line last and writes it to the device field `relianFeatureUpgrade`. `status` is one of:

| status | meaning | exit |
| --- | --- | --- |
| `started` / `starting` | worker launched, not finished | 0 |
| `busy` | the worker or another run holds the mutex (setup running) | 0 |
| `staged` | setup returned 0, 3010 or 1641; the upgrade finishes at the next reboot | 0 |
| `finished` | rebooted onto the ISO's build | 0 |
| `alreadyCurrent` | the running build is at or above the ISO's | 0 |
| `rebootPending` | Windows has a servicing reboot pending; reboot first | 0 |
| `failed` | bad hash, low space, download error, or setup's exit code (`exitHex`, `setupErr`) | 1 |
| `rolledBack` | rebooted after staging but still on the old build | 1 |
| `interrupted` | the worker stopped without a result | 1 |

A `finished`, `failed`, `rolledBack` or `interrupted` result is reported once and cleared; the next run starts a new attempt and reuses the downloaded ISO. `Uninstall` exits 0 and changes nothing. `windows/releases/feature-upgrade.json` records the field and the argument shape.

## Restart notice

`windows/packages/restart-notice/Invoke-RestartNotice.ps1` restarts a device that is waiting for a restart and tells the signed-in user first. Run it through the deploy runner (NinjaOne script 374) as SYSTEM. It acts only when Windows servicing or Windows Update has a restart pending, or the feature-upgrade package left an upgrade `staged` that has not booted yet. Otherwise it writes `none` and exits 0.

When nobody is signed in it restarts at once, at any hour. The toolkit's session list decides who is signed in: a session counts when it has a person's account name and is not session 0, the Services session, or a listening placeholder. A user whose sessions are all disconnected gets the countdown without a notice, then the restart. The console user and `explorer.exe` owners are a cross-check: a person they name with no session of their own (a ghost session) means it cannot tell, and then it assumes someone is. If the toolkit still finds no user to show the notice to, a second check decides: nobody means `restartedNoUser` with reason `toolkitNoUser`; anyone else gets the countdown without a notice. Any other error writes `failed` and exits 1. A signed-in user sees a notice with `Restart now` and one snooze (60 minutes by default). The snooze is kept under `HKLM\SOFTWARE\Relian\RestartNotice`, used once and never extended, and cleared after the restart or when nothing is pending. A run during the snooze writes `snoozed` and does nothing else. If the notice gets no answer (10 minutes by default) or the snooze is used up, a 15-minute countdown with `Restart now` shows, then the device restarts with `shutdown /r /f /t 0`. `Restart now` on the countdown restarts at once: the countdown runs in its own toolkit client process, and when that process ends before the countdown does, the result is `restarted` with button `Restart now`. If the process list cannot be read, the countdown is waited out. Both dialogs get the same black brand accent as the user check: the user-check package's dialog theme, copied into this script, is loaded by the toolkit's client process in the user's session and paints the sidebar and accent colours black. Before enabling the theme, its generated assembly receives read/execute access for the active user sessions, including standard users. If compilation or permission repair fails, the original client configuration remains in place and the toolkit's own colours show. `ReportOnly` installs nothing.

The result goes to the device field `relianRestartNotice` before any restart: `none`, `snoozed`, `restarted`, `restartedNoUser`, `restartedAfterCountdown` (with `reason`) or `failed`, plus the button pressed and whether the snooze was used. Optional package arguments: `Message`, `SnoozeMinutes`, `PromptMinutes`, `CountdownMinutes`, `ReportOnly`; see `windows/releases/restart-notice.json`. A run can last the prompt time plus the countdown, so the NinjaOne script timeout must allow that. `Uninstall` exits 0 and changes nothing.

`ReportOnly` set to `true` runs the same detection and stops there: no notice, no snooze marker change, no restart. It writes one JSON line to the device field `relianSessionState`: `userPresent` (`present`, `disconnected`, `none` or `unknown`), `reason` (`none`, `console`, `rdp`, `disconnected` or `cannotTell`), the people counted, each user session (account, id, `console`/`rdp`, state such as `active` or `disconnected`, idle minutes when Windows reports them, `locked` always `unknown` because the toolkit does not report it), pending restart reasons, last boot, build, snooze state and a UTC timestamp. Use it instead of NinjaOne's logged-on-user data, which can name a user who is not there.

## Feature upgrade diagnostics

`windows/packages/diagnose-feature-upgrade/Invoke-DiagnoseFeatureUpgrade.ps1` collects read-only evidence through the deploy runner as SYSTEM. The optional package argument `Section` is `Summary` (default), `Rollback`, `Servicing`, `Setup` or `Boot`, for example `{"Section":"Servicing"}` base64-encoded in the runner arguments. Run sections separately. It prints JSON to stdout and does not write a custom field, change update state, scan Windows Update, start setup, change services, or restart the device. It can inspect a running upgrade worker.

Summary includes allowlisted feature-upgrade state, SetupDiag results (up to 2,000 characters per value), MoSetup progress, OS/boot/disk/hardware, and current setup process names/PIDs without command lines. Summary also includes system-volume BitLocker encryption, protection and lock status plus volume type. It requests only the three status properties from `Win32_EncryptableVolume` and calls the read-only `GetLockStatus` method, each with a five-second CIM timeout. It never enumerates key protectors or requests recovery passwords. Unavailable or unrecognized values are reported as unavailable/unknown, not as unencrypted or unprotected. Summary contains no logs, so the prior failure details and current upgrade state remain available. Rollback reads the two rollback logs; Servicing reads offline NewOS and host CBS/DISM; Setup reads Panther and MoSetup. Boot reads the flat and nested rollback `setupapi.dev.log` candidates and Windows `INF\setupapi.dev.log`, preserving first and last `!!!` error context. It reports rollback `setupmem.dmp` existence, size and modification time only, never dump contents. It includes up to eight newest System events from the last 72 hours: Kernel-Power 41, WER-SystemErrorReporting 1001 and EventLog 6008, with sanitized messages capped at 500 characters and a five-second CIM query timeout. These events can describe an unrelated restart; correlate timestamps with the upgrade attempt. Paths follow [Microsoft upgrade logs](https://learn.microsoft.com/en-us/windows/deployment/upgrade/log-files) and [upgrade resolution procedures](https://learn.microsoft.com/en-us/troubleshoot/windows-client/setup-upgrade-and-drivers/windows-10-upgrade-resolution-procedures). Every section includes current state and attempt identifiers before its logs. Each samples only its final 2 MiB, with file size and sampled bytes reported. It retains the latest lines and nearby context for `0x80070057`, `0x80070005`, `0x20003`, `KB5043080`, package-add and rollback failures, `ERROR_ACCESS_DENIED` and `STATUS_CANNOT_DELETE`. Both the first and last `0x80070005` occurrences in the sampled window retain nearby context so terminal summaries do not displace the first operation failure. Rollback outcome markers `Current phase`, `Current op`, `Current result`, `Setup360` and `PostRebootInstall` have separate match categories, so later diagnostic timeouts do not hide the upgrade result. History outside that window remains unavailable; a successful collection does not mean the upgrade succeeded.

Credential/command-line records are omitted, URLs and profile names are redacted, and serialized JSON output is limited to 8,000 UTF-8 bytes, below Ninja activity output truncation, with explicit truncation markers. Generic tails are removed before targeted matches are clipped. Oversized fields are shortened progressively while retaining state and error metadata; the collector never replaces the whole report with a content-free output-limit message. No new section starts after 40 seconds; CIM requests have five-second operation timeouts. Uninstall changes nothing.

## Pin records

`windows/releases/<name>.json` records the file that was hashed: the source URL, the file name, the sha256, the size, and the version. A device does not read that file. The runner downloads the package script and no other file from this repo, so the URL and the hash are copied into the script. The tests fail when the script and the JSON disagree.

`scripts/publish-relian-packs.ps1` reads `windows/releases/psadt.json`. `scripts/publish-teams.ps1` reads `windows/releases/teams.json`.

## Collectors

`windows/bootstrap.ps1` downloads one script from `windows/collectors/` and runs it. The collectors are `cpu-benchmark`, `hardware-inventory`, `network-audit`, and `storage-health`. They write inventory into NinjaOne fields.

## Layout

- `windows/runner/Invoke-RelianRunner.ps1` is the NinjaOne install script.
- `windows/packages/<name>/` is one application.
- `windows/releases/<name>.json` is that application's pin record.
- `windows/brand/` is the source of the Relian dialog pack.
- `windows/collectors/` and `windows/bootstrap.ps1` are the inventory path.
- `scripts/` holds the pin and publish tools.
- `tests/windows/` holds the PowerShell suite. `tests/` holds `run-all.ps1` and the reviewer unit tests.

## Storage and Windows Update maintenance

`windows/packages/storage-maintenance/Invoke-StorageMaintenance.ps1` reports disk usage, profile-age evidence and cleanup opportunities. Explicit Cleanup mode removes old temporary files; profile removal is separately enabled with a configurable inactivity threshold (60 days by default), protected-profile exclusions and fresh evidence checks. Windows servicing timestamps are not treated as user logins.

`windows/packages/update-maintenance/Invoke-UpdateMaintenance.ps1` reports update services, policy, OS lifecycle and servicing state. Explicit Repair mode recovers selected disabled services and verifies an update search; cache reset and DISM/SFC are separate options. Empty search results never mean the installed OS is necessarily current.

Both use the existing hash-pinned `Invoke-RelianRunner`, show Relian PSADT progress when a user session is available, keep protected local reports, and defer mutations during active/staged Setup or uncertain servicing state. Neither starts an upgrade or reboots. See [the maintenance runbook](docs/maintenance.md) for runner parameters, report interpretation and limits.
