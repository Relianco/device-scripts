# WireGuard network guard

`windows/packages/wireguard-network-guard/Invoke-WireGuardNetworkGuard.ps1` stops Windows `WireGuardTunnel$*` services when a laptop connects to a trusted office network and starts them again when the laptop connects to an external network. Run it directly or as SYSTEM through `windows/runner/Invoke-RelianRunner.ps1`.

## Why a running WireGuard service breaks local office access on Windows

WireGuard for Windows (`wireguard-windows`) has no built-in On-Demand or Trusted Network Detection. When you install a tunnel with `wireguard.exe /installtunnelservice C:\path\to\client.conf`, Windows registers an automatic service named `WireGuardTunnel$<name>` that brings up the `wireguard-nt` virtual adapter at boot and keeps it running on every network.

When a laptop brings that service onto the office network, four mechanisms cause local office connections to fail:

1. **Multi-VLAN default-route preemption (Longest Prefix Match):**
   When office laptops connect to a dedicated Wi-Fi VLAN (such as `192.0.2.0/24`) while servers and printers live on separate office VLANs (such as `198.51.100.0/24` and `203.0.113.0/24`), the laptop's Wi-Fi adapter only has two IPv4 routes: `192.0.2.0/24` (on-link) and `0.0.0.0/0` (the office Wi-Fi gateway `192.0.2.1`). Meanwhile, the WireGuard tunnel configures `/24` routes for `198.51.100.0/24` and `203.0.113.0/24`. Because Windows always prefers a `/24` route over `0.0.0.0/0` regardless of interface metric, Windows sends all server and printer traffic into the WireGuard tunnel instead of to the local Wi-Fi gateway.
2. **Same-subnet metric collision (`Metric = 0` vs `Metric = 256`):**
   When a laptop connects directly to a subnet listed in `AllowedIPs` (both `/24`), Windows assigns `RouteMetric = 256` (effective metric `271–311`) to the physical adapter's connected route. `wireguard-windows` adds every `AllowedIPs` route with `RouteMetric = 0` (effective metric `5` for split tunnel, `0` for full tunnel). On identical prefix lengths, WireGuard wins the metric tie-breaker and hijacks local subnet traffic.
3. **Asymmetric return routing for inbound LAN traffic:**
   When a device on another office VLAN (such as a network scanner or workstation on `198.51.100.0/24`) initiates a connection to the laptop's Wi-Fi IP (`192.0.2.50`), the packet arrives on the Wi-Fi adapter. The laptop routes its reply (`src = 192.0.2.50`, `dst = 198.51.100.10`) into the `wireguard-nt` tunnel because the `/24` tunnel route beats `0.0.0.0/0`. WireGuard drops the reply packet because `192.0.2.50` is not the laptop's tunnel IP.
4. **Stateless tunnel blackholing:**
   Because `wireguard-nt` is connectionless, the service installs its `/24` routes as soon as it starts, even if the UDP handshake to `Endpoint` fails (for example, when a guest VLAN blocks the WAN port or two devices share a peer key). A tunnel that cannot complete a handshake blackholes every subnet in `AllowedIPs`, including internal DNS.

### Why split-brain DNS on the WireGuard endpoint does not work

Pointing the tunnel `Endpoint` hostname to an internal LAN IP on the office DNS server fails for three reasons:

* **Routing loop:** If the internal IP falls inside any subnet in `AllowedIPs`, WireGuard routes the outer encrypted UDP packets into the tunnel interface itself.
* **Single DNS lookup at startup:** `WireGuardTunnel$<name>` resolves `Endpoint` only once when the Windows service starts. A laptop that starts at home caches the public WAN IP and never re-queries DNS when it roams into the office; a laptop that starts in the office caches the internal IP and cannot connect after going home.
* **Tunnel DNS leak to remote users:** When the tunnel config sets `DNS` to the internal DNS server, remote users also query that server as soon as the tunnel starts and receive the internal override.

## How `Invoke-WireGuardNetworkGuard.ps1` works

### 1. Physical gateway and Layer-2 MAC verification

During each evaluation pass (`Invoke-WgEvaluationStep`), the guard inspects only active physical hardware network adapters (`Get-NetAdapter -Physical` with `Status -eq 'Up'`, `HardwareInterface -eq $true`, `Virtual -eq $false`, excluding any `WireGuard`, `Wintun`, loopback, or `WireGuardTunnel$<name>` adapter alias).

For each physical adapter with an IPv4 default gateway (`0.0.0.0/0`), `Test-WgTrustedNetwork` checks whether the adapter matches a trusted office network rule:

