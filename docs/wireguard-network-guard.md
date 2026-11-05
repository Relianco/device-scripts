# WireGuard network guard

This package turns off a laptop's WireGuard VPN while the laptop is on the office network, and turns the VPN back on when the laptop leaves.

You run `windows/packages/wireguard-network-guard/Invoke-WireGuardNetworkGuard.ps1` as SYSTEM, either directly or through `windows/runner/Invoke-RelianRunner.ps1`.

## Why the VPN breaks office access

WireGuard for Windows does not detect which network a laptop is on. When you install a tunnel as a Windows service (`WireGuardTunnel$<name>`), that service starts at boot and stays on everywhere.

When a user brings that laptop into the office, four routing behaviors block local servers and printers:

* **Tunnel routes beat the Wi-Fi gateway.**
  On a separate office Wi-Fi VLAN (`192.0.2.0/24`), the laptop reaches office servers (`198.51.100.0/24`) through its `0.0.0.0/0` default gateway. WireGuard adds a narrower `/24` route for `198.51.100.0/24`, and Windows always prefers `/24` over `0.0.0.0/0`.
* **Tunnel routes beat the local subnet metric.**
  When the laptop plugs directly into a `/24` subnet that is also in `AllowedIPs`, Windows gives the physical adapter a metric of `256`+. WireGuard adds its `/24` route with a metric of `0`, so the tunnel wins the tie-breaker.
* **Inbound office connections drop on reply.**
  When an office printer or PC connects to the laptop's Wi-Fi IP, the request arrives on Wi-Fi. The laptop sends its reply into the WireGuard tunnel, and WireGuard drops the packet because the source IP does not match the tunnel IP.
* **Failed handshakes blackhole office subnets.**
  WireGuard installs its `/24` routes as soon as the service starts, even before a handshake succeeds. If a guest VLAN blocks the VPN port or two laptops share one peer key, every subnet in `AllowedIPs` (including internal DNS) goes dark.

### Why internal DNS overrides fail

Changing the VPN `Endpoint` hostname on your internal DNS server does not solve the conflict:

* **Routing loop:** If the internal IP sits inside any `AllowedIPs` subnet, WireGuard routes its own encrypted UDP packets back into the tunnel.
* **One-time DNS lookup:** The Windows service looks up the `Endpoint` hostname only once when the service starts. A sleeping laptop that moves between home and the office keeps using the old IP until the service restarts.
* **Remote user impact:** When the tunnel config points `DNS` at your internal DNS server, remote users also query that server and receive the internal override.

## How the guard works

### 1. Verifies the physical office gateway

During each check, the guard inspects only active physical hardware adapters (`Get-NetAdapter -Physical`). It ignores virtual adapters, loopback interfaces, and WireGuard tunnels.

To confirm the laptop is in the office, the guard checks two things on the physical adapter:

1. **Gateway IP:** The adapter's IPv4 default gateway (`0.0.0.0/0`) must match an IP in `TrustedGateways`.
2. **Gateway MAC address:** The gateway's Layer-2 hardware address (MAC) in the Windows ARP table (`Get-NetNeighbor`) must match `TrustedGatewayMacs`.

### 2. Re-probes stale ARP entries

A home or hotel router might use the same gateway IP as your office. If a laptop sleeps at the office and wakes up at a hotel, Windows can keep the office router's MAC address in its ARP cache as `Stale`.

To prevent a false match, the guard never trusts a `Stale`, `Delay`, `Probe`, `Incomplete`, or `Unreachable` ARP entry:

1. It binds a UDP socket directly to the physical adapter (`IP_UNICAST_IF`) so the probe bypasses any active WireGuard route.
2. It calls `SendARP` (`iphlpapi.dll`) from the physical adapter's IPv4 address to force a fresh Layer-2 ARP request on the wire.
3. It polls `Get-NetNeighbor` up to three times and accepts the MAC only when Windows confirms the state is `Reachable` or `Permanent`.

### 3. Stops and starts the VPN service

* **In the office (`onTrustedNetwork: true`):**
  The guard stops any running service that matches `TunnelPattern` (default `WireGuardTunnel$*`) and records the service name in `state.json`. It leaves the service startup type (`Automatic`) alone.
* **Outside the office (`onTrustedNetwork: false`):**
  When the laptop has an active external gateway, the guard starts any stopped `WireGuardTunnel$*` service that is set to `Automatic` or listed in `state.json`. It never starts a `Disabled` service.
