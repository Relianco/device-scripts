# device-scripts

NinjaOne installs software by pasting `windows/runner/Invoke-RelianRunner.ps1`. That file is the installer. `windows/bootstrap.ps1` loads an inventory collector. It is not the installer.

## Deploy runner

The runner is `windows/runner/Invoke-RelianRunner.ps1`. Paste that file into NinjaOne. Each run passes the package script URL and `PackageSha256`, the toolkit URL and `ToolkitSha256`, and the brand pack URL and `BrandPackSha256`, plus `Action` and `PinVersion`. The package URL is one script under `windows/packages/`. An empty pin exits 0 and downloads nothing. There are three download attempts. A bad hash is not retried. Cancel exits 130. The toolkit and the brand pack are downloaded from `https://relianpub.blob.core.windows.net/pub/sec/`. bootstrap.ps1 remains the collector loader. It follows `main`, checks no file hash, and can put a git token in the download URL. `PackageArguments` is an optional base64 JSON object of extra package parameters. An empty value adds none. Invalid package arguments exit 1 and download nothing. An empty hash still exits 0 before those arguments are read.

`scripts/publish-relian-packs.ps1` prints the toolkit and brand-pack URLs and does not upload unless `-Publish` is set.

## Shell runners

`linux/runner/relian-runner.sh` is the Linux script to paste. It is not the macOS runner.

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

The Linux runner passes no package arguments, so the values come from NinjaOne script variables on the runner, which arrive as environment variables. `ClientTag` is required. The auth key is the `AuthKey` script variable when set. Otherwise the package reads the organization-level Secure custom field `tailscaleAuthKey` with `ninjarmm-cli get`. Set `AuthKeyField` to use another field name. The field needs automation read permission and can be read only while an automation runs. Its limit is 200 characters. The key is never on a command line. The package writes it to a mode 0600 file in a private temp directory, passes that path to `tailscale up`, and removes the file when the command finishes or the script exits. Use tagged, pre-approved, short-lived keys.

A node that is Running with exactly that tag gets `tailscale set` with the same preferences and exits 0. A node that is Stopped with that tag is brought up without a key. A node with any other tag, or joined without a tag, exits 1 and is not re-joined. A status that cannot be read on an installed node exits 1. Uninstall and Reinstall exit 1. An empty pin exits 0. The package does not change the Proxmox firewall, sshd, or anything else on the host. Those changes stay manual.

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
