# Deploy runner and Relian brand pack

Spec for the first Relian software-deploy runner. There is no separate spec document. This plan is the authority.

The runner lives in this public repo. PSAppDeployToolkit 4.1.8 and the Relian brand pack are published as content-addressed blobs. A NinjaOne copy of the runner downloads one package script from this repo and the two blobs, checks each SHA256, and runs the package. Client branding later is another brand zip and different pins. This version publishes only the Relian pack.

Do not push, do not open a pull request, and do not upload blobs. The controller does that after review.

## Global Constraints

- Do not modify `bootstrap.ps1` or anything under `collectors/`.
- The runner and the action-probe package do not call `Ninja-Property-Get`, `Ninja-Property-Set`, or any NinjaOne API.
- Do not read `relian_git_deploy_token`. If a download URL has userinfo (`scheme://user@host`), refuse it and exit 1 before any download.
- Do not run whatever is newest on `main`. The caller passes the package URL and its SHA256.
- If `PackageSha256`, `ToolkitSha256`, or `BrandPackSha256` is empty or whitespace, exit 0 and download nothing.
- Compare hashes case-insensitively. A mismatch exits 1 and does not run the package.
- Toolkit blob is the module-only zip, tag `4.1.8`:
  - URL `https://github.com/PSAppDeployToolkit/PSAppDeployToolkit/releases/download/4.1.8/PSAppDeployToolkit_ModuleOnly.zip`
  - GitHub digest `80b45fb8e518ee98774e16e44599d470e4069a0695a6a359022f954edaa83360`
  - Size `8791109`
  - Verify with `sha256sum` after download. If the file hash differs, stop with status BLOCKED. Do not commit the zip.
- Public blob base is `https://relianpub.blob.core.windows.net/pub/sec/`.
- Blob names are `PSAppDeployToolkit-4.1.8-<sha256>.zip` and `relian-brand-<sha256>.zip` inside container `pub`, virtual directory `sec`. Account `relianpub`. Auth is `az storage blob upload --auth-mode login`. Never put a key in a command.
- Brand pack zip entries, forward slashes, no wrapper folder:
  - `Config/config.psd1`
  - `Assets/AppIcon.png`
  - `Assets/AppIcon.Dark.png`
  - `Strings/en.psd1`
- Committed source tree for that zip is `brand/relian/` with those same relative paths.
- SVG sources are read only, not committed:
  - `/home/kverbr/Develop/Relian/web/www-rebased/layers/shared/public/images/logo/relian-logo-black.svg` sha256 `c521b7fefcef44f9d9eec85a0cade62ebe3701224fbff4ec54904618d27c9d12` size 2477. This becomes `Assets/AppIcon.png`, 256x256.
  - `/home/kverbr/Develop/Relian/web/www-rebased/layers/shared/public/images/logo/relian-logo-white.svg` sha256 `5891af78188b2d1480a2daf9c759d824fa016f625d7d295559cbae920a2217cc` size 2490. This becomes `Assets/AppIcon.Dark.png`, 256x256.
  - The build exits 1 when either hash differs.
- `Config/config.psd1` sets only these keys: `Assets.Logo = '..\Assets\AppIcon.png'`, `Assets.LogoDark = '..\Assets\AppIcon.Dark.png'`, `Toolkit.CompanyName = 'Relian'`, `UI.DialogStyle = 'Fluent'`. Do not set `FluentAccentColor`. Do not copy the rest of the module defaults.
- `Strings/en.psd1` is `@{ DeployNotice = 'Relian needs to update {AppName}. You can defer once. After that, the app will close and then start again.' }`. This is probe copy, not a confirmed Teams sentence.
- The shell is zsh. Never put command arguments in a scalar variable.
- Tests are plain `pwsh` scripts named `tests/*.Tests.ps1`. They exit 0 on success and 1 on failure. No Pester. No network in tests.
- `tests/run-all.ps1` runs every `tests/*.Tests.ps1` and exits 1 if any exit non-zero.
- Dot-source runtime scripts with `RELIAN_DEPLOY_TEST=1` so they define functions and do not start work.
- Commit with the repo's existing identity. No `Co-Authored-By` trailer.
- Do not edit files outside this repo except reading the two SVG paths above.

