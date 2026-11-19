# ninja-reset

Removes what is left of a NinjaOne agent and installs a fresh one, once per device. For a PC that was deleted in
NinjaOne, or whose agent is damaged, and will not enrol again.

Why leftovers block a reinstall: the generic agent MSI has the launch condition
`(NOT NINJA_AGENT_FOUND) OR (REMOVE~="ALL")` ("An existing version of [ProductName] is already installed"), found
through the `SOFTWARE\NinjaRMM LLC\NinjaRMMAgent` registry key. A stale `NinjaRMMAgent` service also makes a
presence-only detection (service exists) report the agent as installed.

## What it removes

From NinjaOne's own "Uninstall NinjaOne Agent" script (NinjaOne script library, the script NinjaOne support hands
out for agents that no longer check in; a copy is published at
[mennotech/ninjaone-scripts](https://github.com/mennotech/ninjaone-scripts/blob/main/Windows/Powershell/87-Uninstall%20NinjaOne%20Agent.ps1)).
NinjaOne's [Delete or Remove a Device](https://www.ninjaone.com/docs/endpoint-management/delete-or-remove-a-device/)
says deleting a device only uninstalls the agent when the device is online; an offline or broken agent stays.

1. `NinjaRMMAgent.exe -disableUninstallPrevention NOUI`, then `msiexec /x{ProductCode} /qn WRAPPED_ARGUMENTS="--mode unattended"`
   when a `NinjaRMMAgent` MSI uninstall entry exists.
2. Processes `NinjaRMMAgent`, `NinjaRMMAgentPatcher`, `njbar`, `NinjaRMMProxyProcess64`, `ncstreamer`.
3. Services `NinjaRMMAgent`, `nmsmanager`, `lockhart`, `ncstreamer` (Ninja Remote).
4. Folders: the agent folder `C:\Program Files (x86)\<org>-<location>` (from the `Location` value, the service path,
   or any direct child of Program Files that holds `NinjaRMMAgent.exe`; never a Program Files root), `C:\ProgramData\NinjaRMMAgent`,
   `C:\Program Files\NinjaRemote`.
5. Registry: `NinjaRMMAgent` uninstall entries (both views), Windows Installer product keys named `NinjaRMMAgent`,
   the EXEMSI wrapper entry, and the whole `HKLM\SOFTWARE\WOW6432Node\NinjaRMM LLC` key (agent settings, server,
   token and the device identity), plus `HKLM\SOFTWARE\NinjaRMM LLC` and `HKU\S-1-5-18\Software\NinjaRMM LLC`.

Not removed (cosmetic, from the same vendor script): the Ninja Remote printer and virtual display driver, and per-user
`Run` values.

## Install

The generic agent MSI with `TOKENID=<location token>`. NinjaOne's public generic-installer link redirects to a
versioned file on its resources CDN; the package pins that file (`InstallerUrl`, `InstallerSha256`, defaults from
`windows/releases/ninja-reset.json`). It is a plain download with no login and no token inside. The package checks
the SHA256 and the Authenticode signer (`O=NinjaOne LLC`) before it removes anything; a mismatch is not retried. An
empty `InstallerSha256` turns the package off. The agent updates itself after install, so an older pin still works;
re-pin when NinjaOne retires the file.

The token is read from `RELIAN_NINJA_TOKENID` and never printed. No MSI log is written, because a verbose MSI log
records `TOKENID`.

## Run

Report-only by default. `-Apply true` changes the device. Log and marker: `C:\ProgramData\Relian\ninja-reset\`.
`Detect-NinjaReset.ps1` is detected once `done.txt` exists; delete it to run the reset again. A service that is
marked for deletion but still loaded leaves exit 1 without installing: restart and Intune retries.
