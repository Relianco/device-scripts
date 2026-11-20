# Intune install for "Relian Managed - WireGuard". The template builder puts this text in the app's
# install script, and CIPP replaces each %wg...% token with the tenant's variable. A token the tenant
# lacks stays literal, and Prepare then exits 1 without changing anything.
# The values reach the package as parameters inside this process, so none is on a command line
# (Intune caps the install command at 1024 characters, and the map key alone is longer than 500).
# A value must not contain a single quote; Prepare validates every value before it writes.
$ErrorActionPreference = 'Stop'
$settings = @{
    TunnelName              = '%wgtunnel%'
    Endpoint                = '%wgendpoint%'
    ServerPublicKey         = '%wgserverkey%'
    AllowedIPs              = '%wgallowedips%'
    NrptNamespaces          = '%wgnrptns%'
    NrptServers             = '%wgnrptdns%'
    TrustedGateways         = '%wggateways%'
    TrustedGatewayMacs      = '%wggatewaymacs%'
    MapUrl                  = '%wgmapurl%'
    MapKey                  = '%wgmapkey%'
    LegacyPattern           = '%wglegacy%'
    DisableGsaPrivateAccess = '%wgdisablepa%'
}
& ([IO.Path]::Combine($PSScriptRoot, 'Invoke-WireGuardClient.ps1')) -DeploymentType Install -Action Prepare -PinVersion '1.1.1' @settings
exit $LASTEXITCODE
