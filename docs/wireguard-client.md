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

## Intune: app and Remediation

The same package runs as the Win32 app **Relian Managed - WireGuard** (`intune.json`) and the Remediation **Relian - WireGuard Tunnel** (`remediation/`). The device makes its key, an enrolment job outside this repo admits the public key, and the device learns its address from a signed map. The private key never leaves the device.

### Actions

| Action | What it does |
|---|---|
| `Prepare` | Installs or upgrades the MSI, secures `%ProgramData%\Relian\WireGuard`, then makes the key in `<tunnel>.key` with `wg.exe genkey` (a key already in `<tunnel>.conf` is copied there, never replaced). Writes `tenant.json`, copies the package scripts to `bin\` and installs `wireguard-network-guard` with `TrustedGateways` and `TrustedGatewayMacs`. No tunnel. Prints the public key. Exit 1 if a required setting is empty or still a literal `%name%` |
| `Install` | As before, but the key comes from `<tunnel>.key`, then the config. A second key is never made. With `LegacyPattern`, removes matching legacy tunnels (below) |
| `Report` | Remediation detection. Prints one JSON line (below). Exit 1 when the device must change |
| `Apply` | Remediation. Fetches and verifies the map again, then runs `Install` with the mapped address, `Revoke` or `Rotate` |
| `Revoke` | Uninstalls the tunnel, removes its NRPT rules, deletes `<tunnel>.conf` and `<tunnel>.key`, makes a new key |
| `Rotate` | Uninstalls the tunnel, deletes `<tunnel>.conf` and `<tunnel>.key`, makes a new key. NRPT rules stay |
| `Uninstall` | As before. If `tenant.json` exists it also uninstalls the network guard and deletes `bin\`, `tenant.json` and `map-serial.txt`. The key stays |

Without `TunnelName`, every action except `Prepare` reads its settings from `tenant.json`.

**Legacy tunnels.** `LegacyPattern` (`client_*`: lower case, digits, `_`, `-`, one optional trailing `*`) names old `WireGuardTunnel$<name>` services. They are uninstalled, and their config files deleted, only while the managed tunnel's latest handshake is under 180 seconds. The managed tunnel never matches.

### tenant.json

Written by `Prepare`. Every value is a string: `tunnel`, `endpoint`, `serverPublicKey`, `allowedIPs`, `nrptNamespaces`, `nrptServers`, `persistentKeepalive`, `mapUrl` (https only), `mapKey`, `legacyPattern`, `disableGsaPrivateAccess`, `trustedGateways`, `trustedGatewayMacs`. `nrptNamespaces`, `nrptServers` and `legacyPattern` may be empty.

`mapKey` is an RSA public key of at least 3072 bits in .NET XML form: `<RSAKeyValue><Modulus>…</Modulus><Exponent>…</Exponent></RSAKeyValue>`.

### The map

`Report` and `Apply` fetch `mapUrl` over HTTPS (no redirect, 20 s timeout, at most 1 MB):

```json
{"payload":"<base64 of UTF-8 JSON>","sig":"<base64 RSA PKCS#1 v1.5 SHA-256 signature over the decoded payload bytes>"}
```

The payload:

```json
{"v":1,"tenant":"example.invalid","tunnel":"office","serial":12,"entries":{"<sha256>":{"state":"active","address":"10.99.10.20/32"}}}
```

- The entry key is the lower-case hex SHA-256 of the ASCII bytes of the device's base64 public key.
- `state` is `active` (with an `/32` address), `revoked` or `rotate`.
- The map is rejected when the signature fails, `v` is not 1, `tunnel` differs from `tenant.json`, or `serial` is lower than the last accepted serial in `map-serial.txt`. An equal serial is accepted. The file is updated only after a valid map.
- A rejected map is `invalid`, a failed fetch is `unavailable`. Neither changes anything on the device.

### Detection output

One compressed JSON line of at most 2048 characters. It never holds the private key:

```json
{"v":1,"tunnel":"office","publicKey":"<base64>","address":"10.99.10.20/32","service":"Running","handshakeAge":12,"wgVersion":"1.1.1","onOfficeLan":false,"legacyTunnels":[],"mapState":"active","errors":[]}
```

`service` is `Running`, `Stopped` or `Absent`. `onOfficeLan` comes from the network guard's `state.json`, or is `null`. Exit 1 when the entry is `revoked` or `rotate`, or `active` and the tunnel is absent, its address differs, or legacy tunnels remain while the handshake is under 180 s. Otherwise, and with no entry, exit 0. A tunnel the guard stopped is not a change, and `Apply` keeps it stopped.

### Win32 app

- **Install:** `Install-WireGuardIntune.ps1`. The template builder puts its text in the app's install script, and CIPP replaces the tokens `%wgtunnel%`, `%wgendpoint%`, `%wgserverkey%`, `%wgallowedips%`, `%wgnrptns%`, `%wgnrptdns%`, `%wggateways%`, `%wggatewaymacs%`, `%wgmapurl%`, `%wgmapkey%`, `%wglegacy%` and `%wgdisablepa%`. The values go to `Prepare` as parameters in the same process, not on a command line, because Intune caps the install command at 1024 characters and the map key alone is over 500. A value must not contain a single quote.
- **Uninstall:** `Invoke-WireGuardClient.ps1 -DeploymentType Uninstall -Action Uninstall -PinVersion 1.1.1`, which reads `tenant.json`.
- **Detection:** `Detect-WireGuardClient.ps1`. Exit 0 when WireGuard is at or above the floor (the one `$RelianWireGuardFloor` line), `tenant.json` parses, `<tunnel>.key` and the four staged scripts exist, and the task `\Relian\Relian-WireGuardNetworkGuard` exists.
- **Content:** this folder plus `Invoke-WireGuardNetworkGuard.ps1`, either next to the script or in `../wireguard-network-guard/`.

### Remediation

`remediation/Detect-WireGuardTunnel.ps1` and `remediation/Remediate-WireGuardTunnel.ps1`. Run hourly as SYSTEM in 64-bit PowerShell, no arguments. Both call the copy that `Prepare` staged in `bin\` (`Report` and `Apply`), so the Remediation content is the same in every tenant.