## Task 1: Brand pack

Create the Relian brand pack source, the build script, and tests.

Files:

- `brand/relian/Config/config.psd1`
- `brand/relian/Strings/en.psd1`
- `brand/relian/Assets/AppIcon.png`
- `brand/relian/Assets/AppIcon.Dark.png`
- `brand/build-relian-pack.ps1`
- `tests/brand-pack.Tests.ps1`
- `tests/run-all.ps1`
- `.gitignore` gains `brand/out/`

`brand/build-relian-pack.ps1` parameters:

- `-BlackSvg` default the black path in Global Constraints
- `-WhiteSvg` default the white path
- `-Destination` default `brand/relian` relative to the repo root (parent of `brand/`)
- `-OutZip` default `brand/out/relian-brand.zip`

Behavior:

1. Hash both SVGs. Exit 1 on mismatch with the digests in Global Constraints. Print the path and both digests. Do not print file contents.
2. Rasterize each SVG to a 256x256 PNG with `rsvg-convert -w 256 -h 256`. Write the PNGs into the destination Assets folder.
3. Write `config.psd1` and `en.psd1` as specified. Overwrite those two files so the pack cannot drift.
4. Create the zip with `System.IO.Compression.ZipFile`. Entry names are exactly the four paths in Global Constraints. No extra entries.
5. Print one line: `sha256 <lowercase hex> <zip path>`.

Tests, with copies of the SVGs under the test temp so the defaults are not required:

- Matching hashes and a run against temp SVGs produce a zip whose entry names are exactly those four, and both PNGs have IHDR width 256 and height 256. Read IHDR from the PNG bytes. Do not require System.Drawing.
- A one-byte change to the black SVG copy makes the build exit 1 and write no zip.
- `config.psd1` contains `Relian`, `AppIcon.Dark.png`, and `Fluent`, and does not contain `FluentAccentColor`.
- `run-all.ps1` returns this test's exit code.

TDD: write `tests/brand-pack.Tests.ps1` first and record a failing run, then implement.

Commit: `Add the Relian brand pack`.

## Task 2: Toolkit pin

Record the verified PSAppDeployToolkit 4.1.8 module zip. Do not commit the zip.

Files:

- `releases/psadt.json`
- `tests/psadt-pin.Tests.ps1`

Download the URL in Global Constraints to a temp file. Run `sha256sum` and `wc -c`. If either disagrees with the digest or the size, status BLOCKED and do not write the json.

`releases/psadt.json` is UTF-8 JSON with exactly these keys:

- `name`: `PSAppDeployToolkit`
- `version`: `4.1.8`
- `file`: `PSAppDeployToolkit_ModuleOnly.zip`
- `url`: the URL in Global Constraints
- `sha256`: the lowercase digest
- `size`: `8791109`

The test reads that file and asserts each value. It does not download.

Commit: `Pin PSAppDeployToolkit 4.1.8`.

## Task 3: Runner

Create the runner and its tests.

Files:

- `runner/Invoke-RelianRunner.ps1`
- `tests/runner.Tests.ps1`

Parameters, all strings, all mandatory except where noted:

- `PackageUrl`, `PackageSha256`
- `ToolkitUrl`, `ToolkitSha256`
- `BrandPackUrl`, `BrandPackSha256`
- `Action` with `ValidateSet('Install','Update','Repair','Reinstall','Uninstall')`
- `PinVersion`

When `RELIAN_DEPLOY_TEST=1` and the script is dot-sourced, define functions and return. Do not download.

Replaceable script-scoped defaults:

- `$script:DownloadFile` is `{ param($Url, $Destination) }` and uses `Invoke-WebRequest -UseBasicParsing -TimeoutSec 120`.
- `$script:ExpandArchive` expands a zip.
- `$script:InvokePackage` is `{ param($ScriptPath, $DeploymentType, $Action, $PinVersion, $WorkRoot) }` and runs the package script.

`Invoke-RelianRunner` returns an `[int]` exit code. The executed script exits with that code only when it is the entry script, not when dot-sourced.

Order:

