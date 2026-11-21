# VirtIO guest tools

`windows/packages/virtio-guest-tools/Invoke-VirtioGuestTools.ps1` installs or updates the VirtIO drivers and the QEMU guest agent on a Windows guest on QEMU or Proxmox.

## Source

The package installs two MSIs from the fedorapeople virtio-win archive (`sourceUrl` in `windows/releases/virtio-guest-tools.json`):

- `drivers`: `virtio-win-gt-x64.msi` 0.1.302, the VirtIO drivers. Its uninstall entry is "Virtio-win-driver-installer".
- `agent`: `qemu-ga-x86_64.msi` 110.2.3, the QEMU guest agent and its VSS provider. Its uninstall entry is "QEMU guest agent".

These are the same files the 0.1.302 `virtio-win-guest-tools.exe` bundle carries (the SHA1 in the bundle manifest matches). The package downloads content-addressed copies from `relianpub` (`url` there), checked against the pinned SHA256.

The fedorapeople bot check answers any User-Agent that contains `Mozilla` with an HTML page. Windows PowerShell 5.1 sends such a User-Agent by default. For that reason the package sends `relian-device-scripts` as its User-Agent.

## Why not the bundle

The bundle is a WiX Burn chain with one rollback boundary. When the agent MSI failed with 1603 (`RegisterCom` on `qga-vss.dll`: the old VSS provider service was marked for delete, held by a backup), Burn rolled back the driver MSI as well. The guest lost NetKVM and vioserial and was off the network until someone installed them again. The package now runs each MSI on its own, so an agent failure never touches the drivers. The bundle also installed the SPICE agents, which a Proxmox server guest does not need; the package does not install them.

## Sequence

1. Refuse bad input (exit 1). An empty `PinVersion`, `DriverSha256` or `AgentSha256` exits 0 and does nothing.
2. Not a QEMU guest: `notQemuGuest`, exit 0.
3. Decide per component, from the MSI uninstall entries:
   - drivers: "Virtio-win-driver-installer" missing or below `PinVersion`;
   - agent: "QEMU guest agent" missing or below `AgentVersion`, or the `QEMU-GA` service missing (then a repair, `msiexec /famus`).
   - The bundle entry "Virtio-win-guest-tools" is reported as `BundleVersion` and never decides. It can say an older bundle is installed while the driver MSI was rolled back and is not registered at all.
4. If a step is needed and a backup runs, exit 20 (`backupRunning`) before anything changes.
5. Drivers: download, save the network (below), check for a backup again (exit 20), `msiexec /i virtio-win-gt-x64.msi /qn /norestart /l*v`, restore the network (also after a failed MSI). Failure exits 1; the agent step does not run.
6. Agent: download, then check for a cancel (exit 130) and a backup (exit 20) again. Send a stop to `QEMU-GA` and `QEMU Guest Agent VSS Provider` (without waiting on it), then wait up to 120 s until neither runs nor is marked for delete (`DeleteFlag` under the service key). If one still is, skip the MSI: exit 21 (`agentServiceHeld`). Check for a backup once more (exit 20). Then `msiexec /i qemu-ga-x86_64.msi /qn /norestart /l*v`; a failure exits 22 (`agentInstallFailed`).
7. Always: set `QEMU-GA` to Automatic and start it (also the old one after a skipped or failed agent step), keep the VSS provider from Disabled, and write `VssOption` when given.

The package never restarts the machine. `RebootRequired` is true when an MSI exits 3010 or 1641.

### Backup check

- Comet: a `backup-tool.exe` process whose arguments are not one of the idle helpers (`delegate-server`, `elevator-server`, `stream`, with or without `cmd -Action=`) is a job. An unreadable command line counts as a job.
- VSS: `vssadmin list writers` shows a writer in state 2 to 5 (waiting for freeze, thaw, post-snapshot or backup complete). Stable and failed writers do not block. Empty output counts as a backup.

### Network

A NetKVM update can give the NIC a new device instance. Static addresses survive, but DNS servers typed by hand on a DHCP adapter are lost.

Before the driver MSI the package writes every Up adapter to `network-<time>.json` in the log folder: MAC, alias, IPv4 DHCP state, addresses (`Manual` for `PrefixOrigin Manual`), default gateways (`Manual` for route protocol `NetMgmt`), the DNS servers in use, and `StaticDns`: the interface's `NameServer` value under `Tcpip\Parameters\Interfaces\{guid}` (and `Tcpip6`), which holds only hand-set servers.

