# AutoElevate package

`windows/packages/autoelevate/Invoke-AutoElevate.ps1` installs, upgrades and
removes the AutoElevate agent from the hash-pinned `AESetup.msi` in
`windows/releases/autoelevate.json`.

For a service that rejects normal stop requests with error 1061, see the
[manual recovery reference](../windows/packages/autoelevate/reference/README.md).
It preserves the scoped recovery sequence and SCM helper used for that case.
It is separate from normal installation and requires review before reuse.

## Where the facts come from

- The MSI public properties are from the pinned `AESetup.msi` itself (its
  Property, AppSearch, RegLocator, CustomAction and InstallExecuteSequence
  tables, read with `msiinfo`) and from the vendor guide:
  <https://support.cyberfox.com/115003703811-System-Agent-Installation>.
- `LICENSE_KEY`, `COMPANY_NAME` and `LOCATION_NAME` are required on a device
  that has no stored registration. The MSI fails without them (2.9.4 and
  later). `COMPANY_INITIALS` is optional. The MSI also takes the key from the
  registry: AppSearch reads `HKLM\SOFTWARE\AutoElevate` `LicenseKey` (64-bit
  view) into `LICENSE_KEY_REG`, `SetLicenseKey0` copies it into
  `LICENSE_KEY_FINAL`, and `SetLicenseKey1` lets a `LICENSE_KEY` property
  override it. The checks and the stored value use `LICENSE_KEY_FINAL`.
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
  location name. Otherwise the package needs the key (`LicenseKey` or `AE_LICENSE_KEY`), `CompanyName`
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
- **The key** comes from the `LicenseKey` package argument if it is not
  empty, else from the `AE_LICENSE_KEY` environment variable. Both have the
  same validation. The package reads it once and removes the environment
  variable from its own process. It is redacted from the stdout report, from
  errors, and from the msiexec command the report prints. The runner never
  prints argument values (it reports only `invalid package arguments` and
  hash or download failures, and strips pinned URLs from error text). The
  argument way is kept in NinjaOne's activity and parameter history, and is on
  the package process command line while it runs. The environment variable is
  neither.
- **The key never goes on the msiexec command line.** Windows logs process
  command lines (Sysmon event 1, Security 4688) and Wazuh collects them. Before
  msiexec, the package writes the key itself, through .NET and with no child
  process, to `HKLM\SOFTWARE\AutoElevate` `LicenseKey` (REG_SZ, 64-bit
  view), where the MSI reads it as above. msiexec gets only `COMPANY_NAME`,
  `COMPANY_INITIALS`, `LOCATION_NAME` and `ELEVATION_MODE`. If msiexec
  fails, the package puts back what was there before, before it restarts the
  services: it removes the value on a device that had none, and restores the
  old key on a device that had one. A failed registry write exits 1 before
  msiexec runs.
- **No msiexec log.** The MSI loads the stored key into `LICENSE_KEY_REG` and
  does not hide it, so a verbose msiexec log would hold the key. The package
  writes no msiexec log. For a failed install, use `Section` `Evidence`
  (MsiInstaller events) and the MSI exit code in the report. A machine policy
  that turns on Windows Installer logging still writes one, so keep that
  policy off.
- **`Section` `Evidence`** is read-only. It reports the installed version, the
  product code, the install path, the stored registration (the key and
  `Settings` only as `present` or `absent`), both services with their state
  and recovery actions, the AutoElevate processes, and up to 20 MsiInstaller
  events from the last 30 days that mention AutoElevate.
- **Intune detection** (`Detect-AutoElevate.ps1`) counts the agent as
  installed only when all three hold: the version is at or above the pin, the
  device is registered (the same rule as above), and the `AutoElevateAgent`
  service exists. Otherwise Intune runs the install again. `Install` does
  nothing for an agent already at the pin, so a deployment that must
  re-register one runs `Uninstall` and then `Install` with the key and names.
  An agent whose service will not stop still fails with exit 1 and no msiexec
  run. Recover it by hand with the reference above.

## Runner package arguments

These are base64 of the JSON shown. The other runner parameters are as in the
README.

| Run | `-Action` | `-PackageArguments` | JSON |
|---|---|---|---|
| Evidence | `Install` | `eyJTZWN0aW9uIjoiRXZpZGVuY2UifQ==` | `{"Section":"Evidence"}` |
| Upgrade a registered agent | `Install` | none | |
| Fresh install | `Install` | `eyJDb21wYW55TmFtZSI6IkV4YW1wbGUgQ29tcGFueSIsIkNvbXBhbnlJbml0aWFscyI6IkVDIiwiTG9jYXRpb25OYW1lIjoiTWFpbiBPZmZpY2UiLCJFbGV2YXRpb25Nb2RlIjoibGl2ZSJ9` | `{"CompanyName":"Example Company","CompanyInitials":"EC","LocationName":"Main Office","ElevationMode":"live"}` |

Fresh install with the key as an argument (the value is a placeholder):

`{"LicenseKey":"TEST-KEY-0000","CompanyName":"Example Company","CompanyInitials":"EC","LocationName":"Main Office","ElevationMode":"live"}`

Make your own with `printf '%s' '<json>' | base64 -w0`.

## NinjaOne: the key from a secure field (runner 374)

This is the install path for a client without Intune. Runner 374 runs the
package with `LicenseKeyField` in `-PackageArguments`. That argument is only
the field name. The package reads the key with `Ninja-Property-Get` inside its
own process, so the key is on no command line: not in the runner's command
line, not in the package's, not in `ninjarmm-cli`'s (it gets the field name),
and not in msiexec's. NinjaOne activity history holds only the field name.
There is no msiexec log.

- The field: `autoelevateLicenseKey`, type Secure (API `TEXT_ENCRYPTED`),
  scopes Organization, Location and Device, script access Read only, API
  access Write only. Set it per organization. A device or location value
  overrides the organization value.
- `Ninja-Property-Get` comes from the NinjaOne module `NJCliPSh`
  (`C:\Program Files\WindowsPowerShell\Modules`), which the package process
  loads on first use. It works only in a process the NinjaOne agent started.
- The field is read only when `LicenseKey` and `AE_LICENSE_KEY` are empty. An
  unreadable or empty field leaves the key empty. A fresh install then exits 1
  with a reason that names the field.
- `CompanyName` and `LocationName` stay plain package arguments. Use the
  names exactly as the AutoElevate portal shows them.

Example `-PackageArguments` JSON for a fresh install:

`{"LicenseKeyField":"autoelevateLicenseKey","CompanyName":"Example Company","CompanyInitials":"EC","LocationName":"Main Office","ElevationMode":"live"}`

Do not run this with PowerShell transcription turned on.