1. Refuse any URL that contains userinfo. Exit 1. Do not call `DownloadFile`.
2. If any of the three SHA256 parameters is empty or whitespace, exit 0. Do not call `DownloadFile`.
3. Download the three files. A download failure exits 1.
4. Hash each file. A mismatch exits 1 and does not call `InvokePackage`.
5. Expand the toolkit and the brand pack into one work directory. The brand entries overlay the toolkit. `Config/config.psd1` from the brand pack is the file at `WorkRoot\Config\config.psd1`.
6. Copy the package script to `WorkRoot\Invoke-Package.ps1`.
7. Call `InvokePackage`. For `Reinstall`, call it twice: `DeploymentType` `Uninstall`, then `Install`, with `Action` `Reinstall` both times. If the first call returns non-zero, do not call the second. For `Update` and `Install`, `DeploymentType` is `Install`. `Repair` and `Uninstall` use those names.
8. Return the package exit code. Remove the work directory afterwards unless `RELIAN_DEPLOY_KEEP_WORK=1`.

Tests replace the three scriptblocks. They must assert:

- Empty `BrandPackSha256` returns 0 and `DownloadFile` is not called.
- A URL `https://user:token@github.com/Relianco/device-scripts` returns 1 and `DownloadFile` is not called.
- A hash mismatch returns 1 and `InvokePackage` is not called.
- Uppercase SHA256 matching the fixture returns 0 and `InvokePackage` is called once for `Install`.
- `Reinstall` calls `InvokePackage` twice, `Uninstall` then `Install`, and skips the second call when the first returns 1.
- The work directory contains `Config\config.psd1` whose text includes `Relian`, taken from the brand zip fixture, after a successful run with `RELIAN_DEPLOY_KEEP_WORK=1`. The test deletes that directory.

Commit: `Add the hash-pinned deploy runner`.

## Task 4: Action probe

Create the first package. It writes a version marker and a sentinel. It does not install software.

Files:

- `packages/action-probe/Invoke-ActionProbe.ps1`
- `tests/action-probe.Tests.ps1`

Dot-sourcing with `RELIAN_DEPLOY_TEST=1` defines `Invoke-ProbeAction` and does not import PSAppDeployToolkit.

`Invoke-ProbeAction` parameters:

- `Action` with the same set as the runner
- `PinVersion`, parsed with `[version]`. Unparseable returns exit 1 and writes nothing.
- `MarkerRoot`, a directory the function creates

Marker file: `MarkerRoot\marker.txt`, one line, the version. Sentinel file: `MarkerRoot\sentinel.txt`, contents `ok`. Toolkit log: `MarkerRoot\toolkit.log`, one deployment type per line.

Rules:

- `Install` and `Update` when the marker is missing or lower than the pin: write the pin, write the sentinel, append `Install`, exit 0.
- `Install` and `Update` when the marker equals the pin and the sentinel exists: exit 0, append nothing.
- `Install` and `Update` when the marker is greater than the pin: exit 0, leave both files, append nothing.
- `Repair` when the marker equals the pin and the sentinel is missing: write the sentinel, leave the marker, append `Repair`, exit 0.
- `Repair` when the marker equals the pin and the sentinel exists: exit 0, append nothing.
- `Repair` when the marker is missing: same result as `Install`.
- `Repair` when the marker exists and differs from the pin: exit 1, change nothing, append nothing.
- `Reinstall`: delete both files, then do `Install`. Append `Uninstall` and then `Install`. This still replaces a marker that is newer than the pin.
- `Uninstall` when either file exists: delete both, append `Uninstall`, exit 0.
- `Uninstall` when both are absent: exit 0, append nothing.

The file also contains the PSAppDeployToolkit 4.1.8 entry used when the script is executed rather than dot-sourced. Import the module from `$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1` with GUID `8c3c366b-8606-4576-9f2d-4051144f7ca2` and `ModuleVersion` `4.1.8`. Session values: `AppVendor` `Relian`, `AppName` `Action Probe`, `AppVersion` the pin, `AppProcessesToClose` an empty array, `RequireAdmin` `$true`, `DeployAppScriptVersion` `4.1.8`. `Install-ADTDeployment`, `Uninstall-ADTDeployment`, and `Repair-ADTDeployment` call `Invoke-ProbeAction`. Do not show a welcome dialog when the close list is empty. Do not set `DeferTimes`. Map a toolkit exit `1602` to process exit 1 without writing the marker. That mapping is a function `Convert-ProbeExit` tested directly: `1602` becomes `1`, `0` stays `0`.

