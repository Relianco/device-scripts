# WireGuard client

`windows/packages/wireguard-client/Invoke-WireGuardClient.ps1` installs WireGuard for Windows and one split tunnel that runs as a Windows service (`WireGuardTunnel$<TunnelName>`). Run it as SYSTEM through `windows/runner/Invoke-RelianRunner.ps1`.

## What it does

1. Installs the pinned WireGuard MSI (`windows/releases/wireguard-client.json`) when WireGuard is missing or older than the pin. ARM64 devices get the ARM64 MSI. A hash mismatch stops the run.
2. Creates `%ProgramData%\Relian\WireGuard` with an ACL of SYSTEM and Administrators only, **before** it writes anything. Files already in the folder are reset to that ACL.
3. Generates the private key on the device with `wg.exe genkey`. A key already in the tunnel config is kept, so the server peer stays valid across runs. The key is never printed or logged.
4. Writes `<TunnelName>.conf` with no `DNS =` line, and installs the tunnel service. When the config changes, a running tunnel is restarted. A tunnel that is stopped (for example by `wireguard-network-guard` in the office) stays stopped.
5. Optional: adds NRPT rules that send `NrptNamespaces` to `NrptServers`. Each rule is tagged `Relian WireGuard client: <TunnelName>`, and the package never changes a rule without its tag. NRPT is used instead of `DNS =` because Windows sends a query to every adapter's DNS server on a split tunnel, and a public answer can win.
6. Optional: `DisableGsaPrivateAccess=true` sets `HKCU\Software\Microsoft\Global Secure Access Client\IsPrivateAccessDisabledByUser = 1` in every loaded user hive, so Global Secure Access Private Access does not capture the same traffic. Users who are not signed in during the run are not changed.
7. Prints one JSON line with the tunnel name, address, **public key**, service state, NRPT namespaces, and the latest handshake age. Add the public key as a peer on the server.

`Uninstall` removes the tunnel service, the package's NRPT rules, the config file, and the GSA value it set. It leaves the WireGuard app installed.

## Package arguments

Base64 JSON object, all values strings:

| Key | Example | Notes |
|---|---|---|
| `TunnelName` | `office` | lower case, digits, dashes |
| `Address` | `10.99.10.10/32` | this device's tunnel address |
| `ServerPublicKey` | `AAEC…Hh8=` | the server's public key |
| `Endpoint` | `198.51.100.7:51820` | an IP avoids a stale DNS answer after sleep |
| `AllowedIPs` | `192.0.2.0/24,203.0.113.4/32` | `0.0.0.0/0` is refused. Use `/32` for hosts in ranges that home networks also use |
| `PersistentKeepalive` | `25` | optional, `0` turns it off |
| `NrptNamespaces` | `.corp.example.invalid,files.example.invalid` | optional, with `NrptServers` |
| `NrptServers` | `192.0.2.5` | optional, with `NrptNamespaces` |
| `DisableGsaPrivateAccess` | `true` | optional, default `false` |
| `Mode` | `Check` | optional; read-only report, nothing changes |

## Example

```bash
printf '%s' '{"TunnelName":"office","Address":"10.99.10.10/32","ServerPublicKey":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=","Endpoint":"198.51.100.7:51820","AllowedIPs":"192.0.2.0/24","NrptNamespaces":".corp.example.invalid","NrptServers":"192.0.2.5"}' | base64 -w0
```

Pass the result as `-PackageArguments` with the usual runner pins and `-Action Install -PinVersion 1.1.1`.
