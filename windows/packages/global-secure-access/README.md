# Global Secure Access replacement

`Invoke-GlobalSecureAccess.ps1` installs the pinned x64 client, currently
2.34.222. Run as administrator or SYSTEM. It works directly and as an
`Invoke-RelianRunner.ps1` package; it does not call a management provider.

```powershell
.\Invoke-GlobalSecureAccess.ps1 -InstallerPath '.\GlobalSecureAccessInstaller_2.34.222.exe'
```

`Install` (default) and `Update` both:

1. Read GSA's machine uninstall registration in both registry views.
2. Leave 2.34.222 or newer installed clients alone. Versions compare
   numerically; 2.34.222 and 2.34.222.0 are equivalent.
3. Stage the replacement locally and verify its SHA256, product version,
   and Microsoft Authenticode signature before removing anything.
4. For an older client, run its registered, Microsoft-signed cached bundle
   with `/uninstall /quiet /norestart`. This removes the bundle's components,
   including those in older releases, rather than removing only its main MSI.
5. If removal returns 0 and registration is gone, install the replacement
   with `/install /quiet /norestart`, then check its registered version.

A clean device goes straight to installation. Missing or unreadable versions,
missing cached uninstallers, orphaned MSI registrations, or old and current
bundles coexisting fail closed. It does not uninstall equal/newer clients,
repair broken registrations, or support the runner's Repair, Reinstall, or
Uninstall actions.

The default SHA256 is
`d274b91fea1b14c4fbb59391c38905dbaa64ce57ba7fa226fedf523e06205413`.
The inspected Microsoft bundle identifies itself as 2.34.222 (x64); its PE
product version is 2.34.222.0. The installer binary is not committed or
published by this change. Supply it locally, or provide `-InstallerUrl` for
an HTTPS copy. Supply only one source. The hash must be 64 lowercase
hexadecimal characters. URLs containing userinfo, including an empty name
before `@`, are refused before discovery or download.

Downloads get at most three attempts for timeouts, connection or DNS failures,
and HTTP 408, 429, 500, 502, 503, or 504. Delays are 5 and 20 seconds.
Other HTTP errors and hash mismatches are not retried. A failed download or
hash check leaves the old client in place.

For a future target, change `PinVersion` and `InstallerSha256` together to
match the replacement. An empty pin or hash disables the package without
reading installed state or downloading. `CancelPath` and
`RELIAN_DEPLOY_CANCEL=1` stop work before the next operation, not during an
installer process.

## Exit codes and reboot

- `0`: already current or installation completed and verified.
- `3010`: reboot required. If returned by removal, installation has **not**
  run. Reboot and rerun the same command to install the replacement.
- `1641`: the installer reports a restart initiated; stop and rerun after restart.
- `130`: cancelled before the next operation.
- `1`: validation, discovery, download, or post-install verification failed.
- Other installer codes (including `1618` and `1603`) are returned unchanged.

No reboot is initiated by this script and no scheduled resume task is created.
The caller must handle reboot and rerun. Removing GSA can interrupt access
that depends on its tunnel. Stage the installer on the device before running
if its source requires that tunnel. A failed replacement is reported; there
is no automatic rollback to the old client.

## Through the runner

Use this script's pinned URL and SHA256 as the runner's `PackageUrl` and
`PackageSha256`. Pass `-Action Install -PinVersion 2.34.222`. Encode a JSON
object containing `InstallerPath` (a path on the target device), or
`InstallerUrl`, as UTF-8 base64 in `PackageArguments`:

```powershell
$json = @{ InstallerPath = 'C:\Staging\GlobalSecureAccessInstaller_2.34.222.exe' } | ConvertTo-Json -Compress
$packageArguments = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
```

The existing runner supplies its usual toolkit and brand parameters. All
GSA version checks and replacement behavior live in this Invoke package.

Microsoft documents [silent installation and uninstallation](https://learn.microsoft.com/en-us/entra/global-secure-access/how-to-install-windows-client)
and recommends [uninstalling the earlier client and restarting when troubleshooting upgrades](https://learn.microsoft.com/en-us/troubleshoot/entra/global-secure-access/troubleshoot-global-secure-access-client-windows-issues).
