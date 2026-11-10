# device-scripts

Public scripts that a managed device downloads and runs without a login. A technician pastes one small script into NinjaOne. That script downloads a second script, checks its SHA256, and runs it.

This repo is public. It holds no client name, device id, token, password, or home-directory path. A package that needs a secret reads it from an environment variable that its caller sets on the device. No package reads a NinjaOne field.

## Pick your reader

- **Technician:** go to [Which script do I paste?](#which-script-do-i-paste) and then your platform.
- **Developer:** go to [Add a package](#add-a-package) and [Tests](#tests).
- **Security reviewer:** go to [What runs as SYSTEM](#what-runs-as-system).

## Which script do I paste?

People confuse these. Each one does a different job.

- **Install, repair or diagnose on Windows:** paste `windows/runner/Invoke-RelianRunner.ps1`. It runs one package.
- **A recurring fix on a schedule, on Windows:** paste `windows/runner/Invoke-RelianJob.ps1`. It runs one job module.
- **Inventory on Windows:** paste `windows/bootstrap.ps1`. It runs one collector. It is not an installer.
- **Linux:** paste `linux/runner/relian-runner.sh`.
- **macOS:** paste `macos/runner/relian-runner.sh`.

The two shell runners do not source each other. Each is a complete file.

## How the runner model works

The same rules hold on every platform. The runner never runs code it has not hashed.

1. You give the runner a package URL and the SHA256 of that file.
2. The runner downloads the file and compares the hash.
3. It runs the file only when the hash matches.

Rules:

- **Empty hash:** the run exits 0 and downloads nothing. This is the off switch for a deployment. A URL with userinfo is refused first, even with an empty hash.
- **Hash mismatch:** the run exits 1 and does not retry.
- **URL with userinfo** (`https://user@host`, including an empty name `https://@host`): the run exits 1 before any download. All four entry points check this first, even when the hash is empty: the credential is already in the job's parameters, which NinjaOne keeps in its activity history. Inside a package, an empty pin still exits 0 before the installer URL is read.
- **Retries:** three attempts, for a timeout, a connection or DNS failure, or HTTP 408, 429, 500, 502, 503, or 504. Any other HTTP status gets one attempt.
- **Pin a commit, not a branch.** A branch moves, and the hash then fails.
- **Get the hash** with `git show <commit>:<path> | sha256sum`.

### Package arguments

Some packages take extra values. Both the Windows runner and the Linux runner pass them as base64, because NinjaOne rejects these characters in the Parameters box: `& | ; $ > < \` !`. Base64 uses none of them.

- **Windows:** `-PackageArguments` is base64 of a JSON object. Every value is a string. Make it with `printf '%s' '{"Section":"Summary"}' | base64 -w0`.
- **Linux:** `--package-arguments-b64` is base64 of `Name=Value` lines.
- **macOS:** the runner takes no package arguments.

Invalid arguments exit 1 and download nothing. An empty hash still exits 0 before the arguments are read.

## Windows

All Windows paths start with `windows/`. Run every script below as **System** in NinjaOne. Windows PowerShell 5.1 is the floor.

### Install, repair or diagnose: Invoke-RelianRunner

**When:** you want one package run on a device, with a progress dialog for the signed-in user.

**Paste:** put `windows/runner/Invoke-RelianRunner.ps1` in the NinjaOne script library. Set **Run As** to System.

**Parameters** (all required except the last two):

- `-PackageUrl` and `-PackageSha256`: the package script and its hash.
- `-ToolkitUrl` and `-ToolkitSha256`: the PSAppDeployToolkit 4.1.8 zip and its hash.
- `-BrandPackUrl` and `-BrandPackSha256`: the Relian dialog pack zip and its hash.
- `-Action`: `Install`, `Update`, `Repair`, `Reinstall`, or `Uninstall`. `Reinstall` runs an uninstall and then an install.
- `-PinVersion`: a version, or another pin the package defines. A package that does not use the pin accepts any version text, such as `1.0.0`.
- `-CancelPath`: optional. A file path. If the file exists, the run exits 130. The environment variable `RELIAN_DEPLOY_CANCEL=1` does the same.
- `-PackageArguments`: optional. Base64 JSON, described above.

The toolkit and the brand pack come from `https://relianpub.blob.core.windows.net/pub/sec/`. Run `scripts/publish-relian-packs.ps1` to print their URLs. The file name in each URL ends with the file's SHA256, so the hash is the part before `.zip`. It uploads nothing unless you pass `-Publish`. The toolkit pin is in `windows/releases/psadt.json`.

**Exit codes:** 0 success or empty hash, 1 failure, 130 cancelled. A toolkit deferral (1602) is reported as 1.

**Example.** Run `gpo-evidence`, Summary section, on a domain controller. Replace each placeholder with the real value.

```
-PackageUrl "https://raw.githubusercontent.com/Relianco/device-scripts/<commit>/windows/packages/gpo-evidence/Invoke-GpoEvidence.ps1" -PackageSha256 "<package-sha256>" -ToolkitUrl "<toolkit-url>" -ToolkitSha256 "<toolkit-sha256>" -BrandPackUrl "<brand-pack-url>" -BrandPackSha256 "<brand-pack-sha256>" -Action "Install" -PinVersion "1.0.0" -PackageArguments "eyJTZWN0aW9uIjoiU3VtbWFyeSJ9"
```

The base64 string above is `{"Section":"Summary"}`. Most read-only packages use `-Action "Install"` to mean "run now". `Uninstall` on a read-only package changes nothing.

### Recurring jobs: Invoke-RelianJob

**When:** a fix must run every few hours. The runner downloads an 8.8 MB toolkit each run, so it is too heavy for a schedule. The job loader has no toolkit and no dialog. It downloads one module once, caches it, and then uses no network.

**Paste:** put `windows/runner/Invoke-RelianJob.ps1` in the NinjaOne script library. Set **Run As** to System. It does not work as Current user, because only SYSTEM can write to the cache.

**Parameters:**

- `-ModuleUrl`: the module script, at a commit.
- `-ModuleSha256`: its hash, 64 lowercase hex characters.
- `-ReportOnly`: optional switch. Detect and change nothing.

**Example.** Run `scansnap-update-prompts` in report-only mode:

```
-ModuleUrl "https://raw.githubusercontent.com/Relianco/device-scripts/<commit>/windows/jobs/scansnap-update-prompts.ps1" -ModuleSha256 "<module-sha256>" -ReportOnly
```

Drop `-ReportOnly` to let the job fix the drift.

**Schedule:** in the NinjaOne policy, add an "Every N hours" row (not under 1 hour), an "On System Startup" row, and an "On User Login" row for laptops. Each row carries the same Parameters.

**Version bump:** commit the module, hash it, and edit the URL and hash in every row. A row you have not edited keeps running its cached version.

**Cache:** `%ProgramData%\Relian\Jobs\<sha256>.ps1`. Its ACL allows SYSTEM only. Every run checks the ACL and the hash again, and runs the bytes it hashed, in process. A wrong ACL or a failed hash refuses the run and leaves the cache in place.

**Also refused, exit 1:** a URL that is not `https`, a missing parameter, a hash that is not 64 lowercase hex characters, and Constrained Language Mode.

**A module** prints one JSON line of at most 1024 characters and ends with `exit`:

- Status `compliant`: healthy, nothing changed. Exit 0.
- Status `fixed`: drift fixed and a second check passed. Exit 0.
- Status `drift`: `-ReportOnly` found drift. Exit 1.
- Status `failed`: could not read, could not fix, or still wrong after the fix. Exit 2.

**Limits:**

- NinjaOne does not replay a schedule missed while a device is off. The startup and login rows narrow the gap.
- A row set to Current user is skipped and reported as success. Do not use one.
- A failing job shows as FAILURE in activity rows and raises no alert.

### Inventory: bootstrap.ps1 and collectors

**When:** you want hardware, network, or storage inventory written to NinjaOne fields.

`windows/bootstrap.ps1` downloads one collector from `windows/collectors/` and runs it. It follows a branch (default `main`) and checks no hash. It can read an optional git token from the org custom field `relian_git_deploy_token`. It is the only script here that does. Do not use it to install software.

Parameter: `-ScriptName`, the collector path without the extension.

```
-ScriptName "windows/collectors/hardware-inventory"
```

Collectors: `cpu-benchmark`, `hardware-inventory`, `network-audit`, `storage-health`.

### TLS

Windows PowerShell 5.1 on an older host (Server 2016) defaults to TLS 1.0 and 1.1, and Azure Storage refuses those. Every script that downloads adds TLS 1.2 to the session when the host offers neither TLS 1.2 nor TLS 1.3. A host on the system default, or one that already offers TLS 1.2 or 1.3, is left alone, so modern hosts keep TLS 1.3. The change lasts for the process and writes nothing to the registry.

### Packages

One folder per package under `windows/packages/`. Each is a single script. In the lists below, "read-only" means the package changes nothing on the device.

**Applications.** Each downloads a hash-pinned installer from the vendor. The pin is in the script and in `windows/releases/<name>.json`.

- `7-zip`: installs 7-Zip.
- `acrobat`: installs Adobe Acrobat. Parameter `Edition` picks the edition.
- `adobe-reader`: installs Adobe Acrobat Reader.
- `autoelevate`: installs the AutoElevate agent.
- `chrome`: installs Google Chrome.
- `edge`: installs Microsoft Edge.
- `everything`: installs Everything, the file search tool.
- `firefox`: installs Mozilla Firefox.
- `git`: installs Git for Windows.
- `microsoft-365`: installs Microsoft 365 Apps with the Office Deployment Tool and a pinned `configuration.xml`. The Office payloads download at install time and are not pinned.
- `notepadpp`: installs Notepad++.
- `putty`: installs PuTTY.
- `quicklook`: installs QuickLook.
- `sysmon`: installs Sysmon.
- `tailscale`: installs the Tailscale client and joins it with a tag. `ClientTag` comes in package arguments. The auth key never goes on a command line. It comes only from the `AuthKey` environment variable, which the caller sets before it starts the runner. The package reads no NinjaOne field.
- `teams`: installs Microsoft Teams from a pinned bootstrapper and MSIX.
- `thin-manager`: adds or removes one Startup shortcut. It installs nothing.
- `vlc`: installs VLC.
- `wazuh`: installs the Wazuh agent.
- `winget`: installs Microsoft App Installer (winget). It does not install other apps.
- `zoom`: installs Zoom.
- `browser-extension`: sets browser policy to force-install one extension in Chrome, Edge, Brave, or Firefox. The pin is `<browser>-<extension id>`. It does not download the extension.
- `printer-tcp`: adds a TCP/IP printer. Parameters `PrinterName`, `PrinterAddress`, and `PrinterModel`. Two driver models are built in: Brother HL-L2370DW and KONICA MINOLTA Universal PCL. Empty values exit 0.
- `user-check`: installs nothing. It shows a dialog that asks the person for a code, or opens Microsoft sign-in. The pin is the code, or `microsoft-sign-in`.

**Windows maintenance.** These change the device only when you ask.

- `storage-maintenance`: reports disk use and cleanup candidates. `Mode` is `Report` (default) or `Cleanup`. Profile removal is a separate opt-in. It never reboots.
- `update-maintenance`: reports update services, policy, and servicing state. `Mode` is `Report` (default) or `Repair`. It never reboots and never starts Setup.
- `feature-update`: read-only check of why Windows Update has not offered the next feature update. `Fix` set to `true` repairs only the compatibility appraiser task.
- `feature-upgrade`: runs an in-place Windows upgrade from a pinned ISO (`IsoUrl`, `IsoSha256`). Setup runs detached as a scheduled task, so the job returns quickly. It changes the device.
- `restart-notice`: restarts a device that has a restart pending, after a notice to the signed-in user. `ReportOnly` set to `true` reports who is signed in and restarts nothing.
- `outlook-autocomplete`: counts, and with `Fix` set to `true` removes, matching rows in Classic Outlook autocomplete caches. It is read-only by default.

**Diagnostics and evidence.** All read-only. Each prints bounded JSON.

- `diagnose-feature-upgrade`: evidence for a failed or running feature upgrade. `Section` is `Summary` (default), `Rollback`, `Servicing`, `Setup`, `Boot`, or `Maintenance`.
- `maintenance-evidence`: reads back the stored reports of the two maintenance packages in pages.
- `gpo-evidence`: Group Policy state for a domain, at most 8,000 bytes of JSON. `Section` is `Summary` (default), `Gpos`, `Policy`, or `Rsop`. `Gpo` selects one GPO. A `cpassword` is counted and never printed.
- `action-probe`: a test package. It writes a marker file under `%ProgramData%\Relian\action-probe` so you can prove the runner passed the right action and pin.

**Policy and configuration.** These change settings.

- `gpo-baseline`: applies an embedded Group Policy definition on the PDC emulator. Plan-only unless `Apply` is `true`. It backs up an existing GPO first. Definitions: `cis-ws2022-dc-low-risk` and `comet-vss-provider-qemu`.
- `wu-policy`: finds local policy values that turn off automatic Windows Update. `Fix` set to `true` removes them, after a backup. It does nothing on a WSUS-managed device.
- `apply-action`: applies one registry action from `windows/actions/<id>.json`. The pin is `<id>:<sha256 of that file>`.
- `msi-repair`: repairs one installed Windows Installer product machine-wide (`msiexec /f`). Give `ProductCode` or an exact `DisplayName`. `RepairMode` is `/fa` (default) or `/fomus`. It refuses when the cached MSI is missing unless `SourcePath` is an MSI with the same ProductCode. `Section` set to `Evidence` is read-only. It downloads nothing.
- `comet-vss-provider`: keeps `COMET_FORCE_VSS_PROVIDER=system` in Comet Backup's service environment on QEMU guests. `Section` set to `Evidence` is read-only. See [the runbook](docs/comet-vss-provider.md).
- `wireguard-network-guard`: stops WireGuard tunnel services on a trusted office network and starts them when the laptop leaves. `Check` is read-only. See [the runbook](docs/wireguard-network-guard.md).

**Actions** for `apply-action` are in `windows/actions/`: `avd-logon-timeouts`, `azure-ad-sso-zone`, `cloud-kerberos-ticket`, `edge-startup-boost-off`, `fast-startup-off`, `fslogix-cleanup-invalid-sessions`, `fslogix-no-roam-recycle-bin`, `long-paths`, `mapped-drive-reconnect`, `onedrive-dehydrate-team-sites`, and `teams-avd-media`. Each sets one or a few registry values.

### Jobs

One module per file under `windows/jobs/`.

- `scansnap-update-prompts`: stops ScanSnap Online Update from prompting staff who cannot install updates. It marks the watcher's startup entry disabled and stops a running watcher. A machine without ScanSnap reports `compliant`.

### Pin records

`windows/releases/<name>.json` records what was hashed: source URL, file name, SHA256, size, and version. A device never reads it. The runner downloads the package script and nothing else from this repo, so the URL and hash are copied into the script. Tests fail when the script and the JSON disagree.

### Maintenance runbook

`docs/maintenance.md` covers runner parameters and report interpretation for storage and update maintenance.

## Linux

**Paste:** put `linux/runner/relian-runner.sh` in the NinjaOne script library as a shell script. Run it as root. It downloads one package script, checks its hash, and runs it.

**Parameters** (all but the last are required):

- `--package-url` and `--package-sha256`
- `--action`: `Install`, `Update`, `Repair`, `Reinstall`, or `Uninstall`
- `--pin-version`
- `--package-arguments-b64`: optional. Base64 of `Name=Value` lines, at most 4,096 bytes. A name must start with a letter. The runner refuses names that change how a process runs, such as `PATH` or anything starting `LD_`. The values reach the package as environment variables. They are not secret, because they sit on the command line.

An unknown parameter, or a missing one, exits 1. The runner prints no trace, so the arguments do not reach the log.

**Example.** Install Tailscale with a client tag:

```
--package-url "https://raw.githubusercontent.com/Relianco/device-scripts/<commit>/linux/packages/tailscale/tailscale.sh" --package-sha256 "<package-sha256>" --action "Install" --pin-version "1.104.4" --package-arguments-b64 "Q2xpZW50VGFnPXRhZzpjbGllbnQtZXhhbXBsZQ=="
```

That base64 string is `ClientTag=tag:client-example`. Set the auth key in the `AuthKey` environment variable of the runner process. Do not put it in package arguments: they are kept in the job's activity history.

Packages in `linux/packages/`:

- `tailscale`: installs Tailscale from the signed apt repo on Debian and Proxmox VE (bookworm and trixie) and joins it with a tag. The pin version is a floor. It must run as root. It never changes the firewall, sshd, or Proxmox config. The key is read from a `0600` file, not a command line.
- `diagnose-pve`: read-only diagnostics for Proxmox VE and Debian hosts. It prints plain text: host, kernel, uptime, load, CPU, memory pressure, swap, ZFS ARC, block devices, file systems, RAID, ZFS and LVM state, and disk activity sampled twice (`Sample`, 1 to 10 seconds, default 5). Every command runs under `timeout`. It writes nothing, and exits 0 even when a command is missing.
- `noop`: installs nothing and exits 0. Use it to prove that the runner, the hash pin, and the NinjaOne wiring work on a host before a real package.

Pin records are in `linux/releases/<name>.json`.

## macOS

**Paste:** put `macos/runner/relian-runner.sh` in the NinjaOne script library as a shell script. Run it as root. It follows the same rules as the Linux runner, with two differences: it takes no `--package-arguments-b64`, and it hashes with `shasum -a 256`.

**Parameters** (all required): `--package-url`, `--package-sha256`, `--action`, `--pin-version`.

**Example.** Prove the wiring with the `noop` package:

```
--package-url "https://raw.githubusercontent.com/Relianco/device-scripts/<commit>/macos/packages/noop/noop.sh" --package-sha256 "<package-sha256>" --action "Install" --pin-version "1.0.0"
```

Packages in `macos/packages/`:

- `noop`: installs nothing and exits 0. It exists to test the runner.

Pin records are in `macos/releases/<name>.json`.

## What runs as SYSTEM

For a security reviewer. This is what a pasted script can and cannot do.

- **The two PowerShell loaders** (`Invoke-RelianRunner`, `Invoke-RelianJob`) download only the files you pin. They check each SHA256 before they run anything.
- **The job loader** runs a module in process from the bytes it hashed. Its cache directory is SYSTEM-only, and it re-checks the owner, the ACL, and the hash on every run.
- **`windows/bootstrap.ps1` is the exception.** It follows a branch, checks no hash, and may read a git token. It runs inventory collectors only. Do not use it to install anything.
- **Neither runner calls the NinjaOne API.** Packages read and write no NinjaOne field: they report one JSON line on stdout and an exit code. `tailscale` takes its auth key only from the `AuthKey` environment variable, on Windows and Linux. No package reads `relian_git_deploy_token`.
- **Read-only packages** are tested for it. The tests scan their source for write commands, or run them against stubs.
- **Changing packages** say so in their header: what they change, what they back up first, and what they never do (reboot, start Setup, change firewall rules).
- **Hash pins and the repo.** A pin names exact bytes. Moving `main` cannot change what a pinned device runs.
- **Secrets.** A secret scan runs before push and in CI. No secret belongs in a command, a commit, or a PR.
- **Never installed by CI.** CI runs the tests. It does not install an application.

## Add a package

Layout for Windows, one folder per package:

```
windows/packages/<name>/Invoke-<Name>.ps1
windows/releases/<name>.json
tests/windows/<name>-plan.Tests.ps1
```

Application packages also carry `Detect-<Name>.ps1` and `intune.json`, so Intune can deploy them. Detect exits 0 when the app is present. `intune.json` holds the install and uninstall command lines.

Rules for a package script:

1. **The runner copies the script alone.** Inline every URL, hash, and setting. Do not read a sibling file.
2. **Parameters are not `Mandatory`.** A mandatory parameter prompts when a test dot-sources the file. Take `DeploymentType`, `Action`, `PinVersion`, and your own names as plain strings.
3. **Check the hash before you run a download.** Exit 1 on a mismatch, and do not retry. Exit 1 on a URL with userinfo. If the script downloads, carry the TLS guard line that the other packages carry.
4. **Do not call NinjaOne.** Report through stdout and the exit code. `tests/windows/ninja-agnostic.Tests.ps1` fails on a custom-field read or write, `ninjarmm-cli`, the NinjaOne API, or the deploy token.
5. **Keep it Windows PowerShell 5.1 compatible.**
6. **Keep PowerShell output bounded.** NinjaOne truncates long output. Print one JSON line.

For Linux and macOS, add `<platform>/packages/<name>/<name>.sh` and `<platform>/releases/<name>.json`. The JSON records the file name and its SHA256.

Then add the package to this README, in its platform section, as a list item that starts with the folder name in backticks. A test fails when you do not.

## Tests

Tests are plain scripts. There is no Pester, and no test uses the network.

```
pwsh -NoProfile -File tests/run-all.ps1
bash tests/linux/run-tests.sh
bash tests/macos/run-tests.sh
node --test tests/ai-pr-review.test.mjs tests/secret-scan.test.mjs
scripts/scan-secrets.sh
```

- `tests/run-all.ps1` runs every `tests/windows/*.Tests.ps1` and every `tests/*.Tests.ps1`. A test exits non-zero to fail.
- `tests/windows/` holds the PowerShell tests.
- `tests/readme-inventory.Tests.ps1` fails when a package or job folder on any platform is missing from this README, or when the README lists one that does not exist.
- `tests/linux/` and `tests/macos/` hold the shell tests. Each `run-tests.sh` runs the platform's test files in order.
- The Node tests cover the review script and the secret scan.

To test a PowerShell script, set `RELIAN_DEPLOY_TEST=1` and dot-source it. The script then defines its functions and runs nothing. Write the failing test first, then the code.

## CI

Three workflows run on a pull request:

- **PR verify** (`.github/workflows/pr-verify.yml`). On Ubuntu: the PowerShell suite, the reviewer unit tests, the Linux runner tests, and the macOS runner tests. On `windows-2022`: the maintenance, job loader, and ScanSnap tests, which need real NTFS ACLs, and the Comet test under Windows PowerShell 5.1.
- **Secret scan** (`.github/workflows/secret-scan.yml`). betterleaks scans the commits in the pull request, with a pinned binary. It uses the policy in `.betterleaks.toml` from the base commit, so a pull request cannot weaken it.
- **AI PR review** (`.github/workflows/ai-pr-review.yml`). A model reads each changed file and posts one review. It starts with `LGTM` when it finds nothing to fix. It reads at most 20 files, so keep each pull request under 20 changed files. When it cannot read every file, it posts "AI review incomplete", and that is not an approval. A push that changes only docs skips a new review.

## Contribute

1. Once per clone: `git config core.hooksPath .githooks`. The pre-push hook scans the commits you push with betterleaks. CI is the hard gate.
2. Branch from `origin/main`. New work is a pull request into `main`. Do not force-push `main`.
3. Commit as `Relian Technologies <112814130+Relianco@users.noreply.github.com>`.
4. Keep client names, device ids, tokens, and home-directory paths out of every file and every PR text.
5. Stage files by name. Do not run an installer on a device unless the maintainer asks.
