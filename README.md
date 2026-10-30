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

## Windows Desktop Optimization Tool

`windows/packages/wdot/Invoke-Wdot.ps1` is the NinjaOne script "Virtual Desktop Optimization" for Azure Virtual Desktop session hosts. It is a VDI tool: it disables services, tasks, and visual effects that a physical PC needs, so do not run it on physical workstations. Paste it in place of the old VDOT script. It runs as SYSTEM on Windows PowerShell 5.1. Its one script variable is the checkbox "Keep Outlook" (`keepOutlook`). Checked, it keeps the retired Mail and Calendar app. The new Outlook is always kept.

The script downloads one zip from `https://relianpub.blob.core.windows.net/pub/rmm/wdot/` and checks its sha256 before it expands anything. A mismatch exits 1. The zip is Microsoft's Windows Desktop Optimization Tool (WDOT) at the commit in `windows/releases/wdot.json`, plus `windows/packages/wdot/profile/` as the profile `Configurations/Relian`. The script runs `Windows_Optimization.ps1 -ConfigProfile Relian -Optimizations All -AcceptEULA` in a child process. It works in a new folder under `%ProgramData%` that only SYSTEM and Administrators can write, and removes the folder afterwards. WDOT's DiskCleanup empties `C:\Windows\Temp`, so the work folder is not there.

Before WDOT runs, the script removes VDOT's event log, `Virtual Desktop Optimization`. VDOT registered the event sources `WindowsMediaPlayer`, `AppxPackages`, and others to that log. WDOT registers the same names to its own log and exits 1 when they are taken, so without this step WDOT fails on every device that ran VDOT. The download gets three attempts for a failure with no HTTP status and for HTTP 408, 429, 500, 502, 503, and 504. An empty `ZipSha256` exits 0 and downloads nothing. Under the deploy runner, `Uninstall` exits 1: WDOT changes are not reversible.

The profile does not disable the Microsoft Compatibility Appraiser tasks. They refresh the upgrade-compatibility data that Windows Update uses to offer feature updates. After WDOT, the script turns both tasks back on where the old VDOT run had turned them off. `tests/windows/wdot.Tests.ps1` fails if the profile ever disables either task, or a service Windows Update needs.

WDOT ships its own profiles opt-in: every task, service, and app is `Skip`. The Relian profile instead applies what the old VDOT run applied: the same tasks, services, policy values, default-user settings, and app removals, minus the two appraiser tasks, and minus the Copilot app, the Microsoft 365 Copilot app (`Microsoft.MicrosoftOfficeHub`), and the new Outlook, which session-host users now use. Teams, OneDrive, and Edge are never removed. The tests fail if any of those is removed. A setting that is new in WDOT is `Skip`. Five policy values that WDOT renamed from `Enabled` to `Apply` are named `Enabled` again, and two app names that could never match a package are corrected. Five DWORD entries with an empty value (`NoInternetOpenWith`, `NoBalloonFeatureAdvertisements`, `NoInstrumentation`) are `Skip`: WDOT writes an empty DWORD as 0, which is the same as not configured.

`-Optimizations All` includes DiskCleanup, as the old run did. DiskCleanup deletes every `*.log`, `*.tmp`, `*.dmp`, `*.etl`, `*.evtx`, and `thumbcache*.db` file it can on `C:\`, including in user profiles, and empties every recycle bin. Replace `All` in `Get-WdotArgument` with the other categories to stop that.

To change the profile, edit `windows/packages/wdot/profile/`, then run `pwsh -NoProfile -File scripts/build-wdot.ps1`. It prints the zip path, the sha256, and the blob name. Upload with `az storage blob upload --account-name relianpub --container-name pub --name <blob> --file <zip> --content-type application/zip --auth-mode login --overwrite false`, then put the URL, file, sha256, and size in `windows/releases/wdot.json` and the script defaults. Never overwrite or delete a published blob: a pasted script may still use it.

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