After the driver MSI it waits up to 120 s for each saved MAC to be Up again. Then, on the adapter with that MAC, it adds back missing manual addresses (turning IPv4 DHCP off when the adapter was static), missing manual gateways, and the hand-set DNS servers when they differ. `NetReapplied` lists what it set; `NetMissing` lists MACs that did not come back; `NetError` lists changes that failed. Each change is tried on its own. Either one makes the run exit 1 after the agent step, with the snapshot path in `Reason`.

## Exit codes

| Exit | Status | Meaning |
|---|---|---|
| 0 | `installed`, `updated`, `current`, `agentChannelMissing`, `notQemuGuest`, `disabled` | Done or nothing to do. |
| 1 | `error` | Bad input, download or hash failure, driver MSI failure, network restore incomplete (`NetMissing` or `NetError`; this wins over 20-22), or the agent did not start with a channel present. |
| 20 | `backupRunning` | A Comet job or VSS snapshot is running. Run again later. Drivers may already be done (`DriverVersion`). |
| 21 | `agentServiceHeld` | An agent service was still running or marked for delete after 120 s. The agent MSI did not run; the drivers are installed. |
| 22 | `agentInstallFailed` | The agent MSI failed (`AgentExit`) or left the agent below the pin. The drivers are installed. |
| 130 | `cancelled` | Cancelled before an installer started. |

Logs: `%ProgramData%\Relian\virtio-guest-tools\drivers-<time>.log`, `agent-<time>.log` and `network-<time>.json`.

## Recovery

A guest that lost NetKVM (no network) after a failed bundle run:

1. From the Proxmox console, attach the virtio-win ISO of the pinned version and run `msiexec /i D:\virtio-win-gt-x64.msi /qn /norestart /l*v C:\Windows\Temp\virtio-drivers.log`, or `pnputil /add-driver D:\NetKVM\<os>\amd64\netkvm.inf /install` for the network driver alone.
2. Check each adapter's IP, gateway and DNS against the last `network-<time>.json` (if the package ran) or your records, and set hand-set DNS again with `Set-DnsClientServerAddress`.
3. For a held agent service (exit 21, or a 1603 with `0x80070430` in the agent log): stop the backup software's services, or reboot, so the old `QEMU Guest Agent VSS Provider` is deleted. Then run the package again; it installs only what is still below its pin.

## Package arguments

`VssOption` sets the backup type the agent's VSS provider asks for. It takes a value from 1 to 5; 5 means copy-only. The agent MSI resets this setting, so the package writes it after the agent step on every run.

Leave it empty to keep the current value.

Use `{"VssOption":"5"}` on a guest where SQL Server or Comet uses VSS. Then a Proxmox backup does not break the application's backup chain.

On a guest that runs Comet Backup, also run `comet-vss-provider`.

`DriverUrl`, `DriverSha256`, `AgentUrl`, `AgentSha256` and `AgentVersion` default to the pins; `PinVersion` is the driver version. Each MSI is hashed again just before msiexec runs.

`Install`, `Update` and `Repair` do the same thing: each component below its pin is installed.

## Other behaviour

- The agent needs the hypervisor's channel. On Proxmox, run `qm set <vmid> --agent enabled=1`, then power-cycle the VM. A reboot from inside the guest is not enough.
  - With no channel, the run prints `agentChannelMissing` and exits 0.
- It has no `Uninstall`. Removing VirtIO storage drivers can leave a VM unbootable.

## Version notes

- **0.1.302, the pin.** It contains the upstream vioscsi fix for clobbered SRB IDs (issue 1453, PR 1465, merged January 2026).
  - That bug gave read errors on Server 2025 under heavy IO in 0.1.285 and 0.1.292.
  - Upstream closed the issue after the reproducer ran clean on 0.1.301 and 0.1.302.
  - The Proxmox wiki still lists 0.1.271 as its conservative choice and 0.1.302 as new.
  - Pilot 0.1.302 before you roll it to Server 2025 hosts with heavy IO, such as SQL Server.
- **Older than 0.1.266.** These builds have known disk-reset and hung-IO problems with vioscsi. Update guests on 0.1.2xx builds below 0.1.266.
