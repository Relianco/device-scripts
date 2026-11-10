# AutoElevate package

`windows/packages/autoelevate/Invoke-AutoElevate.ps1` installs, upgrades and
removes the AutoElevate agent from the hash-pinned `AESetup.msi` in
`windows/releases/autoelevate.json`.

## Where the facts come from

- The MSI public properties are from the pinned `AESetup.msi` itself (its
  Property, AppSearch, RegLocator, CustomAction and InstallExecuteSequence
  tables, read with `msiinfo`) and from the vendor guide:
  <https://support.cyberfox.com/115003703811-System-Agent-Installation>.
- `LICENSE_KEY`, `COMPANY_NAME` and `LOCATION_NAME` are required on a device
  that has no stored registration. The MSI fails without them (2.9.4 and
  later). `COMPANY_INITIALS` is optional.
- The vendor guide names the mode property `ELEVATION_MODE`, with the values
  `audit` (the default), `live` and `policy`, lowercase only. The MSI also
  accepts `AGENT_MODE` as an older alias. The package sends `ELEVATION_MODE`.
  On an upgrade the agent keeps its mode, and the property has no effect.
- The MSI keeps the registration in `HKLM\SOFTWARE\AutoElevate` (64-bit view):
  `LicenseKey`, `CompanyName`, `CompanyInitials`, `CompanyID`, `LocationName`,
  `LocationID`, `ElevationMode`, `Settings`. An upgrade reads these back, which
  is why an upgrade needs no key.
- The MSI stops and replaces two services: `AutoElevateAgent` and
  `AEDelayedStartService`. `AEAlert` and `AEUACAgent` run in each user session.

## Behaviour

- **Upgrade.** Before msiexec, the package stops `AEDelayedStartService`, then
  `AutoElevateAgent`, and waits up to 60 seconds for each. If one does not
  stop, msiexec does not run. The package starts any service it already
  stopped and exits 1. The error names the service state, the start type,
  whether the service accepts a stop, its process id, and its recovery
  actions. That is the case behind MSI error 1921 followed by 1603. The
  package never kills msiexec or a service process. After the install it
  waits for `AutoElevateAgent` to run, and it checks that the installed
  version is at or above the pin. The stdout JSON reports both.
- **Fresh install, or installed but not registered.** The device counts as
  registered when the registry holds a license key, a company name and a
  location name. Otherwise the package needs `AE_LICENSE_KEY`, `CompanyName`
  and `LocationName`. Without them it exits 1 before the download. The local
  registry cannot tell whether the AutoElevate portal knows the device. If the
  Partner API does not list a device that looks registered locally, run
  `Reinstall` with the key and names.
- **Registration values** go to the MSI as a set. When any of them is given,
  the key, `CompanyName` and `LocationName` are all required. They are checked
  before the download:
  - `CompanyName` and `LocationName`: 1 to 100 letters, digits, spaces or
    `. , & ' ( ) _ -`.
  - `CompanyInitials`: 2 to 5 letters or digits.
  - `ElevationMode`: `audit`, `live` or `policy`.
  - The key: 8 to 256 of `A-Z a-z 0-9 . _ + / = -`.

  Use the company and location names exactly as the portal shows them. The
  portal generates the install command per location (Companies tab).
- **The key** comes only from the `AE_LICENSE_KEY` environment variable. The
  package reads it once and removes it from its own process. It is never a
  parameter, and it is redacted from the stdout report, from errors, and from
  the msiexec command the report prints. The MSI does not mark `LICENSE_KEY`
  hidden, so the package writes no msiexec log when it passes a key. Without
  a key, the msiexec log is at
  `%ProgramData%\Relian\autoelevate\msiexec-install.log`. msiexec still gets
  the key on its command line, which local administrators can read while it
  runs. The agent stores the key in the registry anyway.
- **`Section` `Evidence`** is read-only. It reports the installed version, the
  product code, the install path, the stored registration (the key and
  `Settings` only as `present` or `absent`), both services with their state
  and recovery actions, the AutoElevate processes, and up to 20 MsiInstaller
  events from the last 30 days that mention AutoElevate.

## Runner package arguments

These are base64 of the JSON shown. The other runner parameters are as in the
README.

| Run | `-Action` | `-PackageArguments` | JSON |
|---|---|---|---|
| Evidence | `Install` | `eyJTZWN0aW9uIjoiRXZpZGVuY2UifQ==` | `{"Section":"Evidence"}` |
| Upgrade a registered agent | `Install` | none | |
| Fresh install | `Install` | `eyJDb21wYW55TmFtZSI6IkV4YW1wbGUgQ29tcGFueSIsIkNvbXBhbnlJbml0aWFscyI6IkVDIiwiTG9jYXRpb25OYW1lIjoiTWFpbiBPZmZpY2UiLCJFbGV2YXRpb25Nb2RlIjoibGl2ZSJ9` | `{"CompanyName":"Example Company","CompanyInitials":"EC","LocationName":"Main Office","ElevationMode":"live"}` |

Make your own with `printf '%s' '<json>' | base64 -w0`.

## NinjaOne wrapper for the key

The key must not go in `-PackageArguments`, because those are kept in the
job's activity history. Keep it in a NinjaOne custom field of type Secure,
set at the organization level, with script read access. A wrapper script in
the NinjaOne library, outside this repo, reads the field into
`$env:AE_LICENSE_KEY` for its own process. It then starts the pinned runner,
which passes the variable to the package process. Replace each placeholder.
The field name here is an example.

```powershell
$ErrorActionPreference = 'Stop'
$runnerUrl = 'https://raw.githubusercontent.com/Relianco/device-scripts/<commit>/windows/runner/Invoke-RelianRunner.ps1'
$runnerSha = '<runner-sha256>'
$runner = Join-Path $env:TEMP ('relian-runner-' + [guid]::NewGuid().ToString('n') + '.ps1')
Invoke-WebRequest -Uri $runnerUrl -OutFile $runner -UseBasicParsing
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $runner).Hash -ne $runnerSha) {
    Remove-Item -LiteralPath $runner -Force
    exit 1
}
$code = 1
try {
    $env:AE_LICENSE_KEY = [string](Ninja-Property-Get autoelevateLicenseKey)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner `
        -PackageUrl 'https://raw.githubusercontent.com/Relianco/device-scripts/<commit>/windows/packages/autoelevate/Invoke-AutoElevate.ps1' `
        -PackageSha256 '<package-sha256>' `
        -ToolkitUrl '<toolkit-url>' -ToolkitSha256 '<toolkit-sha256>' `
        -BrandPackUrl '<brand-pack-url>' -BrandPackSha256 '<brand-pack-sha256>' `
        -Action 'Install' -PinVersion '2.11.1959' `
        -PackageArguments '<base64 of the fresh-install JSON>'
    $code = $LASTEXITCODE
} finally {
    Remove-Item -LiteralPath 'Env:AE_LICENSE_KEY' -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $runner -Force -ErrorAction SilentlyContinue
}
exit $code
```

Do not print the field, and do not run the wrapper with transcript logging
turned on.
