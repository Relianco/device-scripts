# Comet VSS provider guard

`windows/packages/comet-vss-provider/Invoke-CometVssProvider.ps1` keeps
`COMET_FORCE_VSS_PROVIDER=system` in the `AppEnvironmentExtra` value
(REG_MULTI_SZ) of these keys:

- `HKLM\SYSTEM\CurrentControlSet\Services\backup.delegate\Parameters`
- `HKLM\SYSTEM\CurrentControlSet\Services\backup.elevator\Parameters`

## Why

Inside a QEMU/Proxmox guest, Comet Backup can pick a VSS provider other than
the Microsoft one. That can be the QEMU guest agent's provider, or a Hyper-V IC
provider left over from a migration. The snapshot then fails with `0x8004230f`
(`The shadow copy provider had an unexpected error`). Comet then backs up the
live disk and ends the job with the warning `Couldn't get exclusive read access
... data may be corrupt or inconsistent`. Comet's troubleshooting guide gives
the fix: add the line, then restart both services.

A Comet client update can rewrite `AppEnvironmentExtra` and drop the line. Run
the package on a schedule so it puts the line back.

## Behaviour

- **`Install`** (`Update`, `Repair` too) adds the line or normalises it. It
  keeps every other entry, and their order, exactly as it found them. If the
  value has duplicates or variants, such as a different case or a different
  provider, they become one canonical line at the first variant's position.
- It runs only on a QEMU guest: `Win32_ComputerSystem` Manufacturer or Model
  contains `QEMU`, or the QEMU guest agent or its VSS provider is registered.
  On any other machine it prints `notQemuGuest`, exits 0 and changes nothing,
  unless you pass `AllowNonQemu=true`.
- It restarts `backup.delegate` and `backup.elevator` only when the value
  changed and no backup job is running. A job means a `backup-tool.exe`
  process whose command line is not one of the idle helpers
  (`delegate-server`, `elevator-server` or `stream`, bare or as
  `-Action=<name>`). If the package cannot
  read a command line, it treats the process as a running job.
- If a job is running, it writes the value, skips the restart, sets
  `HKLM\SOFTWARE\Relian\CometVssProvider\RestartPending=1`, prints
  `restartPending` and exits 0. The next idle run does the restart and clears
  the marker.
- After a write, `Services[].Lines` and `Compliant` show the re-read value;
  the old lines are in `Before`.
- **`Uninstall`** removes only the `COMET_FORCE_VSS_PROVIDER` lines. It
  follows the same restart rule.
- **`Section=Evidence`** is read-only with any action. It reports each
  service's lines (credential-looking values are redacted), whether each
  service is compliant, the manufacturer and model, the registered VSS
  providers, whether a job is running, and whether a restart is pending.
- If a value is not REG_MULTI_SZ, or only one of the two service keys exists,
  the package exits 1 without writing. If neither key exists it prints
  `cometNotInstalled` and exits 0.

The package downloads nothing. It prints one JSON line.

## Runner package arguments

| Purpose | `-Action` | `-PackageArguments` |
| --- | --- | --- |
| Read-only evidence | `Install` | `eyJTZWN0aW9uIjoiRXZpZGVuY2UifQ==` (`{"Section":"Evidence"}`) |
| Apply | `Install` | none |
| Apply on a non-QEMU machine | `Install` | `eyJBbGxvd05vblFlbXUiOiJ0cnVlIn0=` (`{"AllowNonQemu":"true"}`) |
| Remove the line | `Uninstall` | none |

Pass these with the usual runner pins: `-PackageUrl`, `-PackageSha256`,
`-ToolkitUrl`, `-ToolkitSha256`, `-BrandPackUrl`, `-BrandPackSha256` and
`-PinVersion "1.0.0"`.