* **Gateway IPv4 + Layer-2 MAC (`GatewayIpAndMac`, default):**
  The adapter's default gateway IP must match a rule in `TrustedGateways`, and `Resolve-WgGatewayMac` must confirm that the gateway's Layer-2 neighbor entry on that `InterfaceIndex` matches one of the allowed MAC addresses (`TrustedGatewayMacs` or inline `IP=MAC`).
* **Anti-spoofing ARP probe (`$script:WgProbeGateway`):**
  When a laptop wakes from sleep or joins a home or hotel network that uses the same gateway IP as an office VLAN, the Windows neighbor table (`Get-NetNeighbor`) can hold a `Stale`, `Delay`, `Probe`, `Incomplete`, or `Unreachable` entry from the previous network. Whenever the neighbor entry is not already in a confirmed `Reachable` or `Permanent` state, the guard actively probes the gateway on that specific physical `InterfaceIndex`:
  1. It binds a UDP socket to the physical adapter's IPv4 address and sets `IP_UNICAST_IF` (`SocketOptionName` `31`) to `InterfaceIndex` so the packet bypasses any lower-metric WireGuard route.
  2. It calls `iphlpapi.dll` `SendARP` with the physical adapter's source IPv4 address so Windows sends an ARP request directly on that physical interface.
  3. It polls `Get-NetNeighbor` up to three times (150 ms apart) and trusts the MAC only if the neighbor reaches `Reachable` or `Permanent`.
* **Optional Active Directory NLA (`TrustDomainAuthenticated` and `TrustedDnsSuffixes`):**
  When `TrustDomainAuthenticated` is `'true'`, a physical adapter whose `Get-NetConnectionProfile` reports `NetworkCategory -eq 'DomainAuthenticated'` (and matches `TrustedDnsSuffixes` when configured) is also treated as on the trusted network.

### 2. Service state transitions

* **On a trusted network (`onTrustedNetwork = $true`):**
  The guard finds all services matching `TunnelPattern` (default `WireGuardTunnel$*`), stops any service that is not `Stopped`, and records its service name under `stoppedByGuard` in `%ProgramData%\Relian\WireGuardNetworkGuard\state.json`. The service's `StartType` (`Automatic` or `Manual`) is left unchanged.
* **On an external network (`onTrustedNetwork = $false` with at least one active physical gateway):**
  When `ManageOffNetwork` is `'true'` (default), the guard starts any stopped service matching `TunnelPattern` whose `StartType` is not `Disabled` and that is either `Automatic` or listed in `stoppedByGuard`.
* **Disconnected / airplane mode (`physicalGateways` count is `0`):**
  When no physical adapter has an active default gateway, the guard leaves service states unchanged and waits for the next network connect event.

### 3. Scheduled task and filesystem hardening

`Install` (along with `Update`, `Repair`, and `Reinstall`):

1. Acquires the machine-wide mutex `Global\RelianWireGuardNetworkGuard` before reading or writing configuration.
2. Verifies that no path component of `%ProgramData%\Relian\WireGuardNetworkGuard` is a reparse point or junction (`Test-WgNoReparsePoint`).
3. Creates `%ProgramData%\Relian\WireGuardNetworkGuard`, stages a fresh copy of `Invoke-WireGuardNetworkGuard.ps1` and `config.json`, removes any pre-existing target file before writing so an unprivileged explicit file ACL cannot survive, and locks ownership and ACLs on both the directory and each file to `NT AUTHORITY\SYSTEM` (`S-1-5-18`) and `BUILTIN\Administrators` (`S-1-5-32-544`) with inheritance disabled.
4. Registers the scheduled task `\Relian\Relian-WireGuardNetworkGuard` running as `S-1-5-18` (`NT AUTHORITY\SYSTEM`, `RunLevel HighestAvailable`, `MultipleInstancesPolicy Queue`) with three triggers:
   * `BootTrigger` (system startup)
   * `EventTrigger` on `Microsoft-Windows-NetworkProfile/Operational` for Event IDs `10000` (network connected) and `10001` (network disconnected)
   * `EventTrigger` on `System` (`Microsoft-Windows-Power-Troubleshooter`) for Event ID `1` (wake from sleep)
5. Runs an immediate evaluation pass and prints the result as a single compact JSON line on the last line of stdout.

### 4. Clean `Uninstall`

`Uninstall` (or `-DeploymentType Uninstall`):