* **Offline or airplane mode:**
  When no physical adapter has a default gateway, the guard makes no changes and waits for the next network event.

### 4. Runs automatically on network changes

When you run `Install`, the package stages a copy of the script and `config.json` in `%ProgramData%\Relian\WireGuardNetworkGuard`. It removes any pre-existing target file before writing and locks both the folder and file ACLs to `SYSTEM` and `Administrators`.

It then registers the scheduled task `\Relian\Relian-WireGuardNetworkGuard` as `SYSTEM` with three triggers:

* **Boot:** Runs when Windows starts.
* **Network change:** Runs on `Microsoft-Windows-NetworkProfile/Operational` Event IDs `10000` (connected) and `10001` (disconnected).
* **Wake from sleep:** Runs on `Microsoft-Windows-Power-Troubleshooter` Event ID `1`.

### 5. Restores the VPN on uninstall

When you run `Uninstall`, the package removes the scheduled task, starts any non-disabled `WireGuardTunnel$*` service that the guard stopped, and deletes `%ProgramData%\Relian\WireGuardNetworkGuard`.

## Parameters

Pass parameters directly on the command line or as a base64 JSON object in `-PackageArguments`:

* **`Action`** (default `Install`):
  `Install`, `Update`, `Repair`, `Reinstall`, `Evaluate`, `Check` (read-only), or `Uninstall`.
* **`TrustedGateways`**:
  Comma-separated office gateway IPv4 addresses, such as `192.0.2.25,192.0.2.1`, or inline `IP=MAC` pairs such as `192.0.2.25=00-53-00-11-22-33`.
* **`TrustedGatewayMacs`**:
  Trusted gateway MAC address(es), such as `00-53-00-11-22-33` (colon, dash, dot, or 12-hex formats all work).
* **`TunnelPattern`** (default `WireGuardTunnel$*`):
  Service name filter. Must start with `WireGuardTunnel$`.
* **`TrustDomainAuthenticated`** (default `false`):
  Set to `true` to also trust physical adapters that Windows marks as `DomainAuthenticated`.
* **`TrustedDnsSuffixes`** (optional):
  Comma-separated DNS suffixes (such as `office.example.invalid`) required on the physical adapter.
* **`ManageOffNetwork`** (default `true`):
  Set to `false` if you only want the guard to stop tunnels in the office without starting them on external networks.

## Running the script

### Direct PowerShell

Install and evaluate right away:

```powershell
.\Invoke-WireGuardNetworkGuard.ps1 `
  -Action Install `
  -TrustedGateways '192.0.2.25,192.0.2.1' `
  -TrustedGatewayMacs '00-53-00-11-22-33'
```

Run a read-only check without changing services or tasks:

```powershell
.\Invoke-WireGuardNetworkGuard.ps1 `
  -Action Check `
  -TrustedGateways '192.0.2.25,192.0.2.1' `
  -TrustedGatewayMacs '00-53-00-11-22-33'
```

Uninstall and restore the tunnel service:

```powershell
.\Invoke-WireGuardNetworkGuard.ps1 -Action Uninstall
```

### Through `Invoke-RelianRunner.ps1`

Encode the JSON arguments as base64:

```bash
printf '%s' \
  '{"TrustedGateways":"192.0.2.25,192.0.2.1",' \
  '"TrustedGatewayMacs":"00-53-00-11-22-33"}' \
  | base64 -w0
```

Pass the encoded string in `-PackageArguments` alongside the standard runner pins (`-PackageUrl`, `-PackageSha256`, `-ToolkitUrl`, `-ToolkitSha256`, `-BrandPackUrl`, `-BrandPackSha256`, `-Action "Install"`, `-PinVersion "1.0.0"`).

To uninstall through the runner, pass `-Action "Uninstall"`. No `-PackageArguments` value is needed for `Uninstall`.

## Reading the output

Every run prints a single-line JSON summary at the end of stdout:

```json
{
  "mode": "install",
  "taskName": "Relian-WireGuardNetworkGuard",
  "onTrustedNetwork": true,
  "reasons": [
    "adapter 'Wi-Fi' matched gateway 192.0.2.25 (00-53-00-11-22-33)"
  ],
  "stoppedServices": [
    "WireGuardTunnel$client_00001"
  ],
  "startedServices": [],
  "services": [
    {
      "name": "WireGuardTunnel$client_00001",
      "status": "Stopped",
      "startType": "Automatic"
    }
  ],
  "errors": [],
  "verdict": "install: on trusted network; stopped WireGuardTunnel$client_00001"
}
```
