# Intune runs this file with no arguments.
# Exit 0 when the Sysmon64 or Sysmon service key is present. Exit 1 otherwise.
# The config file is not required. Do not dot-source the installer.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-RelianSysmonInstalled {
    param([string[]]$ServiceNames)
    if ($null -eq $ServiceNames) {
        return $false
    }
    foreach ($name in $ServiceNames) {
        if ($name -eq 'Sysmon64' -or $name -eq 'Sysmon') {
            return $true
        }
    }
    return $false
}

function Get-RelianSysmonServiceNames {
    # A missing service key is not installed. It is not an error.
    $services = @(
        @{ Name = 'Sysmon64'; Key = 'HKLM:\SYSTEM\CurrentControlSet\Services\Sysmon64' },
        @{ Name = 'Sysmon'; Key = 'HKLM:\SYSTEM\CurrentControlSet\Services\Sysmon' }
    )
    foreach ($service in $services) {
        $exists = $false
        try {
            $exists = [bool](Test-Path -LiteralPath ([string]$service['Key']))
        } catch {
            $exists = $false
        }
        if ($exists) {
            [string]$service['Name']
        }
    }
}

if ($env:RELIAN_DEPLOY_TEST -eq '1') {
    return
}

$present = $false
try {
    $present = [bool](Test-RelianSysmonInstalled -ServiceNames @(Get-RelianSysmonServiceNames))
} catch {
    $present = $false
}
# Intune treats exit 0 with empty stdout as not installed. Stderr is also a failure.
if ($present) {
    Write-Output 'Relian Sysmon'
    exit 0
}
exit 1
