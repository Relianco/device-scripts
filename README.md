# device-scripts

NinjaOne installs software by pasting `runner/Invoke-RelianRunner.ps1`. That file is the installer. `bootstrap.ps1` loads an inventory collector. It is not the installer.

## Deploy runner

The runner is `runner/Invoke-RelianRunner.ps1`. Paste that file into NinjaOne. Each run passes the package script URL and `PackageSha256`, the toolkit URL and `ToolkitSha256`, and the brand pack URL and `BrandPackSha256`, plus `Action` and `PinVersion`. The package URL is one script under `packages/`. An empty pin exits 0 and downloads nothing. There are three download attempts. A bad hash is not retried. Cancel exits 130. The toolkit and the brand pack are downloaded from `https://relianpub.blob.core.windows.net/pub/sec/`. bootstrap.ps1 remains the collector loader. It follows `main`, checks no file hash, and can put a git token in the download URL.

`scripts/publish-relian-packs.ps1` prints the toolkit and brand-pack URLs and does not upload unless `-Publish` is set.

## Pin records

`releases/<name>.json` records the file that was hashed: the source URL, the file name, the sha256, the size, and the version. A device does not read that file. The runner downloads the package script and no other file from this repo, so the URL and the hash are copied into the script. The tests fail when the script and the JSON disagree.

`scripts/publish-relian-packs.ps1` reads `releases/psadt.json`. `scripts/publish-teams.ps1` reads `releases/teams.json`.

## Collectors

`bootstrap.ps1` downloads one script from `collectors/` and runs it. The collectors are `cpu-benchmark`, `hardware-inventory`, `network-audit`, and `storage-health`. They write inventory into NinjaOne fields.

## Layout

- `runner/Invoke-RelianRunner.ps1` is the NinjaOne install script.
- `packages/<name>/` is one application.
- `releases/<name>.json` is that application's pin record.
- `brand/` is the source of the Relian dialog pack.
- `collectors/` and `bootstrap.ps1` are the inventory path.
- `scripts/` holds the pin and publish tools.
- `tests/` holds the PowerShell suite and the reviewer unit tests.
