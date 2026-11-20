# Intune runs this file with no arguments.
# Exit 0 when WireGuard is installed at or above the floor, tenant.json parses, the device key
# <tunnel>.key exists, the staged scripts are in bin\, and the network guard task exists.
# The floor is the one $RelianWireGuardFloor line below; a template builder may replace that line.
# It never reads the key, only checks that the file exists. This file does not run setup.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$RelianWireGuardFloor = '1.1.1'

function Test-RelianWireGuardDetected {
    param(
        [string]$InstalledVersion,
        [string]$Floor,
        [string]$Root,
        [bool]$TaskPresent
    )
    try {
        if ([version]$InstalledVersion.Trim() -lt [version]$Floor) {
            return $false
        }
        $tenant = [IO.File]::ReadAllText([IO.Path]::Combine($Root, 'tenant.json')) | ConvertFrom-Json
        $tunnel = [string]$tenant.tunnel
    } catch {
        return $false
    }
    if ($tunnel -cnotmatch '^[a-z][a-z0-9-]{0,31}$') {
        return $false
    }
    $files = @([IO.Path]::Combine($Root, "$tunnel.key"))
    foreach ($name in @('Invoke-WireGuardClient.ps1', 'Detect-WireGuardTunnel.ps1', 'Remediate-WireGuardTunnel.ps1', 'Invoke-WireGuardNetworkGuard.ps1')) {
        $files += [IO.Path]::Combine($Root, 'bin', $name)
    }
    foreach ($file in $files) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            return $false
        }
    }
    return $TaskPresent
}

function Get-RelianWireGuardVersion {
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $props) { continue }
            $names = @($props.PSObject.Properties.Name)
            if ($names -contains 'DisplayName' -and [string]$props.DisplayName -ceq 'WireGuard' -and $names -contains 'DisplayVersion') {
                return [string]$props.DisplayVersion
            }
        }
    }
    return ''
}

if ($env:RELIAN_DEPLOY_TEST -eq '1') {
    return
}

$present = $false
try {
    $programData = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($programData)) { $programData = 'C:\ProgramData' }
    $task = Get-ScheduledTask -TaskPath '\Relian\' -TaskName 'Relian-WireGuardNetworkGuard' -ErrorAction SilentlyContinue
    $present = [bool](Test-RelianWireGuardDetected -InstalledVersion (Get-RelianWireGuardVersion) -Floor $RelianWireGuardFloor -Root ([IO.Path]::Combine($programData, 'Relian', 'WireGuard')) -TaskPresent ($null -ne $task))
} catch {
    $present = $false
}
# Intune treats exit 0 with empty stdout as not installed. Stderr is also a failure.
if ($present) {
    Write-Output 'Relian Managed - WireGuard'
    exit 0
}
exit 1
