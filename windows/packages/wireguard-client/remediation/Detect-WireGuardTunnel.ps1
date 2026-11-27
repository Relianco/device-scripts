# Intune Remediation "Relian - WireGuard Tunnel", detection. Runs hourly as SYSTEM in 64-bit
# PowerShell with no arguments. It runs the package that the Win32 app staged in
# %ProgramData%\Relian\WireGuard\bin in Report mode, which reads tenant.json, fetches and verifies
# the signed map, and prints one JSON line with the PUBLIC key (never the private key).
# Exit 1 when the map asks this device to change, so the remediation script runs. Changes nothing
# except the last accepted map serial.
$ErrorActionPreference = 'Stop'
$RelianWireGuardPin = '1.1.1'
$programData = $env:ProgramData
if ([string]::IsNullOrWhiteSpace($programData)) { $programData = 'C:\ProgramData' }
$package = [IO.Path]::Combine($programData, 'Relian', 'WireGuard', 'bin', 'Invoke-WireGuardClient.ps1')
if (-not (Test-Path -LiteralPath $package -PathType Leaf)) {
    Write-Output '{"v":1,"tunnel":null,"publicKey":null,"address":null,"service":"Absent","handshakeAge":null,"wgVersion":null,"onOfficeLan":null,"legacyTunnels":[],"mapState":"none","errors":["package not staged"]}'
    exit 0
}
& $package -DeploymentType Install -Action Report -PinVersion $RelianWireGuardPin
exit $LASTEXITCODE
