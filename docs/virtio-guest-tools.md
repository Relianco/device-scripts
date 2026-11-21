# VirtIO guest tools

`windows/packages/virtio-guest-tools/Invoke-VirtioGuestTools.ps1` installs or updates the virtio-win guest tools bundle on a Windows guest on QEMU or Proxmox. The bundle holds the VirtIO drivers, the QEMU guest agent and the SPICE agent.

## What it does

- It runs the pinned `virtio-win-guest-tools.exe` with `/install /quiet /norestart` in two cases:
  - the installed bundle is missing or older than `PinVersion`;
  - the `QEMU-GA` service is missing.
- It sets `QEMU-GA` to Automatic and starts it. If the `QEMU Guest Agent VSS Provider` service is Disabled, it sets it to Manual, which is that service's default.
- It never restarts the machine. `RebootRequired` is true when the installer exits 3010 or 1641.
- On hardware that is not QEMU, it prints `notQemuGuest` and exits 0.
- The agent needs the hypervisor's channel. On Proxmox, run `qm set <vmid> --agent enabled=1`, then power-cycle the VM. A reboot from inside the guest is not enough.
  - With no channel, the run prints `agentChannelMissing` and exits 0.
- It has no `Uninstall`. Removing VirtIO storage drivers can leave a VM unbootable.
- Logs go to `%ProgramData%\Relian\virtio-guest-tools\install-<time>.log`.

## Package arguments

`VssOption` sets the backup type the agent's VSS provider asks for. It takes a value from 1 to 5; 5 means copy-only. Upgrading the guest tools resets this setting, so the package writes it again on every run.

Leave it empty to keep the current value.

Use `{"VssOption":"5"}` on a guest where SQL Server or Comet uses VSS. Then a Proxmox backup does not break the application's backup chain.

On a guest that runs Comet Backup, also run `comet-vss-provider`.

## Version notes

- **0.1.302, the pin.** It contains the upstream vioscsi fix for clobbered SRB IDs (issue 1453, PR 1465, merged January 2026).
  - That bug gave read errors on Server 2025 under heavy IO in 0.1.285 and 0.1.292.
  - Upstream closed the issue after the reproducer ran clean on 0.1.301 and 0.1.302.
  - The Proxmox wiki still lists 0.1.271 as its conservative choice and 0.1.302 as new.
  - Pilot 0.1.302 before you roll it to Server 2025 hosts with heavy IO, such as SQL Server.
- **Older than 0.1.266.** These builds have known disk-reset and hung-IO problems with vioscsi. Update guests on 0.1.2xx builds below 0.1.266.