Tests cover every rule above, including a newer marker left in place by `Update` and replaced by `Reinstall`, and `Convert-ProbeExit`.

Commit: `Add the action-probe package`.

## Task 5: Publisher

Add a dry-run publisher and a short README section.

Files:

- `scripts/publish-relian-packs.ps1`
- `tests/publish.Tests.ps1`
- `README.md` gains a `Deploy runner` section. Do not remove the existing title and description.

Parameters:

- `-Publish` switch, default off
- `-BrandRoot` default `brand/relian`
- `-ToolkitRecord` default `releases/psadt.json`

Dry run prints two blob URLs and does not invoke `az`. The brand URL uses the sha256 of a zip built the same way as Task 1. The toolkit URL uses `releases/psadt.json`.

`-Publish` runs `az` with arguments as an array: `storage`, `blob`, `upload`, `--auth-mode`, `login`, `--account-name`, `relianpub`, `-c`, `pub`, `-n`, `sec/<blob file name>`, `-f`, `<local file>`, `--no-progress`, `-o`, `none`. One upload per blob. If the blob already exists, skip the upload. Existence is `az storage blob exists` with the same account, auth, container, and name, `--query`, `exists`, `-o`, `tsv`.

The test replaces the az invoker. Without `-Publish`, the invoker is not called. With `-Publish`, the recorded argument list contains `--auth-mode` and `login`, and does not contain a connection string or an account key.

README `Deploy runner` says, in this order: the runner file path, the three pins and that an empty pin exits 0, the three download attempts and that a bad hash is not retried, cancel exit 130, the blob base URL, and that `bootstrap.ps1` remains the collector loader.

Commit: `Add the pack publisher`.

## Task 6: Retries and cancel

Add download retries and a cancel check to `runner/Invoke-RelianRunner.ps1`. Extend `tests/runner.Tests.ps1`. Do not retry the package, and do not call NinjaOne.

Download attempts: 3. The first retry waits 5 seconds and the second waits 20. Tests set `$script:RetryDelay` to a scriptblock `{ param($Seconds) }` that records the seconds and does not sleep. The default delay uses `Start-Sleep -Seconds`.

Retry only when `DownloadFile` throws, or returns and the file is missing, and the failure is transient:

- A timeout, a connection failure, or a DNS failure.
- HTTP status 408, 429, 500, 502, 503, or 504.

Do not retry HTTP 401, 403, or 404. Do not retry a hash mismatch. Do not retry a URL that contains userinfo. An empty SHA256 still exits 0 before any download. After 3 transient failures, exit 1. The error text does not include the URL.

Cancel:

- Optional parameter `CancelPath`. Also honor environment variable `RELIAN_DEPLOY_CANCEL=1`.
- Check before each download attempt and during each retry wait. The replaceable check is `$script:TestCancel`. The default returns true when the environment variable is `1` or when `CancelPath` is a path that exists.
- If cancel is set before `InvokePackage`, delete the temp files and return 130. Do not call `InvokePackage`.
- If the first reinstall call has returned 0 and cancel is then set, do not make the second call. Return 130.
- Do not stop a package process that has already started.

Tests:

- The first two download calls throw a transient error and the third writes the fixture. `InvokePackage` runs once. The recorded delays are 5 then 20 when the test delay is not replaced... The test replaces the delay, so it asserts the requested seconds were 5 then 20 and that the replacement was used.
- A hash mismatch is one download and no retry.
- HTTP 404 is one attempt and exit 1.
- `RELIAN_DEPLOY_CANCEL=1` before the run returns 130 and does not call `DownloadFile`.
- Cancel that becomes true after the first reinstall `InvokePackage` returns skips the install call and returns 130.

Commit: `Retry transient downloads and honor cancel`.

## Controller after Task 6

Upload is a separate controller step. Pushing the branch is a separate controller step. Neither is an implementer task.
