# Intune install for "Relian Managed - WireGuard". The template builder puts this text in the app's
# install script, and CIPP replaces each %wg...% token with the tenant's variable. A token the tenant
# lacks stays literal, and Prepare then exits 1 without changing anything.
# The tokens sit inside one single-quoted here-string, one Name=value per line, so a one-line value
# is only data: no quote or $ in it can end the string or run code (a here-string ends only at a
# line that starts with '@, and every line here starts with a name). CIPP variables are one line.
# The values reach the package as parameters inside this process, so none is on a command line
# (Intune caps the install command at 1024 characters, and the map key alone is over 500).
# Prepare validates every value.
$ErrorActionPreference = 'Stop'
$raw = @'
TunnelName=%wgtunnel%
Endpoint=%wgendpoint%
ServerPublicKey=%wgserverkey%
AllowedIPs=%wgallowedips%
NrptNamespaces=%wgnrptns%
NrptServers=%wgnrptdns%
TrustedGateways=%wggateways%
TrustedGatewayMacs=%wggatewaymacs%
MapUrl=%wgmapurl%
MapKey=%wgmapkey%
LegacyPattern=%wglegacy%
DisableGsaPrivateAccess=%wgdisablepa%
'@
$names = @('TunnelName', 'Endpoint', 'ServerPublicKey', 'AllowedIPs', 'NrptNamespaces', 'NrptServers', 'TrustedGateways', 'TrustedGatewayMacs', 'MapUrl', 'MapKey', 'LegacyPattern', 'DisableGsaPrivateAccess')
$settings = @{}
foreach ($line in ($raw -split "`r?`n")) {
    $at = $line.IndexOf('=')
    if ($at -lt 1) { continue }
    $name = $line.Substring(0, $at)
    # A value with a line break would add lines; only the first line for each name counts.
    if ($names -ccontains $name -and -not $settings.ContainsKey($name)) { $settings[$name] = $line.Substring($at + 1).Trim() }
}
if ($settings.Count -ne $names.Count) {
    [Console]::Error.WriteLine('install settings are incomplete')
    exit 1
}
& ([IO.Path]::Combine($PSScriptRoot, 'Invoke-WireGuardClient.ps1')) -DeploymentType Install -Action Prepare -PinVersion '1.1.1' @settings
exit $LASTEXITCODE
