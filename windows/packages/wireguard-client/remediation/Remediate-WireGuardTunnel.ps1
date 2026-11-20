# Intune Remediation "Relian - WireGuard Tunnel", remediation. Runs as SYSTEM in 64-bit PowerShell
# with no arguments, after the detection script exits 1. It runs the staged package in Apply mode,
# which fetches and verifies the signed map again (it does not trust the detection output) and then:
#   active  - installs or updates the tunnel with the mapped address, then removes legacy tunnels
#             once the managed tunnel has a handshake under 180 seconds;
#   revoked - uninstalls the tunnel and its NRPT rules, deletes the config and key, makes a new key;
#   rotate  - uninstalls the tunnel, deletes the config and key, makes a new key.
# A missing, invalid or older map changes nothing.
$ErrorActionPreference = 'Stop'
$RelianWireGuardPin = '1.1.1'
$programData = $env:ProgramData
if ([string]::IsNullOrWhiteSpace($programData)) { $programData = 'C:\ProgramData' }
$package = [IO.Path]::Combine($programData, 'Relian', 'WireGuard', 'bin', 'Invoke-WireGuardClient.ps1')
if (-not (Test-Path -LiteralPath $package -PathType Leaf)) {
    Write-Output '{"mode":"Apply","errors":["package not staged"]}'
    exit 1
}
& $package -DeploymentType Install -Action Apply -PinVersion $RelianWireGuardPin
exit $LASTEXITCODE