1. Acquires `Global\RelianWireGuardNetworkGuard` before any queued `Evaluate` process can read `config.json`.
2. Unregisters `\Relian\Relian-WireGuardNetworkGuard`.
3. Starts any `Stopped` service matching `TunnelPattern` (excluding `Disabled` services) that the guard previously stopped or that has `StartType = Automatic`, so removing the guard never leaves a laptop's VPN turned off.
4. Deletes `%ProgramData%\Relian\WireGuardNetworkGuard`. Running `Uninstall` when the guard is already absent exits `0` with `uninstalled: nothing was installed`.

## Parameters and invocation

| Parameter | Default | Description |
|---|---|---|
| `Action` | `Install` (or `DeploymentType` when `Action` is omitted) | `Install`, `Update`, `Repair`, `Reinstall`, `Evaluate`, `Check` (read-only), or `Uninstall`. |
| `TrustedGateways` | `''` | Comma- or semicolon-separated office IPv4 gateways. Each entry can be `<IPv4>` (paired with `TrustedGatewayMacs`) or `<IPv4>=<MAC1>\|<MAC2>`. |
| `TrustedGatewayMacs` | `''` | Comma-, semicolon-, or pipe-separated gateway MAC addresses (`00:53:00:11:22:33`, `00-53-00-11-22-33`, `0053.0011.2233`, or `005300112233`). |
| `TunnelPattern` | `WireGuardTunnel$*` | Comma- or semicolon-separated service patterns. Every pattern must begin with `WireGuardTunnel$`. |
| `TrustDomainAuthenticated` | `'false'` | `'true'` or `'false'`. Also treats a physical adapter with `NetworkCategory -eq 'DomainAuthenticated'` as on the trusted network. |
| `TrustedDnsSuffixes` | `''` | Optional comma- or semicolon-separated DNS suffixes (such as `office.example.invalid`) required to match on the physical adapter. |
| `AllowGatewayIpOnly` | `'false'` | `'true'` or `'false'`. Must remain `'false'` in production unless MAC verification is intentionally waived. |
| `ManageOffNetwork` | `'true'` | `'true'` or `'false'`. Starts stopped `WireGuardTunnel$*` services when connected to an external network. |
| `TaskName` | `Relian-WireGuardNetworkGuard` | Scheduled task name under `\Relian\`. |
| `InstallRoot` | `%ProgramData%\Relian\WireGuardNetworkGuard` | Directory holding `config.json`, `state.json`, and the staged script copy. |

### Runner invocation (`Invoke-RelianRunner.ps1`)

Build the base64 `-PackageArguments` string from the JSON object:

```bash
printf '{"TrustedGateways":"192.0.2.25,192.0.2.1","TrustedGatewayMacs":"00-53-00-11-22-33"}' | base64 -w0
```

* **Install / Update:**
  ```text
  -PackageUrl "https://raw.githubusercontent.com/Relianco/device-scripts/<commit>/windows/packages/wireguard-network-guard/Invoke-WireGuardNetworkGuard.ps1" -PackageSha256 "<sha256>" -ToolkitUrl "<toolkit-url>" -ToolkitSha256 "<toolkit-sha256>" -BrandPackUrl "<brand-url>" -BrandPackSha256 "<brand-sha256>" -Action "Install" -PinVersion "1.0.0" -PackageArguments "<base64-json>"
  ```
* **Uninstall:**
  Pass `-Action "Uninstall"` with the same package, toolkit, and brand pins (`-PackageArguments` can be omitted).

## Reading the JSON output

Every run prints one compact JSON object on the final line of stdout:

```json
{
  "mode": "install",
  "taskName": "Relian-WireGuardNetworkGuard",
  "onTrustedNetwork": true,
  "reasons": [
    "adapter 'Wi-Fi' matched gateway 192.0.2.25 (00-53-00-11-22-33)"
  ],
  "matchedAdapters": [
    {
      "interfaceIndex": 9,
      "interfaceAlias": "Wi-Fi",
      "gatewayIp": "192.0.2.25",
      "gatewayMac": "00-53-00-11-22-33",
      "matchType": "GatewayIpAndMac"
    }
  ],
  "physicalGateways": [
    {
      "interfaceIndex": 9,
      "interfaceAlias": "Wi-Fi",
      "gatewayIp": "192.0.2.25"
    }
  ],
  "stoppedServices": [],
  "startedServices": [],
  "services": [
    {
      "name": "WireGuardTunnel$client_00001",
      "status": "Stopped",
      "startType": "Automatic"
    }
  ],
  "errors": [],
  "verdict": "install: on trusted network (adapter 'Wi-Fi' matched gateway 192.0.2.25 (00-53-00-11-22-33)); no service state change needed",
  "timestamp": "2026-11-05T21:53:47Z",
  "version": "1.0"
}
```
